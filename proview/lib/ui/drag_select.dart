import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../engine.dart';
import '../selection.dart';

/// Lets a finger that long-pressed a tile keep sweeping across the grid to select more of them, the way
/// Samsung Gallery does. Tiles mark themselves with a [MetaData] holding their clip.
class DragSelect extends StatelessWidget {
  final Widget child;
  const DragSelect({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerMove: (e) {
        final sel = Selection.instance;
        if (!sel.dragging) return;
        final result = HitTestResult();
        WidgetsBinding.instance.hitTestInView(result, e.position, View.of(context).viewId);
        for (final entry in result.path) {
          final t = entry.target;
          if (t is RenderMetaData && t.metaData is Clip) {
            sel.add(t.metaData as Clip);
            break;
          }
        }
      },
      onPointerUp: (_) => Selection.instance.dragging = false,
      onPointerCancel: (_) => Selection.instance.dragging = false,
      child: child,
    );
  }
}
