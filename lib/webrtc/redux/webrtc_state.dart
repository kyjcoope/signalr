import 'package:equatable/equatable.dart';

import '../connection_error.dart';
import '../webrtc_stats_monitor.dart';

enum WebRtcConnectionState {
  disconnected,
  pending,
  connected,
  reconnecting,
  failed,
}

class TrackInfo extends Equatable {
  const TrackInfo({required this.id, this.codec = '', this.enabled = true});

  final String id;
  final String codec;
  final bool enabled;

  @override
  List<Object?> get props => [id, codec, enabled];
}

class WebRtcSessionState extends Equatable {
  const WebRtcSessionState({
    this.connectionState = WebRtcConnectionState.disconnected,
    this.error,
    this.textureId,
    this.videoTracks = const [],
    this.audioTracks = const [],
    this.activeVideoTrack = 0,
    this.activeAudioTrack = 0,
    this.videoStats,
  });

  final WebRtcConnectionState connectionState;
  final ConnectionError? error;
  final int? textureId;
  final List<TrackInfo> videoTracks;
  final List<TrackInfo> audioTracks;
  final int activeVideoTrack;
  final int activeAudioTrack;
  final WebRtcVideoStats? videoStats;

  WebRtcSessionState copyWith({
    WebRtcConnectionState? connectionState,
    ConnectionError? error,
    bool clearError = false,
    int? textureId,
    List<TrackInfo>? videoTracks,
    List<TrackInfo>? audioTracks,
    int? activeVideoTrack,
    int? activeAudioTrack,
    WebRtcVideoStats? videoStats,
  }) {
    return WebRtcSessionState(
      connectionState: connectionState ?? this.connectionState,
      error: clearError ? null : (error ?? this.error),
      textureId: textureId ?? this.textureId,
      videoTracks: videoTracks ?? this.videoTracks,
      audioTracks: audioTracks ?? this.audioTracks,
      activeVideoTrack: activeVideoTrack ?? this.activeVideoTrack,
      activeAudioTrack: activeAudioTrack ?? this.activeAudioTrack,
      videoStats: videoStats ?? this.videoStats,
    );
  }

  @override
  List<Object?> get props => [
    connectionState,
    error,
    textureId,
    videoTracks,
    audioTracks,
    activeVideoTrack,
    activeAudioTrack,
    videoStats,
  ];
}

class WebRtcState extends Equatable {
  const WebRtcState({this.sessions = const {}});

  final Map<String, WebRtcSessionState> sessions;

  WebRtcState copyWith({Map<String, WebRtcSessionState>? sessions}) {
    return WebRtcState(sessions: sessions ?? this.sessions);
  }

  @override
  List<Object?> get props => [sessions];
}
