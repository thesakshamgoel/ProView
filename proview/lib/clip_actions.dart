import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'engine.dart';
import 'library.dart';
import 'screens/player_page.dart';
import 'tasks.dart';
import 'theme.dart';
import 'toast.dart';
import 'widgets.dart';
import 'ui/app_icons.dart';

/// Opening, converting and sharing clips. Every path ends in a visible success or error message.
class ClipActions {
  static Library get _lib => Library.instance;

  /// Opens a clip the right way: native player, phone-playable copy, or preview + ask once to convert.
  static Future<void> open(BuildContext context, Clip clip, {Rect? from, List<Clip> queue = const []}) async {
    final nav = Navigator.of(context);
    ClipInfo info;
    try {
      info = await _withSpinner(context, _lib.analyzeNow(clip));
    } catch (e) {
      Toast.error('Can\'t open ${clip.name}', message: _friendly(e));
      return;
    }
    if (!info.hasVideo) {
      Toast.error('No video in this file', message: '${clip.name} doesn\'t contain a video track.');
      return;
    }
    if (!context.mounted) return;

    if (info.native) {
      nav.push(PlayerPage.route(clip, info, preview: false, from: from, queue: queue));
      return;
    }

    final copy = _lib.copyOf(clip);
    if (copy != null && _lib.settings.preferCopy) {
      final copyInfo = await _lib.analyzeNow(copy).catchError((_) => info);
      Toast.info('Playing phone-playable copy', message: 'Smooth version of ${clip.name}');
      nav.push(PlayerPage.route(copy, copyInfo, preview: !copyInfo.native, original: clip, from: from, queue: queue));
      return;
    }

    final running = TaskCenter.instance.conversionFor(clip.uri);
    final converting = running != null && running.active;
    if (!converting && _lib.settings.autoConvert) {
      await startConversion(context, clip, info);
      return;
    }
    if (!converting && !_lib.asked.contains(clip.key)) {
      _lib.markAsked(clip);
      final choice = await showConvertSheet(context, clip, info, offerPreview: true);
      // After "Make Phone-Playable" the CPU is busy converting; the copy opens from Activity when ready.
      if (choice != 'preview' || !context.mounted) return;
    }
    if (context.mounted) nav.push(PlayerPage.route(clip, info, preview: true, from: from, queue: queue));
  }

  /// Swaps the open player for [clip] (swiping to the next or previous video). Never stops to ask about
  /// conversion: a clip the phone can't play natively just opens in ProView's smooth mode.
  static Future<bool> replaceWith(BuildContext context, Clip clip,
      {List<Clip> queue = const [], bool instant = false}) async {
    final nav = Navigator.of(context);
    ClipInfo info;
    try {
      info = await _lib.analyzeNow(clip);
    } catch (e) {
      Toast.error('Can\'t open ${clip.name}', message: _friendly(e));
      return false;
    }
    if (!info.hasVideo) {
      Toast.error('No video in this file', message: '${clip.name} doesn\'t contain a video track.');
      return false;
    }
    if (!context.mounted) return false;
    if (info.native) {
      nav.pushReplacement(PlayerPage.route(clip, info, preview: false, queue: queue, instant: instant));
      return true;
    }
    final copy = _lib.copyOf(clip);
    if (copy != null && _lib.settings.preferCopy) {
      final copyInfo = await _lib.analyzeNow(copy).catchError((_) => info);
      if (!context.mounted) return false;
      nav.pushReplacement(
          PlayerPage.route(copy, copyInfo, preview: !copyInfo.native, original: clip, queue: queue, instant: instant));
      return true;
    }
    nav.pushReplacement(PlayerPage.route(clip, info, preview: true, queue: queue, instant: instant));
    return true;
  }

  /// Opens a file chosen from the system picker (Google Drive, Files, USB drives…).
  static Future<void> openFromPicker(BuildContext context) async {
    final uri = await Engine.call<String>('pickFile');
    if (uri == null || !context.mounted) return;
    await openUri(context, uri);
  }

