import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../clip_actions.dart';
import '../engine.dart';
import '../library.dart';
import '../tasks.dart';
import '../tags.dart';
import '../theme.dart';
import '../toast.dart';
import '../widgets.dart';
import 'player_backends.dart';
import 'zoom_route.dart';
import '../ui/app_icons.dart';

class PlayerPage extends StatefulWidget {
  final Clip clip;
  final ClipInfo info;
  final bool preview;

  /// Set when playing a phone-playable copy; the original it was made from.
  final Clip? original;

  /// Where playback starts (when switching to a smooth copy mid-playback).
  final Duration startAt;

  /// Thumbnail shown while the video starts (and during the zoom in and out).
  final String? thumb;

  /// The videos a swipe left or right moves through, in the order they were listed.
  final List<Clip> queue;

  const PlayerPage(
      {super.key,
      required this.clip,
      required this.info,
      required this.preview,
      this.original,
      this.startAt = Duration.zero,
      this.thumb,
      this.queue = const []});

  /// [from] is the tapped tile's rectangle: the clip zooms out of it and back into it.
  static Route route(Clip clip, ClipInfo info,
      {required bool preview,
      Clip? original,
      Duration startAt = Duration.zero,
      Rect? from,
      List<Clip> queue = const [],
      bool instant = false}) {
    final lib = Library.instance;
    final thumb = lib.thumb(clip) ?? (original != null ? lib.thumb(original) : null);
    final aspect = info.displayWidth > 0 && info.displayHeight > 0 ? info.displayWidth / info.displayHeight : 16 / 9;
    return ZoomRoute(
      from: from,
      aspect: aspect,
      thumb: thumb,
      instant: instant,
      builder: (_) =>
          PlayerPage(clip: clip, info: info, preview: preview, original: original, startAt: startAt, thumb: thumb, queue: queue),
    );
  }

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with TickerProviderStateMixin {
  /// Players currently open; system UI is restored only when the last one closes (switching from a
  /// copy to its original replaces one player with another).
  static int _open = 0;

  VideoController? _video;
  late bool _preview = widget.preview;
  bool _controls = true;
  bool _muted = false;
  bool _fullscreen = false;
  double _rate = 1;
  Timer? _hideTimer;
  Duration? _scrub;
  bool _wasPlaying = false;
  bool _bannerDismissed = false;
  bool _routeSettled = false;
  bool _autoPrepared = false;
  StreamSubscription<BgTask>? _finishedSub;
  ui.Image? _poster;
  ZoomRoute? _zoomRoute;

  // Swipe sideways to move to the next or previous video: the next picture slides in under the finger.
  bool _hSwipe = false;
  double _swipeDx = 0; // finger offset
  final _swipeShift = ValueNotifier<double>(0); // where the incoming picture is, relative to its resting place
  bool _swipeShown = false; // there is a video in the swiped direction
  int _swipeDir = 0; // +1 next, -1 previous
  int _swipeTo = -1;
  String? _swipeThumb;
  double _swipeFrom = 0, _swipeTarget = 0;
  Curve _swipeCurve = Curves.easeOutCubic;
  bool _navigating = false;
  late final _swipeAnim = AnimationController(vsync: this);

  // Drag down to close: the route's own transition follows the finger.
  bool _closing = false;
  double _dragDy = 0;
  Offset _dragStart = Offset.zero;
  bool _dragLocked = false;

  late final _zoom = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  late final _reveal = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  late final _controlsAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 260), value: 1);
  final _seekFlash = ValueNotifier<(int, int)?>(null); // (direction, seconds)

  // VLC-style swipes in fullscreen: left half = volume, right half = brightness.
  final _level = ValueNotifier<(int, double)?>(null); // (1 volume | 2 brightness, 0..1)
  int _levelKind = 0;
  bool _levelRejected = false;
  bool _levelBusy = false;
  double? _levelBase;
  double? _levelWant;
  double _levelDy = 0;
  double _levelSpan = 300;
  bool _infoOpened = false;
  Timer? _levelTimer;
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    _open++;
    SmartTags.instance.pauses++;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Follow the phone's rotation while playing (the rest of the app stays portrait).
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    Engine.call('keepScreenOn', {'on': true});
    // A smooth copy prepared for this very playback replaces it as soon as it's ready, at the same position.
    _finishedSub = TaskCenter.instance.finished.listen((t) {
      if (mounted && _autoPrepared && t.type == 'convert' && t.state == TaskState.done && t.sourceUri == widget.clip.uri) {
        _playCopy(t, resume: true);
      }
    });
    _swipeAnim.addListener(
        () => _swipeShift.value = _swipeFrom + (_swipeTarget - _swipeFrom) * _swipeCurve.transform(_swipeAnim.value));
    _loadPoster();
    _start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _precacheNeighbors();
      final route = ModalRoute.of(context);
      if (route is ZoomRoute) _zoomRoute = route;
      final anim = route?.animation;
      if (anim == null || anim.isCompleted) {
        _routeSettled = true;
      }
      void listener(AnimationStatus s) {
        if (s == AnimationStatus.completed) {
          _routeSettled = true;
          _video?.setVisible(true);
          _maybeReveal();
        } else if (s == AnimationStatus.reverse) {
          // Leaving (or being dragged away): the picture covers the video, then the video layer steps aside.
          _reveal.value = 0;
          _video?.setVisible(false);
        }
      }
      anim?.addStatusListener(listener);
    });
  }

  Future<void> _loadPoster() async {
    final path = widget.thumb;
    if (path == null) return;
    try {
      final bytes = await File(path).readAsBytes();
      final image = await decodeImageFromList(bytes);
      if (mounted) setState(() => _poster = image);
    } catch (_) {}
  }

  Future<void> _start() async {
    final video = VideoController(system: !_preview);
    setState(() => _video = video);
    try {
      await video.open(widget.clip, widget.info);
      if (!mounted) return;
      video.state.addListener(_onState);
      video.info.addListener(_onInfo);
      if (widget.startAt > Duration.zero) await video.seek(widget.startAt);
      await video.play();
      _scheduleHide();
    } catch (e) {
      if (!_preview) {
        // Android's player refused it; fall back to ProView's engine.
        await video.dispose();
        if (!mounted) return;
        Toast.info('Switched to ProView\'s engine', message: 'Android\'s player couldn\'t open this clip.');
        _preview = true;
        _start();
      } else if (mounted) {
        video.state.value = video.state.value.copy(error: _friendly(e), buffering: false);
        setState(() {});
      }
    }
  }

  String _friendly(Object e) {
    if (e is PlatformException) return e.message ?? e.code;
    return e.toString();
  }

  void _maybeReveal() {
    final s = _video?.state.value;
    if (s != null && !s.buffering && _routeSettled && _reveal.value < 1 && !_reveal.isAnimating) {
      _reveal.forward();
    }
  }

  void _onState() {
    final s = _video!.state.value;
    _maybeReveal();
    if (s.error != null && !_preview && s.position == Duration.zero) {
      // Android's player failed mid-open: retry with ProView's engine.
      _switchToEngine();
      return;
    }
    if (s.completed && !s.playing) _showControls();
  }

  /// The engine reports it can't keep up in real time: prepare a smooth copy in the background.
  void _onInfo() {
    final pi = _video?.info.value;
    // Only for clips that need more than a lighter filter: stage 2+ means the phone can't hold real time.
    if (pi == null || pi.stage < 2 || _autoPrepared || widget.original != null) return;
    final lib = Library.instance;
    if (!lib.settings.smartPrepare) return;
    final source = widget.clip;
    if (lib.copyOf(source) != null || (TaskCenter.instance.conversionFor(source.uri)?.active ?? false)) return;
    _autoPrepared = true;
    Toast.info('Preparing a smooth copy', message: 'This clip is heavier than the phone can play live. Progress is in Activity.');
    ClipActions.startConversion(context, source, widget.info, quiet: true);
  }

  /// Swaps this player for the finished phone-playable copy.
  Future<void> _playCopy(BgTask t, {bool resume = false}) async {
    final uri = t.outputUri;
    if (uri == null) return;
    final at = resume ? (_video?.livePosition ?? Duration.zero) : Duration.zero;
    final lib = Library.instance;
    final copy = lib.byUri(uri) ?? await lib.addDocument(uri);
    final info = await lib.analyzeNow(copy);
    if (!mounted) return;
    Navigator.of(context)
        .pushReplacement(PlayerPage.route(copy, info, preview: !info.native, original: widget.clip, startAt: at, queue: widget.queue));
  }

  Future<void> _switchToEngine() async {
    final old = _video;
    old?.state.removeListener(_onState);
    old?.info.removeListener(_onInfo);
    setState(() {
      _preview = true;
      _video = null;
    });
    _reveal.value = 0;
    await old?.dispose();
    if (mounted) _start();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _flashTimer?.cancel();
    _finishedSub?.cancel();
    _video?.state.removeListener(_onState);
    _video?.info.removeListener(_onInfo);
    _video?.dispose();
    _zoom.dispose();
    _reveal.dispose();
    _controlsAnim.dispose();
    _seekFlash.dispose();
    _levelTimer?.cancel();
    _level.dispose();
    _swipeAnim.dispose();
    _swipeShift.dispose();
    SmartTags.instance.pauses--;
    if (--_open == 0) {
      Engine.call('brightness', {'reset': true});
      Engine.call('keepScreenOn', {'on': false});
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  // ---- Controls visibility ----

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && (_video?.state.value.playing ?? false) && _scrub == null) _hideControls();
    });
  }

  void _showControls() {
    _video?.detailed = true;
    if (!_controls) setState(() => _controls = true);
    _controlsAnim.forward();
    _scheduleHide();
  }

  void _hideControls() {
    _video?.detailed = false;
    setState(() => _controls = false);
    _controlsAnim.reverse();
  }

  void _toggleControls() => _controls ? _hideControls() : _showControls();

  // ---- Actions ----

  Future<void> _togglePlay() async {
    final v = _video;
    if (v == null) return;
    HapticFeedback.lightImpact();
    if (v.state.value.playing) {
      await v.pause();
      _hideTimer?.cancel();
    } else {
      await v.play();
      _scheduleHide();
    }
  }

  void _seekBy(int seconds) {
    final v = _video;
    if (v == null) return;
    final s = v.state.value;
    var to = v.livePosition + Duration(seconds: seconds);
    if (to < Duration.zero) to = Duration.zero;
    if (s.duration > Duration.zero && to > s.duration) to = s.duration;
    v.seek(to);
    HapticFeedback.selectionClick();
    final prev = _seekFlash.value;
    final total = prev != null && prev.$1 == seconds.sign ? prev.$2 + seconds.abs() : seconds.abs();
    _seekFlash.value = (seconds.sign, total);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 700), () => _seekFlash.value = null);
    if (_controls) _scheduleHide();
  }

  void _convert() {
    final source = widget.original ?? widget.clip;
    final info = Library.instance.info(source) ?? widget.info;
    _video?.pause();
    showConvertSheet(context, source, info);
  }

  void _cycleRate() {
    const rates = [1.0, 1.25, 1.5, 2.0, 0.5, 0.75];
    final next = rates[(rates.indexOf(_rate) + 1) % rates.length];
    setState(() => _rate = next);
    _video?.setRate(next);
    _scheduleHide();
  }

  void _setZoom(bool fill) {
    HapticFeedback.selectionClick();
    fill ? _zoom.animateTo(1, curve: Motion.spring) : _zoom.animateTo(0, curve: Motion.spring);
  }

  /// Fullscreen = turn the phone to match the video (landscape clips go landscape), bars hidden.
  void _toggleFullscreen() {
    HapticFeedback.selectionClick();
    final aspect = _video?.state.value.aspect ?? 16 / 9;
    final orientation = MediaQuery.orientationOf(context);
    final landscapeVideo = aspect >= 1;
    final goFull = !_fullscreen;
    setState(() => _fullscreen = goFull);
    if (goFull) {
      SystemChrome.setPreferredOrientations(landscapeVideo
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp]);
      if (!landscapeVideo && orientation == Orientation.portrait) _setZoom(true);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      // Then hand rotation back to the sensor.
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted && !_fullscreen) SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      });
      _setZoom(false);
    }
    _scheduleHide();
  }

  void _more(BuildContext anchor) {
    final clip = widget.clip;
    final source = widget.original ?? clip;
    final converting = TaskCenter.instance.conversionFor(source.uri)?.active ?? false;
    showGlassMenu(context, anchor: anchor, title: clip.name, actions: [
      if (widget.original != null)
        MenuAction('Play Original', icon: AppIcons.film, onTap: () {
          Navigator.of(context).pushReplacement(PlayerPage.route(
              widget.original!, Library.instance.info(widget.original!) ?? widget.info,
              preview: true));
        }),
      if (_preview && widget.original == null && !converting && Library.instance.copyOf(source) == null)
        MenuAction('Make Phone-Playable', icon: AppIcons.wand_stars, onTap: _convert),
      MenuAction(_zoom.value > 0.5 ? 'Fit to Screen' : 'Fill Screen',
          icon: _zoom.value > 0.5 ? AppIcons.arrow_down_right_arrow_up_left : AppIcons.arrow_up_left_arrow_down_right,
          onTap: () => _setZoom(_zoom.value <= 0.5)),
      MenuAction('Share to WhatsApp', icon: AppIcons.chat_bubble_2, onTap: () => ClipActions.share(clip, forWhatsApp: true)),
    ]);
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final v = _video;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: v == null
            ? const ColoredBox(color: Colors.black, child: Center(child: LogoSpinner(size: 54)))
            : ValueListenableBuilder<PlayState>(
                valueListenable: v.state,
                builder: (context, s, _) => Stack(fit: StackFit.expand, children: [
                  AnimatedBuilder(
                    animation: Listenable.merge([_zoom, _reveal]),
                    builder: (context, _) => VideoStageView(
                      controller: v,
                      poster: _poster,
                      aspect: s.aspect,
                      zoom: _zoom.value,
                      reveal: Curves.easeOut.transform(_reveal.value),
                    ),
                  ),
                  _gestures(),
                  _SeekFlash(flash: _seekFlash),
                  _swipeOverlay(),
                  _LevelHud(level: _level),
                  IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: s.buffering && s.error == null ? 1 : 0,
                      duration: Motion.quick,
                      child: const Center(child: LogoSpinner(size: 58)),
                    ),
                  ),
                  _overlay(v, s),
                  if (s.error != null) _errorCard(s.error!),
                ]),
              ),
      ),
    );
  }

  /// Loads the pictures of the videos either side now, so they're ready the instant a swipe brings one in.
  void _precacheNeighbors() {
    final i = _queueIndex;
    if (i < 0) return;
    for (final j in [i - 1, i + 1]) {
      if (j < 0 || j >= widget.queue.length) continue;
      final t = Library.instance.thumb(widget.queue[j]);
      if (t != null) precacheImage(FileImage(File(t)), context);
    }
  }

  /// Position of what's playing in the list it was opened from, or -1.
  int get _queueIndex {
    final uri = (widget.original ?? widget.clip).uri;
    return widget.queue.indexWhere((c) => c.uri == uri);
  }

  /// Moves the incoming picture with the finger: swiping left brings the next video in from the right, swiping
  /// right brings the previous one in from the left.
  void _followSwipe(double dx) {
    if (_swipeShift.value == 0 && !_swipeShown) _hideControls();
    final dir = dx < 0 ? 1 : -1;
    final i = _queueIndex;
    final j = i + dir;
    final ok = i >= 0 && j >= 0 && j < widget.queue.length;
    if (dir != _swipeDir || ok != _swipeShown) {
      _swipeDir = dir;
      _swipeShown = ok;
      _swipeTo = ok ? j : -1;
      _swipeThumb = ok ? Library.instance.thumb(widget.queue[j]) : null;
    }
    _swipeShift.value = dx;
  }

  Future<void> _finishSwipe(double velocityX) async {
    final w = MediaQuery.sizeOf(context).width;
    final dx = _swipeDx;
    if (!_swipeShown) {
      // Nothing further that way: say so.
      if (dx.abs() > 70 || velocityX.abs() > 600) {
        HapticFeedback.heavyImpact();
        Toast.info(dx < 0 ? 'That\'s the last video' : 'That\'s the first video');
      }
      _swipeShift.value = 0;
      return;
    }
    final commit = dx.abs() > w * 0.28 || (velocityX.abs() > 700 && velocityX.sign == dx.sign);
    _glideSwipe(commit ? (_swipeDir > 0 ? -w : w) : 0, commit ? Curves.easeOutCubic : Motion.spring, commit ? 250 : 340);
    await _swipeAnim.forward(from: 0);
    if (!mounted) return;
    if (commit) {
      await _commitSwipe(w);
    } else {
      _swipeShown = false;
      _swipeShift.value = 0;
    }
  }

  void _glideSwipe(double to, Curve curve, int ms) {
    _swipeFrom = _swipeShift.value;
    _swipeTarget = to;
    _swipeCurve = curve;
    _swipeAnim.duration = Duration(milliseconds: ms);
  }

  /// The picture has slid fully in; switch to the new video behind it, with no second animation.
  Future<void> _commitSwipe(double width) async {
    final j = _swipeTo;
    if (_navigating || j < 0) return;
    _navigating = true;
    HapticFeedback.mediumImpact();
    final wasPlaying = _video?.state.value.playing ?? false;
    var swapped = false;
    try {
      await _video?.pause();
      if (!mounted) return;
      swapped = await ClipActions.replaceWith(context, widget.queue[j], queue: widget.queue, instant: true);
    } finally {
      _navigating = false;
    }
    if (swapped || !mounted) return;
    // The next clip couldn't be opened: slide the picture back and carry on.
    _glideSwipe(0, Curves.easeOutCubic, 280);
    await _swipeAnim.forward(from: 0);
    if (!mounted) return;
    _swipeShown = false;
    _swipeShift.value = 0;
    if (wasPlaying) _video?.play();
  }

  /// The incoming picture, drawn above the player while it slides in.
  Widget _swipeOverlay() {
    return ValueListenableBuilder<double>(
      valueListenable: _swipeShift,
      builder: (context, dx, _) {
        if (!_swipeShown || dx == 0) return const SizedBox.shrink();
        final w = MediaQuery.sizeOf(context).width;
        final shift = (_swipeDir > 0 ? w : -w) + dx;
        final thumb = _swipeThumb;
        return IgnorePointer(
          child: Transform.translate(
            offset: Offset(shift, 0),
            child: ColoredBox(
              color: Colors.black,
              child: SizedBox.expand(
                child: thumb == null
                    ? const Center(child: LogoSpinner(size: 40))
                    : Image.file(File(thumb), fit: BoxFit.contain, gaplessPlayback: true),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _beginLevel(int kind, double height) async {
    _levelKind = kind;
    _levelBase = null;
    _levelWant = null;
    _levelTimer?.cancel();
    _hideControls();
    // A full-height swipe is a bit more than the whole range, so it never needs two goes.
    _levelSpan = math.max(160.0, height * 0.7);
    HapticFeedback.selectionClick();
    final now = await Engine.call<double>(kind == 1 ? 'volume' : 'brightness', {}) ?? 0.5;
    if (_levelKind != kind) return;
    _levelBase = now;
    _level.value = (kind, now);
    _applyLevel();
  }

  void _applyLevel() {
    final base = _levelBase;
    if (base == null || _levelKind == 0) return;
    final v = (base - _levelDy / _levelSpan).clamp(0.0, 1.0);
    _levelWant = v;
    _level.value = (_levelKind, v);
    _pushLevel();
  }

  /// Sends the latest wanted level to Android, one call at a time so a fast swipe doesn't flood the channel.
  Future<void> _pushLevel() async {
    if (_levelBusy) return;
    _levelBusy = true;
    try {
      while (_levelKind != 0) {
        final want = _levelWant;
        if (want == null) break;
        await Engine.call<double>(_levelKind == 1 ? 'volume' : 'brightness', {'value': want});
        if (_levelWant == want) break;
      }
    } finally {
      _levelBusy = false;
    }
  }

  void _endLevel() {
    _levelKind = 0;
    _levelBase = null;
    _levelTimer?.cancel();
    _levelTimer = Timer(const Duration(milliseconds: 700), () => _level.value = null);
  }

  Widget _gestures() {
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggleControls,
        onDoubleTapDown: (d) => _seekBy(d.localPosition.dx < box.maxWidth / 2 ? -10 : 10),
        onDoubleTap: () {},
        onScaleStart: (d) {
          _dragStart = d.focalPoint;
          _dragLocked = false;
          _dragDy = 0;
          _levelRejected = false;
          _infoOpened = false;
          _hSwipe = false;
          _swipeDx = 0;
        },
        onScaleUpdate: (d) {
          if (d.pointerCount >= 2) {
            if (d.scale > 1.12 && _zoom.value < 0.5 && !_zoom.isAnimating) _setZoom(true);
            if (d.scale < 0.9 && _zoom.value > 0.5 && !_zoom.isAnimating) _setZoom(false);
            return;
          }
          final delta = d.focalPoint - _dragStart;
          // A clearly sideways swipe moves to the next or previous video (decided when the finger lifts).
          if (_levelKind == 0 && !_dragLocked && !_closing && !_hSwipe && !_infoOpened && !_navigating &&
              !_swipeAnim.isAnimating && delta.dx.abs() > 18 && delta.dx.abs() > delta.dy.abs() * 1.6) {
            _hSwipe = true;
          }
          if (_hSwipe) {
            _swipeDx = delta.dx;
            _followSwipe(delta.dx);
            return;
          }
          // Fullscreen or sideways: swipe up and down on the left half for volume, on the right half for brightness.
          if (_fullscreen || MediaQuery.orientationOf(context) == Orientation.landscape) {
            if (_levelKind == 0 && !_levelRejected) {
              if (delta.dy.abs() > 12 && delta.dy.abs() > delta.dx.abs() * 1.3) {
                _beginLevel(_dragStart.dx < box.maxWidth / 2 ? 1 : 2, box.maxHeight);
              } else if (delta.dx.abs() > 24) {
                _levelRejected = true;
              }
            }
            if (_levelKind != 0) {
              _levelDy = delta.dy;
              _applyLevel();
            }
            return;
          }
          // One finger moving up opens the details, the way Samsung's Gallery does.
          if (!_infoOpened && delta.dy < -70 && delta.dy.abs() > delta.dx.abs() * 1.6) {
            _infoOpened = true;
            HapticFeedback.selectionClick();
            showInfoSheet(context, widget.clip);
            return;
          }
          // One finger moving down closes the player, the way an iOS photo or video sheet does.
          if (!_dragLocked && !_closing) {
            if (delta.dy > 14 && delta.dy.abs() > delta.dx.abs() * 1.2 && !_fullscreen && _zoomRoute != null) {
              _dragLocked = true;
              _zoomRoute!.beginDrag();
              _hideControls();
              _video?.setVisible(false);
              _reveal.value = 0;
            } else {
              return;
            }
          }
          if (!_dragLocked) return;
          _dragDy = math.max(0, delta.dy);
          _zoomRoute!.dragX.value = delta.dx;
          _zoomRoute!.dragTo((_dragDy / (MediaQuery.sizeOf(context).height * 0.55)).clamp(0.0, 1.0));
        },
        onScaleEnd: (d) {
          if (_hSwipe) {
            _hSwipe = false;
            _finishSwipe(d.velocity.pixelsPerSecond.dx);
            return;
          }
          if (_levelKind != 0) {
            _endLevel();
            return;
          }
          if (!_dragLocked) return;
          _dragLocked = false;
          final height = MediaQuery.sizeOf(context).height;
          final dismiss = _dragDy > height * 0.16 || d.velocity.pixelsPerSecond.dy > 700;
          _closing = dismiss;
          _zoomRoute?.endDrag(dismiss: dismiss);
          if (!dismiss) {
            HapticFeedback.selectionClick();
            _video?.setVisible(true);
          } else {
            HapticFeedback.lightImpact();
          }
        },
      ),
    );
  }

  Widget _overlay(VideoController v, PlayState s) {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final info = widget.info;
    final subtitle = [
      info.formatName,
      if (info.resolutionLabel.isNotEmpty) info.resolutionLabel,
      if (info.fpsLabel.isNotEmpty) '${info.fpsLabel} fps',
    ].join(' · ');
    final playIcon = s.completed
        ? AppIcons.arrow_counterclockwise
        : (s.playing ? AppIcons.pause_fill : AppIcons.play_fill);

    return AnimatedBuilder(
      animation: _controlsAnim,
      builder: (context, child) {
        final t = Curves.easeOut.transform(_controlsAnim.value);
        return IgnorePointer(
          ignoring: !_controls,
          child: Opacity(opacity: t, child: child),
        );
      },
      child: Stack(children: [
        // Scrims keep white controls readable on bright footage.
        const Positioned(left: 0, right: 0, top: 0, height: 150, child: _Scrim(top: true)),
        const Positioned(left: 0, right: 0, bottom: 0, height: 240, child: _Scrim(top: false)),
        SafeArea(
          minimum: EdgeInsets.symmetric(horizontal: landscape ? 12 : 0),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Row(children: [
                _PlayerButton(icon: AppIcons.xmark, onTap: () => Navigator.pop(context), label: 'Close'),
                const Spacer(),
                ValueListenableBuilder<PlaybackInfo?>(
                  valueListenable: v.info,
                  builder: (context, pi, _) => AnimatedSwitcher(
                    duration: Motion.medium,
                    child: pi == null ? const SizedBox() : _EngineChip(key: ValueKey(pi.label), info: pi),
                  ),
                ),
                const SizedBox(width: 8),
                _PlayerButton(
                    icon: AppIcons.info_circle,
                    onTap: () => showInfoSheet(context, widget.clip),
                    label: 'Info'),
                const SizedBox(width: 8),
                _PlayerButton(icon: AppIcons.share, onTap: () => ClipActions.share(widget.clip), label: 'Share'),
                const SizedBox(width: 8),
                Builder(
                  builder: (anchor) => _PlayerButton(
                      icon: AppIcons.ellipsis, onTap: () => _more(anchor), label: 'More options'),
                ),
              ]),
            ),
            // Landscape is for watching: the banner stays out of the way there.
            if (_preview && widget.original == null && !_bannerDismissed && !landscape)
              ValueListenableBuilder<PlaybackInfo?>(
                valueListenable: v.info,
                builder: (context, pi, _) => _PreviewBanner(
                  clip: widget.clip,
                  reduced: pi?.reduced ?? false,
                  previewOnly: (pi?.stage ?? 0) >= 3,
                  onConvert: _convert,
                  onPlayCopy: _playCopy,
                  onDismiss: () => setState(() => _bannerDismissed = true),
                ),
              ),
            const Spacer(),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _PlayerButton(
                  plain: true,
                  icon: AppIcons.gobackward_10,
                  size: landscape ? 56 : 64,
                  onTap: () => _seekBy(-10),
                  label: 'Back 10 seconds'),
              SizedBox(width: landscape ? 48 : 28),
              _PlayerButton(
                  plain: true,
                  icon: playIcon,
                  size: landscape ? 84 : 96,
                  iconSize: landscape ? 54 : 62,
                  onTap: _togglePlay,
                  label: s.playing ? 'Pause' : 'Play'),
              SizedBox(width: landscape ? 48 : 28),
              _PlayerButton(
                  plain: true,
                  icon: AppIcons.goforward_10,
                  size: landscape ? 56 : 64,
                  onTap: () => _seekBy(10),
                  label: 'Forward 10 seconds'),
            ]),
            const Spacer(),
            Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, landscape ? 6 : 10),
              child: _BottomPanel(
                compact: landscape,
                title: widget.clip.name,
                subtitle: widget.original != null ? 'Phone-playable copy · $subtitle' : subtitle,
                video: v,
                state: s,
                scrub: _scrub,
                rate: _rate,
                muted: _muted,
                fullscreen: _fullscreen,
                live: _controls,
                onScrubStart: () {
                  _wasPlaying = s.playing;
                  v.pause();
                  _hideTimer?.cancel();
                },
                onScrub: (d) {
                  setState(() => _scrub = d);
                  v.seek(d);
                },
                onScrubEnd: () {
                  final to = _scrub;
                  setState(() => _scrub = null);
                  if (to != null) v.seek(to);
                  if (_wasPlaying) v.play();
                  _scheduleHide();
                },
                onRate: _cycleRate,
                onStep: (dir) {
                  v.step(dir);
                  _scheduleHide();
                },
                onMute: () {
                  setState(() => _muted = !_muted);
                  v.setVolume(_muted ? 0 : 1);
                  _scheduleHide();
                },
                onFullscreen: _toggleFullscreen,
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _errorCard(String error) {
    final p = Palette.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: LiquidGlass(
            radius: 34,
            blur: 0,
            tint: const Color(0xF21C1C1E),
            padding: const EdgeInsets.fromLTRB(22, 26, 22, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(AppIcons.exclamationmark_triangle_fill, color: p.orange, size: 42),
              const SizedBox(height: 14),
              Text('Couldn\'t play this clip', style: TextStyles.title3(p), textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(error, style: TextStyles.footnote(p), textAlign: TextAlign.center, maxLines: 4),
              const SizedBox(height: 22),
              if (!_preview) ...[
                GlassButton('Try ProView\'s Engine', prominent: true, onTap: _switchToEngine),
                const SizedBox(height: 10),
              ],
              GlassButton('Make Phone-Playable', prominent: _preview, onTap: _convert),
              const SizedBox(height: 10),
              GlassButton('Close', color: Colors.white70, onTap: () => Navigator.pop(context)),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _Scrim extends StatelessWidget {
  final bool top;
  const _Scrim({required this.top});
  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: top ? Alignment.topCenter : Alignment.bottomCenter,
              end: top ? Alignment.bottomCenter : Alignment.topCenter,
              colors: const [Color(0x8C000000), Color(0x00000000)],
            ),
          ),
        ),
      );
}

/// Round glass control over video. The video layer sits under Flutter, so the glass is a dark tint
/// with the specular rim rather than a blur.
class _PlayerButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final double? iconSize;
  final String label;

  /// Just the glyph over the picture (the centre transport row), no glass plate.
  final bool plain;
  const _PlayerButton(
      {required this.icon, required this.onTap, required this.label, this.size = 44, this.iconSize, this.plain = false});
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: Pressable(
          onTap: onTap,
          scale: 0.86,
          child: _plate(
            SizedBox.square(
              dimension: size,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (child, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: child)),
                child: Icon(icon,
                    key: ValueKey(icon),
                    color: Colors.white,
                    size: iconSize ?? size * (plain ? 0.62 : 0.44),
                    shadows: plain ? const [Shadow(blurRadius: 16, color: Color(0x80000000))] : null),
              ),
            ),
          ),
        ),
      );

  Widget _plate(Widget child) => plain
      ? child
      : LiquidGlass(blur: 0, shadow: false, tint: Colors.black.withValues(alpha: 0.32), child: child);
}

class _EngineChip extends StatelessWidget {
  final PlaybackInfo info;
  const _EngineChip({super.key, required this.info});
  @override
  Widget build(BuildContext context) {
    final accent = info.reduced ? const Color(0xFFFFB340) : (info.gpuDecode ? const Color(0xFF63B3FF) : Colors.white70);
    return LiquidGlass(
      blur: 0,
      shadow: false,
      tint: Colors.black.withValues(alpha: 0.32),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(info.reduced ? AppIcons.speedometer : (info.gpuDecode ? AppIcons.bolt_fill : AppIcons.memories),
              size: 13, color: accent),
          const SizedBox(width: 6),
          Text(info.label,
              style: const TextStyle(fontFamily: kFont, fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white)),
        ]),
      ),
    );
  }
}

