// A builder returns `this`, so one draft can describe an event and then name
// several channels.
// ignore_for_file: avoid_returning_this
// `lenient` and `gated` cannot be initializing formals: a named parameter may
// not start with an underscore.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:telemetry/src/attributes.dart';
import 'package:telemetry/src/event.dart';
import 'package:telemetry/src/level.dart';
import 'package:telemetry/src/sink.dart';
import 'package:telemetry/src/telemetry.dart';
import 'package:telemetry/src/zone.dart';

/// The `@useResult` message: a dropped draft is a dropped log line.
const String _kChain =
    'a builder returns the draft: chain it with `.`, and close it with an action '
    '(`..warn()`, `..toast()`). A builder whose result is dropped logs nothing.';

/// Everything known about one event, before any channel is named.
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
/// A log action ([warn], [error], [at]) builds the [LogEvent] and dispatches it
/// to the sinks synchronously. A channel action ([toast], [escalate], [track],
/// [notify]) validates its arguments and records itself; on the next microtask
/// every recorded channel receives that same event. Cascade order cannot
/// matter, and a toast's "Details" opens the record the sinks were given.
///
/// Every builder is `@useResult`, so a dropped chain is an `unused_result`
/// diagnostic where it is written, and a build failure under
/// `--fatal-warnings`. There is no runtime guard: it could not tell a draft
/// held across an `await` from a forgotten one.
final class LogDraft {
  /// Created by [Telemetry.call].
  ///
  /// [lenient] exempts the body from the `Telemetry.strict` convention check,
  /// for a captured `print` or a record bridged from another package. [gated]
  /// says the caller already asked `Telemetry.isEnabled` for its level.
  LogDraft(this._telemetry, this._message, {bool lenient = false, bool gated = false})
    : _lenient = lenient,
      _gated = gated {
    // Checked here rather than at snapshot, so the assertion points at the line
    // that wrote the body and fires whether or not the level is consumed.
    assert(
      _lenient || !_telemetry.strict || _message is! String || _isCanonicalBody(_message),
      'a log body is `Area | operation | message`, the crash reporter\'s grouping key: '
      'anything variable goes into .meta({...}). Pass lenient: true for a bridged line, '
      'or set Telemetry.strict = false for a pipeline whose bodies all come from elsewhere. '
      'Got: $_message',
    );
  }

  final Telemetry _telemetry;
  final Object _message;
  final bool _lenient;
  final bool _gated;

  Map<String, Object?>? _meta;
  Object? _error;
  StackTrace? _stackTrace;
  String? _description;
  String? _name;
  int _verbosity = 0;
  DateTime? _timestamp;
  ({String traceId, String? spanId})? _trace;

  /// Channels waiting for the event, in the order they were named. Built on the
  /// first channel action; most drafts never name one.
  List<void Function(LogEvent event)>? _channels;

  LogLevel? _loggedLevel;
  LogEvent? _event;
  bool _scheduled = false;

  /// Adds OpenTelemetry-named attributes: lowercase, dot-namespaced,
  /// snake_case, as in `app.pairing.attempt`. A query filters on these, so
  /// anything variable belongs here rather than in the body.
  ///
  /// A value may be an `Object Function()`, evaluated at snapshot time and only
  /// if the event is built, like `slog`'s `LogValuer`. A null map is a no-op.
  @UseResult(_kChain)
  LogDraft meta(Map<String, Object?>? attributes) {
    assert(_loggedLevel == null, 'A draft is described before it is logged; this one already logged.');
    if (attributes == null || attributes.isEmpty) return this;
    assert(
      !_telemetry.strict || firstInvalidKey(attributes) == null,
      'an attribute key is OpenTelemetry-named: lowercase, dot-namespaced, snake_case within a '
      'segment, at least two segments (app.pairing.attempt). '
      'Got: ${firstInvalidKey(attributes)}',
    );
    (_meta ??= <String, Object?>{}).addAll(attributes);
    return this;
  }

  /// Attaches the error this event is about. When it carries a stack trace of
  /// its own and none was set, that trace is adopted.
  @UseResult(_kChain)
  LogDraft cause(Object? error, [StackTrace? stackTrace]) {
    assert(_loggedLevel == null, 'A draft is described before it is logged; this one already logged.');
    _error = error;
    if (stackTrace != null) {
      _stackTrace = stackTrace;
    } else if (_stackTrace == null && error is Error) {
      _stackTrace = error.stackTrace;
    }
    return this;
  }

