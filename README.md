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
  draft used only for a toast is still logged.
- **Severity says who can act.** `warn` is a condition a user or a network can resolve: journaled,
  never an issue. `error` is a defect: captured by a `ReportingSink` at or above its `captureLevel`,
  through a dedupe per failure identity and a per-minute ceiling.

The record follows OpenTelemetry's log record (body, attributes, resource, severity number 1-24,
event name, trace ids), so it maps onto Sentry's structured logs, `dart:developer`'s levels and any
future exporter without translation.

## Describe with `.`, act with `..`

A fluent chain can be dropped when its terminal call is forgotten. The analyzer closes that gap:
every builder is `@useResult`, so a dropped one is an `unused_result` diagnostic where it is
written, and a build failure under `--fatal-warnings`.

```dart
log('Settings | save | failed').meta({'app.settings.key': 'theme'});   // unused_result
log('Settings | save | failed').meta({'app.settings.key': 'theme'}).warn();  // fine
```

That is a static guard rather than a runtime one. It costs nothing when the app runs, it points at
the line that wrote the code, and it cannot mistake a draft that is still being built, one held
across an `await` while a detail is fetched, for one that was dropped.

## Context that travels

Three layers, each winning over the one before it:

```dart
log.resource = {'app.version': '1.0.0', 'app.environment': 'prod'};   // the launch
log.scoped({'rpc.path': '/auth.v1/SignIn'}, () async {               // the operation
  await client.signIn();                                             // survives awaits
});
log('Rpc | call | failed').meta({'rpc.code': 'unavailable'}).warn();  // the call site
```

`scoped` is `slog.With`, `ILogger.BeginScope`, Serilog's `LogContext`: named once by the code that
knows it. It is carried by the `Zone`, so it follows an `await` inside the body and does not follow
a callback registered outside it.

`resource` is OpenTelemetry's `Resource` and stays a field of its own, `LogEvent.resource`, rather
than being copied into every event's `meta`. It is the same map object on every event, it is not
rendered on a console line, and a sink reads it through `event.attributes` with everything else. An
attribute value may be an `Object Function()`, evaluated once and only if the event is built.

```dart
event.meta        // what varied: the scope, then the call site
event.resource    // what identifies the launch
event.attributes  // the flat projection a sink stores: resource, meta, event.name, exception.*
```

## A stable identity

`name` is OpenTelemetry's `EventName`, .NET's `EventId`, the error slug of wide events:

```dart
log('Sync | upload | refused').name('sync.upload.refused').cause(error).error();
```

The body is prose and gets copy-edited. Anything that keys on it, a crash reporter's fingerprint or
`ReportThrottle`, reads that edit as a new failure. Set a name and those keys stop moving.

## Trace correlation

`LogEvent` carries `traceId` and `spanId`, read at the moment the call site acted. Nothing here
starts or ends a span; whatever owns tracing supplies them:

```dart
log.traceContext = () {
  final span = Sentry.getSpan();
  return span == null ? null : (traceId: span.context.traceId.toString(), spanId: span.context.spanId.toString());
};
```

## Emit and flush

`emit` is the OpenTelemetry bridge API's `Emit`: how a record this pipeline did not compose gets in,
such as a bridge from `package:logging` keeping the record's own timestamp, or a test replaying a
fixture. Nothing is enriched, so a bridge passes what it wants carried. `flush` is `ForceFlush`:
every sink that implements `Flushable` writes through, which is what the app going to the background
or a database about to close needs.

```dart
log.emit(LogEvent(
  level: .warn,
  body: 'Logging | forwarded | record',
  timestamp: record.time.toUtc(),
  sequence: log.nextSequence(),
  runId: log.runId,
  resource: log.resource,
));
await log.flush();
```

## Conventions checked in debug

