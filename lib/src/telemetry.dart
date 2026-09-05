import 'dart:async';

import 'package:meta/meta.dart';
import 'package:telemetry/src/attributes.dart';
import 'package:telemetry/src/buffer.dart';
import 'package:telemetry/src/draft.dart';
import 'package:telemetry/src/event.dart';
import 'package:telemetry/src/level.dart';
import 'package:telemetry/src/options.dart';
import 'package:telemetry/src/sink.dart';
import 'package:telemetry/src/zone.dart';

/// {@template telemetry}
/// The facade every call site talks to.
///
/// One instance per app, created during initialization and reachable as `log`.
/// It owns a sink list, a ring buffer and the launch id; every destination is a
/// [TelemetrySink] registered at composition time.
///
/// State is per isolate. A spawned isolate sees none of these sinks and none of
/// the zone-scoped options, so give it its own instance and forward what it
/// logs through a `SendPort` and [emit].
/// {@endtemplate}
final class Telemetry {
  /// How deep [emit] may re-enter itself before events are dropped.
  ///
  /// A sink that logs from `handle` produces an event that reaches it again.
  /// Synchronous re-entry only: a channel action or an [events] listener that
  /// logs comes back a microtask later, at depth zero, and nothing bounds that.
  static const int _maxDepth = 3;

  /// {@macro telemetry}
  Telemetry({required this.runId, LogBuffer? buffer}) : buffer = buffer ?? LogBuffer();

  /// Sinks that already reported a failure. A broken sink is usually broken for
  /// every event, and one report per event would bury the log.
  final Set<TelemetrySink> _failedSinks = Set<TelemetrySink>.identity();

  int _depth = 0;
  bool _depthReported = false;
  int _sequence = 0;

  /// Identifier of this app launch. Travels on every event.
  final String runId;

  /// The user-message destination (the app's UI messenger).
  ToastSink? toastSink;

  /// The crash-reporter escalation destination.
  EscalationSink? escalationSink;

  /// The product-analytics destination. None ships by default.
  TrackSink? trackSink;

  /// The notification-inbox destination.
  NotifySink? notifySink;

  /// The events of this launch, newest last. Drained into a journal once one
  /// exists, and the only place `trace` lines are kept.
  final LogBuffer buffer;

  /// Where every event's timestamp comes from.
  ///
  /// A seam, so a test can pin time. [now] converts the result to UTC, so a
  /// local clock cannot put local time on what leaves the device.
  DateTime Function() clock = DateTime.now;

  /// The trace in flight, asked once per event, at the moment the call site
  /// acted.
  ///
  /// Supplied by whatever owns tracing, a crash reporter's transaction or an
  /// OpenTelemetry SDK, so a line can be joined to its request. Nothing here
  /// starts or ends a span.
  ({String traceId, String? spanId})? Function()? traceContext;

  /// The level from which an event with no stack trace of its own gets one.
  ///
  /// `package:logging`'s `recordStackTraceAtLevel`. Off by default:
  /// `StackTrace.current` is not free, and most failures arrive with a trace.
  LogLevel? stackTraceAtLevel;

  /// Whether the debug-only conventions are checked.
  ///
  /// When on, a `.meta` key and an event `name` must be OpenTelemetry-named, an
  /// analytics name must be one snake_case word, a trace tier must be 1 to 6,
  /// and a body must carry at least `Area | operation`. Every check is an
  /// `assert`, so a release build pays nothing. Turn it off for a pipeline whose
  /// bodies come from elsewhere; for one bridged line, use
  /// `LogDraft(..., lenient: true)`.
  bool strict = true;

  /// The registered sinks, in the order they were added.
  ///
  /// Unmodifiable, and replaced rather than mutated by [addSink] and
  /// [removeSink], so a held reference goes stale rather than changing under a
  /// reader. For code that has to know whether the sink it built is still the
  /// live one, which the slots ([toastSink] and the rest) answer by identity.
  List<TelemetrySink> get sinks => _sinks;

  /// Replaced rather than mutated, so a sink that adds or removes one while an
  /// event is being dispatched cannot corrupt [emit]'s iteration.
  List<TelemetrySink> _sinks = const <TelemetrySink>[];

