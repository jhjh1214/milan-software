/// Photo capture for one window.
///
/// SPEC.md §8.1: "Photo capture is one tap from inside the line. No gallery
/// round-trip, no crop." So this opens the camera directly and stores the
/// resulting path — there is no picker, no preview step, no confirm.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'quote_state.dart';

/// Overridable so widget tests can supply a stub instead of a camera.
final imagePickerProvider = Provider<ImagePicker>((ref) => ImagePicker());

/// Opens the camera and attaches the photo to [lineId].
///
/// Silently does nothing if the user backs out — cancelling is not an error,
/// and a snackbar for it would be noise in a noisy hall.
Future<void> captureLinePhoto(
  BuildContext context,
  WidgetRef ref,
  String lineId,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final notifier = ref.read(quoteProvider.notifier);
  try {
    final shot = await ref
        .read(imagePickerProvider)
        .pickImage(
          source: ImageSource.camera,
          // Full-resolution photos are 3-6MB each. A six-window house would be
          // 30MB to sync over a fair's connection, and the photo only has to
          // remind the measurer which window this was.
          maxWidth: 1600,
          imageQuality: 70,
        );
    if (shot == null) return;
    await notifier.setLinePhoto(lineId, shot.path);
  } catch (e) {
    // A refused camera permission must not take the quote down.
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$e')));
  }
}

/// The photo on a line: a thumbnail once taken, a camera button before.
class LinePhoto extends ConsumerWidget {
  final String lineId;
  final String? path;
  final double size;

  const LinePhoto({
    super.key,
    required this.lineId,
    required this.path,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = path == null ? null : File(path!);
    // The file can vanish — Android clears its cache directory under pressure.
    // A missing photo must degrade to the camera button, not a broken image.
    final exists = file != null && file.existsSync();

    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => captureLinePhoto(context, ref, lineId),
          borderRadius: BorderRadius.circular(8),
          child: exists
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    file,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _placeholder(context),
                  ),
                )
              : _placeholder(context),
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFCBD5E1)),
      color: const Color(0xFFF1F3F5),
    ),
    child: const Icon(
      Icons.photo_camera_outlined,
      size: 22,
      color: Color(0xFF56637A),
    ),
  );
}
