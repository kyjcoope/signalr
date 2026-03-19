import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../webrtc/webrtc_player.dart';
import '../webrtc/signaling_message.dart';
import '../utils/logger.dart';
import 'signalr_config.dart';
import 'signalr_connection_manager.dart';
import 'signalr_message_router.dart';
import 'signalr_messages.dart';
import 'signalr_session_hub.dart';

class SignalRService {
  SignalRService._();

  static SignalRService? _instance;
  static SignalRService get instance => _instance ??= SignalRService._();

  static void resetInstance() {
    _instance?.closeConnection(closeAllSessions: true);
    _instance = null;
  }

  SignalRConnectionManager? _connectionManager;
  SignalRMessageRouter? _messageRouter;
  SignalRConfig? _config;
  bool _serviceInitialized = false;
  String _signalRClientId = '';
  Completer<void> _readyCompleter = Completer<void>();

  Future<void> get ready => _readyCompleter.future;

  List<IceServerConfig> iceServers = [];

  final List<VideoWebRTCPlayer> _players = [];
  final Map<String, VideoWebRTCPlayer> _playersByDevice = {};
  final Map<String, VideoWebRTCPlayer> _playersBySession = {};
  final Map<String, Completer<void>> _answerGates = {};

  bool get isServiceInitialized => _serviceInitialized;
  bool get isPeerReady => _connectionManager?.isConnected ?? false;
  String get signalRClientId => _signalRClientId;
  SignalRConfig? get config => _config;

  Future<void> initService(String signalRServerUrl) async {
    if (_serviceInitialized) {
      Logger().info('SignalRService: Already initialized, reconnecting...');
      await _connect();
      return;
    }

    Logger().info('SignalRService: Initializing with URL: $signalRServerUrl');
    _config = SignalRConfig(signalRServerUrl: signalRServerUrl);

    _messageRouter = SignalRMessageRouter(
      findPlayerBySession: findPlayerBySession,
      findPlayerByDevice: findPlayerByDevice,
      findPlayerForConnection: _findPlayerForConnection,
      onIceServers: (servers) => iceServers = servers,
      onClientId: (id) => _signalRClientId = id,
      onSessionAssigned: updateSessionIndex,
    );

    _connectionManager = SignalRConnectionManager(
      config: _config!,
      onConnected: _onConnected,
      onDisconnected: _onDisconnected,
      onReconnecting: _onReconnecting,
      onReconnected: _onReconnected,
    );

    _serviceInitialized = true;
    await _connect();
  }

  Future<void> _connect() async {
    await _connectionManager?.connect(
      onConnectionCreated: _bindMessageHandlers,
    );
  }

  void _onConnected() {
    Logger().info('SignalRService: Connected');
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
    _sendRegisterRequest();
  }

  void _onDisconnected(Exception? error) {
    Logger().warn('SignalRService: Disconnected: $error');
  }

  void _onReconnecting(Exception? error) {
    Logger().warn('SignalRService: Reconnecting: $error');
  }

  void _onReconnected(String? connectionId) {
    Logger().info('SignalRService: Reconnected: $connectionId');
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
    _bindMessageHandlers();
    _sendRegisterRequest();

    Future(() => SignalRSessionHub.instance.reconnectAllSessions()).catchError((
      e,
    ) {
      Logger().error('SignalRService: Error while reconnecting sessions: $e');
    });
  }

  void _bindMessageHandlers() {
    final router = _messageRouter;
    if (router == null) return;

    _connectionManager?.off('ReceivedSignalingMessage');
    _connectionManager?.off('register');
    _connectionManager?.off('devicedisconnected');
    _connectionManager?.off('peerdisconnected');
    _connectionManager?.off('error');

    _connectionManager?.on(
      'ReceivedSignalingMessage',
      router.handleSignalRMessage,
    );
    _connectionManager?.on('register', router.handleDeviceSessionInfo);
    _connectionManager?.on(
      'devicedisconnected',
      router.handleDeviceDisconnected,
    );
    _connectionManager?.on('peerdisconnected', router.handlePeerDisconnected);
    _connectionManager?.on('error', router.handleError);
  }

  VideoWebRTCPlayer? _findPlayerForConnection(String? peer) {
    if (peer != null) return findPlayerByDevice(peer);
    Logger().warn(
      'SignalRService: Connect response missing peer — cannot route',
    );
    return null;
  }

