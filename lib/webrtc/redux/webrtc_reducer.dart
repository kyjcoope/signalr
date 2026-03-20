import 'webrtc_actions.dart';
import 'webrtc_state.dart';

WebRtcState webRtcReducer(WebRtcState state, dynamic action) {
  if (action is SetSessionSnapshot) {
    final updated = Map<String, WebRtcSessionState>.from(state.sessions);
    updated[action.slug] = action.snapshot;
    return state.copyWith(sessions: updated);
  }

  if (action is RemoveSession) {
    final updated = Map<String, WebRtcSessionState>.from(state.sessions)
      ..remove(action.slug);
    return state.copyWith(sessions: updated);
  }

  if (action is SetSessionQueued) {
    if (state.sessions.containsKey(action.slug)) return state;
    final updated = Map<String, WebRtcSessionState>.from(state.sessions);
    updated[action.slug] = const WebRtcSessionState(
      connectionState: WebRtcConnectionState.sessionPending,
    );
    return state.copyWith(sessions: updated);
  }

  if (action is ClearAllSessions) {
    return const WebRtcState();
  }

  return state;
}

