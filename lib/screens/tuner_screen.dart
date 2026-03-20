import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'package:pitch_detector_dart/pitch_detector.dart';

class TunerScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback? onBack;
  final VoidCallback? onGoHome;

  const TunerScreen({
    super.key,
    required this.isDarkMode,
    this.onBack,
    this.onGoHome,
  });

  @override
  State<TunerScreen> createState() => _TunerScreenState();
}

class _TunerScreenState extends State<TunerScreen> {
  final FlutterAudioCapture _audioCapture = FlutterAudioCapture();
  static const int _sampleRate = 44100;
  static const int _analysisWindow = 4096;
  static const double _minRms = 0.008;
  final PitchDetector _pitchDetector = PitchDetector(
    audioSampleRate: _sampleRate.toDouble(),
    bufferSize: _analysisWindow,
  );

  bool _listening = false;
  bool _processing = false;

  String _instrument = 'Gitar';
  String _preset = 'Standart (EADGBE)';
  int _selectedString = 0;

  double? _detectedHz;
  String _detectedNote = '-';
  double _cents = 0;
  String _status = 'Dinlemeye hazır';

  Timer? _uiTimer;
  final List<double> _accumulated = <double>[];

  final Map<String, Map<String, List<_StringTarget>>> _instrumentPresets = {
    'Gitar': {
      'Standart (EADGBE)': const [
        _StringTarget(label: '6', note: 'E2', frequency: 82.41),
        _StringTarget(label: '5', note: 'A2', frequency: 110.00),
        _StringTarget(label: '4', note: 'D3', frequency: 146.83),
        _StringTarget(label: '3', note: 'G3', frequency: 196.00),
        _StringTarget(label: '2', note: 'B3', frequency: 246.94),
        _StringTarget(label: '1', note: 'E4', frequency: 329.63),
      ],
      'Drop D (DADGBE)': const [
        _StringTarget(label: '6', note: 'D2', frequency: 73.42),
        _StringTarget(label: '5', note: 'A2', frequency: 110.00),
        _StringTarget(label: '4', note: 'D3', frequency: 146.83),
        _StringTarget(label: '3', note: 'G3', frequency: 196.00),
        _StringTarget(label: '2', note: 'B3', frequency: 246.94),
        _StringTarget(label: '1', note: 'E4', frequency: 329.63),
      ],
    },
    'Baglama': {
      'Baglama Duzeni (La-Re-Sol)': const [
        _StringTarget(label: '7', note: 'A2', frequency: 110.00),
        _StringTarget(label: '6', note: 'A3', frequency: 220.00),
        _StringTarget(label: '5', note: 'D3', frequency: 146.83),
        _StringTarget(label: '4', note: 'D4', frequency: 293.66),
        _StringTarget(label: '3', note: 'G3', frequency: 196.00),
        _StringTarget(label: '2', note: 'G4', frequency: 392.00),
        _StringTarget(label: '1', note: 'G4', frequency: 392.00),
      ],
      'Bozuk Duzen (La-Re-Sol)': const [
        _StringTarget(label: '7', note: 'A2', frequency: 110.00),
        _StringTarget(label: '6', note: 'A3', frequency: 220.00),
        _StringTarget(label: '5', note: 'D3', frequency: 146.83),
        _StringTarget(label: '4', note: 'D4', frequency: 293.66),
        _StringTarget(label: '3', note: 'G3', frequency: 196.00),
        _StringTarget(label: '2', note: 'G4', frequency: 392.00),
        _StringTarget(label: '1', note: 'G4', frequency: 392.00),
      ],
    },
    'Saz': {
      'Kisa Sap (La-Re-Sol)': const [
        _StringTarget(label: '6', note: 'A2', frequency: 110.00),
        _StringTarget(label: '5', note: 'A3', frequency: 220.00),
        _StringTarget(label: '4', note: 'D3', frequency: 146.83),
        _StringTarget(label: '3', note: 'D4', frequency: 293.66),
        _StringTarget(label: '2', note: 'G3', frequency: 196.00),
        _StringTarget(label: '1', note: 'G4', frequency: 392.00),
      ],
      'Misket (Sol-Re-La)': const [
        _StringTarget(label: '6', note: 'G2', frequency: 98.00),
        _StringTarget(label: '5', note: 'G3', frequency: 196.00),
        _StringTarget(label: '4', note: 'D3', frequency: 146.83),
        _StringTarget(label: '3', note: 'D4', frequency: 293.66),
        _StringTarget(label: '2', note: 'A3', frequency: 220.00),
        _StringTarget(label: '1', note: 'A4', frequency: 440.00),
      ],
    },
  };

