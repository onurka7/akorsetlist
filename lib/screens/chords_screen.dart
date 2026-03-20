import 'package:flutter/material.dart';

class ChordsScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback? onBack;
  final VoidCallback? onGoHome;
  final VoidCallback? onOpenTuner;

  const ChordsScreen({
    super.key,
    required this.isDarkMode,
    this.onBack,
    this.onGoHome,
    this.onOpenTuner,
  });

  @override
  State<ChordsScreen> createState() => _ChordsScreenState();
}

class _ChordsScreenState extends State<ChordsScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _family = 'Tümü';
  final Set<String> _favoriteChords = <String>{};

  // Kaynak referansı (açık pozisyon düzeni):
  // https://www.gitaregitim.net/wp-content/uploads/2014/11/acik_pozisyon_akor-_tablosu.pdf
  final List<_ChordData> _presetChords = <_ChordData>[
    _ChordData(name: 'C', family: 'Majör', strings: const [-1, 3, 2, 0, 1, 0]),
    _ChordData(name: 'Cm', family: 'Minör', strings: const [-1, 3, 5, 5, 4, 3]),
    _ChordData(name: 'C7', family: '7', strings: const [-1, 3, 2, 3, 1, 0]),
    _ChordData(name: 'Cm7', family: 'm7', strings: const [-1, 3, 5, 3, 4, 3]),
    _ChordData(name: 'D', family: 'Majör', strings: const [-1, -1, 0, 2, 3, 2]),
    _ChordData(
        name: 'Dm', family: 'Minör', strings: const [-1, -1, 0, 2, 3, 1]),
    _ChordData(name: 'D7', family: '7', strings: const [-1, -1, 0, 2, 1, 2]),
    _ChordData(name: 'Dm7', family: 'm7', strings: const [-1, -1, 0, 2, 1, 1]),
    _ChordData(name: 'E', family: 'Majör', strings: const [0, 2, 2, 1, 0, 0]),
    _ChordData(name: 'Em', family: 'Minör', strings: const [0, 2, 2, 0, 0, 0]),
    _ChordData(name: 'E7', family: '7', strings: const [0, 2, 0, 1, 0, 0]),
    _ChordData(name: 'Em7', family: 'm7', strings: const [0, 2, 2, 0, 3, 0]),
    _ChordData(name: 'F', family: 'Majör', strings: const [1, 3, 3, 2, 1, 1]),
    _ChordData(name: 'Fm', family: 'Minör', strings: const [1, 3, 3, 1, 1, 1]),
    _ChordData(name: 'F7', family: '7', strings: const [1, 3, 1, 2, 1, 1]),
    _ChordData(name: 'Fm7', family: 'm7', strings: const [1, 3, 1, 1, 1, 1]),
    _ChordData(name: 'G', family: 'Majör', strings: const [3, 2, 0, 0, 0, 3]),
    _ChordData(name: 'Gm', family: 'Minör', strings: const [3, 5, 5, 3, 3, 3]),
    _ChordData(name: 'G7', family: '7', strings: const [3, 2, 0, 0, 0, 1]),
    _ChordData(name: 'Gm7', family: 'm7', strings: const [3, 5, 3, 3, 3, 3]),
    _ChordData(name: 'A', family: 'Majör', strings: const [-1, 0, 2, 2, 2, 0]),
    _ChordData(name: 'Am', family: 'Minör', strings: const [-1, 0, 2, 2, 1, 0]),
    _ChordData(name: 'A7', family: '7', strings: const [-1, 0, 2, 0, 2, 0]),
    _ChordData(name: 'Am7', family: 'm7', strings: const [-1, 0, 2, 0, 1, 0]),
    _ChordData(name: 'B', family: 'Majör', strings: const [-1, 2, 4, 4, 4, 2]),
    _ChordData(name: 'Bm', family: 'Minör', strings: const [-1, 2, 4, 4, 3, 2]),
    _ChordData(name: 'B7', family: '7', strings: const [-1, 2, 1, 2, 0, 2]),
    _ChordData(name: 'Bm7', family: 'm7', strings: const [-1, 2, 4, 2, 3, 2]),
    _ChordData(name: 'Bb', family: 'Majör', strings: const [-1, 1, 3, 3, 3, 1]),
    _ChordData(
        name: 'Bbm', family: 'Minör', strings: const [-1, 1, 3, 3, 2, 1]),
    _ChordData(
        name: 'Cmaj7', family: 'Maj7', strings: const [-1, 3, 2, 0, 0, 0]),
    _ChordData(
        name: 'Fmaj7', family: 'Maj7', strings: const [-1, -1, 3, 2, 1, 0]),
    _ChordData(
        name: 'Gmaj7', family: 'Maj7', strings: const [3, 2, 0, 0, 0, 2]),
  ];

  List<_ChordData> get _visibleChords {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _presetChords.where((c) {
      if (_family != 'Tümü' && c.family != _family) return false;
      if (q.isNotEmpty && !c.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFFFC83D);
    final isDark = widget.isDarkMode;
    final bgA = isDark ? const Color(0xFF000000) : const Color(0xFFF4F6FA);
    final bgB = isDark ? const Color(0xFF0B0B0B) : const Color(0xFFE7ECF3);
    final cardColor =
        isDark ? const Color(0xFF151515) : const Color(0xFFFFFFFF);
    final cardBorder =
        isDark ? const Color(0xFF2C2C2C) : const Color(0xFFD8DDE6);
    final inputBg = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFFFFFFF);
    final textColor = isDark ? Colors.white : const Color(0xFF111827);
    final hintColor =
        isDark ? const Color(0xFF9B9B9B) : const Color(0xFF6B7280);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bgA, bgB],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: widget.onBack,
                      icon: const Icon(Icons.arrow_back),
                      color: const Color(0xFFFFC83D),
                    ),
                    Expanded(
                      child: Text(
                        'Gitar Akorları',
                        style: TextStyle(
                          color: textColor,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: widget.onGoHome,
                      icon: const Icon(Icons.home_rounded),
                      color: const Color(0xFFFFC83D),
                      tooltip: 'Ana sayfa',
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.black,
                      ),
                      onPressed: widget.onOpenTuner,
                      icon: const Icon(Icons.tune),
                      label: const Text('Akort'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: inputBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: cardBorder),
                  ),
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (_) => setState(() {}),
                    style: TextStyle(color: textColor),
                    decoration: InputDecoration(
                      hintText: 'Akor ara (örn: G7, Cmaj7)',
                      hintStyle: TextStyle(color: hintColor),
                      border: InputBorder.none,
                      prefixIcon: const Icon(Icons.search, color: accent),
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ['Tümü', 'Majör', 'Minör', '7', 'm7', 'Maj7']
                      .map(
                        (f) => ChoiceChip(
                          label: Text(f),
                          selected: _family == f,
                          onSelected: (_) => setState(() => _family = f),
                          selectedColor: accent,
                          labelStyle: TextStyle(
                            color: _family == f ? Colors.black : textColor,
                            fontWeight: FontWeight.w700,
                          ),
                          backgroundColor:
                              isDark ? const Color(0xFF1F1F1F) : Colors.white,
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.82,
                  ),
                  itemCount: _visibleChords.length,
                  itemBuilder: (_, i) {
                    final chord = _visibleChords[i];
                    final isFav = _favoriteChords.contains(chord.name);
                    return Container(
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: cardBorder),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  chord.name,
                                  style: const TextStyle(
                                    color: accent,
                                    fontSize: 28,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const Spacer(),
                                IconButton(
                                  onPressed: () {
                                    setState(() {
                                      if (isFav) {
                                        _favoriteChords.remove(chord.name);
                                      } else {
                                        _favoriteChords.add(chord.name);
                                      }
                                    });
                                  },
                                  icon: Icon(
                                    isFav
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    color: accent,
                                  ),
                                ),
                              ],
                            ),
                            Expanded(
                              child: Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? const Color(0xFF0D0D0D)
                                      : const Color(0xFFF8FAFC),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: cardBorder),
                                ),
                                child: CustomPaint(
                                  painter: _ChordBoxPainter(
                                    strings: chord.strings,
                                    isDark: isDark,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChordData {
  final String name;
  final String family;
  final List<int> strings; // 6 tel: -1 X, 0 O, 1..n perde

  _ChordData({
    required this.name,
    required this.family,
    required List<int> strings,
  }) : strings = List<int>.unmodifiable(strings);
}

class _Dot {
  final int string;
  final int fret;

  const _Dot(this.string, this.fret);
}

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

    for (int s = 0; s < stringsCount; s++) {
      final x = left + (stringGap * s);
      canvas.drawLine(Offset(x, top), Offset(x, bottom), grid);
    }

    for (int f = 0; f < fretsCount; f++) {
      final y = top + (fretGap * f);
      canvas.drawLine(Offset(left, y), Offset(right, y), grid);
    }
    canvas.drawLine(Offset(left, top), Offset(right, top), nut);

    for (int s = 0; s < stringsCount; s++) {
      final state = s < strings.length ? strings[s] : -1;
      final text = state < 0 ? 'X' : (state == 0 ? 'O' : '');
      if (text.isEmpty) continue;

      final tp = TextPainter(
        text: TextSpan(text: text, style: xoStyle),
        textDirection: TextDirection.ltr,
      )..layout();

      final x = left + (stringGap * s) - tp.width / 2;
      final y = top - tp.height - 6;
      tp.paint(canvas, Offset(x, y));
    }

    final dots = <_Dot>[];
    for (int s = 0; s < stringsCount; s++) {
      final fret = s < strings.length ? strings[s] : -1;
      if (fret > 0) dots.add(_Dot(s, fret));
    }

    for (final d in dots) {
      final x = left + stringGap * d.string;
      final y = top + fretGap * (d.fret - 0.5);
      canvas.drawCircle(Offset(x, y), 6, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ChordBoxPainter oldDelegate) {
    return oldDelegate.isDark != isDark || oldDelegate.strings != strings;
  }
}