  final StreamController<LogEvent> _events = StreamController<LogEvent>.broadcast();

  /// Every event that was built, as it is dispatched.
  ///
  /// An observer rather than a consumer: subscribing does not enable a level, so
  /// a debug overlay cannot switch on every `trace` tier the sinks drop. Late
  /// subscribers see only new events; read [buffer] for what came before.
  ///
  /// A listener that logs is an unbounded loop: delivery is asynchronous, so
  /// each generation starts at depth zero and [emit]'s cap never sees it.
  Stream<LogEvent> get events => _events.stream;

  /// What identifies this launch, carried by every event as [LogEvent.resource].
  ///
  /// OpenTelemetry's `Resource`: `service.name`, `service.version`,
  /// `deployment.environment.name`, a device model. It identifies the source
  /// rather than the occurrence, so it is not
  /// copied into each event's `meta` and not rendered on a console line. Set it
  /// once during initialization; anything that varies per operation belongs in a
  /// scope or at the call site.
  ///
  /// Stored unmodifiable, with any `Object Function()` value resolved on
  /// assignment: the map travels on every event, and a closure left in it would
  /// be run, or stored, by every sink that reads attributes.
  Map<String, Object?> get resource => _resource;
  Map<String, Object?> _resource = const <String, Object?>{};

  set resource(Map<String, Object?> value) {
    assert(
      !strict || firstInvalidKey(value) == null,
      'a resource key is OpenTelemetry-named: lowercase, dot-namespaced, snake_case within a '
      'segment, at least two segments (service.version). Got: ${firstInvalidKey(value)}',
    );
    _resource = value.isEmpty ? const <String, Object?>{} : Map<String, Object?>.unmodifiable(resolveAttributes(value));
  }

  /// Registers a destination for logged events.
  ///
  /// A sink registered while an event is being dispatched receives the next one,
  /// not that one; one removed during a dispatch still receives that one.
  void addSink(TelemetrySink sink) => _sinks = List<TelemetrySink>.unmodifiable(<TelemetrySink>[..._sinks, sink]);

  /// Removes a registered sink and forgets that it failed.
  ///
  /// By identity: two sinks that compare equal are still two destinations.
  void removeSink(TelemetrySink sink) {
    _sinks = List<TelemetrySink>.unmodifiable(_sinks.where((registered) => !identical(registered, sink)));
    _failedSinks.remove(sink);
  }

  /// Starts an event.
  ///
  /// [message] is the canonical one-liner, `Area | operation | message`, or an
  /// `Object Function()` evaluated only if something consumes it. Describe the
  /// returned [LogDraft] with `.`, then close it with an action.
  @UseResult('log(...) starts a draft; close it with an action, e.g. ..info().')
  LogDraft call(Object message) => .new(this, message);

  /// Whether anything would consume, or buffer, an event of [level].
  ///
  /// The `Enabled` check of the OpenTelemetry logs API and of `slog.Handler`,
  /// with [buffer] counted as a consumer, so it answers `true` for `trace`
  /// within the buffer's ceilings. Call it before composing an expensive
  /// message; it does not mean a sink wants the event.
  bool isEnabled(LogLevel level, {int verbosity = 0}) {
    if (buffer.guarantees(level, verbosity)) return true;
    for (final sink in _sinks) {
      try {
        if (sink.enabled(level, verbosity)) return true;
      } on Object {
        // A sink that cannot answer does not want the event, and must not take
        // the question to the call site. `emit` reports the same failure once.
      }
    }
    return false;
  }

  // --- Conveniences: the plain "log one line" call sites ------------------

  /// Logs [message] at [LogLevel.debug].
  void d(Object message, {Map<String, Object?>? meta}) => _quick(.debug, message, meta);

  /// Logs [message] at [LogLevel.info].
  void i(Object message, {Map<String, Object?>? meta}) => _quick(.info, message, meta);

  /// Logs [message] at [LogLevel.warn].
  void w(Object message, {Object? error, StackTrace? stackTrace, Map<String, Object?>? meta}) =>
      _quick(.warn, message, meta, error, stackTrace);

  /// Logs [message] at [LogLevel.error]; captured as an incident by a
  /// `ReportingSink`.
  void e(Object message, {Object? error, StackTrace? stackTrace, Map<String, Object?>? meta}) =>
      _quick(.error, message, meta, error, stackTrace);

