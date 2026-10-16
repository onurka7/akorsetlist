import 'dart:math';

import '../chord_ai/chord_ai_service.dart';
import '../chord_ai/chord_theory.dart';
import '../models/timed_chord_sheet.dart';

/// Builds timed chord sheets from audio files using the on-device chord
/// analyzer ([ChordAiService]) and merges them with an existing lyrics sheet.
class WavChordAiService {
  Future<WavChordAiResult> analyzeFile(String path, {ChordSet chordSet = ChordSet.basic}) async {
    final analysis = await ChordAiService.instance.cached(path) ??
        await ChordAiService.instance.analyze(path, chordSet: chordSet);
    if (analysis.chords.every((c) => c.name == 'N')) {
      throw StateError('Bu kayittan yeterli akor tespit edilemedi.');
    }
    return WavChordAiResult(
      detectedSheet: toTimedChordSheet(analysis, flats: analysis.key.usesFlats),
      // Vocal onset is not estimated yet; mergeWithLyrics then treats every
      // detected chord as part of the lyric section (no separate intro).
      lyricStartMs: null,
    );
  }

  TimedChordSheet mergeWithLyrics({
    required TimedChordSheet detectedSheet,
    TimedChordSheet? lyricsSheet,
    int? lyricStartMs,
  }) {
    if (lyricsSheet == null) return _withSoloFallback(detectedSheet);

    final allDetectedSegments = detectedSheet.lines
        .expand((line) => line.segments)
        .where((segment) => (segment.chord ?? '').trim().isNotEmpty)
        .toList();
    if (allDetectedSegments.isEmpty) return _withSoloFallback(detectedSheet);

    final introSegments = <TimedChordSegment>[];
    final detectedSegments = <TimedChordSegment>[];
    for (final segment in allDetectedSegments) {
      final startMs = segment.startMs ?? 0;
      if (lyricStartMs != null && startMs < lyricStartMs) {
        introSegments.add(segment);
      } else {
        detectedSegments.add(segment);
      }
    }
    if (detectedSegments.isEmpty) {
      detectedSegments.addAll(allDetectedSegments);
      introSegments.clear();
    }

    final hasLyrics = lyricsSheet.lines.any(
      (line) => line.segments.any((segment) {
        final lyric = segment.lyric.trim();
        return lyric.isNotEmpty && lyric != '•';
      }),
    );
    if (!hasLyrics) return _withSoloFallback(detectedSheet);

    final newLines = <TimedChordLine>[];
    final hasExplicitSections = lyricsSheet.lines.any(
      (line) => (line.section ?? '').trim().isNotEmpty,
    );
    if (introSegments.isNotEmpty) {
      newLines.add(const TimedChordLine(section: 'Intro', segments: []));
      for (int i = 0; i < introSegments.length; i += 4) {
        final chunk = introSegments.skip(i).take(4).toList();
        newLines.add(
          TimedChordLine(
            segments: chunk
                .map(
                  (segment) => TimedChordSegment(
                    lyric: 'Solo',
                    chord: segment.chord,
                    beats: segment.beats,
                    startMs: segment.startMs,
                  ),
                )
                .toList(),
          ),
        );
      }
    }

    var detectIndex = 0;
    var insertedVerseHeader = hasExplicitSections;

    for (int lineIndex = 0; lineIndex < lyricsSheet.lines.length; lineIndex++) {
      final line = lyricsSheet.lines[lineIndex];
      if (line.section != null && line.segments.isEmpty) {
        newLines.add(line);
        continue;
      }

      final newSegments = <TimedChordSegment>[];
      for (int segmentIndex = 0;
          segmentIndex < line.segments.length;
          segmentIndex++) {
        final segment = line.segments[segmentIndex];
        final lyric = segment.lyric.trim();
        final keepAsLyric = lyric.isNotEmpty && lyric != '•';
        if (keepAsLyric && detectIndex < detectedSegments.length) {
          final detected = detectedSegments[detectIndex++];
          if (!insertedVerseHeader) {
            newLines
                .add(const TimedChordLine(section: 'Verse 1', segments: []));
            insertedVerseHeader = true;
          }
          newSegments.add(
            TimedChordSegment(
              lyric: segment.lyric,
              chord: detected.chord,
              beats: max(segment.beats, detected.beats),
              startMs: detected.startMs,
            ),
          );
        } else {
          newSegments.add(segment);
        }
      }
      newLines
          .add(TimedChordLine(section: line.section, segments: newSegments));
    }

    final overflow = detectedSegments.skip(detectIndex).toList();
    if (overflow.isNotEmpty) {
      newLines.add(const TimedChordLine(section: 'Solo', segments: []));
      for (int i = 0; i < overflow.length; i += 4) {
        final chunk = overflow.skip(i).take(4).toList();
        newLines.add(
          TimedChordLine(
            segments: chunk
                .map(
                  (segment) => TimedChordSegment(
                    lyric: 'Solo',
                    chord: segment.chord,
                    beats: segment.beats,
                    startMs: segment.startMs,
                  ),
                )
                .toList(),
          ),
        );
      }
    }

    return TimedChordSheet(
      bpm: lyricsSheet.bpm,
      youtubeVideoId: lyricsSheet.youtubeVideoId,
      lines: newLines,
    );
  }

  TimedChordSheet _withSoloFallback(TimedChordSheet detectedSheet) {
    final hasLyrics = detectedSheet.lines.any(
      (line) => line.segments.any((segment) => segment.lyric.trim().isNotEmpty),
    );
    if (hasLyrics) return detectedSheet;

    final lines = <TimedChordLine>[];
    for (final line in detectedSheet.lines) {
      if (line.section != null && line.segments.isEmpty) {
        lines.add(line);
        continue;
      }
      lines.add(
        TimedChordLine(
          section: line.section,
          segments: line.segments
              .map(
                (segment) => TimedChordSegment(
                  lyric: 'Solo',
                  chord: segment.chord,
                  beats: segment.beats,
                  startMs: segment.startMs,
                ),
              )
              .toList(),
        ),
      );
    }
    return TimedChordSheet(
      bpm: detectedSheet.bpm,
      youtubeVideoId: detectedSheet.youtubeVideoId,
      lines: lines,
    );
  }

}

class WavChordAiResult {
  final TimedChordSheet detectedSheet;
  final int? lyricStartMs;

  const WavChordAiResult({
    required this.detectedSheet,
    required this.lyricStartMs,
  });
}
