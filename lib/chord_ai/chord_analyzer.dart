// Offline and live chord analysis. Pure Dart so it runs in a background isolate.
//
// Pipeline:
//   spectral peaks -> NNLS note activations -> treble/bass chroma
//   spectral flux -> tempo (autocorrelation) -> beats (dynamic programming)
//   beat-synchronous chroma -> template emissions -> Viterbi chord sequence
//   downbeat phase, key (Krumhansl + tonic chords), waveform peaks

import 'dart:math' as math;
import 'dart:typed_data';

import 'chord_theory.dart';

const int kAnalysisSampleRate = 22050;
const int _chromaN = 4096;
const int _chromaHop = 1024;
const int _onsetN = 1024;
const int _onsetHop = 512;
const int _noteLo = 36; // C2
const int _noteHi = 96; // C7
const int _noteCount = _noteHi - _noteLo + 1;

class RealFft {
  final int n;
  final Uint32List _rev;
  final Float64List _cos, _sin, _window, _re, _im;

  RealFft(this.n)
      : _rev = Uint32List(n),
        _cos = Float64List(n ~/ 2),
        _sin = Float64List(n ~/ 2),
        _window = Float64List(n),
        _re = Float64List(n),
        _im = Float64List(n) {
    final bits = (math.log(n) / math.ln2).round();
    if (1 << bits != n) throw ArgumentError('FFT size must be a power of two');
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
    for (var i = 0; i < n; i++) {
      _window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / n);
    }
  }

  /// Hann-windowed magnitude spectrum of signal[center - n/2 .. center + n/2),
  /// scaled so a full-scale sinusoid peaks near 1. [out] has n/2 + 1 entries.
  void magnitudes(Float32List signal, int center, Float64List out) {
    final start = center - n ~/ 2;
    for (var i = 0; i < n; i++) {
      final j = start + i;
      _re[_rev[i]] = (j >= 0 && j < signal.length) ? signal[j] * _window[i] : 0;
      _im[_rev[i]] = 0;
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1, step = n ~/ size;
      for (var i = 0; i < n; i += size) {
        for (var j = 0, k = 0; j < half; j++, k += step) {
          final a = i + j, b = a + half;
          final tr = _re[b] * _cos[k] + _im[b] * _sin[k];
          final ti = _im[b] * _cos[k] - _re[b] * _sin[k];
          _re[b] = _re[a] - tr;
          _im[b] = _im[a] - ti;
          _re[a] += tr;
          _im[a] += ti;
        }
      }
    }
    final scale = 4 / n;
    for (var k = 0; k <= n ~/ 2; k++) {
      out[k] = math.sqrt(_re[k] * _re[k] + _im[k] * _im[k]) * scale;
    }
  }
}

class _Peaks {
  final Float64List f = Float64List(512);
  final Float64List a = Float64List(512);
  int count = 0;
}

/// Local maxima with parabolic (log-magnitude) interpolation.
void _spectralPeaks(Float64List mags, int sr, int n, double fmin, double fmax, _Peaks peaks) {
  final binHz = sr / n;
  final k0 = math.max(2, (fmin / binHz).floor());
  final k1 = math.min(mags.length - 2, (fmax / binHz).ceil());
  var frameMax = 0.0;
  for (var k = k0; k <= k1; k++) {
    if (mags[k] > frameMax) frameMax = mags[k];
  }
  final floor = math.max(3e-4, frameMax * 0.01);
  var count = 0;
  for (var k = k0; k <= k1 && count < peaks.f.length; k++) {
    final m = mags[k];
    if (m < floor || m <= mags[k - 1] || m < mags[k + 1]) continue;
    final a = math.log(mags[k - 1] + 1e-12), b = math.log(m + 1e-12), c = math.log(mags[k + 1] + 1e-12);
    final den = a - 2 * b + c;
    final p = den != 0 ? 0.5 * (a - c) / den : 0.0;
    peaks.f[count] = (k + p) * binHz;
    peaks.a[count] = m;
    count++;
  }
  peaks.count = count;
}

double _peakWeight(double a) => math.log(1 + 100 * a);

