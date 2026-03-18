import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:signalr_netcore/http_connection_options.dart';
import 'package:signalr_netcore/hub_connection.dart';
import 'package:signalr_netcore/hub_connection_builder.dart';

import '../utils/logger.dart';
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
  bool _disposed = false;
  bool _manualStop = false;
  int _closeRetryCount = 0;

  static const Duration _connectionTimeout = Duration(seconds: 15);
  static const int _maxCloseRetryDelaySecs = 30;

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
  ///
  /// [onConnectionCreated] is called after the hub connection object exists
  /// but before `start()` — this is the right moment to bind message handlers
  /// so they're active before any server responses arrive.
  Future<bool> connect({VoidCallback? onConnectionCreated}) async {
    _manualStop = false;
    _createConnection();
    onConnectionCreated?.call();
    return _startConnection();
  }

  /// Stop the connection intentionally.
  ///
  /// Sets [_manualStop] to prevent the fallback reconnect loop from
  /// firing when the close event arrives.
  Future<void> disconnect() async {
    _manualStop = true;
    _cancelTimers();
    _retryCount = 0;
    _closeRetryCount = 0;
    _isConnecting = false;

    // Stop connection regardless of current state (Connected, Connecting, etc.)
    if (_connection != null) {
      try {
        await _connection?.stop();
        Logger().info('SignalRConnectionManager: Disconnected');
      } catch (e) {
        Logger().error('SignalRConnectionManager: Error disconnecting: $e');
      }
    }
  }

  /// Dispose of all resources.
  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
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
      Logger().warn('SignalRConnectionManager: Cannot invoke - not connected');
      return;
    }
    await _connection?.invoke(methodName, args: args);
  }

  /// Leave a signaling session.
  ///
  /// This notifies the server that the client is leaving the session,
  /// allowing proper cleanup on the server side.
  Future<void> leaveSession(String sessionId) async {
    if (!isConnected) {
      Logger().warn(
        'SignalRConnectionManager: Cannot leave session - not connected',
      );
      return;
    }
    try {
      await _connection?.invoke('LeaveSession', args: [sessionId]);
      Logger().info('SignalRConnectionManager: Left session $sessionId');
    } catch (e) {
      Logger().error('SignalRConnectionManager: Error leaving session: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection Management
  // ═══════════════════════════════════════════════════════════════════════════

  void _createConnection() {
    if (_connection != null) return;

    Logger().info(
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
      Logger().warn('SignalRConnectionManager: No connection to start');
      return false;
    }

    if (isConnected) {
      Logger().info('SignalRConnectionManager: Already connected');
      return true;
    }

    if (_connection!.state == HubConnectionState.Connecting) {
      Logger().info('SignalRConnectionManager: Already connecting');
      return false;
    }

    _isConnecting = true;
    _startTimeout();

    try {
      await _connection!.start();
      _cancelTimers();
      _retryCount = 0;
      _isConnecting = false;

      Logger().info(
        'SignalRConnectionManager: Connected (${_connection!.connectionId})',
      );
      onConnected?.call();
      return true;
    } catch (e) {
      _isConnecting = false;
      Logger().error('SignalRConnectionManager: Connection failed: $e');
      return _scheduleRetry();
    }
  }

  bool _scheduleRetry() {
    _retryCount++;
    if (_retryCount > _config.reconnectionRetryCount) {
      Logger().warn('SignalRConnectionManager: Max retries exceeded');
      return false;
    }

    final delay =
        _config.reconnectionTimeout * math.pow(2, _retryCount - 1).toInt();
    Logger().info('SignalRConnectionManager: Retry $_retryCount in ${delay}ms');

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

  void _handleClose({Exception? error}) {
    Logger().warn(
      'SignalRConnectionManager: Connection closed (built-in reconnect exhausted): $error',
    );
    onDisconnected?.call(error);

    // Only start fallback reconnect if the close was NOT intentional.
    // Manual disconnect sets _manualStop = true to suppress this.
    if (!_manualStop) {
      _reconnectAfterClose();
    }
  }

  /// Retry connection indefinitely after the built-in reconnect gives up.
  ///
  /// Uses exponential backoff capped at [_maxCloseRetryDelaySecs].
  /// Creates a brand-new HubConnection each time (the old one is dead).
  void _reconnectAfterClose() {
    if (_disposed) return;

    _closeRetryCount++;
    final delaySecs = math.min(
      5 * math.pow(2, _closeRetryCount - 1).toInt(),
      _maxCloseRetryDelaySecs,
    );
    // Randomize delay to prevent thundering herd when server drops many clients
    final jitterMs = math.Random().nextInt(1000);

    Logger().info(
      'SignalRConnectionManager: Fallback retry #$_closeRetryCount in ${delaySecs}s (+${jitterMs}ms jitter)',
    );

    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: delaySecs, milliseconds: jitterMs), () async {
      if (_disposed) return;

      // Destroy the dead connection and create a fresh one
      _connection = null;
      _createConnection();

      try {
        await _connection!.start();
        _closeRetryCount = 0;
        _isConnecting = false;

        Logger().info(
          'SignalRConnectionManager: Fallback reconnect succeeded (${_connection!.connectionId})',
        );
        onReconnected?.call(_connection!.connectionId);
      } catch (e) {
        Logger().warn(
          'SignalRConnectionManager: Fallback retry #$_closeRetryCount failed: $e',
        );
        _reconnectAfterClose();
      }
    });
  }

  void _handleReconnecting({Exception? error}) {
    Logger().warn('SignalRConnectionManager: Reconnecting: $error');
    onReconnecting?.call(error);
  }

  void _handleReconnected({String? connectionId}) {
    Logger().info('SignalRConnectionManager: Reconnected: $connectionId');
    _retryCount = 0;
    onReconnected?.call(connectionId);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Timeout Management
  // ═══════════════════════════════════════════════════════════════════════════

  void _startTimeout() {
    _connectTimeout = Timer(_connectionTimeout, () async {
      Logger().warn('SignalRConnectionManager: Connection timeout');
      _isConnecting = false;
      // Tear down the hung connection attempt before retrying.
      // Without this, the late start() success fires onConnected a second
      // time, causing a duplicate register send.
      try {
        await _connection?.stop();
      } catch (_) {}
      _connection = null;
      _createConnection();
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
