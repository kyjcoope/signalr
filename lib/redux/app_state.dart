import 'package:equatable/equatable.dart';

import '../models/models.dart';
import '../webrtc/redux/webrtc_state.dart';

// Re-export WebRTC state types so existing imports continue to work.
export '../webrtc/redux/webrtc_state.dart';

/// Server connection status.
enum ServerStatus { idle, connecting, connected, error }

/// Root application state.
class AppState extends Equatable {
  final AuthState auth;
  final CameraState cameras;
  final WebRtcState webRtc;
  final FilterState filters;
  final FavoritesState favorites;

  const AppState({
    this.auth = const AuthState(),
    this.cameras = const CameraState(),
    this.webRtc = const WebRtcState(),
    this.filters = const FilterState(),
    this.favorites = const FavoritesState(),
  });

  AppState copyWith({
    AuthState? auth,
    CameraState? cameras,
    WebRtcState? webRtc,
    FilterState? filters,
    FavoritesState? favorites,
  }) {
    return AppState(
      auth: auth ?? this.auth,
      cameras: cameras ?? this.cameras,
      webRtc: webRtc ?? this.webRtc,
      filters: filters ?? this.filters,
      favorites: favorites ?? this.favorites,
    );
  }

  /// Deserialize from JSON. WebRTC and auth are NOT persisted.
  static AppState fromJson(dynamic json) {
    if (json == null || json is! Map<String, dynamic>) return const AppState();
    return AppState(
      cameras: CameraState.fromJson(json['cameras']),
      filters: FilterState.fromJson(json['filters']),
      favorites: FavoritesState.fromJson(json['favorites']),
    );
  }

  /// Serialize to JSON. WebRTC and auth are NOT persisted.
  dynamic toJson() => {
    'cameras': cameras.toJson(),
    'filters': filters.toJson(),
    'favorites': favorites.toJson(),
  };

  @override
  List<Object?> get props => [auth, cameras, webRtc, filters, favorites];
}

/// Auth/connection runtime state. NOT persisted.
class AuthState extends Equatable {
  final ServerStatus serverStatus;
  final bool isFetchingCameras;

  const AuthState({
    this.serverStatus = ServerStatus.idle,
    this.isFetchingCameras = false,
  });

  AuthState copyWith({ServerStatus? serverStatus, bool? isFetchingCameras}) {
    return AuthState(
      serverStatus: serverStatus ?? this.serverStatus,
      isFetchingCameras: isFetchingCameras ?? this.isFetchingCameras,
    );
  }

  @override
  List<Object?> get props => [serverStatus, isFetchingCameras];
}

/// Camera devices fetched from the API, keyed by slug (GUID).
class CameraState extends Equatable {
  final Map<String, Device> cameras;
  final bool isLoaded;

  const CameraState({this.cameras = const {}, this.isLoaded = false});

  CameraState copyWith({Map<String, Device>? cameras, bool? isLoaded}) {
    return CameraState(
      cameras: cameras ?? this.cameras,
      isLoaded: isLoaded ?? this.isLoaded,
    );
  }

  static CameraState fromJson(dynamic json) {
    if (json == null || json is! Map<String, dynamic>) {
      return const CameraState();
    }
    final map = <String, Device>{};
    final cams = json['cameras'];
    if (cams is Map<String, dynamic>) {
      for (final entry in cams.entries) {
        map[entry.key] = Device.fromJson(entry.value as Map<String, dynamic>);
      }
    }
    return CameraState(
      cameras: map,
      isLoaded: json['isLoaded'] as bool? ?? false,
    );
  }

  dynamic toJson() => {
    'cameras': cameras.map((k, v) => MapEntry(k, v.toJson())),
    'isLoaded': isLoaded,
  };

  @override
  List<Object?> get props => [cameras, isLoaded];
}

/// UI filter toggles.
class FilterState extends Equatable {
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

  static FilterState fromJson(dynamic json) {
    if (json == null || json is! Map<String, dynamic>) {
      return const FilterState();
    }
    return FilterState(
      // searchQuery not persisted — always starts empty
      favoritesOnly: json['favoritesOnly'] as bool? ?? false,
      workingOnly: json['workingOnly'] as bool? ?? false,
      pendingOnly: json['pendingOnly'] as bool? ?? false,
    );
  }

  dynamic toJson() => {
    'favoritesOnly': favoritesOnly,
    'workingOnly': workingOnly,
    'pendingOnly': pendingOnly,
  };

  @override
  List<Object?> get props => [
    searchQuery,
    favoritesOnly,
    workingOnly,
    pendingOnly,
  ];
}

/// Favorite camera IDs.
class FavoritesState extends Equatable {
  final Set<String> ids;

  const FavoritesState({this.ids = const {}});

  FavoritesState copyWith({Set<String>? ids}) {
    return FavoritesState(ids: ids ?? this.ids);
  }

  static FavoritesState fromJson(dynamic json) {
    if (json == null || json is! Map<String, dynamic>) {
      return const FavoritesState();
    }
    final list = json['ids'];
    if (list is List) {
      return FavoritesState(ids: list.cast<String>().toSet());
    }
    return const FavoritesState();
  }

  dynamic toJson() => {'ids': ids.toList()};

  @override
  List<Object?> get props => [ids];
}
