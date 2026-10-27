// Music theory primitives shared by the chord analyzer, live detection and UI.
// Pure Dart (no Flutter) so it runs inside background isolates and unit tests.

import 'dart:math' as math;

const List<String> kSharpNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const List<String> kFlatNames = ['C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B'];

/// Chord qualities as semitone intervals above the root.
const Map<String, List<int>> kChordQualities = {
  '': [0, 4, 7],
  'm': [0, 3, 7],
  '7': [0, 4, 7, 10],
  'maj7': [0, 4, 7, 11],
  'm7': [0, 3, 7, 10],
  'dim': [0, 3, 6],
  'm7b5': [0, 3, 6, 10],
  'dim7': [0, 3, 6, 9],
  'aug': [0, 4, 8],
  'sus2': [0, 2, 7],
  'sus4': [0, 5, 7],
  '6': [0, 4, 7, 9],
  'm6': [0, 3, 7, 9],
  'add9': [0, 4, 7, 14],
  '9': [0, 4, 7, 10, 14],
  '5': [0, 7],
};

/// Recognition vocabularies: "Temel" (basic) and "Hepsi" (all).
enum ChordSet { basic, full }

const Map<ChordSet, List<String>> kChordSetQualities = {
  ChordSet.basic: ['', 'm'],
  ChordSet.full: ['', 'm', '7', 'maj7', 'm7', 'dim', 'm7b5', 'sus2', 'sus4', 'aug'],
};

int mod12(int n) => ((n % 12) + 12) % 12;

const Map<String, int> _letters = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};

int? notePc(String name) {
  final m = RegExp(r'^([A-G])([#b♯♭]*)$').firstMatch(name);
  if (m == null) return null;
  var pc = _letters[m.group(1)]!;
  for (final ch in m.group(2)!.split('')) {
    pc += (ch == '#' || ch == '♯') ? 1 : -1;
  }
  return mod12(pc);
}

String noteName(int pc, {bool flats = false}) => (flats ? kFlatNames : kSharpNames)[mod12(pc)];

class ParsedChord {
  final int root;
  final String quality;
  final int? bass;

  const ParsedChord(this.root, this.quality, [this.bass]);

  List<int> get pitchClasses {
    final pcs = kChordQualities[quality]!.map((i) => mod12(root + i)).toList();
    if (bass != null && !pcs.contains(bass)) pcs.add(bass!);
    return pcs;
  }

  String name({bool flats = false}) => chordName(root, quality, bass: bass, flats: flats);
}

final RegExp _chordRe = RegExp(r'^([A-G][#b♯♭]?)([^/]*)(?:/([A-G][#b♯♭]?))?$');

/// Parses names such as "C#m7", "Bb/D", "F#m7b5". "N" (no chord) yields null.
ParsedChord? parseChord(String? name) {
  final m = _chordRe.firstMatch((name ?? '').trim());
  if (m == null || !kChordQualities.containsKey(m.group(2))) return null;
  final root = notePc(m.group(1)!)!;
  final bass = m.group(3) == null ? null : notePc(m.group(3)!);
  return ParsedChord(root, m.group(2)!, bass == root ? null : bass);
}

String chordName(int root, String quality, {int? bass, bool flats = false}) {
  final base = noteName(root, flats: flats) + quality;
  return bass == null ? base : '$base/${noteName(bass, flats: flats)}';
}

String transposeChord(String name, int semitones, {bool flats = false}) {
  final c = parseChord(name);
  if (c == null) return name;
  return chordName(c.root + semitones, c.quality,
      bass: c.bass == null ? null : c.bass! + semitones, flats: flats);
}

class MusicKey {
  final int tonic;
  final bool minor;
  final double confidence;

  const MusicKey(this.tonic, this.minor, [this.confidence = 0]);

  MusicKey transposed(int semitones) => MusicKey(mod12(tonic + semitones), minor, confidence);

  /// Conventional spelling: keys whose relative major is F, Bb, Eb, Ab, Db, Gb use flats.
  bool get usesFlats => const {5, 10, 3, 8, 1, 6}.contains(minor ? mod12(tonic + 3) : tonic);

  String name({bool? flats}) => noteName(tonic, flats: flats ?? usesFlats) + (minor ? 'm' : '');

  Map<String, Object?> toJson() => {'tonic': tonic, 'minor': minor, 'confidence': confidence};

