# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.5] - 2026-09-05

An architectural review of the whole package: module boundaries, the public surface, the OTel
mapping, and a hunt for failures under re-entrancy, zones and the asynchronous fan-out. The shape
held; these are the defects it found.

### Changed

- **`LogEvent.area` and `site` are empty for a body with no `|`.** They used to answer with the
  whole line, so a bridged record or a captured `print` became its own crash-reporter category,
  one per message. A body without a separator carries no subsystem to name.
- **`ReportThrottle` takes its clock in the constructor**, `ReportThrottle({Duration Function()?
  clock})`, instead of a `now:` argument per call. Mixing the two scales was an `assert`, and in
  release it produced negative durations that suppressed every report for the life of the process.
- **`LogEvent.attributes` is unmodifiable.** It is the map sinks store, on an immutable record, and
  one sink could rewrite what the next one wrote.
- **A local `LogEvent.timestamp` is normalised to UTC** rather than asserted. The assert said
  nothing in release, and a bridge composing its own record is the one caller that can pass local
  time.
- **`LogBuffer(limit: 0)` keeps nothing**, the way `traceLimit: 0` already did. It used to reach
  `removeFirst` on an empty ring and throw out of every log call in release.

### Fixed

- A sink whose `enabled` throws no longer takes the failure to the call site of `log.i(...)` and no
  longer skips the sinks after it. `Telemetry.isEnabled` treats a sink that cannot answer as one
  that does not want the event.
- A channel action named after the fan-out microtask ran, on a draft held across an `await`, was
  recorded and never fired. The fan-out re-arms, and the second pass reuses the event.
- The two rings of `LogBuffer` merge by sequence and then by timestamp, so hand-built records left
  at the default sequence no longer sort ahead of everything.
- The console sink looks its delegate up rather than calling `putIfAbsent`, which allocated a
  closure per line for a map that holds one entry.
- `wrapForPrint` is `@visibleForTesting`: it was public only because the tests needed it.

### Docs

- The re-entrancy cap covers synchronous re-entry only: an `events` listener or a channel action
  that logs comes back a microtask later, at depth zero, and nothing bounds that.
- The buffer hand-over is synchronous: read `events`, `markDrained`, register the sink, then write.
- `ReportingSink.report` is not throttled; `capture` spends the identity before the vendor call,
  so a call that throws costs one dedupe window.
- A sink removed during a dispatch still receives that event.
- An exporter reads `name`, `meta` and `resource` rather than `attributes`, and writes
  `TraceFlags` as zero. README gains the two-registration snippet for a reporter.

## [0.3.3] - 2026-09-05

### Changed

- **The browser console gets one plain string per level**, the way `package:l` writes it, with the
  level choosing `console.debug`, `info`, `warn` or `error`. 0.3.0 translated the ANSI escapes into
  the console's `%c` styling, which only Chrome DevTools understands: the debug proxy that carries a
  browser console call to an IDE forwards the first argument and drops the rest, so the VS Code
  debug console printed lines like `%c14:39:02%c %cI%c load | ready`. An escape survives that trip
  and is rendered by Chrome's console and by the debug console alike; Firefox and Safari show it as
  text, which is what `printColors: false` is for. `dart:js_interop_unsafe` is no longer used, so
  the console stops attributing every line to the interop patch.

## [0.3.1] - 2026-09-05

A review round against the OpenTelemetry logs spec, the Dart and Flutter sources, and the practice
of `slog`, Serilog, `tracing`, `tint`, `zerolog` and `package:l`. It corrects statements that were
not true, widens the severity range to the one the spec defines, and removes the last place where
the package guessed something only the application knows.

### Changed

- **`printColors` reaches every destination.** The sink used to turn colours off for
  `LogOutput.developer` and for `print` on the web, which is the same guess that 0.3.0 removed for
  terminals: Chrome renders escapes in `console.log`, and nothing here can know what reads the
  `dart:developer` stream. Pair `LogOutput.developer` with `printColors: false`, since the DevTools
  Logging view stores the escapes in the message.
- **`LogLevel.fromValue` reads the whole 1 to 24 range**, four numbers per level, so a row written
  by another exporter or from `LogEvent.severityNumber` comes back as the level it was. It used to
  match the six lower bounds only, and read `TRACE2` as `info`.
