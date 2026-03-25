enum SubscriptionStatus {
  none,
  active,
  expired,
  cancelled,
  billingRetry,
  gracePeriod,
}

extension SubscriptionStatusX on SubscriptionStatus {
  String get key {
    switch (this) {
      case SubscriptionStatus.none:
        return 'none';
      case SubscriptionStatus.active:
        return 'active';
      case SubscriptionStatus.expired:
        return 'expired';
      case SubscriptionStatus.cancelled:
        return 'cancelled';
      case SubscriptionStatus.billingRetry:
        return 'billing_retry';
      case SubscriptionStatus.gracePeriod:
        return 'grace_period';
    }
  }

  static SubscriptionStatus fromKey(String? key) {
    switch (key) {
      case 'active':
        return SubscriptionStatus.active;
      case 'expired':
        return SubscriptionStatus.expired;
      case 'cancelled':
        return SubscriptionStatus.cancelled;
      case 'billing_retry':
        return SubscriptionStatus.billingRetry;
      case 'grace_period':
        return SubscriptionStatus.gracePeriod;
      case 'none':
      default:
        return SubscriptionStatus.none;
    }
  }
}
