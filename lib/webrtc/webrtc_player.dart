import 'dart:async';

/// Interface for WebRTC players that receive SignalR messages.
abstract class VideoWebRTCPlayer {
  /// Unique identifier for this player instance.
  String get playerId;

  /// The device ID this player is connected to.
  String get deviceId;

  /// The current session ID, if connected.
  String? get sessionId;

  /// Set the session ID.
  set sessionId(String? value);

  /// Handle incoming SignalR message.
  void onSignalRMessage(SignalRMessage message);

  /// Subscription to the SignalR message stream.
  StreamSubscription<SignalRMessage>? subscription;
}

/// SignalR message wrapper.
class SignalRMessage {
  SignalRMessage({required this.method, required this.detail});

  /// The message type.
  final SignalRMessageType method;

  /// The message detail/payload.
  final dynamic detail;

  @override
  String toString() => 'SignalRMessage(method: $method, detail: $detail)';
}

/// SignalR message types.
enum SignalRMessageType {
  onSignalReady,
  onSignalClosed,
  onSignalInvite,
  onSignalTrickle,
  onSignalTimeout,
  onSignalError,
  onSignalIceServers,
}
