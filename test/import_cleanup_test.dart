import 'package:akor_setlist/models/timed_chord_sheet.dart';
import 'package:akor_setlist/services/song_title.dart';
import 'package:akor_setlist/services/timed_chord_sheet_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('import title keeps only artist and song', () {
    expect(songTitleFrom(artist: ' Sezen Aksu ', song: 'Biliyorsun', pageTitle: 'Biliyorsun Akor ve Sözleri | Akormatik'),
        'Sezen Aksu - Biliyorsun');
    expect(cleanPageTitle('Biliyorsun Akor ve Sözleri | Akormatik'), 'Biliyorsun');
    expect(cleanPageTitle("Haluk Levent - Elfida akor - Google'da Ara"), 'Haluk Levent - Elfida');
    expect(cleanPageTitle('haluk levent elfida akor - Google Search'), 'haluk levent elfida');
    expect(cleanPageTitle('Elfida (Haluk Levent) Akorları'), 'Haluk Levent - Elfida');
    expect(cleanPageTitle('Duman – Bekle Dedi Gitti Gitar Akorları ve Sözleri'), 'Duman - Bekle Dedi Gitti');
    expect(cleanPageTitle('Jean-Michel Jarre - Oxygene Chords'), 'Jean-Michel Jarre - Oxygene');
    expect(cleanPageTitle('Teoman - Paramparça'), 'Teoman - Paramparça');
    expect(songTitleFrom(pageTitle: ''), '');
  });

  test('reader page shows only the title, no status bar', () {
    const sheet = TimedChordSheet(bpm: 90, lines: [
      TimedChordLine(section: 'Nakarat', segments: []),
      TimedChordLine(segments: [TimedChordSegment(lyric: 'gel', chord: 'Am', beats: 4)]),
    ]);
    final html = TimedChordSheetService().buildReaderHtml(sheet: sheet, title: 'Kıyı - Yağmur Sonrası');
    expect(html, contains('<h1 id="sheetTitle">Kıyı - Yağmur Sonrası</h1>'));
    for (final gone in ['Hazır</div>', 'Bölüm yok</span>', 'Timed prototype', 'sheetHud', 'sheetBpm']) {
      expect(html.contains(gone), isFalse, reason: gone);
    }
    expect(html, contains('window.timedSheet'));
  });
}
