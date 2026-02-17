import '../models/models.dart';
import 'app_state.dart';

// Re-export WebRTC actions so existing imports continue to work.
export '../webrtc/redux/webrtc_actions.dart';

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
