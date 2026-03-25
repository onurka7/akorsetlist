import 'package:cloud_firestore/cloud_firestore.dart';

import 'membership_plan.dart';
import 'subscription_status.dart';

class MembershipProfile {
  final MembershipPlan plan;
  final SubscriptionStatus subscriptionStatus;
  final DateTime? subscriptionExpiresAt;
  final DateTime? subscriptionLastVerifiedAt;
  final String? subscriptionPlatform;
  final String? subscriptionProductId;
  final String? originalTransactionId;

  const MembershipProfile({
    required this.plan,
    this.subscriptionStatus = SubscriptionStatus.none,
    this.subscriptionExpiresAt,
    this.subscriptionLastVerifiedAt,
    this.subscriptionPlatform,
    this.subscriptionProductId,
    this.originalTransactionId,
  });

  bool get hasActiveSubscription {
    if (plan != MembershipPlan.annual) return false;
    final expiresAt = subscriptionExpiresAt;
    if (expiresAt == null) return false;
    return expiresAt.isAfter(DateTime.now().toUtc());
  }

  MembershipProfile copyWith({
    MembershipPlan? plan,
    SubscriptionStatus? subscriptionStatus,
    DateTime? subscriptionExpiresAt,
    DateTime? subscriptionLastVerifiedAt,
    String? subscriptionPlatform,
    String? subscriptionProductId,
    String? originalTransactionId,
    bool clearSubscriptionFields = false,
  }) {
    return MembershipProfile(
      plan: plan ?? this.plan,
      subscriptionStatus: subscriptionStatus ?? this.subscriptionStatus,
      subscriptionExpiresAt: clearSubscriptionFields
          ? null
          : (subscriptionExpiresAt ?? this.subscriptionExpiresAt),
      subscriptionLastVerifiedAt: clearSubscriptionFields
          ? null
          : (subscriptionLastVerifiedAt ?? this.subscriptionLastVerifiedAt),
      subscriptionPlatform: clearSubscriptionFields
          ? null
          : (subscriptionPlatform ?? this.subscriptionPlatform),
      subscriptionProductId: clearSubscriptionFields
          ? null
          : (subscriptionProductId ?? this.subscriptionProductId),
      originalTransactionId: clearSubscriptionFields
          ? null
          : (originalTransactionId ?? this.originalTransactionId),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'plan': plan.key,
      'subscriptionStatus': subscriptionStatus.key,
      'subscriptionPlatform': subscriptionPlatform,
      'subscriptionProductId': subscriptionProductId,
      'originalTransactionId': originalTransactionId,
      'subscriptionExpiresAt': subscriptionExpiresAt == null
          ? null
          : Timestamp.fromDate(subscriptionExpiresAt!.toUtc()),
      'subscriptionLastVerifiedAt': subscriptionLastVerifiedAt == null
          ? null
          : Timestamp.fromDate(subscriptionLastVerifiedAt!.toUtc()),
    };
  }

  static MembershipProfile fromMap(Map<String, dynamic>? data) {
    final source = data ?? const <String, dynamic>{};
    return MembershipProfile(
      plan: MembershipPlanX.fromKey(source['plan'] as String?) ??
          MembershipPlan.free,
      subscriptionStatus: SubscriptionStatusX.fromKey(
        source['subscriptionStatus'] as String?,
      ),
      subscriptionExpiresAt: _readDateTime(source['subscriptionExpiresAt']),
      subscriptionLastVerifiedAt:
          _readDateTime(source['subscriptionLastVerifiedAt']),
      subscriptionPlatform: source['subscriptionPlatform'] as String?,
      subscriptionProductId: source['subscriptionProductId'] as String?,
      originalTransactionId: source['originalTransactionId'] as String?,
    );
  }

  static MembershipProfile fromFunctionResult(Map<dynamic, dynamic> data) {
    return MembershipProfile(
      plan: MembershipPlanX.fromKey(data['plan'] as String?) ??
          MembershipPlan.free,
      subscriptionStatus: SubscriptionStatusX.fromKey(
        data['subscriptionStatus'] as String?,
      ),
      subscriptionExpiresAt: _readDateTime(
          data['subscriptionExpiresAtIso'] ?? data['subscriptionExpiresAtMs']),
      subscriptionLastVerifiedAt: _readDateTime(
        data['subscriptionLastVerifiedAtIso'] ??
            data['subscriptionLastVerifiedAtMs'],
      ),
      subscriptionPlatform: data['subscriptionPlatform'] as String?,
      subscriptionProductId: data['subscriptionProductId'] as String?,
      originalTransactionId: data['originalTransactionId'] as String?,
    );
  }

  static DateTime? _readDateTime(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate().toUtc();
    if (value is DateTime) return value.toUtc();
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value)?.toUtc();
    }
    return null;
  }
}
