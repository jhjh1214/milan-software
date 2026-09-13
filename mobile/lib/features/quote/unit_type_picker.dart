/// Starting a line from a saved plan. SPEC.md Phase 8.
///
/// > A salesperson hears "ABC Development, Type B", picks the development,
/// > picks the unit type, and the known windows... load. They choose products
/// > and a reference quotation exists in seconds.
///
/// Three short steps -- project, unit type, window -- each one decision,
/// matching the wizard's own §8.1 rule. Read-only and **online-only**,
/// unlike the rate card pull: the library is row-level and growing, not a
/// small versioned document, and picking a unit type is something that
/// happens with a connection in hand, not mid-fair with none. SPEC.md §13
/// carries the open question of whether this ever needs to work fully
/// offline.
///
/// Only `approved` unit types are ever asked for. A part-timer's own pending
/// submission stays invisible to quoting until an admin has approved it --
/// the two-step gate the library's whole design turns on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/length.dart';
import '../../core/rational.dart';
import '../../l10n/app_localizations.dart';
import '../../sync/api_client.dart';
import '../../sync/sync_state.dart';
import '../../ui/theme.dart';

/// What was picked from the library, ready to seed a new quote line.
///
/// Two shapes, because a window and a room seed a line differently: an
/// opening gives a width and a height for any product; a room gives only an
/// area (SPEC.md's property library -- a real room is not always a
/// rectangle, so there is no width and length to keep), which only a
/// `per_sqft` flooring line can price from.
sealed class LibraryPick {
  final String sourceProjectId;
  final String sourceUnitTypeId;
  final int sourceVersion;

  const LibraryPick({
    required this.sourceProjectId,
    required this.sourceUnitTypeId,
    required this.sourceVersion,
  });
}

class PickedOpening extends LibraryPick {
  final String room;
  final int nominalWTmm;
  final int nominalHTmm;

  const PickedOpening({
    required this.room,
    required this.nominalWTmm,
    required this.nominalHTmm,
    required super.sourceProjectId,
    required super.sourceUnitTypeId,
    required super.sourceVersion,
  });
}

class PickedRoom extends LibraryPick {
  final String room;
  final Rational areaSqft;

  /// A running length of skirting, if the schedule recorded one. Offered as
  /// its own optional line -- skirting is priced `per_ft_width` (RM4/ft),
  /// not `per_sqft`, so this is a real length, not an area.
  final int? skirtingRunTmm;

  const PickedRoom({
    required this.room,
    required this.areaSqft,
    this.skirtingRunTmm,
    required super.sourceProjectId,
    required super.sourceUnitTypeId,
    required super.sourceVersion,
  });
}

/// Pushes the picker and returns what was picked, or null if the salesperson
/// backed out at any step.
Future<LibraryPick?> showUnitTypePicker(BuildContext context, WidgetRef ref) =>
    Navigator.of(context).push<LibraryPick>(
      MaterialPageRoute(builder: (_) => const UnitTypePickerScreen()),
    );

enum _PickerStep { project, unitType, opening }

class UnitTypePickerScreen extends ConsumerStatefulWidget {
  const UnitTypePickerScreen({super.key});

  @override
  ConsumerState<UnitTypePickerScreen> createState() =>
      _UnitTypePickerScreenState();
}

class _UnitTypePickerScreenState extends ConsumerState<UnitTypePickerScreen> {
  _PickerStep _step = _PickerStep.project;

  final _search = TextEditingController();

  /// Guards against a slow, stale request overwriting a faster, later one --
  /// the same problem the dashboard's own preview screen once had.
  int _requestId = 0;

  bool _loading = false;
  bool _failed = false;
  List<ProjectSummary> _projects = const [];
  List<UnitTypeSummary> _unitTypes = const [];
  List<OpeningRef> _openings = const [];
  List<RoomRef> _rooms = const [];

  ProjectSummary? _project;
  UnitTypeSummary? _unitType;
  ApprovedUnitType? _approved;

