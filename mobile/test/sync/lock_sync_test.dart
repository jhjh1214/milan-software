/// Learning about a hold this handset did not take. SPEC.md §6.1, §13 B9.
///
/// The scenario, end to end: six phones work a fair, the customer deposits on
/// phone 3, and in March walks into the showroom where phone 1 is used. Phone 1
/// has never seen that hold. Without the pull it quotes the standard rate —
/// more than the customer paid RM300 to be protected from.
///
/// The other half of what is checked here is that the pull is safe when it goes
/// wrong. Offline is the default (§9), so a failure has to be silent and
/// harmless, and a pulled row must never overwrite a deposit taken on this
/// handset and not yet pushed.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/rational.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/lock_repository.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/pricing/rate_lock.dart';
import 'package:milan_quote/sync/api_client.dart';
import 'package:milan_quote/sync/lock_sync.dart';

import 'fake_server.dart';

const credentials = Credentials(
  token: 'good-token',
  user: Identity(id: 'u1', name: 'Ah Lian', role: 'parttime', language: 'zh'),
);

final inMarch = DateTime(2027, 3, 14);

void main() {
  late AppDatabase db;
  late FakeServer server;
  late LockSync sync;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    server = FakeServer();
    sync = LockSync(
      db: db,
      api: ApiClient(
        baseUrl: Uri.parse('https://example.test'),
        client: server.client,
        timeout: const Duration(milliseconds: 200),
      ),
    );
  });

  tearDown(() => db.close());

  /// A hold the server knows about, taken on some other handset.
  void serverHolds({
    String id = 'lock-from-phone-3',
    String category = 'curtain',
    String pct = '1/10',
    String status = 'active',
    DateTime? until,
  }) {
    server.heldRates.putIfAbsent('phone:0123456789', () => []).add({
      'id': id,
      'customer_key': 'phone:0123456789',
      'category': category,
      'held_rate_card_version': 1,
      'held_discount_pct': pct,
      'held_until': (until ?? DateTime.utc(2027, 8, 29)).toIso8601String(),
      'status': status,
    });
  }

  Future<int> pull() => sync.pullFor(
    credentials: credentials,
    customerKey: 'phone:0123456789',
    at: inMarch,
  );

  test('a hold taken on another handset arrives, and prices', () async {
    serverHolds();
    expect(await pull(), 1);

    final locks = await LockRepository(db).locksFor('phone:0123456789');
    expect(locks, hasLength(1));

    final lock = locks.single;
    expect(lock.category, DepositCategory.curtain);
    expect(
      lock.heldDiscountPct,
      Rational(1, 10),
      reason: 'the percentage is pinned too, not only the version',
    );
    expect(
      lock.isActiveOn(inMarch),
      isTrue,
      reason: 'this is the whole point — in March it still holds',
    );
  });

  test('pulling twice adds nothing the second time', () async {
    serverHolds();
    expect(await pull(), 1);
    expect(await pull(), 0);
    expect(await LockRepository(db).locksFor('phone:0123456789'), hasLength(1));
  });

  test('it never overwrites a hold taken here', () async {
    // The local row is the one somebody on this handset watched the money
    // change hands for. A stale server copy must not replace it.
    final grant = openCategoryLock(
      id: 'lock-from-phone-3',
      channel: Channel.fair,
      category: DepositCategory.curtain,
      depositDate: DateTime(2026, 8, 29),
      // A card with no fair dates: the year counts from the deposit day,
      // which keeps this test about storage rather than the grant rule.
      fairEndsOn: null,
      depositSen: 30000,
      minDepositSen: 30000,
      rateCardVersion: 7,
      promoPct: Rational(1, 5),
    );
    await LockRepository(db).store(
      grant.lock!,
      customerId: 'phone:0123456789',
      at: DateTime(2026, 8, 29),
    );

    serverHolds(pct: '0');
    expect(await pull(), 0);

    final lock = (await LockRepository(db).locksFor('phone:0123456789')).single;
    expect(lock.heldRateCardVersion, 7);
    expect(lock.heldDiscountPct, Rational(1, 5));
  });

  test('two categories both arrive', () async {
    serverHolds(id: 'lock-curtain', category: 'curtain');
    serverHolds(id: 'lock-flooring', category: 'flooring');
    expect(await pull(), 2);

    final categories = (await LockRepository(
      db,
    ).locksFor('phone:0123456789')).map((l) => l.category).toSet();
    expect(categories, {DepositCategory.curtain, DepositCategory.flooring});
  });

  test('a customer with no holds is not an error', () async {
    expect(await pull(), 0);
    expect(await LockRepository(db).locksFor('phone:0123456789'), isEmpty);
  });

  group('when it goes wrong', () {
    test('no signal adds nothing and raises nothing', () async {
      // §9: offline is the default, not a fallback. The quote is priced from
      // what this handset knows, which is what it did before this existed.
      serverHolds();
      server.offline = true;
      expect(await pull(), 0);
      expect(await LockRepository(db).locksFor('phone:0123456789'), isEmpty);
    });

    test('a rejected request adds nothing and raises nothing', () async {
      serverHolds();
      server.rejectLocks = true;
      expect(await pull(), 0);
    });

    test('a stale hold is stored, and the resolver decides', () async {
      // Expiry is not filtered on either side. A handset offline for a week
      // needs the row to judge against the date it is pricing on — filtering
      // here would hide a hold from a quote taken yesterday.
      serverHolds(until: DateTime.utc(2026, 12, 31));
      expect(await pull(), 1);

      final lock = (await LockRepository(
        db,
      ).locksFor('phone:0123456789')).single;
      expect(lock.isActiveOn(inMarch), isFalse);
      expect(lock.isActiveOn(DateTime(2026, 12, 1)), isTrue);
    });
  });
}
