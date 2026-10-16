import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../chord_ai/chord_ai_service.dart';
import '../chord_ai/chord_analyzer.dart';
import '../chord_ai/chord_theory.dart';
import '../chord_ai/widgets/chord_diagram.dart';

/// Chord ai–style song view: analyses an audio file on device and shows the
/// chord grid in sync with playback, with transpose, capo suggestion, speed,
/// bar looping and chord editing.
class ChordAnalysisScreen extends StatefulWidget {
  final String audioPath;
  final String title;

  const ChordAnalysisScreen({super.key, required this.audioPath, required this.title});

  @override
  State<ChordAnalysisScreen> createState() => _ChordAnalysisScreenState();
}

// Circle-of-fifths colours for chord cells (from Chord ai's palette).
const List<Color> _fifthColors = [
  Color(0xFF174477), Color(0xFF255082), Color(0xFF2660A2), Color(0xFF2E74A6),
  Color(0xFF2A6F97), Color(0xFF2C7DA0), Color(0xFF468FAF), Color(0xFF61A5C2),
  Color(0xFF89C2D9), Color(0xFF76ABBB), Color(0xFF79BCC0), Color(0xFF7BBFC3),
];
const Color _accent = Color(0xFFFFC83D);
const double _barHeight = 64;
const double _barGap = 8;

Color _chordColor(String name) {
  final c = parseChord(name);
  return c == null ? Colors.transparent : _fifthColors[fifthsIndex(c.root)];
}

class _ChordAnalysisScreenState extends State<ChordAnalysisScreen> {
  final AudioPlayer _player = AudioPlayer();
  final ScrollController _gridScroll = ScrollController();
  final List<StreamSubscription<Object?>> _subs = [];

  ChordAnalysis? _analysis;
  String? _error;
  double _progress = 0;
  String _progressLabel = 'Hazırlanıyor';

