import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'dates.dart';
import 'clip_actions.dart';
import 'engine.dart';
import 'main.dart' show navigatorKey;
import 'tags.dart';
import 'tasks.dart';

class PickedFolder {
  final String uri;
  final String name;
  PickedFolder(this.uri, this.name);
  Map<String, dynamic> toJson() => {'uri': uri, 'name': name};
}

enum Quality { balanced, high, maximum }

/// What ProView does with clips that are too heavy to play smoothly on this phone.
enum SlowMode {
  ask('Ask Me First', 'Offers a smooth copy once per clip, and you decide'),
  whilePlaying('When Playback Struggles', 'Starts a smooth copy by itself if a clip can\'t keep up'),
  onOpen('As Soon As I Open It', 'Makes the copy straight away, so it plays smoothly next time'),
  ahead('Ahead of Time', 'Checks new clips in the background and prepares the heavy ones');

  final String title;
  final String detail;
  const SlowMode(this.title, this.detail);
}

class AppSettings extends ChangeNotifier {
  Quality quality = Quality.high;
  bool autoConvert = false;
  bool deband = true;
  bool loop = false;
  bool preferCopy = true;

  /// When a clip can't be decoded in real time, prepare a smooth copy in the background without asking.
  bool smartPrepare = true;
  LibrarySort sort = LibrarySort.newest;

  /// Prepare smooth copies of heavy new clips in the background, before they're ever opened.
  bool prepareAhead = false;

  /// Preferred width of a library tile (logical px); pinching the library changes it.
  double tileExtent = 124;

  /// Let the phone look at preview frames (on-device) so search can find people and things.
  bool smartTags = true;

  SlowMode get slowMode => prepareAhead
      ? SlowMode.ahead
      : autoConvert
          ? SlowMode.onOpen
          : smartPrepare
              ? SlowMode.whilePlaying
              : SlowMode.ask;

  void setSlowMode(SlowMode m) {
    prepareAhead = m == SlowMode.ahead;
    autoConvert = m == SlowMode.onOpen;
    smartPrepare = m != SlowMode.ask;
  }

  Map<String, dynamic> toJson() => {
        'quality': quality.name,
        'autoConvert': autoConvert,
        'deband': deband,
        'loop': loop,
        'preferCopy': preferCopy,
        'smartPrepare': smartPrepare,
        'sort': sort.name,
        'prepareAhead': prepareAhead,
        'tileExtent': tileExtent,
        'smartTags': smartTags,
      };

  void load(Map<String, dynamic> j) {
    quality = Quality.values.asNameMap()[j['quality']] ?? Quality.high;
    autoConvert = j['autoConvert'] as bool? ?? false;
    deband = j['deband'] as bool? ?? true;
    loop = j['loop'] as bool? ?? false;
    preferCopy = j['preferCopy'] as bool? ?? true;
    smartPrepare = j['smartPrepare'] as bool? ?? true;
    sort = LibrarySort.values.asNameMap()[j['sort']] ?? LibrarySort.newest;
    prepareAhead = j['prepareAhead'] as bool? ?? false;
    tileExtent = ((j['tileExtent'] as num?) ?? 124).toDouble().clamp(56.0, 340.0);
    smartTags = j['smartTags'] as bool? ?? true;
  }

  /// Live resize while pinching (no save until the pinch ends).
  void previewTileExtent(double v) {
    tileExtent = v;
    notifyListeners();
  }

  void set(void Function(AppSettings s) change) {
    change(this);
    notifyListeners();
    Library.instance.save();
  }
}

/// The video library: every clip ProView knows about plus cached analysis and thumbnails.
class Library extends ChangeNotifier {
  Library._();
  static final instance = Library._();

  final settings = AppSettings();
  String permission = 'unknown';
  bool loaded = false;
  bool scanning = false;

  List<Clip> _device = [];
  final Map<String, List<Clip>> _trees = {};
  final List<Clip> _documents = [];
  final List<PickedFolder> folders = [];

  final Map<String, ClipInfo> _info = {};
  final Map<String, String> _thumbs = {};
  final Set<String> _failed = {};
  final Set<String> asked = {};

  /// Hearted clips, by uri.
  final Set<String> favorites = {};

  /// Clips in the system bin.
  List<Clip> bin = [];
  final Map<String, String> copies = {}; // original clip key -> converted copy uri

  final _queue = ListQueue<Clip>();
  final Set<String> _queued = {};
  int _inFlight = 0;
  int _analyzedThisRun = 0;
  Timer? _saveTimer;
  Timer? _notifyTimer;
  final Map<String, ValueNotifier<int>> _clipNotes = {};
  File? _file;

