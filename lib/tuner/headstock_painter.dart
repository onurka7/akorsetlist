import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'tuner_tunings.dart';

/// Geometry of one string on the headstock, in a 400×600 design space.
class StringGeometry {
  final Offset post;
  final Offset button;
  final Offset label;
  final bool leftSide;
  final double nutX;

  const StringGeometry(this.post, this.button, this.label, this.leftSide, this.nutX);
}

/// Shared by the painter and hit testing so taps map to the drawn strings.
class HeadstockGeometry {
  static const Size design = Size(400, 600);
  static const double nutY = 470;

  final HeadstockLayout layout;
  final List<StringGeometry> strings;

  HeadstockGeometry._(this.layout, this.strings);

  factory HeadstockGeometry(HeadstockLayout layout, int count) {
    final strings = <StringGeometry>[];
    double nutX(int i, double spacing) => 200 - (count - 1) / 2 * spacing + i * spacing;
    switch (layout) {
      case HeadstockLayout.inline6:
      case HeadstockLayout.inline4:
        final gap = count >= 6 ? 62.0 : 82.0;
        final slant = count >= 6 ? 14.0 : 18.0;
        for (var i = 0; i < count; i++) {
          final post = Offset(262 - i * slant, 70 + i * gap);
          strings.add(StringGeometry(post, post.translate(-78, 0), Offset(58, post.dy), true, nutX(i, 17)));
        }
      case HeadstockLayout.split3:
      case HeadstockLayout.split2:
        final perSide = count ~/ 2;
        final gap = perSide == 3 ? 92.0 : 120.0;
        for (var i = 0; i < count; i++) {
          final left = i < perSide;
          final row = left ? i : count - 1 - i; // outer strings closest to the nut
          final y = nutY - 90 - row * gap;
          strings.add(StringGeometry(
            Offset(left ? 165 : 235, y),
            Offset(left ? 105 : 295, y),
            Offset(left ? 42 : 358, y),
            left,
            nutX(i, count == 4 ? 20 : 15),
          ));
        }
      case HeadstockLayout.sidePegs:
        // Long saz/bağlama head with pegs alternating on both sides.
        final gap = (nutY - 110) / count;
        for (var i = 0; i < count; i++) {
          final left = i.isEven;
          final y = nutY - 50 - i * gap;
          strings.add(StringGeometry(
            Offset(left ? 186 : 214, y),
            Offset(left ? 128 : 272, y),
            Offset(left ? 58 : 342, y),
            left,
            nutX(i, 9),
          ));
        }
    }
    return HeadstockGeometry._(layout, strings);
  }

  Path bodyPath() {
    final p = Path();
    switch (layout) {
      case HeadstockLayout.inline6:
        p
          ..moveTo(150, 470)
          ..cubicTo(150, 420, 168, 380, 178, 330)
          ..lineTo(205, 60)
          ..cubicTo(210, 20, 245, 8, 280, 14)
          ..cubicTo(322, 22, 338, 52, 330, 92)
          ..cubicTo(322, 130, 296, 150, 290, 190)
          ..lineTo(262, 330)
          ..cubicTo(254, 380, 250, 420, 250, 470);
      case HeadstockLayout.inline4:
        p
          ..moveTo(150, 470)
          ..cubicTo(150, 420, 165, 380, 172, 330)
          ..lineTo(200, 50)
          ..cubicTo(205, 12, 248, 0, 288, 10)
          ..cubicTo(330, 22, 345, 60, 334, 100)
          ..cubicTo(322, 140, 300, 160, 293, 200)
          ..lineTo(264, 340)
          ..cubicTo(256, 390, 250, 420, 250, 470);
      case HeadstockLayout.split3:
        p
          ..moveTo(155, 470)
          ..cubicTo(150, 420, 140, 380, 132, 340)
          ..lineTo(120, 120)
          ..cubicTo(118, 70, 140, 40, 170, 38)
          ..lineTo(200, 50)
          ..lineTo(230, 38)
          ..cubicTo(260, 40, 282, 70, 280, 120)
          ..lineTo(268, 340)
          ..cubicTo(260, 380, 250, 420, 245, 470);
      case HeadstockLayout.split2:
        p
          ..moveTo(160, 470)
          ..cubicTo(152, 430, 140, 400, 136, 360)
          ..lineTo(128, 190)
          ..cubicTo(126, 150, 146, 128, 172, 126)
          ..lineTo(200, 136)
          ..lineTo(228, 126)
          ..cubicTo(254, 128, 274, 150, 272, 190)
          ..lineTo(264, 360)
          ..cubicTo(260, 400, 248, 430, 240, 470);
      case HeadstockLayout.sidePegs:
        p
          ..moveTo(172, 470)
          ..lineTo(170, 90)
          ..cubicTo(170, 60, 182, 44, 200, 40)
          ..cubicTo(218, 44, 230, 60, 230, 90)
          ..lineTo(228, 470);
    }
    return p..close();
  }

