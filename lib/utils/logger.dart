import 'dart:developer' as dev;

import 'i_logger.dart';
import 'log_level.dart';

/// Centralized logger for the application.
///
/// Singleton that implements [ILogger] with level-based filtering.
/// Messages below the current [LogLevel] are silently dropped.
///
/// Usage:
/// ```dart
/// Logger().info('Connection established');
/// Logger().warn('Retrying connection');
/// Logger().error('Connection failed', error: e, stackTrace: st);
/// Logger().debug('SDP offer: $sdp'); // suppressed when level > debug
/// ```
class Logger implements ILogger {
  /// Singleton instance.
  static final Logger _instance = Logger._();

  Logger._();

  /// Returns the singleton instance.
  factory Logger() => _instance;

  static const String _name = 'SignalR';

  /// Current minimum log level. Messages below this are dropped.
  LogLevel _level = LogLevel.info;

  /// The current log level.
  LogLevel get level => _level;

  /// Format: HH:MM:SS.mmm
  String get _ts {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    final ms = now.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  @override
  void setLevel(LogLevel level) => _level = level;

  @override
  void debug(String message) {
    if (_level.index > LogLevel.debug.index) return;
    dev.log('$_ts $message', name: '$_name.DEBUG');
  }

  @override
  void info(String message) {
    if (_level.index > LogLevel.info.index) return;
    dev.log('$_ts $message', name: _name);
  }

  @override
  void warn(String message) {
    if (_level.index > LogLevel.warning.index) return;
    dev.log('$_ts $message', name: '$_name.WARN');
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    // Errors are never filtered.
    final buf = StringBuffer('$_ts $message');
    if (error != null) buf.write('\n  Error: $error');
    if (stackTrace != null) buf.write('\n  StackTrace: $stackTrace');
    dev.log(buf.toString(), name: '$_name.ERROR');
  }
}
