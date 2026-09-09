/// Reading the Property / Project / Unit Library. SPEC.md Phase 8.
///
/// Read-only and online-only, unlike the rate card pull: the library is
/// row-level and growing, not a small versioned document, and picking a
/// unit type happens with a connection in hand. See SPEC.md §13's open
/// question about whether this ever needs to work fully offline.
///
/// What matters most here is the gate: a part-timer's own pending submission
/// must never come back from [ApiClient.unitTypes] (it always asks for
/// `approved`), and [ApprovedUnitType.latestApproved] must never pick a
/// version nobody has approved.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/sync/api_client.dart';

import 'fake_server.dart';

void main() {
  late FakeServer server;
  late ApiClient client;

  setUp(() {
    server = FakeServer();
    client = ApiClient(
      baseUrl: Uri.parse('https://example.test'),
      client: server.client,
      timeout: const Duration(milliseconds: 200),
    );
  });

  tearDown(() => client.close());

  group('projects', () {
    test('finds by area or by name', () async {
      server.projects = [
        {
          'id': 'p1',
          'name': 'ABC Development',
          'developer': 'ABC Holdings',
          'area': 'Ayer Keroh',
        },
        {
          'id': 'p2',
          'name': 'XYZ Residences',
          'developer': null,
          'area': 'Bukit Beruang',
        },
      ];

      final byArea = (await client.projects(
        token: 'good-token',
        query: 'ayer',
      )).valueOrNull!;
      expect(byArea.map((p) => p.name), ['ABC Development']);

      final byName = (await client.projects(
        token: 'good-token',
        query: 'XYZ',
      )).valueOrNull!;
      expect(byName.map((p) => p.name), ['XYZ Residences']);
    });

    test('no query returns everything', () async {
      server.projects = [
        {
          'id': 'p1',
          'name': 'ABC Development',
          'developer': null,
          'area': null,
        },
      ];
      final all = (await client.projects(token: 'good-token')).valueOrNull!;
      expect(all, hasLength(1));
    });
  });

  group('unit types', () {
    test('asks the server for approved only, never pending', () async {
      server.unitTypesByProject['p1'] = [
        {
          'id': 'ut1',
          'project_id': 'p1',
          'project_name': 'ABC Development',
          'name': 'Type A',
          'status': 'approved',
        },
        {
          'id': 'ut2',
          'project_id': 'p1',
          'project_name': 'ABC Development',
          'name': 'Type B (pending)',
          'status': 'pending_review',
        },
      ];

      final result = await client.unitTypes(
        token: 'good-token',
        projectId: 'p1',
      );

      // The request itself asked for `status=approved` -- the gate is on the
      // wire, not just in what this fake happens to filter.
      final sent = server.seen.last;
      expect(sent.url.queryParameters['status'], 'approved');
      expect(result.valueOrNull!.map((u) => u.name), ['Type A']);
    });
  });

  group('ApprovedUnitType.latestApproved', () {
    test('null when nothing has been approved yet', () {
      final detail = {
        'unit_type': {'id': 'ut1'},
        'versions': [
          {
            'id': 'v1',
            'version': 1,
            'approved_at': null,
            'openings': <Map<String, dynamic>>[],
          },
        ],
      };
      expect(ApprovedUnitType.latestApproved(detail), isNull);
    });

    test('picks the latest approved version, not the latest submitted', () {
      // A correction (v2) is under review; v1 is still what a quote may
      // actually start from until v2 is approved too.
      final detail = {
        'unit_type': {'id': 'ut1'},
        'versions': [
          {
            'id': 'v1',
            'version': 1,
            'approved_at': '2026-09-01T09:00:00Z',
            'openings': [
              {
                'id': 'o1',
                'label': 'W1',
                'room': 'Living',
                'nominal_w_tmm': 18000,
                'nominal_h_tmm': 24000,
              },
            ],
          },
          {
            'id': 'v2',
            'version': 2,
            'approved_at': null,
            'openings': <Map<String, dynamic>>[],
          },
        ],
      };

      final approved = ApprovedUnitType.latestApproved(detail)!;
      expect(approved.version, 1);
      expect(approved.openings, hasLength(1));
      expect(approved.openings.single.label, 'W1');
    });
  });

  test('an unknown unit type is a 404, not a crash', () async {
    final result = await client.unitTypeDetail(
      token: 'good-token',
      unitTypeId: 'not-a-real-id',
    );
    expect(result.ok, isFalse);
  });
}
