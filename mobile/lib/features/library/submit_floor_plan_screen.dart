/// A part-timer's own floor-plan submission. SPEC.md Phase 8's last open
/// item -- the handset sibling of the admin's dashboard upload, built for
/// exactly the scenario the client described: a customer WhatsApps a floor
/// plan to a part-timer's phone at a fair, and it needs to become something
/// quotable without waiting for a desk and a connection.
///
/// **Reference measurements are not site measurements**, and nothing here
/// changes that. Submitting writes a local row and queues it on the outbox,
/// mirroring `queueQuoteForOffice` -- "this never blocks and never fails
/// visibly." The server lands it at `pending_review`; it stays invisible to
/// quoting until an admin approves it, the same two-step gate the dashboard's
/// own upload goes through.
///
/// **A resumable multi-visit draft is deliberately not built here.** Every
/// other screen in this app persists on every keystroke because a dropped
/// phone call must cost nothing mid-quote; a floor-plan submission is a
/// shorter, lower-stakes piece of data entry, typed once and sent. If the
/// app is killed mid-form, the fields are lost and the part-timer starts
/// again -- a real simplification, named rather than silently accepted.
///
/// **AI recognition is a placeholder.** `ApiClient.recognize` always comes
/// back `configured: false` today (`app/services/recognition.py`'s
/// `NullRecognitionProvider`); this screen is wired against that contract so
/// turning on a real provider later touches only the server's config, not
/// this UI.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show InsertMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/length.dart';
import '../../core/length_parser.dart';
import '../../data/database.dart';
import '../../data/library_submission_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../sync/api_client.dart';
import '../../sync/library_submission_payload.dart';
import '../../sync/sync_state.dart';
import '../../ui/theme.dart';
import '../../ui/unit_labels.dart';
import '../quote/quote_state.dart' show databaseProvider;

/// Where the cached project list lives in `Settings` -- read with no
/// connection, written whenever one is available. `Project.id` stays
/// server-generated (see the server's own docstring for why), so a
/// submission can only ever point at a project this handset has already
/// seen with a connection in hand.
const _kLibraryProjectsCacheKey = 'library_projects_cache';

Future<List<ProjectSummary>> _readProjectCache(AppDatabase db) async {
  final row = await (db.select(
    db.settings,
  )..where((s) => s.key.equals(_kLibraryProjectsCacheKey))).getSingleOrNull();
  if (row == null) return const [];
  final list = jsonDecode(row.value) as List;
  return list.cast<Map<String, dynamic>>().map(ProjectSummary.fromJson).toList();
}

Future<void> _writeProjectCache(
  AppDatabase db,
  List<ProjectSummary> projects,
) => db
    .into(db.settings)
    .insert(
      SettingsCompanion.insert(
        key: _kLibraryProjectsCacheKey,
        value: jsonEncode([for (final p in projects) p.toJson()]),
      ),
      mode: InsertMode.insertOrReplace,
    );

const _kUnitChoices = [
  LengthUnit.foot,
  LengthUnit.inch,
  LengthUnit.mm,
  LengthUnit.cm,
  LengthUnit.m,
];

/// One window or door, still being typed in. Kept as a mutable draft object
/// (rather than immutable + `setState` replacing the list) so each row's
/// text fields can be given a stable `ObjectKey` across rebuilds.
class _OpeningDraft {
  String label = '';
  String room = '';
  String widthRaw = '';
  LengthUnit widthUnit = LengthUnit.foot;
  String heightRaw = '';
  LengthUnit heightUnit = LengthUnit.foot;
}

class _RoomDraft {
  String name = '';
  String widthRaw = '';
  LengthUnit widthUnit = LengthUnit.foot;
  String lengthRaw = '';
  LengthUnit lengthUnit = LengthUnit.foot;
}

class SubmitFloorPlanScreen extends ConsumerStatefulWidget {
  const SubmitFloorPlanScreen({super.key});

  @override
  ConsumerState<SubmitFloorPlanScreen> createState() =>
      _SubmitFloorPlanScreenState();
}