  Map<String, List<_StringTarget>> get _presets =>
      _instrumentPresets[_instrument]!;

  List<_StringTarget> get _strings => _presets[_preset]!;

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
    try {
      await _audioCapture.init();
      await _audioCapture.start(
        _listener,
        (err) {
          if (!mounted) return;
          setState(() => _status = 'Mikrofon hatasi: $err');
        },
        sampleRate: _sampleRate,
        bufferSize: _analysisWindow,
      );

      _uiTimer?.cancel();
      _uiTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted) return;
        setState(() {});
      });

      if (!mounted) return;
      setState(() {
        _listening = true;
        _status = 'Dinleniyor';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Baslatilamadi: $e');
    }
  }

  Future<void> _stopListening() async {
    try {
      await _audioCapture.stop();
    } catch (_) {}
    _accumulated.clear();
    if (!mounted) return;
    setState(() {
      _listening = false;
      _status = 'Dinleme durdu';
    });
  }

  void _listener(Float32List buffer) async {
    if (_processing) return;
    _processing = true;
    try {
      _accumulated.addAll(buffer);
      if (_accumulated.length < _analysisWindow) {
        return;
      }
      final window =
          List<double>.from(_accumulated.take(_analysisWindow).toList());
      _accumulated.removeRange(0, _analysisWindow ~/ 2);

      final rms = _rms(window);
      if (rms < _minRms) {
        _detectedHz = null;
        _detectedNote = '-';
        _cents = 0;
        _status = 'Sinyal zayif - tele daha yakin ol';
        return;
      }

      final result = await _pitchDetector.getPitchFromFloatBuffer(
        window,
      );
      if (!mounted) return;
      if (!result.pitched) {
        _detectedHz = null;
        _detectedNote = '-';
        _cents = 0;
        _status = 'Sinyal bekleniyor';
        return;
      }

      final hz = result.pitch;
      if (hz < 50 || hz > 900) {
        return;
      }

      final target = _strings[_selectedString];
      final cents = _calcCents(hz, target.frequency).clamp(-50.0, 50.0);
      final note = _noteNameFromFrequency(hz);

      _detectedHz = hz;
      _detectedNote = note;
      _cents = cents;

      if (cents.abs() <= 4) {
        _status = 'Tam Akort';
      } else if (cents < 0) {
        _status = 'Dusuk - Sik';
      } else {
        _status = 'Yuksek - Gevset';
      }
    } catch (_) {
      // no-op
    } finally {
      _processing = false;
    }
  }

  double _calcCents(double measured, double target) {
    return 1200 * (log(measured / target) / ln2);
  }

  double _rms(List<double> values) {
    if (values.isEmpty) return 0;
    var sum = 0.0;
    for (final v in values) {
      sum += v * v;
    }
    return sqrt(sum / values.length);
  }

  String _noteNameFromFrequency(double hz) {
    const names = [
      'C',
      'C#',
      'D',
      'D#',
      'E',
      'F',
      'F#',
      'G',
      'G#',
      'A',
      'A#',
      'B'
    ];
    final midi = (69 + 12 * (log(hz / 440.0) / ln2)).round();
    final name = names[midi % 12];
    final octave = (midi ~/ 12) - 1;
    return '$name$octave';
  }

  Color _statusColor() {
    if (_cents.abs() <= 4) return const Color(0xFF22C55E);
    if (_cents.abs() <= 15) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  String _displayPresetName() {
    if (_instrument == 'Gitar' && _preset.startsWith('Standart')) {
      return 'Standard';
    }
    return _preset
        .replaceAll('(EADGBE)', '')
        .replaceAll('(DADGBE)', '')
        .replaceAll('(La-Re-Sol)', '')
        .replaceAll('(Sol-Re-La)', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _headlineText() {
    if (!_listening) return 'Tuner hazir';
    if (_detectedHz == null) return 'Bir tel cal';
    if (_cents.abs() <= 4) return 'Akor tamam';
    if (_cents < 0) return 'Biraz sik';
    return 'Biraz gevset';
  }

  Future<void> _openSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Center(
                      child: SizedBox(
                        width: 48,
                        child: Divider(thickness: 4),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Akort Ayarlari',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF141414),
                      ),
                    ),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<String>(
                      initialValue: _instrument,
                      decoration: const InputDecoration(
                        labelText: 'Enstruman',
                        border: OutlineInputBorder(),
                      ),
                      items: _instrumentPresets.keys
                          .map(
                            (e) => DropdownMenuItem(
                              value: e,
                              child: Text(e),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _instrument = value;
                          _preset = _instrumentPresets[value]!.keys.first;
                          _selectedString = 0;
                        });
                        setModalState(() {});
                      },
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      initialValue: _preset,
                      decoration: const InputDecoration(
                        labelText: 'Duzen',
                        border: OutlineInputBorder(),
                      ),
                      items: _presets.keys
                          .map(
                            (e) => DropdownMenuItem(
                              value: e,
                              child: Text(e),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _preset = value;
                          _selectedString = 0;
                        });
                        setModalState(() {});
                      },
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () async {
                          Navigator.of(context).pop();
                          if (_listening) {
                            await _stopListening();
                          } else {
                            await _startListening();
                          }
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF111111),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: Icon(_listening ? Icons.mic_off : Icons.mic),
                        label: Text(
                          _listening ? 'Dinlemeyi Durdur' : 'Dinlemeyi Baslat',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _strings[_selectedString];
    final statusColor = _statusColor();
    final noteLabel = _detectedHz == null
        ? active.note.replaceAll(RegExp(r'\d'), '')
        : _detectedNote.replaceAll(RegExp(r'\d'), '');
    final stringsTopToBottom = _strings.reversed.toList();
    final selectedFromTop = stringsTopToBottom.indexOf(active);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
              child: Row(
                children: [
                  IconButton(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back_ios_new_rounded),
                    color: const Color(0xFF111111),
                    iconSize: 28,
                  ),
                  Expanded(
                    child: Text(
                      _displayPresetName(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF101010),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _openSettingsSheet,
                    icon: const Icon(Icons.tune_rounded),
                    color: const Color(0xFF616161),
                    iconSize: 30,
                  ),
                ],
              ),
            ),
            Container(height: 1, color: const Color(0xFFE5E7EB)),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 42,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _instrumentPresets.keys.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (context, index) {
                          final instrument =
                              _instrumentPresets.keys.elementAt(index);
                          final selected = instrument == _instrument;
                          return _ChoicePill(
                            label: instrument,
                            selected: selected,
                            onTap: () {
                              setState(() {
                                _instrument = instrument;
                                _preset =
                                    _instrumentPresets[instrument]!.keys.first;
                                _selectedString = 0;
                              });
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Duzen',
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 38,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _presets.keys.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final preset = _presets.keys.elementAt(index);
                          return _ChoicePill(
                            label: preset,
                            compact: true,
                            selected: preset == _preset,
                            onTap: () {
                              setState(() {
                                _preset = preset;
                                _selectedString = 0;
                              });
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        _headlineText(),
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF424242),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(12, 18, 12, 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFBFBFB),
                        borderRadius: BorderRadius.circular(32),
                        border: Border.all(color: const Color(0xFFEDEDED)),
                      ),
                      child: SizedBox(
                        height: 300,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 250,
                              height: 250,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFFF1F1F1),
                              ),
                            ),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: _detectedHz == null ? 126 : 210,
                              height: _detectedHz == null ? 126 : 210,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _detectedHz == null
                                    ? const Color(0xFFF7F7F7)
                                    : const Color(0xFFF4F4F4),
                              ),
                            ),
                            if (_detectedHz == null)
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 82,
                                    height: 104,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF0A0A0A),
                                      borderRadius: BorderRadius.only(
                                        topLeft: Radius.circular(42),
                                        topRight: Radius.circular(42),
                                        bottomLeft: Radius.circular(34),
                                        bottomRight: Radius.circular(34),
                                      ),
                                    ),
                                    child: const Center(
                                      child: Icon(
                                        Icons.music_note_rounded,
                                        color: Colors.white,
                                        size: 42,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    _listening
                                        ? 'Secili tel: ${active.note}'
                                        : 'Mikrofondan dinleme kapali',
                                    style: const TextStyle(
                                      color: Color(0xFF8A8A8A),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              )
                            else
                              Stack(
                                clipBehavior: Clip.none,
                                alignment: Alignment.center,
                                children: [
                                  AnimatedPositioned(
                                    duration: const Duration(milliseconds: 180),
                                    left: 112 +
                                        (_cents.clamp(-50.0, 50.0) * 1.45),
                                    child: Container(
                                      width: 170,
                                      height: 170,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFFC43D),
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: const Color(0xFFFFC43D)
                                                .withValues(alpha: 0.24),
                                            blurRadius: 28,
                                            offset: const Offset(0, 10),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Text(
                                    noteLabel,
                                    style: const TextStyle(
                                      fontSize: 138,
                                      height: 1,
                                      fontWeight: FontWeight.w500,
                                      color: Color(0xFF050505),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _detectedHz == null
                          ? 'Hedef ${active.note} • ${active.frequency.toStringAsFixed(2)} Hz'
                          : '${_detectedHz!.toStringAsFixed(2)} Hz • ${_cents.toStringAsFixed(1)} cent',
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _status,
                      style: const TextStyle(
                        color: Color(0xFF8A8A8A),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _MinimalStringsView(
                      strings: stringsTopToBottom,
                      selectedIndex: selectedFromTop,
                      highlightColor: statusColor,
                      onStringTap: (index) {
                        final tapped = stringsTopToBottom[index];
                        setState(() {
                          _selectedString = _strings.indexOf(tapped);
                        });
                      },
                    ),
                    const SizedBox(height: 18),
                    _CentsDotsBar(
                      cents: _cents,
                      highlightColor: statusColor,
                    ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed:
                              _listening ? _stopListening : _startListening,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF111111),
                            side: const BorderSide(color: Color(0xFFD8D8D8)),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                          ),
                          icon: Icon(_listening ? Icons.mic_off : Icons.mic),
                          label: Text(
                            _listening
                                ? 'Dinlemeyi Durdur'
                                : 'Dinlemeyi Baslat',
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: widget.onGoHome,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF111111),
                            side: const BorderSide(color: Color(0xFFD8D8D8)),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                          ),
                          icon: const Icon(Icons.home_rounded),
                          label: const Text('Ana Sayfa'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MinimalStringsView extends StatelessWidget {
  final List<_StringTarget> strings;
  final int selectedIndex;
  final Color highlightColor;
  final ValueChanged<int> onStringTap;

  const _MinimalStringsView({
    required this.strings,
    required this.selectedIndex,
    required this.highlightColor,
    required this.onStringTap,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final spacing = constraints.maxWidth / strings.length;
        return SizedBox(
          height: 146,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 56,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF222222),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              for (int i = 0; i < strings.length; i++)
                Positioned(
                  left: (spacing * i) + ((spacing - 50) / 2),
                  top: 0,
                  child: GestureDetector(
                    onTap: () => onStringTap(i),
                    child: SizedBox(
                      width: 50,
                      child: Column(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: i == selectedIndex
                                  ? highlightColor
                                  : const Color(0xFFF0F1F4),
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              strings[i].note.replaceAll(RegExp(r'\d'), ''),
                              style: TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w500,
                                color: i == selectedIndex
                                    ? const Color(0xFF0B120C)
                                    : const Color(0xFF111111),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            width: 4,
                            height: i == selectedIndex ? 62 : 54,
                            decoration: BoxDecoration(
                              color: i == selectedIndex
                                  ? highlightColor
                                  : const Color(0xFFE1E4E8),
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ChoicePill extends StatelessWidget {
  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  const _ChoicePill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : 18,
          vertical: compact ? 9 : 11,
        ),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF111111) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? const Color(0xFF111111) : const Color(0xFFE5E7EB),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xFF111111),
            fontSize: compact ? 13 : 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _CentsDotsBar extends StatelessWidget {
  final double cents;
  final Color highlightColor;

  const _CentsDotsBar({
    required this.cents,
    required this.highlightColor,
  });

  @override
  Widget build(BuildContext context) {
    const total = 48;
    final active =
        (((cents + 50) / 100) * (total - 1)).round().clamp(0, total - 1);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (index) {
        final ratio = index / (total - 1);
        Color base;
        if (ratio < 0.34) {
          base = const Color(0xFF31C971);
        } else if (ratio < 0.67) {
          base = const Color(0xFFF5C46B);
        } else {
          base = const Color(0xFFF0A1A1);
        }
        final selected = index == active;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          width: selected ? 10 : 8,
          height: selected ? 10 : 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? highlightColor : base.withValues(alpha: 0.18),
          ),
        );
      }),
    );
  }
}

class _StringTarget {
  final String label;
  final String note;
  final double frequency;

  const _StringTarget({
    required this.label,
    required this.note,
    required this.frequency,
  });
}