  static MusicKey fromJson(Map<String, Object?> j) =>
      MusicKey(j['tonic'] as int, j['minor'] as bool, (j['confidence'] as num?)?.toDouble() ?? 0);
}

// Krumhansl–Kessler key profiles.
const List<double> _majorProfile = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const List<double> _minorProfile = [6.33, 2.68, 3.52, 5.38, 2.6, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

double _pearson(List<double> a, List<double> b, int shift) {
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < 12; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= 12;
  mb /= 12;
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < 12; i++) {
    final x = a[mod12(i + shift)] - ma, y = b[i] - mb;
    num += x * y;
    da += x * x;
    db += y * y;
  }
  return da > 0 && db > 0 ? num / math.sqrt(da * db) : 0;
}

/// A timed chord span used by key refinement and capo suggestions.
class ChordSpan {
  final String name;
  final double start;
  final double end;

  const ChordSpan(this.name, this.start, this.end);

  double get duration => end - start;
}

/// Chooses the key from both evidence sources. A chroma profile alone confuses
/// a key with its relatives and neighbours, so each of the 24 keys is scored by
/// profile correlation plus how long its tonic chord sounds (with a bonus for
/// opening/closing on it) and how much of the song uses its diatonic chords
/// (including the major dominant of harmonic minor).
MusicKey chooseKey(List<double> chroma, List<ChordSpan> chords) {
  final named = <(ChordSpan, ParsedChord)>[];
  for (final c in chords) {
    final p = parseChord(c.name);
    if (p != null) named.add((c, p));
  }
  final total = named.fold<double>(0, (a, e) => a + e.$1.duration);
  var best = const MusicKey(0, false, double.negativeInfinity);
  var bestScore = double.negativeInfinity;
  for (var t = 0; t < 12; t++) {
    for (final minor in const [false, true]) {
      final corr = _pearson(chroma, minor ? _minorProfile : _majorProfile, t);
      var score = corr;
      if (total > 0) {
        final steps = minor ? const [0, 2, 3, 5, 7, 8, 10] : const [0, 2, 4, 5, 7, 9, 11];
        final triads = minor ? const ['m', 'dim', '', 'm', 'm', '', ''] : const ['', 'm', 'm', '', '', 'm', 'dim'];
        bool isTonic(ParsedChord p) =>
            p.root == t && (minor ? const ['m', 'm7', 'm6'] : const ['', 'maj7', '6', 'add9', 'sus2', 'sus4', '5']).contains(p.quality);
        bool isDiatonic(ParsedChord p) {
          final degree = steps.indexOf(mod12(p.root - t));
          if (degree < 0) return false;
          final triad = p.quality.startsWith('m') && !p.quality.startsWith('maj') ? 'm' : (p.quality.startsWith('dim') || p.quality == 'm7b5' ? 'dim' : '');
          return triad == triads[degree] || (minor && degree == 4 && triad == '');
        }

        var tonic = 0.0, diatonic = 0.0;
        for (final (c, p) in named) {
          if (isTonic(p)) tonic += c.duration;
          if (isDiatonic(p)) diatonic += c.duration;
        }
        if (isTonic(named.first.$2)) tonic += 0.1 * total;
        if (isTonic(named.last.$2)) tonic += 0.1 * total;
        score += 0.8 * tonic / total + 0.5 * diatonic / total;
      }
      if (score > bestScore) {
        bestScore = score;
        best = MusicKey(t, minor, corr);
      }
    }
  }
  return best;
}

const List<String> _numerals = ['I', '♭II', 'II', '♭III', 'III', 'IV', '♯IV', 'V', '♭VI', 'VI', '♭VII', 'VII'];

String romanNumeral(String name, MusicKey? key) {
  final c = parseChord(name);
  if (c == null || key == null) return '';
  var n = _numerals[mod12(c.root - key.tonic)];
  if (const ['m', 'm7', 'm6', 'dim', 'm7b5', 'dim7'].contains(c.quality)) n = n.toLowerCase();
  const suffix = {'dim': '°', 'dim7': '°7', 'm7b5': 'ø7', 'aug': '+', '7': '7', 'maj7': 'maj7', 'm7': '7'};
  return n + (suffix[c.quality] ?? '');
}

// ---------------------------------------------------------------------------
// Instruments and voicings

enum ChordInstrument { guitar, ukulele, piano }