  /// Opens a content:// uri from the picker, a share, a notification or "Open with".
  static Future<void> openUri(BuildContext context, String uri) async {
    try {
      var clip = _lib.byUri(uri);
      if (clip == null) {
        final seekable = await Engine.call<bool>('isSeekable', {'uri': uri}) ?? false;
        var target = uri;
        if (!seekable) {
          final described = await Engine.describe(uri);
          Toast.working('Downloading ${described.name}', message: 'Progress is shown in Activity.');
          final id = 'dl-${DateTime.now().microsecondsSinceEpoch}';
          target = await Engine.call<String>('cacheDocument', {'uri': uri, 'name': described.name, 'taskId': id}) ?? uri;
          Toast.success('Downloaded', message: described.name);
        }
        clip = await _lib.addDocument(target);
      }
      if (context.mounted) await open(context, clip);
    } catch (e) {
      Toast.error('Couldn\'t open that file', message: _friendly(e));
    }
  }

  static Future<void> startConversion(BuildContext context, Clip clip, ClipInfo info,
      {Quality? quality, bool quiet = false}) async {
    final existing = TaskCenter.instance.conversionFor(clip.uri);
    if (existing != null && existing.active) {
      Toast.info('Already converting', message: '${clip.name} · ${existing.detail}');
      return;
    }
    final device = await deviceInfo();
    final vb = videoBitrate(info, quality ?? _lib.settings.quality, (device['maxBitrate'] as num?)?.toInt());
    await Engine.call('requestNotifications');
    final id = 'cv-${DateTime.now().microsecondsSinceEpoch}';
    try {
      await Engine.call('convert', {
        'taskId': id,
        'uri': clip.uri,
        'name': clip.name,
        'duration': info.duration,
        'videoBitrate': vb,
        'audioBitrate': 320000,
      });
      if (!quiet) {
        Toast.success('Conversion started',
            message: '${clip.name} keeps converting even if you leave the app.');
      }
    } catch (e) {
      Toast.error('Couldn\'t start the conversion', message: _friendly(e));
    }
  }

  static Future<void> cancelAllConversions() async {
    await Engine.call('cancelAllConvert');
    Toast.info('Stopped all conversions', message: 'Your original files are untouched.');
  }

  static Future<void> cancelConversion(BgTask t) async {
    await Engine.call('cancelConvert', {'taskId': t.id});
    Toast.info('Conversion cancelled', message: t.title);
  }

  static Future<void> share(Clip clip, {bool forWhatsApp = false}) async {
    var target = clip;
    if (forWhatsApp) {
      final info = _lib.info(clip);
      if (info != null && !info.native) {
        final copy = _lib.copyOf(clip);
        if (copy == null) {
          Toast.info('Make it phone-playable first',
              message: 'WhatsApp can\'t read ${info.formatName}. Convert the clip, then share the copy.');
          return;
        }
        target = copy;
      }
    }
    try {
      await Engine.call('share', {
        'uri': target.uri,
        'mime': target.name.toLowerCase().endsWith('.mp4') ? 'video/mp4' : 'video/*',
        'title': forWhatsApp ? 'Share to WhatsApp' : 'Share ${target.name}',
      });
      if (forWhatsApp) {
        Toast.info('Tip: send as a Document',
            message: 'In WhatsApp, attach as "Document" to avoid heavy recompression.');
      }
    } catch (e) {
      Toast.error('Couldn\'t share', message: _friendly(e));
    }
  }

  static Future<void> showMenu(BuildContext context, Clip clip, {BuildContext? anchor}) async {
    final info = _lib.info(clip);
    final copy = _lib.copyOf(clip);
    final running = TaskCenter.instance.conversionFor(clip.uri);
    await showGlassMenu(context, anchor: anchor, title: clip.name, message: info == null ? null : _summary(info), actions: [
      MenuAction('Play', icon: AppIcons.play_fill, onTap: () => open(context, clip)),
      if (copy != null)
        MenuAction('Play Phone-Playable Copy', icon: AppIcons.checkmark_seal, onTap: () => open(context, copy)),
      if (info != null && !info.native && copy == null && !(running?.active ?? false))
        MenuAction('Make Phone-Playable', icon: AppIcons.wand_stars, onTap: () => showConvertSheet(context, clip, info)),
      MenuAction('Info', icon: AppIcons.info_circle, onTap: () => showInfoSheet(context, clip)),
      MenuAction('Share', icon: AppIcons.share, onTap: () => share(clip)),
      MenuAction('Share to WhatsApp', icon: AppIcons.chat_bubble_2, onTap: () => share(clip, forWhatsApp: true)),
      if (clip.source == 'document')
        MenuAction('Remove from List', icon: AppIcons.minus_circle, destructive: true, onTap: () {
          _lib.removeDocument(clip);
          Toast.success('Removed from ProView', message: 'The file itself wasn\'t deleted.');
        }),
    ]);
  }

