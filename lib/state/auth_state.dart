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

  final ValueNotifier<AppUser?> currentUser = ValueNotifier<AppUser?>(null);

  FirebaseAuth? _auth;
  StreamSubscription<User?>? _authSub;
  bool _initialized = false;
  bool _firebaseAvailable = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      _auth = FirebaseAuth.instance;
      _firebaseAvailable = true;
    } catch (_) {
      _firebaseAvailable = false;
      currentUser.value = null;
      return;
    }

    final auth = _auth!;
    _authSub = auth.authStateChanges().listen((user) {
      currentUser.value = _fromFirebaseUser(user);
    });
    currentUser.value = _fromFirebaseUser(auth.currentUser);
  }

  Future<AppUser?> signIn() async {
    return signInWithGoogle();
  }

  Future<AppUser?> signInWithGoogle() async {
    await initialize();
    if (!_firebaseAvailable || _auth == null) {
      throw Exception('Bulut girisi bu masaustu yapida henuz ayarli degil.');
    }
    final result = await _auth!.signInWithProvider(GoogleAuthProvider());
    final user = _fromFirebaseUser(result.user);
    currentUser.value = user;
    return user;
  }

  Future<AppUser?> signInWithApple() async {
    await initialize();
    if (!_firebaseAvailable || _auth == null) {
      throw Exception('Bulut girisi bu masaustu yapida henuz ayarli degil.');
    }

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

    final result = await _auth!.signInWithCredential(oauthCredential);
    final user = _fromFirebaseUser(result.user);
    currentUser.value = user;
    return user;
  }

  Future<void> signOut() async {
    final auth = _auth;
    if (auth == null) {
      currentUser.value = null;
      return;
    }
    await auth.signOut();
    currentUser.value = null;
  }

  /// Step 1 of account deletion: signs the user in again (Firebase only
  /// deletes accounts with a recent sign-in) and, for Sign in with Apple,
  /// revokes the Apple token as App Store guideline 5.1.1(v) requires.
  /// Throws if the user cancels; nothing is deleted at that point.
  Future<String> reauthenticateForDeletion() async {
    final auth = _auth;
    final user = auth?.currentUser;
    if (auth == null || user == null) throw Exception('Oturum açık değil.');
    final isApple = user.providerData.any((p) => p.providerId == 'apple.com');
    if (isApple) {
      final rawNonce = _generateNonce();
      final apple = await SignInWithApple.getAppleIDCredential(
        scopes: const [],
        nonce: _sha256OfString(rawNonce),
      );
      final idToken = apple.identityToken;
      if (idToken == null || idToken.isEmpty) throw Exception('Apple identity token alınamadı.');
      await user.reauthenticateWithCredential(OAuthProvider('apple.com').credential(
        idToken: idToken,
        accessToken: apple.authorizationCode,
        rawNonce: rawNonce,
      ));
      await auth.revokeTokenWithAuthorizationCode(apple.authorizationCode);
    } else {
      await user.reauthenticateWithProvider(GoogleAuthProvider());
    }
    return user.uid;
  }

  /// Step 2 of account deletion: removes the Firebase Auth account. Call
  /// after the user's cloud and local data have been deleted.
  Future<void> deleteFirebaseAccount() async {
    final user = _auth?.currentUser;
    if (user != null) await user.delete();
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

  bool get isFirebaseAvailable => _firebaseAvailable;

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
