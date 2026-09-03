/// Which customer a rate lock belongs to. SPEC.md §6.1, §13 B9.
///
/// The cases live in `shared/pricing-fixtures.json` and both suites load them:
/// a lock granted on a handset and a lock read back from the server have to
/// agree about whose it is.
///
/// The failure this replaces is worth naming. The key was the quote id, so the
/// twelve-month hold could never match a second quote — the customer paid RM300
/// at the fair and was quoted the standard rate in March, which is *more* than
/// the hold they bought.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/pricing/customer_key.dart';

void main() {
  late List<dynamic> cases;

  setUpAll(() {
    var dir = Directory.current;
    while (!File('${dir.path}/shared/pricing-fixtures.json').existsSync()) {
      dir = dir.parent;
    }
    final json =
        jsonDecode(
              File(
                '${dir.path}/shared/pricing-fixtures.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    cases = json['customer_key_cases'] as List<dynamic>;
  });

  group('the shared contract', () {
    test('carries cases at all', () {
      expect(cases.length, greaterThanOrEqualTo(10));
    });

    test('covers both kinds of key', () {
      final kinds = cases
          .map((c) => (c as Map<String, dynamic>)['expect']['from_phone'])
          .toSet();
      expect(kinds, {true, false});
    });

    test('the fixtures agree with the rule', () {
      for (final raw in cases) {
        final c = raw as Map<String, dynamic>;
        final expected = c['expect'] as Map<String, dynamic>;

        final key = customerKeyFor(
          phone: c['phone'] as String?,
          quoteId: c['quote_id'] as String,
        );

        final why = '${c['id']} — ${c['why']}';
        expect(key.value, expected['key'], reason: why);
        expect(key.fromPhone, expected['from_phone'], reason: why);
      }
    });
  });

  group('the returning customer', () {
    test('two quotes on one phone are one customer', () {
      // The whole point of a twelve-month hold. This is the case that was
      // broken: the August quote and the March quote must produce one key.
      final atTheFair = customerKeyFor(
        phone: '012-345 6789',
        quoteId: 'q-august',
      );
      final inTheShowroom = customerKeyFor(
        phone: '+60123456789',
        quoteId: 'q-march',
      );
      expect(atTheFair, inTheShowroom);
    });

    test('two different phones are two customers', () {
      expect(
        customerKeyFor(phone: '0123456789', quoteId: 'q-1'),
        isNot(customerKeyFor(phone: '0129999999', quoteId: 'q-1')),
      );
    });

    test('two walk-ins with no phone never share a key', () {
      // Falling back to the quote id keeps them apart. A shared fallback would
      // hand the second walk-in the first one's held prices.
      expect(
        customerKeyFor(phone: null, quoteId: 'q-1'),
        isNot(customerKeyFor(phone: null, quoteId: 'q-2')),
      );
    });

    test('a quote id cannot be mistaken for a phone', () {
      // The prefixes exist for this. A quote id that happened to look like a
      // number would otherwise become one.
      final byPhone = customerKeyFor(phone: '0123456789', quoteId: 'x');
      final byQuote = customerKeyFor(phone: null, quoteId: '0123456789');
      expect(byPhone, isNot(byQuote));
      expect(byPhone.value, startsWith('phone:'));
      expect(byQuote.value, startsWith('quote:'));
    });
  });

  group('normalising a phone', () {
    test('keeps only digits', () {
      expect(normalisePhone('012-345 6789'), '0123456789');
      expect(normalisePhone('(012) 345.6789'), '0123456789');
      expect(normalisePhone('  0123456789  '), '0123456789');
    });

    test('reads a country code as a leading zero', () {
      expect(normalisePhone('+60123456789'), '0123456789');
      expect(normalisePhone('60123456789'), '0123456789');
      expect(normalisePhone('+60 12 345 6789'), '0123456789');
    });

    test('never takes a zero off a number that already has one', () {
      // 060... is a real local number. Stripping here would produce somebody
      // else's, and the customer whose prices those are would never know.
      expect(normalisePhone('0601234567'), '0601234567');
    });

    test('refuses a fragment rather than guessing', () {
      expect(normalisePhone('0123'), isNull);
      expect(normalisePhone('01234567'), isNull, reason: 'eight digits');
      expect(normalisePhone('012345678'), '012345678', reason: 'nine');
      expect(minPhoneDigits, 9);
    });

    test('refuses what is not a number at all', () {
      expect(normalisePhone(null), isNull);
      expect(normalisePhone(''), isNull);
      expect(normalisePhone('   '), isNull);
      expect(normalisePhone('call the office'), isNull);
      expect(normalisePhone('-'), isNull);
    });
  });

  test('a key is a value, so it can be compared and stored', () {
    // Built through the function rather than as literals: two keys derived
    // from the same customer on different days have to land in one bucket, and
    // const literals would prove only that the compiler folded them.
    final august = customerKeyFor(phone: '0123456789', quoteId: 'q-august');
    final march = customerKeyFor(phone: '012 345 6789', quoteId: 'q-march');

    expect(august, march);
    expect(<CustomerKey>{}..addAll([august, march]), hasLength(1));
    expect(august.toString(), 'phone:0123456789');
    expect(
      august,
      isNot(const CustomerKey('phone:0123456789', fromPhone: false)),
      reason: 'how the key was arrived at is part of what it means',
    );
  });
}
