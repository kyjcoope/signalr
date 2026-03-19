class SignalRConfig {
  SignalRConfig({
    required this.signalRServerUrl,
    String? clientId,
    this.reconnectionTimeout = 5000,
    this.reconnectionRetryCount = 5,
  }) : clientId = clientId ?? _generateClientId();

  final String signalRServerUrl;
  final String clientId;
  final int reconnectionTimeout;
  final int reconnectionRetryCount;

  static String _generateClientId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final random = (now % 10000).toString().padLeft(4, '0');
    return 'flutter_$now$random';
  }
}