// Approximate note transcription by non-negative least squares (after Mauch &
// Dixon's NNLS chroma). Two timbres per note (dark and bright harmonic decay)
// attribute overtones to the note producing them instead of false pitches.
const int _specLo = _noteLo, _specHi = 108;
const int _specCount = _specHi - _specLo + 1;
const int _harmonics = 8, _nnlsIterations = 30;
const List<double> _decays = [0.55, 0.95];
const int _atoms = _noteCount * 2;

class _NoteDictionary {
  final Float64List a = Float64List(_specCount * _atoms);
  final Float64List ata = Float64List(_atoms * _atoms);

  _NoteDictionary() {
    for (var d = 0; d < _decays.length; d++) {
      for (var n = 0; n < _noteCount; n++) {
        final col = d * _noteCount + n;
        var norm = 0.0;
        for (var h = 1; h <= _harmonics; h++) {
          final m = _noteLo + n + (12 * math.log(h) / math.ln2).round();
          if (m > _specHi) break;
          final w = math.pow(_decays[d], h - 1).toDouble();
          a[(m - _specLo) * _atoms + col] += w;
          norm += w * w;
        }
        norm = math.sqrt(norm);
        for (var r = 0; r < _specCount; r++) {
          a[r * _atoms + col] /= norm;
        }
      }
    }
    for (var i = 0; i < _atoms; i++) {
      for (var j = 0; j < _atoms; j++) {
        var s = 0.0;
        for (var r = 0; r < _specCount; r++) {
          s += a[r * _atoms + i] * a[r * _atoms + j];
        }
        ata[i * _atoms + j] = s;
      }
    }
  }
}

final _NoteDictionary _dict = _NoteDictionary();

class _NoteWork {
  final Float64List y = Float64List(_specCount);
  final Float64List aty = Float64List(_atoms);
  final Float64List z = Float64List(_atoms);
}

/// Writes per-note activations (summed over timbres) into [x].
void _noteActivations(_Peaks peaks, double tuning, Float64List x, _NoteWork w) {
  final a = _dict.a, ata = _dict.ata;
  w.y.fillRange(0, _specCount, 0);
  for (var i = 0; i < peaks.count; i++) {
    final midi = 69 + 12 * math.log(peaks.f[i] / 440) / math.ln2 - tuning;
    final r = midi.round();
    if (r < _specLo || r > _specHi) continue;
    w.y[r - _specLo] += math.sqrt(peaks.a[i]) * math.max(0, 1 - 2 * (midi - r).abs());
  }
  for (var n = 0; n < _atoms; n++) {
    var s = 0.0;
    for (var r = 0; r < _specCount; r++) {
      s += a[r * _atoms + n] * w.y[r];
    }
    w.aty[n] = s;
    w.z[n] = s;
  }
  for (var it = 0; it < _nnlsIterations; it++) {
    for (var n = 0; n < _atoms; n++) {
      if (w.z[n] == 0) continue;
      var ax = 0.0;
      final row = n * _atoms;
      for (var j = 0; j < _atoms; j++) {
        final zj = w.z[j];
        if (zj != 0) ax += ata[row + j] * zj;
      }
      w.z[n] *= w.aty[n] / (ax + 1e-12);
    }
  }
  for (var n = 0; n < _noteCount; n++) {
    x[n] = w.z[n] + w.z[_noteCount + n];
  }
}

/// Treble chroma from C3 upwards, bass chroma from C2 to B3.
void _foldActivations(Float64List act, Float64List treble, Float64List bass) {
  treble.fillRange(0, 12, 0);
  bass.fillRange(0, 12, 0);
  for (var p = 0; p < _noteCount; p++) {
    final v = act[p];
    if (v == 0) continue;
    final midi = _noteLo + p;
    if (midi >= 48) treble[midi % 12] += v;
    if (midi < 60) bass[midi % 12] += v;
  }
}

// ---------------------------------------------------------------------------
// Chord templates and decoding

class _Template {
  final int root;
  final String quality;
  final String name;
  final Float64List v;
  final double complexity;

  _Template(this.root, this.quality, this.name, this.v, this.complexity);
}

final Map<ChordSet, List<_Template>> _templateCache = {};

