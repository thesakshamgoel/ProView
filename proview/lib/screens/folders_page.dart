import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../clip_actions.dart';
import '../engine.dart';
import '../library.dart';
import '../theme.dart';
import '../toast.dart';
import '../widgets.dart';
import 'bin_page.dart';
import 'clip_grid.dart';
import 'selection_layer.dart';
import '../ui/app_icons.dart';

class FoldersPage extends StatelessWidget {
  const FoldersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final lib = Library.instance;
    return ListenableBuilder(
      listenable: lib,
      builder: (context, _) {
        final phone = lib.deviceFolders;
        return GlassPage(
          title: 'Folders',
          onRefresh: lib.refresh,
          actions: [
            GlassIconButton(
              icon: AppIcons.folder_badge_plus,
              semanticLabel: 'Add a drive or folder',
              onTap: () => _addFolder(),
            ),
          ],
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 6)),
            SliverToBoxAdapter(
              child: GroupedSection(
                header: 'Drives & Folders',
                footer: 'Plug in a USB-C SSD or insert an SD card, then add it here. ProView remembers it.',
                children: [
                  for (final f in lib.folders)
                    _FolderRow(
                      title: f.name,
                      clips: lib.treeClips(f.uri),
                      icon: AppIcons.archivebox_fill,
                      color: p.orange,
                      onTap: () => _openFolder(context, f.name, () => lib.treeClips(f.uri)),
                      onLongPress: (anchor) => _confirmRemove(context, anchor, f),
                    ),
                  GroupedRow(
                    leading: IconTile(AppIcons.plus, p.accent),
                    title: 'Add Drive or Folder',
                    titleColor: p.accent,
                    onTap: _addFolder,
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: GroupedSection(
                header: 'Cloud & Other Apps',
                footer: 'Google Drive, OneDrive and Dropbox open with the accounts already on your phone. For iCloud, '
                    'download the video from icloud.com or share it to ProView.',
                children: [
                  GroupedRow(
                    leading: IconTile(AppIcons.cloud_fill, p.teal),
                    title: 'Open from Drive or Files',
                    titleColor: p.accent,
                    onTap: () => ClipActions.openFromPicker(context),
                  ),
                  if (lib.documents.isNotEmpty)
                    _FolderRow(
                      title: 'Recently Opened',
                      clips: lib.documents,
                      icon: AppIcons.clock_fill,
                      color: p.purple,
                      onTap: () => _openFolder(context, 'Recently Opened', () => lib.documents),
                    ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: GroupedSection(
                header: 'Library',
                children: [
                  GroupedRow(
                    leading: IconTile(AppIcons.heart_fill, p.red),
                    title: 'Favorites',
                    value: '${lib.all.where(lib.isFavorite).length}',
                    chevron: true,
                    onTap: () => _openFolder(context, 'Favorites', () => lib.all.where(lib.isFavorite).toList()),
                  ),
                  GroupedRow(
                    leading: IconTile(AppIcons.trash_fill, p.secondaryLabel),
                    title: 'Bin',
                    subtitle: 'Deleted videos stay for 30 days',
                    chevron: true,
                    onTap: () => BinPage.open(context),
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: GroupedSection(
                header: 'On This Phone',
                children: phone.isEmpty
                    ? [
                        GroupedRow(
                          leading: IconTile(AppIcons.lock_fill, p.secondaryLabel),
                          title: lib.permission == 'denied' ? 'Allow Access to Videos' : 'No videos on this phone',
                          titleColor: lib.permission == 'denied' ? p.accent : p.secondaryLabel,
                          onTap: lib.permission == 'denied' ? () => lib.requestPermission() : null,
                        ),
                      ]
                    : [
                        for (final e in phone.entries)
                          _FolderRow(
                            title: e.key,
                            clips: e.value,
                            onTap: () => _openFolder(context, e.key, () => lib.deviceFolders[e.key] ?? const []),
                          ),
                      ],
              ),
            ),
          ],
        );
      },
    );
  }

  static Future<void> _addFolder() async {
    final lib = Library.instance;
    final f = await lib.addFolder();
    if (f != null) {
      final n = lib.treeClips(f.uri).length;
      Toast.success('${f.name} added', message: '$n video${n == 1 ? '' : 's'} found');
    }
  }

  void _openFolder(BuildContext context, String title, List<Clip> Function() clips) {
    Navigator.of(context).push(CupertinoPageRoute(builder: (_) => FolderGridPage(title: title, clips: clips)));
  }

  void _confirmRemove(BuildContext context, BuildContext anchor, PickedFolder f) {
    showGlassMenu(context,
        anchor: anchor,
        title: f.name,
        message: 'ProView will stop showing videos from here. Nothing is deleted.',
        actions: [
          MenuAction('Remove from ProView', icon: AppIcons.minus_circle, destructive: true, onTap: () {
            Library.instance.removeFolder(f);
            Toast.success('Removed ${f.name}');
          }),
        ]);
  }
}

class _FolderRow extends StatelessWidget {
  final String title;
  final List<Clip> clips;
  final IconData? icon;
  final Color? color;
  final VoidCallback onTap;
  final void Function(BuildContext anchor)? onLongPress;
  const _FolderRow({
    required this.title,
    required this.clips,
    required this.onTap,
    this.icon,
    this.color,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final lib = Library.instance;
    final first = clips.isEmpty ? null : clips.first;
    if (first != null) lib.ensureProcessed(first);
    return Builder(builder: (anchor) {
      return GroupedRow(
        leading: ClipRSuperellipse(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox.square(
            dimension: 46,
            child: first == null
                ? _placeholder(p)
                : ListenableBuilder(
                    listenable: lib.clipListenable(first),
                    builder: (context, _) {
                      final cover = lib.thumb(first);
                      return cover != null
                          ? Image.file(File(cover), fit: BoxFit.cover, cacheWidth: 138, gaplessPlayback: true)
                          : _placeholder(p);
                    },
                  ),
          ),
        ),
        title: title,
        subtitle: '${clips.length} video${clips.length == 1 ? '' : 's'}',
        chevron: true,
        onTap: onTap,
        onLongPress: onLongPress == null ? null : () => onLongPress!(anchor),
      );
    });
  }

  Widget _placeholder(Palette p) => ColoredBox(
        color: color ?? p.fill,
        child: Icon(icon ?? AppIcons.folder_fill, color: color != null ? Colors.white : p.tertiaryLabel, size: 22),
      );
}

class FolderGridPage extends StatelessWidget {
  final String title;
  final List<Clip> Function() clips;
  const FolderGridPage({super.key, required this.title, required this.clips});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.background,
      body: ListenableBuilder(
        listenable: Library.instance,
        builder: (context, _) {
          final list = clips();
          return SelectionLayer(
            all: () => list,
            child: GlassPage(
            title: title,
            background: p.background,
            reportScroll: false,
            onRefresh: Library.instance.refresh,
            leading: GlassIconButton(
              icon: AppIcons.chevron_back,
              semanticLabel: 'Back',
              onTap: () => Navigator.of(context).maybePop(),
            ),
            slivers: [
              if (list.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: AppIcons.folder,
                    title: 'No videos here',
                    message: 'If this is a drive, check it\'s plugged in, then pull down to refresh.',
                  ),
                )
              else ...[
                ClipGrid(clips: list),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('${list.length} Video${list.length == 1 ? '' : 's'}',
                        style: TextStyles.headline(p), textAlign: TextAlign.center),
                  ),
                ),
              ],
            ],
          ),
          );
        },
      ),
    );
  }
}