  // ---- Conversion maths ----

  static Map<String, dynamic>? _device;
  static Future<Map<String, dynamic>> deviceInfo() async {
    _device ??= Map<String, dynamic>.from(await Engine.call<Map<dynamic, dynamic>>('deviceInfo') ?? {});
    return _device!;
  }

  static int videoBitrate(ClipInfo info, Quality q, int? encoderMax) {
    final bpp = switch (q) { Quality.balanced => 0.10, Quality.high => 0.20, Quality.maximum => 0.30 };
    final fps = info.fps > 0 ? info.fps : 30;
    var bitrate = (info.width * info.height * fps * bpp).round();
    bitrate = bitrate.clamp(8000000, 200000000);
    if (encoderMax != null && encoderMax > 0) bitrate = bitrate.clamp(4000000, encoderMax);
    return bitrate;
  }

  static int estimatedBytes(ClipInfo info, int videoBitrate) =>
      ((videoBitrate + 320000) / 8 * info.duration).round();

  static String _summary(ClipInfo i) =>
      '${i.formatName} · ${i.resolutionLabel}${i.fpsLabel.isNotEmpty ? ' · ${i.fpsLabel} fps' : ''}'
      '${i.duration > 0 ? ' · ${formatDuration(Duration(milliseconds: (i.duration * 1000).round()))}' : ''}';

  static String _friendly(Object e) {
    final s = e.toString();
    final m = RegExp(r'PlatformException\([^,]*, ([^,]*),').firstMatch(s);
    return (m?.group(1) ?? s).replaceAll('Exception: ', '');
  }

  static Future<T> _withSpinner<T>(BuildContext context, Future<T> future) async {
    var shown = false;
    final timer = Timer(const Duration(milliseconds: 250), () {
      shown = true;
      showGeneralDialog(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black.withValues(alpha: 0.12),
        transitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => const Center(child: _SpinnerCard()),
        transitionBuilder: (_, anim, _, child) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(CurvedAnimation(parent: anim, curve: Motion.spring)), child: child),
        ),
      );
    });
    try {
      return await future;
    } finally {
      timer.cancel();
      if (shown && context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }
}

