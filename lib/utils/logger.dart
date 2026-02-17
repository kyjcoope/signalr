import 'dart:developer' as dev;

/// Centralized logger for the application.
///
/// Provides `info`, `warn`, and `error` methods that currently delegate
/// to `dart:developer` `dev.log`. This abstraction allows future expansion
/// (e.g., remote logging, file logging, log levels) without changing
/// call sites throughout the app.
///
/// Usage:
/// ```dart
/// Logger().info('Connection established');
/// Logger().warn('Retrying connection');
/// Logger().error('Connection failed: $e');
/// ```
class Logger {
  /// Singleton instance.
  static final Logger _instance = Logger._();

  Logger._();

  /// Returns the singleton instance.
  factory Logger() => _instance;

  static const String _name = 'SignalR';

  /// Format: HH:MM:SS.mmm
  String get _ts {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    final ms = now.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  /// Log an informational message.
  void info(String message) {
    dev.log('$_ts $message', name: _name);
  }

  /// Log a warning message.
  void warn(String message) {
    dev.log('$_ts $message', name: '$_name.WARN');
  }

  /// Log an error message.
  void error(String message) {
    dev.log('$_ts $message', name: '$_name.ERROR');
  }
}
