import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../selection.dart';
import '../tasks.dart';
import '../theme.dart';
import '../widgets.dart';
import 'activity_page.dart';
import 'folders_page.dart';
import 'library_page.dart';
import 'settings_page.dart';
import '../ui/app_icons.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  static final selectedTab = ValueNotifier(0);
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final PageController _pages = PageController(initialPage: HomeShell.selectedTab.value);

  @override
  void initState() {
    super.initState();
    HomeShell.selectedTab.addListener(_goToSelected);
  }

  @override
  void dispose() {
    HomeShell.selectedTab.removeListener(_goToSelected);
    _pages.dispose();
    super.dispose();
  }

  void _goToSelected() {
    final i = HomeShell.selectedTab.value;
    if (_pages.hasClients && (_pages.page ?? i.toDouble()).round() != i) {
      _pages.animateToPage(i, duration: const Duration(milliseconds: 420), curve: Motion.emphasized);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (p.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
      child: ValueListenableBuilder<int>(
        valueListenable: HomeShell.selectedTab,
        builder: (context, tab, _) => PopScope(
          canPop: tab == 0,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) HomeShell.selectedTab.value = 0;
          },
          child: Scaffold(
            backgroundColor: p.groupedBackground,
            // One shared backdrop read for the tab bar and the filter strip, instead of one each.
            body: BackdropGroup(child: Stack(children: [
              // Swipe left and right to move between tabs; pages stay alive so scroll positions are kept.
              ListenableBuilder(
                listenable: Selection.instance,
                builder: (context, child) => PageView(
                controller: _pages,
                physics: Selection.instance.active ? const NeverScrollableScrollPhysics() : const BouncingScrollPhysics(),
                onPageChanged: (i) {
                  tabBarMinimized.value = false;
                  HomeShell.selectedTab.value = i;
                },
                children: [
                  _TabPage(index: 0, pages: _pages, child: const LibraryPage()),
                  _TabPage(index: 1, pages: _pages, child: const FoldersPage()),
                  _TabPage(index: 2, pages: _pages, child: const ActivityPage()),
                  _TabPage(index: 3, pages: _pages, child: const SettingsPage()),
                ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                // Slides down while clips are being selected: the action bar takes its place.
                child: ListenableBuilder(
                  listenable: Selection.instance,
                  builder: (context, child) => IgnorePointer(
                    ignoring: Selection.instance.active,
                    child: AnimatedSlide(
                      offset: Selection.instance.active ? const Offset(0, 1.4) : Offset.zero,
                      duration: const Duration(milliseconds: 460),
                      curve: Motion.spring,
                      child: AnimatedOpacity(
                        opacity: Selection.instance.active ? 0 : 1,
                        duration: Motion.quick,
                        child: child,
                      ),
                    ),
                  ),
                  child: LiquidTabBar(
                    index: tab,
                    pages: _pages,
                    onTap: (i) {
                      tabBarMinimized.value = false;
                      HomeShell.selectedTab.value = i;
                    },
                  ),
                ),
              ),
            ])),
          ),
        ),
      ),
    );
  }
}

/// A tab's page: kept alive so scroll positions survive, but its animations (spinners, progress rings) only run
/// while it is on screen. A running animation anywhere makes the phone redraw every frame, even if nothing visible
/// changes.
class _TabPage extends StatefulWidget {
  final int index;
  final PageController pages;
  final Widget child;
  const _TabPage({required this.index, required this.pages, required this.child});
  @override
  State<_TabPage> createState() => _TabPageState();
}

class _TabPageState extends State<_TabPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AnimatedBuilder(
      animation: widget.pages,
      child: widget.child,
      builder: (context, child) {
        var page = HomeShell.selectedTab.value.toDouble();
        final c = widget.pages;
        if (c.hasClients && c.position.haveDimensions) page = c.page ?? page;
        return TickerMode(enabled: (page - widget.index).abs() < 1.0, child: child!);
      },
    );
  }
}

/// Floating Liquid Glass tab bar with a sliding lens; tucks into a small pill while scrolling down.
class LiquidTabBar extends StatefulWidget {
  final int index;
  final ValueChanged<int> onTap;

  /// The tab pages: the lens follows the finger while the user swipes between them.
  final PageController? pages;
  const LiquidTabBar({super.key, required this.index, required this.onTap, this.pages});

  static const items = [
    (AppIcons.play_rectangle, AppIcons.play_rectangle_fill, 'Library'),
    (AppIcons.folder, AppIcons.folder_fill, 'Folders'),
    (AppIcons.clock, AppIcons.clock_fill, 'Activity'),
    (AppIcons.gear, AppIcons.gear_solid, 'Settings'),
  ];

  @override
  State<LiquidTabBar> createState() => _LiquidTabBarState();
}

class _LiquidTabBarState extends State<LiquidTabBar> with SingleTickerProviderStateMixin {
  // Lens position in tab units; animated with a spring, or following the finger while dragging.
  late final _lens = AnimationController.unbounded(vsync: this, value: widget.index.toDouble());
  double? _drag;

  @override
  void initState() {
    super.initState();
    widget.pages?.addListener(_followPages);
  }

  void _followPages() {
    final c = widget.pages;
    if (_drag != null || c == null || !c.hasClients) return;
    final page = c.page;
    if (page != null) _lens.value = page;
  }