class _SpinnerCard extends StatelessWidget {
  const _SpinnerCard();
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LiquidGlass(
      radius: 30,
      blur: 24,
      tint: p.isDark ? const Color(0xCC1C1C1E) : const Color(0xE6FFFFFF),
      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const LogoSpinner(size: 46),
        const SizedBox(height: 14),
        Text('Reading video', style: TextStyles.footnote(p).copyWith(color: p.label, decoration: TextDecoration.none)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Make Phone-Playable sheet

/// Returns 'convert', 'preview', or null if dismissed.
Future<String?> showConvertSheet(BuildContext context, Clip clip, ClipInfo info, {bool offerPreview = false}) {
  return showAppSheet<String>(context,
      builder: (_, c) => _ConvertSheet(clip: clip, info: info, offerPreview: offerPreview, controller: c));
}

class _ConvertSheet extends StatefulWidget {
  final Clip clip;
  final ClipInfo info;
  final bool offerPreview;
  final ScrollController controller;
  const _ConvertSheet(
      {required this.clip, required this.info, required this.offerPreview, required this.controller});
  @override
  State<_ConvertSheet> createState() => _ConvertSheetState();
}

class _ConvertSheetState extends State<_ConvertSheet> {
  late Quality _quality = Library.instance.settings.quality;
  Map<String, dynamic>? _device;
  double? _decodeFps;

  @override
  void initState() {
    super.initState();
    ClipActions.deviceInfo().then((d) => mounted ? setState(() => _device = d) : null);
    Engine.decodeSpeed(widget.clip.uri).then((f) => mounted ? setState(() => _decodeFps = f) : null).catchError((_) {
      if (mounted) setState(() => _decodeFps = 0);
    });
  }

  String get _timeEstimate {
    final fps = _decodeFps;
    if (fps == null) return '';
    final i = widget.info;
    if (fps <= 0 || i.duration <= 0) return 'A few minutes';
    final frames = i.duration * (i.fps > 0 ? i.fps : 30);
    // Hardware encoding runs alongside decoding; decoding speed dominates.
    final seconds = frames / (fps * 0.85) + 4;
    if (seconds < 60) return 'Under a minute';
    final mins = (seconds / 60).ceil();
    return 'About $mins min';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final i = widget.info;
    final maxBitrate = (_device?['maxBitrate'] as num?)?.toInt();
    final vb = ClipActions.videoBitrate(i, _quality, maxBitrate);
    final size = ClipActions.estimatedBytes(i, vb);
    final free = (_device?['freeBytes'] as num?)?.toInt();
    final enough = free == null || free > size * 2;
    final tenBit = _device?['tenBitEncoder'] as bool? ?? true;
    final realtime = _decodeFps != null && _decodeFps! >= i.fps * 0.95 && i.fps > 0;

    return SingleChildScrollView(
      controller: widget.controller,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(0, 28, 0, MediaQuery.paddingOf(context).bottom + 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Center(child: ProViewLogo(size: 64)),
        const SizedBox(height: 14),
        Text('Make Phone-Playable', style: TextStyles.title2(p), textAlign: TextAlign.center),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 6, 32, 20),
          child: Text(
            '${widget.info.reason}. ProView can create a smooth ${tenBit ? '10-bit ' : ''}HEVC copy that plays perfectly here, '
            'in Gallery and in WhatsApp.',
            style: TextStyles.subhead(p).copyWith(color: p.secondaryLabel),
            textAlign: TextAlign.center,
          ),
        ),
        GroupedSection(children: [
          GroupedRow(title: 'Original', value: '${i.formatName} · ${i.resolutionLabel} ${i.fpsLabel}'),
          GroupedRow(
              title: 'Copy',
              value: 'HEVC ${tenBit ? '10' : '8'}-bit · ${i.resolutionLabel} ${i.fpsLabel} · ${formatBitrate(vb)}'),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: GlassSegmented<Quality>(
            value: _quality,
            onChanged: (q) => setState(() => _quality = q),
            segments: const {Quality.balanced: 'Balanced', Quality.high: 'High', Quality.maximum: 'Maximum'},
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 20),
          child: Text(
            switch (_quality) {
              Quality.balanced => 'Smaller files. Great on the phone screen.',
              Quality.high => 'Recommended. Visually identical to the original on any phone.',
              Quality.maximum => 'Largest files. For viewing on big screens.',
            },
            style: TextStyles.footnote(p),
            textAlign: TextAlign.center,
          ),
        ),
        GroupedSection(
          footer: 'Your original file is never changed. The copy is saved to Gallery › ProView.',
          children: [
            GroupedRow(title: 'Estimated size', value: '≈ ${formatBytes(size)}'),
            GroupedRow(
              title: 'Estimated time',
              value: _decodeFps == null ? null : _timeEstimate,
              trailing: _decodeFps == null ? const Skeleton(width: 70) : null,
            ),
            GroupedRow(
              title: 'Free space',
              value: free == null ? null : formatBytes(free),
              trailing: free == null
                  ? const Skeleton(width: 60)
                  : enough
                      ? null
                      : Icon(AppIcons.exclamationmark_triangle_fill, color: p.orange, size: 18),
            ),
          ],
        ),
        if (!tenBit)
          _Note(
              icon: AppIcons.info_circle_fill,
              color: p.orange,
              text: 'This phone\'s encoder only makes 8-bit copies. Dark gradients may show slight banding.'),
        if (realtime && widget.offerPreview)
          _Note(
              icon: AppIcons.checkmark_seal_fill,
              color: p.green,
              text: 'Good news: this phone can decode this clip in real time, so preview should already be smooth.'),
        if (!enough)
          _Note(
              icon: AppIcons.exclamationmark_triangle_fill,
              color: p.red,
              text: 'Not enough free space. Free up about ${formatBytes(size * 2)} first.'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: PrimaryButton(
            'Make Phone-Playable',
            icon: AppIcons.wand_stars,
            onPressed: !enough
                ? null
                : () {
                    Navigator.pop(context, 'convert');
                    ClipActions.startConversion(context, widget.clip, widget.info, quality: _quality);
                  },
          ),
        ),
        if (widget.offerPreview)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: PrimaryButton('Preview Without Converting',
                filled: false, onPressed: () => Navigator.pop(context, 'preview')),
          ),
      ]),
    );
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _Note({required this.icon, required this.color, required this.text});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyles.footnote(p).copyWith(color: p.label))),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Info sheet

