import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

enum AuthProvider {
  google,
  apple,
}

class AppUser {
  final String id;
  final String email;
  final String? displayName;
  final String? photoUrl;
  final AuthProvider provider;

  const AppUser({
    required this.id,
    required this.email,
    required this.provider,
    this.displayName,
    this.photoUrl,
  });
}

class AuthState {
  AuthState._();

  static final AuthState instance = AuthState._();

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: const ['email', 'profile'],
  );

  final ValueNotifier<AppUser?> currentUser = ValueNotifier<AppUser?>(null);

  StreamSubscription<GoogleSignInAccount?>? _authSub;
  bool _initialized = false;

  static const String _kProviderKey = 'auth.provider';
  static const String _kAppleUserId = 'auth.apple.user_id';
  static const String _kAppleEmail = 'auth.apple.email';
  static const String _kAppleName = 'auth.apple.name';

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    _authSub = _googleSignIn.onCurrentUserChanged.listen((account) {
      if (account == null) return;
      currentUser.value = _fromGoogle(account);
    });

    final cachedGoogle = _googleSignIn.currentUser;
    if (cachedGoogle != null) {
      currentUser.value = _fromGoogle(cachedGoogle);
    }

    try {
      final silent = await _googleSignIn.signInSilently();
      if (silent != null) {
        currentUser.value = _fromGoogle(silent);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kProviderKey, AuthProvider.google.name);
        return;
      }
    } catch (_) {
      // Session restore best effort.
    }

    await _restoreAppleSessionFromCache();
  }

  Future<AppUser?> signIn() async {
    return signInWithGoogle();
  }

  Future<AppUser?> signInWithGoogle() async {
    await initialize();
    final account = await _googleSignIn.signIn();
    if (account != null) {
      final user = _fromGoogle(account);
      currentUser.value = user;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kProviderKey, AuthProvider.google.name);
      return user;
    }
    return null;
  }

  Future<AppUser?> signInWithApple() async {
    await initialize();

    final available = await SignInWithApple.isAvailable();
    if (!available) {
      throw Exception(
          'Sign in with Apple is not available on this device. Please use Google Sign-In.');
    }

    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: const [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );
    final userId = credential.userIdentifier;
    if (userId == null || userId.isEmpty) {
      throw Exception('Apple user identifier could not be retrieved.');
    }

    final prefs = await SharedPreferences.getInstance();
    final fallbackEmail = 'apple_$userId@privaterelay.local';
    final email =
        credential.email ?? prefs.getString(_kAppleEmail) ?? fallbackEmail;

    final given = credential.givenName?.trim() ?? '';
    final family = credential.familyName?.trim() ?? '';
    final fullName = '$given $family'.trim();
    final displayName = fullName.isNotEmpty
        ? fullName
        : (prefs.getString(_kAppleName) ?? 'Apple Kullanıcısı');

    await prefs.setString(_kProviderKey, AuthProvider.apple.name);
    await prefs.setString(_kAppleUserId, userId);
    await prefs.setString(_kAppleEmail, email);
    await prefs.setString(_kAppleName, displayName);

    final user = AppUser(
      id: userId,
      email: email,
      displayName: displayName,
      provider: AuthProvider.apple,
    );
    currentUser.value = user;
    return user;
  }

  Future<void> signOut() async {
    final provider = currentUser.value?.provider;
    try {
      if (provider == AuthProvider.google) {
        await _googleSignIn.signOut();
      }
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kProviderKey);
    currentUser.value = null;
  }

  Future<void> _restoreAppleSessionFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final provider = prefs.getString(_kProviderKey);
    if (provider != AuthProvider.apple.name) return;

    final id = prefs.getString(_kAppleUserId);
    final email = prefs.getString(_kAppleEmail);
    if (id == null || email == null || email.isEmpty) return;

    currentUser.value = AppUser(
      id: id,
      email: email,
      displayName: prefs.getString(_kAppleName) ?? 'Apple Kullanıcısı',
      provider: AuthProvider.apple,
    );
  }

  AppUser _fromGoogle(GoogleSignInAccount account) {
    return AppUser(
      id: account.id,
      email: account.email,
      displayName: account.displayName,
      photoUrl: account.photoUrl,
      provider: AuthProvider.google,
    );
  }

  Future<void> dispose() async {
    await _authSub?.cancel();
    currentUser.dispose();
  }
}
