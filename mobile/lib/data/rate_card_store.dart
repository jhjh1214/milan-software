/// Which price list is in force, and where an edited one lives.
///
/// Two lists ship with the app:
///
/// - **fair** — the MITC promo, valid for its four days.
/// - **standard** — everything else. Derived from the fair list per the
///   client's provisional answer to §13 A3 (curtains +20%, blinds +50%), and
///   marked `provisional` until a real standard list exists.
///
/// **Two things decide, and both are needed.** §3: "Promo and the 12-month lock
/// are fair-only. Showroom pays standard." So the fair list applies when the
/// handset is at a fair *and* the fair's own promo window covers today.
///
/// The date alone used to decide, which quoted fair prices to a showroom
/// walk-in during the four days of a fair — and, once locks existed, would have
/// handed them a twelve-month hold they never bought. The window is still the
/// guard on the other side: a handset left in fair mode cannot quote promo
/// rates in September.
///
/// An admin edit is stored against the list it was made on, so editing fair
/// prices in August cannot quietly move showroom prices in November.
///
/// ## Where a card comes from, since Phase 3
///
/// Prices are **server-owned**. A card is published once and pulled by every
/// handset (§9.1, SPEC.md §11), because six handsets each holding their own
/// edited copy is six handsets quoting six different prices at one fair.
///
/// So a stored card now carries its [RateCardOrigin]:
///
/// - [RateCardOrigin.server] — pulled. The normal state.
/// - [RateCardOrigin.local] — a Phase 2 on-device edit. Superseded by the
///   first successful pull, deliberately and without asking.
/// - [RateCardOrigin.bundled] — what shipped in the APK. The starting state,
///   and what a handset that has never reached the server quotes from, so a
///   fair with no signal still works on day one.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../pricing/models.dart';
import '../pricing/rate_lock.dart' show Channel, channelFor;

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

/// Where the card on this handset came from.
enum RateCardOrigin {
  /// Shipped in the APK. Never reached the server, or never needed to.
  bundled,

  /// Edited on this device, before Phase 3 made prices server-owned. The next
  /// successful pull replaces it.
  local,

  /// Pulled from the server. The normal state.
  server,
}

/// What is known about the stored card, beyond its contents.
class RateCardProvenance {
  final RateCardOrigin origin;
  final int version;

  /// When it was pulled. Null for a bundled or locally edited card.
  ///
  /// Shown on the rates screen as "prices as of ...", because the honest
  /// answer to "are these current?" offline is *when they were last known to
  /// be*, not a claim that they are.
  final DateTime? fetchedAt;

  const RateCardProvenance({
    required this.origin,
    required this.version,
    this.fetchedAt,
  });

  bool get isServerOwned => origin == RateCardOrigin.server;
}

/// The card in force, plus which list it came from and why.
class ActiveRateCard {
  final RateCard card;
  final PriceList list;

  /// Where a quote started now would be taken. It decides whether an RM300 can
  /// lock anything (§13 B1) and whether the category prompt appears (§6.2), so
  /// it travels with the card rather than being worked out again elsewhere.
  final Channel channel;

  const ActiveRateCard({
    required this.card,
    required this.list,
    Channel? channel,
  }) : channel =
           channel ??
           (list == PriceList.fair ? Channel.fair : Channel.showroom);

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

  /// Which list applies to a quote taken through [channel] on [today].
  ///
  /// **Two conditions, and both are needed.** §3: "Promo and the 12-month lock
  /// are fair-only. Showroom pays standard." And the fair list only inside its
  /// own promo window, so a fair that ended yesterday cannot price today.
  ///
  /// The channel used to be inferred from the date alone, which quoted fair
  /// prices to a showroom walk-in during the four days of a fair — and, once
  /// locks existed, would have handed them a twelve-month hold they never
  /// bought.
  Future<PriceList> listFor(DateTime today, Channel channel) async {
    if (channel != Channel.fair) return PriceList.standard;
    final fair = RateCard.fromJson(await loadJson(PriceList.fair));
    return fair.isExpiredOn(today) ? PriceList.standard : PriceList.fair;
  }

  /// The card in force for [channel] on [today], and which list it is.
  Future<ActiveRateCard> loadActive(DateTime today, Channel channel) async {
    final list = await listFor(today, channel);
    return ActiveRateCard(
      card: RateCard.fromJson(await loadJson(list)),
      list: list,
      channel: channel,
    );
  }

