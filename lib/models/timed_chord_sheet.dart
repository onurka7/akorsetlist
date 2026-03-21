class TimedChordSheet {
  final int bpm;
  final List<TimedChordLine> lines;
  final String? youtubeVideoId;

  const TimedChordSheet({
    required this.bpm,
    required this.lines,
    this.youtubeVideoId,
  });

  bool get hasPlayableSegments =>
      lines.any(
        (line) => line.segments.any(
          (segment) => segment.beats > 0 || segment.startMs != null,
        ),
      );

  Map<String, Object?> toMap() => {
        'bpm': bpm,
        'youtubeVideoId': youtubeVideoId,
        'lines': lines.map((line) => line.toMap()).toList(),
      };

  static TimedChordSheet fromMap(Map<String, Object?> map) {
    final rawLines = (map['lines'] as List?) ?? const [];
    return TimedChordSheet(
      bpm: (map['bpm'] as int?) ?? 82,
      youtubeVideoId: map['youtubeVideoId'] as String?,
      lines: rawLines
          .whereType<Map>()
          .map(
            (line) => TimedChordLine.fromMap(
              Map<String, Object?>.from(line.cast<String, Object?>()),
            ),
          )
          .toList(),
    );
  }
}

class TimedChordLine {
  final String? section;
  final List<TimedChordSegment> segments;

  const TimedChordLine({
    this.section,
    required this.segments,
  });

  Map<String, Object?> toMap() => {
        'section': section,
        'segments': segments.map((segment) => segment.toMap()).toList(),
      };

  static TimedChordLine fromMap(Map<String, Object?> map) {
    final rawSegments = (map['segments'] as List?) ?? const [];
    return TimedChordLine(
      section: map['section'] as String?,
      segments: rawSegments
          .whereType<Map>()
          .map(
            (segment) => TimedChordSegment.fromMap(
              Map<String, Object?>.from(segment.cast<String, Object?>()),
            ),
          )
          .toList(),
    );
  }
}

class TimedChordSegment {
  final String lyric;
  final String? chord;
  final int beats;
  final int? startMs;

  const TimedChordSegment({
    required this.lyric,
    this.chord,
    this.beats = 0,
    this.startMs,
  });

  Map<String, Object?> toMap() => {
        'lyric': lyric,
        'chord': chord,
        'beats': beats,
        'startMs': startMs,
      };

  static TimedChordSegment fromMap(Map<String, Object?> map) {
    return TimedChordSegment(
      lyric: (map['lyric'] as String?) ?? '',
      chord: map['chord'] as String?,
      beats: (map['beats'] as int?) ?? 0,
      startMs: map['startMs'] as int?,
    );
  }
}
