import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/quote/quote_screen.dart';
import 'features/quote/quote_state.dart';
import 'l10n/app_localizations.dart';
import 'ui/theme.dart';

class MilanQuoteApp extends ConsumerWidget {
  const MilanQuoteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final language = ref.watch(languageProvider);

    return MaterialApp(
      onGenerateTitle: (context) => L.of(context).appTitle,
      debugShowCheckedModeBanner: false,

      // Language is per user, not per device (SPEC.md §8.3), so the app drives
      // the locale rather than reading the system one.
      locale: Locale(language),
      supportedLocales: L.supportedLocales,
      localizationsDelegates: const [
        L.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      // One theme, always light. SPEC.md §8.1: a dark system setting washes the
      // wizard out in a bright fair hall, so the app does not inherit it.
      theme: buildAppTheme(),
      themeMode: ThemeMode.light,
      darkTheme: buildAppTheme(),

      builder: (context, child) {
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light.copyWith(
            statusBarColor: AppColors.primary,
            systemNavigationBarColor: AppColors.surface,
            systemNavigationBarIconBrightness: Brightness.dark,
          ),
          child: MediaQuery.withClampedTextScaling(
            // Respect the user's text size, but stop the largest settings from
            // breaking a wizard used at arm's length. Accessibility guidance
            // wants scaling supported, not unbounded.
            minScaleFactor: 1.0,
            maxScaleFactor: 1.4,
            child: child!,
          ),
        );
      },

      home: const QuoteScreen(),
    );
  }
}
