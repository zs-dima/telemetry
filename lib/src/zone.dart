import 'dart:async';

import 'package:telemetry/src/options.dart';

/// Zone key under which [TelemetryOptions] travel.
const Symbol kTelemetryOptionsKey = #telemetry.options;

/// Zone key under which the ambient attributes travel.
const Symbol kTelemetryContextKey = #telemetry.context;

/// The options in force for the current zone, if any.
TelemetryOptions? currentTelemetryOptions() => switch (Zone.current[kTelemetryOptionsKey]) {
  final TelemetryOptions options => options,
  _ => null,
};

/// The attributes every event logged in the current zone carries; empty outside
/// any scope.
///
/// The Dart form of `slog.With`, `ILogger.BeginScope`, Serilog's `LogContext`
/// and pino's `child`: context set once by the code that knows it, rather than
/// repeated at every call site under it.
Map<String, Object?> currentTelemetryContext() => switch (Zone.current[kTelemetryContextKey]) {
  final Map<String, Object?> attributes => attributes,
  _ => const <String, Object?>{},
};

/// Runs [body] with [attributes] added to the ambient scope.
///
/// Merged once, here, rather than walked at every emit: a nested scope costs one
/// map and an event costs one zone lookup. A key set by an inner scope wins over
/// the same key outside it, and a call site's own `.meta` wins over both.
R runTelemetryScope<R>(Map<String, Object?> attributes, R Function() body) {
  if (attributes.isEmpty) return body();
  final merged = <String, Object?>{...currentTelemetryContext(), ...attributes};
  return runZoned<R>(
    body,
    zoneValues: <Symbol, Object?>{kTelemetryContextKey: Map<String, Object?>.unmodifiable(merged)},
  );
}

/// Runs [body] with [options] in force and, when [onPrint] is given, every
/// `print` inside it turned into an event.
///
/// Two mechanics, both carried over from `package:l` (WTFPL, Plague Fox):
///
/// * the print handler re-enters the same zone (`self.run`) before emitting, so
///   the event is produced under the options it belongs to;
/// * when [TelemetryOptions.handlePrint] is off, or no [onPrint] was given, it
///   forwards to `parent.print` rather than `self.print`, which would recurse
///   forever (l issue #20).
///
/// The console sink writes through `Zone.root.print`, outside this
/// specification, so rendering an event can never be captured as a new one.
R runTelemetry<R>(
  R Function() body, {
  TelemetryOptions options = .defaults,
  void Function(String line)? onPrint,
}) => runZoned<R>(
  body,
  zoneValues: <Symbol, Object?>{kTelemetryOptionsKey: options},
  zoneSpecification: ZoneSpecification(
    print: (self, parent, zone, line) {
      final capture = onPrint;
      if (capture != null && (currentTelemetryOptions()?.handlePrint ?? options.handlePrint)) {
        self.run<void>(() => capture(line));
      } else {
        parent.print(zone, line);
      }
    },
  ),
);
