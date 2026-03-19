import 'log_level.dart';

/// Abstract logger interface.
///
/// All logging in the application flows through this contract.
/// Implementations handle filtering, formatting, and output routing.
abstract interface class ILogger {
  /// Log a verbose diagnostic message (suppressed unless level ≤ debug).
  void debug(String message);

  /// Log a normal operational message.
  void info(String message);

  /// Log a warning — something unexpected but non-fatal.
  void warn(String message);

  /// Log an error with optional cause and stack trace.
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  });

  /// Change the minimum log level at runtime.
  void setLevel(LogLevel level);
}
