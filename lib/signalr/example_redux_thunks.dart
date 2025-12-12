// Redux Thunks for SignalR/WebRTC Integration
//
// This file demonstrates how to use SignalRSessionHub with Redux thunks.
// Adapt the imports and action types to match your actual codebase.

import 'dart:async';

import '../signalr/signalr_session_hub.dart';
import '../auth/auth.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Type Stubs - Replace with your actual imports
// ══════════════════════════════════════════════════════════════════════════════

// Replace these with your actual imports:
// import 'package:osp_mobile/api/isolates/i_isolate_api.dart';
// import 'package:osp_mobile/camera/redux/actions.dart';
// import 'package:osp_mobile/camera/redux/selectors.dart';
// import 'package:osp_mobile/logging/logger.dart';
// import 'package:osp_mobile/redux/state.dart';
// import 'package:redux/redux.dart';
// import 'package:redux_thunk/redux_thunk.dart';

typedef AppState = dynamic;
typedef Store<T> = dynamic;
typedef ThunkAction<T> = dynamic Function(dynamic store);

// Stub Logger - replace with your Logger()
class Logger {
  void info(String msg) => print('[INFO] $msg');
  void warn(String msg) => print('[WARN] $msg');
  void error(String msg, {dynamic error}) => print('[ERROR] $msg: $error');
}

// Stub selectors - replace with your actual selectors
String getCameraGUID(dynamic state, String cameraId) =>
    state.camera.bySlug['camera::$cameraId']?.ospCamera?.guid ?? '';

List<dynamic> getCamerasList(dynamic state) =>
    state.camera.bySlug.values.toList();

// ══════════════════════════════════════════════════════════════════════════════
// Helper
// ══════════════════════════════════════════════════════════════════════════════

String _fixCameraId(String cameraId) => cameraId.replaceFirst('dual-', '');

// ══════════════════════════════════════════════════════════════════════════════
// Connection Handlers
// ══════════════════════════════════════════════════════════════════════════════

Future<void> _handleConnect(dynamic store, String cameraId) async {
  final guid = getCameraGUID(store.state, cameraId);
  Logger().info('Connecting to camera $cameraId');

  final session = await SignalRSessionHub.instance.connectToCamera(guid);
  if (session == null) return;

  session.onTrack = (event) {
    if (event.streams.isEmpty) return;

    Logger().info(
      'Received track: ${event.track.id} of kind ${event.track.kind}',
    );

    if (event.track.kind == 'video' && event.streams.isNotEmpty) {
      // Video track - the session now stores it automatically
      // Get texture ID from your renderer setup
      // final textureId = session.renderer?.textureId;
      // store.dispatch(SetTextureId(slug: cameraId, textureId: textureId));
    } else if (event.track.kind == 'audio') {
      // Audio track - session stores it, default muted
      // The new session automatically mutes audio on receive
      // store.dispatch(SetLiveWebRTCAudio(slug: cameraId, enabled: true));
      // store.dispatch(SetCameraMute(slug: cameraId, mute: true));
    }
  };

  session.onConnectionComplete = () {
    Logger().info('Connection complete for camera $cameraId');
  };
}

void _handleDisconnect(dynamic store, String cameraId) {
  final guid = getCameraGUID(store.state, cameraId);

  // Dispatch Redux actions to reset state
  // store.dispatch(SetTextureId(slug: cameraId, textureId: null));
  // store.dispatch(SetLiveWebRTCAudio(slug: cameraId, enabled: false));
  // store.dispatch(SetCameraMute(slug: cameraId, mute: true));

  SignalRSessionHub.instance.disconnectCamera(guid);
  Logger().info('Camera $cameraId disconnected');
}

// ══════════════════════════════════════════════════════════════════════════════
// Redux Thunks
// ══════════════════════════════════════════════════════════════════════════════

