/// SPEC.md §6.2, the revenue feature.
///
/// > This is the moment the second RM300 gets collected, and it is almost
/// > certainly being missed at fairs today.
///
/// Two ways to lose money here, and both are silent: never asking, and asking
/// for a category the customer has already paid for.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/rational.dart';
import 'package:milan_quote/pricing/deposit_prompt.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/pricing/rate_lock.dart';

final atTheFair = DateTime(2026, 8, 29);

CategoryLock lockOn(
  DepositCategory category, {
  DateTime? until,
  LockStatus status = LockStatus.active,
}) => CategoryLock(
  id: 'lock-${category.name}',
  category: category,
  heldRateCardVersion: 1,
  heldDiscountPct: Rational.zero,
  heldUntil: until ?? DateTime(2027, 8, 29),
  status: status,
);

LineCategoryInput line(
  String id,
  Family family, {
  Family? parent,
  DepositCategory? override,
}) => LineCategoryInput(
  id: id,
  family: family,
  parentFamily: parent,
  depositCategoryOverride: override,
);

void main() {
  group('at a fair', () {
    test('a curtain-only quote with no deposit asks once', () {
      final gaps = depositGaps(
        lines: [line('a', Family.curtain), line('b', Family.blind)],
        locks: const [],
        channel: Channel.fair,
        today: atTheFair,
      );

      expect(gaps, hasLength(1));
      expect(gaps.single.category, DepositCategory.curtain);
      expect(
        gaps.single.lineIds,
        ['a', 'b'],
        reason: 'blinds ride the curtain deposit, so it is one ask, not two',
      );
    });

    test('adding flooring to a curtain-locked quote asks for flooring', () {
      // The whole feature. RM300 was paid for curtains; the flooring is a
      // second RM300 and today it is being missed.
      final gaps = depositGaps(
        lines: [line('a', Family.curtain), line('b', Family.flooring)],
        locks: [lockOn(DepositCategory.curtain)],
        channel: Channel.fair,
        today: atTheFair,
      );

      expect(gaps, hasLength(1));
      expect(gaps.single.category, DepositCategory.flooring);
      expect(gaps.single.lineIds, ['b']);
    });

    test('a locked category is never asked about again', () {
      // Asking for money already taken is how a customer stops trusting the
      // quote in front of them.
      final gaps = depositGaps(
        lines: [line('a', Family.curtain)],
        locks: [lockOn(DepositCategory.curtain)],
        channel: Channel.fair,
        today: atTheFair,
      );
      expect(gaps, isEmpty);
    });

    test('three categories with one lock asks for the other two', () {
      final gaps = depositGaps(
        lines: [
          line('a', Family.curtain),
          line('b', Family.flooring),
          line('c', Family.wallpaper),
        ],
        locks: [lockOn(DepositCategory.curtain)],
        channel: Channel.fair,
        today: atTheFair,
      );

      expect(
        gaps.map((g) => g.category),
        [DepositCategory.flooring, DepositCategory.wallpaper],
        reason: 'in the order the customer built the quote',
      );
    });

    test('an expired lock is a gap again', () {
      final gaps = depositGaps(
        lines: [line('a', Family.curtain)],
        locks: [lockOn(DepositCategory.curtain, until: DateTime(2026, 8, 28))],
        channel: Channel.fair,
        today: atTheFair,
      );
      expect(gaps, hasLength(1));
    });

    test('a refunded lock is a gap again', () {
      final gaps = depositGaps(
        lines: [line('a', Family.curtain)],
        locks: [lockOn(DepositCategory.curtain, status: LockStatus.refunded)],
        channel: Channel.fair,
        today: atTheFair,
      );
      expect(gaps, hasLength(1));
    });

    test('a motor on a flooring line asks about flooring, not curtains', () {
      // The §6.1 bug in prompt form. Asking for a curtain deposit because an
      // add-on defaulted to curtains would collect the wrong RM300.
      final gaps = depositGaps(
        lines: [line('m', Family.addon, parent: Family.flooring)],
        locks: [lockOn(DepositCategory.curtain)],
        channel: Channel.fair,
        today: atTheFair,
      );

      expect(gaps.single.category, DepositCategory.flooring);
    });

    test('a service uses the category its rule names', () {
      final gaps = depositGaps(
        lines: [line('s', Family.service, override: DepositCategory.flooring)],
        locks: [lockOn(DepositCategory.flooring)],
        channel: Channel.fair,
        today: atTheFair,
      );
      expect(gaps, isEmpty);
    });

    test('a line whose category cannot be decided does not ask', () {
      // An unparented add-on is a data error, surfaced where it is priced.
      // Asking for a deposit on "unknown" would collect money against nothing.
      final gaps = depositGaps(
        lines: [line('x', Family.addon)],
        locks: const [],
        channel: Channel.fair,
        today: atTheFair,
      );
      expect(gaps, isEmpty);
    });

    test('an empty quote asks for nothing', () {
      expect(
        depositGaps(
          lines: const [],
          locks: const [],
          channel: Channel.fair,
          today: atTheFair,
        ),
        isEmpty,
      );
    });
  });

  group('away from a fair', () {
    test('nothing is ever asked, even with no locks at all', () {
      // Client, Sep 2026: "no second rm300 paid later in showroom, only depo at
      // fair can lock price." Collecting RM300 for a hold that will not exist
      // is worse than not asking.
      for (final channel in Channel.values) {
        final gaps = depositGaps(
          lines: [line('a', Family.curtain), line('b', Family.flooring)],
          locks: const [],
          channel: channel,
          today: atTheFair,
        );
        expect(gaps.isEmpty, channel != Channel.fair, reason: channel.wire);
      }
    });
  });

  group('the choice is recorded, not just acted on', () {
    test('every button has a distinct wire value', () {
      // The declined-deposit report is the point of logging, and it only works
      // if the four outcomes stay distinguishable.
      final wires = DepositChoice.values.map((c) => c.wire).toSet();
      expect(wires, hasLength(DepositChoice.values.length));
    });

    test('dismissing is not filed as declining', () {
      // "They said no" and "nobody asked properly" are different problems, and
      // only one of them is the customer's.
      expect(DepositChoice.dismissed, isNot(DepositChoice.declined));
      expect(DepositChoice.fromWire('dismissed'), DepositChoice.dismissed);
      expect(DepositChoice.fromWire('declined'), DepositChoice.declined);
    });
  });
}
