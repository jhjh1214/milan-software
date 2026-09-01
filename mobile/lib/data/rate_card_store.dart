/// Where an edited price list lives.
///
/// The bundled asset is the card the app ships with. When the admin imports a
/// change, the result is written to app documents and used in preference — so a
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

class RateCardStore {
  /// Where the override is kept. Injected so tests do not touch app storage.
  final Future<Directory> Function() _directory;

  RateCardStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationDocumentsDirectory;

  Future<File> _file() async =>
      File('${(await _directory()).path}/$_overrideFileName');

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
    final file = await _file();
    if (file.existsSync()) {
      try {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        // Parsed and thrown away purely to prove it is a card before anything
        // downstream depends on it.
        RateCard.fromJson(json);
        return json;
      } catch (_) {
        await file.delete();
      }
    }
    return loadBundledJson();
  }

  Future<Map<String, dynamic>> loadBundledJson() async =>
      jsonDecode(await rootBundle.loadString(bundledRateCardAsset))
          as Map<String, dynamic>;

  /// The card in force, parsed.
  Future<RateCard> load() async => RateCard.fromJson(await loadJson());

  /// Saves an edited card as the one in force.
  Future<void> save(Map<String, dynamic> json) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(json), flush: true);
  }

  /// Throws the admin's edits away and goes back to the shipped list.
  Future<void> restoreBundled() async {
    final file = await _file();
    if (file.existsSync()) await file.delete();
  }

  Future<bool> hasOverride() async => (await _file()).existsSync();
}
