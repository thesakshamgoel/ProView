import 'package:flutter/cupertino.dart';

import '../clip_actions.dart';
import '../engine.dart';
import '../library.dart';
import '../tasks.dart';
import '../theme.dart';
import '../toast.dart';
import '../widgets.dart';
import '../ui/app_icons.dart';

class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    final center = TaskCenter.instance;
    return ListenableBuilder(
      listenable: center,
      builder: (context, _) {
        final tasks = center.all;
        final hasFinished = tasks.any((t) => !t.active);
        return GlassPage(
          title: 'Activity',
          actions: [
            if (center.all.where((t) => t.active && t.type == 'convert').length > 1)
              GlassButton('Stop All', height: 44, expand: false, color: Palette.of(context).red,
                  onTap: ClipActions.cancelAllConversions),
            AnimatedScale(
              scale: hasFinished ? 1 : 0,
              duration: Motion.medium,
              curve: Motion.spring,
              child: GlassButton('Clear', height: 44, expand: false, onTap: hasFinished ? center.clearFinished : null),
            ),
          ],
          slivers: [
            if (tasks.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: AppIcons.checkmark_circle,
                  title: 'Nothing running',
                  message: 'Conversions, downloads and library scans show up here with live progress.',
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(Insets.card, 6, Insets.card, 0),
                sliver: SliverList.separated(
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: Insets.gap),
                  itemBuilder: (context, i) => _TaskCard(key: ValueKey(tasks[i].id), task: tasks[i]),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _TaskCard extends StatelessWidget {
  final BgTask task;
  const _TaskCard({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final t = task;
    final (IconData icon, Color color) = switch (t.type) {
      'convert' => (AppIcons.wand_stars, p.purple),
      'download' => (AppIcons.cloud_download, const Color(0xFF34AADC)),
      'scan' => (AppIcons.search, const Color(0xFF8E8E93)),
      _ => (AppIcons.photo_on_rectangle, p.orange),
    };
    final (String stateLabel, Color stateColor) = switch (t.state) {
      TaskState.queued => ('Waiting', p.secondaryLabel),
      TaskState.running => (t.type == 'convert' ? 'Converting' : 'Working', p.accent),
      TaskState.saving => ('Saving', p.accent),
      TaskState.done => ('Done', p.green),
      TaskState.failed => ('Failed', p.red),
      TaskState.cancelled => ('Cancelled', p.secondaryLabel),
    };

    return Container(
      padding: const EdgeInsets.all(Insets.card),
      decoration: ShapeDecoration(
        color: p.surface,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(Insets.radius)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (t.type == 'convert' && t.active)
            SizedBox.square(
              dimension: 40,
              child: LogoProgress(value: t.state == TaskState.running ? t.progress : null, size: 40),
            )
          else
            IconTile(icon, color, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title, style: TextStyles.headline(p), maxLines: 2, overflow: TextOverflow.fade),
              const SizedBox(height: 2),
              Text(
                t.state == TaskState.failed ? (t.error ?? t.detail) : t.detail,
                style: TextStyles.footnote(p).copyWith(color: t.state == TaskState.failed ? p.red : p.secondaryLabel),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          AnimatedSwitcher(
            duration: Motion.quick,
            child: Container(
              key: ValueKey(stateLabel),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: ShapeDecoration(color: stateColor.withValues(alpha: 0.14), shape: const StadiumBorder()),
              child: Text(stateLabel,
                  style: TextStyles.caption(p).copyWith(color: stateColor, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
        if (t.active) ...[
          const SizedBox(height: 14),
          ThinProgress(value: t.state == TaskState.running ? t.progress : null),
        ],
        if (t.type == 'convert' && t.encoder != null && t.active) ...[
          const SizedBox(height: 8),
          Text(
            'Encoding ${t.bitDepth}-bit HEVC${t.encoder!.contains('@') ? ' at ${t.encoder!.split('@').last.replaceAll('x', ' × ')}' : ''}',
            style: TextStyles.caption(p),
          ),
        ],
        if (t.type == 'convert') _actions(context, p),
        if (t.type != 'convert' && !t.active)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(children: [
              const Spacer(),
              GlassButton('Dismiss', height: 38, expand: false, color: p.secondaryLabel,
                  onTap: () => TaskCenter.instance.dismiss(t.id)),
            ]),
          ),
      ]),
    );
  }

  Widget _actions(BuildContext context, Palette p) {
    final t = task;
    final buttons = <Widget>[];
    void add(String label, VoidCallback onTap, {Color? color, bool filled = false}) {
      buttons.add(Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: GlassButton(label, height: 42, prominent: filled, color: color, onTap: onTap),
        ),
      ));
    }

    switch (t.state) {
      case TaskState.queued:
      case TaskState.running:
        add('Cancel', () => ClipActions.cancelConversion(t), color: p.red);
      case TaskState.saving:
        break;
      case TaskState.done:
        add('Play', () => _playOutput(context), filled: true);
        add('Share', () => _shareOutput(context));
        add('Dismiss', () => TaskCenter.instance.dismiss(t.id), color: p.secondaryLabel);
      case TaskState.failed:
      case TaskState.cancelled:
        add('Try Again', () => _retry(context));
        add('Dismiss', () => TaskCenter.instance.dismiss(t.id), color: p.secondaryLabel);
    }
    if (buttons.isEmpty) return const SizedBox();
    return Padding(padding: const EdgeInsets.only(top: 12), child: Row(children: buttons));
  }

  Future<Clip?> _output() async {
    final uri = task.outputUri;
    if (uri == null) return null;
    final lib = Library.instance;
    return lib.byUri(uri) ?? await lib.addDocument(uri);
  }

  Future<void> _playOutput(BuildContext context) async {
    final clip = await _output();
    if (clip == null || !context.mounted) {
      Toast.error('Couldn\'t find the converted file', message: 'It may have been deleted from Gallery.');
      return;
    }
    ClipActions.open(context, clip);
  }

  Future<void> _shareOutput(BuildContext context) async {
    final clip = await _output();
    if (clip != null) ClipActions.share(clip);
  }

  Future<void> _retry(BuildContext context) async {
    final uri = task.sourceUri;
    final clip = uri == null ? null : Library.instance.byUri(uri);
    if (clip == null) {
      Toast.error('The original file isn\'t available', message: 'It may have been moved or the drive unplugged.');
      return;
    }
    try {
      final info = await Library.instance.analyzeNow(clip);
      TaskCenter.instance.dismiss(task.id);
      if (context.mounted) await ClipActions.startConversion(context, clip, info);
    } catch (e) {
      Toast.error('Couldn\'t read the original', message: e.toString());
    }
  }
}
