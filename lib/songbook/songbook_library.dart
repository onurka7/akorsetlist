import 'dart:convert';

import '../models/song.dart';
import '../repositories/setlist_repo.dart';
import '../repositories/song_repo.dart';
import '../services/offline_reader_service.dart';
import '../services/timed_chord_sheet_service.dart';
import 'songbook.dart';

/// Saves a ready-made song into the user's library the same way the web
/// importer does: a timed chord sheet plus an offline reader page, so the
/// existing play screen opens it without network access.
class SongbookLibrary {
  final SongRepo _songs = SongRepo();
  final SetlistRepo _setlists = SetlistRepo();
  final TimedChordSheetService _sheets = TimedChordSheetService();
  final OfflineReaderService _offline = OfflineReaderService();

  static String sourceUrlFor(SongbookSong song, int transpose) =>
      'songbook://${song.id}${transpose == 0 ? '' : '?transpose=$transpose'}';

  static String titleFor(SongbookSong song, int transpose) {
    final key = transposeKeyName(song.key, transpose);
    return '${song.artist} - ${song.title}${transpose == 0 ? '' : ' (${prettyChord(key)})'}';
  }

  /// Returns (songId, alreadyExisted).
  Future<(int, bool)> save(SongbookSong song, {int transpose = 0, int? setlistId}) async {
    final title = titleFor(song, transpose);
    final url = sourceUrlFor(song, transpose);
    final existing = await _songs.findByTitleAndSourceUrl(title, url);
    final sheet = songbookToTimedSheet(song, transpose: transpose);
    final sheetJson = jsonEncode(sheet.toMap());
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = existing?.id ??
        await _songs.insertSong(Song(title: title, sourceUrl: url, importedAt: now, timedChordSheetJson: sheetJson));
    final offlinePath = await _offline.saveOfflineHtml(songId: id, html: _sheets.buildReaderHtml(sheet: sheet, title: title));
    await _songs.updateSong(Song(
      id: id,
      title: title,
      sourceUrl: url,
      importedAt: existing?.importedAt ?? now,
      lastOpenedAt: existing?.lastOpenedAt,
      playCount: existing?.playCount ?? 0,
      offlinePath: offlinePath,
      audioPath: existing?.audioPath,
      isFavorite: existing?.isFavorite ?? false,
      timedChordSheetJson: sheetJson,
    ));
    if (setlistId != null) await _setlists.addSongToSetlist(setlistId, id);
    return (id, existing != null);
  }
}