Future<void> showInfoSheet(BuildContext context, Clip clip) {
  return showAppSheet(context, builder: (_, c) => _InfoSheet(clip: clip, controller: c));
}

class _InfoSheet extends StatelessWidget {
  final Clip clip;
  final ScrollController controller;
  const _InfoSheet({required this.clip, required this.controller});

  static String _dateTime(BuildContext context, DateTime d) {
    final l = MaterialLocalizations.of(context);
    return '${l.formatMediumDate(d)}, ${l.formatTimeOfDay(TimeOfDay.fromDateTime(d))}';
  }

  /// "+37.3349-122.0090+012.3/" (ISO 6709, as phones write it) -> "37.3349° N, 122.0090° W".
  static String? _place(String raw) {
    final m = RegExp(r'^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)').firstMatch(raw.trim());
    if (m == null) return raw.isEmpty ? null : raw;
    final lat = double.tryParse(m.group(1)!), lon = double.tryParse(m.group(2)!);
    if (lat == null || lon == null) return raw;
    return '${lat.abs().toStringAsFixed(4)}° ${lat >= 0 ? 'N' : 'S'}, ${lon.abs().toStringAsFixed(4)}° ${lon >= 0 ? 'E' : 'W'}';
  }

  static String _sourceLabel(Clip c) => switch (c.source) {
        'tree' => 'Drive or folder',
        'document' => 'Opened file',
        _ => 'This phone',
      };

