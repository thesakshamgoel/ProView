import 'package:flutter/material.dart';

import '../theme.dart';

/// The app's backdrop: pure white (light) or pure black (dark) with a slight, evenly spaced grid.
/// Painted once and cached, so it costs nothing while content scrolls over it.
class GridPattern extends StatelessWidget {
  const GridPattern({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return RepaintBoundary(
      child: CustomPaint(
        isComplex: true,
        willChange: false,
        painter: _GridPainter(
          background: p.groupedBackground,
          line: (p.isDark ? Colors.white : Colors.black).withValues(alpha: p.isDark ? 0.055 : 0.05),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final Color background;
  final Color line;
  _GridPainter({required this.background, required this.line});

  static const double step = 28;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final path = Path();
    for (double x = step; x < size.width; x += step) {
      path.moveTo(x, 0);
      path.lineTo(x, size.height);
    }
    for (double y = step; y < size.height; y += step) {
      path.moveTo(0, y);
      path.lineTo(size.width, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..isAntiAlias = false,
    );
    // Fade the grid out toward the edges a little so it stays a texture, not a pattern fighting the content.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 1.15,
          colors: [background.withValues(alpha: 0), background.withValues(alpha: 0.55)],
          stops: const [0.45, 1],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.background != background || old.line != line;
}
