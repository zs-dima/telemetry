/// One event model for every telemetry channel: console, journal, crash
/// reporting, toasts and analytics.
///
/// A call site describes what happened once, then names the channels it wants;
/// nothing is inferred from severity and nothing waits for a terminal call:
///
/// ```dart
/// log('Pairing | handshake | refused')
///     .meta({'app.pairing.attempt': 3})
///     .cause(error)
///     .description(copy.pairingRefused)
///   ..warn()
///   ..toast(tone: ToastTone.alert);
/// ```
///
/// The shape follows OpenTelemetry's log record (body, attributes, severity
/// number, event name, trace ids), so an event maps onto Sentry's structured
/// logs, `dart:developer`'s level scale and any future exporter without
/// translation.
library;

export 'src/buffer.dart' show LogBuffer;
export 'src/console/console_sink.dart' show ConsoleFormat, ConsoleSink;
export 'src/console/delegate.dart' show ConsoleDelegate;
export 'src/draft.dart' show LogDraft;
export 'src/event.dart' show LogEvent;
export 'src/level.dart' show LogLevel;
export 'src/options.dart' show LogOutput, TelemetryOptions;
export 'src/reporting.dart' show ReportingSink;
export 'src/sink.dart'
    show EscalationSink, Flushable, NotifySink, TelemetrySink, ToastRequest, ToastSink, ToastTone, TrackSink;
export 'src/telemetry.dart' show Telemetry;
export 'src/throttle.dart' show ReportThrottle;
export 'src/zone.dart'
    show
        currentTelemetryContext,
        currentTelemetryOptions,
        kTelemetryContextKey,
        kTelemetryOptionsKey,
        runTelemetry,
        runTelemetryScope;
