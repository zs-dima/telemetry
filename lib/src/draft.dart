// A builder returns `this` so one draft can describe an event once and then
// name several channels.
// ignore_for_file: avoid_returning_this

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:telemetry/src/event.dart';
import 'package:telemetry/src/level.dart';
import 'package:telemetry/src/sink.dart';
import 'package:telemetry/src/telemetry.dart';
import 'package:telemetry/src/zone.dart';

/// An OpenTelemetry attribute key: lowercase, dot-namespaced, snake_case within
/// a segment, at least two segments. Checked only in debug, and only while
/// `Telemetry.strict` is on.
final RegExp _kAttributeKey = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$');

/// Everything known about one thing that happened, before any channel is named.
/// A context carrier, not a deferred log statement:
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
/// The log action ([warn], [error], [at], …) builds the [LogEvent] and
/// dispatches it to the sinks synchronously. A channel action ([toast],
/// [escalate], [track], [notify]) validates its arguments at the call site and
/// then records itself; on the next microtask every recorded channel receives
/// that same event. Cascade order therefore cannot matter, and the event behind
/// a toast's "Details" is the one the sinks were given.
///
/// A fluent chain can be dropped silently when its terminal call is forgotten,
/// with no compile-time error. Two guards close that gap:
///
/// * a draft used only for a non-log channel is logged anyway when the microtask
///   runs, at [LogLevel.info], or [LogLevel.warn] when it carries a cause, so a
///   user-visible effect always leaves a record;
/// * a draft that names no channel at all is logged, in debug builds, as
///   `Telemetry | draft | unused` at [LogLevel.warn], carrying the body that was
///   dropped.
final class LogDraft {
  /// Created by [Telemetry.call]; not constructed directly.
  ///
  /// [guard] arms the debug-only unused-draft report, and is off for the one-call
  /// conveniences, which act before they return. [lenient] exempts the body from
  /// the `Telemetry.strict` convention check, for a line that was never going to
  /// be `Area | operation | message` — a captured `print`, a bridged record.
  // A named parameter cannot be an initializing formal for a private field.
  // ignore: prefer_initializing_formals
  LogDraft(this._telemetry, this._message, {bool guard = true, bool lenient = false}) : _lenient = lenient {
    if (!guard) return;
    // Armed from the constructor: it is the only code that runs for a draft
    // nobody ever acts on, so arming from an action would miss the very case it
    // exists to catch. The standard debug-only idiom; the body runs only in
    // debug builds.
    // ignore: avoid-immediately-invoked-functions
    assert(() {
      _telemetry.guardUnused(this);
      return true;
    }(), 'unreachable: the closure only arms the guard');
  }

  final Telemetry _telemetry;
  final Object _message;
  final bool _lenient;

  Map<String, Object?>? _meta;
  Object? _error;
  StackTrace? _stackTrace;
  String? _description;
  String? _name;
  int _verbosity = 0;
  DateTime? _timestamp;

  /// Channels waiting for the event, in the order they were named.
  final List<void Function(LogEvent event)> _channels = <void Function(LogEvent event)>[];

  LogLevel? _loggedLevel;
  LogEvent? _event;
  bool _acted = false;
  bool _scheduled = false;

  /// Adds structured attributes, OpenTelemetry-named (lowercase,
  /// dot-namespaced, snake_case): `app.pairing.attempt`, `rpc.path`. Values are
  /// what a query filters on, and belong here rather than in the message.
  ///
  /// A value may be an `Object Function()`, evaluated once, at snapshot time and
  /// only if the event is built — `slog`'s `LogValuer`, for an attribute that
  /// costs something to compute.
  LogDraft meta(Map<String, Object?> attributes) {
    if (attributes.isEmpty) return this;
    // ignore: avoid-immediately-invoked-functions, the debug-only convention check.
    assert(() {
      if (!_telemetry.strict) return true;
      for (final key in attributes.keys) {
        if (_kAttributeKey.hasMatch(key)) continue;
        throw ArgumentError.value(
          key,
          'attributes',
          'an attribute key is OpenTelemetry-named: lowercase, dot-namespaced, '
              'snake_case within a segment, at least two segments (app.pairing.attempt). '
              'Set Telemetry.strict = false for a pipeline that cannot follow that',
        );
      }
      return true;
    }(), 'unreachable: the closure only checks the keys');
    (_meta ??= <String, Object?>{}).addAll(attributes);
    return this;
  }

  /// Attaches the error this event is about. When it carries a stack trace of
  /// its own and none was set, that trace is adopted.
  LogDraft cause(Object? error, [StackTrace? stackTrace]) {
    _error = error;
    if (stackTrace != null) {
      _stackTrace = stackTrace;
    } else if (_stackTrace == null && error is Error) {
      _stackTrace = error.stackTrace;
    }
    return this;
  }