List<_Template> _templates(ChordSet set) => _templateCache.putIfAbsent(set, () {
      final list = <_Template>[];
      for (final quality in kChordSetQualities[set]!) {
        final ints = kChordQualities[quality]!;
        final complex = ints.length > 3 || const ['dim', 'aug', 'sus2', 'sus4'].contains(quality);
        for (var root = 0; root < 12; root++) {
          final v = Float64List(12);
          for (var idx = 0; idx < ints.length; idx++) {
            v[mod12(root + ints[idx])] = idx >= 3 ? 0.8 : 1;
          }
          var norm = 0.0;
          for (final x in v) {
            norm += x * x;
          }
          norm = math.sqrt(norm);
          for (var i = 0; i < 12; i++) {
            v[i] /= norm;
          }
          list.add(_Template(root, quality, chordName(root, quality), v, complex ? 0.04 : 0));
        }
      }
      return list;
    });

const double _kappa = 25;
const double _noChordSim = 0.55;

Float64List _emissions(List<double> treble, List<double> bass, bool quiet, List<_Template> tpl) {
  // Normalise chroma after removing most of the floor shared by all classes.
  final c = Float64List(12);
  final minV = treble.reduce(math.min);
  var norm = 0.0;
  for (var i = 0; i < 12; i++) {
    c[i] = treble[i] - 0.8 * minV;
    norm += c[i] * c[i];
  }
  norm = math.sqrt(norm);
  if (norm > 0) {
    for (var i = 0; i < 12; i++) {
      c[i] /= norm;
    }
  }
  var bassMax = bass.reduce(math.max);
  if (bassMax <= 0) bassMax = 1;
  final e = Float64List(tpl.length + 1);
  for (var s = 0; s < tpl.length; s++) {
    final t = tpl[s];
    var sim = 0.0;
    for (var i = 0; i < 12; i++) {
      sim += c[i] * t.v[i];
    }
    e[s] = _kappa * (sim + 0.12 * (bass[t.root] / bassMax) - t.complexity);
  }
  e[tpl.length] = _kappa * (quiet ? 1.5 : _noChordSim);
  return e;
}

class ChordGuess {
  final String name; // 'N' for no chord
  final double confidence;

  const ChordGuess(this.name, this.confidence);
}

/// Classifies a single chroma observation (live microphone mode).
ChordGuess classifyChroma(List<double> treble, List<double> bass, ChordSet set) {
  final tpl = _templates(set);
  final total = treble.fold<double>(0, (a, b) => a + b);
  final e = _emissions(treble, bass, total < 1e-6, tpl);
  var best = 0;
  for (var s = 1; s < e.length; s++) {
    if (e[s] > e[best]) best = s;
  }
  var z = 0.0;
  for (final v in e) {
    z += math.exp(v - e[best]);
  }
  return ChordGuess(best == tpl.length ? 'N' : tpl[best].name, 1 / z);
}

class DecodedChords {
  final List<String> labels;
  final List<double> confidence;

  const DecodedChords(this.labels, this.confidence);
}

/// Viterbi decoding of beat-synchronous chroma into one chord label per beat.
DecodedChords decodeChords(Float64List beatChroma, Float64List beatBass, Float64List beatEnergy, ChordSet set) {
  final tpl = _templates(set);
  final states = tpl.length + 1, t = beatEnergy.length;
  if (t == 0) return const DecodedChords([], []);
  final sorted = beatEnergy.toList()..sort();
  final quietLevel = 0.08 * sorted[sorted.length ~/ 2];
  final logStay = math.log(0.82), logSwitch = math.log(0.18 / (states - 1));
  final em = List.generate(
    t,
    (k) => _emissions(beatChroma.sublist(k * 12, k * 12 + 12), beatBass.sublist(k * 12, k * 12 + 12),
        beatEnergy[k] <= quietLevel, tpl),
  );
  var dp = Float64List.fromList(em[0]), next = Float64List(states);
  final back = List<Uint16List?>.filled(t, null);
  for (var k = 1; k < t; k++) {
    var bestPrev = 0;
    for (var s = 1; s < states; s++) {
      if (dp[s] > dp[bestPrev]) bestPrev = s;
    }
    final bp = Uint16List(states);
    for (var s = 0; s < states; s++) {
      final stay = dp[s] + logStay, sw = dp[bestPrev] + logSwitch;
      if (stay >= sw) {
        next[s] = stay + em[k][s];
        bp[s] = s;
      } else {
        next[s] = sw + em[k][s];
        bp[s] = bestPrev;
      }
    }
    back[k] = bp;
    final tmp = dp;
    dp = next;
    next = tmp;
  }
  final path = Uint16List(t);
  var s = 0;
  for (var i = 1; i < states; i++) {
    if (dp[i] > dp[s]) s = i;
  }
  for (var k = t - 1; k >= 0; k--) {
    path[k] = s;
    if (k > 0) s = back[k]![s];
  }
  final labels = List<String>.filled(t, 'N');
  final conf = List<double>.filled(t, 0);
  for (var k = 0; k < t; k++) {
    final e = em[k];
    final maxE = e.reduce(math.max);
    var z = 0.0;
    for (final v in e) {
      z += math.exp(v - maxE);
    }
    conf[k] = math.exp(e[path[k]] - maxE) / z;
    labels[k] = path[k] == tpl.length ? 'N' : tpl[path[k]].name;
  }
  if (set == ChordSet.full) _addInversions(labels, beatBass, tpl);
  return DecodedChords(labels, conf);
}

