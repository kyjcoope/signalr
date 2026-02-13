import '../models/models.dart';
import 'app_state.dart';
import 'camera_session_info.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Auth Actions
// ═══════════════════════════════════════════════════════════════════════════

/// Set server connection status (idle/connecting/connected/error).
class SetServerStatus {
  final ServerStatus status;
  SetServerStatus(this.status);
}

/// Set whether cameras are currently being fetched.
class SetFetchingCameras {
  final bool value;
  SetFetchingCameras(this.value);
}

// ═══════════════════════════════════════════════════════════════════════════
// Camera Actions
// ═══════════════════════════════════════════════════════════════════════════

/// Set the full camera map after API fetch.
class SetCameras {
  final Map<String, Device> cameras;
  SetCameras(this.cameras);
}

/// Clear all cameras (e.g., on logout).
class ClearCameras {}

// ═══════════════════════════════════════════════════════════════════════════
// Session Actions
// ═══════════════════════════════════════════════════════════════════════════

/// Set connection status for a single camera.
class SetSessionStatus {
  final String slug;
  final ConnectionStatus status;
  SetSessionStatus(this.slug, this.status);
}

/// Set resolved codec for a camera.
class SetSessionCodec {
  final String slug;
  final String codec;
  SetSessionCodec(this.slug, this.codec);
}

/// Set track counts for a camera.
class SetSessionTrackInfo {
  final String slug;
  final int videoTrackCount;
  final int audioTrackCount;
  SetSessionTrackInfo(
    this.slug, {
    required this.videoTrackCount,
    required this.audioTrackCount,
  });
}

/// Set the active video track index for a camera.
class SetActiveVideoTrack {
  final String slug;
  final int trackIndex;
  SetActiveVideoTrack(this.slug, this.trackIndex);
}

/// Set the texture ID for a camera renderer.
class SetSessionTextureId {
  final String slug;
  final int? textureId;
  SetSessionTextureId(this.slug, this.textureId);
}

/// Set audio enabled/disabled for a camera.
class SetAudioEnabled {
  final String slug;
  final bool enabled;
  SetAudioEnabled(this.slug, this.enabled);
}

/// Remove a single camera session (on disconnect).
class RemoveSession {
  final String slug;
  RemoveSession(this.slug);
}

/// Clear all sessions (on shutdown).
class ClearSessions {}

// ═══════════════════════════════════════════════════════════════════════════
// Filter Actions
// ═══════════════════════════════════════════════════════════════════════════

class SetSearchQuery {
  final String query;
  SetSearchQuery(this.query);
}

class SetFavoritesOnly {
  final bool value;
  SetFavoritesOnly(this.value);
}

class SetWorkingOnly {
  final bool value;
  SetWorkingOnly(this.value);
}

class SetPendingOnly {
  final bool value;
  SetPendingOnly(this.value);
}

// ═══════════════════════════════════════════════════════════════════════════
// Favorites Actions
// ═══════════════════════════════════════════════════════════════════════════

/// Replace the full favorites set (e.g., on load from storage).
class SetFavorites {
  final Set<String> ids;
  SetFavorites(this.ids);
}

/// Toggle a single favorite.
class ToggleFavorite {
  final String slug;
  ToggleFavorite(this.slug);
}
