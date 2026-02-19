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

/// Whether audio is enabled for a camera.
bool isWebRtcAudioEnabled(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.audioEnabled ?? true;

/// Video track count for a camera.
int getWebRtcVideoTrackCount(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.videoTrackCount ?? 0;

/// Audio track count for a camera.
int getWebRtcAudioTrackCount(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.audioTrackCount ?? 0;

/// Active video track index for a camera.
int getWebRtcActiveVideoTrack(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.activeVideoTrack ?? 0;

/// Negotiated codec for a camera.
String? getWebRtcNegotiatedCodec(AppState state, String slug) =>
    state.webRtc.sessions[slug]?.negotiatedCodec;

/// Formatted track info string (e.g. "V:2 A:0"), or null if not connected.
String? selectTrackInfo(AppState state, String slug) {
  final session = state.webRtc.sessions[slug];
  if (session == null ||
      session.connectionState != WebRtcConnectionState.sessionConnected) {
    return null;
  }
  return 'V:${session.videoTrackCount} A:${session.audioTrackCount}';
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
