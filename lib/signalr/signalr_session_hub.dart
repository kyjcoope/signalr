import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';
import 'package:signalr/signalr/singalr_handler.dart';

import '../webrtc/webrtc_camera_session.dart';
import 'signalr_message.dart';

class SignalRSessionHub {
  static SignalRSessionHub? _instance;
  static SignalRSessionHub get instance {
    if (_instance == null) {
      throw StateError(
        'SignalRSessionHub not initialized. Call initialize() first.',
      );
    }
    return _instance!;
  }

  SignalRSessionHub._({required String signalRUrl, this.onRegister}) {
    signalingHandler = SignalRHandler(
      signalServiceUrl: signalRUrl,
      onConnect: _onConnectResponse,
      onRegister: _onRegister,
      onInvite: _onInvite,
      onTrickle: _onTrickleMessage,
    );
  }

  static Future<SignalRSessionHub> initialize({
    required String signalRUrl,
    VoidCallback? onRegister,
  }) async {
    if (_instance != null) {
      dev.log('SignalRSessionHub already initialized');
      return _instance!;
    }

    dev.log('Initializing SignalRSessionHub with URL: $signalRUrl');
    _instance = SignalRSessionHub._(
      signalRUrl: signalRUrl,
      onRegister: onRegister,
    );

    await _instance!.signalingHandler.setupSignaling();
    dev.log('SignalRSessionHub initialized successfully');

    return _instance!;
  }

  static bool get isInitialized => _instance != null;

  static void dispose() {
    if (_instance != null) {
      _instance!._dispose();
      _instance = null;
    }
  }

  late final SignalRHandler signalingHandler;
  final Set<String> _availableProducers = {};
  final Map<String, WebRtcCameraSession> _activeSessions = {};
  List<IceServer> iceServers = [];

  VoidCallback? onRegister;

  Set<String> get availableProducers => _availableProducers;
  Map<String, WebRtcCameraSession> get activeSessions => _activeSessions;

  void _dispose() {
    for (var session in _activeSessions.values) {
      session.dispose();
    }
    _activeSessions.clear();
    signalingHandler.shutdown(_activeSessions.keys.toList());
    _availableProducers.clear();
    dev.log('SignalRSessionHub disposed');
  }

  Future<WebRtcCameraSession?> connectToCamera(String cameraId) async {
    final fullProducerId = _availableProducers
        .where((p) => p.startsWith(cameraId))
        .firstOrNull;

    if (fullProducerId == null) {
      dev.log('Camera $cameraId not found in available producers');
      return null;
    }

    if (_activeSessions.containsKey(fullProducerId)) {
      dev.log('Camera $cameraId already connected');
      return _activeSessions[fullProducerId];
    }

    final cameraSession = WebRtcCameraSession(
      cameraId: fullProducerId,
      sessionHub: this,
    );

    _activeSessions[fullProducerId] = cameraSession;

    signalingHandler.sendConnect(
      ConnectRequest(
        signalingHandler.connectionId,
        authorization: '',
        deviceId: fullProducerId,
        iceServers: iceServers,
      ),
    );

    return cameraSession;
  }

  void disconnectCamera(String cameraId) {
    final session = _activeSessions.remove(cameraId);
    if (session != null) {
      session.dispose();
      // signalingHandler.endSession(session.sessionId);
    }
  }

  void _onRegister(RegisterResponse msg) {
    dev.log('onRegister: ${msg.deviceIds.length} devices');
    _availableProducers.addAll(msg.deviceIds);
    onRegister?.call();
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
    final session = _activeSessions.values
        .where((s) => s.sessionId == msg.session)
        .firstOrNull;

    if (session != null) {
      session.handleInvite(msg);
    } else {
      dev.log('Received invite for unknown session: ${msg.session}');
    }
  }

  void _onTrickleMessage(TrickleMessage msg) {
    final session = _activeSessions.values
        .where((s) => s.sessionId == msg.session)
        .firstOrNull;

    if (session != null) {
      session.handleTrickle(msg);
    } else {
      dev.log('Received trickle for unknown session: ${msg.session}');
    }
  }
}
