/// Severity of an event, ordered.
///
/// Two numbers travel with every level, one per ecosystem that owns a scale:
///
/// * [severityNumber] is OpenTelemetry's, the lower bound of the level's range
///   (TRACE 1-4, DEBUG 5-8, INFO 9-12, WARN 13-16, ERROR 17-20, FATAL 21-24).
///   Exporters, Sentry's structured logs and stored rows use it.
/// * [developerLevel] is `package:logging`'s 0-2000 scale, read by
///   `dart:developer` and the DevTools Logging view. Write-only: the two scales
///   overlap, so a stored number always comes from [severityNumber].
///
/// Trace noise is a separate dial, `LogEvent.verbosity` with
/// `TelemetryOptions.maxVerbosity`.
enum LogLevel implements Comparable<LogLevel> {
  /// Fine-grained tracing: frame-by-frame detail, protocol chatter.
  trace(1, 300),

  /// Developer-facing detail: state transitions, timings, cache hits.
  debug(5, 500),

  /// Normal, noteworthy operation: one line per meaningful operation.
  info(9, 800),

  /// Something recovered, degraded, or is suspicious, but is not an incident.
  warn(13, 900),

  /// An operation failed. Captured as an incident from a `ReportingSink`'s
  /// capture floor up, which is this level by default.
  error(17, 1000),

  /// The app cannot continue in a meaningful state. Captured on the same terms.
  fatal(21, 1200);

  const LogLevel(this.severityNumber, this.developerLevel);

  /// OpenTelemetry severity number, the lower bound of the level's range.
  ///
  /// `LogEvent.severityNumber` is what an exporter should store: it spends the
  /// four numbers of the `trace` range on the verbosity tiers.
  final int severityNumber;

  /// `package:logging` / `dart:developer` level. Write-only; see [fromValue].
  final int developerLevel;

  /// Single-character name of the level: the fallback text of a `LevelTag`, and
  /// what a stored row is usually rendered with.
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

  /// Restores a level from [value]: its [name] or any OpenTelemetry severity
  /// number.
  ///
  /// The whole 1 to 24 range, four numbers per level, so a row written from
  /// `LogEvent.severityNumber` or by another exporter comes back as the level it
  /// was. [developerLevel] is not matched: `300`, `500` and `1000` are valid on
  /// both scales and denote different levels, so accepting both would resolve
  /// stored rows to the wrong severity. Migrate such rows at the storage layer.
  /// An unrecognised value falls back to [info] rather than throwing.
  static LogLevel fromValue(Object? value) => switch (value) {
    final LogLevel level => level,
    final String name => values.firstWhere((level) => level.name == name, orElse: () => info),
    final int number when number >= 1 && number <= 24 => values.lastWhere(
      (level) => number >= level.severityNumber,
      orElse: () => info,
    ),
    _ => info,
  };
}
