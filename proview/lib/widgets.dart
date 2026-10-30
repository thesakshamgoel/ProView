import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand/logo.dart';
import 'library.dart';
import 'theme.dart';
import 'ui/glass.dart';
import 'ui/grid_pattern.dart';
import 'ui/app_icons.dart';

export 'brand/logo.dart';
export 'ui/glass.dart';

/// Small capsule label on thumbnails. Solid translucent fill (no blur) so long grids stay smooth.
class FormatBadge extends StatelessWidget {
  final String text;
  final Color? color;
  final IconData? icon;

  /// Shrinks the badge on small tiles so it always fits.
  final double scale;
  const FormatBadge(this.text, {super.key, this.color, this.icon, this.scale = 1});
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: (color ?? Colors.black).withValues(alpha: color == null ? 0.5 : 0.88),
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 7 * scale, vertical: 3 * scale),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 10 * scale, color: Colors.white), SizedBox(width: 3 * scale)],
          Text(text,
              style: TextStyle(
                  fontFamily: kFont,
                  fontSize: 10.5 * scale,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.15)),
        ]),
      ),
    );
  }
}

/// Inset grouped list section (iOS 26: larger, continuous corners).
class GroupedSection extends StatelessWidget {
  final String? header;
  final String? footer;
  final List<Widget> children;
  final EdgeInsets margin;
  const GroupedSection({
    super.key,
    this.header,
    this.footer,
    required this.children,
    this.margin = const EdgeInsets.fromLTRB(Insets.card, 0, Insets.card, 28),
  });
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // Rows that have nothing to show (SizedBox.shrink) don't leave a gap or a stray divider.
    final shown = children.where((c) => !(c is SizedBox && c.width == 0 && c.height == 0)).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    final rows = <Widget>[];
    for (var i = 0; i < shown.length; i++) {
      rows.add(shown[i]);
      if (i < shown.length - 1) {
        rows.add(Padding(
          padding: const EdgeInsets.only(left: Insets.card),
          child: Container(height: 0.5, color: p.separator),
        ));
      }
    }
    return Padding(
      padding: margin,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Insets.card, 0, Insets.card, 8),
            child: Text(header!, style: TextStyles.footnote(p).copyWith(fontWeight: FontWeight.w600)),
          ),
        ClipRSuperellipse(
          borderRadius: BorderRadius.circular(Insets.radius),
          child: ColoredBox(color: p.surface, child: Column(children: rows)),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Insets.card, 8, Insets.card, 0),
            child: Text(footer!, style: TextStyles.footnote(p)),
          ),
      ]),
    );
  }
}

class GroupedRow extends StatefulWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool chevron;
  final Color? titleColor;
  const GroupedRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.chevron = false,
    this.titleColor,
  });
  @override
  State<GroupedRow> createState() => _GroupedRowState();
}

class _GroupedRowState extends State<GroupedRow> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final row = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      color: _down ? p.fill : p.fill.withValues(alpha: 0),
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: Insets.card, vertical: 11),
      child: Row(children: [
        if (widget.leading != null) ...[widget.leading!, const SizedBox(width: 14)],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(widget.title, style: TextStyles.body(p).copyWith(color: widget.titleColor ?? p.label)),
            if (widget.subtitle != null) ...[
              const SizedBox(height: 2),
              Text(widget.subtitle!, style: TextStyles.footnote(p)),
            ],
          ]),
        ),
        if (widget.value != null)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(widget.value!,
                  textAlign: TextAlign.right,
                  style: TextStyles.body(p).copyWith(color: p.secondaryLabel),
                  maxLines: 2,
                  overflow: TextOverflow.fade),
            ),
          ),
        if (widget.trailing != null) ...[const SizedBox(width: 10), widget.trailing!],
        if (widget.chevron) ...[
          const SizedBox(width: 6),
          Icon(AppIcons.chevron_forward, size: 16, color: p.tertiaryLabel),
        ],
      ]),
    );
    if (widget.onTap == null && widget.onLongPress == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              widget.onTap!();
            },
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              setState(() => _down = false);
              HapticFeedback.mediumImpact();
              widget.onLongPress!();
            },
      child: row,
    );
  }
}

/// Rounded-square coloured icon, like iOS Settings.
class IconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  const IconTile(this.icon, this.color, {super.key, this.size = 30});
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: ShapeDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color.lerp(color, Colors.white, 0.12)!, color],
          ),
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(size * 0.28)),
        ),
        child: SizedBox.square(dimension: size, child: Icon(icon, color: Colors.white, size: size * 0.6)),
      );
}