  /// Logs [message] at [LogLevel.fatal]; captured as an incident by a
  /// `ReportingSink`.
  void f(Object message, {Object? error, StackTrace? stackTrace, Map<String, Object?>? meta}) =>
      _quick(.fatal, message, meta, error, stackTrace);

  // --- Trace tiers -------------------------------------------------------
  //
  // Six named methods rather than one `v(int tier, ...)`, where the tier would
  // read as a magic number at the call site.

  /// Logs [message] at [LogLevel.trace], tier 1, the loudest tier.
  void v1(Object message, {Map<String, Object?>? meta}) => _verbose(1, message, meta);

  /// Logs [message] at [LogLevel.trace], tier 2.
  void v2(Object message, {Map<String, Object?>? meta}) => _verbose(2, message, meta);

  /// Logs [message] at [LogLevel.trace], tier 3.
  void v3(Object message, {Map<String, Object?>? meta}) => _verbose(3, message, meta);

  /// Logs [message] at [LogLevel.trace], tier 4.
  void v4(Object message, {Map<String, Object?>? meta}) => _verbose(4, message, meta);

  /// Logs [message] at [LogLevel.trace], tier 5.
  void v5(Object message, {Map<String, Object?>? meta}) => _verbose(5, message, meta);

  /// Logs [message] at [LogLevel.trace], tier 6, a whisper.
  void v6(Object message, {Map<String, Object?>? meta}) => _verbose(6, message, meta);

  // --- Error hooks -------------------------------------------------------

  /// Records an uncaught zone error.
  void logZoneError(Object error, StackTrace stackTrace) =>
      e('Zone | uncaught | error', error: error, stackTrace: stackTrace);

  /// Records a `PlatformDispatcher` error; always returns `true` so the
  /// platform considers it handled.
  bool logPlatformError(Object error, StackTrace stackTrace) {
    e('Platform | uncaught | error', error: error, stackTrace: stackTrace);
    return true;
  }

  // --- Dispatch ----------------------------------------------------------

  /// Delivers an already-built [event] to every sink that wants it.
  ///
  /// The `Emit` of the OpenTelemetry logs bridge API: how a record this pipeline
  /// did not compose gets in. A bridge keeps the record's own timestamp, an
  /// isolate forwards what it logged, a test replays a fixture.
  ///
  /// The event is taken as given, down to its [LogEvent.resource], and the
  /// conventions [strict] checks are skipped. Only the per-sink `enabled` and
  /// the buffer's floors gate it. Synchronous, like every log action.
  void emit(LogEvent event) {
    if (_depth >= _maxDepth) {
      if (!_depthReported) {
        _depthReported = true;
        Zone.root.print(
          'Telemetry | dispatch | re-entered $_maxDepth deep, dropping (further reports silent) | $event',
        );
      }
      return;
    }
    _depth++;
    try {
      buffer.add(event);
      for (final sink in _sinks) {
        try {
          // Inside the guard: a sink whose `enabled` throws would otherwise take
          // the error to the call site of `log.i(...)` and skip the sinks after
          // it.
          if (!sink.enabled(event.level, event.verbosity)) continue;
          sink.handle(event);
        } on Object catch (error, stackTrace) {
          // A failing sink must not take the others down or recurse through the
          // pipeline it just broke, so report outside it, once.
          if (_failedSinks.add(sink)) {
            Zone.root.print(
              'Telemetry | sink ${sink.runtimeType} failed (further reports silent) | $error\n$stackTrace',
            );
          }
        }
      }
      if (!_events.isClosed && _events.hasListener) _events.add(event);
    } finally {
      _depth--;
    }
  }

  /// The instant an event happened, in UTC.
  ///
  /// Reads [clock] and normalises it, so a pinned local clock cannot put local
  /// time on a record that leaves the device.
  DateTime now() => clock().toUtc();

  /// The next position in this launch, consuming it.
  ///
  /// Public for the same reason [emit] is: a bridge composing its own
  /// [LogEvent] has no other way to number it, and a record left at zero sorts
  /// ahead of everything sharing its timestamp. Call it once per event.
  int nextSequence() => _sequence++;

