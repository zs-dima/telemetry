/// Severity of an event, ordered.
///
/// Two numbers travel with every level, one per ecosystem that owns a scale:
///
/// * [severityNumber] is OpenTelemetry's, the lower bound of the level's range
///   (TRACE 1-4, DEBUG 5-8, INFO 9-12, WARN 13-16, ERROR 17-20, FATAL 21-24).
///   Exporters, Sentry's structured logs and stored rows use it.
/// * [developerLevel] is `package:logging`'s 0-2000 scale, read by
///   `dart:developer` `log(level:)` and the DevTools Logging view (FINE 500,
///   INFO 800, WARNING 900, SEVERE 1000, SHOUT 1200). Write-only: the scales
///   overlap (`300`, `500`, `1000`… are valid on both), so a stored number must
///   come from one of them, and that one is [severityNumber].
///
/// How much trace noise is rendered is a separate dial, `LogEvent.verbosity`
/// with `TelemetryOptions.maxVerbosity`.
enum LogLevel implements Comparable<LogLevel> {
  /// Fine-grained tracing: frame-by-frame detail, protocol chatter.
  trace(1, 300),

  /// Developer-facing detail: state transitions, timings, cache hits.
  debug(5, 500),

  /// Normal, noteworthy operation: one line per meaningful operation.
  info(9, 800),

  /// Something recovered, degraded, or is suspicious, but is not an incident.
  warn(13, 900),

  /// An operation failed. Auto-reported to the crash reporter.
  error(17, 1000),

  /// The app cannot continue in a meaningful state. Auto-reported.
  fatal(21, 1200);

  const LogLevel(this.severityNumber, this.developerLevel);

  /// OpenTelemetry severity number (lower bound of the level's range).
  final int severityNumber;

  /// `package:logging` / `dart:developer` level. Write-only; see [fromValue].
  final int developerLevel;

  /// Single-character prefix used by the console renderer.
  String get prefix => switch (this) {
    trace => 'T',
    debug => 'D',
    info => 'I',
    warn => 'W',
    error => 'E',
    fatal => 'F',
  };

  /// Whether this level is at least as severe as [other].
  bool operator >=(LogLevel other) => severityNumber >= other.severityNumber;

  /// Whether this level is more severe than [other].
  bool operator >(LogLevel other) => severityNumber > other.severityNumber;

  /// Whether this level is less severe than [other].
  bool operator <(LogLevel other) => severityNumber < other.severityNumber;

  /// Whether this level is no more severe than [other].
  bool operator <=(LogLevel other) => severityNumber <= other.severityNumber;

  @override
  int compareTo(LogLevel other) => severityNumber.compareTo(other.severityNumber);

  /// Restores a level from [value]: its [name] or its [severityNumber].
  ///
  /// [developerLevel] is not matched: `300`, `500` and `1000` are valid on both
  /// scales and denote different levels, so accepting both would resolve stored
  /// rows to the wrong severity. Migrate such rows at the storage layer. An
  /// unrecognised value falls back to [info] rather than throwing.
  static LogLevel fromValue(Object? value) => switch (value) {
    final LogLevel level => level,
    final String name => values.firstWhere((level) => level.name == name, orElse: () => info),
    final int number => values.firstWhere((level) => level.severityNumber == number, orElse: () => info),
    _ => info,
  };
}
