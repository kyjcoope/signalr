import 'package:signalr/camera/redux/state.dart';
import 'package:signalr/redux/state.dart';

CameraState selectCameraState(AppState state) => state.cameraState;

bool selectIsSignalRConnected(AppState state) =>
    selectCameraState(state).isSignalRConnected;

bool selectIsDeviceRegistrationComplete(AppState state) =>
    selectCameraState(state).isDeviceRegistrationComplete;

List<String> selectAvailableDevices(AppState state) =>
    selectCameraState(state).availableDevices;

Map<String, CameraInfo> selectActiveCameras(AppState state) =>
    selectCameraState(state).activeCameras;

String? selectCameraError(AppState state) =>
    selectCameraState(state).errorMessage;

int selectConnectedCameraCount(AppState state) {
  return selectActiveCameras(state).values
      .where((camera) => camera.status == CameraConnectionStatus.connected)
      .length;
}

List<CameraInfo> selectConnectedCameras(AppState state) {
  return selectActiveCameras(state).values
      .where((camera) => camera.status == CameraConnectionStatus.connected)
      .toList();
}

List<CameraInfo> selectCamerasWithVideo(AppState state) {
  return selectActiveCameras(state).values
      .where(
        (camera) =>
            camera.status == CameraConnectionStatus.connected &&
            camera.hasVideo,
      )
      .toList();
}

bool selectCanConnectToCameras(AppState state) {
  return selectIsSignalRConnected(state) &&
      selectIsDeviceRegistrationComplete(state) &&
      selectAvailableDevices(state).isNotEmpty;
}

CameraInfo? selectCameraInfo(AppState state, String deviceId) {
  return selectActiveCameras(state)[deviceId];
}

bool selectIsCameraConnected(AppState state, String deviceId) {
  final camera = selectCameraInfo(state, deviceId);
  return camera?.status == CameraConnectionStatus.connected;
}

bool selectIsCameraConnecting(AppState state, String deviceId) {
  final camera = selectCameraInfo(state, deviceId);
  return camera?.status == CameraConnectionStatus.connecting;
}