/// Marks slash chords when the bass clearly sits on a non-root chord tone.
void _addInversions(List<String> labels, Float64List beatBass, List<_Template> tpl) {
  final byName = {for (final t in tpl) t.name: t};
  var i = 0;
  while (i < labels.length) {
    var j = i;
    while (j + 1 < labels.length && labels[j + 1] == labels[i]) {
      j++;
    }
    final t = byName[labels[i]];
    if (t != null) {
      final bass = Float64List(12);
      for (var k = i; k <= j; k++) {
        for (var p = 0; p < 12; p++) {
          bass[p] += beatBass[k * 12 + p];
        }
      }
      var top = 0;
      for (var p = 1; p < 12; p++) {
        if (bass[p] > bass[top]) top = p;
      }
      final tones = kChordQualities[t.quality]!.map((iv) => mod12(t.root + iv)).toList();
      if (top != t.root && tones.contains(top) && bass[top] > 1.6 * bass[t.root]) {
        final name = chordName(t.root, t.quality, bass: top);
        for (var k = i; k <= j; k++) {
          labels[k] = name;
        }
      }
    }
    i = j + 1;
  }
}

// ---------------------------------------------------------------------------
// Rhythm

class _OnsetEnvelope {
  final Float64List env;
  final double fps;

  _OnsetEnvelope(this.env, this.fps);
}

_OnsetEnvelope _onsetEnvelope(Float32List samples, int sr) {
  final fft = RealFft(_onsetN);
  final frames = (samples.length / _onsetHop).ceil();
  final mags = Float64List(_onsetN ~/ 2 + 1), prev = Float64List(_onsetN ~/ 2 + 1);
  final env = Float64List(frames);
  for (var j = 0; j < frames; j++) {
    fft.magnitudes(samples, j * _onsetHop, mags);
    var flux = 0.0;
    for (var k = 1; k < mags.length; k++) {
      final v = math.log(1 + 100 * mags[k]);
      if (j > 0 && v > prev[k]) flux += v - prev[k];
      prev[k] = v;
    }
    env[j] = flux;
  }
  // Remove the slow trend (moving average over ±8 frames) and standardise.
  final out = Float64List(frames);
  const w = 8;
  var sum = 0.0;
  for (var j = 0; j < math.min(frames, w); j++) {
    sum += env[j];
  }
  for (var j = 0; j < frames; j++) {
    if (j + w < frames) sum += env[j + w];
    if (j - w - 1 >= 0) sum -= env[j - w - 1];
    final n = math.min(frames - 1, j + w) - math.max(0, j - w) + 1;
    out[j] = math.max(0, env[j] - sum / n);
  }
  var mean = 0.0, sq = 0.0;
  for (final v in out) {
    mean += v;
    sq += v * v;
  }
  final count = math.max(1, frames);
  mean /= count;
  final std = math.sqrt(math.max(1e-12, sq / count - mean * mean));
  for (var j = 0; j < frames; j++) {
    out[j] /= std;
  }
  return _OnsetEnvelope(out, sr / _onsetHop);
}

