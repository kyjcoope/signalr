/// Unified connection error types for WebRTC camera sessions.
///
/// Covers both server errors (parsed from JSON-RPC error codes) and
/// client-side lifecycle errors (timeouts, ICE failures, etc.).
/// Each value carries a user-facing [displayMessage] for the UI.
enum ConnectionError {
  // ── Server errors (from JSON-RPC) ──────────────────────────────────────

  /// Error 100: A session already exists for this camera on the server.
  sessionAlreadyExists(100, 'Session already exists'),

  /// Error 101: The server's active session limit has been reached.
  sessionLimitExceeded(101, 'Active session limit exceeded'),

  /// Error 201: Generic WebRTC session error on the server.
  webrtcSessionError(201, 'WebRTC session error'),

  /// Error 480: The target camera/device is not reachable.
  deviceUnavailable(480, 'Device is currently unavailable'),

  // ── Client-side lifecycle errors ───────────────────────────────────────

  /// No session or invite received within the connect timeout window.
  connectTimeout(null, 'Connection timed out'),

  /// SDP negotiation did not complete in time.
  negotiationTimeout(null, 'Negotiation timed out'),

  /// SDP negotiation threw an exception.
  negotiationFailed(null, 'SDP negotiation failed'),

  /// ICE connection entered the "failed" state.
  iceFailed(null, 'ICE connection failed'),

  /// The remote peer (camera) disconnected.
  peerDisconnected(null, 'Camera disconnected'),

  /// The server closed the session unexpectedly.
  serverClosed(null, 'Server closed the session'),

  /// Reconnect attempts exhausted.
  reconnectFailed(null, 'Reconnect failed'),

  /// Fallback for unrecognized error codes.
  unknown(null, 'Connection failed');

  const ConnectionError(this.serverCode, this.displayMessage);

  /// Server error code, or `null` for client-side errors.
  final int? serverCode;

  /// User-facing error description suitable for display in the UI.
  final String displayMessage;

  /// Look up a [ConnectionError] by server error code.
  ///
  /// Returns [unknown] if no matching code is found.
  static ConnectionError fromServerCode(int code) {
    return values.where((e) => e.serverCode == code).firstOrNull ?? unknown;
  }
}
