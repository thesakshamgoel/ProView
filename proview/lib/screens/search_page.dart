import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../library.dart';
import '../smart_search.dart';
import '../tags.dart';
import '../theme.dart';
import '../ui/app_icons.dart';
import '../ui/grid_pattern.dart';
import '../widgets.dart';
import 'clip_grid.dart';

/// Smart Search: type a phrase ("4K ProRes from last week") and see what was understood and what matched.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  static Route<void> route() => PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => const SearchPage(),
        transitionsBuilder: (_, anim, _, child) {
          final c = CurvedAnimation(parent: anim, curve: Motion.emphasized, reverseCurve: Curves.easeIn);
          return FadeTransition(
            opacity: c,
            child: SlideTransition(position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(c), child: child),
          );
        },
      );

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  SmartQuery _query = SmartQuery.parse('');

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _set(String text) {
    _controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    setState(() => _query = SmartQuery.parse(text));
  }

  List<Clip> _results(Library lib) {
    if (_query.isEmpty) return const [];
    return lib.all.where((c) {
      final info = lib.info(c);
      final copy = c.isProViewCopy;
      return _query.matches(c, info,
          isCopy: copy, hasCopy: lib.copyOf(c) != null, tags: SmartTags.instance.of(c), favorite: lib.isFavorite(c));
    }).toList()
      ..sort((a, b) => b.modified.compareTo(a.modified));
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      backgroundColor: p.background,
      body: Stack(children: [
        const Positioned.fill(child: GridPattern()),
        ListenableBuilder(
        listenable: Listenable.merge([Library.instance, SmartTags.instance]),
        builder: (context, _) {
          final lib = Library.instance;
          final results = _results(lib);
          final searching = !_query.isEmpty;
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => _focus.unfocus(),
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(Insets.card, top + 8, Insets.card, 6),
                    child: Row(children: [
                      GlassIconButton(
                          icon: AppIcons.chevron_back, semanticLabel: 'Back', onTap: () => Navigator.of(context).maybePop()),
                      const SizedBox(width: 10),
                      Expanded(child: _field(p)),
                    ]),
                  ),
                ),
                if (searching && _query.chips.isNotEmpty)
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 56,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(Insets.card, 8, Insets.card, 4),
                        itemCount: _query.chips.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (_, i) => _Chip(_query.chips[i], selected: true),
                      ),
                    ),
                  ),
                if (!searching)
                  SliverToBoxAdapter(child: _suggestions(p))
                else if (results.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: AppIcons.search,
                      title: 'Nothing found',
                      message: _query.needsTags && SmartTags.instance.pending > 0
                          ? 'Still looking through ${SmartTags.instance.pending} videos. Results will appear as it goes.'
                          : 'Try fewer words, or a phrase like “4K from this month”.',
                    ),
                  )
                else ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(Insets.page, 10, Insets.page, 10),
                      child: Text('${results.length} result${results.length == 1 ? '' : 's'}',
                          style: TextStyles.footnote(p).copyWith(fontWeight: FontWeight.w600)),
                    ),
                  ),
                  ClipGrid(clips: results),
                  SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 40)),
                ],
              ],
            ),
          );
        },
      ),
      ]),
    );
  }

  Widget _field(Palette p) {
    return LiquidGlass(
      tint: p.isDark ? const Color(0x99262628) : const Color(0xBFFFFFFF),
      blur: 18,
      child: SizedBox(
        height: 44,
        child: Row(children: [
          const SizedBox(width: 14),
          Icon(AppIcons.search, size: 18, color: p.secondaryLabel),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              textInputAction: TextInputAction.search,
              cursorColor: p.accent,
              style: TextStyles.body(p),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Search your videos',
                hintStyle: TextStyles.body(p).copyWith(color: p.tertiaryLabel),
              ),
              onChanged: (t) => setState(() => _query = SmartQuery.parse(t)),
            ),
          ),
          if (_controller.text.isNotEmpty)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.selectionClick();
                _set('');
              },
              child: SizedBox(width: 44, height: 44, child: Icon(AppIcons.xmark, size: 14, color: p.secondaryLabel)),
            )
          else
            const SizedBox(width: 14),
        ]),
      ),
    );
  }

  Widget _suggestions(Palette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.page, 22, Insets.page, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Ask in plain words', style: TextStyles.title3(p)),
        const SizedBox(height: 4),
        Text('Formats, sizes, lengths, dates, people and what\'s in the picture. Everything stays on your phone.',
            style: TextStyles.footnote(p)),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 10, children: [
          for (final e in searchExamples) _Chip(e, onTap: () => _set(e)),
        ]),
        ..._seen(p),
      ]),
    );
  }
}

extension on _SearchPageState {
  /// Suggestions drawn from what the phone found in the user's own videos.
  List<Widget> _seen(Palette p) {
    final tags = SmartTags.instance;
    final lib = Library.instance;
    final labels = tags.topLabels();
    return [
      const SizedBox(height: 26),
      if (!lib.settings.smartTags)
        Text('Turn on Smart Tags in Settings to search for people and things in your videos.', style: TextStyles.footnote(p))
      else if (tags.unavailable)
        Text('Searching for people and things isn\'t available on this phone. Names, formats and dates still work.',
            style: TextStyles.footnote(p))
      else ...[
        if (labels.isNotEmpty) ...[
          Text('Found in your videos', style: TextStyles.title3(p)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 10, children: [
            for (final l in labels) _Chip(l[0].toUpperCase() + l.substring(1), onTap: () => _set(l)),
          ]),
        ],
        if (tags.pending > 0) ...[
          const SizedBox(height: 14),
          Row(children: [
            const LogoSpinner(size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Looking through ${tags.pending} more video${tags.pending == 1 ? '' : 's'}…',
                  style: TextStyles.footnote(p)),
            ),
          ]),
        ],
      ],
    ];
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  const _Chip(this.label, {this.selected = false, this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Pressable(
      onTap: onTap,
      scale: 0.95,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: selected ? p.accent : p.fill,
          shape: const StadiumBorder(),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Text(label,
              style: TextStyles.subhead(p).copyWith(
                  fontWeight: FontWeight.w600, color: selected ? Colors.white : p.label)),
        ),
      ),
    );
  }
}
