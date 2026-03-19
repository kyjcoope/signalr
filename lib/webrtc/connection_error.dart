enum ConnectionError {
  sessionAlreadyExists(100, 'Session already exists'),
  sessionLimitExceeded(101, 'Active session limit exceeded'),
  invalidSessionId(106, 'Invalid session'),
  webrtcSessionError(201, 'WebRTC session error'),
  deviceUnavailable(480, 'Device is currently unavailable'),
  connectTimeout(null, 'Connection timed out'),
  negotiationTimeout(null, 'Negotiation timed out'),
  negotiationFailed(null, 'SDP negotiation failed'),
  iceFailed(null, 'ICE connection failed'),
  peerDisconnected(null, 'Camera disconnected'),
  serverClosed(null, 'Server closed the session'),
  reconnectFailed(null, 'Reconnect failed'),
  unknown(null, 'Connection failed');

  const ConnectionError(this.serverCode, this.displayMessage);

  final int? serverCode;
  final String displayMessage;

  static ConnectionError fromServerCode(int code) {
    return values.where((e) => e.serverCode == code).firstOrNull ?? unknown;
  }

  bool get isRecoverable =>
      this != sessionLimitExceeded && this != deviceUnavailable;
}
