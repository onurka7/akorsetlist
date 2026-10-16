import 'dart:math' as math;
import 'dart:typed_data';

import 'package:akor_setlist/chord_ai/audio_decoder.dart';
import 'package:akor_setlist/chord_ai/chord_ai_service.dart';
import 'package:akor_setlist/chord_ai/chord_analyzer.dart';
import 'package:akor_setlist/chord_ai/chord_theory.dart';
import 'package:flutter_test/flutter_test.dart';

// ---- Small deterministic synthesiser (Karplus–Strong guitar, bass, drums) ----

double _hz(int midi) => 440 * math.pow(2, (midi - 69) / 12).toDouble();

void _pluck(Float32List out, int sr, double start, int midi, double dur, double gain, math.Random rnd) {
  final f = _hz(midi);
  final period = math.max(2, (sr / f - 0.5).round());
  final buf = Float32List(period);
  var lp = 0.0;
  for (var i = 0; i < period; i++) {
    lp += 0.5 * (rnd.nextDouble() * 2 - 1 - lp);
    buf[i] = lp * 2;
  }
  final loss = math.min(0.99995, math.pow(0.5, 1 / (0.9 * f)) / math.cos(math.pi * f / sr));
  final s0 = (start * sr).round(), n = math.min(out.length - s0, (dur * sr).round());
  var idx = 0;
  for (var i = 0; i < n; i++) {
    final next = (idx + 1) % period;
    final v = buf[idx];
    buf[idx] = loss * 0.5 * (v + buf[next]);
    idx = next;
    out[s0 + i] += v * gain;
  }
}

void _kick(Float32List out, int sr, double start) {
  final s0 = (start * sr).round(), n = math.min(out.length - s0, (0.18 * sr).round());
  var phase = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / sr;
    phase += 2 * math.pi * (50 + 90 * math.exp(-t * 30)) / sr;
    out[s0 + i] += math.sin(phase) * math.exp(-t * 18) * 0.45;
  }
}

Float32List renderProgression(List<(String, int)> prog, {double bpm = 96, int sr = kAnalysisSampleRate}) {
  final beat = 60 / bpm;
  final totalBeats = prog.fold<int>(0, (a, e) => a + e.$2);
  final out = Float32List(((totalBeats * beat + 1.5) * sr).ceil());
  final rnd = math.Random(7);
  const tuning = [40, 45, 50, 55, 59, 64];
  var b = 0;
  for (final (name, beats) in prog) {
    final c = parseChord(name)!;
    final v = findVoicings(name, ChordInstrument.guitar, count: 1).first;
    for (var i = 0; i < beats; i++) {
      final t = (b + i) * beat;
      if (i.isEven) {
        var k = 0;
        for (var s = 0; s < 6; s++) {
          if (v.frets[s] >= 0) _pluck(out, sr, t + 0.012 * k++, tuning[s] + v.frets[s], beat * 2.05, 0.2, rnd);
        }
      }
      _pluck(out, sr, t, 40 + mod12((c.bass ?? c.root) - 4), beat * 0.95, 0.35, rnd);
      if ((b + i).isEven) _kick(out, sr, t);
    }
    b += beats;
  }
  var peak = 0.0;
  for (final v in out) {
    peak = math.max(peak, v.abs());
  }
  for (var i = 0; i < out.length; i++) {
    out[i] *= 0.85 / peak;
  }
  return out;
}

double accuracy(List<(String, int)> prog, double bpm, ChordAnalysis a, {bool ignoreBass = false}) {
  final beat = 60 / bpm;
  final ref = <(String, double, double)>[];
  var t = 0.0;
  for (final (name, beats) in prog) {
    ref.add((name, t, t + beats * beat));
    t += beats * beat;
  }
  var hit = 0, total = 0;
  for (var x = 0.05; x < t; x += 0.05) {
    final r = ref.firstWhere((e) => x >= e.$2 && x < e.$3).$1;
    final d = a.chords.where((c) => x >= c.start && x < c.end).map((c) => c.name).firstOrNull;
    total++;
    if (d != null && (ignoreBass ? d.split('/').first : d) == r) hit++;
  }
  return hit / total;
}

const demo = [
  ('Am', 4), ('F', 4), ('C', 4), ('G', 4), ('Am', 4), ('F', 4), ('C', 4), ('G', 4),
  ('Dm', 4), ('Am', 4), ('E', 4), ('Am', 4),
];

