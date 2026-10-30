import 'dates.dart';
import 'engine.dart';
import 'tags.dart';

/// "Smart Search": understands plain phrases such as "4K ProRes from last week", "longer than 1 min" or
/// "needs conversion" and turns them into filters over what ProView knows about each clip (format,
/// resolution, frame rate, length, size, date, conversion status). Whatever words are left are matched
/// against file and folder names, forgiving typos. When the phone has looked at the preview frames (see
/// [SmartTags]) it also finds people, selfies, groups, written text and things like "dog" or "beach".
/// Everything runs on the phone; nothing is uploaded.
class SmartQuery {
  final List<bool Function(Clip, ClipInfo?, bool isCopy, bool hasCopy)> _tests = [];
  final List<bool Function(ClipTags? tags, bool favorite)> _tagTests = [];
  final List<String> words = [];

  /// Human description of each understood part, shown as chips ("4K", "ProRes", "Last week").
  final List<String> chips = [];

  bool get isEmpty => _tests.isEmpty && _tagTests.isEmpty && words.isEmpty;

  /// True when part of the question needs what the phone saw in the pictures.
  bool get needsTags => _tagTests.isNotEmpty || words.isNotEmpty;

  bool matches(Clip c, ClipInfo? info,
      {required bool isCopy, required bool hasCopy, ClipTags? tags, bool favorite = false}) {
    for (final t in _tests) {
      if (!t(c, info, isCopy, hasCopy)) return false;
    }
    for (final t in _tagTests) {
      if (!t(tags, favorite)) return false;
    }
    if (words.isEmpty) return true;
    final hay = _tokens('${c.name} ${c.folder}');
    final seen = tags == null ? const <String>[] : _tokens('${tags.labels.join(' ')} ${tags.text}');
    for (final w in words) {
      final stem = w.length > 3 && w.endsWith('s') ? w.substring(0, w.length - 1) : w;
      final ok = hay.any((t) => t.contains(w) || (w.length >= 4 && t.length >= 4 && _distance(t, w) <= 1)) ||
          seen.any((t) => t.length >= 3 && (t.startsWith(stem) || (stem.length >= 3 && stem.startsWith(t))));
      if (!ok) return false;
    }
    return true;
  }

  // -------------------------------------------------------------------------

  static const _stop = {
    'from', 'the', 'in', 'of', 'a', 'an', 'my', 'me', 'show', 'find', 'videos', 'video', 'clips', 'clip', 'files',
    'file', 'with', 'and', 'at', 'than', 'that', 'are', 'is', 'all', 'only', 'on', 'for', 'to', 'i', 'shot', 'taken',
    'made', 'recorded', 'have', 'has', 'any', 'some', 'ones', 'one', 'were', 'was',
  };

  static const _units = {
    's': 1.0, 'sec': 1.0, 'secs': 1.0, 'second': 1.0, 'seconds': 1.0,
    'm': 60.0, 'min': 60.0, 'mins': 60.0, 'minute': 60.0, 'minutes': 60.0,
    'h': 3600.0, 'hr': 3600.0, 'hrs': 3600.0, 'hour': 3600.0, 'hours': 3600.0,
  };
  static const _sizes = {'kb': 1e3, 'mb': 1e6, 'gb': 1e9};

