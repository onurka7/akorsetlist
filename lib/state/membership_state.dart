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
    // Paid app: all signed-in users have full access.
    currentPlan.value = MembershipPlan.full;
    await _repo.upsertPlan(email: user.email, plan: MembershipPlan.full);
    loading.value = false;
  }

  Future<void> selectPlan(MembershipPlan plan) async {
    if (_demoMode) {
      currentPlan.value = plan;
      return;
    }
    final user = AuthState.instance.currentUser.value;
    if (user == null) return;
    await _repo.upsertPlan(email: user.email, plan: plan);
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
