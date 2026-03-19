import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:signalr_netcore/http_connection_options.dart';
import 'package:signalr_netcore/hub_connection.dart';
import 'package:signalr_netcore/hub_connection_builder.dart';

import '../utils/logger.dart';
import 'signalr_config.dart';

typedef SignalRMessageCallback = void Function(List<Object?>? args);

class SignalRConnectionManager {
  SignalRConnectionManager({
    required SignalRConfig config,
    this.onConnected,
    this.onDisconnected,
    this.onReconnecting,
    this.onReconnected,
  }) : _config = config;

  final SignalRConfig _config;
  final VoidCallback? onConnected;
  final void Function(Exception? error)? onDisconnected;
  final void Function(Exception? error)? onReconnecting;
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

  HubConnection? get connection => _connection;
  HubConnectionState? get state => _connection?.state;
  String? get connectionId => _connection?.connectionId;
  bool get isConnected => _connection?.state == HubConnectionState.Connected;
  bool get isConnecting => _isConnecting;

  Future<bool> connect({VoidCallback? onConnectionCreated}) async {
    _manualStop = false;
    _createConnection();
    onConnectionCreated?.call();
    return _startConnection();
  }

  Future<void> disconnect() async {
    _manualStop = true;
    _cancelTimers();
    _retryCount = 0;
    _closeRetryCount = 0;
    _isConnecting = false;

    if (_connection != null) {
      try {
        await _connection?.stop();
        Logger().info('SignalRConnectionManager: Disconnected');
      } catch (e) {
        Logger().error('SignalRConnectionManager: Error disconnecting: $e');
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    _connection = null;
  }

  void on(String methodName, SignalRMessageCallback handler) {
    _connection?.on(methodName, handler);
  }

  void off(String methodName) {
    _connection?.off(methodName);
  }

  Future<void> invoke(String methodName, {List<Object>? args}) async {
    if (!isConnected) {
      Logger().warn('SignalRConnectionManager: Cannot invoke - not connected');
      return;
    }
    await _connection?.invoke(methodName, args: args);
  }

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

    if (!_manualStop) {
      _reconnectAfterClose();
    }
  }

  void _reconnectAfterClose() {
    if (_disposed) return;

    _closeRetryCount++;
    final delaySecs = math.min(
      5 * math.pow(2, _closeRetryCount - 1).toInt(),
      _maxCloseRetryDelaySecs,
    );
    final jitterMs = math.Random().nextInt(1000);

    Logger().info(
      'SignalRConnectionManager: Fallback retry #$_closeRetryCount in ${delaySecs}s (+${jitterMs}ms jitter)',
    );

    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: delaySecs, milliseconds: jitterMs), () async {
      if (_disposed) return;

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

  void _startTimeout() {
    _connectTimeout = Timer(_connectionTimeout, () async {
      Logger().warn('SignalRConnectionManager: Connection timeout');
      _isConnecting = false;
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