- **`LogBuffer.events` returns a `List` snapshot** in every case. It handed out the live queue when
  one ring was empty, so a sink that logged while a journal drained could break the iteration.

### Added

- **`LogEvent.severityNumber`**: the number to store or export. `LogLevel.severityNumber` for every
  level but `trace`, which spends the four numbers of its range on the verbosity tiers, as the spec
  asks of a source with several severities in one range.
- **`LogEvent.site`**: `Area | operation`, the body without the segment a call site writes freely.
  What a breadcrumb or a category wants when the message may carry a user-authored label.
- **`Telemetry.sinks`**: the registered sinks, unmodifiable. Both applications kept their own
  bookkeeping to answer whether the sink they built was still the live one.

### Fixed

- `package:l` is MIT, Copyright (c) 2023 Matiunin Mikhail, not WTFPL. The notice now sits with the
  code carried over, in `lib/src/console/ansi.dart` and `lib/src/zone.dart`.
- `debugPrintThrottled` paces 12K characters per second, not 12 KB.
- `dart:developer`'s `log()` is a no-op under dart2js and dart2wasm alike; they share one patch.
- `ReportingSink` documents two floors, not three.
- `LogEvent.name` said `ReportThrottle` reads a copy edit as a new failure. The throttle is
  per-process memory; what a name does is group lines that say the same thing in different words,
  and pin the crash reporter's fingerprint.
- `error` and `fatal` are no longer documented as "auto-reported": the line is the reporting sink's
  capture floor, which is that level by default.

## [0.3.0] - 2026-09-05

A correction release: 0.2.x got the shape right and several details wrong. Everything here came out
of reviewing it against the OpenTelemetry logs data model, `log/slog`, `tracing`, Serilog and
`Microsoft.Extensions.Logging`, Sentry's structured logs and `package:l`.

### Changed

- **The console line has one colour and two dims.** The level tag is coloured, the time and the
  attribute keys are faint (`ESC[2m`), and the body, the values and the error stay plain. That is
  the layout of `tint`, `zerolog`'s console writer and `charmbracelet/log`. Dim follows colour.
- **`Telemetry.resource` is a field on the record, not a copy in every event's `meta`.**
  OpenTelemetry keeps `Resource` apart from record `Attributes` because it does not vary per
  occurrence. `LogEvent.resource` holds the launch map by reference, `meta` is the scope and the
  call site, and `event.attributes` is the flat projection a sink stores. A console line no longer
  repeats the app version. **A sink that reads `event.meta` directly and expected the launch
  attributes there must read `event.attributes`.**
- **`LogDraft.escalate()` always forwards; the sink decides.** It used to swallow an escalation of
  an event at `error` or above, guessing the reporting sink had captured it. That is
  `ReportingSink.captureLevel`'s decision, and with a higher floor the request reached the reporter
  zero times. `ReportThrottle`, shared by both paths under one identity, makes a second send free
  without spending a per-minute slot.
- **`ReportingSink.enabled` consults both floors.** It gated on `breadcrumbLevel` alone, so
  `captureLevel` could only narrow what the trail admitted and a quiet-trail-loud-capture reporter
  captured nothing. `handle` now applies each floor separately.
- **The unused-draft guard is the analyzer.** Every builder (`meta`, `cause`, `description`, `name`,
  `verbosity`) and `Telemetry.call` are `@useResult`, so a dropped draft is an `unused_result`
  where it is written. The runtime guard is gone: it could not tell a draft held across an `await`
  from a forgotten one, and reported the difference a microtask later, into the pipeline.
- **The body convention is checked at the call site**, synchronously and whatever the level, rather
  than at snapshot. For a channel-only draft that was inside a microtask, and it was skipped
  entirely when nothing consumed the level. `name`, analytics names and trace tiers are checked
  too, and every check is a plain `assert` rather than an `ArgumentError`.
- **A channel that throws is isolated**, reported once to the root zone like a failing sink. A toast
  whose messenger had gone away used to escape as an uncaught error, which the app's own handler
  filed as a defect, and cancel the channels after it.
- **`toast()` resolves its text at the fan-out**, so a description set after it is still the one the
  user sees, and a toast with no text at all falls back to the body with a diagnostic rather than
  asserting from a microtask.
