import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tuner/headstock_painter.dart';
import '../tuner/pitch_engine.dart';
import '../tuner/reference_tone.dart';
import '../tuner/tuner_tunings.dart';

enum TunerMode { auto, manual, chromatic }

/// Instrument tuner with automatic string detection, manual reference tones,
/// a chromatic mode and a "pro" readout (Hz, decimal cents, history).
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

const Color _ink = Color(0xFF111111);
const Color _muted = Color(0xFF6E6E73);
const Color _panel = Color(0xFFF5F5F7);
const Color _green = HeadstockPainter.green;
const Color _brandRed = Color(0xFFD9232E);

class _TunerScreenState extends State<TunerScreen> {
  static const int _sampleRate = 44100;
  static const int _captureBuffer = 2048;

  final FlutterAudioCapture _audioCapture = FlutterAudioCapture();
  final ReferenceTonePlayer _tones = ReferenceTonePlayer();
  final PitchTracker _tracker = PitchTracker();
  PitchDetector? _detector;
  Float64List _window = Float64List(4096);
  int _filled = 0;

  // Settings (persisted).
  String _instrumentId = 'electric';
  String _tuningId = 'electric:Standart';
  TunerMode _mode = TunerMode.auto;
  bool _pro = false;
  double _a4 = 440;
  bool _flats = false;
  bool _leftHanded = false;
  bool _successSound = true;
  bool _haptics = true;
  List<TunerTuning> _custom = [];

  // Live state.
  bool _listening = false;
  int _manualString = 0;
  int _activeString = -1;
  final Set<int> _tuned = {};
  int _inTuneSinceMs = 0;
  bool _successShown = false;
  bool _showSuccess = false;
  TargetMatch? _match;
  double? _frequency;
  TuneFeedback _feedback = const TuneFeedback(TuneState.idle, 'Başlamak için mikrofona dokun');
  final List<(int, double)> _history = [];
  final Stopwatch _clock = Stopwatch()..start();

  TunerInstrument get _instrument => instrumentById(_instrumentId);

  List<TunerTuning> get _tunings => [..._instrument.presets, ..._custom.where((t) => t.instrument == _instrumentId)];

  TunerTuning get _tuning => _tunings.firstWhere((t) => t.id == _tuningId, orElse: () => _tunings.first);