extension ChordInstrumentInfo on ChordInstrument {
  String get label => switch (this) {
        ChordInstrument.guitar => 'Gitar',
        ChordInstrument.ukulele => 'Ukulele',
        ChordInstrument.piano => 'Piyano',
      };

  List<int> get tuning => switch (this) {
        ChordInstrument.guitar => const [40, 45, 50, 55, 59, 64],
        ChordInstrument.ukulele => const [67, 60, 64, 69],
        ChordInstrument.piano => const [],
      };

  bool get bassIsLowest => this == ChordInstrument.guitar;
}

class Barre {
  final int fret;
  final int from;
  final int to;

  const Barre(this.fret, this.from, this.to);
}

class Voicing {
  /// One entry per string, low to high; -1 muted, 0 open.
  final List<int> frets;
  final int baseFret;
  final Barre? barre;
  final double score;

  const Voicing(this.frets, this.baseFret, this.barre, this.score);
}

const int _x = -1;

// Standard guitar shapes players expect first.
const Map<String, List<int>> _guitarOpen = {
  'C': [_x, 3, 2, 0, 1, 0], 'C7': [_x, 3, 2, 3, 1, 0], 'Cmaj7': [_x, 3, 2, 0, 0, 0], 'Cadd9': [_x, 3, 2, 0, 3, 0],
  'C6': [_x, 3, 2, 2, 1, 0],
  'D': [_x, _x, 0, 2, 3, 2], 'Dm': [_x, _x, 0, 2, 3, 1], 'D7': [_x, _x, 0, 2, 1, 2], 'Dm7': [_x, _x, 0, 2, 1, 1],
  'Dmaj7': [_x, _x, 0, 2, 2, 2], 'Dsus4': [_x, _x, 0, 2, 3, 3], 'Dsus2': [_x, _x, 0, 2, 3, 0], 'D6': [_x, _x, 0, 2, 0, 2],
  'E': [0, 2, 2, 1, 0, 0], 'Em': [0, 2, 2, 0, 0, 0], 'E7': [0, 2, 0, 1, 0, 0], 'Em7': [0, 2, 2, 0, 3, 0],
  'Emaj7': [0, 2, 1, 1, 0, 0], 'Esus4': [0, 2, 2, 2, 0, 0], 'E5': [0, 2, 2, _x, _x, _x],
  'Fmaj7': [_x, _x, 3, 2, 1, 0],
  'G': [3, 2, 0, 0, 0, 3], 'G7': [3, 2, 0, 0, 0, 1], 'Gmaj7': [3, 2, 0, 0, 0, 2], 'G6': [3, 2, 0, 0, 0, 0],
  'A': [_x, 0, 2, 2, 2, 0], 'Am': [_x, 0, 2, 2, 1, 0], 'A7': [_x, 0, 2, 0, 2, 0], 'Am7': [_x, 0, 2, 0, 1, 0],
  'Amaj7': [_x, 0, 2, 1, 2, 0], 'Asus4': [_x, 0, 2, 2, 3, 0], 'Asus2': [_x, 0, 2, 2, 0, 0], 'A5': [_x, 0, 2, 2, _x, _x],
  'A6': [_x, 0, 2, 2, 2, 2],
  'B7': [_x, 2, 1, 2, 0, 2],
};

// Movable barre forms; offsets relative to the root fret.
const Map<String, List<int>> _eForm = {
  '': [0, 2, 2, 1, 0, 0], 'm': [0, 2, 2, 0, 0, 0], '7': [0, 2, 0, 1, 0, 0], 'm7': [0, 2, 0, 0, 0, 0],
  '5': [0, 2, 2, _x, _x, _x], 'sus4': [0, 2, 2, 2, 0, 0], 'maj7': [0, _x, 1, 1, 0, _x],
};
const Map<String, List<int>> _aForm = {
  '': [_x, 0, 2, 2, 2, 0], 'm': [_x, 0, 2, 2, 1, 0], '7': [_x, 0, 2, 0, 2, 0], 'm7': [_x, 0, 2, 0, 1, 0],
  'maj7': [_x, 0, 2, 1, 2, 0], 'sus4': [_x, 0, 2, 2, 3, 0], 'sus2': [_x, 0, 2, 2, 0, 0], 'dim': [_x, 0, 1, 2, 1, _x],
  'm7b5': [_x, 0, 1, 0, 1, _x], 'dim7': [_x, 0, 1, 2, 1, 2], 'aug': [_x, 0, 3, 2, 2, 1], '6': [_x, 0, 2, 2, 2, 2],
  'm6': [_x, 0, 2, 2, 1, 2], 'add9': [_x, 0, 2, 2, 0, 0], '5': [_x, 0, 2, 2, _x, _x],
};

