/// Connection states for WebRTC session lifecycle.
///
/// Provides clear state tracking to prevent invalid operations
/// and simplify debugging.
enum SessionConnectionState {
  /// Initial state, no connection attempt made.
  idle,

  /// Waiting for session ID from signaling server.
  waitingForSession,

  /// Received session ID, initializing peer connection.
  initializingPeer,

  /// Received offer, setting remote description.
  settingRemoteDescription,

  /// Creating SDP answer.
  creatingAnswer,

  /// Sending answer to signaling server.
  sendingAnswer,

  /// Waiting for ICE candidates to exchange.
  exchangingIce,

  /// ICE connection established, media flowing.
  connected,

  /// ICE connection temporarily lost, may recover.
  disconnected,

  /// ICE restart in progress.
  restarting,

  /// Fatal error or connection failed.
  failed,

  /// Session intentionally closed.
  closed,
}

/// Extension for state queries.
extension SessionConnectionStateX on SessionConnectionState {
  /// Whether the session is in an active state where operations are allowed.
  bool get isActive =>
      this == SessionConnectionState.connected ||
      this == SessionConnectionState.exchangingIce ||
      this == SessionConnectionState.disconnected;

  /// Whether the session is in a transitional state.
  bool get isTransitioning =>
      this == SessionConnectionState.waitingForSession ||
      this == SessionConnectionState.initializingPeer ||
      this == SessionConnectionState.settingRemoteDescription ||
      this == SessionConnectionState.creatingAnswer ||
      this == SessionConnectionState.sendingAnswer ||
      this == SessionConnectionState.restarting;

  /// Whether the session has terminated (failed or closed).
  bool get isTerminal =>
      this == SessionConnectionState.failed ||
      this == SessionConnectionState.closed;

  /// Whether ICE restart is allowed in this state.
  bool get canRestartIce =>
      this == SessionConnectionState.connected ||
      this == SessionConnectionState.disconnected;
}