  @override
  void initState() {
    super.initState();
    _searchProjects();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Waits for the session, rather than racing a synchronous read of it.
  ///
  /// A bug this exact shape once caught elsewhere in this app: reading
  /// `credentialsProvider` with `.read(...).valueOrNull` right as a screen
  /// opens sees `AsyncLoading` far more often than it looks like it should,
  /// because the provider's own `build()` has not resolved on the very
  /// first frame yet. Returning early from that left `_loading` stuck
  /// `true` forever -- an indeterminate spinner nobody's tap could recover
  /// from. `.future` waits for the real answer instead of guessing at it.
  Future<String?> get _token async =>
      (await ref.read(credentialsProvider.future))?.token;

  Future<void> _searchProjects() async {
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final token = await _token;
    if (!mounted || id != _requestId) return;
    if (token == null) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }

    final result = await ref
        .read(apiClientProvider)
        .projects(token: token, query: _search.text.trim());
    if (!mounted || id != _requestId) return;

    setState(() {
      _loading = false;
      _failed = !result.ok;
      _projects = result.valueOrNull ?? const [];
    });
  }

  Future<void> _pickProject(ProjectSummary project) async {
    final id = ++_requestId;
    setState(() {
      _project = project;
      _step = _PickerStep.unitType;
      _loading = true;
      _failed = false;
    });
    final token = await _token;
    if (!mounted || id != _requestId) return;
    if (token == null) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }

    final result = await ref
        .read(apiClientProvider)
        .unitTypes(token: token, projectId: project.id);
    if (!mounted || id != _requestId) return;

