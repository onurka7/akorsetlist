import '../models/membership_profile.dart';
import '../models/membership_plan.dart';
import '../models/subscription_status.dart';
import '../repositories/membership_repo.dart';
import 'auth_state.dart';
import 'package:flutter/material.dart';

class MembershipState {
  MembershipState._();

  static final MembershipState instance = MembershipState._();

  final MembershipRepo _repo = MembershipRepo();
  final ValueNotifier<MembershipProfile?> currentProfile =
      ValueNotifier<MembershipProfile?>(null);
  final ValueNotifier<MembershipPlan?> currentPlan =
      ValueNotifier<MembershipPlan?>(null);
  final ValueNotifier<bool> loading = ValueNotifier<bool>(true);
  bool _demoMode = false;

  VoidCallback? _authListener;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    await AuthState.instance.initialize();
    _authListener = _onUserChanged;
    AuthState.instance.currentUser.addListener(_authListener!);
    await _reloadForCurrentUser();
  }

  Future<void> _reloadForCurrentUser() async {
    if (_demoMode) {
      loading.value = false;
      return;
    }
    loading.value = true;
    final user = AuthState.instance.currentUser.value;
    if (user == null) {
      _setProfile(null);
      loading.value = false;
      return;
    }
    var profile = await _repo.getProfileByUserId(user.id);
    if (profile == null) {
      profile = const MembershipProfile(plan: MembershipPlan.free);
      await _repo.upsertPlan(
        userId: user.id,
        email: user.email,
        plan: profile.plan,
        displayName: user.displayName,
        photoUrl: user.photoUrl,
        provider: user.provider.name,
      );
    }

    final hasRecognizedAnnualAccess = profile.plan != MembershipPlan.annual ||
        profile.subscriptionPlatform == 'app_store_local' ||
        profile.subscriptionPlatform == 'app_store';
    if (!hasRecognizedAnnualAccess) {
      profile = const MembershipProfile(plan: MembershipPlan.free);
      await _repo.upsertPlan(
        userId: user.id,
        email: user.email,
        plan: MembershipPlan.free,
        clearSubscriptionFields: true,
        displayName: user.displayName,
        photoUrl: user.photoUrl,
        provider: user.provider.name,
      );
    }

    _setProfile(profile);
    loading.value = false;
  }

  Future<void> selectPlan(MembershipPlan plan) async {
    if (_demoMode) {
      currentPlan.value = plan;
      return;
    }
    final user = AuthState.instance.currentUser.value;
    if (user == null) return;
    await _repo.upsertPlan(
      userId: user.id,
      email: user.email,
      plan: plan,
      clearSubscriptionFields: plan == MembershipPlan.free,
      displayName: user.displayName,
      photoUrl: user.photoUrl,
      provider: user.provider.name,
    );
    _setProfile(MembershipProfile(plan: plan));
  }

  Future<void> reload() async {
    await _reloadForCurrentUser();
  }

  Future<void> markAnnualPurchase() async {
    if (_demoMode) {
      _setProfile(
        MembershipProfile(
          plan: MembershipPlan.annual,
          subscriptionStatus: SubscriptionStatus.active,
          subscriptionPlatform: 'app_store_local',
          subscriptionLastVerifiedAt: DateTime.now().toUtc(),
        ),
      );
      return;
    }
    final user = AuthState.instance.currentUser.value;
    if (user == null) return;

    final profile = MembershipProfile(
      plan: MembershipPlan.annual,
      subscriptionStatus: SubscriptionStatus.active,
      subscriptionPlatform: 'app_store_local',
      subscriptionLastVerifiedAt: DateTime.now().toUtc(),
    );
    await _repo.markAnnualPurchase(
      userId: user.id,
      email: user.email,
      displayName: user.displayName,
      photoUrl: user.photoUrl,
      provider: user.provider.name,
    );
    _setProfile(profile);
  }

  void enableDemoMode({MembershipPlan plan = MembershipPlan.annual}) {
    _demoMode = true;
    _setProfile(MembershipProfile(plan: plan));
    loading.value = false;
  }

  void disableDemoMode() {
    _demoMode = false;
    if (AuthState.instance.currentUser.value == null) {
      _setProfile(null);
      loading.value = false;
    }
  }

  void _onUserChanged() {
    _reloadForCurrentUser();
  }

  bool get isAnnual => currentPlan.value == MembershipPlan.annual;
  bool get isFull => isAnnual;
  bool get isFree => currentPlan.value == MembershipPlan.free;
  bool get isDemoMode => _demoMode;

  void _setProfile(MembershipProfile? profile) {
    currentProfile.value = profile;
    currentPlan.value = profile?.plan;
  }

  Future<void> dispose() async {
    final listener = _authListener;
    if (listener != null) {
      AuthState.instance.currentUser.removeListener(listener);
    }
    currentProfile.dispose();
    currentPlan.dispose();
    loading.dispose();
  }
}
