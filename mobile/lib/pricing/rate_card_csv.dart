/// Reads and writes the rate card as a spreadsheet.
///
/// The admin's real tool is Excel, not a JSON editor. So the card exports as a
/// CSV they can open, change a number in, and import back. Phase 5 replaces
/// this with the dashboard's rate-card editor and its two-step publish.
///
/// PURE. No Flutter, no I/O — the caller supplies the text and decides where it
/// came from.
///
/// ## What an import may and may not change
///
/// **Only rates, MVP rates and minimum quantities.** Not bands, not bases, not
/// which products exist. A price adjustment is a number change; restructuring
/// the card is a different job with different risks, and doing it through a
/// spreadsheet with no validation is how a band silently disappears.
///
/// Rows are matched on `id`. An unknown id is reported, never silently ignored
/// — a typo that quietly does nothing is worse than an error, because the admin
/// believes the price changed.
library;

import '../core/money.dart';
import 'models.dart';

/// One change an import would make.
class RateChange {
  final String ruleId;
  final String label;

  final int? oldRateSen;
  final int newRateSen;

  final int? oldMvpRateSen;
  final int? newMvpRateSen;

  /// True when this change gives a placeholder row its first real rate.
  ///
  /// Supplying the rate is what makes the product sellable — the flag is
  /// cleared by the same edit that sets the number, never separately. If the
  /// two could drift apart the admin would type RM120, see it accepted, and
  /// the engine would still refuse to quote it.
  final bool clearsProvisional;

  const RateChange({
    required this.ruleId,
    required this.label,
    required this.oldRateSen,
    required this.newRateSen,
    required this.oldMvpRateSen,
    required this.newMvpRateSen,
    this.clearsProvisional = false,
  });

  bool get rateChanged => oldRateSen != newRateSen;
  bool get mvpChanged => oldMvpRateSen != newMvpRateSen;
  bool get isChange => rateChanged || mvpChanged;

  /// How far the rate moved, for the preview. Positive is a rise.
  int get deltaSen => newRateSen - (oldRateSen ?? newRateSen);
}

/// The result of reading an import, before anything is applied.
///
/// §8.2: publishing a rate card is deliberate and two-step, with a diff preview
/// showing exactly which products change and by how much. Nothing here mutates
/// the card; the caller decides whether to apply.
class RateCardImport {
  final List<RateChange> changes;
  final List<String> errors;

  const RateCardImport({required this.changes, required this.errors});

  bool get hasErrors => errors.isNotEmpty;
  List<RateChange> get actualChanges =>
      changes.where((c) => c.isChange).toList(growable: false);
}

const _header = 'id,product,band,unit,rate_rm,mvp_rate_rm,min_qty';

/// Writes the card as CSV, in [language] so the admin reads product names they
/// recognise.
String exportRateCardCsv(RateCard card, String language) {
  final rows = <String>[
    '# Milan Software price list. Change rate_rm, mvp_rate_rm or min_qty and',
    '# import this file back. Everything else is for your reference and is',
    '# ignored on import; leave the id column alone or the row will not match.',
    _header,
  ];

  final sorted = [...card.rules]
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  for (final r in sorted) {
    rows.add(
      [
        r.id,
        _quote(r.labels(language)),
        _quote(r.bandLabels?.call(language) ?? ''),
        r.basis.unit,
        // Plain, ungrouped: format() would write RM1,500.00 as "1,500.00"
        // and the comma would split the cell.
        Money.sen(r.rateSen).toPlainString(),
        r.mvpRateSen == null ? '' : Money.sen(r.mvpRateSen!).toPlainString(),
        r.minQty?.toString() ?? '',
      ].join(','),
    );
  }
  return rows.join('\n');
}

