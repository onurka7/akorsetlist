import '../db/app_db.dart';
import '../models/song.dart';

class SongRepo {
  final _db = AppDb.instance;

  Future<int> countSongs() async {
    final db = await _db.db;
    final r = await db.rawQuery('SELECT COUNT(*) c FROM songs');
    return (r.first['c'] as int?) ?? 0;
  }

  Future<int> insertSong(Song s) async {
    final db = await _db.db;
    return db.insert('songs', s.toMap());
  }

  Future<Song?> findByTitleAndSourceUrl(String title, String sourceUrl) async {
    final db = await _db.db;
    final normalizedTitle = title.trim().toLowerCase();
    final normalizedUrl = sourceUrl.trim().toLowerCase();
    final rows = await db.query(
      'songs',
      where: 'LOWER(title) = ? AND LOWER(sourceUrl) = ?',
      whereArgs: [normalizedTitle, normalizedUrl],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Song.fromMap(rows.first);
  }

  Future<void> renameSong(int id, String newTitle) async {
    final db = await _db.db;
    await db.update(
      'songs',
      {'title': newTitle},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteSong(int id) async {
    final db = await _db.db;
    await db.delete(
      'songs',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateSong(Song s) async {
    final db = await _db.db;
    await db.update('songs', s.toMap(), where: 'id = ?', whereArgs: [s.id]);
  }

  Future<void> setFavorite(int songId, bool isFavorite) async {
    final db = await _db.db;
    await db.update(
      'songs',
      {'isFavorite': isFavorite ? 1 : 0},
      where: 'id = ?',
      whereArgs: [songId],
    );
  }

  Future<void> touchLastOpened(int songId) async {
    final db = await _db.db;
    await db.rawUpdate(
      '''
      UPDATE songs
      SET lastOpenedAt = ?, playCount = COALESCE(playCount, 0) + 1
      WHERE id = ?
      ''',
      [DateTime.now().millisecondsSinceEpoch, songId],
    );
  }

  Future<List<Song>> searchSongsByTitle(String query, {int limit = 100}) async {
    final db = await _db.db;
    final q = query.trim().toLowerCase();
    final rows = await db.query(
      'songs',
      where: q.isEmpty ? null : 'LOWER(title) LIKE ?',
      whereArgs: q.isEmpty ? null : ['%$q%'],
      orderBy: 'COALESCE(lastOpenedAt, importedAt) DESC',
      limit: limit,
    );
    return rows.map(Song.fromMap).toList();
  }

  Future<List<Song>> listAllSongs({int limit = 500}) async {
    final db = await _db.db;
    final rows = await db.query(
      'songs',
      orderBy: 'COALESCE(lastOpenedAt, importedAt) DESC',
      limit: limit,
    );
    return rows.map(Song.fromMap).toList();
  }

  Future<List<Song>> listFavoriteSongs({int limit = 500}) async {
    final db = await _db.db;
    final rows = await db.query(
      'songs',
      where: 'isFavorite = 1',
      orderBy: 'COALESCE(lastOpenedAt, importedAt) DESC',
      limit: limit,
    );
    return rows.map(Song.fromMap).toList();
  }
}