/// Main call to action (filled = tinted glass, otherwise clear glass with accent text).
class PrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color? color;
  final bool filled;
  const PrimaryButton(this.label, {super.key, this.icon, this.onPressed, this.color, this.filled = true});
  @override
  Widget build(BuildContext context) =>
      GlassButton(label, icon: icon, onTap: onPressed, prominent: filled, color: color);
}

/// Thin capsule progress bar that glides between values; indeterminate shows a travelling highlight.
class ThinProgress extends StatefulWidget {
  final double? value;
  final Color? color;
  final double height;
  const ThinProgress({super.key, this.value, this.color, this.height = 5});
  @override
  State<ThinProgress> createState() => _ThinProgressState();
}

class _ThinProgressState extends State<ThinProgress> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    if (widget.value == null) _c.repeat();
  }

  @override
  void didUpdateWidget(ThinProgress old) {
    super.didUpdateWidget(old);
    if (widget.value == null && !_c.isAnimating) _c.repeat();
    if (widget.value != null && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = widget.color ?? p.accent;
    return SizedBox(
      height: widget.height,
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(widget.height),
        child: ColoredBox(
          color: color.withValues(alpha: 0.16),
          child: widget.value == null
              ? AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) => FractionallySizedBox(
                    alignment: Alignment(-1.6 + 3.2 * Curves.easeInOut.transform(_c.value), 0),
                    widthFactor: 0.35,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [color.withValues(alpha: 0), color, color.withValues(alpha: 0)]),
                      ),
                    ),
                  ),
                )
              : TweenAnimationBuilder<double>(
                  tween: Tween(end: widget.value!.clamp(0.0, 1.0)),
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOutCubic,
                  builder: (context, v, _) => FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: v,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(widget.height)),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Shimmering placeholder block shown while a value loads (instead of "…" text).
class Skeleton extends StatefulWidget {
  final double width;
  final double height;
  const Skeleton({super.key, this.width = 80, this.height = 14});
  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.height / 2),
          gradient: LinearGradient(
            begin: Alignment(-2 + 4 * _c.value, 0),
            end: Alignment(-1 + 4 * _c.value, 0),
            colors: [p.fill, p.fill.withValues(alpha: p.fill.a * 2.4), p.fill],
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String message;
  final Widget? action;
  final bool logo;
  const EmptyState({super.key, this.icon, required this.title, required this.message, this.action, this.logo = false});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 48),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (logo)
            const ProViewLogo(size: 76)
          else
            Container(
              width: 76,
              height: 76,
              decoration: ShapeDecoration(color: p.fill, shape: const CircleBorder()),
              child: Icon(icon ?? AppIcons.film, size: 34, color: p.secondaryLabel),
            ),
          const SizedBox(height: 20),
          Text(title, style: TextStyles.title3(p), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(message, style: TextStyles.subhead(p).copyWith(color: p.secondaryLabel), textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 24), action!],
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sheets and menus

/// Floating glass sheet, inset from the screen edges with large continuous corners (iOS 26 style).
Future<T?> showAppSheet<T>(BuildContext context,
    {required Widget Function(BuildContext context, ScrollController controller) builder, double initialSize = 0.88}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    enableDrag: false, // the draggable sheet below handles the gesture, including over scrolling content
    barrierColor: Colors.black.withValues(alpha: 0.32),
    sheetAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 460),
      reverseDuration: Duration(milliseconds: 300),
      curve: Motion.emphasized,
    ),
    builder: (ctx) {
      final p = Palette.of(ctx);
      final bottom = MediaQuery.paddingOf(ctx).bottom;
      // Drag anywhere on the card: it follows the finger, scrolls its content when it is fully open, and
      // slides away when pulled down (or flicked), like an iOS sheet.
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: initialSize,
        minChildSize: 0.4,
        maxChildSize: 0.96,
        snap: true,
        snapSizes: [initialSize],
        builder: (ctx, controller) => Padding(
          padding: EdgeInsets.fromLTRB(8, 0, 8, bottom > 0 ? 6 : 8),
          child: LiquidGlass(
            radius: 38,
            blur: 30,
            tint: p.isDark ? const Color(0xE61C1C1E) : const Color(0xF2F7F7FA),
            child: Stack(children: [
              builder(ctx, controller),
              // The grabber floats above the content.
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      width: 38,
                      height: 5,
                      decoration: BoxDecoration(color: p.tertiaryLabel, borderRadius: BorderRadius.circular(3)),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
    },
  );
}

/// One row of a glass menu.
class MenuAction {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool destructive;
  const MenuAction(this.label, {this.icon, required this.onTap, this.destructive = false});
}

/// Liquid Glass context menu. It grows out of [anchor] (the pressed tile or button) with a spring;
/// without an anchor it rises from the bottom like an action sheet.
Future<void> showGlassMenu(BuildContext context,
    {BuildContext? anchor, String? title, String? message, required List<MenuAction> actions}) {
  Rect? rect;
  final box = anchor?.findRenderObject() as RenderBox?;
  if (box != null && box.hasSize) rect = box.localToGlobal(Offset.zero) & box.size;
  HapticFeedback.mediumImpact();
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.18),
    transitionDuration: const Duration(milliseconds: 420),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, anim, _) => _GlassMenu(anchor: rect, title: title, message: message, actions: actions, anim: anim),
  ));
}

