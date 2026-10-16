import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'chord_analyzer.dart';

/// Decodes audio files to mono float PCM at [kAnalysisSampleRate].
///
/// WAV is parsed in Dart. Compressed formats (MP3, M4A, AAC, ...) go through
/// the platform decoder: AVAssetReader on iOS/macOS, MediaCodec on Android.
/// Native code writes raw little-endian float32 to a temporary file so large
/// songs never travel through a platform message.
class AudioDecoder {
  static const MethodChannel _channel = MethodChannel('akor_setlist/audio_decoder');
  static const int maxSeconds = 30 * 60;

  static Future<Float32List> decodeToMono(String path, {bool forceNative = false}) async {
    if (!forceNative && path.toLowerCase().endsWith('.wav')) {
      final bytes = await File(path).readAsBytes();
      try {
        return decodeWav(bytes, targetRate: kAnalysisSampleRate);
      } on UnsupportedError {
        // Unusual WAV encodings (ADPCM, A-law, ...) fall back to the platform decoder.
      }
    }
    final String? pcmPath;
    try {
      pcmPath = await _channel.invokeMethod<String>('decodeToPcm', {
        'path': path,
        'sampleRate': kAnalysisSampleRate,
      });
    } on MissingPluginException {
      throw UnsupportedError('Bu cihazda yalnızca WAV dosyaları analiz edilebilir.');
    } on PlatformException catch (e) {
      throw FormatException('Ses dosyası çözülemedi: ${e.message ?? e.code}');
    }
    if (pcmPath == null) throw const FormatException('Ses dosyası çözülemedi.');
    final file = File(pcmPath);
    try {
      final raw = await file.readAsBytes();
      final samples = raw.buffer.asFloat32List(raw.offsetInBytes, raw.lengthInBytes ~/ 4);
      _checkDuration(samples.length / kAnalysisSampleRate);
      return Float32List.fromList(samples);
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  static void _checkDuration(double seconds) {
    if (seconds > maxSeconds) throw const FormatException('Ses kaydı 30 dakikadan kısa olmalıdır.');
    if (seconds < 2) throw const FormatException('Ses kaydı analiz için çok kısa.');
  }

  /// Parses PCM (8/16/24/32-bit) or float (32/64-bit) WAV, mixes to mono and
  /// resamples to [targetRate].
  static Float32List decodeWav(Uint8List bytes, {required int targetRate}) {
    final data = ByteData.sublistView(bytes);
    String ascii(int offset) => String.fromCharCodes(bytes.sublist(offset, offset + 4));
    if (bytes.length < 12 || ascii(0) != 'RIFF' || ascii(8) != 'WAVE') {
      throw const FormatException('Geçerli bir WAV dosyası değil.');
    }
    int? format, channels, rate, bits;
    int dataOffset = -1, dataLength = 0;
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = ascii(offset);
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ' && body + 16 <= bytes.length) {
        format = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        rate = data.getUint32(body + 4, Endian.little);
        bits = data.getUint16(body + 14, Endian.little);
        if (format == 0xFFFE && size >= 26) format = data.getUint16(body + 24, Endian.little); // WAVE_FORMAT_EXTENSIBLE
      } else if (id == 'data') {
        dataOffset = body;
        dataLength = math.min(size, bytes.length - body); // tolerate truncated/streamed files
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    if (format == null || channels == null || rate == null || bits == null || dataOffset < 0 || channels == 0) {
      throw const FormatException('WAV başlığı eksik ya da bozuk.');
    }
    final isFloat = format == 3;
    if (!(format == 1 && const [8, 16, 24, 32].contains(bits)) && !(isFloat && (bits == 32 || bits == 64))) {
      throw UnsupportedError('Desteklenmeyen WAV biçimi (format $format, $bits bit).');
    }
    final bytesPerSample = bits ~/ 8;
    final frameBytes = bytesPerSample * channels;
    final frames = dataLength ~/ frameBytes;
    _checkDuration(frames / rate);

    double read(int o) {
      switch (bits) {
        case 8:
          return (data.getUint8(o) - 128) / 128.0;
        case 16:
          return data.getInt16(o, Endian.little) / 32768.0;
        case 24:
          final v = data.getUint8(o) | (data.getUint8(o + 1) << 8) | (data.getInt8(o + 2) << 16);
          return v / 8388608.0;
        case 32:
          return isFloat ? data.getFloat32(o, Endian.little) : data.getInt32(o, Endian.little) / 2147483648.0;
        default:
          return data.getFloat64(o, Endian.little);
      }
    }

    final mono = Float32List(frames);
    for (var f = 0; f < frames; f++) {
      final base = dataOffset + f * frameBytes;
      var sum = 0.0;
      for (var c = 0; c < channels; c++) {
        sum += read(base + c * bytesPerSample);
      }
      mono[f] = (sum / channels).clamp(-1.0, 1.0);
    }
    return resample(mono, rate, targetRate);
  }

  /// Box-filtered decimation followed by linear interpolation. Adequate for
  /// chroma analysis, which only uses content below ~4 kHz.
  static Float32List resample(Float32List input, int fromRate, int toRate) {
    if (fromRate == toRate) return input;
    var src = input;
    final ratio = fromRate / toRate;
    if (ratio > 1) {
      final width = ratio.floor();
      if (width > 1) {
        final filtered = Float32List(src.length);
        var acc = 0.0;
        for (var i = 0; i < src.length; i++) {
          acc += src[i];
          if (i >= width) acc -= src[i - width];
          filtered[i] = acc / math.min(width, i + 1);
        }
        src = filtered;
      }
    }
    final outLength = (src.length / ratio).floor();
    final out = Float32List(outLength);
    for (var i = 0; i < outLength; i++) {
      final pos = i * ratio;
      final j = pos.floor();
      final frac = pos - j;
      final a = src[j], b = j + 1 < src.length ? src[j + 1] : a;
      out[i] = a + (b - a) * frac;
    }
    return out;
  }
}
