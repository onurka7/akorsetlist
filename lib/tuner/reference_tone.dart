import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import 'pitch_engine.dart';

/// Plays synthesized plucked-string reference tones (and a success chime)
/// through just_audio. Tones are rendered once per frequency to WAV files in
/// the temporary directory.
class ReferenceTonePlayer {
  static const int _sampleRate = 44100;
  final AudioPlayer _player = AudioPlayer();
  final Map<String, String> _files = {};

  Future<void> playFrequency(double freq) async {
    final key = freq.toStringAsFixed(2);
    final path = _files[key] ??= await _write('tone_$key', pluckTone(_sampleRate, freq, seconds: 2.8, seed: freq.round()));
    await _play(path);
  }

  Future<void> playChime() async {
    final path = _files['chime'] ??= await _write('chime', _chime());
    await _play(path);
  }

  Future<void> _play(String path) async {
    try {
      await _player.stop();
      await _player.setFilePath(path);
      await _player.play();
    } catch (_) {
      // Audio output may be unavailable (e.g. another session holds it); tuning still works.
    }
  }

  Future<void> dispose() => _player.dispose();

  Float32List _chime() {
    final out = Float32List((_sampleRate * 0.9).round());
    for (final (f, t0) in const [(880.0, 0.0), (1318.5, 0.12)]) {
      final s0 = (t0 * _sampleRate).round();
      for (var i = s0; i < out.length; i++) {
        final t = (i - s0) / _sampleRate;
        out[i] += 0.25 * math.sin(2 * math.pi * f * t) * math.exp(-5 * t) * math.min(1, t / 0.005);
      }
    }
    return out;
  }

  Future<String> _write(String name, Float32List samples) async {
    final bytes = ByteData(44 + samples.length * 2);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes.setUint8(offset + i, s.codeUnitAt(i));
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
      ..setUint32(24, _sampleRate, Endian.little)
      ..setUint32(28, _sampleRate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    bytes.setUint32(40, samples.length * 2, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      bytes.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    }
    final file = File(p.join(Directory.systemTemp.path, 'akor_tuner_$name.wav'));
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return file.path;
  }
}