class _GlassMenu extends StatelessWidget {
  final Rect? anchor;
  final String? title;
  final String? message;
  final List<MenuAction> actions;
  final Animation<double> anim;
  const _GlassMenu({required this.anchor, required this.title, required this.message, required this.actions, required this.anim});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final mq = MediaQuery.of(context);
    final size = mq.size;
    const width = 260.0;
    final menu = LiquidGlass(
      radius: 28,
      blur: 26,
      tint: p.isDark ? const Color(0xCC2A2A2C) : const Color(0xE6FAFAFC),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: size.height * 0.6),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (title != null || message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (title != null)
                    Text(title!,
                        maxLines: 2,
                        overflow: TextOverflow.fade,
                        style: TextStyles.subhead(p).copyWith(fontWeight: FontWeight.w600)),
                  if (message != null) ...[
                    const SizedBox(height: 2),
                    Text(message!, style: TextStyles.caption(p)),
                  ],
                ]),
              ),
            if (title != null || message != null)
              Container(height: 0.5, margin: const EdgeInsets.symmetric(horizontal: 12), color: p.separator),
            for (final a in actions) _MenuRow(action: a),
          ]),
        ),
      ),
    );

    // Place next to the anchor when there is one, otherwise above the bottom edge.
    double left, top;
    Alignment origin;
    if (anchor != null) {
      left = (anchor!.center.dx - width / 2).clamp(12.0, size.width - width - 12);
      final below = anchor!.bottom + 10;
      final roomBelow = size.height - mq.padding.bottom - below;
      final estimated = 56.0 * actions.length + (title != null ? 64 : 12);
      if (roomBelow > estimated || anchor!.top < size.height / 2) {
        top = math.min(below, size.height - mq.padding.bottom - estimated - 12).clamp(mq.padding.top + 8, size.height);
        origin = Alignment.topCenter;
      } else {
        top = math.max(mq.padding.top + 8, anchor!.top - 10 - estimated);
        origin = Alignment.bottomCenter;
      }
    } else {
      left = (size.width - width) / 2;
      top = double.nan;
      origin = Alignment.bottomCenter;
    }
    final curved = CurvedAnimation(parent: anim, curve: Motion.spring, reverseCurve: Curves.easeIn);
    final animated = AnimatedBuilder(
      animation: curved,
      builder: (context, child) => Opacity(
        opacity: anim.value.clamp(0.0, 1.0),
        child: Transform.scale(alignment: origin, scale: 0.6 + 0.4 * curved.value, child: child),
      ),
      child: SizedBox(width: width, child: menu),
    );
    return Material(
      type: MaterialType.transparency,
      child: Stack(children: [
      Positioned.fill(child: GestureDetector(onTap: () => Navigator.pop(context))),
      if (top.isNaN)
        Positioned(left: left, bottom: mq.padding.bottom + 16, child: animated)
      else
        Positioned(left: left, top: top, child: animated),
      ]),
    );
  }
}

