import 'dart:async';
import 'dart:developer' as dev;
import 'package:signalr/auth/auth.dart';
import 'package:signalr/config.dart';
import 'package:signalr/signalr/singalr_handler.dart';

import '../webrtc/webrtc_camera_session.dart';
import 'signalr_message.dart';

class SignalRSessionHub {
  SignalRSessionHub({required String signalRUrl}) {
    signalingHandler = SignalRHandler(
      signalServiceUrl: signalRUrl,
      onConnect: _onConnectResponse,
      onInvite: _onInvite,
      onTrickle: _onTrickleMessage,
    );
  }

  late final SignalRHandler signalingHandler;
  final Set<String> _availableProducers = {};
  final Map<String, WebRtcCameraSession> _activeSessions = {};
  List<IceServer> iceServers = [];

  Set<String> get availableProducers => _availableProducers;
  Map<String, WebRtcCameraSession> get activeSessions => _activeSessions;

  Future<void> initialize() async {
    await authLogin(
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
    _availableProducers.addAll(devices.keys);
    await signalingHandler.setupSignaling();
  }

  Future<void> shutdown() async {
    final sessions = _activeSessions.values.toList();
    final sessionIds =
        sessions.map((s) => s.sessionId).whereType<String>().toList();

    for (final s in sessions) {
      s.dispose();
    }
    _activeSessions.clear();
    await signalingHandler.shutdown(sessionIds);

    _availableProducers.clear();
  }

  Future<WebRtcCameraSession?> connectToCamera(String cameraId) async {
    final fullProducerId =
        _availableProducers.where((p) => p.startsWith(cameraId)).firstOrNull;

    if (fullProducerId == null) {
      dev.log('Camera $cameraId not found in available producers');
      return null;
    }

    if (_activeSessions.containsKey(fullProducerId)) {
      dev.log('Camera $cameraId already connected');
      return _activeSessions[fullProducerId];
    }

    // Create new camera session
    final cameraSession = WebRtcCameraSession(
      cameraId: fullProducerId,
      sessionHub: this,
    );

    _activeSessions[fullProducerId] = cameraSession;

    // Send connect request
    signalingHandler.sendConnect(
      ConnectRequest(
        signalingHandler.connectionId,
        authorization: '',
        deviceId: fullProducerId,
        profile: '',
      ),
    );

    return cameraSession;
  }

  Future<void> disconnectCamera(String cameraId) async {
    final session = _activeSessions.remove(cameraId);
    if (session != null) {
      final sessionId = session.sessionId;
      session.dispose();

      if (sessionId != null && sessionId.isNotEmpty) {
        await signalingHandler.leaveSession(sessionId);
      }
    }
  }

  void _onConnectResponse(ConnectResponse msg) {
    dev.log('Session started: ${msg.session}');
    iceServers = msg.iceServers;

    for (var session in _activeSessions.values) {
      if (session.sessionId == null) {
        session.handleConnectResponse(msg);
        break;
      }
    }
  }

  void _onInvite(InviteResponse msg) {
    final session =
        _activeSessions.values
            .where((s) => s.sessionId == msg.session)
            .firstOrNull;
    if (session != null) {
      session.handleInvite(msg);
    } else {
      dev.log('Received invite for unknown session: ${msg.session}');
    }
  }

  void _onTrickleMessage(TrickleMessage msg) {
    final session =
        _activeSessions.values
            .where((s) => s.sessionId == msg.session)
            .firstOrNull;

    if (session != null) {
      session.handleTrickle(msg);
    } else {
      dev.log('Received trickle for unknown session: ${msg.session}');
    }
  }
}