  /// The localized, user-facing sentence for this event, shown by [toast].
  ///
  /// The log body stays a stable English line, the crash reporter's grouping
  /// key; the user reads this instead.
  LogDraft description(String? text) {
    _description = text;
    return this;
  }

  /// Sets [LogEvent.name], the identity that outlives a copy edit to the body.
  ///
  /// Lowercase and dot-separated, `area.operation.outcome`. A crash reporter's
  /// fingerprint and `ReportThrottle` key on it once it is set.
  LogDraft name(String value) {
    _name = value;
    return this;
  }

  /// Marks a [trace] line as noise of tier [level] (1 loud … 6 whisper),
  /// filtered by `TelemetryOptions.maxVerbosity` and `LogBuffer.maxVerbosity`.
  /// `Telemetry.v1` … `v6` are the short form; this is for a trace line that
  /// also carries attributes or a cause.
  LogDraft verbosity(int level) {
    _verbosity = level;
    return this;
  }

  // --- Log actions -------------------------------------------------------

  /// Logs at [LogLevel.trace]. Null when nothing consumes that level.
  LogEvent? trace() => _log(.trace);

  /// Logs at [LogLevel.debug]. Null when nothing consumes that level.
  LogEvent? debug() => _log(.debug);

  /// Logs at [LogLevel.info]. Null when nothing consumes that level.
  LogEvent? info() => _log(.info);

  /// Logs at [LogLevel.warn]. Null when nothing consumes that level.
  LogEvent? warn() => _log(.warn);

  /// Logs at [LogLevel.error]. Reported to the crash reporter automatically.
  LogEvent? error() => _log(.error);

  /// Logs at [LogLevel.fatal]. Reported to the crash reporter automatically.
  LogEvent? fatal() => _log(.fatal);

  /// Logs at a [level] computed at runtime, for a transport whose severity
  /// depends on the outcome or a bridge from another logging package. Call sites
  /// that know their severity name it ([warn], [error], …).
  LogEvent? at(LogLevel level) => _log(level);

  // --- Channel actions ---------------------------------------------------

  /// Shows the user a message: [text] when given, otherwise [description]. With
  /// neither, debug asserts and release falls back to the body, so a toast is
  /// never blank and never crashes.
  void toast({ToastTone tone = .info, String? text}) {
    final message = text ?? _description;
    assert(
      message != null,
      'toast() needs user-facing text: pass text:, or set .description(...). '
      'the log body is developer English and must not reach the UI',
    );
    _act();
    _channels.add(
      (event) => _telemetry.dispatchToast(ToastRequest(tone: tone, text: message ?? event.body, event: event)),
    );
  }

  /// Sends this event to the crash reporter.
  ///
  /// Below [LogLevel.error] it arrives as a structured log, making a warning
  /// visible without filing an issue; pass [level] to capture it as an incident
  /// anyway. A no-op when the event is logged at `error` or above, since the
  /// reporting sink already captured it and a second send would duplicate the
  /// issue. That check runs once the event exists, so it does not depend on
  /// where in the cascade this call sits.
  void escalate({LogLevel? level, StackTrace? stackTrace}) {
    _act();
    _channels.add((event) {
      if (event.level >= .error) return;
      _telemetry.dispatchEscalation(event, level: level, stackTrace: stackTrace ?? event.stackTrace);
    });
  }

  /// Sends this event to the crash reporter.
  @Deprecated('Renamed to escalate(): the destination is an EscalationSink, not a vendor. Removed in 0.3.0.')
  void sentry({LogLevel? level, StackTrace? stackTrace}) => escalate(level: level, stackTrace: stackTrace);

  /// Records a product-analytics event. No tracker ships by default.
  ///
  /// [name] is a product vocabulary, not a log body: lowercase snake_case, one
  /// of a bounded set the application owns. Analytics backends cap that set —
  /// Firebase at 500 distinct names and 25 properties per event — so a name
  /// built from a value exhausts it.
  void track(String name, {Map<String, Object?> props = const <String, Object?>{}}) {
    _act();
    _channels.add((event) => _telemetry.dispatchTrack(name, props, event));
  }

  /// Writes a row into the app's notification inbox. Always an explicit decision
  /// by the code that knows the user missed something; never derived from
  /// severity.
  void notify(Object kind, {Map<String, Object?> args = const <String, Object?>{}}) {
    _act();
    _channels.add((event) => _telemetry.dispatchNotify(kind, args, event));
  }

  // --- Internals ---------------------------------------------------------