class _MenuRow extends StatefulWidget {
  final MenuAction action;
  const _MenuRow({required this.action});
  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = widget.action.destructive ? p.red : p.label;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.pop(context);
        widget.action.onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: ShapeDecoration(
          color: _down ? p.fill.withValues(alpha: p.fill.a * 2) : p.fill.withValues(alpha: 0),
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
        ),
        child: Row(children: [
          Expanded(child: Text(widget.action.label, style: TextStyles.body(p).copyWith(color: color))),
          if (widget.action.icon != null) Icon(widget.action.icon, size: 20, color: color),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Controls

/// Segmented control with a glass lens that slides (and briefly stretches) between segments.
class GlassSegmented<T> extends StatelessWidget {
  final T value;
  final Map<T, String> segments;
  final ValueChanged<T> onChanged;

  /// No track of its own, for placing inside another glass surface.
  final bool bare;
  const GlassSegmented({super.key, required this.value, required this.segments, required this.onChanged, this.bare = false});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final keys = segments.keys.toList();
    final index = keys.indexOf(value);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth / keys.length;
      return Container(
        height: 40,
        decoration: ShapeDecoration(color: bare ? Colors.transparent : p.fill, shape: const StadiumBorder()),
        padding: const EdgeInsets.all(3),
        child: Stack(children: [
          TweenAnimationBuilder<double>(
            tween: Tween(end: index.toDouble()),
            duration: const Duration(milliseconds: 420),
            curve: Motion.spring,
            builder: (context, x, _) {
              // Stretch while travelling, like a drop of liquid.
              final frac = (x - x.floor());
              final stretch = 1 + 0.18 * math.sin(frac * math.pi);
              final width = (w - 2) * stretch;
              return Positioned(
                left: x * (w - 2) - (width - (w - 2)) / 2,
                top: 0,
                bottom: 0,
                width: width,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: p.isDark ? const Color(0xFF636366) : Colors.white,
                    shape: const StadiumBorder(),
                    shadows: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 8, offset: const Offset(0, 2))],
                  ),
                ),
              );
            },
          ),
          Row(children: [
            for (var i = 0; i < keys.length; i++)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (keys[i] == value) return;
                    HapticFeedback.selectionClick();
                    onChanged(keys[i]);
                  },
                  child: Center(
                    child: AnimatedDefaultTextStyle(
                      duration: Motion.quick,
                      style: TextStyle(
                        fontFamily: kFont,
                        fontSize: 13.5,
                        letterSpacing: -0.1,
                        fontWeight: i == index ? FontWeight.w600 : FontWeight.w500,
                        color: i == index ? p.label : p.secondaryLabel,
                      ),
                      child: Text(segments[keys[i]]!, maxLines: 1),
                    ),
                  ),
                ),
              ),
          ]),
        ]),
      );
    });
  }
}

/// iOS 26 switch: wide track with a pill knob that swells while touched.
class LiquidSwitch extends StatefulWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const LiquidSwitch({super.key, required this.value, required this.onChanged});
  @override
  State<LiquidSwitch> createState() => _LiquidSwitchState();
}

class _LiquidSwitchState extends State<LiquidSwitch> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    const w = 62.0, h = 28.0;
    final on = widget.value;
    return Semantics(
      toggled: on,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: () {
          HapticFeedback.lightImpact();
          widget.onChanged(!on);
        },
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v > 0 && !on || v < 0 && on) {
            HapticFeedback.lightImpact();
            widget.onChanged(!on);
          }
          setState(() => _pressed = false);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
          width: w,
          height: h,
          decoration: ShapeDecoration(color: on ? p.green : p.fill.withValues(alpha: p.fill.a * 2.2), shape: const StadiumBorder()),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 380),
            curve: Motion.spring,
            alignment: on ? Alignment.centerRight : Alignment.centerLeft,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              margin: const EdgeInsets.all(2),
              width: _pressed ? 44 : 38,
              height: h - 4,
              decoration: ShapeDecoration(
                color: Colors.white,
                shape: const StadiumBorder(),
                shadows: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 6, offset: const Offset(0, 2))],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pages

/// Tells the tab bar to tuck itself away while the user scrolls down (iOS 26 behaviour).
final tabBarMinimized = ValueNotifier(false);

/// Tab-page scaffold: a large title that scrolls with the content, floating glass toolbar buttons, and
/// a soft edge effect with a compact title once the large title has scrolled away.
class GlassPage extends StatefulWidget {
  final String title;
  final List<Widget> actions;
  final List<Widget> slivers;
  final Future<void> Function()? onRefresh;
  final Widget? leading;
  final Color? background;
  final bool reportScroll;

  /// Extra space under the content, for floating controls above the tab bar.
  final double extraBottom;

  /// While true the page doesn't scroll (a pinch is in progress).
  final ValueListenable<bool>? lockScroll;

  /// Wraps just the scrolling area (not the floating title and buttons), e.g. with a pinch gesture.
  final Widget Function(Widget scroll)? scrollWrapper;
  const GlassPage({
    super.key,
    required this.title,
    required this.slivers,
    this.actions = const [],
    this.onRefresh,
    this.leading,
    this.background,
    this.reportScroll = true,
    this.extraBottom = 0,
    this.lockScroll,
    this.scrollWrapper,
  });
  @override
  State<GlassPage> createState() => _GlassPageState();
}

final _never = ValueNotifier(false);

