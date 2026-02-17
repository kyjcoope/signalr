import 'dart:convert';

import '../webrtc/webrtc_player.dart';
import '../utils/logger.dart';
import 'json_rpc.dart';
import 'signalr_messages.dart';

/// Callback for when ICE servers are received.
typedef IceServersCallback = void Function(List<IceServerConfig> servers);

/// Callback for when a client ID is received.
typedef ClientIdCallback = void Function(String clientId);

/// Routes incoming SignalR messages to the appropriate handlers.
///
/// Extracted from [SignalRService] for better separation of concerns.
/// Handles JSON-RPC message parsing and player notification.
class SignalRMessageRouter {
  SignalRMessageRouter({
    required this.findPlayerBySession,
    required this.findPlayerByDevice,
    required this.findPlayerForConnection,
    this.onIceServers,
    this.onClientId,
  });

  /// Find a player by session ID.
  final VideoWebRTCPlayer? Function(String session) findPlayerBySession;

  /// Find a player by device ID.
  final VideoWebRTCPlayer? Function(String deviceId) findPlayerByDevice;

  /// Find a player for a new connection (by peer or first without session).
  final VideoWebRTCPlayer? Function(String? peer) findPlayerForConnection;

  /// Called when ICE servers are received.
  final IceServersCallback? onIceServers;

  /// Called when client ID is received from registration.
  final ClientIdCallback? onClientId;

  // ═══════════════════════════════════════════════════════════════════════════
  // Hub Method Handlers
  // ═══════════════════════════════════════════════════════════════════════════

  /// Handle incoming SignalR message from hub.
  void handleSignalRMessage(List<Object?>? args) {
    if (args == null || args.isEmpty) return;

    final messageStr = args[0]?.toString();
    if (messageStr == null) return;

    Logger().info('SignalRMessageRouter: Received: $messageStr');

    try {
      final parsed = jsonDecode(messageStr) as Map<String, dynamic>;

      if (parsed.isRequest) {
        _handleRequestMessage(parsed);
      } else if (parsed.isResponse) {
        _handleResponseMessage(parsed);
      }
    } catch (e) {
      Logger().error('SignalRMessageRouter: Parse error: $e');
    }
  }

  /// Handle device session info event.
  void handleDeviceSessionInfo(List<Object?>? args) {
    Logger().info('SignalRMessageRouter: Device session info: $args');
  }

  /// Handle device disconnection event.
  void handleDeviceDisconnected(List<Object?>? args) {
    Logger().info('SignalRMessageRouter: Device disconnected: $args');
    final deviceId = args?.firstOrNull?.toString();
    if (deviceId != null) {
      final player = findPlayerByDevice(deviceId);
      player?.onSignalRMessage(
        SignalRMessage(
          method: SignalRMessageType.onSignalClosed,
          detail: {'device': deviceId, 'reason': 'device_disconnected'},
        ),
      );
    }
  }

  /// Handle peer disconnection event.
  void handlePeerDisconnected(List<Object?>? args) {
    Logger().info('SignalRMessageRouter: Peer disconnected: $args');
    final session = args?.firstOrNull?.toString();
    if (session != null) {
      final player = findPlayerBySession(session);
      if (player != null) {
        Logger().info(
          'SignalRMessageRouter: Notifying player of peer disconnection',
        );
        player.onSignalRMessage(
          SignalRMessage(
            method: SignalRMessageType.onSignalClosed,
            detail: {'session': session, 'reason': 'peer_disconnected'},
          ),
        );
      }
    }
  }

  /// Handle generic error event.
  void handleError(List<Object?>? args) {
    Logger().error('SignalRMessageRouter: Error: $args');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // JSON-RPC Message Routing
  // ═══════════════════════════════════════════════════════════════════════════

  void _handleRequestMessage(Map<String, dynamic> message) {
    switch (message.method) {
      case 'invite':
        _handleInvite(message);
      case 'trickle':
        _handleTrickle(message);
      case 'error':
        _handleSignalError(message);
      default:
        Logger().warn(
          'SignalRMessageRouter: Unknown method: ${message.method}',
        );
    }
  }

  void _handleResponseMessage(Map<String, dynamic> message) {
    switch (message.id) {
      case '1': // Register response
        _handleRegisterResponse(message);
      case '2': // Connect response
        _handleConnectResponse(message);
      default:
        Logger().warn(
          'SignalRMessageRouter: Unknown response id: ${message.id}',
        );
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Response Handlers
  // ═══════════════════════════════════════════════════════════════════════════

  void _handleRegisterResponse(Map<String, dynamic> message) {
    final id = message.resultValue<String>('id');
    if (id != null) {
      Logger().info('SignalRMessageRouter: Registered with client ID: $id');
      onClientId?.call(id);
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
      final servers = iceList.map((e) => IceServerConfig.fromJson(e)).toList();
      Logger().info(
        'SignalRMessageRouter: Received ${servers.length} ICE servers',
      );
      // DEBUG: Log credential details
      for (int i = 0; i < servers.length; i++) {
        final s = servers[i];
        final hasCredentials = s.credential != null && s.username != null;
        Logger().info(
          'SignalRMessageRouter: 🔍 Server[$i] urls=${s.urls.length}, hasCredentials=$hasCredentials',
        );
        if (hasCredentials) {
          Logger().info(
            'SignalRMessageRouter: 🔍   credential=${s.credential?.substring(0, 8)}..., username=${s.username?.substring(0, 10)}...',
          );
        }
      }
      onIceServers?.call(servers);

      // Notify the player
      final player = findPlayerForConnection(peer);
      if (player != null && session != null) {
        player.sessionId = session;
        player.onSignalRMessage(
          SignalRMessage(
            method: SignalRMessageType.onSignalIceServers,
            detail: {
              'session': session,
              'iceServers': servers.map((e) => e.toJson()).toList(),
            },
          ),
        );
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Request Handlers
  // ═══════════════════════════════════════════════════════════════════════════

  void _handleInvite(Map<String, dynamic> message) {
    final session = message.param<String>('session');
    if (session == null) return;

    Logger().info('SignalRMessageRouter: Invite for session: $session');
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

    Logger().info('SignalRMessageRouter: Trickle for session: $session');

    // Support batched candidates (params.candidates: [...])
    final candidatesList = message.param<List<dynamic>>('candidates');
    if (candidatesList != null) {
      Logger().info(
        'SignalRMessageRouter: Received ${candidatesList.length} batched candidates',
      );
      findPlayerBySession(session)?.onSignalRMessage(
        SignalRMessage(
          method: SignalRMessageType.onSignalTrickle,
          detail: {'session': session, 'candidates': candidatesList},
        ),
      );
      return;
    }

    // Single candidate fallback (params.candidate: {...})
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
}
