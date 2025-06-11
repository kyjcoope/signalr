import 'package:redux/redux.dart';
import 'package:redux_thunk/redux_thunk.dart';
import 'package:signalr/signalr/signalr_session_hub.dart';
import 'package:signalr/redux/state.dart';
import 'dart:developer' as dev;

import 'actions.dart';

ThunkAction<AppState> initializeSignalRThunk(String signalRUrl) {
  return (Store<AppState> store) async {
    try {
      dev.log('Initializing SignalR with URL: $signalRUrl');
      store.dispatch(InitializeSignalRAction(signalRUrl));
      await SignalRSessionHub.initialize(
        signalRUrl: signalRUrl,
        onRegister: () {
          final devices = SignalRSessionHub.instance.availableProducers
              .toList();
          store.dispatch(DevicesRegisteredAction(devices));
        },
      );

      store.dispatch(const SignalRConnectedAction());
      dev.log('SignalR initialization complete');
    } catch (e) {
      dev.log('SignalR initialization failed: $e');
      store.dispatch(CameraErrorAction('signalr', 'Failed to initialize: $e'));
    }
  };
}

ThunkAction<AppState> connectToCameraThunk(String deviceId) {
  return (Store<AppState> store) async {
    if (!SignalRSessionHub.isInitialized) {
      store.dispatch(CameraErrorAction(deviceId, 'SignalR not initialized'));
      return;
    }

    try {
      dev.log('Connecting to camera: $deviceId');
      store.dispatch(CameraConnectingAction(deviceId));
      final session = await SignalRSessionHub.instance.connectToCamera(
        deviceId,
      );

      if (session != null) {
        store.dispatch(CameraConnectedAction(deviceId, session));
        session.onTrack = (event) {
          dev.log('[$deviceId] Track received in thunk: ${event.track.kind}');
          if (event.track.kind == 'video') {
            store.dispatch(CameraVideoTrackReceivedAction(deviceId));
          }
        };

        session.onConnectionComplete = () {
          dev.log('Camera $deviceId connection completed');
        };

        dev.log('Camera $deviceId connected successfully');
      } else {
        store.dispatch(
          CameraConnectionFailedAction(deviceId, 'Failed to create session'),
        );
      }
    } catch (e) {
      dev.log('Camera connection failed: $e');
      store.dispatch(CameraConnectionFailedAction(deviceId, e.toString()));
    }
  };
}

ThunkAction<AppState> disconnectCameraThunk(String deviceId) {
  return (Store<AppState> store) async {
    if (!SignalRSessionHub.isInitialized) return;

    try {
      dev.log('Disconnecting camera: $deviceId');
      SignalRSessionHub.instance.disconnectCamera(deviceId);
      store.dispatch(CameraDisconnectedAction(deviceId));
    } catch (e) {
      dev.log('Camera disconnection failed: $e');
      store.dispatch(CameraErrorAction(deviceId, e.toString()));
    }
  };
}

ThunkAction<AppState> disconnectAllCamerasThunk() {
  return (Store<AppState> store) async {
    if (!SignalRSessionHub.isInitialized) return;

    try {
      dev.log('Disconnecting all cameras');

      final activeCameras = store.state.cameraState.activeCameras.keys.toList();
      for (final cameraId in activeCameras) {
        SignalRSessionHub.instance.disconnectCamera(cameraId);
        store.dispatch(CameraDisconnectedAction(cameraId));
      }
    } catch (e) {
      dev.log('Failed to disconnect all cameras: $e');
      store.dispatch(CameraErrorAction('all', e.toString()));
    }
  };
}

ThunkAction<AppState> disposeSignalRThunk() {
  return (Store<AppState> store) async {
    try {
      dev.log('Disposing SignalR hub');
      SignalRSessionHub.dispose();
      store.dispatch(const SignalRDisconnectedAction());
    } catch (e) {
      dev.log('Failed to dispose SignalR hub: $e');
    }
  };
}
