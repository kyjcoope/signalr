import '../models/models.dart';
import 'camera_session_info.dart';

/// Root application state.
class AppState {
  final CameraState cameras;
  final SessionState sessions;
  final FilterState filters;
  final FavoritesState favorites;

  const AppState({
    this.cameras = const CameraState(),
    this.sessions = const SessionState(),
    this.filters = const FilterState(),
    this.favorites = const FavoritesState(),
  });

  AppState copyWith({
    CameraState? cameras,
    SessionState? sessions,
    FilterState? filters,
    FavoritesState? favorites,
  }) {
    return AppState(
      cameras: cameras ?? this.cameras,
      sessions: sessions ?? this.sessions,
      filters: filters ?? this.filters,
      favorites: favorites ?? this.favorites,
    );
  }
}

/// Camera devices fetched from the API, keyed by slug (GUID).
class CameraState {
  final Map<String, Device> cameras;
  final bool isLoaded;

  const CameraState({this.cameras = const {}, this.isLoaded = false});

  CameraState copyWith({Map<String, Device>? cameras, bool? isLoaded}) {
    return CameraState(
      cameras: cameras ?? this.cameras,
      isLoaded: isLoaded ?? this.isLoaded,
    );
  }
}

/// WebRTC session info keyed by slug (GUID).
class SessionState {
  final Map<String, CameraSessionInfo> sessions;

  const SessionState({this.sessions = const {}});

  SessionState copyWith({Map<String, CameraSessionInfo>? sessions}) {
    return SessionState(sessions: sessions ?? this.sessions);
  }
}

/// UI filter toggles.
class FilterState {
  final String searchQuery;
  final bool favoritesOnly;
  final bool workingOnly;
  final bool pendingOnly;

  const FilterState({
    this.searchQuery = '',
    this.favoritesOnly = false,
    this.workingOnly = false,
    this.pendingOnly = false,
  });

  FilterState copyWith({
    String? searchQuery,
    bool? favoritesOnly,
    bool? workingOnly,
    bool? pendingOnly,
  }) {
    return FilterState(
      searchQuery: searchQuery ?? this.searchQuery,
      favoritesOnly: favoritesOnly ?? this.favoritesOnly,
      workingOnly: workingOnly ?? this.workingOnly,
      pendingOnly: pendingOnly ?? this.pendingOnly,
    );
  }
}

/// Favorite camera IDs.
class FavoritesState {
  final Set<String> ids;

  const FavoritesState({this.ids = const {}});

  FavoritesState copyWith({Set<String>? ids}) {
    return FavoritesState(ids: ids ?? this.ids);
  }
}
