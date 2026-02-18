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