class _SubmitFloorPlanScreenState extends ConsumerState<SubmitFloorPlanScreen> {
  final _picker = ImagePicker();
  final _unitTypeName = TextEditingController();
  final _floorCount = TextEditingController();
  final _realDistance = TextEditingController();

  List<ProjectSummary> _projects = const [];
  ProjectSummary? _project;
  bool _refreshingProjects = false;
  bool _projectsFailed = false;

  final List<_OpeningDraft> _openings = [];
  final List<_RoomDraft> _rooms = [];

  String? _photoPath;
  String? _photoContentType;
  int? _imageWidth;
  int? _imageHeight;

  bool _calibrating = false;
  List<Offset> _calibPoints = [];
  LengthUnit _realDistanceUnit = LengthUnit.mm;
  int? _pixelDistance;
  int? _realDistanceTmm;

  bool _recognizing = false;
  RecognitionResult? _recognition;
  bool _recognizeFailed = false;

  bool _submitting = false;
  bool _submitted = false;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _loadCachedProjects();
    _refreshProjects();
  }

  @override
  void dispose() {
    _unitTypeName.dispose();
    _floorCount.dispose();
    _realDistance.dispose();
    super.dispose();
  }

  Future<String?> get _token async =>
      (await ref.read(credentialsProvider.future))?.token;

  Future<void> _loadCachedProjects() async {
    final cached = await _readProjectCache(ref.read(databaseProvider));
    if (mounted) setState(() => _projects = cached);
  }

  Future<void> _refreshProjects() async {
    setState(() {
      _refreshingProjects = true;
      _projectsFailed = false;
    });
    final token = await _token;
    if (!mounted) return;
    if (token == null) {
      setState(() => _refreshingProjects = false);
      return;
    }
    final result = await ref.read(apiClientProvider).projects(token: token);
    if (!mounted) return;
    if (result.ok) {
      final projects = result.valueOrNull!;
      await _writeProjectCache(ref.read(databaseProvider), projects);
      if (!mounted) return;
      setState(() {
        _projects = projects;
        _refreshingProjects = false;
        // The chosen project may have been renamed or dropped from the
        // list since the cache was last written -- keep the selection only
        // if it is still there, by id.
        if (_project != null) {
          _project = projects
              .where((p) => p.id == _project!.id)
              .cast<ProjectSummary?>()
              .firstOrNull;
        }
      });
    } else {
      setState(() {
        _refreshingProjects = false;
        _projectsFailed = _projects.isEmpty;
      });
    }
  }

  Future<void> _pickPhoto(ImageSource source) async {
    try {
      final shot = await _picker.pickImage(
        source: source,
        // Matches `line_photo.dart`'s own limits -- a floor plan needs to be
        // readable when tapped on, not printed.
        maxWidth: 1600,
        imageQuality: 70,
      );
      if (shot == null || !mounted) return;
      final bytes = await shot.readAsBytes();
      final decoded = await decodeImageFromList(bytes);
      if (!mounted) return;
      setState(() {
        _photoPath = shot.path;
        _photoContentType = _contentTypeFor(shot.path);
        _imageWidth = decoded.width;
        _imageHeight = decoded.height;
        _calibrating = false;
        _calibPoints = [];
        _pixelDistance = null;
        _realDistanceTmm = null;
        _recognition = null;
        _recognizeFailed = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  String _contentTypeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  void _removePhoto() {
    setState(() {
      _photoPath = null;
      _photoContentType = null;
      _imageWidth = null;
      _imageHeight = null;
      _calibrating = false;
      _calibPoints = [];
      _pixelDistance = null;
      _realDistanceTmm = null;
      _recognition = null;
    });
  }

  void _startCalibrating() {
    setState(() {
      _calibrating = true;
      _calibPoints = [];
      _realDistance.clear();
    });
  }

  void _cancelCalibrating() {
    setState(() {
      _calibrating = false;
      _calibPoints = [];
    });
  }

  int? get _tappedPixelDistance {
    if (_calibPoints.length != 2) return null;
    final dx = _calibPoints[1].dx - _calibPoints[0].dx;
    final dy = _calibPoints[1].dy - _calibPoints[0].dy;
    return math.sqrt(dx * dx + dy * dy).round();
  }

  void _confirmCalibration() {
    final px = _tappedPixelDistance;
    final parsed = parseLength(_realDistance.text, _realDistanceUnit);
    if (px == null || px <= 0 || parsed == null) return;
    setState(() {
      _pixelDistance = px;
      _realDistanceTmm = parsed.length.tmm;
      _calibrating = false;
    });
  }

  Future<void> _tryRecognition() async {
    final path = _photoPath;
    final contentType = _photoContentType;
    if (path == null || contentType == null) return;
    setState(() {
      _recognizing = true;
      _recognizeFailed = false;
    });
    final token = await _token;
    if (!mounted) return;
    if (token == null) {
      setState(() {
        _recognizing = false;
        _recognizeFailed = true;
      });
      return;
    }
    final bytes = await File(path).readAsBytes();
    final result = await ref
        .read(apiClientProvider)
        .recognize(
          token: token,
          contentType: contentType,
          imageBase64: base64Encode(bytes),
        );
    if (!mounted) return;
    setState(() {
      _recognizing = false;
      _recognizeFailed = !result.ok;
      _recognition = result.valueOrNull;
    });
  }

  /// Copies a proposal into the editable list -- never applied silently,
  /// always a person's own action, and still just as editable afterwards as
  /// anything typed by hand.
  void _applyProposedOpenings() {
    final proposed = _recognition?.openings ?? const [];
    setState(() {
      for (final o in proposed) {
        final draft = _OpeningDraft()
          ..label = o['label'] as String? ?? ''
          ..room = o['room'] as String? ?? ''
          ..widthUnit = LengthUnit.mm
          ..heightUnit = LengthUnit.mm;
        final w = o['nominal_w_tmm'] as int?;
        final h = o['nominal_h_tmm'] as int?;
        if (w != null) draft.widthRaw = (w / 10).toString();
        if (h != null) draft.heightRaw = (h / 10).toString();
        _openings.add(draft);
      }
    });
  }

  int? _roomAreaMm2(_RoomDraft r) {
    final w = parseLength(r.widthRaw, r.widthUnit)?.length;
    final l = parseLength(r.lengthRaw, r.lengthUnit)?.length;
    if (w == null || l == null) return null;
    // tenths-of-mm × tenths-of-mm is hundredths-of-mm² -- rounded once, here,
    // to the plain mm² `Room.nominal_area_mm2` actually stores.
    return (w.tmm * l.tmm + 50) ~/ 100;
  }

  Future<void> _submit() async {
    final project = _project;
    final name = _unitTypeName.text.trim();
    if (project == null || name.isEmpty) {
      setState(() => _validationError = L.of(context).libNeedProjectAndName);
      return;
    }
    setState(() {
      _submitting = true;
      _validationError = null;
    });

    final db = ref.read(databaseProvider);
    final repo = LibrarySubmissionRepository(db);
    final id = await repo.startDraft(
      projectId: project.id,
      projectName: project.name,
      unitTypeName: name,
      floorCount: int.tryParse(_floorCount.text.trim()),
    );

    final openings = [
      for (final o in _openings)
        if (_openingValid(o))
          SubmittedOpening(
            label: o.label.trim(),
            room: o.room.trim(),
            nominalWTmm: parseLength(o.widthRaw, o.widthUnit)!.length.tmm,
            nominalHTmm: parseLength(o.heightRaw, o.heightUnit)!.length.tmm,
          ),
    ];
    final rooms = [
      for (final r in _rooms)
        if (_roomValid(r))
          SubmittedRoom(
            name: r.name.trim(),
            nominalAreaMm2: _roomAreaMm2(r)!,
          ),
    ];

    await repo.setOpenings(id, openings);
    await repo.setRooms(id, rooms);
    if (_photoPath != null) {
      await repo.setPhoto(id, path: _photoPath, contentType: _photoContentType);
      if (_pixelDistance != null && _realDistanceTmm != null) {
        await repo.setCalibration(
          id,
          pixelDistance: _pixelDistance!,
          realDistanceTmm: _realDistanceTmm!,
        );
      }
    }

    final row = await repo.find(id);
    final payload = await libraryySubmissionPayload(
      submission: row!,
      openings: openings,
      rooms: rooms,
    );
    await repo.markQueued(id);
    await ref.read(outboxerProvider).enqueueLibrarySubmission(id, payload);
    // The badge in the app bar, the same invalidation `queueQuoteForOffice`
    // does -- without it a part-timer has no sign the submission was kept.
    ref.invalidate(outboxDepthProvider);

    if (!mounted) return;
    setState(() {
      _submitting = false;
      _submitted = true;
    });
  }

  bool _openingValid(_OpeningDraft o) =>
      o.label.trim().isNotEmpty &&
      o.room.trim().isNotEmpty &&
      parseLength(o.widthRaw, o.widthUnit) != null &&
      parseLength(o.heightRaw, o.heightUnit) != null;

  bool _roomValid(_RoomDraft r) =>
      r.name.trim().isNotEmpty && _roomAreaMm2(r) != null;

  void _reset() {
    setState(() {
      _project = null;
      _unitTypeName.clear();
      _floorCount.clear();
      _openings.clear();
      _rooms.clear();
      _removePhoto();
      _submitted = false;
      _validationError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);

    if (_submitted) {
      return Scaffold(
        appBar: AppBar(title: Text(l.libTitle)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(Space.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  size: 48,
                  color: AppColors.primary,
                ),
                const SizedBox(height: Space.lg),
                Text(
                  l.libSubmitted,
                  style: AppText.body,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Space.xl),
                FilledButton(onPressed: _reset, child: Text(l.libSubmitAnother)),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.libTitle)),
      body: ListView(
        key: const Key('lib-scroll'),
        padding: const EdgeInsets.all(Space.lg),
        children: [
          Text(l.libIntro, style: AppText.caption),
          const SizedBox(height: Space.lg),
          _projectSection(l),
          const SizedBox(height: Space.xl),
          _unitTypeSection(l),
          const SizedBox(height: Space.xl),
          _photoSection(l),
          const SizedBox(height: Space.xl),
          _openingsSection(l),
          const SizedBox(height: Space.xl),
          _roomsSection(l),
          const SizedBox(height: Space.xl),
          if (_validationError != null) ...[
            Text(
              _validationError!,
              style: AppText.body.copyWith(color: AppColors.destructive),
            ),
            const SizedBox(height: Space.md),
          ],
          FilledButton(
            key: const Key('lib-submit'),
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l.libSubmit),
          ),
        ],
      ),
    );
  }

  Widget _projectSection(L l) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.libProjectLabel, style: AppText.label),
        const SizedBox(height: Space.sm),
        if (_projects.isEmpty)
          Text(
            _projectsFailed ? l.libProjectsFailed : l.libNoProjectsCached,
            style: AppText.caption,
          )
        else
          DropdownButtonFormField<ProjectSummary>(
            key: const Key('lib-project-dropdown'),
            initialValue: _project,
            isExpanded: true,
            hint: Text(l.libProjectHint),
            items: [
              for (final p in _projects)
                DropdownMenuItem(value: p, child: Text(p.name)),
            ],
            onChanged: (p) => setState(() => _project = p),
          ),
        const SizedBox(height: Space.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _refreshingProjects ? null : _refreshProjects,
            icon: _refreshingProjects
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(l.libRefreshProjects),
          ),
        ),
      ],
    );
  }

  Widget _unitTypeSection(L l) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('lib-unit-type-name'),
          controller: _unitTypeName,
          decoration: InputDecoration(
            labelText: l.libUnitTypeNameLabel,
            hintText: l.libUnitTypeNameHint,
          ),
        ),
        const SizedBox(height: Space.md),
        TextField(
          key: const Key('lib-floor-count'),
          controller: _floorCount,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: l.libFloorCountLabel),
        ),
      ],
    );
  }

  Widget _photoSection(L l) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.libPhotoSectionTitle, style: AppText.label),
        const SizedBox(height: Space.sm),
        if (_photoPath == null)
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: () => _pickPhoto(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(l.libPickFromGallery),
              ),
              const SizedBox(width: Space.sm),
              OutlinedButton.icon(
                onPressed: () => _pickPhoto(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(l.libTakePhoto),
              ),
            ],
          )
        else ...[
          if (_calibrating)
            _calibrationArea(l)
          else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.md),
              child: Image.file(
                File(_photoPath!),
                height: 200,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: Space.sm),
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                OutlinedButton(
                  onPressed: _startCalibrating,
                  child: Text(
                    _pixelDistance == null ? l.libCalibrate : l.libRecalibrate,
                  ),
                ),
                if (_pixelDistance != null)
                  Center(
                    child: Text(l.libCalibrated, style: AppText.caption),
                  ),
                OutlinedButton(
                  onPressed: _recognizing ? null : _tryRecognition,
                  child: _recognizing
                      ? Text(l.libRecognizing)
                      : Text(l.libTryRecognition),
                ),
                TextButton(
                  onPressed: _removePhoto,
                  child: Text(l.libRemovePhoto),
                ),
              ],
            ),
            if (_recognizeFailed) ...[
              const SizedBox(height: Space.sm),
              Text(
                l.libRecognitionFailed,
                style: AppText.body.copyWith(color: AppColors.destructive),
              ),
            ],
            if (_recognition != null) ...[
              const SizedBox(height: Space.sm),
              if (!_recognition!.configured)
                Text(l.libRecognitionNotConfigured, style: AppText.caption)
              else ...[
                Text(
                  l.libRecognitionProposedOpenings(_recognition!.openings.length),
                  style: AppText.caption,
                ),
                if (_recognition!.openings.isNotEmpty)
                  TextButton(
                    onPressed: _applyProposedOpenings,
                    child: Text(l.libApplyProposal),
                  ),
              ],
            ],
          ],
        ],
      ],
    );
  }

  Widget _calibrationArea(L l) {
    final imgW = _imageWidth!;
    final imgH = _imageHeight!;
    final displayWidth = MediaQuery.of(context).size.width - Space.lg * 2;
    final displayHeight = displayWidth * imgH / imgW;
    final px = _tappedPixelDistance;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _calibPoints.length == 1 ? l.libOnePointChosen : l.libClickTwoPoints,
          style: AppText.caption,
        ),
        const SizedBox(height: Space.sm),
        GestureDetector(
          onTapUp: (details) {
            if (_calibPoints.length >= 2) return;
            final scaleX = imgW / displayWidth;
            final scaleY = imgH / displayHeight;
            setState(() {
              _calibPoints = [
                ..._calibPoints,
                Offset(
                  details.localPosition.dx * scaleX,
                  details.localPosition.dy * scaleY,
                ),
              ];
            });
          },
          child: SizedBox(
            width: displayWidth,
            height: displayHeight,
            child: Image.file(
              File(_photoPath!),
              width: displayWidth,
              height: displayHeight,
              fit: BoxFit.fill,
            ),
          ),
        ),
        if (px != null) ...[
          const SizedBox(height: Space.md),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _realDistance,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(labelText: l.libRealDistanceLabel),
                ),
              ),
              const SizedBox(width: Space.sm),
              DropdownButton<LengthUnit>(
                value: _realDistanceUnit,
                items: [
                  for (final u in _kUnitChoices)
                    DropdownMenuItem(value: u, child: Text(unitLabel(l, u))),
                ],
                onChanged: (u) {
                  if (u != null) setState(() => _realDistanceUnit = u);
                },
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Row(
            children: [
              FilledButton(
                onPressed: _confirmCalibration,
                child: Text(l.libConfirmCalibration),
              ),
              const SizedBox(width: Space.sm),
              TextButton(
                onPressed: _cancelCalibrating,
                child: Text(l.libCancelCalibration),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _openingsSection(L l) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.libOpeningsSectionTitle, style: AppText.label),
        const SizedBox(height: Space.sm),
        for (var i = 0; i < _openings.length; i++) _openingRow(l, _openings[i], i),
        OutlinedButton.icon(
          onPressed: () => setState(() => _openings.add(_OpeningDraft())),
          icon: const Icon(Icons.add),
          label: Text(l.libAddOpening),
        ),
      ],
    );
  }

  Widget _openingRow(L l, _OpeningDraft o, int index) {
    return Container(
      key: ObjectKey(o),
      margin: const EdgeInsets.only(bottom: Space.md),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  key: Key('opening-$index-label'),
                  initialValue: o.label,
                  decoration: InputDecoration(
                    labelText: l.libOpeningLabelField,
                    hintText: l.libOpeningLabelHint,
                  ),
                  onChanged: (v) => o.label = v,
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: TextFormField(
                  key: Key('opening-$index-room'),
                  initialValue: o.room,
                  decoration: InputDecoration(labelText: l.libRoomField),
                  onChanged: (v) => o.room = v,
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Row(
            children: [
              Expanded(
                child: _lengthField(
                  key: Key('opening-$index-width'),
                  raw: o.widthRaw,
                  unit: o.widthUnit,
                  label: l.libWidthField,
                  onRaw: (v) => o.widthRaw = v,
                  onUnit: (u) => setState(() => o.widthUnit = u),
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: _lengthField(
                  key: Key('opening-$index-height'),
                  raw: o.heightRaw,
                  unit: o.heightUnit,
                  label: l.libHeightField,
                  onRaw: (v) => o.heightRaw = v,
                  onUnit: (u) => setState(() => o.heightUnit = u),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _openings.remove(o)),
              child: Text(l.libRemoveOpening),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roomsSection(L l) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.libRoomsSectionTitle, style: AppText.label),
        const SizedBox(height: Space.sm),
        for (var i = 0; i < _rooms.length; i++) _roomRow(l, _rooms[i], i),
        OutlinedButton.icon(
          onPressed: () => setState(() => _rooms.add(_RoomDraft())),
          icon: const Icon(Icons.add),
          label: Text(l.libAddRoom),
        ),
      ],
    );
  }

  Widget _roomRow(L l, _RoomDraft r, int index) {
    return Container(
      key: ObjectKey(r),
      margin: const EdgeInsets.only(bottom: Space.md),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            key: Key('room-$index-name'),
            initialValue: r.name,
            decoration: InputDecoration(labelText: l.libRoomNameField),
            onChanged: (v) => r.name = v,
          ),
          const SizedBox(height: Space.sm),
          Row(
            children: [
              Expanded(
                child: _lengthField(
                  key: Key('room-$index-width'),
                  raw: r.widthRaw,
                  unit: r.widthUnit,
                  label: l.libWidthField,
                  onRaw: (v) => r.widthRaw = v,
                  onUnit: (u) => setState(() => r.widthUnit = u),
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: _lengthField(
                  key: Key('room-$index-length'),
                  raw: r.lengthRaw,
                  unit: r.lengthUnit,
                  label: l.libRoomLengthField,
                  onRaw: (v) => r.lengthRaw = v,
                  onUnit: (u) => setState(() => r.lengthUnit = u),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _rooms.remove(r)),
              child: Text(l.libRemoveRoom),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lengthField({
    required Key key,
    required String raw,
    required LengthUnit unit,
    required String label,
    required ValueChanged<String> onRaw,
    required ValueChanged<LengthUnit> onUnit,
  }) {
    final l = L.of(context);
    final invalid = raw.trim().isNotEmpty && parseLength(raw, unit) == null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextFormField(
            key: key,
            initialValue: raw,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: label,
              errorText: invalid ? l.libInvalidDimension : null,
            ),
            onChanged: onRaw,
          ),
        ),
        const SizedBox(width: Space.xs),
        DropdownButton<LengthUnit>(
          value: unit,
          items: [
            for (final u in _kUnitChoices)
              DropdownMenuItem(value: u, child: Text(unitLabel(l, u))),
          ],
          onChanged: (u) {
            if (u != null) onUnit(u);
          },
        ),
      ],
    );
  }
}