/// Initialize SignalR and set up the live WebRTC stream listener.
///
/// Usage:
/// ```dart
/// store.dispatch(initializeSignalRThunk(signalRUrl));
/// ```
ThunkAction<AppState> initializeSignalRThunk(String signalRUrl) {
  return (store) async {
    try {
      Logger().info('Initializing SignalR with URL: $signalRUrl');

      // Get the live WebRTC stream from EvIsolateApi
      // final stream = EvIsolateApi().getLiveWebRTCStream();

      // Initialize the hub
      // Note: AuthService should already be logged in at this point
      final authService = AuthService(); // Or get from your DI/store
      await SignalRSessionHub.instance.initialize(signalRUrl, authService);

      // onRegister is no longer needed - registration is handled internally
      // But we can still enable cameras based on available producers:
      final devices =
          SignalRSessionHub.instance.authService?.devices.keys.toList() ?? [];
      Logger().info('SignalR registered devices: $devices');

      final existingCameras = getCamerasList(
        store.state,
      ).where((cam) => devices.contains(cam.ospCamera?.guid)).toList();

      for (final cam in existingCameras) {
        if (cam.enabled) continue;
        // store.dispatch(SetCameraEnabledStatus(slug: cam.slug, enabled: true));
      }

      // Set up the event stream listener
      // This replaces the old onEvent callback pattern
      // stream.listen((e) async {
      //   final (cameraId, isConnecting) = e as (String, bool);
      //   if (isConnecting) {
      //     await _handleConnect(store, _fixCameraId(cameraId));
      //   } else {
      //     _handleDisconnect(store, _fixCameraId(cameraId));
      //   }
      // });

      // Set available producers from store camera slugs
      final slugs = store.state.camera.bySlug.keys
          .map((k) => k.replaceFirst('camera::', ''))
          .toSet();
      // SignalRSessionHub.instance.setAvailableProducers = slugs;

      Logger().info('SignalR initialized successfully');
    } catch (e) {
      Logger().error('SignalR initialization failed', error: e);
    }
  };
}

/// Dispose SignalR hub and close all sessions.
///
/// Usage:
/// ```dart
/// store.dispatch(disposeSignalRThunk());
/// ```
ThunkAction<AppState> disposeSignalRThunk() {
  return (store) async {
    try {
      Logger().info('Disposing SignalR hub');
      await SignalRSessionHub.instance.shutdown();
    } catch (e) {
      Logger().error('Failed to dispose SignalR hub', error: e);
    }
  };
}

/// Toggle audio track for a camera.
///
/// Usage:
/// ```dart
/// store.dispatch(toggleAudioTrack('camera-123'));
/// store.dispatch(toggleAudioTrack('camera-123', enable: true));
/// ```
ThunkAction<AppState> toggleAudioTrack(String cameraId, {bool? enable}) {
  return (store) async {
    final guid = getCameraGUID(store.state, cameraId);
    final session = SignalRSessionHub.instance.getSession(guid);

    if (session == null) {
      Logger().warn('No active session found for camera $cameraId');
      return;
    }

    final audioTrack = session.audioTrack;
    if (audioTrack == null) {
      Logger().warn('No audio track found for camera $cameraId');
      return;
    }

    // Toggle or set the enabled state
    if (enable != null) {
      audioTrack.enabled = enable;
    } else {
      audioTrack.enabled = !audioTrack.enabled;
    }

    // Dispatch Redux action to update mute state
    // store.dispatch(SetCameraMute(slug: cameraId, mute: !audioTrack.enabled));

    Logger().info(
      'Track ${audioTrack.id} for camera $cameraId ${audioTrack.enabled ? "enabled" : "disabled"}',
    );
  };
}

/// Connect to a specific camera.
///
/// Usage:
/// ```dart
/// store.dispatch(connectCameraThunk('camera-123'));
/// ```
ThunkAction<AppState> connectCameraThunk(String cameraId) {
  return (store) async {
    await _handleConnect(store, _fixCameraId(cameraId));
  };
}

/// Disconnect from a specific camera.
///
/// Usage:
/// ```dart
/// store.dispatch(disconnectCameraThunk('camera-123'));
/// ```
ThunkAction<AppState> disconnectCameraThunk(String cameraId) {
  return (store) async {
    _handleDisconnect(store, _fixCameraId(cameraId));
  };
}
