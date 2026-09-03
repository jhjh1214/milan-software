/// Changing one price, in the app.
///
/// The CSV route is for a whole-list revision. This is for the phone call that
/// says "night curtain goes up two ringgit from Monday" — the case where
/// exporting a spreadsheet, opening Excel and importing it back is absurd.
///
/// Both routes produce a [RateCardImport] and both show the same diff before
/// anything is applied, so there is one set of rules about what a price may be
/// rather than two that can drift apart.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/models.dart';
import '../../pricing/rate_card_csv.dart';
import '../../sync/api_client.dart';
import '../../sync/sync_state.dart';
import '../../ui/theme.dart';
import '../quote/quote_state.dart';

/// Lets the admin pick a product and change its rate. Returns true if a change
/// was applied.
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

  PricingRule? _selected;
  List<String> _errors = const [];

  @override
  void dispose() {
    _search.dispose();
    _rate.dispose();
    _mvp.dispose();
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
                        onPressed: () => _apply(selected),
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
    if (import.hasErrors) {
      setState(() => _errors = import.errors);
      return;
    }
    if (import.actualChanges.isEmpty) {
      if (mounted) Navigator.of(context).pop(false);
      return;
    }

    // Edited against the list actually in force, so changing fair prices in
    // August cannot quietly move showroom prices in November.
    final store = ref.read(rateCardStoreProvider);
    final list = (await ref.read(activeRateCardProvider.future)).list;
    final json = applyRateCardImportToJson(await store.loadJson(list), import);

    // Published, not saved. Since Phase 3 a price belongs to the office: the
    // server takes the new version and every handset picks it up on its next
    // sync. Saving it here instead would leave this phone quoting a number no
    // other phone has.
    final credentials = ref.read(credentialsProvider).valueOrNull;
    if (credentials == null) {
      setState(() => _errors = [L.of(context).ratesPublishOffline]);
      return;
    }

    final result = await ref
        .read(apiClientProvider)
        .publishCard(token: credentials.token, listId: list.id, payload: json);
    if (!mounted) return;

    if (result case SyncFailed(:final failure)) {
      setState(() {
        _errors = [
          failure == SyncFailure.offline
              ? L.of(context).ratesPublishOffline
              : L.of(context).ratesReadOnly,
        ];
      });
      return;
    }

    await ref.read(syncProvider.notifier).syncNow();
    if (mounted) Navigator.of(context).pop(true);
  }
}