  Duration _position = Duration.zero;
  bool _playing = false;
  int _beat = -1;
  int _transpose = 0;
  int _capo = 0;
  int _beatsPerBar = 4;
  int? _downbeat;
  double _speed = 1;
  ChordInstrument _instrument = ChordInstrument.guitar;
  bool _showNumerals = false;
  bool _loopOn = false;
  (int, int)? _loop; // inclusive bar range
  DateTime _userScrolledAt = DateTime.fromMillisecondsSinceEpoch(0);
  List<ChordBar> _bars = const [];

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    _subs.add(_player.positionStream.listen(_onPosition));
    _subs.add(_player.playingStream.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
      p ? WakelockPlus.enable() : WakelockPlus.disable();
    }));
    _subs.add(_player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) _player.pause();
    }));
    _load();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    _gridScroll.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _error = null;
      _progress = 0;
      _progressLabel = 'Hazırlanıyor';
      if (force) _analysis = null;
    });
    try {
      unawaited(_player.setFilePath(widget.audioPath).catchError((_) => null));
      final cached = force ? null : await ChordAiService.instance.cached(widget.audioPath);
      final analysis = cached ??
          await ChordAiService.instance.analyze(
            widget.audioPath,
            chordSet: _analysis?.chordSet ?? ChordSet.basic,
            onProgress: (f, label) {
              if (!mounted) return;
              setState(() {
                _progress = f;
                _progressLabel = label;
              });
            },
          );
      if (!mounted) return;
      setState(() {
        _analysis = analysis;
        _capo = 0;
        _rebuildBars();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is FormatException ? e.message : (e is UnsupportedError ? '${e.message}' : '$e'));
    }
  }

  bool get _flats {
    final a = _analysis;
    return a != null && a.key.transposed(_transpose).usesFlats;
  }

  void _rebuildBars() {
    final a = _analysis;
    if (a == null) return;
    _bars = buildBars(a, beatsPerBar: _beatsPerBar, downbeat: _downbeat, transpose: _transpose, capo: _capo, flats: _flats);
    _beat = -1;
  }

  void _onPosition(Duration pos) {
    final a = _analysis;
    if (!mounted || a == null) return;
    final t = pos.inMicroseconds / 1e6;
    if (_loopOn && _loop != null && _playing) {
      final (start, end) = _loopTimes();
      if (t >= end || t < start - 0.25) {
        _player.seek(Duration(microseconds: (start * 1e6).round()));
        return;
      }
    }
    final k = beatIndexAt(a.beats, t);
    setState(() => _position = pos);
    if (k != _beat) {
      setState(() => _beat = k);
      _autoScroll();
    }
  }

  (double, double) _loopTimes() {
    final a = _analysis!;
    final (s, e) = _loop!;
    final lastBeat = _bars[e].beats.last.beat;
    return (_bars[s].beats.first.time, lastBeat + 1 < a.beats.length ? a.beats[lastBeat + 1] : a.duration);
  }

  int _barOfBeat(int beat) {
    for (final b in _bars) {
      if (b.beats.isNotEmpty && beat >= b.beats.first.beat && beat <= b.beats.last.beat) return b.index;
    }
    return 0;
  }

  int get _columns => MediaQuery.of(context).size.width >= 700 ? 4 : 2;

  void _autoScroll() {
    if (!_playing || !_gridScroll.hasClients || _beat < 0) return;
    if (DateTime.now().difference(_userScrolledAt).inMilliseconds < 2500) return;
    final row = _barOfBeat(_beat) ~/ _columns;
    final target = row * (_barHeight + _barGap) - _gridScroll.position.viewportDimension / 2 + _barHeight;
    final clamped = target.clamp(0.0, _gridScroll.position.maxScrollExtent);
    if ((clamped - _gridScroll.offset).abs() > 4) {
      _gridScroll.animateTo(clamped, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
    }
  }

  Future<void> _seekTo(double seconds) async {
    await _player.seek(Duration(microseconds: (seconds.clamp(0, _analysis?.duration ?? 0) * 1e6).round()));
  }

  void _togglePlay() => _playing ? _player.pause() : _player.play();

  void _setChordSet(ChordSet set) {
    final a = _analysis;
    if (a == null || a.chordSet == set) return;
    setState(() {
      _analysis = a.withChordSet(set);
      _rebuildBars();
    });
    ChordAiService.instance.save(widget.audioPath, _analysis!);
  }

  Future<void> _editChord(BeatCell cell) async {
    final a = _analysis!;
    final ctrl = TextEditingController(text: cell.name == 'N' ? '' : cell.name);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Akoru düzenle'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Örn. Am, F#m7, Bb/D (boş = akor yok)'),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            const SizedBox(height: 8),
            Text('Transpoze ve kapo dikkate alınır.', style: Theme.of(ctx).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Kaydet')),
        ],
      ),
    );
    if (value == null || !mounted) return;
    final typed = value.replaceAll(' ', '');
    if (typed.isNotEmpty && parseChord(typed) == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Bilinmeyen akor')));
      return;
    }
    // Store in sounding pitch: undo the display transpose/capo shift.
    final stored = typed.isEmpty ? 'N' : transposeChord(typed, _capo - _transpose);
    setState(() {
      _analysis = a.withEditedChord(cell.beat, stored);
      _rebuildBars();
    });
    await ChordAiService.instance.save(widget.audioPath, _analysis!);
  }

  void _onBeatTap(BeatCell cell, int barIndex) {
    if (_loopOn && _loop != null) {
      final (s, e) = _loop!;
      setState(() => _loop = barIndex < s ? (barIndex, e) : (s, barIndex));
    }
    _seekTo(cell.time + 0.001);
  }

  void _toggleLoop() {
    setState(() {
      _loopOn = !_loopOn;
      if (_loopOn) {
        final bar = _barOfBeat(_beat < 0 ? 0 : _beat);
        _loop = (bar, bar);
      }
    });
    if (_loopOn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Döngü açık. Aralığı genişletmek için başka bir ölçüye dokun.')),
      );
    }
  }

  Future<void> _share() async {
    final a = _analysis!;
    final key = a.key.transposed(_transpose);
    final buf = StringBuffer()
      ..writeln('{title: ${widget.title}}')
      ..writeln('{key: ${key.name(flats: _flats)}}')
      ..writeln('{tempo: ${a.bpm.round()}}');
    if (_capo > 0) buf.writeln('{capo: $_capo}');
    buf.writeln();
    for (var i = 0; i < _bars.length; i += 4) {
      final row = _bars.skip(i).take(4).map((b) => b.beats.map((c) => c.change ? '[${c.name}]' : '.').join(' '));
      buf.writeln('| ${row.join(' | ')} |');
    }
    await Share.share(buf.toString(), subject: '${widget.title} akorları');
  }

  List<ChordSpan> get _soundingSpans =>
      _analysis!.chords.map((c) => ChordSpan(displayChord(c.name, transpose: _transpose), c.start, c.end)).toList();

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final bg = _isDark ? const Color(0xFF0F1115) : const Color(0xFFF4F6FA);
    final a = _analysis;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        titleSpacing: 0,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        actions: a == null
            ? null
            : [
                IconButton(tooltip: 'Akorları paylaş', onPressed: _share, icon: const Icon(Icons.ios_share_rounded)),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    switch (v) {
                      case 'basic':
                        _setChordSet(ChordSet.basic);
                      case 'full':
                        _setChordSet(ChordSet.full);
                      case 'numerals':
                        setState(() => _showNumerals = !_showNumerals);
                      case 'downbeat':
                        setState(() {
                          _downbeat = ((_downbeat ?? a.downbeat) + 1) % _beatsPerBar;
                          _rebuildBars();
                        });
                      case 'reanalyze':
                        _load(force: true);
                    }
                  },
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(value: 'basic', checked: a.chordSet == ChordSet.basic, child: const Text('Temel akorlar')),
                    CheckedPopupMenuItem(
                        value: 'full', checked: a.chordSet == ChordSet.full, child: const Text('Tüm akorlar (7, sus, dim, çevrim)')),
                    const PopupMenuDivider(),
                    CheckedPopupMenuItem(value: 'numerals', checked: _showNumerals, child: const Text('Dereceleri göster')),
                    const PopupMenuItem(value: 'downbeat', child: Text('Ölçü başını kaydır')),
                    const PopupMenuItem(value: 'reanalyze', child: Text('Yeniden analiz et')),
                  ],
                ),
              ],
      ),
      body: a == null ? _buildLoading() : _buildSong(a),
      bottomNavigationBar: a == null ? null : _buildTransport(a),
    );
  }

  Widget _buildLoading() {
    final fg = _isDark ? Colors.white : const Color(0xFF111827);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: _error != null
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline_rounded, color: _accent, size: 44),
                const SizedBox(height: 12),
                Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: fg)),
                const SizedBox(height: 16),
                FilledButton(onPressed: () => _load(force: true), child: const Text('Tekrar dene')),
              ])
            : Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.graphic_eq_rounded, color: _accent, size: 48),
                const SizedBox(height: 16),
                Text(_progressLabel, style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: _progress <= 0 ? null : _progress, minHeight: 6, color: _accent),
                ),
                const SizedBox(height: 12),
                Text('Analiz tamamen cihazında yapılır.', style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 12)),
              ]),
      ),
    );
  }

  Widget _buildSong(ChordAnalysis a) {
    final fg = _isDark ? Colors.white : const Color(0xFF111827);
    final sub = _isDark ? const Color(0xFFB7C2D3) : const Color(0xFF6B7280);
    final key = a.key.transposed(_transpose);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            _chip('Ton', key.name(flats: _flats)),
            _chip('BPM', '~${a.bpm.round()}'),
            _chip('Ölçü', '$_beatsPerBar/4'),
            if (a.tuningCents.abs() >= 5) _chip('Akort', '${a.tuningCents > 0 ? '+' : ''}${a.tuningCents} sent'),
            if (_capo > 0) _chip('Kapo', '$_capo', highlight: true),
          ]),
        ),
        _buildDiagramStrip(a, fg),
        const SizedBox(height: 6),
        Expanded(
          child: NotificationListener<UserScrollNotification>(
            onNotification: (_) {
              _userScrolledAt = DateTime.now();
              return false;
            },
            child: GridView.builder(
              controller: _gridScroll,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columns,
                mainAxisExtent: _barHeight,
                mainAxisSpacing: _barGap,
                crossAxisSpacing: _barGap,
              ),
              itemCount: _bars.length,
              itemBuilder: (_, i) => _buildBar(_bars[i], key, fg, sub),
            ),
          ),
        ),
      ],
    );
  }

  Widget _chip(String label, String value, {bool highlight = false}) {
    final fg = _isDark ? Colors.white : const Color(0xFF111827);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: highlight ? _accent : (_isDark ? Colors.white.withValues(alpha: 0.07) : Colors.white),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text.rich(TextSpan(children: [
        TextSpan(text: '$label ', style: TextStyle(color: highlight ? Colors.black : fg.withValues(alpha: 0.6), fontSize: 12)),
        TextSpan(text: value, style: TextStyle(color: highlight ? Colors.black : fg, fontSize: 12, fontWeight: FontWeight.w800)),
      ])),
    );
  }

  Widget _buildDiagramStrip(ChordAnalysis a, Color fg) {
    final t = _position.inMicroseconds / 1e6;
    final chords = a.chords;
    var i = 0;
    for (var k = 0; k < chords.length; k++) {
      if (chords[k].start <= t) i = k;
    }
    final card = _isDark ? const Color(0xFF16181D) : Colors.white;
    return SizedBox(
      height: 150,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (var k = i - 1; k <= i + 3; k++)
            if (k >= 0 && k < chords.length)
              _diagramCard(displayChord(chords[k].name, transpose: _transpose, capo: _capo, flats: _flats), k == i, k < i, card, fg),
        ],
      ),
    );
  }

  Widget _diagramCard(String name, bool current, bool past, Color card, Color fg) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: past ? 0.45 : 1,
      child: Container(
        width: 104,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
        decoration: BoxDecoration(
          color: card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: current ? _accent : fg.withValues(alpha: 0.08), width: current ? 2 : 1),
        ),
        child: Column(children: [
          Text(name == 'N' ? '—' : name,
              style: TextStyle(color: current ? _accent : fg, fontSize: current ? 20 : 16, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Expanded(
            child: FittedBox(
              child: ChordDiagram(
                chord: name,
                instrument: _instrument,
                foreground: fg,
                accent: current ? _accent : fg,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildBar(ChordBar bar, MusicKey key, Color fg, Color sub) {
    final inLoop = _loopOn && _loop != null && bar.index >= _loop!.$1 && bar.index <= _loop!.$2;
    final card = _isDark ? const Color(0xFF16181D) : Colors.white;
    final cells = <Widget>[];
    for (var i = 0; i < _beatsPerBar; i++) {
      if (i >= bar.beats.length) {
        cells.add(const Expanded(child: SizedBox()));
        continue;
      }
      final cell = bar.beats[i];
      final now = cell.beat == _beat;
      final numeral = _showNumerals && cell.change && cell.name != 'N'
          ? romanNumeral(transposeChord(cell.name, _capo), key)
          : '';
      cells.add(Expanded(
        child: GestureDetector(
          onTap: () => _onBeatTap(cell, bar.index),
          onLongPress: () => _editChord(cell),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              color: now
                  ? _accent.withValues(alpha: cell.change ? 1 : 0.35)
                  : (cell.change && cell.name != 'N' ? _chordColor(cell.name) : Colors.transparent),
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: cell.change
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    FittedBox(
                      child: Text(cell.name == 'N' ? '–' : cell.name,
                          style: TextStyle(
                              color: now ? Colors.black : (cell.name == 'N' ? sub : Colors.white),
                              fontWeight: FontWeight.w900,
                              fontSize: 15)),
                    ),
                    if (numeral.isNotEmpty)
                      Text(numeral, style: TextStyle(color: now ? Colors.black87 : Colors.white70, fontSize: 10)),
                  ])
                : Container(width: 4, height: 4, decoration: BoxDecoration(color: sub.withValues(alpha: 0.35), shape: BoxShape.circle)),
          ),
        ),
      ));
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
      decoration: BoxDecoration(
        color: inLoop ? _accent.withValues(alpha: 0.14) : card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: inLoop ? _accent : fg.withValues(alpha: 0.06)),
      ),
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(top: -12, left: 4, child: Text('${bar.index + 1}', style: TextStyle(color: sub, fontSize: 9))),
        Row(children: cells),
      ]),
    );
  }

  Widget _buildTransport(ChordAnalysis a) {
    final fg = _isDark ? Colors.white : const Color(0xFF111827);
    final bar = _isDark ? const Color(0xFF111111) : Colors.white;
    final best = _instrument == ChordInstrument.guitar ? suggestCapo(_soundingSpans).first : null;
    final t = _position.inMicroseconds / 1e6;
    String clock(double s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(color: bar, border: Border(top: BorderSide(color: fg.withValues(alpha: 0.08)))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          GestureDetector(
            onTapDown: (d) => _seekFromWave(d.localPosition.dx, context),
            onHorizontalDragUpdate: (d) => _seekFromWave(d.localPosition.dx, context),
            child: CustomPaint(
              size: const Size(double.infinity, 42),
              painter: _WavePainter(a.peaks, a.duration <= 0 ? 0 : t / a.duration, _loopOn && _loop != null ? _loopFraction(a) : null, fg),
            ),
          ),
          Row(children: [
            SizedBox(width: 72, child: Text('${clock(t)} / ${clock(a.duration)}', style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 11))),
            const Spacer(),
            IconButton(onPressed: () => _seekTo(t - 5), icon: const Icon(Icons.replay_5_rounded), color: fg),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: _togglePlay,
              style: FilledButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.black, shape: const CircleBorder(), padding: const EdgeInsets.all(14)),
              child: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30),
            ),
            const SizedBox(width: 4),
            IconButton(onPressed: () => _seekTo(t + 5), icon: const Icon(Icons.forward_5_rounded), color: fg),
            const Spacer(),
            SizedBox(
              width: 72,
              child: Text(_beat < 0 ? '' : 'Ölçü ${_barOfBeat(_beat) + 1}', textAlign: TextAlign.right, style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 11)),
            ),
          ]),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _stepper('Transpoze', _transpose > 0 ? '+$_transpose' : '$_transpose', () => _setTranspose(_transpose - 1), () => _setTranspose(_transpose + 1)),
              _stepper('Kapo', '$_capo', () => _setCapo(_capo - 1), () => _setCapo(_capo + 1)),
              if (best != null && best.capo != _capo)
                _pill(best.capo == 0 ? 'Önerilen: kapo yok' : 'Önerilen kapo: ${best.capo}', () => _setCapo(best.capo), color: const Color(0xFF506D6C)),
              _menuPill<double>('Hız ${_speed}x', const [0.5, 0.75, 0.9, 1.0, 1.1, 1.25], (v) => '${v}x', (v) {
                setState(() => _speed = v);
                _player.setSpeed(v);
              }),
              _menuPill<ChordInstrument>(_instrument.label, ChordInstrument.values, (v) => v.label, (v) => setState(() => _instrument = v)),
              _menuPill<int>('$_beatsPerBar/4', const [2, 3, 4, 6], (v) => '$v/4', (v) => setState(() {
                    _beatsPerBar = v;
                    _rebuildBars();
                  })),
              _pill('Döngü', _toggleLoop, active: _loopOn),
            ]),
          ),
        ]),
      ),
    );
  }

  (double, double) _loopFraction(ChordAnalysis a) {
    final (s, e) = _loopTimes();
    return (s / a.duration, e / a.duration);
  }

  void _seekFromWave(double dx, BuildContext context) {
    final a = _analysis;
    if (a == null) return;
    final width = MediaQuery.of(context).size.width - 24;
    _seekTo((dx / width).clamp(0.0, 1.0) * a.duration);
  }

  void _setTranspose(int v) => setState(() {
        _transpose = v.clamp(-11, 11);
        _rebuildBars();
      });

  void _setCapo(int v) => setState(() {
        _capo = v.clamp(0, 11);
        _rebuildBars();
      });

  Widget _stepper(String label, String value, VoidCallback dec, VoidCallback inc) {
    final fg = _isDark ? Colors.white : const Color(0xFF111827);
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(color: fg.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Text(label, style: TextStyle(color: fg.withValues(alpha: 0.65), fontSize: 12)),
        IconButton(visualDensity: VisualDensity.compact, onPressed: dec, icon: const Icon(Icons.remove_rounded, size: 18), color: fg),
        Text(value, style: TextStyle(color: fg, fontWeight: FontWeight.w800)),
        IconButton(visualDensity: VisualDensity.compact, onPressed: inc, icon: const Icon(Icons.add_rounded, size: 18), color: fg),
      ]),
    );
  }

  Widget _pill(String label, VoidCallback onTap, {bool active = false, Color? color}) {
    final fg = _isDark ? Colors.white : const Color(0xFF111827);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: active ? _accent : (color ?? fg.withValues(alpha: 0.06)),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Text(label,
                style: TextStyle(color: active ? Colors.black : (color != null ? Colors.white : fg), fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ),
      ),
    );
  }

  Widget _menuPill<T>(String label, List<T> values, String Function(T) text, ValueChanged<T> onSelected) {
    return PopupMenuButton<T>(
      onSelected: onSelected,
      itemBuilder: (_) => [for (final v in values) PopupMenuItem(value: v, child: Text(text(v)))],
      child: IgnorePointer(child: _pill('$label ▾', () {})),
    );
  }
}

