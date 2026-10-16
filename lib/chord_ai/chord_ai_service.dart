import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/timed_chord_sheet.dart';
import '../services/user_storage_service.dart';
import 'audio_decoder.dart';
import 'chord_analyzer.dart';
import 'chord_theory.dart';

/// Runs chord analysis off the UI isolate and caches results per audio file.
///
/// The cache key covers everything that affects the result: the file's path,
/// size and modification time plus the analysis format version. Edits and
/// vocabulary changes made in the UI are written back through [save].
class ChordAiService {
  ChordAiService._();

  static final ChordAiService instance = ChordAiService._();

  Future<ChordAnalysis?> cached(String audioPath) async {
    try {
      final file = await _cacheFile(audioPath);
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      return json is Map ? ChordAnalysis.tryFromJson(Map<String, Object?>.from(json)) : null;
    } catch (_) {
      return null; // a corrupt or stale cache entry is simply recomputed
    }
  }

  Future<void> save(String audioPath, ChordAnalysis analysis) async {
    final file = await _cacheFile(audioPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(analysis.toJson()));
  }

  Future<ChordAnalysis> analyze(
    String audioPath, {
    ChordSet chordSet = ChordSet.basic,
    AnalysisProgress? onProgress,
  }) async {
    onProgress?.call(0, 'Ses alınıyor');
    final isWav = audioPath.toLowerCase().endsWith('.wav');
    // WAV is decoded inside the worker isolate; other formats need the
    // platform decoder, which is only reachable from the root isolate.
    final Float32List? samples = isWav ? null : await AudioDecoder.decodeToMono(audioPath);
    final job = _Job(
      wavPath: isWav ? audioPath : null,
      samples: samples == null ? null : TransferableTypedData.fromList([samples]),
      chordSet: chordSet,
    );
    ChordAnalysis result;
    try {
      result = await _runIsolate(job, onProgress);
    } on _WavFallback {
      // Uncommon WAV encodings: let the platform decoder handle them.
      final decoded = await AudioDecoder.decodeToMono(audioPath, forceNative: true);
      result = await _runIsolate(
        _Job(samples: TransferableTypedData.fromList([decoded]), chordSet: chordSet),
        onProgress,
      );
    }
    await save(audioPath, result);
    return result;
  }

  Future<ChordAnalysis> _runIsolate(_Job job, AnalysisProgress? onProgress) async {
    final port = ReceivePort();
    final errors = ReceivePort();
    final isolate = await Isolate.spawn(_worker, (port.sendPort, job), onError: errors.sendPort);
    final completer = Completer<ChordAnalysis>();
    errors.listen((e) {
      if (!completer.isCompleted) completer.completeError(StateError('Analiz başarısız: ${(e as List).first}'));
    });
    port.listen((msg) {
      if (msg is (double, String)) {
        onProgress?.call(msg.$1, msg.$2);
      } else if (msg is ChordAnalysis) {
        completer.complete(msg);
      } else if (msg is _WavFallback) {
        completer.completeError(msg);
      } else if (msg is String) {
        completer.completeError(FormatException(msg));
      }
    });
    try {
      return await completer.future;
    } finally {
      port.close();
      errors.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  Future<File> _cacheFile(String audioPath) async {
    final stat = await File(audioPath).stat();
    final key = sha1
        .convert(utf8.encode('${ChordAnalysis.formatVersion}|$audioPath|${stat.size}|${stat.modified.millisecondsSinceEpoch}'))
        .toString();
    final root = (await UserStorageService.audioDirectory()).parent;
    return File(p.join(root.path, 'chord_ai', '$key.json'));
  }
}

class _Job {
  final String? wavPath;
  final TransferableTypedData? samples;
  final ChordSet chordSet;

  const _Job({this.wavPath, this.samples, required this.chordSet});
}

class _WavFallback implements Exception {
  const _WavFallback();
}

Future<void> _worker((SendPort, _Job) args) async {
  final (out, job) = args;
  try {
    Float32List samples;
    if (job.wavPath != null) {
      out.send((0.01, 'WAV okunuyor'));
      try {
        samples = AudioDecoder.decodeWav(await File(job.wavPath!).readAsBytes(), targetRate: kAnalysisSampleRate);
      } on UnsupportedError {
        out.send(const _WavFallback());
        return;
      }
    } else {
      samples = job.samples!.materialize().asFloat32List();
    }
    final result = analyzeChords(samples, chordSet: job.chordSet, onProgress: (f, label) => out.send((f, label)));
    out.send(result);
  } on FormatException catch (e) {
    out.send(e.message);
  }
}

// ---------------------------------------------------------------------------
// Bar grid (lines -> bars -> beats)

class BeatCell {
  final int beat;
  final double time;
  final String name; // display name after transpose/capo, 'N' for none
  final bool change;

  const BeatCell(this.beat, this.time, this.name, this.change);
}

class ChordBar {
  final int index;
  final List<BeatCell> beats;

  const ChordBar(this.index, this.beats);
}

String displayChord(String name, {int transpose = 0, int capo = 0, bool flats = false}) =>
    name == 'N' ? 'N' : transposeChord(name, transpose - capo, flats: flats);

List<ChordBar> buildBars(
  ChordAnalysis a, {
  int beatsPerBar = 4,
  int? downbeat,
  int transpose = 0,
  int capo = 0,
  bool flats = false,
}) {
  final phase = mod12(downbeat ?? a.downbeat) % beatsPerBar;
  final bars = <ChordBar>[];
  List<BeatCell>? current;
  String? prev;
  for (var k = 0; k < a.beats.length; k++) {
    if (current == null || (k - phase) % beatsPerBar == 0) {
      current = <BeatCell>[];
      bars.add(ChordBar(bars.length, current));
    }
    final name = displayChord(a.beatLabels[k], transpose: transpose, capo: capo, flats: flats);
    current.add(BeatCell(k, a.beats[k], name, name != prev));
    prev = name;
  }
  return bars;
}

int beatIndexAt(List<double> beats, double time) {
  if (beats.isEmpty || time < beats.first) return -1;
  var lo = 0, hi = beats.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (beats[mid] <= time) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

/// Converts an analysis to the app's timed chord sheet (four bars per line,
/// one segment per chord change, beats and start times preserved).
TimedChordSheet toTimedChordSheet(
  ChordAnalysis a, {
  int beatsPerBar = 4,
  int transpose = 0,
  int capo = 0,
  bool flats = false,
  String section = 'AI Akor Analizi',
}) {
  final bars = buildBars(a, beatsPerBar: beatsPerBar, transpose: transpose, capo: capo, flats: flats);
  final lines = <TimedChordLine>[TimedChordLine(section: section, segments: const [])];
  for (var i = 0; i < bars.length; i += 4) {
    final segments = <TimedChordSegment>[];
    for (final bar in bars.skip(i).take(4)) {
      for (final cell in bar.beats) {
        if (cell.change || segments.isEmpty) {
          segments.add(TimedChordSegment(
            lyric: _clock(cell.time),
            chord: cell.name == 'N' ? null : cell.name,
            beats: 1,
            startMs: (cell.time * 1000).round(),
          ));
        } else {
          final last = segments.removeLast();
          segments.add(TimedChordSegment(lyric: last.lyric, chord: last.chord, beats: last.beats + 1, startMs: last.startMs));
        }
      }
    }
    lines.add(TimedChordLine(segments: segments));
  }
  return TimedChordSheet(bpm: a.bpm.round(), lines: lines);
}

String _clock(double seconds) {
  final s = seconds.floor();
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}
