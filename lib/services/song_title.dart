/// Builds the "Şarkıcı - Şarkı" title used when a web page is imported.
///
/// Page titles carry site and search noise ("… - Google'da Ara",
/// "… Akor ve Sözleri | Akormatik"); only the artist and song name are kept.
String songTitleFrom({String? artist, String? song, String? pageTitle}) {
  final a = _tidy(artist ?? '');
  final s = _tidy(song ?? '');
  if (s.isNotEmpty) return a.isEmpty ? s : '$a - $s';
  return cleanPageTitle(pageTitle ?? '');
}

final List<RegExp> _noise = [
  // Search engines.
  RegExp(r"\s*[-–|]\s*Google(?:'da|’da)?\s*Ara\s*$", caseSensitive: false),
  RegExp(r'\s*[-–|]\s*Google\s*(?:Search|Arama)?\s*$', caseSensitive: false),
  RegExp(r'\s*[-–|]\s*(?:Yandex|Bing|DuckDuckGo)[^|–-]*$', caseSensitive: false),
  // Site suffixes such as "| Akormatik", "- Akorlar.com".
  // ("–" is not a site separator: it often splits artist and song.)
  RegExp(r'\s*\|\s*[^|]+$'),
  RegExp(r'\s+-\s+[\w.]+\.(?:com|net|org|tr)(?:\.tr)?\s*$', caseSensitive: false),
  // Chord-sheet wording.
  // (No trailing \b: Dart's \b is ASCII-only and fails after "ı".)
  RegExp(r'\s*\b(?:gitar\s+)?akor.*$', caseSensitive: false),
  RegExp(r'\s*\bs[öo]zler.*$', caseSensitive: false),
  RegExp(r'\s*\b(?:chords?|tabs?|lyrics)\b.*$', caseSensitive: false),
];

String cleanPageTitle(String raw) {
  var t = _tidy(raw);
  if (t.isEmpty || t.startsWith('http')) return t;
  for (var pass = 0; pass < 2; pass++) {
    for (final re in _noise) {
      final next = _tidy(t.replaceFirst(re, ''));
      if (next.isNotEmpty) t = next;
    }
  }
  // "Elfida (Haluk Levent)" -> "Haluk Levent - Elfida".
  final paren = RegExp(r'^(.+?)\s*\(([^()]+)\)$').firstMatch(t);
  if (paren != null && !t.contains(' - ')) t = '${_tidy(paren.group(2)!)} - ${_tidy(paren.group(1)!)}';
  return t.replaceAll(RegExp(r'\s+[-–]\s+|\s*–\s*'), ' - ').replaceAll(RegExp(r'^[-\s]+|[-\s]+$'), '');
}

String _tidy(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
