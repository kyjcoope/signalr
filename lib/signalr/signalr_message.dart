import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/signalr/signalr_parameters.dart';

import '../webrtc/json_parser.dart';
import '../webrtc/signaling_message.dart';

class IceServer {
  IceServer({
    required this.urls,
    required this.credential,
    required this.username,
  });

  factory IceServer.fromJson(dynamic json) => IceServer(
    urls: (json['urls'] as List?)?.map((r) => r.toString()).toList() ?? [],
    credential: json['credential'],
    username: json['username'],
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

enum SignalRMethod {
  register('register'),
  connect('connect'),
  invite('invite'),
  trickle('trickle');

  const SignalRMethod(this.json);

  final String json;
}

abstract interface class SignalRMessage {
  String get jsonRPC;
  SignalRMethod get method;
  SignalRParamsList get params;
  String get id;
}

class RegisterRequest implements SignalRMessage {
  RegisterRequest({required this.authorization, required this.id});
  final String authorization;
  @override
  final String id;

  @override
  String get jsonRPC => '2.0';

  @override
  SignalRMethod get method => SignalRMethod.register;

  @override
  SignalRParamsList get params =>
      SignalRParamsList([AuthorizationParam(authorization)]);

  Map<String, Object> toJson() => {
    'jsonrpc': jsonRPC,
    'method': method.json,
    'params': {'authorization': ''},
    'id': id,
  };
}

// This one is unique for some reason
class RegisterResponse {
  RegisterResponse({required this.deviceIds});

  factory RegisterResponse.fromJson(dynamic json) => RegisterResponse(
    deviceIds: listFromJson(json, (jsonItem) => jsonItem['DeviceID']),
  );
  final List<String> deviceIds;
}

class ConnectRequest implements SignalRMessage {
  ConnectRequest(
    this._signalRId, {
    required this.authorization,
    required this.deviceId,
    this.profile,
    this.session,
    this.iceServers,
  });
  final String authorization;
  final String deviceId;
  final String? profile;
  final String? session;
  final List<IceServer>? iceServers;
  final String _signalRId;

  @override
  String get jsonRPC => '2.0';

  @override
  SignalRMethod get method => SignalRMethod.connect;

  @override
  String get id => _signalRId;

  @override
  SignalRParamsList get params => SignalRParamsList([
    AuthorizationParam(authorization),
    DeviceIdParam(deviceId),
    if (profile != null) ProfileParam(profile!),
    if (session != null) SessionParam(session!),
    if (iceServers != null) IceServersParam(iceServers!),
  ]);

  Map<String, Object> toJson() => {
    'jsonrpc': jsonRPC,
    'method': method.json,
    'params': params.toJson(),
    'id': '2',
  };
}

class ConnectResponse implements SignalRMessage {
  ConnectResponse({
    required this.session,
    required this.iceServers,
    required this.id,
  });

  factory ConnectResponse.fromJson(dynamic json) => ConnectResponse(
    session: json['result']['session'] ?? '',
    iceServers: listFromJson(json['result']['iceServers'], IceServer.fromJson),
    id: json['id'] ?? '',
  );
  final String session;
  final List<IceServer> iceServers;
  @override
  final String id;

  @override
  String get jsonRPC => '2.0';

  @override
  SignalRMethod get method => SignalRMethod.connect;

  @override
  SignalRParamsList get params =>
      SignalRParamsList([SessionParam(session), IceServersParam(iceServers)]);

  Map<String, Object> toJson() => {
    'jsonrpc': jsonRPC,
    'method': method.json,
    'params': params.toJson(),
    'id': id,
  };
}

class InviteRequest implements SignalRMessage {
  InviteRequest({
    required this.session,
    required this.answer,
    required this.id,
  });
  final String session;
  final SdpWrapper answer;
  @override
  final String id;

  @override
  String get jsonRPC => '2.0';

  @override
  SignalRMethod get method => SignalRMethod.invite;

  @override
  SignalRParamsList get params =>
      SignalRParamsList([SessionParam(session), OfferParam(answer)]);

  Map<String, Object> toJson() => {
    'jsonrpc': jsonRPC,
    'method': method.json,
    'params': params.toJson(),
    'id': id,
  };
}

class InviteResponse implements SignalRMessage {
  InviteResponse({
    required this.session,
    required this.offer,
    required this.id,
  });

  factory InviteResponse.fromJson(dynamic json) => InviteResponse(
    session: json['params']['session'] ?? '',
    offer: SdpWrapper.fromJson(json['params']['offer']),
    id: json['id'] ?? '',
  );
  final String session;
  final SdpWrapper offer;
  @override
  final String id;

  @override
  String get jsonRPC => '2.0';

  @override
  SignalRMethod get method => SignalRMethod.invite;

  @override
  SignalRParamsList get params =>
      SignalRParamsList([SessionParam(session), OfferParam(offer)]);

  Map<String, Object> toJson() => {
    'jsonrpc': jsonRPC,
    'method': method.json,
    'params': params.toJson(),
    'id': id,
  };

  @override
  String toString() => jsonEncode(toJson());
}

class TrickleMessage implements SignalRMessage {
  TrickleMessage({
    required this.session,
    required this.candidate,
    required this.id,
  });

  factory TrickleMessage.fromJson(dynamic json) {
    final candidate = json['params']['candidate'];
    return TrickleMessage(
      session: json['params']['session'] ?? '',
      candidate: RTCIceCandidate(
        candidate['candidate'],
        candidate['sdpMid'] ?? '',
        candidate['sdpMLineIndex'],
      ),
      id: json['id'] ?? '',
    );
  }
  final String session;
  final RTCIceCandidate candidate;
  @override
  final String id;

  @override
  String get jsonRPC => '2.0';

  @override
  SignalRMethod get method => SignalRMethod.trickle;

  @override
  SignalRParamsList get params =>
      SignalRParamsList([SessionParam(session), CandidateParam(candidate)]);

  Map<String, Object> toJson() => {
    'jsonrpc': jsonRPC,
    'method': method.json,
    'params': params.toJson(),
    'id': id,
  };

  @override
  String toString() => jsonEncode(toJson());
}
