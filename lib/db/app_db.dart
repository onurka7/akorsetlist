import 'dart:io';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../state/auth_state.dart';
import '../state/user_scope.dart';

class AppDb {
  static final AppDb instance = AppDb._();
  AppDb._();

  Database? _db;
  String? _activeUserKey;

  Future<Database> get db async {
    final userEmail = AuthState.instance.currentUser.value?.email;
    final userKey = UserScope.keyFromEmail(userEmail);
    final dbPath = await _resolveDbPath(userKey);

    if (_db != null && _activeUserKey == userKey) return _db!;

    if (_db != null && _activeUserKey != userKey) {
      await _db!.close();
      _db = null;
    }

    _db = await openDatabase(
      dbPath,
      version: 9,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE setlists(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            coverPath TEXT
          );
        ''');

        await db.execute('''
          CREATE TABLE songs(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            sourceUrl TEXT NOT NULL,
            importedAt INTEGER NOT NULL,
            lastOpenedAt INTEGER,
            playCount INTEGER NOT NULL DEFAULT 0,
            offlinePath TEXT,
            audioPath TEXT,
            isFavorite INTEGER NOT NULL DEFAULT 0,
            timedChordSheetJson TEXT
          );
        ''');

        await db.execute('''
          CREATE TABLE setlist_items(
            setlistId INTEGER NOT NULL,
            songId INTEGER NOT NULL,
            orderIndex INTEGER NOT NULL,
            tone TEXT,
            durationMinutes INTEGER,
            PRIMARY KEY(setlistId, songId)
          );
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE setlists ADD COLUMN coverPath TEXT');
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE songs ADD COLUMN playCount INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 4) {
          await db.execute(
            'ALTER TABLE songs ADD COLUMN isFavorite INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 6) {
          await db.execute(
            'ALTER TABLE setlist_items ADD COLUMN tone TEXT',
          );
          await db.execute(
            'ALTER TABLE setlist_items ADD COLUMN durationMinutes INTEGER',
          );
        }
        if (oldVersion < 7) {
          await db.execute(
            'ALTER TABLE songs ADD COLUMN timedChordSheetJson TEXT',
          );
        }
        if (oldVersion < 8) {
          await db.execute(
            'ALTER TABLE songs ADD COLUMN audioPath TEXT',
          );
        }
        if (oldVersion < 9) {
          await db.execute('DROP TABLE IF EXISTS user_memberships');
        }
      },
    );

    _activeUserKey = userKey;
    return _db!;
  }

  Future<String> _resolveDbPath(String userKey) async {
    final dbDir = await getDatabasesPath();
    final legacyPath = join(dbDir, 'akor_setlist.db');
    final userDbPath = join(dbDir, 'akor_setlist_$userKey.db');

    final userDbFile = File(userDbPath);
    if (await userDbFile.exists()) return userDbPath;

    final legacyDbFile = File(legacyPath);
    if (!await legacyDbFile.exists()) return userDbPath;

    final existingUserDbs = await Directory(dbDir)
        .list()
        .where(
          (e) =>
              e is File &&
              basename(e.path).startsWith('akor_setlist_') &&
              basename(e.path).endsWith('.db'),
        )
        .toList();

    if (existingUserDbs.isEmpty) {
      await legacyDbFile.copy(userDbPath);
    }

    return userDbPath;
  }

  Future<void> deleteCurrentUserDatabase() async {
    final userEmail = AuthState.instance.currentUser.value?.email;
    if (userEmail == null || userEmail.isEmpty) return;
    final userDbPath = await _dbPathForEmail(userEmail);

    if (_db != null && _activeUserKey == UserScope.keyFromEmail(userEmail)) {
      await _db!.close();
      _db = null;
      _activeUserKey = null;
    }

    final dbFile = File(userDbPath);
    if (await dbFile.exists()) {
      await deleteDatabase(userDbPath);
    }
  }

  Future<String> _dbPathForEmail(String email) async {
    final dbDir = await getDatabasesPath();
    final userKey = UserScope.keyFromEmail(email);
    return join(dbDir, 'akor_setlist_$userKey.db');
  }
}
