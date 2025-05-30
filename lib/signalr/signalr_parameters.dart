import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../webrtc/signaling_message.dart';
import 'signalr_message.dart';

enum SignalRParamType {
  authorization('authorization'),
  session('session'),
  offer('offer'),
  candidate('candidate'),
  deviceId('peer'),
  clientConnectionId('clientConnectionId'),
  oldClientConnectionId('oldClientConnectionId'),
  iceServers('iceServers'),
  deviceGuid('guid'),
  profile('profile'),
  deviceConnectionId('deviceConnectionId');

  const SignalRParamType(this.json);

  final String json;
}

class SignalRParamsList {
  SignalRParamsList(this.params);
  final List<SignalRParam> params;

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{};
    for (var param in params) {
      result[param.type.json] = param.value;
    }
    return result;
  }
}

abstract interface class SignalRParam {
  SignalRParamType get type;
  dynamic get value;
}

class AuthorizationParam implements SignalRParam {
  AuthorizationParam(this.authorization);
  final String authorization;

  @override
  SignalRParamType get type => SignalRParamType.authorization;

  @override
  String get value => authorization;
}

class SessionParam implements SignalRParam {
  SessionParam(this.sessionId);
  final String sessionId;

  @override
  SignalRParamType get type => SignalRParamType.session;

  @override
  String get value => sessionId;
}

class OfferParam implements SignalRParam {
  OfferParam(this.offer);
  final SdpWrapper offer;

  @override
  SignalRParamType get type => SignalRParamType.offer;

  @override
  dynamic get value => offer.toJson();
}

class CandidateParam implements SignalRParam {
  CandidateParam(this.candidate);
  final RTCIceCandidate candidate;

  @override
  SignalRParamType get type => SignalRParamType.candidate;

  @override
  dynamic get value => candidate.toJson();
}

class DeviceIdParam implements SignalRParam {
  DeviceIdParam(this.deviceId);
  final String deviceId;

  @override
  SignalRParamType get type => SignalRParamType.deviceId;

  @override
  String get value => deviceId;
}

class ClientConnectionIdParam implements SignalRParam {
  ClientConnectionIdParam(this.clientConnectionId);
  final String clientConnectionId;

  @override
  SignalRParamType get type => SignalRParamType.clientConnectionId;

  @override
  String get value => clientConnectionId;
}

class OldClientConnectionIdParam implements SignalRParam {
  OldClientConnectionIdParam(this.oldClientConnectionId);
  final String oldClientConnectionId;

  @override
  SignalRParamType get type => SignalRParamType.oldClientConnectionId;

  @override
  String get value => oldClientConnectionId;
}

class IceServersParam implements SignalRParam {
  IceServersParam(List<IceServer>? iceServers) : iceServers = iceServers ?? [];
  final List<IceServer> iceServers;

  @override
  SignalRParamType get type => SignalRParamType.iceServers;

  @override
  String get value => iceServers.toString();
}

class DeviceGuidParam implements SignalRParam {
  DeviceGuidParam(this.deviceGuid);
  final String deviceGuid;

  @override
  SignalRParamType get type => SignalRParamType.deviceGuid;

  @override
  String get value => deviceGuid;
}

class ProfileParam implements SignalRParam {
  ProfileParam(this.profile);
  final String profile;

  @override
  SignalRParamType get type => SignalRParamType.profile;

  @override
  String get value => profile;
}

class DeviceConnectionIdParam implements SignalRParam {
  DeviceConnectionIdParam(this.deviceConnectionId);
  final String deviceConnectionId;

  @override
  SignalRParamType get type => SignalRParamType.deviceConnectionId;

  @override
  String get value => deviceConnectionId;
}
