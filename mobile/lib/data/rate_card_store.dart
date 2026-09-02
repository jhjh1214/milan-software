/// Which price list is in force, and where an edited one lives.
///
/// Two lists ship with the app:
///
/// - **fair** — the MITC promo, valid for its four days.
/// - **standard** — everything else. Derived from the fair list per the
///   client's provisional answer to §13 A3 (curtains +20%, blinds +50%), and
///   marked `provisional` until a real standard list exists.
///
/// The date decides. §3: "Promo and the 12-month lock are fair-only. Showroom
/// pays standard." So inside the fair window the fair list applies and outside
/// it the standard one does, rather than a salesperson remembering to switch.
///
/// An admin edit is stored against the list it was made on, so editing fair
/// prices in August cannot quietly move showroom prices in November.
///
/// > **Phase 3 replaces all of this.** The card becomes server-owned and pulled
/// > (§9.1), on-device editing turns read-only, and the override is dropped on
/// > the first successful pull. Six handsets quoting six different prices is the
/// > failure that prevents.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../pricing/models.dart';

/// The lists the app ships with.
enum PriceList {
  fair('fair', 'assets/data/rate-card-fair-2026-08.json'),
  standard('standard', 'assets/data/rate-card-standard.json');

  const PriceList(this.id, this.asset);

  final String id;
  final String asset;
}

/// Where an edited card is kept.
///
/// An interface rather than direct file calls, because real file I/O and
/// `rootBundle` both hang inside `flutter test`'s fake-async zone. A widget test
/// that exercises the whole change-a-price flow needs an in-memory
/// implementation; without this seam that test cannot exist at all.
abstract interface class RateCardStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String contents);
  Future<void> delete(String key);
  Future<bool> exists(String key);
}

/// The real thing: one JSON file per list in the app's documents directory.
class FileRateCardStorage implements RateCardStorage {
  final Future<Directory> Function() _directory;

  FileRateCardStorage({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationDocumentsDirectory;

  Future<File> _file(String key) async =>
      File('${(await _directory()).path}/rate-card-$key.json');

  @override
  Future<bool> exists(String key) async => (await _file(key)).existsSync();

  @override
  Future<String?> read(String key) async {
    final file = await _file(key);
    return file.existsSync() ? file.readAsString() : null;
  }

  @override
  Future<void> write(String key, String contents) async =>
      (await _file(key)).writeAsString(contents, flush: true);

  @override
  Future<void> delete(String key) async {
    final file = await _file(key);
    if (file.existsSync()) await file.delete();
  }
}

/// For tests. Holds the cards in memory so nothing touches the filesystem.
class InMemoryRateCardStorage implements RateCardStorage {
  final Map<String, String> _contents = {};

  @override
  Future<bool> exists(String key) async => _contents.containsKey(key);

  @override
  Future<String?> read(String key) async => _contents[key];

  @override
  Future<void> write(String key, String contents) async =>
      _contents[key] = contents;

  @override
  Future<void> delete(String key) async => _contents.remove(key);
}

/// The card in force, plus which list it came from.
class ActiveRateCard {
  final RateCard card;
  final PriceList list;

  const ActiveRateCard({required this.card, required this.list});

  bool get isFair => list == PriceList.fair;
}

class RateCardStore {
  final RateCardStorage _storage;

  /// Reads a shipped list. Injected because `rootBundle` does not resolve
  /// inside `flutter test`'s fake-async zone, so a widget test using the real
  /// one would sit on a loading spinner forever.
  final Future<String> Function(PriceList) _bundled;

  RateCardStore({
    RateCardStorage? storage,
    Future<Directory> Function()? directory,
    Future<String> Function(PriceList)? bundled,
  }) : _storage = storage ?? FileRateCardStorage(directory: directory),
       _bundled = bundled ?? ((list) => rootBundle.loadString(list.asset));

  /// Which list applies on [today].
  ///
  /// The fair list only inside its own promo window. Everything else — every
  /// showroom day of the year — is standard.
  Future<PriceList> listFor(DateTime today) async {
    final fair = RateCard.fromJson(await loadJson(PriceList.fair));
    return fair.isExpiredOn(today) ? PriceList.standard : PriceList.fair;
  }

  /// The card in force on [today], and which list it is.
  Future<ActiveRateCard> loadActive(DateTime today) async {
    final list = await listFor(today);
    return ActiveRateCard(
      card: RateCard.fromJson(await loadJson(list)),
      list: list,
    );
  }

  /// The raw JSON of one list: the admin's edit if there is one, otherwise as
  /// shipped.
  ///
  /// The map rather than the parsed card, because applying a price change edits
  /// the map — see `applyRateCardImportToJson`.
  ///
  /// An override is only returned if it actually parses as a rate card. Bad
  /// JSON, or well-formed JSON that is not a card, is deleted and the shipped
  /// list used instead: mid-fair, an unreadable file must not stop someone
  /// quoting, and it must not fail again on the next launch.
  Future<Map<String, dynamic>> loadJson(PriceList list) async {
    final raw = await _storage.read(list.id);
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        // Parsed and thrown away purely to prove it is a card before anything
        // downstream depends on it.
        RateCard.fromJson(json);
        return json;
      } catch (_) {
        await _storage.delete(list.id);
      }
    }
    return loadBundledJson(list);
  }

  Future<Map<String, dynamic>> loadBundledJson(PriceList list) async =>
      jsonDecode(await _bundled(list)) as Map<String, dynamic>;

  Future<RateCard> load(PriceList list) async =>
      RateCard.fromJson(await loadJson(list));

  /// Saves an edited card as the one in force for [list].
  Future<void> save(PriceList list, Map<String, dynamic> json) =>
      _storage.write(list.id, jsonEncode(json));

  /// Throws the admin's edits to [list] away and goes back to the shipped one.
  Future<void> restoreBundled(PriceList list) => _storage.delete(list.id);

  Future<bool> hasOverride(PriceList list) => _storage.exists(list.id);
}
