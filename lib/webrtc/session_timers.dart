import 'dart:async';

import '../utils/logger.dart';

class SessionTimers {
  SessionTimers({
    required this.tag,
    required this.onNegotiationTimeout,
    required this.onConnectTimeout,
    this.negotiationDuration = const Duration(seconds: 30),
    this.connectDuration = const Duration(seconds: 45),
  });

  final String tag;
  final VoidCallback onNegotiationTimeout;
  final VoidCallback onConnectTimeout;
  final Duration negotiationDuration;
  final Duration connectDuration;

  Timer? _negotiationTimer;
  Timer? _connectTimer;

  void startNegotiation() {
    cancelNegotiation();
    _negotiationTimer = Timer(negotiationDuration, () {
      Logger().warn('$tag Negotiation timeout');
      onNegotiationTimeout();
    });
  }

  void cancelNegotiation() {
    _negotiationTimer?.cancel();
    _negotiationTimer = null;
  }

  void startConnect() {
    cancelConnect();
    _connectTimer = Timer(connectDuration, () {
      Logger().warn('$tag Connect phase timeout - no session received');
      onConnectTimeout();
    });
  }

  void cancelConnect() {
    _connectTimer?.cancel();
    _connectTimer = null;
  }

  void cancelAll() {
    cancelNegotiation();
    cancelConnect();
  }
}

typedef VoidCallback = void Function();
