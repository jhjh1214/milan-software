/// Reads and writes quotes. The database is the source of truth; nothing lives
/// only in memory.
///
/// SPEC.md §8.1: the app will be backgrounded mid-quote by a phone call, and
/// reopening must return to the exact window. So every mutation lands in SQLite
/// before the UI reports success — there is no "save" button to forget.
library;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';

const _uuid = Uuid();

/// Generates a client-side UUID v4.
///
/// CLAUDE.md: ids are client-generated so two part-timers offline at one fair
/// cannot collide. Nothing here ever waits on a server for an identifier.
String newId() => _uuid.v4();

class QuoteRepository {
  final AppDatabase _db;

  QuoteRepository(this._db);

  /// Returns the quote in progress, creating one if there is none.
  ///
  /// Phase 1 has no order concept, so a device carries a single draft. Phase 4
  /// turns this into a real order with a customer attached.
  Future<QuoteRow> ensureDraft({
    required int rateCardVersion,
    required String language,
    required String channel,
  }) async {
    final existing = await _db.latestQuote();
    // The channel is fixed when the quote starts and never revised. A quote
    // begun at a fair and finished in the car is still a fair quote, and
    // rewriting it later would change which prices it was entitled to.
    if (existing != null) return existing;

    final now = DateTime.now();
    final row = QuotesCompanion.insert(
      id: newId(),
      rateCardVersion: rateCardVersion,
      language: Value(language),
      channel: Value(channel),
      createdAt: now,
      updatedAt: now,
    );
    await _db.into(_db.quotes).insert(row);
    return (await _db.latestQuote())!;
  }

  /// The quote in progress, or null if none has been started.
  Future<QuoteRow?> currentQuote() => _db.latestQuote();

  Future<List<QuoteLineRow>> lines(String quoteId) => _db.linesFor(quoteId);

  Stream<List<QuoteLineRow>> watchLines(String quoteId) =>
      _db.watchLines(quoteId);

  /// Appends a line to a quote.
  ///
  /// The sort order is the current count, so lines stay in the order they were
  /// entered — the order the customer watched them appear in.
  Future<String> addLine({
    required String quoteId,
    required String room,
    required String variant,
    required String? materialKey,
    required String layer,
    required int widthTmm,
    required int? heightTmm,
    required String rawWidth,
    required String rawHeight,
    int quantity = 1,
    String? parentLineId,
  }) async {
    final existing = await _db.linesFor(quoteId);
    final id = newId();
    await _db.addLine(
      QuoteLinesCompanion.insert(
        id: id,
        quoteId: quoteId,
        sortOrder: existing.length,
        room: room,
        variant: variant,
        materialKey: Value(materialKey),
        layer: layer,
        parentLineId: Value(parentLineId),
        widthTmm: widthTmm,
        heightTmm: Value(heightTmm),
        rawWidth: rawWidth,
        rawHeight: rawHeight,
        quantity: Value(quantity),
        createdAt: DateTime.now(),
      ),
      quoteId,
    );
    return id;
  }

  /// Removes a line and every upgrade hanging off it.
  ///
  /// Deleting a curtain has to take its special track with it. Leaving an
  /// orphaned RM80/ft track line on the quote would be both wrong and very hard
  /// for a part-timer to notice.
  Future<List<QuoteLineRow>> deleteLineWithChildren(String lineId) async {
    final all = await _db.linesFor((await _db.lineById(lineId))?.quoteId ?? '');
    final doomed = all
        .where((l) => l.id == lineId || l.parentLineId == lineId)
        .toList(growable: false);
    for (final line in doomed) {
      await _db.deleteLine(line.id);
    }
    return doomed;
  }

  /// Puts back a line and its upgrades, in their original positions.
  Future<void> restoreLines(List<QuoteLineRow> lines) async {
    for (final line in lines) {
      await restoreLine(line);
    }
  }

  /// Restores a deleted line in its original position.
  ///
  /// Undo has to put the line back where it was, not on the end — §8.1 offers
  /// undo precisely so a mis-tap costs nothing, and a line that reappears
  /// somewhere else still costs the user their place.
  Future<void> restoreLine(QuoteLineRow line) => _db.addLine(
    QuoteLinesCompanion.insert(
      id: line.id,
      quoteId: line.quoteId,
      sortOrder: line.sortOrder,
      room: line.room,
      variant: line.variant,
      materialKey: Value(line.materialKey),
      layer: line.layer,
      widthTmm: line.widthTmm,
      heightTmm: Value(line.heightTmm),
      rawWidth: line.rawWidth,
      rawHeight: line.rawHeight,
      quantity: Value(line.quantity),
      // The photo comes back with the line. Undoing a mis-tap must not cost
      // the part-timer a walk back to the window.
      photoPath: Value(line.photoPath),
      parentLineId: Value(line.parentLineId),
      createdAt: line.createdAt,
    ),
    line.quoteId,
  );

  Future<void> deleteLine(String lineId) => _db.deleteLine(lineId);

  Future<void> setTier(String quoteId, String tier) =>
      (_db.update(_db.quotes)..where((q) => q.id.equals(quoteId))).write(
        QuotesCompanion(tier: Value(tier), updatedAt: Value(DateTime.now())),
      );

  /// Attaches a photo to a line, or clears it.
  ///
  /// Stores the path, never the bytes — a 3MB JPEG in the row would bloat every
  /// query that touches the line.
  Future<void> setLinePhoto(String lineId, String? path) =>
      (_db.update(_db.quoteLines)..where((l) => l.id.equals(lineId))).write(
        QuoteLinesCompanion(photoPath: Value(path)),
      );

  Future<void> setDeliveryZone(String quoteId, String? zoneId) =>
      (_db.update(_db.quotes)..where((q) => q.id.equals(quoteId))).write(
        QuotesCompanion(
          deliveryZoneId: Value(zoneId),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<void> setCustomer(String quoteId, String? name, String? phone) =>
      (_db.update(_db.quotes)..where((q) => q.id.equals(quoteId))).write(
        QuotesCompanion(
          customerName: Value(name),
          customerPhone: Value(phone),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<void> setLanguage(String quoteId, String language) =>
      (_db.update(_db.quotes)..where((q) => q.id.equals(quoteId))).write(
        QuotesCompanion(
          language: Value(language),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<void> clearAll() => _db.clearAll();
}
