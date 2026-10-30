import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../ui/cutout.dart';
import 'logo_paths.dart';

/// Ring outlines, built once.
final List<Path> _rings = [
  for (final ops in kLogoRings) _build(ops),
];

Path _build(List<double> ops) {
  final p = Path()..fillType = PathFillType.evenOdd;
  var i = 0;
  while (i < ops.length) {
    switch (ops[i].toInt()) {
      case 0:
        p.moveTo(ops[i + 1], ops[i + 2]);
        i += 3;
      case 1:
        p.lineTo(ops[i + 1], ops[i + 2]);
        i += 3;
      default:
        p.cubicTo(ops[i + 1], ops[i + 2], ops[i + 3], ops[i + 4], ops[i + 5], ops[i + 6]);
        i += 7;
    }
  }
  p.close();
  return p;
}

/// The rounded play symbol at the centre of the mark (unit coordinates).
Path _play() {
  const corners = [Offset(-0.215, -0.27), Offset(-0.215, 0.27), Offset(0.285, 0)];
  const r = 0.075;
  final p = Path();
  for (var i = 0; i < 3; i++) {
    final c = corners[i];
    final prev = corners[(i + 2) % 3];
    final next = corners[(i + 1) % 3];
    final a = c + (prev - c) / (prev - c).distance * r;
    final b = c + (next - c) / (next - c).distance * r;
    i == 0 ? p.moveTo(a.dx, a.dy) : p.lineTo(a.dx, a.dy);
    p.quadraticBezierTo(c.dx, c.dy, b.dx, b.dy);
  }
  return p..close();
}

final Path _playPath = _play();

/// Colours of the four rings, innermost first: light cyan-blue to deep blue (from the logo reference).
const _ringColors = [
  [Color(0xFF6FBDFF), Color(0xFF2F6BF2)],
  [Color(0xFF5AAAFF), Color(0xFF2A63EE)],
  [Color(0xFF4B97FF), Color(0xFF2459E8)],
  [Color(0xFF4290FF), Color(0xFF1F55E6)],
];

/// Paints the ProView mark. Every ring can be turned independently, which is what all the
/// loading animations are made of.
class LogoPainter extends CustomPainter {
  /// Rotation of each ring in radians, innermost first.
  final List<double> turns;

  /// 0..1: how much of each ring is drawn in colour (the rest is a faint track). 1 = whole logo.
  final double progress;

  /// Scale of each ring around the centre (for the breathing / assembling effects).
  final List<double> scales;
  final double opacity;
  final bool play;
  final double playScale;

  /// Solid colour instead of the brand gradients (e.g. white on dark glass).
  final Color? mono;
  final Color trackColor;

  LogoPainter({
    this.turns = const [0, 0, 0, 0],
    this.progress = 1,
    this.scales = const [1, 1, 1, 1],
    this.opacity = 1,
    this.play = false,
    this.playScale = 1,
    this.mono,
    this.trackColor = const Color(0x22808080),
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final c = size.center(Offset.zero);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.scale(r);
    final full = progress >= 0.999;
    for (var i = 0; i < _rings.length; i++) {
      canvas.save();
      canvas.rotate(turns[i]);
      canvas.scale(scales[i]);
      if (!full) {
        canvas.drawPath(_rings[i], Paint()..color = trackColor);
        canvas.save();
        // Reveal the coloured ring clockwise from 12 o'clock, undoing this ring's own rotation.
        canvas.rotate(-turns[i]);
        canvas.clipPath(Path()
          ..moveTo(0, 0)
          ..arcTo(const Rect.fromLTRB(-1.2, -1.2, 1.2, 1.2), -math.pi / 2, 2 * math.pi * progress, false)
          ..close());
        canvas.rotate(turns[i]);
      }
      canvas.drawPath(_rings[i], _ringPaint(i));
      if (!full) canvas.restore();
      canvas.restore();
    }
    if (play && playScale > 0) {
      canvas.save();
      canvas.scale(playScale);
      final paint = Paint()..isAntiAlias = true;
      if (mono != null) {
        paint.color = mono!.withValues(alpha: opacity);
      } else {
        paint.shader = LinearGradient(
          begin: const Alignment(0.6, -0.6),
          end: const Alignment(-0.4, 0.6),
          colors: [const Color(0xFF7CCBFF).withValues(alpha: opacity), const Color(0xFF1E5BEA).withValues(alpha: opacity)],
        ).createShader(const Rect.fromLTRB(-0.3, -0.3, 0.3, 0.3));
      }
      canvas.drawPath(_playPath, paint);
      canvas.restore();
    }
    canvas.restore();
  }

  Paint _ringPaint(int i) {
    final paint = Paint()..isAntiAlias = true;
    // Overlaps read darker, as in the artwork, because each ring is slightly translucent.
    final a = 0.84 * opacity;
    if (mono != null) {
      paint.color = mono!.withValues(alpha: mono!.a * a);
    } else {
      paint.shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_ringColors[i][0].withValues(alpha: a), _ringColors[i][1].withValues(alpha: a)],
      ).createShader(const Rect.fromLTRB(-1, -1, 1, 1));
    }
    return paint;
  }

  @override
  bool shouldRepaint(LogoPainter old) => true;
}

