import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';

import '../services/chord_detector_service.dart';

// Chord diagram data (name → 6 strings: -1 muted, 0 open, 1-5 fret)
const Map<String, List<int>> _chordDiagrams = {
  'C': [-1, 3, 2, 0, 1, 0],
  'Cm': [-1, 3, 5, 5, 4, 3],
  'C7': [-1, 3, 2, 3, 1, 0],
  'Cm7': [-1, 3, 5, 3, 4, 3],
  'Cmaj7': [-1, 3, 2, 0, 0, 0],
  'D': [-1, -1, 0, 2, 3, 2],
  'Dm': [-1, -1, 0, 2, 3, 1],
  'D7': [-1, -1, 0, 2, 1, 2],
  'Dm7': [-1, -1, 0, 2, 1, 1],
  'E': [0, 2, 2, 1, 0, 0],
  'Em': [0, 2, 2, 0, 0, 0],
  'E7': [0, 2, 0, 1, 0, 0],
  'Em7': [0, 2, 2, 0, 3, 0],
  'F': [1, 3, 3, 2, 1, 1],
  'Fm': [1, 3, 3, 1, 1, 1],
  'F7': [1, 3, 1, 2, 1, 1],
  'Fm7': [1, 3, 1, 1, 1, 1],
  'G': [3, 2, 0, 0, 0, 3],
  'Gm': [3, 5, 5, 3, 3, 3],
  'G7': [3, 2, 0, 0, 0, 1],
  'Gm7': [3, 5, 3, 3, 3, 3],
  'Gmaj7': [3, 2, 0, 0, 0, 2],
  'A': [-1, 0, 2, 2, 2, 0],
  'Am': [-1, 0, 2, 2, 1, 0],
  'A7': [-1, 0, 2, 0, 2, 0],
  'Am7': [-1, 0, 2, 0, 1, 0],
  'B': [-1, 2, 4, 4, 4, 2],
  'Bm': [-1, 2, 4, 4, 3, 2],
  'B7': [-1, 2, 1, 2, 0, 2],
  'Bm7': [-1, 2, 4, 2, 3, 2],
};

class ChordDetectionScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback? onBack;
  final VoidCallback? onGoHome;

  const ChordDetectionScreen({
    super.key,
    required this.isDarkMode,
    this.onBack,
    this.onGoHome,
  });

  @override
  State<ChordDetectionScreen> createState() => _ChordDetectionScreenState();
}

class _ChordDetectionScreenState extends State<ChordDetectionScreen> {
  final FlutterAudioCapture _audioCapture = FlutterAudioCapture();
  static const double _minRms = 0.0022;
  static const int _minScore = 2;

  bool _listening = false;
  bool _processing = false;

  ChordMatch? _currentMatch;
  final List<String> _history = [];
  final List<_ChordFlowSegment> _flow = [];
  String _status = 'Başlatmak için mikrofon ikonuna bas';
  int _stage = 0; // 0: idle, 1: signal, 2: note parse, 3: stable chord

  // Buffer accumulator — collect multiple callbacks to fill fftSize
  final List<double> _accumulated = [];

