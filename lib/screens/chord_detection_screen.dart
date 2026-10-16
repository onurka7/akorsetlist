import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';

import '../chord_ai/chord_analyzer.dart';
import '../chord_ai/chord_theory.dart';
import '../chord_ai/widgets/chord_diagram.dart';
import 'chord_analysis_screen.dart';

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
  static const int _captureRate = 44100;
  static const double _minLevel = 0.002;

  // Same NNLS chroma + chord templates as the offline analyzer, with
  // smoothing and a three-frame hysteresis before a chord is accepted.
  final LiveChordTracker _tracker = LiveChordTracker(sampleRate: _captureRate);

  bool _listening = false;

  String? _currentChord;
  List<String> _detectedNotes = const [];
  final List<String> _history = [];
  final List<_ChordFlowSegment> _flow = [];
  String _status = 'Başlatmak için mikrofon ikonuna bas';
  int _stage = 0; // 0: idle, 1: signal, 2: note parse, 3: stable chord
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
    _tracker.reset();
    try {
      await _audioCapture.init();
      await _audioCapture.start(
        _onBuffer,
        (err) {
          if (!mounted) return;
          setState(() => _status = 'Mikrofon hatası: $err');
        },
        sampleRate: _captureRate,
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
    _tracker.reset();
    if (!mounted) return;
    setState(() {
      _listening = false;
      _status = 'Dinleme durduruldu';
      _stage = 0;
    });
  }

  void _onBuffer(Float32List buffer) {
    final guess = _tracker.addSamples(buffer);
    if (!mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_tracker.level < _minLevel) {
      if (_currentChord != null && (now - _lastGoodMatchAtMs) < 1500) {
        _stage = 3;
        _status = '3/3 Sinyal dalgalı — dinleme sürüyor';
      } else {
        _stage = 1;
        _status = '1/3 Sinyal zayıf — mikrofona yaklaş';
      }
      return;
    }
    _detectedNotes = _tracker.activeNotes();
    if (_tracker.current != 'N') _lastGoodMatchAtMs = now;
    if (guess == null) {
      if (_stage < 2) {
        _stage = 2;
        _status = '2/3 Notalar ayrıştırılıyor…';
      }
      return;
    }
    if (guess.name == 'N') {
      _stage = 2;
      _status = '2/3 Akor seçilemedi — tek akor bas';
      return;
    }
    _currentChord = guess.name;
    _stage = 3;
    _status = '3/3 Dış sesten akor bulundu';
    _appendFlow(guess.name, now);
    if (_history.isEmpty || _history.first != guess.name) {
      _history.insert(0, guess.name);
      if (_history.length > 12) _history.removeLast();
    }
  }

  Future<void> _analyzeFile() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'm4a', 'aac'],
    );
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    if (_listening) await _stopListening();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChordAnalysisScreen(audioPath: path, title: picked!.files.single.name),
    ));
  }

  void _clearHistory() => setState(() {
        _history.clear();
        _flow.clear();
        _currentChord = null;
        _tracker.reset();
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
            onPressed: _analyzeFile,
            icon: const Icon(Icons.audio_file_rounded),
            tooltip: 'Dosyadan analiz et',
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
                  const SizedBox(height: 12),
                  SegmentedButton<ChordSet>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: ChordSet.basic, label: Text('Temel')),
                      ButtonSegment(value: ChordSet.full, label: Text('Hepsi')),
                    ],
                    selected: {_tracker.chordSet},
                    onSelectionChanged: (v) => setState(() => _tracker.chordSet = v.first),
                  ),
                  const SizedBox(height: 16),
                  if (_currentChord != null) ...[
                    Text(
                      _currentChord!,
                      style: TextStyle(
                        color: accent,
                        fontSize: 72,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _detectedNotes.isEmpty ? ' ' : 'Algılanan notalar: ${_detectedNotes.join(' · ')}',
                      style: TextStyle(color: subColor, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    // Chord diagram
                    Container(
                      height: 170,
                      margin: const EdgeInsets.symmetric(horizontal: 32),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF0D0D0D)
                            : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: borderColor),
                      ),
                      child: FittedBox(
                        child: ChordDiagram(
                          chord: _currentChord!,
                          instrument: ChordInstrument.guitar,
                          foreground: titleColor,
                          accent: accent,
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
                      setState(() => _currentChord = name);
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
