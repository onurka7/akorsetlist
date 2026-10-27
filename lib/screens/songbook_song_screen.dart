import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../chord_ai/chord_theory.dart';
import '../chord_ai/widgets/chord_diagram.dart';
import '../models/setlist.dart';
import '../repositories/setlist_repo.dart';
import '../services/membership_access_service.dart';
import '../songbook/songbook.dart';
import '../songbook/songbook_backing.dart';
import '../songbook/songbook_library.dart';
import 'songbook_screen.dart' show SongbookCover;

const Color _accent = Color(0xFFFFC83D);
const List<Color> _markColors = [Color(0xFFB58E93), Color(0xFF90A959), Color(0xFF6494AA)];
const List<double> _speeds = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];

/// One ready-made song: chart with chords, diagrams and lyrics aligned,
/// key-aware transpose, synthesised accompaniment (audio transpose, speed,
/// stanza repeat) and beat-synchronised highlighting with auto-scroll.
class SongbookSongScreen extends StatefulWidget {
  final SongbookSong song;

  const SongbookSongScreen({super.key, required this.song});

  @override
  State<SongbookSongScreen> createState() => _SongbookSongScreenState();
}

class _SongbookSongScreenState extends State<SongbookSongScreen> {
  static final SongbookBackingCache _cache = SongbookBackingCache();

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<Object?>> _subs = [];
  final Map<int, GlobalKey> _blockKeys = {};

  int _transpose = 0;
  bool _audioTranspose = true;
  int? _trackOffset;
  bool _trackLoading = false;
  double _speed = 1;
  bool _repeatOn = false;
  late int _repeatFrom;
  late int _repeatTo;
  bool _showDiagrams = true;
  bool _playing = false;
  Duration _position = Duration.zero;
  int? _markedBlock;
  double? _markedBeat;

  SongbookSong get song => widget.song;
  String get _key => transposeKeyName(song.key, _transpose);
  String _shown(String chord) => transposeForKey(chord, _transpose, _key);