- **`Telemetry.events` is an observer.** A listener no longer makes every level and tier "enabled",
  which had quietly undone `LogBuffer.maxVerbosity` for any app with a debug overlay.
- **`LogBuffer` keeps two rings**, `limit` for `minLevel` and up and the new `traceLimit` (default
  100) for `trace`, merged by `sequence` when read. One `v1` per frame used to evict the boot from a
  shared ring before the journal could drain it. `traceLimit: 0` refuses trace outright, which
  `maxVerbosity` never could.
- **`LogOutput.developer` reaches the browser console on the web**, where `dart:developer`'s `log()`
  is a no-op and every line was being dropped.
- **`printColors` is honoured as written.** 0.2 suppressed colours wherever it guessed the
  destination could not render them, and the guess said no for every Flutter app on a desktop,
  which has no terminal of its own. Now the app decides, the way `package:l` does it; a CLI passes
  `stdout.supportsAnsiEscapes`. Only DevTools and `print` on the web, which store the escapes as
  text, stay plain.
- **Console values are escaped, not just quoted.** A carriage return, a tab, a backslash and every
  other control character are escaped; an ESC in a value can no longer drive the terminal. The body
  and the error text get the same treatment.
- **`print` output wraps at 1000 code units**, never through a surrogate pair. The old 800 cited
  `debugPrintThrottled`, which paces 12K characters per second and does not wrap unless asked; the
  real limit is Android's ~4 KB per call.
- **`removeSink` and `flush` compare by identity**, so two sinks that happen to be equal are still
  two destinations.
- `ReportThrottle` prunes its dedupe map before the ceiling check rather than after, so it prunes
  during the storm it exists to survive; it asserts that one instance measures on one clock.
- The print capture re-enters the zone `print` was called in, so a captured line keeps the scope it
  was printed in.
- A lazy body may return any `Object`, not only a `String`.
- `track`/`notify` copy their payload at the call rather than reading it at the fan-out.
- `Telemetry.clock` may answer in local time: `now()` normalises to UTC.

### Added

- **`TelemetryOptions.levelTag`**: the text that says the level, in its level's colour where the
  destination renders colour. `LevelTag.bracketed` (`[I]`, the default), `.letter` (`I`), `.word`
  (`INFO`), `.glyph` (`💡`), or a map of the app's own.
