/// Setting when the fair runs, from the handset. Admin only.
///
/// The fair card's promo window decides which days this handset quotes fair
/// prices at all, and when every deposit taken at the fair stops holding its
/// price — twelve months from the day after it ends (SPEC.md §6.1). So the
/// dates are data an admin sets, never a date in code, and the sheet shows
/// that consequence as the dates are picked, worked out by the same
/// `holdStartsOn` / `twelveMonthsFrom` the deposit screen grants with.
///
/// Published, never saved here, for the same reason a price is: the server
/// records who and why, publishes a new fair card, and every handset picks
/// it up on its next pull. Needs a connection and says so without one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/models.dart';
import '../../pricing/price_edit.dart';
import '../../pricing/rate_lock.dart';
import '../../sync/api_client.dart';
import '../../sync/sync_state.dart';
import '../../ui/theme.dart';

/// Picks a first and last day. Injectable so a test need not drive a
/// calendar widget to supply two dates.
typedef PickFairRange =
    Future<DateTimeRange?> Function(
      BuildContext context,
      DateTimeRange? initial,
    );

Future<DateTimeRange?> _materialRangePicker(
  BuildContext context,
  DateTimeRange? initial,
) {
  final anchor = initial?.start ?? DateTime.now();
  return showDateRangePicker(
    context: context,
    initialDateRange: initial,
    firstDate: DateTime(anchor.year - 1),
    lastDate: DateTime(anchor.year + 3),
  );
}

/// Returns the version the change was published as, or null if nothing was.
Future<int?> showFairDatesSheet(
  BuildContext context, {
  required CardPromo? current,
  PickFairRange pickRange = _materialRangePicker,
}) => showModalBottomSheet<int>(
  context: context,
  isScrollControlled: true,
  backgroundColor: AppColors.surface,
  builder: (_) => _FairDatesSheet(current: current, pickRange: pickRange),
);

/// The last day a deposit taken at a fair ending on [lastDay] holds its
/// price. Every deposit at one fair shares it, so any deposit day inside the
/// fair gives the same answer; the last day itself is used.
DateTime holdEndsForFairEnding(DateTime lastDay) =>
    twelveMonthsFrom(holdStartsOn(depositDate: lastDay, fairEndsOn: lastDay));

class _FairDatesSheet extends ConsumerStatefulWidget {
  final CardPromo? current;
  final PickFairRange pickRange;

  const _FairDatesSheet({required this.current, required this.pickRange});

  @override
  ConsumerState<_FairDatesSheet> createState() => _FairDatesSheetState();
}

class _FairDatesSheetState extends ConsumerState<_FairDatesSheet> {
  late final _name = TextEditingController(text: widget.current?.code ?? '');
  final _reason = TextEditingController();
  late DateTimeRange? _range = widget.current == null
      ? null
      : DateTimeRange(
          start: widget.current!.validFrom,
          end: widget.current!.validTo,
        );

  List<String> _errors = const [];
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _reason.dispose();
    super.dispose();
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _pick() async {
    final picked = await widget.pickRange(context, _range);
    if (picked != null && mounted) setState(() => _range = picked);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final reason = _reason.text.trim();
    final range = _range;
    final current = widget.current;

    final errors = [
      if (name.isEmpty || name.length > 64) 'name',
      if (range == null) 'range',
      if (reason.length < minPriceEditReasonLength) 'reason',
      if (range != null &&
          current != null &&
          name == current.code &&
          _sameDay(range.start, current.validFrom) &&
          _sameDay(range.end, current.validTo))
        'no_change',
    ];
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }

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
    final result = await ref
        .read(apiClientProvider)
        .setFairDates(
          token: credentials.token,
          code: name,
          validFrom: range!.start,
          validTo: range.end,
          reason: reason,
        );
    if (!mounted) return;

    switch (result) {
      case SyncOk(:final value):
        // Pull the new fair card straight back: fair mode's own boundaries
        // move with it, on this handset as on every other.
        await ref.read(syncProvider.notifier).syncNow();
        if (mounted) Navigator.of(context).pop(value['version'] as int);
      case SyncFailed(:final failure):
        setState(() {
          _saving = false;
          _errors = [
            switch (failure) {
              SyncFailure.offline => 'offline',
              SyncFailure.forbidden ||
              SyncFailure.unauthenticated => 'forbidden',
              SyncFailure.serverError => 'refused',
            },
          ];
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final range = _range;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.fairDatesChange, style: AppText.title),
              const SizedBox(height: Space.lg),
              TextField(
                key: const Key('fair-name'),
                controller: _name,
                decoration: InputDecoration(
                  labelText: l.fairDatesName,
                  border: const OutlineInputBorder(),
                  errorText: _errors.contains('name')
                      ? l.fairDatesNoName
                      : null,
                ),
              ),
              const SizedBox(height: Space.md),
              OutlinedButton.icon(
                key: const Key('fair-range'),
                onPressed: _saving ? null : _pick,
                icon: const Icon(Icons.date_range_outlined),
                label: Text(
                  range == null
                      ? l.fairDatesPick
                      : '${formatDate(range.start)} – ${formatDate(range.end)}',
                ),
              ),
              if (_errors.contains('range'))
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(
                    l.fairDatesPick,
                    style: AppText.caption.copyWith(color: AppColors.alarm),
                  ),
                ),
              if (range != null) ...[
                const SizedBox(height: Space.sm),
                Text(
                  l.fairDatesHoldsUntil(
                    formatDate(holdEndsForFairEnding(range.end)),
                  ),
                  style: AppText.bodyStrong,
                ),
              ],
              const SizedBox(height: Space.md),
              TextField(
                key: const Key('fair-reason'),
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
              for (final message in [
                if (_errors.contains('no_change')) l.fairDatesNoChange,
                if (_errors.contains('offline')) l.ratesPublishOffline,
                if (_errors.contains('forbidden')) l.ratesReadOnly,
                if (_errors.contains('refused')) l.ratesRefused,
              ])
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
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: Text(l.cancel),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: FilledButton(
                      key: const Key('fair-save'),
                      onPressed: _saving ? null : _save,
                      child: Text(l.save),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
