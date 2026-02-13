import 'app_state.dart';
import 'actions.dart';
import 'camera_session_info.dart';

/// Root reducer — delegates to sub-reducers.
AppState appReducer(AppState state, dynamic action) {
  return AppState(
    cameras: cameraReducer(state.cameras, action),
    sessions: sessionReducer(state.sessions, action),
    filters: filterReducer(state.filters, action),
    favorites: favoritesReducer(state.favorites, action),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// Camera Reducer
// ═══════════════════════════════════════════════════════════════════════════

CameraState cameraReducer(CameraState state, dynamic action) {
  if (action is SetCameras) {
    return state.copyWith(cameras: action.cameras, isLoaded: true);
  }
  if (action is ClearCameras) {
    return const CameraState();
  }
  return state;
}

// ═══════════════════════════════════════════════════════════════════════════
// Session Reducer
// ═══════════════════════════════════════════════════════════════════════════

SessionState sessionReducer(SessionState state, dynamic action) {
  if (action is SetSessionStatus) {
    final current = state.sessions[action.slug] ?? const CameraSessionInfo();
    final updated = Map<String, CameraSessionInfo>.from(state.sessions);
    updated[action.slug] = current.copyWith(status: action.status);
    return state.copyWith(sessions: updated);
  }

  if (action is SetSessionCodec) {
    final current = state.sessions[action.slug] ?? const CameraSessionInfo();
    final updated = Map<String, CameraSessionInfo>.from(state.sessions);
    updated[action.slug] = current.copyWith(codec: action.codec);
    return state.copyWith(sessions: updated);
  }

  if (action is SetSessionTrackInfo) {
    final current = state.sessions[action.slug] ?? const CameraSessionInfo();
    final updated = Map<String, CameraSessionInfo>.from(state.sessions);
    updated[action.slug] = current.copyWith(
      videoTrackCount: action.videoTrackCount,
      audioTrackCount: action.audioTrackCount,
    );
    return state.copyWith(sessions: updated);
  }

  if (action is SetActiveVideoTrack) {
    final current = state.sessions[action.slug];
    if (current == null) return state;
    final updated = Map<String, CameraSessionInfo>.from(state.sessions);
    updated[action.slug] = current.copyWith(
      activeVideoTrack: action.trackIndex,
    );
    return state.copyWith(sessions: updated);
  }

  if (action is SetSessionTextureId) {
    final current = state.sessions[action.slug] ?? const CameraSessionInfo();
    final updated = Map<String, CameraSessionInfo>.from(state.sessions);
    updated[action.slug] = current.copyWith(textureId: action.textureId);
    return state.copyWith(sessions: updated);
  }

  if (action is RemoveSession) {
    final updated = Map<String, CameraSessionInfo>.from(state.sessions)
      ..remove(action.slug);
    return state.copyWith(sessions: updated);
  }

  if (action is ClearSessions) {
    return const SessionState();
  }

  return state;
}

// ═══════════════════════════════════════════════════════════════════════════
// Filter Reducer
// ═══════════════════════════════════════════════════════════════════════════

FilterState filterReducer(FilterState state, dynamic action) {
  if (action is SetSearchQuery) {
    return state.copyWith(searchQuery: action.query);
  }
  if (action is SetFavoritesOnly) {
    return state.copyWith(favoritesOnly: action.value);
  }
  if (action is SetWorkingOnly) {
    return state.copyWith(workingOnly: action.value);
  }
  if (action is SetPendingOnly) {
    return state.copyWith(pendingOnly: action.value);
  }
  return state;
}

// ═══════════════════════════════════════════════════════════════════════════
// Favorites Reducer
// ═══════════════════════════════════════════════════════════════════════════

FavoritesState favoritesReducer(FavoritesState state, dynamic action) {
  if (action is SetFavorites) {
    return state.copyWith(ids: action.ids);
  }
  if (action is ToggleFavorite) {
    final updated = Set<String>.from(state.ids);
    if (updated.contains(action.slug)) {
      updated.remove(action.slug);
    } else {
      updated.add(action.slug);
    }
    return state.copyWith(ids: updated);
  }
  return state;
}
