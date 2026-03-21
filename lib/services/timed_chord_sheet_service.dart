import 'dart:convert';
import 'dart:io';

import '../models/song.dart';
import '../models/timed_chord_sheet.dart';
import 'akormatik_parser_service.dart';

class TimedChordSheetService {
  final AkormatikParserService _akormatikParser = AkormatikParserService();
  static final RegExp _inlineChordMarkerRe = RegExp(r'\[\[CHORD:(.*?)\]\]');
  static final RegExp _songBlockRe = RegExp(
    r'<div id="song">(.*?)</div>\s*</div>',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _spanChordRe = RegExp(
    r'<span[^>]*class="[^"]*chord[^"]*"[^>]*>(.*?)</span>',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _dataChordRe = RegExp(
    r'<[^>]*data-chord[^>]*>(.*?)</[^>]+>',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _tagRe = RegExp(r'<[^>]+>', dotAll: true);
  static final RegExp _spaceRe = RegExp(r'\s+');
  static final RegExp _chordTokenRe = RegExp(
    r'^[A-G](?:#|b)?(?:m|maj|min|dim|aug|sus|add)?\d*(?:/[A-G](?:#|b)?)?$',
  );

  Future<TimedChordSheet?> buildFromSong(Song song) async {
    final existingJson = song.timedChordSheetJson;
    if (existingJson != null && existingJson.trim().isNotEmpty) {
      final decoded = jsonDecode(existingJson);
      if (decoded is Map<String, Object?>) {
        return TimedChordSheet.fromMap(decoded);
      }
      if (decoded is Map) {
        return TimedChordSheet.fromMap(
          Map<String, Object?>.from(decoded.cast<String, Object?>()),
        );
      }
    }

    final path = song.offlinePath;
    if (path == null || path.isEmpty) return null;

    final file = File(path);
    if (!await file.exists()) return null;

    final html = await file.readAsString();
    return buildFromHtml(html);
  }

  TimedChordSheet? buildFromHtml(String html) {
    final blockMatch = _songBlockRe.firstMatch(html);
    final source = blockMatch?.group(1) ?? html;
    var text = source;

    text = text.replaceAllMapped(_spanChordRe, (m) {
      return ' [[CHORD:${_decodeHtml(m.group(1) ?? '')}]] ';
    });
    text = text.replaceAllMapped(_dataChordRe, (m) {
      return ' [[CHORD:${_decodeHtml(m.group(1) ?? '')}]] ';
    });
    text = text
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</div>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</li>', caseSensitive: false), '\n');
    text = text.replaceAll(_tagRe, '');
    text = _decodeHtml(text);

    final akormatikSheet = _akormatikParser.parse(text);
    if (akormatikSheet != null) return akormatikSheet;

    final lines = text
        .split('\n')
        .map((line) => line.replaceAll('\r', '').trimRight())
        .where((line) => line.trim().isNotEmpty)
        .toList();

    final timedLines = <TimedChordLine>[];
    List<String>? pendingChords;
    var sectionIndex = 0;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (_isSectionLine(line)) {
        sectionIndex++;
        timedLines.add(
          TimedChordLine(
            section: line,
            segments: const [],
          ),
        );
        pendingChords = null;
        continue;
      }

      if (_isChordOnlyLine(line)) {
        pendingChords = _extractChordTokens(line);
        continue;
      }

      final segments = line.contains('[[CHORD:')
          ? _buildInlineSegments(line)
          : _buildSegments(
              lyricLine: line,
              chords: pendingChords,
            );
      pendingChords = null;

      if (segments.isNotEmpty) {
        timedLines.add(TimedChordLine(segments: segments));
      }
    }

    if (timedLines.length < 4) return null;

    return TimedChordSheet(
      bpm: 82 + sectionIndex.clamp(0, 6),
      lines: timedLines,
    );
  }

  String buildReaderHtml({
    required TimedChordSheet sheet,
    required String title,
  }) {
    final payload = jsonEncode(sheet.toMap());
    final safeTitle = _escapeHtml(title);
    final hasYoutube = (sheet.youtubeVideoId ?? '').trim().isNotEmpty;
    return '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$safeTitle</title>
<style>
  html, body { margin:0; padding:0; background:#fff; color:#111; }
  body { font-family:-apple-system, system-ui, Arial; }
  #sheetRoot {
    min-height:100vh;
    padding:16px 16px 110px;
    box-sizing:border-box;
  }
  #playerWrap {
    position:relative;
    width:100%;
    margin:0 0 14px;
    border-radius:18px;
    overflow:hidden;
    background:#000;
    aspect-ratio:16 / 9;
    box-shadow:0 10px 30px rgba(0,0,0,.16);
  }
  #player {
    width:100%;
    height:100%;
  }
  #sheetHud {
    position:sticky;
    top:0;
    z-index:20;
    display:flex;
    align-items:center;
    justify-content:space-between;
    gap:12px;
    margin:0 0 16px;
    padding:10px 12px;
    border:1px solid rgba(0,0,0,.08);
    border-radius:16px;
    background:rgba(255,255,255,.92);
    backdrop-filter:blur(12px);
  }
  .ts-hud-pill {
    display:inline-flex;
    align-items:center;
    gap:6px;
    padding:6px 10px;
    border-radius:999px;
    background:#111;
    color:#fff;
    font-size:12px;
    font-weight:800;
  }
  .ts-hud-meta {
    display:flex;
    flex-wrap:wrap;
    gap:8px;
    align-items:center;
    color:#666;
    font-size:12px;
    font-weight:700;
  }
  #sheetTitle {
    margin:0 0 10px;
    font-size:22px;
    font-weight:800;
  }
  #sheetMeta {
    margin:0 0 18px;
    color:#666;
    font-size:13px;
    font-weight:700;
  }
  .ts-line {
    margin:0 0 18px;
    padding:10px 12px;
    border-radius:14px;
    transition:background-color .18s ease, transform .18s ease;
  }
  .ts-line.active {
    background:rgba(255, 200, 61, .16);
    transform:translateX(2px);
  }
  .ts-section {
    margin:18px 0 8px;
    color:#d89a00;
    font-size:12px;
    font-weight:800;
    letter-spacing:.08em;
    text-transform:uppercase;
  }
  .ts-row {
    display:flex;
    flex-wrap:wrap;
    gap:10px 12px;
    align-items:flex-start;
  }
  .ts-segment {
    display:inline-flex;
    flex-direction:column;
    min-width:32px;
    transition:transform .16s ease;
    border-radius:10px;
    padding:4px 6px;
    cursor:pointer;
  }
  .ts-segment.active {
    transform:translateY(-1px);
    background:rgba(255,200,61,.12);
  }
  .ts-chord {
    color:#b00020;
    font-size:.88em;
    line-height:1.1;
    font-weight:900;
    margin-bottom:2px;
  }
  .ts-lyric {
    color:inherit;
    font-size:1em;
    line-height:1.5;
    white-space:pre-wrap;
  }
  .ts-segment.active .ts-chord,
  .ts-segment.active .ts-lyric {
    color:#ffc83d;
  }
