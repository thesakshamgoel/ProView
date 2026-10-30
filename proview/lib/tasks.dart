import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine.dart';

enum TaskState { queued, running, saving, done, failed, cancelled }

class BgTask {
  final String id;
  final String type; // convert | download | scan | analyze
  String title;
  String detail;
  TaskState state;
  double? progress;
  double fps;
  double eta;
  String? sourceUri;
  String? outputUri;
  String? outputName;
  int outputSize;
  String? error;
  String? encoder;
  int bitDepth;
  final DateTime createdAt;

  BgTask({
    required this.id,
    required this.type,
    required this.title,
    this.detail = '',
    this.state = TaskState.running,
    this.progress,
    this.fps = 0,
    this.eta = -1,
    this.outputSize = 0,
    this.bitDepth = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get active => state == TaskState.queued || state == TaskState.running || state == TaskState.saving;
}

/// All background work, from both the native side (conversions, downloads) and Dart (scans).
class TaskCenter extends ChangeNotifier {
  TaskCenter._();
  static final instance = TaskCenter._();

  final Map<String, BgTask> _tasks = {};
  final _finished = StreamController<BgTask>.broadcast();

  /// Ticks only when a conversion or download changes. Library tiles watch this instead of the whole task list,
  /// so background previews and tagging (which update many times a second) don't repaint the grid.
  final convertTick = ValueNotifier<int>(0);
  Timer? _throttle;
  StreamSubscription? _sub;

  /// Emits a task once when it reaches done / failed (used for toasts).
  Stream<BgTask> get finished => _finished.stream;

  List<BgTask> get all => _tasks.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  List<BgTask> get active => all.where((t) => t.active).toList();
  int get activeCount => _tasks.values.where((t) => t.active).length;

  BgTask? byId(String id) => _tasks[id];

  /// The running or finished conversion for a source clip, if any.
  BgTask? conversionFor(String uri) {
    final matches = _tasks.values.where((t) => t.type == 'convert' && t.sourceUri == uri).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return matches.isEmpty ? null : matches.first;
  }

  void start() {
    _sub ??= Engine.tasks.receiveBroadcastStream().listen((event) {
      final m = Map<String, dynamic>.from(event as Map);
      final id = m['id'] as String;
      if (m['removed'] == true) {
        _tasks.remove(id);
        notifyListeners();
        return;
      }
      final previous = _tasks[id]?.state;
      final t = _tasks.putIfAbsent(
        id,
        () => BgTask(
          id: id,
          type: m['type'] as String? ?? 'convert',
          title: m['title'] as String? ?? 'Task',
          createdAt: m['createdAt'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch((m['createdAt'] as num).toInt()),
        ),
      );
      if (m['title'] != null) t.title = m['title'] as String;
      if (m['detail'] != null) t.detail = m['detail'] as String;
      if (m['state'] != null) t.state = TaskState.values.byName(m['state'] as String);
      if (m['progress'] != null) t.progress = (m['progress'] as num).toDouble();
      if (m['fps'] != null) t.fps = (m['fps'] as num).toDouble();
      if (m['eta'] != null) t.eta = (m['eta'] as num).toDouble();
      if (m['sourceUri'] != null) t.sourceUri = m['sourceUri'] as String;
      if (m['outputUri'] != null) t.outputUri = m['outputUri'] as String;
      if (m['outputName'] != null) t.outputName = m['outputName'] as String;
      if (m['outputSize'] != null) t.outputSize = (m['outputSize'] as num).toInt();
      if (m['error'] != null) t.error = m['error'] as String;
      if (m['encoder'] != null) t.encoder = m['encoder'] as String;
      if (m['bitDepth'] != null) t.bitDepth = (m['bitDepth'] as num).toInt();
      if (previous != t.state && (t.state == TaskState.done || t.state == TaskState.failed)) _finished.add(t);
      convertTick.value++;
      notifyListeners();
    });
  }

  // ---- Dart-side tasks ----

  BgTask local(String id, String type, String title, {String detail = ''}) {
    final t = _tasks[id] ?? BgTask(id: id, type: type, title: title);
    t
      ..title = title
      ..detail = detail
      ..state = TaskState.running
      ..progress = null;
    _tasks[id] = t;
    notifyListeners();
    if (type == 'convert') convertTick.value++;
    return t;
  }

  void update(String id, {String? detail, double? progress, TaskState? state, String? error}) {
    final t = _tasks[id];
    if (t == null) return;
    if (detail != null) t.detail = detail;
    if (progress != null) t.progress = progress;
    if (error != null) t.error = error;
    if (state != null) {
      final changed = t.state != state;
      t.state = state;
      final background = t.type == 'scan' || t.type == 'analyze';
      if (changed && (state == TaskState.done || state == TaskState.failed) && !background) {
        _finished.add(t);
      }
      // Housekeeping tasks tidy themselves away once they've finished; conversions and downloads stay.
      if (changed && state == TaskState.done && background) {
        Future.delayed(const Duration(seconds: 4), () {
          if (_tasks[id]?.state == TaskState.done) dismiss(id);
        });
      }
    }
    if (t.type == 'convert') convertTick.value++;
    // Progress ticks of housekeeping tasks arrive for every clip; a few redraws a second is plenty.
    if (state == null && (t.type == 'scan' || t.type == 'analyze')) {
      _throttle ??= Timer(const Duration(milliseconds: 300), () {
        _throttle = null;
        notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  void dismiss(String id) {
    final t = _tasks.remove(id);
    if (t != null && (t.type == 'convert' || t.type == 'download')) {
      Engine.call('dismissTask', {'taskId': id});
    }
    if (t?.type == 'convert') convertTick.value++;
    notifyListeners();
  }

  void clearFinished() {
    for (final t in all.where((t) => !t.active)) {
      dismiss(t.id);
    }
  }
}
