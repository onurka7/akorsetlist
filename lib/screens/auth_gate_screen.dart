import 'package:flutter/material.dart';

import '../models/membership_plan.dart';
import '../state/auth_state.dart';
import '../state/membership_state.dart';
import 'home_screen.dart';
import 'plan_selection_screen.dart';

class AuthGateScreen extends StatefulWidget {
  final bool isDarkMode;
  final ValueChanged<bool>? onThemeChanged;

  const AuthGateScreen({
    super.key,
    required this.isDarkMode,
    this.onThemeChanged,
  });

  @override
  State<AuthGateScreen> createState() => _AuthGateScreenState();
}

class _AuthGateScreenState extends State<AuthGateScreen> {
  bool _authBusy = false;
  String? _planPromptDismissedForUserId;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: AuthState.instance.currentUser,
      builder: (_, user, __) {
        if (user == null) {
          _planPromptDismissedForUserId = null;
        }

        if (user == null && MembershipState.instance.isDemoMode) {
          return HomeScreen(
            key: const ValueKey('demo-mode'),
            isDarkMode: widget.isDarkMode,
            onThemeChanged: widget.onThemeChanged,
          );
        }

        if (user == null) {
          return _AuthRequiredScreen(
            isDarkMode: widget.isDarkMode,
            busy: _authBusy,
            onGoogleSignIn: _signInWithGoogle,
            onAppleSignIn: _signInWithApple,
            onDemo: _continueWithDemoMode,
          );
        }

        return ValueListenableBuilder<bool>(
          valueListenable: MembershipState.instance.loading,
          builder: (_, loading, __) {
            if (loading) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            final plan = MembershipState.instance.currentPlan.value;
            final shouldShowPlanSelection = plan != MembershipPlan.annual &&
                _planPromptDismissedForUserId != user.id;

            if (shouldShowPlanSelection) {
              return PlanSelectionScreen(
                isDarkMode: widget.isDarkMode,
                allowClose: true,
                onCompleted: () {
                  if (!mounted) return;
                  setState(() {
                    _planPromptDismissedForUserId = user.id;
                  });
                },
                onClosed: () {
                  if (!mounted) return;
                  setState(() {
                    _planPromptDismissedForUserId = user.id;
                  });
                },
              );
            }

            return HomeScreen(
              key: ValueKey(user.email),
              isDarkMode: widget.isDarkMode,
              onThemeChanged: widget.onThemeChanged,
            );
          },
        );
      },
    );
  }

  Future<void> _signInWithGoogle() async {
    if (_authBusy) return;
    setState(() => _authBusy = true);
    try {
      MembershipState.instance.disableDemoMode();
      await AuthState.instance.signInWithGoogle();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Giriş başarısız: $e')),
      );
    } finally {
      if (mounted) setState(() => _authBusy = false);
    }
  }

  Future<void> _signInWithApple() async {
    if (_authBusy) return;
    setState(() => _authBusy = true);
    try {
      MembershipState.instance.disableDemoMode();
      await AuthState.instance.signInWithApple();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Apple ile giriş başarısız: $e')),
      );
    } finally {
      if (mounted) setState(() => _authBusy = false);
    }
  }

  Future<void> _continueWithDemoMode() async {
    if (_authBusy) return;
    MembershipState.instance.enableDemoMode(plan: MembershipPlan.annual);
    if (!mounted) return;
    setState(() {});
  }
}

class _AuthRequiredScreen extends StatelessWidget {
  final bool isDarkMode;
  final bool busy;
  final VoidCallback onGoogleSignIn;
  final VoidCallback onAppleSignIn;
  final VoidCallback onDemo;

  const _AuthRequiredScreen({
    required this.isDarkMode,
    required this.busy,
    required this.onGoogleSignIn,
    required this.onAppleSignIn,
    required this.onDemo,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDarkMode ? const Color(0xFF0F1115) : const Color(0xFFF4F6FA);
    final fg = isDarkMode ? Colors.white : const Color(0xFF111827);

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_person_rounded,
                    size: 56, color: Color(0xFFFFC83D)),
                const SizedBox(height: 14),
                Text(
                  'Üye Girişi Gerekli',
                  style: TextStyle(
                      color: fg, fontSize: 26, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sign in with Apple or Google to sync your setlists and chords.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: fg.withValues(alpha: 0.75)),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: busy ? null : onAppleSignIn,
                    icon: const Icon(Icons.apple, size: 22),
                    label: Text(
                      busy ? 'Connecting...' : 'Sign in with Apple',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: busy ? null : onGoogleSignIn,
                    icon: const Icon(Icons.login, size: 20),
                    label: Text(
                      busy ? 'Bağlanıyor...' : 'Google ile Giriş Yap',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                TextButton(
                  onPressed: busy ? null : onDemo,
                  child: Text(
                    'Kayıt olmadan dene',
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.5),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
