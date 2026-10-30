import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

// Plain blur: composing a colour matrix with it costs an extra full pass per glass surface on every frame.
ui.ImageFilter glassFilter(double sigma) => ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp);

/// The Liquid Glass material: a blurred, saturated view of what's behind, a light tint, a specular rim
/// along the edge and a soft inner highlight. Shapes use Apple's continuous (superellipse) corners.
class LiquidGlass extends StatelessWidget {
  final Widget child;

  /// Corner radius; null makes a capsule (or a circle when the child is square).
  final double? radius;
  final Color? tint;

  /// Tinted with the accent colour, for the main action on a screen.
  final bool prominent;
  final double blur;
  final EdgeInsetsGeometry? padding;
  final bool shadow;

  /// Share one backdrop read with sibling glass under the same [BackdropGroup] (cheaper).
  final bool grouped;

  const LiquidGlass({
    super.key,
    required this.child,
    this.radius,
    this.tint,
    this.prominent = false,
    this.blur = 14,
    this.padding,
    this.shadow = true,
    this.grouped = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final fill = tint ?? (prominent ? p.accent.withValues(alpha: 0.92) : p.glassTint);
    return CustomPaint(
      painter: _GlassShadow(radius: radius, enabled: shadow, color: p.glassShadow),
      foregroundPainter: _GlassRim(radius: radius, dark: p.isDark, prominent: prominent),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(radius ?? 999),
        child: _backdrop(
          child: DecoratedBox(
            decoration: BoxDecoration(color: fill),
            child: DecoratedBox(
              // Light catching the top of the glass.
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white.withValues(alpha: p.isDark ? 0.08 : 0.25), Colors.white.withValues(alpha: 0)],
                  stops: const [0, 0.55],
                ),
              ),
              child: padding == null ? child : Padding(padding: padding!, child: child),
            ),
          ),
        ),
      ),
    );
  }

  Widget _backdrop({required Widget child}) {
    if (blur <= 0) return child;
    return grouped
        ? BackdropFilter.grouped(filter: glassFilter(blur), child: child)
        : BackdropFilter(filter: glassFilter(blur), child: child);
  }
}

Path _shape(Rect rect, double? radius) {
  final r = radius ?? rect.shortestSide / 2;
  return RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(r)).getOuterPath(rect);
}

class _GlassRim extends CustomPainter {
  final double? radius;
  final bool dark;
  final bool prominent;
  _GlassRim({required this.radius, required this.dark, required this.prominent});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = _shape(rect.deflate(0.5), radius == null ? null : radius! - 0.5);
    final a = dark ? 0.42 : 0.9;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: a),
          Colors.white.withValues(alpha: a * 0.12),
          Colors.white.withValues(alpha: a * 0.04),
          Colors.white.withValues(alpha: a * (prominent ? 0.5 : 0.35)),
        ],
        stops: const [0, 0.35, 0.65, 1],
      ).createShader(rect);
    canvas.drawPath(path, paint);
    if (!dark) {
      // A hairline of shade on light backgrounds keeps the edge readable on white.
      canvas.drawPath(
          _shape(rect, radius),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.5
            ..color = Colors.black.withValues(alpha: 0.06));
    }
  }

  @override
  bool shouldRepaint(_GlassRim old) => old.radius != radius || old.dark != dark || old.prominent != prominent;
}

class _GlassShadow extends CustomPainter {
  final double? radius;
  final bool enabled;
  final Color color;
  _GlassShadow({required this.radius, required this.enabled, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (!enabled) return;
    // Soft shadow from stacked, growing, fading shapes: no blur pass, so it costs next to nothing per frame.
    final base = (Offset.zero & size).translate(0, 6);
    const steps = 5;
    for (var i = steps - 1; i >= 0; i--) {
      final grow = i * 3.4;
      final fade = (1 - i / steps);
      canvas.drawPath(
        _shape(base.inflate(grow), radius == null ? null : radius! + grow),
        Paint()..color = color.withValues(alpha: color.a * 0.32 * fade * fade),
      );
    }
  }

  @override
  bool shouldRepaint(_GlassShadow old) => old.radius != radius || old.enabled != enabled || old.color != color;
}

/// Responds to touch the way Liquid Glass controls do: a quick squish with a brightening sheen, then a
/// springy release.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final bool haptics;
  const Pressable({super.key, required this.child, this.onTap, this.onLongPress, this.scale = 0.95, this.haptics = true});
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 420));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _down() => _c.forward();
  void _up() => _c.reverse();

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _down() : null,
      onTapUp: enabled ? (_) => _up() : null,
      onTapCancel: enabled ? _up : null,
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptics) HapticFeedback.selectionClick();
              widget.onTap!();
            },
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              _up();
              HapticFeedback.mediumImpact();
              widget.onLongPress!();
            },
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = _c.status == AnimationStatus.reverse
              ? Motion.spring.transform(_c.value)
              : Curves.easeOut.transform(_c.value);
          return Transform.scale(scale: 1 - (1 - widget.scale) * t, child: child);
        },
        child: widget.child,
      ),
    );
  }
}

/// Round glass button with an icon (toolbar buttons, player controls).
class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double? iconSize;
  final Color? color;
  final bool prominent;
  final bool grouped;
  final String? semanticLabel;
  const GlassIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 44,
    this.iconSize,
    this.color,
    this.prominent = false,
    this.grouped = false,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Pressable(
        onTap: onTap,
        scale: 0.88,
        // A 44 px circle gains nothing from blurring what's behind it, and a live backdrop blur per button is
        // costly while the page scrolls under it: use a more solid tint instead.
        child: LiquidGlass(
          prominent: prominent,
          grouped: grouped,
          blur: 0,
          shadow: false,
          tint: prominent ? null : (p.isDark ? const Color(0xD92A2A2C) : const Color(0xE6FFFFFF)),
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: iconSize ?? size * 0.45, color: color ?? (prominent ? Colors.white : p.label)),
          ),
        ),
      ),
    );
  }
}

/// Capsule glass button with a label (and optional icon).
class GlassButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool prominent;
  final Color? color;
  final double height;
  final bool expand;
  const GlassButton(this.label,
      {super.key, this.icon, this.onTap, this.prominent = false, this.color, this.height = 52, this.expand = true});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final enabled = onTap != null;
    final fg = prominent ? Colors.white : (color ?? p.accent);
    final content = Row(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
      if (icon != null) ...[Icon(icon, size: 19, color: fg), const SizedBox(width: 8)],
      Flexible(
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.fade,
            style: TextStyles.headline(p).copyWith(color: fg)),
      ),
    ]);
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Pressable(
        onTap: onTap,
        scale: 0.96,
        child: LiquidGlass(
          prominent: prominent,
          tint: prominent && color != null ? color!.withValues(alpha: 0.92) : null,
          child: SizedBox(
            height: height,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 22), child: content),
          ),
        ),
      ),
    );
  }
}
