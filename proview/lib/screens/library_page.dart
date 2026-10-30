import 'dart:math' as math;
import 'package:flutter/services.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../clip_actions.dart';
import '../engine.dart';
import '../library.dart';
import '../selection.dart';
import '../theme.dart';
import '../ui/pinch_resize.dart';
import '../widgets.dart';
import '../dates.dart';
import 'clip_grid.dart';
import 'search_page.dart';
import 'selection_layer.dart';
import '../ui/app_icons.dart';

enum LibraryFilter { all, pro, converted, favorites }

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  LibraryFilter _filter = LibraryFilter.all;
  final _pinching = ValueNotifier(false);

  List<Clip> _filtered(Library lib) {
    final all = lib.all;
    return switch (_filter) {
      LibraryFilter.all => all,
      LibraryFilter.pro => all.where((c) {
          final i = lib.info(c);
          return i != null && !i.native && !c.isProViewCopy;
        }).toList(),
      LibraryFilter.converted => all.where((c) => c.isProViewCopy).toList(),
      LibraryFilter.favorites => all.where(lib.isFavorite).toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final lib = Library.instance;
    return ListenableBuilder(
      listenable: lib,
      builder: (context, _) {
        final sort = lib.settings.sort;
        final clips = sortClips(_filtered(lib), sort, duration: (c) => lib.info(c)?.duration ?? c.durationMs / 1000);
        final sections = sort.byDate ? groupByDate(clips, DateTime.now()) : <(String, List<Clip>)>[('', clips)];
        final needs = lib.needsConversionCount;
        final bottomInset = math.max(MediaQuery.paddingOf(context).bottom, 12.0);
        final page = GlassPage(
          lockScroll: _pinching,
          scrollWrapper: (scroll) => PinchResize(
            value: lib.settings.tileExtent,
            min: 56,
            max: 340,
            pinching: _pinching,
            snap: (extent) => _snapExtent(context, extent),
            onCommit: (extent) {
              lib.settings.previewTileExtent(extent);
              lib.settings.set((_) {});
            },
            child: scroll,
          ),
          title: 'Library',
          background: p.background,
          onRefresh: lib.refresh,
          extraBottom: 62,
          actions: [
            GlassIconButton(
              icon: AppIcons.search,
              semanticLabel: 'Search',
              onTap: () => Navigator.of(context).push(SearchPage.route()),
            ),
            Builder(
              builder: (anchor) => GlassIconButton(
                icon: AppIcons.sort,
                semanticLabel: 'Sort',
                onTap: () => _sortMenu(context, anchor),
              ),
            ),
            GlassIconButton(
              icon: AppIcons.add,
              semanticLabel: 'Open a file',
              onTap: () => ClipActions.openFromPicker(context),
            ),
          ],
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Insets.card, 4, Insets.card, 14),
                child: AnimatedSize(
                  duration: Motion.medium,
                  curve: Motion.ease,
                  child: needs > 0 && _filter != LibraryFilter.converted
                      ? _ProBanner(count: needs, onTap: () => setState(() => _filter = LibraryFilter.pro))
                      : const SizedBox(width: double.infinity),
                ),
              ),
            ),
            if (clips.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: lib.scanning
                    ? Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const LogoSpinner(size: 56),
                          const SizedBox(height: 16),
                          Text('Finding your videos', style: TextStyles.subhead(p).copyWith(color: p.secondaryLabel)),
                        ]),
                      )
                    : _empty(context),
              )
            else ...[
              for (final (title, group) in sections) ...[
                if (title.isNotEmpty) SliverToBoxAdapter(child: _SectionHeader(title: title, count: group.length)),
                ClipGrid(clips: group, queue: clips),
              ],
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Insets.page, 22, Insets.page, 0),
                  child: Text('${clips.length} Video${clips.length == 1 ? '' : 's'}',
                      style: TextStyles.headline(p), textAlign: TextAlign.center),
                ),
              ),
            ],
          ],
        );
        // The filter floats in the thumb zone, just above the tab bar (beside it while the bar is tucked away).
        final stack = Stack(children: [
          page,
          ValueListenableBuilder<bool>(
            valueListenable: tabBarMinimized,
            builder: (context, minimized, _) => AnimatedPositioned(
              duration: const Duration(milliseconds: 460),
              curve: Motion.spring,
              left: minimized ? 92 : 20,
              right: 20,
              bottom: minimized ? bottomInset + 8 : bottomInset + 64 + 12,
              height: 46,
              // Out of the way while picking clips: the action bar takes this spot.
              child: ListenableBuilder(
                listenable: Selection.instance,
                builder: (context, child) => IgnorePointer(
                  ignoring: Selection.instance.active,
                  child: AnimatedOpacity(
                    opacity: Selection.instance.active ? 0 : 1,
                    duration: Motion.quick,
                    child: child,
                  ),
                ),
                child: LiquidGlass(
                tint: p.isDark ? const Color(0x99262628) : const Color(0xBFFFFFFF),
                blur: 18,
                grouped: true,
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: GlassSegmented<LibraryFilter>(
                  bare: true,
                  value: _filter,
                  onChanged: (f) => setState(() => _filter = f),
                  segments: const {
                    LibraryFilter.all: 'All',
                    LibraryFilter.pro: 'Pro',
                    LibraryFilter.converted: 'Converted',
                    LibraryFilter.favorites: 'Favorites',
                  },
                ),
              ),
              ),
            ),
          ),
        ]);
        return SelectionLayer(all: () => clips, child: stack);
      },
    );
  }

  /// The tile size that fills the width with a whole number of columns, nearest to [extent].
  double _snapExtent(BuildContext context, double extent) {
    final avail = MediaQuery.sizeOf(context).width - 24;
    const gap = 8.0;
    final cols = ((avail + gap) / (extent + gap)).round().clamp(2, 8);
    return (avail - gap * (cols - 1)) / cols;
  }

  void _sortMenu(BuildContext context, BuildContext anchor) {
    final s = Library.instance.settings;
    showGlassMenu(context, anchor: anchor, title: 'Sort By', actions: [
      for (final o in LibrarySort.values)
        MenuAction(o.label,
            icon: s.sort == o ? AppIcons.checkmark : null, onTap: () => s.set((s) => s.sort = o)),
    ]);
  }

  Widget _empty(BuildContext context) {
    return switch (_filter) {
      LibraryFilter.all => EmptyState(
          logo: true,
          title: 'No videos yet',
          message: 'Videos on this phone show up here automatically. Add a USB drive in Folders, or open a file '
              'from Google Drive.',
          action: GlassButton('Open a File',
              icon: AppIcons.folder, prominent: true, expand: false, onTap: () => ClipActions.openFromPicker(context)),
        ),
      LibraryFilter.pro => const EmptyState(
          icon: AppIcons.film,
          title: 'No pro-format clips',
          message: 'Clips your phone can\'t play on its own, like ProRes or HEVC 4:2:2, appear here.',
        ),
      LibraryFilter.favorites => const EmptyState(
          icon: AppIcons.heart,
          title: 'No favorites yet',
          message: 'Touch and hold a video, tick it, then tap Favorite. Hearted videos collect here.',
        ),
      LibraryFilter.converted => const EmptyState(
          icon: AppIcons.wand_stars,
          title: 'Nothing converted yet',
          message: 'Phone-playable copies you make are saved to Gallery › ProView and listed here.',
        ),
    };
  }
}

class _ProBanner extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _ProBanner({required this.count, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Pressable(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: ShapeDecoration(
          color: p.surface,
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(Insets.radius)),
        ),
        child: Row(children: [
          Container(
            width: 48,
            height: 48,
            padding: const EdgeInsets.all(6),
            decoration: ShapeDecoration(
              color: p.isDark ? const Color(0xFF2C2C2E) : Colors.white,
              shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: const ProViewLogo(size: 36),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$count clip${count == 1 ? '' : 's'} need${count == 1 ? 's' : ''} ProView',
                  style: TextStyles.headline(p)),
              const SizedBox(height: 2),
              Text('Your phone can\'t play ${count == 1 ? 'it' : 'these'} on its own. ProView can.',
                  style: TextStyles.footnote(p)),
            ]),
          ),
          Icon(AppIcons.chevron_forward, size: 16, color: p.tertiaryLabel),
        ]),
      ),
    );
  }
}

/// "Today", "Yesterday", "October"... above each group of clips.
class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  const _SectionHeader({required this.title, required this.count});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.page, 18, Insets.page, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text(title, style: TextStyles.title3(p)),
        const SizedBox(width: 8),
        Text('$count', style: TextStyles.footnote(p).copyWith(fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
