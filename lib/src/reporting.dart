import 'package:meta/meta.dart';
import 'package:telemetry/src/event.dart';
import 'package:telemetry/src/level.dart';
import 'package:telemetry/src/sink.dart';
import 'package:telemetry/src/throttle.dart';

/// {@template reporting_sink}
/// The crash-reporting end of a pipeline, minus the vendor.
///
/// Three destinations, three independent thresholds, the shape Sentry's own
/// `LoggingIntegration` uses (`minBreadcrumbLevel`, `minEventLevel`,
/// `minSentryLogLevel`):
///
/// * everything from [breadcrumbLevel] up becomes a [breadcrumb], so a report
///   arrives with the trail that led to it;
/// * everything from [captureLevel] up is [capture]d as an incident, through
///   [throttle] — a dedupe per failure identity and a per-minute ceiling, which
///   is what keeps a ten-minute outage from filing one issue per retry;
/// * an explicit `..escalate()` on a lighter event is [report]ed as a
///   structured log: visible in the reporter without becoming an incident.
///
/// The policy lives here because it is the same policy in every app; the three
/// hooks are the only part that knows a vendor. What may leave the device is not
/// this class's business: a subclass decides which attributes travel, and
/// redacts what it must.
/// {@endtemplate}
abstract base class ReportingSink implements TelemetrySink, EscalationSink {
  /// {@macro reporting_sink}
  ReportingSink({ReportThrottle? throttle, this.breadcrumbLevel = LogLevel.info, this.captureLevel = LogLevel.error})
    : throttle = throttle ?? ReportThrottle();

  /// Decides which failures are worth an incident. Shared by the automatic path
  /// and by an escalation, so one failure cannot spend two reports.
  final ReportThrottle throttle;

  /// Events at or above this level become breadcrumbs.
  final LogLevel breadcrumbLevel;

  /// Events at or above this level become incidents.
  final LogLevel captureLevel;

  @override
  bool enabled(LogLevel level, int verbosity) => level >= breadcrumbLevel;

  @override
  void handle(LogEvent event) {
    // The trail first: an incident captured below then carries its own last line.
    breadcrumb(event);
    if (event.level < captureLevel) return;
    if (!throttle.allow(event)) return;
    capture(event, event.level, event.stackTrace);
  }

  @override
  void escalate(LogEvent event, {LogLevel? level, StackTrace? stackTrace}) {
    final effective = level ?? event.level;
    // An override that says "this warning IS an incident" is the one case where
    // an escalation captures: the draft only forwards it because the line was
    // logged at a level the automatic path ignores.
    if (effective >= captureLevel) {
      if (!throttle.allow(event)) return;
      capture(event, effective, stackTrace ?? event.stackTrace);
      return;
    }
    report(event, effective);
  }

  /// Adds [event] to the trail that travels with the next incident.
  @protected
  void breadcrumb(LogEvent event);

  /// Files [event] as an incident at [level]. Already past [throttle].
  @protected
  void capture(LogEvent event, LogLevel level, StackTrace? stackTrace);

  /// Sends [event] as a structured log at [level], which is below
  /// [captureLevel].
  @protected
  void report(LogEvent event, LogLevel level);
}
