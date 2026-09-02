/// Where an edited price list lives.
///
/// The bundled asset is the card the app ships with. When the admin imports or
/// edits a price, the result is written here and used in preference — so a
/// price adjustment never needs a code change, a rebuild or a release
/// (CLAUDE.md hard rule 1).
///
/// The bundled asset is never overwritten, so "restore the original" is always
/// one tap away. That matters at a fair: a mistaken import at 9am must not cost
/// the whole day.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../pricing/models.dart';

const bundledRateCardAsset = 'assets/data/rate-card-fair-2026-08.json';
const _overrideFileName = 'rate-card-current.json';

/// Where the edited card is kept.
///
/// An interface rather than direct file calls, because real file I/O and
/// `rootBundle` both hang inside `flutter test`'s fake-async zone. A widget
/// test that exercises the whole change-a-price flow needs an in-memory
/// implementation; without this seam that test cannot exist at all.
abstract interface class RateCardStorage {
  Future<String?> read();
  Future<void> write(String contents);
  Future<void> delete();
  Future<bool> exists();
}

/// The real thing: a JSON file in the app's documents directory.
class FileRateCardStorage implements RateCardStorage {
  final Future<Directory> Function() _directory;

  FileRateCardStorage({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationDocumentsDirectory;

  Future<File> _file() async =>
      File('${(await _directory()).path}/$_overrideFileName');

  @override
  Future<bool> exists() async => (await _file()).existsSync();

  @override
  Future<String?> read() async {
    final file = await _file();
    return file.existsSync() ? file.readAsString() : null;
  }

  @override
  Future<void> write(String contents) async =>
      (await _file()).writeAsString(contents, flush: true);

  @override
  Future<void> delete() async {
    final file = await _file();
    if (file.existsSync()) await file.delete();
  }
}

/// For tests. Holds the card in memory so nothing touches the filesystem.
class InMemoryRateCardStorage implements RateCardStorage {
  String? _contents;

  @override
  Future<bool> exists() async => _contents != null;

  @override
  Future<String?> read() async => _contents;

  @override
  Future<void> write(String contents) async => _contents = contents;

  @override
  Future<void> delete() async => _contents = null;
}

class RateCardStore {
  final RateCardStorage _storage;

  /// Reads the shipped price list. Injected because `rootBundle` does not
  /// resolve inside `flutter test`'s fake-async zone, so a widget test using
  /// the real one would sit on a loading spinner forever.
  final Future<String> Function() _bundled;

  RateCardStore({
    RateCardStorage? storage,
    Future<Directory> Function()? directory,
    Future<String> Function()? bundled,
  }) : _storage = storage ?? FileRateCardStorage(directory: directory),
       _bundled =
           bundled ?? (() => rootBundle.loadString(bundledRateCardAsset));

  /// The raw JSON of the card in force: the admin's edit if there is one,
  /// otherwise the bundled list.
  ///
  /// The map rather than the parsed card, because applying a price change edits
  /// the map — see `applyRateCardImportToJson`.
  ///
  /// An override is only returned if it actually parses as a rate card. Bad
  /// JSON, or well-formed JSON that is not a card, is deleted and the bundled
  /// list used instead — mid-fair, an unreadable file must not stop someone
  /// quoting, and it must not fail again on the next launch.
  Future<Map<String, dynamic>> loadJson() async {
    final raw = await _storage.read();
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        // Parsed and thrown away purely to prove it is a card before anything
        // downstream depends on it.
        RateCard.fromJson(json);
        return json;
      } catch (_) {
        await _storage.delete();
      }
    }
    return loadBundledJson();
  }

  Future<Map<String, dynamic>> loadBundledJson() async =>
      jsonDecode(await _bundled()) as Map<String, dynamic>;

  /// The card in force, parsed.
  Future<RateCard> load() async => RateCard.fromJson(await loadJson());

  /// Saves an edited card as the one in force.
  Future<void> save(Map<String, dynamic> json) =>
      _storage.write(jsonEncode(json));

  /// Throws the admin's edits away and goes back to the shipped list.
  Future<void> restoreBundled() => _storage.delete();

  Future<bool> hasOverride() => _storage.exists();
}
