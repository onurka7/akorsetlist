import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/setlist.dart';
import '../models/setlist_item.dart';
import '../models/song.dart';

class SetlistSharePayload {
  final File file;
  final String shareText;

  const SetlistSharePayload({
    required this.file,
    required this.shareText,
  });
}

class SetlistShareService {
  Future<SetlistSharePayload> buildPayload({
    required Setlist setlist,
    required List<Song> songs,
    Map<int, SetlistItem> itemMetaBySongId = const <int, SetlistItem>{},
  }) async {
    final tempDir = await getTemporaryDirectory();
    final safeName = _safeFileName(setlist.name);
    final file = File(
      p.join(
        tempDir.path,
        'repertuar_${safeName}_${DateTime.now().millisecondsSinceEpoch}.akorsetlist',
      ),
    );

    final payload = <String, Object?>{
      'format': 'akor_setlist_share_v1',
      'exportedAt': DateTime.now().toIso8601String(),
      'setlist': {
        'name': setlist.name,
        'createdAt': setlist.createdAt,
      },
      'songs': songs.map(
        (song) {
          final meta = song.id == null ? null : itemMetaBySongId[song.id!];
          return <String, Object?>{
            'title': song.title,
            'sourceUrl': song.sourceUrl,
            'importedAt': song.importedAt,
            'tone': meta?.tone,
            'durationMinutes': meta?.durationMinutes,
          };
        },
      ).toList(),
    };

    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );

    return SetlistSharePayload(
      file: file,
      shareText: _buildShareText(
        setlist: setlist,
        songs: songs,
        itemMetaBySongId: itemMetaBySongId,
      ),
    );
  }

  String _buildShareText({
    required Setlist setlist,
    required List<Song> songs,
    required Map<int, SetlistItem> itemMetaBySongId,
  }) {
    final buffer = StringBuffer()
      ..writeln('Akor Setlist repertuar paylaşımı')
      ..writeln()
      ..writeln('Repertuar: ${setlist.name}')
      ..writeln('Şarkı sayısı: ${songs.length}')
      ..writeln();

    for (var i = 0; i < songs.length; i++) {
      final song = songs[i];
      final meta = song.id == null ? null : itemMetaBySongId[song.id!];
      final details = <String>[];
      if (meta?.tone != null && meta!.tone!.trim().isNotEmpty) {
        details.add('Ton: ${meta.tone!.trim()}');
      }
      if (meta?.durationMinutes != null && meta!.durationMinutes! > 0) {
        details.add('Süre: ${meta.durationMinutes} dk');
      }
      final suffix = details.isEmpty ? '' : ' [${details.join(' • ')}]';
      buffer.writeln('${i + 1}. ${song.title}$suffix');
    }

    buffer
      ..writeln()
      ..writeln(
        'Ekli dosya repertuar verisini içerir. Akor Setlist kullanan biriyle paylaşabilirsin.',
      );

    return buffer.toString().trim();
  }

  String _safeFileName(String input) {
    final normalized = input
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return normalized.isEmpty ? 'setlist' : normalized;
  }
}
