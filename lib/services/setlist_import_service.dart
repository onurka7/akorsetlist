import 'dart:convert';
import 'dart:io';

import '../models/song.dart';
import '../repositories/setlist_repo.dart';
import '../repositories/song_repo.dart';

class SetlistImportService {
  final SetlistRepo _setlistRepo = SetlistRepo();
  final SongRepo _songRepo = SongRepo();

  Future<String> importSharedSetlist(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Paylaşılan repertuar dosyası bulunamadı.');
    }

    final raw = await file.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Dosya formatı geçersiz.');
    }

    if (decoded['format'] != 'akor_setlist_share_v1') {
      throw Exception('Bu dosya repertuar paylaşım formatında değil.');
    }

    final setlistMap = decoded['setlist'];
    final songsRaw = decoded['songs'];
    if (setlistMap is! Map || songsRaw is! List) {
      throw Exception('Paylaşılan repertuar içeriği eksik.');
    }

    final baseName = (setlistMap['name'] as String?)?.trim();
    final setlistName = (baseName == null || baseName.isEmpty)
        ? 'Paylaşılan Repertuar'
        : baseName;
    final uniqueSetlistName = await _setlistRepo.nextAvailableSetlistName(
      '$setlistName (Paylaşılan)',
    );
    final importedSetlistId = await _setlistRepo.createSetlist(
      uniqueSetlistName,
    );

    var importedCount = 0;
    final addedSongIds = <int>{};
    for (final entry in songsRaw) {
      if (entry is! Map) continue;
      final title = (entry['title'] as String?)?.trim();
      final sourceUrl = (entry['sourceUrl'] as String?)?.trim();
      final tone = (entry['tone'] as String?)?.trim();
      final durationMinutes = entry['durationMinutes'] as int?;
      if (title == null ||
          title.isEmpty ||
          sourceUrl == null ||
          sourceUrl.isEmpty) {
        continue;
      }

      final existingSong = await _songRepo.findByTitleAndSourceUrl(
        title,
        sourceUrl,
      );
      final songId = existingSong?.id ??
          await _songRepo.insertSong(
            Song(
              title: title,
              sourceUrl: sourceUrl,
              importedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
      if (!addedSongIds.add(songId)) {
        continue;
      }
      await _setlistRepo.addSongToSetlist(importedSetlistId, songId);
      await _setlistRepo.updateSetlistItemMeta(
        importedSetlistId,
        songId,
        tone: tone,
        durationMinutes: durationMinutes != null && durationMinutes > 0
            ? durationMinutes
            : null,
      );
      importedCount++;
    }

    if (importedCount == 0) {
      await _setlistRepo.deleteSetlist(importedSetlistId);
      throw Exception('Dosyada içe aktarılabilir şarkı bulunamadı.');
    }

    return '$uniqueSetlistName ($importedCount şarkı)';
  }
}
