import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Design tokens in the style of iOS 26/27 (Liquid Glass): system colours, a Pro blue taken from the
/// ProView mark, and an SF-like type scale set in Inter.
class Palette {
  final Brightness brightness;
  final Color background;
  final Color groupedBackground;
  final Color surface;
  final Color surfaceRaised;
  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;
  final Color separator;
  final Color fill;
  final Color accent;
  final Color accentSoft;
  final Color green;
  final Color red;
  final Color orange;
  final Color purple;
  final Color teal;

  /// Glass material: tint over the blurred backdrop, rim highlight and shadow.
  final Color glassTint;
  final Color glassRim;
  final Color glassShadow;

  const Palette._({
    required this.brightness,
    required this.background,
    required this.groupedBackground,
    required this.surface,
    required this.surfaceRaised,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.separator,
    required this.fill,
    required this.accent,
    required this.accentSoft,
    required this.green,
    required this.red,
    required this.orange,
    required this.purple,
    required this.teal,
    required this.glassTint,
    required this.glassRim,
    required this.glassShadow,
  });

  bool get isDark => brightness == Brightness.dark;

  static const light = Palette._(
    brightness: Brightness.light,
    background: Color(0xFFFFFFFF),
    groupedBackground: Color(0xFFFFFFFF),
    surface: Color(0xFFF3F4F7),
    surfaceRaised: Color(0xFFF3F4F7),
    label: Color(0xFF000000),
    secondaryLabel: Color(0x993C3C43),
    tertiaryLabel: Color(0x4D3C3C43),
    separator: Color(0x333C3C43),
    fill: Color(0x14787880),
    accent: Color(0xFF2C6BF2),
    accentSoft: Color(0x1A2C6BF2),
    green: Color(0xFF34C759),
    red: Color(0xFFFF3B30),
    orange: Color(0xFFFF9500),
    purple: Color(0xFFAF52DE),
    teal: Color(0xFF30B0C7),
    glassTint: Color(0x8CFFFFFF),
    glassRim: Color(0xFFFFFFFF),
    glassShadow: Color(0x1F000000),
  );

  static const dark = Palette._(
    brightness: Brightness.dark,
    background: Color(0xFF000000),
    groupedBackground: Color(0xFF000000),
    surface: Color(0xFF1C1C1E),
    surfaceRaised: Color(0xFF2C2C2E),
    label: Color(0xFFFFFFFF),
    secondaryLabel: Color(0x99EBEBF5),
    tertiaryLabel: Color(0x4DEBEBF5),
    separator: Color(0x40545458),
    fill: Color(0x2E787880),
    accent: Color(0xFF4C8DFF),
    accentSoft: Color(0x294C8DFF),
    green: Color(0xFF30D158),
    red: Color(0xFFFF453A),
    orange: Color(0xFFFF9F0A),
    purple: Color(0xFFBF5AF2),
    teal: Color(0xFF40C8E0),
    glassTint: Color(0x3D3A3A3C),
    glassRim: Color(0xFFFFFFFF),
    glassShadow: Color(0x66000000),
  );

  static Palette of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// The ProView brand gradient (from the logo): bright cyan-blue to deep blue.
const kBrandGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF63B3FF), Color(0xFF2F6BF2), Color(0xFF1F55E6)],
  stops: [0, 0.55, 1],
);

const kFont = 'Inter';

/// Standard spacing, so every screen lines up the same way.
class Insets {
  static const double page = 20; // left/right margin of titles and cards
  static const double card = 16; // inner padding of cards and rows
  static const double gap = 12;
  static const double radius = 26; // cards
  static const double radiusSmall = 14;

  /// Space reserved under scrolling content for the floating tab bar.
  static double tabBarClearance(BuildContext context) => MediaQuery.paddingOf(context).bottom + 96;
}

class TextStyles {
  static TextStyle largeTitle(Palette p) => TextStyle(
      fontFamily: kFont, fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -1.0, height: 1.12, color: p.label);
  static TextStyle title1(Palette p) => TextStyle(
      fontFamily: kFont, fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.8, height: 1.15, color: p.label);
  static TextStyle title2(Palette p) => TextStyle(
      fontFamily: kFont, fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.5, height: 1.2, color: p.label);
  static TextStyle title3(Palette p) => TextStyle(
      fontFamily: kFont, fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.4, height: 1.2, color: p.label);
  static TextStyle headline(Palette p) => TextStyle(
      fontFamily: kFont, fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.4, height: 1.3, color: p.label);
  static TextStyle body(Palette p) => TextStyle(
      fontFamily: kFont, fontSize: 17, fontWeight: FontWeight.w400, letterSpacing: -0.4, height: 1.3, color: p.label);
  static TextStyle callout(Palette p) => TextStyle(
      fontFamily: kFont, fontSize: 16, fontWeight: FontWeight.w400, letterSpacing: -0.3, height: 1.3, color: p.label);
  static TextStyle subhead(Palette p) => TextStyle(
      fontFamily: kFont, fontSize: 15, fontWeight: FontWeight.w400, letterSpacing: -0.2, height: 1.3, color: p.label);
  static TextStyle footnote(Palette p) => TextStyle(
      fontFamily: kFont, fontSize: 13, fontWeight: FontWeight.w400, letterSpacing: -0.1, height: 1.3,
      color: p.secondaryLabel);
  static TextStyle caption(Palette p) => TextStyle(
      fontFamily: kFont, fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0, height: 1.2,
      color: p.secondaryLabel);
  static TextStyle sectionHeader(Palette p) => TextStyle(
      fontFamily: kFont, fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.4, height: 1.2, color: p.label);
}

/// iOS-style spring curves used for every movement in the app.
class Motion {
  static const Duration quick = Duration(milliseconds: 220);
  static const Duration medium = Duration(milliseconds: 380);
  static const Duration slow = Duration(milliseconds: 560);

  /// Smooth deceleration with a hint of overshoot, like UIKit's default spring.
  static const Curve spring = Cubic(0.2, 0.9, 0.25, 1.08);
  static const Curve ease = Cubic(0.25, 0.1, 0.25, 1.0);
  static const Curve emphasized = Cubic(0.05, 0.7, 0.1, 1.0);
}

ThemeData buildTheme(Palette p) {
  final base = p.isDark ? ThemeData.dark() : ThemeData.light();
  return base.copyWith(
    scaffoldBackgroundColor: p.groupedBackground,
    canvasColor: p.groupedBackground,
    colorScheme: base.colorScheme.copyWith(primary: p.accent, secondary: p.accent, surface: p.surface, error: p.red),
    textTheme: base.textTheme.apply(fontFamily: kFont, bodyColor: p.label, displayColor: p.label),
    textSelectionTheme: TextSelectionThemeData(cursorColor: p.accent),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: p.brightness,
      primaryColor: p.accent,
      scaffoldBackgroundColor: p.groupedBackground,
      textTheme: CupertinoTextThemeData(
        textStyle: TextStyles.body(p),
        primaryColor: p.accent,
        actionTextStyle: TextStyles.body(p).copyWith(color: p.accent),
        navTitleTextStyle: TextStyles.headline(p),
        navLargeTitleTextStyle: TextStyles.largeTitle(p),
        navActionTextStyle: TextStyles.body(p).copyWith(color: p.accent),
      ),
    ),
    dividerColor: p.separator,
  );
}