  Future<void> _sendMessage(Map<String, dynamic> data) async {
    if (!isPeerReady) {
      Logger().warn('SignalRService: Cannot send - not connected');
      return;
    }
    try {
      await _connectionManager?.invoke('SendMessage', args: [data]);
    } catch (e) {
      Logger().error('SignalRService: Send error: $e');
    }
  }

  Future<void> _sendRegisterRequest() async {
    final message = RegisterRequest(authorization: '');
    await _sendMessage(message.toJson());
  }

  Future<bool> connectConsumerSession(String deviceId) async {
    if (!isPeerReady) {
      Logger().warn('SignalRService: Cannot connect - not connected');
      return false;
    }
    try {
      final message = ConnectRequest(deviceId: deviceId);
      await _connectionManager?.invoke('SendMessage', args: [message.toJson()]);
      return true;
    } catch (e) {
      Logger().error('SignalRService: Connect request failed for $deviceId: $e');
      return false;
    }
  }

  Future<void> sendSignalInviteMessage(
    String sessionId,
    SdpWrapper sdp,
    String messageId,
  ) async {
    Logger().info(
      'SignalRService: 📤 SDP answer session=$sessionId id=$messageId type=${sdp.type}',
    );
    _answerGates[sessionId] = Completer<void>();

    final message = InviteAnswerMessage(
      session: sessionId,
      answerSdp: sdp,
      id: messageId,
    );

    try {
      await _sendMessage(message.toJson());
      Logger().info('SignalRService: ✅ SDP answer sent successfully');
    } finally {
      final gate = _answerGates.remove(sessionId);
      gate?.complete();
    }
  }

  void sendSignalTrickleMessage(String sessionId, RTCIceCandidate candidate) {
    final message = TrickleMessage(session: sessionId, candidate: candidate);

    Future<void> send() async {
      final gate = _answerGates[sessionId];
      if (gate != null && !gate.isCompleted) {
        await gate.future;
      }
      await _sendMessage(message.toJson());
    }

    send().catchError((e) {
      Logger().error(
        'SignalRService: ICE candidate send error for $sessionId: $e',
      );
    });
  }

  Future<void> sendCloseMessage(String sessionId, String deviceId) async {
    Logger().info(
      'SignalRService: Sending close message for session: $sessionId',
    );
    if (!isPeerReady) return;

    try {
      final message = CloseMessage(session: sessionId, deviceId: deviceId);
      await _connectionManager?.invoke('SendMessage', args: [message.toJson()]);
    } catch (e) {
      Logger().error('SignalRService: Send close message error: $e');
    }
  }

  void registerPlayer(VideoWebRTCPlayer player) {
    if (_players.any((p) => p.playerId == player.playerId)) {
      Logger().info(
        'SignalRService: Player ${player.playerId} already registered',
      );
      return;
    }
    _players.add(player);
    _playersByDevice[player.deviceId] = player;
    Logger().info(
      'SignalRService: Registered player. Total: ${_players.length}',
    );
  }

  void unregisterPlayer(VideoWebRTCPlayer player) {
    _players.removeWhere((p) => p.playerId == player.playerId);
    _playersByDevice.remove(player.deviceId);
    if (player.sessionId != null) {
      _playersBySession.remove(player.sessionId);
      final gate = _answerGates.remove(player.sessionId);
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    Logger().info(
      'SignalRService: Unregistered player. Remaining: ${_players.length}',
    );
  }

  void updateSessionIndex(String sessionId, VideoWebRTCPlayer player) {
    _playersBySession[sessionId] = player;
  }

  VideoWebRTCPlayer? findPlayerBySession(String sessionId) =>
      _playersBySession[sessionId];

  VideoWebRTCPlayer? findPlayerByDevice(String deviceId) =>
      _playersByDevice[deviceId];

  Future<void> closeConnection({bool closeAllSessions = false}) async {
    Logger().info('SignalRService: Closing connection');

    if (closeAllSessions) {
      _players.clear();
      _playersByDevice.clear();
      _playersBySession.clear();
      _messageRouter = null;
    }

    await _connectionManager?.dispose();
    _connectionManager = null;
    _serviceInitialized = false;

    if (!_readyCompleter.isCompleted) {
      _readyCompleter.completeError(
        StateError('SignalR service closed while waiting for connection'),
      );
    }
    _readyCompleter = Completer<void>();
  }
}
