// =============================================================================
// SHE V3 — Uploaded images (scene / group covers + custom icons)
// =============================================================================
// Until now the app could only use BUNDLED images: `node_groups.image` held a
// key like 'home-dusk' and scenes had no image at all. This lets the user pick a
// photo from the phone and store it on the server.
//
//   POST /api/v3/media  (multipart `file`, authenticated) -> {data:{id,url,...}}
//   GET  /api/v3/media/{id}                               -> the bytes
//
// The value stored on a scene/group is the SERVER-RELATIVE path
// (`/api/v3/media/<uuid>`), not an absolute URL: the dev server's IP changes
// often, and a stored `http://192.168.1.21:8080/...` would go stale. Render
// through [MediaUrls.resolve] to prefix the current base URL.
// =============================================================================

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../network/dio_client.dart';

/// Resolves a stored scene/group image value to something `Image` can load.
///
/// Three shapes are possible:
///   * '' or null                -> nothing set
///   * '/api/v3/media/<uuid>'    -> uploaded, prefix the current base URL
///   * 'home-dusk' / 'assets/...'-> a bundled asset key (pre-V41 rows)
abstract final class MediaUrls {
  /// Kept in sync from `apiBaseUrlProvider` in `app.dart` so plain widgets (no
  /// Riverpod scope) can resolve without threading `ref` through every card.
  static String base = '';

  static bool isUploaded(String? value) =>
      value != null && value.startsWith('/api/v3/media/');

  static String resolve(String value) {
    if (value.isEmpty) return value;
    if (value.startsWith('http://') || value.startsWith('https://')) return value;
    if (value.startsWith('/')) return '$base$value';
    return value;
  }
}

/// Picks a photo from the gallery and uploads it.
class MediaService {
  MediaService(this._ref);

  final Ref _ref;

  /// Returns the stored value (`/api/v3/media/<uuid>`), or null when the user
  /// cancels the picker.
  ///
  /// The image is downscaled to [maxWidth] before upload: a modern phone photo
  /// is 3–5 MB, and a cover tile never needs more than ~1600 px. The server
  /// caps at 5 MB and sniffs the real type from the bytes.
  Future<String?> pickAndUpload({
    int maxWidth = 1600,
    int quality = 85,
  }) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: maxWidth.toDouble(),
      imageQuality: quality,
    );
    if (picked == null) return null;

    final bytes = await picked.readAsBytes();
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: picked.name),
    });

    final response = await _ref.read(dioProvider).post(
          '/api/v3/media',
          data: form,
        );
    final data = response.data['data'] as Map<String, dynamic>;
    return data['url']?.toString();
  }
}

final mediaServiceProvider = Provider<MediaService>(MediaService.new);
