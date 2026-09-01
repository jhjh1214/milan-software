import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `shared/` is the source of truth for the rate card; `mobile/assets/data/`
/// holds the copy Flutter can bundle, because assets must live inside the
/// package. This test is the only thing stopping the two drifting apart, and a
/// drift would mean the app quoting from a stale price list.
void main() {
  test('the bundled rate card matches shared/rate-card-fair-2026-08.json', () {
    var dir = Directory.current;
    while (!File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).existsSync()) {
      final parent = dir.parent;
      if (parent.path == dir.path) fail('repo root not found');
      dir = parent;
    }

    final source = File('${dir.path}/shared/rate-card-fair-2026-08.json');
    final bundled = File(
      '${dir.path}/mobile/assets/data/rate-card-fair-2026-08.json',
    );

    expect(bundled.existsSync(), isTrue, reason: 'asset copy is missing');
    expect(
      bundled.readAsStringSync().replaceAll('\r\n', '\n'),
      source.readAsStringSync().replaceAll('\r\n', '\n'),
      reason:
          'mobile/assets/data/rate-card-fair-2026-08.json has drifted from shared/. '
          'Copy shared/rate-card-fair-2026-08.json over it — shared/ is the source.',
    );
  });
}
