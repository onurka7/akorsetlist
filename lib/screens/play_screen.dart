import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter/services.dart';

import '../models/song.dart';
import '../repositories/setlist_repo.dart';
import '../repositories/song_repo.dart';

class PlayScreen extends StatefulWidget {
  final int setlistId;
  final int initialIndex;

  const PlayScreen({
    super.key,
    required this.setlistId,
    required this.initialIndex,
  });

  @override
  State<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends State<PlayScreen> {
  final setlistRepo = SetlistRepo();
  final songRepo = SongRepo();

  late final WebViewController controller;

  List<Song> songs = [];
  int idx = 0;

  double fontScale = 1.0; // 1.0 normal
  bool darkMode = false; // gece modu
  bool stageMode = false; // 🎤 sahne modu
  bool touchLocked = false; // 🔒 dokunma kilidi
  int transposeSteps = 0;

  // px/frame (0.10 çok yavaş, 0.18 orta, 0.30 hızlı)
  double stageScrollSpeed = 0.18;

  bool _pageReady = false;
  bool _pendingStageStart = false;

  void _goHome() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  void initState() {
    super.initState();
    idx = widget.initialIndex;

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            _pageReady = true;

            // 1) scroll bridge garanti
            try {
              await _ensureReaderScrollBridge();
            } catch (_) {}

            // 2) tepeye al (offline ise scrollRoot, değilse window)
            try {
              await controller.runJavaScript(
                "if (window.readerScroll && window.readerScroll.toTop) { window.readerScroll.toTop(); } else { window.scrollTo(0,0); }",
              );
            } catch (_) {}

            // 3) görünüm + renkler + chordizer
            try {
              await _applyReaderPrefs();
            } catch (_) {}

            try {
              await _applyTranspose();
            } catch (_) {}

            // 4) sahne modunda pending start
            if (stageMode && _pendingStageStart) {
              _pendingStageStart = false;
              await _stageStartScroll();
            }
          },
        ),
      );
    _loadSongs();
  }

  @override
  void dispose() {
    // dispose içinde await kullanmayalım
    _stageStopScroll();
    _exitStageUIMode();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _bumpScrollSpeed(double delta) async {
    stageScrollSpeed = (stageScrollSpeed + delta).clamp(0.03, 0.60);

    if (stageMode) {
      await _stageStartScroll();
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text("Scroll hız: ${stageScrollSpeed.toStringAsFixed(2)}")),
    );
  }

  String _scrollSpeedLabel() {
    if (stageScrollSpeed <= 0.10) return 'Yavaş';
    if (stageScrollSpeed <= 0.20) return 'Normal';
    if (stageScrollSpeed <= 0.32) return 'Hızlı';
    return 'Çok hızlı';
  }

  Future<void> _setScrollSpeed(double value) async {
    stageScrollSpeed = value.clamp(0.03, 0.60);
    if (stageMode) {
      await _stageStartScroll();
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _showAutoScrollSpeedSheet() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Otomatik Scroll Hızı',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_scrollSpeedLabel()} • ${stageScrollSpeed.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 14),
                Slider(
                  min: 0.03,
                  max: 0.60,
                  value: stageScrollSpeed,
                  onChanged: (value) async {
                    await _setScrollSpeed(value);
                    if (sheetContext.mounted) setSheetState(() {});
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _SpeedPresetChip(
                      label: 'Yavaş',
                      selected: stageScrollSpeed <= 0.10,
                      onTap: () async {
                        await _setScrollSpeed(0.08);
                        if (sheetContext.mounted) setSheetState(() {});
                      },
                    ),
                    _SpeedPresetChip(
                      label: 'Normal',
                      selected:
                          stageScrollSpeed > 0.10 && stageScrollSpeed <= 0.20,
                      onTap: () async {
                        await _setScrollSpeed(0.18);
                        if (sheetContext.mounted) setSheetState(() {});
                      },
                    ),
                    _SpeedPresetChip(
                      label: 'Hızlı',
                      selected:
                          stageScrollSpeed > 0.20 && stageScrollSpeed <= 0.32,
                      onTap: () async {
                        await _setScrollSpeed(0.28);
                        if (sheetContext.mounted) setSheetState(() {});
                      },
                    ),
                    _SpeedPresetChip(
                      label: 'Çok hızlı',
                      selected: stageScrollSpeed > 0.32,
                      onTap: () async {
                        await _setScrollSpeed(0.42);
                        if (sheetContext.mounted) setSheetState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  stageMode
                      ? 'Sahne modu açıkken hız anında uygulanır.'
                      : 'Sahne modunu açtığında bu hız kullanılacak.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadSongs() async {
    final loaded = await setlistRepo.listSongsInSetlist(widget.setlistId);

    if (!mounted) return;
    setState(() {
      songs = loaded;
      if (songs.isEmpty) {
        idx = 0;
      } else {
        if (idx < 0) idx = 0;
        if (idx >= songs.length) idx = songs.length - 1;
      }
    });

    if (songs.isNotEmpty) {
      await _loadSongByIndex(idx);
    }
  }

  Future<void> _loadSongByIndex(int newIndex) async {
    if (songs.isEmpty) return;
    if (newIndex < 0 || newIndex >= songs.length) return;

    if (stageMode) {
      await _stageStopScroll();
    }

    setState(() => idx = newIndex);

    final s = songs[idx];
    if (s.id != null) {
      await songRepo.touchLastOpened(s.id!);
    }

    _pageReady = false;

    final p = s.offlinePath;
    if (p != null && p.isNotEmpty) {
      final f = File(p);
      if (await f.exists()) {
        _pendingStageStart = stageMode;
        await controller.loadFile(p);
        return;
      }
    }

    _pendingStageStart = stageMode;
    await controller.loadRequest(Uri.parse(s.sourceUrl));
  }

  Future<void> _next() async => _loadSongByIndex(idx + 1);
  Future<void> _prev() async => _loadSongByIndex(idx - 1);

  // -------------------------------------------------------
  // ✅ readerScroll bridge: Yoksa enjekte eder (web/offline)
  // -------------------------------------------------------
  Future<void> _ensureReaderScrollBridge() async {
    final js = """
(function(){
  if (window.readerScroll) return;

  var root = document.getElementById('scrollRoot');
  if (!root) root = document.scrollingElement || document.documentElement || document.body;

  var running = false;
  var speed = 0.18;
  var lastTs = 0;

  function tick(ts){
    if (!running) return;
    if (!root) { stop(); return; }

    if (!lastTs) lastTs = ts;
    var dt = (ts - lastTs) / 1000.0;
    lastTs = ts;

    root.scrollTop += speed * (dt * 60.0);

    if (root.scrollTop + root.clientHeight >= root.scrollHeight - 1){
      stop();
      return;
    }
    requestAnimationFrame(tick);
  }

  function start(){
    if (!root) return;
    if (running) return;
    running = true;
    lastTs = 0;
    requestAnimationFrame(tick);
  }

  function stop(){
    running = false;
    lastTs = 0;
  }

  function setSpeed(v){
    var n = Number(v);
    if (!isNaN(n) && isFinite(n)) speed = n;
  }

  function toTop(){
    if (root) root.scrollTop = 0;
  }

  window.readerScroll = { start: start, stop: stop, setSpeed: setSpeed, toTop: toTop };
})();
""";
    await controller.runJavaScript(js);
  }

  // -------------------------------------------------------
  // ✅ Online sayfalarda <pre> içindeki chord-line satırlarını sar
  // (Offline template varsa dokunma: scrollRoot varsa offline say)
  // -------------------------------------------------------
  Future<void> _ensureChordColorizeForWebPages() async {
    final js = """
(function(){
  // Offline template ise zaten chord parser var
  if (document.getElementById('scrollRoot')) return;

  // birden fazla kez çalışmasın
  if (window.__ayseChordizedV2) return;
  window.__ayseChordizedV2 = true;

  // Chord token: match uzunluk kontrolü ile tam eşleşme (regex içinde satır sonu işareti kullanmıyoruz)
  var chordTokenRe = /^[A-G](#|b)?(m|maj|min|dim|aug|sus|add)?\\d?(\\/[A-G](#|b)?)?/;

  function isChordToken(t){
    t = (t || '').trim();
    if (!t) return false;
    var m = t.match(chordTokenRe);
    return m && m[0] && m[0].length === t.length;
  }

  function isChordLine(line){
    var s = (line || '').trim();
    if (!s) return false;
    var toks = s.split(/\\s+/).filter(Boolean);
    if (!toks.length) return false;
    for (var i=0;i<toks.length;i++){
      if (!isChordToken(toks[i])) return false;
    }
    return true;
  }

  function esc(s){
    return (s || '')
      .replace(/&/g,'&amp;')
      .replace(/</g,'&lt;')
      .replace(/>/g,'&gt;');
  }

  function wrapLine(line){
    var parts = line.split(/(\\s+)/); // boşlukları koru
    for (var i=0;i<parts.length;i++){
      var p = parts[i];
      if (!p) { parts[i] = ''; continue; }

      // whitespace aynen kalsın
      if ((p || '').trim().length === 0) {
        parts[i] = p;
        continue;
      }

      if (isChordToken(p)) {
        parts[i] = '<span class="ay-chord">' + esc(p) + '</span>';
      } else {
        parts[i] = esc(p);
      }
    }
    return parts.join('');
  }

  // En güvenlisi: <pre> üzerinde satır satır çalış
  var pres = document.querySelectorAll('pre');
  for (var pi=0; pi<pres.length; pi++){
    var pre = pres[pi];
    if (!pre) continue;

    // zaten chord markup varsa dokunma
    if (pre.querySelector && (pre.querySelector('.ay-chord') || pre.querySelector('.chord') || pre.querySelector('[data-chord]'))) {
      continue;
    }

    var text = pre.textContent || '';
    if (!text || text.length < 3) continue;

    var lines = text.split('\\n');
    var out = [];

    var any = false;
    for (var li=0; li<lines.length; li++){
      var line = lines[li] || '';
      if (isChordLine(line)) {
        out.push(wrapLine(line));
        any = true;
      } else {
        out.push(esc(line));
      }
    }

    if (any) {
      pre.innerHTML = out.join('\\n');
      pre.setAttribute('data-ay-chordized','1');
    }
  }
})();
""";

    await controller.runJavaScript(js);
  }

  // ---------------------------
  // 🎤 Stage scroll helpers
  // ---------------------------
  Future<void> _stageStartScroll() async {
    if (!_pageReady) {
      _pendingStageStart = true;
      return;
    }

    try {
      await _ensureReaderScrollBridge();
    } catch (_) {}

    try {
      await controller.runJavaScript(
        "if (window.readerScroll && window.readerScroll.setSpeed) window.readerScroll.setSpeed(${stageScrollSpeed.toStringAsFixed(3)});",
      );
    } catch (_) {}

    try {
      await controller.runJavaScript(
        "if (window.readerScroll && window.readerScroll.start) window.readerScroll.start();",
      );
    } catch (_) {}
  }

  Future<void> _stageStopScroll() async {
    _pendingStageStart = false;
    try {
      await controller.runJavaScript(
        "if (window.readerScroll && window.readerScroll.stop) window.readerScroll.stop();",
      );
    } catch (_) {}
  }

  // ---------------------------
  // 🎤 Stage UI
  // ---------------------------
  Future<void> _enterStageUIMode() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _exitStageUIMode() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  Future<void> _enterStageMode() async {
    stageMode = true;
    _pendingStageStart = true;

    await WakelockPlus.enable();
    await _enterStageUIMode();

    if (!mounted) return;
    setState(() {});

    await _applyReaderPrefs();
    await _stageStartScroll();
  }

  Future<void> _exitStageMode() async {
    stageMode = false;
    touchLocked = false;

    await _stageStopScroll();
    await _exitStageUIMode();
    await WakelockPlus.disable();

    if (!mounted) return;
    setState(() {});

    await _applyReaderPrefs();
  }

  // ✅ CSS/prefs + renkler
  Future<void> _applyReaderPrefs() async {
    final bg = darkMode ? "#0b0b0b" : "#ffffff";
    final fg = darkMode ? "#f5f5f5" : "#111111";
    final linkColor = darkMode ? "#8ab4f8" : "#1a73e8";

    final fontPx = (18 * fontScale).clamp(14, 34).toStringAsFixed(1);
    final linePx = (26 * fontScale).clamp(20, 44).toStringAsFixed(1);

    // 🎸 chord rengi
    final chordColor = darkMode ? "#ff6b6b" : "#b00020";

    final stageExtra = stageMode
        ? """
#scrollRoot{ padding-top:24px !important; }
#song .chord, #song .ay-chord, #song [data-chord],
.chord, .ay-chord, [data-chord]{
  font-size:1.25em !important;
}
"""
        : "";

    final css = """
html,body{
  background:$bg !important;
  color:$fg !important;
  overflow-x:hidden !important;
  -webkit-text-size-adjust:100% !important;
}
body{
  margin:0 !important;
  font-family:-apple-system,system-ui,Arial !important;
  font-size:${fontPx}px !important;
  line-height:${linePx}px !important;
}
a{ color:$linkColor !important; }

/* Offline container: taşmayı engelle */
#scrollRoot{
  width:100% !important;
  max-width:100% !important;
  overflow-x:hidden !important;
  box-sizing:border-box !important;
}
#song, #song pre, pre{
  white-space: pre-wrap !important;
  word-break: break-word !important;
  overflow-wrap: anywhere !important;
  font-size:${fontPx}px !important;
  line-height:${linePx}px !important;
}

/* ✅ Metin rengi: sadece container'a ver, child'lar inherit etsin */
#scrollRoot, #song{ color:$fg !important; }
#song *{ color: inherit !important; }

/* ✅ Akorlar: daha spesifik yazarak kesin boyat */
#song .chord, #song .ay-chord, #song [data-chord],
.chord, .ay-chord, [data-chord]{
  color:$chordColor !important;
  font-weight:900 !important;
}

$stageExtra
""";

    final js = """
(() => {
  const css = ${jsonEncode(css)};
  let style = document.getElementById('ayse-reader-style');
  if (!style) {
    style = document.createElement('style');
    style.id = 'ayse-reader-style';
    document.head.appendChild(style);
  }
  style.textContent = css;
})();
""";

    await controller.runJavaScript(js);

    // ✅ online sayfalarda chord span üret (offline’a dokunmaz)
    try {
      await _ensureChordColorizeForWebPages();
    } catch (_) {}

    if (stageMode) {
      await _stageStopScroll();
      await _stageStartScroll();
    }
  }

  Future<void> _applyTranspose() async {
    final js = """
(() => {
  const notes = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B'];
  const flatToSharp = {
    'Db': 'C#',
    'Eb': 'D#',
    'Gb': 'F#',
    'Ab': 'G#',
    'Bb': 'A#',
  };

  function normalizeRoot(root) {
    return flatToSharp[root] || root;
  }

  function transposeRoot(root, steps) {
    const normalized = normalizeRoot(root);
    const idx = notes.indexOf(normalized);
    if (idx < 0) return root;
    let next = (idx + steps) % notes.length;
    if (next < 0) next += notes.length;
    return notes[next];
  }

  function transposeChord(chord, steps) {
    const match = String(chord || '').match(/^([A-G](?:#|b)?)(.*?)(?:\\/([A-G](?:#|b)?))?\$/);
    if (!match) return chord;
    const root = transposeRoot(match[1], steps);
    const suffix = match[2] || '';
    const bass = match[3] ? '/' + transposeRoot(match[3], steps) : '';
    return root + suffix + bass;
  }

  const nodes = document.querySelectorAll('#song .chord, #song .ay-chord, #song [data-chord], .chord, .ay-chord, [data-chord]');
  for (const node of nodes) {
    const original = node.dataset.originalChord || (node.textContent || '').trim();
    node.dataset.originalChord = original;
    node.textContent = transposeChord(original, $transposeSteps);
  }
})();
""";
    await controller.runJavaScript(js);
  }

  Future<void> _changeTranspose(int delta) async {
    setState(() {
      transposeSteps = (transposeSteps + delta).clamp(-11, 11);
    });
    await _applyTranspose();
  }

  Future<void> _resetTranspose() async {
    setState(() => transposeSteps = 0);
    await _applyTranspose();
  }

  Future<void> _showTransposeSheet() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Transpoze: ${transposeSteps > 0 ? '+$transposeSteps' : transposeSteps}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await _changeTranspose(-1);
                          if (sheetContext.mounted) {
                            setSheetState(() {});
                          }
                        },
                        icon: const Icon(Icons.remove),
                        label: const Text('Yarım ses düşür'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: transposeSteps == 0
                            ? null
                            : () async {
                                await _resetTranspose();
                                if (sheetContext.mounted) {
                                  setSheetState(() {});
                                }
                              },
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('Sıfırla'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      await _changeTranspose(1);
                      if (sheetContext.mounted) {
                        setSheetState(() {});
                      }
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Yarım ses yükselt'),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: const Text('Kapat'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  ({String songName, String artistName}) _parsedSongTitle() {
    if (songs.isEmpty) {
      return (songName: 'Çalma Modu', artistName: 'Notalar');
    }
    final raw = songs[idx].title.trim();
    final parts = raw.split(' - ');
    if (parts.length >= 2) {
      final artist = parts.first.trim();
      final song = parts.sublist(1).join(' - ').trim();
      if (song.isNotEmpty && artist.isNotEmpty) {
        return (
          songName: song,
          artistName: '$artist • Notalar',
        );
      }
    }
    return (songName: raw, artistName: 'Notalar');
  }

  List<Widget> _buildTopBarActions() {
    final actions = <Widget>[
      IconButton(
        tooltip: "Ana sayfa",
        icon: const Icon(Icons.home_rounded),
        onPressed: _goHome,
      ),
    ];

    if (stageMode) {
      actions.addAll([
        IconButton(
          tooltip: touchLocked ? "Dokunmayı Aç" : "Dokunmayı Kilitle",
          icon: Icon(touchLocked ? Icons.lock : Icons.lock_open),
          onPressed: () => setState(() => touchLocked = !touchLocked),
        ),
        IconButton(
          tooltip: "Scroll Hızı",
          icon: const Icon(Icons.speed_rounded),
          onPressed: _showAutoScrollSpeedSheet,
        ),
        IconButton(
          tooltip: "Yavaşlat",
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => _bumpScrollSpeed(-0.03),
        ),
        IconButton(
          tooltip: "Hızlandır",
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: () => _bumpScrollSpeed(0.03),
        ),
      ]);
    } else {
      actions.addAll([
        IconButton(
          tooltip: "Font -",
          icon: const Icon(Icons.text_decrease),
          onPressed: () async {
            setState(() => fontScale = (fontScale - 0.1).clamp(0.7, 2.0));
            await _applyReaderPrefs();
          },
        ),
        IconButton(
          tooltip: "Font +",
          icon: const Icon(Icons.text_increase),
          onPressed: () async {
            setState(() => fontScale = (fontScale + 0.1).clamp(0.7, 2.0));
            await _applyReaderPrefs();
          },
        ),
        IconButton(
          tooltip: darkMode ? "Açık Mod" : "Gece Modu",
          icon: Icon(darkMode ? Icons.dark_mode : Icons.light_mode),
          onPressed: () async {
            setState(() => darkMode = !darkMode);
            await _applyReaderPrefs();
            await _applyTranspose();
          },
        ),
        IconButton(
          tooltip: "Transpoze",
          icon: const Icon(Icons.swap_vert_rounded),
          onPressed: _showTransposeSheet,
        ),
        IconButton(
          tooltip: "Scroll Hızı",
          icon: const Icon(Icons.speed_rounded),
          onPressed: _showAutoScrollSpeedSheet,
        ),
      ]);
    }

    actions.add(
      IconButton(
        tooltip: stageMode ? "Sahne Modundan Çık" : "Sahne Modu",
        icon: Icon(stageMode ? Icons.close_fullscreen : Icons.fullscreen),
        onPressed: () async {
          if (stageMode) {
            await _exitStageMode();
          } else {
            await _enterStageMode();
          }
        },
      ),
    );

    return actions;
  }

  @override
  Widget build(BuildContext context) {
    final parsedTitle = _parsedSongTitle();
    final actions = _buildTopBarActions();
    final headerText = parsedTitle.artistName == 'Notalar'
        ? parsedTitle.songName
        : '${parsedTitle.artistName.replaceFirst(' • Notalar', '')} - ${parsedTitle.songName}';
    final headerBg = stageMode
        ? Colors.black
        : Theme.of(context).appBarTheme.backgroundColor ??
            Theme.of(context).colorScheme.surface;
    final headerFg = stageMode
        ? Colors.white
        : Theme.of(context).appBarTheme.foregroundColor ??
            Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(108),
        child: Material(
          color: headerBg,
          elevation: 2,
          child: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    headerText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: headerFg,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                SizedBox(
                  height: 52,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                    child: IconTheme(
                      data: IconThemeData(color: headerFg),
                      child: Row(children: actions),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              WebViewWidget(controller: controller),

              // ✅ Overlay sadece STAGE MODE’da
              if (stageMode)
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: touchLocked,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapUp: (details) async {
                        final x = details.localPosition.dx;
                        final w = constraints.maxWidth;
                        if (x < w * 0.5) {
                          await _prev();
                        } else {
                          await _next();
                        }
                      },
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SpeedPresetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SpeedPresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: const Color(0xFFFFC83D),
      labelStyle: TextStyle(
        color:
            selected ? Colors.black : Theme.of(context).colorScheme.onSurface,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}
