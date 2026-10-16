// Monophonic pitch detection for the tuner. Pure Dart (unit-testable).
//
// Structure (as observed in Fender Tune): RMS gate, autocorrelation period
// (McLeod NSDF, FFT-accelerated), spectral octave correction, and a
// statistical tracker that rejects outliers and reports stability.

import 'dart:math' as math;
import 'dart:typed_data';

class _ComplexFft {
  final int n;
  final Uint32List _rev;
  final Float64List _cos, _sin;

  _ComplexFft(this.n)
      : _rev = Uint32List(n),
        _cos = Float64List(n ~/ 2),
        _sin = Float64List(n ~/ 2) {
    final bits = (math.log(n) / math.ln2).round();
    for (var i = 0; i < n; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        r |= ((i >> b) & 1) << (bits - 1 - b);
      }
      _rev[i] = r;
    }
    for (var i = 0; i < n ~/ 2; i++) {
      _cos[i] = math.cos(2 * math.pi * i / n);
      _sin[i] = math.sin(2 * math.pi * i / n);
    }
  }

  void transform(Float64List re, Float64List im, {bool inverse = false}) {
    final sgn = inverse ? -1.0 : 1.0;
    for (var i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1, step = n ~/ size;
      for (var i = 0; i < n; i += size) {
        for (var j = 0, k = 0; j < half; j++, k += step) {
          final a = i + j, b = a + half;
          final tr = re[b] * _cos[k] + sgn * im[b] * _sin[k];
          final ti = im[b] * _cos[k] - sgn * re[b] * _sin[k];
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
  }
}

class PitchReading {
  /// Detected fundamental in Hz, or null when there is no confident tone.
  final double? frequency;

  /// NSDF peak height (0..1); low values with a loud signal mean noise.
  final double clarity;
  final double rms;

  const PitchReading(this.frequency, this.clarity, this.rms);
}

class PitchDetector {
  final int sampleRate;
  final int size;
  final double keyThreshold;
  final double minClarity;
  final int _minLag, _maxLag;
  final _ComplexFft _fft;
  final Float64List _re, _im, _x, _nsdf, _spec;

  PitchDetector(
    this.sampleRate,
    this.size, {
    double minFrequency = 27,
    double maxFrequency = 1500,
    this.keyThreshold = 0.88,
    this.minClarity = 0.6,
  })  : _minLag = math.max(2, (sampleRate / maxFrequency).floor()),
        _maxLag = math.min(size - 2, (sampleRate / minFrequency).ceil()),
        _fft = _ComplexFft(size * 2),
        _re = Float64List(size * 2),
        _im = Float64List(size * 2),
        _x = Float64List(size),
        _nsdf = Float64List(size),
        _spec = Float64List(size);

  PitchReading detect(List<double> frame) {
    var mean = 0.0;
    for (var i = 0; i < size; i++) {
      mean += frame[i];
    }
    mean /= size;
    var energy = 0.0;
    for (var i = 0; i < size; i++) {
      final v = frame[i] - mean;
      _x[i] = v;
      energy += v * v;
    }
    final rms = math.sqrt(energy / size);
    if (rms < 1e-4) return PitchReading(null, 0, rms);

    // Autocorrelation via FFT of the zero-padded frame.
    _re.fillRange(0, size * 2, 0);
    _im.fillRange(0, size * 2, 0);
    _re.setRange(0, size, _x);
    _fft.transform(_re, _im);
    for (var k = 0; k < size; k++) {
      _spec[k] = math.sqrt(_re[k] * _re[k] + _im[k] * _im[k]);
    }
    for (var k = 0; k < size * 2; k++) {
      _re[k] = _re[k] * _re[k] + _im[k] * _im[k];
      _im[k] = 0;
    }
    _fft.transform(_re, _im, inverse: true);
    final scale = 1 / (2 * size);

    // NSDF n(τ) = 2 r(τ) / m(τ) with m updated incrementally.
    var m = 2 * energy;
    _nsdf[0] = 1;
    for (var tau = 1; tau <= _maxLag + 1; tau++) {
      m -= _x[tau - 1] * _x[tau - 1] + _x[size - tau] * _x[size - tau];
      _nsdf[tau] = m > 1e-12 ? 2 * _re[tau] * scale / m : 0;
    }

    // Key maxima: the highest point of each positive lobe after the first
    // negative crossing.
    final peaks = <int>[];
    var tau = 1;
    while (tau < _maxLag && _nsdf[tau] > 0) {
      tau++;
    }
    while (tau < _maxLag) {
      while (tau < _maxLag && _nsdf[tau] <= 0) {
        tau++;
      }
      var best = -1;
      while (tau < _maxLag && _nsdf[tau] > 0) {
        if (tau >= _minLag && (best < 0 || _nsdf[tau] > _nsdf[best])) best = tau;
        tau++;
      }
      if (best > 0) peaks.add(best);
    }
    if (peaks.isEmpty) return PitchReading(null, 0, rms);
    final top = peaks.map((p) => _nsdf[p]).reduce(math.max);
    final chosen = peaks.firstWhere((p) => _nsdf[p] >= keyThreshold * top);
    final clarity = _nsdf[chosen];
    if (clarity < minClarity) return PitchReading(null, clarity, rms);
    var period = _interpolate(chosen);
    var freq = sampleRate / period;

    // Octave correction for weak fundamentals: energy at odd multiples of f/2
    // plus autocorrelation support at twice the period.
    final lower = freq / 2;
    if (lower >= sampleRate / _maxLag) {
      final odd = _harmonicEnergy(lower, const [1, 3, 5, 7]);
      final even = _harmonicEnergy(lower, const [2, 4, 6, 8]);
      final t2 = (period * 2).round();
      if (even > 0 && odd > 0.35 * even && t2 <= _maxLag && _nsdf[t2] > 0.8 * clarity) {
        period = _interpolate(t2);
        freq = sampleRate / period;
      }
    }
    return PitchReading(freq, clarity, rms);
  }

  double _interpolate(int t) {
    final a = _nsdf[t - 1], b = _nsdf[t], c = _nsdf[t + 1];
    final den = a - 2 * b + c;
    return den != 0 ? t + 0.5 * (a - c) / den : t.toDouble();
  }

  double _harmonicEnergy(double f0, List<int> multiples) {
    final binHz = sampleRate / (2 * size);
    var e = 0.0;
    for (final h in multiples) {
      final k = (h * f0 / binHz).round();
      if (k + 1 >= size || k < 1) break;
      e += math.max(_spec[k - 1], math.max(_spec[k], _spec[k + 1]));
    }
    return e;
  }
}

class TrackedPitch {
  /// Smoothed MIDI value (A4 = 440 Hz), or null when nothing is tracked.
  final double? midi;
  final bool stable;

  const TrackedPitch(this.midi, this.stable);
}

/// Keeps recent estimates of the current note (semitones), rejects outliers
/// beyond the allowable deviation, and switches note after consistent outliers.
class PitchTracker {
  final int historySize;
  final double allowable;
  final double stableStd;
  final int switchAfter;
  final int holdMs;

  final List<double> _values = [];
  final List<double> _outliers = [];
  double? _smoothed;
  int _lastSeenMs = -1 << 30;

  PitchTracker({this.historySize = 8, this.allowable = 0.5, this.stableStd = 0.12, this.switchAfter = 3, this.holdMs = 1200});

  void reset() {
    _values.clear();
    _outliers.clear();
    _smoothed = null;
    _lastSeenMs = -1 << 30;
  }

  double? get _mean => _values.isEmpty ? null : _values.reduce((a, b) => a + b) / _values.length;

  double get _std {
    final m = _mean;
    if (m == null || _values.length < 2) return double.infinity;
    var s = 0.0;
    for (final v in _values) {
      s += (v - m) * (v - m);
    }
    return math.sqrt(s / (_values.length - 1));
  }

  TrackedPitch push(double? midi, int nowMs) {
    if (midi == null || !midi.isFinite) {
      if (nowMs - _lastSeenMs > holdMs) reset();
      return _state(nowMs);
    }
    _lastSeenMs = nowMs;
    final mean = _mean;
    if (mean != null && (midi - mean).abs() > allowable) {
      if (_outliers.isNotEmpty) {
        final om = _outliers.reduce((a, b) => a + b) / _outliers.length;
        if ((midi - om).abs() > allowable) _outliers.clear();
      }
      _outliers.add(midi);
      if (_outliers.length < switchAfter) return _state(nowMs);
      _values
        ..clear()
        ..addAll(_outliers.skip(_outliers.length - switchAfter));
      _outliers.clear();
      _smoothed = _mean;
      return _state(nowMs);
    }
    _outliers.clear();
    _values.add(midi);
    if (_values.length > historySize) _values.removeAt(0);
    _smoothed = _smoothed == null ? midi : _smoothed! + 0.35 * (midi - _smoothed!);
    return _state(nowMs);
  }

  TrackedPitch _state(int nowMs) {
    final active = _smoothed != null && nowMs - _lastSeenMs <= holdMs;
    return TrackedPitch(active ? _smoothed : null, active && _values.length >= 3 && _std <= stableStd);
  }
}

/// Plucked-string reference tone (Karplus–Strong with fractional delay).
Float32List pluckTone(int sampleRate, double freq, {double seconds = 2.5, int seed = 1, double gain = 0.6}) {
  final out = Float32List((sampleRate * seconds).round());
  var s = seed;
  double rnd() {
    s = (s * 1664525 + 1013904223) & 0xFFFFFFFF;
    return s / 4294967296.0;
  }

  // Loop delay = N - 0.5 (averaging the oldest two samples) + allpass delay d.
  final total = sampleRate / freq + 0.5;
  final n = (total - 0.1).floor();
  final d = total - n;
  final c = (1 - d) / (1 + d);
  final buf = Float64List(n);
  var lp = 0.0;
  for (var i = 0; i < n; i++) {
    lp += 0.6 * (rnd() * 2 - 1 - lp);
    buf[i] = lp;
  }
  final loss = math.min(0.99995, math.pow(0.5, 1 / (1.2 * freq)) / math.cos(math.pi * freq / sampleRate));
  var idx = 0;
  var apX = 0.0, apY = 0.0;
  for (var i = 0; i < out.length; i++) {
    final next = (idx + 1) % n;
    final avg = 0.5 * (buf[idx] + buf[next]);
    final y = c * avg + apX - c * apY;
    apX = avg;
    apY = y;
    out[i] = buf[idx] * gain;
    buf[idx] = loss * y;
    idx = next;
  }
  final attack = (0.004 * sampleRate).round();
  for (var i = 0; i < attack; i++) {
    out[i] *= i / attack;
  }
  return out;
}
