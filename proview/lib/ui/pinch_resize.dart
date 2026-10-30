import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

enum _Phase { idle, pinching, settling }

/// Shared state of a pinch on the tile grid. Every [PinchTile] reads it while painting, so a pinch moves only the
/// tiles (a GPU transform per tile; nothing is rebuilt or laid out until you let go).
class PinchScope extends ChangeNotifier {
  PinchScope._();
  static final instance = PinchScope._();

  _Phase phase = _Phase.idle;

  /// Scale applied to the tiles, relative to how the grid was laid out when the pinch began.
  double scale = 1;

  /// Where the fingers were (screen coordinates); tiles scale around this point.
  Offset focal = Offset.zero;

  /// 0..1 while the tiles ease from where you left them onto the new layout.
  double progress = 1;
  int epoch = 0;

  void begin(Offset focal) {
    this.focal = focal;
    scale = 1;
    phase = _Phase.pinching;
    epoch++;
    notifyListeners();
  }

  void update(double s) {
    scale = s;
    notifyListeners();
  }

  void release() {
    phase = _Phase.settling;
    progress = 0;
    notifyListeners();
  }

  void setProgress(double p) {
    progress = p;
    if (p >= 1) {
      phase = _Phase.idle;
      scale = 1;
    }
    notifyListeners();
  }
}

/// Wraps one grid tile so it follows a [PinchScope]: while pinching it scales around the fingers, and after
/// release it glides from where it was drawn to its place in the new layout.
class PinchTile extends SingleChildRenderObjectWidget {
  const PinchTile({super.key, super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPinchTile();
}

class _RenderPinchTile extends RenderProxyBox {
  final _scope = PinchScope.instance;
  int _epoch = -1;
  Offset? _c0; // centre (screen coordinates) when the pinch began
  double? _size0;
  bool _wasIdle = true;

  Offset _centre() => localToGlobal(size.center(Offset.zero));

  void _onScope() {
    if (!attached) return;
    if (_scope.epoch != _epoch && _scope.phase == _Phase.pinching) {
      _epoch = _scope.epoch;
      if (hasSize) {
        _c0 = _centre();
        _size0 = size.width;
      } else {
        _c0 = null;
        _size0 = null;
      }
    }
    if (_scope.phase == _Phase.idle && _wasIdle) return;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scope.addListener(_onScope);
  }

  @override
  void detach() {
    _scope.removeListener(_onScope);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_scope.phase == _Phase.idle) {
      _wasIdle = true;
      super.paint(context, offset);
      return;
    }
    _wasIdle = false;
    final centre = size.center(Offset.zero);
    final c1 = _centre(); // where the grid now puts this tile
    final c0 = _c0 ?? c1;
    final focal = _scope.focal;
    Offset delta;
    double k;
    if (_scope.phase == _Phase.pinching) {
      delta = focal + (c0 - focal) * _scope.scale - c1;
      k = _scope.scale;
    } else {
      // Settling: from the spot it was drawn at when you let go, to its place in the new layout.
      final from = focal + (c0 - focal) * _scope.scale;
      final fromSize = (_size0 ?? size.width) * _scope.scale;
      final t = _scope.progress;
      final at = Offset.lerp(from, c1, t)!;
      delta = at - c1;
      k = lerpDouble(fromSize, size.width, t)! / size.width;
    }
    final m = Matrix4.translationValues(delta.dx, delta.dy, 0)
      ..translateByDouble(centre.dx, centre.dy, 0, 1)
      ..scaleByDouble(k, k, 1, 1)
      ..translateByDouble(-centre.dx, -centre.dy, 0, 1);
    context.pushTransform(true, offset, m, super.paint);
  }
}

/// Two-finger pinch on a scrolling grid, in the way Photos on iPhone does it: the tiles scale under your fingers
/// while you pinch, then on release they settle onto a whole number of columns with a springy glide. It reads raw
/// touches, so one finger scrolls as normal and a second finger turns it into a pinch.
class PinchResize extends StatefulWidget {
  /// The tile size the grid is laid out with right now.
  final double value;
  final double min;
  final double max;

  /// Rounds a tile size to one that fills the width with whole columns.
  final double Function(double) snap;

  /// Called on release with the size to lay the grid out with.
  final ValueChanged<double> onCommit;

  /// True while two fingers are down (use it to freeze scrolling).
  final ValueNotifier<bool>? pinching;
  final Widget child;
  const PinchResize({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.snap,
    required this.onCommit,
    required this.child,
    this.pinching,
  });
  @override
  State<PinchResize> createState() => _PinchResizeState();
}

class _PinchResizeState extends State<PinchResize> with SingleTickerProviderStateMixin {
  final _scope = PinchScope.instance;
  final _points = <int, Offset>{};
  late final _settle = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  double? _startDistance;
  double _lastSnapped = 0;

  @override
  void initState() {
    super.initState();
    _settle.addListener(() => _scope.setProgress(Motion.emphasized.transform(_settle.value)));
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  double _distance() {
    final p = _points.values.take(2).toList();
    return (p[0] - p[1]).distance;
  }

  void _down(PointerDownEvent e) {
    _points[e.pointer] = e.position;
    if (_points.length == 2) {
      // A new pinch while the last one is still easing in: let that finish instantly.
      if (_settle.isAnimating) _settle.stop();
      if (_scope.phase != _Phase.idle) _scope.setProgress(1);
      _startDistance = _distance();
      _lastSnapped = widget.snap(widget.value);
      _scope.begin((_points.values.first + _points.values.last) / 2);
      widget.pinching?.value = true;
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_points.containsKey(e.pointer)) return;
    _points[e.pointer] = e.position;
    final start = _startDistance;
    if (_points.length < 2 || start == null || start < 24) return;
    // Spreading the fingers enlarges the tiles; the size is held between the smallest and largest allowed.
    final lo = widget.min / widget.value;
    final hi = widget.max / widget.value;
    final s = (_distance() / start).clamp(lo, hi);
    _scope.update(s);
    // A small tick each time the grid would land on a different number of columns.
    final snapped = widget.snap(widget.value * s);
    if (snapped != _lastSnapped) {
      _lastSnapped = snapped;
      HapticFeedback.selectionClick();
    }
  }

  void _up(PointerEvent e) {
    final wasPinching = _startDistance != null;
    _points.remove(e.pointer);
    if (!wasPinching || _points.length >= 2) return;
    _startDistance = null;
    final target = widget.snap(widget.value * _scope.scale);
    widget.pinching?.value = false;
    HapticFeedback.lightImpact();
    // Lay the grid out at the snapped size now; the tiles glide there from where they were left.
    _scope.release();
    widget.onCommit(target);
    _settle.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: widget.child,
      );
}