void main() {
  test('FFT recovers a sinusoid', () {
    const n = 4096;
    final x = Float32List.fromList(List.generate(n * 2, (i) => 0.5 * math.sin(2 * math.pi * 440 * i / kAnalysisSampleRate)));
    final mags = Float64List(n ~/ 2 + 1);
    RealFft(n).magnitudes(x, n, mags);
    var k = 0;
    for (var i = 1; i < mags.length; i++) {
      if (mags[i] > mags[k]) k = i;
    }
    expect((k * kAnalysisSampleRate / n - 440).abs(), lessThan(kAnalysisSampleRate / n));
    expect(mags[k], closeTo(0.5, 0.15));
  });

  test('basic vocabulary: chords, tempo and key of the demo progression', () {
    final audio = renderProgression(demo);
    final sw = Stopwatch()..start();
    final a = analyzeChords(audio);
    final acc = accuracy(demo, 96, a);
    // ignore: avoid_print
    print('basic acc=${(acc * 100).toStringAsFixed(1)}% bpm=${a.bpm} key=${a.key.name()} '
        'chords=${a.chords.map((c) => c.name).join(' ')} ${sw.elapsedMilliseconds}ms');
    expect(acc, greaterThan(0.85));
    expect((a.bpm - 96).abs() < 3 || (a.bpm - 192).abs() < 6, isTrue);
    expect(a.key.name(), 'Am');
  });

  test('full vocabulary recognises sevenths and suspended chords', () {
    const prog = [('Cmaj7', 4), ('Am7', 4), ('Dm7', 4), ('G7', 4), ('Dsus4', 4), ('D', 4), ('Em', 4), ('Bdim', 4)];
    final a = analyzeChords(renderProgression(prog, bpm: 100), chordSet: ChordSet.full);
    final acc = accuracy(prog, 100, a, ignoreBass: true);
    // ignore: avoid_print
    print('full acc=${(acc * 100).toStringAsFixed(1)}% chords=${a.chords.map((c) => c.name).join(' ')}');
    expect(acc, greaterThan(0.6));
  });

  test('re-decoding, edits, JSON round trip and timed sheet', () {
    final a = analyzeChords(renderProgression(const [('G', 8), ('C', 8)], bpm: 100), chordSet: ChordSet.full);
    final basic = a.withChordSet(ChordSet.basic);
    expect(basic.beatLabels.every((l) => !l.contains('7')), isTrue);
    final edited = basic.withEditedChord(4, 'Bm7');
    expect(edited.beatLabels[4], 'Bm7');
    final restored = ChordAnalysis.tryFromJson(Map<String, Object?>.from(
        // simulate jsonEncode/jsonDecode numeric widening
        edited.toJson().map((k, v) => MapEntry(k, v is Float64List || v is Float32List ? (v as List).toList() : v))))!;
    expect(restored.beatLabels, edited.beatLabels);
    expect(restored.chords.length, edited.chords.length);
    final sheet = toTimedChordSheet(edited, transpose: 2);
    final chords = sheet.lines.expand((l) => l.segments).map((s) => s.chord).whereType<String>().toSet();
    expect(chords.contains('A'), isTrue); // G + 2
    expect(sheet.bpm, closeTo(100, 4));
  });

  test('live tracker settles on the strummed chord', () {
    final audio = renderProgression(const [('D', 8)], bpm: 100, sr: 44100);
    final tracker = LiveChordTracker(sampleRate: 44100);
    final changes = <String>[];
    for (var i = 0; i + 4096 <= audio.length; i += 4096) {
      final g = tracker.addSamples(Float32List.sublistView(audio, i, i + 4096));
      if (g != null) changes.add(g.name);
    }
    // The clip ends in silence, so the tracker should report D and then N.
    expect(changes.where((c) => c != 'N').toList(), ['D']);
  });

  test('WAV decoding and resampling', () {
    const sr = 44100;
    final frames = sr * 3;
    final bytes = ByteData(44 + frames * 4);
    void ascii(int o, String s) {
      for (var i = 0; i < 4; i++) {
        bytes.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    bytes.setUint32(4, 36 + frames * 4, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 2, Endian.little);
    bytes.setUint32(24, sr, Endian.little);
    bytes.setUint32(28, sr * 4, Endian.little);
    bytes.setUint16(32, 4, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    bytes.setUint32(40, frames * 4, Endian.little);
    for (var f = 0; f < frames; f++) {
      final v = (math.sin(2 * math.pi * 440 * f / sr) * 16000).round();
      bytes.setInt16(44 + f * 4, v, Endian.little);
      bytes.setInt16(46 + f * 4, v, Endian.little);
    }
    final mono = AudioDecoder.decodeWav(bytes.buffer.asUint8List(), targetRate: kAnalysisSampleRate);
    expect(mono.length, closeTo(frames / 2, 2));
    expect(mono.reduce(math.max), closeTo(16000 / 32768, 0.03));
  });

  test('theory: parsing, voicings, capo, numerals', () {
    expect(parseChord('C/E')!.bass, 4);
    expect(parseChord('N'), isNull);
    expect(transposeChord('Bb/D', 2), 'C/E');
    expect(findVoicings('C', ChordInstrument.guitar, count: 1).first.frets, [-1, 3, 2, 0, 1, 0]);
    expect(findVoicings('F', ChordInstrument.guitar, count: 1).first.barre, isNotNull);
    expect(findVoicings('Am', ChordInstrument.ukulele, count: 1).first.frets, [2, 0, 0, 0]);
    final capo = suggestCapo(const [ChordSpan('F', 0, 1), ChordSpan('Bb', 1, 2), ChordSpan('C', 2, 3)]);
    expect(capo.first.capo, 3);
    expect(romanNumeral('G7', const MusicKey(0, false)), 'V7');
    // Every generated guitar voicing contains only chord tones.
    const tuning = [40, 45, 50, 55, 59, 64];
    for (var r = 0; r < 12; r++) {
      for (final q in kChordQualities.keys) {
        final name = chordName(r, q);
        final pcs = parseChord(name)!.pitchClasses.toSet();
        for (final v in findVoicings(name, ChordInstrument.guitar)) {
          for (var s = 0; s < 6; s++) {
            if (v.frets[s] >= 0) expect(pcs.contains(mod12(tuning[s] + v.frets[s])), isTrue, reason: '$name ${v.frets}');
          }
        }
      }
    }
  });

  test('bar grid follows meter and downbeat', () {
    final a = analyzeChords(renderProgression(demo));
    final bars = buildBars(a, beatsPerBar: 4, downbeat: 0);
    expect(bars.every((b) => b.beats.length <= 4), isTrue);
    expect(bars.first.beats.first.beat, 0);
    expect(beatIndexAt(a.beats, a.beats[5] + 0.01), 5);
  });
}
