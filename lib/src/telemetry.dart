import 'dart:async';

import 'package:meta/meta.dart';
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
/// It owns a sink list, a ring buffer and the launch id, nothing more: every
/// destination is a [TelemetrySink] registered at composition time.
///
/// Per isolate, like everything else in Dart: a spawned isolate sees none of
/// these sinks and none of the zone-scoped options. Give it its own instance and
/// forward what it logs to the main one through a `SendPort` and [emit].
/// {@endtemplate}
final class Telemetry {
  /// How deep [emit] may re-enter itself before events are dropped.
  ///
  /// A sink that logs from `handle` produces an event that reaches that sink
  /// again. One level of that is a diagnostic; unbounded is a hang.
  static const int _maxDepth = 3;

  /// {@macro telemetry}
  Telemetry({required this.runId, LogBuffer? buffer}) : buffer = buffer ?? LogBuffer();

  /// The registered sinks, replaced rather than mutated: [emit] iterates the
  /// list it read, so a sink that registers or removes one while handling an
  /// event cannot corrupt the iteration.
  List<TelemetrySink> _sinks = const <TelemetrySink>[];

  /// Sinks that already reported a failure. A broken sink is usually broken for
  /// every event, and one report per event would bury the lines being read.
  final Set<TelemetrySink> _failedSinks = Set<TelemetrySink>.identity();

  int _depth = 0;
  bool _depthReported = false;
  int _sequence = 0;
  List<LogDraft>? _unchecked;

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
  /// exists, and the only source of `trace`, which no sink stores.
  final LogBuffer buffer;

  /// Where every event's timestamp comes from. Must return UTC.
  ///
  /// A seam, so a test can pin time instead of tolerating it.
  DateTime Function() clock = _utcNow;

  /// The trace in flight, asked once per event.
  ///
  /// Supplied by whatever owns tracing — a crash reporter's transaction, an
  /// OpenTelemetry SDK — so a log line can be joined to the request it belongs
  /// to. Nothing here starts or ends a span.
  ({String traceId, String? spanId})? Function()? traceContext;

  /// The level from which an event with no stack trace of its own gets one.
  ///
  /// `package:logging`'s `recordStackTraceAtLevel`. Off by default:
  /// `StackTrace.current` is not free, and most failures arrive with the trace
  /// that matters already attached.
  LogLevel? stackTraceAtLevel;

  /// Whether the debug-only conventions are checked.
  ///
  /// When on, a `.meta` key must be OpenTelemetry-named (lowercase,
  /// dot-namespaced, snake_case within a segment) and a body must carry at least
  /// `Area | operation`. Both are checked inside `assert`, so a release build
  /// pays nothing and cannot throw. Turn it off for a pipeline whose bodies come
  /// from somewhere else — a test fixture, a bridge that logs through a draft.
  bool strict = true;

  final StreamController<LogEvent> _events = StreamController<LogEvent>.broadcast();

  /// Every event, as it is dispatched. Late subscribers see only new events;
  /// read [buffer] for what came before.
  Stream<LogEvent> get events => _events.stream;

  /// Attributes every event of this launch carries, under the ambient scope and
  /// under the call site's own.
  ///
  /// OpenTelemetry's `Resource`: what identifies the source rather than the
  /// occurrence — `app.version`, `app.environment`, a device model. Set once
  /// during initialization; a value that changes per operation belongs in a
  /// scope or at the call site, not here.
  Map<String, Object?> get resource => _resource;
  Map<String, Object?> _resource = const <String, Object?>{};

  set resource(Map<String, Object?> value) =>
      _resource = value.isEmpty ? const <String, Object?>{} : Map<String, Object?>.unmodifiable(value);

  /// Registers a destination for logged events.
  ///
  /// A sink registered while an event is being dispatched receives the next one,
  /// not that one.
  void addSink(TelemetrySink sink) => _sinks = List<TelemetrySink>.unmodifiable(<TelemetrySink>[..._sinks, sink]);

  /// Removes a previously registered sink, and forgets that it ever failed.
  void removeSink(TelemetrySink sink) {
    _sinks = List<TelemetrySink>.unmodifiable(_sinks.where((registered) => registered != sink));
    _failedSinks.remove(sink);
  }

  /// Starts an event.
  ///
  /// [message] is the canonical one-liner (`Area | operation | message`) or a
  /// `String Function()` evaluated only if something consumes it.
  LogDraft call(Object message) => .new(this, message);

  /// Whether anything would consume, or buffer, an event of [level].
  ///
  /// The `Enabled` check of the OpenTelemetry logs API and of `slog.Handler`,
  /// with one addition: [buffer] counts as a consumer, so this answers `true`
  /// for `trace` within the buffer's own verbosity ceiling and for `debug` until
  /// the drain. Call it before composing an expensive message, but do not read
  /// it as "a sink wants this".
  bool isEnabled(LogLevel level, {int verbosity = 0}) {
    if (buffer.guarantees(level, verbosity)) return true;
    for (final sink in _sinks) {
      if (sink.enabled(level, verbosity)) return true;
    }
    return !_events.isClosed && _events.hasListener;
  }

  // --- Conveniences: the plain "log one line" call sites ------------------

  /// Logs [message] at [LogLevel.debug].
  void d(Object message, {Map<String, Object?>? meta}) => _quick(.debug, message, meta);

