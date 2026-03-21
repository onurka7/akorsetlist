import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/app_db.dart';
import 'user_storage_service.dart';

class BackupService {
  final _dbProvider = AppDb.instance;

  Future<File> exportToJsonFile() async {
    final db = await _dbProvider.db;

    final setlists = await db.query('setlists', orderBy: 'createdAt DESC');
    final songs = await db.query('songs', orderBy: 'id ASC');
    final items = await db.query('setlist_items', orderBy: 'orderIndex ASC');

    final setlistsJson = <Map<String, Object?>>[];
    for (final row in setlists) {
      final setlist = Map<String, Object?>.from(row);
      final coverPath = setlist['coverPath'] as String?;
      if (coverPath != null && coverPath.isNotEmpty) {
        final coverFile = File(coverPath);
        if (await coverFile.exists()) {
          final bytes = await coverFile.readAsBytes();
          setlist['coverFileName'] = p.basename(coverPath);
          setlist['coverBase64'] = base64Encode(bytes);
        }
      }
      setlistsJson.add(setlist);
    }

    final songsJson = <Map<String, Object?>>[];
    for (final row in songs) {
      final song = Map<String, Object?>.from(row);
      final offlinePath = song['offlinePath'] as String?;
      final audioPath = song['audioPath'] as String?;
      if (offlinePath != null && offlinePath.isNotEmpty) {
        final f = File(offlinePath);
        if (await f.exists()) {
          song['offlineHtml'] = await f.readAsString();
        }
      }
      if (audioPath != null && audioPath.isNotEmpty) {
        final f = File(audioPath);
        if (await f.exists()) {
          song['audioFileName'] = p.basename(audioPath);
          song['audioBase64'] = base64Encode(await f.readAsBytes());
        }
      }
      songsJson.add(song);
    }

    final payload = {
      'meta': {
        'schemaVersion': 1,
        'createdAt': DateTime.now().toIso8601String(),
        'app': 'Akor Setlist',
      },
      'setlists': setlistsJson,
      'songs': songsJson,
      'setlistItems': items.map((e) => Map<String, Object?>.from(e)).toList(),
    };

    final temp = await getTemporaryDirectory();
    final fileName =
        'akor_setlist_backup_${DateTime.now().millisecondsSinceEpoch}.json';
    final out = File(p.join(temp.path, fileName));
    await out.writeAsString(jsonEncode(payload), flush: true);
    return out;
  }

  Future<void> restoreFromJsonFile(String filePath) async {
    final backupFile = File(filePath);
    if (!await backupFile.exists()) {
      throw Exception('Yedek dosyası bulunamadı.');
    }

    final raw = await backupFile.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Yedek dosyası formatı geçersiz.');
    }

    final setlists =
        (decoded['setlists'] as List?)?.cast<Map>() ?? const <Map>[];
    final songs = (decoded['songs'] as List?)?.cast<Map>() ?? const <Map>[];
    final items =
        (decoded['setlistItems'] as List?)?.cast<Map>() ?? const <Map>[];

    final db = await _dbProvider.db;
    final songsDir = await UserStorageService.songsDirectory();
    final coversDir = await UserStorageService.coversDirectory();

    await db.transaction((txn) async {
      await txn.delete('setlist_items');
      await txn.delete('songs');
      await txn.delete('setlists');

      int maxSetlistId = 0;
      int maxSongId = 0;

      for (final rawSetlist in setlists) {
        final row =
            Map<String, Object?>.from(rawSetlist.cast<String, Object?>());
        final id = (row['id'] as int?) ?? 0;
        if (id > maxSetlistId) maxSetlistId = id;

        String? coverPath = row['coverPath'] as String?;
        final coverBase64 = row['coverBase64'] as String?;
        final coverFileName = row['coverFileName'] as String?;
        if (coverBase64 != null &&
            coverBase64.isNotEmpty &&
            coverFileName != null &&
            coverFileName.isNotEmpty) {
          final bytes = base64Decode(coverBase64);
          final restoredCover =
              File(p.join(coversDir.path, '${id}_$coverFileName'));
          await restoredCover.writeAsBytes(bytes, flush: true);
          coverPath = restoredCover.path;
        }

        await txn.insert('setlists', {
          'id': row['id'],
          'name': row['name'],
          'createdAt': row['createdAt'],
          'coverPath': coverPath,
        });
      }

      for (final rawSong in songs) {
        final row = Map<String, Object?>.from(rawSong.cast<String, Object?>());
        final id = (row['id'] as int?) ?? 0;
        if (id > maxSongId) maxSongId = id;

        String? offlinePath = row['offlinePath'] as String?;
        String? audioPath = row['audioPath'] as String?;
        final offlineHtml = row['offlineHtml'] as String?;
        final audioBase64 = row['audioBase64'] as String?;
        final audioFileName = row['audioFileName'] as String?;
        if (offlineHtml != null && offlineHtml.isNotEmpty) {
          final restoredSong = File(p.join(songsDir.path, '$id.html'));
          await restoredSong.writeAsString(offlineHtml, flush: true);
          offlinePath = restoredSong.path;
        }
        if (audioBase64 != null &&
            audioBase64.isNotEmpty &&
            audioFileName != null &&
            audioFileName.isNotEmpty) {
          final audioDir = await UserStorageService.audioDirectory();
          final restoredAudio =
              File(p.join(audioDir.path, '${id}_$audioFileName'));
          await restoredAudio.writeAsBytes(base64Decode(audioBase64),
              flush: true);
          audioPath = restoredAudio.path;
        }

        await txn.insert('songs', {
          'id': row['id'],
          'title': row['title'],
          'sourceUrl': row['sourceUrl'],
          'importedAt': row['importedAt'],
          'lastOpenedAt': row['lastOpenedAt'],
          'playCount': row['playCount'] ?? 0,
          'offlinePath': offlinePath,
          'audioPath': audioPath,
          'isFavorite': row['isFavorite'] ?? 0,
          'timedChordSheetJson': row['timedChordSheetJson'],
        });
      }

      for (final rawItem in items) {
        final row = Map<String, Object?>.from(rawItem.cast<String, Object?>());
        await txn.insert('setlist_items', {
          'setlistId': row['setlistId'],
          'songId': row['songId'],
          'orderIndex': row['orderIndex'],
          'tone': row['tone'],
          'durationMinutes': row['durationMinutes'],
        });
      }

      await txn.rawDelete(
        "DELETE FROM sqlite_sequence WHERE name IN ('setlists','songs')",
      );
      await txn.rawInsert(
        "INSERT INTO sqlite_sequence(name, seq) VALUES('setlists', ?)",
        [maxSetlistId],
      );
      await txn.rawInsert(
        "INSERT INTO sqlite_sequence(name, seq) VALUES('songs', ?)",
        [maxSongId],
      );
    });
  }
}
