import 'engine.dart';

/// How the library is ordered.
enum LibrarySort {
  newest('Newest First'),
  oldest('Oldest First'),
  name('Name'),
  largest('Largest'),
  longest('Longest');

  final String label;
  const LibrarySort(this.label);

  /// Date orders get "Today / Yesterday / October" sections; the others are one flat grid.
  bool get byDate => this == newest || this == oldest;
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November',
  'December'
];
const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

String monthName(int month) => _months[month - 1];

/// Section title for a clip's date, relative to [now] ("Today", "Yesterday", "Tuesday", "October", "March 2025").
String dateSection(DateTime d, DateTime now) {
  final day = DateTime(d.year, d.month, d.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return _weekdays[d.weekday - 1];
  if (d.year == now.year && d.month == now.month) return 'Earlier This Month';
  if (d.year == now.year) return _months[d.month - 1];
  return '${_months[d.month - 1]} ${d.year}';
}

DateTime clipDate(Clip c) => DateTime.fromMillisecondsSinceEpoch(c.modified > 0 ? c.modified : 0);

List<Clip> sortClips(List<Clip> clips, LibrarySort sort, {double Function(Clip)? duration}) {
  final out = List<Clip>.of(clips);
  switch (sort) {
    case LibrarySort.newest:
      out.sort((a, b) => b.modified.compareTo(a.modified));
    case LibrarySort.oldest:
      out.sort((a, b) => a.modified.compareTo(b.modified));
    case LibrarySort.name:
      out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    case LibrarySort.largest:
      out.sort((a, b) => b.size.compareTo(a.size));
    case LibrarySort.longest:
      final d = duration ?? (c) => c.durationMs / 1000.0;
      out.sort((a, b) => d(b).compareTo(d(a)));
  }
  return out;
}

/// Splits (already date-sorted) clips into titled sections, keeping their order.
List<(String, List<Clip>)> groupByDate(List<Clip> sorted, DateTime now) {
  final groups = <(String, List<Clip>)>[];
  for (final c in sorted) {
    final title = dateSection(clipDate(c), now);
    if (groups.isEmpty || groups.last.$1 != title) {
      groups.add((title, <Clip>[]));
    }
    groups.last.$2.add(c);
  }
  return groups;
}
