/// Every price somebody moved by hand this week. SPEC.md §6.5.
///
/// This screen is not a report. It is the control:
///
/// > An offline PIN is bypassable, and one shared admin password reaches every
/// > part-timer within a month. The real control is the audit log plus a weekly
/// > review screen, not the gate. Individual PINs so the log names a person,
/// > and build the "overrides this week" screen — **without it the log is never
/// > read and the control does not exist.**
///
/// Which is why it is deliberately plain and deliberately short. Every row says
/// three things — who, how much, and why — and nothing else competes with them.
/// A screen with more on it is one that gets skimmed, and a skimmed audit log is
/// the same as no audit log.
///
/// The week runs Monday to Monday, half-open, so a row lands in exactly one week
/// rather than in two or in neither.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/money.dart';
import '../../data/database.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../quote/confirm_order.dart';
import '../quote/quote_state.dart';

/// The Monday on or before [day], at midnight.
///
/// Monday because that is how the shop talks about a week, and midnight because
/// an override at 9am Monday belongs to the week that starts that morning.
DateTime weekStart(DateTime day) {
  final midnight = DateTime(day.year, day.month, day.day);
  return midnight.subtract(Duration(days: midnight.weekday - DateTime.monday));
}

/// This week's overrides, newest first.
final overridesThisWeekProvider = FutureProvider<List<PriceOverrideRow>>((
  ref,
) async {
  final from = weekStart(ref.watch(todayProvider));
  return ref
      .watch(orderRepositoryProvider)
      .overridesBetween(from: from, to: from.add(const Duration(days: 7)));
});

class OverridesReviewScreen extends ConsumerWidget {
  const OverridesReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final rows = ref.watch(overridesThisWeekProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(l.overridesThisWeek)),
      body: rows.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (overrides) {
          if (overrides.isEmpty) {
            // Said in words. An empty list reads as "not loaded yet", and this
            // screen has to be trustworthy about a week in which nothing
            // happened.
            return Padding(
              padding: const EdgeInsets.all(Space.xl),
              child: Text(l.overridesNone, style: AppText.body),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(Space.lg),
            itemCount: overrides.length,
            separatorBuilder: (_, _) => const Divider(height: Space.xl),
            itemBuilder: (context, i) => _Row(row: overrides[i]),
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row});

  final PriceOverrideRow row;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final delta = row.afterSen - row.beforeSen;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l.overrideRow(
                  Money.sen(row.beforeSen).format(),
                  Money.sen(row.afterSen).format(),
                  row.adminUserId,
                ),
                style: AppText.bodyStrong,
              ),
            ),
            // The direction, in colour, so a week's worth can be scanned. A
            // discount is the ordinary case; a price going up is the one worth
            // a second look.
            Text(
              Money.sen(delta).format(),
              style: AppText.money.copyWith(
                color: delta < 0 ? AppColors.warning : AppColors.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.xs),
        // The reason as it was typed. Summarising it here would lose the thing
        // the review exists to read.
        Text(row.reason, style: AppText.body),
        const SizedBox(height: Space.xs),
        Text(formatDateTime(row.at), style: AppText.caption),
      ],
    );
  }
}
