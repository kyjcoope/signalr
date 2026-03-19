import 'package:redux/redux.dart';
import 'package:redux_thunk/redux_thunk.dart';

import '../auth/auth.dart';
import '../config.dart';
import '../models/models.dart';
import '../signalr/signalr_session_hub.dart';
import '../store/favorites_store.dart';
import '../utils/logger.dart';
import '../webrtc/session_state.dart';
import '../webrtc/webrtc_camera_session.dart';
import 'actions.dart';
import 'app_state.dart';
import 'camera_connection_controller.dart';
import 'camera_connection_queue.dart';
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

  final existing = getWebRtcSession(store.state, slug);
  final newVideoTracks = _buildVideoTrackInfos(session);
  final newAudioTracks = _buildAudioTrackInfos(session);

  // Reuse existing references when content hasn't changed, so downstream
  // shallow/identical checks on individual fields don't see a spurious change.
  final videoTracks = existing != null && newVideoTracks == existing.videoTracks
      ? existing.videoTracks
      : newVideoTracks;
  final audioTracks = existing != null && newAudioTracks == existing.audioTracks
      ? existing.audioTracks
      : newAudioTracks;

  final snapshot = WebRtcSessionState(
    connectionState: _mapConnectionState(session.state),
    error: session.lastError,
    textureId: hub.getTextureId(slug),
    videoTracks: videoTracks,
    audioTracks: audioTracks,
    activeVideoTrack: hub.getActiveVideoTrack(slug),
    activeAudioTrack: hub.getActiveAudioTrack(slug),
    videoStats: hub.getStatsNotifier(slug)?.value,
  );

  if (snapshot == existing) return;
  store.dispatch(SetSessionSnapshot(slug, snapshot));
}

/// Build a [TrackInfo] list for video tracks from session data.
List<TrackInfo> _buildVideoTrackInfos(WebRtcCameraSession session) {
  final tracks = session.videoTracks;
  final codecs = session.videoTrackCodecs;
  return [
    for (var i = 0; i < tracks.length; i++)
      TrackInfo(
        id: tracks[i].id ?? '',
        codec: i < codecs.length ? codecs[i] : '',
        enabled: tracks[i].enabled,
      ),
  ];
}

/// Build a [TrackInfo] list for audio tracks from session data.
List<TrackInfo> _buildAudioTrackInfos(WebRtcCameraSession session) {
  final tracks = session.audioTracks;
  return [
    for (var i = 0; i < tracks.length; i++)
      TrackInfo(id: tracks[i].id ?? '', enabled: tracks[i].enabled),
  ];
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

      // Initialize SignalR hub (cameras loaded from persistence)
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
    CameraConnectionController.instance.cancelAll();
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
      // Only replace the cache if we actually got cameras back
      if (authService.devices.isNotEmpty) {
        store.dispatch(SetCameras(authService.devices));
        Logger().info(
          '[Thunk] fetchCameras: ${authService.devices.length} cameras loaded',
        );
      } else {
        Logger().warn('[Thunk] fetchCameras: empty response, keeping cache');
      }
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

/// Connect to a single camera.
///
/// Routes through [CameraConnectionQueue] which throttles concurrent
/// signaling and respects the decoder cap. The queue delegates to
/// [CameraConnectionController] for per-camera locking and debounce.
ThunkAction<AppState> connectCamera(String slug) {
  return (Store<AppState> store) async {
    Logger().info('[Thunk] connectCamera: $slug');
    await CameraConnectionQueue.instance.enqueue(slug, store);
  };
}

/// Disconnect a single camera.
///
/// Delegates to [CameraConnectionController] which debounces the
/// disconnect by 500ms. If the user presses connect within that
/// window, the disconnect is cancelled.
ThunkAction<AppState> disconnectCamera(String slug) {
  return (Store<AppState> store) async {
    Logger().info('[Thunk] disconnectCamera: $slug');
    CameraConnectionController.instance.disconnect(slug, store);
  };
}

/// Connect all currently visible cameras via the connection queue.
///
/// The [CameraConnectionQueue] throttles concurrent signaling (max 4 at a
/// time), retries failures with a longer timeout, and respects the decoder
/// cap (max 16 active connections).
ThunkAction<AppState> connectAllVisible() {
  return (Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;
    final visible = selectVisibleCameras(store.state);
    final toConnect = visible.where((s) => !hub.isConnected(s)).toList();

    Logger().info(
      '[Thunk] connectAllVisible: ${toConnect.length} cameras',
    );

    await CameraConnectionQueue.instance.enqueueAll(toConnect, store);
  };
}

/// Stop all connected cameras immediately (no debounce).
///
/// First cancels the connection queue (stops pending/retrying cameras),
/// then disconnects all active sessions.
ThunkAction<AppState> stopAll() {
  return (Store<AppState> store) async {
    CameraConnectionQueue.instance.cancelAll();
    final ctrl = CameraConnectionController.instance;
    final hub = SignalRSessionHub.instance;
    final ids = hub.connectedCameraIds.toList();
    Logger().info('[Thunk] stopAll: ${ids.length} cameras');
    // Disconnect all cameras in parallel for instant teardown.
    await Future.wait(
      ids.map((slug) => ctrl.disconnectImmediate(slug, store)),
    );
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Track Thunks
// ═══════════════════════════════════════════════════════════════════════════

/// Switch video track for a camera.
ThunkAction<AppState> switchVideoTrack(String slug, int trackIndex) {
  return (Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;
    if (await hub.switchVideoTrack(slug, trackIndex)) {
      syncSessionToRedux(store, slug);
    }
  };
}

/// Switch audio track for a camera (preserves mute state).
ThunkAction<AppState> switchAudioTrack(String slug, int trackIndex) {
  return (Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;
    if (hub.switchAudioTrack(slug, trackIndex)) {
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
