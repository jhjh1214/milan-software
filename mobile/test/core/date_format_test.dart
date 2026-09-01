import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/date_format.dart';

void main() {
  group('SPEC.md §8.3 date format', () {
    test('the month is always a word, never a number', () {
      // 12/03/27 is 12 March here and 3 December in the US. An order that waits
      // a year for a handover is exactly where that costs a measurement visit.
      expect(formatDate(DateTime(2027, 3, 12)), '12 Mar 2027');
      expect(formatDate(DateTime(2026, 8, 31)), '31 Aug 2026');
      expect(formatDate(DateTime(2026, 1, 1)), '1 Jan 2026');
      expect(formatDate(DateTime(2026, 12, 25)), '25 Dec 2026');
    });

    test('every month renders', () {
      for (var m = 1; m <= 12; m++) {
        final out = formatDate(DateTime(2026, m, 15));
        expect(out, startsWith('15 '));
        expect(out, endsWith(' 2026'));
        expect(out.split(' ')[1].length, 3);
      }
    });
  });
}