  /// The card in force for a handset whose fair switch is [fairModeEnabled].
  ///
  /// Resolves the channel here rather than making the caller do it, because
  /// deciding the channel needs the fair card's promo window and choosing the
  /// list needs the channel. Splitting the two across providers made that
  /// circular, and the first quote of a session was recorded as `showroom`
  /// while the card was still loading.
  Future<ActiveRateCard> loadActiveForHandset(
    DateTime today, {
    required bool fairModeEnabled,
  }) async {
    final fairCard = RateCard.fromJson(await loadJson(PriceList.fair));
    final channel = channelFor(
      fairModeEnabled: fairModeEnabled,
      fairCard: fairCard,
      today: today,
    );

    if (channel == Channel.fair) {
      return ActiveRateCard(
        card: fairCard,
        list: PriceList.fair,
        channel: channel,
      );
    }
    return ActiveRateCard(
      card: RateCard.fromJson(await loadJson(PriceList.standard)),
      list: PriceList.standard,
      channel: channel,
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
  ///
  /// The Phase 2 path. Since Phase 3 an edit belongs on the server — see
  /// [adoptServerCard] — and this is kept for the offline demo build and for
  /// the tests that cover the import format. A card saved this way is marked
  /// [RateCardOrigin.local] and is replaced by the next successful pull.
  Future<void> save(PriceList list, Map<String, dynamic> json) async {
    await _storage.write(list.id, jsonEncode(json));
    await _writeProvenance(
      list,
      origin: RateCardOrigin.local,
      version: json['version'] as int? ?? 0,
      fetchedAt: null,
    );
  }

  /// Takes the server's card as the one in force. §9.1.
  ///
  /// **Replaces wholesale, never merges.** A merge of two price lists is a way
  /// to end up with a card nobody has ever read end to end. This is also what
  /// discards a leftover Phase 2 local edit: the same file is overwritten, so
  /// the override is gone on the first successful pull rather than lingering
  /// until someone notices.
  Future<void> adoptServerCard(
    PriceList list,
    Map<String, dynamic> json, {
    required DateTime at,
  }) async {
    // Parsed before it is stored. A card the engine cannot read would leave
    // the handset unable to quote, and the bundled list it just overwrote is
    // the thing that would have saved it.
    RateCard.fromJson(json);

    await _storage.write(list.id, jsonEncode(json));
    await _writeProvenance(
      list,
      origin: RateCardOrigin.server,
      version: json['version'] as int,
      fetchedAt: at,
    );
  }

  /// Throws any override to [list] away and goes back to the shipped one.
  Future<void> restoreBundled(PriceList list) async {
    await _storage.delete(list.id);
    await _storage.delete(_provenanceKey(list));
  }

  Future<bool> hasOverride(PriceList list) => _storage.exists(list.id);

  /// Where this handset's copy of [list] came from, and when.
  Future<RateCardProvenance> provenance(PriceList list) async {
    if (!await _storage.exists(list.id)) {
      return RateCardProvenance(
        origin: RateCardOrigin.bundled,
        version: RateCard.fromJson(await loadBundledJson(list)).version,
      );
    }

    final raw = await _storage.read(_provenanceKey(list));
    if (raw == null) {
      // A card with no note beside it was written before provenance existed,
      // so it is a Phase 2 edit. Treating it as `server` would exempt it from
      // being replaced, which is the whole failure this is here to prevent.
      return RateCardProvenance(
        origin: RateCardOrigin.local,
        version: RateCard.fromJson(await loadJson(list)).version,
      );
    }

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final fetched = json['fetched_at'] as String?;
      return RateCardProvenance(
        origin: RateCardOrigin.values.byName(json['origin'] as String),
        version: json['version'] as int,
        fetchedAt: fetched == null ? null : DateTime.parse(fetched).toUtc(),
      );
    } catch (_) {
      // Unreadable. Assume the pessimistic answer for the same reason as
      // above: a card that might be a local edit must still be replaceable.
      return RateCardProvenance(
        origin: RateCardOrigin.local,
        version: RateCard.fromJson(await loadJson(list)).version,
      );
    }
  }

  String _provenanceKey(PriceList list) => '${list.id}.origin';

  Future<void> _writeProvenance(
    PriceList list, {
    required RateCardOrigin origin,
    required int version,
    required DateTime? fetchedAt,
  }) => _storage.write(
    _provenanceKey(list),
    jsonEncode({
      'origin': origin.name,
      'version': version,
      'fetched_at': fetchedAt?.toUtc().toIso8601String(),
    }),
  );
}