  /// A row whose value can be copied by touching and holding it.
  Widget _row(BuildContext context, String title, String? value, {String? subtitle}) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    return GroupedRow(
      title: title,
      value: value,
      subtitle: subtitle,
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: value));
        HapticFeedback.mediumImpact();
        Toast.info('Copied', message: value);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final lib = Library.instance;
    return FutureBuilder<ClipInfo>(
      future: lib.analyzeDetailed(clip),
      builder: (context, snap) {
        final i = snap.data;
        final thumb = lib.thumb(clip);
        return SingleChildScrollView(
          controller: controller,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(top: 28, bottom: MediaQuery.paddingOf(context).bottom + 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (thumb != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: ClipRSuperellipse(
                  borderRadius: BorderRadius.circular(22),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Container(color: Colors.black, child: Image.file(File(thumb), fit: BoxFit.contain)),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(clip.name, style: TextStyles.title3(p)),
            ),
            if (i != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Text(
                  [
                    i.formatName,
                    if (i.resolutionLabel.isNotEmpty) i.resolutionLabel,
                    if (i.fpsLabel.isNotEmpty) '${i.fpsLabel} fps',
                    if (i.duration > 0) formatDuration(Duration(milliseconds: (i.duration * 1000).round())),
                    formatBytes(clip.size),
                  ].join(' · '),
                  style: TextStyles.footnote(p),
                ),
              )
            else
              const SizedBox(height: 14),
            if (snap.hasError && i == null)
              EmptyState(
                  icon: AppIcons.exclamationmark_triangle,
                  title: 'Couldn\'t read this file',
                  message: ClipActions._friendly(snap.error!))
            else if (i == null)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: LogoSpinner(size: 40)))
            else ...[
              GroupedSection(header: 'Playback', children: [
                GroupedRow(
                  leading: IconTile(i.native ? AppIcons.checkmark : AppIcons.bolt_slash_fill,
                      i.native ? p.green : p.orange),
                  title: i.native ? 'Plays natively' : 'Needs conversion for smooth playback',
                  subtitle: i.reason,
                ),
                if (lib.copyOf(clip) != null)
                  GroupedRow(
                    leading: IconTile(AppIcons.checkmark_seal_fill, p.accent),
                    title: 'Phone-playable copy ready',
                    subtitle: lib.copyOf(clip)!.name,
                  ),
                if (lib.isFavorite(clip))
                  GroupedRow(leading: IconTile(AppIcons.heart_fill, p.red), title: 'In your Favorites'),
              ]),
              GroupedSection(header: 'Video', children: [
                _row(context, 'Format', i.formatName),
                _row(context, 'Codec profile',
                    [if (i.profile.isNotEmpty) i.profile, if (i.level > 0) 'Level ${i.level}'].join(' · ')),
                _row(context, 'Resolution',
                    '${i.displayWidth} × ${i.displayHeight}${i.resolutionLabel.isEmpty ? '' : ' (${i.resolutionLabel})'}',
                    subtitle: i.megapixels >= 0.1 ? '${i.megapixels.toStringAsFixed(1)} megapixels' : null),
                _row(context, 'Aspect ratio', i.aspectLabel),
                if (i.pixelAspect.isNotEmpty) _row(context, 'Pixel aspect', i.pixelAspect),
                if (i.rotation != 0) _row(context, 'Rotation', '${i.rotation}°'),
                if (i.fps > 0) _row(context, 'Frame rate', '${i.fpsLabel} fps'),
                if (i.hasDetails) _row(context, 'Scan', i.progressive ? 'Progressive' : 'Interlaced'),
                _row(context, 'Bit depth', '${i.bitDepth}-bit'),
                _row(context, 'Chroma', i.chroma),
                if (i.alpha) _row(context, 'Alpha channel', 'Yes'),
                _row(context, 'Pixel format', i.pixFmt),
                _row(context, 'Dynamic range', i.dynamicRange),
                _row(context, 'Color', i.colorLabel),
                if (i.videoBitRate > 0 || i.bitRate > 0)
                  _row(context, 'Video bitrate', formatBitrate(i.videoBitRate > 0 ? i.videoBitRate : i.bitRate)),
                if (i.bitsPerPixel > 0)
                  _row(context, 'Data per pixel', '${i.bitsPerPixel.toStringAsFixed(2)} bits',
                      subtitle: i.bitsPerPixel > 1.5
                          ? 'Light compression, large files'
                          : i.bitsPerPixel > 0.3
                              ? 'Balanced'
                              : 'Heavily compressed'),
                if (i.duration > 0)
                  _row(context, 'Duration', formatDuration(Duration(milliseconds: (i.duration * 1000).round()))),
                if (i.frames > 0 || (i.duration > 0 && i.fps > 0))
                  _row(context, 'Frames', '${i.frames > 0 ? i.frames : (i.duration * i.fps).round()}'),
              ]),
              GroupedSection(header: 'Audio', children: [
                if (i.audioChannels == 0)
                  const GroupedRow(title: 'Audio', value: 'None')
                else ...[
                  _row(context, 'Format', i.audioLabel),
                  _row(context, 'Channels', i.audioLayout.isEmpty ? '${i.audioChannels}' : i.audioLayout),
                  if (i.audioSampleRate > 0) _row(context, 'Sample rate', '${i.audioSampleRate} Hz'),
                  if (i.audioBits > 0) _row(context, 'Bit depth', '${i.audioBits}-bit'),
                  if (i.audioBitRate > 0) _row(context, 'Bitrate', formatBitrate(i.audioBitRate)),
                ],
              ]),
              if (i.tags.isNotEmpty)
                GroupedSection(header: 'Camera & Origin', children: [
                  _row(context, 'Camera', [i.tags['make'], i.tags['model']].whereType<String>().join(' ')),
                  _row(context, 'Software', i.tags['encoder'] as String?),
                  _row(context, 'Recorded', () {
                    final d = DateTime.tryParse(i.tags['created'] as String? ?? '');
                    return d == null ? null : _dateTime(context, d.toLocal());
                  }()),
                  _row(context, 'Location', _place(i.tags['location'] as String? ?? '')),
                  _row(context, 'Title', i.tags['title'] as String?),
                ]),
              GroupedSection(header: 'File', children: [
                _row(context, 'Name', clip.name),
                _row(context, 'Size', formatBytes(clip.size), subtitle: '${clip.size} bytes'),
                _row(context, 'Container', i.container.split(',').first.toUpperCase()),
                _row(context, 'Stored on', _sourceLabel(clip)),
                if (clip.folder.isNotEmpty) _row(context, 'Folder', clip.folder),
                if (clip.path.isNotEmpty) _row(context, 'Path', clip.path),
                if (clip.modified > 0)
                  _row(context, 'Modified', _dateTime(context, DateTime.fromMillisecondsSinceEpoch(clip.modified))),
                if (i.hasDetails && (i.streams['audio'] ?? 0) is num && ((i.streams['audio'] as num) > 1))
                  _row(context, 'Audio tracks', '${i.streams['audio']}'),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 2, 28, 8),
                child: Text('Touch and hold a value to copy it.', style: TextStyles.footnote(p), textAlign: TextAlign.center),
              ),
            ],
          ]),
        );
      },
    );
  }
}
