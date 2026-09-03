/// What the deposit prompt actually earned. SPEC.md §6.2 and §11 Phase 4.
///
/// > Declined category deposits appear in a report
///
/// The count is not the point. `leftOnTheTable` is: what a fair quoted in a
/// category and did not take a deposit on. That is the number that says whether
/// the prompt is worth having at all, and whether the answer to a bad week is
/// training or a different question.
///
/// Dismissals are kept apart from declines throughout. "They said no" and
/// "nobody got an answer" are different problems and only one of them is the
/// customer's — collapsing them would blame a customer for a conversation that
/// never finished, and make a busy stall look like a bad one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/rational.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/deposit_prompt.dart';
import '../../pricing/models.dart';
import '../../ui/theme.dart';
import '../quote/deposit_prompt_sheet.dart'
    show categoryLabel, lockRepositoryProvider;
import '../quote/quote_state.dart';
import 'overrides_review_screen.dart' show weekStart;

/// This week's prompts, grouped by category.
final declinesThisWeekProvider = FutureProvider<List<CategoryDeclines>>((
  ref,
) async {
  final from = weekStart(ref.watch(todayProvider));
  final rows = await ref
      .watch(lockRepositoryProvider)
      .promptsBetween(from: from, to: from.add(const Duration(days: 7)));

  return summariseDeposits([
    for (final row in rows)
      PromptOutcome(
        category: DepositCategory.values.byName(row.category),
        choice: DepositChoice.fromWire(row.choice),
        categorySubtotal: Money.sen(row.categorySubtotalSen),
      ),
  ]);
});

class DeclinesReportScreen extends ConsumerWidget {
  const DeclinesReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final report = ref.watch(declinesThisWeekProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(l.declinesTitle)),
      body: report.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (categories) {
          if (categories.isEmpty) {
            // In words. An empty list reads as "failed to load", and a week in
            // which nobody was asked is a real answer worth trusting.
            return Padding(
              padding: const EdgeInsets.all(Space.xl),
              child: Text(l.declinesNone, style: AppText.body),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(Space.lg),
            itemCount: categories.length,
            separatorBuilder: (_, _) => const Divider(height: Space.xl),
            itemBuilder: (context, i) => _CategoryBlock(row: categories[i]),
          );
        },
      ),
    );
  }
}

class _CategoryBlock extends StatelessWidget {
  const _CategoryBlock({required this.row});

  final CategoryDeclines row;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final rate = row.takeRate;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(categoryLabel(l, row.category), style: AppText.title),
        const SizedBox(height: Space.sm),

        // The number the report exists for: what was quoted in this category
        // and not deposited on.
        Text(
          l.declinesLeftOnTable(row.leftOnTheTable.format()),
          style: AppText.money.copyWith(color: AppColors.warning),
        ),
        const SizedBox(height: Space.md),

        Text(l.declinesAsked(row.asked), style: AppText.body),
        Text(l.declinesTook(row.collected), style: AppText.caption),
        if (row.declined > 0)
          Text(l.declinesSaidNo(row.declined), style: AppText.caption),
        if (row.linesRemoved > 0)
          Text(l.declinesRemoved(row.linesRemoved), style: AppText.caption),
        if (row.dismissed > 0)
          // Its own line, never folded into the declines. A dismissal is a
          // conversation that did not finish, which is a training problem
          // rather than a customer one.
          Text(
            l.declinesDismissed(row.dismissed),
            style: AppText.caption.copyWith(color: AppColors.mutedForeground),
          ),

        if (rate != null) ...[
          const SizedBox(height: Space.sm),
          Text(
            l.declinesTakeRate(
              (rate * const Rational.fromInt(100)).roundHalfUpToInt(),
            ),
            style: AppText.bodyStrong,
          ),
        ],
      ],
    );
  }
}