  /// Logs [message] at [LogLevel.info].
  void i(Object message, {Map<String, Object?>? meta}) => _quick(.info, message, meta);

  /// Logs [message] at [LogLevel.warn].
  void w(Object message, {Object? error, StackTrace? stackTrace, Map<String, Object?>? meta}) =>
      _quick(.warn, message, meta, error, stackTrace);

  /// Logs [message] at [LogLevel.error]; reported to the crash reporter.
  void e(Object message, {Object? error, StackTrace? stackTrace, Map<String, Object?>? meta}) =>
      _quick(.error, message, meta, error, stackTrace);

  /// Logs [message] at [LogLevel.fatal]; reported to the crash reporter.
  void f(Object message, {Object? error, StackTrace? stackTrace, Map<String, Object?>? meta}) =>
      _quick(.fatal, message, meta, error, stackTrace);

  // --- Trace tiers -------------------------------------------------------
  //
  // Six named methods rather than one `v(int tier, ...)`: as a leading
  // positional argument the tier reads as a magic number at the call site.

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
  /// did not compose gets in. A bridge from another logging package keeps that
  /// record's own timestamp, an isolate forwards what it logged, a test replays
  /// a fixture. Nothing is enriched here — the event is taken as given — and the
  /// conventions [strict] checks are not applied.
  ///
  /// Synchronous, like every log action.
  void emit(LogEvent event) {
    if (_depth >= _maxDepth) {
      // A sink that logs from `handle` on every event would never return.
      if (!_depthReported) {
        _depthReported = true;
        Zone.root.print('Telemetry | dispatch | re-entered $_maxDepth deep, dropping | $event');
      }
      return;
    }
    _depth++;
    try {
      buffer.add(event);
      for (final sink in _sinks) {
        if (!sink.enabled(event.level, event.verbosity)) continue;
        try {
          sink.handle(event);
        } on Object catch (error, stackTrace) {
          // A failing sink must not take the others down, and must not recurse
          // through the pipeline it just broke: report outside it, once.
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

  /// The next position in this launch, consuming it.
  ///
  /// Public for the same reason [emit] is: a bridge that composes its own
  /// [LogEvent] cannot number it otherwise, and a record that arrives with the
  /// default zero sorts ahead of everything else that shares its timestamp.
  /// Call it once per event.
  int nextSequence() => _sequence++;

  /// Arms the debug-only unused-draft guard. Used by [LogDraft].
  @internal
  void guardUnused(LogDraft draft) {
    // One microtask per burst, not one per draft: a frame that logs two hundred
    // lines should not schedule two hundred callbacks to discover that every one
    // of them was used.
    final first = _unchecked == null;
    (_unchecked ??= <LogDraft>[]).add(draft);
    if (first) scheduleMicrotask(_reportUnused);
  }

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
    // `debug`, not `info`: a captured `print` is developer output, and `info` is
    // the usual breadcrumb floor of a crash reporter, which would then ship
    // whatever was printed, unredacted. Lenient, because a printed line is
    // whatever somebody printed and was never going to be `Area | op | message`.
    onPrint: (line) =>
        LogDraft(this, line, guard: false, lenient: true).meta(const <String, Object?>{'log.source': 'print'}).debug(),
  );

  /// Runs [body] with [attributes] on every event logged inside it, across
  /// awaits.
  ///
  /// `slog.With`, `ILogger.BeginScope`, Serilog's `LogContext`: the request id,
  /// the route, the controller, named once by the code that knows them. A key
  /// set at the call site wins over the scope, and an inner scope wins over an
  /// outer one.
  R scoped<R>(Map<String, Object?> attributes, R Function() body) => runTelemetryScope<R>(attributes, body);

  /// Writes through every sink that holds events, and waits for them.
  ///
  /// The OpenTelemetry SDK's `ForceFlush`. A sink that throws is reported to the
  /// root zone and does not stop the others.
  Future<void> flush() async {
    // One set, so a class registered as both a sink and, say, the escalation
    // destination — which is what a crash reporter usually is — flushes once.
    final candidates = <Object?>[..._sinks, toastSink, escalationSink, trackSink, notifySink];
    final targets = <Flushable>{
      for (final candidate in candidates)
        if (candidate is Flushable) candidate,
    };
    if (targets.isEmpty) return;
    await Future.wait<void>(targets.map(_flushOne));
  }

  /// Flushes, then releases the event stream. Sinks own their own resources.
  Future<void> close() async {
    await flush();
    await _events.close();
  }

  void _reportUnused() {
    final pending = _unchecked;
    _unchecked = null;
    if (pending == null) return;
    for (final draft in pending) {
      draft.reportIfUnused();
    }
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
    // `guard: false`: this draft acts before it returns, so the unused-draft
    // guard has nothing to catch and its bookkeeping is pure cost.
    final draft = LogDraft(this, message, guard: false);
    if (meta != null) draft.meta(meta);
    if (error != null || stackTrace != null) draft.cause(error, stackTrace);
    draft.at(level);
  }

  void _verbose(int tier, Object message, Map<String, Object?>? meta) {
    if (!isEnabled(.trace, verbosity: tier)) return;
    final draft = LogDraft(this, message, guard: false)..verbosity(tier);
    if (meta != null) draft.meta(meta);
    draft.trace();
  }

  static DateTime _utcNow() => .now().toUtc();
}