  /// Maps a widget-space point to the string whose label/peg was tapped.
  int? hitTest(Offset local, Size size, {bool mirrored = false}) {
    final fit = _fit(size);
    var x = (local.dx - fit.dx) / fit.scale;
    final y = (local.dy - fit.dy) / fit.scale;
    if (mirrored) x = design.width - x;
    int? best;
    var bestDist = 34.0;
    for (var i = 0; i < strings.length; i++) {
      for (final p in [strings[i].label, strings[i].button, strings[i].post]) {
        final d = (Offset(x, y) - p).distance;
        if (d < bestDist) {
          bestDist = d;
          best = i;
        }
      }
    }
    return best;
  }

  static ({double scale, double dx, double dy}) _fit(Size size) {
    final scale = (size.width / design.width).clamp(0.0, size.height / design.height).toDouble();
    return (scale: scale, dx: (size.width - design.width * scale) / 2, dy: (size.height - design.height * scale) / 2);
  }
}

enum TurnHint { none, tighten, loosen }

class HeadstockPainter extends CustomPainter {
  final HeadstockGeometry geometry;
  final List<String> labels;
  final int activeString;
  final Set<int> tuned;
  final TurnHint hint;
  final bool mirrored;
  final bool dimmed;

  static const green = Color(0xFF2FBF5A);
  static const flatColor = Color(0xFF2F7DE1);
  static const sharpColor = Color(0xFFE8711A);

