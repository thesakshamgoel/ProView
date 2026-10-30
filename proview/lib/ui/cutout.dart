import 'dart:ui' show DisplayFeatureType;

import 'package:flutter/widgets.dart';

/// The front-camera cut-out (punch hole or notch) at the top of the screen, when the phone has one.
/// Message bars grow out of it and the refresh logo drops out of it, like the Dynamic Island.
class Cutout {
  /// Bounds in logical pixels.
  final Rect rect;
  const Cutout(this.rect);

  Offset get center => rect.center;

  /// The cut-out, or null on phones without one (or when it isn't at the top edge).
  static Cutout? of(BuildContext context) {
    final mq = MediaQuery.of(context);
    if (mq.orientation != Orientation.portrait) return null;
    for (final f in mq.displayFeatures) {
      if (f.type == DisplayFeatureType.cutout && f.bounds.top < 48 && f.bounds.height < 160 && f.bounds.width < 400) {
        return Cutout(f.bounds);
      }
    }
    return null;
  }
}
