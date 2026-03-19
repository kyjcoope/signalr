enum SessionConnectionState {
  idle,
  waitingForSession,
  initializingPeer,
  settingRemoteDescription,
  creatingAnswer,
  sendingAnswer,
  exchangingIce,
  connected,
  disconnected,
  reconnecting,
  failed,
  closed,
}

extension SessionConnectionStateX on SessionConnectionState {
  bool get isActive =>
      this == SessionConnectionState.connected ||
      this == SessionConnectionState.exchangingIce ||
      this == SessionConnectionState.disconnected;

  bool get isTerminal =>
      this == SessionConnectionState.failed ||
      this == SessionConnectionState.closed;
}
