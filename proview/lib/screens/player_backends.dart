import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../engine.dart';
import '../library.dart';

class PlayState {
  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;
  final bool completed;
  final String? error;
  final double aspect;
  final int droppedFrames;

  const PlayState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.buffering = true,
    this.completed = false,
    this.error,
    this.aspect = 16 / 9,
    this.droppedFrames = 0,
  });

  PlayState copy({
    Duration? position,
    Duration? duration,
    bool? playing,
    bool? buffering,
    bool? completed,
    String? error,
    double? aspect,
    int? droppedFrames,
  }) =>
      PlayState(
        position: position ?? this.position,
        duration: duration ?? this.duration,
        playing: playing ?? this.playing,
        buffering: buffering ?? this.buffering,
        completed: completed ?? this.completed,
        error: error ?? this.error,
        aspect: aspect ?? this.aspect,
        droppedFrames: droppedFrames ?? this.droppedFrames,
      );
}

/// How a clip is being played, shown in the player.
class PlaybackInfo {
  final String engine; // system | proview
  final String decode; // gpu | cpu | hardware
  final String output; // gpu | cpu | hardware
  final int bits;

  /// Quality stage of the CPU decoder: 0 full, 1 lighter filtering, 2 even lower frame rate.
  final int stage;
  final int threads;
  const PlaybackInfo({this.engine = '', this.decode = '', this.output = '', this.bits = 8, this.stage = 0, this.threads = 0});

  factory PlaybackInfo.fromMap(Map<dynamic, dynamic> m) => PlaybackInfo(
        engine: m['engine'] as String? ?? '',
        decode: m['decode'] as String? ?? '',
        output: m['output'] as String? ?? '',
        bits: (m['bits'] as num?)?.toInt() ?? 8,
        stage: (m['stage'] as num?)?.toInt() ?? 0,
        threads: (m['threads'] as num?)?.toInt() ?? 0,
      );

  bool get reduced => stage > 0;
  bool get gpuDecode => decode == 'gpu' || engine == 'system';

  /// Short label for the player chip.
  String get label {
    if (stage >= 3) return 'Preview only';
    if (reduced) return 'Smooth mode';
    if (engine == 'system') return '$bits-bit';
    return '${decode == 'gpu' ? 'GPU' : 'CPU'} · $bits-bit';
  }
}

/// Drives the native video layer (VideoStage.kt): Android's own player for files the phone can play,
/// or ProView's engine (GPU ProRes decoding, 10-bit Vulkan output) for everything else.
class VideoController {
  static const _ch = MethodChannel('proview/player');

  final state = ValueNotifier(const PlayState());
  final info = ValueNotifier<PlaybackInfo?>(null);
  final bool system;
  int? _id;
  Timer? _poll;
  int _polls = 0;
  Duration _lastPosition = Duration.zero;
  int _lastPositionAt = 0;
  double _rate = 1;
  Rect? _lastLayout;
  int _tick = 0;

  /// While false (controls hidden) the UI is idle: state refreshes only once a second, so Flutter doesn't
  /// wake up ten times a second and take CPU time from the decoder.
  bool detailed = true;

  VideoController({required this.system});

