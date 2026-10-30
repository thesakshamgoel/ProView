import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../clip_actions.dart';
import '../engine.dart';
import '../library.dart';
import '../selection.dart';
import '../theme.dart';
import '../toast.dart';
import '../ui/app_icons.dart';
import '../ui/drag_select.dart';
import '../widgets.dart';
import 'bin_page.dart';

/// Wraps a page of clip tiles with everything selection needs: drag-to-select, the "N Selected" bar on top
/// and the action bar (share, favourite, convert, bin) at the bottom.
class SelectionLayer extends StatefulWidget {
  final Widget child;

  /// Everything "Select All" should pick on this page.
  final List<Clip> Function() all;
  const SelectionLayer({super.key, required this.child, required this.all});

  @override
  State<SelectionLayer> createState() => _SelectionLayerState();
}

class _SelectionLayerState extends State<SelectionLayer> {
  @override
  void dispose() {
    // Leaving a page never leaves a selection behind.
    if (Selection.instance.active) Selection.instance.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sel = Selection.instance;
    return ListenableBuilder(
      listenable: sel,
      builder: (context, child) => PopScope(
        // Back closes selection first, then leaves the page.
        canPop: !sel.active,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) sel.clear();
        },
        child: child!,
      ),
      child: DragSelect(
        child: Stack(children: [
          widget.child,
          Positioned(left: 0, right: 0, top: 0, child: _TopBar(all: widget.all)),
          const Positioned(left: 0, right: 0, bottom: 0, child: _ActionBar()),
        ]),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final List<Clip> Function() all;
  const _TopBar({required this.all});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final sel = Selection.instance;
    return ListenableBuilder(
      listenable: sel,
      builder: (context, _) {
        final on = sel.active;
        final every = on && all().isNotEmpty && sel.count >= all().length;
        return IgnorePointer(
          ignoring: !on,
          child: AnimatedSlide(
            offset: on ? Offset.zero : const Offset(0, -1),
            duration: Motion.medium,
            curve: Motion.spring,
            child: AnimatedOpacity(
              opacity: on ? 1 : 0,
              duration: Motion.quick,
              child: Container(
                padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [p.background, p.background, p.background.withValues(alpha: 0)],
                    stops: const [0, 0.82, 1],
                  ),
                ),
                child: Row(children: [
                  _TextPill(every ? 'Deselect All' : 'Select All', onTap: () {
                    HapticFeedback.selectionClick();
                    every ? sel.clear(armed: true) : sel.selectAll(all());
                  }),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: Motion.quick,
                      child: Text(
                        sel.count == 0 ? 'Select Items' : '${sel.count} Selected',
                        key: ValueKey(sel.count),
                        textAlign: TextAlign.center,
                        style: TextStyles.headline(p),
                      ),
                    ),
                  ),
                  _TextPill('Done', bold: true, onTap: sel.clear),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TextPill extends StatelessWidget {
  final String label;
  final bool bold;
  final VoidCallback onTap;
  const _TextPill(this.label, {required this.onTap, this.bold = false});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Pressable(
      onTap: onTap,
      scale: 0.93,
      child: LiquidGlass(
        child: Container(
          height: 40,
          constraints: const BoxConstraints(minWidth: 78),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          child: Text(label,
              maxLines: 1,
              style: TextStyles.subhead(p).copyWith(color: p.accent, fontWeight: bold ? FontWeight.w700 : FontWeight.w600)),
        ),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar();

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final sel = Selection.instance;
    final lib = Library.instance;
    final bottom = math.max(MediaQuery.paddingOf(context).bottom, 12.0);
    return ListenableBuilder(
      listenable: Listenable.merge([sel, lib]),
      builder: (context, _) {
        final on = sel.active;
        final clips = sel.clips;
        final has = clips.isNotEmpty;
        final allFav = has && clips.every(lib.isFavorite);
        return IgnorePointer(
          ignoring: !on,
          child: AnimatedSlide(
            offset: on ? Offset.zero : const Offset(0, 1.4),
            duration: const Duration(milliseconds: 460),
            curve: Motion.spring,
            child: AnimatedOpacity(
              opacity: on ? 1 : 0,
              duration: Motion.quick,
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, bottom),
                child: Center(
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: LiquidGlass(
                      tint: p.isDark ? const Color(0xCC262628) : const Color(0xD9FFFFFF),
                      blur: 18,
                      child: SizedBox(
                        height: 64,
                        child: Row(children: [
                          _BarButton(AppIcons.share, 'Share', enabled: has, onTap: () => _share(clips)),
                          _BarButton(allFav ? AppIcons.heart_fill : AppIcons.heart, allFav ? 'Unfavorite' : 'Favorite',
                              enabled: has, onTap: () => _favorite(clips)),
                          _BarButton(AppIcons.wand_stars, 'Convert', enabled: has, onTap: () => _convert(context, clips)),
                          _BarButton(AppIcons.trash, 'Bin', enabled: has, color: p.red, onTap: () => _delete(context, clips)),
                          // Play, Info, Share to WhatsApp... for a single clip.
                          _BarButton(AppIcons.ellipsis, 'More', enabled: clips.length == 1, onTap: () {
                            final c = clips.first;
                            Selection.instance.clear();
                            ClipActions.showMenu(context, c);
                          }),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _share(List<Clip> clips) async {
    try {
      await Engine.call('shareMany', {
        'uris': clips.map((c) => c.uri).toList(),
        'title': 'Share ${clips.length} video${clips.length == 1 ? '' : 's'}',
      });
    } catch (e) {
      Toast.error('Couldn\'t share', message: '$e');
    }
  }

  void _favorite(List<Clip> clips) {
    final lib = Library.instance;
    final adding = !clips.every(lib.isFavorite);
    lib.toggleFavorites(clips);
    Selection.instance.clear();
    Toast.success(adding ? 'Added to Favorites' : 'Removed from Favorites',
        message: '${clips.length} video${clips.length == 1 ? '' : 's'}');
  }

  Future<void> _convert(BuildContext context, List<Clip> clips) async {
    final lib = Library.instance;
    var started = 0;
    for (final c in clips) {
      final info = lib.info(c);
      if (info == null || info.native || lib.copyOf(c) != null) continue;
      await ClipActions.startConversion(context, c, info, quiet: true);
      started++;
    }
    Selection.instance.clear();
    if (started == 0) {
      Toast.info('Nothing to convert', message: 'These videos already play on your phone.');
    } else {
      Toast.success('Converting $started video${started == 1 ? '' : 's'}',
          message: 'They run one after another. Follow along in Activity.');
    }
  }

  Future<void> _delete(BuildContext context, List<Clip> clips) async {
    final binnable = clips.where((c) => c.source == 'device').length;
    final n = clips.length;
    final what = n == 1 ? 'this video' : '$n videos';
    final message = binnable == n
        ? 'You can still get ${n == 1 ? 'it' : 'them'} back from the Bin for 30 days.'
        : binnable == 0
            ? 'It can\'t be undone: ${n == 1 ? 'this video isn\'t' : 'these videos aren\'t'} on the phone\'s own storage, so there is no Bin.'
            : '${n - binnable} of them are on a drive or another app and will be deleted for good. The rest go to the Bin.';
    final ok = await showGlassConfirm(context,
        title: binnable == 0 ? 'Delete $what?' : 'Move $what to the Bin?',
        message: message,
        confirmLabel: binnable == 0 ? 'Delete' : 'Move to Bin',
        destructive: true);
    if (!ok) return;
    final removed = await Library.instance.delete(clips);
    if (removed > 0) {
      Selection.instance.clear();
      Toast.success(binnable == 0 ? 'Deleted' : 'Moved to Bin',
          message: '$removed video${removed == 1 ? '' : 's'}',
          actionLabel: binnable == 0 ? null : 'View Bin',
          onAction: binnable == 0 ? null : () => BinPage.open());
    } else {
      Toast.info('Nothing was deleted', message: 'Your videos are untouched.');
    }
  }
}

class _BarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final Color? color;
  final VoidCallback onTap;
  const _BarButton(this.icon, this.label, {required this.onTap, this.enabled = true, this.color});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final c = color ?? p.label;
    return Expanded(
      child: Opacity(
        opacity: enabled ? 1 : 0.35,
        child: Pressable(
          onTap: enabled ? onTap : null,
          scale: 0.9,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 23, color: c),
            const SizedBox(height: 3),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(fontFamily: kFont, fontSize: 10.5, fontWeight: FontWeight.w600, color: c)),
          ]),
        ),
      ),
    );
  }
}
