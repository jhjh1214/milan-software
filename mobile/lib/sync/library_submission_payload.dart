/// Turning a stored floor-plan submission into what the server expects.
/// SPEC.md Phase 8.
///
/// Unlike an order or a payment, the image travels **inside** this same
/// payload as base64 rather than through a second multipart request -- the
/// whole submission is one outbox row, frozen at enqueue time, so a flaky
/// fair connection has one request to get through rather than two that must
/// both land.
library;

import 'dart:convert';
import 'dart:io';

import '../data/database.dart';
import '../data/library_submission_repository.dart';

/// Builds the request body for `POST /api/unit-type-submissions`.
///
/// Reads the photo file from disk if one was attached -- the one place this
/// payload does I/O, which is why building it is asynchronous unlike every
/// other payload in `sync/`.
Future<Map<String, dynamic>> libraryySubmissionPayload({
  required LibrarySubmissionRow submission,
  required List<SubmittedOpening> openings,
  required List<SubmittedRoom> rooms,
}) async {
  Map<String, dynamic>? floorPlan;
  final path = submission.photoPath;
  if (path != null) {
    final file = File(path);
    // The file can vanish between being attached and being pushed -- Android
    // clears its cache directory under pressure, the same failure
    // `LinePhoto` already degrades from. A submission with no photo is still
    // worth sending; failing the whole push over a missing thumbnail is not.
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      floorPlan = {
        'filename': path.split(Platform.pathSeparator).last,
        'content_type': submission.photoContentType ?? 'image/jpeg',
        'image_base64': base64Encode(bytes),
        'pixel_distance': ?submission.pixelDistance,
        'real_distance_tmm': ?submission.realDistanceTmm,
      };
    }
  }

  return {
    'id': submission.id,
    'project_id': submission.projectId,
    'name': submission.unitTypeName,
    'floor_count': ?submission.floorCount,
    'openings': [for (final o in openings) o.toJson()],
    'rooms': [for (final r in rooms) r.toJson()],
    'floor_plan': ?floorPlan,
  };
}
