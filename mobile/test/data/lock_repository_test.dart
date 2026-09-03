/// Locks and the prompt log, on a real database.
///
/// The rules live in `pricing/rate_lock.dart` and are tested there. What is
/// checked here is that they survive storage: a lock that comes back as a
/// different lock, or a decline that quietly disappears, would break the two
/// things Phase 4 exists to protect — the held price, and the report that says
/// what fairs are leaving on the table.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/rational.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/lock_repository.dart';
import 'package:milan_quote/features/quote/deposit_prompt_sheet.dart'
    show customerKeyForQuote;
import 'package:milan_quote/features/quote/quote_state.dart';
import 'package:milan_quote/pricing/deposit_prompt.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/pricing/rate_lock.dart';

void main() {
  late AppDatabase db;
  late LockRepository repo;

  final depositDay = DateTime(2026, 8, 29);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = LockRepository(db);
  });

  tearDown(() => db.close());

  /// The only way to make a lock: through the rule that decides whether one
  /// may exist at all.
  CategoryLock aLock({
    DepositCategory category = DepositCategory.curtain,
    Rational? pct,
  }) {
    final grant = openCategoryLock(
      id: 'lock-1',
      channel: Channel.fair,
      category: category,
      depositDate: depositDay,
      depositSen: 30000,
      minDepositSen: 30000,
      rateCardVersion: 1,
      promoPct: pct ?? Rational.zero,
    );
    return grant.lock!;
  }

  group('a stored lock comes back as the same lock', () {
    test('every field survives the round trip', () {
      // A lock that comes back different is a customer charged a price they
      // were not promised, twelve months after anyone could remember why.
      final lock = aLock(pct: Rational(1, 10));

      return repo
          .store(lock, customerId: 'cust-1', at: depositDay)
          .then((_) => repo.locksFor('cust-1'))
          .then((back) {
            expect(back, hasLength(1));
            expect(back.single.id, lock.id);
            expect(back.single.category, DepositCategory.curtain);
            expect(back.single.heldRateCardVersion, 1);
            expect(back.single.heldDiscountPct, Rational(1, 10));
            expect(back.single.heldUntil, DateTime(2027, 8, 29));
            expect(back.single.status, LockStatus.active);
          });
    });

    test('the percentage stays exact, not a rounded decimal', () {
      // One third cannot be written as a decimal. Storing 0.33 would lose a
      // hundredth of a percent of every held price for twelve months.
      final lock = CategoryLock(
        id: 'l',
        category: DepositCategory.flooring,
        heldRateCardVersion: 7,
        heldDiscountPct: Rational(1, 3),
        heldUntil: DateTime(2027, 8, 29),
      );

      return repo
          .store(lock, customerId: 'cust-1', at: depositDay)
          .then((_) => repo.locksFor('cust-1'))
          .then((back) {
            expect(back.single.heldDiscountPct, Rational(1, 3));
            expect(
              back.single.heldDiscountPct * Rational.fromInt(3),
              Rational.one,
            );
          });
    });

    test('an unreadable percentage reads as no discount, not a crash', () async {
      // Zero over-quotes, and §8.5 promises the final never exceeds the quote.
      // A crash on the quote screen would cost the sale outright.
      await db
          .into(db.categoryLocks)
          .insert(
            CategoryLocksCompanion.insert(
              id: 'broken',
              customerId: 'cust-1',
              category: 'curtain',
              heldRateCardVersion: 1,
              heldDiscountPct: const Value('not a number'),
              heldUntil: DateTime(2027, 8, 29),
              createdAt: depositDay,
            ),
          );

      final back = await repo.locksFor('cust-1');
      expect(back.single.heldDiscountPct, Rational.zero);
    });

    test('one customer does not see another customer locks', () {
      // The lock is on customer plus category. Leaking one across customers
      // would hand a stranger twelve months of held prices.
      return repo
          .store(aLock(), customerId: 'cust-1', at: depositDay)
          .then((_) => repo.locksFor('cust-2'))
          .then((back) => expect(back, isEmpty));
    });

    test(
      'expired and cancelled rows are returned, not filtered away',
      () async {
        // The resolver checks status and date itself, because a handset offline
        // for a week holds rows the nightly job has not expired yet. Filtering
        // in SQL would hide that from it.
        await repo.store(
          CategoryLock(
            id: 'old',
            category: DepositCategory.curtain,
            heldRateCardVersion: 1,
            heldDiscountPct: Rational.zero,
            heldUntil: DateTime(2020, 1, 1),
            status: LockStatus.expired,
          ),
          customerId: 'cust-1',
          at: depositDay,
        );

        final back = await repo.locksFor('cust-1');
        expect(back, hasLength(1));
        expect(back.single.status, LockStatus.expired);
      },
    );
  });

  group('the prompt log', () {
    test('a decline is recorded as deliberately as a sale', () async {
      // The declined-deposit report is the whole point of §6.2's "log which
      // button was pressed".
      await repo.recordPrompt(
        quoteId: 'q1',
        category: DepositCategory.flooring,
        choice: DepositChoice.declined,
        categorySubtotalSen: 240000,
        at: depositDay,
      );

      final rows = await repo.promptsFor('q1');
      expect(rows, hasLength(1));
      expect(rows.single.choice, 'declined');
      expect(
        rows.single.categorySubtotalSen,
        240000,
        reason:
            'the report says what was left on the table, not just how often',
      );
    });

    test('it is append only — a second answer is a second row', () async {
      for (final choice in [DepositChoice.declined, DepositChoice.collected]) {
        await repo.recordPrompt(
          quoteId: 'q1',
          category: DepositCategory.flooring,
          choice: choice,
          categorySubtotalSen: 240000,
          at: depositDay,
        );
      }

      final rows = await repo.promptsFor('q1');
      expect(rows, hasLength(2), reason: 'the decline is still on the record');
      expect(rows.map((r) => r.choice), ['declined', 'collected']);
    });

    test('an answered category is not asked about again', () async {
      // Asking a customer who already said no, three windows later, is how a
      // part-timer ends up not asking at all.
      await repo.recordPrompt(
        quoteId: 'q1',
        category: DepositCategory.flooring,
        choice: DepositChoice.declined,
        categorySubtotalSen: 240000,
        at: depositDay,
      );

      expect(await repo.answeredOn('q1'), {DepositCategory.flooring});
    });

    test('a dismissal does not count as an answer', () async {
      // Nobody decided anything, so the question is still live.
      await repo.recordPrompt(
        quoteId: 'q1',
        category: DepositCategory.flooring,
        choice: DepositChoice.dismissed,
        categorySubtotalSen: 240000,
        at: depositDay,
      );

      expect(await repo.answeredOn('q1'), isEmpty);
      expect(
        await repo.promptsFor('q1'),
        hasLength(1),
        reason: 'it is still on the record that the question went unanswered',
      );
    });

    test('one quote does not inherit another answers', () async {
      await repo.recordPrompt(
        quoteId: 'q1',
        category: DepositCategory.flooring,
        choice: DepositChoice.declined,
        categorySubtotalSen: 240000,
        at: depositDay,
      );
      expect(await repo.answeredOn('q2'), isEmpty);
    });
  });

  test('only a fair deposit ever reaches storage', () {
    // The rule is enforced where the lock is built, so there is nothing to
    // store. This asserts the two halves are wired together.
    final refused = openCategoryLock(
      id: 'l',
      channel: Channel.showroom,
      category: DepositCategory.curtain,
      depositDate: depositDay,
      depositSen: 30000,
      minDepositSen: 30000,
      rateCardVersion: 1,
      promoPct: Rational.zero,
    );

    expect(refused.lock, isNull);
    expect(refused.refusedBecause, LockRefusal.notAFair);
  });

  group('the returning customer', () {
    // The case the twelve-month hold exists for, and the one that was broken.
    // The lock was keyed on the quote id, so the August deposit could never
    // match the March quote: the customer paid RM300 and was then quoted the
    // standard rate — more than the hold they bought, after the app had told
    // them the promo was held until next August. Nothing caught it because
    // nothing tested a second quote.

    QuoteState quoteFor({required String id, String? phone}) =>
        QuoteState(quoteId: id, channel: Channel.fair, customerPhone: phone);

    test('a hold bought in August prices a quote made in March', () async {
      await repo.store(
        aLock(),
        at: depositDay,
        customerId: customerKeyForQuote(
          quoteFor(id: 'q-august', phone: '012-345 6789'),
        ),
      );

      final inMarch = await repo.locksFor(
        customerKeyForQuote(quoteFor(id: 'q-march', phone: '+60123456789')),
      );

      expect(
        inMarch,
        hasLength(1),
        reason: 'the same customer, a new quote, and the hold they paid for',
      );
      expect(inMarch.single.category, DepositCategory.curtain);
    });

    test('a different phone gets nothing', () async {
      await repo.store(
        aLock(),
        at: depositDay,
        customerId: customerKeyForQuote(
          quoteFor(id: 'q-august', phone: '0123456789'),
        ),
      );

      expect(
        await repo.locksFor(
          customerKeyForQuote(quoteFor(id: 'q-march', phone: '0129999999')),
        ),
        isEmpty,
      );
    });

    test('two anonymous quotes never share a hold', () async {
      // The reason the key was the quote id in the first place, and it still
      // holds: with no usable phone the fallback keeps them apart.
      await repo.store(
        aLock(),
        at: depositDay,
        customerId: customerKeyForQuote(quoteFor(id: 'q-one')),
      );

      expect(
        await repo.locksFor(customerKeyForQuote(quoteFor(id: 'q-two'))),
        isEmpty,
      );
      expect(
        await repo.locksFor(customerKeyForQuote(quoteFor(id: 'q-one'))),
        hasLength(1),
        reason: 'within its own quote the hold still works',
      );
    });

    test('a phone too short to be one is treated as none', () async {
      // A fragment would match every other fragment, and hand one customer
      // another's held prices.
      await repo.store(
        aLock(),
        at: depositDay,
        customerId: customerKeyForQuote(quoteFor(id: 'q-one', phone: '0123')),
      );

      expect(
        await repo.locksFor(
          customerKeyForQuote(quoteFor(id: 'q-two', phone: '0123')),
        ),
        isEmpty,
      );
    });
  });
}
