import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter/services.dart';

import '../models/song.dart';
import '../repositories/setlist_repo.dart';
import '../repositories/song_repo.dart';
import '../services/offline_reader_service.dart';
import '../services/user_storage_service.dart';
import '../state/ui_prefs.dart';
import 'chord_analysis_screen.dart';

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
  final _offlineReader = OfflineReaderService();
  final AudioPlayer _audioPlayer = AudioPlayer();

  late final WebViewController controller;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;

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
  bool _audioAvailable = false;
  bool _audioLoading = false;
  Duration _audioPosition = Duration.zero;
  Duration _audioDuration = Duration.zero;

  void _handleChordColorChanged() {
    _applyReaderPrefs();
  }

  void _goHome() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  void initState() {
    super.initState();
    idx = widget.initialIndex;
    UiPrefs.chordColor.addListener(_handleChordColorChanged);
    _playerStateSub = _audioPlayer.playerStateStream.listen((_) {
      if (mounted) setState(() {});
    });
    _positionSub = _audioPlayer.positionStream.listen((position) {
      if (!mounted) return;
      setState(() {
        _audioPosition = position;
      });
    });
    _durationSub = _audioPlayer.durationStream.listen((duration) {
      if (!mounted) return;
      setState(() {
        _audioDuration = duration ?? Duration.zero;
      });
    });

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
    UiPrefs.chordColor.removeListener(_handleChordColorChanged);
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stageStopScroll();
    _exitStageUIMode();
    _audioPlayer.dispose();
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

    setState(() {
      // Each song opens in its own key; a transpose is per song.
      if (newIndex != idx) transposeSteps = 0;
      idx = newIndex;
    });

    final s = songs[idx];
    if (s.id != null) {
      await songRepo.touchLastOpened(s.id!);
    }
    await _prepareAudioForSong(s);

    _pageReady = false;

    final p = await _offlineReader.resolveReaderPath(s);
    if (!mounted || songs.isEmpty || songs[idx].id != s.id) return;
    if (p != null) {
      if (p != s.offlinePath) {
        final repaired = Song(
          id: s.id,
          title: s.title,
          sourceUrl: s.sourceUrl,
          importedAt: s.importedAt,
          lastOpenedAt: s.lastOpenedAt,
          playCount: s.playCount,
          offlinePath: p,
          audioPath: s.audioPath,
          isFavorite: s.isFavorite,
          timedChordSheetJson: s.timedChordSheetJson,
        );
        songs[idx] = repaired;
        if (s.id != null) await songRepo.updateSong(repaired);
      }
      _pendingStageStart = stageMode;
      await controller.loadFile(p);
      return;
    }

    _pendingStageStart = stageMode;
    await controller.loadRequest(Uri.parse(s.sourceUrl));
  }

  Future<void> _prepareAudioForSong(Song song) async {
    final rawPath = await UserStorageService.resolveStoredFile(song.audioPath, UserStorageService.audioDirectory);
    if (mounted) {
      setState(() {
        _audioLoading = true;
        _audioAvailable = false;
        _audioPosition = Duration.zero;
        _audioDuration = Duration.zero;
      });
    }

    await _audioPlayer.stop();

    if (rawPath == null || rawPath.isEmpty) {
      if (!mounted) return;
      setState(() => _audioLoading = false);
      return;
    }

    final audioFile = File(rawPath);
    if (!await audioFile.exists()) {
      if (!mounted) return;
      setState(() => _audioLoading = false);
      return;
    }

    try {
      await _audioPlayer.setFilePath(rawPath);
      if (!mounted) return;
      setState(() {
        _audioAvailable = true;
        _audioLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _audioLoading = false);
    }
  }

  Future<void> _openChordAnalysis() async {
    if (songs.isEmpty) return;
    final song = songs[idx];
    final audioPath = song.audioPath;
    if (audioPath == null || audioPath.isEmpty) return;
    await _audioPlayer.pause();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ChordAnalysisScreen(audioPath: audioPath, title: song.title),
      ),
    );
  }

  Future<void> _toggleAudioPlayback() async {
    if (_audioLoading || !_audioAvailable) return;

    final playerState = _audioPlayer.playerState;
    if (playerState.processingState == ProcessingState.completed) {
      await _audioPlayer.seek(Duration.zero);
    }

    if (_audioPlayer.playing) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
  }

  String _formatAudioTime(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _seekAudio(double value) async {
    final maxSeconds = _audioDuration.inMilliseconds <= 0
        ? 0.0
        : _audioDuration.inMilliseconds / 1000.0;
    if (maxSeconds <= 0) return;
    final targetSeconds = value.clamp(0.0, maxSeconds);
    await _audioPlayer.seek(
      Duration(milliseconds: (targetSeconds * 1000).round()),
    );
  }

  Widget _buildAudioTimeline(Color foregroundColor) {
    final totalSeconds = _audioDuration.inMilliseconds <= 0
        ? 0.0
        : _audioDuration.inMilliseconds / 1000.0;
    final currentSeconds = _audioPosition.inMilliseconds <= 0
        ? 0.0
        : _audioPosition.inMilliseconds / 1000.0;
    final sliderValue =
        totalSeconds <= 0 ? 0.0 : currentSeconds.clamp(0.0, totalSeconds);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: foregroundColor,
              inactiveTrackColor: foregroundColor.withValues(alpha: 0.25),
              thumbColor: foregroundColor,
              overlayColor: foregroundColor.withValues(alpha: 0.14),
            ),
            child: Slider(
              min: 0,
              max: totalSeconds <= 0 ? 1 : totalSeconds,
              value: sliderValue,
              onChanged:
                  _audioAvailable && totalSeconds > 0 ? _seekAudio : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Text(
                  _formatAudioTime(_audioPosition),
                  style: TextStyle(
                    color: foregroundColor.withValues(alpha: 0.82),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _audioAvailable ? _openChordAnalysis : null,
                  icon: const Icon(Icons.graphic_eq_rounded, size: 16),
                  label: const Text('AI Akorlar'),
                  style: TextButton.styleFrom(
                    foregroundColor: foregroundColor,
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  _formatAudioTime(_audioDuration),
                  style: TextStyle(
                    color: foregroundColor.withValues(alpha: 0.82),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
  var speed = 0.18;   // px/frame @60fps, usually below one pixel
  var carry = 0.0;
  var lastTs = 0;

  function tick(ts){
    if (!running) return;
    if (!root) { stop(); return; }

    if (!lastTs) lastTs = ts;
    var dt = (ts - lastTs) / 1000.0;
    lastTs = ts;

    // WebKit rounds scrollTop, so sub-pixel steps never moved the page;
    // accumulate and apply whole pixels.
    carry += speed * (dt * 60.0);
    var stepPx = Math.floor(carry);
    if (stepPx >= 1) {
      root.scrollTop += stepPx;
      carry -= stepPx;
    }

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
    carry = 0.0;
    lastTs = 0;
    requestAnimationFrame(tick);
  }

  function stop(){
    running = false;
    carry = 0.0;
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
    // Keep lyrics compact enough to fit more lines on stage-sized screens.
    final linePx = (20 * fontScale).clamp(15, 31).toStringAsFixed(1);

    // 🎸 chord rengi
    final selectedChordColor = UiPrefs.chordColor.value;
    final chordColor =
        '#${selectedChordColor.toARGB32().toRadixString(16).substring(2)}';

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

.ts-chord{
  color:$chordColor !important;
  line-height:1.0 !important;
  margin-bottom:0 !important;
}
.ts-line{
  margin:0 0 10px !important;
  padding:6px 8px !important;
}
.ts-row{
  gap:4px 8px !important;
}
.ts-segment{
  padding:1px 3px !important;
}
.ts-lyric{
  line-height:1.15 !important;
}
.ts-segment.active .ts-chord,
.ts-segment.active .ts-lyric{
  color:#ffc83d !important;
}
.ts-line.active{
  background:rgba(255,200,61,.16) !important;
}
/* Pages saved by older versions had a status bar ("Hazır", "Bölüm yok",
   BPM); keep just the title. */
#sheetMeta, .ts-hud-pill, .ts-hud-meta{ display:none !important; }
#sheetHud{
  position:static !important; display:block !important; padding:0 !important;
  border:0 !important; background:none !important; backdrop-filter:none !important;
}
#sheetTitle{ color:$fg !important; }

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
  const sharps = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B'];
  const flats = ['C','Db','D','Eb','E','F','Gb','G','Ab','A','Bb','B'];

  // A chord written with a flat stays in flats (Bb -> B -> C, Eb -> D).
  function transposeRoot(root, steps) {
    const r = String(root).replace('♯', '#').replace('♭', 'b');
    let idx = sharps.indexOf(r);
    if (idx < 0) idx = flats.indexOf(r);
    if (idx < 0) return root;
    let next = (idx + steps) % 12;
    if (next < 0) next += 12;
    return (r.indexOf('b') > 0 ? flats : sharps)[next];
  }

  function transposeChord(chord, steps) {
    const match = String(chord || '').match(/^([A-G](?:#|b|♯|♭)?)(.*?)(?:\\/([A-G](?:#|b|♯|♭)?))?\$/);
    if (!match) return chord;
    const root = transposeRoot(match[1], steps);
    const suffix = match[2] || '';
    const bass = match[3] ? '/' + transposeRoot(match[3], steps) : '';
    return root + suffix + bass;
  }

  // .ts-chord: timed sheets (akormatik imports); the rest: offline/web pages.
  const nodes = document.querySelectorAll('.ts-chord, #song .chord, #song .ay-chord, #song [data-chord], .chord, .ay-chord, [data-chord]');
  for (const node of nodes) {
    const original = node.dataset.originalChord ?? (node.textContent || '').trim();
    node.dataset.originalChord = original;
    if (!original) continue;
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
    final hasAudio = _audioAvailable;
    final audioReady = !_audioLoading && hasAudio;
    final isPlaying = _audioPlayer.playing;
    final actions = <Widget>[
      IconButton(
        tooltip: "Ana sayfa",
        icon: const Icon(Icons.home_rounded),
        onPressed: _goHome,
      ),
      // Recording button only when the song has audio attached.
      if (hasAudio || _audioLoading)
      IconButton(
        tooltip: _audioLoading
            ? "Ses dosyasi hazirlaniyor"
            : hasAudio
                ? (isPlaying ? "Kaydi durdur" : "Kaydi cal")
                : "Bu sarki icin ses dosyasi bagli degil",
        icon: _audioLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                hasAudio
                    ? (isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill)
                    : Icons.music_off_rounded,
              ),
        onPressed: audioReady ? _toggleAudioPlayback : null,
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
        preferredSize: Size.fromHeight(
          (_audioAvailable || _audioLoading) ? 156 : 108,
        ),
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
                if (_audioAvailable || _audioLoading)
                  _buildAudioTimeline(headerFg),
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
