enum MembershipPlan {
  free,
  annual,
}

extension MembershipPlanX on MembershipPlan {
  String get key => this == MembershipPlan.annual ? 'annual' : 'free';

  String get title =>
      this == MembershipPlan.annual ? 'Yillik Plan' : 'Free Plan';

  static MembershipPlan? fromKey(String? key) {
    if (key == 'annual') return MembershipPlan.annual;
    if (key == 'full') return MembershipPlan.annual;
    if (key == 'free') return MembershipPlan.free;
    return null;
  }
}
