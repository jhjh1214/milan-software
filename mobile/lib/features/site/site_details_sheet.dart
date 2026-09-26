/// Where a visit is, and when the house can be measured. SPEC.md §13 C10.
///
/// One sheet, two places: on the quote at the fair, when the customer has
/// the address to hand, and on the order afterwards, when they WhatsApp it.
/// Every field is optional — a deposit is never held up for an address (hard
/// rule 9) — but a postcode, if typed, must be five digits, because the
/// office groups a day's visits by it and a wrong one sends somebody to the
/// wrong end of Melaka.
library;

import 'package:flutter/material.dart';

import '../../core/date_format.dart';
import '../../core/site_details.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';

/// What was entered. Blank fields are null.
class SiteEntry {
  final String? address;
  final String? postcode;
  final DateTime? readyFrom;

  const SiteEntry({this.address, this.postcode, this.readyFrom});
}

/// Picks the ready-from day. Injectable so a test need not drive a calendar.
typedef PickReadyDate =
    Future<DateTime?> Function(BuildContext context, DateTime? initial);

Future<DateTime?> _materialDatePicker(BuildContext context, DateTime? initial) {
  final now = DateTime.now();
  return showDatePicker(
    context: context,
    initialDate: initial ?? now,
    firstDate: DateTime(now.year - 1),
    lastDate: DateTime(now.year + 3),
  );
}

/// Returns what was saved, or null if the sheet was dismissed.
Future<SiteEntry?> showSiteDetailsSheet(
  BuildContext context, {
  required SiteEntry current,
  PickReadyDate pickDate = _materialDatePicker,
}) => showModalBottomSheet<SiteEntry>(
  context: context,
  isScrollControlled: true,
  backgroundColor: AppColors.surface,
  builder: (_) => _SiteDetailsSheet(current: current, pickDate: pickDate),
);

class _SiteDetailsSheet extends StatefulWidget {
  final SiteEntry current;
  final PickReadyDate pickDate;

  const _SiteDetailsSheet({required this.current, required this.pickDate});

  @override
  State<_SiteDetailsSheet> createState() => _SiteDetailsSheetState();
}

class _SiteDetailsSheetState extends State<_SiteDetailsSheet> {
  late final _address = TextEditingController(
    text: widget.current.address ?? '',
  );
  late final _postcode = TextEditingController(
    text: widget.current.postcode ?? '',
  );
  late DateTime? _readyFrom = widget.current.readyFrom;
  bool _postcodeWrong = false;

  @override
  void dispose() {
    _address.dispose();
    _postcode.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await widget.pickDate(context, _readyFrom);
    if (picked != null && mounted) {
      setState(
        () => _readyFrom = DateTime(picked.year, picked.month, picked.day),
      );
    }
  }

  void _save() {
    if (!postcodeIsValid(_postcode.text)) {
      setState(() => _postcodeWrong = true);
      return;
    }
    Navigator.of(context).pop(
      SiteEntry(
        address: cleanText(_address.text),
        postcode: cleanPostcode(_postcode.text),
        readyFrom: _readyFrom,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final ready = _readyFrom;

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
              Text(l.siteTitle, style: AppText.title),
              Text(l.siteOptional, style: AppText.caption),
              const SizedBox(height: Space.lg),
              TextField(
                key: const Key('site-address'),
                controller: _address,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: l.siteAddressLabel,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const Key('site-postcode'),
                controller: _postcode,
                keyboardType: TextInputType.number,
                maxLength: 5,
                decoration: InputDecoration(
                  labelText: l.sitePostcodeLabel,
                  border: const OutlineInputBorder(),
                  errorText: _postcodeWrong ? l.sitePostcodeInvalid : null,
                ),
                onChanged: (_) {
                  if (_postcodeWrong) setState(() => _postcodeWrong = false);
                },
              ),
              const SizedBox(height: Space.sm),
              Text(l.siteReadyLabel, style: AppText.label),
              const SizedBox(height: Space.xs),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('site-ready'),
                      onPressed: _pick,
                      icon: const Icon(Icons.key_outlined),
                      label: Text(
                        ready == null
                            ? l.siteReadyNow
                            : l.siteReadyFrom(formatDate(ready)),
                      ),
                    ),
                  ),
                  if (ready != null)
                    TextButton(
                      onPressed: () => setState(() => _readyFrom = null),
                      child: Text(l.siteReadyClear),
                    ),
                ],
              ),
              const SizedBox(height: Space.lg),
              FilledButton(
                key: const Key('site-save'),
                onPressed: _save,
                child: Text(l.save),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One line saying what is on file, for a row on the quote or the order.
String siteSummary(L l, SiteEntry site) {
  final parts = [
    ?site.postcode,
    ?site.address,
    if (site.readyFrom != null) l.siteReadyFrom(formatDate(site.readyFrom!)),
  ];
  return parts.isEmpty ? l.siteOptional : parts.join('  ·  ');
}
