import 'dart:async';

import '../signalr/signalr_messages.dart';

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