double _estimateTempo(Float64List env, double fps) {
  final minLag = math.max(1, (fps * 60 / 200).round()), maxLag = (fps * 60 / 55).round();
  final ac = Float64List(maxLag + 2);
  for (var lag = minLag - 1; lag <= maxLag + 1; lag++) {
    var s = 0.0;
    for (var t = lag; t < env.length; t++) {
      s += env[t] * env[t - lag];
    }
    ac[lag] = s / math.max(1, env.length - lag);
  }
  var bestLag = minLag;
  var best = double.negativeInfinity;
  for (var lag = minLag; lag <= maxLag; lag++) {
    final bpm = 60 * fps / lag;
    final dev = math.log(bpm / 115) / math.ln2 / 0.9;
    final w = ac[lag] * math.exp(-0.5 * dev * dev);
    if (w > best) {
      best = w;
      bestLag = lag;
    }
  }
  final a = ac[bestLag - 1], b = ac[bestLag], c = ac[bestLag + 1];
  final den = a - 2 * b + c;
  final lag = bestLag + (den != 0 ? 0.5 * (a - c) / den : 0);
  return 60 * fps / lag;
}

List<int> _trackBeats(Float64List env, double fps, double bpm, {double tightness = 100}) {
  final period = 60 * fps / bpm, n = env.length;
  final score = Float64List(n);
  final back = Int32List(n)..fillRange(0, n, -1);
  for (var t = 0; t < n; t++) {
    final lo = math.max(0, t - (2 * period).round()), hi = t - (period / 2).round();
    var best = double.negativeInfinity;
    var arg = -1;
    for (var tau = lo; tau <= hi; tau++) {
      final l = math.log((t - tau) / period);
      final v = score[tau] - tightness * l * l;
      if (v > best) {
        best = v;
        arg = tau;
      }
    }
    score[t] = env[t] + (arg >= 0 ? best : 0);
    back[t] = arg;
  }
  var end = math.max(0, n - period.round());
  for (var t = end; t < n; t++) {
    if (score[t] > score[end]) end = t;
  }
  final frames = <int>[];
  for (var t = end; t >= 0; t = back[t]) {
    frames.add(t);
  }
  return frames.reversed.toList();
}

// ---------------------------------------------------------------------------
// Result model

class ChordSegment {
  final String name;
  final double start;
  final double end;
  final int beat;
  final double confidence;

  const ChordSegment(this.name, this.start, this.end, this.beat, this.confidence);

  ChordSpan get span => ChordSpan(name, start, end);

  Map<String, Object?> toJson() => {'name': name, 'start': start, 'end': end, 'beat': beat, 'confidence': confidence};

  static ChordSegment fromJson(Map<String, Object?> j) => ChordSegment(j['name'] as String, (j['start'] as num).toDouble(),
      (j['end'] as num).toDouble(), j['beat'] as int, (j['confidence'] as num).toDouble());
}

List<ChordSegment> segmentsFromBeats(List<double> beats, List<String> labels, List<double> confidence, double duration) {
  final out = <ChordSegment>[];
  var start = 0;
  for (var k = 1; k <= labels.length; k++) {
    if (k < labels.length && labels[k] == labels[start]) continue;
    var c = 0.0;
    for (var i = start; i < k; i++) {
      c += confidence[i];
    }
    final end = k < beats.length ? beats[k] : duration;
    out.add(ChordSegment(labels[start], beats[start], end, start, (c / (k - start) * 100).round() / 100));
    start = k;
  }
  return out;
}

class ChordAnalysis {
  static const int formatVersion = 1;

  final double duration;
  final int tuningCents;
  final double bpm;
  final List<double> beats;
  final int downbeat;
  final ChordSet chordSet;
  final Float64List beatChroma;
  final Float64List beatBass;
  final Float64List beatEnergy;
  final List<String> beatLabels;
  final List<double> beatConfidence;
  final MusicKey key;
  final Float32List peaks;

  late final List<ChordSegment> chords = segmentsFromBeats(beats, beatLabels, beatConfidence, duration);

  ChordAnalysis({
    required this.duration,
    required this.tuningCents,
    required this.bpm,
    required this.beats,
    required this.downbeat,
    required this.chordSet,
    required this.beatChroma,
    required this.beatBass,
    required this.beatEnergy,
    required this.beatLabels,
    required this.beatConfidence,
    required this.key,
    required this.peaks,
  });

  /// Re-decodes the stored beat features with another vocabulary (fast; no audio needed).
  ChordAnalysis withChordSet(ChordSet set) {
    final d = decodeChords(beatChroma, beatBass, beatEnergy, set);
    return _copy(chordSet: set, labels: d.labels, confidence: d.confidence);
  }

