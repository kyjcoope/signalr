import '../../webrtc/webrtc_camera_session.dart';

class InitializeSignalRAction {
  const InitializeSignalRAction(this.signalRUrl);
  final String signalRUrl;
}

class SignalRConnectedAction {
  const SignalRConnectedAction();
}

class SignalRDisconnectedAction {
  const SignalRDisconnectedAction();
}

class DevicesRegisteredAction {
  const DevicesRegisteredAction(this.deviceIds);
  final List<String> deviceIds;
}

class ConnectToCameraAction {
  const ConnectToCameraAction(this.deviceId);
  final String deviceId;
}

class CameraConnectingAction {
  const CameraConnectingAction(this.deviceId);
  final String deviceId;
}

class CameraConnectedAction {
  const CameraConnectedAction(this.deviceId, this.session);
  final String deviceId;
  final WebRtcCameraSession session;
}

class CameraConnectionFailedAction {
  const CameraConnectionFailedAction(this.deviceId, this.error);
  final String deviceId;
  final String error;
}

class DisconnectCameraAction {
  const DisconnectCameraAction(this.deviceId);
  final String deviceId;
}

class CameraDisconnectedAction {
  const CameraDisconnectedAction(this.deviceId);
  final String deviceId;
}

class DisconnectAllCamerasAction {
  const DisconnectAllCamerasAction();
}

class CameraVideoTrackReceivedAction {
  const CameraVideoTrackReceivedAction(this.deviceId);
  final String deviceId;
}

class CameraVideoTrackLostAction {
  const CameraVideoTrackLostAction(this.deviceId);
  final String deviceId;
}

class CameraErrorAction {
  const CameraErrorAction(this.deviceId, this.error);
  final String deviceId;
  final String error;
}

class ClearCameraErrorAction {
  const ClearCameraErrorAction();
}
