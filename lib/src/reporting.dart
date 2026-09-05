import 'package:meta/meta.dart';
import 'package:telemetry/src/event.dart';
import 'package:telemetry/src/level.dart';
import 'package:telemetry/src/sink.dart';
import 'package:telemetry/src/throttle.dart';

/// {@template reporting_sink}
/// The crash-reporting end of a pipeline, minus the vendor.
///
/// Three destinations behind two independent floors, the shape of Sentry's
/// `LoggingIntegration` (`minBreadcrumbLevel`, `minEventLevel`,
/// `minSentryLogLevel`):
///
/// * from [breadcrumbLevel] up an event becomes a [breadcrumb], so a report
///   arrives with the trail that led to it;
/// * from [captureLevel] up it is [capture]d as an incident, through
///   [throttle], which dedupes per failure identity and caps sends per minute;
/// * an explicit `..escalate()` below [captureLevel] is [report]ed as a
///   structured log, visible without becoming an incident.
///
/// The two floors are independent, and the call site knows neither: it says
/// `..escalate()` and this class answers.
///
/// The policy lives here because it is the same in every app, and the three
/// hooks are the only part that knows a vendor. A subclass decides which
/// attributes may leave the device, and redacts what it must.
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

  /// Whether either floor wants this event.
  ///
  /// Both floors, since the pipeline skips `handle` for a level no sink claims.
  /// Gating on the trail's floor alone would let [captureLevel] only narrow what
  /// the trail admitted, so a quiet trail with loud capture would capture
  /// nothing.
  @override
  bool enabled(LogLevel level, int verbosity) => level >= breadcrumbLevel || level >= captureLevel;

  @override
  void handle(LogEvent event) {
    // The trail first, so an incident captured below carries its own last line.
    if (event.level >= breadcrumbLevel) breadcrumb(event);
    if (event.level < captureLevel) return;
    if (!throttle.allow(event)) return;
    capture(event, event.level, event.stackTrace);
  }

  /// Decides what an explicit `..escalate()` becomes.
  ///
  /// At or above [captureLevel] an escalation is an incident, below it a
  /// structured log. Escalating an event the automatic path already captured
  /// costs nothing: [throttle] refuses the second capture at the dedupe check,
  /// without spending a slot in the per-minute ceiling. So [level] and
  /// [stackTrace] cannot change a capture that already happened.
  @override
  void escalate(LogEvent event, {LogLevel? level, StackTrace? stackTrace}) {
    final effective = level ?? event.level;
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
  ///
  /// A fingerprint set here should key on [LogEvent.name] and the error type
  /// when the call site named the event, which is what [ReportThrottle.identityOf]
  /// dedupes on, so the reporter groups what the throttle counted as one
  /// failure. An unnamed event is better left to the reporter's own grouping.
  @protected
  void capture(LogEvent event, LogLevel level, StackTrace? stackTrace);

  /// Sends [event] as a structured log at [level], always below [captureLevel].
  /// An implementation must handle every level below that floor, including
  /// `error` when the floor is higher than the default.
  @protected
  void report(LogEvent event, LogLevel level);
}