/// Reads an edited CSV and works out what it would change.
///
/// Money is parsed as an exact decimal and multiplied by 100, never through a
/// double: `4.80` must become 480 sen, and binary floating point does not hold
/// 4.80.
RateCardImport readRateCardCsv(String csv, RateCard card) {
  final byId = {for (final r in card.rules) r.id: r};
  final changes = <RateChange>[];
  final errors = <String>[];
  final seen = <String>{};

  final lines = csv.split(RegExp(r'\r?\n'));
  var sawHeader = false;

  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i].trim();
    if (raw.isEmpty || raw.startsWith('#')) continue;
    if (!sawHeader) {
      if (!raw.toLowerCase().startsWith('id,')) {
        errors.add(
          'Line ${i + 1}: expected the header row starting with "id,"',
        );
        return RateCardImport(changes: const [], errors: errors);
      }
      sawHeader = true;
      continue;
    }

    final cells = _splitCsvLine(raw);
    if (cells.length < 6) {
      errors.add(
        'Line ${i + 1}: expected at least 6 columns, found ${cells.length}',
      );
      continue;
    }

    final id = cells[0].trim();
    final rule = byId[id];
    if (rule == null) {
      // Never silently ignored: a typo that quietly does nothing is worse than
      // an error, because the admin walks away believing the price changed.
      errors.add('Line ${i + 1}: no product has id "$id"');
      continue;
    }
    if (!seen.add(id)) {
      errors.add('Line ${i + 1}: "$id" appears more than once');
      continue;
    }

    final rateSen = _money(cells[4]);
    if (rateSen == null) {
      errors.add('Line ${i + 1}: "${cells[4]}" is not a price');
      continue;
    }
    // Zero is refused on a row that has a price, and accepted on a placeholder
    // that never had one — where it is what the export just wrote and means
    // "still no rate". Without the exception the card could not round-trip at
    // all, and an admin who exported, changed one curtain and imported back
    // would be told four products they never touched are broken.
    if (rateSen < 0 || (rateSen == 0 && !rule.provisional)) {
      errors.add('Line ${i + 1}: a rate of ${cells[4]} is not sellable');
      continue;
    }

    int? mvpSen;
    if (cells[5].trim().isNotEmpty) {
      mvpSen = _money(cells[5]);
      if (mvpSen == null) {
        errors.add('Line ${i + 1}: "${cells[5]}" is not a price');
        continue;
      }
      if (mvpSen > rateSen) {
        // An MVP rate above the standard one is a transcription slip, and it
        // would quietly charge the best customers the most.
        errors.add(
          'Line ${i + 1}: the MVP rate ${cells[5]} is above the standard rate '
          '${cells[4]}',
        );
        continue;
      }
    }

    changes.add(
      RateChange(
        ruleId: id,
        label: cells.length > 1 ? cells[1] : id,
        oldRateSen: rule.rateSen,
        newRateSen: rateSen,
        oldMvpRateSen: rule.mvpRateSen,
        newMvpRateSen: mvpSen,
        clearsProvisional: rule.provisional && rateSen > 0,
      ),
    );
  }

  if (!sawHeader) errors.add('No header row found');
  return RateCardImport(changes: changes, errors: errors);
}

/// Builds a one-product change from what the admin typed on screen.
///
/// Goes through the same [RateCardImport] the CSV route produces, so a direct
/// edit gets the identical validation and the identical diff preview. Two paths
/// to the same place; one set of rules about what a price may be.
RateCardImport editSingleRate({
  required PricingRule rule,
  required String rateText,
  required String mvpText,
}) {
  final errors = <String>[];

  final rateSen = _money(rateText);
  if (rateSen == null) {
    errors.add('rate');
  } else if (rateSen <= 0) {
    // Stricter than the CSV route on purpose. There the zero is one the export
    // wrote; here somebody typed it, and typing 0 into a price box is never a
    // way to say "leave it alone" — a placeholder is left alone by not editing.
    errors.add('rate');
  }

  int? mvpSen;
  if (mvpText.trim().isNotEmpty) {
    mvpSen = _money(mvpText);
    if (mvpSen == null || mvpSen <= 0) {
      // Zero is refused for the same reason as the rate above -- and the
      // server's live edit refuses it too. Blank is how to say "no MVP rate".
      errors.add('mvp');
    } else if (rateSen != null && mvpSen > rateSen) {
      errors.add('mvp_above_rate');
    }
  }

  if (errors.isNotEmpty || rateSen == null) {
    return RateCardImport(changes: const [], errors: errors);
  }

  return RateCardImport(
    changes: [
      RateChange(
        ruleId: rule.id,
        label: rule.id,
        oldRateSen: rule.rateSen,
        newRateSen: rateSen,
        oldMvpRateSen: rule.mvpRateSen,
        newMvpRateSen: mvpSen,
        clearsProvisional: rule.provisional,
      ),
    ],
    errors: const [],
  );
}