    setState(() {
      _loading = false;
      _failed = !result.ok;
      _unitTypes = result.valueOrNull ?? const [];
    });
  }

  Future<void> _pickUnitType(UnitTypeSummary unitType) async {
    final id = ++_requestId;
    setState(() {
      _unitType = unitType;
      _step = _PickerStep.opening;
      _loading = true;
      _failed = false;
    });
    final token = await _token;
    if (!mounted || id != _requestId) return;
    if (token == null) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }

    final result = await ref
        .read(apiClientProvider)
        .unitTypeDetail(token: token, unitTypeId: unitType.id);
    if (!mounted || id != _requestId) return;

    final detail = result.valueOrNull;
    final approved = detail == null
        ? null
        : ApprovedUnitType.latestApproved(detail);
    setState(() {
      _loading = false;
      _failed = !result.ok;
      _approved = approved;
      _openings = approved?.openings ?? const [];
      _rooms = approved?.rooms ?? const [];
    });
  }

  void _back() {
    setState(() {
      switch (_step) {
        case _PickerStep.project:
          Navigator.of(context).pop();
        case _PickerStep.unitType:
          _step = _PickerStep.project;
          _unitType = null;
          _openings = const [];
          _rooms = const [];
        case _PickerStep.opening:
          _step = _PickerStep.unitType;
          _approved = null;
          _openings = const [];
          _rooms = const [];
      }
    });
  }

  void _pickOpening(OpeningRef opening) {
    final unitType = _unitType!;
    final approved = _approved!;
    Navigator.of(context).pop(
      PickedOpening(
        room: opening.room,
        nominalWTmm: opening.nominalWTmm,
        nominalHTmm: opening.nominalHTmm,
        sourceProjectId: unitType.projectId,
        sourceUnitTypeId: unitType.id,
        sourceVersion: approved.version,
      ),
    );
  }

  void _pickRoom(RoomRef room) {
    final unitType = _unitType!;
    final approved = _approved!;
    Navigator.of(context).pop(
      PickedRoom(
        room: room.name,
        areaSqft: areaSqftFromMm2(room.nominalAreaMm2),
        skirtingRunTmm: room.skirtingRunTmm,
        sourceProjectId: unitType.projectId,
        sourceUnitTypeId: unitType.id,
        sourceVersion: approved.version,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return PopScope(
      canPop: _step == _PickerStep.project,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _back,
            tooltip: l.back,
          ),
          title: Text(switch (_step) {
            _PickerStep.project => l.pickerFindProject,
            _PickerStep.unitType => l.pickerPickUnitType,
            // Only a unit type with both kinds needs the broader title -- an
            // openings-only unit type (still the common case) keeps reading
            // exactly as it always has, and a rooms-only one asks for a
            // room specifically rather than a window that is not there.
            _PickerStep.opening => switch ((
              _openings.isNotEmpty,
              _rooms.isNotEmpty,
            )) {
              (true, true) => l.pickerPickOpeningOrRoom,
              (false, true) => l.pickerPickRoom,
              _ => l.pickerPickOpening,
            },
          }),
        ),
        body: switch (_step) {
          _PickerStep.project => _projectStep(l),
          _PickerStep.unitType => _unitTypeStep(l),
          _PickerStep.opening => _openingStep(l),
        },
      ),
    );
  }

  Widget _projectStep(L l) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: TextField(
            controller: _search,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l.pickerSearchProjectHint,
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.md),
              ),
            ),
            onSubmitted: (_) => _searchProjects(),
            onChanged: (_) => _searchProjects(),
          ),
        ),
        Expanded(
          child: _body(
            empty: l.pickerNoProjects,
            children: [
              for (final project in _projects)
                _PickerRow(
                  title: project.name,
                  subtitle: [
                    if (project.area != null) project.area!,
                    if (project.developer != null) project.developer!,
                  ].join(' · '),
                  onTap: () => _pickProject(project),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _unitTypeStep(L l) {
    return _body(
      empty: l.pickerNoUnitTypes,
      children: [
        for (final unitType in _unitTypes)
          _PickerRow(
            title: unitType.name,
            onTap: () => _pickUnitType(unitType),
          ),
      ],
    );
  }

  Widget _openingStep(L l) {
    // A room only ever seeds a `per_sqft` flooring line -- most unit types
    // have none, and the plain single-list openings screen is unchanged for
    // them. A heading only earns its place once there is a second list to
    // tell apart from the first.
    return _body(
      empty: l.pickerNoOpenings,
      children: [
        if (_rooms.isNotEmpty && _openings.isNotEmpty)
          _SectionHeading(l.pickerOpeningsHeading),
        for (final opening in _openings)
          _PickerRow(
            title: '${opening.label} · ${opening.room}',
            subtitle: l.pickerOpeningSize(
              _feet(opening.nominalWTmm),
              _feet(opening.nominalHTmm),
            ),
            onTap: () => _pickOpening(opening),
          ),
        if (_rooms.isNotEmpty) ...[
          if (_openings.isNotEmpty) _SectionHeading(l.pickerRoomsHeading),
          for (final room in _rooms)
            _PickerRow(
              title: room.name,
              subtitle: l.pickerRoomAreaSqft(_area(room.nominalAreaMm2)),
              onTap: () => _pickRoom(room),
            ),
        ],
      ],
    );
  }

  /// One decimal place, display only. `_add()` in the wizard uses the exact
  /// tenths-of-a-millimetre value directly and never re-parses this string --
  /// CLAUDE.md's arithmetic invariant does not carve out an exception for a
  /// picker's own preview text.
  String _feet(int tmm) => (tmm / 3048).toStringAsFixed(1);

  /// Same rule as [_feet]: display only. `_pickRoom` converts the exact
  /// `nominal_area_mm2` directly and never re-parses this string.
  String _area(int areaMm2) =>
      areaSqftFromMm2(areaMm2).toDouble().toStringAsFixed(1);

  Widget _body({required String empty, required List<Widget> children}) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return _ErrorState(
        message: L.of(context).pickerCouldNotReach,
        actionLabel: L.of(context).pickerTryAgain,
        onRetry: switch (_step) {
          _PickerStep.project => _searchProjects,
          _PickerStep.unitType => () => _pickProject(_project!),
          _PickerStep.opening => () => _pickUnitType(_unitType!),
        },
      );
    }
    if (children.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Text(
            empty,
            style: AppText.caption,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: children,
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final String label;

  const _SectionHeading(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Text(label, style: AppText.caption),
    );
  }
}

class _PickerRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _PickerRow({required this.title, required this.onTap, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.lg),
          child: Container(
            constraints: const BoxConstraints(minHeight: Touch.primary),
            padding: const EdgeInsets.symmetric(
              horizontal: Space.lg,
              vertical: Space.lg,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: AppText.title),
                      if (subtitle != null) ...[
                        const SizedBox(height: Space.xs),
                        Text(subtitle!, style: AppText.caption),
                      ],
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  color: AppColors.mutedForeground,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback onRetry;

  const _ErrorState({
    required this.message,
    required this.actionLabel,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, style: AppText.body, textAlign: TextAlign.center),
            const SizedBox(height: Space.lg),
            FilledButton(onPressed: onRetry, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
