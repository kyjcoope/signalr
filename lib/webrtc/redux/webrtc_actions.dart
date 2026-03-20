import 'webrtc_state.dart';

class SetSessionSnapshot {
  final String slug;
  final WebRtcSessionState snapshot;
  SetSessionSnapshot(this.slug, this.snapshot);
}

class RemoveSession {
  final String slug;
  RemoveSession(this.slug);
}

class ClearAllSessions {}

class SetSessionQueued {
  final String slug;
  SetSessionQueued(this.slug);
}

