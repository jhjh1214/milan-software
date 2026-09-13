/// Turning a stored floor-plan submission into the wire body. SPEC.md
/// Phase 8. What matters here is the one thing this payload does that no
/// other one in `sync/` does: reading a file from disk and folding its bytes
/// into the same JSON the rest of the submission travels in.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/library_submission_repository.dart';
import 'package:milan_quote/sync/library_submission_payload.dart';

void main() {
  late AppDatabase db;
  late LibrarySubmissionRepository repo;
  late Directory tempDir;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = LibrarySubmissionRepository(db);
    tempDir = Directory.systemTemp.createTempSync('milan_library_payload');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('carries the ids, name and dimensions plainly', () async {
    final id = await repo.startDraft(
      projectId: 'p-1',
      projectName: 'ABC Development',
      unitTypeName: 'Type C',
      floorCount: 2,
    );
    final row = (await repo.find(id))!;
    const openings = [
      SubmittedOpening(
        label: 'W1',
        room: 'Living',
        nominalWTmm: 18000,
        nominalHTmm: 24000,
      ),
    ];
    const rooms = [SubmittedRoom(name: 'Living', nominalAreaMm2: 18_000_000)];

    final payload = await libraryySubmissionPayload(
      submission: row,
      openings: openings,
      rooms: rooms,
    );

    expect(payload['id'], id);
    expect(payload['project_id'], 'p-1');
    expect(payload['name'], 'Type C');
    expect(payload['floor_count'], 2);
    expect(payload['openings'], [
      {
        'label': 'W1',
        'room': 'Living',
        'nominal_w_tmm': 18000,
        'nominal_h_tmm': 24000,
      },
    ]);
    expect(payload['rooms'], [
      {'name': 'Living', 'nominal_area_mm2': 18000000},
    ]);
    expect(payload.containsKey('floor_plan'), isFalse);
  });

  test(
    'a photo is read from disk and sent as base64, with its calibration',
    () async {
      final file = File('${tempDir.path}${Platform.pathSeparator}plan.jpg');
      final bytes = utf8.encode('fake jpeg bytes');
      file.writeAsBytesSync(bytes);

      final id = await repo.startDraft(
        projectId: 'p-1',
        projectName: 'ABC Development',
        unitTypeName: 'Type C',
      );
      await repo.setPhoto(id, path: file.path, contentType: 'image/jpeg');
      await repo.setCalibration(id, pixelDistance: 500, realDistanceTmm: 30000);
      final row = (await repo.find(id))!;

      final payload = await libraryySubmissionPayload(
        submission: row,
        openings: const [],
        rooms: const [],
      );

      final floorPlan = payload['floor_plan'] as Map<String, dynamic>;
      expect(floorPlan['filename'], 'plan.jpg');
      expect(floorPlan['content_type'], 'image/jpeg');
      expect(base64Decode(floorPlan['image_base64'] as String), bytes);
      expect(floorPlan['pixel_distance'], 500);
      expect(floorPlan['real_distance_tmm'], 30000);
    },
  );

  test(
    'an uncalibrated photo is still sent, with no calibration fields',
    () async {
      final file = File('${tempDir.path}${Platform.pathSeparator}plan.jpg');
      file.writeAsBytesSync(utf8.encode('data'));

      final id = await repo.startDraft(
        projectId: 'p-1',
        projectName: 'ABC Development',
        unitTypeName: 'Type C',
      );
      await repo.setPhoto(id, path: file.path, contentType: 'image/jpeg');
      final row = (await repo.find(id))!;

      final payload = await libraryySubmissionPayload(
        submission: row,
        openings: const [],
        rooms: const [],
      );

      final floorPlan = payload['floor_plan'] as Map<String, dynamic>;
      expect(floorPlan.containsKey('pixel_distance'), isFalse);
      expect(floorPlan.containsKey('real_distance_tmm'), isFalse);
    },
  );

  test(
    'a photo path that no longer exists is left out rather than crashing',
    () async {
      // The file can vanish between being attached and being pushed -- Android
      // clears its cache directory under pressure, the same failure
      // `LinePhoto` already degrades from. Losing the photo must not lose the
      // rest of the submission.
      final id = await repo.startDraft(
        projectId: 'p-1',
        projectName: 'ABC Development',
        unitTypeName: 'Type C',
      );
      await repo.setPhoto(
        id,
        path: '${tempDir.path}${Platform.pathSeparator}gone.jpg',
        contentType: 'image/jpeg',
      );
      final row = (await repo.find(id))!;

      final payload = await libraryySubmissionPayload(
        submission: row,
        openings: const [],
        rooms: const [],
      );

      expect(payload.containsKey('floor_plan'), isFalse);
    },
  );
}
