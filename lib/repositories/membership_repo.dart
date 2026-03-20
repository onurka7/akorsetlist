import '../db/app_db.dart';
import '../models/membership_plan.dart';
import 'package:sqflite/sqflite.dart';

class MembershipRepo {
  final _db = AppDb.instance;

  Future<MembershipPlan?> getPlanByEmail(String email) async {
    final db = await _db.db;
    final rows = await db.query(
      'user_memberships',
      where: 'email = ?',
      whereArgs: [email],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return MembershipPlanX.fromKey(rows.first['plan'] as String?);
  }

  Future<void> upsertPlan({
    required String email,
    required MembershipPlan plan,
  }) async {
    final db = await _db.db;
    await db.insert(
      'user_memberships',
      {
        'email': email,
        'plan': plan.key,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