  /// Replaces the chord from [beat] up to the next chord change (user edit).
  ChordAnalysis withEditedChord(int beat, String name) {
    final labels = List<String>.of(beatLabels);
    final old = labels[beat];
    for (var i = beat; i < labels.length && (i == beat || labels[i] == old); i++) {
      labels[i] = name;
    }
    return _copy(labels: labels);
  }

  ChordAnalysis _copy({ChordSet? chordSet, List<String>? labels, List<double>? confidence}) => ChordAnalysis(
        duration: duration,
        tuningCents: tuningCents,
        bpm: bpm,
        beats: beats,
        downbeat: downbeat,
        chordSet: chordSet ?? this.chordSet,
        beatChroma: beatChroma,
        beatBass: beatBass,
        beatEnergy: beatEnergy,
        beatLabels: labels ?? beatLabels,
        beatConfidence: confidence ?? beatConfidence,
        key: key,
        peaks: peaks,
      );

  Map<String, Object?> toJson() => {
        'formatVersion': formatVersion,
        'duration': duration,
        'tuningCents': tuningCents,
        'bpm': bpm,
        'beats': beats,
        'downbeat': downbeat,
        'chordSet': chordSet.name,
        'beatChroma': beatChroma,
        'beatBass': beatBass,
        'beatEnergy': beatEnergy,
        'beatLabels': beatLabels,
        'beatConfidence': beatConfidence,
        'key': key.toJson(),
        'peaks': peaks,
      };

  static ChordAnalysis? tryFromJson(Map<String, Object?> j) {
    if (j['formatVersion'] != formatVersion) return null;
    List<double> doubles(String k) => (j[k] as List).map((e) => (e as num).toDouble()).toList();
    return ChordAnalysis(
      duration: (j['duration'] as num).toDouble(),
      tuningCents: j['tuningCents'] as int,
      bpm: (j['bpm'] as num).toDouble(),
      beats: doubles('beats'),
      downbeat: j['downbeat'] as int,
      chordSet: ChordSet.values.byName(j['chordSet'] as String),
      beatChroma: Float64List.fromList(doubles('beatChroma')),
      beatBass: Float64List.fromList(doubles('beatBass')),
      beatEnergy: Float64List.fromList(doubles('beatEnergy')),
      beatLabels: (j['beatLabels'] as List).cast<String>(),
      beatConfidence: doubles('beatConfidence'),
      key: MusicKey.fromJson(Map<String, Object?>.from(j['key'] as Map)),
      peaks: Float32List.fromList(doubles('peaks')),
    );
  }
}

typedef AnalysisProgress = void Function(double fraction, String label);

