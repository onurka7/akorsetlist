import 'dart:math' as math;

import 'package:akor_setlist/screens/tuner_screen.dart';
import 'package:akor_setlist/tuner/pitch_engine.dart';
import 'package:akor_setlist/tuner/tuner_tunings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const sr = 44100;

  test('detects open strings within ±1.5 cents without octave errors', () {
    const notes = ['B0', 'E1', 'A1', 'D2', 'E2', 'A2', 'D3', 'G3', 'B3', 'E4', 'C4', 'G4', 'A4'];
    for (final note in notes) {
      for (final detune in const [-15, 0, 12]) {
        final target = midiToFrequency(noteToMidi(note));
        final freq = target * math.pow(2, detune / 1200);
        final size = target < 60 ? 8192 : 4096;
        final tone = pluckTone(sr, freq, seconds: 1.0, seed: 3);
        final frame = tone.sublist(11000, 11000 + size).map((v) => v.toDouble()).toList();
        final r = PitchDetector(sr, size).detect(frame);
        expect(r.frequency, isNotNull, reason: note);
        final err = 1200 * math.log(r.frequency! / freq) / math.ln2;
        expect(err.abs(), lessThan(1.5), reason: '$note ${detune}c → ${r.frequency}');
      }
    }
  });

  test('silence and noise are rejected', () {
    final det = PitchDetector(sr, 4096);
    expect(det.detect(List.filled(4096, 0)).frequency, isNull);
    final rnd = math.Random(1);
    final noise = List.generate(4096, (_) => (rnd.nextDouble() * 2 - 1) * 0.2);
    final r = det.detect(noise);
    expect(r.frequency, isNull);
    expect(r.rms, greaterThan(0.05));
  });

  test('tracker smooths, ignores a glitch and switches notes', () {
    final t = PitchTracker();
    TrackedPitch s = const TrackedPitch(null, false);
    for (var i = 0; i < 6; i++) {
      s = t.push(45 + (i.isOdd ? 0.02 : -0.02), i * 50);
    }
    expect(s.stable, isTrue);
    s = t.push(57, 400);
    expect((s.midi! - 45).abs(), lessThan(0.05));
    t.push(50, 450);
    t.push(50, 500);
    s = t.push(50.01, 550);
    expect((s.midi! - 50).abs(), lessThan(0.1));
    expect(t.push(null, 3000).midi, isNull);
  });

  test('tunings: string matching, chromatic, feedback and custom JSON', () {
    final std = instrumentById('electric').presets.first;
    expect(std.notes, ['E2', 'A2', 'D3', 'G3', 'B3', 'E4']);
    expect(nearestString(146.0, std.notes).index, 2);
    expect(nearestNote(445).midi, 69);
    expect(feedbackForCents(2).state, TuneState.inTune);
    expect(feedbackForCents(-30).text, contains('Çok pes'));
    expect(instrumentById('baglama').presets.first.notes.length, 7); // carried over
    const custom = TunerTuning(id: 'custom:1', instrument: 'bass', name: 'X', notes: ['D1', 'A1', 'D2', 'G2'], custom: true);
    final decoded = TunerTuning.decodeCustom(TunerTuning.encodeCustom([custom]));
    expect(decoded.single.notes, custom.notes);
    expect(TunerTuning.decodeCustom('[{"id":"x","instrument":"bass","name":"bad","notes":["H9"]}]'), isEmpty);
    expect(TunerTuning.decodeCustom('not json'), isEmpty);
  });

  testWidgets('tuner screen renders and switches instrument, mode and pro view', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: TunerScreen(isDarkMode: false)));
    await tester.pumpAndSettle();
    expect(find.text('Standart'), findsOneWidget);
    await tester.dragUntilVisible(find.text('Bağlama'), find.byType(ListView).first, const Offset(-150, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bağlama'));
    await tester.pumpAndSettle();
    expect(find.text('Bağlama düzeni (La-Re-Sol)'), findsOneWidget);
    await tester.dragUntilVisible(find.text('Ukulele'), find.byType(ListView).first, const Offset(150, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ukulele'));
    await tester.pumpAndSettle();
    expect(find.text('G C E A'), findsOneWidget);
    await tester.tap(find.text('Kromatik'));
    await tester.tap(find.text('PRO'));
    await tester.pumpAndSettle();
    expect(find.text('Ölçülen'), findsOneWidget);
    await tester.tap(find.text('Geleneksel (High G)'));
    await tester.pumpAndSettle();
    expect(find.text('Özel akort oluştur'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
