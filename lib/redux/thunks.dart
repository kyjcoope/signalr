import 'package:redux/redux.dart';
import 'package:redux_thunk/redux_thunk.dart';

import '../auth/auth.dart';
import '../config.dart';
import '../models/models.dart';
import '../signalr/signalr_session_hub.dart';
import '../store/favorites_store.dart';
import '../utils/logger.dart';
import '../webrtc/session_state.dart';
import 'actions.dart';
import 'app_state.dart';
import 'selectors.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Session Sync
// ═══════════════════════════════════════════════════════════════════════════

/// Build a [WebRtcSessionState] snapshot from the hub's current state.
///
/// This is the single point that translates live hub/session state into
/// a plain Redux value object. All callbacks call this instead of dispatching
/// individual fine-grained actions.
void syncSessionToRedux(Store<AppState> store, String slug) {
  final hub = SignalRSessionHub.instance;
  final session = hub.getSession(slug);
  if (session == null) return;

  // Map internal session state → Redux connection state
  final connectionState = _mapConnectionState(session.state);

  final snapshot = WebRtcSessionState(
    connectionState: connectionState,
    textureId: hub.getTextureId(slug),
    videoTrackCount: hub.getVideoTrackCount(slug),
    audioTrackCount: hub.getAudioTrackCount(slug),
    activeVideoTrack: hub.getActiveVideoTrack(slug),
    audioEnabled: hub.isAudioEnabled(slug) ?? true,
    negotiatedCodec: session.negotiatedVideoCodec,
  );

  store.dispatch(SetSessionSnapshot(slug, snapshot));
}

