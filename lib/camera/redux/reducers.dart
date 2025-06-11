import 'package:redux/redux.dart';

import 'actions.dart';
import 'state.dart';

final cameraReducer = combineReducers<CameraState>([
  TypedReducer<CameraState, InitializeSignalRAction>(_initializeSignalR).call,
  TypedReducer<CameraState, SignalRConnectedAction>(_signalRConnected).call,
  TypedReducer<CameraState, SignalRDisconnectedAction>(
    _signalRDisconnected,
  ).call,
  TypedReducer<CameraState, DevicesRegisteredAction>(_devicesRegistered).call,
  TypedReducer<CameraState, CameraConnectingAction>(_cameraConnecting).call,
  TypedReducer<CameraState, CameraConnectedAction>(_cameraConnected).call,
  TypedReducer<CameraState, CameraConnectionFailedAction>(
    _cameraConnectionFailed,
  ).call,
  TypedReducer<CameraState, CameraDisconnectedAction>(_cameraDisconnected).call,
  TypedReducer<CameraState, DisconnectAllCamerasAction>(
    _disconnectAllCameras,
  ).call,
  TypedReducer<CameraState, CameraVideoTrackReceivedAction>(
    _cameraVideoTrackReceived,
  ).call,
  TypedReducer<CameraState, CameraVideoTrackLostAction>(
    _cameraVideoTrackLost,
  ).call,
  TypedReducer<CameraState, CameraErrorAction>(_cameraError).call,
  TypedReducer<CameraState, ClearCameraErrorAction>(_clearCameraError).call,
]);

CameraState _initializeSignalR(
  CameraState state,
  InitializeSignalRAction action,
) {
  return state.copyWith(signalRUrl: action.signalRUrl, errorMessage: null);
}

CameraState _signalRConnected(
  CameraState state,
  SignalRConnectedAction action,
) {
  return state.copyWith(isSignalRConnected: true, errorMessage: null);
}

CameraState _signalRDisconnected(
  CameraState state,
  SignalRDisconnectedAction action,
) {
  return state.copyWith(
    isSignalRConnected: false,
    isDeviceRegistrationComplete: false,
    availableDevices: [],
  );
}

CameraState _devicesRegistered(
  CameraState state,
  DevicesRegisteredAction action,
) {
  return state.copyWith(
    availableDevices: action.deviceIds,
    isDeviceRegistrationComplete: true,
    errorMessage: null,
  );
}

CameraState _cameraConnecting(
  CameraState state,
  CameraConnectingAction action,
) {
  final updatedCameras = Map<String, CameraInfo>.from(state.activeCameras);
  updatedCameras[action.deviceId] = CameraInfo(
    deviceId: action.deviceId,
    status: CameraConnectionStatus.connecting,
  );

  return state.copyWith(activeCameras: updatedCameras);
}

CameraState _cameraConnected(CameraState state, CameraConnectedAction action) {
  final updatedCameras = Map<String, CameraInfo>.from(state.activeCameras);
  updatedCameras[action.deviceId] = CameraInfo(
    deviceId: action.deviceId,
    status: CameraConnectionStatus.connected,
    session: action.session,
  );

  return state.copyWith(activeCameras: updatedCameras);
}

CameraState _cameraConnectionFailed(
  CameraState state,
  CameraConnectionFailedAction action,
) {
  final updatedCameras = Map<String, CameraInfo>.from(state.activeCameras);
  updatedCameras[action.deviceId] = CameraInfo(
    deviceId: action.deviceId,
    status: CameraConnectionStatus.failed,
    errorMessage: action.error,
  );

  return state.copyWith(activeCameras: updatedCameras);
}

CameraState _cameraDisconnected(
  CameraState state,
  CameraDisconnectedAction action,
) {
  final updatedCameras = Map<String, CameraInfo>.from(state.activeCameras);
  updatedCameras.remove(action.deviceId);

  return state.copyWith(activeCameras: updatedCameras);
}

CameraState _disconnectAllCameras(
  CameraState state,
  DisconnectAllCamerasAction action,
) {
  return state.copyWith(activeCameras: {});
}

CameraState _cameraVideoTrackReceived(
  CameraState state,
  CameraVideoTrackReceivedAction action,
) {
  final currentCamera = state.activeCameras[action.deviceId];
  if (currentCamera == null) return state;

  final updatedCameras = Map<String, CameraInfo>.from(state.activeCameras);
  updatedCameras[action.deviceId] = currentCamera.copyWith(hasVideo: true);

  return state.copyWith(activeCameras: updatedCameras);
}

CameraState _cameraVideoTrackLost(
  CameraState state,
  CameraVideoTrackLostAction action,
) {
  final currentCamera = state.activeCameras[action.deviceId];
  if (currentCamera == null) return state;

  final updatedCameras = Map<String, CameraInfo>.from(state.activeCameras);
  updatedCameras[action.deviceId] = currentCamera.copyWith(hasVideo: false);

  return state.copyWith(activeCameras: updatedCameras);
}

CameraState _cameraError(CameraState state, CameraErrorAction action) {
  return state.copyWith(errorMessage: action.error);
}

CameraState _clearCameraError(
  CameraState state,
  ClearCameraErrorAction action,
) {
  return state.copyWith(errorMessage: null);
}
