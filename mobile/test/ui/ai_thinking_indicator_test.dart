/// The AI-thinking pulse. SPEC.md §14.7: a recognition proposal is never
/// production truth, and this widget carries no state about what a request
/// will return -- only that one is in flight, the way `.spinner`/
/// `CircularProgressIndicator` already do elsewhere.
///
/// The animation loops forever (`AnimationController.repeat()`), so
/// `pumpAndSettle` would hang on it -- every case here uses a bounded
/// `tester.pump(Duration(...))` instead, the same workaround
/// `measure_screen_test.dart` already needed for its own endless spinner.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/ui/widgets/ai_thinking_indicator.dart';

Widget _wrap(Widget child, {bool disableAnimations = false}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

List<double> _opacities(WidgetTester tester) => tester
    .widgetList<Opacity>(find.byType(Opacity))
    .map((o) => o.opacity)
    .toList();

void main() {
  testWidgets('renders three dots', (tester) async {
    await tester.pumpWidget(_wrap(const AiThinkingIndicator()));
    await tester.pump();

    expect(find.byType(Opacity), findsNWidgets(3));
  });

  testWidgets('pulses over time', (tester) async {
    await tester.pumpWidget(_wrap(const AiThinkingIndicator()));
    await tester.pump();
    final first = _opacities(tester);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    final later = _opacities(tester);

    expect(later, isNot(equals(first)));
  });

  testWidgets('holds a static frame under reduced motion', (tester) async {
    await tester.pumpWidget(
      _wrap(const AiThinkingIndicator(), disableAnimations: true),
    );
    await tester.pump();
    final first = _opacities(tester);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    final later = _opacities(tester);

    // The one correctness-bearing case: nothing in this app read
    // `disableAnimations` before this widget existed.
    expect(later, equals(first));
  });
}
