import 'dart:convert';
import 'dart:math' as math;

const List<String> kSharpNotes = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const List<String> kFlatNotes = ['C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B'];
const Map<String, int> _letters = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};

/// "E2" / "Bb3" / "F#4" -> MIDI number.
int noteToMidi(String note) {
  final m = RegExp(r'^([A-G])([#b]?)(-?\d)$').firstMatch(note.trim());
  if (m == null) throw FormatException('Geçersiz nota: $note');
  final acc = m.group(2) == '#' ? 1 : (m.group(2) == 'b' ? -1 : 0);
  return 12 * (int.parse(m.group(3)!) + 1) + _letters[m.group(1)]! + acc;
}

String midiToNote(int midi, {bool flats = false, bool octave = true}) {
  final name = (flats ? kFlatNotes : kSharpNotes)[((midi % 12) + 12) % 12];
  return octave ? '$name${midi ~/ 12 - 1}' : name;
}

double midiToFrequency(num midi, {double a4 = 440}) => a4 * math.pow(2, (midi - 69) / 12).toDouble();
double frequencyToMidi(double freq, {double a4 = 440}) => 69 + 12 * math.log(freq / a4) / math.ln2;
double centsBetween(double freq, double reference) => 1200 * math.log(freq / reference) / math.ln2;

/// Headstock drawing families.
enum HeadstockLayout { inline6, inline4, split3, split2, sidePegs }

class TunerInstrument {
  final String id;
  final String label;
  final HeadstockLayout layout;
  final List<TunerTuning> presets;

  const TunerInstrument(this.id, this.label, this.layout, this.presets);

  /// Bass needs a longer analysis window for its low fundamentals.
  int get frameSize => id == 'bass' ? 8192 : 4096;
}

class TunerTuning {
  final String id;
  final String instrument;
  final String name;
  final List<String> notes; // low to high
  final bool custom;

  const TunerTuning({required this.id, required this.instrument, required this.name, required this.notes, this.custom = false});

  Map<String, Object?> toJson() => {'id': id, 'instrument': instrument, 'name': name, 'notes': notes};

  static TunerTuning? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final notes = (json['notes'] as List?)?.whereType<String>().toList();
    final id = json['id'], instrument = json['instrument'], name = json['name'];
    if (id is! String || instrument is! String || name is! String || notes == null || notes.isEmpty) return null;
    try {
      notes.forEach(noteToMidi); // validate
    } on FormatException {
      return null;
    }
    return TunerTuning(id: id, instrument: instrument, name: name, notes: notes, custom: true);
  }

  static List<TunerTuning> decodeCustom(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      return list is List ? list.map(tryFromJson).whereType<TunerTuning>().toList() : [];
    } on FormatException {
      return [];
    }
  }

  static String encodeCustom(List<TunerTuning> list) => jsonEncode(list.map((t) => t.toJson()).toList());
}

List<TunerTuning> _presets(String instrument, List<(String, String)> items) => [
      for (final (name, notes) in items)
        TunerTuning(id: '$instrument:$name', instrument: instrument, name: name, notes: notes.split(' ')),
    ];

const _guitar = [
  ('Standart', 'E2 A2 D3 G3 B3 E4'),
  ('Drop D', 'D2 A2 D3 G3 B3 E4'),
  ('Drop C', 'C2 G2 C3 F3 A3 D4'),
  ('Drop B', 'B1 F#2 B2 E3 G#3 C#4'),
  ('Drop A', 'A1 E2 A2 D3 F#3 B3'),
  ('DADGAD', 'D2 A2 D3 G3 A3 D4'),
  ('Yarım ses düşük', 'Eb2 Ab2 Db3 Gb3 Bb3 Eb4'),
  ('Tam ses düşük', 'D2 G2 C3 F3 A3 D4'),
  ('Yarım ses yüksek', 'F2 A#2 D#3 G#3 C4 F4'),
  ('Open C', 'C2 G2 C3 G3 C4 E4'),
  ('Open D', 'D2 A2 D3 F#3 A3 D4'),
  ('Open E', 'E2 B2 E3 G#3 B3 E4'),
  ('Open F', 'C2 F2 C3 F3 A3 F4'),
  ('Open G', 'D2 G2 D3 G3 B3 D4'),
  ('Open A', 'E2 A2 E3 A3 C#4 E4'),
];

