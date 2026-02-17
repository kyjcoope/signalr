import 'dart:async';

import '../utils/logger.dart';

/// Manages session timers for WebRTC connections.
///
/// Handles negotiation timeout and connect phase timeout with
/// consistent start/cancel patterns.
class SessionTimers {
  SessionTimers({
    required this.tag,
    required this.onNegotiationTimeout,
    required this.onConnectTimeout,
    this.negotiationDuration = const Duration(seconds: 30),
    this.connectDuration = const Duration(seconds: 15),
  });

  final String tag;
  final VoidCallback onNegotiationTimeout;
  final VoidCallback onConnectTimeout;
  final Duration negotiationDuration;
  final Duration connectDuration;

  Timer? _negotiationTimer;
  Timer? _connectTimer;

  /// Start the negotiation timeout.
  void startNegotiation() {
    cancelNegotiation();
    _negotiationTimer = Timer(negotiationDuration, () {
      Logger().warn('$tag ❌ Negotiation timeout');
      onNegotiationTimeout();
    });
  }

  /// Cancel the negotiation timeout.
  void cancelNegotiation() {
    _negotiationTimer?.cancel();
    _negotiationTimer = null;
  }

  /// Start the connect phase timeout.
  void startConnect() {
    cancelConnect();
    _connectTimer = Timer(connectDuration, () {
      Logger().warn('$tag ⏰ Connect phase timeout - no session received');
      onConnectTimeout();
    });
  }

  /// Cancel the connect timeout.
  void cancelConnect() {
    _connectTimer?.cancel();
    _connectTimer = null;
  }

  /// Cancel all timers.
  void cancelAll() {
    cancelNegotiation();
    cancelConnect();
  }

  /// Whether the negotiation timer is active.
  bool get isNegotiating => _negotiationTimer?.isActive ?? false;

  /// Whether the connect timer is active.
  bool get isConnecting => _connectTimer?.isActive ?? false;
}

/// Callback type for timer events.
typedef VoidCallback = void Function();
