import 'dart:collection';

import 'package:meta/meta.dart';
import 'package:telemetry/src/body.dart';
import 'package:telemetry/src/level.dart';

/// {@template log_event}
/// One thing that happened, in the shape every channel can consume.
///
/// An OpenTelemetry log record: a stable [body] plus structured attributes. The
/// body groups issues in a crash reporter and is what a human greps for; the
/// attributes are what a query filters on. Interpolating `'refused for user
/// $id'` into the body destroys both.
///
/// The attributes arrive in two fields, as in OpenTelemetry. [resource]
/// identifies the source and is the same object on every event of a launch,
/// [meta] is what this occurrence said, and [attributes] is the flat projection
/// a sink stores.
/// {@endtemplate}
@immutable
final class LogEvent {
  /// {@macro log_event}
  LogEvent({
    required this.level,
    required this.body,
    required DateTime timestamp,
    required this.runId,
    Map<String, Object?> meta = const <String, Object?>{},
    this.resource = const <String, Object?>{},
    this.error,
    this.stackTrace,
    this.description,
    this.verbosity = 0,
    this.name,
    this.sequence = 0,
    this.traceId,
    this.spanId,
  }) : meta = meta.isEmpty ? const <String, Object?>{} : Map<String, Object?>.unmodifiable(meta),
       // Normalised rather than asserted: a bridge composing its own record is
       // the one caller that can pass local time, and in release an assert says
       // nothing. `toUtc` returns the same instance when it is UTC already.
       timestamp = timestamp.toUtc();

  /// Severity.
  final LogLevel level;

  /// The canonical one-liner, by convention `Area | operation | message`.
  ///
  /// Stable across runs and locales; values belong in [meta].
  final String body;

  /// A stable identifier for this kind of event, independent of [body].
  ///
  /// OpenTelemetry's `EventName`, .NET's `EventId`, the error slug of wide
  /// events: `pairing.handshake.refused`. It says that two lines are the same
  /// failure however their bodies are worded, which is what `ReportThrottle`
  /// dedupes on and what a crash reporter should fingerprint on. Without it
  /// both fall back to the body, and a reworded body is a new group.
  final String? name;

  /// What this occurrence said: the ambient scope, then the call site's own
  /// `.meta({...})`, the call site winning.
  ///
  /// OpenTelemetry-named: lowercase, dot-namespaced, snake_case within a
  /// segment, as in `app.pairing.attempt`. A value is a scalar, a list or map of
  /// scalars, or anything whose `toString()` a sink can store; nothing here
  /// promises a JSON shape.
  ///
  /// The launch attributes live in [resource], so a console line carries what
  /// varies and nothing else.
  final Map<String, Object?> meta;

  /// What identifies the launch: `app.version`, `app.environment`, a device
  /// model.
  ///
  /// OpenTelemetry's `Resource`, kept apart from [meta] because it does not vary
  /// per occurrence. Its semantic-convention keys are `service.name` (the one
  /// OpenTelemetry requires), `service.version` and `deployment.environment.name`.
  ///
  /// The same map object travels on every event, at one reference each.
  /// `Telemetry.resource` makes it unmodifiable; code that builds a [LogEvent]
  /// by hand must not mutate what it passes here.
  final Map<String, Object?> resource;

  /// The error this event is about, if any.
  final Object? error;

  /// Stack trace for [error].
  final StackTrace? stackTrace;

  /// User-facing, localized text.
  ///
  /// Separate from [body]: a journal and a crash reporter need stable English, a
  /// toast needs the user's language, and one event carries both.
  final String? description;

  /// When it happened, in UTC. Local time is a rendering choice, and a stamp
  /// that leaves the device must never be local.
  final DateTime timestamp;

  /// Position of this event in its launch, from zero.
  ///
  /// `package:logging`'s `sequenceNumber`: a total order that survives two
  /// events inside one millisecond. A journal sorts by `(timestamp, sequence)`.
  final int sequence;

