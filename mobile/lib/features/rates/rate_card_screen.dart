/// Lets the admin change prices without a developer.
///
/// Export the list, edit it in Excel, import it back. CLAUDE.md hard rule 1: a
/// price change must never need a code change, a rebuild or a release.
///
/// SPEC.md §8.2: "Publishing a rate card is deliberate and two-step, with a
/// diff preview showing exactly which products change and by how much." So an
/// import shows what it would do and changes nothing until confirmed.
///
/// ## What Phase 3 changed
///
/// Prices are **server-owned**. A change made here is *published* — it goes to
/// the server and every handset picks it up on its next sync. It is no longer
/// saved to this phone. That is the whole point: six handsets each holding
/// their own edited list is six handsets quoting six different prices at one
/// fair, and a customer walking from one table to the next gets two numbers.
///
/// Two consequences, both deliberate:
///
/// - **Publishing needs a connection.** Refused, not queued. A price change
///   that sat in an outbox would be live on one phone and not the others, which
///   is exactly the state being designed out.
/// - **Only an admin sees the editing controls.** §3: staff see rates and
///   cannot edit them; part-timers never see a rate at all. The server enforces
///   this too — the check here is a courtesy, not the control.
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/date_format.dart';
import '../../core/money.dart';
import '../../data/rate_card_store.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/models.dart';
import '../../pricing/rate_card_csv.dart';
import '../../sync/api_client.dart';
import '../../sync/sync_state.dart';
import '../../ui/theme.dart';
import '../quote/quote_state.dart';
import '../sync/sync_screen.dart' show provenanceProvider;
import 'edit_rate_sheet.dart';

class RateCardScreen extends ConsumerStatefulWidget {
  const RateCardScreen({super.key});

  @override
  ConsumerState<RateCardScreen> createState() => _RateCardScreenState();
}

class _RateCardScreenState extends ConsumerState<RateCardScreen> {
  RateCardImport? _pending;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final cardAsync = ref.watch(rateCardProvider);

