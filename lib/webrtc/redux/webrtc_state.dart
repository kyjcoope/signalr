/// Connection lifecycle states exposed to the UI layer.
enum WebRtcConnectionState {
  /// No connection attempt — default state.
  sessionDisconnected,

  /// Connection initiated, negotiating.
  sessionPending,

  /// ICE connected, media flowing.
  sessionConnected,

  /// Temporarily lost, may recover.
  sessionReconnecting,

  /// Fatal error or connection failed.
  sessionFailed,
}

/// Per-camera WebRTC session snapshot for the UI layer.
///
/// This is a plain value object — no references to RTCVideoRenderer or
/// WebRtcCameraSession. The hub remains the source of truth for those.
class WebRtcSessionState {
  final WebRtcConnectionState connectionState;
  final int? textureId;
  final int videoTrackCount;
  final int audioTrackCount;
  final int activeVideoTrack;
  final bool audioEnabled;
  final String? negotiatedCodec;

  const WebRtcSessionState({
    this.connectionState = WebRtcConnectionState.sessionDisconnected,
    this.textureId,
    this.videoTrackCount = 0,
    this.audioTrackCount = 0,
    this.activeVideoTrack = 0,
    this.audioEnabled = true,
    this.negotiatedCodec,
  });

  /// Whether this session has more than one video track.
  bool get hasMultipleVideoTracks => videoTrackCount > 1;

  /// Whether this session has more than one audio track.
  bool get hasMultipleAudioTracks => audioTrackCount > 1;

  WebRtcSessionState copyWith({
    WebRtcConnectionState? connectionState,
    int? textureId,
    int? videoTrackCount,
    int? audioTrackCount,
    int? activeVideoTrack,
    bool? audioEnabled,
    String? negotiatedCodec,
  }) {
    return WebRtcSessionState(
      connectionState: connectionState ?? this.connectionState,
      textureId: textureId ?? this.textureId,
      videoTrackCount: videoTrackCount ?? this.videoTrackCount,
      audioTrackCount: audioTrackCount ?? this.audioTrackCount,
      activeVideoTrack: activeVideoTrack ?? this.activeVideoTrack,
      audioEnabled: audioEnabled ?? this.audioEnabled,
      negotiatedCodec: negotiatedCodec ?? this.negotiatedCodec,
    );
  }
}

/// WebRTC state for all camera sessions. NOT persisted.
///
/// Pure data container — all query logic lives in selectors.
class WebRtcState {
  final Map<String, WebRtcSessionState> _sessions;

  const WebRtcState({Map<String, WebRtcSessionState> sessions = const {}})
    : _sessions = sessions;

  /// All session entries (read-only).
  Map<String, WebRtcSessionState> get sessions => Map.unmodifiable(_sessions);

  WebRtcState copyWith({Map<String, WebRtcSessionState>? sessions}) {
    return WebRtcState(sessions: sessions ?? _sessions);
  }
}
