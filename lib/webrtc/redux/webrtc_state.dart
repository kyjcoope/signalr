import '../webrtc_stats_monitor.dart';

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

/// Metadata for a single media track (video or audio).
class TrackInfo {
  /// MediaStreamTrack ID.
  final String id;

  /// Codec name (e.g. 'H264', 'opus'). Empty if unknown.
  final String codec;

  /// Whether the track is currently enabled.
  final bool enabled;

  const TrackInfo({required this.id, this.codec = '', this.enabled = true});
}

/// Per-camera WebRTC session snapshot for the UI layer.
///
/// This is a plain value object — no references to RTCVideoRenderer or
/// WebRtcCameraSession. The hub remains the source of truth for those.
class WebRtcSessionState {
  final WebRtcConnectionState connectionState;
  final int? textureId;
  final List<TrackInfo> videoTracks;
  final List<TrackInfo> audioTracks;
  final int activeVideoTrack;
  final int activeAudioTrack;
  final WebRtcVideoStats? videoStats;

  const WebRtcSessionState({
    this.connectionState = WebRtcConnectionState.sessionDisconnected,
    this.textureId,
    this.videoTracks = const [],
    this.audioTracks = const [],
    this.activeVideoTrack = 0,
    this.activeAudioTrack = 0,
    this.videoStats,
  });

  WebRtcSessionState copyWith({
    WebRtcConnectionState? connectionState,
    int? textureId,
    List<TrackInfo>? videoTracks,
    List<TrackInfo>? audioTracks,
    int? activeVideoTrack,
    int? activeAudioTrack,
    WebRtcVideoStats? videoStats,
  }) {
    return WebRtcSessionState(
      connectionState: connectionState ?? this.connectionState,
      textureId: textureId ?? this.textureId,
      videoTracks: videoTracks ?? this.videoTracks,
      audioTracks: audioTracks ?? this.audioTracks,
      activeVideoTrack: activeVideoTrack ?? this.activeVideoTrack,
      activeAudioTrack: activeAudioTrack ?? this.activeAudioTrack,
      videoStats: videoStats ?? this.videoStats,
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
