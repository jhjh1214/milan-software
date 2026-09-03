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

/// Decides a quote's channel from the handset setting and the card.
///
/// Client, Sep 2026, asked how the app should know it is at a fair:
/// *"Quotation normally is only at fair anyway, but make a toggle I guess with
/// date window."*
///
/// So: a toggle, **bounded by the promo window on the rate card**. The window
/// is what grants a fair price; the switch only says the handset is at the fair
/// that window describes. Outside those dates this returns `showroom` however
/// the switch is set, so nobody can leave it on and quote promo rates through
/// September.
///
/// That guard is why the toggle can default to on: there is no state a
/// part-timer can leave the handset in that gives a price away, and no step to
/// remember before the first quote of a fair.
///
/// Pure, and takes the card rather than reading it, so the fair-day boundary is
/// testable without waiting for August.
Channel channelFor({
  required bool fairModeEnabled,
  required RateCard fairCard,
  required DateTime today,
}) {
  if (!fairModeEnabled) return Channel.showroom;
  // The card's own promo window, inclusive of the final day. A fair that ended
  // yesterday cannot price today, whatever the switch says.
  return fairCard.isExpiredOn(today) ? Channel.showroom : Channel.fair;
}

/// The life of an RM300 hold.
enum LockStatus {
  active('active'),
  expired('expired'),
  cancelled('cancelled'),
  refunded('refunded'),

  /// A second RM300 arrived for a category this customer already held.
  ///
  /// Two handsets at one busy fair, each taking a deposit for the same thing.
  /// Both payments are real. The first hold keeps pricing and this one is
  /// parked, because §6.1 allows only one active lock per customer and
  /// category -- and dropping the row instead would lose a payment nobody
  /// could then find. Which RM300 gets refunded is §13 B10, and is a person's
  /// decision.
  superseded('superseded');

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

/// Why an RM300 did not open a lock.
enum LockRefusal {
  /// Not taken at a fair. Client, Sep 2026: *"no second rm300 paid later in
  /// showroom, only depo at fair can lock price."*
  notAFair('not_a_fair'),

  /// Less than the configured deposit. RM250 is not RM300.
  belowMinimum('below_minimum');

  const LockRefusal(this.wire);

  final String wire;
}

/// The outcome of trying to open a lock: the row, or the reason there is none.
class LockGrant {
  final CategoryLock? lock;
  final LockRefusal? refusedBecause;

  const LockGrant.granted(CategoryLock this.lock) : refusedBecause = null;
  const LockGrant.refused(LockRefusal this.refusedBecause) : lock = null;

  bool get granted => lock != null;
}

/// Opens a category lock, or explains why it cannot. SPEC.md §6.1, §13 B1.
///
/// **The only place a `category_locks` row is created.** Both rules live here
/// rather than on the screen that collects the money, so a screen that forgets
/// one cannot bypass it:
///
/// - **Only a fair.** A showroom, home-visit, phone or referral deposit
///   confirms an order and buys nothing else. There is no way to acquire held
///   prices after the fair has packed up.
/// - **The full RM300.** Checked here rather than trusted from the caller: a
///   partial payment must not buy a full twelve-month hold.
///
/// [promoPct] is pinned alongside the version, because pinning only the version
/// silently reprices this customer when the promo moves.
LockGrant openCategoryLock({
  required String id,
  required Channel channel,
  required DepositCategory category,
  required DateTime depositDate,
  required int depositSen,
  required int minDepositSen,
  required int rateCardVersion,
  required Rational promoPct,
}) {
  if (channel != Channel.fair) {
    return const LockGrant.refused(LockRefusal.notAFair);
  }
  if (depositSen < minDepositSen) {
    return const LockGrant.refused(LockRefusal.belowMinimum);
  }

  return LockGrant.granted(
    CategoryLock(
      id: id,
      category: category,
      heldRateCardVersion: rateCardVersion,
      heldDiscountPct: promoPct,
      heldUntil: twelveMonthsFrom(depositDate),
      status: LockStatus.active,
    ),
  );
}

/// The last day a hold taken on [depositDate] is good for.
///
/// The same day of the month, twelve months on, **clamped to the end of the
/// month**. 29 February has no anniversary, so a leap-day deposit runs to 28
/// February — which is what a calendar does with a monthly anniversary and what
/// a person reading "12 months" would say.
///
/// Built by hand rather than with `DateTime(y, m + 12, d)`, because Dart rolls
/// an out-of-range day forward: `DateTime(2029, 2, 29)` silently becomes 1
/// March, quietly extending the hold by a day.
DateTime twelveMonthsFrom(DateTime depositDate) {
  final year = depositDate.year + 1;
  final month = depositDate.month;
  final lastDayOfThatMonth = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, depositDate.day.clamp(1, lastDayOfThatMonth));
}
