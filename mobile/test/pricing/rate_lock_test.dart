/// The rate lock resolver, against the shared contract.
///
/// SPEC.md §6.1 asks for these before the resolver, and they live in
/// `shared/pricing-fixtures.json` so the Python engine answers the same way.
/// The one that matters most:
///
/// > Silently applying a curtain lock to a flooring line is the expensive bug
/// > in this design.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/rational.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/pricing/rate_lock.dart';

void main() {
  late List<dynamic> cases;
  late List<dynamic> grantCases;

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
    cases = json['rate_lock_cases'] as List<dynamic>;
    grantCases = json['lock_grant_cases'] as List<dynamic>;
  });

  test('the contract carries cases at all', () {
    // A fixture file that silently lost its cases would turn this whole file
    // green while testing nothing.
    expect(cases.length, greaterThanOrEqualTo(20));
  });

  test('every branch of §6.1 is covered', () {
    // Three cases, and the spec says do not collapse them. A suite that only
    // ever exercised one would not notice if the other two were wrong.
    final covered = cases
        .map((c) => (c as Map<String, dynamic>)['expect']['basis'] as String)
        .toSet();
    expect(covered, {'held', 'fair_current', 'standard_pinned'});
  });

  test('the fixtures agree with the resolver', () {
    for (final raw in cases) {
      final c = raw as Map<String, dynamic>;
      final line = c['line'] as Map<String, dynamic>;
      final expected = c['expect'] as Map<String, dynamic>;

      final basis = resolveRateBasis(
        family: Family.values.byName(line['family'] as String),
        depositCategoryOverride: line['deposit_category_override'] == null
            ? null
            : DepositCategory.values.byName(
                line['deposit_category_override'] as String,
              ),
        parentFamily: line['parent_family'] == null
            ? null
            : Family.values.byName(line['parent_family'] as String),
        locks: [
          for (final l in c['locks'] as List<dynamic>)
            _lock(l as Map<String, dynamic>),
        ],
        channel: Channel.fromWire(c['channel'] as String),
        currentRateCardVersion: c['current_rate_card_version'] as int,
        currentPromoPct: Rational.tryParse(c['current_promo_pct'] as String)!,
        orderPinnedRateCardVersion: c['order_pinned_rate_card_version'] as int,
        today: DateTime.parse(c['today'] as String),
      );

      final id = c['id'];
      final why = c['why'];
      expect(_wire(basis.source), expected['basis'], reason: '$id — $why');
      expect(
        basis.rateCardVersion,
        expected['rate_card_version'],
        reason: '$id — $why',
      );
      expect(
        basis.discountPct.toString(),
        expected['discount_pct'],
        reason: '$id — $why',
      );
      expect(basis.lockId, expected['lock_id'], reason: '$id — $why');
    }
  });

  group('the cases the fixtures cannot express', () {
    test('an add-on with no parent is refused, not filed under curtains', () {
      // A guess about money. Defaulting to curtains could price a motor at a
      // held curtain rate that its RM300 never bought.
      expect(
        () => depositCategoryOf(Family.addon),
        throwsA(isA<UnknownDepositCategory>()),
      );
    });

    test('an add-on hanging off an add-on is refused', () {
      expect(
        () => depositCategoryOf(Family.addon, parentFamily: Family.service),
        throwsA(isA<UnknownDepositCategory>()),
      );
    });

    test('a lock is checked by status and by date, not one or the other', () {
      // The nightly job that flips active to expired may not have run on a
      // handset that has been offline for a week, so the date is checked here
      // too rather than trusted from the row.
      final stale = CategoryLock(
        id: 'l',
        category: DepositCategory.curtain,
        heldRateCardVersion: 1,
        heldDiscountPct: Rational.zero,
        heldUntil: DateTime(2027, 8, 29),
        status: LockStatus.active,
      );
      expect(stale.isActiveOn(DateTime(2027, 8, 29)), isTrue);
      expect(stale.isActiveOn(DateTime(2027, 8, 30)), isFalse);
    });

    test('the time of day does not end a lock early', () {
      // held_until is a date. A customer arriving at 4pm on the final day is
      // inside it, and comparing raw DateTimes would say otherwise.
      final lock = CategoryLock(
        id: 'l',
        category: DepositCategory.curtain,
        heldRateCardVersion: 1,
        heldDiscountPct: Rational.zero,
        heldUntil: DateTime(2027, 8, 29),
        status: LockStatus.active,
      );
      expect(lock.isActiveOn(DateTime(2027, 8, 29, 16, 30)), isTrue);
    });
  });

  group('opening a lock', () {
    test('the contract carries grant cases too', () {
      expect(grantCases.length, greaterThanOrEqualTo(12));
      // Both outcomes, or the file is only testing one branch.
      final outcomes = grantCases
          .map((c) => (c as Map<String, dynamic>)['expect']['granted'] as bool)
          .toSet();
      expect(outcomes, {true, false});
    });

    test('the fixtures agree with the grant rule', () {
      for (final raw in grantCases) {
        final c = raw as Map<String, dynamic>;
        final expected = c['expect'] as Map<String, dynamic>;
        final id = c['id'];
        final why = c['why'];

        final grant = openCategoryLock(
          id: 'new-lock',
          channel: Channel.fromWire(c['channel'] as String),
          category: DepositCategory.values.byName(c['category'] as String),
          depositDate: DateTime.parse(c['deposit_date'] as String),
          fairEndsOn: c['fair_ends_on'] == null
              ? null
              : DateTime.parse(c['fair_ends_on'] as String),
          depositSen: c['deposit_sen'] as int,
          minDepositSen: c['min_deposit_sen'] as int,
          rateCardVersion: c['rate_card_version'] as int,
          promoPct: Rational.tryParse(c['promo_pct'] as String)!,
        );

        expect(grant.granted, expected['granted'], reason: '$id — $why');
        if (expected['granted'] != true) {
          expect(
            grant.refusedBecause?.wire,
            expected['refused_because'],
            reason: '$id — $why',
          );
          continue;
        }

        final lock = grant.lock!;
        expect(
          lock.heldRateCardVersion,
          expected['held_rate_card_version'],
          reason: '$id — $why',
        );
        expect(
          lock.heldDiscountPct.toString(),
          expected['held_discount_pct'],
          reason: '$id — $why',
        );
        expect(
          lock.heldUntil,
          DateTime.parse(expected['held_until'] as String),
          reason: '$id — $why',
        );
      }
    });

    test('every channel but fair is refused', () {
      // Checked one by one rather than "not fair", so a channel added later
      // cannot default into locking.
      for (final channel in Channel.values) {
        final grant = openCategoryLock(
          id: 'l',
          channel: channel,
          category: DepositCategory.curtain,
          depositDate: DateTime(2026, 8, 29),
          fairEndsOn: DateTime(2026, 8, 31),
          depositSen: 30000,
          minDepositSen: 30000,
          rateCardVersion: 1,
          promoPct: Rational.zero,
        );
        expect(grant.granted, channel == Channel.fair, reason: channel.wire);
      }
    });

    test('a refused grant produces no row at all', () {
      // Not a lock with a flag on it. A row that exists can be read by
      // something that forgets to check the flag.
      final grant = openCategoryLock(
        id: 'l',
        channel: Channel.showroom,
        category: DepositCategory.curtain,
        depositDate: DateTime(2026, 8, 29),
        fairEndsOn: DateTime(2026, 8, 31),
        depositSen: 30000,
        minDepositSen: 30000,
        rateCardVersion: 1,
        promoPct: Rational.zero,
      );
      expect(grant.lock, isNull);
    });
  });

  group('twelve months from a deposit', () {
    test('a leap day clamps rather than rolling forward', () {
      // Dart rolls an out-of-range day forward: DateTime(2029, 2, 29) is 1
      // March, which would quietly extend the hold by a day.
      expect(twelveMonthsFrom(DateTime(2028, 2, 29)), DateTime(2029, 2, 28));
    });

    test('a month end that exists is left alone', () {
      expect(twelveMonthsFrom(DateTime(2026, 8, 31)), DateTime(2027, 8, 31));
      expect(twelveMonthsFrom(DateTime(2026, 1, 31)), DateTime(2027, 1, 31));
    });

    test('every day of a leap year lands on a real date', () {
      // A sweep rather than three examples: the clamp has to hold for all 366.
      for (var day = DateTime(2028, 1, 1); day.year == 2028;) {
        final held = twelveMonthsFrom(day);
        expect(held.year, 2029, reason: '$day');
        expect(held.month, day.month, reason: '$day');
        expect(held.day, lessThanOrEqualTo(day.day), reason: '$day');
        day = day.add(const Duration(days: 1));
      }
    });

    test('the hold is never shortened by more than a day', () {
      // The clamp exists for 29 February and nothing else.
      for (var day = DateTime(2027, 1, 1); day.year == 2027;) {
        expect(
          day.day - twelveMonthsFrom(day).day,
          anyOf(0, 1),
          reason: '$day',
        );
        day = day.add(const Duration(days: 1));
      }
    });
  });

  group('Rational round trips through the contract', () {
    test('toString and tryParse are inverses', () {
      for (final r in [
        Rational.zero,
        Rational.one,
        Rational(1, 10),
        Rational(1, 3),
        Rational(-2, 7),
        Rational(20, 4),
      ]) {
        expect(Rational.tryParse(r.toString()), r, reason: '$r');
      }
    });

    test('nonsense is null rather than zero', () {
      // Returning zero would turn a typo in the rate card into a silent
      // hundred percent discount.
      for (final s in ['', 'x', '1/', '/2', '1/0', '1/2/3']) {
        expect(Rational.tryParse(s), isNull, reason: s);
      }
    });
  });
}

CategoryLock _lock(Map<String, dynamic> json) => CategoryLock(
  id: json['id'] as String,
  category: DepositCategory.values.byName(json['category'] as String),
  heldRateCardVersion: json['held_rate_card_version'] as int,
  heldDiscountPct: Rational.tryParse(json['held_discount_pct'] as String)!,
  heldUntil: DateTime.parse(json['held_until'] as String),
  status: LockStatus.fromWire(json['status'] as String),
);

String _wire(RateSource source) => switch (source) {
  RateSource.held => 'held',
  RateSource.fairCurrent => 'fair_current',
  RateSource.standardPinned => 'standard_pinned',
};
