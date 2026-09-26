/// Changing one price, in the app.
///
/// The CSV route is for a whole-list revision. This is for the phone call that
/// says "night curtain goes up two ringgit from Monday" — the case where
/// exporting a spreadsheet, opening Excel and importing it back is absurd.
///
/// It is also the fair-table one: staff answering a competitor on a single
/// item. So it goes through the server's live price route — staff or admin,
/// a mandatory reason recorded against whoever made the change — rather than
/// republishing a whole card built on this phone, which would leave no record
/// of who moved the price or why. The server publishes the new version; this
/// handset pulls it straight back.
///
/// The typed values are still read by [editSingleRate], the same parser the
/// CSV route uses, so there is one set of rules about what a price may be.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/models.dart';
import '../../pricing/price_edit.dart';
import '../../pricing/rate_card_csv.dart';
import '../../sync/api_client.dart';
import '../../sync/sync_state.dart';
import '../../ui/theme.dart';
import '../quote/quote_state.dart';

/// Lets staff or an admin pick a product and change its rate. Returns true if
/// a change was published.
Future<bool> showEditRateSheet(
  BuildContext context,
  WidgetRef ref,
  RateCard card,
) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (_) => _EditRateSheet(card: card),
  );
  return result ?? false;
}

class _EditRateSheet extends ConsumerStatefulWidget {
  final RateCard card;

  const _EditRateSheet({required this.card});

  @override
  ConsumerState<_EditRateSheet> createState() => _EditRateSheetState();
}

class _EditRateSheetState extends ConsumerState<_EditRateSheet> {
  final _search = TextEditingController();
  final _rate = TextEditingController();
  final _mvp = TextEditingController();
  final _reason = TextEditingController();
  bool _saving = false;

  PricingRule? _selected;
  List<String> _errors = const [];

  @override
  void dispose() {
    _search.dispose();
    _rate.dispose();
    _mvp.dispose();
    _reason.dispose();
    super.dispose();
  }

  List<PricingRule> _matches(String language) {
    final query = _search.text.trim().toLowerCase();
    final all = [...widget.card.rules]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    if (query.isEmpty) return all.take(30).toList(growable: false);
    return all
        .where(
          (r) =>
              r.labels(language).toLowerCase().contains(query) ||
              r.id.toLowerCase().contains(query) ||
              r.variant.toLowerCase().contains(query),
        )
        .take(30)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final language = ref.watch(languageProvider);
    final selected = _selected;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.ratesEditOne, style: AppText.title),
              const SizedBox(height: Space.lg),