/// The volume / brightness bar that appears at the edge of the screen while swiping.
class _LevelHud extends StatelessWidget {
  final ValueNotifier<(int, double)?> level;
  const _LevelHud({required this.level});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<(int, double)?>(
        valueListenable: level,
        builder: (context, l, _) {
          final kind = l?.$1 ?? 0;
          return SafeArea(
            minimum: const EdgeInsets.symmetric(horizontal: 18),
            child: AnimatedOpacity(
              opacity: l == null ? 0 : 1,
              duration: const Duration(milliseconds: 180),
              child: Align(
                alignment: kind == 2 ? Alignment.centerRight : Alignment.centerLeft,
                child: l == null ? const SizedBox() : _bar(kind, l.$2),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _bar(int kind, double v) {
    final icon = kind == 1
        ? (v <= 0.001 ? AppIcons.volume_off : (v < 0.5 ? AppIcons.volume_low : AppIcons.volume_high))
        : (v < 0.4 ? AppIcons.brightness_low : AppIcons.brightness);
    return Container(
      width: 52,
      height: 190,
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: ShapeDecoration(color: const Color(0x73000000), shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(26))),
      child: Column(children: [
        Expanded(
          child: Container(
            width: 8,
            decoration: ShapeDecoration(color: Colors.white24, shape: const StadiumBorder()),
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: v.clamp(0.0, 1.0),
              child: DecoratedBox(decoration: ShapeDecoration(color: Colors.white, shape: const StadiumBorder())),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Icon(icon, color: Colors.white, size: 22),
      ]),
    );
  }
}

class _SeekFlash extends StatelessWidget {
  final ValueNotifier<(int, int)?> flash;
  const _SeekFlash({required this.flash});
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<(int, int)?>(
        valueListenable: flash,
        builder: (context, f, _) {
          return Row(children: [
            Expanded(child: _side(f != null && f.$1 < 0, f?.$2 ?? 0, AppIcons.backward_fill)),
            const Spacer(),
            Expanded(child: _side(f != null && f.$1 > 0, f?.$2 ?? 0, AppIcons.forward_fill)),
          ]);
        },
      ),
    );
  }

  Widget _side(bool on, int seconds, IconData icon) => AnimatedOpacity(
        opacity: on ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: AnimatedScale(
          scale: on ? 1 : 0.8,
          duration: const Duration(milliseconds: 300),
          curve: Motion.spring,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: Colors.white, size: 30, shadows: const [Shadow(blurRadius: 12, color: Colors.black54)]),
              const SizedBox(height: 6),
              Text('$seconds seconds',
                  style: const TextStyle(
                      fontFamily: kFont,
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(blurRadius: 10, color: Colors.black54)])),
            ]),
          ),
        ),
      );
}

