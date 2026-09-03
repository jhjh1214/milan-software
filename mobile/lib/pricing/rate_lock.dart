/// Which rate card and which discount a line is priced at. SPEC.md §6.1.
///
/// The lock is on **customer plus category**, never on the order. One order can
/// carry curtain lines at held promo rates and flooring lines at standard
/// price, because only one RM300 was paid.
///
/// > **Hard rule.** A line whose category has no active lock must not be priced
/// > at a held version. *Silently applying a curtain lock to a flooring line is
/// > the expensive bug in this design.*
///
/// Three cases, and SPEC.md says plainly: **do not collapse them.**
///
/// 1. an active lock for this line's category — the held version and the held
///    percentage, both pinned at deposit time
/// 2. no lock, but the order came from a fair — today's card and today's promo
/// 3. anything else — the version the order was pinned to, and no discount
///
/// The cases in `shared/pricing-fixtures.json` under `rate_lock_cases` were
/// written before this file, as SPEC.md §6.1 asks, and the Python engine loads
/// the same ones.
///
/// Pure: no clock, no I/O, no Flutter imports. `today` and the locks are passed
/// in.
library;

import '../core/rational.dart';
import 'models.dart';

/// Where a line's price came from.
///
/// Named rather than inferred from the other fields, because the three cases
/// are the thing that must not be collapsed — and a test that can only compare
/// version numbers cannot tell case 2 from case 1 when they happen to agree.
enum RateSource {
  /// An RM300 deposit is holding this category's prices.
  held,

  /// At a fair, with no deposit yet for this category.
  fairCurrent,

  /// Everything else. Showroom, home visit, phone, referral.
  standardPinned,
}

/// Where an order came from. Every report segments by it (§3).
enum Channel {
  showroom('showroom'),
  homeVisit('home_visit'),
  fair('fair'),
  referral('referral'),
  phone('phone');

  const Channel(this.wire);

  final String wire;

  static Channel fromWire(String wire) =>
      Channel.values.firstWhere((c) => c.wire == wire);
}

/// The life of an RM300 hold.
enum LockStatus {
  active('active'),
  expired('expired'),
  cancelled('cancelled'),
  refunded('refunded');

  const LockStatus(this.wire);

  final String wire;

  static LockStatus fromWire(String wire) =>
      LockStatus.values.firstWhere((s) => s.wire == wire);
}

/// One RM300, holding one category's prices for twelve months.
class CategoryLock {
  final String id;
  final DepositCategory category;

  /// Pinned at deposit time, together with [heldDiscountPct]. Pinning only the
  /// version would silently reprice this customer when the promo percentage
  /// moves.
  final int heldRateCardVersion;
  final Rational heldDiscountPct;

  /// The **last day** the hold is good for, inclusive. A customer who arrives
  /// on that day was promised that price.
  final DateTime heldUntil;

  final LockStatus status;

  const CategoryLock({
    required this.id,
    required this.category,
    required this.heldRateCardVersion,
    required this.heldDiscountPct,
    required this.heldUntil,
    this.status = LockStatus.active,
  });

  /// Whether this hold still prices anything on [today].
  ///
  /// Status and date are both checked here. A cancelled row whose date has not
  /// passed is still not a price, and an active row whose date has is not
  /// either — the nightly job that flips `active` to `expired` may not have run
  /// on a handset that has been offline for a week.
  bool isActiveOn(DateTime today) {
    if (status != LockStatus.active) return false;
    final day = DateTime(today.year, today.month, today.day);
    final until = DateTime(heldUntil.year, heldUntil.month, heldUntil.day);
    return !day.isAfter(until);
  }
}

/// What a line is priced at, and why.
class RateBasis {
  final RateSource source;
  final int rateCardVersion;
  final Rational discountPct;

  /// The lock that decided it, or null when nothing did. Written onto the order
  /// line as `category_lock_id` so a price can still be explained a year later.
  final String? lockId;

  const RateBasis({
    required this.source,
    required this.rateCardVersion,
    required this.discountPct,
    this.lockId,
  });

  bool get isHeld => source == RateSource.held;
}

/// Decides the card and the discount for one line. SPEC.md §6.1.
///
/// [locks] is every lock the **customer** holds, not the order — a hold bought
/// at last August's fair prices a line added in the showroom in March.
RateBasis resolveRateBasis({
  required Family family,
  required List<CategoryLock> locks,
  required Channel channel,
  required int currentRateCardVersion,
  required Rational currentPromoPct,
  required int orderPinnedRateCardVersion,
  required DateTime today,

  /// The category the rule names outright, if it names one.
  DepositCategory? depositCategoryOverride,

  /// The family of the line this one attaches to, for add-ons and services.
  Family? parentFamily,
}) {
  final category =
      depositCategoryOverride ??
      depositCategoryOf(family, parentFamily: parentFamily);

  // Case 1. Only a lock on THIS category counts. Searching by category rather
  // than taking the first active lock is the whole hard rule.
  for (final lock in locks) {
    if (lock.category == category && lock.isActiveOn(today)) {
      return RateBasis(
        source: RateSource.held,
        rateCardVersion: lock.heldRateCardVersion,
        discountPct: lock.heldDiscountPct,
        lockId: lock.id,
      );
    }
  }

  // Case 2. At a fair, before any RM300 is paid. Fair prices today; nothing is
  // held, so the customer walks away with a price that is not promised.
  if (channel == Channel.fair) {
    return RateBasis(
      source: RateSource.fairCurrent,
      rateCardVersion: currentRateCardVersion,
      discountPct: currentPromoPct,
    );
  }

  // Case 3. "Showroom pays standard" (§3). The order's own pinned version, so a
  // publish halfway through an order cannot move a price the customer has
  // already been shown, and never a promo percentage — promo is fair-only.
  return RateBasis(
    source: RateSource.standardPinned,
    rateCardVersion: orderPinnedRateCardVersion,
    discountPct: Rational.zero,
  );
}
