import 'dart:convert';

import 'package:flutter/services.dart';

/// Thin wrapper over the Android side (MainActivity.kt).
class Engine {
  static const _ch = MethodChannel('proview/engine');
  static const tasks = EventChannel('proview/tasks');

  static Future<T?> call<T>(String method, [Map<String, dynamic>? args]) => _ch.invokeMethod<T>(method, args);

  static void onOpenUri(void Function(String uri) handler) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'openUri') handler(call.arguments as String);
    });
  }

  static Future<String> permissionState() async => await call<String>('permissionState') ?? 'denied';
  static Future<String> requestPermission() async => await call<String>('requestPermission') ?? 'denied';

  static Future<List<Clip>> queryLibrary() async {
    final list = await call<List<dynamic>>('queryLibrary') ?? const [];
    return list.map((e) => Clip.fromMap(Map<String, dynamic>.from(e as Map))).toList();
  }

  static Future<List<Clip>> queryTrash() async {
    final list = await call<List<dynamic>>('queryTrash') ?? const [];
    return list.map((e) => Clip.fromMap(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// Moves to the system bin (or restores). Android asks the user to confirm; returns whether they did.
  static Future<bool> trash(List<String> uris, {bool trash = true}) async =>
      await call<bool>('trash', {'uris': uris, 'trash': trash}) ?? false;

  static Future<bool> deleteForever(List<String> uris) async =>
      await call<bool>('deleteForever', {'uris': uris}) ?? false;

  static Future<int> deleteDocuments(List<String> uris) async =>
      await call<int>('deleteDocuments', {'uris': uris}) ?? 0;

  static Future<List<Clip>> listTree(String uri) async {
    final list = await call<List<dynamic>>('listTree', {'uri': uri}) ?? const [];
    return list.map((e) => Clip.fromMap(Map<String, dynamic>.from(e as Map))).toList();
  }

  static Future<Clip> describe(String uri) async =>
      Clip.fromMap(Map<String, dynamic>.from(await call<Map<dynamic, dynamic>>('describe', {'uri': uri}) ?? {}));

  static Future<ClipInfo> analyze(String uri) async {
    final m = await call<Map<dynamic, dynamic>>('analyze', {'uri': uri});
    return ClipInfo.fromJson({
      'probe': jsonDecode(m!['probe'] as String),
      'native': m['native'],
      'reason': m['reason'],
    });
  }

  static Future<String?> thumbnail(Clip clip, ClipInfo info) async {
    final key = await call<String>('cacheKey', {'uri': clip.uri, 'size': clip.size, 'modified': clip.modified});
    return call<String>('thumbnail', {
      'uri': clip.uri,
      'key': key,
      'duration': info.duration,
      'rotation': info.rotation,
      'preferSystem': info.native,
    });
  }

  static Future<double> decodeSpeed(String uri) async => await call<double>('decodeSpeed', {'uri': uri}) ?? 0;
}

class Clip {
  final String uri;
  final String name;
  final int size;
  final int modified;
  final int durationMs;
  final String folder;
  final String path;
  final int width;
  final int height;
  final String source; // device | tree | document

  /// When a clip in the bin is purged automatically (ms since epoch), or 0.
  final int expires;

  const Clip({
    required this.uri,
    required this.name,
    required this.size,
    required this.modified,
    required this.durationMs,
    required this.folder,
    required this.path,
    required this.width,
    required this.height,
    required this.source,
    this.expires = 0,
  });

  factory Clip.fromMap(Map<String, dynamic> m) => Clip(
        uri: m['uri'] as String? ?? '',
        name: m['name'] as String? ?? 'Video',
        size: (m['size'] as num?)?.toInt() ?? 0,
        modified: (m['modified'] as num?)?.toInt() ?? 0,
        durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        folder: m['folder'] as String? ?? '',
        path: m['path'] as String? ?? '',
        width: (m['width'] as num?)?.toInt() ?? 0,
        height: (m['height'] as num?)?.toInt() ?? 0,
        source: m['source'] as String? ?? 'device',
        expires: (m['expires'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toMap() => {
        'uri': uri,
        'name': name,
        'size': size,
        'modified': modified,
        'durationMs': durationMs,
        'folder': folder,
        'path': path,
        'width': width,
        'height': height,
        'source': source,
      };

  /// Identity that changes when the file changes (used for caches).
  String get key => '$uri|$size|$modified';

  bool get isProViewCopy => path.contains('Movies/ProView') || name.endsWith('(ProView).mp4');
}

/// What the engine found inside a file, plus whether the phone can play it natively.
class ClipInfo {
  final Map<String, dynamic> probe;
  final bool native;
  final String reason;

  ClipInfo({required this.probe, required this.native, required this.reason});

  factory ClipInfo.fromJson(Map<String, dynamic> j) => ClipInfo(
        probe: Map<String, dynamic>.from(j['probe'] as Map),
        native: j['native'] as bool? ?? false,
        reason: j['reason'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'probe': probe, 'native': native, 'reason': reason};

  Map<String, dynamic> get _v => Map<String, dynamic>.from(probe['video'] as Map? ?? const {});
  Map<String, dynamic>? get _a => probe['audio'] == null ? null : Map<String, dynamic>.from(probe['audio'] as Map);

  bool get hasVideo => probe['video'] != null;
  String get codec => _v['codec'] as String? ?? '';
  String get fourcc => _v['fourcc'] as String? ?? '';
  String get profile => _v['profile'] as String? ?? '';
  int get width => (_v['width'] as num?)?.toInt() ?? 0;
  int get height => (_v['height'] as num?)?.toInt() ?? 0;
  double get fps => (_v['fps'] as num?)?.toDouble() ?? 0;
  int get bitDepth => (_v['bitDepth'] as num?)?.toInt() ?? 8;
  String get chroma => _v['chroma'] as String? ?? '';
  int get rotation => (_v['rotation'] as num?)?.toInt() ?? 0;
  double get duration => (probe['duration'] as num?)?.toDouble() ?? 0;
  int get bitRate => (probe['bitRate'] as num?)?.toInt() ?? 0;
  String get container => probe['container'] as String? ?? '';
  String get primaries => _v['primaries'] as String? ?? '';
  String get transfer => _v['transfer'] as String? ?? '';
  String get matrix => _v['matrix'] as String? ?? '';
  String get range => _v['range'] as String? ?? '';
  bool get alpha => _v['alpha'] as bool? ?? false;

  // ---- Details for the Info page (probe revision 2; older cached probes simply lack them) ----
  bool get hasDetails => probe['rev'] == 2;
  String get pixFmt => _v['pixFmt'] as String? ?? '';
  int get level => (_v['level'] as num?)?.toInt() ?? 0;
  bool get progressive => _v['progressive'] as bool? ?? true;
  int get videoBitRate => (_v['bitRate'] as num?)?.toInt() ?? 0;
  int get frames => (_v['frames'] as num?)?.toInt() ?? 0;
  int get audioChannels => (_a?['channels'] as num?)?.toInt() ?? 0;
  int get audioSampleRate => (_a?['sampleRate'] as num?)?.toInt() ?? 0;
  int get audioBits => (_a?['bits'] as num?)?.toInt() ?? 0;
  int get audioBitRate => (_a?['bitRate'] as num?)?.toInt() ?? 0;
  String get audioLayout => _a?['layout'] as String? ?? '';
  Map<String, dynamic> get streams => Map<String, dynamic>.from(probe['streams'] as Map? ?? const {});
  Map<String, dynamic> get tags => Map<String, dynamic>.from(probe['tags'] as Map? ?? const {});

  /// Pixel aspect ratio when the picture isn't square-pixel, e.g. "4:3".
  String get pixelAspect {
    final n = (_v['sarNum'] as num?)?.toInt() ?? 0;
    final d = (_v['sarDen'] as num?)?.toInt() ?? 0;
    return n > 0 && d > 0 && n != d ? '$n:$d' : '';
  }

  /// Picture shape as people say it: 16:9, 4:3, 9:16, 2.39:1...
  String get aspectLabel {
    final w = displayWidth, h = displayHeight;
    if (w <= 0 || h <= 0) return '';
    final r = w / h;
    const known = {
      '16:9': 16 / 9,
      '9:16': 9 / 16,
      '4:3': 4 / 3,
      '3:4': 3 / 4,
      '3:2': 3 / 2,
      '2:3': 2 / 3,
      '1:1': 1.0,
      '21:9': 21 / 9,
      '2:1': 2.0,
      '1.85:1': 1.85,
      '2.39:1': 2.39,
      '17:9': 17 / 9,
      '19.5:9': 19.5 / 9,
    };
    for (final e in known.entries) {
      if ((r - e.value).abs() / e.value < 0.012) return e.key;
    }
    return r >= 1 ? '${r.toStringAsFixed(2)}:1' : '1:${(1 / r).toStringAsFixed(2)}';
  }

  /// How much data each pixel gets: a rough gauge of how heavily the clip is compressed.
  double get bitsPerPixel {
    final rate = videoBitRate > 0 ? videoBitRate : bitRate;
    if (rate <= 0 || width <= 0 || height <= 0 || fps <= 0) return 0;
    return rate / (width * height * fps);
  }

  /// "SDR", "HDR10 (PQ)" or "HLG HDR".
  String get dynamicRange {
    if (transfer == 'smpte2084') return 'HDR10 (PQ)';
    if (transfer == 'arib-std-b67') return 'HLG HDR';
    return 'SDR';
  }

  double get megapixels => width * height / 1e6;

  bool get isProRes => codec == 'prores';
  bool get isHdr => transfer == 'smpte2084' || transfer == 'arib-std-b67';

  /// Display size after rotation.
  int get displayWidth => rotation % 180 == 0 ? width : height;
  int get displayHeight => rotation % 180 == 0 ? height : width;

  static const _proresNames = {
    'apco': 'ProRes 422 Proxy',
    'apcs': 'ProRes 422 LT',
    'apcn': 'ProRes 422',
    'apch': 'ProRes 422 HQ',
    'ap4h': 'ProRes 4444',
    'ap4x': 'ProRes 4444 XQ',
  };

  /// Full format name, e.g. "ProRes 422 HQ" or "HEVC 4:2:2 10-bit".
  String get formatName {
    switch (codec) {
      case 'prores':
        return _proresNames[fourcc] ?? (profile.isNotEmpty ? 'ProRes $profile' : 'ProRes');
      case 'hevc':
        return 'HEVC${chroma.isNotEmpty && chroma != '4:2:0' ? ' $chroma' : ''}${bitDepth > 8 ? ' $bitDepth-bit' : ''}';
      case 'h264':
        return 'H.264${bitDepth > 8 ? ' $bitDepth-bit' : ''}';
      case 'dnxhd':
        return profile.isNotEmpty ? 'DNx${profile.replaceFirst('DNX', '')}' : 'DNxHD';
      case 'cfhd':
        return 'CineForm';
      case 'vp9':
        return 'VP9';
      case 'av1':
        return 'AV1';
      case '':
        return 'Unknown';
      default:
        return codec.toUpperCase();
    }
  }

  /// Short badge for grid tiles.
  String get badge {
    if (isProRes) return 'ProRes';
    if (codec == 'hevc' && chroma.isNotEmpty && chroma != '4:2:0') return 'HEVC $chroma';
    if (codec == 'dnxhd') return 'DNx';
    if (codec == 'cfhd') return 'CineForm';
    if (isHdr) return 'HDR';
    return '';
  }

  String get resolutionLabel {
    final long = width > height ? width : height;
    final short = width > height ? height : width;
    if (long >= 7600) return '8K';
    if (long >= 5000) return '6K';
    if (long >= 3800) return '4K';
    if (long >= 2500) return '${short}p';
    if (long >= 1900) return '1080p';
    if (long >= 1270) return '720p';
    return short > 0 ? '${short}p' : '';
  }

  String get fpsLabel {
    if (fps <= 0) return '';
    final rounded = fps.roundToDouble();
    return (fps - rounded).abs() < 0.02 ? rounded.toInt().toString() : fps.toStringAsFixed(2);
  }

  String get colorLabel {
    final prim = {'bt709': 'Rec. 709', 'bt2020': 'Rec. 2020', 'smpte170m': 'Rec. 601', 'bt470bg': 'Rec. 601'}[primaries];
    final trc = {'smpte2084': 'PQ (HDR10)', 'arib-std-b67': 'HLG', 'bt709': 'Gamma 2.4'}[transfer];
    final parts = [?prim, ?trc];
    final rng = range == 'pc' ? 'Full range' : (range == 'tv' ? 'Video range' : null);
    if (rng != null) parts.add(rng);
    return parts.isEmpty ? 'Not tagged' : parts.join(' · ');
  }

  String get audioLabel {
    final a = _a;
    if (a == null) return 'No audio';
    final codecName = {
          'aac': 'AAC',
          'pcm_s16le': '16-bit PCM',
          'pcm_s16be': '16-bit PCM',
          'pcm_s24le': '24-bit PCM',
          'pcm_s24be': '24-bit PCM',
          'pcm_s32le': '32-bit PCM',
          'pcm_s32be': '32-bit PCM',
          'pcm_f32le': '32-bit float PCM',
          'pcm_f32be': '32-bit float PCM',
          'alac': 'Apple Lossless',
          'mp3': 'MP3',
          'mp3float': 'MP3',
          'ac3': 'Dolby Digital',
          'eac3': 'Dolby Digital Plus',
          'opus': 'Opus',
          'flac': 'FLAC',
        }[a['codec']] ??
        (a['codec'] as String? ?? '').toUpperCase();
    final ch = (a['channels'] as num?)?.toInt() ?? 0;
    final chLabel = ch == 1 ? 'Mono' : ch == 2 ? 'Stereo' : '$ch channels';
    final rate = (a['sampleRate'] as num?)?.toInt() ?? 0;
    return '$codecName · $chLabel${rate > 0 ? ' · ${(rate / 1000).toStringAsFixed(rate % 1000 == 0 ? 0 : 1)} kHz' : ''}';
  }
}

String formatBytes(int bytes) {
  if (bytes >= 1000000000) return '${(bytes / 1e9).toStringAsFixed(bytes >= 10e9 ? 0 : 1)} GB';
  if (bytes >= 1000000) return '${(bytes / 1e6).round()} MB';
  if (bytes >= 1000) return '${(bytes / 1e3).round()} KB';
  return '$bytes B';
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  return '${h > 0 ? '$h:' : ''}$mm:${s.toString().padLeft(2, '0')}';
}

String formatBitrate(int bps) =>
    bps >= 1000000 ? '${(bps / 1e6).toStringAsFixed(bps >= 100e6 ? 0 : 1)} Mbps' : '${(bps / 1e3).round()} kbps';