  /// The localized sentence [toast] shows the user. The body stays stable
  /// English, since a crash reporter groups on it.
  @UseResult(_kChain)
  LogDraft description(String? text) {
    assert(_loggedLevel == null, 'A draft is described before it is logged; this one already logged.');
    _description = text;
    return this;
  }

  /// Sets [LogEvent.name], the identity that survives a copy edit to the body.
  ///
  /// Lowercase and dot-separated, `area.operation.outcome`. A crash reporter's
  /// fingerprint and `ReportThrottle` key on it once it is set.
  @UseResult(_kChain)
  LogDraft name(String value) {
    assert(_loggedLevel == null, 'A draft is described before it is logged; this one already logged.');
    assert(
      !_telemetry.strict || kEventName.hasMatch(value),
      'an event name is lowercase, dot-separated, at least two segments '
      '(pairing.handshake.refused). Got: $value',
    );
    _name = value;
    return this;
  }

  /// Marks a [trace] line as tier [level], 1 loud to 6 a whisper, filtered by
  /// `TelemetryOptions.maxVerbosity` and `LogBuffer.maxVerbosity`.
  /// `Telemetry.v1` to `v6` are the short form; this one also takes attributes.
  @UseResult(_kChain)
  LogDraft verbosity(int level) {
    assert(_loggedLevel == null, 'A draft is described before it is logged; this one already logged.');
    assert(level >= 1 && level <= 6, 'a trace tier is 1 (loud) to 6 (a whisper). Got: $level');
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

  /// Logs at [LogLevel.error]. A `ReportingSink` captures it as an incident by
  /// default.
  LogEvent? error() => _log(.error);

  /// Logs at [LogLevel.fatal]. A `ReportingSink` captures it as an incident.
  LogEvent? fatal() => _log(.fatal);

  /// Logs at a [level] computed at runtime, for a bridge or a transport whose
  /// severity depends on the outcome. A call site that knows its severity names
  /// it instead.
  LogEvent? at(LogLevel level) => _log(level);

  // --- Channel actions ---------------------------------------------------

  /// Shows the user [text], or [description] when it is null.
  ///
  /// Both are read when the cascade ends, so `..toast()` written above
  /// `..description(...)` still says what the description says. With neither,
  /// the body is shown and debug prints a diagnostic to the root zone.
  void toast({ToastTone tone = .info, String? text}) {
    _act();
    _channels!.add((event) {
      final message = text ?? _description;
      // The standard debug-only idiom; the body runs only in debug builds.
      // ignore: avoid-immediately-invoked-functions
      assert(() {
        if (message == null) {
          Zone.root.print(
            'Telemetry | toast | no user-facing text for "${event.body}": pass text:, or set '
            '.description(...). The log body is developer English and must not reach the UI',
          );
        }
        return true;
      }(), 'unreachable: the closure only reports');
      _telemetry.dispatchToast(ToastRequest(tone: tone, text: message ?? event.body, event: event));
    });
  }

  /// Sends this event to the crash reporter's [EscalationSink].
  ///
  /// The sink decides what becomes of it. A `ReportingSink` captures it as an
  /// incident at or above its `captureLevel`, and sends it as a structured log
  /// below that, so a warning is visible without filing an issue. [level]
  /// overrides the severity for this escalation only.
  ///
  /// Escalating an event the sink already captured costs nothing: the shared
  /// `ReportThrottle` identity refuses the second capture. [level] and
  /// [stackTrace] therefore cannot change a capture that already happened.
  /// Attach the trace at the failure, with `.cause(error, stackTrace)`.
  void escalate({LogLevel? level, StackTrace? stackTrace}) {
    _act();
    _channels!.add(
      (event) => _telemetry.dispatchEscalation(event, level: level, stackTrace: stackTrace ?? event.stackTrace),
    );
  }

  /// Records a product-analytics event. No tracker ships by default.
  ///
  /// [name] is a product vocabulary rather than a log body: lowercase
  /// snake_case, out of a bounded set the application owns. Backends cap that
  /// set, Firebase at 500 names and 25 properties per event, so a name built out
  /// of a value exhausts it.
  void track(String name, {Map<String, Object?> props = const <String, Object?>{}}) {
    assert(
      !_telemetry.strict || kTrackName.hasMatch(name),
      'an analytics event name is one lowercase snake_case word out of a bounded set '
      '(purchase_completed). Got: $name',
    );
    _act();
    // Copied: the fan-out is a microtask away, and a caller may reuse its map
    // before then.
    final payload = props.isEmpty ? const <String, Object?>{} : Map<String, Object?>.of(props);
    _channels!.add((event) => _telemetry.dispatchTrack(name, payload, event));
  }

  /// Writes a row into the app's notification inbox. Always explicit, never
  /// derived from severity.
  void notify(Object kind, {Map<String, Object?> args = const <String, Object?>{}}) {
    _act();
    final payload = args.isEmpty ? const <String, Object?>{} : Map<String, Object?>.of(args);
    _channels!.add((event) => _telemetry.dispatchNotify(kind, payload, event));
  }

  // --- Internals ---------------------------------------------------------

  /// The level of a draft that reached a channel without naming one.
  ///
  /// `warn` when a cause is attached, never `error`: a reporting sink captures
  /// `error`, so a forgotten `..warn()` would file an incident.
  LogLevel _implicitLevel() => _error == null ? .info : .warn;

  /// The body, building it now if the call site passed a lazy builder.
  String _bodyText() {
    final message = _message;
    if (message is String) return message;
    if (message is Object Function()) return message().toString();
    return message.toString();
  }

  /// The ambient scope, under what this call site set. The launch resource is a
  /// field of its own on [LogEvent].
  Map<String, Object?> _attributes() {
    final scope = currentTelemetryContext();
    final own = _meta;
    if (scope.isEmpty) return own == null ? const <String, Object?>{} : resolveAttributes(own);
    return resolveAttributes(<String, Object?>{...scope, ...?own});
  }

  LogEvent _snapshot(LogLevel level) {
    final body = _bodyText();
    // A `String` body was checked at construction; a lazy one can only be
    // checked once built.
    assert(
      _lenient || !_telemetry.strict || _message is String || _isCanonicalBody(body),
      'a log body is `Area | operation | message`, the crash reporter\'s grouping key. Got: $body',
    );
    return .new(
      level: level,
      body: body,
      name: _name,
      timestamp: _timestamp ??= _telemetry.now(),
      sequence: _telemetry.nextSequence(),
      runId: _telemetry.runId,
      meta: _attributes(),
      resource: _telemetry.resource,
      error: _error,
      stackTrace: _stackTrace ?? _capturedTrace(level),
      description: _description,
      verbosity: _verbosity,
      traceId: _trace?.traceId,
      spanId: _trace?.spanId,
    );
  }

  /// A trace for an event that arrived without one, from
  /// `Telemetry.stackTraceAtLevel` up.
  StackTrace? _capturedTrace(LogLevel level) {
    final floor = _telemetry.stackTraceAtLevel;
    if (floor == null || level < floor) return null;
    return .current;
  }

  LogEvent? _log(LogLevel level) {
    if (_loggedLevel != null) {
      assert(false, 'A draft logs once; this one already logged at ${_loggedLevel!.name}.');
      return _event;
    }
    _loggedLevel = level;
    // Building the record copies the attributes and may run a lazy body, so the
    // gate comes first. Nothing above this line allocates or reads the clock.
    if (!_gated && !_telemetry.isEnabled(level, verbosity: _verbosity)) return null;
    _mark();
    final event = _event = _snapshot(level);
    _telemetry.emit(event);
    return event;
  }

  /// Marks a non-log action and arms the fan-out.
  void _act() {
    _channels ??= <void Function(LogEvent event)>[];
    _mark();
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(_afterActions);
  }

  /// Stamps the moment the call site acted, and the trace it acted inside.
  ///
  /// Read here rather than at snapshot: a channel action snapshots a microtask
  /// later, when the span may have ended and the clock has moved.
  void _mark() {
    if (_timestamp != null) return;
    _timestamp = _telemetry.now();
    _trace = _telemetry.traceContext?.call();
  }

  void _afterActions() {
    // A channel fired without a log action: log it, so a user-visible effect
    // leaves a record.
    if (_loggedLevel == null) _log(_implicitLevel());
    final channels = _channels;
    if (channels == null || channels.isEmpty) return;
    // `_event` is null when `isEnabled` suppressed the log action. The channels
    // share one event regardless, so a toast's "Details" has a record to open.
    final event = _event ??= _snapshot(_loggedLevel!);
    try {
      for (final channel in channels) {
        try {
          channel(event);
        } on Object catch (error, stackTrace) {
          // One failing channel must not swallow the others or escape into the
          // zone, where the app's error handler would file it as a defect.
          Zone.root.print('Telemetry | channel | failed for "${event.body}" | $error\n$stackTrace');
        }
      }
    } finally {
      channels.clear();
    }
  }

  /// Whether [body] carries at least `Area | operation`.
  static bool _isCanonicalBody(Object body) {
    if (body is! String) return true;
    final parts = body.split('|');
    return parts.length >= 2 && parts.first.trim().isNotEmpty && parts[1].trim().isNotEmpty;
  }
}