- **`TelemetryOptions.icon`**: the subsystem's glyph after the level tag. `AreaIcons({'Boot': '🏗',
  ...})` looks it up by area and drops the word it already says: `I 🪢 lifecycle | disposed`. The
  console only: the body a journal and a crash reporter are given is unchanged.
- `kAttributeKey`, `kEventName` and `kTrackName` are exported, so an application's source-scanning
  test can assert the rule the runtime asserts rather than a copy of it that drifts.
- `LogEvent.resource` and `copyWith(resource:)`; `LogEvent.attributes` is computed once and cached.
- `LogBuffer.traceLimit`.
- The browser console shows the colours: `JsConsoleDelegate` turns the escapes into `%c` styling.
- `PrintConsoleDelegate`, `IgnoreConsoleDelegate`, `DeveloperConsoleDelegate`, `wrapForPrint` and
  `kPrintWrapWidth` are exported. The package's own tests had to reach into `src/` for them.
- `make bench`, a compiled micro-benchmark of the hot paths, and the numbers in the README.
- `test/analyzer_guard_test.dart`: runs the analyzer over a fixture to prove `unused_result` fires
  on a dropped builder and not on a closed draft; `dart_test.yaml` declares the `analyzer` tag it
  runs under, and `.pubignore` keeps `tool/` and that fixture out of the published archive.

### Removed

- `LogDraft.sentry()`, deprecated in 0.2.0.
- The runtime unused-draft report and `Telemetry.guardUnused`.

### Fixed

- The disabled fluent path read the clock before the gate.
- The quick path asked every sink twice whether it wanted a level.
- A builder called after the log action was silently ignored; it now asserts, and a second log
  action returns the first event instead of emitting a second one in release.
- `traceContext` was read at snapshot, so a channel-only draft got the trace of a microtask later,
  when the span it belonged to may have ended.
- Every draft allocated a channel list it usually never used.

## [0.2.1] - 2026-09-05

### Changed

- `Telemetry.nextSequence()` is public. A bridge that composes its own `LogEvent` for `emit` could
  not number it, and an event left at the default zero sorts ahead of everything sharing its
  timestamp.

## [0.2.0] - 2026-09-05

### Added

- `Telemetry.scoped(attributes, body)`: zone-carried attributes on every event logged inside it,
  across awaits. `currentTelemetryContext()` reads them; an inner scope wins over an outer one and
  a call site's own `.meta` wins over both.
- `Telemetry.resource`: the attributes that identify the launch (`app.version`,
  `app.environment`), merged under the scope and the call site.
- `LogEvent.name` and `LogDraft.name(...)`: OpenTelemetry's `EventName`, a stable identity
  independent of the body. Surfaced as `event.name` in `attributes`; `ReportThrottle` keys on it
  when it is set.
- `LogEvent.traceId` / `LogEvent.spanId`, filled from `Telemetry.traceContext`.
- `LogEvent.sequence`, a per-launch counter, and `Telemetry.clock`, so a test can pin time.
- `LogEvent.copyWith`, for a bridge that adopts a foreign record.
- `Telemetry.emit(LogEvent)`: the OpenTelemetry bridge API's `Emit`, for a record this pipeline did
  not compose. `Telemetry.dispatch` is gone; it was internal.
- `Flushable` and `Telemetry.flush()`, the SDK's `ForceFlush`. `close()` flushes first.
- `ReportingSink`: the crash-reporting policy: breadcrumb floor, throttled capture of failures,
  escalation as a structured log - with `breadcrumbLevel` and `captureLevel` and three vendor hooks.
- `Telemetry.stackTraceAtLevel`, `package:logging`'s `recordStackTraceAtLevel`.
- `Telemetry.strict`: debug-only checks that an attribute key is OpenTelemetry-named and a body
  carries at least `Area | operation`.
- An attribute value may be an `Object Function()`, resolved once, only if the event is built.
- `LogBuffer.maxVerbosity`, the ceiling on the trace tiers the ring keeps.
- `TelemetryOptions.showMillis`, `developerName`, `copyWith`, and `renders(..., release:)`.
- `ConsoleSink(format:)` with `ConsoleSink.render` as the built-in renderer; `ConsoleSink.options`
  is settable, so a dev menu can raise the floor at runtime.
- `LogLevel` gained `>` and `<=`.
- `currentTelemetryOptions`, `currentTelemetryContext`, `runTelemetryScope` and the zone keys are
  exported; `runTelemetry`'s `onPrint` is optional.
- `make test-web` and `make compile-check` (the example, compiled to JS and to Wasm).

### Changed

- `LogDraft.sentry()` is now `escalate()`; the old name remains as a deprecated alias until 0.3.0.
- A draft that names no channel is reported through the pipeline as `Telemetry | draft | unused` at
  `warn`, in debug builds, instead of throwing an `AssertionError` from a bare microtask - which
  arrived as an uncaught zone error and became a defect-severity line. One microtask per burst
  now, not one per draft.
- Console colours are suppressed where the destination cannot render them (browser console,
  DevTools, `NO_COLOR`, `TERM=dumb`).
- Console attribute values containing whitespace, `=` or a quote are quoted.
- The `print` destination splits output at 800 characters and at every newline, so Android's log
  limits cannot swallow a stack trace.
- Sinks added or removed while an event is being dispatched no longer corrupt the iteration;
  `removeSink` clears the sink's failure mark; dispatch re-entered more than three levels deep
  drops the event and says so once.
- `ReportThrottle` measures on a monotonic clock, so moving the device clock backwards cannot
  suppress reports.
- `LogEvent.attributes` gained `event.name`.

### Fixed

- A draft that named only a channel was stamped with the microtask's time, not the moment the
  action ran.
- The console sink's documented format did not match what it rendered.
- A `trace` whisper above the console's ceiling was still built and still evicted the ring.

## [0.1.0] - 2026-09-04

First release: the `LogEvent` model, the `log` draft with its independent channel actions, the
console sink and its per-platform delegates, the ring buffer, `ReportThrottle` and the telemetry
zone.
