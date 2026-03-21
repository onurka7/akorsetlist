import '../models/timed_chord_sheet.dart';

class AkormatikParserService {
  static final RegExp _bpmRe = RegExp(r'♩\s*=\s*(\d{2,3})');
  static final RegExp _sectionRe =
      RegExp(r'^Bölüm\s+\d+', caseSensitive: false);
  static final RegExp _measureRe = RegExp(r'^\d{1,2}$');
  static final RegExp _imageLineRe =
      RegExp(r'^(Image:|Reklam alanı)', caseSensitive: false);
  static final RegExp _spaceRe = RegExp(r'\s+');
  static final RegExp _chordTokenRe = RegExp(
    r'^[A-G](?:#|b|♯|♭)?(?:m|maj|min|dim|aug|sus|add)?\s?\d*(?:/[A-G](?:#|b|♯|♭)?)?$',
  );

  TimedChordSheet? parse(String rawText) {
    if (!rawText.contains('Bölüm') || !rawText.contains('♩=')) return null;

    final bpmMatch = _bpmRe.firstMatch(rawText);
    final bpm = int.tryParse(bpmMatch?.group(1) ?? '') ?? 82;

    final lines = rawText
        .split('\n')
        .map(_cleanLine)
        .where((line) => line.isNotEmpty)
        .where((line) => !_imageLineRe.hasMatch(line))
        .toList();

    if (lines.isEmpty) return null;

    final timedLines = <TimedChordLine>[];
    final lyricBuffer = <String>[];
    final chordBuffer = <String>[];
    String? currentSection;

    void flushLyricBuffer() {
      if (lyricBuffer.isEmpty) return;
      final lyric = lyricBuffer.join(' ').replaceAll(_spaceRe, ' ').trim();
      lyricBuffer.clear();
      if (lyric.isEmpty) return;
      timedLines.add(
        TimedChordLine(
          section: null,
          segments: _segmentsForLyric(
            lyric: lyric,
            chords: List<String>.from(chordBuffer),
          ),
        ),
      );
      chordBuffer.clear();
    }

    for (final line in lines) {
      if (_sectionRe.hasMatch(line)) {
        flushLyricBuffer();
        currentSection = line;
        timedLines
            .add(TimedChordLine(section: currentSection, segments: const []));
        continue;
      }

      if (_measureRe.hasMatch(line)) {
        flushLyricBuffer();
        continue;
      }

      if (_isChordLine(line)) {
        if (lyricBuffer.isNotEmpty) {
          flushLyricBuffer();
        }
        chordBuffer.addAll(_splitChordLine(line));
        continue;
      }

      lyricBuffer.add(line);
    }

    flushLyricBuffer();

    final effectiveLines = timedLines
        .where((line) => line.section != null || line.segments.isNotEmpty)
        .toList();
    if (effectiveLines.length < 4) return null;

    return TimedChordSheet(
      bpm: bpm,
      lines: effectiveLines,
    );
  }

  List<TimedChordSegment> _segmentsForLyric({
    required String lyric,
    required List<String> chords,
  }) {
    if (chords.isEmpty) {
      return [TimedChordSegment(lyric: lyric)];
    }

    final words =
        lyric.split(_spaceRe).where((word) => word.isNotEmpty).toList();
    if (words.isEmpty) {
      return chords
          .map((chord) => TimedChordSegment(lyric: '', chord: chord, beats: 2))
          .toList();
    }

    final segments = <TimedChordSegment>[];
    var start = 0;
    for (var i = 0; i < chords.length; i++) {
      final remainingWords = words.length - start;
      if (remainingWords <= 0) {
        segments.add(TimedChordSegment(lyric: '', chord: chords[i], beats: 2));
        continue;
      }
      final isLast = i == chords.length - 1;
      final take = isLast
          ? remainingWords
          : (remainingWords / (chords.length - i))
              .ceil()
              .clamp(1, remainingWords);
      final end = (start + take).clamp(0, words.length);
      final phrase = words.sublist(start, end).join(' ');
      start = end;
      segments.add(
        TimedChordSegment(
          lyric: phrase,
          chord: chords[i],
          beats: phrase
              .split(_spaceRe)
              .where((word) => word.isNotEmpty)
              .length
              .clamp(1, 4),
        ),
      );
    }
    return segments;
  }

  bool _isChordLine(String line) {
    final parts = _splitChordLine(line);
    if (parts.isEmpty) return false;
    return parts.every(_isChordToken);
  }

  List<String> _splitChordLine(String line) {
    return line
        .split(_spaceRe)
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
  }

  bool _isChordToken(String token) {
    return _chordTokenRe.hasMatch(
      token
          .replaceAll('♯', '#')
          .replaceAll('♭', 'b')
          .replaceAll('maj7', 'maj7')
          .replaceAll('sus4', 'sus4'),
    );
  }

  String _cleanLine(String line) {
    return line
        .replaceAll('\r', '')
        .replaceAll('\u00a0', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
