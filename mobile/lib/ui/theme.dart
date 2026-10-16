/// The design system: colour, type scale, spacing, touch targets.
///
/// Every visual constant in the app lives here. A raw hex or a magic padding in
/// a widget is a bug — SPEC.md §8 is binding, not advisory.
///
/// The look matches the office dashboard (`dashboard/design-system/MASTER.md`):
/// neutral greys, one blue that means "you can act on this", flat surfaces
/// separated by a hairline rather than a shadow, the platform's own typeface
/// and no gradients. Colour is otherwise for state only.
///
/// ## Why light-only
///
/// SPEC.md §8.1: "Force light theme in the wizard rather than inheriting a dark
/// system setting that washes out outdoors." Fair halls are bright and staff
/// use personal phones whose theme we do not control. This is the one place the
/// app deliberately ignores a system preference, and it is a legibility
/// decision rather than a stylistic one. The dashboard has a dark mode; the
/// handset does not, for exactly this reason.
library;

import 'package:flutter/material.dart';

/// Colour tokens. Every foreground/background pair below clears 4.5:1.
abstract final class AppColors {
  /// The one accent: primary buttons, links, selected state, focus. 4.6:1 on
  /// white.
  static const primary = Color(0xFF0071E3);
  static const onPrimary = Color(0xFFFFFFFF);

  /// A quiet tint of the accent, for a selected row or a pressed state.
  static const primarySurface = Color(0xFFE8F1FC);

  /// Kept as a name of its own because screens pick it for "in progress"
  /// emphasis; it is the same blue.
  static const secondary = primary;
  static const onSecondary = onPrimary;

  /// Money, confirmation, the running total.
  static const accent = Color(0xFF1D7D36);
  static const onAccent = Color(0xFFFFFFFF);

  /// A quiet green ground for the one thing worth being pleased about: a
  /// confirmed sale. Deliberately pale — the warning and alarm surfaces have to
  /// stay the loudest things on a screen.
  static const accentSurface = Color(0xFFE6F5EA);

  /// Page background. Never pure white — a faint tint reduces glare outdoors
  /// while keeping surfaces distinct.
  static const background = Color(0xFFF5F5F7);
  static const surface = Color(0xFFFFFFFF);

  /// Body text. Near-black, ~16:1 on the background.
  static const foreground = Color(0xFF1D1D1F);

  /// Secondary text. 4.6:1 on the background — the lightest grey §8.1 allows.
  static const mutedForeground = Color(0xFF6E6E73);

  static const muted = Color(0xFFEDEDF0);
  static const border = Color(0xFFD2D2D7);

  static const destructive = Color(0xFFD70015);
  static const onDestructive = Color(0xFFFFFFFF);

  /// Soft warnings. Never blocks; always one tap to fix.
  static const warning = Color(0xFF8A4600);
  static const warningSurface = Color(0xFFFFF3DF);

  /// The provisional rate-card banner. Deliberately alarming.
  static const alarm = Color(0xFF9E0012);
  static const alarmSurface = Color(0xFFFFEBE9);
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

/// Controls and chips 8, surfaces 12, sheets and dialogs 16.
abstract final class Radii {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
}

/// Type scale. §8.1 forbids weights under 14sp and grey under 60% on white.
/// Headings tighten their tracking slightly, the way the platform's own does.
abstract final class AppText {
  /// The running total. The most-looked-at number in the app — the part-timer
  /// and the customer both watch it, so it is the largest thing on screen.
  static const totalDisplay = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w600,
    height: 1.1,
    letterSpacing: -0.6,
    color: AppColors.foreground,
    // Tabular figures stop the total jittering as digits change.
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const headline = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1.3,
    letterSpacing: -0.4,
    color: AppColors.foreground,
  );

  static const title = TextStyle(
    fontSize: 19,
    fontWeight: FontWeight.w600,
    height: 1.35,
    letterSpacing: -0.2,
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
    primaryContainer: AppColors.primarySurface,
    onPrimaryContainer: AppColors.primary,
    secondary: AppColors.secondary,
    onSecondary: AppColors.onSecondary,
    tertiary: AppColors.accent,
    onTertiary: AppColors.onAccent,
    surface: AppColors.surface,
    onSurface: AppColors.foreground,
    onSurfaceVariant: AppColors.mutedForeground,
    surfaceContainerHighest: AppColors.muted,
    error: AppColors.destructive,
    onError: AppColors.onDestructive,
    outline: AppColors.border,
    outlineVariant: AppColors.border,
  );

  final fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(Radii.md),
    borderSide: const BorderSide(color: AppColors.border),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    // Falls back to the platform's own face: San Francisco on iOS, and the
    // platform CJK font for Chinese. See pubspec.yaml for why nothing is
    // bundled.
    fontFamily: null,
    // No ink ripple: a pressed row takes a faint tint instead, the way the
    // platform's own lists do.
    splashFactory: NoSplash.splashFactory,
    highlightColor: AppColors.foreground.withValues(alpha: 0.06),
    hoverColor: AppColors.foreground.withValues(alpha: 0.04),
    // Flat bar on the page ground with a hairline beneath it, not a coloured
    // slab.
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.foreground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      shape: Border(bottom: BorderSide(color: AppColors.border)),
      titleTextStyle: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: AppColors.foreground,
      ),
      iconTheme: IconThemeData(color: AppColors.primary),
      actionsIconTheme: IconThemeData(color: AppColors.primary),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(Touch.primary),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        disabledBackgroundColor: AppColors.border,
        disabledForegroundColor: AppColors.mutedForeground,
        elevation: 0,
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
        backgroundColor: AppColors.surface,
        side: const BorderSide(color: AppColors.border),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.md,
      ),
      border: fieldBorder,
      enabledBorder: fieldBorder,
      disabledBorder: fieldBorder.copyWith(
        borderSide: const BorderSide(color: AppColors.muted),
      ),
      focusedBorder: fieldBorder.copyWith(
        borderSide: const BorderSide(color: AppColors.primary, width: 2),
      ),
      errorBorder: fieldBorder.copyWith(
        borderSide: const BorderSide(color: AppColors.destructive),
      ),
      focusedErrorBorder: fieldBorder.copyWith(
        borderSide: const BorderSide(color: AppColors.destructive, width: 2),
      ),
      labelStyle: AppText.caption,
      floatingLabelStyle: AppText.caption.copyWith(color: AppColors.primary),
      hintStyle: AppText.body.copyWith(color: AppColors.mutedForeground),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surface,
      selectedColor: AppColors.primarySurface,
      disabledColor: AppColors.muted,
      side: const BorderSide(color: AppColors.border),
      labelStyle: AppText.label,
      secondaryLabelStyle: AppText.label.copyWith(color: AppColors.primary),
      checkmarkColor: AppColors.primary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.primary
            : Colors.transparent,
      ),
      side: const BorderSide(color: AppColors.border, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.accent
            : AppColors.border,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.primary,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: AppColors.primary,
      selectionColor: AppColors.primary.withValues(alpha: 0.25),
      selectionHandleColor: AppColors.primary,
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.mutedForeground,
      titleTextStyle: AppText.body,
      subtitleTextStyle: AppText.caption,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.foreground,
      contentTextStyle: const TextStyle(
        fontSize: 16,
        color: Colors.white,
        fontWeight: FontWeight.w500,
      ),
      actionTextColor: const Color(0xFF7DB8FF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),
  );
}