While `Telemetry.strict` is on (the default), an attribute key and an event `name` must be
OpenTelemetry-named, an analytics name must be one snake_case word, a trace tier must be 1 to 6, and
a body must carry at least `Area | operation`, checked where the body is written rather than a
microtask later. Every check lives inside an `assert`, so a release build pays nothing and cannot
throw. Turn it off for a pipeline whose bodies all come from elsewhere; for a single bridged line,
`LogDraft(log, line, lenient: true)` is the narrower tool, and `emit` is never checked at all.

## Sinks are yours

The package ships the console sink, the ring buffer and `ReportingSink`, which holds the
crash-reporting policy: a breadcrumb floor, throttled capture above a capture floor, and an
escalation below it as a structured log, with three hooks where the vendor goes. The two floors are
independent, and a call site says `..escalate()` without knowing either. The sink decides, and its
`ReportThrottle` makes a second send for an already-captured failure free.

Everything else is an interface: `TelemetrySink`, `ToastSink`, `NotifySink`, `TrackSink`,
`EscalationSink`, `Flushable`. A journal is a database you chose, a reporter is an account you own,
and an inbox has a vocabulary only your app knows, which is why `NotifySink` takes an `Object kind`.

An analytics event name is a product vocabulary rather than a log body: lowercase snake_case, from a
bounded set the application owns. Backends cap that set, Firebase at 500 distinct names and 25
properties per event, so a name built out of a value exhausts it.

## Console

One greppable line: `HH:MM:SS [I] Area | operation | message event.name=… key=value`, the error
after ` | `, the stack trace below it for failures only. A value containing a space, a quote, an `=`
or a control character is quoted and escaped, so the pairs stay parseable and nothing in a value can
drive the terminal it is printed to. The body and the error text are escaped the same way; the stack
trace is the one part allowed to be multi-line.

Where the destination renders colour, the tag is in its level's colour (red `[E]`, yellow `[W]`,
green `[I]`) and the time and the keys are dimmed, so what varies between two lines stays plain.
That is the layout of `tint`, `zerolog`'s console writer and `charmbracelet/log`, and it is all the
colour there is: a coloured body would hide the attributes.

### The level tag

The tag's text is `TelemetryOptions.levelTag`: one of four presets, or a map of the app's own.

```dart
LevelTag.bracketed                     // [I]   the default, and what a log without colour greps best
LevelTag.letter                        // I     the bare letter, once colour carries the level
LevelTag.word                          // INFO  what tracing, slog and charmbracelet/log print, five wide
LevelTag.glyph                         // 💡    🔍 🐞 💡 ⚠️ 🚫 ❗, as package:logger shows it
LevelTag({LogLevel.info: 'ℹ', ...})   // yours; a level left out falls back to [I]
```

### Icons

`TelemetryOptions.icon` adds the subsystem's glyph after the tag and drops the word the glyph
already says:

```dart
const TelemetryOptions(
  levelTag: LevelTag.letter,
  icon: AreaIcons({'Boot': '🏗', 'Rpc': '🌍', 'Control': '🪢'}),
)
```

```
11:01:54 I 🏗 init | first launch
11:01:54 I 🌍 call | ok rpc.path=/auth.v1/SignIn net.duration_ms=42
11:01:54 I 🪢 lifecycle | disposed control.controller=PairingController
11:01:54 E 🪢 handler | failed control.controller=PairingController | Bad state: …
11:01:54 I Pairing | handshake | ok
```

The tag says the level and the glyph says the subsystem, so neither stands in for the other, and a
line always carries both: the subsystem as a glyph or, for an area nobody mapped, as the word.
`replacesArea: false` keeps the word on every line, which a log grepped by area wants. `AreaIcons`
is a map; `ConsoleIcon` is the interface behind it, for a rule of the app's own.

This is the console and nothing else. The journal, the crash reporter and the breadcrumb trail are
given `LogEvent.body`, which stays `Area | operation | message`; a glyph in the body would reach all
three and would take the place of `event.area`. Most terminals draw an emoji two columns wide, so
pick glyphs of one width. The forms with a variation selector (`⚠️`, `⚙️`) align better than the
bare ones.

