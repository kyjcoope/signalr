import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../webrtc/signaling_message.dart';
import 'json_rpc.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Core Message Types
// ══════════════════════════════════════════════════════════════════════════════

/// SignalR message types for internal routing.
enum SignalRMessageType {
  onSignalReady,
  onSignalClosed,
  onSignalInvite,
  onSignalTrickle,
  onSignalTimeout,
  onSignalError,
  onSignalIceServers,
}

/// SignalR message wrapper for internal routing.
class SignalRMessage {
  SignalRMessage({required this.method, required this.detail});

  /// The message type.
  final SignalRMessageType method;

  /// The message detail/payload.
  final dynamic detail;

  @override
  String toString() => 'SignalRMessage(method: $method, detail: $detail)';
}

// ══════════════════════════════════════════════════════════════════════════════
// SignalR Method Enum
// ══════════════════════════════════════════════════════════════════════════════

/// SignalR JSON-RPC method types.
enum SignalRMethod {
  register('register'),
  connect('connect'),
  invite('invite'),
  trickle('trickle'),
  disconnect('disconnect'),
  error('error');

  const SignalRMethod(this.json);

  /// The JSON string representation of this method.
  final String json;

  /// Parse a method name string to enum value.
  static SignalRMethod? fromString(String? method) {
    if (method == null) return null;
    return SignalRMethod.values.where((m) => m.json == method).firstOrNull;
  }
}

/// Base interface for all SignalR messages.
abstract interface class SignalRTypedMessage {
  /// The JSON-RPC method.
  SignalRMethod get method;

  /// The message ID (for requests/responses).
  String get id;

  /// Convert to JSON map for sending.
  Map<String, dynamic> toJson();
}

/// Abstract base class for JSON-RPC request messages.
///
/// Subclasses only need to define [method], [id], and [params].
/// The [toJson] method is automatically provided.
abstract class JsonRpcRequest implements SignalRTypedMessage {
  /// The request params.
  Map<String, dynamic> get params;

  @override
  Map<String, dynamic> toJson() =>
      JsonRpc.request(method: method.json, id: id, params: params);
}

// ══════════════════════════════════════════════════════════════════════════════
// Register Messages
// ══════════════════════════════════════════════════════════════════════════════

/// Register request sent to SignalR server.
class RegisterRequest extends JsonRpcRequest {
  RegisterRequest({required this.authorization, this.id = '1'});

  final String authorization;

  @override
  final String id;

  @override
  SignalRMethod get method => SignalRMethod.register;

  @override
  Map<String, dynamic> get params => {'authorization': authorization};
}

/// Register response from SignalR server.
class RegisterResponse {
  RegisterResponse({required this.clientId});

  factory RegisterResponse.fromJson(Map<String, dynamic> json) =>
      RegisterResponse(clientId: json['result']?['id'] as String? ?? '');

  /// The client ID assigned by the server.
  final String clientId;
}

// ══════════════════════════════════════════════════════════════════════════════
// Connect Messages
// ══════════════════════════════════════════════════════════════════════════════

/// Connect request to start a camera session.
class ConnectRequest extends JsonRpcRequest {
  ConnectRequest({
    required this.deviceId,
    this.authorization = '',
    this.profile = '',
    this.id = '2',
  });

  final String deviceId;
  final String authorization;
  final String profile;

  @override
  final String id;

  @override
  SignalRMethod get method => SignalRMethod.connect;

  @override
  Map<String, dynamic> get params => {
    'authorization': authorization,
    'peer': deviceId,
    'profile': profile,
  };
}

/// Connect response with session and ICE servers.
class ConnectResponse {
  ConnectResponse({
    required this.session,
    required this.iceServers,
    required this.peer,
    this.id = '',
  });

  factory ConnectResponse.fromJson(Map<String, dynamic> json) {
    final result = json['result'] as Map<String, dynamic>? ?? {};
    final iceList = result['iceServers'] as List? ?? [];

    return ConnectResponse(
      session: result['session'] as String? ?? '',
      peer: result['peer'] as String? ?? '',
      iceServers: iceList.map((e) => IceServerConfig.fromJson(e)).toList(),
      id: json['id']?.toString() ?? '',
    );
  }