/// The logo exactly as designed (Logos/Logo 1.png): nothing added to it, nothing recoloured.
class ProViewLogo extends StatelessWidget {
  final double size;
  const ProViewLogo({super.key, this.size = 64});
  @override
  Widget build(BuildContext context) => Image.asset(
        'assets/brand/logo.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
      );
}

/// ProView's loader: the logo itself, turning one lobe at a time with a gentle breath. The mark repeats every
/// 36 degrees, so each step lands on exactly the same picture and the loop never shows a seam.
class LogoSpinner extends StatefulWidget {
  final double size;
  const LogoSpinner({super.key, this.size = 28});
  @override
  State<LogoSpinner> createState() => _LogoSpinnerState();
}

class _LogoSpinnerState extends State<LogoSpinner> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          child: ProViewLogo(size: widget.size),
          builder: (context, logo) {
            final t = _c.value;
            final e = Curves.easeInOutCubic.transform((t * 2) % 1.0);
            final steps = (t < 0.5 ? 0 : 1) + e;
            final breath = 1 + 0.035 * math.sin(t * 4 * math.pi);
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.rotationZ(steps * 2 * math.pi / 10)..scaleByDouble(breath, breath, 1, 1),
              child: logo,
            );
          },
        ),
      ),
    );
  }
}

/// Pull-to-refresh with the logo: the rings wind up as you pull, then spin while refreshing.
Widget logoRefreshIndicator(
  BuildContext context,
  RefreshIndicatorMode mode,
  double pulledExtent,
  double refreshTriggerPullDistance,
  double refreshIndicatorExtent,
) {
  final pull = (pulledExtent / refreshTriggerPullDistance).clamp(0.0, 1.0);
  final spinning = mode == RefreshIndicatorMode.refresh || mode == RefreshIndicatorMode.armed;
  // On a phone with a camera hole the logo drops out of it as you pull; otherwise it simply fades in.
  final cutout = Cutout.of(context);
  final width = MediaQuery.sizeOf(context).width;
  final x = cutout == null ? 0.0 : ((cutout.center.dx / width) * 2 - 1);
  final fall = cutout == null ? 0.0 : (1 - Curves.easeOutCubic.transform(pull)) * -(pulledExtent * 0.9);
  return Align(
    alignment: Alignment(x, 0),
    child: Transform.translate(offset: Offset(0, fall), child: _refreshLogo(mode, pull, spinning)),
  );
}

Widget _refreshLogo(RefreshIndicatorMode mode, double pull, bool spinning) {
  return Center(
    child: Opacity(
      opacity: mode == RefreshIndicatorMode.done ? 0.0 : (pull * 1.4).clamp(0.0, 1.0),
      child: spinning
          ? const LogoSpinner(size: 30)
          // Pulling turns the real logo and grows it into place.
          : Transform(
              alignment: Alignment.center,
              transform: Matrix4.rotationZ(pull * 2 * math.pi / 5)
                ..scaleByDouble(0.6 + 0.4 * Curves.easeOut.transform(pull), 0.6 + 0.4 * Curves.easeOut.transform(pull), 1, 1),
              child: const ProViewLogo(size: 30),
            ),
    ),
  );
}

/// Determinate progress with the mark: rings fill clockwise in colour over a faint track and keep
/// turning gently so it never looks frozen. Used for conversions.
class LogoProgress extends StatefulWidget {
  final double? value;
  final double size;
  final Color? trackColor;
  const LogoProgress({super.key, required this.value, this.size = 44, this.trackColor});
  @override
  State<LogoProgress> createState() => _LogoProgressState();
}

class _LogoProgressState extends State<LogoProgress> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    if (v == null) return LogoSpinner(size: widget.size);
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: v.clamp(0.0, 1.0)),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          builder: (context, value, _) => AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final a = _c.value * 2 * math.pi;
              return CustomPaint(
                painter: LogoPainter(
                  progress: value,
                  turns: [a * 0.2, -a * 0.1, a * 0.1, -a * 0.2],
                  trackColor: widget.trackColor ?? const Color(0x26808080),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The welcome / launch animation: the logo turns into place and settles. Nothing is added to it.
class LogoIntro extends StatefulWidget {
  final double size;
  final VoidCallback? onDone;
  const LogoIntro({super.key, this.size = 120, this.onDone});
  @override
  State<LogoIntro> createState() => _LogoIntroState();
}

class _LogoIntroState extends State<LogoIntro> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));

  @override
  void initState() {
    super.initState();
    _c.forward().whenComplete(() => widget.onDone?.call());
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        child: ProViewLogo(size: widget.size),
        builder: (context, logo) {
          final t = _c.value;
          final settle = Curves.easeOutBack.transform((t / 0.85).clamp(0.0, 1.0));
          final scale = 0.55 + 0.45 * settle;
          return Opacity(
            opacity: Curves.easeOut.transform((t / 0.3).clamp(0.0, 1.0)),
            child: Transform(
              alignment: Alignment.center,
              // Two lobes of turn, landing on the same picture: it winds into place.
              transform: Matrix4.rotationZ((1 - settle) * -2 * math.pi / 5)..scaleByDouble(scale, scale, 1, 1),
              child: logo,
            ),
          );
        },
      ),
    );
  }
}