/// Title, scrubber, times and secondary controls in one glass panel (iOS 26 player layout).
class _BottomPanel extends StatelessWidget {
  final bool compact;
  final String title;
  final String subtitle;
  final VideoController video;
  final PlayState state;
  final Duration? scrub;
  final double rate;
  final bool muted;
  final bool fullscreen;
  final bool live;
  final VoidCallback onScrubStart;
  final ValueChanged<Duration> onScrub;
  final VoidCallback onScrubEnd;
  final VoidCallback onRate;
  final ValueChanged<int> onStep;
  final VoidCallback onMute;
  final VoidCallback onFullscreen;
  const _BottomPanel({
    required this.compact,
    required this.title,
    required this.subtitle,
    required this.video,
    required this.state,
    required this.scrub,
    required this.rate,
    required this.muted,
    required this.fullscreen,
    required this.live,
    required this.onScrubStart,
    required this.onScrub,
    required this.onScrubEnd,
    required this.onRate,
    required this.onStep,
    required this.onMute,
    required this.onFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: LiquidGlass(
        radius: compact ? 24 : 30,
        blur: 0,
        shadow: false,
        tint: Colors.black.withValues(alpha: 0.36),
        padding: EdgeInsets.fromLTRB(18, compact ? 10 : 14, 18, compact ? 2 : 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Title and details share one line in landscape to leave room for the picture.
          Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: title,
                  style: const TextStyle(fontFamily: kFont, color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
              if (compact)
                TextSpan(
                    text: '   $subtitle',
                    style: const TextStyle(fontFamily: kFont, color: Colors.white60, fontSize: 12.5, fontWeight: FontWeight.w500)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.fade,
          ),
          if (!compact) ...[
            const SizedBox(height: 1),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.fade,
                style: const TextStyle(fontFamily: kFont, color: Colors.white60, fontSize: 12.5, fontWeight: FontWeight.w500)),
          ],
          SizedBox(height: compact ? 4 : 10),
          _Scrubber(
            live: live,
            video: video,
            scrub: scrub,
            duration: state.duration,
            onStart: onScrubStart,
            onChanged: onScrub,
            onEnd: onScrubEnd,
          ),
          SizedBox(height: compact ? 0 : 4),
          Row(children: [
            _PanelButton(
              onTap: onRate,
              child: Text(rate == 1 ? '1×' : '${rate.toString().replaceAll(RegExp(r'\.0$'), '')}×',
                  style: const TextStyle(fontFamily: kFont, color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
            ),
            const Spacer(),
            _PanelButton(onTap: () => onStep(-1), child: const Icon(AppIcons.backward_end_fill, color: Colors.white, size: 19)),
            _PanelButton(onTap: () => onStep(1), child: const Icon(AppIcons.forward_end_fill, color: Colors.white, size: 19)),
            const Spacer(),
            _PanelButton(
              onTap: onMute,
              child: Icon(muted ? AppIcons.speaker_slash_fill : AppIcons.speaker_2_fill, color: Colors.white, size: 19),
            ),
            _PanelButton(
              onTap: onFullscreen,
              child: Icon(
                  fullscreen ? AppIcons.arrow_down_right_arrow_up_left : AppIcons.arrow_up_left_arrow_down_right,
                  color: Colors.white,
                  size: 18),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _PanelButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const _PanelButton({required this.child, required this.onTap});
  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        scale: 0.85,
        child: SizedBox(width: 48, height: 42, child: Center(child: child)),
      );
}

/// iOS 26-style scrubber: a capsule track that thickens while dragging, with a time bubble; the
/// position glides between updates.
class _Scrubber extends StatefulWidget {
  final bool live;
  final VideoController video;
  final Duration? scrub;
  final Duration duration;
  final VoidCallback onStart;
  final ValueChanged<Duration> onChanged;
  final VoidCallback onEnd;
  const _Scrubber({
    required this.live,
    required this.video,
    required this.scrub,
    required this.duration,
    required this.onStart,
    required this.onChanged,
    required this.onEnd,
  });
  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> with SingleTickerProviderStateMixin {
  bool _active = false;
  DateTime _lastSeek = DateTime(0);
  late final _ticker = createTicker((_) {
    if (mounted && !_active) setState(() {});
  });

  @override
  void initState() {
    super.initState();
    if (widget.live) _ticker.start();
  }

  @override
  void didUpdateWidget(_Scrubber old) {
    super.didUpdateWidget(old);
    // The glide animation only runs while the controls are on screen.
    if (widget.live && !_ticker.isActive) _ticker.start();
    if (!widget.live && _ticker.isActive) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _update(double dx, double width) {
    if (widget.duration <= Duration.zero) return;
    final f = (dx / width).clamp(0.0, 1.0);
    final to = Duration(milliseconds: (widget.duration.inMilliseconds * f).round());
    final now = DateTime.now();
    // Throttle seeks so heavy formats keep up while dragging.
    if (now.difference(_lastSeek).inMilliseconds > 70) {
      _lastSeek = now;
      widget.onChanged(to);
    }
  }

  @override
  Widget build(BuildContext context) {
    final position = widget.scrub ?? widget.video.livePosition;
    final total = widget.duration.inMilliseconds;
    final f = total > 0 ? (position.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
    final remaining = widget.duration - position > Duration.zero ? widget.duration - position : Duration.zero;
    return Column(children: [
      LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) {
            setState(() => _active = true);
            HapticFeedback.selectionClick();
            widget.onStart();
            _update(d.localPosition.dx, w);
          },
          onHorizontalDragUpdate: (d) => _update(d.localPosition.dx, w),
          onHorizontalDragEnd: (_) {
            setState(() => _active = false);
            widget.onEnd();
          },
          onTapUp: (d) {
            widget.onStart();
            _lastSeek = DateTime(0);
            _update(d.localPosition.dx, w);
            widget.onEnd();
          },
          child: SizedBox(
            height: 26,
            child: Stack(alignment: Alignment.centerLeft, clipBehavior: ui.Clip.none, children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Motion.spring,
                height: _active ? 12 : 6,
                decoration: ShapeDecoration(color: Colors.white.withValues(alpha: 0.25), shape: const StadiumBorder()),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Motion.spring,
                height: _active ? 12 : 6,
                width: math.max(_active ? 12 : 6, w * f),
                decoration: const ShapeDecoration(color: Colors.white, shape: StadiumBorder()),
              ),
              if (_active)
                Positioned(
                  left: (w * f - 36).clamp(0.0, math.max(0.0, w - 72)),
                  top: -36,
                  child: Container(
                    width: 72,
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    decoration: const ShapeDecoration(color: Colors.white, shape: StadiumBorder()),
                    child: Text(formatDuration(position),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontFamily: kFont,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Colors.black,
                            fontFeatures: [FontFeature.tabularFigures()])),
                  ),
                ),
            ]),
          ),
        );
      }),
      const SizedBox(height: 2),
      Row(children: [
        Text(formatDuration(position), style: _time),
        const Spacer(),
        Text('-${formatDuration(remaining)}', style: _time),
      ]),
    ]);
  }

  static const _time = TextStyle(
      fontFamily: kFont,
      color: Colors.white70,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      fontFeatures: [FontFeature.tabularFigures()]);
}

/// Explains preview mode and shows live conversion progress for this clip.
class _PreviewBanner extends StatelessWidget {
  final Clip clip;
  final bool reduced;
  final bool previewOnly;
  final VoidCallback onConvert;
  final void Function(BgTask) onPlayCopy;
  final VoidCallback onDismiss;
  const _PreviewBanner(
      {required this.clip,
      required this.reduced,
      required this.previewOnly,
      required this.onConvert,
      required this.onPlayCopy,
      required this.onDismiss});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: TaskCenter.instance,
      builder: (context, _) {
        final t = TaskCenter.instance.conversionFor(clip.uri);
        final converting = t != null && t.active;
        final done = t != null && t.state == TaskState.done;
        // Say nothing while playback is fine; speak up only when the phone can't keep up.
        if (!reduced && !converting && !done) return const SizedBox(width: double.infinity);
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: LiquidGlass(
              radius: 24,
              blur: 0,
              shadow: false,
              tint: Colors.black.withValues(alpha: 0.36),
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(children: [
                if (converting)
                  LogoProgress(value: t.state == TaskState.running ? t.progress : null, size: 30, trackColor: Colors.white24)
                else
                  Icon(done ? AppIcons.checkmark_seal_fill : AppIcons.speedometer,
                      color: done ? const Color(0xFF30D158) : const Color(0xFFFFB340), size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      done
                          ? 'Smooth copy ready'
                          : converting
                              ? 'Making phone-playable${t.state == TaskState.running ? ' · ${((t.progress ?? 0) * 100).round()}%' : ''}'
                              : (previewOnly ? 'Too heavy to play live' : 'Reduced quality'),
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      style: const TextStyle(fontFamily: kFont, color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      done
                          ? 'Switch to full-quality, perfectly smooth playback'
                          : converting
                              ? 'Keeps going in the background'
                              : (previewOnly
                                  ? 'Showing keyframes until a smooth copy is ready'
                                  : 'Convert for full quality'),
                      maxLines: 2,
                      style: const TextStyle(fontFamily: kFont, color: Colors.white60, fontSize: 11.5),
                    ),
                  ]),
                ),
                if (!converting && !done) ...[
                  GlassButton('Convert', prominent: true, height: 34, expand: false, onTap: onConvert),
                  const SizedBox(width: 2),
                ],
                if (done) ...[
                  GlassButton('Play Copy', prominent: true, height: 34, expand: false, onTap: () => onPlayCopy(t)),
                  const SizedBox(width: 2),
                ],
                Pressable(
                  onTap: onDismiss,
                  scale: 0.85,
                  child: const SizedBox.square(
                      dimension: 34, child: Icon(AppIcons.xmark, size: 15, color: Colors.white60)),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}
