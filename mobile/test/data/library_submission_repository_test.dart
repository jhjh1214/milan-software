/// A part-timer's own floor-plan submission, held locally before the outbox
/// pushes it. SPEC.md Phase 8's last open item.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/library_submission_repository.dart';

void main() {
  late AppDatabase db;
  late LibrarySubmissionRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = LibrarySubmissionRepository(db);
  });

  tearDown(() => db.close());

  test('a new draft starts with empty openings and rooms, unqueued', () async {
    final id = await repo.startDraft(
      projectId: 'p-1',
      projectName: 'ABC Development',
      unitTypeName: 'Type C',
    );

    final row = await repo.find(id);
    expect(row, isNotNull);
    expect(row!.projectId, 'p-1');
    expect(row.openingsJson, '[]');
    expect(row.roomsJson, '[]');
    expect(row.queuedAt, isNull);
  });

  test('openings and rooms round-trip through JSON', () async {
    final id = await repo.startDraft(
      projectId: 'p-1',
      projectName: 'ABC Development',
      unitTypeName: 'Type C',
    );

    await repo.setOpenings(id, const [
      SubmittedOpening(
        label: 'W1',
        room: 'Living',
        nominalWTmm: 18000,
        nominalHTmm: 24000,
      ),
    ]);
    await repo.setRooms(id, const [
      SubmittedRoom(name: 'Living', nominalAreaMm2: 18_000_000),
    ]);

    final row = (await repo.find(id))!;
    final openings = repo.openingsOf(row);
    final rooms = repo.roomsOf(row);

    expect(openings, hasLength(1));
    expect(openings.single.label, 'W1');
    expect(openings.single.nominalWTmm, 18000);
    expect(rooms.single.nominalAreaMm2, 18_000_000);
  });

  test('a photo replaces any calibration already tapped on the old one', () async {
    final id = await repo.startDraft(
      projectId: 'p-1',
      projectName: 'ABC Development',
      unitTypeName: 'Type C',
    );
    await repo.setPhoto(id, path: '/tmp/plan.jpg', contentType: 'image/jpeg');
    await repo.setCalibration(id, pixelDistance: 500, realDistanceTmm: 30000);

    // A new photo makes the old scale meaningless -- a tap on the previous
    // image means nothing on a different one.
    await repo.setPhoto(id, path: '/tmp/plan2.jpg', contentType: 'image/jpeg');

    final row = (await repo.find(id))!;
    expect(row.photoPath, '/tmp/plan2.jpg');
    expect(row.pixelDistance, isNull);
    expect(row.realDistanceTmm, isNull);
  });

  test('markQueued stamps the row and drafts() no longer lists it', () async {
    final keep = await repo.startDraft(
      projectId: 'p-1',
      projectName: 'ABC Development',
      unitTypeName: 'Still drafting',
    );
    final sent = await repo.startDraft(
      projectId: 'p-1',
      projectName: 'ABC Development',
      unitTypeName: 'Already sent',
    );
    await repo.markQueued(sent);

    final drafts = await repo.drafts();
    expect(drafts.map((d) => d.id), [keep]);
    expect((await repo.find(sent))!.queuedAt, isNotNull);
  });

  test('deleting a draft removes it', () async {
    final id = await repo.startDraft(
      projectId: 'p-1',
      projectName: 'ABC Development',
      unitTypeName: 'Type C',
    );
    await repo.deleteDraft(id);
    expect(await repo.find(id), isNull);
  });
}
