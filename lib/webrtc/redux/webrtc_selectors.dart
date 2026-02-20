import 'package:reselect/reselect.dart';

import '../../redux/app_state.dart';

// ═══════════════════════════════════════════════════════════════════════════
// WebRTC Session Selectors
// ═══════════════════════════════════════════════════════════════════════════

/// Get the full WebRTC state.
WebRtcState getWebRtcState(AppState state) => state.webRtc;

/// Get session snapshot for a slug (returns null if not tracked).
WebRtcSessionState? getWebRtcSession(AppState state, String slug) =>
    state.webRtc.sessions[slug];

/// Whether a session exists for this slug.
bool hasWebRtcSession(AppState state, String slug) =>
    state.webRtc.sessions.containsKey(slug);

/// Whether a camera is connected.
bool isWebRtcConnected(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.connectionState ==
    WebRtcConnectionState.sessionConnected;

/// Whether a camera is pending (negotiating).
bool isWebRtcPending(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.connectionState ==
    WebRtcConnectionState.sessionPending;

/// Get the connection state for a slug.
WebRtcConnectionState getWebRtcConnectionState(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.connectionState ??
    WebRtcConnectionState.sessionDisconnected;

/// Get texture ID for a slug.
int? getWebRtcTextureId(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.textureId;

/// Whether audio is enabled for a camera (derived from active audio track).
bool isWebRtcAudioEnabled(AppState state, String slug) {
  final session = state.webRtc.sessions[slug];
  if (session == null || session.audioTracks.isEmpty) return true;
  final idx = session.activeAudioTrack.clamp(0, session.audioTracks.length - 1);
  return session.audioTracks[idx].enabled;
}

/// Video track count for a camera.
int getWebRtcVideoTrackCount(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.videoTracks.length ?? 0;

/// Audio track count for a camera.
int getWebRtcAudioTrackCount(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.audioTracks.length ?? 0;

/// Active video track index for a camera.
int getWebRtcActiveVideoTrack(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.activeVideoTrack ?? 0;

/// Negotiated codec for a camera (from active video track).
String? getWebRtcNegotiatedCodec(AppState state, String slug) {
  final session = state.webRtc.sessions[slug];
  if (session == null || session.videoTracks.isEmpty) return null;
  final idx = session.activeVideoTrack.clamp(0, session.videoTracks.length - 1);
  final codec = session.videoTracks[idx].codec;
  return codec.isEmpty ? null : codec;
}

/// Active audio track index for a camera.
int getWebRtcActiveAudioTrack(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.activeAudioTrack ?? 0;

/// Formatted track info string (e.g. "V:2 A:0"), or null if not connected.
String? selectTrackInfo(AppState state, String slug) {
  final session = state.webRtc.sessions[slug];
  if (session == null ||
      session.connectionState != WebRtcConnectionState.sessionConnected) {
    return null;
  }
  return 'V:${session.videoTracks.length} A:${session.audioTracks.length}';
}

/// All slugs with connected sessions (memoized — safe for shallow compare).
final getConnectedWebRtcSlugs =
    createSelector1<AppState, Map<String, WebRtcSessionState>, List<String>>(
      (state) => state.webRtc.sessions,
      (sessions) => sessions.entries
          .where(
            (e) =>
                e.value.connectionState ==
                WebRtcConnectionState.sessionConnected,
          )
          .map((e) => e.key)
          .toList(),
    );
