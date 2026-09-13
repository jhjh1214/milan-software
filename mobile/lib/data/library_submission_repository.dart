/// Reads and writes a part-timer's own floor-plan submission. SPEC.md
/// Phase 8's last open item -- the offline sibling of the admin's dashboard
/// upload, built so a floor plan a customer WhatsApped to a part-timer's
/// phone at a fair can become a submission with no signal in the room.
///
/// Two lifecycles compose here: this repository owns a draft -- create it,
/// edit its openings and rooms, attach a photo, calibrate it -- until it is
/// handed to the outbox. After `markQueued`, the row is history the outbox
/// is pushing, and nothing here edits it again -- the same "never touch what
/// is already queued" rule the outbox's own payload-freezing enforces
/// everywhere else.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import 'database.dart';
import 'quote_repository.dart' show newId;

/// One window or door, as typed from the developer's schedule (or read off
/// a photo a customer sent over WhatsApp). Mirrors the server's `OpeningIn`.
class SubmittedOpening {
  final String label;
  final String room;
  final int nominalWTmm;
  final int nominalHTmm;

  const SubmittedOpening({
    required this.label,
    required this.room,
    required this.nominalWTmm,
    required this.nominalHTmm,
  });

  Map<String, dynamic> toJson() => {
    'label': label,
    'room': room,
    'nominal_w_tmm': nominalWTmm,
    'nominal_h_tmm': nominalHTmm,
  };

  factory SubmittedOpening.fromJson(Map<String, dynamic> json) =>
      SubmittedOpening(
        label: json['label'] as String,
        room: json['room'] as String,
        nominalWTmm: json['nominal_w_tmm'] as int,
        nominalHTmm: json['nominal_h_tmm'] as int,
      );
}

/// One room's floor, typed as an area rather than read off the image --
/// SPEC.md Phase 8 is explicit that the numbers come from the schedule, not
/// from the plan. Mirrors the server's `RoomIn`.
class SubmittedRoom {
  final String name;
  final int nominalAreaMm2;

  const SubmittedRoom({required this.name, required this.nominalAreaMm2});

  Map<String, dynamic> toJson() => {
    'name': name,
    'nominal_area_mm2': nominalAreaMm2,
  };

  factory SubmittedRoom.fromJson(Map<String, dynamic> json) => SubmittedRoom(
    name: json['name'] as String,
    nominalAreaMm2: json['nominal_area_mm2'] as int,
  );
}

class LibrarySubmissionRepository {
  final AppDatabase _db;

  LibrarySubmissionRepository(this._db);

  /// Starts a new draft. Returns its id -- the same id that becomes the unit
  /// type's own id on the server once pushed.
  Future<String> startDraft({
    required String projectId,
    required String projectName,
    required String unitTypeName,
    int? floorCount,
  }) async {
    final id = newId();
    await _db
        .into(_db.librarySubmissions)
        .insert(
          LibrarySubmissionsCompanion.insert(
            id: id,
            projectId: projectId,
            projectName: projectName,
            unitTypeName: unitTypeName,
            floorCount: Value(floorCount),
            createdAt: DateTime.now(),
          ),
        );
    return id;
  }

  Future<LibrarySubmissionRow?> find(String id) => (_db.select(
    _db.librarySubmissions,
  )..where((s) => s.id.equals(id))).getSingleOrNull();

  /// Everything not yet handed to the outbox -- unfinished business waiting
  /// for the part-timer to come back to it.
  Future<List<LibrarySubmissionRow>> drafts() =>
      (_db.select(_db.librarySubmissions)
            ..where((s) => s.queuedAt.isNull())
            ..orderBy([(s) => OrderingTerm.desc(s.createdAt)]))
          .get();

  Future<void> setOpenings(String id, List<SubmittedOpening> openings) =>
      (_db.update(_db.librarySubmissions)..where((s) => s.id.equals(id))).write(
        LibrarySubmissionsCompanion(
          openingsJson: Value(
            jsonEncode(openings.map((o) => o.toJson()).toList()),
          ),
        ),
      );

  Future<void> setRooms(String id, List<SubmittedRoom> rooms) =>
      (_db.update(_db.librarySubmissions)..where((s) => s.id.equals(id))).write(
        LibrarySubmissionsCompanion(
          roomsJson: Value(jsonEncode(rooms.map((r) => r.toJson()).toList())),
        ),
      );

  Future<void> setPhoto(String id, {String? path, String? contentType}) =>
      (_db.update(_db.librarySubmissions)..where((s) => s.id.equals(id))).write(
        LibrarySubmissionsCompanion(
          photoPath: Value(path),
          photoContentType: Value(contentType),
          // A new photo invalidates whatever was tapped on the old one.
          pixelDistance: const Value(null),
          realDistanceTmm: const Value(null),
        ),
      );

  Future<void> setCalibration(
    String id, {
    required int pixelDistance,
    required int realDistanceTmm,
  }) =>
      (_db.update(_db.librarySubmissions)..where((s) => s.id.equals(id))).write(
        LibrarySubmissionsCompanion(
          pixelDistance: Value(pixelDistance),
          realDistanceTmm: Value(realDistanceTmm),
        ),
      );

  Future<void> setUnitTypeName(String id, String name) =>
      (_db.update(_db.librarySubmissions)..where((s) => s.id.equals(id))).write(
        LibrarySubmissionsCompanion(unitTypeName: Value(name)),
      );

  List<SubmittedOpening> openingsOf(LibrarySubmissionRow row) =>
      (jsonDecode(row.openingsJson) as List)
          .cast<Map<String, dynamic>>()
          .map(SubmittedOpening.fromJson)
          .toList();

  List<SubmittedRoom> roomsOf(LibrarySubmissionRow row) =>
      (jsonDecode(row.roomsJson) as List)
          .cast<Map<String, dynamic>>()
          .map(SubmittedRoom.fromJson)
          .toList();

  /// Marks a draft as handed to the outbox. Called right before
  /// `Outboxer.enqueueLibrarySubmission` -- after this the row is history,
  /// not something this repository edits again.
  Future<void> markQueued(String id) =>
      (_db.update(_db.librarySubmissions)..where((s) => s.id.equals(id))).write(
        LibrarySubmissionsCompanion(queuedAt: Value(DateTime.now())),
      );

  Future<void> deleteDraft(String id) =>
      (_db.delete(_db.librarySubmissions)..where((s) => s.id.equals(id))).go();
}
