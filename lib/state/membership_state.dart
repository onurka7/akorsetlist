import '../models/membership_plan.dart';
import '../repositories/membership_repo.dart';
import 'auth_state.dart';
import 'package:flutter/material.dart';

class MembershipState {
  MembershipState._();

  static final MembershipState instance = MembershipState._();

  final MembershipRepo _repo = MembershipRepo();
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
      currentPlan.value = null;
      loading.value = false;
      return;
    }
    final existing = await _repo.getPlanByUserId(user.id);
    final effectivePlan = existing ?? MembershipPlan.full;
    currentPlan.value = effectivePlan;
    await _repo.upsertPlan(
      userId: user.id,
      email: user.email,
      plan: effectivePlan,
      displayName: user.displayName,
      photoUrl: user.photoUrl,
      provider: user.provider.name,
    );
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
      displayName: user.displayName,
      photoUrl: user.photoUrl,
      provider: user.provider.name,
    );
    currentPlan.value = plan;
  }

  void enableDemoMode({MembershipPlan plan = MembershipPlan.full}) {
    _demoMode = true;
    currentPlan.value = plan;
    loading.value = false;
  }

  void disableDemoMode() {
    _demoMode = false;
    if (AuthState.instance.currentUser.value == null) {
      currentPlan.value = null;
      loading.value = false;
    }
  }

  void _onUserChanged() {
    _reloadForCurrentUser();
  }

  bool get isFull => currentPlan.value == MembershipPlan.full;
  bool get isFree => currentPlan.value == MembershipPlan.free;
  bool get isDemoMode => _demoMode;

  Future<void> dispose() async {
    final listener = _authListener;
    if (listener != null) {
      AuthState.instance.currentUser.removeListener(listener);
    }
    currentPlan.dispose();
    loading.dispose();
  }
}
