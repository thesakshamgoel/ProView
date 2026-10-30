import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';
import 'ui/cutout.dart';
import 'widgets.dart';
import 'ui/app_icons.dart';

enum ToastKind { success, error, info, working }

class _ToastData {
  final String title;
  final String? message;
  final ToastKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
  _ToastData(this.title, this.message, this.kind, this.actionLabel, this.onAction);
}

/// Pill-shaped banners that drop in from the top, like iOS system notifications.
class Toast {
  static final _key = GlobalKey<_ToastHostState>();

  static Widget host({required Widget child}) => _ToastHost(key: _key, child: child);

  static void show(String title,
      {String? message, ToastKind kind = ToastKind.info, String? actionLabel, VoidCallback? onAction}) {
    if (kind == ToastKind.error) {
      HapticFeedback.heavyImpact();
    } else if (kind == ToastKind.success) {
      HapticFeedback.mediumImpact();
    }
    _key.currentState?.show(_ToastData(title, message, kind, actionLabel, onAction));
  }

  static void success(String title, {String? message, String? actionLabel, VoidCallback? onAction}) =>
      show(title, message: message, kind: ToastKind.success, actionLabel: actionLabel, onAction: onAction);
  static void error(String title, {String? message, String? actionLabel, VoidCallback? onAction}) =>
      show(title, message: message, kind: ToastKind.error, actionLabel: actionLabel, onAction: onAction);
  static void info(String title, {String? message, String? actionLabel, VoidCallback? onAction}) =>
      show(title, message: message, kind: ToastKind.info, actionLabel: actionLabel, onAction: onAction);
  static void working(String title, {String? message}) => show(title, message: message, kind: ToastKind.working);
}

class _ToastHost extends StatefulWidget {
  final Widget child;
  const _ToastHost({super.key, required this.child});
  @override
  State<_ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends State<_ToastHost> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
  _ToastData? _current;
  bool _restarting = false;
  Timer? _timer;

  void show(_ToastData data) {
    _timer?.cancel();
    setState(() => _current = data);
    _restarting = true;
    _anim.forward(from: _anim.value > 0.5 ? 0.6 : 0);
    _restarting = false;
    final ms = data.kind == ToastKind.error ? 5500 : (data.actionLabel != null ? 4500 : 3000);
    _timer = Timer(Duration(milliseconds: ms), hide);
  }

  void hide() {
    _timer?.cancel();
    _anim.reverse();
  }

  @override
  void initState() {
    super.initState();
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.dismissed && !_restarting && mounted && _current != null) setState(() => _current = null);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cutout = Cutout.of(context);
    final top = MediaQuery.paddingOf(context).top + 8;
    final width = MediaQuery.sizeOf(context).width;
    return Stack(children: [
      widget.child,
      if (_current != null)
        AnimatedBuilder(
          animation: _anim,
          builder: (context, _) {
            final v = _anim.value.clamp(0.0, 1.0);
            final t = _anim.status == AnimationStatus.reverse ? Curves.easeIn.transform(v) : Motion.spring.transform(v);
            final full = math.min(width - 24, 520.0);
            final card = Material(type: MaterialType.transparency, child: _ToastCard(data: _current!, onTap: hide));
            if (cutout == null) {
              // Drops in from above the screen edge and fades in. Plain positioning: no transforms to go wrong.
              return Positioned(
                left: 12,
                right: 12,
                top: top + (1 - t.clamp(0.0, 1.2)) * -70,
                child: IgnorePointer(
                  ignoring: v < 0.5,
                  child: Opacity(
                    opacity: Curves.easeOut.transform(v),
                    child: Align(alignment: Alignment.topCenter, heightFactor: 1, child: card),
                  ),
                ),
              );
            }
            // The bar grows out of the camera hole: a pill the size of the hole widens, drops and fills in.
            final c = cutout.rect;
            final w = ui.lerpDouble(c.width + 14, full, t.clamp(0.0, 1.15))!;
            final y = ui.lerpDouble(c.top - 3, top, t.clamp(0.0, 1.1))!;
            final grow = Curves.easeOut.transform(((v - 0.15) / 0.85).clamp(0.0, 1.0));
            return Positioned(
              left: 0,
              right: 0,
              top: y,
              child: IgnorePointer(
                ignoring: v < 0.6,
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: 1,
                  child: SizedBox(
                    width: w,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(ui.lerpDouble(c.height / 2 + 4, 30, grow)!),
                      child: Align(
                        alignment: Alignment.topCenter,
                        heightFactor: ui.lerpDouble(0.2, 1, grow),
                        // A fixed window the card fits in: the pill opens downwards from the camera hole.
                        child: SizedBox(
                          height: 150,
                          child: OverflowBox(
                            minWidth: full,
                            maxWidth: full,
                            minHeight: 0,
                            maxHeight: 150,
                            alignment: Alignment.topCenter,
                            child: Opacity(opacity: Curves.easeIn.transform(((v - 0.35) / 0.65).clamp(0.0, 1.0)), child: card),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
    ]);
  }
}

class _ToastCard extends StatelessWidget {
  final _ToastData data;
  final VoidCallback onTap;
  const _ToastCard({required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final (IconData icon, Color color) = switch (data.kind) {
      ToastKind.success => (AppIcons.checkmark_circle_fill, p.green),
      ToastKind.error => (AppIcons.exclamationmark_octagon_fill, p.red),
      ToastKind.info => (AppIcons.info_circle_fill, p.accent),
      ToastKind.working => (AppIcons.arrow_2_circlepath, p.accent),
    };
    return GestureDetector(
      onTap: onTap,
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) < 0) onTap();
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: LiquidGlass(
          radius: 30,
          blur: 24,
          tint: p.isDark ? const Color(0xCC1C1C1E) : const Color(0xD9FFFFFF),
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Row(children: [
            SizedBox.square(
              dimension: 34,
              child: Center(
                child: data.kind == ToastKind.working
                    ? const LogoSpinner(size: 28)
                    : Icon(icon, color: color, size: 28),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(data.title, style: TextStyles.subhead(p).copyWith(fontWeight: FontWeight.w600)),
                  if (data.message != null) ...[
                    const SizedBox(height: 1),
                    Text(data.message!, style: TextStyles.footnote(p), maxLines: 3, overflow: TextOverflow.fade),
                  ],
                ],
              ),
            ),
            if (data.actionLabel != null) ...[
              const SizedBox(width: 8),
              GlassButton(data.actionLabel!, prominent: true, height: 36, expand: false, onTap: () {
                onTap();
                data.onAction?.call();
              }),
            ],
          ]),
        ),
      ),
    );
  }
}
