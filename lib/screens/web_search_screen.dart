import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../widgets/import_modal.dart';

class WebSearchScreen extends StatefulWidget {
  final int setlistId;
  final VoidCallback? onImported;
  final VoidCallback? onGoHome;

  const WebSearchScreen({
    super.key,
    required this.setlistId,
    this.onImported,
    this.onGoHome,
  });

  @override
  State<WebSearchScreen> createState() => WebSearchScreenState();
}

/// ✅ GlobalKey ile erişeceğimiz State
class WebSearchScreenState extends State<WebSearchScreen> {
  WebViewController? controller;
  final queryController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  static const List<String> _frequentSearches = [
    'Haluk Levent - Elfida',
    'Ufuk Beydemir - Ay Tenli Kadın',
    'Duman - Bekle Dedi Gitti',
    'MFÖ - Ah Bu Ben',
    "Teoman - İstanbul'da Sonbahar",
    'Onur Can Özcan - Yaramızda Kalsın',
    'Leyla The Band - Yokluğunda',
    'Duman - Her Şeyi Yak',
    'Haluk Levent - Anlasana',
    'Ogün Sanlısoy - Saydım',
    'Manga - Cevapsız Sorular',
    'Seksendört - Ölürüm Hasretinle',
    'Ahmet Kaya - Kendine İyi Bak',
    'Dolu Kadehi Ters Tut - Yapma Nolursun',
    'Kargo - Yıldızların Altında',
    'Cem Karaca - Deniz Üstü Köpürür',
    'Pinhani - Beni Sen İnandır',
    'Barış Manço - Gülpembe',
    'Emir Can İğrek - Nalan',
    'Badem - Sen Ağlama',
    'Tuğkan - Kusura Bakma',
    'Mor Ve Ötesi - Bir Derdim Var',
    'Duman - Aman Aman',
    'Yüzyüzeyken Konuşuruz - Dinle Beni Bi',
    'Yüksek Sadakat - Belki Üstümüzden Bir Kuş Geçer',
    'Onur Can Özcan - İntihaşk',
    'Pinhani - Dön Bak Dünyaya',
    'Teoman - Kupa Kizi Sinek Valesi',
    'Madrigal - Seni Dert Etmeler',
    'Pinhani - Dünyadan Uzak',
    'Şebnem Ferah - Sil Baştan',
    'Seksendört - Kendime Yalan Söyledim',
    'Yaşar - Kumralım',
    'Adamlar - Koca Yaşlı Şişko Dünya',
    'Kenan Doğulu - Tutamıyorum Zamanı',
    'Ahmet Kaya - Kum Gibi',
    'Fikret Kızılok - Bu Kalp Seni Unutur Mu',
    'Barış Manço - Gesi Bağları',
    'Yüksek Sadakat - Gel İçelim',
    'Halil Sezai - Isyan',
    'Oğuzhan Koç - Gül ki Sevgilim',
    'Pinhani - Ne Güzel Güldün',
    'Onur Can Özcan - Hırka',
    'Can Ozan - Sar Bu Şehri',
    'Teoman - Paramparça',
    'Barış Akarsu - Islak Islak',
    'Haluk Levent - Yollarda Bulurum Seni',
    'İlyas Yalçıntaş - İçimdeki Duman',
  ];

  String currentUrl = "about:blank";
  String currentTitle = "";
  bool webViewReady = false;
  bool _hasSearched = false;

  int get selectedSetlistId => widget.setlistId;

