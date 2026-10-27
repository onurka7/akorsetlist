import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../state/auth_state.dart';
import '../state/user_scope.dart';

class UserStorageService {
  /// Resolves a stored file path that may have gone stale.
  ///
  /// Paths are saved absolute, but iOS moves the app container on every
  /// update/reinstall and the per-user folder changes with the signed-in
  /// account. Files keep their names, so fall back to the same name in
  /// [folder]. Returns null when the file is really gone.
  static Future<String?> resolveStoredFile(String? stored, Future<Directory> Function() folder) async {
    if (stored == null || stored.isEmpty) return null;
    if (await File(stored).exists()) return stored;
    final candidate = File(p.join((await folder()).path, p.basename(stored)));
    return await candidate.exists() ? candidate.path : null;
  }

  static Future<Directory> songsDirectory() async {
    final root = await _userRootDirectory();
    final dir = Directory(p.join(root.path, 'songs'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> coversDirectory() async {
    final root = await _userRootDirectory();
    final dir = Directory(p.join(root.path, 'setlist_covers'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> audioDirectory() async {
    final root = await _userRootDirectory();
    final dir = Directory(p.join(root.path, 'audio'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> _userRootDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final email = AuthState.instance.currentUser.value?.email;
    final userKey = UserScope.keyFromEmail(email);
    final dir = Directory(p.join(docs.path, 'users', userKey));
    if (!await dir.exists()) {
      await _migrateOldSandboxStorageIfNeeded(userKey, dir);
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<void> deleteCurrentUserStorage() async {
    final root = await _userRootDirectory();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }

  static Future<void> _migrateOldSandboxStorageIfNeeded(
    String userKey,
    Directory targetDir,
  ) async {
    if (!Platform.isMacOS) return;
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return;

    final oldDir = Directory(
      p.join(
        home,
        'Library',
        'Containers',
        'com.example.akorSetlist',
        'Data',
        'Documents',
        'users',
        userKey,
      ),
    );
    if (!await oldDir.exists()) return;

    await _copyDirectory(oldDir, targetDir);
  }

  static Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(recursive: false)) {
      final newPath = p.join(target.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      } else if (entity is File) {
        await entity.copy(newPath);
      }
    }
  }
}