  // Stability vote — require same chord N times before showing
  final List<String> _votes = [];
  static const int _voteWindow = 5;
  static const int _requiredVotes = 2;
  static const int _minSwitchMs = 320;
  String? _stableChord;
  int _lastStableAtMs = 0;
  int _lastGoodMatchAtMs = 0;

  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _stopListening();
    super.dispose();
  }

  Future<void> _startListening() async {
    if (_listening) return;
    _accumulated.clear();
    _votes.clear();
    try {
      await _audioCapture.init();
      await _audioCapture.start(
        _onBuffer,
        (err) {
          if (!mounted) return;
          setState(() => _status = 'Mikrofon hatası: $err');
        },
        sampleRate: ChordDetectorService.sampleRate,
        bufferSize: 4096,
      );
      _uiTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
        if (mounted) setState(() {});
      });
      if (!mounted) return;
      setState(() {
        _listening = true;
        _status = 'Dış ses dinleniyor…';
        _stage = 1;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Başlatılamadı: $e');
    }
  }

  Future<void> _stopListening() async {
    try {
      await _audioCapture.stop();
    } catch (_) {}
    _uiTimer?.cancel();
    _accumulated.clear();
    _votes.clear();
    if (!mounted) return;
    setState(() {
      _listening = false;
      _status = 'Dinleme durduruldu';
      _stage = 0;
    });
  }

  void _onBuffer(Float32List buffer) {
    if (_processing) return;
    _processing = true;
    try {
      // Accumulate samples until we have a full fftSize window
      _accumulated.addAll(buffer);
      if (_accumulated.length < ChordDetectorService.fftSize) return;

      final window = Float32List.fromList(
          _accumulated.take(ChordDetectorService.fftSize).toList());
      // Slide by half a window for overlap
      _accumulated.removeRange(0, ChordDetectorService.fftSize ~/ 2);

      final rms = _rms(window);
      if (rms < _minRms) {
        _votes.clear();
        final now = DateTime.now().millisecondsSinceEpoch;
        if (_stableChord != null && (now - _lastGoodMatchAtMs) < 1500) {
          _stage = 3;
          _status = '3/3 Sinyal dalgalı — dinleme sürüyor';
        } else {
          _stage = 1;
          _status = '1/3 Sinyal zayıf — mikrofona yaklaş';
        }
        return;
      }

      final match = ChordDetectorService.detect(window);
      if (!mounted) return;

      if (match != null && match.score >= _minScore) {
        _stage = 2;
        _lastGoodMatchAtMs = DateTime.now().millisecondsSinceEpoch;
        // Stability vote: add to recent detections
        _votes.add(match.name);
        if (_votes.length > _voteWindow) _votes.removeAt(0);

        // Show chord only if it appears in majority of vote window
        final counts = <String, int>{};
        for (final v in _votes) {
          counts[v] = (counts[v] ?? 0) + 1;
        }
        final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);

        final canAcceptQuickly =
            match.matchedCount >= 2 && match.extraCount <= 6;
        if (top.value >= _requiredVotes || canAcceptQuickly) {
          final now = DateTime.now().millisecondsSinceEpoch;
          final shouldSwitch = _stableChord == null ||
              _stableChord == top.key ||
              (now - _lastStableAtMs) >= _minSwitchMs;
          if (!shouldSwitch) {
            _status = '3/3 Stabilize ediliyor…';
            return;
          }

          final chosen = canAcceptQuickly ? match.name : top.key;
          _stableChord = chosen;
          _lastStableAtMs = now;
          _currentMatch = ChordMatch(
            name: chosen,
            root: match.root,
            type: match.type,
            score: match.score,
            matchedCount: match.matchedCount,
            extraCount: match.extraCount,
            detectedNotes: match.detectedNotes,
          );
          _stage = 3;
          _status = '3/3 Dış sesten akor bulundu';
          _appendFlow(chosen, now);
          if (_history.isEmpty || _history.first != chosen) {
            _history.insert(0, chosen);
            if (_history.length > 12) _history.removeLast();
          }
        } else {
          _status = '3/3 Stabilize ediliyor…';
        }
      } else {
        _votes.clear();
        final now = DateTime.now().millisecondsSinceEpoch;
        if (_stableChord != null && (now - _lastGoodMatchAtMs) < 1500) {
          _stage = 3;
          _status = '3/3 Sinyal izleniyor…';
        } else {
          _stage = 2;
          _status = '2/3 Nota ayrıştırılamadı — tek akor bas';
        }
      }
    } finally {
      _processing = false;
    }
  }

  void _clearHistory() => setState(() {
        _history.clear();
        _flow.clear();
        _currentMatch = null;
        _stableChord = null;
        _lastStableAtMs = 0;
        _stage = 1;
        _status = 'Dış ses dinleniyor';
      });

  void _appendFlow(String chord, int nowMs) {
    if (_flow.isEmpty) {
      _flow.add(
        _ChordFlowSegment(
          chord: chord,
          startedAtMs: nowMs,
          endedAtMs: nowMs,
          hits: 1,
        ),
      );
      return;
    }

    final last = _flow.last;
    if (last.chord == chord) {
      last.endedAtMs = nowMs;
      last.hits += 1;
      return;
    }

    if ((nowMs - last.endedAtMs) < 1200 && last.hits < 2) {
      last.chord = chord;
      last.endedAtMs = nowMs;
      last.hits += 1;
      return;
    }

    _flow.add(
      _ChordFlowSegment(
        chord: chord,
        startedAtMs: nowMs,
        endedAtMs: nowMs,
        hits: 1,
      ),
    );
    if (_flow.length > 40) {
      _flow.removeAt(0);
    }
  }

  String _formatElapsed(int ms) {
    final seconds = (ms / 1000).floor();
    final minutes = seconds ~/ 60;
    final remaining = seconds % 60;
    return '$minutes:${remaining.toString().padLeft(2, '0')}';
  }

  Map<String, int> _flowSummary() {
    final counts = <String, int>{};
    for (final segment in _flow) {
      counts[segment.chord] = (counts[segment.chord] ?? 0) + 1;
    }
    return counts;
  }

  double _rms(Float32List samples) {
    if (samples.isEmpty) return 0;
    var sum = 0.0;
    for (final s in samples) {
      sum += s * s;
    }
    return sqrt(sum / samples.length);
  }

  @override
  Widget build(BuildContext context) {
    final flowSummaryEntries = _flowSummary().entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final isDark = widget.isDarkMode;
    final bgA = isDark ? const Color(0xFF000000) : const Color(0xFFF4F6FA);
    final bgB = isDark ? const Color(0xFF0B0B0B) : const Color(0xFFE7ECF3);
    final cardColor =
        isDark ? const Color(0xFF131313) : const Color(0xFFFFFFFF);
    final borderColor =
        isDark ? const Color(0xFF2C2C2C) : const Color(0xFFD8DDE6);
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);
    final subColor = isDark ? const Color(0xFFB7C2D3) : const Color(0xFF6B7280);
    const accent = Color(0xFFFFC83D);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text(
          'Dış Sesten Akor Bul',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        leading: IconButton(
          onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          IconButton(
            onPressed: widget.onGoHome,
            icon: const Icon(Icons.home_rounded),
            tooltip: 'Ana sayfa',
          ),
          IconButton(
            onPressed: _history.isNotEmpty ? _clearHistory : null,
            icon: const Icon(Icons.clear_all),
            tooltip: 'Geçmişi temizle',
          ),
          IconButton(
            onPressed: _listening ? _stopListening : _startListening,
            icon: Icon(_listening ? Icons.mic : Icons.mic_off),
            tooltip: _listening ? 'Durdur' : 'Başlat',
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bgA, bgB],
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // ── Main chord display ──────────────────────────────────
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: borderColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                children: [
                  GestureDetector(
                    onTap: _listening ? _stopListening : _startListening,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _listening ? Icons.mic : Icons.mic_off,
                          color: _listening ? accent : subColor,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _status,
                          style: TextStyle(
                            color: _listening ? accent : subColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Hoparlöre veya dışarıda çalan kaynağa yakın tut.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: subColor, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  _StageRow(
                    stage: _stage,
                    isDark: isDark,
                    accent: accent,
                    subColor: subColor,
                  ),
                  const SizedBox(height: 16),
                  if (_currentMatch != null) ...[
                    Text(
                      _currentMatch!.name,
                      style: TextStyle(
                        color: accent,
                        fontSize: 72,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Algılanan notalar: ${_currentMatch!.detectedNotes.join(' · ')}',
                      style: TextStyle(color: subColor, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    // Chord diagram
                    if (_chordDiagrams.containsKey(_currentMatch!.name))
                      SizedBox(
                        height: 160,
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 32),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF0D0D0D)
                                : const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: borderColor),
                          ),
                          child: CustomPaint(
                            painter: _ChordBoxPainter(
                              strings: _chordDiagrams[_currentMatch!.name]!,
                              isDark: isDark,
                            ),
                          ),
                        ),
                      ),
                  ] else
                    Column(
                      children: [
                        Icon(Icons.music_note_rounded,
                            size: 56, color: subColor.withValues(alpha: 0.4)),
                        const SizedBox(height: 8),
                        Text(
                          'Dışarıda çalan şarkıyı dinlet',
                          style: TextStyle(color: subColor, fontSize: 15),
                        ),
                      ],
                    ),
                ],
              ),
            ),

            if (_flow.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                'Akor Akışı',
                style: TextStyle(
                  color: titleColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  children: _flow.reversed.take(10).map((segment) {
                    final lengthMs = max(
                      1000,
                      segment.endedAtMs - segment.startedAtMs,
                    );
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Container(
                            width: 54,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: accent.withValues(alpha: 0.28),
                              ),
                            ),
                            child: Text(
                              segment.chord,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: accent,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Başlangıç: ${_formatElapsed(segment.startedAtMs - _flow.first.startedAtMs)}',
                                  style: TextStyle(
                                    color: titleColor,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  'Süre: ${_formatElapsed(lengthMs)}',
                                  style:
                                      TextStyle(color: subColor, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],

            // ── History ─────────────────────────────────────────────
            if (_history.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                'Geçmiş',
                style: TextStyle(
                  color: titleColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: flowSummaryEntries
                    .take(min(6, flowSummaryEntries.length))
                    .map((entry) {
                  final name = entry.key;
                  final isLatest = name == _history.first;
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _currentMatch = ChordMatch(
                          name: name,
                          root: '',
                          type: '',
                          score: 0,
                          matchedCount: 0,
                          extraCount: 0,
                          detectedNotes: const [],
                        );
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isLatest
                            ? accent.withValues(alpha: 0.15)
                            : cardColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isLatest ? accent : borderColor,
                        ),
                      ),
                      child: Text(
                        '$name (${entry.value})',
                        style: TextStyle(
                          color: isLatest ? accent : titleColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],

            // ── Usage tip ────────────────────────────────────────────
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderColor),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: subColor, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Bu ekran dışarıdan gelen seste yaklaşık akor tahmini yapar. '
                      'Akustik, sade ve temiz kayıtlarda daha doğru sonuç verir.',
                      style: TextStyle(color: subColor, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StageRow extends StatelessWidget {
  final int stage;
  final bool isDark;
  final Color accent;
  final Color subColor;

  const _StageRow({
    required this.stage,
    required this.isDark,
    required this.accent,
    required this.subColor,
  });

  @override
  Widget build(BuildContext context) {
    final steps = <String>[
      '1. Sinyal',
      '2. Nota',
      '3. Stabil Akor',
    ];
    return Row(
      children: List.generate(steps.length, (i) {
        final idx = i + 1;
        final done = stage >= idx;
        return Expanded(
          child: Container(
            margin: EdgeInsets.only(right: i == steps.length - 1 ? 0 : 8),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: done
                  ? accent.withValues(alpha: 0.16)
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : const Color(0xFFE5E7EB)),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: done
                    ? accent.withValues(alpha: 0.9)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : const Color(0xFFD1D5DB)),
              ),
            ),
            child: Text(
              steps[i],
              textAlign: TextAlign.center,
              style: TextStyle(
                color: done ? accent : subColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _ChordFlowSegment {
  String chord;
  final int startedAtMs;
  int endedAtMs;
  int hits;

  _ChordFlowSegment({
    required this.chord,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.hits,
  });
}

// ── Chord diagram painter ─────────────────────────────────────────────────────

class _ChordBoxPainter extends CustomPainter {
  final List<int> strings;
  final bool isDark;

  _ChordBoxPainter({required this.strings, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = isDark ? const Color(0xFF3D3D3D) : const Color(0xFF8A94A6)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final nut = Paint()
      ..color = isDark ? const Color(0xFF8B8B8B) : const Color(0xFF4B5563)
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = const Color(0xFFFFC83D)
      ..style = PaintingStyle.fill;

    final xoStyle = TextStyle(
      color: isDark ? Colors.white : const Color(0xFF1F2937),
      fontSize: 12,
      fontWeight: FontWeight.w800,
    );

    const stringsCount = 6;
    const fretsCount = 5;

    final left = size.width * 0.12;
    final right = size.width * 0.88;
    final top = size.height * 0.26;
    final bottom = size.height * 0.88;

    final stringGap = (right - left) / (stringsCount - 1);
    final fretGap = (bottom - top) / (fretsCount - 1);

    // Vertical string lines
    for (int s = 0; s < stringsCount; s++) {
      final x = left + stringGap * s;
      canvas.drawLine(Offset(x, top), Offset(x, bottom), grid);
    }
    // Horizontal fret lines
    for (int f = 0; f < fretsCount; f++) {
      final y = top + fretGap * f;
      canvas.drawLine(Offset(left, y), Offset(right, y), grid);
    }
    // Nut
    canvas.drawLine(Offset(left, top), Offset(right, top), nut);

    // X / O markers above nut
    for (int s = 0; s < stringsCount; s++) {
      final state = s < strings.length ? strings[s] : -1;
      final text = state < 0 ? 'X' : (state == 0 ? 'O' : '');
      if (text.isEmpty) continue;
      final tp = TextPainter(
        text: TextSpan(text: text, style: xoStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = left + stringGap * s - tp.width / 2;
      final y = top - tp.height - 4;
      tp.paint(canvas, Offset(x, y));
    }

    // Fret dots
    for (int s = 0; s < stringsCount; s++) {
      final fret = s < strings.length ? strings[s] : -1;
      if (fret <= 0) continue;
      final x = left + stringGap * s;
      final y = top + fretGap * (fret - 0.5);
      canvas.drawCircle(Offset(x, y), 7, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ChordBoxPainter old) =>
      old.isDark != isDark || old.strings != strings;
}
