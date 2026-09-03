/// How fair mode looks on screen.
///
/// The rule itself is `channelFor` in `pricing/rate_lock.dart`, beside the
/// channel it produces. What is here is only the wording problem: a switch that
/// is on while the prices are standard needs to say so, or somebody re-enters a
/// quote thinking the app got it wrong.
library;

import '../../pricing/models.dart';

/// What the fair switch is actually doing right now.
enum FairModeState {
  /// On, inside the promo window. Quotes are fair and an RM300 locks.
  active,

  /// On, but the promo window has passed. Quotes are standard and an RM300
  /// locks nothing — the window is the guard, not the switch.
  outsideWindow,

  /// Off. Quotes are standard.
  off,
}

FairModeState fairModeState({
  required bool fairModeEnabled,
  required RateCard fairCard,
  required DateTime today,
}) {
  if (!fairModeEnabled) return FairModeState.off;
  return fairCard.isExpiredOn(today)
      ? FairModeState.outsideWindow
      : FairModeState.active;
}
