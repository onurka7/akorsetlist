class ChordReference {
  final String name;
  final List<int> strings;
  final List<String> chordNotes;
  final List<String> playedNotes;

  const ChordReference({
    required this.name,
    required this.strings,
    required this.chordNotes,
    required this.playedNotes,
  });
}

class ChordReferenceService {
  static const List<String> _noteNames = [
    'C',
    'C#',
    'D',
    'D#',
    'E',
    'F',
    'F#',
    'G',
    'G#',
    'A',
    'A#',
    'B',
  ];

  static const List<int> _standardTuning = [4, 9, 2, 7, 11, 4];

  static const Map<String, List<int>> _shapes = {
    'C': [-1, 3, 2, 0, 1, 0],
    'Cm': [-1, 3, 5, 5, 4, 3],
    'C7': [-1, 3, 2, 3, 1, 0],
    'Cm7': [-1, 3, 5, 3, 4, 3],
    'Cmaj7': [-1, 3, 2, 0, 0, 0],
    'Csus2': [-1, 3, 0, 0, 1, 3],
    'Csus4': [-1, 3, 3, 0, 1, 1],
    'Cadd9': [-1, 3, 2, 0, 3, 0],
    'C9': [-1, 3, 2, 3, 3, 3],
    'D': [-1, -1, 0, 2, 3, 2],
    'Dm': [-1, -1, 0, 2, 3, 1],
    'D7': [-1, -1, 0, 2, 1, 2],
    'Dm7': [-1, -1, 0, 2, 1, 1],
    'Dsus2': [-1, -1, 0, 2, 3, 0],
    'Dsus4': [-1, -1, 0, 2, 3, 3],
    'Dadd9': [-1, -1, 0, 2, 3, 0],
    'E': [0, 2, 2, 1, 0, 0],
    'Em': [0, 2, 2, 0, 0, 0],
    'E7': [0, 2, 0, 1, 0, 0],
    'Em7': [0, 2, 2, 0, 3, 0],
    'Esus2': [0, 2, 4, 4, 0, 0],
    'Esus4': [0, 2, 2, 2, 0, 0],
    'Eadd9': [0, 2, 4, 1, 0, 0],
    'F': [1, 3, 3, 2, 1, 1],
    'Fm': [1, 3, 3, 1, 1, 1],
    'F7': [1, 3, 1, 2, 1, 1],
    'Fm7': [1, 3, 1, 1, 1, 1],
    'Fmaj7': [-1, -1, 3, 2, 1, 0],
    'Fsus2': [1, 3, 3, 0, 1, 1],
    'Fsus4': [1, 3, 3, 3, 1, 1],
    'G': [3, 2, 0, 0, 0, 3],
    'Gm': [3, 5, 5, 3, 3, 3],
    'G7': [3, 2, 0, 0, 0, 1],
    'Gm7': [3, 5, 3, 3, 3, 3],
    'Gmaj7': [3, 2, 0, 0, 0, 2],
    'Gsus2': [3, 0, 0, 0, 3, 3],
    'Gsus4': [3, 3, 0, 0, 1, 3],
    'Gadd9': [3, 2, 0, 2, 0, 3],
    'G9': [3, 2, 3, 2, 3, 3],
    'A': [-1, 0, 2, 2, 2, 0],
    'Am': [-1, 0, 2, 2, 1, 0],
    'A7': [-1, 0, 2, 0, 2, 0],
    'Am7': [-1, 0, 2, 0, 1, 0],
    'Asus2': [-1, 0, 2, 2, 0, 0],
    'Asus4': [-1, 0, 2, 2, 3, 0],
    'Aadd9': [-1, 0, 2, 4, 2, 0],
    'B': [-1, 2, 4, 4, 4, 2],
    'Bm': [-1, 2, 4, 4, 3, 2],
    'B7': [-1, 2, 1, 2, 0, 2],
    'Bm7': [-1, 2, 4, 2, 3, 2],
    'Bb': [-1, 1, 3, 3, 3, 1],
    'Bbm': [-1, 1, 3, 3, 2, 1],
    'D/F#': [2, -1, 0, 2, 3, 2],
    'C/G': [3, 3, 2, 0, 1, 0],
    'G/B': [-1, 2, 0, 0, 0, 3],
    'Am/G': [3, 0, 2, 2, 1, 0],
    'Dm/F': [1, -1, 0, 2, 3, 1],
    'F/C': [-1, 3, 3, 2, 1, 1],
  };

  static const Map<String, List<int>> _intervals = {
    '': [0, 4, 7],
    'm': [0, 3, 7],
    '7': [0, 4, 7, 10],
    'm7': [0, 3, 7, 10],
    'maj7': [0, 4, 7, 11],
    'dim': [0, 3, 6],
    'aug': [0, 4, 8],
    'sus2': [0, 2, 7],
    'sus4': [0, 5, 7],
    'add9': [0, 4, 7, 14],
    '9': [0, 4, 7, 10, 14],
    'm9': [0, 3, 7, 10, 14],
    '11': [0, 4, 7, 10, 14, 17],
    '13': [0, 4, 7, 10, 14, 21],
    '5': [0, 7],
  };

  static ChordReference? lookup(String rawName) {
    final normalized = normalizeName(rawName);
    final strings = _shapes[normalized];
    if (strings == null) return null;

    return ChordReference(
      name: normalized,
      strings: strings,
      chordNotes: chordNotes(normalized),
      playedNotes: playedNotes(strings),
    );
  }

  static String normalizeName(String rawName) {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) return trimmed;
    return trimmed
        .replaceAll(' ', '')
        .replaceAll('maj9', 'maj7')
        .replaceAll('Maj9', 'maj7')
        .replaceAll('add2', 'add9')
        .replaceAll('sus', 'sus')
        .replaceAll('M7', 'maj7')
        .replaceAll('Maj7', 'maj7')
        .replaceAll('Maj', 'maj')
        .replaceAll('FM7', 'Fmaj7')
        .replaceAll('CM7', 'Cmaj7')
        .replaceAll('GM7', 'Gmaj7')
        .replaceAll('A#', 'Bb');
  }

  static List<String> chordNotes(String chordName) {
    final normalized = normalizeName(chordName);
    final match = RegExp(r'^([A-G](?:#|b)?)(.*)$').firstMatch(normalized);
    if (match == null) return const [];

    final root = match.group(1)!;
    final rawSuffix = match.group(2) ?? '';
    final parts = rawSuffix.split('/');
    final suffix = parts.first;
    final rootIndex = _noteIndex(root);
    final intervals = _intervals[suffix] ?? _intervals['']!;
    final notes = intervals
        .map((step) => _noteNames[(rootIndex + (step % 12)) % 12])
        .toList();
    if (parts.length > 1 && parts[1].isNotEmpty) {
      notes.add(parts[1]);
    }
    return notes;
  }

  static List<String> playedNotes(List<int> strings) {
    final notes = <String>[];
    for (int i = 0; i < strings.length && i < _standardTuning.length; i++) {
      final fret = strings[i];
      if (fret < 0) continue;
      notes.add(_noteNames[(_standardTuning[i] + fret) % 12]);
    }
    return notes;
  }

  static int _noteIndex(String note) {
    switch (note) {
      case 'Cb':
        return 11;
      case 'Db':
        return 1;
      case 'Eb':
        return 3;
      case 'Fb':
        return 4;
      case 'Gb':
        return 6;
      case 'Ab':
        return 8;
      case 'Bb':
        return 10;
      default:
        return _noteNames.indexOf(note);
    }
  }
}
