import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../engine.dart';
import '../library.dart';
import '../main.dart' show navigatorKey;
import '../theme.dart';
import '../toast.dart';
import '../ui/app_icons.dart';
import '../widgets.dart';

/// Videos moved to the system bin: restore them or delete them for good. Android empties the bin by itself
/// after 30 days.
class BinPage extends StatefulWidget {
  const BinPage({super.key});

  static void open([BuildContext? context]) {
    final nav = context != null ? Navigator.of(context) : navigatorKey.currentState;
    nav?.push(CupertinoPageRoute(builder: (_) => const BinPage()));
  }

  @override
  State<BinPage> createState() => _BinPageState();
}

class _BinPageState extends State<BinPage> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Library.instance.loadBin().whenComplete(() {
      if (mounted) setState(() => _loading = false);
    });
  }

  String _left(Clip c) {
    if (c.expires <= 0) return formatBytes(c.size);
    final days = ((c.expires - DateTime.now().millisecondsSinceEpoch) / Duration.millisecondsPerDay).ceil();
    final when = days <= 0 ? 'Deleting soon' : '$days day${days == 1 ? '' : 's'} left';
    return '$when · ${formatBytes(c.size)}';
  }

  Future<void> _restore(List<Clip> clips) async {
    final ok = await Library.instance.restore(clips);
    if (ok) {
      Toast.success('Restored', message: '${clips.length} video${clips.length == 1 ? '' : 's'} back in your library.');
    }
  }

  Future<void> _forever(List<Clip> clips, {bool all = false}) async {
    final n = clips.length;
    final sure = await showGlassConfirm(context,
        title: all ? 'Empty the Bin?' : 'Delete for good?',
        message: all
            ? 'All $n video${n == 1 ? '' : 's'} will be deleted for good. This can\'t be undone.'
            : 'This video will be deleted for good. This can\'t be undone.',
        confirmLabel: all ? 'Empty Bin' : 'Delete',
        destructive: true);
    if (!sure) return;
    final ok = await Library.instance.deleteForever(clips);
    if (ok) Toast.success('Deleted', message: '$n video${n == 1 ? '' : 's'} removed for good.');
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final lib = Library.instance;
    return Scaffold(
      backgroundColor: p.background,
      body: ListenableBuilder(
        listenable: lib,
        builder: (context, _) {
          final bin = lib.bin;
          return GlassPage(
            title: 'Bin',
            background: p.background,
            reportScroll: false,
            onRefresh: lib.loadBin,
            leading: GlassIconButton(
              icon: AppIcons.chevron_back,
              semanticLabel: 'Back',
              onTap: () => Navigator.of(context).maybePop(),
            ),
            slivers: [
              if (bin.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _loading
                      ? const Center(child: LogoSpinner(size: 48))
                      : const EmptyState(
                          icon: AppIcons.trash,
                          title: 'The Bin is empty',
                          message: 'Videos you delete stay here for 30 days before they\'re removed for good.',
                        ),
                )
              else ...[
                SliverToBoxAdapter(
                  child: GroupedSection(
                    footer: 'Videos are deleted for good 30 days after they were moved here.',
                    children: [
                      for (final c in bin)
                        Builder(
                          builder: (anchor) => GroupedRow(
                            leading: IconTile(AppIcons.film, p.secondaryLabel),
                            title: c.name,
                            subtitle: _left(c),
                            onTap: () => showGlassMenu(context, anchor: anchor, title: c.name, message: _left(c), actions: [
                              MenuAction('Restore', icon: AppIcons.arrow_counterclockwise, onTap: () => _restore([c])),
                              MenuAction('Delete for Good', icon: AppIcons.trash, destructive: true, onTap: () => _forever([c])),
                            ]),
                          ),
                        ),
                    ],
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Insets.card, 6, Insets.card, 0),
                    child: Column(children: [
                      GlassButton('Restore All', icon: AppIcons.arrow_counterclockwise, onTap: () => _restore(bin)),
                      const SizedBox(height: 10),
                      GlassButton('Empty Bin', icon: AppIcons.trash, color: p.red, onTap: () => _forever(bin, all: true)),
                    ]),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
