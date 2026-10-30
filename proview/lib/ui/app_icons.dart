// ignore_for_file: constant_identifier_names
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';

/// ProView's icon set: Phosphor's rounded, evenly weighted glyphs (regular for resting state, fill for
/// selected or emphasised, bold for small controls). One place to change an icon for the whole app.
/// Glyphs come from the Phosphor font that ships with the `phosphor_flutter` package. Only its font files
/// are used (its Dart code doesn't build with current Flutter), so these are plain IconData constants.
const _pkg = 'phosphor_flutter';

class AppIcons {
  // Navigation and toolbar
  static const IconData play_rectangle = IconData(0xe58c, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData play_rectangle_fill = IconData(0xe58c, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData folder = IconData(0xe24a, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData folder_fill = IconData(0xe24a, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData folder_badge_plus = IconData(0xe258, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData clock = IconData(0xe19a, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData clock_fill = IconData(0xe19a, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData gear = IconData(0xe270, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData gear_solid = IconData(0xe270, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData search = IconData(0xe30c, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData plus = IconData(0xe3d4, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData add = IconData(0xe3d4, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData ellipsis = IconData(0xe1fe, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData xmark = IconData(0xe4f6, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData chevron_forward = IconData(0xe13a, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData chevron_back = IconData(0xe138, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData sort = IconData(0xe444, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData calendar = IconData(0xe7b4, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);

  // Status
  static const IconData checkmark = IconData(0xe182, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData checkmark_alt = IconData(0xe182, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData checkmark_circle = IconData(0xe184, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData checkmark_circle_fill = IconData(0xe184, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData checkmark_seal = IconData(0xe606, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData checkmark_seal_fill = IconData(0xe606, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData exclamationmark_triangle = IconData(0xe4e0, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData exclamationmark_triangle_fill = IconData(0xe4e0, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData exclamationmark_octagon_fill = IconData(0xe4e4, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData info_circle = IconData(0xe2ce, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData info_circle_fill = IconData(0xe2ce, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData arrow_2_circlepath = IconData(0xe094, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData minus_circle = IconData(0xe32c, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData lock_fill = IconData(0xe2fa, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData bolt_fill = IconData(0xe2de, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData bolt_slash_fill = IconData(0xe2e0, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData speedometer = IconData(0xe628, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData memories = IconData(0xe610, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData sparkles = IconData(0xe6a2, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);

  // Content
  static const IconData film = IconData(0xe792, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData wand_stars = IconData(0xe6b6, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData archivebox_fill = IconData(0xe2a0, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData cloud_fill = IconData(0xe1aa, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData cloud_download = IconData(0xe1ac, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData photo_on_rectangle = IconData(0xe2ca, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData share = IconData(0xeaf0, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData chat_bubble_2 = IconData(0xe16c, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);

  // Player
  static const IconData play_fill = IconData(0xe3d0, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData pause_fill = IconData(0xe39e, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData forward_fill = IconData(0xe6a6, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData backward_fill = IconData(0xe6a8, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData forward_end_fill = IconData(0xe5a6, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData backward_end_fill = IconData(0xe5a4, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData speaker_2_fill = IconData(0xe44a, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData speaker_slash_fill = IconData(0xe45a, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData arrow_up_left_arrow_down_right = IconData(0xe0a6, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData arrow_down_right_arrow_up_left = IconData(0xe09e, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData arrow_counterclockwise = IconData(0xe038, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  // Library tools
  static const IconData heart = IconData(0xe2a8, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData heart_fill = IconData(0xe2a8, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData trash = IconData(0xe4a6, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData trash_fill = IconData(0xe4a6, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData restore = IconData(0xe038, fontFamily: 'PhosphorBold', fontPackage: _pkg, matchTextDirection: true);
  static const IconData brightness = IconData(0xe472, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData brightness_low = IconData(0xe474, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData volume_low = IconData(0xe44c, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData volume_off = IconData(0xe45a, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData volume_high = IconData(0xe44a, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData people = IconData(0xe4d6, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData person = IconData(0xe4c2, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData tag = IconData(0xe478, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData text_aa = IconData(0xe6ee, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData select_all = IconData(0xe53a, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData check_circle_fill = IconData(0xe184, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData circle = IconData(0xe18a, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData copy = IconData(0xe1ca, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData map_pin = IconData(0xe316, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData camera = IconData(0xe10e, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData speaker = IconData(0xe44a, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData clock_history = IconData(0xe1a0, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData hard_drive = IconData(0xe29e, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData lightning = IconData(0xe2de, fontFamily: 'PhosphorFill', fontPackage: _pkg, matchTextDirection: true);
  static const IconData stack = IconData(0xe466, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData swap = IconData(0xe098, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData sparkle = IconData(0xe6a2, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);
  static const IconData eye = IconData(0xe220, fontFamily: 'PhosphorRegular', fontPackage: _pkg, matchTextDirection: true);

  // The ten-second skip glyphs have no Phosphor equivalent; the system ones are kept.
  static const IconData gobackward_10 = CupertinoIcons.gobackward_10;
  static const IconData goforward_10 = CupertinoIcons.goforward_10;
}
