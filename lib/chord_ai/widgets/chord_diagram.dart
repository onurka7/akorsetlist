import 'package:flutter/material.dart';

import '../chord_theory.dart';

/// Chord diagram for guitar/ukulele (fret box with barre and base fret) or
/// piano (two-octave keyboard with chord tones lit).
class ChordDiagram extends StatelessWidget {
  final String chord;
  final ChordInstrument instrument;
  final bool leftHanded;
  final Color foreground;
  final Color accent;
  final double width;

  /// Specific fingering to draw; defaults to the best-ranked one.
  final Voicing? voicing;

  const ChordDiagram({
    super.key,
    required this.chord,
    required this.instrument,
    required this.foreground,
    required this.accent,
    this.leftHanded = false,
    this.width = 96,
    this.voicing,
  });

  @override
  Widget build(BuildContext context) {
    if (parseChord(chord) == null) {
      return SizedBox(width: width, height: width * 1.2, child: Center(child: Text('—', style: TextStyle(color: foreground))));
    }
    if (instrument == ChordInstrument.piano) {
      return CustomPaint(
        size: Size(width * 1.5, width * 0.62),
        painter: _PianoPainter(pianoVoicing(chord).toSet(), foreground, accent),
      );
    }
    final voicings = voicing != null ? [voicing!] : findVoicings(chord, instrument, count: 1);
    if (voicings.isEmpty) {
      return SizedBox(
        width: width,
        height: width * 1.2,
        child: Center(child: Text('Pozisyon yok', style: TextStyle(color: foreground, fontSize: 11))),
      );
    }
    return CustomPaint(
      size: Size(width, width * 1.22),
      painter: _FretPainter(voicings.first, instrument.tuning.length, leftHanded, foreground, accent),
    );
  }
}

class _FretPainter extends CustomPainter {
  final Voicing voicing;
  final int strings;
  final bool leftHanded;
  final Color fg;
  final Color accent;

  _FretPainter(this.voicing, this.strings, this.leftHanded, this.fg, this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    const frets = 5;
    final left = size.width * 0.18, right = size.width * 0.9;
    final top = size.height * 0.2, bottom = size.height * 0.94;
    final sx = (right - left) / (strings - 1), sy = (bottom - top) / frets;
    final line = Paint()
      ..color = fg.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    final base = voicing.baseFret;
    for (var f = 0; f <= frets; f++) {
      final y = top + f * sy;
      canvas.drawLine(Offset(left, y), Offset(right, y), f == 0 && base == 1 ? (Paint()..color = fg..strokeWidth = 3.5) : line);
    }
    for (var s = 0; s < strings; s++) {
      canvas.drawLine(Offset(left + s * sx, top), Offset(left + s * sx, bottom), line..color = fg.withValues(alpha: 0.7));
    }
    final dot = Paint()..color = accent;
    final r = size.width * 0.058;
    if (base > 1) _text(canvas, '$base', Offset(left - r * 1.6, top + sy * 0.5), size.width * 0.11, fg, alignRight: true);
    final frets0 = leftHanded ? voicing.frets.reversed.toList() : voicing.frets;
    final barre = voicing.barre;
    if (barre != null) {
      var from = barre.from, to = barre.to;
      if (leftHanded) (from, to) = (strings - 1 - to, strings - 1 - from);
      final y = top + (barre.fret - base + 0.5) * sy;
      canvas.drawRRect(
        RRect.fromLTRBR(left + from * sx - r, y - r, left + to * sx + r, y + r, Radius.circular(r)),
        dot,
      );
    }
    for (var s = 0; s < strings; s++) {
      final f = frets0[s];
      final x = left + s * sx;
      if (f < 0) {
        _text(canvas, '×', Offset(x, top - sy * 0.55), size.width * 0.12, fg.withValues(alpha: 0.7));
      } else if (f == 0) {
        canvas.drawCircle(Offset(x, top - sy * 0.45), r * 0.7, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = fg);
      } else {
        canvas.drawCircle(Offset(x, top + (f - base + 0.5) * sy), r, dot);
      }
    }
  }

  void _text(Canvas canvas, String s, Offset center, double fontSize, Color color, {bool alignRight = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: fontSize, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(alignRight ? center.dx - tp.width : center.dx - tp.width / 2, center.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _FretPainter old) =>
      old.voicing != voicing || old.leftHanded != leftHanded || old.fg != fg || old.accent != accent;
}

class _PianoPainter extends CustomPainter {
  final Set<int> lit;
  final Color fg;
  final Color accent;

  _PianoPainter(this.lit, this.fg, this.accent);

  static const _black = {1, 3, 6, 8, 10};

  @override
  void paint(Canvas canvas, Size size) {
    const from = 48, octaves = 2;
    final whites = [for (var m = from; m <= from + octaves * 12; m++) if (!_black.contains(m % 12)) m];
    final kw = size.width / whites.length;
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.black.withValues(alpha: 0.6);
    for (var i = 0; i < whites.length; i++) {
      final rect = Rect.fromLTWH(i * kw, 0, kw, size.height);
      canvas.drawRect(rect, Paint()..color = lit.contains(whites[i]) ? accent : const Color(0xFFE6E6E6));
      canvas.drawRect(rect, border);
    }
    for (var i = 0; i < whites.length; i++) {
      final b = whites[i] + 1;
      if (_black.contains(b % 12) && b < from + octaves * 12) {
        final rect = Rect.fromLTWH(i * kw + kw * 0.62, 0, kw * 0.76, size.height * 0.6);
        canvas.drawRect(rect, Paint()..color = lit.contains(b) ? Color.lerp(accent, Colors.black, 0.25)! : const Color(0xFF1C1C1C));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PianoPainter old) => old.lit != lit || old.accent != accent;
}