</style>
</head>
<body>
  <div id="sheetRoot">
    ${hasYoutube ? '<div id="playerWrap"><div id="player"></div></div>' : ''}
    <div id="sheetHud">
      <div>
        <h1 id="sheetTitle">$safeTitle</h1>
        <p id="sheetMeta">Timed prototype • BPM <span id="sheetBpm"></span></p>
      </div>
      <div>
        <div class="ts-hud-pill" id="sheetStatus">Hazır</div>
        <div class="ts-hud-meta">
          <span id="sheetSection">Bölüm yok</span>
          <span id="sheetRate">1.00x</span>
        </div>
      </div>
    </div>
    <div id="sheetLines"></div>
  </div>
<script>
(() => {
  const sheet = $payload;
  const hasYoutube = !!(sheet.youtubeVideoId && String(sheet.youtubeVideoId).trim());
  const bpm = Number(sheet.bpm || 82);
  const linesHost = document.getElementById('sheetLines');
  const bpmNode = document.getElementById('sheetBpm');
  const statusNode = document.getElementById('sheetStatus');
  const sectionNode = document.getElementById('sheetSection');
  const rateNode = document.getElementById('sheetRate');
  bpmNode.textContent = String(bpm);
  rateNode.textContent = '1.00x';

  let running = false;
  let rate = 1.0;
  let timer = null;
  let beatTimers = [];
  let activeLineIndex = -1;
  let activeSegmentIndex = -1;
  let soundEnabled = true;
  let audioContext = null;
  let player = null;
  let pollTimer = null;
  let isSeekingInternally = false;
  const flatSegments = [];
  const lineNodes = [];
  const lineSections = [];
  let currentSection = 'Bölüm yok';

  function build() {
    sheet.lines.forEach((line, lineIndex) => {
      if (line.section && (!line.segments || !line.segments.length)) {
        const section = document.createElement('div');
        section.className = 'ts-section';
        section.textContent = line.section;
        linesHost.appendChild(section);
        currentSection = line.section;
        return;
      }

      const lineNode = document.createElement('div');
      lineNode.className = 'ts-line';
      lineNode.dataset.lineIndex = String(lineIndex);
      lineSections[lineIndex] = currentSection;

      const row = document.createElement('div');
      row.className = 'ts-row';
      lineNode.appendChild(row);

      (line.segments || []).forEach((segment, segmentIndex) => {
        const item = document.createElement('div');
        item.className = 'ts-segment';
        item.dataset.lineIndex = String(lineIndex);
        item.dataset.segmentIndex = String(segmentIndex);
        item.addEventListener('click', () => {
          seekTo(lineIndex, segmentIndex, true);
        });

        const chord = document.createElement('div');
        chord.className = 'ts-chord';
        chord.textContent = segment.chord || '';
        item.appendChild(chord);

        const lyric = document.createElement('div');
        lyric.className = 'ts-lyric';
        lyric.textContent = segment.lyric || ' ';
        item.appendChild(lyric);

        row.appendChild(item);
        flatSegments.push({
          lineIndex,
          segmentIndex,
          beats: Number(segment.beats || 0),
          startMs: segment.startMs == null ? null : Number(segment.startMs),
        });
      });

      linesHost.appendChild(lineNode);
      lineNodes[lineIndex] = lineNode;
    });
  }

  function clearActive() {
    document.querySelectorAll('.ts-line.active').forEach((node) => {
      node.classList.remove('active');
    });
    document.querySelectorAll('.ts-segment.active').forEach((node) => {
      node.classList.remove('active');
    });
  }

  function activate(lineIndex, segmentIndex) {
    clearActive();
    activeLineIndex = lineIndex;
    activeSegmentIndex = segmentIndex;
    sectionNode.textContent = lineSections[lineIndex] || 'Bölüm yok';

    const lineNode = lineNodes[lineIndex];
    if (lineNode) {
      lineNode.classList.add('active');
      lineNode.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }

    const segmentNode = document.querySelector(
      '.ts-segment[data-line-index="' + lineIndex + '"][data-segment-index="' + segmentIndex + '"]'
    );
    if (segmentNode) segmentNode.classList.add('active');
  }

  function step(index) {
    if (hasYoutube) return;
    if (!running) return;
    if (index >= flatSegments.length) {
      stop();
      return;
    }

    const current = flatSegments[index];
    activate(current.lineIndex, current.segmentIndex);

    const beatMs = 60000 / bpm;
    scheduleClicks(Math.max(1, current.beats), beatMs);
    const durationMs = Math.max(380, beatMs * Math.max(1, current.beats) / rate);
    timer = setTimeout(() => step(index + 1), durationMs);
  }

  function start() {
    if (running) return;
    running = true;
    statusNode.textContent = 'Çalıyor';
    if (hasYoutube && player && player.playVideo) {
      player.playVideo();
      startPolling();
      return;
    }
    const nextIndex = flatSegments.findIndex((segment) => {
      if (activeLineIndex < 0) return true;
      return segment.lineIndex > activeLineIndex ||
        (segment.lineIndex === activeLineIndex && segment.segmentIndex > activeSegmentIndex);
    });
    step(nextIndex >= 0 ? nextIndex : 0);
  }

  function stop() {
    running = false;
    statusNode.textContent = 'Durdu';
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
    if (hasYoutube && player && player.pauseVideo) {
      player.pauseVideo();
    }
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    clearBeatTimers();
  }

  function reset() {
    stop();
    activeLineIndex = -1;
    activeSegmentIndex = -1;
    clearActive();
    sectionNode.textContent = 'Bölüm yok';
    statusNode.textContent = 'Hazır';
    if (hasYoutube && player && player.seekTo) {
      player.seekTo(0, true);
    }
  }

  function setRate(value) {
    const next = Number(value);
    if (!isNaN(next) && isFinite(next) && next > 0) {
      rate = next;
      rateNode.textContent = next.toFixed(2) + 'x';
    }
  }

  function ensureAudio() {
    if (!soundEnabled) return null;
    const AudioCtx = window.AudioContext || window.webkitAudioContext;
    if (!AudioCtx) return null;
    if (!audioContext) {
      audioContext = new AudioCtx();
    }
    if (audioContext.state === 'suspended') {
      audioContext.resume().catch(() => {});
    }
    return audioContext;
  }

  function playClick(isAccent) {
    if (!soundEnabled) return;
    const ctx = ensureAudio();
    if (!ctx) return;

    const now = ctx.currentTime;
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();

    osc.type = 'square';
    osc.frequency.value = isAccent ? 1560 : 1040;
    gain.gain.setValueAtTime(0.0001, now);
    gain.gain.exponentialRampToValueAtTime(isAccent ? 0.09 : 0.05, now + 0.01);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.08);

    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start(now);
    osc.stop(now + 0.09);
  }

  function clearBeatTimers() {
    beatTimers.forEach((id) => clearTimeout(id));
    beatTimers = [];
  }

  function scheduleClicks(beats, beatMs) {
    clearBeatTimers();
    for (let i = 0; i < beats; i++) {
      const id = setTimeout(() => {
        if (!running) return;
        playClick(i === 0);
      }, Math.max(0, (beatMs * i) / rate));
      beatTimers.push(id);
    }
  }

  function seekTo(lineIndex, segmentIndex, shouldPlay) {
    const nextIndex = flatSegments.findIndex((segment) =>
      segment.lineIndex === lineIndex && segment.segmentIndex === segmentIndex
    );
    if (nextIndex < 0) return;
    stop();
    activate(lineIndex, segmentIndex);
    const target = flatSegments[nextIndex];
    if (hasYoutube && target && target.startMs != null && player && player.seekTo) {
      isSeekingInternally = true;
      player.seekTo(target.startMs / 1000, true);
      setTimeout(() => { isSeekingInternally = false; }, 350);
      if (shouldPlay) {
        running = true;
        statusNode.textContent = 'Çalıyor';
        player.playVideo();
        startPolling();
      } else {
        statusNode.textContent = 'Hazır';
      }
      return;
    }
    if (shouldPlay) {
      running = true;
      statusNode.textContent = 'Çalıyor';
      timer = setTimeout(() => step(nextIndex + 1), 180);
    } else {
      statusNode.textContent = 'Hazır';
    }
  }

  function findSegmentForMs(ms) {
    let candidate = null;
    for (const segment of flatSegments) {
      if (segment.startMs == null) continue;
      if (ms >= segment.startMs) {
        candidate = segment;
      } else {
        break;
      }
    }
    return candidate;
  }

  function syncFromPlayer() {
    if (!running || !player || !player.getCurrentTime || isSeekingInternally) return;
    const currentMs = Math.floor(Number(player.getCurrentTime() || 0) * 1000);
    syncToMs(currentMs, true);
  }

  function syncToMs(ms, shouldClick) {
    const match = findSegmentForMs(Math.max(0, Number(ms) || 0));
    if (!match) return;
    if (match.lineIndex !== activeLineIndex || match.segmentIndex !== activeSegmentIndex) {
      activate(match.lineIndex, match.segmentIndex);
      if (shouldClick) {
        playClick(true);
      }
    }
  }

  function startPolling() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = setInterval(syncFromPlayer, 180);
  }

  function onPlayerReady() {
    statusNode.textContent = 'Hazır';
  }

  function onPlayerStateChange(event) {
    if (!window.YT || !YT.PlayerState) return;
    if (event.data === YT.PlayerState.PLAYING) {
      running = true;
      statusNode.textContent = 'Çalıyor';
      startPolling();
    } else if (event.data === YT.PlayerState.PAUSED) {
      running = false;
      statusNode.textContent = 'Durdu';
      if (pollTimer) {
        clearInterval(pollTimer);
        pollTimer = null;
      }
    } else if (event.data === YT.PlayerState.ENDED) {
      reset();
    }
  }

  function setupYoutube() {
    if (!hasYoutube) return;
    const script = document.createElement('script');
    script.src = 'https://www.youtube.com/iframe_api';
    document.head.appendChild(script);
    window.onYouTubeIframeAPIReady = function() {
      player = new YT.Player('player', {
        videoId: sheet.youtubeVideoId,
        playerVars: {
          playsinline: 1,
          rel: 0,
        },
        events: {
          onReady: onPlayerReady,
          onStateChange: onPlayerStateChange,
        },
      });
    };
  }

  build();
  setupYoutube();
  window.timedSheet = {
    start,
    stop,
    reset,
    setRate,
    setSoundEnabled: (value) => { soundEnabled = !!value; },
    seekTo,
    syncToMs: (ms) => syncToMs(ms, false),
    isRunning: () => running,
  };
})();
</script>
</body>
</html>
''';
  }

  List<TimedChordSegment> _buildSegments({
    required String lyricLine,
    required List<String>? chords,
  }) {
    if (chords == null || chords.isEmpty) {
      return [TimedChordSegment(lyric: lyricLine)];
    }

    final words =
        lyricLine.split(_spaceRe).where((word) => word.isNotEmpty).toList();
    if (words.isEmpty) {
      return chords
          .map((chord) => TimedChordSegment(lyric: '', chord: chord, beats: 2))
          .toList();
    }

    final segments = <TimedChordSegment>[];
    var start = 0;
    for (var i = 0; i < chords.length; i++) {
      final isLast = i == chords.length - 1;
      final remainingWords = words.length - start;
      if (remainingWords <= 0) {
        segments.add(TimedChordSegment(lyric: '', chord: chords[i], beats: 2));
        continue;
      }

      final take = isLast
          ? remainingWords
          : (remainingWords / (chords.length - i))
              .ceil()
              .clamp(1, remainingWords);
      final end = (start + take).clamp(0, words.length);
      final lyric = words.sublist(start, end).join(' ');
      start = end;
      segments.add(
        TimedChordSegment(
          lyric: lyric,
          chord: chords[i],
          beats: lyric
              .split(_spaceRe)
              .where((word) => word.isNotEmpty)
              .length
              .clamp(1, 4),
        ),
      );
    }

    return segments;
  }

  List<TimedChordSegment> _buildInlineSegments(String line) {
    final matches = _inlineChordMarkerRe.allMatches(line).toList();
    if (matches.isEmpty) {
      return [
        TimedChordSegment(
            lyric: line.replaceAll('[[CHORD:', '').replaceAll(']]', '').trim())
      ];
    }

    final segments = <TimedChordSegment>[];
    for (var i = 0; i < matches.length; i++) {
      final chord = _decodeHtml(matches[i].group(1) ?? '').trim();
      final start = matches[i].end;
      final end = i + 1 < matches.length ? matches[i + 1].start : line.length;
      final lyric = line
          .substring(start, end)
          .replaceAll(_inlineChordMarkerRe, '')
          .trim();
      segments.add(
        TimedChordSegment(
          lyric: lyric.isEmpty ? ' ' : lyric,
          chord: chord.isEmpty ? null : chord,
          beats: lyric
              .split(_spaceRe)
              .where((word) => word.isNotEmpty)
              .length
              .clamp(1, 4),
        ),
      );
    }
    return segments;
  }

  List<String> _extractChordTokens(String line) {
    return line
        .split(_spaceRe)
        .map((token) => token.trim())
        .where(_isChordToken)
        .toList();
  }

  bool _isSectionLine(String line) {
    final lower = line.toLowerCase();
    return lower.startsWith('bölüm ') ||
        lower.startsWith('nakarat') ||
        lower.startsWith('verse') ||
        lower.startsWith('bridge') ||
        lower.startsWith('intro');
  }

  bool _isChordOnlyLine(String line) {
    if (line.contains('[[CHORD:')) return false;
    final tokens = line
        .replaceAll('[[CHORD:', '')
        .replaceAll(']]', '')
        .split(_spaceRe)
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList();
    if (tokens.isEmpty || tokens.length > 8) return false;
    return tokens.every(_isChordToken);
  }

  bool _isChordToken(String token) {
    final normalized = token
        .replaceAll('♯', '#')
        .replaceAll('♭', 'b')
        .replaceAll('maj7', 'maj7')
        .replaceAll('sus4', 'sus4')
        .replaceAll(' ', '');
    return _chordTokenRe.hasMatch(normalized);
  }

  String _decodeHtml(String value) {
    return value
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#8220;', '"')
        .replaceAll('&#8221;', '"');
  }

  String _escapeHtml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }
}