final List<TunerInstrument> kTunerInstruments = [
  TunerInstrument('electric', 'Elektro', HeadstockLayout.inline6, _presets('electric', _guitar)),
  TunerInstrument('acoustic', 'Akustik', HeadstockLayout.split3, _presets('acoustic', _guitar)),
  TunerInstrument('bass', 'Bas', HeadstockLayout.inline4, _presets('bass', const [
    ('Standart', 'E1 A1 D2 G2'),
    ('Drop D', 'D1 A1 D2 G2'),
    ('Yarım ses düşük', 'Eb1 Ab1 Db2 Gb2'),
    ('Tam ses düşük', 'D1 G1 C2 F2'),
    ('5 telli gibi (B E A D)', 'B0 E1 A1 D2'),
  ])),
  TunerInstrument('ukulele', 'Ukulele', HeadstockLayout.split2, _presets('ukulele', const [
    ('Geleneksel (High G)', 'G4 C4 E4 A4'),
    ('Low G', 'G3 C4 E4 A4'),
    ('Bariton', 'D3 G3 B3 E4'),
    ('Slack Key', 'G4 C4 E4 G4'),
    ('İngiliz (D)', 'A4 D4 F#4 B4'),
    ('Kanada (D)', 'A3 D4 F#4 B4'),
  ])),
  // Bağlama and saz tunings carried over unchanged from the previous tuner.
  TunerInstrument('baglama', 'Bağlama', HeadstockLayout.sidePegs, _presets('baglama', const [
    ('Bağlama düzeni (La-Re-Sol)', 'A2 A3 D3 D4 G3 G4 G4'),
    ('Bozuk düzen (La-Re-Sol)', 'A2 A3 D3 D4 G3 G4 G4'),
  ])),
  TunerInstrument('saz', 'Saz', HeadstockLayout.sidePegs, _presets('saz', const [
    ('Kısa sap (La-Re-Sol)', 'A2 A3 D3 D4 G3 G4'),
    ('Misket (Sol-Re-La)', 'G2 G3 D3 D4 A3 A4'),
  ])),
];

TunerInstrument instrumentById(String id) =>
    kTunerInstruments.firstWhere((i) => i.id == id, orElse: () => kTunerInstruments.first);

class TargetMatch {
  final int index; // string index, or -1 in chromatic mode
  final int midi;
  final double targetFrequency;
  final double cents;

  const TargetMatch(this.index, this.midi, this.targetFrequency, this.cents);
}

/// Nearest string of [notes] to [freq], measured in cents.
TargetMatch nearestString(double freq, List<String> notes, {double a4 = 440}) {
  TargetMatch? best;
  for (var i = 0; i < notes.length; i++) {
    final midi = noteToMidi(notes[i]);
    final target = midiToFrequency(midi, a4: a4);
    final cents = centsBetween(freq, target);
    if (best == null || cents.abs() < best.cents.abs()) best = TargetMatch(i, midi, target, cents);
  }
  return best!;
}

TargetMatch stringTarget(double freq, List<String> notes, int index, {double a4 = 440}) {
  final midi = noteToMidi(notes[index]);
  final target = midiToFrequency(midi, a4: a4);
  return TargetMatch(index, midi, target, centsBetween(freq, target));
}

TargetMatch nearestNote(double freq, {double a4 = 440}) {
  final midi = frequencyToMidi(freq, a4: a4).round();
  final target = midiToFrequency(midi, a4: a4);
  return TargetMatch(-1, midi, target, centsBetween(freq, target));
}

const double kInTuneCents = 3;
const double kSlightCents = 20;

enum TuneState { idle, quiet, noisy, flat, sharp, inTune }

class TuneFeedback {
  final TuneState state;
  final String text;

  const TuneFeedback(this.state, this.text);
}

/// Five-state feedback wording, following the source app.
TuneFeedback feedbackForCents(double cents) {
  final a = cents.abs();
  if (a <= kInTuneCents) return const TuneFeedback(TuneState.inTune, 'Akortlu!');
  if (cents < 0) {
    return TuneFeedback(TuneState.flat, a <= kSlightCents ? 'Biraz pes — teli sıkıştır.' : 'Çok pes — teli sıkıştır.');
  }
  return TuneFeedback(TuneState.sharp, a <= kSlightCents ? 'Biraz tiz — teli gevşet.' : 'Çok tiz — teli gevşet.');
}
