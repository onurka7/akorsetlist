enum MembershipPlan {
  free,
  full,
}

extension MembershipPlanX on MembershipPlan {
  String get key => this == MembershipPlan.full ? 'full' : 'free';

  String get title =>
      this == MembershipPlan.full ? 'Full Üyelik' : 'Free Üyelik';

  static MembershipPlan? fromKey(String? key) {
    if (key == 'full') return MembershipPlan.full;
    if (key == 'free') return MembershipPlan.free;
    return null;
  }
}
