import '../db/app_db.dart';
import '../models/setlist.dart';
import '../models/song.dart';
import '../models/setlist_item.dart';

class SetlistRepo {
  final _db = AppDb.instance;

  Future<int> countSetlists() async {
    final db = await _db.db;
    final r = await db.rawQuery('SELECT COUNT(*) c FROM setlists');
    return (r.first['c'] as int?) ?? 0;
  }

  Future<int> createSetlist(String name, {String? coverPath}) async {
    final db = await _db.db;
    return db.insert(
      'setlists',
      Setlist(
        name: name,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        coverPath: coverPath,
      ).toMap(),
    );
  }

  Future<String> nextAvailableSetlistName(String desiredName) async {
    final db = await _db.db;
    final base =
        desiredName.trim().isEmpty ? 'Yeni Repertuar' : desiredName.trim();
    final rows = await db.query(
      'setlists',
      columns: ['name'],
      where: 'LOWER(name) = ? OR LOWER(name) LIKE ?',
      whereArgs: [base.toLowerCase(), '${base.toLowerCase()} (%)'],
    );
    final used = rows
        .map((row) => (row['name'] as String?)?.trim())
        .whereType<String>()
        .toSet();
    if (!used.contains(base)) return base;

    var suffix = 2;
    while (used.contains('$base ($suffix)')) {
      suffix++;
    }
    return '$base ($suffix)';
  }

  Future<void> removeSongFromSetlist(int setlistId, int songId) async {
    final db = await _db.db;

    await db.delete(
      'setlist_items',
      where: 'setlistId = ? AND songId = ?',
      whereArgs: [setlistId, songId],
    );
  }

  Future<void> removeSongFromAllSetlists(int songId) async {
    final db = await _db.db;
    await db.delete(
      'setlist_items',
      where: 'songId = ?',
      whereArgs: [songId],
    );
  }

  Future<List<Setlist>> listSetlists() async {
    final db = await _db.db;
    final rows = await db.query('setlists', orderBy: 'createdAt DESC');
    return rows.map(Setlist.fromMap).toList();
  }

  Future<void> renameSetlist(int id, String name) async {
    final db = await _db.db;
    await db.update('setlists', {'name': name},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteSetlist(int id) async {
    final db = await _db.db;
    await db.delete('setlists', where: 'id = ?', whereArgs: [id]);
    await db.delete('setlist_items', where: 'setlistId = ?', whereArgs: [id]);
  }

  Future<int> countSongsInSetlist(int setlistId) async {
    final db = await _db.db;
    final r = await db.rawQuery(
        'SELECT COUNT(*) c FROM setlist_items WHERE setlistId=?', [setlistId]);
    return (r.first['c'] as int?) ?? 0;
  }

  Future<List<Song>> listSongsInSetlist(int setlistId) async {
    final db = await _db.db;
    final rows = await db.rawQuery('''
      SELECT s.* FROM songs s
      JOIN setlist_items i ON i.songId = s.id
      WHERE i.setlistId = ?
      ORDER BY i.orderIndex ASC
    ''', [setlistId]);

    return rows.map((m) => Song.fromMap(Map<String, Object?>.from(m))).toList();
  }

  Future<List<SetlistItem>> listSetlistItems(int setlistId) async {
    final db = await _db.db;
    final rows = await db.query(
      'setlist_items',
      where: 'setlistId = ?',
      whereArgs: [setlistId],
      orderBy: 'orderIndex ASC',
    );
    return rows.map(SetlistItem.fromMap).toList();
  }

  Future<void> updateSetlistItemMeta(
    int setlistId,
    int songId, {
    String? tone,
    int? durationMinutes,
  }) async {
    final db = await _db.db;
    await db.update(
      'setlist_items',
      {
        'tone': tone?.trim().isEmpty ?? true ? null : tone!.trim(),
        'durationMinutes': durationMinutes,
      },
      where: 'setlistId = ? AND songId = ?',
      whereArgs: [setlistId, songId],
    );
  }

  Future<Setlist?> firstSetlistForSong(int songId) async {
    final db = await _db.db;
    final rows = await db.rawQuery(
      '''
      SELECT s.* FROM setlists s
      JOIN setlist_items i ON i.setlistId = s.id
      WHERE i.songId = ?
      ORDER BY s.createdAt DESC
      LIMIT 1
      ''',
      [songId],
    );
    if (rows.isEmpty) return null;
    return Setlist.fromMap(Map<String, Object?>.from(rows.first));
  }

  Future<void> setOrder(int setlistId, List<int> songIdsInOrder) async {
    final db = await _db.db;
    final batch = db.batch();
    for (var i = 0; i < songIdsInOrder.length; i++) {
      batch.update(
        'setlist_items',
        {'orderIndex': i},
        where: 'setlistId = ? AND songId = ?',
        whereArgs: [setlistId, songIdsInOrder[i]],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> addSongToSetlist(int setlistId, int songId) async {
    final db = await _db.db;
    final r = await db.rawQuery(
        'SELECT MAX(orderIndex) m FROM setlist_items WHERE setlistId=?',
        [setlistId]);
    final maxIdx = (r.first['m'] as int?) ?? -1;
    await db.insert('setlist_items', {
      'setlistId': setlistId,
      'songId': songId,
      'orderIndex': maxIdx + 1,
      'tone': null,
      'durationMinutes': null,
    });
  }
}
