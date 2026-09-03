/// Money recorded, on a real database. SPEC.md §6.4.
///
/// The rules are in `pricing/cash_up.dart` and tested there. What is checked
/// here is that a payment survives storage and reaches the right day — a
/// deposit that lands on the wrong day makes the cash-up disagree with the tin,
/// and the person holding the tin is the one who has to explain it.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/money.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/payment_repository.dart';
import 'package:milan_quote/pricing/cash_up.dart';

void main() {
  late AppDatabase db;
  late PaymentRepository repo;

  final morning = DateTime(2026, 8, 29, 9, 30);
  final evening = DateTime(2026, 8, 29, 20, 15);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = PaymentRepository(db);
  });

  tearDown(() => db.close());

  Future<String> take(
    int sen, {
    DateTime? at,
    PaymentMethod method = PaymentMethod.cash,
    PaymentKind kind = PaymentKind.deposit,
    String quoteId = 'q1',
    String? byUserId,
  }) => repo.record(
    id: 'pay-${DateTime.now().microsecondsSinceEpoch}-$sen-${method.wire}',
    quoteId: quoteId,
    kind: kind,
    method: method,
    amountSen: sen,
    takenAt: at ?? morning,
    takenByUserId: byUserId,
  );

  group('a recorded payment', () {
    test('is written down immediately, with no server', () async {
      // §6.4: "Works fully offline; nothing needs authorising."
      await take(30000);
      final rows = await repo.forQuote('q1');

      expect(rows, hasLength(1));
      expect(rows.single.amountSen, 30000);
      expect(rows.single.method, 'cash');
      expect(rows.single.kind, 'deposit');
    });

    test('carries no receipt number until the server issues one', () async {
      // CLAUDE.md: server-issued, null until sync, shown as "pending sync",
      // never fabricated on-device. It goes on a legal document, and two
      // handsets offline at one fair would invent the same number.
      await take(30000);
      expect((await repo.forQuote('q1')).single.receiptNo, isNull);
      expect((await repo.forQuote('q1')).single.syncedAt, isNull);
    });

    test('lands as pending, not settled', () async {
      expect((await repo.forQuote('q1')).length, 0);
      await take(30000);
      expect((await repo.forQuote('q1')).single.status, 'pending');
    });

    test('one quote does not see another quote money', () async {
      await take(30000, quoteId: 'q1');
      await take(50000, quoteId: 'q2');
      expect(await repo.forQuote('q1'), hasLength(1));
      expect((await repo.forQuote('q2')).single.amountSen, 50000);
    });

    test('payments come back oldest first', () async {
      await take(30000, at: evening);
      await take(10000, at: morning);
      expect((await repo.forQuote('q1')).map((p) => p.amountSen), [
        10000,
        30000,
      ]);
    });
  });

  group('the day it belongs to', () {
    test('everything taken today is counted', () async {
      await take(30000, at: morning);
      await take(30000, at: evening);
      final day = await repo.cashUp(morning);
      expect(day.expectedTotal, Money.sen(60000));
    });

    test('a payment at 11pm is still today', () async {
      // The boundary that matters at a fair: the stall closes late and the
      // cash-up happens after it.
      await take(30000, at: DateTime(2026, 8, 29, 23, 59, 59));
      expect((await repo.cashUp(morning)).expectedTotal, Money.sen(30000));
    });

    test('a payment at midnight is tomorrow', () async {
      await take(30000, at: DateTime(2026, 8, 30));
      expect((await repo.cashUp(morning)).byMethod, isEmpty);
      expect(
        (await repo.cashUp(DateTime(2026, 8, 30))).expectedTotal,
        Money.sen(30000),
      );
    });

    test('yesterday is not in today', () async {
      await take(30000, at: DateTime(2026, 8, 28, 23, 59));
      expect((await repo.cashUp(morning)).byMethod, isEmpty);
    });

    test('one person cashes up their own day', () async {
      // Per user, per §6.4: two part-timers on one stall each hold their own
      // float, and a combined number tells neither of them anything.
      await take(30000, byUserId: 'ah-lian');
      await take(50000, byUserId: 'ah-meng');

      final lian = await repo.cashUp(morning, byUserId: 'ah-lian');
      expect(lian.expectedTotal, Money.sen(30000));

      final meng = await repo.cashUp(morning, byUserId: 'ah-meng');
      expect(meng.expectedTotal, Money.sen(50000));
    });

    test('a refund on the same day comes off the total', () async {
      await take(30000);
      await take(30000, kind: PaymentKind.refund);
      final day = await repo.cashUp(morning);

      expect(day.expectedTotal, Money.zero);
      expect(
        day.byMethod,
        hasLength(1),
        reason: 'a day that nets to zero is not a day with no payments',
      );
    });

    test('counting the tin reconciles against it', () async {
      await take(30000);
      await take(30000);
      final day = await repo.cashUp(
        morning,
        counted: {PaymentMethod.cash: Money.sen(55000)},
      );

      expect(day.discrepancies, hasLength(1));
      expect(day.discrepancies.single.variance, Money.sen(-5000));
    });
  });

  group('a deposit and the hold it bought', () {
    test('the two point at each other', () async {
      // A refund has to find the lock it cancels, and a lock has to be
      // explainable by the money that opened it.
      final paymentId = await take(30000);
      await db
          .into(db.categoryLocks)
          .insert(
            CategoryLocksCompanion.insert(
              id: 'lock-1',
              customerId: 'q1',
              category: 'curtain',
              heldRateCardVersion: 1,
              heldUntil: DateTime(2027, 8, 29),
              createdAt: morning,
            ),
          );

      await repo.linkToLock(paymentId: paymentId, lockId: 'lock-1');

      expect((await repo.forQuote('q1')).single.categoryLockId, 'lock-1');
      final lock = await (db.select(
        db.categoryLocks,
      )..where((l) => l.id.equals('lock-1'))).getSingle();
      expect(lock.depositPaymentId, paymentId);
    });

    test('a deposit with no hold is still money on the record', () async {
      // A showroom RM300 confirms an order and locks nothing. Losing the
      // payment because there is no lock to hang it on would lose the sale.
      final paymentId = await take(30000);
      final row = (await repo.forQuote('q1')).single;
      expect(row.id, paymentId);
      expect(row.categoryLockId, isNull);
      expect(row.amountSen, 30000);
    });
  });
}
