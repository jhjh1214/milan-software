/// The postcode rule both site-details screens share. §13 C10: the office
/// groups a day's visits by postcode, so a wrong one sends somebody to the
/// wrong end of Melaka — and the server refuses anything but five digits.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/site_details.dart';

void main() {
  test('blank is fine: the postcode is not known yet', () {
    expect(postcodeIsValid(null), isTrue);
    expect(postcodeIsValid(''), isTrue);
    expect(postcodeIsValid('   '), isTrue);
    expect(cleanPostcode('  '), isNull);
  });

  test('five digits, surrounding spaces trimmed', () {
    expect(postcodeIsValid('75450'), isTrue);
    expect(postcodeIsValid(' 75450 '), isTrue);
    expect(cleanPostcode(' 75450 '), '75450');
  });

  test('anything else is refused', () {
    for (final bad in ['7545', '754500', '7545A', '75 450', 'Melaka']) {
      expect(postcodeIsValid(bad), isFalse, reason: bad);
    }
  });

  test('free text trims to null', () {
    expect(cleanText('  3 Jalan Bunga '), '3 Jalan Bunga');
    expect(cleanText('   '), isNull);
    expect(cleanText(null), isNull);
  });
}
