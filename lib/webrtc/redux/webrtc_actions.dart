import 'webrtc_state.dart';

/// Set the full session snapshot for a camera (the primary sync action).
///
/// Called by `syncSessionToRedux` to push the hub's current state into Redux.
class SetSessionSnapshot {
  final String slug;
  final WebRtcSessionState snapshot;
  SetSessionSnapshot(this.slug, this.snapshot);
}

/// Remove a single camera session (on disconnect).
class RemoveSession {
  final String slug;
  RemoveSession(this.slug);
}

/// Clear all sessions (on shutdown).
class ClearAllSessions {}