/// Full analysis of mono [samples] at [sr] (normally [kAnalysisSampleRate]).
ChordAnalysis analyzeChords(Float32List samples, {int sr = kAnalysisSampleRate, ChordSet chordSet = ChordSet.basic, AnalysisProgress? onProgress}) {
  final duration = samples.length / sr;
  final fft = RealFft(_chromaN);
  final mags = Float64List(_chromaN ~/ 2 + 1);
  final peaks = _Peaks();
  final frames = (samples.length / _chromaHop).ceil();

  // 1. Global tuning offset (circular mean of peak deviations from 12-TET).
  onProgress?.call(0.02, 'Akort sapması ölçülüyor');
  var tx = 0.0, ty = 0.0;
  for (var i = 0; i < frames; i += 8) {
    fft.magnitudes(samples, i * _chromaHop, mags);
    _spectralPeaks(mags, sr, _chromaN, 80, 2000, peaks);
    for (var p = 0; p < peaks.count; p++) {
      final midi = 69 + 12 * math.log(peaks.f[p] / 440) / math.ln2;
      final w = _peakWeight(peaks.a[p]), ang = 2 * math.pi * (midi - midi.round());
      tx += w * math.cos(ang);
      ty += w * math.sin(ang);
    }
  }
  final tuning = (tx != 0 || ty != 0) ? math.atan2(ty, tx) / (2 * math.pi) : 0.0;

  // 2. Chroma, bass chroma and energy per frame.
  final treble = Float64List(frames * 12), bass = Float64List(frames * 12), energy = Float64List(frames);
  final tr = Float64List(12), bs = Float64List(12), act = Float64List(_noteCount);
  final work = _NoteWork();
  for (var i = 0; i < frames; i++) {
    fft.magnitudes(samples, i * _chromaHop, mags);
    _spectralPeaks(mags, sr, _chromaN, 30, 4200, peaks);
    _noteActivations(peaks, tuning, act, work);
    _foldActivations(act, tr, bs);
    treble.setRange(i * 12, i * 12 + 12, tr);
    bass.setRange(i * 12, i * 12 + 12, bs);
    var e = 0.0;
    for (var p = 0; p < peaks.count; p++) {
      e += peaks.a[p] * peaks.a[p];
    }
    energy[i] = e;
    if (i % 200 == 0) onProgress?.call(0.05 + 0.6 * i / frames, 'Kroma özellikleri çıkarılıyor');
  }

  // 3. Tempo and beats.
  onProgress?.call(0.7, 'Vuruşlar bulunuyor');
  final onset = _onsetEnvelope(samples, sr);
  var bpm = _estimateTempo(onset.env, onset.fps);
  var beatTimes = _trackBeats(onset.env, onset.fps, bpm).map((j) => j * _onsetHop / sr).toList();
  if (beatTimes.length < 4 || !bpm.isFinite) {
    bpm = 120;
    beatTimes = [for (var t = 0.0; t < duration; t += 0.5) t];
  } else {
    final period = 60 / bpm;
    while (beatTimes.first - period > -0.05) {
      beatTimes.insert(0, math.max(0, beatTimes.first - period));
    }
    while (beatTimes.last + period < duration - 0.05) {
      beatTimes.add(beatTimes.last + period);
    }
  }

  // 4. Beat-synchronous features.
  final k = beatTimes.length;
  final beatChroma = Float64List(k * 12), beatBass = Float64List(k * 12), beatEnergy = Float64List(k);
  final beatAccent = Float64List(k);
  for (var b = 0; b < k; b++) {
    final s = beatTimes[b], e = b + 1 < k ? beatTimes[b + 1] : math.min(duration, s + 60 / bpm);
    final i0 = math.max(0, (s * sr / _chromaHop).round());
    final i1 = math.min(frames, math.max(i0 + 1, (e * sr / _chromaHop).round()));
    for (var i = i0; i < i1; i++) {
      for (var p = 0; p < 12; p++) {
        beatChroma[b * 12 + p] += treble[i * 12 + p];
        beatBass[b * 12 + p] += bass[i * 12 + p];
      }
      beatEnergy[b] += energy[i];
    }
    final n = math.max(1, i1 - i0);
    for (var p = 0; p < 12; p++) {
      beatChroma[b * 12 + p] /= n;
      beatBass[b * 12 + p] /= n;
    }
    beatEnergy[b] /= n;
    beatAccent[b] = onset.env[math.min(onset.env.length - 1, (s * sr / _onsetHop).round())];
  }

  // 5. Chords.
  onProgress?.call(0.85, 'Akor dizisi çözülüyor');
  final decoded = decodeChords(beatChroma, beatBass, beatEnergy, chordSet);
  final labels = decoded.labels;

  // 6. Downbeat phase: chord changes and accents tend to fall on beat 1.
  var downbeat = 0;
  var bestPhase = double.negativeInfinity;
  for (var p = 0; p < 4; p++) {
    var sc = 0.0;
    for (var b = p; b < k; b += 4) {
      if (b > 0 && labels[b] != labels[b - 1]) sc += 1;
      sc += 0.15 * beatAccent[b];
    }
    if (sc > bestPhase) {
      bestPhase = sc;
      downbeat = p;
    }
  }

  // 7. Key from energy-weighted chroma combined with the decoded chords.
  final keyChroma = List<double>.filled(12, 0);
  for (var b = 0; b < k; b++) {
    final w = math.sqrt(beatEnergy[b]);
    for (var p = 0; p < 12; p++) {
      keyChroma[p] += beatChroma[b * 12 + p] * w;
    }
  }
  final spans = segmentsFromBeats(beatTimes, labels, decoded.confidence, duration).map((c) => c.span).toList();
  final key = chooseKey(keyChroma, spans);

  onProgress?.call(0.97, 'Tamamlanıyor');
  return ChordAnalysis(
    duration: duration,
    tuningCents: (tuning * 100).round(),
    bpm: (bpm * 10).round() / 10,
    beats: beatTimes,
    downbeat: downbeat,
    chordSet: chordSet,
    beatChroma: beatChroma,
    beatBass: beatBass,
    beatEnergy: beatEnergy,
    beatLabels: labels,
    beatConfidence: decoded.confidence,
    key: key,
    peaks: waveformPeaks(samples, 600),
  );
}

