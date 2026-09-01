/// Lets the admin change prices without a developer.
///
/// Export the list, edit it in Excel, import it back. CLAUDE.md hard rule 1: a
/// price change must never need a code change, a rebuild or a release.
///
/// SPEC.md §8.2: "Publishing a rate card is deliberate and two-step, with a
/// diff preview showing exactly which products change and by how much." So an
/// import shows what it would do and changes nothing until confirmed. Phase 5
/// moves this to the dashboard, where the office can do it properly.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/money.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/models.dart';
import '../../pricing/rate_card_csv.dart';
import '../../ui/theme.dart';
import '../quote/quote_state.dart';

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
            if (card.version > 1) ...[
              const SizedBox(height: Space.sm),
              Container(
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: AppColors.warningSurface,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Text(
                  l.ratesCustom(card.version),
                  style: AppText.caption.copyWith(color: AppColors.warning),
                ),
              ),
            ],
            const SizedBox(height: Space.xl),

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
                onApply: () => _apply(pending),
                onDiscard: () => setState(() => _pending = null),
              ),
            ],

            const SizedBox(height: Space.xxl),
            TextButton.icon(
              onPressed: _busy ? null : _restore,
              icon: const Icon(Icons.restore, color: AppColors.destructive),
              label: Text(
                l.ratesRestore,
                style: const TextStyle(color: AppColors.destructive),
              ),
            ),
          ],
        ),
      ),
    );
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
      await Share.shareXFiles([
        XFile(file.path, mimeType: 'text/csv'),
      ], subject: l.ratesTitle);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import(RateCard card) async {
    // Phase 2 reads the file the admin shared back to the app's documents
    // folder. Phase 5 does this properly in the dashboard, where the office
    // has a keyboard and a real screen.
    final l = L.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final candidates = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.csv'))
          .toList();
      if (candidates.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(l.ratesErrors)));
        return;
      }
      candidates.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      final text = (await candidates.first.readAsString()).replaceFirst(
        '﻿',
        '',
      );
      setState(() => _pending = readRateCardCsv(text, card));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply(RateCardImport import) async {
    final l = L.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final store = ref.read(rateCardStoreProvider);
    setState(() => _busy = true);
    try {
      final json = applyRateCardImportToJson(await store.loadJson(), import);
      await store.save(json);
      ref.invalidate(rateCardProvider);
      if (!mounted) return;
      setState(() => _pending = null);
      messenger.showSnackBar(
        SnackBar(content: Text(l.ratesApplied(json['version'] as int))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    await ref.read(rateCardStoreProvider).restoreBundled();
    ref.invalidate(rateCardProvider);
    if (mounted) setState(() => _pending = null);
  }
}

/// What the import would do, before it does it.
class _Preview extends StatelessWidget {
  final RateCardImport import;
  final VoidCallback onApply;
  final VoidCallback onDiscard;

  const _Preview({
    required this.import,
    required this.onApply,
    required this.onDiscard,
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
                  child: Text(l.ratesApply),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
