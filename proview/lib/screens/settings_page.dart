import 'package:flutter/cupertino.dart';

import '../clip_actions.dart';
import '../engine.dart';
import '../library.dart';
import '../tags.dart';
import '../theme.dart';
import '../toast.dart';
import '../widgets.dart';
import '../ui/app_icons.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = Library.instance.settings;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => GlassPage(
        title: 'Settings',
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 6)),
          SliverToBoxAdapter(
            child: GroupedSection(
              header: 'Copy Quality',
              footer: 'How sharp and how large a phone-playable copy is.',
              children: [
                for (final q in Quality.values)
                  GroupedRow(
                    title: switch (q) {
                      Quality.balanced => 'Balanced',
                      Quality.high => 'High',
                      Quality.maximum => 'Maximum',
                    },
                    subtitle: switch (q) {
                      Quality.balanced => 'Smaller files · ~50 Mbps for 4K60',
                      Quality.high => 'Recommended · ~100 Mbps for 4K60',
                      Quality.maximum => 'Largest files · ~150 Mbps for 4K60',
                    },
                    trailing: AnimatedScale(
                      scale: s.quality == q ? 1 : 0,
                      duration: Motion.quick,
                      curve: Motion.spring,
                      child: Icon(AppIcons.checkmark_alt, color: p.accent, size: 22),
                    ),
                    onTap: () => s.set((s) => s.quality = q),
                  ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: GroupedSection(
              header: 'Slow Clips',
              footer: 'Some pro clips are too heavy for any phone to play live. ProView can make a smooth copy in '
                  'the background; your original is never changed.',
              children: [
                for (final m in SlowMode.values)
                  GroupedRow(
                    title: m.title,
                    subtitle: m.detail,
                    trailing: AnimatedScale(
                      scale: s.slowMode == m ? 1 : 0,
                      duration: Motion.quick,
                      curve: Motion.spring,
                      child: Icon(AppIcons.checkmark, color: p.accent, size: 22),
                    ),
                    onTap: () => s.set((s) => s.setSlowMode(m)),
                  ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: GroupedSection(
              header: 'Playback',
              footer: 'ProView draws video on the GPU in 10-bit. Smooth Gradients adds fine dithering on screens or '
                  'paths that can only show 8-bit, so skies and glows stay free of banding.',
              children: [
                GroupedRow(
                  title: 'Smooth Gradients',
                  trailing: LiquidSwitch(
                    value: s.deband,
                    onChanged: (v) => s.set((s) => s.deband = v),
                  ),
                ),
                GroupedRow(
                  title: 'Prefer Phone-Playable Copies',
                  trailing: LiquidSwitch(
                    value: s.preferCopy,
                    onChanged: (v) => s.set((s) => s.preferCopy = v),
                  ),
                ),
                GroupedRow(
                  title: 'Loop Videos',
                  trailing: LiquidSwitch(
                    value: s.loop,
                    onChanged: (v) => s.set((s) => s.loop = v),
                  ),
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: ListenableBuilder(
              listenable: SmartTags.instance,
              builder: (context, _) => GroupedSection(
                header: 'Smart Search',
                footer: s.smartTags && SmartTags.instance.unavailable
                    ? 'Image search couldn\'t start on this phone, so Smart Search uses names, formats and dates only.'
                    : s.smartTags
                    ? 'ProView looks at one picture from each video, on this phone only, so you can search for people, '
                        'places, things and written words. ${SmartTags.instance.pending > 0 ? 'Still going through ${SmartTags.instance.pending} videos.' : '${SmartTags.instance.tagged} videos understood.'}'
                    : 'Switch on to search your videos for people, places, things and written words. Nothing leaves your phone.',
                children: [
                  GroupedRow(
                    leading: IconTile(AppIcons.wand_stars, p.purple),
                    title: 'Smart Tags',
                    trailing: LiquidSwitch(
                      value: s.smartTags,
                      onChanged: (v) {
                        s.set((s) => s.smartTags = v);
                        if (v) {
                          SmartTags.instance.retry();
                          Toast.success('Smart Tags on', message: 'Progress shows in Activity.');
                        } else {
                          SmartTags.instance.clear();
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: GroupedSection(header: 'Storage', children: [
              GroupedRow(
                title: 'Rebuild Thumbnails',
                titleColor: p.accent,
                onTap: () {
                  Library.instance.clearThumbnails();
                  Toast.success('Rebuilding thumbnails', message: 'Progress is shown in Activity.');
                },
              ),
              GroupedRow(
                title: 'Rescan Library',
                titleColor: p.accent,
                onTap: () async {
                  await Library.instance.refresh();
                  Toast.success('Library updated', message: '${Library.instance.all.length} videos');
                },
              ),
            ]),
          ),
          SliverToBoxAdapter(child: _DeviceSection()),
          SliverToBoxAdapter(
            child: GroupedSection(
              header: 'About',
              footer: 'Plays ProRes (Proxy to 4444 XQ), HEVC including 4:2:2 10-bit, H.264, DNxHD/DNxHR, CineForm '
                  'and VP9 in MOV, MP4, MKV and MXF files. No ads, no tracking.',
              children: [
                GroupedRow(
                  leading: const ProViewLogo(size: 30),
                  title: 'ProView',
                  value: 'Version 1.4.4',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: ClipActions.deviceInfo(),
      builder: (context, snap) {
        final d = snap.data;
        if (d == null) return const SizedBox();
        return GroupedSection(header: 'This Phone', children: [
          GroupedRow(title: 'Model', value: '${d['manufacturer']} ${d['model']}'.trim()),
          GroupedRow(title: 'Android', value: '${d['android']}'),
          GroupedRow(title: 'GPU video output', value: d['gpuDecode'] == true ? 'Vulkan · 10-bit' : 'Standard'),
          GroupedRow(title: 'Screen refresh', value: '${_refreshHz().round()} Hz'),
          GroupedRow(title: 'CPU cores', value: '${d['cores']}'),
          GroupedRow(title: '10-bit HEVC encoder', value: d['tenBitEncoder'] == true ? 'Yes' : 'No (8-bit copies)'),
          GroupedRow(title: 'Max encoder bitrate', value: formatBitrate((d['maxBitrate'] as num).toInt())),
          GroupedRow(title: 'Free space', value: formatBytes((d['freeBytes'] as num).toInt())),
        ]);
      },
    );
  }
}

/// What the screen is running at right now (60 Hz while Power saving holds it down, up to 120 Hz otherwise).
double _refreshHz() {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  return views.isEmpty ? 60 : views.first.display.refreshRate;
}
