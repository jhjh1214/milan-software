/// The design system: colour, type scale, spacing, touch targets.
///
/// Every visual constant in the app lives here. A raw hex or a magic padding in
/// a widget is a bug — SPEC.md §8 is binding, not advisory.
///
/// ## Why light-only
///
/// SPEC.md §8.1: "Force light theme in the wizard rather than inheriting a dark
/// system setting that washes out outdoors." Fair halls are bright and staff
/// use personal phones whose theme we do not control. This is the one place the
/// app deliberately ignores a system preference, and it is a legibility
/// decision rather than a stylistic one.
library;

import 'package:flutter/material.dart';

/// Colour tokens. Navy and a money green, from the invoice-and-billing family —
/// high contrast on white, which is what survives daylight.
abstract final class AppColors {
  /// Primary surface colour for headers and primary buttons. 11:1 on white.
  static const primary = Color(0xFF1E3A5F);
  static const onPrimary = Color(0xFFFFFFFF);

  /// Secondary actions and selected states.
  static const secondary = Color(0xFF2563EB);
  static const onSecondary = Color(0xFFFFFFFF);

  /// Money, confirmation, the running total. Darkened from the palette's
  /// #059669 so white text on it clears 4.5:1 rather than sitting at 3.7:1.
  static const accent = Color(0xFF047857);
  static const onAccent = Color(0xFFFFFFFF);

  /// Page background. Never pure white — a faint tint reduces glare outdoors
  /// while keeping cards distinct.
  static const background = Color(0xFFF8FAFC);
  static const surface = Color(0xFFFFFFFF);

  /// Body text. Near-black, ~16:1 on the background.
  static const foreground = Color(0xFF0F172A);

  /// Secondary text. 4.6:1 on the background — the lightest grey §8.1 allows.
  static const mutedForeground = Color(0xFF56637A);

  static const muted = Color(0xFFF1F3F5);
  static const border = Color(0xFFCBD5E1);

  static const destructive = Color(0xFFB91C1C);
  static const onDestructive = Color(0xFFFFFFFF);

  /// Soft warnings. Never blocks; always one tap to fix.
  static const warning = Color(0xFF92400E);
  static const warningSurface = Color(0xFFFEF3C7);

  /// The provisional rate-card banner. Deliberately alarming.
  static const alarm = Color(0xFF7F1D1D);
  static const alarmSurface = Color(0xFFFEE2E2);
}

/// Spacing on a 4dp rhythm. Nothing in the app uses a value not on this scale.
abstract final class Space {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const xxxl = 48.0;
}

/// Touch targets. §8.1: minimum 48dp, 56dp for wizard primaries.
abstract final class Touch {
  /// Absolute minimum for any tappable thing.
  static const min = 48.0;

  /// Wizard primary actions — the buttons a part-timer hits all day.
  static const primary = 56.0;

  /// Keypad keys. Larger again, because they are hit hardest and fastest.
  static const key = 64.0;
}

abstract final class Radii {
  static const sm = 6.0;
  static const md = 10.0;
  static const lg = 14.0;
}

/// Type scale. §8.1 forbids weights under 14sp and grey under 60% on white.
abstract final class AppText {
  /// The running total. The most-looked-at number in the app — the part-timer
  /// and the customer both watch it, so it is the largest thing on screen.
  static const totalDisplay = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w700,
    height: 1.1,
    color: AppColors.foreground,
    // Tabular figures stop the total jittering as digits change.
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const headline = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1.3,
    color: AppColors.foreground,
  );

  static const title = TextStyle(
    fontSize: 19,
    fontWeight: FontWeight.w600,
    height: 1.35,
    color: AppColors.foreground,
  );

  static const body = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: AppColors.foreground,
  );

  static const bodyStrong = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.5,
    color: AppColors.foreground,
  );

  /// Prices in a list. Tabular so columns line up.
  static const money = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    height: 1.3,
    color: AppColors.foreground,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Supporting text. 14sp is the floor.
  static const caption = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: AppColors.mutedForeground,
  );

  static const label = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.3,
    color: AppColors.foreground,
  );

  /// Keypad digits.
  static const keypadDigit = TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.w500,
    height: 1.0,
    color: AppColors.foreground,
  );

  static const keypadUnit = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 1.0,
    color: AppColors.primary,
  );
}

/// Motion. §8: 150-300ms, meaningful, interruptible.
abstract final class Motion {
  static const fast = Duration(milliseconds: 120);
  static const normal = Duration(milliseconds: 200);
  static const enter = Curves.easeOut;
  static const exit = Curves.easeIn;

  /// How long a deleted line can be restored. §8.1 prefers undo over a modal
  /// confirmation, which gets tapped through blindly under pressure.
  static const undoWindow = Duration(seconds: 5);
}

/// Builds the single, light theme the app runs in.
ThemeData buildAppTheme() {
  const scheme = ColorScheme.light(
    primary: AppColors.primary,
    onPrimary: AppColors.onPrimary,
    secondary: AppColors.secondary,
    onSecondary: AppColors.onSecondary,
    tertiary: AppColors.accent,
    onTertiary: AppColors.onAccent,
    surface: AppColors.surface,
    onSurface: AppColors.foreground,
    error: AppColors.destructive,
    onError: AppColors.onDestructive,
    outline: AppColors.border,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    // Falls back to the platform CJK font for Chinese. See pubspec.yaml for
    // why nothing is bundled.
    fontFamily: null,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.primary,
      foregroundColor: AppColors.onPrimary,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w600,
        color: AppColors.onPrimary,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(Touch.primary),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(Touch.min),
        foregroundColor: AppColors.primary,
        side: const BorderSide(color: AppColors.border, width: 1.5),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.foreground,
      contentTextStyle: const TextStyle(
        fontSize: 16,
        color: Colors.white,
        fontWeight: FontWeight.w500,
      ),
      actionTextColor: const Color(0xFF7DD3FC),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),
  );
}
