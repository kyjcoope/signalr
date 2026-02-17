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

  /// Log an informational message.
  void info(String message) {
    dev.log(message);
  }

  /// Log a warning message.
  void warn(String message) {
    dev.log('[WARN] $message');
  }

  /// Log an error message.
  void error(String message) {
    dev.log('[ERROR] $message');
  }
}