  /// Reports this draft if nothing ever acted on it. Debug only; called by
  /// [Telemetry], not directly.
  ///
  /// A line, not a thrown `AssertionError`: the throw left a bare microtask and
  /// arrived as an uncaught zone error, which an app with `logZoneError` wired
  /// then recorded as `Zone | uncaught | error` — a defect-severity line about a
  /// missing terminal call, in the one place a reader is looking for real ones.
  @internal
  void reportIfUnused() {
    if (_acted) return;
    // Before the log, so the warning's own draft cannot re-enter this one.
    _acted = true;
    _telemetry.w('Telemetry | draft | unused', meta: <String, Object?>{'log.body': _bodyText()});
  }

  /// The level of a draft that reached a channel without naming one.
  ///
  /// `warn`, never `error`, when a cause is attached: `error` is auto-reported,
  /// so deriving it from an attached exception would file a crash-reporter issue
  /// for a forgotten `..warn()`.
  LogLevel _implicitLevel() => _error == null ? .info : .warn;

  /// The body, building it now if the call site passed a lazy builder.
  String _bodyText() {
    final message = _message;
    if (message is String) return message;
    if (message is String Function()) return message();
    return message.toString();
  }

  /// The attributes of the event: the launch's resource, under the ambient
  /// scope, under what this call site set.
  Map<String, Object?> _attributes() {
    final resource = _telemetry.resource;
    final scope = currentTelemetryContext();
    final own = _meta;
    if (resource.isEmpty && scope.isEmpty) return own == null ? const <String, Object?>{} : _resolve(own);
    return _resolve(<String, Object?>{...resource, ...scope, ...?own});
  }

  LogEvent _snapshot(LogLevel level) {
    final body = _bodyText();
    assert(
      _lenient || !_telemetry.strict || _isCanonicalBody(body),
      'a log body is `Area | operation | message`, the crash reporter\'s grouping key: '
      'anything variable goes into .meta({...}). '
      'Set Telemetry.strict = false for a pipeline whose bodies come from elsewhere. Got: $body',
    );
    final trace = _telemetry.traceContext?.call();
    return .new(
      level: level,
      body: body,
      name: _name,
      timestamp: _timestamp ??= _telemetry.clock(),
      sequence: _telemetry.nextSequence(),
      runId: _telemetry.runId,
      meta: _attributes(),
      error: _error,
      stackTrace: _stackTrace ?? _capturedTrace(level),
      description: _description,
      verbosity: _verbosity,
      traceId: trace?.traceId,
      spanId: trace?.spanId,
    );
  }

  /// A trace for an event that arrived without one, when the pipeline asks for
  /// them from this level up.
  StackTrace? _capturedTrace(LogLevel level) {
    final floor = _telemetry.stackTraceAtLevel;
    if (floor == null || level < floor) return null;
    return .current;
  }

  LogEvent? _log(LogLevel level) {
    assert(_loggedLevel == null, 'A draft logs once; this one already logged.');
    _acted = true;
    _loggedLevel = level;
    // Stamped before the gate, so a channel action that snapshots on the next
    // microtask still records the moment the call site acted.
    _timestamp ??= _telemetry.clock();
    // The `Enabled` check applies here too: building the record copies the
    // attributes and may run a lazy body.
    if (!_telemetry.isEnabled(level, verbosity: _verbosity)) return null;
    final event = _event = _snapshot(level);
    _telemetry.emit(event);
    return event;
  }

  /// Marks a non-log action and arms the fan-out.
  void _act() {
    _acted = true;
    _timestamp ??= _telemetry.clock();
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(_afterActions);
  }

  void _afterActions() {
    // A channel fired but nothing was logged: log it, so a user-visible effect
    // always leaves a record.
    if (_loggedLevel == null) _log(_implicitLevel());
    if (_channels.isEmpty) return;
    // `_event` is null when `isEnabled` suppressed the log action; the channels
    // still need the event they share, so it is built anyway — a toast's
    // "Details" cannot open a record that was never made.
    final event = _event ??= _snapshot(_loggedLevel!);
    for (final channel in _channels) {
      channel(event);
    }
    _channels.clear();
  }

  /// Resolves any `Object Function()` value, leaving the map untouched when
  /// there is none.
  static Map<String, Object?> _resolve(Map<String, Object?> attributes) {
    Map<String, Object?>? resolved;
    for (final MapEntry(:key, :value) in attributes.entries) {
      if (value is Object Function()) (resolved ??= Map<String, Object?>.of(attributes))[key] = value();
    }
    return resolved ?? attributes;
  }

  /// Whether [body] carries at least `Area | operation`.
  static bool _isCanonicalBody(String body) {
    final parts = body.split('|');
    return parts.length >= 2 && parts.first.trim().isNotEmpty && parts[1].trim().isNotEmpty;
  }
}