  @override
  void didUpdateWidget(LiquidTabBar old) {
    super.didUpdateWidget(old);
    // With a page controller the lens already follows the pages (tab taps animate them).
    if (widget.pages == null && old.index != widget.index && _drag == null) _moveTo(widget.index);
  }

  void _moveTo(int i) {
    _lens.animateWith(SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 420, damping: 30),
      _lens.value,
      i.toDouble(),
      _lens.velocity,
    ));
  }

  @override
  void dispose() {
    widget.pages?.removeListener(_followPages);
    _lens.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final bottom = math.max(MediaQuery.paddingOf(context).bottom, 12.0);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, bottom),
      child: ValueListenableBuilder<bool>(
        valueListenable: tabBarMinimized,
        builder: (context, minimized, _) {
          return LayoutBuilder(builder: (context, box) {
            final fullWidth = math.min(box.maxWidth, 440.0);
            const compact = 62.0;
            return Align(
              alignment: minimized ? Alignment.centerLeft : Alignment.center,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 460),
                curve: Motion.spring,
                width: minimized ? compact : fullWidth,
                height: minimized ? 54 : 64,
                child: LiquidGlass(
                  tint: p.isDark ? const Color(0x99262628) : const Color(0xBFFFFFFF),
                  blur: 18,
                  grouped: true,
                  child: minimized ? _compact(p) : _full(p, fullWidth),
                ),
              ),
            );
          });
        },
      ),
    );
  }

  Widget _compact(Palette p) {
    final item = LiquidTabBar.items[widget.index];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        tabBarMinimized.value = false;
      },
      child: Center(child: _icon(widget.index, item.$2, p.accent)),
    );
  }

  Widget _full(Palette p, double width) {
    const pad = 4.0;
    final n = LiquidTabBar.items.length;
    final slot = (width - pad * 2) / n;
    int nearest(double x) => ((x - pad) / slot).floor().clamp(0, n - 1);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        final i = nearest(d.localPosition.dx);
        if (i != widget.index) HapticFeedback.selectionClick();
        widget.onTap(i);
      },
      onHorizontalDragStart: (d) => setState(() => _drag = _lens.value),
      onHorizontalDragUpdate: (d) {
        _drag = ((_drag ?? _lens.value) + d.delta.dx / slot).clamp(0.0, n - 1.0);
        final before = _lens.value.round();
        _lens.value = _drag!;
        if (_lens.value.round() != before) HapticFeedback.selectionClick();
      },
      onHorizontalDragEnd: (d) {
        final i = _lens.value.round().clamp(0, n - 1);
        setState(() => _drag = null);
        _moveTo(i);
        widget.onTap(i);
      },
      onHorizontalDragCancel: () => setState(() => _drag = null),
      child: Stack(children: [
        AnimatedBuilder(
          animation: _lens,
          builder: (context, _) {
            final x = _lens.value;
            // Stretch while moving, like a drop of liquid; swell while held.
            final travel = (x - x.round()).abs() * 2;
            final stretch = 1 + 0.22 * travel + (_drag != null ? 0.08 : 0);
            final w = slot * stretch;
            return Positioned(
              left: pad + x * slot - (w - slot) / 2,
              top: pad,
              bottom: pad,
              width: w,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: p.isDark ? Colors.white.withValues(alpha: 0.14) : Colors.black.withValues(alpha: 0.065),
                  shape: const StadiumBorder(),
                ),
              ),
            );
          },
        ),
        Row(children: [
          const SizedBox(width: pad),
          for (var i = 0; i < n; i++)
            SizedBox(
              width: slot,
              child: AnimatedBuilder(
                animation: _lens,
                builder: (context, _) {
                  final selected = (1 - (_lens.value - i).abs()).clamp(0.0, 1.0);
                  final color = Color.lerp(p.label, p.accent, selected)!;
                  final item = LiquidTabBar.items[i];
                  return Transform.scale(
                    scale: 1 + 0.06 * selected,
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      _icon(i, selected > 0.5 ? item.$2 : item.$1, color),
                      const SizedBox(height: 3),
                      Text(item.$3,
                          style: TextStyle(
                            fontFamily: kFont,
                            fontSize: 10.5,
                            letterSpacing: -0.1,
                            fontWeight: FontWeight.w600,
                            color: color,
                          )),
                    ]),
                  );
                },
              ),
            ),
        ]),
      ]),
    );
  }

  Widget _icon(int i, IconData icon, Color color) {
    final w = Icon(icon, size: 24, color: color);
    return i == 2 ? ActivityBadge(child: w) : w;
  }
}

/// Small count badge on the Activity tab while conversions or downloads run.
class ActivityBadge extends StatelessWidget {
  final Widget child;
  const ActivityBadge({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: TaskCenter.instance,
      builder: (context, _) {
        final n = TaskCenter.instance.all.where((t) => t.active && (t.type == 'convert' || t.type == 'download')).length;
        return Stack(clipBehavior: Clip.none, children: [
          child,
          Positioned(
            right: -9,
            top: -5,
            child: AnimatedScale(
              scale: n > 0 ? 1 : 0,
              duration: const Duration(milliseconds: 320),
              curve: Motion.spring,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: ShapeDecoration(color: Palette.of(context).red, shape: const StadiumBorder()),
                constraints: const BoxConstraints(minWidth: 18),
                child: Text('$n',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontFamily: kFont, color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ]);
      },
    );
  }
}