  String _label(String note) => midiToNote(noteToMidi(note), flats: _flats, octave: false);

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _stopListening(updateUi: false);
    _tones.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- settings

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _instrumentId = instrumentById(prefs.getString('tuner.instrument') ?? 'electric').id;
      _custom = TunerTuning.decodeCustom(prefs.getString('tuner.custom'));
      _tuningId = prefs.getString('tuner.tuning') ?? _instrument.presets.first.id;
      _mode = TunerMode.values.asNameMap()[prefs.getString('tuner.mode')] ?? TunerMode.auto;
      _pro = prefs.getBool('tuner.pro') ?? false;
      _a4 = (prefs.getDouble('tuner.a4') ?? 440).clamp(430, 450).toDouble();
      _flats = prefs.getBool('tuner.flats') ?? false;
      _leftHanded = prefs.getBool('tuner.leftHanded') ?? false;
      _successSound = prefs.getBool('tuner.successSound') ?? true;
      _haptics = prefs.getBool('tuner.haptics') ?? true;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tuner.instrument', _instrumentId);
    await prefs.setString('tuner.tuning', _tuningId);
    await prefs.setString('tuner.mode', _mode.name);
    await prefs.setBool('tuner.pro', _pro);
    await prefs.setDouble('tuner.a4', _a4);
    await prefs.setBool('tuner.flats', _flats);
    await prefs.setBool('tuner.leftHanded', _leftHanded);
    await prefs.setBool('tuner.successSound', _successSound);
    await prefs.setBool('tuner.haptics', _haptics);
    await prefs.setString('tuner.custom', TunerTuning.encodeCustom(_custom));
  }

  // ------------------------------------------------------------------- audio

  Future<void> _startListening() async {
    if (_listening) return;
    _resetProgress();
    try {
      await _audioCapture.init();
      await _audioCapture.start(
        _onBuffer,
        (err) {
          if (mounted) setState(() => _feedback = TuneFeedback(TuneState.noisy, 'Mikrofon hatası: $err'));
        },
        sampleRate: _sampleRate,
        bufferSize: _captureBuffer,
      );
      if (!mounted) return;
      setState(() {
        _listening = true;
        _feedback = const TuneFeedback(TuneState.idle, 'Bir tel çal');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _feedback = const TuneFeedback(TuneState.noisy, 'Mikrofon başlatılamadı. İzinleri kontrol et.'));
    }
  }

  Future<void> _stopListening({bool updateUi = true}) async {
    try {
      await _audioCapture.stop();
    } catch (_) {}
    if (!updateUi || !mounted) return;
    setState(() {
      _listening = false;
      _resetProgress();
      _feedback = const TuneFeedback(TuneState.idle, 'Başlamak için mikrofona dokun');
    });
  }

  void _onBuffer(Float32List buffer) {
    final size = _instrument.frameSize;
    if (_window.length != size) {
      _window = Float64List(size);
      _filled = 0;
    }
    // Slide the newest samples into the analysis window.
    if (buffer.length >= size) {
      for (var i = 0; i < size; i++) {
        _window[i] = buffer[buffer.length - size + i];
      }
      _filled = size;
    } else {
      final keep = math.min(_filled, size - buffer.length);
      _window.setRange(0, keep, _window, _filled - keep);
      for (var i = 0; i < buffer.length; i++) {
        _window[keep + i] = buffer[i];
      }
      _filled = keep + buffer.length;
    }
    if (_filled < size) return;
    final detector = _detector != null && _detector!.size == size ? _detector! : (_detector = PitchDetector(_sampleRate, size));
    final reading = detector.detect(_window);
    if (!mounted) return;
    _process(reading);
  }

  void _process(PitchReading reading) {
    final now = _clock.elapsedMilliseconds;
    final tracked = _tracker.push(reading.frequency == null ? null : frequencyToMidi(reading.frequency!), now);
    if (tracked.midi == null) {
      setState(() {
        _match = null;
        _frequency = null;
        _inTuneSinceMs = 0;
        if (_mode == TunerMode.auto) _activeString = -1;
        if (reading.rms < 0.0015) {
          _feedback = const TuneFeedback(TuneState.idle, 'Bir tel çal');
        } else if (reading.rms < 0.004 && reading.frequency == null) {
          _feedback = const TuneFeedback(TuneState.quiet, 'Seni tam duyamıyorum — biraz daha yüksek çal.');
        } else {
          _feedback = const TuneFeedback(TuneState.noisy, 'Ortam biraz gürültülü.');
        }
      });
      return;
    }
    final freq = midiToFrequency(tracked.midi!); // tracker uses A4 = 440 internally
    final notes = _tuning.notes;
    final match = switch (_mode) {
      TunerMode.chromatic => nearestNote(freq, a4: _a4),
      TunerMode.manual => stringTarget(freq, notes, _manualString.clamp(0, notes.length - 1), a4: _a4),
      TunerMode.auto => nearestString(freq, notes, a4: _a4),
    };
    setState(() {
      _match = match;
      _frequency = freq;
      _activeString = match.index;
      _feedback = feedbackForCents(match.cents);
      if (_pro) {
        _history.add((now, match.cents));
        _history.removeWhere((e) => now - e.$1 > 6000);
      }
      // A string counts as tuned after holding inside the window for 600 ms.
      if (match.index >= 0) {
        if (match.cents.abs() <= kInTuneCents && tracked.stable) {
          if (_inTuneSinceMs == 0) _inTuneSinceMs = now;
          if (now - _inTuneSinceMs > 600 && !_tuned.contains(match.index)) _markTuned(match.index);
        } else {
          _inTuneSinceMs = 0;
          if (match.cents.abs() > 10) _tuned.remove(match.index);
        }
      }
    });
  }

  void _markTuned(int index) {
    _tuned.add(index);
    if (_haptics) HapticFeedback.mediumImpact();
    final count = _tuning.notes.length;
    if (_tuned.length == count && !_successShown) {
      _successShown = true;
      _showSuccess = true;
      if (_successSound && _mode == TunerMode.auto) _tones.playChime();
      if (_haptics) HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 2200), () {
        if (mounted) setState(() => _showSuccess = false);
      });
    } else if (_mode == TunerMode.manual && index < count - 1) {
      // Manual mode walks on to the next string.
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        setState(() => _manualString = index + 1);
        _tracker.reset();
      });
    }
  }

  void _resetProgress() {
    _tuned.clear();
    _successShown = false;
    _inTuneSinceMs = 0;
    _tracker.reset();
    _history.clear();
    _match = null;
    _frequency = null;
    _activeString = -1;
  }

  void _onStringTap(int index) {
    if (_mode == TunerMode.chromatic) return;
    _tones.playFrequency(midiToFrequency(noteToMidi(_tuning.notes[index]), a4: _a4));
    setState(() {
      if (_mode == TunerMode.manual) {
        _manualString = index;
        _tracker.reset();
      }
    });
  }

  void _selectInstrument(String id) {
    setState(() {
      _instrumentId = id;
      _tuningId = _instrument.presets.first.id;
      _manualString = 0;
      _detector = null;
      _resetProgress();
    });
    _saveSettings();
  }

  void _selectTuning(String id) {
    setState(() {
      _tuningId = id;
      _manualString = 0;
      _resetProgress();
    });
    _saveSettings();
  }

  void _setMode(TunerMode mode) {
    setState(() {
      _mode = mode;
      _tracker.reset();
      _match = null;
    });
    _saveSettings();
  }

  // ------------------------------------------------------------------- sheets

  Future<void> _openTuningSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const _SheetHandle(),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(alignment: Alignment.centerLeft, child: Text('Akort seç', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink))),
            ),
            Flexible(
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                for (final t in _tunings)
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    decoration: BoxDecoration(
                      color: _panel,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: t.id == _tuningId ? _green : Colors.transparent, width: 2),
                    ),
                    child: ListTile(
                      title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w700, color: _ink)),
                      subtitle: Text(t.notes.map(_label).join(' '), style: const TextStyle(letterSpacing: 2, color: _muted)),
                      trailing: t.custom
                          ? TextButton(
                              onPressed: () {
                                Navigator.pop(ctx);
                                _openCustomEditor(existing: t);
                              },
                              child: const Text('Düzenle', style: TextStyle(color: _brandRed)),
                            )
                          : null,
                      onTap: () {
                        Navigator.pop(ctx);
                        _selectTuning(t.id);
                      },
                    ),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _openCustomEditor();
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Özel akort oluştur'),
                  style: OutlinedButton.styleFrom(foregroundColor: _ink, padding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _openCustomEditor({TunerTuning? existing}) async {
    final base = existing ?? _tuning;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final midis = base.notes.map(noteToMidi).toList();
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const _SheetHandle(),
              Text(existing == null ? 'Yeni özel akort' : 'Özel akortu düzenle',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink)),
              const SizedBox(height: 12),
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Ad', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (var i = 0; i < midis.length; i++)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(12)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('${i + 1}.', style: const TextStyle(color: _muted)),
                      IconButton(visualDensity: VisualDensity.compact, onPressed: () => setSheet(() => midis[i]--), icon: const Icon(Icons.remove_rounded, size: 18)),
                      SizedBox(width: 38, child: Text(midiToNote(midis[i], flats: _flats), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800))),
                      IconButton(visualDensity: VisualDensity.compact, onPressed: () => setSheet(() => midis[i]++), icon: const Icon(Icons.add_rounded, size: 18)),
                    ]),
                  ),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                if (existing != null)
                  TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Sil', style: TextStyle(color: _brandRed))),
                const Spacer(),
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, 'save'),
                  style: FilledButton.styleFrom(backgroundColor: _ink),
                  child: const Text('Kaydet'),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      if (result == 'delete' && existing != null) {
        _custom.removeWhere((t) => t.id == existing.id);
        if (_tuningId == existing.id) _tuningId = _instrument.presets.first.id;
      } else if (result == 'save') {
        final tuning = TunerTuning(
          id: existing?.id ?? 'custom:${DateTime.now().millisecondsSinceEpoch}',
          instrument: _instrumentId,
          name: nameCtrl.text.trim().isEmpty ? 'Özel akort' : nameCtrl.text.trim(),
          notes: midis.map((m) => midiToNote(m)).toList(),
          custom: true,
        );
        _custom.removeWhere((t) => t.id == tuning.id);
        _custom.add(tuning);
        _tuningId = tuning.id;
      }
      _resetProgress();
    });
    _saveSettings();
  }

  Future<void> _openSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void update(VoidCallback fn) {
            setState(fn);
            setSheet(() {});
            _saveSettings();
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const _SheetHandle(),
                const Text('Akort ayarları', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink)),
                const SizedBox(height: 12),
                Text('Referans perde: A4 = ${_a4.round()} Hz', style: const TextStyle(color: _muted, fontWeight: FontWeight.w600)),
                Slider(value: _a4, min: 430, max: 450, divisions: 20, activeColor: _ink, onChanged: (v) => update(() => _a4 = v)),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [ButtonSegment(value: false, label: Text('Diyez (#)')), ButtonSegment(value: true, label: Text('Bemol (♭)'))],
                  selected: {_flats},
                  onSelectionChanged: (v) => update(() => _flats = v.first),
                ),
                SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Solak görünüm'), value: _leftHanded, onChanged: (v) => update(() => _leftHanded = v)),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Başarı sesi'),
                    subtitle: const Text('Yalnızca otomatik modda'),
                    value: _successSound,
                    onChanged: (v) => update(() => _successSound = v)),
                SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Titreşim'), value: _haptics, onChanged: (v) => update(() => _haptics = v)),
              ]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openTips() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => const SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _SheetHandle(),
            Text('Akort yardımı', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink)),
            SizedBox(height: 12),
            _Tip('Standartla başla', 'E A D G B E akortunda en kalın telden başlayıp en ince tele doğru ilerle.'),
            _Tip('Tele net vur', 'Pena ya da başparmakla, ne çok sert ne çok yumuşak; temiz ve kararlı bir vuruş en iyi sonucu verir.'),
            _Tip('Sesi bırak', 'Teli çaldıktan sonra susturma; ses sürerken uygulama notayı duyar ve sen akort edersin.'),
            _Tip('Pes mi, tiz mi?', 'Pes ise teli sıkıştır (mandalı ok yönünde çevir), tiz ise gevşet. Yeşil olunca o tel tamam.'),
          ]),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final tuning = _tuning;
    final geometry = HeadstockGeometry(_instrument.layout, tuning.notes.length);
    final labels = tuning.notes.map(_label).toList();
    final hint = switch (_feedback.state) {
      TuneState.flat => TurnHint.tighten,
      TuneState.sharp => TurnHint.loosen,
      _ => TurnHint.none,
    };
    final active = _mode == TunerMode.manual ? _manualString : _activeString;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(children: [
          Column(children: [
            _buildTopBar(tuning, labels),
            _buildInstrumentChips(),
            _buildModeBar(),
            _buildMeter(),
            if (_pro) _buildProPanel(),
            Expanded(
              child: LayoutBuilder(
                builder: (_, constraints) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) {
                    final i = geometry.hitTest(d.localPosition, constraints.biggest, mirrored: _leftHanded);
                    if (i != null) _onStringTap(i);
                  },
                  child: CustomPaint(
                    size: constraints.biggest,
                    painter: HeadstockPainter(
                      geometry: geometry,
                      labels: labels,
                      activeString: active,
                      tuned: Set.of(_tuned),
                      hint: _match == null ? TurnHint.none : hint,
                      mirrored: _leftHanded,
                      dimmed: _mode == TunerMode.chromatic,
                    ),
                  ),
                ),
              ),
            ),
            _buildBottomBar(),
          ]),
          if (_showSuccess) _buildSuccess(),
        ]),
      ),
    );
  }

  Widget _buildTopBar(TunerTuning tuning, List<String> labels) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(children: [
        IconButton(onPressed: widget.onBack, icon: const Icon(Icons.arrow_back_ios_new_rounded), color: _ink),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _openTuningSheet,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                    child: Text(tuning.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: _ink)),
                  ),
                  const Icon(Icons.arrow_drop_down_rounded, color: _muted),
                ]),
                Text(labels.join(' '), style: const TextStyle(fontSize: 12, letterSpacing: 3, color: _muted)),
              ]),
            ),
          ),
        ),
        IconButton(onPressed: widget.onGoHome, icon: const Icon(Icons.home_rounded), color: _muted, tooltip: 'Ana sayfa'),
        IconButton(onPressed: _openSettingsSheet, icon: const Icon(Icons.tune_rounded), color: _muted, tooltip: 'Akort ayarları'),
      ]),
    );
  }

  Widget _buildInstrumentChips() {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: kTunerInstruments.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final inst = kTunerInstruments[i];
          final selected = inst.id == _instrumentId;
          return GestureDetector(
            onTap: () => _selectInstrument(inst.id),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: selected ? _ink : _panel, borderRadius: BorderRadius.circular(999)),
              child: Text(inst.label, style: TextStyle(color: selected ? Colors.white : _ink, fontWeight: FontWeight.w700, fontSize: 13)),
            ),
          );
        },
      ),
    );
  }

  Widget _buildModeBar() {
    Widget tab(String label, TunerMode mode) {
      final selected = _mode == mode;
      return Expanded(
        child: GestureDetector(
          onTap: () => _setMode(mode),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              boxShadow: selected ? [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 3, offset: const Offset(0, 1))] : null,
            ),
            child: Text(label, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: selected ? _ink : _muted)),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        tab('Otomatik', TunerMode.auto),
        tab('Manuel', TunerMode.manual),
        tab('Kromatik', TunerMode.chromatic),
        GestureDetector(
          onTap: () {
            setState(() {
              _pro = !_pro;
              _history.clear();
            });
            _saveSettings();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
            decoration: BoxDecoration(color: _pro ? _ink : Colors.transparent, borderRadius: BorderRadius.circular(9)),
            child: Text('PRO', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 1.2, color: _pro ? Colors.white : _muted)),
          ),
        ),
      ]),
    );
  }

  Color get _stateColor => switch (_feedback.state) {
        TuneState.inTune => _green,
        TuneState.flat => HeadstockPainter.flatColor,
        TuneState.sharp => HeadstockPainter.sharpColor,
        TuneState.idle => _ink,
        _ => _muted,
      };

  Widget _buildMeter() {
    final match = _match;
    final noteName = match == null ? '–' : midiToNote(match.midi, flats: _flats, octave: false);
    final octave = match == null ? '' : '${match.midi ~/ 12 - 1}';
    final rounded = match?.cents.round() ?? 0;
    final centsText = match == null
        ? ' '
        : (match.cents.abs() > 99 ? '${match.cents > 0 ? '+' : '−'}99+ sent' : '${rounded > 0 ? '+' : (rounded < 0 ? '−' : '')}${rounded.abs()} sent');
    final inTune = _feedback.state == TuneState.inTune;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(children: [
        SizedBox(
          height: 64,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(noteName, style: TextStyle(fontSize: 58, height: 1, fontWeight: FontWeight.w800, color: inTune ? _green : _ink)),
            Padding(padding: const EdgeInsets.only(bottom: 4, left: 2), child: Text(octave, style: const TextStyle(fontSize: 18, color: _muted))),
          ]),
        ),
        SizedBox(
          width: 260,
          height: 130,
          child: CustomPaint(painter: _DialPainter(cents: match?.cents, color: inTune ? _green : _ink)),
        ),
        Text(centsText, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _muted)),
        const SizedBox(height: 2),
        Text(_feedback.text, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _stateColor)),
      ]),
    );
  }

  Widget _buildProPanel() {
    final match = _match;
    Widget cell(String label, String value) => Expanded(
          child: Column(children: [
            Text(label, style: const TextStyle(fontSize: 11, color: _muted)),
            Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _ink, fontFeatures: [FontFeature.tabularFigures()])),
          ]),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(16)),
      child: Column(children: [
        Row(children: [
          cell('Ölçülen', _frequency == null ? '– Hz' : '${_frequency!.toStringAsFixed(1)} Hz'),
          cell('Hedef', match == null ? '– Hz' : '${match.targetFrequency.toStringAsFixed(1)} Hz'),
          cell('Sapma', match == null ? '– sent' : '${match.cents >= 0 ? '+' : ''}${match.cents.toStringAsFixed(1)} sent'),
        ]),
        const SizedBox(height: 6),
        SizedBox(height: 56, width: double.infinity, child: CustomPaint(painter: _HistoryPainter(List.of(_history), _clock.elapsedMilliseconds))),
      ]),
    );
  }

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: _openTips, child: const Text('Akort yardımı', style: TextStyle(color: _brandRed, fontWeight: FontWeight.w700))),
          ),
        ),
        GestureDetector(
          onTap: _listening ? _stopListening : _startListening,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 66,
            height: 66,
            decoration: BoxDecoration(
              color: _listening ? _brandRed : _ink,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: (_listening ? _brandRed : Colors.black).withValues(alpha: 0.28), blurRadius: 18, offset: const Offset(0, 8))],
            ),
            child: Icon(_listening ? Icons.mic_rounded : Icons.mic_none_rounded, color: Colors.white, size: 30),
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(_resetProgress),
              child: const Text('Sıfırla', style: TextStyle(color: _muted, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildSuccess() {
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _showSuccess = false),
        child: Container(
          color: Colors.white.withValues(alpha: 0.75),
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 40, offset: const Offset(0, 16))],
            ),
            child: const Column(mainAxisSize: MainAxisSize.min, children: [
              CircleAvatar(radius: 38, backgroundColor: _green, child: Icon(Icons.check_rounded, color: Colors.white, size: 44)),
              SizedBox(height: 12),
              Text('Tüm teller akortlu!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink)),
              Text('Çalmaya hazırsın.', style: TextStyle(color: _muted)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(padding: EdgeInsets.symmetric(vertical: 10), child: SizedBox(width: 44, child: Divider(thickness: 4))),
      );
}

class _Tip extends StatelessWidget {
  final String title;
  final String body;

  const _Tip(this.title, this.body);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: '$title. ', style: const TextStyle(fontWeight: FontWeight.w800, color: _ink)),
          TextSpan(text: body, style: const TextStyle(color: _muted, height: 1.35)),
        ])),
      );
}

