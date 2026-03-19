import 'dart:convert';

import '../webrtc/webrtc_player.dart';
import '../utils/logger.dart';
import 'json_rpc.dart';
import 'signalr_messages.dart';

typedef IceServersCallback = void Function(List<IceServerConfig> servers);
typedef ClientIdCallback = void Function(String clientId);

class SignalRMessageRouter {
  SignalRMessageRouter({
    required this.findPlayerBySession,
    required this.findPlayerByDevice,
    required this.findPlayerForConnection,
    this.onIceServers,
    this.onClientId,
    this.onSessionAssigned,
  });

  final VideoWebRTCPlayer? Function(String session) findPlayerBySession;
  final VideoWebRTCPlayer? Function(String deviceId) findPlayerByDevice;
  final VideoWebRTCPlayer? Function(String? peer) findPlayerForConnection;
  final IceServersCallback? onIceServers;
  final ClientIdCallback? onClientId;
  final void Function(String sessionId, VideoWebRTCPlayer player)?
  onSessionAssigned;

  void handleSignalRMessage(List<Object?>? args) {
    if (args == null || args.isEmpty) return;

    final messageStr = args[0]?.toString();
    if (messageStr == null) return;

    try {
      final parsed = jsonDecode(messageStr) as Map<String, dynamic>;
      final method = parsed.method;
      final session = parsed.param<String>('session');
      final logLabel = method != null
          ? 'method=$method${session != null ? ', session=$session' : ''}'
          : 'response id=${parsed['id']}';
      Logger().info('SignalRMessageRouter: Received $logLabel');

      if (parsed.isRequest) {
        _handleRequestMessage(parsed);
      } else if (parsed.isSuccessResponse) {
        _handleSuccessResponse(parsed);
      } else if (parsed.isErrorResponse) {
        _handleErrorResponse(parsed);
      }
    } catch (e) {
      Logger().error('SignalRMessageRouter: Parse error: $e');
    }
  }

  void handleDeviceSessionInfo(List<Object?>? args) {
    Logger().info('SignalRMessageRouter: Device session info: $args');
  }

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

  void handleError(List<Object?>? args) {
    Logger().error('SignalRMessageRouter: Error: $args');
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
        Logger().warn(
          'SignalRMessageRouter: Unknown method: ${message.method}',
        );
    }
  }

  void _handleSuccessResponse(Map<String, dynamic> message) {
    switch (message.id) {
      case '1':
        _handleRegisterResponse(message);
      case '2':
        _handleConnectResponse(message);
      default:
        Logger().warn(
          'SignalRMessageRouter: Unknown response id: ${message.id}',
        );
    }
  }

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

    final iceList = result['iceServers'] as List?;
    final servers = (iceList ?? [])
        .map((e) => IceServerConfig.fromJson(e))
        .toList();

    if (servers.isNotEmpty) {
      Logger().info(
        'SignalRMessageRouter: Received ${servers.length} ICE servers',
      );
      for (int i = 0; i < servers.length; i++) {
        final s = servers[i];
        Logger().info(
          'SignalRMessageRouter: Server[$i] urls=${s.urls.length}, '
          'hasCredentials=${s.credential != null && s.username != null}',
        );
      }
      onIceServers?.call(servers);
    }

    final player = findPlayerForConnection(peer);
    if (player != null && session != null) {
      player.sessionId = session;
      onSessionAssigned?.call(session, player);
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

  void _handleErrorResponse(Map<String, dynamic> message) {
    final error = ErrorMessage.fromJson(message);
    Logger().error(
      'SignalRMessageRouter: Error response: '
      'code=${error.code}, message="${error.message}", peer=${error.peer}',
    );
    _notifyPlayerOfError(error);
  }

  void _handleSignalError(Map<String, dynamic> message) {
    final error = ErrorMessage.fromJson(message);
    Logger().error(
      'SignalRMessageRouter: Signal error: '
      'code=${error.code}, message="${error.message}", session=${error.session}',
    );
    _notifyPlayerOfError(error);
  }

  void _notifyPlayerOfError(ErrorMessage error) {
    VideoWebRTCPlayer? player;
    if (error.session != null) {
      player = findPlayerBySession(error.session!);
    }
    player ??= error.peer != null ? findPlayerByDevice(error.peer!) : null;

    player?.onSignalRMessage(
      SignalRMessage(method: SignalRMessageType.onSignalError, detail: error),
    );
  }

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
}
