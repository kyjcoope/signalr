abstract interface class IWebrtcSession {
  Stream<String> get messageStream;
  void sendDataChannelMessage(String text);
}