  @override
  void initState() {
    super.initState();
    final blocks = song.blocks;
    _repeatFrom = blocks.first.number;
    _repeatTo = blocks.last.number;
    for (final b in blocks) {
      _blockKeys[b.number] = GlobalKey();
    }
    _subs.add(_player.positionStream.listen(_onPosition));
    _subs.add(_player.playingStream.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
      p ? WakelockPlus.enable() : WakelockPlus.disable();
    }));
    _subs.add(_player.processingStateStream.listen((s) {
      if (s != ProcessingState.completed) return;
      final w = _repeatOn ? repeatWindow(song, _repeatFrom, _repeatTo) : null;
      if (w != null) {
        _seek(w.begin);
      } else {
        _player.pause();
        _seek(0);
      }
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ---------------------------------------------------------------- player

  Future<void> _ensureTrack() async {
    final semis = _audioTranspose ? _transpose : 0;
    if (_trackOffset == semis) return;
    setState(() => _trackLoading = true);
    try {
      final path = await _cache.pathFor(song, semis);
      final pos = _player.position;
      final wasPlaying = _player.playing;
      await _player.setFilePath(path);
      await _player.seek(pos);
      await _player.setSpeed(_speed);
      _trackOffset = semis;
      if (wasPlaying) unawaited(_player.play());
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Eşlik sesi hazırlanamadı: $e')));
    } finally {
      if (mounted) setState(() => _trackLoading = false);
    }
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
      return;
    }
    await _ensureTrack();
    if (_trackOffset != null) unawaited(_player.play());
  }

  Future<void> _seek(double seconds) async {
    await _player.seek(Duration(microseconds: (seconds.clamp(0, song.duration) * 1e6).round()));
    if (!_playing) _onPosition(_player.position);
  }

  Future<void> _seekBlock(SongbookBlock b) async {
    final w = repeatWindow(song, _repeatFrom, _repeatTo);
    if (_repeatOn && w != null && (b.time < w.begin || b.time >= w.end)) setState(() => _repeatOn = false);
    await _ensureTrack();
    await _seek(b.time);
  }

  void _onPosition(Duration pos) {
    if (!mounted) return;
    final t = pos.inMicroseconds / 1e6;
    final w = _repeatOn ? repeatWindow(song, _repeatFrom, _repeatTo) : null;
    if (w != null && _playing && (t < w.begin - 0.25 || t > w.end)) {
      _seek(w.begin);
      return;
    }
    final at = locateInSong(song, t);
    final block = at.block?.number;
    final beat = at.cell?.beat;
    final blockChanged = block != _markedBlock;
    setState(() {
      _position = pos;
      _markedBlock = block;
      _markedBeat = beat;
    });
    if (blockChanged && _playing && block != null) _scrollTo(block);
  }

  void _scrollTo(int block) {
    final ctx = _blockKeys[block]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx, alignment: 0.3, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  void _setTranspose(int value) {
    setState(() => _transpose = normalizeTranspose(value));
    if (_trackOffset != null) _ensureTrack();
  }

  // ------------------------------------------------------------- library

  Future<void> _addToLibrary() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await MembershipAccessService.instance.canImportSong()) {
      messenger.showSnackBar(const SnackBar(content: Text('Free planda en fazla 5 şarkı eklenebilir. Yıllık plan gerekli.')));
      return;
    }
    final setlists = await SetlistRepo().listSetlists();
    if (!mounted) return;
    final choice = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(SongbookLibrary.titleFor(song, _transpose), style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('Ton: ${prettyChord(_key)} · çalma ekranında çevrimdışı açılır'),
            ),
            ListTile(
              leading: const Icon(Icons.library_music_rounded),
              title: const Text('Sadece Tüm Şarkılar\'a ekle'),
              onTap: () => Navigator.pop(ctx, 'library'),
            ),
            for (final Setlist s in setlists)
              ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: Text('Sete ekle: ${s.name}'),
                onTap: () => Navigator.pop(ctx, s),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    try {
      final setlist = choice is Setlist ? choice : null;
      final (_, existed) = await SongbookLibrary().save(song, transpose: _transpose, setlistId: setlist?.id);
      messenger.showSnackBar(SnackBar(
        content: Text([
          existed ? 'Şarkı zaten kütüphanede, güncellendi' : 'Kütüphaneye eklendi',
          if (setlist != null) '“${setlist.name}” setine eklendi',
        ].join(' · ')),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Eklenemedi: $e')));
    }
  }

  void _showChordSheet(String chord, Color fg) {
    final shapes = findVoicings(chord, ChordInstrument.guitar, count: 3);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ChordLabel(chord: chord, color: fg, size: 24),
              const SizedBox(height: 12),
              Wrap(
                spacing: 20,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  for (final v in shapes)
                    ChordDiagram(chord: chord, instrument: ChordInstrument.guitar, voicing: v, foreground: fg, accent: _accent, width: 92),
                  if (shapes.isEmpty) const Text('Pozisyon bulunamadı'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : const Color(0xFF212529);
    final dim = isDark ? const Color(0xFF9CA3AF) : const Color(0xFF8E9295);
    final line = isDark ? const Color(0xFF3A3A3A) : const Color(0xFFCED4DA);

    return Scaffold(
      appBar: AppBar(
        title: Text(song.title),
        actions: [
          IconButton(
            tooltip: _showDiagrams ? 'Basılışları gizle' : 'Basılışları göster',
            icon: Icon(_showDiagrams ? Icons.grid_on_rounded : Icons.grid_off_rounded),
            onPressed: () => setState(() => _showDiagrams = !_showDiagrams),
          ),
          IconButton(tooltip: 'Repertuvara ekle', icon: const Icon(Icons.library_add_rounded), onPressed: _addToLibrary),
        ],
      ),
      body: Column(
        children: [
          _playerPanel(fg, dim, line, isDark),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(fg, dim),
                  const SizedBox(height: 8),
                  Text('♩=${song.bpm}${song.meter != 4 ? ' · ${song.meter}/4' : ''}', style: TextStyle(color: dim, fontStyle: FontStyle.italic)),
                  for (final s in song.stanzas) _stanza(s, fg, dim, line, isDark),
                  const SizedBox(height: 16),
                  if (song.contributors.isNotEmpty)
                    Text('Söz/Müzik: ${song.contributors.join(', ')}', style: TextStyle(color: dim, fontStyle: FontStyle.italic, fontSize: 13)),
                  const SizedBox(height: 4),
                  Text('Eşlik sesi akor şemasından cihazda üretilir.', style: TextStyle(color: dim, fontSize: 11)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(Color fg, Color dim) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 76, height: 76, child: SongbookCover(song: song, fontSize: 11)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(song.title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: fg, height: 1.15)),
              Text(song.artist, style: TextStyle(fontSize: 17, color: fg)),
              const SizedBox(height: 2),
              Row(
                children: [
                  _ChordLabel(chord: _key, color: dim, size: 15),
                  const Spacer(),
                  for (final t in song.tags)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: const Color(0xFF6C757D), borderRadius: BorderRadius.circular(10)),
                        child: Text(t, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _playerPanel(Color fg, Color dim, Color line, bool isDark) {
    final dur = song.duration;
    final t = (_position.inMicroseconds / 1e6).clamp(0.0, dur);
    String fmt(double s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';
    final blocks = song.blocks;
    final options = [for (var s = -6; s <= 5; s++) s];

    Widget box({required Widget child}) => Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(border: Border.all(color: line), borderRadius: BorderRadius.circular(6)),
          child: child,
        );

    return Material(
      color: isDark ? const Color(0xFF111111) : Colors.white,
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Column(
          children: [
            Row(
              children: [
                IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.black),
                  tooltip: _playing ? 'Duraklat' : 'Çal',
                  onPressed: _trackLoading ? null : _togglePlay,
                  icon: _trackLoading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                ),
                IconButton(
                  tooltip: 'Başa sar',
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: () {
                    _player.pause();
                    setState(() => _repeatOn = false);
                    _seek(0);
                  },
                ),
                Expanded(
                  child: Slider(
                    value: t,
                    max: dur,
                    activeColor: fg,
                    onChanged: (v) async {
                      await _ensureTrack();
                      await _seek(v);
                    },
                  ),
                ),
                Text('${fmt(t)} / ${fmt(dur)}', style: TextStyle(fontSize: 12, color: dim, fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                box(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('T ', style: TextStyle(fontWeight: FontWeight.w700, color: dim)),
                    DropdownButton<int>(
                      value: _transpose,
                      underline: const SizedBox.shrink(),
                      isDense: true,
                      items: [
                        for (final s in options)
                          DropdownMenuItem(
                            value: s,
                            child: Text('${s > 0 ? '+$s' : '$s'}  (${prettyChord(transposeKeyName(song.key, s))})'),
                          ),
                      ],
                      onChanged: (v) => v == null ? null : _setTranspose(v),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: _audioTranspose ? 'Ses transpozeyi kapat' : 'Ses transpozeyi aç',
                      icon: Icon(Icons.graphic_eq_rounded, color: _audioTranspose ? Colors.blue : dim),
                      onPressed: () {
                        setState(() => _audioTranspose = !_audioTranspose);
                        if (_trackOffset != null) _ensureTrack();
                      },
                    ),
                  ]),
                ),
                box(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.speed_rounded, size: 18, color: dim),
                    const SizedBox(width: 4),
                    DropdownButton<double>(
                      value: _speed,
                      underline: const SizedBox.shrink(),
                      isDense: true,
                      items: [for (final s in _speeds) DropdownMenuItem(value: s, child: Text('${s}x'))],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _speed = v);
                        _player.setSpeed(v);
                      },
                    ),
                  ]),
                ),
                box(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: _repeatOn ? 'Tekrarı kapat' : 'Kıta tekrarı',
                      icon: Icon(Icons.repeat_rounded, color: _repeatOn ? Colors.blue : dim),
                      onPressed: () => setState(() => _repeatOn = !_repeatOn),
                    ),
                    DropdownButton<int>(
                      value: _repeatFrom,
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      items: [for (final b in blocks) DropdownMenuItem(value: b.number, child: Text('${b.number}'))],
                      onChanged: !_repeatOn
                          ? null
                          : (v) => setState(() {
                                _repeatFrom = v!;
                                if (_repeatTo < v) _repeatTo = v;
                              }),
                    ),
                    Text(' – ', style: TextStyle(color: dim)),
                    DropdownButton<int>(
                      value: _repeatTo,
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final b in blocks)
                          DropdownMenuItem(value: b.number, enabled: b.number >= _repeatFrom, child: Text('${b.number}')),
                      ],
                      onChanged: !_repeatOn ? null : (v) => setState(() => _repeatTo = v!),
                    ),
                  ]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stanza(SongbookStanza s, Color fg, Color dim, Color line, bool isDark) {
    switch (s) {
      case SongbookComment(:final text):
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Row(children: [
            Text(text, style: TextStyle(fontWeight: FontWeight.w700, fontStyle: FontStyle.italic, color: dim)),
            const SizedBox(width: 8),
            Expanded(child: Divider(color: line, height: 1)),
          ]),
        );
      case SongbookBlock():
        final marked = _markedBlock == s.number;
        return Padding(
          key: _blockKeys[s.number],
          padding: const EdgeInsets.only(top: 14),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GestureDetector(
                  onTap: () => _seekBlock(s),
                  child: Container(
                    width: 24,
                    padding: const EdgeInsets.only(top: 2),
                    decoration: BoxDecoration(
                      color: marked ? _markColors[s.number % 3] : (isDark ? const Color(0xFF1C1C22) : const Color(0xFFF8F8FF)),
                      border: Border(top: BorderSide(color: line), bottom: BorderSide(color: line), right: BorderSide(color: line)),
                    ),
                    child: Text(
                      '${s.number}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w700,
                        color: marked ? Colors.white : line,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [for (final v in s.verses) _verse(s, v, fg, dim)],
                  ),
                ),
              ],
            ),
          ),
        );
    }
  }

  Widget _verse(SongbookBlock block, SongbookVerse verse, Color fg, Color dim) {
    final cells = <Widget>[];
    if (verse.instrumental) cells.add(Text('| ', style: TextStyle(color: dim, fontSize: 16)));
    for (var i = 0; i < verse.cells.length; i++) {
      final c = verse.cells[i];
      final prevFlows = i > 0 && verse.cells[i - 1].lyric.isNotEmpty && !RegExp(r'\s$').hasMatch(verse.cells[i - 1].lyric);
      final marked = block.number == _markedBlock && c.beat == _markedBeat && c.chord != null;
      final chord = c.chord == null ? null : _shown(c.chord!);
      cells.add(Padding(
        padding: EdgeInsets.only(left: i == 0 || prevFlows || verse.instrumental ? 0 : 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 24,
              child: chord == null
                  ? null
                  : Container(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: marked
                          ? BoxDecoration(color: Colors.yellow, border: Border.all(color: Colors.black), borderRadius: BorderRadius.circular(3))
                          : null,
                      child: _ChordLabel(chord: chord, color: marked ? Colors.black : fg, size: 16),
                    ),
            ),
            if (_showDiagrams && chord != null)
              GestureDetector(
                onTap: () => _showChordSheet(chord, fg),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: ChordDiagram(chord: chord, instrument: ChordInstrument.guitar, foreground: fg, accent: _accent, width: 32),
                ),
              ),
            if (!verse.instrumental) Text(c.lyric, style: TextStyle(fontSize: 16, color: fg, height: 1.3)),
          ],
        ),
      ));
      if (verse.instrumental) cells.add(Text('  |  ', style: TextStyle(color: dim, fontSize: 16)));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells),
      ),
    );
  }
}

/// Chord name with the extension in a smaller raised font and an orange bass.
class _ChordLabel extends StatelessWidget {
  final String chord;
  final Color color;
  final double size;

  const _ChordLabel({required this.chord, required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    final p = chordDisplayParts(chord);
    return Text.rich(
      TextSpan(
        style: TextStyle(fontWeight: FontWeight.w700, color: color, fontSize: size),
        children: [
          TextSpan(text: p.root),
          if (p.degree.isNotEmpty)
            WidgetSpan(
              alignment: PlaceholderAlignment.top,
              child: Text(p.degree, style: TextStyle(fontWeight: FontWeight.w700, color: color, fontSize: size * 0.72)),
            ),
          if (p.bass.isNotEmpty) TextSpan(text: '/${p.bass}', style: const TextStyle(color: Color(0xFFFD7E14))),
        ],
      ),
    );
  }
}
