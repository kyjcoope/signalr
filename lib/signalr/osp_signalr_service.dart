import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:math' as math;

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr_netcore/http_connection_options.dart';
import 'package:signalr_netcore/hub_connection.dart';
import 'package:signalr_netcore/hub_connection_builder.dart';

import '../webrtc/osp_webrtc_player.dart';
import '../webrtc/signaling_message.dart';
import 'osp_signalr_config.dart';
import 'signalr_message.dart';

/// JSON-RPC version used in all messages.
const String jsonRpcVersion = '2.0';

/// Singleton SignalR service for WebRTC signaling.
///
/// Matches the web's `OSPVideoWebRTCSignalRService` pattern.
/// Uses a singleton pattern and player registration for message routing.
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
  // Configuration & State
  // ═══════════════════════════════════════════════════════════════════════════

  OSPSignalRConfig? _config;
  HubConnection? _connection;

  bool _serviceInitialized = false;
  bool _peerReady = false;
  bool _isConnecting = false;
  int _signalRRetry = 0;

  String _clientName = '';
  String _signalRUrl = '';
  String _channelId = '';
  String _signalRClientId = '';

  /// ICE server configuration received from the signaling server.
  List<IceServer> iceServers = [];

  // ═══════════════════════════════════════════════════════════════════════════
  // Timers
  // ═══════════════════════════════════════════════════════════════════════════

  Timer? _connectTimeout;
  Timer? _retryTimer;
  static const int _timeoutValue = 15000; // 15 seconds

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
  bool get isPeerReady => _peerReady;

  /// The channel ID (server URL).
  String get channelId => _channelId;

  /// The SignalR client ID assigned by the server.
  String get signalRClientId => _signalRClientId;

  /// The client name.
  String get clientName => _clientName;

  /// Configuration object.
  OSPSignalRConfig? get config => _config;

  /// Connection state.
  HubConnectionState? get connectionState => _connection?.state;

  // ═══════════════════════════════════════════════════════════════════════════
  // Initialization
  // ═══════════════════════════════════════════════════════════════════════════

  /// Initialize the SignalR service.
  ///
  /// Matches the web's `initService` method.
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
    _clientName = _config!.clientId;
    _signalRUrl = _config!.signalRServerUrl;
    _serviceInitialized = true;

    _createConnection();
    await _startSignalRConnection();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection Management
  // ═══════════════════════════════════════════════════════════════════════════

  /// Create the SignalR hub connection.
  void _createConnection() {
    dev.log('OSPSignalRService: createConnection');

    try {
      if (_connection != null) return;

      _connection = HubConnectionBuilder()
          .withUrl(
            _config!.signalRServerUrl,
            options: HttpConnectionOptions(skipNegotiation: false),
          )
          .withAutomaticReconnect(
            retryDelays: [
              0,
              _config!.reconnectionTimeout,
              _config!.reconnectionTimeout,
              _config!.reconnectionTimeout,
            ],
          )
          .build();

      _bindEventHandlers();
    } catch (error) {
      dev.log('OSPSignalRService: createConnection: Error: $error');
    }
  }

  /// Start the SignalR connection.
  Future<void> _startSignalRConnection() async {
    dev.log('OSPSignalRService: startSignalRConnection');
    _clearConnectTimeout();

    if (_connection == null) {
      dev.log('OSPSignalRService: startSignalRConnection: Connection is null!');
      if (_signalRRetry >= _config!.reconnectionRetryCount) {
        await closeConnection(closeAllSessions: true);
        dev.log(
          'OSPSignalRService: startSignalRConnection: '
          'Connection not established after $_signalRRetry attempts, giving up!',
        );
        return;
      }
      _signalRRetry++;
      _retryTimer = Timer(
        const Duration(milliseconds: 50),
        _startSignalRConnection,
      );
      return;
    }

    if (_connection!.state == HubConnectionState.Connected) {
      dev.log('OSPSignalRService: startSignalRConnection: Already connected');
      _peerReady = true;
      _signalRRetry = 0;
      _notifyPlayers(OSPSignalRMessageType.onSignalReady, {});
      // Send register message
      Timer(Duration.zero, _getRegisterSessions);
      return;
    }

    if (_connection!.state == HubConnectionState.Connecting) {
      dev.log(
        'OSPSignalRService: startSignalRConnection: Already connecting...',
      );
      return;
    }

    try {
      _isConnecting = true;
      _setConnectTimeout();
      await _connection!.start();

      dev.log(
        'OSPSignalRService: SignalR Connected: ${_connection!.connectionId}',
      );
      _signalRRetry = 0;
      _peerReady = true;
      _isConnecting = false;
      _clearConnectTimeout();

      _notifyPlayers(OSPSignalRMessageType.onSignalReady, {});
      Timer(Duration.zero, _getRegisterSessions);
    } catch (error) {
      dev.log('OSPSignalRService: startSignalRConnection: Error: $error');
      _peerReady = false;
      _isConnecting = false;
      _signalRRetry++;

      if (_signalRRetry < _config!.reconnectionRetryCount) {
        final delay =
            _config!.reconnectionTimeout * math.pow(2, _signalRRetry).toInt();
        dev.log(
          'OSPSignalRService: Retrying in ${delay}ms (attempt $_signalRRetry)',
        );
        _retryTimer = Timer(
          Duration(milliseconds: delay),
          _startSignalRConnection,
        );
      } else {
        dev.log('OSPSignalRService: Max retries reached, giving up');
        _notifyPlayers(OSPSignalRMessageType.onSignalTimeout, {});
      }
    }
  }

  /// Close the SignalR connection.
  Future<void> closeConnection({bool closeAllSessions = false}) async {
    dev.log(
      'OSPSignalRService: closeConnection: closeAllSessions=$closeAllSessions',
    );

    if (closeAllSessions) {
      _clearConnectTimeout();
      _closeAllConsumerSessions();
      _unbindEventHandlers();
      _serviceInitialized = false;
      _peerReady = false;
      _signalRRetry = 0;
      _isConnecting = false;
    }

    if (_connection != null &&
        _connection!.state == HubConnectionState.Connected) {
      try {
        await _connection!.stop();
        dev.log('OSPSignalRService: Connection stopped');
      } catch (e) {
        dev.log('OSPSignalRService: Error stopping connection: $e');
      }
    }

    if (closeAllSessions) {
      _connection = null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Event Handler Binding (matches web pattern)
  // ═══════════════════════════════════════════════════════════════════════════

  void _bindEventHandlers() {
    dev.log('OSPSignalRService: bindEventHandlers');

    if (_connection == null) return;

    // Connection lifecycle callbacks
    _connection!.onclose(_onClose);
    _connection!.onreconnecting(_onReconnecting);
    _connection!.onreconnected(_onReconnected);

    // SignalR event handlers
    _connection!.on('register', _onDeviceSessionInfo);
    _connection!.on('devicedisconnected', _onDeviceDisconnected);
    _connection!.on('peerdisconnected', _onPeerDisconnected);
    _connection!.on('error', _onErrorHandler);
    _connection!.on('ReceivedSignalingMessage', _handleSignalRMessage);
  }

  void _unbindEventHandlers() {
    dev.log('OSPSignalRService: unbindEventHandlers');

    if (_connection == null) return;

    _connection!.off('register');
    _connection!.off('devicedisconnected');
    _connection!.off('peerdisconnected');
    _connection!.off('error');
    _connection!.off('ReceivedSignalingMessage');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection Event Handlers
  // ═══════════════════════════════════════════════════════════════════════════

  void _onClose({Exception? error}) {
    dev.log('OSPSignalRService: onClose: $error');
    _peerReady = false;
    _notifyPlayers(OSPSignalRMessageType.onSignalClosed, {
      'error': error?.toString(),
    });
  }

  void _onReconnecting({Exception? error}) {
    dev.log('OSPSignalRService: onReconnecting: $error');
    _peerReady = false;
  }

  void _onReconnected({String? connectionId}) {
    dev.log('OSPSignalRService: onReconnected: $connectionId');
    _peerReady = true;
    _signalRRetry = 0;
    _notifyPlayers(OSPSignalRMessageType.onSignalReady, {});
  }

  void _onDeviceSessionInfo(List<Object?>? args) {
    dev.log('OSPSignalRService: onDeviceSessionInfo: $args');
  }

  void _onDeviceDisconnected(List<Object?>? args) {
    dev.log('OSPSignalRService: onDeviceDisconnected: $args');
  }

  void _onPeerDisconnected(List<Object?>? args) {
    dev.log('OSPSignalRService: onPeerDisconnected: $args');
    if (args != null && args.isNotEmpty) {
      final session = args[0]?.toString();
      if (session != null) {
        final player = findPlayerBySession(session);
        if (player != null) {
          player.onSignalRMessage(
            OSPSignalRMessage(
              method: OSPSignalRMessageType.onSignalClosed,
              detail: {'session': session},
            ),
          );
        }
      }
    }
  }

  void _onErrorHandler(List<Object?>? args) {
    dev.log('OSPSignalRService: onError: $args');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Timeout Management
  // ═══════════════════════════════════════════════════════════════════════════

  void _setConnectTimeout() {
    dev.log('OSPSignalRService: setConnectTimeout');
    _clearConnectTimeout();
    _connectTimeout = Timer(
      Duration(milliseconds: _timeoutValue),
      _onTimeoutHandler,
    );
  }

  void _clearConnectTimeout() {
    _connectTimeout?.cancel();
    _connectTimeout = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _onTimeoutHandler() {
    dev.log('OSPSignalRService: onTimeoutHandler');
    _clearConnectTimeout();
    _notifyPlayers(OSPSignalRMessageType.onSignalTimeout, {});
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Message Handling
  // ═══════════════════════════════════════════════════════════════════════════

  /// Handle incoming SignalR messages.
  ///
  /// Matches the web's `handleSignalRMessage` method.
  void _handleSignalRMessage(List<Object?>? args) {
    if (args == null || args.isEmpty) return;

    final messageStr = args[0]?.toString();
    if (messageStr == null) return;

    dev.log('OSPSignalRService: handleSignalRMessage: $messageStr');

    try {
      final parsed = jsonDecode(messageStr) as Map<String, dynamic>;

      // Handle method-based messages
      if (parsed.containsKey('method')) {
        final method = parsed['method'] as String?;
        switch (method) {
          case 'invite':
            _onInvite(parsed);
            break;
          case 'trickle':
            _onTrickle(parsed);
            break;
          case 'error':
            _onError(parsed);
            break;
          default:
            dev.log('OSPSignalRService: Unknown method: $method');
        }
      }
      // Handle response messages (with id but no method)
      else if (parsed.containsKey('id')) {
        _handleResponseMessage(parsed);
      }
    } catch (e) {
      dev.log('OSPSignalRService: Error parsing message: $e');
    }
  }

  void _handleResponseMessage(Map<String, dynamic> parsed) {
    final id = parsed['id']?.toString();
    dev.log('OSPSignalRService: handleResponseMessage: id=$id');

    switch (id) {
      case '1':
        // Register response
        if (parsed['result'] != null && parsed['result']['id'] != null) {
          _signalRClientId = parsed['result']['id'].toString();
          dev.log(
            'OSPSignalRService: Client registered with ID: $_signalRClientId',
          );
        }
        break;
      case '2':
        // Connect response - contains session and ICE servers
        _handleConnectResponse(parsed);
        break;
      default:
        dev.log('OSPSignalRService: Unknown response id: $id');
    }
  }

  void _handleConnectResponse(Map<String, dynamic> parsed) {
    dev.log('OSPSignalRService: handleConnectResponse');

    final result = parsed['result'] as Map<String, dynamic>?;
    if (result == null) return;

    final session = result['session'] as String?;
    final peer = result['peer'] as String?;

    // Parse ICE servers
    if (result['iceServers'] != null) {
      final iceList = result['iceServers'] as List;
      iceServers = iceList.map((e) => IceServer.fromJson(e)).toList();
      dev.log('OSPSignalRService: Received ${iceServers.length} ICE servers');
    }

    // Find the player waiting for this connection
    OSPVideoWebRTCPlayer? player;
    if (peer != null) {
      player = findPlayerByDevice(peer);
    }
    if (player == null) {
      // Find any player without a session
      player = _players.where((p) => p.sessionId == null).firstOrNull;
    }

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

  void _onInvite(Map<String, dynamic> message) {
    final params = message['params'] as Map<String, dynamic>?;
    if (params == null) return;

    final session = params['session'] as String?;
    if (session == null) {
      dev.log('OSPSignalRService: onInvite: No session in message');
      return;
    }

    dev.log('OSPSignalRService: onInvite: session=$session');

    final player = findPlayerBySession(session);
    if (player != null) {
      player.onSignalRMessage(
        OSPSignalRMessage(
          method: OSPSignalRMessageType.onSignalInvite,
          detail: message,
        ),
      );
    } else {
      dev.log(
        'OSPSignalRService: onInvite: No player found for session: $session',
      );
    }
  }

  void _onTrickle(Map<String, dynamic> message) {
    final params = message['params'] as Map<String, dynamic>?;
    if (params == null) return;

    final session = params['session'] as String?;
    if (session == null) {
      dev.log('OSPSignalRService: onTrickle: No session in message');
      return;
    }

    dev.log('OSPSignalRService: onTrickle: session=$session');

    final player = findPlayerBySession(session);
    if (player != null) {
      player.onSignalRMessage(
        OSPSignalRMessage(
          method: OSPSignalRMessageType.onSignalTrickle,
          detail: {'session': session, 'candidate': params['candidate']},
        ),
      );
    } else {
      dev.log(
        'OSPSignalRService: onTrickle: No player found for session: $session',
      );
    }
  }

  void _onError(Map<String, dynamic> message) {
    dev.log('OSPSignalRService: onError: $message');
    final params = message['params'] as Map<String, dynamic>?;
    final session = params?['session'] as String?;

    if (session != null) {
      final player = findPlayerBySession(session);
      player?.onSignalRMessage(
        OSPSignalRMessage(
          method: OSPSignalRMessageType.onSignalError,
          detail: message,
        ),
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sending Messages
  // ═══════════════════════════════════════════════════════════════════════════

  /// Send a message to the SignalR server.
  Future<void> sendMessage(Map<String, dynamic> data) async {
    dev.log('OSPSignalRService: sendMessage: ${jsonEncode(data)}');

    if (_connection == null ||
        _connection!.state != HubConnectionState.Connected) {
      dev.log('OSPSignalRService: sendMessage: Not connected!');
      return;
    }

    try {
      await _connection!.invoke('SendMessage', args: [data]);
    } catch (e) {
      dev.log('OSPSignalRService: sendMessage error: $e');
    }
  }

  /// Send a register request.
  Future<void> _getRegisterSessions() async {
    dev.log('OSPSignalRService: getRegisterSessions');

    if (_connection == null ||
        _connection!.state != HubConnectionState.Connected) {
      return;
    }

    final data = requestPayload('register', {'authorization': ''}, '1');
    await sendMessage(data);
  }

  /// Connect to a consumer session (camera).
  Future<void> connectConsumerSession(String deviceId) async {
    dev.log('OSPSignalRService: connectConsumerSession: $deviceId');

    if (_connection == null ||
        _connection!.state != HubConnectionState.Connected) {
      dev.log('OSPSignalRService: connectConsumerSession: Not connected!');
      return;
    }

    final data = requestPayload('connect', {
      'authorization': '',
      'peer': deviceId,
      'profile': '',
    }, '2');

    await sendMessage(data);
  }

  /// Send an invite answer (SDP answer).
  Future<bool> sendSignalInviteMessage(
    String sessionId,
    SdpWrapper sdp,
    String messageId,
  ) async {
    dev.log('OSPSignalRService: sendSignalInviteMessage: session=$sessionId');

    if (_connection == null ||
        _connection!.state != HubConnectionState.Connected) {
      dev.log('OSPSignalRService: sendSignalInviteMessage: Not connected!');
      return false;
    }

    try {
      final data = <String, dynamic>{
        'jsonrpc': jsonRpcVersion,
        'result': {'session': sessionId, 'answer': sdp.toJson()},
        'id': messageId,
      };

      await _connection!.invoke('SendMessage', args: [data]);
      dev.log('OSPSignalRService: sendSignalInviteMessage: sent');
      return true;
    } catch (e) {
      dev.log('OSPSignalRService: sendSignalInviteMessage error: $e');
      return false;
    }
  }

  /// Send a trickle ICE candidate.
  Future<bool> sendSignalTrickleMessage(
    String sessionId,
    RTCIceCandidate candidate,
  ) async {
    dev.log('OSPSignalRService: sendSignalTrickleMessage: session=$sessionId');

    if (_connection == null ||
        _connection!.state != HubConnectionState.Connected) {
      dev.log('OSPSignalRService: sendSignalTrickleMessage: Not connected!');
      return false;
    }

    try {
      final data = <String, dynamic>{
        'jsonrpc': jsonRpcVersion,
        'method': 'trickle',
        'params': {
          'session': sessionId,
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        },
      };

      await _connection!.invoke('SendMessage', args: [data]);
      return true;
    } catch (e) {
      dev.log('OSPSignalRService: sendSignalTrickleMessage error: $e');
      return false;
    }
  }

  /// Send a close/error message.
  void sendCloseMessage(String producerId, String sessionId) {
    dev.log(
      'OSPSignalRService: sendCloseMessage: producer=$producerId session=$sessionId',
    );

    final data = requestPayload('error', {
      'code': 1002,
      'message': 'WebClient $producerId has closed its connection.',
      'session': sessionId,
    }, '');

    sendMessage(data);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Player Management
  // ═══════════════════════════════════════════════════════════════════════════

  /// Register a player to receive SignalR messages.
  void registerPlayer(OSPVideoWebRTCPlayer player) {
    dev.log('OSPSignalRService: registerPlayer: ${player.playerId}');

    final existing = _players
        .where((p) => p.playerId == player.playerId)
        .firstOrNull;
    if (existing != null) {
      dev.log(
        'OSPSignalRService: Player ${player.playerId} already registered',
      );
      return;
    }

    // Subscribe to message stream
    player.subscription = _messageController.stream.listen(
      player.onSignalRMessage,
    );
    _players.add(player);

    dev.log(
      'OSPSignalRService: Player registered. Total players: ${_players.length}',
    );
  }

  /// Unregister a player.
  void unregisterPlayer(OSPVideoWebRTCPlayer player) {
    dev.log('OSPSignalRService: unregisterPlayer: ${player.playerId}');

    player.subscription?.cancel();
    player.subscription = null;
    _players.removeWhere((p) => p.playerId == player.playerId);

    dev.log(
      'OSPSignalRService: Player unregistered. Remaining: ${_players.length}',
    );
  }

  /// Check if a player is registered.
  bool isPlayerRegistered(OSPVideoWebRTCPlayer player) {
    return _players.any((p) => p.playerId == player.playerId);
  }

  /// Find a player by session ID.
  OSPVideoWebRTCPlayer? findPlayerBySession(String sessionId) {
    return _players.where((p) => p.sessionId == sessionId).firstOrNull;
  }

  /// Find a player by device ID.
  OSPVideoWebRTCPlayer? findPlayerByDevice(String deviceId) {
    return _players.where((p) => p.deviceId == deviceId).firstOrNull;
  }

  /// Notify all players of an event.
  void _notifyPlayers(OSPSignalRMessageType type, dynamic detail) {
    dev.log('OSPSignalRService: notifyPlayers: $type');
    final message = OSPSignalRMessage(method: type, detail: detail);
    _messageController.add(message);
  }

  void _closeAllConsumerSessions() {
    dev.log('OSPSignalRService: closeAllConsumerSessions');
    for (final player in _players) {
      player.subscription?.cancel();
    }
    _players.clear();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Payload Builders
  // ═══════════════════════════════════════════════════════════════════════════

  /// Build a JSON-RPC request payload.
  Map<String, dynamic> requestPayload(
    String method,
    Map<String, dynamic> params,
    String id,
  ) {
    return {
      'jsonrpc': jsonRpcVersion,
      'method': method,
      'params': params,
      'id': id,
    };
  }

  /// Build a JSON-RPC notification payload (no id).
  Map<String, dynamic> notificationPayload(
    String method,
    Map<String, dynamic> params,
  ) {
    return {'jsonrpc': jsonRpcVersion, 'method': method, 'params': params};
  }
}
