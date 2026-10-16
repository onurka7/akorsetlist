import 'dart:convert';

import 'package:flutter/painting.dart';

import '../chord_ai/chord_theory.dart';
import '../models/timed_chord_sheet.dart';

/// Ready-made songs ("Hazır Şarkılar"): parser, beat timeline, catalogue
/// search and key-aware transposition. Same model and line format as the
/// web clone (`akormatik-clone/js/songbook.js`, `data/songs.json`):
///
///   {Nakarat}            section comment
///   ""                   ends the current stanza
///   [Am]söz [F:2]söz     chord cells; ":n" = length in beats, default a bar
///   [Am] [F] [C] [G]     chord-only line = instrumental verse

const double kSongbookLeadIn = 0.3; // seconds before the first beat
const String kSongbookAsset = 'assets/songbook/songs.json';

/// Turkish lower-casing (Dart's toLowerCase is locale-independent).
String _trLower(String s) => s.replaceAll('I', 'ı').replaceAll('İ', 'i').toLowerCase();

class SongbookCell {
  final String? chord;
  final double beats;
  final String lyric;
  final double beat; // stanza-relative start

  const SongbookCell({required this.chord, required this.beats, required this.lyric, this.beat = 0});

  SongbookCell at(double beat) => SongbookCell(chord: chord, beats: beats, lyric: lyric, beat: beat);
}

class SongbookVerse {
  final bool instrumental;
  final List<SongbookCell> cells;

  const SongbookVerse(this.instrumental, this.cells);
}

sealed class SongbookStanza {
  const SongbookStanza();
}

class SongbookComment extends SongbookStanza {
  final String text;

  const SongbookComment(this.text);
}

class SongbookBlock extends SongbookStanza {
  final int number;
  final double startBeat;
  final double beats;
  final double time;
  final double duration;
  final List<SongbookVerse> verses;

  const SongbookBlock({
    required this.number,
    required this.startBeat,
    required this.beats,
    required this.time,
    required this.duration,
    required this.verses,
  });
}

class ProgressionItem {
  final String chord;
  final double startBeat;
  final double beats;

  const ProgressionItem(this.chord, this.startBeat, this.beats);
}

class SongbookSong {
  final String id;
  final String title;
  final String artist;
  final String? album;
  final int? year;
  final List<String> tags;
  final List<String> contributors;
  final String key;
  final int bpm;
  final int meter;
  final List<SongbookStanza> stanzas;
  final double totalBeats;

  const SongbookSong({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.year,
    required this.tags,
    required this.contributors,
    required this.key,
    required this.bpm,
    required this.meter,
    required this.stanzas,
    required this.totalBeats,
  });

  double get secondsPerBeat => 60 / bpm;
  double get duration => kSongbookLeadIn + totalBeats * secondsPerBeat;
  List<SongbookBlock> get blocks => stanzas.whereType<SongbookBlock>().toList();

  String get albumLine => [if (album != null) album!, if (year != null) '($year)'].join(' ');

  List<ProgressionItem> get progression => [
        for (final b in blocks)
          for (final v in b.verses)
            for (final c in v.cells)
              if (c.chord != null && c.beats > 0) ProgressionItem(c.chord!, b.startBeat + c.beat, c.beats),
      ];

  List<String> get uniqueChords => progression.map((p) => p.chord).toSet().toList();
}

/// "[Am]Yağmur [F:2]dindi" -> cells. Throws [FormatException] on bad chords.
List<SongbookCell> parseSongbookLine(String line, int meter) {
  final cells = <SongbookCell>[];
  final lead = line.indexOf('[');
  if (lead < 0) return line.trim().isEmpty ? cells : [SongbookCell(chord: null, beats: 0, lyric: line)];
  if (lead > 0 && line.substring(0, lead).trim().isNotEmpty) {
    cells.add(SongbookCell(chord: null, beats: 0, lyric: line.substring(0, lead)));
  }
  for (final m in RegExp(r'\[([^\]:]+)(?::(\d+(?:\.\d+)?))?\]([^\[]*)').allMatches(line)) {
    final chord = m.group(1)!.trim();
    if (parseChord(chord) == null) throw FormatException('Geçersiz akor: $chord');
    cells.add(SongbookCell(
      chord: chord,
      beats: m.group(2) == null ? meter.toDouble() : double.parse(m.group(2)!),
      lyric: m.group(3)!,
    ));
  }
  return cells;
}

