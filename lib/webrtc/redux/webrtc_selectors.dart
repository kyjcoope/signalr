import 'package:reselect/reselect.dart';

import '../../redux/app_state.dart';

WebRtcState getWebRtcState(AppState state) => state.webRtc;

WebRtcSessionState? getWebRtcSession(AppState state, String slug) =>
    state.webRtc.sessions[slug];

bool hasWebRtcSession(AppState state, String slug) =>
    state.webRtc.sessions.containsKey(slug);

bool isWebRtcConnected(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.connectionState ==
    WebRtcConnectionState.connected;

bool isWebRtcPending(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.connectionState ==
    WebRtcConnectionState.pending;

WebRtcConnectionState getWebRtcConnectionState(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.connectionState ??
    WebRtcConnectionState.disconnected;

int? getWebRtcTextureId(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.textureId;

bool isWebRtcAudioEnabled(AppState state, String slug) {
  final session = state.webRtc.sessions[slug];
  if (session == null || session.audioTracks.isEmpty) return true;
  final idx = session.activeAudioTrack.clamp(0, session.audioTracks.length - 1);
  return session.audioTracks[idx].enabled;
}

int getWebRtcVideoTrackCount(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.videoTracks.length ?? 0;

int getWebRtcAudioTrackCount(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.audioTracks.length ?? 0;

int getWebRtcActiveVideoTrack(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.activeVideoTrack ?? 0;

String? getWebRtcNegotiatedCodec(AppState state, String slug) {
  final session = state.webRtc.sessions[slug];
  if (session == null || session.videoTracks.isEmpty) return null;
  final idx = session.activeVideoTrack.clamp(0, session.videoTracks.length - 1);
  final codec = session.videoTracks[idx].codec;
  return codec.isEmpty ? null : codec;
}

int getWebRtcActiveAudioTrack(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.activeAudioTrack ?? 0;

String? selectTrackInfo(AppState state, String slug) {
  final session = state.webRtc.sessions[slug];
  if (session == null ||
      session.connectionState != WebRtcConnectionState.connected) {
    return null;
  }
  return 'V:${session.videoTracks.length} A:${session.audioTracks.length}';
}

final getConnectedWebRtcSlugs =
    createSelector1<AppState, Map<String, WebRtcSessionState>, List<String>>(
      (state) => state.webRtc.sessions,
      (sessions) => sessions.entries
          .where(
            (e) =>
                e.value.connectionState ==
                WebRtcConnectionState.connected,
          )
          .map((e) => e.key)
          .toList(),
    );