class _WavePainter extends CustomPainter {
  final Float32List peaks;
  final double progress;
  final (double, double)? loop;
  final Color fg;

  _WavePainter(this.peaks, this.progress, this.loop, this.fg);

  @override
  void paint(Canvas canvas, Size size) {
    if (loop != null) {
      canvas.drawRect(
        Rect.fromLTRB(loop!.$1 * size.width, 0, loop!.$2 * size.width, size.height),
        Paint()..color = _accent.withValues(alpha: 0.18),
      );
    }
    var maxV = 0.0;
    for (final v in peaks) {
      if (v > maxV) maxV = v;
    }
    if (maxV <= 0) maxV = 1;
    final step = size.width / peaks.length;
    final played = Paint()..color = _accent;
    final rest = Paint()..color = fg.withValues(alpha: 0.25);
    final pos = progress * size.width;
    for (var i = 0; i < peaks.length; i++) {
      final x = i * step;
      final h = (peaks[i] / maxV) * (size.height / 2 - 2);
      canvas.drawRect(Rect.fromLTWH(x, size.height / 2 - h, step < 1.2 ? 1 : step - 0.4, h * 2 + 1), x <= pos ? played : rest);
    }
    canvas.drawRect(Rect.fromLTWH(pos - 1, 0, 2, size.height), Paint()..color = fg);
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => old.progress != progress || old.loop != loop || old.peaks != peaks;
}
