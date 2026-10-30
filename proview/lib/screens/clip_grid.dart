import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../clip_actions.dart';
import '../engine.dart';
import '../library.dart';
import '../selection.dart';
import '../tasks.dart';
import '../theme.dart';
import '../ui/pinch_resize.dart';
import '../widgets.dart';
import '../ui/app_icons.dart';

/// Photos-style square grid of clips.
class ClipGrid extends StatelessWidget {
  final List<Clip> clips;

  /// The whole list a swipe in the player moves through (defaults to [clips]); a library split into date sections
  /// passes the full sorted list so the player can carry on into the next section.
  final List<Clip>? queue;
  const ClipGrid({super.key, required this.clips, this.queue});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Library.instance.settings,
      builder: (context, _) => SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: Library.instance.settings.tileExtent,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => PinchTile(key: ValueKey(clips[i].key), child: ClipTile(clip: clips[i], queue: queue ?? clips)),
            childCount: clips.length,
            addAutomaticKeepAlives: false,
            findChildIndexCallback: (key) {
              final k = (key as ValueKey<String>).value;
              final i = clips.indexWhere((c) => c.key == k);
              return i < 0 ? null : i;
            },
          ),
        ),
      ),
    );
  }
}

class ClipTile extends StatelessWidget {
  final Clip clip;
  final List<Clip> queue;
  const ClipTile({super.key, required this.clip, this.queue = const []});

  @override
  Widget build(BuildContext context) {
    final lib = Library.instance;
    lib.ensureProcessed(clip);
    return Builder(builder: (anchor) {
      return MetaData(
        metaData: clip,
        behavior: HitTestBehavior.translucent,
        child: Pressable(
        scale: 0.96,
        onTap: () {
          final sel = Selection.instance;
          if (sel.active) {
            sel.toggle(clip);
            return;
          }
          // The player zooms out of this tile and back into it.
          Rect? from;
          final box = anchor.findRenderObject();
          if (box is RenderBox && box.hasSize) from = box.localToGlobal(Offset.zero) & box.size;
          ClipActions.open(context, clip, from: from, queue: queue);
        },
        // Long-press starts selecting; keep the finger down and drag to select more.
        onLongPress: () {
          final sel = Selection.instance;
          sel.active ? sel.toggle(clip) : sel.begin(clip);
        },
        child: RepaintBoundary(
          // Rounded corners are drawn into each shape (picture, scrims, overlays) rather than clipped: a clip per tile
          // is a stencil pass per tile, and this is the busiest widget in the app.
          child: ListenableBuilder(
            listenable: lib.clipListenable(clip),
            builder: (context, _) => _content(context, lib),
          ),
        ),
        ),
      );
    });
  }

  Widget _content(BuildContext context, Library lib) {
    final p = Palette.of(context);
    final info = lib.info(clip);
    final thumb = lib.thumb(clip);
    final failed = lib.failed(clip);
    final hasCopy = lib.copyOf(clip) != null;
    final seconds = info?.duration ?? clip.durationMs / 1000;
    final res = info == null ? '' : '${info.resolutionLabel}${info.fpsLabel}';
    return LayoutBuilder(builder: (context, box) => _tile(context, lib, p, info, thumb, failed, hasCopy, seconds, res, box.maxWidth));
  }

