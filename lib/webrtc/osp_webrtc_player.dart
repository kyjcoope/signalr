import 'dart:async';

/// Interface for WebRTC players that can receive SignalR messages.
///
/// Matches the web's `OSPVideoWebRTCPlayerRenderer` interface pattern.
abstract class OSPVideoWebRTCPlayer {
  /// Unique player ID for this instance.
  String get playerId;

  /// Device ID this player is connected to.
  String get deviceId;

  /// Session ID assigned by the signaling server.
  String? get sessionId;

  /// Set the session ID.
  set sessionId(String? value);

  /// Handle incoming SignalR messages.
  void onSignalRMessage(OSPSignalRMessage message);

  /// Subscription to the SignalR service message stream.
  StreamSubscription<OSPSignalRMessage>? subscription;
}

/// Message dispatched from SignalR service to registered players.
///
/// Matches the web's `OSPSignalRMessage` interface.
class OSPSignalRMessage {
  OSPSignalRMessage({required this.method, required this.detail});

  /// The type of SignalR event.
  final OSPSignalRMessageType method;

  /// Event-specific details/payload.
  final dynamic detail;
}

/// SignalR message types dispatched to players.
///
/// Matches the web's `OSPWebRTCSignalRMessageType` enum.
enum OSPSignalRMessageType {
  /// SignalR connection closed.
  onSignalClosed,

  /// SignalR connection is ready.
  onSignalReady,

  /// Connection timeout occurred.
  onSignalTimeout,

  /// Received an invite (SDP offer) from the server.
  onSignalInvite,

  /// Received an ICE candidate (trickle).
  onSignalTrickle,

  /// Received ICE server configuration.
  onSignalIceServers,

  /// An error occurred.
  onSignalError,
}
