import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// A quiet frame-time meter. While frames are being drawn it prints one summary line every two seconds to the
/// log ("ProViewPerf"), so smoothness can be read off a real phone without any extra tooling. Idle screens
/// produce no frames and so no output.
class FramePerf {
  static final _build = <double>[];
  static final _raster = <double>[];
  static final _total = <double>[];
  static final _clock = Stopwatch();

  static void start() => SchedulerBinding.instance.addTimingsCallback(_onTimings);

  static void _onTimings(List<FrameTiming> timings) {
    if (!_clock.isRunning) _clock.start();
    for (final t in timings) {
      _build.add(t.buildDuration.inMicroseconds / 1000);
      _raster.add(t.rasterDuration.inMicroseconds / 1000);
      _total.add(t.totalSpan.inMicroseconds / 1000);
    }
    if (_clock.elapsedMilliseconds < 2000) return;
    final seconds = _clock.elapsedMilliseconds / 1000;
    _clock
      ..stop()
      ..reset();
    if (_total.length >= 12) {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      final hz = views.isEmpty ? 0.0 : views.first.display.refreshRate;
      int over(double ms) => _total.where((t) => t > ms).length;
      debugPrint('ProViewPerf: ${_total.length} frames in ${seconds.toStringAsFixed(1)}s '
          '(${(_total.length / seconds).toStringAsFixed(0)} fps, screen ${hz.round()} Hz) | '
          'build avg ${_avg(_build)} p95 ${_p95(_build)} max ${_max(_build)} ms | '
          'raster avg ${_avg(_raster)} p95 ${_p95(_raster)} max ${_max(_raster)} ms | '
          'frame >8.3ms: ${over(8.34)}  >16.7ms: ${over(16.7)}  >33ms: ${over(33.4)}');
    }
    _build.clear();
    _raster.clear();
    _total.clear();
  }

  static String _avg(List<double> v) => (v.reduce((a, b) => a + b) / v.length).toStringAsFixed(1);
  static String _max(List<double> v) => v.reduce(math.max).toStringAsFixed(1);
  static String _p95(List<double> v) {
    final s = [...v]..sort();
    return s[(s.length * 0.95).floor().clamp(0, s.length - 1)].toStringAsFixed(1);
  }
}