  Widget _tile(BuildContext context, Library lib, Palette p, ClipInfo? info, String? thumb, bool failed, bool hasCopy,
      double seconds, String res, double width) {
    // Labels shrink with the tile instead of disappearing, so the quality tags (ProRes, 4K60...) stay on at every size.
    final f = (width / 124).clamp(0.6, 1.15);
    final showDuration = seconds > 0 && width >= 60;
    final label = _label.copyWith(fontSize: 12 * f);
    final iconSize = 16 * f;
    return Stack(fit: StackFit.expand, children: [
      // Background and picture in one rounded shape. No fade-in: a fading image is an offscreen layer.
      DecoratedBox(
        decoration: BoxDecoration(
          color: p.fill,
          borderRadius: _radius,
          image: thumb == null
              ? null
              : DecorationImage(image: ResizeImage(FileImage(File(thumb)), width: 360), fit: BoxFit.cover),
        ),
      ),
      if (thumb == null)
        Center(
          child: failed
              ? Icon(AppIcons.exclamationmark_triangle, color: p.tertiaryLabel)
              // Static: dozens of animated placeholders on screen at once made scrolling stutter.
              : Icon(AppIcons.film, color: p.tertiaryLabel, size: 24 * f),
        ),
      // Scrims keep the white tags legible on any picture. Plain gradients: far cheaper than blurred text shadows.
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: 40 * f,
        child: const DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xB3000000), Color(0x00000000)],
            ),
          ),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        height: 30 * f,
        child: const DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x73000000), Color(0x00000000)],
            ),
          ),
        ),
      ),
      if (info != null && info.badge.isNotEmpty)
        Positioned(
          left: 4 + 2 * f,
          top: 3 + 2 * f,
          child: FormatBadge(info.badge, color: info.native ? null : const Color(0xFF2F6BF2), scale: f),
        ),
      Positioned(
        right: 4 + 2 * f,
        top: 3 + 2 * f,
        child: _HideWhileSelecting(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (lib.isFavorite(clip)) Icon(AppIcons.heart_fill, color: Colors.white, size: iconSize),
            if (hasCopy || clip.isProViewCopy) ...[
              SizedBox(width: 3 * f),
              Icon(AppIcons.checkmark_seal_fill, color: Colors.white, size: iconSize + 1),
            ],
          ]),
        ),
      ),
      if (res.isNotEmpty || showDuration)
        Positioned(
          left: 4 + 2 * f,
          right: 4 + 2 * f,
          bottom: 2 + 2 * f,
          child: Row(children: [
            if (res.isNotEmpty) Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(res, style: label))),
            const Spacer(),
            if (showDuration)
              Text(formatDuration(Duration(milliseconds: (seconds * 1000).round())), style: label),
          ]),
        ),
      _ConversionOverlay(uri: clip.uri),
      _SelectionMark(clip: clip),
    ]);
  }

  static const _radius = BorderRadius.all(Radius.circular(16));

  static const _label = TextStyle(
    fontFamily: kFont,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: Colors.white,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// Live conversion progress on a tile (the only part that rebuilds as progress ticks).
class _ConversionOverlay extends StatelessWidget {
  final String uri;
  const _ConversionOverlay({required this.uri});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: TaskCenter.instance.convertTick,
      builder: (context, _, _) {
        final task = TaskCenter.instance.conversionFor(uri);
        final converting = task != null && task.active;
        return IgnorePointer(
          child: AnimatedOpacity(
            opacity: converting ? 1 : 0,
            duration: Motion.medium,
            child: !converting
                ? const SizedBox.expand()
                : DecoratedBox(
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: ClipTile._radius),
                    child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        LogoProgress(
                          value: task.state == TaskState.running ? task.progress : null,
                          size: 40,
                          trackColor: Colors.white24,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          task.state == TaskState.running
                              ? '${((task.progress ?? 0) * 100).round()}%'
                              : task.state == TaskState.saving
                                  ? 'Saving'
                                  : 'Queued',
                          style: ClipTile._label.copyWith(fontSize: 11),
                        ),
                      ]),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

/// Fades its child out while the library is in selection mode.
class _HideWhileSelecting extends StatelessWidget {
  final Widget child;
  const _HideWhileSelecting({required this.child});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Selection.instance,
        builder: (context, child) => AnimatedOpacity(
          opacity: Selection.instance.active ? 0 : 1,
          duration: Motion.quick,
          child: child,
        ),
        child: child,
      );
}

/// Dims a selected tile and shows the tick circle while the library is in selection mode.
class _SelectionMark extends StatelessWidget {
  final Clip clip;
  const _SelectionMark({required this.clip});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: Selection.instance,
      builder: (context, _) {
        if (!Selection.instance.active) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: Selection.instance.flag(clip),
          builder: (context, on, _) => IgnorePointer(
            child: AnimatedContainer(
              duration: Motion.quick,
              decoration: BoxDecoration(
                color: on ? p.accent.withValues(alpha: 0.28) : Colors.transparent,
                borderRadius: ClipTile._radius,
              ),
              alignment: Alignment.topRight,
              padding: const EdgeInsets.all(7),
              child: AnimatedContainer(
                duration: Motion.quick,
                curve: Motion.spring,
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? p.accent : Colors.black.withValues(alpha: 0.28),
                  border: Border.all(color: Colors.white, width: on ? 0 : 1.8),
                ),
                child: AnimatedScale(
                  scale: on ? 1 : 0,
                  duration: Motion.quick,
                  curve: Motion.spring,
                  child: const Icon(AppIcons.checkmark, color: Colors.white, size: 15),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