  Future<void> open(Clip clip, ClipInfo clipInfo) async {
    if (clipInfo.displayWidth > 0 && clipInfo.displayHeight > 0) {
      state.value = state.value.copy(aspect: clipInfo.displayWidth / clipInfo.displayHeight);
    }
    final r = await _ch.invokeMethod<Map<dynamic, dynamic>>('open', {
      'uri': clip.uri,
      'engine': system ? 'system' : 'proview',
      'smooth': Library.instance.settings.deband,
      'loop': Library.instance.settings.loop,
    });
    _id = (r?['id'] as num?)?.toInt();
    if (_lastLayout != null) _sendLayout(_lastLayout!);
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (detailed || ++_tick % 10 == 0) _sync();
    });
  }

  /// Position extrapolated between polls, so the scrubber glides instead of ticking.
  Duration get livePosition {
    final s = state.value;
    if (!s.playing || s.buffering) return s.position;
    final elapsed = DateTime.now().millisecondsSinceEpoch - _lastPositionAt;
    final p = _lastPosition + Duration(milliseconds: (elapsed * _rate).round().clamp(0, 400));
    return s.duration > Duration.zero && p > s.duration ? s.duration : p;
  }

  Future<void> _sync() async {
    final id = _id;
    if (id == null) return;
    final v = await _ch.invokeMethod<List<dynamic>>('state', {'id': id});
    if (v == null || _id == null) return;
    num n(int i) => (v[i] as num?) ?? 0;
    final pos = Duration(milliseconds: (n(0) * 1000).round());
    _lastPosition = pos;
    _lastPositionAt = DateTime.now().millisecondsSinceEpoch;
    state.value = state.value.copy(
      position: pos,
      duration: Duration(milliseconds: (n(1) * 1000).round()),
      playing: n(2) != 0,
      buffering: n(3) != 0,
      completed: n(4) != 0,
      aspect: n(5) > 0 && n(6) > 0 ? n(5) / n(6) : null,
      droppedFrames: n(7).toInt(),
      error: v.length > 8 ? v[8] as String? : null,
    );
    // The engine settles on its decode path in the first second; refresh the info a few times.
    if (_polls++ % 10 == 3) {
      final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('info', {'id': id});
      if (m != null) info.value = PlaybackInfo.fromMap(m);
    }
    if (state.value.completed && Library.instance.settings.loop && !system) await play();
  }

  Future<void> _call(String method, [Map<String, dynamic>? args]) async {
    final id = _id;
    if (id == null) return;
    await _ch.invokeMethod(method, {'id': id, ...?args});
    await _sync();
  }

  /// Places the video layer at [rect] (logical pixels, global coordinates).
  void layout(Rect rect, double dpr) {
    final physical = Rect.fromLTWH(rect.left * dpr, rect.top * dpr, rect.width * dpr, rect.height * dpr);
    if (physical == _lastLayout) return;
    _lastLayout = physical;
    if (_id != null) _sendLayout(physical);
  }

  void _sendLayout(Rect r) {
    _ch.invokeMethod('layout', {'x': r.left, 'y': r.top, 'w': r.width.round(), 'h': r.height.round()});
  }

  /// Shows or hides the native video layer (hidden while the player is dragged away or closing).
  Future<void> setVisible(bool visible) async {
    final id = _id;
    if (id == null) return;
    await _ch.invokeMethod('visible', {'id': id, 'visible': visible});
  }

  Future<void> play() => _call('play');
  Future<void> pause() => _call('pause');
  Future<void> seek(Duration to) {
    _lastPosition = to;
    _lastPositionAt = DateTime.now().millisecondsSinceEpoch;
    state.value = state.value.copy(position: to);
    return _call('seek', {'sec': to.inMicroseconds / 1e6});
  }

  Future<void> setRate(double rate) {
    _rate = rate;
    return _call('rate', {'rate': rate});
  }

  Future<void> setVolume(double volume) => _call('volume', {'volume': volume});
  Future<void> step(int direction) => _call('step', {'dir': direction});

  Future<void> dispose() async {
    _poll?.cancel();
    final id = _id;
    _id = null;
    if (id != null) await _ch.invokeMethod('release', {'id': id});
  }
}

/// Reports where the video should appear and keeps the native layer glued to it every frame (layout
/// changes, rotation, zoom animation). Paints black around the picture and a fade over it.
class VideoStageView extends StatefulWidget {
  final VideoController controller;
  final double aspect;

  /// The thumbnail drawn over the video until it is ready (and again as the player closes).
  final ui.Image? poster;

  /// 0 = whole picture visible (fit), 1 = fill the screen.
  final double zoom;

  /// 0 = picture covered in black, 1 = fully revealed.
  final double reveal;
  const VideoStageView(
      {super.key, required this.controller, required this.aspect, required this.zoom, required this.reveal, this.poster});
  @override
  State<VideoStageView> createState() => _VideoStageViewState();
}

class _VideoStageViewState extends State<VideoStageView> {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final size = box.biggest;
      final rect = videoRect(size, widget.aspect, widget.zoom);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ro = context.findRenderObject() as RenderBox?;
        if (ro == null || !ro.attached) return;
        final origin = ro.localToGlobal(Offset.zero);
        widget.controller.layout(rect.shift(origin), MediaQuery.devicePixelRatioOf(context));
      });
      return CustomPaint(size: size, painter: _Backdrop(rect: rect, reveal: widget.reveal, poster: widget.poster));
    });
  }
}

/// Fit/fill rectangle of a picture with [aspect] inside [size].
Rect videoRect(Size size, double aspect, double zoom) {
  if (size.isEmpty || aspect <= 0) return Offset.zero & size;
  final fitW = size.width / size.height > aspect ? size.height * aspect : size.width;
  final fitH = fitW / aspect;
  final fillW = size.width / size.height > aspect ? size.width : size.height * aspect;
  final fillH = fillW / aspect;
  final w = fitW + (fillW - fitW) * zoom, h = fitH + (fillH - fitH) * zoom;
  return Rect.fromCenter(center: size.center(Offset.zero), width: w, height: h);
}

class _Backdrop extends CustomPainter {
  final Rect rect;
  final double reveal;
  final ui.Image? poster;
  _Backdrop({required this.rect, required this.reveal, required this.poster});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000));
    final cover = (1 - reveal).clamp(0.0, 1.0);
    final img = poster;
    if (img == null) {
      // No thumbnail: fade the video in from black.
      canvas.drawRect(
          rect,
          Paint()
            ..blendMode = BlendMode.src
            ..color = Color.fromRGBO(0, 0, 0, cover));
      return;
    }
    // Cut through to the video layer underneath (BlendMode.src writes transparency), then lay the
    // thumbnail over it and fade that away as the first frames arrive.
    canvas.drawRect(rect, Paint()..blendMode = BlendMode.src..color = const Color(0x00000000));
    if (cover > 0) {
      canvas.drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          rect,
          Paint()
            ..filterQuality = FilterQuality.medium
            ..color = Color.fromRGBO(255, 255, 255, cover));
    }
  }

  @override
  bool shouldRepaint(_Backdrop old) => old.rect != rect || old.reveal != reveal || old.poster != poster;
}
