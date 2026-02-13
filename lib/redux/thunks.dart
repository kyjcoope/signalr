import 'dart:developer' as dev;
import 'package:redux/redux.dart';
import 'package:redux_thunk/redux_thunk.dart';

import '../auth/auth.dart';
import '../config.dart';
import '../models/models.dart';
import '../signalr/signalr_session_hub.dart';
import '../store/favorites_store.dart';
import 'actions.dart';
import 'app_state.dart';
import 'camera_session_info.dart';
import 'selectors.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Auth / Hub Initialization
// ═══════════════════════════════════════════════════════════════════════════

/// Login and initialize the SignalR hub. Does NOT fetch cameras.
///
/// Cameras are loaded from persistence. Use [fetchCameras] to refresh.
ThunkAction<AppState> loginAndInitHub({required AuthService authService}) {
  return (Store<AppState> store) async {
    dev.log('[Thunk] loginAndInitHub: starting');
    store.dispatch(SetServerStatus(ServerStatus.connecting));

    try {
      await authService.login(
        UserLogin(
          username: username,
          password: password,
          clientName: 'driver',
          clientID: 'fb2be96f-05a3-4fea-a151-6365feaaf30c',
          clientVersion: '3.0',
          grantType: 'password',
          scopes: '[IdentityServerApi, rabbitmq-jci, api]',
          clientId_: 'jci-authui-client',
        ),
      );

      // Initialize SignalR hub
      final hub = SignalRSessionHub.instance;
      await hub.initialize('https://$url/SignalingHub', authService);
      dev.log('[Thunk] loginAndInitHub: hub initialized');

      // Sync any existing sessions (e.g., survived page navigation)
      for (final entry in hub.activeSessions.entries) {
        final cameraId = entry.key;
        final session = entry.value;
        if (session.remoteStream != null) {
          store.dispatch(
            SetSessionStatus(cameraId, ConnectionStatus.connected),
          );
        }
      }

      store.dispatch(SetServerStatus(ServerStatus.connected));
      dev.log(
        '[Thunk] loginAndInitHub: complete (${store.state.cameras.cameras.length} cameras from persist)',
      );
    } catch (e) {
      dev.log('[Thunk] loginAndInitHub: ERROR $e');
      store.dispatch(SetServerStatus(ServerStatus.error));
    }
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Camera Fetch
// ═══════════════════════════════════════════════════════════════════════════

/// Fetch cameras from the API and update the store.
///
/// This acts as a refresh — replaces persisted cameras with fresh data.
ThunkAction<AppState> fetchCameras({required AuthService authService}) {
  return (Store<AppState> store) async {
    dev.log('[Thunk] fetchCameras: fetching...');
    store.dispatch(SetFetchingCameras(true));

    try {
      await authService.fetchDevices();
      store.dispatch(SetCameras(authService.devices));
      dev.log(
        '[Thunk] fetchCameras: ${authService.devices.length} cameras loaded',
      );
    } catch (e) {
      dev.log('[Thunk] fetchCameras: ERROR $e');
    } finally {
      store.dispatch(SetFetchingCameras(false));
    }
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Connection Thunks
// ═══════════════════════════════════════════════════════════════════════════

/// Connect to a single camera via the hub, wiring callbacks to dispatch.
ThunkAction<AppState> connectCamera(String slug) {
  return (Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;

    dev.log('[Thunk] connectCamera: $slug');
    final session = await hub.connectToCamera(slug);
    if (session == null) {
      dev.log('[Thunk] connectCamera: FAILED for $slug');
      return;
    }

    // ICE candidates → pending
    session.onLocalIceCandidate = () {
      final info = selectSessionInfo(store.state, slug);
      if (info.status == ConnectionStatus.idle) {
        store.dispatch(SetSessionStatus(slug, ConnectionStatus.pending));
      }
    };

    session.onRemoteIceCandidate = () {
      final info = selectSessionInfo(store.state, slug);
      if (info.status == ConnectionStatus.idle) {
        store.dispatch(SetSessionStatus(slug, ConnectionStatus.pending));
      }
    };

    // Connection established → connected + track info
    session.onConnectionComplete = () {
      store.dispatch(SetSessionStatus(slug, ConnectionStatus.connected));

      // Update track counts
      store.dispatch(
        SetSessionTrackInfo(
          slug,
          videoTrackCount: hub.getVideoTrackCount(slug),
          audioTrackCount: hub.getAudioTrackCount(slug),
        ),
      );

      // Update texture ID
      final textureId = hub.getTextureId(slug);
      if (textureId != null) {
        store.dispatch(SetSessionTextureId(slug, textureId));
      }
    };

    // Codec resolved
    session.onVideoCodecResolved = (codec) {
      store.dispatch(SetSessionCodec(slug, codec));
    };
  };
}

/// Disconnect a single camera.
ThunkAction<AppState> disconnectCamera(String slug) {
  return (Store<AppState> store) async {
    dev.log('[Thunk] disconnectCamera: $slug');
    final hub = SignalRSessionHub.instance;
    await hub.disconnectCamera(slug);
    store.dispatch(RemoveSession(slug));
  };
}

/// Connect all currently visible cameras.
ThunkAction<AppState> connectAllVisible() {
  return (Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;
    final visible = selectVisibleCameras(store.state);
    for (final slug in visible) {
      if (!hub.isConnected(slug)) {
        await store.dispatch(connectCamera(slug));
      }
    }
  };
}

/// Stop all connected cameras.
ThunkAction<AppState> stopAll() {
  return (Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;
    final ids = hub.connectedCameraIds.toList();
    for (final slug in ids) {
      await store.dispatch(disconnectCamera(slug));
    }
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Track Thunks
// ═══════════════════════════════════════════════════════════════════════════

/// Switch video track for a camera.
ThunkAction<AppState> switchVideoTrack(String slug, int trackIndex) {
  return (Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;
    if (hub.switchVideoTrack(slug, trackIndex)) {
      store.dispatch(SetActiveVideoTrack(slug, trackIndex));
    }
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Favorites Thunks
// ═══════════════════════════════════════════════════════════════════════════

/// Toggle favorite and persist to storage.
ThunkAction<AppState> toggleFavoriteAndPersist(String slug) {
  return (Store<AppState> store) async {
    store.dispatch(ToggleFavorite(slug));
    final favStore = FavoritesStore();
    await favStore.saveFavorites(store.state.favorites.ids);
  };
}

/// Persist a filter toggle to storage.
ThunkAction<AppState> setFavoritesOnlyAndPersist(bool value) {
  return (Store<AppState> store) async {
    store.dispatch(SetFavoritesOnly(value));
    await FavoritesStore().saveFavoritesOnly(value);
  };
}

ThunkAction<AppState> setWorkingOnlyAndPersist(bool value) {
  return (Store<AppState> store) async {
    store.dispatch(SetWorkingOnly(value));
    await FavoritesStore().saveWorkingOnly(value);
  };
}

ThunkAction<AppState> setPendingOnlyAndPersist(bool value) {
  return (Store<AppState> store) async {
    store.dispatch(SetPendingOnly(value));
    await FavoritesStore().savePendingOnly(value);
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Reset Thunk
// ═══════════════════════════════════════════════════════════════════════════

/// Reset favorites and all sessions.
ThunkAction<AppState> resetFavoritesAndWorking() {
  return (Store<AppState> store) async {
    store.dispatch(SetFavorites({}));
    store.dispatch(ClearSessions());
    await FavoritesStore().saveFavorites({});
  };
}
