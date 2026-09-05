# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
