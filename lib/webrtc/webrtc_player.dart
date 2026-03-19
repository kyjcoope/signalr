import '../signalr/signalr_messages.dart';

abstract class VideoWebRTCPlayer {
  String get playerId;
  String get deviceId;
  String? get sessionId;
  set sessionId(String? value);

  void onSignalRMessage(SignalRMessage message);
}
