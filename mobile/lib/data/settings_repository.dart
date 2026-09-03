/// Handset preferences. One table, string keys, no ceremony.
library;

import 'package:drift/drift.dart';

import 'database.dart';

/// Whether this handset is at a fair.
///
/// **Defaults to on.** The promo window on the rate card is what actually
/// grants a fair price, so a handset left switched on outside a fair quotes
/// standard anyway — there is no state this can be left in that gives a price
/// away. Client, Sep 2026: *"Quotation normally is only at fair anyway."*
const String kFairModeKey = 'fair_mode';

class SettingsRepository {
  final AppDatabase _db;

  SettingsRepository(this._db);

  Future<bool> fairModeEnabled() async {
    final row = await (_db.select(
      _db.settings,
    )..where((s) => s.key.equals(kFairModeKey))).getSingleOrNull();
    // Absent means never touched, which is on. Anything unrecognisable is
    // treated as on too, for the same reason: the window is the real guard.
    return row?.value != 'false';
  }

  Future<void> setFairMode(bool enabled) => _db
      .into(_db.settings)
      .insert(
        SettingsCompanion.insert(key: kFairModeKey, value: '$enabled'),
        mode: InsertMode.insertOrReplace,
      );
}
