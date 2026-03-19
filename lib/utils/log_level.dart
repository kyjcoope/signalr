/// Log severity levels, ordered from most verbose to most critical.
///
/// The [Logger] filters messages below its current level.
/// Default is [LogLevel.info] so [debug] messages are suppressed in production.
enum LogLevel {
  /// Verbose diagnostic output (SDP dumps, ICE candidates, stats).
  debug,

  /// Normal operational messages.
  info,

  /// Potential problems that don't prevent operation.
  warning,

  /// Failures that need attention.
  error,
}
