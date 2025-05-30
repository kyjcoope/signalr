import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'json_parser.dart';

enum SignalingMessageType {
  welcome('welcome'),
  peerStatusChanged('peerStatusChanged'),
  list('list'),
  sessionStarted('sessionStarted'),
  peer('peer'),
  startSession('startSession'),
  endSession('endSession'),
  error('error');

  const SignalingMessageType(this.json);

  final String json;
}

abstract interface class SignalingMessage {
  SignalingMessageType get type;
}

class WelcomeMessage implements SignalingMessage {
  WelcomeMessage({required this.peerId});

  factory WelcomeMessage.fromJson(dynamic json) =>
      WelcomeMessage(peerId: json['peerId'] ?? '');
  final String peerId;
  @override
  SignalingMessageType get type => SignalingMessageType.welcome;

  Map<String, String> toJson() => {
        'type': type.json,
        'peerId': peerId,
      };
}

class Producer {
  Producer({required this.id, required this.meta});

  factory Producer.fromJson(dynamic json) =>
      Producer(id: json['id'] ?? '', meta: json['meta'] ?? {});
  String id;
  Map<String, dynamic> meta;

  Map<String, Object> toJson() => {
        'id': id,
        'meta': meta,
      };

  @override
  String toString() => 'Producer: $id';

  String? get name => meta['name'];
}

class ListMessage implements SignalingMessage {
  ListMessage({required this.producers});

  factory ListMessage.fromJson(dynamic json) => ListMessage(
        producers: listFromJson(
          json['producers'],
          (p) => Producer.fromJson(p),
        ),
      );
  final List<Producer> producers;
  @override
  SignalingMessageType get type => SignalingMessageType.list;

  Map<String, Object> toJson() => {
        'type': type.json,
        'producers': producers,
      };
}

class PeerStatusChangedMessage implements SignalingMessage {
  PeerStatusChangedMessage({
    required this.peerId,
    required this.roles,
    required this.meta,
  });

  factory PeerStatusChangedMessage.fromJson(dynamic json) =>
      PeerStatusChangedMessage(
        peerId: json['peerId'] ?? '',
        roles:
            (json['roles'] as List?)?.map((r) => r.toString()).toList() ?? [],
        meta: json['meta'] ?? {},
      );
  final String peerId;
  final List<String> roles;
  final Map<String, dynamic> meta;
  @override
  SignalingMessageType get type => SignalingMessageType.peerStatusChanged;

  Map<String, Object> toJson() => {
        'type': type.json,
        'peerId': peerId,
        'roles': roles,
        'meta': meta,
      };
}

class StartSessionMessage implements SignalingMessage {
  StartSessionMessage({
    required this.peerId,
    required this.sessionId,
    required this.offer,
  });

  factory StartSessionMessage.fromJson(dynamic json) => StartSessionMessage(
        peerId: json['peerId'] ?? '',
        sessionId: json['sessionId'] ?? '',
        offer: json['offer'] ?? '',
      );
  final String peerId;
  final String sessionId;
  final String? offer;

  @override
  SignalingMessageType get type => SignalingMessageType.startSession;

  Map<String, String?> toJson() => {
        'type': type.json,
        'peerId': peerId,
        'sessionId': sessionId,
        'offer': offer,
      };
}

class SessionStartedMessage implements SignalingMessage {
  SessionStartedMessage({
    required this.sessionId,
    required this.peerId,
  });

  factory SessionStartedMessage.fromJson(dynamic json) => SessionStartedMessage(
        sessionId: json['sessionId'] ?? '',
        peerId: json['peerId'] ?? '',
      );
  final String sessionId;
  final String peerId;
  @override
  SignalingMessageType get type => SignalingMessageType.sessionStarted;

  Map<String, String> toJson() => {
        'type': type.json,
        'sessionId': sessionId,
        'peerId': peerId,
      };
}

class EndSessionMessage implements SignalingMessage {
  EndSessionMessage({required this.sessionId});

  factory EndSessionMessage.fromJson(dynamic json) =>
      EndSessionMessage(sessionId: json['sessionId'] ?? '');
  final String sessionId;
  @override
  SignalingMessageType get type => SignalingMessageType.endSession;

  Map<String, String> toJson() => {
        'type': type.json,
        'sessionId': sessionId,
      };
}

extension RTCIceCandidateExt on RTCIceCandidate {
  static RTCIceCandidate fromJson(dynamic json) => RTCIceCandidate(
        json['candidate'],
        json['sdpMid'],
        json['sdpMLineIndex'],
      );

  Map<String, Object?> toJson() => {
        'candidate': candidate,
        'sdpMid': sdpMid,
        'sdpMLineIndex': sdpMLineIndex,
      };
}

class SdpWrapper {
  SdpWrapper({required this.type, required this.sdp});

  factory SdpWrapper.fromJson(dynamic json) => SdpWrapper(
        type: json['type'] ?? '',
        sdp: json['sdp'] ?? '',
      );
  String type;
  String sdp;

  Map<String, String> toJson() => {
        'type': type,
        'sdp': sdp,
      };

  @override
  String toString() => 'SDP: $type :: $sdp';
}

extension RTCSEssionDescriptionExt on RTCSessionDescription {
  Map<String, String> toJson() => {
        'type': type ?? '',
        'sdp': sdp ?? '',
      };
}

class PeerMessage implements SignalingMessage {
  PeerMessage({
    required this.sessionId,
    required this.sdp,
    required this.iceCandiate,
  });

  factory PeerMessage.fromJson(dynamic json) => PeerMessage(
        sessionId: json['sessionId'] ?? '',
        sdp: SdpWrapper.fromJson(json['sdp'] ?? {}),
        iceCandiate: json['inceCandiate'] ?? {},
      );
  final String sessionId;
  final SdpWrapper sdp;
  final Map<dynamic, dynamic> iceCandiate;

  @override
  SignalingMessageType get type => SignalingMessageType.peer;

  Map<String, dynamic> toJson() => {
        'type': type.json,
        'sessionId': sessionId,
        'sdp': sdp.toJson(),
        'iceCandiate': iceCandiate,
      };
}
