import 'package:flutter/material.dart';

import '../state/auth_state.dart';

enum GoogleAuthMode {
  card,
  listTile,
  banner,
}

class GoogleAuthWidget extends StatefulWidget {
  final GoogleAuthMode mode;
  final bool isDark;
  final Color? cardBg;
  final Color? borderColor;
  final Color? titleColor;
  final Color? subtitleColor;
  final ValueChanged<String>? onMessage;

  const GoogleAuthWidget({
    super.key,
    required this.mode,
    required this.isDark,
    this.cardBg,
    this.borderColor,
    this.titleColor,
    this.subtitleColor,
    this.onMessage,
  });

  @override
  State<GoogleAuthWidget> createState() => _GoogleAuthWidgetState();
}

class _GoogleAuthWidgetState extends State<GoogleAuthWidget> {
  bool _busy = false;

  void _emitMessage(String message) {
    final cb = widget.onMessage;
    if (cb != null) {
      cb(message);
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _signInGoogle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final user = await AuthState.instance.signInWithGoogle();
      if (!mounted) return;
      if (user == null) {
        _emitMessage('Google girişi iptal edildi.');
      } else {
        _emitMessage('Giriş yapıldı: ${user.email}');
      }
    } catch (e) {
      if (!mounted) return;
      _emitMessage('Google girişi başarısız: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInApple() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final user = await AuthState.instance.signInWithApple();
      if (!mounted) return;
      if (user == null) {
        _emitMessage('Apple girişi iptal edildi.');
      } else {
        _emitMessage('Giriş yapıldı: ${user.email}');
      }
    } catch (e) {
      if (!mounted) return;
      _emitMessage('Apple girişi başarısız: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    if (_busy) return;
    setState(() => _busy = true);
    await AuthState.instance.signOut();
    if (!mounted) return;
    setState(() => _busy = false);
    _emitMessage('Hesaptan çıkış yapıldı.');
  }

  Widget _avatar({
    required AppUser? user,
    required bool signedIn,
    required bool isDark,
    double radius = 18,
  }) {
    return CircleAvatar(
      radius: radius,
      backgroundColor:
          isDark ? const Color(0xFF303030) : const Color(0xFFE5E7EB),
      backgroundImage:
          signedIn && user?.photoUrl != null && user!.photoUrl!.isNotEmpty
              ? NetworkImage(user.photoUrl!)
              : null,
      child: !signedIn || user?.photoUrl == null || user!.photoUrl!.isEmpty
          ? Icon(
              Icons.person,
              color: isDark ? Colors.white70 : const Color(0xFF4B5563),
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final cardBg =
        widget.cardBg ?? (isDark ? const Color(0xFF1E1E1E) : Colors.white);
    final borderColor = widget.borderColor ??
        (isDark ? const Color(0xFF2D2D2D) : const Color(0xFFD8DDE6));
    final titleColor =
        widget.titleColor ?? (isDark ? Colors.white : const Color(0xFF111827));
    final subtitleColor = widget.subtitleColor ??
        (isDark ? const Color(0xFFE1D0A2) : const Color(0xFF6B7280));

    return ValueListenableBuilder<AppUser?>(
      valueListenable: AuthState.instance.currentUser,
      builder: (_, user, __) {
        final signedIn = user != null;
        final name = signedIn
            ? (user.displayName ??
                (user.provider == AuthProvider.apple
                    ? 'Apple Kullanıcısı'
                    : 'Google Kullanıcısı'))
            : 'Giriş yapılmadı';
        final subtitle =
            signedIn ? user.email : 'Google veya Apple ile üye ol / giriş yap';

        if (widget.mode == GoogleAuthMode.listTile) {
          return ListTile(
            leading: Icon(signedIn ? Icons.verified_user : Icons.login),
            title: Text(signedIn ? 'Hesap bağlı' : 'Üye girişi'),
            subtitle: Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: subtitleColor),
            ),
            trailing: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _busy ? null : (signedIn ? _signOut : _signInGoogle),
          );
        }

        if (widget.mode == GoogleAuthMode.banner) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                _avatar(
                    user: user, signedIn: signedIn, isDark: isDark, radius: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: titleColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: subtitleColor, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (signedIn)
                  FilledButton(
                    onPressed: _busy ? null : _signOut,
                    child: Text(_busy ? '...' : 'Çıkış'),
                  )
                else
                  FilledButton(
                    onPressed: _busy ? null : _signInApple,
                    child: const Text('Apple'),
                  ),
              ],
            ),
          );
        }

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Hesap',
                style: TextStyle(
                  color: titleColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _avatar(user: user, signedIn: signedIn, isDark: isDark),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            color: titleColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: TextStyle(color: subtitleColor, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (signedIn)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _signOut,
                    icon: const Icon(Icons.logout),
                    label: Text(_busy ? 'İşleniyor...' : 'Hesaptan Çıkış Yap'),
                  ),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _signInGoogle,
                        icon: const Icon(Icons.login),
                        label: const Text('Google'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _signInApple,
                        icon: const Icon(Icons.apple),
                        label: const Text('Apple'),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}