/// ±50 cent arc gauge with a needle and a green in-tune zone.
class _DialPainter extends CustomPainter {
  final double? cents;
  final Color color;

  _DialPainter({required this.cents, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 8);
    final r = size.width / 2 - 14;
    final rect = Rect.fromCircle(center: center, radius: r);
    canvas.drawArc(rect, math.pi, math.pi, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFE6E6EA));
    // In-tune zone (±3 cents of the ±50 range mapped to ±60°).
    const zone = kInTuneCents / 50 * (math.pi / 3);
    canvas.drawArc(rect, -math.pi / 2 - zone, zone * 2, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..color = _green);
    for (var c = -50; c <= 50; c += 5) {
      final a = (c / 50) * (math.pi / 3) - math.pi / 2;
      final inner = c % 25 == 0 ? r - 16 : r - 10;
      canvas.drawLine(center + Offset(math.cos(a), math.sin(a)) * inner, center + Offset(math.cos(a), math.sin(a)) * (r - 4), Paint()
        ..strokeWidth = c == 0 ? 3 : 2
        ..color = c == 0 ? _green : const Color(0xFFC7C7CC));
    }
    final c = (cents ?? 0).clamp(-50.0, 50.0);
    final a = (c / 50) * (math.pi / 3) - math.pi / 2;
    final needleColor = cents == null ? const Color(0xFFD1D1D6) : color;
    canvas.drawLine(center, center + Offset(math.cos(a), math.sin(a)) * (r - 18), Paint()
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = needleColor);
    canvas.drawCircle(center, 7, Paint()..color = needleColor);
  }

  @override
  bool shouldRepaint(covariant _DialPainter old) => old.cents != cents || old.color != color;
}

/// Last six seconds of cent deviation (pro view).
class _HistoryPainter extends CustomPainter {
  final List<(int, double)> history;
  final int now;

  _HistoryPainter(this.history, this.now);

  @override
  void paint(Canvas canvas, Size size) {
    double y(double c) => size.height / 2 - (c.clamp(-50.0, 50.0) / 50) * (size.height / 2 - 3);
    canvas.drawRect(Rect.fromLTRB(0, y(kInTuneCents), size.width, y(-kInTuneCents)), Paint()..color = _green.withValues(alpha: 0.16));
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), Paint()..color = Colors.black12);
    if (history.length < 2) return;
    final path = Path();
    for (var i = 0; i < history.length; i++) {
      final (t, c) = history[i];
      final x = size.width - (now - t) / 6000 * size.width;
      i == 0 ? path.moveTo(x, y(c)) : path.lineTo(x, y(c));
    }
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = _green);
  }

  @override
  bool shouldRepaint(covariant _HistoryPainter old) => true;
}
