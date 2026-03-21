import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
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

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ValueNotifier<AppUser?> currentUser = ValueNotifier<AppUser?>(null);

  StreamSubscription<User?>? _authSub;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    _authSub = _auth.authStateChanges().listen((user) {
      currentUser.value = _fromFirebaseUser(user);
    });
    currentUser.value = _fromFirebaseUser(_auth.currentUser);
  }

  Future<AppUser?> signIn() async {
    return signInWithGoogle();
  }

  Future<AppUser?> signInWithGoogle() async {
    await initialize();
    final result = await _auth.signInWithProvider(GoogleAuthProvider());
    final user = _fromFirebaseUser(result.user);
    currentUser.value = user;
    return user;
  }

  Future<AppUser?> signInWithApple() async {
    await initialize();

    final available = await SignInWithApple.isAvailable();
    if (!available) {
      throw Exception(
        'Sign in with Apple bu cihazda kullanilamiyor.',
      );
    }

    final rawNonce = _generateNonce();
    final hashedNonce = _sha256OfString(rawNonce);
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: const [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: hashedNonce,
    );

    final identityToken = credential.identityToken;
    if (identityToken == null || identityToken.isEmpty) {
      throw Exception('Apple identity token alinamadi.');
    }

    final oauthCredential = OAuthProvider('apple.com').credential(
      idToken: identityToken,
      accessToken: credential.authorizationCode,
      rawNonce: rawNonce,
    );

    final result = await _auth.signInWithCredential(oauthCredential);
    final user = _fromFirebaseUser(result.user);
    currentUser.value = user;
    return user;
  }

  Future<void> signOut() async {
    await _auth.signOut();
    currentUser.value = null;
  }

  AppUser? _fromFirebaseUser(User? user) {
    if (user == null) return null;
    final providerId = user.providerData.isNotEmpty
        ? user.providerData.first.providerId
        : 'google.com';
    final provider =
        providerId == 'apple.com' ? AuthProvider.apple : AuthProvider.google;
    return AppUser(
      id: user.uid,
      email: user.email ?? '',
      displayName: user.displayName,
      photoUrl: user.photoURL,
      provider: provider,
    );
  }

  Future<void> dispose() async {
    await _authSub?.cancel();
    currentUser.dispose();
  }

  String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List<String>.generate(
      length,
      (_) => charset[random.nextInt(charset.length)],
    ).join();
  }

  String _sha256OfString(String input) {
    final bytes = utf8.encode(input);
    return sha256.convert(bytes).toString();
  }
}
