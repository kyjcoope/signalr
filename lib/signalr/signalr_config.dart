/// Configuration for the SignalR service.
class SignalRConfig {
  SignalRConfig({
    required this.signalRServerUrl,
    String? clientId,
    this.reconnectionTimeout = 5000,
    this.reconnectionRetryCount = 5,
  }) : clientId = clientId ?? _generateClientId();

  /// The URL of the SignalR hub.
  final String signalRServerUrl;

  /// Unique client identifier.
  final String clientId;

  /// Timeout between reconnection attempts in milliseconds.
  final int reconnectionTimeout;

  /// Maximum number of reconnection attempts before giving up.
  final int reconnectionRetryCount;

  /// Generate a unique client ID using timestamp and random values.
  static String _generateClientId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final random = (now % 10000).toString().padLeft(4, '0');
    return 'flutter_$now$random';
  }
}