Voicing _describeShape(List<int> frets) {
  final fretted = <int>[];
  for (var i = 0; i < frets.length; i++) {
    if (frets[i] > 0) fretted.add(i);
  }
  final minF = fretted.isEmpty ? 0 : fretted.map((i) => frets[i]).reduce((a, b) => a < b ? a : b);
  final maxF = fretted.isEmpty ? 0 : fretted.map((i) => frets[i]).reduce((a, b) => a > b ? a : b);
  Barre? barre;
  if (fretted.length > 4) {
    final atMin = fretted.where((i) => frets[i] == minF).toList();
    barre = Barre(minF, atMin.first, atMin.last);
  }
  return Voicing(List.unmodifiable(frets), maxF > 4 ? minF : 1, barre, 0);
}

List<Voicing> _standardGuitarShapes(ParsedChord chord) {
  if (chord.bass != null) return const [];
  final out = <Voicing>[];
  final open = _guitarOpen[chordName(chord.root, chord.quality)] ??
      _guitarOpen[chordName(chord.root, chord.quality, flats: true)];
  if (open != null) out.add(_describeShape(open));
  final movable = <List<int>>[];
  void addForm(Map<String, List<int>> forms, int rootString) {
    final shape = forms[chord.quality];
    if (shape == null) return;
    final rootFret = mod12(chord.root - rootString);
    final base = rootFret == 0 ? 12 : rootFret; // fret 0 equals the open shape
    final frets = shape.map((o) => o == _x ? _x : base + o).toList();
    if (frets.every((f) => f <= 15)) movable.add(frets);
  }

  addForm(_eForm, 4);
  addForm(_aForm, 9);
  movable.sort((a, b) => a.reduce((x, y) => x > y ? x : y).compareTo(b.reduce((x, y) => x > y ? x : y)));
  out.addAll(movable.map(_describeShape));
  return out;
}

final Map<String, List<Voicing>> _voicingCache = {};

/// Playable fingerings, best first. Guitar starts from standard shapes; further
/// alternatives come from a search over four-fret windows.
List<Voicing> findVoicings(String name, ChordInstrument instrument, {int count = 3}) {
  if (instrument == ChordInstrument.piano) return const [];
  final key = '${instrument.name}|$name|$count';
  final cached = _voicingCache[key];
  if (cached != null) return cached;
  final chord = parseChord(name);
  if (chord == null) return const [];
  final standard = instrument == ChordInstrument.guitar ? _standardGuitarShapes(chord) : <Voicing>[];
  final searched = _searchVoicings(chord, instrument, count + standard.length);
  final seen = <String>{};
  final merged = [...standard, ...searched].where((v) => seen.add(v.frets.join(','))).take(count).toList();
  return _voicingCache[key] = List.unmodifiable(merged);
}

List<Voicing> _searchVoicings(ParsedChord chord, ChordInstrument inst, int count) {
  final intervals = kChordQualities[chord.quality]!.map(mod12).toList();
  final pcs = intervals.map((i) => mod12(chord.root + i)).toList();
  final optional = pcs.length >= 4 && intervals.contains(7) ? {mod12(chord.root + 7)} : <int>{};
  final bassPc = chord.bass ?? chord.root;
  final allowed = {...pcs, if (chord.bass != null) chord.bass!};
  final tuning = inst.tuning;
  final results = <String, Voicing>{};
  final frets = List<int>.filled(tuning.length, -1);

  for (var start = 0; start <= 12; start++) {
    final lo = start < 1 ? 1 : start, hi = lo + 3;
    final options = tuning.map((open) {
      final opts = <int>[-1];
      if (allowed.contains(mod12(open))) opts.add(0);
      for (var f = lo; f <= hi; f++) {
        if (allowed.contains(mod12(open + f))) opts.add(f);
      }
      return opts;
    }).toList();
    void walk(int s) {
      if (s == tuning.length) {
        final v = _evaluate(frets, tuning, inst, pcs, optional, bassPc);
        if (v != null) {
          final k = frets.join(',');
          final prev = results[k];
          if (prev == null || prev.score > v.score) results[k] = v;
        }
        return;
      }
      for (final f in options[s]) {
        frets[s] = f;
        walk(s + 1);
      }
    }

    walk(0);
  }
  final ranked = results.values.toList()..sort((a, b) => a.score.compareTo(b.score));
  return ranked.take(count).toList();
}