/// Applies an import to the card's own JSON, returning the new JSON.
///
/// Works on the source map rather than serialising a [RateCard] back out. A
/// hand-written `toJson` would have to know every field, and the one it forgot
/// would be silently dropped the first time an admin changed a price. Editing
/// the map touches only `rate_sen`, `mvp_rate_sen` and `version`, and carries
/// everything else through untouched by construction.
///
/// [version] defaults to one past this card's own; a card about to be
/// published passes the next version across both lists instead — see
/// `RateCardStore.publishJsonFor`.
Map<String, dynamic> applyRateCardImportToJson(
  Map<String, dynamic> json,
  RateCardImport import, {
  int? version,
}) {
  final byId = {for (final c in import.actualChanges) c.ruleId: c};
  final out = Map<String, dynamic>.from(json);

  out['version'] = version ?? (json['version'] as int) + 1;
  out['rules'] = [
    for (final raw in json['rules'] as List<dynamic>)
      if (byId[(raw as Map<String, dynamic>)['id']] case final change?)
        {
          ...raw,
          'rate_sen': change.newRateSen,
          'mvp_rate_sen': change.newMvpRateSen,
          if (change.clearsProvisional) 'provisional': false,
        }
      else
        raw,
  ];
  return out;
}

/// Applies an import, returning a new card at the next version.
///
/// A new version rather than an edit in place: CLAUDE.md requires that rate
/// card rows are never updated in place, so a quote already priced at version 1
/// can still be explained after version 2 is published.
RateCard applyRateCardImport(RateCard card, RateCardImport import) {
  final byId = {for (final c in import.actualChanges) c.ruleId: c};

  return RateCard(
    version: card.version + 1,
    provisional: card.provisional,
    promo: card.promo,
    config: card.config,
    deliveryZones: card.deliveryZones,
    productRules: card.productRules,
    rules: [
      for (final r in card.rules)
        if (byId[r.id] case final change?)
          PricingRule(
            id: r.id,
            family: r.family,
            variant: r.variant,
            layer: r.layer,
            materialKey: r.materialKey,
            fulfilment: r.fulfilment,
            labels: r.labels,
            basis: r.basis,
            bandField: r.bandField,
            bandMinTmm: r.bandMinTmm,
            bandMaxTmm: r.bandMaxTmm,
            bandLabels: r.bandLabels,
            rateSen: change.newRateSen,
            mvpRateSen: change.newMvpRateSen,
            provisional: r.provisional && !change.clearsProvisional,
            minQty: r.minQty,
            sortOrder: r.sortOrder,
            coverageSqft: r.coverageSqft,
            bundleQty: r.bundleQty,
            depositCategoryOverride: r.depositCategoryOverride,
            isAddon: r.isAddon,
            attachesTo: r.attachesTo,
            note: r.note,
          )
        else
          r,
    ],
  );
}

/// Parses `46.00` into 4600 sen, exactly.
int? _money(String cell) => Money.tryParse(cell)?.sen;

String _quote(String value) => value.contains(',') || value.contains('"')
    ? '"${value.replaceAll('"', '""')}"'
    : value;

/// Splits one CSV line, honouring quoted cells that contain commas.
List<String> _splitCsvLine(String line) {
  final out = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        buffer.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (ch == ',' && !inQuotes) {
      out.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(ch);
    }
  }
  out.add(buffer.toString());
  return out;
}
