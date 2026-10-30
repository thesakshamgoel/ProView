import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'engine.dart';
import 'library.dart';
import 'tasks.dart';

/// What the phone recognised in a clip's preview frame: things, faces and written words.
class ClipTags {
  final List<String> labels;

  /// Share of the picture's width taken by each face found.
  final List<double> faces;
  final String text;
  const ClipTags({this.labels = const [], this.faces = const [], this.text = ''});

  static const _peopleLabels = {
    'person', 'people', 'selfie', 'smile', 'face', 'crowd', 'child', 'toddler', 'baby', 'boy', 'girl', 'man', 'woman',
    'dance', 'team', 'audience',
  };
  static const _groupLabels = {'crowd', 'team', 'audience', 'party', 'event'};

  bool get person => faces.isNotEmpty || labels.any(_peopleLabels.contains);
  bool get selfie => (faces.length == 1 && faces.first >= 0.28) || labels.contains('selfie');
  bool get group => faces.length >= 3 || labels.any(_groupLabels.contains);
  bool get hasText => text.trim().length >= 4;

  Map<String, dynamic> toJson() => {'l': labels, 'f': faces, 't': text};

  factory ClipTags.fromJson(Map<String, dynamic> j) => ClipTags(
        labels: (j['l'] as List? ?? const []).cast<String>(),
        faces: (j['f'] as List? ?? const []).map((e) => (e as num).toDouble()).toList(),
        text: j['t'] as String? ?? '',
      );
}

/// Quietly looks at every clip's preview frame, one at a time and at low priority, and remembers what it saw so
/// Smart Search can find people, places and things. Everything runs on the phone.
class SmartTags extends ChangeNotifier {
  SmartTags._();
  static final instance = SmartTags._();

  final Map<String, ClipTags> _tags = {};
  final Queue<(Clip, String)> _queue = Queue();
  final Set<String> _queued = {};
  File? _file;
  Timer? _saveTimer;
  bool _running = false;
  int _done = 0;
  int _failures = 0;

  /// True once the phone's image models refused to run (several failures in a row); search then falls back to
  /// names, formats and dates, and Settings says so instead of pretending.
  bool unavailable = false;

  /// While above zero (a video is playing) the tagger waits.
  int pauses = 0;

  bool get enabled => Library.instance.settings.smartTags && !unavailable;
  int get pending => _queue.length + (_running ? 1 : 0);
  int get tagged => _tags.length;
  ClipTags? of(Clip c) => _tags[c.key];

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}/tags.json');
    try {
      if (await _file!.exists()) {
        final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        (j['tags'] as Map? ?? {}).forEach((k, v) => _tags[k as String] = ClipTags.fromJson(Map<String, dynamic>.from(v as Map)));
      }
    } catch (e) {
      debugPrint('tags unreadable, starting fresh: $e');
    }
    notifyListeners();
  }

  /// Queues every clip that has a preview but no tags yet (after a scan, or when the setting is switched on).
  void scan() {
    if (!enabled) return;
    final lib = Library.instance;
    for (final c in lib.all) {
      final thumb = lib.thumb(c);
      if (thumb != null) consider(c, thumb);
    }
  }

  void consider(Clip c, String thumbPath) {
    if (!enabled || _tags.containsKey(c.key) || !_queued.add(c.key)) return;
    _queue.add((c, thumbPath));
    _run();
  }

  /// Try again (after switching the setting back on).
  void retry() {
    unavailable = false;
    _failures = 0;
    scan();
  }

  /// Forget everything (turning the feature off and wiping what it learnt).
  void clear() {
    _queue.clear();
    _queued.clear();
    _tags.clear();
    _save();
    notifyListeners();
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    var total = 0;
    try {
      while (_queue.isNotEmpty) {
        if (!enabled) {
          _queue.clear();
          _queued.clear();
          break;
        }
        if (pauses > 0) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        total = _done + _queue.length;
        final (clip, path) = _queue.removeFirst();
        try {
          final m = await Engine.call<Map<dynamic, dynamic>>('tagImage', {'path': path});
          _tags[clip.key] = m == null
              ? const ClipTags()
              : ClipTags(
                  labels: (m['labels'] as List? ?? const []).cast<String>(),
                  faces: (m['faces'] as List? ?? const []).map((e) => (e as num).toDouble()).toList(),
                  text: m['text'] as String? ?? '',
                );
          _failures = 0;
        } catch (e) {
          // Not remembered as "done": a broken model must not look like a clip with nothing in it.
          debugPrint('tagging failed for ${clip.name}: $e');
          if (++_failures >= 3) {
            unavailable = true;
            _queue.clear();
            _queued.clear();
            TaskCenter.instance.update('tags',
                state: TaskState.failed, detail: 'This phone can\'t run image search', error: '$e');
            break;
          }
        }
        _queued.remove(clip.key);
        _done++;
        _report(total);
        _save();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    } finally {
      _running = false;
      if (_done > 0 && _queue.isEmpty && TaskCenter.instance.byId('tags') != null) {
        TaskCenter.instance.update('tags',
            state: TaskState.done, progress: 1, detail: 'Search can now find people and things in $_done videos');
        _done = 0;
      }
      notifyListeners();
    }
  }

  void _report(int total) {
    if (_done % 4 != 0 && _queue.isNotEmpty) return;
    if (TaskCenter.instance.byId('tags')?.active != true) {
      TaskCenter.instance.local('tags', 'analyze', 'Learning what\'s in your videos');
    }
    TaskCenter.instance.update('tags',
        progress: total == 0 ? 0 : _done / total, detail: '$_done of $total videos · finding people and things');
    notifyListeners();
  }

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), () async {
      final f = _file;
      if (f == null) return;
      final known = Library.instance.all.map((c) => c.key).toSet();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({
        'tags': {
          for (final e in _tags.entries)
            if (known.contains(e.key)) e.key: e.value.toJson()
        }
      }));
      await tmp.rename(f.path);
    });
  }

  /// The things seen most often across the library, for suggestion chips.
  List<String> topLabels({int limit = 8}) {
    const generic = {'sky', 'room', 'cloud', 'tree', 'plant', 'sleeve', 'sun', 'daytime', 'fun', 'event', 'darkness', 'night'};
    final counts = <String, int>{};
    for (final t in _tags.values) {
      for (final l in t.labels) {
        if (!generic.contains(l) && !ClipTags._peopleLabels.contains(l)) counts[l] = (counts[l] ?? 0) + 1;
      }
    }
    final entries = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(limit).map((e) => e.key).toList();
  }

  bool get anyPeople => _tags.values.any((t) => t.person);
  bool get anyText => _tags.values.any((t) => t.hasText);
}
