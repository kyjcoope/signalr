import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../webrtc/webrtc_player.dart';
import '../webrtc/signaling_message.dart';
import '../utils/logger.dart';
import 'signalr_config.dart';
import 'signalr_connection_manager.dart';
import 'signalr_message_router.dart';
import 'signalr_messages.dart';

/// Singleton SignalR service for WebRTC signaling.
///
/// Provides a high-level API for WebRTC signaling operations,
/// delegating connection management to [SignalRConnectionManager]
/// and message routing to [SignalRMessageRouter].
class SignalRService {
  SignalRService._()
    : _messageController = StreamController<SignalRMessage>.broadcast();

  // ═══════════════════════════════════════════════════════════════════════════
  // Singleton
  // ═══════════════════════════════════════════════════════════════════════════

  static SignalRService? _instance;

  /// Get the singleton instance.
  static SignalRService get instance => _instance ??= SignalRService._();

  /// Reset the singleton (for testing or full cleanup).
  static void resetInstance() {
    _instance?.closeConnection(closeAllSessions: true);
    _instance = null;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // State
  // ═══════════════════════════════════════════════════════════════════════════

  SignalRConnectionManager? _connectionManager;
  SignalRMessageRouter? _messageRouter;
  SignalRConfig? _config;
  bool _serviceInitialized = false;
  String _signalRClientId = '';

  /// ICE server configuration received from the signaling server.
  List<IceServerConfig> iceServers = [];

  // ═══════════════════════════════════════════════════════════════════════════
  // Players & Messaging
  // ═══════════════════════════════════════════════════════════════════════════

  final List<VideoWebRTCPlayer> _players = [];
  final StreamController<SignalRMessage> _messageController;

  /// Stream of SignalR messages for players to subscribe to.
  Stream<SignalRMessage> get messageStream => _messageController.stream;

  // ═══════════════════════════════════════════════════════════════════════════
  // Getters
  // ═══════════════════════════════════════════════════════════════════════════

  /// Whether the service has been initialized.
  bool get isServiceInitialized => _serviceInitialized;

  /// Whether the SignalR connection is ready.
  bool get isPeerReady => _connectionManager?.isConnected ?? false;

  /// The SignalR client ID assigned by the server.
  String get signalRClientId => _signalRClientId;

  /// Configuration object.
  SignalRConfig? get config => _config;

  // ═══════════════════════════════════════════════════════════════════════════
  // Initialization
  // ═══════════════════════════════════════════════════════════════════════════

  /// Initialize the SignalR service.
  Future<void> initService(String signalRServerUrl) async {
    if (_serviceInitialized) {
      Logger().info('SignalRService: Already initialized, reconnecting...');
      await _connect();
      return;
    }

    Logger().info('SignalRService: Initializing with URL: $signalRServerUrl');
    _config = SignalRConfig(signalRServerUrl: signalRServerUrl);

    // Create message router
    _messageRouter = SignalRMessageRouter(
      findPlayerBySession: findPlayerBySession,
      findPlayerByDevice: findPlayerByDevice,
      findPlayerForConnection: _findPlayerForConnection,
      onIceServers: (servers) => iceServers = servers,
      onClientId: (id) => _signalRClientId = id,
    );

    // Create connection manager
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
    final connected = await _connectionManager?.connect() ?? false;
    if (connected) {
      _bindMessageHandlers();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection Callbacks
  // ═══════════════════════════════════════════════════════════════════════════

  void _onConnected() {
    Logger().info('SignalRService: Connected');
    _sendRegisterRequest();
  }

  void _onDisconnected(Exception? error) {
    Logger().warn('SignalRService: Disconnected: $error');
    _notifyPlayers(SignalRMessageType.onSignalClosed, {'error': error});
  }

  void _onReconnecting(Exception? error) {
    Logger().warn('SignalRService: Reconnecting: $error');
  }

  void _onReconnected(String? connectionId) {
    Logger().info('SignalRService: Reconnected: $connectionId');
    _sendRegisterRequest();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Message Handlers - Delegated to Router
  // ═══════════════════════════════════════════════════════════════════════════

  void _bindMessageHandlers() {
    final router = _messageRouter;
    if (router == null) return;

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
    if (peer != null) {
      final player = findPlayerByDevice(peer);
      if (player != null) return player;
    }
    return _players.where((p) => p.sessionId == null).firstOrNull;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sending Messages
  // ═══════════════════════════════════════════════════════════════════════════

  /// Gate that blocks low-priority sends (ICE trickle) while a high-priority
  /// send (SDP answer) is in-flight. This prevents the WebSocket invoke queue
  /// from delaying critical answer messages behind dozens of fire-and-forget
  /// ICE candidate sends.
  Completer<void>? _answerGate;

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

  /// Connect to a camera device.
  Future<bool> connectConsumerSession(String deviceId) async {
    final message = ConnectRequest(deviceId: deviceId);
    await _sendMessage(message.toJson());
    return true;
  }

  /// Send an SDP answer for an invite.
  ///
  /// This is a high-priority send. While the answer is in-flight, ICE trickle
  /// sends are gated so they don't queue ahead of answers on the WebSocket.
  Future<void> sendSignalInviteMessage(
    String sessionId,
    SdpWrapper sdp,
    String messageId,
  ) async {
    Logger().info(
      'SignalRService: 📤 SDP answer session=$sessionId id=$messageId type=${sdp.type}',
    );

    // Open the gate — ICE trickle sends will wait until this completes.
    _answerGate = Completer<void>();

    final message = InviteAnswerMessage(
      session: sessionId,
      answerSdp: sdp,
      id: messageId,
    );

    try {
      await _sendMessage(message.toJson());
      Logger().info('SignalRService: ✅ SDP answer sent successfully');
    } finally {
      // Release the gate so buffered ICE trickle sends can proceed.
      final gate = _answerGate;
      _answerGate = null;
      gate?.complete();
    }
  }

  /// Send an ICE candidate (fire-and-forget, gated behind answer sends).
  ///
  /// Does not await the hub response to avoid blocking the ICE exchange
  /// with ~100 serial awaits during multi-camera connection bursts.
  /// However, if an SDP answer is currently being sent, this will wait
  /// for it to complete first to avoid WebSocket queue contention.
  void sendSignalTrickleMessage(String sessionId, RTCIceCandidate candidate) {
    final message = TrickleMessage(session: sessionId, candidate: candidate);

    Future<void> send() async {
      // Wait for any in-flight answer send to complete first.
      final gate = _answerGate;
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

  /// Send a close message to the signaling server.
  ///
  /// Notifies the server that the client is intentionally closing the session.
  /// This matches the web UI behavior for clean disconnection.
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

  /// Leave a signaling session on the server.
  ///
  /// This is the proper way to disconnect from a session - it notifies
  /// the server to clean up resources for this session.
  ///
  /// Optionally sends a close message first for full cleanup.
  Future<void> leaveSession(
    String sessionId, {
    String? deviceId,
    bool sendCloseFirst = true,
  }) async {
    if (sendCloseFirst && deviceId != null) {
      await sendCloseMessage(sessionId, deviceId);
    }
    await _connectionManager?.leaveSession(sessionId);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Player Management
  // ═══════════════════════════════════════════════════════════════════════════

  /// Register a player to receive SignalR messages.
  void registerPlayer(VideoWebRTCPlayer player) {
    if (_players.any((p) => p.playerId == player.playerId)) {
      Logger().info(
        'SignalRService: Player ${player.playerId} already registered',
      );
      return;
    }

    player.subscription = _messageController.stream.listen(
      player.onSignalRMessage,
    );
    _players.add(player);
    Logger().info(
      'SignalRService: Registered player. Total: ${_players.length}',
    );
  }

  /// Unregister a player.
  void unregisterPlayer(VideoWebRTCPlayer player) {
    player.subscription?.cancel();
    player.subscription = null;
    _players.removeWhere((p) => p.playerId == player.playerId);
    Logger().info(
      'SignalRService: Unregistered player. Remaining: ${_players.length}',
    );
  }

  /// Find a player by session ID.
  VideoWebRTCPlayer? findPlayerBySession(String sessionId) =>
      _players.where((p) => p.sessionId == sessionId).firstOrNull;

  /// Find a player by device ID.
  VideoWebRTCPlayer? findPlayerByDevice(String deviceId) =>
      _players.where((p) => p.deviceId == deviceId).firstOrNull;

  void _notifyPlayers(SignalRMessageType type, dynamic detail) {
    _messageController.add(SignalRMessage(method: type, detail: detail));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Cleanup
  // ═══════════════════════════════════════════════════════════════════════════

  /// Close the SignalR connection.
  Future<void> closeConnection({bool closeAllSessions = false}) async {
    Logger().info('SignalRService: Closing connection');

    if (closeAllSessions) {
      for (final player in _players) {
        player.subscription?.cancel();
      }
      _players.clear();
      _serviceInitialized = false;
    }

    await _connectionManager?.dispose();
    if (closeAllSessions) {
      _connectionManager = null;
      _messageRouter = null;
    }
  }
}