SongbookSong buildSongbookSong(Map<String, Object?> raw) {
  String req(String k) {
    final v = raw[k];
    if (v is! String || v.isEmpty) throw FormatException('${raw['id'] ?? '?'}: $k eksik');
    return v;
  }

  final meter = (raw['meter'] as num?)?.toInt() ?? 4;
  final bpm = (raw['bpm'] as num?)?.toInt() ?? 90;
  final body = (raw['body'] as List?)?.whereType<String>().toList();
  if (body == null) throw FormatException('${raw['id']}: body eksik');
  final spb = 60 / bpm;
  final stanzas = <SongbookStanza>[];
  var beatCursor = 0.0;
  var number = 0;
  List<SongbookVerse>? verses;
  var stanzaStart = 0.0, stanzaBeats = 0.0;

  void close() {
    if (verses != null && verses!.isNotEmpty) {
      stanzas.add(SongbookBlock(
        number: number,
        startBeat: stanzaStart,
        beats: stanzaBeats,
        time: kSongbookLeadIn + stanzaStart * spb,
        duration: stanzaBeats * spb,
        verses: verses!,
      ));
    }
    verses = null;
  }

  for (final line in body) {
    final section = RegExp(r'^\{(.+)\}$').firstMatch(line.trim());
    if (section != null) {
      close();
      stanzas.add(SongbookComment(section.group(1)!));
      continue;
    }
    if (line.trim().isEmpty) {
      close();
      continue;
    }
    if (verses == null) {
      verses = [];
      number++;
      stanzaStart = beatCursor;
      stanzaBeats = 0;
    }
    final cells = <SongbookCell>[];
    for (final c in parseSongbookLine(line, meter)) {
      cells.add(c.at(stanzaBeats));
      stanzaBeats += c.beats;
      beatCursor += c.beats;
    }
    verses!.add(SongbookVerse(cells.every((c) => c.lyric.trim().isEmpty), cells));
  }
  close();

  return SongbookSong(
    id: req('id'),
    title: req('title'),
    artist: req('artist'),
    album: raw['album'] as String?,
    year: (raw['year'] as num?)?.toInt(),
    tags: (raw['tags'] as List?)?.whereType<String>().toList() ?? const [],
    contributors: (raw['contributors'] as List?)?.whereType<String>().toList() ?? const [],
    key: req('key'),
    bpm: bpm,
    meter: meter,
    stanzas: stanzas,
    totalBeats: beatCursor,
  );
}

/// Parses the songbook JSON; ids must be unique.
List<SongbookSong> parseSongbook(String json) {
  final data = jsonDecode(json);
  final list = data is Map ? data['songs'] : null;
  if (list is! List) throw const FormatException('songs dizisi yok');
  final ids = <String>{};
  return [
    for (final raw in list.whereType<Map>())
      () {
        final song = buildSongbookSong(Map<String, Object?>.from(raw));
        if (!ids.add(song.id)) throw FormatException('Yinelenen id: ${song.id}');
        return song;
      }(),
  ];
}

class SongbookPosition {
  final SongbookBlock? block;
  final SongbookCell? cell;

  const SongbookPosition(this.block, this.cell);
}