Float32List waveformPeaks(Float32List samples, int buckets) {
  final out = Float32List(buckets);
  final size = math.max(1, samples.length ~/ buckets);
  for (var b = 0; b < buckets; b++) {
    var m = 0.0;
    final end = math.min(samples.length, (b + 1) * size);
    for (var i = b * size; i < end; i++) {
      final v = samples[i].abs();
      if (v > m) m = v;
    }
    out[b] = m;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Live microphone tracking

/// Real-time chord tracker for raw microphone buffers. Uses the same NNLS
/// chroma and templates as the offline analyzer, with exponential smoothing
/// and hysteresis (a new chord must win [holdFrames] consecutive frames).
class LiveChordTracker {
  final int sampleRate;
  final int fftSize;
  final int holdFrames;
  ChordSet chordSet;

  final RealFft _fft;
  final Float64List _mags;
  final _Peaks _peaks = _Peaks();
  final _NoteWork _work = _NoteWork();
  final Float64List _act = Float64List(_noteCount);
  final Float64List _tr = Float64List(12), _bs = Float64List(12);
  final Float64List _smoothT = Float64List(12), _smoothB = Float64List(12);
  final Float32List _ring;
  int _filled = 0;
  String _candidate = 'N';
  int _candidateCount = 0;
  String current = 'N';
  double level = 0;

  LiveChordTracker({this.sampleRate = 44100, this.fftSize = 8192, this.holdFrames = 3, this.chordSet = ChordSet.basic})
      : _fft = RealFft(fftSize),
        _mags = Float64List(fftSize ~/ 2 + 1),
        _ring = Float32List(fftSize);

  void reset() {
    _filled = 0;
    _smoothT.fillRange(0, 12, 0);
    _smoothB.fillRange(0, 12, 0);
    _candidate = 'N';
    _candidateCount = 0;
    current = 'N';
  }

  /// Appends samples; returns the new stable chord when it changes, else null.
  ChordGuess? addSamples(Float32List buffer) {
    // Keep the latest fftSize samples in a sliding window.
    if (buffer.length >= fftSize) {
      _ring.setRange(0, fftSize, buffer, buffer.length - fftSize);
      _filled = fftSize;
    } else {
      final keep = math.min(_filled, fftSize - buffer.length);
      _ring.setRange(0, keep, _ring, _filled - keep);
      _ring.setRange(keep, keep + buffer.length, buffer);
      _filled = keep + buffer.length;
    }
    if (_filled < fftSize) return null;
    _fft.magnitudes(_ring, fftSize ~/ 2, _mags);
    _spectralPeaks(_mags, sampleRate, fftSize, 30, 4200, _peaks);
    var lvl = 0.0;
    for (var p = 0; p < _peaks.count; p++) {
      lvl = math.max(lvl, _peaks.a[p]);
    }
    level = lvl;
    _noteActivations(_peaks, 0, _act, _work);
    _foldActivations(_act, _tr, _bs);
    for (var i = 0; i < 12; i++) {
      _smoothT[i] = 0.65 * _smoothT[i] + 0.35 * _tr[i];
      _smoothB[i] = 0.65 * _smoothB[i] + 0.35 * _bs[i];
    }
    final guess = lvl < 0.002 ? const ChordGuess('N', 0) : classifyChroma(_smoothT, _smoothB, chordSet);
    if (guess.name == _candidate) {
      _candidateCount++;
    } else {
      _candidate = guess.name;
      _candidateCount = 1;
    }
    if (_candidateCount >= holdFrames && guess.name != current) {
      current = guess.name;
      return guess;
    }
    return null;
  }

  /// Pitch classes currently sounding most strongly (for display).
  List<String> activeNotes({int max = 4}) {
    final idx = List.generate(12, (i) => i)..sort((a, b) => _smoothT[b].compareTo(_smoothT[a]));
    final top = _smoothT[idx.first];
    if (top <= 0) return const [];
    return idx.where((i) => _smoothT[i] >= 0.35 * top).take(max).map((i) => kSharpNames[i]).toList();
  }
}