              if (selected == null) ...[
                TextField(
                  controller: _search,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l.ratesSearch,
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: Space.md),
                SizedBox(
                  height: 320,
                  child: Builder(
                    builder: (context) {
                      final matches = _matches(language);
                      if (matches.isEmpty) {
                        return Center(
                          child: Text(l.ratesNoMatch, style: AppText.caption),
                        );
                      }
                      return ListView.builder(
                        itemCount: matches.length,
                        itemBuilder: (context, i) {
                          final rule = matches[i];
                          return ListTile(
                            minTileHeight: Touch.min,
                            title: Text(
                              rule.labels(language),
                              style: AppText.body,
                            ),
                            subtitle: Text(
                              '${rule.bandLabels?.call(language) ?? ''}  '
                                      '${l.ratesCurrent(Money.sen(rule.rateSen).format())}'
                                  .trim(),
                              style: AppText.caption,
                            ),
                            onTap: () => setState(() {
                              _selected = rule;
                              _rate.text = Money.sen(
                                rule.rateSen,
                              ).toPlainString();
                              _mvp.text = rule.mvpRateSen == null
                                  ? ''
                                  : Money.sen(rule.mvpRateSen!).toPlainString();
                            }),
                          );
                        },
                      );
                    },
                  ),
                ),
              ] else ...[
                Text(selected.labels(language), style: AppText.bodyStrong),
                if (selected.bandLabels != null)
                  Text(selected.bandLabels!(language), style: AppText.caption),
                const SizedBox(height: Space.lg),

                TextField(
                  controller: _rate,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: l.ratesNewRate,
                    helperText: l.ratesCurrent(
                      Money.sen(selected.rateSen).format(),
                    ),
                    border: const OutlineInputBorder(),
                    errorText: _errors.contains('rate') ? l.ratesInvalid : null,
                  ),
                ),
                const SizedBox(height: Space.md),
                TextField(
                  controller: _mvp,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: l.ratesNewMvp,
                    border: const OutlineInputBorder(),
                    errorText: _errors.contains('mvp')
                        ? l.ratesInvalid
                        : _errors.contains('mvp_above_rate')
                        ? l.ratesMvpTooHigh
                        : null,
                  ),
                ),
                const SizedBox(height: Space.md),
                TextField(
                  key: const Key('rate-reason'),
                  controller: _reason,
                  decoration: InputDecoration(
                    labelText: l.ratesReason,
                    helperText: l.ratesReasonHint,
                    border: const OutlineInputBorder(),
                    errorText: _errors.contains('reason')
                        ? l.ratesNoReason
                        : null,
                  ),
                ),
                for (final message in _messages(l))
                  Padding(
                    padding: const EdgeInsets.only(top: Space.md),
                    child: Text(
                      message,
                      style: AppText.caption.copyWith(color: AppColors.alarm),
                    ),
                  ),
                const SizedBox(height: Space.lg),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => setState(() {
                          _selected = null;
                          _errors = const [];
                        }),
                        child: Text(l.back),
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: FilledButton(
                        onPressed: _saving ? null : () => _apply(selected),
                        child: Text(l.save),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _apply(PricingRule rule) async {
    final import = editSingleRate(
      rule: rule,
      rateText: _rate.text,
      mvpText: _mvp.text,
    );
    final reason = _reason.text.trim();

    // The server's own refusals, answered here first so a fair-table edit
    // gets an instant reply. The server still decides.
    final errors = [
      ...import.errors,
      if (reason.length < minPriceEditReasonLength) 'reason',
      if (!import.hasErrors && import.actualChanges.isEmpty) 'no_change',
    ];
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }
    final change = import.actualChanges.single;

    // Published by the server, not saved here. Since Phase 3 a price belongs
    // to the office; a number saved on this phone would be quoted by no other.
    // Awaited, never read synchronously: a session still loading reads as
    // null, and would tell a signed-in admin they may not change anything.
    final credentials = await ref.read(credentialsProvider.future);
    if (!mounted) return;
    if (credentials == null) {
      setState(() => _errors = const ['forbidden']);
      return;
    }

    setState(() {
      _saving = true;
      _errors = const [];
    });

    // Against the list actually in force, so changing fair prices in August
    // cannot quietly move showroom prices in November.
    final list = (await ref.read(activeRateCardProvider.future)).list;
    final result = await ref
        .read(apiClientProvider)
        .editProductPrice(
          token: credentials.token,
          listId: list.id,
          ruleId: rule.id,
          rateSen: change.newRateSen,
          mvpRateSen: change.newMvpRateSen,
          reason: reason,
        );
    if (!mounted) return;

    if (result case SyncFailed(:final failure)) {
      setState(() {
        _saving = false;
        _errors = [
          switch (failure) {
            SyncFailure.offline => 'offline',
            SyncFailure.forbidden || SyncFailure.unauthenticated => 'forbidden',
            SyncFailure.serverError => 'refused',
          },
        ];
      });
      return;
    }

    // Pull it straight back, so this handset quotes the published card rather
    // than a local copy that happens to match it.
    await ref.read(syncProvider.notifier).syncNow();
    if (mounted) Navigator.of(context).pop(true);
  }

  /// Whole-sheet messages, as opposed to the ones under a field.
  List<String> _messages(L l) => [
    if (_errors.contains('no_change')) l.ratesNoChange,
    if (_errors.contains('offline')) l.ratesPublishOffline,
    if (_errors.contains('forbidden')) l.ratesReadOnly,
    if (_errors.contains('refused')) l.ratesRefused,
  ];
}
