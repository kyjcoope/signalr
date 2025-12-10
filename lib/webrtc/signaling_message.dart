import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Wrapper for SDP (Session Description Protocol) data.
class SdpWrapper {
  SdpWrapper({required this.type, required this.sdp});

  factory SdpWrapper.fromJson(dynamic json) =>
      SdpWrapper(type: json['type'] ?? '', sdp: json['sdp'] ?? '');

  String type;
  String sdp;

  Map<String, String> toJson() => {'type': type, 'sdp': sdp};

  @override
  String toString() => 'SDP: $type :: $sdp';
}

/// Extension for RTCIceCandidate JSON serialization.
extension RTCIceCandidateExt on RTCIceCandidate {
  static RTCIceCandidate fromJson(dynamic json) => RTCIceCandidate(
    json['candidate'] ?? '',
    json['sdpMid'],
    json['sdpMLineIndex'],
  );

  Map<String, Object?> toJson() => {
    'candidate': candidate,
    'sdpMid': sdpMid,
    'sdpMLineIndex': sdpMLineIndex,
  };
}

/// Extension for RTCSessionDescription JSON serialization.
extension RTCSessionDescriptionExt on RTCSessionDescription {
  Map<String, String> toJson() => {'type': type ?? '', 'sdp': sdp ?? ''};
}