  /// Delivers a user-facing message. Used by [LogDraft].
  @internal
  void dispatchToast(ToastRequest request) => toastSink?.toast(request);

  /// Escalates an event to the crash reporter. Used by [LogDraft].
  @internal
  void dispatchEscalation(LogEvent event, {LogLevel? level, StackTrace? stackTrace}) =>
      escalationSink?.escalate(event, level: level, stackTrace: stackTrace);

  /// Records a product-analytics event. Used by [LogDraft].
  @internal
  void dispatchTrack(String name, Map<String, Object?> props, LogEvent event) => trackSink?.track(name, props, event);

  /// Records a notification-inbox row. Used by [LogDraft].
  @internal
  void dispatchNotify(Object kind, Map<String, Object?> args, LogEvent event) => notifySink?.notify(kind, args, event);

  /// Runs [body] with [options] in force, capturing `print` into the pipeline.
  R zoned<R>(R Function() body, {TelemetryOptions options = .defaults}) => runTelemetry<R>(
    body,
    options: options,
    // `debug` rather than `info`: a captured `print` is developer output, and
    // `info` is the usual breadcrumb floor, which would ship it unredacted.
    // Lenient, because a printed line follows no body convention.
    onPrint: (line) => LogDraft(
      this,
      line,
      lenient: true,
    ).meta(const <String, Object?>{'log.source': 'print'}).debug(),
  );

  /// Runs [body] with [attributes] on every event logged inside it, across
  /// awaits.
  ///
  /// `slog.With`, `ILogger.BeginScope`, Serilog's `LogContext`: the request id,
  /// the route, the controller, named once by the code that knows them. A key
  /// set at the call site wins over the scope, and an inner scope over an outer
  /// one.
  ///
  /// Carried by the `Zone`, so it follows an `await` inside [body] and does not
  /// follow a callback registered outside it. Code that runs later on a timer or
  /// a stream logs in the scope it was scheduled in.
  R scoped<R>(Map<String, Object?> attributes, R Function() body) {
    assert(
      !strict || firstInvalidKey(attributes) == null,
      'a scope key is OpenTelemetry-named: lowercase, dot-namespaced, snake_case within a '
      'segment, at least two segments (rpc.path). Got: ${firstInvalidKey(attributes)}',
    );
    return runTelemetryScope<R>(attributes, body);
  }

  /// Writes through every sink that holds events, and waits for them.
  ///
  /// The OpenTelemetry SDK's `ForceFlush`. A sink that throws is reported to the
  /// root zone and does not stop the others. There is no deadline here; wrap the
  /// call in `Future.timeout` where one is needed.
  Future<void> flush() async {
    // One identity set, so a class registered as both a sink and the escalation
    // destination, which a crash reporter usually is, flushes once. Two equal
    // but distinct sinks still flush separately.
    final candidates = <Object?>[..._sinks, toastSink, escalationSink, trackSink, notifySink];
    final targets = Set<Flushable>.identity();
    for (final candidate in candidates) {
      if (candidate is Flushable) targets.add(candidate);
    }
    if (targets.isEmpty) return;
    await Future.wait<void>(targets.map(_flushOne));
  }

  /// Flushes, then releases the event stream. Sinks own their own resources.
  Future<void> close() async {
    await flush();
    await _events.close();
  }

  Future<void> _flushOne(Flushable target) async {
    try {
      await target.flush();
    } on Object catch (error, stackTrace) {
      Zone.root.print('Telemetry | flush | ${target.runtimeType} failed | $error\n$stackTrace');
    }
  }

  void _quick(LogLevel level, Object message, Map<String, Object?>? meta, [Object? error, StackTrace? stackTrace]) {
    if (!isEnabled(level)) return;
    // `gated: true`: the check above is the one the draft would repeat.
    var draft = LogDraft(this, message, gated: true).meta(meta);
    if (error != null || stackTrace != null) draft = draft.cause(error, stackTrace);
    draft.at(level);
  }

  void _verbose(int tier, Object message, Map<String, Object?>? meta) {
    if (!isEnabled(.trace, verbosity: tier)) return;
    LogDraft(this, message, gated: true).verbosity(tier).meta(meta).trace();
  }
}
