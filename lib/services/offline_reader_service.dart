import 'dart:io';
import 'package:path/path.dart';

import 'user_storage_service.dart';

class OfflineReaderService {
  Future<String> makeReaderHtml(String rawHtml, {required String title}) async {
    final normalized = _maybeDecodeHtml(rawHtml);

    return """
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_escape(title)}</title>

<style>
  html, body { margin:0; padding:0; height:100%; }
  body { font-family:-apple-system, system-ui, Arial; background:#fff; color:#111; overflow-x:hidden; }

  #scrollRoot{
    height:100vh;
    overflow-y:auto;
    overflow-x:hidden;
    padding:16px;
    box-sizing:border-box;
    -webkit-overflow-scrolling: touch;
  }

  h2{
    margin:0 0 14px 0;
    font-size:22px;
    line-height:1.2;
    word-break: break-word;
    overflow-wrap:anywhere;
  }

  /* ✅ Mobil taşma engeli */
  #song, #song *{ max-width:100%; box-sizing:border-box; }

  /* Kaynak pre ile gelse bile sardır */
  #song{
    white-space: pre-wrap;
    word-break: break-word;
    overflow-wrap:anywhere;
    font-size: inherit;
    line-height: inherit;
  }
  #song pre{
    margin:0;
    white-space: pre-wrap !important;
    word-break: break-word !important;
    overflow-wrap:anywhere !important;
    font: inherit !important;
  }

  /* 🎸 Akor rengi (PlayScreen dark mode’da bunu override edecek) */
  .chord { color:#b00020; font-weight:900; }

  img, video, iframe { max-width:100% !important; height:auto !important; }
</style>
</head>

<body>
  <div id="scrollRoot">
    <h2>${_escape(title)}</h2>
    <div id="song">$normalized</div>
  </div>

<script>
(function(){
  /* ---------- safe html escape ---------- */
  function escHtml(s){
    s = String(s == null ? '' : s);
    s = s.replace(/&/g, '&amp;');
    s = s.replace(/</g, '&lt;');
    s = s.replace(/>/g, '&gt;');
    return s;
  }

  /* ---------- chord helpers ---------- */
  var baseTokenRe = /[A-G](?:#|b)?(?:m|maj|min|dim|aug|sus|add)?\\d?/g;

  function isBaseChord(part){
    part = String(part || '').trim();
    if (!part) return false;
    var m = part.match(baseTokenRe);
    return m && m.length === 1 && m[0].length === part.length;
  }

  // Slash chord support: C/E, Bm/F#
  function isChordToken(t){
    t = String(t || '').trim();
    if (!t) return false;

    var parts = t.split('/');
    if (parts.length > 2) return false;

    for (var i=0; i<parts.length; i++){
      if (!isBaseChord(parts[i])) return false;
    }
    return true;
  }

  function wrapMaybeChord(raw){
    if (!raw) return raw;

    var lead = '';
    var core = raw;
    var trail = '';

    // leading wrappers
    while (core.length) {
      var c0 = core.charAt(0);
      if (c0 === '(' || c0 === '[' || c0 === '{' || c0 === '"' || c0 === "'" ) {
        lead += c0;
        core = core.substring(1);
        continue;
      }
      break;
    }

    // trailing wrappers/punct
    while (core.length) {
      var c1 = core.charAt(core.length - 1);
      if (c1 === ')' || c1 === ']' || c1 === '}' || c1 === '"' || c1 === "'" ||
          c1 === ',' || c1 === '.' || c1 === ';' || c1 === ':' || c1 === '!' || c1 === '?') {
        trail = c1 + trail;
        core = core.substring(0, core.length - 1);
        continue;
      }
      break;
    }

    if (isChordToken(core)) {
      return lead + '<span class="chord">' + escHtml(core) + '</span>' + trail;
    }
    return escHtml(raw);
  }

  function colorizeChordsEverywhere(){
    var el = document.getElementById('song');
    if (!el) return;

    // eğer kaynak zaten data-chord ile işaretliyse: sadece renk CSS’i için chord class ekleyelim
    // (bazı sitelerde <span data-chord="1">Bm</span> geliyor)
    var hasDataChord = el.querySelector && el.querySelector('[data-chord]');
    if (hasDataChord) {
      var nodes = el.querySelectorAll('[data-chord]');
      for (var i=0; i<nodes.length; i++){
        nodes[i].classList.add('chord');
      }
      return;
    }

    // Plain text üzerinden satır satır üret
    var lines = (el.innerText || el.textContent || '').split('\\n');

    var out = lines.map(function(line){
      var raw = String(line || '');
      if (!raw.trim()) return '';

      // whitespace'i korumak için parçala
      var parts = raw.split(/(\\s+)/);
      for (var i=0; i<parts.length; i++){
        // boşlukları dokunma
        if (parts[i] && parts[i].trim() !== '') {
          parts[i] = wrapMaybeChord(parts[i]);
        } else {
          parts[i] = escHtml(parts[i]);
        }
      }
      return parts.join('');
    }).join('\\n');

    el.innerHTML =
      '<pre style="margin:0; white-space:pre-wrap; word-break:break-word; overflow-wrap:anywhere;">' +
      out +
      '</pre>';
  }

  colorizeChordsEverywhere();

  /* ---------- auto scroll bridge (fraction-safe) ---------- */
  var root = document.getElementById('scrollRoot');
  if (!root) root = document.scrollingElement || document.documentElement || document.body;

  var running = false;
  var speed = 0.12;   // px/frame @60fps
  var carry = 0.0;
  var lastTs = 0;

  function frame(ts){
    if (!running) return;
    if (!root) { stop(); return; }

    if (!lastTs) lastTs = ts;
    var dt = (ts - lastTs) / 1000.0;
    lastTs = ts;

    carry += speed * (dt * 60.0);

    var step = Math.floor(carry);
    if (step >= 1) {
      root.scrollTop += step;
      carry -= step;
    }

    if (root.scrollTop + root.clientHeight >= root.scrollHeight - 2) {
      stop();
      return;
    }

    requestAnimationFrame(frame);
  }

  function start(){
    if (running) return;
    running = true;
    carry = 0.0;
    lastTs = 0;
    requestAnimationFrame(frame);
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

  window.readerScroll = { start:start, stop:stop, setSpeed:setSpeed, toTop:toTop };
})();
</script>

</body>
</html>
""";
  }

  Future<String> saveOfflineHtml(
      {required int songId, required String html}) async {
    final songsDir = await UserStorageService.songsDirectory();

    final file = File(join(songsDir.path, '$songId.html'));
    await file.writeAsString(html, flush: true);
    return file.path;
  }

  String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  String _maybeDecodeHtml(String s) {
    final hasRealTag = s.contains('<') && s.contains('>');
    final hasEntities = s.contains('&lt;') || s.contains('&gt;');

    if (!hasRealTag && hasEntities) {
      return s
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&amp;', '&');
    }
    return s;
  }
}
