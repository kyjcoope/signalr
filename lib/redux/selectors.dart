import '../models/models.dart';
import 'app_state.dart';
import 'camera_session_info.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Camera Selectors
// ═══════════════════════════════════════════════════════════════════════════

/// All cameras as a sorted list of slugs.
List<String> selectAllSlugs(AppState state) {
  final slugs = state.cameras.cameras.keys.toList()..sort();
  return slugs;
}

/// Get a Device by slug.
Device? selectDevice(AppState state, String slug) =>
    state.cameras.cameras[slug];

/// Whether cameras have been loaded from the API.
bool selectCamerasLoaded(AppState state) => state.cameras.isLoaded;

// ═══════════════════════════════════════════════════════════════════════════
// Session Selectors
// ═══════════════════════════════════════════════════════════════════════════

/// Get session info for a slug (returns default if not connected).
CameraSessionInfo selectSessionInfo(AppState state, String slug) =>
    state.sessions.sessions[slug] ?? const CameraSessionInfo();

/// Whether a camera is connected.
bool selectIsConnected(AppState state, String slug) =>
    selectSessionInfo(state, slug).status == ConnectionStatus.connected;

/// Whether a camera is pending.
bool selectIsPending(AppState state, String slug) =>
    selectSessionInfo(state, slug).status == ConnectionStatus.pending;

/// Formatted track info string (e.g. "V:2 A:0"), or null if not connected.
String? selectTrackInfo(AppState state, String slug) {
  final info = selectSessionInfo(state, slug);
  if (info.status != ConnectionStatus.connected) return null;
  return 'V:${info.videoTrackCount} A:${info.audioTrackCount}';
}

// ═══════════════════════════════════════════════════════════════════════════
// Filter + Favorites Selectors
// ═══════════════════════════════════════════════════════════════════════════

/// Whether a slug is a favorite.
bool selectIsFavorite(AppState state, String slug) =>
    state.favorites.ids.contains(slug);

/// Visible camera slugs after applying all filters.
List<String> selectVisibleCameras(AppState state) {
  var base = selectAllSlugs(state);

  final filters = state.filters;
  final favorites = state.favorites.ids;

  // Favorites filter
  if (filters.favoritesOnly) {
    base = base.where((id) => favorites.contains(id)).toList();
  }

  // Working / Pending filter
  bool isWorking(String id) => selectIsConnected(state, id);
  bool isPending(String id) => selectIsPending(state, id);

  if (filters.workingOnly && filters.pendingOnly) {
    base = base.where((id) => isWorking(id) || isPending(id)).toList();
  } else if (filters.workingOnly) {
    base = base.where(isWorking).toList();
  } else if (filters.pendingOnly) {
    base = base.where(isPending).toList();
  }

  // Search filter
  if (filters.searchQuery.isNotEmpty) {
    final q = filters.searchQuery.toLowerCase();
    base = base.where((id) {
      final name = state.cameras.cameras[id]?.name.toLowerCase() ?? '';
      return id.toLowerCase().contains(q) || name.contains(q);
    }).toList();
  }

  return base;
}
