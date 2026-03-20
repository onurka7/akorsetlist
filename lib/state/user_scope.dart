class UserScope {
  static String keyFromEmail(String? email) {
    final normalized = (email ?? '').trim().toLowerCase();
    if (normalized.isEmpty) return 'guest';

    final b = StringBuffer();
    for (final r in normalized.runes) {
      final c = String.fromCharCode(r);
      final isLetter = (r >= 97 && r <= 122);
      final isDigit = (r >= 48 && r <= 57);
      if (isLetter || isDigit) {
        b.write(c);
      } else {
        b.write('_');
      }
    }

    final out = b.toString().replaceAll(RegExp(r'_+'), '_');
    return out.isEmpty ? 'guest' : out;
  }
}
