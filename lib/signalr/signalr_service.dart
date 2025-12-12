import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../webrtc/webrtc_player.dart';
import '../webrtc/signaling_message.dart';
import 'json_rpc.dart';
import 'signalr_config.dart';
import 'signalr_connection_manager.dart';

/// ICE server configuration from the signaling server.
class IceServer {
  IceServer({required this.urls, this.credential, this.username});

  factory IceServer.fromJson(dynamic json) => IceServer(
    urls: (json['urls'] as List?)?.map((r) => r.toString()).toList() ?? [],
    credential: json['credential'] as String?,
    username: json['username'] as String?,
  );

  final List<String> urls;
  final String? credential;
  final String? username;

  Map<String, Object?> toJson() => {
    'urls': urls,
    if (credential != null) 'credential': credential,
    if (username != null) 'username': username,
  };
}

/// Singleton SignalR service for WebRTC signaling.
///
/// Provides a high-level API for WebRTC signaling operations,
/// delegating connection management to [SignalRConnectionManager].
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
  SignalRConfig? _config;
  bool _serviceInitialized = false;
  String _signalRClientId = '';

  /// ICE server configuration received from the signaling server.
  List<IceServer> iceServers = [];

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
    dev.log('SignalRService: initService: $signalRServerUrl');

    if (signalRServerUrl.isEmpty) {
      dev.log('SignalRService: initService: SignalR Server URL is empty!');
      return;
    }

    if (_serviceInitialized) {
      dev.log('SignalRService: initService: Service already initialized!');
      return;
    }

    _config = SignalRConfig(signalRServerUrl: signalRServerUrl);

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
    final connected = await _connectionManager!.connect();
    if (connected) {
      _bindMessageHandlers();
      await _sendRegisterRequest();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection Lifecycle Callbacks
  // ═══════════════════════════════════════════════════════════════════════════

  void _onConnected() {
    dev.log('SignalRService: Connected');
    _notifyPlayers(SignalRMessageType.onSignalReady, {});
  }

  void _onDisconnected(Exception? error) {
    dev.log('SignalRService: Disconnected: $error');
    _notifyPlayers(SignalRMessageType.onSignalClosed, {
      'error': error?.toString(),
    });
  }

  void _onReconnecting(Exception? error) {
    dev.log('SignalRService: Reconnecting: $error');
  }

  void _onReconnected(String? connectionId) {
    dev.log('SignalRService: Reconnected: $connectionId');
    _notifyPlayers(SignalRMessageType.onSignalReady, {});
    _sendRegisterRequest();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Message Handlers
  // ═══════════════════════════════════════════════════════════════════════════

  void _bindMessageHandlers() {
    _connectionManager?.on('ReceivedSignalingMessage', _handleSignalRMessage);
    _connectionManager?.on('register', _handleDeviceSessionInfo);
    _connectionManager?.on('devicedisconnected', _handleDeviceDisconnected);
    _connectionManager?.on('peerdisconnected', _handlePeerDisconnected);
    _connectionManager?.on('error', _handleError);
  }

  void _handleSignalRMessage(List<Object?>? args) {
    if (args == null || args.isEmpty) return;

    final messageStr = args[0]?.toString();
    if (messageStr == null) return;

    dev.log('SignalRService: Received: $messageStr');

    try {
      final parsed = jsonDecode(messageStr) as Map<String, dynamic>;

      if (parsed.isRequest) {
        _handleRequestMessage(parsed);
      } else if (parsed.isResponse) {
        _handleResponseMessage(parsed);
      }
    } catch (e) {
      dev.log('SignalRService: Parse error: $e');
    }
  }

  void _handleRequestMessage(Map<String, dynamic> message) {
    switch (message.method) {
      case 'invite':
        _handleInvite(message);
      case 'trickle':
        _handleTrickle(message);
      case 'error':
        _handleSignalError(message);
      default:
        dev.log('SignalRService: Unknown method: ${message.method}');
    }
  }

  void _handleResponseMessage(Map<String, dynamic> message) {
    switch (message.id) {
      case '1': // Register response
        _handleRegisterResponse(message);
      case '2': // Connect response
        _handleConnectResponse(message);
      default:
        dev.log('SignalRService: Unknown response id: ${message.id}');
    }
  }

  void _handleRegisterResponse(Map<String, dynamic> message) {
    final id = message.resultValue<String>('id');
    if (id != null) {
      _signalRClientId = id;
      dev.log('SignalRService: Registered with client ID: $id');
    }
  }

  void _handleConnectResponse(Map<String, dynamic> message) {
    final result = message.result;
    if (result == null) return;

    final session = result['session'] as String?;
    final peer = result['peer'] as String?;

    // Parse ICE servers
    final iceList = result['iceServers'] as List?;
    if (iceList != null) {
      iceServers = iceList.map((e) => IceServer.fromJson(e)).toList();
      dev.log('SignalRService: Received ${iceServers.length} ICE servers');
    }

    // Find and notify the player
    final player = _findPlayerForConnection(peer);
    if (player != null && session != null) {
      player.sessionId = session;
      player.onSignalRMessage(
        SignalRMessage(
          method: SignalRMessageType.onSignalIceServers,
          detail: {
            'session': session,
            'iceServers': iceServers.map((e) => e.toJson()).toList(),
          },
        ),
      );
    }
  }

  VideoWebRTCPlayer? _findPlayerForConnection(String? peer) {
    if (peer != null) {
      final player = findPlayerByDevice(peer);
      if (player != null) return player;
    }
    return _players.where((p) => p.sessionId == null).firstOrNull;
  }

  void _handleInvite(Map<String, dynamic> message) {
    final session = message.param<String>('session');
    if (session == null) return;

    dev.log('SignalRService: Invite for session: $session');
    findPlayerBySession(session)?.onSignalRMessage(
      SignalRMessage(
        method: SignalRMessageType.onSignalInvite,
        detail: message,
      ),
    );
  }

  void _handleTrickle(Map<String, dynamic> message) {
    final session = message.param<String>('session');
    if (session == null) return;

    dev.log('SignalRService: Trickle for session: $session');
    findPlayerBySession(session)?.onSignalRMessage(
      SignalRMessage(
        method: SignalRMessageType.onSignalTrickle,
        detail: {
          'session': session,
          'candidate': message.param<Map<String, dynamic>>('candidate'),
        },
      ),
    );
  }

  void _handleSignalError(Map<String, dynamic> message) {
    final session = message.param<String>('session');
    if (session != null) {
      findPlayerBySession(session)?.onSignalRMessage(
        SignalRMessage(
          method: SignalRMessageType.onSignalError,
          detail: message,
        ),
      );
    }
  }

  void _handleDeviceSessionInfo(List<Object?>? args) {
    dev.log('SignalRService: Device session info: $args');
  }

  void _handleDeviceDisconnected(List<Object?>? args) {
    dev.log('SignalRService: Device disconnected: $args');
    // Notify all players that a device has disconnected
    // The device ID is typically passed as the first argument
    final deviceId = args?.firstOrNull?.toString();
    if (deviceId != null) {
      final player = findPlayerByDevice(deviceId);
      if (player != null) {
        player.onSignalRMessage(
          SignalRMessage(
            method: SignalRMessageType.onSignalClosed,
            detail: {'device': deviceId, 'reason': 'device_disconnected'},
          ),
        );
      }
    }
  }

  void _handlePeerDisconnected(List<Object?>? args) {
    dev.log('SignalRService: Peer disconnected: $args');
    final session = args?.firstOrNull?.toString();
    if (session != null) {
      final player = findPlayerBySession(session);
      if (player != null) {
        dev.log('SignalRService: Notifying player of peer disconnection');
        player.onSignalRMessage(
          SignalRMessage(
            method: SignalRMessageType.onSignalClosed,
            detail: {'session': session, 'reason': 'peer_disconnected'},
          ),
        );
      }
    }
  }

  void _handleError(List<Object?>? args) {
    dev.log('SignalRService: Error: $args');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sending Messages
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _sendMessage(Map<String, dynamic> data) async {
    if (!isPeerReady) {
      dev.log('SignalRService: Cannot send - not connected');
      return;
    }

    try {
      await _connectionManager?.invoke('SendMessage', args: [data]);
    } catch (e) {
      dev.log('SignalRService: Send error: $e');
    }
  }

  Future<void> _sendRegisterRequest() async {
    final message = JsonRpc.request(
      method: 'register',
      id: '1',
      params: {'authorization': ''},
    );
    await _sendMessage(message);
  }

  /// Connect to a camera device.
  Future<void> connectConsumerSession(String deviceId) async {
    dev.log('SignalRService: Connecting to device: $deviceId');

    final message = JsonRpc.request(
      method: 'connect',
      id: '2',
      params: {'authorization': '', 'peer': deviceId, 'profile': ''},
    );
    await _sendMessage(message);
  }

  /// Send an SDP answer for an invite.
  Future<bool> sendSignalInviteMessage(
    String sessionId,
    SdpWrapper sdp,
    String messageId,
  ) async {
    dev.log('SignalRService: Sending invite answer for session: $sessionId');

    if (!isPeerReady) return false;

    try {
      final message = JsonRpc.response(
        id: messageId,
        result: {'session': sessionId, 'answer': sdp.toJson()},
      );
      await _connectionManager?.invoke('SendMessage', args: [message]);
      return true;
    } catch (e) {
      dev.log('SignalRService: Send invite error: $e');
      return false;
    }
  }

  /// Send an ICE candidate.
  Future<bool> sendSignalTrickleMessage(
    String sessionId,
    RTCIceCandidate candidate,
  ) async {
    if (!isPeerReady) return false;

    try {
      final message = JsonRpc.notification(
        method: 'trickle',
        params: {
          'session': sessionId,
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        },
      );
      await _connectionManager?.invoke('SendMessage', args: [message]);
      return true;
    } catch (e) {
      dev.log('SignalRService: Send trickle error: $e');
      return false;
    }
  }

  /// Send an ICE restart offer.
  ///
  /// This is used when the ICE connection fails and needs to be re-established.
  Future<bool> sendIceRestartOffer(String sessionId, SdpWrapper offer) async {
    dev.log(
      'SignalRService: Sending ICE restart offer for session: $sessionId',
    );

    if (!isPeerReady) return false;

    try {
      final message = JsonRpc.notification(
        method: 'restart',
        params: {'session': sessionId, 'offer': offer.toJson()},
      );
      await _connectionManager?.invoke('SendMessage', args: [message]);
      return true;
    } catch (e) {
      dev.log('SignalRService: Send ICE restart error: $e');
      return false;
    }
  }

  /// Send a close message to the signaling server.
  ///
  /// Notifies the server that the client is intentionally closing the session.
  /// This matches the web UI behavior for clean disconnection.
  Future<void> sendCloseMessage(String sessionId, String deviceId) async {
    dev.log('SignalRService: Sending close message for session: $sessionId');

    if (!isPeerReady) return;

    try {
      final message = JsonRpc.notification(
        method: 'error',
        params: {
          'code': 1002,
          'message':
              'Client $deviceId has closed its connection with the Signaling Server.',
          'session': sessionId,
        },
      );
      await _connectionManager?.invoke('SendMessage', args: [message]);
    } catch (e) {
      dev.log('SignalRService: Send close message error: $e');
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
      dev.log('SignalRService: Player ${player.playerId} already registered');
      return;
    }

    player.subscription = _messageController.stream.listen(
      player.onSignalRMessage,
    );
    _players.add(player);
    dev.log('SignalRService: Registered player. Total: ${_players.length}');
  }

  /// Unregister a player.
  void unregisterPlayer(VideoWebRTCPlayer player) {
    player.subscription?.cancel();
    player.subscription = null;
    _players.removeWhere((p) => p.playerId == player.playerId);
    dev.log(
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
    dev.log('SignalRService: Closing connection');

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
    }
  }
}
