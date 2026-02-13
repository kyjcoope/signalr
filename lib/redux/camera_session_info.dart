/// Per-camera session info for the UI layer.
///
/// This is a plain value object — no references to RTCVideoRenderer or
/// WebRtcCameraSession.  The hub remains the source of truth for those.
enum ConnectionStatus { idle, pending, connected }

class CameraSessionInfo {
  final ConnectionStatus status;
  final String? codec;
  final int videoTrackCount;
  final int audioTrackCount;
  final int activeVideoTrack;
  final int? textureId;

  const CameraSessionInfo({
    this.status = ConnectionStatus.idle,
    this.codec,
    this.videoTrackCount = 0,
    this.audioTrackCount = 0,
    this.activeVideoTrack = 0,
    this.textureId,
  });

  CameraSessionInfo copyWith({
    ConnectionStatus? status,
    String? codec,
    int? videoTrackCount,
    int? audioTrackCount,
    int? activeVideoTrack,
    int? textureId,
  }) {
    return CameraSessionInfo(
      status: status ?? this.status,
      codec: codec ?? this.codec,
      videoTrackCount: videoTrackCount ?? this.videoTrackCount,
      audioTrackCount: audioTrackCount ?? this.audioTrackCount,
      activeVideoTrack: activeVideoTrack ?? this.activeVideoTrack,
      textureId: textureId ?? this.textureId,
    );
  }
}
