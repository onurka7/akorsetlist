import 'dart:io';

import 'package:akor_setlist/services/user_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('stale absolute paths resolve to the same file name in the current folder', () async {
    final tmp = await Directory.systemTemp.createTemp('stored_path');
    addTearDown(() => tmp.delete(recursive: true));
    final current = await Directory(p.join(tmp.path, 'new', 'audio')).create(recursive: true);
    await File(p.join(current.path, '12.mp3')).writeAsString('x');
    Future<Directory> folder() async => current;

    // Old container path (moved by an update) -> found in the current folder.
    expect(await UserStorageService.resolveStoredFile(p.join(tmp.path, 'old', 'audio', '12.mp3'), folder),
        p.join(current.path, '12.mp3'));
    // Existing path is returned as is.
    expect(await UserStorageService.resolveStoredFile(p.join(current.path, '12.mp3'), folder), p.join(current.path, '12.mp3'));
    // Really missing, empty or null -> null.
    expect(await UserStorageService.resolveStoredFile(p.join(tmp.path, 'old', 'audio', '13.mp3'), folder), isNull);
    expect(await UserStorageService.resolveStoredFile('', folder), isNull);
    expect(await UserStorageService.resolveStoredFile(null, folder), isNull);
  });
}
