import 'dart:async';
import 'dart:developer' as dev;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:signalr_netcore/http_connection_options.dart';
import 'package:signalr_netcore/hub_connection.dart';
import 'package:signalr_netcore/hub_connection_builder.dart';

import 'signalr_config.dart';

/// Callback for when a SignalR message is received.
typedef SignalRMessageCallback = void Function(List<Object?>? args);

/// Manages SignalR hub connection lifecycle.
///
/// Handles connection creation, start/stop, retry logic with exponential backoff,
/// and event handler binding. Separated from message handling for clarity.
class SignalRConnectionManager {
  SignalRConnectionManager({
    required SignalRConfig config,
    this.onConnected,
    this.onDisconnected,
    this.onReconnecting,
    this.onReconnected,
  }) : _config = config;

  final SignalRConfig _config;

  /// Callback when connection is established.
  final VoidCallback? onConnected;

  /// Callback when connection is closed.
  final void Function(Exception? error)? onDisconnected;

  /// Callback when reconnecting.
  final void Function(Exception? error)? onReconnecting;

  /// Callback when reconnected.
  final void Function(String? connectionId)? onReconnected;

  HubConnection? _connection;
  Timer? _connectTimeout;
  Timer? _retryTimer;
  int _retryCount = 0;
  bool _isConnecting = false;

  static const Duration _connectionTimeout = Duration(seconds: 15);

  // ═══════════════════════════════════════════════════════════════════════════
  // Public API
  // ═══════════════════════════════════════════════════════════════════════════

  /// The underlying hub connection (for advanced usage).
  HubConnection? get connection => _connection;

  /// Current connection state.
  HubConnectionState? get state => _connection?.state;

  /// Connection ID from the server.
  String? get connectionId => _connection?.connectionId;

  /// Whether the connection is currently connected.
  bool get isConnected => _connection?.state == HubConnectionState.Connected;

  /// Whether the connection is currently in progress.
  bool get isConnecting => _isConnecting;

  /// Start the connection.
  Future<bool> connect() async {
    _createConnection();
    return _startConnection();
  }

  /// Stop the connection.
  Future<void> disconnect() async {
    _cancelTimers();
    _retryCount = 0;
    _isConnecting = false;

    if (_connection?.state == HubConnectionState.Connected) {
      try {
        await _connection?.stop();
        dev.log('SignalRConnectionManager: Disconnected');
      } catch (e) {
        dev.log('SignalRConnectionManager: Error disconnecting: $e');
      }
    }
  }

  /// Dispose of all resources.
  Future<void> dispose() async {
    await disconnect();
    _unbindEventHandlers();
    _connection = null;
  }

  /// Register a handler for a SignalR method.
  void on(String methodName, SignalRMessageCallback handler) {
    _connection?.on(methodName, handler);
  }

  /// Unregister a handler for a SignalR method.
  void off(String methodName) {
    _connection?.off(methodName);
  }

  /// Invoke a method on the hub.
  Future<void> invoke(String methodName, {List<Object>? args}) async {
    if (!isConnected) {
      dev.log('SignalRConnectionManager: Cannot invoke - not connected');
      return;
    }
    await _connection?.invoke(methodName, args: args);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection Management
  // ═══════════════════════════════════════════════════════════════════════════

  void _createConnection() {
    if (_connection != null) return;

    dev.log(
      'SignalRConnectionManager: Creating connection to ${_config.signalRServerUrl}',
    );

    _connection = HubConnectionBuilder()
        .withUrl(
          _config.signalRServerUrl,
          options: HttpConnectionOptions(skipNegotiation: false),
        )
        .withAutomaticReconnect(
          retryDelays: List.filled(4, _config.reconnectionTimeout),
        )
        .build();

    _bindEventHandlers();
  }

  Future<bool> _startConnection() async {
    _cancelTimers();

    if (_connection == null) {
      dev.log('SignalRConnectionManager: No connection to start');
      return false;
    }

    if (isConnected) {
      dev.log('SignalRConnectionManager: Already connected');
      onConnected?.call();
      return true;
    }

    if (_connection!.state == HubConnectionState.Connecting) {
      dev.log('SignalRConnectionManager: Already connecting');
      return false;
    }

    _isConnecting = true;
    _startTimeout();

    try {
      await _connection!.start();
      _cancelTimers();
      _retryCount = 0;
      _isConnecting = false;

      dev.log(
        'SignalRConnectionManager: Connected (${_connection!.connectionId})',
      );
      onConnected?.call();
      return true;
    } catch (e) {
      _isConnecting = false;
      dev.log('SignalRConnectionManager: Connection failed: $e');
      return _scheduleRetry();
    }
  }

  bool _scheduleRetry() {
    _retryCount++;
    if (_retryCount > _config.reconnectionRetryCount) {
      dev.log('SignalRConnectionManager: Max retries exceeded');
      return false;
    }

    final delay =
        _config.reconnectionTimeout * math.pow(2, _retryCount - 1).toInt();
    dev.log('SignalRConnectionManager: Retry $_retryCount in ${delay}ms');

    _retryTimer = Timer(Duration(milliseconds: delay), () {
      _startConnection();
    });
    return false;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Event Handlers
  // ═══════════════════════════════════════════════════════════════════════════

  void _bindEventHandlers() {
    _connection?.onclose(_handleClose);
    _connection?.onreconnecting(_handleReconnecting);
    _connection?.onreconnected(_handleReconnected);
  }

  void _unbindEventHandlers() {
    // Note: signalr_netcore doesn't have unbind for lifecycle events
  }

  void _handleClose({Exception? error}) {
    dev.log('SignalRConnectionManager: Connection closed: $error');
    onDisconnected?.call(error);
  }

  void _handleReconnecting({Exception? error}) {
    dev.log('SignalRConnectionManager: Reconnecting: $error');
    onReconnecting?.call(error);
  }

  void _handleReconnected({String? connectionId}) {
    dev.log('SignalRConnectionManager: Reconnected: $connectionId');
    _retryCount = 0;
    onReconnected?.call(connectionId);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Timeout Management
  // ═══════════════════════════════════════════════════════════════════════════

  void _startTimeout() {
    _connectTimeout = Timer(_connectionTimeout, () {
      dev.log('SignalRConnectionManager: Connection timeout');
      _isConnecting = false;
      _scheduleRetry();
    });
  }

  void _cancelTimers() {
    _connectTimeout?.cancel();
    _connectTimeout = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }
}