  final String session;
  final String peer;
  final List<IceServerConfig> iceServers;
  final String id;
}

/// ICE server configuration.
class IceServerConfig {
  IceServerConfig({required this.urls, this.credential, this.username});

  factory IceServerConfig.fromJson(dynamic json) => IceServerConfig(
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

// ══════════════════════════════════════════════════════════════════════════════
// Invite Messages
// ══════════════════════════════════════════════════════════════════════════════

/// Invite request (offer) from the server.
class InviteRequest {
  InviteRequest({required this.session, required this.offer, required this.id});

  factory InviteRequest.fromJson(Map<String, dynamic> json) {
    final params = json['params'] as Map<String, dynamic>? ?? {};
    final offerJson = params['offer'] as Map<String, dynamic>? ?? {};

    return InviteRequest(
      session: params['session'] as String? ?? '',
      offer: SdpWrapper.fromJson(offerJson),
      id: json['id']?.toString() ?? '',
    );
  }

  final String session;
  final SdpWrapper offer;
  final String id;
}

/// Invite answer message sent back to server.
class InviteAnswerMessage implements SignalRTypedMessage {
  InviteAnswerMessage({
    required this.session,
    required this.answerSdp,
    required this.id,
  });

  final String session;
  final SdpWrapper answerSdp;

  @override
  final String id;

  @override
  SignalRMethod get method => SignalRMethod.invite;

  @override
  Map<String, dynamic> toJson() => JsonRpc.response(
    id: id,
    result: {'session': session, 'answer': answerSdp.toJson()},
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// Trickle Messages
// ══════════════════════════════════════════════════════════════════════════════

/// Trickle message for ICE candidate exchange.
class TrickleMessage implements SignalRTypedMessage {
  TrickleMessage({
    required this.session,
    required this.candidate,
    this.id = '',
  });

  final String session;
  final RTCIceCandidate candidate;

  @override
  final String id;

  @override
  SignalRMethod get method => SignalRMethod.trickle;

  @override
  Map<String, dynamic> toJson() => JsonRpc.notification(
    method: method.json,
    params: {
      'session': session,
      'candidate': {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      },
    },
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// Error Messages
// ══════════════════════════════════════════════════════════════════════════════

/// Error notification message.
class ErrorMessage implements SignalRTypedMessage {
  ErrorMessage({
    required this.code,
    required this.message,
    this.session,
    this.id = '',
  });

  factory ErrorMessage.fromJson(Map<String, dynamic> json) {
    final params = json['params'] as Map<String, dynamic>? ?? {};

    // Server sends errors in two formats:
    // 1. Nested: params.error.{code, message, peer}
    // 2. Flat:   params.{code, message}
    final errorObj = params['error'] as Map<String, dynamic>?;
    final int code;
    final String message;
    if (errorObj != null) {
      code = errorObj['code'] as int? ?? 0;
      message = errorObj['message'] as String? ?? '';
    } else {
      code = params['code'] as int? ?? 0;
      message = params['message'] as String? ?? '';
    }

    return ErrorMessage(
      code: code,
      message: message,
      session: params['session'] as String?,
      id: json['id']?.toString() ?? '',
    );
  }

  final int code;
  final String message;
  final String? session;

  @override
  final String id;

  @override
  SignalRMethod get method => SignalRMethod.error;

  @override
  Map<String, dynamic> toJson() => JsonRpc.notification(
    method: method.json,
    params: {
      'code': code,
      'message': message,
      if (session != null) 'session': session,
    },
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// Close/Leave Messages
// ══════════════════════════════════════════════════════════════════════════════

/// Disconnect message sent when client leaves a session.
///
/// Matches the web client's disconnect format:
/// `{jsonrpc: '2.0', method: 'disconnect', params: {peer: '<deviceId>', session: '<sessionId>'}}`
class CloseMessage implements SignalRTypedMessage {
  CloseMessage({required this.session, required this.deviceId});

  final String session;
  final String deviceId;

  @override
  String get id => '';

  @override
  SignalRMethod get method => SignalRMethod.disconnect;

  @override
  Map<String, dynamic> toJson() => JsonRpc.notification(
    method: method.json,
    params: {'peer': deviceId, 'session': session},
  );
}
