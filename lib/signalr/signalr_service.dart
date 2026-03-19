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

/// Singleton SignalR service for WebRTC signaling.
///
/// Provides a high-level API for WebRTC signaling operations,
/// delegating connection management to [SignalRConnectionManager]
/// and message routing to [SignalRMessageRouter].
class SignalRService {
  SignalRService._();

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

  /// Completes when the SignalR transport connects and registration succeeds.
  /// `connectToCamera` callers await this so early requests are deferred
  /// instead of silently failing.
  Completer<void> _readyCompleter = Completer<void>();

  /// A future that completes when the service is connected and ready.
  ///
  /// Callers can `await` this to defer work until SignalR is available.
  /// Completes immediately if already connected.
  Future<void> get ready => _readyCompleter.future;

  /// ICE server configuration received from the signaling server.
  List<IceServerConfig> iceServers = [];

  // ═══════════════════════════════════════════════════════════════════════════
  // Players & Messaging
  // ═══════════════════════════════════════════════════════════════════════════

  final List<VideoWebRTCPlayer> _players = [];
  final Map<String, VideoWebRTCPlayer> _playersByDevice = {};
  final Map<String, VideoWebRTCPlayer> _playersBySession = {};

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
      onSessionAssigned: updateSessionIndex,
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
    // Bind handlers AFTER the connection object is created but BEFORE start()
    // so ReceivedSignalingMessage is registered before any server responses.
    await _connectionManager?.connect(
      onConnectionCreated: _bindMessageHandlers,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection Callbacks
  // ═══════════════════════════════════════════════════════════════════════════

  void _onConnected() {
    Logger().info('SignalRService: Connected');
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
    _sendRegisterRequest();
  }

  void _onDisconnected(Exception? error) {
    Logger().warn('SignalRService: Disconnected: $error');
    // Do NOT broadcast onSignalClosed to sessions here.
    // The transport may recover via our fallback retry loop.
    // Sessions will be re-established by reconnectAllSessions().
  }

  void _onReconnecting(Exception? error) {
    Logger().warn('SignalRService: Reconnecting: $error');
  }

  void _onReconnected(String? connectionId) {
    Logger().info('SignalRService: Reconnected: $connectionId');
    // Complete the readiness signal for any callers that queued up
    // during the outage.
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
    // Re-bind message handlers — critical when fallback reconnect
    // creates a brand-new HubConnection.
    _bindMessageHandlers();
    _sendRegisterRequest();

    // Re-establish all camera sessions that died during the outage
    Future(() => SignalRSessionHub.instance.reconnectAllSessions()).catchError((
      e,
    ) {
      Logger().error('SignalRService: Error while reconnecting sessions: $e');
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Message Handlers - Delegated to Router
  // ═══════════════════════════════════════════════════════════════════════════

  void _bindMessageHandlers() {
    final router = _messageRouter;
    if (router == null) return;

    // Unbind first to prevent duplicate registrations.
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
    if (peer != null) {
      return findPlayerByDevice(peer);
    }
    // Don't blindly grab the first null-session player — in multi-camera
    // bursts that can bind the session to the wrong camera.
    Logger().warn(
      'SignalRService: Connect response missing peer — cannot route',
    );
    return null;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sending Messages
  // ═══════════════════════════════════════════════════════════════════════════

  /// Per-session gates that block low-priority sends (ICE trickle) while a
  /// high-priority send (SDP answer) is in-flight for the SAME session.
  /// This prevents the WebSocket invoke queue from delaying critical answer
  /// messages behind dozens of fire-and-forget ICE candidate sends.
  final Map<String, Completer<void>> _answerGates = {};

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
  ///
  /// Returns false if the connection is not ready or the send fails.
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

    // Open a per-session gate — ICE trickle sends for this session
    // will wait until this answer completes.
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
      // Release the gate so buffered ICE trickle sends can proceed.
      final gate = _answerGates.remove(sessionId);
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
      // Wait for any in-flight answer send for THIS session to complete.
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

    _players.add(player);
    _playersByDevice[player.deviceId] = player;
    Logger().info(
      'SignalRService: Registered player. Total: ${_players.length}',
    );
  }

  /// Unregister a player.
  void unregisterPlayer(VideoWebRTCPlayer player) {
    _players.removeWhere((p) => p.playerId == player.playerId);
    _playersByDevice.remove(player.deviceId);
    if (player.sessionId != null) {
      _playersBySession.remove(player.sessionId);
      // Release any pending answer gate — the session is dead, so any
      // ICE trickle sends awaiting the gate should unblock and fail gracefully.
      final gate = _answerGates.remove(player.sessionId);
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    Logger().info(
      'SignalRService: Unregistered player. Remaining: ${_players.length}',
    );
  }

  /// Update the session index after the message router assigns a sessionId.
  ///
  /// Called by [SignalRMessageRouter._handleConnectResponse] so the
  /// [findPlayerBySession] lookup stays O(1).
  void updateSessionIndex(String sessionId, VideoWebRTCPlayer player) {
    _playersBySession[sessionId] = player;
  }

  /// Find a player by session ID (O(1) indexed lookup).
  VideoWebRTCPlayer? findPlayerBySession(String sessionId) =>
      _playersBySession[sessionId];

  /// Find a player by device ID.
  VideoWebRTCPlayer? findPlayerByDevice(String deviceId) =>
      _playersByDevice[deviceId];

  // ═══════════════════════════════════════════════════════════════════════════
  // Cleanup
  // ═══════════════════════════════════════════════════════════════════════════

  /// Close the SignalR connection.
  Future<void> closeConnection({bool closeAllSessions = false}) async {
    Logger().info('SignalRService: Closing connection');

    if (closeAllSessions) {
      _players.clear();
      _playersByDevice.clear();
      _playersBySession.clear();
      _messageRouter = null;
    }

    await _connectionManager?.dispose();
    // Always null out the disposed manager — calling methods on a disposed
    // manager silently suppresses reconnect. Recreated by initService().
    _connectionManager = null;
    // Always reset so initService() recreates everything cleanly.
    _serviceInitialized = false;
    // Unblock any callers stuck on `await ready` — they'll hit their
    // catch block and clean up via the finally-block.
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.completeError(
        StateError('SignalR service closed while waiting for connection'),
      );
    }
    // Reset the readiness signal so callers that queue up during restart
    // properly wait for the next connection.
    _readyCompleter = Completer<void>();
  }
}
