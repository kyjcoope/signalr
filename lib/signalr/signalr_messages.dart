import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../webrtc/signaling_message.dart';
import 'json_rpc.dart';

enum SignalRMessageType {
  onSignalReady,
  onSignalClosed,
  onSignalInvite,
  onSignalTrickle,
  onSignalTimeout,
  onSignalError,
  onSignalIceServers,
}

class SignalRMessage {
  SignalRMessage({required this.method, required this.detail});

  final SignalRMessageType method;
  final dynamic detail;

  @override
  String toString() => 'SignalRMessage(method: $method, detail: $detail)';
}

enum SignalRMethod {
  register('register'),
  connect('connect'),
  invite('invite'),
  trickle('trickle'),
  disconnect('disconnect'),
  error('error');

  const SignalRMethod(this.json);

  final String json;

  static SignalRMethod? fromString(String? method) {
    if (method == null) return null;
    return SignalRMethod.values.where((m) => m.json == method).firstOrNull;
  }
}

abstract interface class SignalRTypedMessage {
  SignalRMethod get method;
  String get id;
  Map<String, dynamic> toJson();
}

abstract class JsonRpcRequest implements SignalRTypedMessage {
  Map<String, dynamic> get params;

  @override
  Map<String, dynamic> toJson() =>
      JsonRpc.request(method: method.json, id: id, params: params);
}

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

class RegisterResponse {
  RegisterResponse({required this.clientId});

  factory RegisterResponse.fromJson(Map<String, dynamic> json) =>
      RegisterResponse(clientId: json['result']?['id'] as String? ?? '');

  final String clientId;
}

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

class IceServerConfig {
  IceServerConfig({required this.urls, this.credential, this.username});

  factory IceServerConfig.fromJson(dynamic json) => IceServerConfig(
    urls: _parseUrls(json['urls']),
    credential: json['credential'] as String?,
    username: json['username'] as String?,
  );

  static List<String> _parseUrls(dynamic urls) {
    if (urls is String) return [urls];
    if (urls is List) return urls.map((r) => r.toString()).toList();
    return [];
  }

  final List<String> urls;
  final String? credential;
  final String? username;

  Map<String, Object?> toJson() => {
    'urls': urls,
    if (credential != null) 'credential': credential,
    if (username != null) 'username': username,
  };
}

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

class ErrorMessage implements SignalRTypedMessage {
  ErrorMessage({
    required this.code,
    required this.message,
    this.session,
    this.peer,
    this.id = '',
  });

  factory ErrorMessage.fromJson(Map<String, dynamic> json) {
    final topError = json['error'] as Map<String, dynamic>?;
    if (topError != null && !json.containsKey('method')) {
      return ErrorMessage(
        code: topError['code'] as int? ?? 0,
        message: topError['message'] as String? ?? '',
        peer: topError['peer'] as String?,
        id: json['id']?.toString() ?? '',
      );
    }

    final params = json['params'] as Map<String, dynamic>? ?? {};
    final errorObj = params['error'] as Map<String, dynamic>?;

    final int code;
    final String message;
    final String? peer;
    if (errorObj != null) {
      code = errorObj['code'] as int? ?? 0;
      message = errorObj['message'] as String? ?? '';
      peer = errorObj['peer'] as String?;
    } else {
      code = params['code'] as int? ?? 0;
      message = params['message'] as String? ?? '';
      peer = params['peer'] as String?;
    }

    return ErrorMessage(
      code: code,
      message: message,
      session: params['session'] as String?,
      peer: peer,
      id: json['id']?.toString() ?? '',
    );
  }

  final int code;
  final String message;
  final String? session;
  final String? peer;

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
      if (peer != null) 'peer': peer,
    },
  );
}

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
