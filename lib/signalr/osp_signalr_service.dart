import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../webrtc/osp_webrtc_player.dart';
import '../webrtc/signaling_message.dart';
import 'json_rpc.dart';
import 'osp_signalr_config.dart';
import 'signalr_connection_manager.dart';
import 'signalr_message.dart';

/// Singleton SignalR service for WebRTC signaling.
///
/// Provides a high-level API for WebRTC signaling operations,
/// delegating connection management to [SignalRConnectionManager].
class OSPSignalRService {
  OSPSignalRService._()
    : _messageController = StreamController<OSPSignalRMessage>.broadcast();

  // ═══════════════════════════════════════════════════════════════════════════
  // Singleton
  // ═══════════════════════════════════════════════════════════════════════════

  static OSPSignalRService? _instance;

  /// Get the singleton instance.
  static OSPSignalRService get instance => _instance ??= OSPSignalRService._();

  /// Reset the singleton (for testing or full cleanup).
  static void resetInstance() {
    _instance?.closeConnection(closeAllSessions: true);
    _instance = null;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // State
  // ═══════════════════════════════════════════════════════════════════════════

  SignalRConnectionManager? _connectionManager;
  OSPSignalRConfig? _config;
  bool _serviceInitialized = false;
  String _signalRClientId = '';

  /// ICE server configuration received from the signaling server.
  List<IceServer> iceServers = [];

  // ═══════════════════════════════════════════════════════════════════════════
  // Players & Messaging
  // ═══════════════════════════════════════════════════════════════════════════

  final List<OSPVideoWebRTCPlayer> _players = [];
  final StreamController<OSPSignalRMessage> _messageController;

  /// Stream of SignalR messages for players to subscribe to.
  Stream<OSPSignalRMessage> get messageStream => _messageController.stream;

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
  OSPSignalRConfig? get config => _config;

  // ═══════════════════════════════════════════════════════════════════════════
  // Initialization
  // ═══════════════════════════════════════════════════════════════════════════

  /// Initialize the SignalR service.
  Future<void> initService(String signalRServerUrl) async {
    dev.log('OSPSignalRService: initService: $signalRServerUrl');

    if (signalRServerUrl.isEmpty) {
      dev.log('OSPSignalRService: initService: SignalR Server URL is empty!');
      return;
    }

    if (_serviceInitialized) {
      dev.log('OSPSignalRService: initService: Service already initialized!');
      return;
    }

    _config = OSPSignalRConfig(signalRServerUrl: signalRServerUrl);

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
    dev.log('OSPSignalRService: Connected');
    _notifyPlayers(OSPSignalRMessageType.onSignalReady, {});
  }

  void _onDisconnected(Exception? error) {
    dev.log('OSPSignalRService: Disconnected: $error');
    _notifyPlayers(OSPSignalRMessageType.onSignalClosed, {
      'error': error?.toString(),
    });
  }

  void _onReconnecting(Exception? error) {
    dev.log('OSPSignalRService: Reconnecting: $error');
  }

  void _onReconnected(String? connectionId) {
    dev.log('OSPSignalRService: Reconnected: $connectionId');
    _notifyPlayers(OSPSignalRMessageType.onSignalReady, {});
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

    dev.log('OSPSignalRService: Received: $messageStr');

    try {
      final parsed = jsonDecode(messageStr) as Map<String, dynamic>;

      if (parsed.isRequest) {
        _handleRequestMessage(parsed);
      } else if (parsed.isResponse) {
        _handleResponseMessage(parsed);
      }
    } catch (e) {
      dev.log('OSPSignalRService: Parse error: $e');
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
        dev.log('OSPSignalRService: Unknown method: ${message.method}');
    }
  }

  void _handleResponseMessage(Map<String, dynamic> message) {
    switch (message.id) {
      case '1': // Register response
        _handleRegisterResponse(message);
      case '2': // Connect response
        _handleConnectResponse(message);
      default:
        dev.log('OSPSignalRService: Unknown response id: ${message.id}');
    }
  }

  void _handleRegisterResponse(Map<String, dynamic> message) {
    final id = message.resultValue<String>('id');
    if (id != null) {
      _signalRClientId = id;
      dev.log('OSPSignalRService: Registered with client ID: $id');
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
      dev.log('OSPSignalRService: Received ${iceServers.length} ICE servers');
    }

    // Find and notify the player
    final player = _findPlayerForConnection(peer);
    if (player != null && session != null) {
      player.sessionId = session;
      player.onSignalRMessage(
        OSPSignalRMessage(
          method: OSPSignalRMessageType.onSignalIceServers,
          detail: {
            'session': session,
            'iceServers': iceServers.map((e) => e.toJson()).toList(),
          },
        ),
      );
    }
  }

  OSPVideoWebRTCPlayer? _findPlayerForConnection(String? peer) {
    if (peer != null) {
      final player = findPlayerByDevice(peer);
      if (player != null) return player;
    }
    return _players.where((p) => p.sessionId == null).firstOrNull;
  }

  void _handleInvite(Map<String, dynamic> message) {
    final session = message.param<String>('session');
    if (session == null) return;

    dev.log('OSPSignalRService: Invite for session: $session');
    findPlayerBySession(session)?.onSignalRMessage(
      OSPSignalRMessage(
        method: OSPSignalRMessageType.onSignalInvite,
        detail: message,
      ),
    );
  }

  void _handleTrickle(Map<String, dynamic> message) {
    final session = message.param<String>('session');
    if (session == null) return;

    dev.log('OSPSignalRService: Trickle for session: $session');
    findPlayerBySession(session)?.onSignalRMessage(
      OSPSignalRMessage(
        method: OSPSignalRMessageType.onSignalTrickle,
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
        OSPSignalRMessage(
          method: OSPSignalRMessageType.onSignalError,
          detail: message,
        ),
      );
    }
  }

  void _handleDeviceSessionInfo(List<Object?>? args) {
    dev.log('OSPSignalRService: Device session info: $args');
  }

  void _handleDeviceDisconnected(List<Object?>? args) {
    dev.log('OSPSignalRService: Device disconnected: $args');
  }

  void _handlePeerDisconnected(List<Object?>? args) {
    dev.log('OSPSignalRService: Peer disconnected: $args');
    final session = args?.firstOrNull?.toString();
    if (session != null) {
      findPlayerBySession(session)?.onSignalRMessage(
        OSPSignalRMessage(
          method: OSPSignalRMessageType.onSignalClosed,
          detail: {'session': session},
        ),
      );
    }
  }

  void _handleError(List<Object?>? args) {
    dev.log('OSPSignalRService: Error: $args');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sending Messages
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _sendMessage(Map<String, dynamic> data) async {
    if (!isPeerReady) {
      dev.log('OSPSignalRService: Cannot send - not connected');
      return;
    }

    try {
      await _connectionManager?.invoke('SendMessage', args: [data]);
    } catch (e) {
      dev.log('OSPSignalRService: Send error: $e');
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
    dev.log('OSPSignalRService: Connecting to device: $deviceId');

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
    dev.log('OSPSignalRService: Sending invite answer for session: $sessionId');

    if (!isPeerReady) return false;

    try {
      final message = JsonRpc.response(
        id: messageId,
        result: {'session': sessionId, 'answer': sdp.toJson()},
      );
      await _connectionManager?.invoke('SendMessage', args: [message]);
      return true;
    } catch (e) {
      dev.log('OSPSignalRService: Send invite error: $e');
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
      dev.log('OSPSignalRService: Send trickle error: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Player Management
  // ═══════════════════════════════════════════════════════════════════════════

  /// Register a player to receive SignalR messages.
  void registerPlayer(OSPVideoWebRTCPlayer player) {
    if (_players.any((p) => p.playerId == player.playerId)) {
      dev.log(
        'OSPSignalRService: Player ${player.playerId} already registered',
      );
      return;
    }

    player.subscription = _messageController.stream.listen(
      player.onSignalRMessage,
    );
    _players.add(player);
    dev.log('OSPSignalRService: Registered player. Total: ${_players.length}');
  }

  /// Unregister a player.
  void unregisterPlayer(OSPVideoWebRTCPlayer player) {
    player.subscription?.cancel();
    player.subscription = null;
    _players.removeWhere((p) => p.playerId == player.playerId);
    dev.log(
      'OSPSignalRService: Unregistered player. Remaining: ${_players.length}',
    );
  }

  /// Find a player by session ID.
  OSPVideoWebRTCPlayer? findPlayerBySession(String sessionId) =>
      _players.where((p) => p.sessionId == sessionId).firstOrNull;

  /// Find a player by device ID.
  OSPVideoWebRTCPlayer? findPlayerByDevice(String deviceId) =>
      _players.where((p) => p.deviceId == deviceId).firstOrNull;

  void _notifyPlayers(OSPSignalRMessageType type, dynamic detail) {
    _messageController.add(OSPSignalRMessage(method: type, detail: detail));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Cleanup
  // ═══════════════════════════════════════════════════════════════════════════

  /// Close the SignalR connection.
  Future<void> closeConnection({bool closeAllSessions = false}) async {
    dev.log('OSPSignalRService: Closing connection');

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
