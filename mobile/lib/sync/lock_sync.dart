/// Learning about holds this handset did not take. SPEC.md §6.1, §13 B9.
///
/// A hold is bought once and used later, possibly on a different phone. Six
/// handsets work a fair: the customer deposits on phone 3, and walks into the
/// showroom in March where phone 1 is used. Phone 1 has never seen that hold,
/// so without this it quotes the standard rate — more than the customer paid
/// RM300 to be protected from.
///
/// ## Best effort, always
///
/// Offline is the default (§9), so this never blocks anything and never
/// reports an error to a screen. With no signal the handset simply prices from
/// what it knows, which is what it did before this existed. The hold is not
/// lost; it is on the server, and the next connection finds it.
///
/// ## It only ever adds
///
/// A pulled hold is inserted if the device does not already have that id, and
/// otherwise left alone. Overwriting would let a stale server row replace a
/// deposit taken here five minutes ago and not yet pushed — the one row that
/// is definitely real, because somebody on this handset watched the money
/// change hands.
library;

import 'package:drift/drift.dart';

import '../data/database.dart';
import 'api_client.dart';

class LockSync {
  const LockSync({required this.db, required this.api});

  final AppDatabase db;
  final ApiClient api;

  /// Fetches this customer's holds and stores any the device does not have.
  ///
  /// Returns how many were new, for a log line. Returns zero on any failure —
  /// there is nothing a customer-facing screen could usefully do with a
  /// network error here, and the price it quotes is honest either way.
  Future<int> pullFor({
    required Credentials credentials,
    required String customerKey,
    required DateTime at,
  }) async {
    final result = await api.locksFor(credentials.token, customerKey);
    if (result is! SyncOk<List<HeldRate>>) return 0;

    var added = 0;
    for (final held in result.value) {
      final existing = await (db.select(
        db.categoryLocks,
      )..where((l) => l.id.equals(held.id))).getSingleOrNull();
      if (existing != null) continue;

      await db
          .into(db.categoryLocks)
          .insert(
            CategoryLocksCompanion.insert(
              id: held.id,
              customerId: held.customerKey,
              category: held.category,
              heldRateCardVersion: held.heldRateCardVersion,
              heldDiscountPct: Value(held.heldDiscountPct),
              heldUntil: held.heldUntil,
              status: Value(held.status),
              // The date it was opened is not sent back: this row is a copy of
              // something that happened on another handset, and the only thing
              // this one can say honestly is when it learned about it.
              createdAt: at,
              // It came from the server, so it is already there.
              syncedAt: Value(at),
            ),
          );
      added++;
    }
    return added;
  }
}
