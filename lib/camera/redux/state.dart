import 'package:equatable/equatable.dart';
import '../../webrtc/webrtc_camera_session.dart';

enum CameraConnectionStatus { disconnected, connecting, connected, failed }

class CameraInfo extends Equatable {
  const CameraInfo({
    required this.deviceId,
    required this.status,
    this.session,
    this.hasVideo = false,
    this.errorMessage,
  });

  final String deviceId;
  final CameraConnectionStatus status;
  final WebRtcCameraSession? session;
  final bool hasVideo;
  final String? errorMessage;

  CameraInfo copyWith({
    String? deviceId,
    CameraConnectionStatus? status,
    WebRtcCameraSession? session,
    bool? hasVideo,
    String? errorMessage,
  }) {
    return CameraInfo(
      deviceId: deviceId ?? this.deviceId,
      status: status ?? this.status,
      session: session ?? this.session,
      hasVideo: hasVideo ?? this.hasVideo,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  List<Object?> get props => [
    deviceId,
    status,
    session,
    hasVideo,
    errorMessage,
  ];
}

class CameraState extends Equatable {
  const CameraState({
    this.availableDevices = const [],
    this.activeCameras = const {},
    this.isSignalRConnected = false,
    this.isDeviceRegistrationComplete = false,
    this.signalRUrl = '',
    this.errorMessage,
  });

  final List<String> availableDevices;
  final Map<String, CameraInfo> activeCameras;
  final bool isSignalRConnected;
  final bool isDeviceRegistrationComplete;
  final String signalRUrl;
  final String? errorMessage;

  CameraState copyWith({
    List<String>? availableDevices,
    Map<String, CameraInfo>? activeCameras,
    bool? isSignalRConnected,
    bool? isDeviceRegistrationComplete,
    String? signalRUrl,
    String? errorMessage,
  }) {
    return CameraState(
      availableDevices: availableDevices ?? this.availableDevices,
      activeCameras: activeCameras ?? this.activeCameras,
      isSignalRConnected: isSignalRConnected ?? this.isSignalRConnected,
      isDeviceRegistrationComplete:
          isDeviceRegistrationComplete ?? this.isDeviceRegistrationComplete,
      signalRUrl: signalRUrl ?? this.signalRUrl,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  List<Object?> get props => [
    availableDevices,
    activeCameras,
    isSignalRConnected,
    isDeviceRegistrationComplete,
    signalRUrl,
    errorMessage,
  ];
}