    final user = ref.watch(credentialsProvider).valueOrNull?.user;
    final mayPublish = user?.mayPublishRates ?? false;
    final held = ref.watch(provenanceProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: Text(l.ratesTitle)),
      body: cardAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (card) => ListView(
          padding: const EdgeInsets.all(Space.lg),
          children: [
            Text(
              l.ratesVersion(card.version, card.rules.length),
              style: AppText.caption,
            ),

            // Where this list came from, always. "Which version" is not the
            // useful question offline — "how do I know it is current" is.
            if (held != null) ...[
              const SizedBox(height: Space.sm),
              _Banner(
                text: switch (held.origin) {
                  RateCardOrigin.server => l.pricesFromServer(
                    held.fetchedAt == null
                        ? ''
                        : formatDateTime(held.fetchedAt!),
                  ),
                  RateCardOrigin.bundled => l.pricesBundled,
                  RateCardOrigin.local => l.pricesLocal,
                },
                warning: held.origin == RateCardOrigin.local,
              ),
            ],

            const SizedBox(height: Space.lg),
            Text(
              mayPublish ? l.ratesServerOwned : l.ratesReadOnly,
              style: AppText.caption,
            ),

            const SizedBox(height: Space.xl),
            OutlinedButton.icon(
              onPressed: _busy ? null : _checkForUpdates,
              icon: const Icon(Icons.sync),
              label: Text(l.ratesCheckUpdates),
            ),

            if (mayPublish) ...[
              const SizedBox(height: Space.xxl),

              // The one-off adjustment. Exporting a spreadsheet to change a
              // single number would be absurd, so this is the direct path.
              FilledButton.icon(
                onPressed: _busy ? null : () => _editOne(card),
                icon: const Icon(Icons.edit_outlined),
                label: Text(l.ratesEditOne),
              ),
              const SizedBox(height: Space.xl),

              // The whole-list revision.
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _export(card),
                icon: const Icon(Icons.table_view_outlined),
                label: Text(l.ratesExport),
              ),
              const SizedBox(height: Space.md),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _import(card),
                icon: const Icon(Icons.upload_file_outlined),
                label: Text(l.ratesImport),
              ),

              if (_pending case final pending?) ...[
                const SizedBox(height: Space.xl),
                _Preview(
                  import: pending,
                  onApply: () => _publish(pending),
                  onDiscard: () => setState(() => _pending = null),
                  applyLabel: l.ratesPublish,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Pulls whatever the office has published since the last sync.
  Future<void> _checkForUpdates() async {
    final l = L.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final status = await ref.read(syncProvider.notifier).syncNow();
      if (!mounted) return;
      final card = await ref.read(rateCardProvider.future);
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              status.lastFailure == SyncFailure.offline
                  ? l.syncOffline
                  : status.pricesUpdated.isEmpty
                  ? l.syncPricesCurrent
                  : l.syncPricesUpdated(card.version),
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editOne(RateCard card) async {
    final l = L.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final changed = await showEditRateSheet(context, ref, card);
    if (!changed || !mounted) return;

    final updated = await ref.read(rateCardProvider.future);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l.ratesApplied(updated.version))));
  }

  Future<void> _export(RateCard card) async {
    final l = L.of(context);
    final language = ref.read(languageProvider);
    setState(() => _busy = true);
    try {
      final csv = exportRateCardCsv(card, language);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/milan-prices-v${card.version}.csv');
      // A BOM, so Excel opens the Chinese product names correctly instead of
      // showing mojibake and sending the admin back to us.
      await file.writeAsString('﻿$csv', flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          subject: l.ratesTitle,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import(RateCard card) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFiles(type: FileType.any);
      final file = picked.firstOrNull;
      if (file == null) return; // Cancelling is not an error.

      // Bytes rather than a path: on Android a picked file often arrives as a
      // content:// URI with no readable filesystem path.
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);

      // Excel writes a UTF-8 BOM. Left in place it becomes part of the header
      // cell and every row fails to match.
      setState(
        () => _pending = readRateCardCsv(text.replaceFirst('﻿', ''), card),
      );
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Publishes the change to the server, for everyone.
  ///
  /// Not saved locally, and not queued when there is no connection. A price
  /// change sitting in an outbox would be live on this phone and on no other,
  /// which is precisely the state Phase 3 exists to remove.
  Future<void> _publish(RateCardImport import) async {
    final l = L.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final credentials = ref.read(credentialsProvider).valueOrNull;
    if (credentials == null) return;

    setState(() => _busy = true);
    try {
      // Applied to the list actually in force, so a fair-price edit cannot
      // quietly move showroom prices.
      final list = (await ref.read(activeRateCardProvider.future)).list;
      final json = applyRateCardImportToJson(
        await ref.read(rateCardStoreProvider).loadJson(list),
        import,
      );

      final result = await ref
          .read(apiClientProvider)
          .publishCard(
            token: credentials.token,
            listId: list.id,
            payload: json,
          );
      if (!mounted) return;

      switch (result) {
        case SyncOk():
          // Pull it straight back, so this handset holds the published card
          // rather than a local copy that happens to match it.
          await ref.read(syncProvider.notifier).syncNow();
          if (!mounted) return;
          setState(() => _pending = null);
          messenger.showSnackBar(
            SnackBar(content: Text(l.ratesPublished(json['version'] as int))),
          );
        case SyncFailed(:final failure):
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                failure == SyncFailure.offline
                    ? l.ratesPublishOffline
                    : l.ratesReadOnly,
              ),
            ),
          );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// One line saying where these prices came from.
class _Banner extends StatelessWidget {
  final String text;
  final bool warning;

  const _Banner({required this.text, required this.warning});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(Space.md),
    decoration: BoxDecoration(
      color: warning ? AppColors.warningSurface : AppColors.muted,
      borderRadius: BorderRadius.circular(Radii.sm),
    ),
    child: Text(
      text,
      style: AppText.caption.copyWith(
        color: warning ? AppColors.warning : AppColors.mutedForeground,
      ),
    ),
  );
}

/// What the import would do, before it does it.
class _Preview extends StatelessWidget {
  final RateCardImport import;
  final VoidCallback onApply;
  final VoidCallback onDiscard;

  /// "Publish to everyone" rather than "apply", because that is what the
  /// button now does — the change leaves this phone.
  final String applyLabel;

  const _Preview({
    required this.import,
    required this.onApply,
    required this.onDiscard,
    required this.applyLabel,
  });

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);

    if (import.hasErrors) {
      return Container(
        padding: const EdgeInsets.all(Space.lg),
        decoration: BoxDecoration(
          color: AppColors.alarmSurface,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.ratesErrors,
              style: AppText.bodyStrong.copyWith(color: AppColors.alarm),
            ),
            const SizedBox(height: Space.sm),
            for (final e in import.errors.take(12))
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  e,
                  style: AppText.caption.copyWith(color: AppColors.alarm),
                ),
              ),
            const SizedBox(height: Space.md),
            OutlinedButton(onPressed: onDiscard, child: Text(l.cancel)),
          ],
        ),
      );
    }

    final changes = import.actualChanges;
    if (changes.isEmpty) {
      return Text(l.ratesNoChanges, style: AppText.caption);
    }

    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: AppColors.muted,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.ratesReview(changes.length), style: AppText.bodyStrong),
          const SizedBox(height: Space.md),
          // Exactly which products change and by how much — §8.2.
          for (final c in changes)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.sm),
              child: Row(
                children: [
                  Expanded(child: Text(c.label, style: AppText.body)),
                  Text(
                    '${Money.sen(c.oldRateSen ?? 0).format(withSymbol: false)}'
                    '  →  '
                    '${Money.sen(c.newRateSen).format(withSymbol: false)}',
                    style: AppText.money.copyWith(
                      color: c.deltaSen > 0
                          ? AppColors.destructive
                          : AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: Space.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onDiscard,
                  child: Text(l.cancel),
                ),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: FilledButton(
                  onPressed: onApply,
                  child: Text(applyLabel),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