  static SmartQuery parse(String text, {DateTime? now}) {
    final q = SmartQuery();
    now ??= DateTime.now();
    var s = ' ${text.toLowerCase().replaceAll(RegExp(r'[“”"]'), ' ')} ';

    // Removes the first match of [re] from the text and returns it.
    RegExpMatch? take(RegExp re) {
      final m = re.firstMatch(s);
      if (m != null) s = s.replaceRange(m.start, m.end, ' ');
      return m;
    }

    bool has(RegExp re) => take(re) != null;
    void add(String chip, bool Function(Clip, ClipInfo?, bool, bool) test) {
      q.chips.add(chip);
      q._tests.add(test);
    }

    void addTag(String chip, bool Function(ClipTags? tags, bool favorite) test) {
      q.chips.add(chip);
      q._tagTests.add(test);
    }

    // ---- people and pictures (needs the phone to have looked at the preview frames) ----
    if (has(RegExp(r'\b(?:no\s+(?:people|persons?|faces?|humans?|one)|nobody|empty|unpeopled)\b'))) {
      addTag('No people', (t, _) => t != null && !t.person);
    }
    if (has(RegExp(r'\bselfies?\b'))) addTag('Selfies', (t, _) => t?.selfie ?? false);
    if (has(RegExp(r'\b(?:groups?|crowd(?:s|ed)?|party|parties|gatherings?)\b'))) addTag('Groups', (t, _) => t?.group ?? false);
    if (has(RegExp(r'\b(?:people|persons?|humans?|man|men|woman|women|boys?|girls?|kids?|child(?:ren)?|friends?|family|guys?|someone|anyone|faces?)\b'))) {
      addTag('People', (t, _) => t?.person ?? false);
    }
    if (has(RegExp(r'\b(?:text|words?|writing|signs?|captions?|written|titles?|lettering)\b'))) {
      addTag('With text', (t, _) => t?.hasText ?? false);
    }
    if (has(RegExp(r'\b(?:favou?rites?|liked|hearted|loved|starred)\b'))) addTag('Favorites', (_, fav) => fav);

    // ---- length and size (before bare numbers are read as frame rates) ----
    final durRe = r'(\d+(?:\.\d+)?)\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?|[smh])\b';
    var m = take(RegExp(r'\b(?:longer|more|over|above|greater|bigger)\s*(?:than)?\s*' + durRe));
    if (m != null) {
      final sec = double.parse(m.group(1)!) * (_units[m.group(2)!] ?? 1);
      add('Longer than ${_fmtDuration(sec)}', (c, i, _, _) => (i?.duration ?? c.durationMs / 1000) > sec);
    }
    m = take(RegExp(r'\b(?:shorter|less|under|below|within)\s*(?:than)?\s*' + durRe));
    if (m != null) {
      final sec = double.parse(m.group(1)!) * (_units[m.group(2)!] ?? 1);
      add('Shorter than ${_fmtDuration(sec)}', (c, i, _, _) {
        final d = i?.duration ?? c.durationMs / 1000;
        return d > 0 && d < sec;
      });
    }
    const sizeRe = r'(\d+(?:\.\d+)?)\s*(kb|mb|gb)\b';
    m = take(RegExp(r'\b(?:bigger|larger|over|above|more|heavier)\s*(?:than)?\s*' + sizeRe));
    if (m != null) {
      final bytes = double.parse(m.group(1)!) * _sizes[m.group(2)!]!;
      add('Over ${m.group(1)} ${m.group(2)!.toUpperCase()}', (c, _, _, _) => c.size > bytes);
    }
    m = take(RegExp(r'\b(?:smaller|less|under|below|lighter)\s*(?:than)?\s*' + sizeRe));
    if (m != null) {
      final bytes = double.parse(m.group(1)!) * _sizes[m.group(2)!]!;
      add('Under ${m.group(1)} ${m.group(2)!.toUpperCase()}', (c, _, _, _) => c.size > 0 && c.size < bytes);
    }
    if (has(RegExp(r'\b(?:long|lengthy)\b'))) {
      add('Long', (c, i, _, _) => (i?.duration ?? c.durationMs / 1000) >= 60);
    }
    if (has(RegExp(r'\b(?:short|quick|brief)\b'))) {
      add('Short', (c, i, _, _) {
        final d = i?.duration ?? c.durationMs / 1000;
        return d > 0 && d <= 15;
      });
    }
    if (has(RegExp(r'\b(?:large|huge|biggest|heavy)\b'))) add('Large files', (c, _, _, _) => c.size >= 1e9);
    if (has(RegExp(r'\b(?:tiny|small|smallest)\b'))) add('Small files', (c, _, _, _) => c.size > 0 && c.size < 1e8);

    // ---- resolution ----
    String? res;
    if (has(RegExp(r'\b(?:8k|4320p)\b'))) {
      res = '8K';
    } else if (has(RegExp(r'\b(?:4k|uhd|ultra\s*hd|2160p)\b'))) {
      res = '4K';
    } else if (has(RegExp(r'\b(?:2k|1440p)\b'))) {
      res = '1440p';
    } else if (has(RegExp(r'\b(?:1080p|full\s*hd|fhd)\b'))) {
      res = '1080p';
    } else if (has(RegExp(r'\b720p\b'))) {
      res = '720p';
    }
    if (res != null) {
      final label = res;
      add(label, (c, i, _, _) => i != null && i.resolutionLabel == label);
    }

    // ---- frame rate ----
    m = take(RegExp(r'\b(\d{2,3}(?:\.\d+)?)\s*(?:fps|frames)\b')) ?? take(RegExp(r'\b(24|25|30|48|50|60|120|240)\s*p\b'));
    if (m != null) {
      final fps = double.parse(m.group(1)!);
      add('${m.group(1)} fps', (c, i, _, _) => i != null && (i.fps - fps).abs() < 1.6);
    }

    // ---- format ----
    if (has(RegExp(r'\bpro\s*res\b|\bprores\b'))) add('ProRes', (c, i, _, _) => i?.codec == 'prores');
    if (has(RegExp(r'\b(?:hevc|h\.?265|x265)\b'))) add('HEVC', (c, i, _, _) => i?.codec == 'hevc');
    if (has(RegExp(r'\b(?:h\.?264|avc|x264)\b'))) add('H.264', (c, i, _, _) => i?.codec == 'h264');
    if (has(RegExp(r'\bdnx(?:hd|hr)?\b'))) add('DNx', (c, i, _, _) => i?.codec == 'dnxhd');
    if (has(RegExp(r'\bcine\s*form\b'))) add('CineForm', (c, i, _, _) => i?.codec == 'cfhd');
    if (has(RegExp(r'4:?2:?2\b'))) add('4:2:2', (c, i, _, _) => i?.chroma == '4:2:2');
    if (has(RegExp(r'\b10[\s-]?bit\b'))) add('10-bit', (c, i, _, _) => (i?.bitDepth ?? 8) >= 10);
    if (has(RegExp(r'\bhdr\b'))) add('HDR', (c, i, _, _) => i?.isHdr ?? false);
    if (has(RegExp(r'\b(?:portrait|vertical)\b'))) add('Portrait', (c, i, _, _) => i != null && i.displayHeight > i.displayWidth);
    if (has(RegExp(r'\b(?:landscape|horizontal)\b'))) add('Landscape', (c, i, _, _) => i != null && i.displayWidth >= i.displayHeight);
    if (has(RegExp(r'\b(?:alpha|transparent|transparency)\b'))) add('Alpha', (c, i, _, _) => i?.alpha ?? false);
    // ---- sound ----
    if (has(RegExp(r'\b(?:no\s+(?:audio|sound)|silent|muted?|without\s+(?:audio|sound))\b'))) {
      add('No audio', (c, i, _, _) => i != null && i.hasVideo && i.audioChannels == 0);
    } else if (has(RegExp(r'\b(?:with\s+)?(?:audio|sound)\b'))) {
      add('Has audio', (c, i, _, _) => (i?.audioChannels ?? 0) > 0);
    }
    if (has(RegExp(r'\bslow\s*-?\s*mo(?:tion)?\b|\bslomo\b'))) add('Slow motion', (c, i, _, _) => (i?.fps ?? 0) >= 100);
    // ---- status ----
    if (has(RegExp(r'\b(?:needs?\s*conver\w*|unplayable|slow|heavy|choppy|laggy|pro\s*formats?|problem\w*)\b'))) {
      add('Needs ProView', (c, i, copy, _) => i != null && !i.native && !copy);
    }
    if (has(RegExp(r'\b(?:converted|conversions?|copies|copy)\b'))) add('Converted', (c, i, copy, _) => copy);
    if (has(RegExp(r'\b(?:plays?\s*natively|playable|smooth|native|compatible)\b'))) {
      add('Plays natively', (c, i, _, _) => i?.native ?? false);
    }

    // ---- dates ----
    final today = DateTime(now.year, now.month, now.day);
    void range(String chip, DateTime from, DateTime to) =>
        add(chip, (c, _, _, _) => c.modified > 0 && !clipDate(c).isBefore(from) && clipDate(c).isBefore(to));
    if (has(RegExp(r'\btoday\b'))) {
      range('Today', today, today.add(const Duration(days: 1)));
    } else if (has(RegExp(r'\byesterday\b'))) {
      range('Yesterday', today.subtract(const Duration(days: 1)), today);
    } else if (has(RegExp(r'\blast\s*week\b'))) {
      final monday = today.subtract(Duration(days: today.weekday - 1));
      range('Last week', monday.subtract(const Duration(days: 7)), monday);
    } else if (has(RegExp(r'\bthis\s*week\b'))) {
      final monday = today.subtract(Duration(days: today.weekday - 1));
      range('This week', monday, today.add(const Duration(days: 1)));
    } else if (has(RegExp(r'\blast\s*month\b'))) {
      final first = DateTime(now.year, now.month, 1);
      range('Last month', DateTime(first.year, first.month - 1, 1), first);
    } else if (has(RegExp(r'\bthis\s*month\b'))) {
      range('This month', DateTime(now.year, now.month, 1), today.add(const Duration(days: 1)));
    } else if ((m = take(RegExp(r'\b(?:last|past)\s*(\d+)\s*days?\b'))) != null) {
      final n = int.parse(m!.group(1)!);
      range('Last $n days', today.subtract(Duration(days: n - 1)), today.add(const Duration(days: 1)));
    } else {
      // A month name, optionally with a year ("october", "march 2025"), or just a year.
      final names = List.generate(12, (i) => monthName(i + 1).toLowerCase());
      for (var mi = 0; mi < 12; mi++) {
        final full = names[mi];
        final re = RegExp('\\b(?:$full|${full.substring(0, 3)})\\b(?:\\s*(\\d{4}))?');
        final hit = re.firstMatch(s);
        if (hit != null) {
          s = s.replaceRange(hit.start, hit.end, ' ');
          final year = hit.group(1) != null ? int.parse(hit.group(1)!) : null;
          final chip = '${monthName(mi + 1)}${year != null ? ' $year' : ''}';
          add(chip, (c, _, _, _) {
            if (c.modified <= 0) return false;
            final d = clipDate(c);
            return d.month == mi + 1 && (year == null || d.year == year);
          });
          break;
        }
      }
      m = take(RegExp(r'\b(20\d{2})\b'));
      if (m != null) {
        final y = int.parse(m.group(1)!);
        add('$y', (c, _, _, _) => c.modified > 0 && clipDate(c).year == y);
      }
    }

    // ---- whatever is left matches names ----
    for (final w in _tokens(s)) {
      if (w.length >= 2 && !_stop.contains(w)) q.words.add(w);
    }
    for (final w in q.words) {
      q.chips.add('“$w”');
    }
    return q;
  }

  static List<String> _tokens(String s) =>
      s.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((t) => t.isNotEmpty).toList();

  static String _fmtDuration(double sec) {
    if (sec >= 3600) return '${_trim(sec / 3600)} hr';
    if (sec >= 60) return '${_trim(sec / 60)} min';
    return '${_trim(sec)} s';
  }

  static String _trim(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  /// Levenshtein distance (typo tolerance for names).
  static int _distance(String a, String b) {
    if (a == b) return 0;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = [cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost].reduce((x, y) => x < y ? x : y);
      }
      prev = cur;
    }
    return prev[b.length];
  }
}

/// Example phrases offered under the search field.
const searchExamples = [
  'People',
  'Selfies',
  'Favorites',
  'With text',
  'Slow motion',
  '4K from this month',
  'ProRes longer than 1 min',
  'Needs conversion',
  'HEVC 4:2:2 60 fps',
  'Yesterday',
  'Converted copies',
  'Over 1 GB',
  'Portrait 4K',
];