  Future<void> dismissKeyboard() async {
    final c = controller;
    if (c != null) {
      try {
        await c.runJavaScript(
          "if (document.activeElement) { document.activeElement.blur(); }",
        );
      } catch (_) {}
    }
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  @override
  void dispose() {
    queryController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _search({String? query, bool appendAkor = false}) async {
    final c = controller;
    if (c == null) return;
    final base = (query ?? queryController.text).trim();
    if (base.isEmpty) return;
    final lower = base.toLowerCase();
    final q = (appendAkor && !lower.contains('akor')) ? '$base akor' : base;
    final url = "https://www.google.com/search?q=${Uri.encodeComponent(q)}";
    setState(() => _hasSearched = true);
    await c.loadRequest(Uri.parse(url));
  }

  Future<void> _openFrequentSearch(String text) async {
    queryController.text = text;
    await _search(query: text, appendAkor: true);
  }

  void showFrequentSearches() {
    if (!mounted) return;
    setState(() {
      _hasSearched = false;
    });
  }

  Future<void> _import() async {
    final c = controller;
    if (c == null) return;
    final url = currentUrl;
    if (!url.startsWith("http")) return;

    final rawHtml = _isAkormatikSongPage(url)
        ? await _extractAkormatikRawText(c)
        : await _extractGenericRawText(c);

    if (rawHtml.trim().isEmpty) return;

    if (!mounted) return;

    final changed = await showImportModal(
      context: context,
      pageTitle: currentTitle.isNotEmpty ? currentTitle : url,
      pageUrl: url,
      rawHtml: rawHtml,
      setlistId: selectedSetlistId,
    );

    if (changed == true) {
      widget.onImported?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Şarkı eklendi.")),
      );
    }
  }

  Future<String> _extractGenericRawText(WebViewController controller) async {
    final rawHtmlObj = await controller.runJavaScriptReturningResult(r"""
(() => {
  const selectors = [
    '#chords', '.chords', '.chord-area', '.akor', '.akorlar',
    '.song-chords', 'pre', 'article', 'main'
  ];

  const REMOVE = [
    'script', 'style', 'iframe', 'video',
    'header', 'nav', 'footer',
    'button', 'svg'
  ];

  function clean(node) {
    REMOVE.forEach(sel => {
      node.querySelectorAll(sel).forEach(x => x.remove());
    });
  }

  function normalizeChords(root) {
    const chordToken = /^(A|B|C|D|E|F|G)(#|b)?(m|m7|7)?$/;

    root.querySelectorAll('p, div, span, pre').forEach(el => {
      const parts = el.innerHTML.split(/(\s+)/);
      let changed = false;

      const out = parts.map(p => {
        const t = p.trim();

        // F #  → F#
        if (t.length === 1 && /[A-G]/.test(t)) {
          return p;
        }

        if (chordToken.test(t)) {
          changed = true;
          return `<span data-chord="1">${t}</span>`;
        }

        return p;
      });

      if (changed) {
        el.innerHTML = out.join('');
      }
    });
  }

  for (const sel of selectors) {
    const el = document.querySelector(sel);
    if (el && el.innerText && el.innerText.trim().length > 80) {
      const clone = el.cloneNode(true);
      clean(clone);
      normalizeChords(clone);
      return clone.innerText || clone.textContent || '';
    }
  }

  const bodyClone = document.body.cloneNode(true);
  clean(bodyClone);
  normalizeChords(bodyClone);
  return bodyClone.innerText || bodyClone.textContent || '';
})();
""");

    return _normalizeJsResult(rawHtmlObj);
  }

  Future<String> _extractAkormatikRawText(WebViewController controller) async {
    final rawHtmlObj = await controller.runJavaScriptReturningResult(r"""
(() => {
  function textOf(node) {
    if (!node) return '';
    return (node.innerText || node.textContent || '').trim();
  }

  const candidates = [
    'main',
    'article',
    '[role="main"]',
    '.page',
    '.content',
    '.container',
    '.song',
    '.song-page',
    '.song-detail',
    '.chords',
    '.akor',
    '.akorlar',
    '#song',
    '#content',
  ];

  let best = '';
  for (const selector of candidates) {
    document.querySelectorAll(selector).forEach((node) => {
      const text = textOf(node);
      if (text.length > best.length && (text.includes('Bölüm') || text.includes('♩='))) {
        best = text;
      }
    });
  }

  if (!best) {
    best = textOf(document.body);
  }

  return best;
})();
""");

    return _normalizeAkormatikRawText(_normalizeJsResult(rawHtmlObj));
  }

  bool _isAkormatikSongPage(String url) {
    final lower = url.toLowerCase();
    return lower.contains('akormatik.com/pages/song/');
  }

  String _normalizeAkormatikRawText(String value) {
    var text = value
        .replaceAll('\r', '')
        .replaceAll('\u00a0', ' ')
        .replaceAllMapped(RegExp(r'[ \t]+\n'), (m) => '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    final lines = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    if (lines.isEmpty) return '';

    var startIndex = lines.indexWhere(
      (line) => line.contains('♩=') || line.startsWith('Bölüm '),
    );
    if (startIndex < 0) {
      startIndex = lines.indexWhere(
        (line) => line.toLowerCase().contains('bölüm'),
      );
    }
    if (startIndex < 0) {
      startIndex = 0;
    }

    var endIndex = lines.length;
    final endMarkers = [
      'Benzer',
      'Diğer Şarkılar',
      'Yorum',
      'Yorumlar',
      'Reklam',
      'Gizlilik',
      'Kullanım Koşulları',
      'Bize Ulaşın',
      'Telif',
    ];
    for (var i = startIndex; i < lines.length; i++) {
      final line = lines[i];
      if (endMarkers.any((marker) => line.contains(marker))) {
        endIndex = i;
        break;
      }
    }

    final normalized = lines.sublist(startIndex, endIndex).join('\n').trim();
    return normalized;
  }

  String _normalizeJsResult(Object value) {
    if (value is String) {
      var v = value;
      if (v.startsWith('"') && v.endsWith('"')) {
        try {
          v = jsonDecode(v) as String;
        } catch (_) {}
      }
      return v;
    }
    return value.toString();
  }

  Future<void> _initWebView() async {
    try {
      final c = WebViewController();
      c
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onUrlChange: (u) =>
                setState(() => currentUrl = u.url ?? currentUrl),
            onPageFinished: (_) async {
              final t = await c.getTitle();
              if (!mounted) return;
              setState(() => currentTitle = t ?? "");
            },
          ),
        )
        ..loadRequest(Uri.parse(currentUrl));

      if (!mounted) return;
      setState(() {
        controller = c;
        webViewReady = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        controller = null;
        webViewReady = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text("Ara (Web)"),
        actions: [
          IconButton(
            tooltip: "Ana Sayfa",
            onPressed: widget.onGoHome,
            icon: const Icon(Icons.home_rounded),
          ),
          IconButton(
            tooltip: "Klavyeyi Gizle",
            onPressed: dismissKeyboard,
            icon: const Icon(Icons.keyboard_hide_outlined),
          ),
          IconButton(
            onPressed: c == null
                ? null
                : () async {
                    await dismissKeyboard();
                    await c.goBack();
                  },
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            onPressed: c == null
                ? null
                : () async {
                    await dismissKeyboard();
                    await c.goForward();
                  },
            icon: const Icon(Icons.arrow_forward),
          ),
          IconButton(
            onPressed: c == null ? null : _import,
            icon: const Icon(Icons.file_download),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    focusNode: _searchFocus,
                    controller: queryController,
                    decoration: const InputDecoration(
                      hintText: "Şarkı/artist ara (örn: Teoman Paramparça)",
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: c == null ? null : _search,
                  child: const Text("Ara"),
                ),
              ],
            ),
          ),
          Expanded(
            child: !_hasSearched
                ? _FrequentSearchList(
                    items: _frequentSearches,
                    onTap: _openFrequentSearch,
                  )
                : webViewReady && c != null
                    ? WebViewWidget(controller: c)
                    : const Center(child: Text("Web görünümü hazır değil")),
          ),
        ],
      ),
    );
  }
}

class _FrequentSearchList extends StatelessWidget {
  final List<String> items;
  final ValueChanged<String> onTap;

  const _FrequentSearchList({
    required this.items,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: items.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, i) {
        if (i == 0) {
          return const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              "Sık Aramalar",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          );
        }
        final text = items[i - 1];
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          child: ListTile(
            leading: const CircleAvatar(
              radius: 14,
              child: Icon(Icons.music_note, size: 16),
            ),
            title: Text(text),
            subtitle: const Text("Tıklayınca Google'da 'akor' ile aranır"),
            trailing: const Icon(Icons.north_east),
            onTap: () => onTap(text),
          ),
        );
      },
    );
  }
}