  /// Identifier of the app launch this event belongs to.
  ///
  /// Usable as a crash-reporter tag, so a report can be joined to the lines that
  /// led to it, including an earlier launch's.
  final String runId;

  /// W3C trace id of the trace in flight when this was logged, if any.
  ///
  /// The log record's `TraceId`, read from `Telemetry.traceContext` at the
  /// moment the call site acted. Nothing here starts or ends a span.
  final String? traceId;

  /// W3C span id of the span in flight when this was logged, if any.
  final String? spanId;

  /// Sub-level for [LogLevel.trace] noise, 1 loud to 6 a whisper, filtered by
  /// `TelemetryOptions.maxVerbosity` and `LogBuffer.maxVerbosity`.
  ///
  /// Zero means an untiered line, which every ceiling admits, and it is what a
  /// level other than `trace` carries.
  final int verbosity;

  /// Everything a sink stores: [resource], then [meta], plus the attributes
  /// derived from [name] and [error].
  ///
  /// A sink that writes one column, one tag set or one JSON blob wants this; a
  /// console showing what varies wants [meta]. [meta] wins over [resource] on a
  /// shared key, and both fields keep their own value.
  ///
  /// The stack trace is not included: journal rows and crash reports have a
  /// field of their own for it.
  ///
  /// A storage projection rather than the record: `event.name` is written in
  /// here for a sink whose rows have no field of their own for it, although
  /// OpenTelemetry deprecated that attribute in favour of the `EventName`
  /// field, which is [name].
  ///
  /// Built once on first read, and unmodifiable: an immutable record has one
  /// answer, and one sink must not rewrite what the next one stores.
  ///
  /// An exporter reads [name], [meta] and [resource] instead: this map holds
  /// `event.name`, which OpenTelemetry deprecated as an attribute in favour of
  /// the field.
  late final Map<String, Object?> attributes = UnmodifiableMapView<String, Object?>(<String, Object?>{
    ...resource,
    ...meta,
    if (name case final String value) 'event.name': value,
    if (error case final Object e) ...<String, Object?>{
      'exception.type': e.runtimeType.toString(),
      'exception.message': e.toString(),
    },
  });

  /// First `|`-separated segment of [body]: the subsystem. Empty for a body
  /// that carries no separator, such as a bridged line or a captured `print`.
  String get area => bodyArea(body);

  /// Second `|`-separated segment of [body]: the operation. Empty when there is
  /// none.
  String get operation => bodyOperation(body);

  /// [body] without its message: `Area | operation`, the area alone when there
  /// is no second segment, empty when there is no separator.
  ///
  /// What a breadcrumb or a category wants. The message segment is the one part
  /// a call site writes freely, so it is where a user-authored label or an
  /// interpolated value ends up; this is the part that does not vary.
  String get site => bodySite(body);

  /// The OpenTelemetry severity number to store or export.
  ///
  /// [LogLevel.severityNumber] for every level but `trace`, which spends the
  /// four numbers of its range on [verbosity]: the spec asks a source with
  /// several severities inside one range to number them by importance, so tier
  /// 1 (the loudest, and an untiered line) is 4 and tiers 4 to 6 are 1.
  int get severityNumber => level == .trace ? (5 - verbosity).clamp(1, 4) : level.severityNumber;

  /// A copy with the given fields replaced.
  ///
  /// For a bridge that adopts a foreign record, or a sink that enriches one
  /// before forwarding. A null argument keeps the current value, so this cannot
  /// clear a field.
  LogEvent copyWith({
    LogLevel? level,
    String? body,
    String? name,
    Map<String, Object?>? meta,
    Map<String, Object?>? resource,
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
    resource: resource ?? this.resource,
    error: error ?? this.error,
    stackTrace: stackTrace ?? this.stackTrace,
    description: description ?? this.description,
    verbosity: verbosity ?? this.verbosity,
    traceId: traceId ?? this.traceId,
    spanId: spanId ?? this.spanId,
  );

  @override
  String toString() => '[${level.prefix}] $body';
}