class _GlassPageState extends State<GlassPage> {
  final _offset = ValueNotifier(0.0);
  double _lastOffset = 0;

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final o = n.metrics.pixels;
    _offset.value = o;
    if (widget.reportScroll && n is ScrollUpdateNotification) {
      final delta = o - _lastOffset;
      if (o <= 40) {
        tabBarMinimized.value = false;
      } else if (delta > 6) {
        tabBarMinimized.value = true;
      } else if (delta < -6) {
        tabBarMinimized.value = false;
      }
    }
    _lastOffset = o;
    return false;
  }

  Widget _wrapScroll(Widget scroll) => widget.scrollWrapper?.call(scroll) ?? scroll;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final bg = widget.background ?? p.groupedBackground;
    return ColoredBox(
      color: bg,
      child: Stack(children: [
        const Positioned.fill(child: GridPattern()),
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: _wrapScroll(ValueListenableBuilder<bool>(
            valueListenable: widget.lockScroll ?? _never,
            builder: (context, locked, child) => CustomScrollView(
            // Rows are built and their pictures decoded a little before they scroll into view.
            cacheExtent: 900,
            physics: locked
                ? const NeverScrollableScrollPhysics()
                : const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              // The refresh control must be the first sliver: it reacts to the overscroll at the very top.
              CupertinoSliverRefreshControl(
                onRefresh: widget.onRefresh ?? Library.instance.refresh,
                refreshTriggerPullDistance: 90,
                refreshIndicatorExtent: 64,
                builder: logoRefreshIndicator,
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(Insets.page, top + 58, Insets.page, 10),
                  child: Text(widget.title, style: TextStyles.largeTitle(p)),
                ),
              ),
              ...widget.slivers,
              SliverToBoxAdapter(child: SizedBox(height: Insets.tabBarClearance(context) + widget.extraBottom)),
            ],
            ),
          )),
        ),
        // Edge effect + compact title + floating buttons.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: ValueListenableBuilder<double>(
            valueListenable: _offset,
            builder: (context, o, _) {
              final t = ((o - 20) / 34).clamp(0.0, 1.0);
              return IgnorePointer(
                ignoring: false,
                child: Stack(children: [
                  IgnorePointer(
                    child: Container(
                      height: top + 76,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [bg.withValues(alpha: t), bg.withValues(alpha: 0.94 * t), bg.withValues(alpha: 0)],
                          stops: const [0, 0.62, 1],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(Insets.card, top + 6, Insets.card, 0),
                    child: SizedBox(
                      height: 44,
                      child: Stack(alignment: Alignment.center, children: [
                      // Centred on the screen whatever buttons sit at the sides.
                      IgnorePointer(
                        child: Opacity(
                          opacity: t,
                          child: Transform.translate(
                            offset: Offset(0, 6 * (1 - t)),
                            child: Text(widget.title, textAlign: TextAlign.center, style: TextStyles.headline(p)),
                          ),
                        ),
                      ),
                      Row(children: [
                        if (widget.leading != null) widget.leading!,
                        const Spacer(),
                        for (var i = 0; i < widget.actions.length; i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          widget.actions[i],
                        ],
                      ]),
                    ]),
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// Section title used inside pages ("On This Phone", etc.).
class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.page, 8, Insets.page, 10),
      child: Row(children: [
        Expanded(child: Text(text, style: TextStyles.sectionHeader(p))),
        ?trailing,
      ]),
    );
  }
}

/// iOS-style confirmation on glass. Returns true when the user taps the main button.
Future<bool> showGlassConfirm(BuildContext context,
    {required String title, required String message, required String confirmLabel, bool destructive = false}) async {
  final ok = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Cancel',
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (ctx, _, _) {
      final p = Palette.of(ctx);
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Material(
              type: MaterialType.transparency,
              child: LiquidGlass(
                radius: 34,
                blur: 28,
                tint: p.isDark ? const Color(0xF21C1C1E) : const Color(0xF5F7F7FA),
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(title, style: TextStyles.title3(p), textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(message, style: TextStyles.subhead(p).copyWith(color: p.secondaryLabel), textAlign: TextAlign.center),
                  const SizedBox(height: 22),
                  GlassButton(confirmLabel,
                      prominent: true, color: destructive ? p.red : null, onTap: () => Navigator.pop(ctx, true)),
                  const SizedBox(height: 10),
                  GlassButton('Cancel', onTap: () => Navigator.pop(ctx, false)),
                ]),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (_, anim, _, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(scale: Tween(begin: 0.9, end: 1.0).animate(CurvedAnimation(parent: anim, curve: Motion.spring)), child: child),
    ),
  );
  return ok ?? false;
}
