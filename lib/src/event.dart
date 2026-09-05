import 'package:meta/meta.dart';
import 'package:telemetry/src/level.dart';

/// {@template log_event}
/// One thing that happened, in the shape every channel can consume.
///
/// An OpenTelemetry log record: a stable, language-neutral [body] plus
/// structured [meta] attributes. The body groups issues in a crash reporter and
/// is what a human greps for; the attributes are what a query filters on.
/// Interpolating `'refused for user $id'` into the body destroys both.
/// {@endtemplate}
@immutable
final class LogEvent {
  /// {@macro log_event}
  LogEvent({
    required this.level,
    required this.body,
    required this.timestamp,
    required this.runId,
    Map<String, Object?> meta = const <String, Object?>{},
    this.error,
    this.stackTrace,
    this.description,
    this.verbosity = 0,
    this.name,
    this.sequence = 0,
    this.traceId,
    this.spanId,
  }) : meta = meta.isEmpty ? const <String, Object?>{} : Map<String, Object?>.unmodifiable(meta),
       assert(timestamp.isUtc, 'LogEvent.timestamp must be UTC; local time is a rendering choice');

  /// Severity.
  final LogLevel level;

  /// The canonical one-liner, by convention `Area | operation | message`.
  ///
  /// Stable across runs and locales; values belong in [meta].
  final String body;

  /// A stable identifier for this kind of event, independent of [body].
  ///
  /// OpenTelemetry's `EventName`, .NET's `EventId`, the "error slug" of wide
  /// events: `pairing.handshake.refused`, lowercase and dot-separated. The body
  /// is prose and gets copy-edited; anything that keys on it — a crash
  /// reporter's fingerprint, `ReportThrottle` — then treats the edit as a new
  /// failure. Set this and those keys stop moving.
  final String? name;

  /// Structured attributes, OpenTelemetry-named (lowercase, dot-namespaced,
  /// snake_case within a segment): `app.pairing.attempt`, `rpc.path`,
  /// `control.duration_ms`.
  ///
  /// Values are scalars (`String`, `num`, `bool`), lists or maps of scalars, or
  /// anything whose `toString()` a sink can store. A sink is free to serialize
  /// them however it stores rows; nothing here promises a JSON shape.
  final Map<String, Object?> meta;

  /// The error this event is about, if any.
  final Object? error;

  /// Stack trace for [error].
  final StackTrace? stackTrace;

  /// User-facing, localized text.
  ///
  /// Separate from [body]: a journal and a crash reporter need a stable English
  /// line, a toast needs the user's language, and one event carries both.
  final String? description;

  /// When it happened, in UTC. Local time is a rendering choice; a stamp that
  /// leaves the device (report, e-mail, export) must never be local.
  final DateTime timestamp;

  /// Position of this event in its launch, from zero.
  ///
  /// `package:logging`'s `sequenceNumber` and `dart:developer`'s: a total order
  /// that survives a timestamp with second resolution and two events inside one
  /// millisecond. A journal sorts by `(timestamp, sequence)`.
  final int sequence;

  /// Identifier of the app launch this event belongs to.
  ///
  /// Usable as a crash-reporter tag, so a report can be joined to the lines that
  /// led to it, including those of an earlier launch.
  final String runId;

  /// W3C trace id of the trace in flight when this was logged, if any.
  ///
  /// The OpenTelemetry log record's `TraceId`. Filled from
  /// `Telemetry.traceContext`; nothing here starts or ends a span.
  final String? traceId;

  /// W3C span id of the span in flight when this was logged, if any.
  final String? spanId;

  /// Sub-level for [LogLevel.trace] noise (1 = loud, 6 = whisper), filtered by
  /// `TelemetryOptions.maxVerbosity` and `LogBuffer.maxVerbosity`.
  final int verbosity;

  /// First `|`-separated segment of [body]: the subsystem.
  String get area => _segment(0);

  /// Second `|`-separated segment of [body]: the operation.
  String get operation => _segment(1);

  /// [meta] plus the attributes derived from [name] and [error].
  ///
  /// The stack trace is not among them: journal rows and crash reports have a
  /// dedicated field for it, and an attribute copy would duplicate it.
  Map<String, Object?> get attributes => <String, Object?>{
    ...meta,
    if (name case final String value) 'event.name': value,
    if (error case final Object e) ...<String, Object?>{
      'exception.type': e.runtimeType.toString(),
      'exception.message': e.toString(),
    },
  };

  /// A copy with the given fields replaced.
  ///
  /// For a bridge that adopts a foreign record and for a sink that enriches one
  /// before forwarding. A null argument means "keep": this cannot clear a field.
  LogEvent copyWith({
    LogLevel? level,
    String? body,
    String? name,
    Map<String, Object?>? meta,
    Object? error,
    StackTrace? stackTrace,
    String? description,
    DateTime? timestamp,
    int? sequence,
    String? runId,
    String? traceId,
    String? spanId,
    int? verbosity,
  }) => .new(
    level: level ?? this.level,
    body: body ?? this.body,
    name: name ?? this.name,
    timestamp: timestamp ?? this.timestamp,
    sequence: sequence ?? this.sequence,
    runId: runId ?? this.runId,
    meta: meta ?? this.meta,
    error: error ?? this.error,
    stackTrace: stackTrace ?? this.stackTrace,
    description: description ?? this.description,
    verbosity: verbosity ?? this.verbosity,
    traceId: traceId ?? this.traceId,
    spanId: spanId ?? this.spanId,
  );

  @override
  String toString() => '[${level.prefix}] $body';

  /// The [index]-th `|`-separated part of [body], trimmed; empty when absent.
  String _segment(int index) {
    final parts = body.split('|');
    return index < parts.length ? parts[index].trim() : '';
  }
}