Colours are turned off automatically where the destination cannot render them: `NO_COLOR` (which
wins over everything), `TERM=dumb`, a browser console, DevTools, and any run without a terminal
except on a phone, since a redirect to a file must not collect escape codes. `FORCE_COLOR` turns
them back on.

`LogOutput.developer` goes to `dart:developer`'s `log()` on the VM and to the browser console on the
web, where that function is a no-op. The `print` destination splits its output at every newline and
every 1000 code units, never through a surrogate pair, because Android's logger truncates a call at
about 4 KB and the casualty is the stack trace being chased.

## What it costs

`make bench` (compiled, asserts off), per call:

| path | ns/op |
|---|---|
| disabled, `log.d(...)` | 10-20 |
| disabled, `log(...).meta(...).debug()` | ~90 |
| enabled, `log.i(...)` into a null sink | ~90 |
| enabled, with attributes | ~300 |
| enabled, inside a scope | ~350 |

Order of magnitude rather than a promise: run it on the machine that matters. A disabled shortcut is
a level comparison and nothing else, with no clock, no allocation and no trace lookup. The disabled
fluent form still allocates the draft and its attribute map before the gate is reached, which is the
price of describing an event before naming its level. Reach for the shortcut on a hot path.

## Isolates

State is per isolate: a spawned isolate sees none of these sinks and none of the zone-scoped
options. Give it its own `Telemetry`. To forward what it logs, send the primitive fields over a
`SendPort`, since an `Object? error` and a `StackTrace` are not reliably sendable, then rebuild a
`LogEvent` on the other side, number it with `nextSequence()` and hand it to `emit`.

## What this does not do

Sampling (.NET's `AddRandomProbabilisticSampler`), pipeline-level redaction (.NET's
`Compliance.Redaction`), a structured `AnyValue` body, `ObservedTimestamp`, `InstrumentationScope`,
and JSON serialization of an event. Each has a precedent worth copying and none has a consumer here
yet; a sink does its own redaction today, and the throttle is a deterministic dedupe rather than a
sampler.

## Migrating from 0.2

- **`event.meta` no longer holds the launch attributes.** A sink that stored `meta` should store
  `event.attributes`, the flat projection of `resource`, `meta`, `event.name` and `exception.*`.
  `meta` is now only what the scope and the call site said.
- **`LogDraft.sentry()` is gone**; it is `escalate()`, and it always forwards. Whether an escalation
  becomes an incident or a structured log is `ReportingSink.captureLevel`'s decision, and the
  throttle makes a second send for an already-captured failure free.
- **A dropped builder is an analyzer warning.** `log('A | b | c').meta({...});` as a statement, or
  as a cascade section, is `unused_result`, so describe with `.` and act with `..`. There is no
  runtime report any more.
- **`LogBuffer` has a second ring** for `trace`, sized by `traceLimit` (100), so tracing cannot
  evict the boot before a journal drains it.
- **`kAttributeKey`, `kEventName` and `kTrackName` are exported**, so a source-scanning test in an
  application can assert the same rule the runtime asserts.

## Install

```yaml
dependencies:
  telemetry:
    git:
      url: https://github.com/zs-dima/telemetry.git
      ref: v0.3.0
```

## Credit

Thanks to Plague Fox for [`package:l`](https://github.com/PlugFox/l), which the console layer here
learned from: per-environment delegates, zone-scoped options, `print` capture that forwards to the
parent zone, release gating, lazy messages, the six trace tiers, and the ANSI palette. `emit` is its
`l.log(LogMessage)`, generalised.

`l` is WTFPL, so nothing obliges this note. The small amount of code carried over is marked where it
sits, in `lib/src/console/ansi.dart` and `lib/src/zone.dart`. If you want a logger rather than an
event model with your own sinks, use `l` directly.

## Changelog

[CHANGELOG.md](CHANGELOG.md)

## License

[MIT](LICENSE)