/// Map internal [SessionConnectionState] to Redux [WebRtcConnectionState].
WebRtcConnectionState _mapConnectionState(SessionConnectionState state) {
  switch (state) {
    case SessionConnectionState.idle:
    case SessionConnectionState.closed:
      return WebRtcConnectionState.sessionDisconnected;
    case SessionConnectionState.waitingForSession:
    case SessionConnectionState.initializingPeer:
    case SessionConnectionState.settingRemoteDescription:
    case SessionConnectionState.creatingAnswer:
    case SessionConnectionState.sendingAnswer:
    case SessionConnectionState.exchangingIce:
      return WebRtcConnectionState.sessionPending;
    case SessionConnectionState.connected:
      return WebRtcConnectionState.sessionConnected;
    case SessionConnectionState.disconnected:
    case SessionConnectionState.restarting:
    case SessionConnectionState.reconnecting:
      return WebRtcConnectionState.sessionReconnecting;
    case SessionConnectionState.failed:
      return WebRtcConnectionState.sessionFailed;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Auth / Hub Initialization
// ═══════════════════════════════════════════════════════════════════════════

/// Initialize SignalR hub with explicit URL. Does NOT fetch cameras.
///
/// Cameras are loaded from persistence. Use [fetchCameras] to refresh.
ThunkAction<AppState> initializeSignalRThunk({
  required AuthService authService,
  required String signalRUrl,
}) {
  return (Store<AppState> store) async {
    Logger().info('[Thunk] initializeSignalRThunk: starting');
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
      await hub.initialize(signalRUrl, authService);
      Logger().info('[Thunk] initializeSignalRThunk: hub initialized');

      // Sync any existing sessions (e.g., survived page navigation)
      for (final cameraId in hub.connectedCameraIds) {
        syncSessionToRedux(store, cameraId);
      }

      store.dispatch(SetServerStatus(ServerStatus.connected));
      Logger().info(
        '[Thunk] initializeSignalRThunk: complete '
        '(${store.state.cameras.cameras.length} cameras from persist)',
      );
    } catch (e) {
      Logger().error('[Thunk] initializeSignalRThunk: ERROR $e');
      store.dispatch(SetServerStatus(ServerStatus.error));
    }
  };
}

/// Convenience wrapper — uses the global [url] from config.dart.
ThunkAction<AppState> loginAndInitHub({required AuthService authService}) {
  return initializeSignalRThunk(
    authService: authService,
    signalRUrl: 'https://$url/SignalingHub',
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// Hub Disposal
// ═══════════════════════════════════════════════════════════════════════════

/// Shutdown the SignalR hub, clear all sessions, and reset server status.
ThunkAction<AppState> disposeSignalRThunk() {
  return (Store<AppState> store) async {
    Logger().info('[Thunk] disposeSignalRThunk: shutting down');
    final hub = SignalRSessionHub.instance;
    await hub.shutdown();
    store.dispatch(ClearAllSessions());
    store.dispatch(SetServerStatus(ServerStatus.idle));
    Logger().info('[Thunk] disposeSignalRThunk: complete');
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
    Logger().info('[Thunk] fetchCameras: fetching...');
    store.dispatch(SetFetchingCameras(true));

    try {
      await authService.fetchDevices();
      store.dispatch(SetCameras(authService.devices));
      Logger().info(
        '[Thunk] fetchCameras: ${authService.devices.length} cameras loaded',
      );
    } catch (e) {
      Logger().error('[Thunk] fetchCameras: ERROR $e');
    } finally {
      store.dispatch(SetFetchingCameras(false));
    }
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Connection Thunks
// ═══════════════════════════════════════════════════════════════════════════

/// Connect to a single camera via the hub, wiring callbacks to sync Redux.
ThunkAction<AppState> connectCamera(String slug) {
  return (Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;

    Logger().info('[Thunk] connectCamera: $slug');
    final session = await hub.connectToCamera(slug);
    if (session == null) {
      Logger().error('[Thunk] connectCamera: FAILED for $slug');
      return;
    }

    // Any state change → sync full snapshot to Redux
    session.onStateChanged = (_) => syncSessionToRedux(store, slug);

    // Connection established → sync (captures tracks, texture, etc.)
    session.onConnectionComplete = () => syncSessionToRedux(store, slug);

    // Codec resolved → sync
    session.onVideoCodecResolved = (_) => syncSessionToRedux(store, slug);

    // ICE candidates → sync (transitions to pending)
    session.onLocalIceCandidate = () => syncSessionToRedux(store, slug);
    session.onRemoteIceCandidate = () => syncSessionToRedux(store, slug);
  };
}

/// Disconnect a single camera.
ThunkAction<AppState> disconnectCamera(String slug) {
  return (Store<AppState> store) async {
    Logger().info('[Thunk] disconnectCamera: $slug');
    final hub = SignalRSessionHub.instance;
    await hub.disconnectCamera(slug);
    store.dispatch(RemoveSession(slug));
  };
}

/// Connect all currently visible cameras in batches.
///
/// Connects up to [batchSize] cameras in parallel, then waits for the
/// batch to finish before starting the next. This avoids overwhelming
/// the signaling server while still being much faster than sequential.
ThunkAction<AppState> connectAllVisible({int batchSize = 10}) {
  return (Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;
    final visible = selectVisibleCameras(store.state);
    final toConnect = visible.where((s) => !hub.isConnected(s)).toList();

    Logger().info(
      '[Thunk] connectAllVisible: ${toConnect.length} cameras in batches of $batchSize',
    );

    for (var i = 0; i < toConnect.length; i += batchSize) {
      final batch = toConnect.sublist(
        i,
        (i + batchSize).clamp(0, toConnect.length),
      );
      Logger().info(
        '[Thunk] Batch ${(i ~/ batchSize) + 1}: connecting ${batch.length} cameras',
      );
      await Future.wait(
        batch.map((slug) => store.dispatch(connectCamera(slug))),
      );
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
      syncSessionToRedux(store, slug);
    }
  };
}

/// Toggle audio track for a camera.
///
/// Calls the hub to enable/disable the audio track, then syncs Redux.
/// Pass [enable] to force a specific state, or omit to toggle.
ThunkAction<AppState> toggleAudioTrack(String cameraId, {bool? enable}) {
  return (Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;
    final newState = hub.toggleAudio(cameraId, enable: enable);
    if (newState != null) {
      syncSessionToRedux(store, cameraId);
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
    store.dispatch(ClearAllSessions());
    await FavoritesStore().saveFavorites({});
  };
}
