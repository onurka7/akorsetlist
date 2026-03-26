import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/membership_profile.dart';
import '../models/membership_plan.dart';
import '../models/subscription_status.dart';

class MembershipRepo {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<MembershipProfile?> getProfileByUserId(String userId) async {
    final snapshot = await _firestore.collection('users').doc(userId).get();
    if (!snapshot.exists) return null;
    return MembershipProfile.fromMap(snapshot.data());
  }

  Future<MembershipPlan?> getPlanByUserId(String userId) async {
    final profile = await getProfileByUserId(userId);
    return profile?.plan;
  }

  Future<void> upsertPlan({
    required String userId,
    required String email,
    required MembershipPlan plan,
    SubscriptionStatus subscriptionStatus = SubscriptionStatus.none,
    DateTime? subscriptionExpiresAt,
    DateTime? subscriptionLastVerifiedAt,
    String? subscriptionPlatform,
    String? subscriptionProductId,
    String? originalTransactionId,
    bool clearSubscriptionFields = false,
    String? displayName,
    String? photoUrl,
    String? provider,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final profile = MembershipProfile(
      plan: plan,
      subscriptionStatus: clearSubscriptionFields
          ? SubscriptionStatus.none
          : subscriptionStatus,
      subscriptionExpiresAt:
          clearSubscriptionFields ? null : subscriptionExpiresAt,
      subscriptionLastVerifiedAt:
          clearSubscriptionFields ? null : subscriptionLastVerifiedAt,
      subscriptionPlatform:
          clearSubscriptionFields ? null : subscriptionPlatform,
      subscriptionProductId:
          clearSubscriptionFields ? null : subscriptionProductId,
      originalTransactionId:
          clearSubscriptionFields ? null : originalTransactionId,
    );

    await _firestore.collection('users').doc(userId).set({
      'uid': userId,
      'email': email,
      'displayName': displayName,
      'photoUrl': photoUrl,
      'provider': provider,
      ...profile.toFirestore(),
      'updatedAt': now,
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> markAnnualPurchase({
    required String userId,
    required String email,
    String? displayName,
    String? photoUrl,
    String? provider,
  }) async {
    await upsertPlan(
      userId: userId,
      email: email,
      plan: MembershipPlan.annual,
      subscriptionStatus: SubscriptionStatus.active,
      subscriptionPlatform: 'app_store_local',
      subscriptionLastVerifiedAt: DateTime.now().toUtc(),
      displayName: displayName,
      photoUrl: photoUrl,
      provider: provider,
    );
  }
}
