import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../chord_ai/chord_theory.dart';
import '../tuner/pitch_engine.dart' show pluckTone;
import 'songbook.dart';

/// Accompaniment (strummed guitar + bass) synthesised from the chart. A
/// transposed track is rendered in the new key rather than pitch-shifted.
Float32List renderSongbookBacking(SongbookSong song, int semitones, {int sampleRate = 22050}) {
  final spb = song.secondsPerBeat;
  final out = Float32List(((song.duration + 2) * sampleRate).ceil());
  final key = transposeKeyName(song.key, semitones);
  final tuning = ChordInstrument.guitar.tuning;
  double hz(int midi) => 440 * math.pow(2, (midi - 69) / 12).toDouble();

  void add(Float32List note, double start, double gain) {
    final s0 = (start * sampleRate).round();
    final fade = (0.03 * sampleRate).round();
    for (var i = 0; i < note.length && s0 + i < out.length; i++) {
      final f = i > note.length - fade ? (note.length - i) / fade : 1.0;
      out[s0 + i] += note[i] * gain * f;
    }
  }

  var seed = 7;
  for (final item in song.progression) {
    final name = transposeForKey(item.chord, semitones, key);
    final chord = parseChord(name);
    final voicing = findVoicings(name, ChordInstrument.guitar, count: 1).firstOrNull;
    for (var i = 0; i < item.beats; i++) {
      final beat = item.startBeat + i;
      final t = kSongbookLeadIn + beat * spb;
      final strong = beat % song.meter == 0;
      if (voicing != null) {
        var k = 0;
        for (var s = 0; s < voicing.frets.length; s++) {
          final f = voicing.frets[s];
          if (f < 0) continue;
          final dur = spb * (strong ? 1.9 : 0.95);
          add(pluckTone(sampleRate, hz(tuning[s] + f), seconds: dur, seed: seed++, gain: 1), t + k++ * 0.012, strong ? 0.2 : 0.11);
        }
      }
      if (chord == null) continue;
      final root = chord.bass ?? chord.root;
      if (strong) {
        add(pluckTone(sampleRate, hz(28 + mod12(root - 4)), seconds: spb * song.meter * 0.95, seed: seed++, gain: 1), t, 0.42);
      } else if (song.meter == 4 && beat % 4 == 2) {
        add(pluckTone(sampleRate, hz(28 + mod12(root + 3)), seconds: spb * 1.9, seed: seed++, gain: 1), t, 0.3);
      }
    }
  }
  var peak = 0.0;
  for (final v in out) {
    peak = math.max(peak, v.abs());
  }
  if (peak > 0) {
    for (var i = 0; i < out.length; i++) {
      out[i] *= 0.85 / peak;
    }
  }
  return out;
}

Uint8List encodeWav16(Float32List samples, int sampleRate) {
  final bytes = ByteData(44 + samples.length * 2);
  void ascii(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + samples.length * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    bytes.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// Renders (once per song + offset) to a temp WAV and returns its path.
class SongbookBackingCache {
  final Map<String, Future<String>> _files = {};

  Future<String> pathFor(SongbookSong song, int semitones) {
    final key = '${song.id}_$semitones';
    return _files[key] ??= () async {
      try {
        final file = File(p.join(Directory.systemTemp.path, 'songbook_$key.wav'));
        final bytes = await Isolate.run(() => encodeWav16(renderSongbookBacking(song, semitones), 22050));
        await file.writeAsBytes(bytes, flush: true);
        return file.path;
      } catch (_) {
        _files.remove(key); // let a later attempt retry
        rethrow;
      }
    }();
  }
}
