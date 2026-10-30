import 'dart:io';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Opens a clip the way iOS opens a photo: the thumbnail grows from its tile to fill the screen, and on
/// close (button, back or a drag down) it shrinks back into place. The route's own animation is what the
/// finger scrubs, so dragging is the transition.
class ZoomRoute<T> extends PageRouteBuilder<T> {
  /// Where the tapped tile is on screen (global logical pixels), or null to fade instead.
  final Rect? from;

  /// Display aspect of the video (so the picture, not the tile crop, lands in the right place).
  final double aspect;
  final String? thumb;

  /// Opens with no animation (used when a swipe has already slid the picture into place).
  final bool instant;

  /// Horizontal finger offset while dragging down to close.
  final ValueNotifier<double> dragX = ValueNotifier(0);

  ZoomRoute(
      {required Widget Function(BuildContext) builder, this.from, this.aspect = 16 / 9, this.thumb, this.instant = false})
      : super(
          transitionDuration: instant ? Duration.zero : const Duration(milliseconds: 480),
          reverseTransitionDuration: const Duration(milliseconds: 400),
          pageBuilder: (context, _, _) => builder(context),
        );

  static const _open = Cubic(0.2, 0.0, 0.0, 1.0);
  static const _close = Cubic(0.3, 0.0, 0.2, 1.0);

  // ---- Interactive close ----

  bool _dragging = false;

  void beginDrag() {
    if (_dragging || navigator == null) return;
    _dragging = true;
    navigator!.didStartUserGesture();
  }

  /// [progress] 0 = fully open, 1 = back at the tile.
  void dragTo(double progress) {
    controller?.value = (1 - progress).clamp(0.0, 1.0);
  }

  void endDrag({required bool dismiss}) {
    final c = controller;
    final nav = navigator;
    if (!_dragging || c == null || nav == null) return;
    _dragging = false;
    dragX.value = 0;
    if (dismiss) {
      nav.pop();
      if (c.isAnimating) c.animateBack(0, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    } else {
      c.animateTo(1, duration: const Duration(milliseconds: 360), curve: Curves.easeOutCubic);
    }
    if (c.isAnimating) {
      void done(AnimationStatus s) {
        if (s == AnimationStatus.completed || s == AnimationStatus.dismissed) {
          c.removeStatusListener(done);
          nav.didStopUserGesture();
        }
      }

      c.addStatusListener(done);
    } else {
      nav.didStopUserGesture();
    }
  }

  // ---- Transition ----

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final tile = from;
    if (tile == null) {
      final c = CurvedAnimation(parent: animation, curve: _open, reverseCurve: Curves.easeIn);
      return FadeTransition(opacity: c, child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(c), child: child));
    }
    final size = MediaQuery.sizeOf(context);
    final full = Offset.zero & size;
    final fit = _contain(full, aspect);
    final cover = _cover(tile, aspect);
    return AnimatedBuilder(
      animation: Listenable.merge([animation, dragX]),
      builder: (context, _) {
        final raw = animation.value;
        // Dragging scrubs the value directly; otherwise ease it.
        final t = (_dragging ? raw : (animation.status == AnimationStatus.reverse ? _close : _open).transform(raw)).clamp(0.0, 1.0);
        final window = Rect.lerp(tile, full, t)!.shift(Offset(dragX.value * t, 0));
        final picture = Rect.lerp(cover, fit, t)!.shift(Offset(dragX.value * t, 0));
        final radius = lerpDouble(16, 0, Curves.easeIn.transform(t))!;
        return Stack(children: [
          Positioned.fill(child: ColoredBox(color: Colors.black.withValues(alpha: Curves.easeOut.transform(t)))),
          Positioned.fromRect(
            rect: window,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              // Black inside the rounded window, so the whole shape (not just the picture) grows like a card.
              child: ColoredBox(
                color: Colors.black,
                child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: 0,
                minHeight: 0,
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                child: Transform.translate(
                  offset: picture.topLeft - window.topLeft,
                  child: SizedBox(
                    width: picture.width,
                    height: picture.height,
                    child: thumb != null
                        ? Image.file(File(thumb!), fit: BoxFit.fill, gaplessPlayback: true, errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black))
                        : const ColoredBox(color: Color(0xFF1C1C1E)),
                  ),
                ),
              ),
            ),
          ),
          ),
          // The player's own controls arrive once the picture has almost landed, and leave first on close.
          IgnorePointer(
            ignoring: raw < 1,
            child: Opacity(opacity: ((t - 0.7) / 0.3).clamp(0.0, 1.0), child: child),
          ),
        ]);
      },
    );
  }

  static Rect _contain(Rect box, double aspect) {
    final w = box.width / box.height > aspect ? box.height * aspect : box.width;
    return Rect.fromCenter(center: box.center, width: w, height: w / aspect);
  }

  static Rect _cover(Rect box, double aspect) {
    final w = box.width / box.height > aspect ? box.width : box.height * aspect;
    return Rect.fromCenter(center: box.center, width: w, height: w / aspect);
  }
}
