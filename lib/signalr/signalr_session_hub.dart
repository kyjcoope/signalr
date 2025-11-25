import 'dart:async';
import 'dart:developer' as dev;
import 'package:signalr/auth/auth.dart';
import 'package:signalr/models/models.dart';
import 'package:signalr/signalr/singalr_handler.dart';
import '../webrtc/webrtc_camera_session.dart';
import 'signalr_message.dart';

class SignalRSessionHub {
  SignalRSessionHub({required String signalRUrl}) {
    signalingHandler = SignalRHandler(
      signalServiceUrl: signalRUrl,
      onMessage: _handleSignalRMessage,
    );
  }

  late final SignalRHandler signalingHandler;
  final AuthService authService = AuthService();
  final Map<String, WebRtcCameraSession> activeSessions = {};
  List<IceServer> iceServers = [];

  Iterable<String> get availableProducers => authService.devices.keys;

  Future<void> initialize(UserLogin loginCredentials) async {
    await authService.login(loginCredentials);
    await signalingHandler.connect();
  }

  Future<void> shutdown() async {
    for (final s in activeSessions.values) {
      if (s.sessionId != null) {
        await signalingHandler.leaveSession(s.sessionId!);
      }
      s.dispose();
    }
    activeSessions.clear();
    await signalingHandler.shutdown();
  }

  Future<WebRtcCameraSession?> connectToCamera(String cameraId) async {
    if (!authService.devices.containsKey(cameraId)) {
      dev.log('Camera $cameraId not found');
      return null;
    }

    if (activeSessions.containsKey(cameraId)) return activeSessions[cameraId];

    final session = WebRtcCameraSession(cameraId: cameraId, sessionHub: this);
    activeSessions[cameraId] = session;

    await signalingHandler.send(
      ConnectRequest(
        signalingHandler.connectionId,
        authorization: '',
        deviceId: cameraId,
        profile: '',
      ),
    );

    return session;
  }

  Future<void> disconnectCamera(String cameraId) async {
    final session = activeSessions.remove(cameraId);
    if (session != null) {
      if (session.sessionId != null) {
        await signalingHandler.leaveSession(session.sessionId!);
      }
      session.dispose();
    }
  }

  void _handleSignalRMessage(String method, dynamic data) {
    switch (method) {
      case 'connect':
        final msg = ConnectResponse.fromJson(data);
        iceServers = msg.iceServers;
        activeSessions.values
            .firstWhere(
              (s) => s.sessionId == null,
              orElse: () => activeSessions.values.first,
            )
            .handleConnectResponse(msg);
        break;
      case 'invite':
        final msg = InviteResponse.fromJson(data);
        _findSession(msg.session)?.handleInvite(msg);
        break;
      case 'trickle':
        final msg = TrickleMessage.fromJson(data);
        _findSession(msg.session)?.handleTrickle(msg);
        break;
    }
  }

  WebRtcCameraSession? _findSession(String? sessionId) {
    if (sessionId == null) return null;
    return activeSessions.values
        .where((s) => s.sessionId == sessionId)
        .firstOrNull;
  }
}
