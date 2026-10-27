import '../models/membership_profile.dart';
import '../models/membership_plan.dart';
import '../models/subscription_status.dart';
import '../repositories/membership_repo.dart';
import '../services/subscription_sync_service.dart';
import 'auth_state.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MembershipState {
  MembershipState._();

  static final MembershipState instance = MembershipState._();
  static const String _localModeEnabledKey = 'local_mode_enabled';

  /// Developer override: build with `--dart-define=FULL_ACCESS=true` to unlock
  /// the annual plan for any signed-in user. Off in normal builds.
  static const bool _fullAccessOverride = bool.fromEnvironment('FULL_ACCESS');

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
    await _loadPersistedLocalMode();
    if (!AuthState.instance.isFirebaseAvailable) {
      enableDemoMode(plan: MembershipPlan.annual);
      return;
    }
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
    try {
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
    } catch (e, st) {
      // Profile could not be read or written (e.g. Firestore rules deny
      // access). Fall back to the free plan without granting paid access
      // instead of leaving the auth gate spinning forever.
      debugPrint('MembershipState: profile load failed: $e\n$st');
      _setProfile(const MembershipProfile(plan: MembershipPlan.free));
    } finally {
      loading.value = false;
    }
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

  /// Activates the annual plan after a store purchase/restore.
  ///
  /// With a [purchase], the receipt is verified server-side first
  /// (verifyAppleSubscriptionReceipt writes the profile). Only when the
  /// function is not reachable (not deployed / offline) does it fall back to
  /// the local mark; a receipt Apple rejects is not granted.
  Future<void> markAnnualPurchase({PurchaseDetails? purchase}) async {
    if (!_demoMode && purchase != null && AuthState.instance.currentUser.value != null) {
      try {
        final verified = await SubscriptionSyncService.instance.verifyAppleSubscriptionPurchase(purchase);
        _setProfile(verified);
        if (verified.plan != MembershipPlan.annual) {
          throw Exception('Apple aboneliği aktif görünmüyor.');
        }
        return;
      } on FirebaseFunctionsException catch (e) {
        const unreachable = {'not-found', 'unavailable', 'deadline-exceeded'};
        if (!unreachable.contains(e.code)) rethrow;
        debugPrint('MembershipState: receipt check unavailable (${e.code}), using local mark');
      }
    }
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
    _persistLocalMode(enabled: true);
    _setProfile(MembershipProfile(plan: plan));
    loading.value = false;
  }

  void disableDemoMode() {
    _demoMode = false;
    _persistLocalMode(enabled: false);
    if (AuthState.instance.currentUser.value == null) {
      _setProfile(null);
      loading.value = false;
    }
  }

  void _onUserChanged() {
    if (AuthState.instance.currentUser.value != null && _demoMode) {
      _demoMode = false;
      _persistLocalMode(enabled: false);
    }
    _reloadForCurrentUser();
  }

  bool get isAnnual => currentPlan.value == MembershipPlan.annual;
  bool get isFull => isAnnual;
  bool get isFree => currentPlan.value == MembershipPlan.free;
  bool get isDemoMode => _demoMode;

  void _setProfile(MembershipProfile? profile) {
    if (_fullAccessOverride && profile != null) {
      profile = const MembershipProfile(plan: MembershipPlan.annual);
    }
    currentProfile.value = profile;
    currentPlan.value = profile?.plan;
  }

  Future<void> _loadPersistedLocalMode() async {
    final prefs = await SharedPreferences.getInstance();
    _demoMode = prefs.getBool(_localModeEnabledKey) ?? false;
    // Restored demo mode carries the same plan enableDemoMode() grants.
    if (_demoMode) _setProfile(const MembershipProfile(plan: MembershipPlan.annual));
  }

  Future<void> _persistLocalMode({required bool enabled}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_localModeEnabledKey, enabled);
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
