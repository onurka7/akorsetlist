import 'dart:io';
import 'dart:math' as math;

import 'package:akor_setlist/chord_ai/chord_theory.dart';
import 'package:akor_setlist/screens/songbook_screen.dart';
import 'package:akor_setlist/songbook/songbook.dart';
import 'package:akor_setlist/songbook/songbook_backing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SongbookSong _song(List<String> body, {int bpm = 120, int meter = 4, String key = 'Am'}) => buildSongbookSong({
      'id': 'x',
      'title': 'X',
      'artist': 'Y',
      'key': key,
      'bpm': bpm,
      'meter': meter,
      'body': body,
    });

void main() {
  final bundled = parseSongbook(File('assets/songbook/songs.json').readAsStringSync());

  test('line parser and stanza timeline match the web clone', () {
    final cells = parseSongbookLine('[Am]Yağmur [F:2]dindi', 4);
    expect(cells.map((c) => (c.chord, c.beats, c.lyric)), [('Am', 4.0, 'Yağmur '), ('F', 2.0, 'dindi')]);
    expect(() => parseSongbookLine('[H7]x', 4), throwsFormatException);

    final s = _song(['[Am] [F]', '', '{Nakarat}', '[C]bir [G:2]iki', '[Am]üç']);
    final blocks = s.blocks;
    expect(blocks.length, 2);
    expect(s.stanzas[1], isA<SongbookComment>());
    expect(blocks[0].verses.single.instrumental, isTrue);
    expect(blocks[1].time, kSongbookLeadIn + 8 * 0.5);
    expect(blocks[1].verses[1].cells.first.beat, 6);
    expect(s.totalBeats, 18);
    expect(s.progression.map((p) => p.startBeat), [0, 4, 8, 12, 14]);
  });

  test('locate and repeat window', () {
    final s = _song(['[C] [G]', '', '[Am]a [F]b'], bpm: 60, key: 'C');
    expect(locateInSong(s, 0).block, isNull);
    expect(locateInSong(s, kSongbookLeadIn + 5).cell!.chord, 'G');
    expect(locateInSong(s, kSongbookLeadIn + 8.1).block!.number, 2);
    expect(locateInSong(s, kSongbookLeadIn + 13).cell!.chord, 'F');
    expect(locateInSong(s, 99).block, isNull);
    final w = repeatWindow(s, 2, 2)!;
    expect((w.begin, w.end), (kSongbookLeadIn + 8, kSongbookLeadIn + 16));
    expect(repeatWindow(s, 2, 1), isNull);
  });

  test('bundled catalogue: search, tags, voicings for every chord', () {
    expect(bundled.length, 8);
    List<String> q(String x) => bundled.where((s) => songMatches(s, x)).map((s) => s.id).toList();
    expect(q('YAĞMUR'), contains('kiyi-yagmur-sonrasi'));
    expect(q('tag:caz'), ['selin-trio-gece-cazi']);
    expect(q('ece yalın').length, greaterThanOrEqualTo(2));
    expect(q('').length, bundled.length);
    expect(songbookTagCounts(bundled).first.$1, 'Pop');
    for (final s in bundled) {
      for (final c in s.uniqueChords) {
        expect(findVoicings(c, ChordInstrument.guitar, count: 1), isNotEmpty, reason: '${s.id} $c');
      }
    }
  });

  test('key-aware transpose and timed-sheet export', () {
    expect(transposeKeyName('Am', 1), 'Bbm');
    expect(transposeKeyName('C', 6), 'F#');
    expect(transposeForKey('G7', 1, 'Bbm'), 'Ab7');
    expect(transposeForKey('D/F#', -2, 'C'), 'C/E');
    expect(normalizeTranspose(7), -5);
    expect(normalizeTranspose(-8), 4);
    final p = chordDisplayParts('Bbm7/F');
    expect((p.root, p.degree, p.bass), ('B♭m', '7', 'F'));

    final song = bundled.first;
    final sheet = songbookToTimedSheet(song, transpose: 2);
    expect(sheet.bpm, song.bpm);
    expect(sheet.lines.where((l) => l.section != null).map((l) => l.section), contains('Nakarat'));
    final first = sheet.lines.firstWhere((l) => l.segments.isNotEmpty);
    expect(first.segments.first.chord, 'Bm'); // Am +2
    expect(first.segments.first.beats, 4);
  });

  test('backing track length and transposed bass pitch', () {
    final s = _song(['[A] [A]'], key: 'A');
    const sr = 8000;
    final a = renderSongbookBacking(s, 0, sampleRate: sr), b = renderSongbookBacking(s, 2, sampleRate: sr);
    expect(a.length, greaterThanOrEqualTo((s.duration * sr).round()));
    // Bass period: low-pass (moving average) then autocorrelate over the
    // E1..D#2 bass range only, so guitar partials cannot win.
    int period(List<double> raw) {
      final buf = List<double>.filled(raw.length, 0);
      var acc = 0.0;
      for (var i = 0; i < raw.length; i++) {
        acc += raw[i] - (i >= 24 ? raw[i - 24] : 0);
        buf[i] = acc / 24;
      }
      final from = ((kSongbookLeadIn + 0.3) * sr).round();
      var best = double.negativeInfinity, lag = 0;
      for (var l = sr ~/ 80; l <= sr ~/ 40; l++) {
        var c = 0.0;
        for (var i = 0; i < 2048; i++) {
          c += buf[from + i] * buf[from + i + l];
        }
        if (c > best) {
          best = c;
          lag = l;
        }
      }
      return lag;
    }

    final ratio = period(a) / period(b);
    expect((ratio - math.pow(2, 2 / 12)).abs(), lessThan(0.04), reason: 'ratio $ratio');
    expect(encodeWav16(a, sr).length, 44 + a.length * 2);
  });

  testWidgets('catalogue filters by genre and opens a song', (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: SongbookScreen(loader: () async => bundled)));
    await tester.pumpAndSettle();
    expect(find.text('Yağmur Sonrası'), findsWidgets);
    await tester.dragUntilVisible(find.text('Caz  1'), find.byType(ListView).first, const Offset(-150, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Caz  1'));
    await tester.pumpAndSettle();
    expect(find.text('Gece Cazı'), findsWidgets);
    expect(find.text('Yağmur Sonrası'), findsNothing);
    await tester.tap(find.text('Gece Cazı').first);
    await tester.pumpAndSettle();
    expect(find.text('Selin Trio'), findsOneWidget);
    expect(find.text('Nakarat'), findsWidgets);
    expect(find.byTooltip('Repertuvara ekle'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