Voicing? _evaluate(List<int> frets, List<int> tuning, ChordInstrument inst, List<int> pcs, Set<int> optional, int bassPc) {
  final sounding = <int>[];
  for (var i = 0; i < frets.length; i++) {
    if (frets[i] >= 0) sounding.add(i);
  }
  if (sounding.length < (frets.length < 4 ? frets.length : 4)) return null;
  for (var i = sounding.first; i <= sounding.last; i++) {
    if (frets[i] < 0) return null; // no interior muted strings
  }
  if (inst.bassIsLowest && mod12(tuning[sounding.first] + frets[sounding.first]) != bassPc) return null;
  final present = sounding.map((i) => mod12(tuning[i] + frets[i])).toSet();
  var missing = 0;
  for (final pc in pcs) {
    if (!present.contains(pc)) {
      if (optional.contains(pc)) {
        missing++;
      } else {
        return null;
      }
    }
  }
  final fretted = sounding.where((i) => frets[i] > 0).toList();
  final minF = fretted.isEmpty ? 0 : fretted.map((i) => frets[i]).reduce((a, b) => a < b ? a : b);
  final maxF = fretted.isEmpty ? 0 : fretted.map((i) => frets[i]).reduce((a, b) => a > b ? a : b);
  var fingers = fretted.length;
  Barre? barre;
  if (fingers > 4) {
    final atMin = fretted.where((i) => frets[i] == minF).toList();
    for (var i = atMin.first; i <= atMin.last; i++) {
      if (frets[i] == 0) return null;
    }
    fingers = 1 + fretted.where((i) => frets[i] > minF).length;
    if (fingers > 4) return null;
    barre = Barre(minF, atMin.first, atMin.last);
  }
  final opens = sounding.length - fretted.length;
  final mutes = frets.length - sounding.length;
  final score = minF * 0.9 + (maxF - minF) * 0.4 + fingers * 0.35 + mutes * 0.9 - opens * 0.25 +
      (barre != null ? 1.6 : 0) + missing * 0.6;
  return Voicing(List.unmodifiable(frets), maxF > 4 ? minF : 1, barre, score);
}

List<int> pianoVoicing(String name) {
  final c = parseChord(name);
  if (c == null) return const [];
  return [
    if (c.bass != null) 48 + c.bass!,
    ...kChordQualities[c.quality]!.map((i) => 60 + c.root + i),
  ];
}

// ---------------------------------------------------------------------------
// Capo suggestion

final Set<String> _openShapeKeys = _guitarOpen.keys.map((n) {
  final c = parseChord(n)!;
  return '${c.root}:${c.quality}';
}).toSet();

double shapeDifficulty(String name) {
  final c = parseChord(name);
  if (c == null) return 0;
  if (_openShapeKeys.contains('${c.root}:${c.quality}')) return 1;
  return const ['', 'm', '7', 'm7', '5'].contains(c.quality) ? 2.6 : 3.2;
}

class CapoOption {
  final int capo;
  final double score;

  const CapoOption(this.capo, this.score);
}

/// Capo positions ranked by how much of the song uses easy open shapes.
List<CapoOption> suggestCapo(List<ChordSpan> chords, {int maxCapo = 7}) {
  final options = <CapoOption>[];
  for (var capo = 0; capo <= maxCapo; capo++) {
    var total = 0.0, time = 0.0;
    for (final ch in chords) {
      if (parseChord(ch.name) == null) continue;
      final d = ch.duration < 0.01 ? 0.01 : ch.duration;
      total += shapeDifficulty(transposeChord(ch.name, -capo)) * d;
      time += d;
    }
    options.add(CapoOption(capo, time > 0 ? total / time + capo * 0.04 : capo.toDouble()));
  }
  options.sort((a, b) => a.score.compareTo(b.score));
  return options;
}

/// Position of a root on the circle of fifths (0..11), used for chord colours.
int fifthsIndex(int pc) => mod12(pc * 7);
