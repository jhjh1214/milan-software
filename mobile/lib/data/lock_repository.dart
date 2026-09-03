/// Reading and writing rate locks, and the log of who was asked for one.
///
/// The rules are not here. `openCategoryLock` in `pricing/rate_lock.dart`
/// decides whether a lock may exist at all, and this file only stores what it
/// returns — so there is no second place where "a showroom deposit does not
/// lock" could quietly stop being true.
library;

import 'package:drift/drift.dart';

import '../core/rational.dart';
import '../pricing/deposit_prompt.dart';
import '../pricing/models.dart';
import '../pricing/rate_lock.dart';
import 'database.dart';
import 'quote_repository.dart' show newId;

class LockRepository {
  final AppDatabase _db;

  LockRepository(this._db);

  /// Every lock this customer holds, in whatever state.
  ///
  /// Not filtered to active here: the resolver checks status *and* date itself,
  /// because a handset offline for a week may hold a row the nightly job has
  /// not expired yet. Filtering in SQL would hide that from it.
  Future<List<CategoryLock>> locksFor(String customerId) async {
    final rows = await (_db.select(
      _db.categoryLocks,
    )..where((l) => l.customerId.equals(customerId))).get();
    return rows.map(_toLock).toList(growable: false);
  }

  /// Stores a lock the pricing rules have already agreed to.
  ///
  /// Takes a [CategoryLock] rather than the raw inputs on purpose: the only way
  /// to get one is from `openCategoryLock`, so a caller cannot assemble a lock
  /// the business does not sell.
  Future<void> store(
    CategoryLock lock, {
    required String customerId,
    required DateTime at,
    String? depositPaymentId,
  }) => _db
      .into(_db.categoryLocks)
      .insert(
        CategoryLocksCompanion.insert(
          id: lock.id,
          customerId: customerId,
          category: lock.category.name,
          depositPaymentId: Value(depositPaymentId),
          heldRateCardVersion: lock.heldRateCardVersion,
          heldDiscountPct: Value(lock.heldDiscountPct.toString()),
          heldUntil: lock.heldUntil,
          status: Value(lock.status.wire),
          createdAt: at,
        ),
      );

  /// Records that the prompt was shown and what was pressed. §6.2.
  ///
  /// Append only. A different answer later is a second row, because the
  /// declined-deposit report is about what happened, not about the last thing
  /// that happened.
  Future<void> recordPrompt({
    required String quoteId,
    required DepositCategory category,
    required DepositChoice choice,
    required int categorySubtotalSen,
    required DateTime at,
    String? byUserId,
  }) => _db
      .into(_db.depositPrompts)
      .insert(
        DepositPromptsCompanion.insert(
          id: newId(),
          quoteId: quoteId,
          category: category.name,
          choice: choice.wire,
          categorySubtotalSen: Value(categorySubtotalSen),
          byUserId: Value(byUserId),
          at: at,
        ),
      );

  /// What was asked on one quote, oldest first.
  Future<List<DepositPromptRow>> promptsFor(String quoteId) =>
      (_db.select(_db.depositPrompts)
            ..where((p) => p.quoteId.equals(quoteId))
            ..orderBy([(p) => OrderingTerm.asc(p.at)]))
          .get();

  /// Every prompt put in a period, oldest first. SPEC.md §11 Phase 4:
  /// *"Declined category deposits appear in a report."*
  ///
  /// [from] is inclusive and [to] exclusive, so one prompt lands in exactly one
  /// period rather than in two or in neither.
  Future<List<DepositPromptRow>> promptsBetween({
    required DateTime from,
    required DateTime to,
  }) =>
      (_db.select(_db.depositPrompts)
            ..where(
              (p) =>
                  p.at.isBiggerOrEqualValue(from) & p.at.isSmallerThanValue(to),
            )
            ..orderBy([(p) => OrderingTerm.asc(p.at)]))
          .get();

  /// Which categories have already been answered on this quote, so the prompt
  /// does not reappear on every line the customer adds.
  ///
  /// Answered, not *paid*: a customer who said no once should not be asked
  /// again three windows later. The report still has the decline.
  Future<Set<DepositCategory>> answeredOn(String quoteId) async {
    final rows = await promptsFor(quoteId);
    return {
      for (final row in rows)
        if (row.choice != DepositChoice.dismissed.wire)
          DepositCategory.values.byName(row.category),
    };
  }

  CategoryLock _toLock(CategoryLockRow row) => CategoryLock(
    id: row.id,
    category: DepositCategory.values.byName(row.category),
    heldRateCardVersion: row.heldRateCardVersion,
    // A stored percentage that cannot be parsed is treated as no discount
    // rather than crashing the quote screen. Zero is the safe direction: it
    // over-quotes, and §8.5 promises the final never exceeds the quote.
    heldDiscountPct: Rational.tryParse(row.heldDiscountPct) ?? Rational.zero,
    heldUntil: row.heldUntil,
    status: LockStatus.fromWire(row.status),
  );
}