int _findIndex<T>(List<T> items, double t, double Function(T) timeOf) {
  if (items.isEmpty || t < timeOf(items.first)) return -1;
  var lo = 0, hi = items.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (timeOf(items[mid]) <= t) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

/// Stanza and chord cell under playback time [t] seconds.
SongbookPosition locateInSong(SongbookSong song, double t) {
  if (t >= song.duration) return const SongbookPosition(null, null);
  final blocks = song.blocks;
  final i = _findIndex<SongbookBlock>(blocks, t, (b) => b.time);
  if (i < 0) return const SongbookPosition(null, null);
  final block = blocks[i];
  final cells = [for (final v in block.verses) ...v.cells.where((c) => c.chord != null)];
  final j = _findIndex<SongbookCell>(cells, t, (c) => block.time + c.beat * song.secondsPerBeat);
  return SongbookPosition(block, j < 0 ? null : cells[j]);
}

/// Repeat window from stanza [from] to [to] inclusive, in seconds.
({double begin, double end})? repeatWindow(SongbookSong song, int from, int to) {
  final blocks = song.blocks;
  final a = blocks.where((b) => b.number == from).firstOrNull;
  final b = blocks.where((b) => b.number == to).firstOrNull;
  if (a == null || b == null || b.number < a.number) return null;
  return (begin: a.time, end: b.time + b.duration);
}

/// All whitespace-separated tokens must match; `tag:x` matches a tag, other
/// tokens match title/artist/album/year or the contributors.
bool songMatches(SongbookSong song, String query) {
  final tokens = _trLower(query).split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
  if (tokens.isEmpty) return true;
  final text = _trLower([song.title, song.artist, song.album ?? '', song.year?.toString() ?? ''].join(' '));
  final contributors = _trLower(song.contributors.join(' '));
  final tags = song.tags.map(_trLower).toList();
  return tokens.every((tok) {
    if (tok.startsWith('tag:') && tok.length > 4) return tags.contains(tok.substring(4));
    return text.contains(tok) || contributors.contains(tok);
  });
}

/// (tag, count) by count desc, then name.
List<(String, int)> songbookTagCounts(List<SongbookSong> songs) {
  final counts = <String, int>{};
  for (final s in songs) {
    for (final t in s.tags) {
      counts[t] = (counts[t] ?? 0) + 1;
    }
  }
  final list = counts.entries.map((e) => (e.key, e.value)).toList()
    ..sort((a, b) => b.$2 != a.$2 ? b.$2 - a.$2 : a.$1.compareTo(b.$1));
  return list;
}

String songbookLower(String s) => _trLower(s);

// ---------------------------------------------------------------------------
// Key-aware transposition (major tonics G D A E B F# spell with sharps,
// everything else with flats — the source site's rule).

const Set<int> _sharpMajorTonics = {7, 2, 9, 4, 11, 6};

({int tonic, bool minor})? _parseKey(String key) {
  final c = parseChord(key);
  if (c == null) return null;
  return (tonic: c.root, minor: c.quality.startsWith('m') && !c.quality.startsWith('maj'));
}

bool keyUsesSharps(String key) {
  final k = _parseKey(key);
  if (k == null) return false;
  return _sharpMajorTonics.contains(k.minor ? mod12(k.tonic + 3) : k.tonic);
}

String transposeKeyName(String key, int semitones) {
  final k = _parseKey(key);
  if (k == null) return key;
  final tonic = mod12(k.tonic + semitones);
  final sharps = _sharpMajorTonics.contains(k.minor ? mod12(tonic + 3) : tonic);
  return noteName(tonic, flats: !sharps) + (k.minor ? 'm' : '');
}

String transposeForKey(String chord, int semitones, String targetKey) {
  if (semitones == 0) return chord;
  return transposeChord(chord, semitones, flats: !keyUsesSharps(targetKey));
}

/// Clamps a transpose offset into -6..+5 like the source page.
int normalizeTranspose(int n) {
  n %= 12;
  if (n > 5) n -= 12;
  if (n < -6) n += 12;
  return n;
}

/// Display parts with ♯/♭: root (+ "m"), smaller degree text, slash bass.
({String root, String degree, String bass}) chordDisplayParts(String chord) {
  final m = RegExp(r'^([A-G][#b]?)([^/]*)(?:/([A-G][#b]?))?$').firstMatch(chord);
  if (m == null) return (root: chord, degree: '', bass: '');
  String glyph(String n) => n.replaceAll('b', '♭').replaceAll('#', '♯');
  var q = m.group(2)!;
  var root = glyph(m.group(1)!);
  if (q.startsWith('m') && !q.startsWith('maj')) {
    root += 'm';
    q = q.substring(1);
  }
  return (root: root, degree: q, bass: m.group(3) == null ? '' : glyph(m.group(3)!));
}

String prettyChord(String chord) {
  final p = chordDisplayParts(chord);
  return '${p.root}${p.degree}${p.bass.isEmpty ? '' : '/${p.bass}'}';
}

/// Deterministic two-colour cover (same hash as the web clone).
List<Color> songbookCoverColors(String id) {
  var h = 2166136261;
  for (final r in id.runes) {
    h = ((h ^ r) * 16777619) & 0xFFFFFFFF;
  }
  h = ((h ^ (h >> 16)) * 0x45d9f3b) & 0xFFFFFFFF;
  h = (h ^ (h >> 16)) & 0xFFFFFFFF;
  final hue = (h % 360).toDouble();
  return [
    HSLColor.fromAHSL(1, hue, 0.62, 0.46).toColor(),
    HSLColor.fromAHSL(1, (hue + 48) % 360, 0.70, 0.28).toColor(),
  ];
}

/// Converts to the app's timed chord sheet so the song can be saved into the
/// library and opened in the existing play screen.
TimedChordSheet songbookToTimedSheet(SongbookSong song, {int transpose = 0}) {
  final key = transposeKeyName(song.key, transpose);
  final lines = <TimedChordLine>[];
  for (final s in song.stanzas) {
    switch (s) {
      case SongbookComment(:final text):
        lines.add(TimedChordLine(section: text, segments: const []));
      case SongbookBlock(:final verses):
        for (final v in verses) {
          lines.add(TimedChordLine(segments: [
            for (final c in v.cells)
              TimedChordSegment(
                lyric: c.lyric.trimRight(),
                chord: c.chord == null ? null : transposeForKey(c.chord!, transpose, key),
                beats: c.beats.round(),
              ),
          ]));
        }
    }
  }
  return TimedChordSheet(bpm: song.bpm, lines: lines);
}
