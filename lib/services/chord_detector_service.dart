import 'dart:math';
import 'dart:typed_data';

class ChordMatch {
  final String name;
  final String root;
  final String type;
  final int score;
  final int matchedCount;
  final int extraCount;
  final List<String> detectedNotes;

  const ChordMatch({
    required this.name,
    required this.root,
    required this.type,
    required this.score,
    required this.matchedCount,
    required this.extraCount,
    required this.detectedNotes,
  });
}

class ChordDetectorService {
  static const int sampleRate = 44100;
  static const int fftSize = 4096;

  static const List<String> noteNames = [
    'C',
    'C#',
    'D',
    'D#',
    'E',
    'F',
    'F#',
    'G',
    'G#',
    'A',
    'A#',
    'B',
  ];

  // Chord type suffix → semitone intervals from root
  static const Map<String, List<int>> _chordTypes = {
    '': [0, 4, 7],
    'm': [0, 3, 7],
    '7': [0, 4, 7, 10],
    'm7': [0, 3, 7, 10],
    'maj7': [0, 4, 7, 11],
    'dim': [0, 3, 6],
    'aug': [0, 4, 8],
    'sus2': [0, 2, 7],
    'sus4': [0, 5, 7],
  };

  static ChordMatch? detect(Float32List buffer) {
    final n = fftSize;
    final real = List<double>.filled(n, 0.0);
    final imag = List<double>.filled(n, 0.0);

    // Hann window + copy into FFT buffer
    final len = buffer.length < n ? buffer.length : n;
    for (int i = 0; i < len; i++) {
      final w = 0.5 * (1.0 - cos(2.0 * pi * i / (len - 1)));
      real[i] = buffer[i] * w;
    }

    _fft(real, imag);

    // Magnitude spectrum (first half only)
    final half = n ~/ 2;
    final mag = List<double>.filled(half, 0.0);
    for (int i = 0; i < half; i++) {
      mag[i] = sqrt(real[i] * real[i] + imag[i] * imag[i]);
    }

    final binHz = sampleRate / n; // ~10.77 Hz per bin
    final minBin = (80.0 / binHz).round().clamp(0, half - 1);
    final maxBin = (1300.0 / binHz).round().clamp(0, half - 1);

    // Noise floor
    double sum = 0;
    for (int i = minBin; i <= maxBin; i++) {
      sum += mag[i];
    }
    final mean = sum / (maxBin - minBin + 1);
    final threshold = mean * 1.55;

    // Find local peaks above threshold
    final peakBins = <int>[];
    for (int i = minBin + 1; i < maxBin; i++) {
      if (mag[i] > mag[i - 1] && mag[i] > mag[i + 1] && mag[i] > threshold) {
        peakBins.add(i);
      }
    }

    if (peakBins.isEmpty) return null;

    // Sort by magnitude, take top bins
    peakBins.sort((a, b) => mag[b].compareTo(mag[a]));
    final topBins = peakBins.take(16).toList();

    // Convert to note classes (0–11), deduped
    final noteSet = <int>{};
    final detectedNoteNames = <String>[];
    for (final bin in topBins) {
      final freq = bin * binHz;
      final midi = _freqToMidi(freq);
      if (midi != null) {
        final nc = midi % 12;
        if (noteSet.add(nc)) {
          detectedNoteNames.add(noteNames[nc]);
        }
      }
    }

    if (noteSet.length < 2) return null;

    // Match against all roots × all chord types
    ChordMatch? best;
    int bestScore = 0;

    for (int root = 0; root < 12; root++) {
      for (final entry in _chordTypes.entries) {
        final chordNotes = entry.value.map((i) => (root + i) % 12).toSet();

        int score = 0;
        int matched = 0;
        int extra = 0;
        for (final n in chordNotes) {
          if (noteSet.contains(n)) {
            score += 3;
            matched++;
          }
        }
        for (final n in noteSet) {
          if (!chordNotes.contains(n)) {
            score -= 1;
            extra++;
          }
        }
        if (noteSet.contains(root)) {
          score += 2;
        }

        if (score > bestScore) {
          bestScore = score;
          best = ChordMatch(
            name: '${noteNames[root]}${entry.key}',
            root: noteNames[root],
            type: entry.key,
            score: score,
            matchedCount: matched,
            extraCount: extra,
            detectedNotes: List.unmodifiable(detectedNoteNames),
          );
        }
      }
    }

    if (bestScore < 3) return null;
    return best;
  }

  static int? _freqToMidi(double hz) {
    if (hz <= 0) return null;
    return (69 + 12 * (log(hz / 440.0) / ln2)).round();
  }

  // Cooley-Tukey in-place FFT — n must be a power of 2
  static void _fft(List<double> real, List<double> imag) {
    final n = real.length;
    // Bit-reversal permutation
    int j = 0;
    for (int i = 1; i < n; i++) {
      int bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        double t = real[i];
        real[i] = real[j];
        real[j] = t;
        t = imag[i];
        imag[i] = imag[j];
        imag[j] = t;
      }
    }
    // Butterfly passes
    for (int len = 2; len <= n; len <<= 1) {
      final ang = -2.0 * pi / len;
      final wRe = cos(ang);
      final wIm = sin(ang);
      for (int i = 0; i < n; i += len) {
        double curRe = 1.0, curIm = 0.0;
        for (int k = 0; k < len ~/ 2; k++) {
          final uRe = real[i + k];
          final uIm = imag[i + k];
          final h = i + k + len ~/ 2;
          final vRe = real[h] * curRe - imag[h] * curIm;
          final vIm = real[h] * curIm + imag[h] * curRe;
          real[i + k] = uRe + vRe;
          imag[i + k] = uIm + vIm;
          real[h] = uRe - vRe;
          imag[h] = uIm - vIm;
          final nr = curRe * wRe - curIm * wIm;
          curIm = curRe * wIm + curIm * wRe;
          curRe = nr;
        }
      }
    }
  }
}
