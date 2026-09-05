# telemetry

[![CI](https://github.com/zs-dima/telemetry/actions/workflows/ci.yml/badge.svg)](https://github.com/zs-dima/telemetry/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](LICENSE)

One event model for everything that happens in an application, and thin sinks that carry it
wherever it needs to go: the console, a journal, a crash reporter, a toast, an inbox, analytics.

Pure Dart. No Flutter, no globals installed behind your back, no logging framework to adopt. The
industrial pattern (`slog`, Serilog, OpenTelemetry) is a small owned core with thin sinks, and this
is that core.

## The shape

A call site describes what happened once and then names the channels it wants. Nothing is inferred
from severity, and nothing waits for a terminal call:

```dart
log('Pairing | handshake | refused')
    .meta({'app.pairing.attempt': 3})
    .cause(error)
    .description(copy.pairingRefused)
  ..warn()
  ..toast(tone: ToastTone.alert);
```

Three rules hold that together:

- **The body is the grouping key.** `Area | operation | message`, with every variable (a path, a
  code, a duration) as an attribute. A value interpolated into the body gives a crash reporter one
  issue per value.
- **Every action is independent and explicit.** Cascade order cannot matter: the actions record
  what they want and the draft fans them out at the end against the one event that was logged. A
  draft used only for a toast is still logged; a draft with no action at all is reported, in debug,
  as `Telemetry | draft | unused`.
- **Severity says who can act.** `warn` is a condition a user or a network can resolve: journaled,
  never an issue. `error` is a defect: captured, through a dedupe per failure identity and a
  per-minute ceiling (`ReportThrottle`, applied by `ReportingSink`).

The record follows OpenTelemetry's log record (body, attributes, severity number 1-24, event name,
trace ids), so it maps onto Sentry's structured logs, `dart:developer`'s levels and any future
exporter without translation.

## Context that travels

Three layers, merged at the moment the event is built, each winning over the one before it:

```dart
log.resource = {'app.version': '1.0.0', 'app.environment': 'prod'};   // the launch

log.scoped({'rpc.path': '/auth.v1/SignIn'}, () async {               // the operation
  await client.signIn();                                             // survives awaits
});

log('Rpc | call | failed').meta({'rpc.code': 'unavailable'}).warn();  // the call site
```

`scoped` is `slog.With`, `ILogger.BeginScope`, Serilog's `LogContext`: named once by the code that
knows it, rather than repeated below. An attribute value may be an `Object Function()`, evaluated
only if the event is actually built.

## A stable identity

`name` is OpenTelemetry's `EventName`, .NET's `EventId`, the error slug of wide events:

```dart
log('Sync | upload | refused').name('sync.upload.refused').cause(error).error();
```

The body is prose and gets copy-edited. Anything that keys on it — a crash reporter's fingerprint,
`ReportThrottle` — treats that edit as a new failure. Set a name and those keys stop moving.

## Trace correlation

`LogEvent` carries `traceId` and `spanId`. Nothing here starts or ends a span; whatever owns tracing
supplies them:

```dart
log.traceContext = () {
  final span = Sentry.getSpan();
  return span == null ? null : (traceId: span.context.traceId.toString(), spanId: span.context.spanId.toString());
};
```

## Emit and flush

`emit` is the OpenTelemetry bridge API's `Emit`: how a record this pipeline did not compose gets in
— a bridge from `package:logging` keeping the record's own timestamp, an isolate forwarding what it
logged, a test replaying a fixture. `flush` is `ForceFlush`: every sink that implements `Flushable`
writes through, which is what the app going to the background or a database about to close needs.

```dart
log.emit(LogEvent(level: .warn, body: 'Logging | forwarded | record', timestamp: record.time.toUtc(), runId: log.runId));
await log.flush();
```

## Conventions checked in debug

While `Telemetry.strict` is on (the default), an attribute key must be OpenTelemetry-named
(`app.pairing.attempt`) and a body must carry at least `Area | operation`. Both checks live inside
`assert`, so a release build pays nothing and cannot throw. Turn it off for a pipeline whose bodies
come from elsewhere; `emit` is never checked, since a bridge does not choose its wording.

## Sinks are yours

The package ships the console sink, the ring buffer and `ReportingSink`, which is the crash-reporting
policy (breadcrumb floor, throttled capture, escalation as a structured log) with three hooks where
the vendor goes. Everything else is an interface: `TelemetrySink`, `ToastSink`, `NotifySink`,
`TrackSink`, `EscalationSink`, `Flushable`. A journal is a database you chose, a reporter is an
account you own, and an inbox has a vocabulary only your app knows. `NotifySink` takes an
`Object kind` for that reason.

An analytics event name is a product vocabulary, not a log body: lowercase snake_case, from a
bounded set the application owns. Backends cap that set — Firebase at 500 distinct names and 25
properties per event — so a name built out of a value exhausts it.

## Attribute values

Scalars (`String`, `num`, `bool`), lists or maps of scalars, or anything whose `toString()` a sink
can store. Nothing here promises a JSON shape: a journal writes columns, a crash reporter writes
tags, and each chooses its own subset.

## Console

One greppable line: `HH:MM:SS [I] Area | operation | message key=value`, the error after ` | `, the
stack trace below it for failures only. A value containing a space, an `=` or a quote is quoted.
Colours are turned off automatically where the destination cannot render them — a browser console,
DevTools, `NO_COLOR`, `TERM=dumb`. The `print` destination splits its output at 800 characters,
Flutter's `debugPrintThrottled` width, because Android's logger drops what it cannot take in one
call and the casualty is the stack trace being chased.

## Isolates

State is per isolate, like everything else in Dart: a spawned isolate sees none of these sinks and
none of the zone-scoped options. Give it its own `Telemetry` and forward what it logs to the main
one over a `SendPort`, rebuilding each event with `LogEvent.copyWith` and handing it to `emit`.

## Install

```yaml
dependencies:
  telemetry:
    git:
      url: https://github.com/zs-dima/telemetry.git
      ref: v0.2.1
```

## Credit

The console layer's ideas (per-environment delegates, zone-scoped options, `print` capture that
forwards to the parent zone, release gating, lazy messages, the six trace tiers) were studied in
and carried over from [`package:l`](https://github.com/PlugFox/l) (WTFPL); copied code is marked
where it sits.

## Changelog

[CHANGELOG.md](CHANGELOG.md)

## License

[MIT](LICENSE)
