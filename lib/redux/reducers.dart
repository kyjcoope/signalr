import '../webrtc/redux/webrtc_reducer.dart';
import 'app_state.dart';
import 'actions.dart';

// Re-export so callers can import from one place if needed.
export '../webrtc/redux/webrtc_reducer.dart';

/// Root reducer — delegates to sub-reducers.
AppState appReducer(AppState state, dynamic action) {
  return AppState(
    auth: authReducer(state.auth, action),
    cameras: cameraReducer(state.cameras, action),
    webRtc: webRtcReducer(state.webRtc, action),
    filters: filterReducer(state.filters, action),
    favorites: favoritesReducer(state.favorites, action),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// Auth Reducer
// ═══════════════════════════════════════════════════════════════════════════

AuthState authReducer(AuthState state, dynamic action) {
  if (action is SetServerStatus) {
    return state.copyWith(serverStatus: action.status);
  }
  if (action is SetFetchingCameras) {
    return state.copyWith(isFetchingCameras: action.value);
  }
  return state;
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
