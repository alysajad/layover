import 'package:flutter/material.dart';

import 'theme.dart';

/// Original vector artwork, drawn locally so it stays crisp and works offline.
class TravelSketch extends StatelessWidget {
  const TravelSketch({super.key, this.height = 190});
  final double height;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _TravelPainter()),
    ),
  );
}

class PageIntro extends StatelessWidget {
  const PageIntro({
    super.key,
    required this.title,
    required this.subtitle,
    this.action,
  });
  final String title;
  final String subtitle;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            ?action,
          ],
        ),
        const SizedBox(height: 10),
        Text(
          subtitle,
          style: const TextStyle(color: LayoverColors.muted, height: 1.5),
        ),
      ],
    ),
  );
}

class _TravelPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = (size.width / 360).clamp(0.0, size.height / 210);
    canvas.save();
    canvas.translate(
      (size.width - 360 * scale) / 2,
      (size.height - 210 * scale) / 2,
    );
    canvas.scale(scale);
    final line = Paint()
      ..color = LayoverColors.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final black = Paint()..color = LayoverColors.ink;
    final white = Paint()..color = LayoverColors.paper;
    void shape(Path path, [Paint? fill]) {
      canvas.drawPath(path, fill ?? white);
      canvas.drawPath(path, line);
    }

    void stroke(Path path) => canvas.drawPath(path, line);
    canvas.drawOval(
      const Rect.fromLTWH(63, 35, 231, 169),
      Paint()..color = LayoverColors.wash,
    );
    canvas.drawCircle(
      const Offset(282, 37),
      20,
      Paint()..color = LayoverColors.mint,
    );
    // A wandering route and a tiny paper plane.
    final route = Path()
      ..moveTo(39, 104)
      ..cubicTo(5, 38, 120, 8, 138, 35)
      ..cubicTo(158, 62, 199, 16, 231, 20);
    for (final metric in route.computeMetrics()) {
      for (double i = 0; i < metric.length; i += 9) {
        canvas.drawPath(metric.extractPath(i, i + 3), line);
      }
    }
    shape(
      Path()
        ..moveTo(229, 19)
        ..lineTo(252, 10)
        ..lineTo(244, 32)
        ..lineTo(238, 24)
        ..close(),
    );
    stroke(
      Path()
        ..moveTo(238, 24)
        ..lineTo(252, 10),
    );
    // Palm tree.
    stroke(
      Path()
        ..moveTo(298, 197)
        ..quadraticBezierTo(292, 130, 307, 86)
        ..moveTo(306, 88)
        ..quadraticBezierTo(280, 68, 264, 91)
        ..quadraticBezierTo(286, 84, 306, 88)
        ..quadraticBezierTo(298, 55, 278, 61)
        ..moveTo(306, 87)
        ..quadraticBezierTo(319, 57, 338, 72)
        ..quadraticBezierTo(318, 69, 306, 87)
        ..quadraticBezierTo(331, 81, 341, 106)
        ..quadraticBezierTo(321, 91, 306, 87),
    );
    // Traveler on the left: loose trousers and oversized shirt.
    shape(
      Path()
        ..moveTo(109, 129)
        ..lineTo(145, 133)
        ..lineTo(149, 170)
        ..lineTo(139, 194)
        ..lineTo(124, 194)
        ..lineTo(130, 165)
        ..lineTo(122, 149)
        ..lineTo(112, 194)
        ..lineTo(96, 194)
        ..close(),
    );
    shape(
      Path()
        ..moveTo(96, 191)
        ..lineTo(112, 191)
        ..lineTo(116, 201)
        ..lineTo(85, 201)
        ..quadraticBezierTo(84, 196, 96, 191)
        ..close(),
      black,
    );
    shape(
      Path()
        ..moveTo(124, 192)
        ..lineTo(140, 192)
        ..lineTo(145, 201)
        ..lineTo(121, 201)
        ..close(),
      black,
    );
    shape(
      Path()
        ..moveTo(119, 74)
        ..quadraticBezierTo(105, 74, 98, 88)
        ..lineTo(88, 117)
        ..lineTo(101, 125)
        ..lineTo(112, 101)
        ..lineTo(106, 136)
        ..quadraticBezierTo(128, 147, 152, 131)
        ..lineTo(143, 92)
        ..lineTo(161, 110)
        ..lineTo(169, 99)
        ..lineTo(142, 76)
        ..close(),
    );
    shape(
      Path()
        ..moveTo(119, 65)
        ..lineTo(119, 79)
        ..quadraticBezierTo(128, 88, 134, 77)
        ..lineTo(132, 62)
        ..close(),
    );
    canvas.drawOval(const Rect.fromLTWH(116, 43, 25, 31), white);
    canvas.drawOval(const Rect.fromLTWH(116, 43, 25, 31), line);
    shape(
      Path()
        ..moveTo(115, 60)
        ..quadraticBezierTo(106, 35, 126, 34)
        ..quadraticBezierTo(148, 36, 140, 55)
        ..lineTo(128, 49)
        ..quadraticBezierTo(129, 61, 115, 60)
        ..close(),
      black,
    );
    stroke(
      Path()
        ..moveTo(133, 61)
        ..lineTo(137, 62)
        ..moveTo(127, 67)
        ..quadraticBezierTo(131, 70, 135, 67),
    );
    // Cross-body bag.
    stroke(
      Path()
        ..moveTo(116, 81)
        ..lineTo(145, 117)
        ..moveTo(110, 83)
        ..lineTo(139, 122),
    );
    shape(
      Path()
        ..moveTo(130, 104)
        ..lineTo(145, 101)
        ..lineTo(150, 117)
        ..quadraticBezierTo(141, 130, 130, 120)
        ..close(),
      Paint()..color = LayoverColors.mint,
    );
    // Hand and rolling suitcase.
    shape(
      Path()
        ..moveTo(89, 115)
        ..lineTo(84, 134)
        ..quadraticBezierTo(89, 144, 94, 134)
        ..lineTo(101, 122)
        ..close(),
    );
    stroke(
      Path()
        ..moveTo(88, 136)
        ..lineTo(78, 154)
        ..moveTo(73, 152)
        ..lineTo(83, 158),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(52, 153, 33, 43),
        const Radius.circular(7),
      ),
      white,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(52, 153, 33, 43),
        const Radius.circular(7),
      ),
      line,
    );
    stroke(
      Path()
        ..moveTo(61, 162)
        ..lineTo(61, 187)
        ..moveTo(74, 162)
        ..lineTo(74, 187),
    );
    canvas.drawCircle(const Offset(59, 200), 3, black);
    canvas.drawCircle(const Offset(79, 200), 3, black);
    // Second traveler, looking at the folded map.
    shape(
      Path()
        ..moveTo(208, 127)
        ..lineTo(241, 125)
        ..lineTo(251, 191)
        ..lineTo(236, 194)
        ..lineTo(224, 155)
        ..lineTo(217, 194)
        ..lineTo(203, 194)
        ..close(),
    );
    shape(
      Path()
        ..moveTo(201, 191)
        ..lineTo(217, 191)
        ..lineTo(219, 201)
        ..lineTo(190, 201)
        ..quadraticBezierTo(190, 195, 201, 191)
        ..close(),
      black,
    );
    shape(
      Path()
        ..moveTo(236, 191)
        ..lineTo(251, 191)
        ..lineTo(263, 201)
        ..lineTo(236, 201)
        ..close(),
      black,
    );
    shape(
      Path()
        ..moveTo(216, 78)
        ..quadraticBezierTo(239, 75, 243, 100)
        ..lineTo(248, 133)
        ..quadraticBezierTo(227, 141, 204, 131)
        ..lineTo(210, 99)
        ..lineTo(190, 115)
        ..lineTo(182, 105)
        ..close(),
    );
    shape(
      Path()
        ..moveTo(216, 68)
        ..lineTo(215, 80)
        ..quadraticBezierTo(222, 90, 229, 80)
        ..lineTo(228, 67)
        ..close(),
    );
    canvas.drawOval(const Rect.fromLTWH(207, 45, 26, 31), white);
    canvas.drawOval(const Rect.fromLTWH(207, 45, 26, 31), line);
    canvas.drawCircle(const Offset(234, 36), 15, black);
    shape(
      Path()
        ..moveTo(208, 55)
        ..quadraticBezierTo(211, 37, 227, 45)
        ..quadraticBezierTo(242, 54, 230, 68)
        ..lineTo(222, 53)
        ..quadraticBezierTo(219, 61, 208, 55)
        ..close(),
      black,
    );
    stroke(
      Path()
        ..moveTo(211, 62)
        ..lineTo(214, 62)
        ..moveTo(213, 69)
        ..quadraticBezierTo(217, 71, 220, 68),
    );
    shape(
      Path()
        ..moveTo(156, 92)
        ..lineTo(172, 87)
        ..lineTo(187, 95)
        ..lineTo(199, 91)
        ..lineTo(196, 124)
        ..lineTo(182, 128)
        ..lineTo(170, 120)
        ..lineTo(157, 123)
        ..close(),
    );
    stroke(
      Path()
        ..moveTo(172, 88)
        ..lineTo(170, 120)
        ..moveTo(187, 96)
        ..lineTo(182, 128),
    );
    shape(
      Path()
        ..moveTo(239, 101)
        ..lineTo(219, 120)
        ..lineTo(196, 113)
        ..lineTo(192, 120)
        ..quadraticBezierTo(220, 137, 228, 129)
        ..lineTo(246, 114),
    );
    canvas.drawCircle(
      const Offset(178, 106),
      3,
      Paint()..color = LayoverColors.mint,
    );
    stroke(
      Path()
        ..moveTo(24, 204)
        ..quadraticBezierTo(165, 201, 338, 204),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TravelPainter oldDelegate) => false;
}