  HeadstockPainter({
    required this.geometry,
    required this.labels,
    required this.activeString,
    required this.tuned,
    required this.hint,
    this.mirrored = false,
    this.dimmed = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fit = HeadstockGeometry._fit(size);
    canvas
      ..save()
      ..translate(fit.dx, fit.dy)
      ..scale(fit.scale);
    if (mirrored) {
      canvas
        ..translate(HeadstockGeometry.design.width, 0)
        ..scale(-1, 1);
    }
    const nutY = HeadstockGeometry.nutY;
    const h = 600.0;

    // Fretboard.
    final board = Path()
      ..moveTo(150, nutY)
      ..lineTo(250, nutY)
      ..lineTo(262, h)
      ..lineTo(138, h)
      ..close();
    canvas.drawPath(board, Paint()..shader = ui.Gradient.linear(const Offset(138, 0), const Offset(262, 0), const [Color(0xFF3B2416), Color(0xFF55331F), Color(0xFF3B2416)], const [0, .5, 1]));
    final fret = Paint()
      ..color = const Color(0xFFC9C3B8)
      ..strokeWidth = 3;
    for (var f = 0; f < 3; f++) {
      final y = nutY + 42 + f * 44;
      canvas.drawLine(Offset(149.0 - f * 4, y), Offset(251.0 + f * 4, y), fret);
    }
    canvas.drawCircle(const Offset(200, nutY + 108), 5, Paint()..color = const Color(0xFFE9E1D2));

    // Headstock body.
    final body = geometry.bodyPath();
    canvas.drawPath(body, Paint()..shader = ui.Gradient.linear(const Offset(120, 0), const Offset(340, 0), const [Color(0xFFC88A4A), Color(0xFFE2B071), Color(0xFFC3843F)], const [0, .5, 1]));
    canvas.drawPath(body, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFF8A5A2B));
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(146, nutY - 6, 108, 10), const Radius.circular(2)), Paint()..color = const Color(0xFFEFE8DA));

    final count = geometry.strings.length;
    for (var i = 0; i < count; i++) {
      final g = geometry.strings[i];
      final active = i == activeString && !dimmed;
      final isTuned = tuned.contains(i);
      // String line.
      final width = 2.6 - i * (1.6 / (count > 1 ? count - 1 : 1));
      final stringPaint = Paint()
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..color = active ? green : (isTuned ? const Color(0xFF9FE0B2) : (dimmed ? const Color(0xFFE3E5E9) : const Color(0xFFCFD3DA)));
      if (active) {
        canvas.drawLine(g.post, Offset(g.nutX, nutY), Paint()
          ..strokeWidth = width + 6
          ..color = green.withValues(alpha: 0.25)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      }
      canvas.drawLine(g.post, Offset(g.nutX, nutY), stringPaint);
      canvas.drawLine(Offset(g.nutX, nutY), Offset(g.nutX + (g.nutX - 200) * 0.12, h), stringPaint);

      // Tuner shaft, button and post.
      canvas.drawLine(g.post, g.button, Paint()
        ..strokeWidth = 5
        ..color = const Color(0xFF9AA1AB));
      final chrome = Paint()..shader = ui.Gradient.radial(g.button.translate(-5, -4), 20, const [Colors.white, Color(0xFFC9CED6), Color(0xFF8B929C)], const [0, .6, 1]);
      canvas.drawOval(Rect.fromCenter(center: g.button, width: 34, height: 24), chrome);
      canvas.drawCircle(g.post, 11, Paint()..shader = ui.Gradient.radial(g.post.translate(-3, -3), 12, const [Colors.white, Color(0xFFC9CED6), Color(0xFF8B929C)], const [0, .6, 1]));
      canvas.drawCircle(g.post, 4, Paint()..color = const Color(0xFF6C737D));
      if (active) {
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = green;
        canvas.drawOval(Rect.fromCenter(center: g.button, width: 34, height: 24), ring);
        canvas.drawCircle(g.post, 11, ring);
      }

      // Rotation hint arrow next to the active peg.
      if (active && hint != TurnHint.none) {
        final color = hint == TurnHint.tighten ? flatColor : sharpColor;
        final dir = g.leftSide ? 1.0 : -1.0;
        final cx = g.button.dx - 26 * dir;
        final arc = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = color;
        final rect = Rect.fromCircle(center: Offset(cx + 18 * dir, g.button.dy), radius: 24);
        canvas.drawArc(rect, dir > 0 ? 2.3 : -0.84, 1.68, false, arc);
        final tipY = hint == TurnHint.tighten ? g.button.dy - 24 : g.button.dy + 24;
        final back = hint == TurnHint.tighten ? 10.0 : -10.0;
        canvas.drawPath(
          Path()
            ..moveTo(cx - 6, tipY + back)
            ..lineTo(cx, tipY)
            ..lineTo(cx + 6, tipY + back)
            ..close(),
          Paint()..color = color,
        );
      }

      // Label circle.
      final labelFill = Paint()..color = isTuned ? green : (active ? green.withValues(alpha: 0.16) : Colors.white);
      canvas.drawCircle(g.label, 22, labelFill);
      canvas.drawCircle(g.label, 22, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 4 : 2
        ..color = active || isTuned ? green : (dimmed ? const Color(0xFFE5E5EA) : const Color(0xFFD1D1D6)));
      canvas.save();
      if (mirrored) {
        canvas
          ..translate(g.label.dx, 0)
          ..scale(-1, 1)
          ..translate(-g.label.dx, 0);
      }
      final tp = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: isTuned ? Colors.white : const Color(0xFF111111)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, g.label - Offset(tp.width / 2, tp.height / 2));
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant HeadstockPainter old) =>
      old.activeString != activeString ||
      old.hint != hint ||
      old.tuned.length != tuned.length ||
      !old.tuned.containsAll(tuned) ||
      old.labels.join() != labels.join() ||
      old.geometry != geometry ||
      old.mirrored != mirrored ||
      old.dimmed != dimmed;
}
