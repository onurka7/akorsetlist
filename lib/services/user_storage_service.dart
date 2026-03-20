import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../state/auth_state.dart';
import '../state/user_scope.dart';

class UserStorageService {
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

  static Future<Directory> _userRootDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final email = AuthState.instance.currentUser.value?.email;
    final userKey = UserScope.keyFromEmail(email);
    final dir = Directory(p.join(docs.path, 'users', userKey));
    if (!await dir.exists()) {
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
}
