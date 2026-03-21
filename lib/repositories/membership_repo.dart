import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/membership_plan.dart';

class MembershipRepo {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<MembershipPlan?> getPlanByUserId(String userId) async {
    final snapshot = await _firestore.collection('users').doc(userId).get();
    if (!snapshot.exists) return null;
    final data = snapshot.data();
    return MembershipPlanX.fromKey(data?['plan'] as String?);
  }

  Future<void> upsertPlan({
    required String userId,
    required String email,
    required MembershipPlan plan,
    String? displayName,
    String? photoUrl,
    String? provider,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _firestore.collection('users').doc(userId).set({
      'uid': userId,
      'email': email,
      'displayName': displayName,
      'photoUrl': photoUrl,
      'provider': provider,
      'plan': plan.key,
      'updatedAt': now,
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
