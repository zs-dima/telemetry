/// One event model for every telemetry channel: console, journal, crash
/// reporting, toasts and analytics.
///
/// A call site describes what happened once, then names the channels it wants.
/// Nothing is inferred from severity, and nothing waits for a terminal call:
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
/// The shape follows OpenTelemetry's log record: body, attributes, resource,
/// severity number, event name, trace ids. An event maps onto Sentry's
/// structured logs, `dart:developer`'s levels and any future exporter without
/// translation.
library;

export 'src/attributes.dart' show kAttributeKey, kEventName, kTrackName;
export 'src/buffer.dart' show LogBuffer;
export 'src/console/console_sink.dart' show ConsoleFormat, ConsoleSink;
export 'src/console/delegate.dart' show ConsoleDelegate;
export 'src/console/delegate_developer.dart' show DeveloperConsoleDelegate;
export 'src/console/delegate_ignore.dart' show IgnoreConsoleDelegate;
export 'src/console/delegate_print.dart' show PrintConsoleDelegate, kPrintWrapWidth, wrapForPrint;
export 'src/console/icons.dart' show AreaIcons, ConsoleGlyph, ConsoleIcon;
export 'src/console/level_tag.dart' show LevelTag;
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
