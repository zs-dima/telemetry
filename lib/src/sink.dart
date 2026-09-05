import 'package:meta/meta.dart';
import 'package:telemetry/src/event.dart';
import 'package:telemetry/src/level.dart';

/// A destination for logged events: console, journal, breadcrumb trail.
///
/// A sink is the only place that knows an output, so the event model stays pure
/// Dart while feeding a Flutter toast, a database table and a crash reporter.
abstract interface class TelemetrySink {
  /// Whether this sink wants events of [level] at [verbosity].
  ///
  /// Checked before an event is built, so a disabled sink costs nothing and a
  /// lazy message is never evaluated. The `Enabled` check of the OpenTelemetry
  /// logs API and of `slog.Handler`.
  bool enabled(LogLevel level, int verbosity);

  /// Consumes [event].
  ///
  /// Must not throw: the dispatcher isolates failures, but a sink that throws on
  /// every event loses them all. Must not block either, though a batching sink
  /// may write through for `error` and `fatal`, so the line before a native
  /// crash reaches disk.
  void handle(LogEvent event);
}

/// A sink that holds events before they reach their destination.
///
/// The OpenTelemetry SDK's `ForceFlush`. A batching sink trades durability for
/// throughput, and the app going to the background, a database about to close
/// or a deliberate exit is where that trade is paid back. `Telemetry.flush`
/// asks every sink that implements this.
///
/// Separate from [TelemetrySink], so a sink that writes through does not carry a
/// method it has no use for.
abstract interface class Flushable {
  /// Writes everything held; completes when it is out of this sink's hands.
  ///
  /// Must not throw: `Telemetry.flush` reports a failure and carries on.
  Future<void> flush();
}

/// Semantic tone of a user-facing message.
///
/// Here rather than in a design system, so application logic can name a tone
/// without importing Flutter. The widget layer maps it to its own palette.
enum ToastTone {
  /// Neutral information.
  info,

  /// Something succeeded.
  ok,

  /// Something failed or needs attention.
  alert,
}

/// {@template toast_request}
/// A request to show the user a message.
/// {@endtemplate}
@immutable
final class ToastRequest {
  /// {@macro toast_request}
  const ToastRequest({required this.tone, required this.text, required this.event});

  /// How to present it.
  final ToastTone tone;

  /// The localized text to show.
  final String text;

  /// The event behind it: carries the cause and stack for a "Details" action.
  final LogEvent event;
}

/// Shows user-facing messages. Implemented by the app's UI messenger.
abstract interface class ToastSink {
  /// Presents [request] to the user.
  void toast(ToastRequest request);
}

/// Sends an event to the crash reporter as an explicit escalation.
///
/// `error` and `fatal` are reported automatically by the crash-reporting
/// [TelemetrySink]. This covers the rest: a lighter line the call site wants in
/// the reporter as a structured log, or one a [level] override marks an
/// incident.
abstract interface class EscalationSink {
  /// Escalates [event].
  ///
  /// [level] overrides the event's own severity for this escalation only: below
  /// `error` the event becomes a structured log, at `error` and above an issue.
  void escalate(LogEvent event, {LogLevel? level, StackTrace? stackTrace});
}

/// Product analytics. No implementation ships; the seat exists so adding a
/// tracker later touches one sink rather than every call site.
abstract interface class TrackSink {
  /// Records a product event named [name].
  void track(String name, Map<String, Object?> props, LogEvent event);
}

/// Writes a row into an in-app notification inbox.
///
/// [kind] is untyped, since the inbox taxonomy belongs to the application.
/// Nothing is implied from severity; a row is always an explicit decision.
abstract interface class NotifySink {
  /// Records a notification of [kind].
  void notify(Object kind, Map<String, Object?> args, LogEvent event);
}