  // ---- Queries ----

  List<Clip> get all {
    final seen = <String>{};
    final out = <Clip>[];
    for (final c in [..._documents, ..._device, ..._trees.values.expand((e) => e)]) {
      if (seen.add(c.uri)) out.add(c);
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  List<Clip> get deviceClips => _device;
  List<Clip> get documents => _documents;
  List<Clip> treeClips(String uri) => _trees[uri] ?? const [];

  Map<String, List<Clip>> get deviceFolders {
    final map = SplayTreeMap<String, List<Clip>>((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    for (final c in _device) {
      map.putIfAbsent(c.folder.isEmpty ? 'Other' : c.folder, () => []).add(c);
    }
    return map;
  }

  /// Fires when this clip's analysis or thumbnail changes (tiles listen to just their own clip).
  Listenable clipListenable(Clip c) => _clipNotes.putIfAbsent(c.key, () => ValueNotifier(0));

  void _touch(Clip c) {
    final n = _clipNotes[c.key];
    if (n != null) n.value++;
    // Counts and filters only need to catch up a few times a second.
    _notifyTimer ??= Timer(const Duration(milliseconds: 1500), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  ClipInfo? info(Clip c) => _info[c.key];
  String? thumb(Clip c) => _thumbs[c.key];
  bool failed(Clip c) => _failed.contains(c.key);

  Clip? byUri(String uri) {
    for (final c in all) {
      if (c.uri == uri) return c;
    }
    return null;
  }

  /// The converted copy of [c], if one exists in the library.
  Clip? copyOf(Clip c) {
    final uri = copies[c.key];
    final linked = uri == null ? null : byUri(uri);
    if (linked != null || c.isProViewCopy) return linked;
    // Conversions that finished while ProView was closed: match "<name> (ProView).mp4".
    final dot = c.name.lastIndexOf('.');
    final expected = '${dot > 0 ? c.name.substring(0, dot) : c.name} (ProView).mp4';
    for (final d in _device) {
      if (d.name == expected) return d;
    }
    return null;
  }

  int get needsConversionCount =>
      all.where((c) => !c.isProViewCopy && _info[c.key] != null && !_info[c.key]!.native && copies[c.key] == null).length;

  // ---- Loading & persistence ----

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}/library.json');
    try {
      if (await _file!.exists()) {
        final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        settings.load(Map<String, dynamic>.from(j['settings'] as Map? ?? {}));
        for (final f in (j['folders'] as List? ?? [])) {
          folders.add(PickedFolder(f['uri'] as String, f['name'] as String));
        }
        for (final d in (j['documents'] as List? ?? [])) {
          _documents.add(Clip.fromMap(Map<String, dynamic>.from(d as Map)));
        }
        (j['info'] as Map? ?? {}).forEach((k, v) {
          _info[k as String] = ClipInfo.fromJson(Map<String, dynamic>.from(v as Map));
        });
        (j['thumbs'] as Map? ?? {}).forEach((k, v) {
          if (File(v as String).existsSync()) _thumbs[k as String] = v;
        });
        asked.addAll((j['asked'] as List? ?? []).cast<String>());
        favorites.addAll((j['favorites'] as List? ?? []).cast<String>());
        (j['copies'] as Map? ?? {}).forEach((k, v) => copies[k as String] = v as String);
      }
    } catch (e) {
      debugPrint('library cache unreadable, starting fresh: $e');
    }
    permission = await Engine.permissionState();
    loaded = true;
    notifyListeners();
    TaskCenter.instance.finished.listen(_onTaskFinished);
    await SmartTags.instance.init();
    if (permission != 'denied') await refresh();
    // Once the library is up, let the tagger catch up on clips whose previews already exist.
    Future<void>.delayed(const Duration(seconds: 6), SmartTags.instance.scan);
  }

  void save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () async {
      final known = all.map((c) => c.key).toSet();
      final j = {
        'settings': settings.toJson(),
        'folders': folders.map((f) => f.toJson()).toList(),
        'documents': _documents.map((d) => d.toMap()).toList(),
        'info': {
          for (final e in _info.entries)
            if (known.contains(e.key)) e.key: e.value.toJson()
        },
        'thumbs': {
          for (final e in _thumbs.entries)
            if (known.contains(e.key)) e.key: e.value
        },
        'asked': asked.toList(),
        'favorites': favorites.toList(),
        'copies': copies,
      };
      final tmp = File('${_file!.path}.tmp');
      await tmp.writeAsString(jsonEncode(j));
      await tmp.rename(_file!.path);
    });
  }

  // ---- Favourites and the bin ----

  bool isFavorite(Clip c) => favorites.contains(c.uri);

  /// Hearts every clip, or un-hearts them all if they were all hearted already.
  void toggleFavorites(Iterable<Clip> clips) {
    final all = clips.every(isFavorite);
    for (final c in clips) {
      all ? favorites.remove(c.uri) : favorites.add(c.uri);
      _touch(c);
    }
    save();
    notifyListeners();
  }

  Future<void> loadBin() async {
    try {
      bin = await Engine.queryTrash();
    } catch (_) {
      bin = [];
    }
    notifyListeners();
  }

  /// Moves clips to the bin (Android shows its own confirmation). Clips on drives have no bin, so those are
  /// deleted for good. Returns how many were removed.
  Future<int> delete(List<Clip> clips) async {
    final device = clips.where((c) => c.source == 'device').toList();
    final other = clips.where((c) => c.source != 'device').toList();
    var removed = 0;
    if (device.isNotEmpty && await Engine.trash(device.map((c) => c.uri).toList())) removed += device.length;
    if (other.isNotEmpty) removed += await Engine.deleteDocuments(other.map((c) => c.uri).toList());
    if (removed > 0) {
      for (final c in other) {
        _documents.removeWhere((d) => d.uri == c.uri);
      }
      await refresh();
      loadBin();
    }
    return removed;
  }

  Future<bool> restore(List<Clip> clips) async {
    final ok = await Engine.trash(clips.map((c) => c.uri).toList(), trash: false);
    if (ok) {
      await refresh();
      await loadBin();
    }
    return ok;
  }

  Future<bool> deleteForever(List<Clip> clips) async {
    final ok = await Engine.deleteForever(clips.map((c) => c.uri).toList());
    if (ok) await loadBin();
    return ok;
  }

  Future<String> requestPermission() async {
    permission = await Engine.requestPermission();
    notifyListeners();
    if (permission != 'denied') unawaited(refresh());
    return permission;
  }

  Future<void> refresh() async {
    if (scanning) return;
    scanning = true;
    notifyListeners();
    final task = TaskCenter.instance.local('scan', 'scan', 'Scanning your videos', detail: 'Looking on this phone');
    String? error;
    try {
      permission = await Engine.permissionState();
      if (permission != 'denied') _device = await Engine.queryLibrary();
      for (final f in List.of(folders)) {
        TaskCenter.instance.update(task.id, detail: 'Reading ${f.name}');
        try {
          _trees[f.uri] = await Engine.listTree(f.uri);
        } catch (e) {
          _trees[f.uri] = const [];
          error = '${f.name} isn\'t available. Is the drive plugged in?';
        }
      }
    } catch (e) {
      error = 'Couldn\'t read your videos: $e';
    }
    scanning = false;
    final count = all.length;
    TaskCenter.instance.update(task.id,
        state: error == null ? TaskState.done : TaskState.failed,
        detail: error ?? '$count video${count == 1 ? '' : 's'} found',
        error: error);
    notifyListeners();
    save();
    _analyzedThisRun = 0;
    for (final c in all) {
      if (_info[c.key] == null || _thumbs[c.key] == null) _enqueue(c, front: false);
    }
  }

  // ---- Folders, drives and documents ----

  Future<PickedFolder?> addFolder() async {
    final r = await Engine.call<Map<dynamic, dynamic>>('pickFolder');
    if (r == null) return null;
    final f = PickedFolder(r['uri'] as String, r['name'] as String);
    if (!folders.any((e) => e.uri == f.uri)) folders.add(f);
    save();
    notifyListeners();
    await refresh();
    return f;
  }

  void removeFolder(PickedFolder f) {
    folders.removeWhere((e) => e.uri == f.uri);
    _trees.remove(f.uri);
    Engine.call('releaseFolder', {'uri': f.uri});
    save();
    notifyListeners();
  }

  /// Adds a file opened from the system picker, a share or "Open with".
  Future<Clip> addDocument(String uri) async {
    final existing = byUri(uri);
    if (existing != null) return existing;
    final clip = await Engine.describe(uri);
    _documents.removeWhere((d) => d.uri == uri);
    _documents.insert(0, clip);
    if (_documents.length > 50) _documents.removeLast();
    save();
    notifyListeners();
    return clip;
  }

  void removeDocument(Clip c) {
    _documents.removeWhere((d) => d.uri == c.uri);
    save();
    notifyListeners();
  }

  // ---- Analysis & thumbnails ----

  /// Called by tiles as they appear so visible clips are processed first.
  void ensureProcessed(Clip c) {
    if ((_info[c.key] != null && _thumbs[c.key] != null) || _failed.contains(c.key)) return;
    scheduleMicrotask(() => _enqueue(c, front: true));
  }

  /// Like [analyzeNow], but makes sure the probe carries the extra details the Info page shows.
  Future<ClipInfo> analyzeDetailed(Clip c) async {
    final cached = _info[c.key];
    if (cached != null && cached.hasDetails) return cached;
    try {
      final info = await Engine.analyze(c.uri);
      _info[c.key] = info;
      _failed.remove(c.key);
      save();
      _touch(c);
      return info;
    } catch (_) {
      if (cached != null) return cached;
      rethrow;
    }
  }

  /// Analyzes [c] right away (used before opening it).
  Future<ClipInfo> analyzeNow(Clip c) async {
    final cached = _info[c.key];
    if (cached != null) return cached;
    final info = await Engine.analyze(c.uri);
    _info[c.key] = info;
    _failed.remove(c.key);
    save();
    _touch(c);
    return info;
  }

  void _enqueue(Clip c, {required bool front}) {
    if (_queued.contains(c.key)) {
      if (front) {
        _queue.removeWhere((e) => e.key == c.key);
        _queue.addFirst(c);
      }
      return;
    }
    _queued.add(c.key);
    front ? _queue.addFirst(c) : _queue.addLast(c);
    _pump();
  }

  void _pump() {
    while (_inFlight < 3 && _queue.isNotEmpty) {
      final c = _queue.removeFirst();
      _inFlight++;
      _process(c).whenComplete(() {
        _inFlight--;
        _queued.remove(c.key);
        _analyzedThisRun++;
        _reportProgress();
        _pump();
      });
    }
  }

  void _reportProgress() {
    final remaining = _queue.length + _inFlight;
    if (remaining == 0) {
      if (TaskCenter.instance.byId('analyze') != null) {
        TaskCenter.instance.update('analyze',
            state: TaskState.done, progress: 1, detail: 'Previews ready for $_analyzedThisRun videos');
      }
      save();
      return;
    }
    final total = _analyzedThisRun + remaining;
    if (TaskCenter.instance.byId('analyze')?.active != true) {
      TaskCenter.instance.local('analyze', 'analyze', 'Preparing previews');
    }
    TaskCenter.instance.update('analyze',
        progress: _analyzedThisRun / total, detail: '$_analyzedThisRun of $total videos · reading formats');
  }

  Future<void> _process(Clip c) async {
    try {
      final info = _info[c.key] ?? await Engine.analyze(c.uri);
      _info[c.key] = info;
      if (!info.hasVideo) {
        _failed.add(c.key);
      } else if (_thumbs[c.key] == null) {
        final path = await Engine.thumbnail(c, info);
        if (path != null) {
          _thumbs[c.key] = path;
          SmartTags.instance.consider(c, path);
        } else {
          _failed.add(c.key);
        }
      }
    } catch (e) {
      _failed.add(c.key);
      debugPrint('analyze failed for ${c.name}: $e');
    }
    _touch(c);
    _maybePrepareAhead(c);
  }

  final Set<String> _checkedAhead = {};

  /// "Ahead of Time" mode: measure how fast this phone decodes a heavy new clip and, if it can't play it live,
  /// quietly start a smooth copy.
  Future<void> _maybePrepareAhead(Clip c) async {
    if (!settings.prepareAhead || !_checkedAhead.add(c.key)) return;
    final info = _info[c.key];
    if (info == null || !info.hasVideo || info.native || info.isProRes || c.isProViewCopy) return;
    if (copyOf(c) != null || (TaskCenter.instance.conversionFor(c.uri)?.active ?? false)) return;
    try {
      final fps = await Engine.decodeSpeed(c.uri);
      if (fps <= 0 || fps >= (info.fps > 0 ? info.fps : 30) * 1.1) return;   // plays fine live
      final ctx = navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) await ClipActions.startConversion(ctx, c, info, quiet: true);
    } catch (_) {}
  }

  void clearThumbnails() async {
    await Engine.call('clearThumbnails');
    _thumbs.clear();
    _failed.clear();
    save();
    notifyListeners();
    for (final c in all) {
      _enqueue(c, front: false);
    }
  }

  void markAsked(Clip c) {
    asked.add(c.key);
    save();
  }

  void _onTaskFinished(BgTask t) {
    if (t.type != 'convert' || t.state != TaskState.done || t.sourceUri == null || t.outputUri == null) return;
    final src = byUri(t.sourceUri!);
    if (src != null) copies[src.key] = t.outputUri!;
    save();
    refresh();
  }
}
