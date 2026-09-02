/// Pulling prices down. §9.1, and the Phase 3 promise that prices are
/// server-owned.
///
/// One card, published once, pulled by every handset. The failure this exists
/// to prevent is concrete: in Phase 2 an admin could edit prices on a device,
/// and six handsets at one fair could each hold a different list. A customer
/// walking from one table to the next got two numbers.
///
/// Three rules shape the implementation:
///
/// 1. **Never block the UI.** A pull that fails is a quiet line on the rates
///    screen, not a dialog and never a barrier to quoting.
/// 2. **Replace wholesale, never merge.** A merged price list is one nobody has
///    read end to end.
/// 3. **A locally edited card is always re-pulled**, whatever version it
///    claims. Its version number was invented on the device, so comparing it
///    against the server's means nothing.
library;

import '../data/rate_card_store.dart';
import 'api_client.dart';

/// What one pull did.
class RateCardPull {
  /// Lists whose card was replaced, and the version now held.
  final Map<PriceList, int> updated;

  /// Lists the handset was already current on. §9.1 sends no payload for
  /// these, so a fair's connection is not spent on them.
  final List<PriceList> alreadyCurrent;

  /// Why the pull stopped, if it did. Null means everything was attempted.
  final SyncFailure? failure;

  /// True when a Phase 2 on-device edit was replaced by the server's card.
  /// Worth telling an admin about — the price they typed is gone.
  final bool discardedLocalEdit;

  const RateCardPull({
    this.updated = const {},
    this.alreadyCurrent = const [],
    this.failure,
    this.discardedLocalEdit = false,
  });

  bool get ok => failure == null;
  bool get changedAnything => updated.isNotEmpty;
}

class RateCardSync {
  final ApiClient api;
  final RateCardStore store;

  /// Injected, per CLAUDE.md: nothing reads the clock directly, so "prices as
  /// of ..." is testable.
  final DateTime Function() clock;

  RateCardSync({
    required this.api,
    required this.store,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  /// Pulls both lists. Safe to call on every launch and every reconnect.
  ///
  /// Both, not just the one in force today: a fair in August must already hold
  /// the standard list for September, and the day it switches over is not a day
  /// anyone will have a connection to spare.
  Future<RateCardPull> pull(Credentials credentials) async {
    final updated = <PriceList, int>{};
    final current = <PriceList>[];
    var discarded = false;

    for (final list in PriceList.values) {
      final held = await store.provenance(list);

      // Only claim to be current when the held card actually came from the
      // server. A bundled or locally edited card's version was decided on the
      // device, so sending it would let a coincidental match leave a stale — or
      // hand-edited — list in place forever.
      final since = held.isServerOwned ? held.version : null;

      final result = await api.bundle(
        token: credentials.token,
        listId: list.id,
        sinceVersion: since,
      );

      switch (result) {
        case SyncFailed(:final failure):
          // Stop at the first failure rather than hammering a connection that
          // is not there. Whatever landed before it stays.
          return RateCardPull(
            updated: updated,
            alreadyCurrent: current,
            failure: failure,
            discardedLocalEdit: discarded,
          );

        case SyncOk(value: final bundle):
          if (bundle.upToDate || bundle.payload == null) {
            current.add(list);
            continue;
          }
          try {
            await store.adoptServerCard(
              list,
              bundle.payload!,
              at: clock().toUtc(),
            );
          } catch (_) {
            // A card this app cannot parse — an older handset meeting a newer
            // format, most likely. Keep the one that works and report it. The
            // alternative is a crash in front of a customer, or worse, storing
            // it and leaving the handset unable to price anything.
            return RateCardPull(
              updated: updated,
              alreadyCurrent: current,
              failure: SyncFailure.serverError,
              discardedLocalEdit: discarded,
            );
          }
          updated[list] = bundle.version;
          if (held.origin == RateCardOrigin.local) discarded = true;
      }
    }

    return RateCardPull(
      updated: updated,
      alreadyCurrent: current,
      discardedLocalEdit: discarded,
    );
  }
}
