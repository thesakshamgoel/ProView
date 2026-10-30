import 'package:flutter/foundation.dart';

import 'engine.dart';

/// Which clips are selected while the library is in selection mode (long-press a clip, then tap or drag over
/// others). Each clip has its own flag, so ticking one tile redraws one tile.
class Selection extends ChangeNotifier {
  Selection._();
  static final instance = Selection._();

  final Map<String, Clip> _items = {};
  final Map<String, ValueNotifier<bool>> _flags = {};

  /// True while a long-press drag is sweeping over tiles.
  bool dragging = false;

  bool get active => _items.isNotEmpty || _armed;
  bool _armed = false;
  int get count => _items.length;
  List<Clip> get clips => _items.values.toList();

  bool contains(Clip c) => _items.containsKey(c.key);
  ValueNotifier<bool> flag(Clip c) => _flags.putIfAbsent(c.key, () => ValueNotifier(false));

  /// Enters selection mode with [c] ticked and lets a following drag extend it.
  void begin(Clip c) {
    _armed = true;
    dragging = true;
    add(c);
    notifyListeners();
  }

  void add(Clip c) {
    if (_items.containsKey(c.key)) return;
    _items[c.key] = c;
    flag(c).value = true;
    notifyListeners();
  }

  void remove(Clip c) {
    if (_items.remove(c.key) == null) return;
    flag(c).value = false;
    if (_items.isEmpty) _armed = false;
    notifyListeners();
  }

  void toggle(Clip c) => contains(c) ? remove(c) : add(c);

  void selectAll(Iterable<Clip> clips) {
    for (final c in clips) {
      if (!_items.containsKey(c.key)) {
        _items[c.key] = c;
        flag(c).value = true;
      }
    }
    _armed = true;
    notifyListeners();
  }

  /// Empties the selection. With [armed] the mode stays on (so "Deselect All" doesn't close the bars).
  void clear({bool armed = false}) {
    for (final c in _items.values) {
      flag(c).value = false;
    }
    _items.clear();
    _armed = armed;
    dragging = false;
    notifyListeners();
  }
}
