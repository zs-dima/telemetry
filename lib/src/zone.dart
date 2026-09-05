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
/// The Dart form of `slog.With`, `ILogger.BeginScope` and Serilog's
/// `LogContext`: context set once by the code that knows it.
Map<String, Object?> currentTelemetryContext() => switch (Zone.current[kTelemetryContextKey]) {
  final Map<String, Object?> attributes => attributes,
  _ => const <String, Object?>{},
};

/// Runs [body] with [attributes] added to the ambient scope.
///
/// Merged here rather than walked at every emit: a nested scope costs one map,
/// an event one zone lookup. An inner scope wins over an outer one, and a call
/// site's own `.meta` over both.
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
/// Two mechanics, both carried over from `package:l`
/// (MIT, Copyright (c) 2023 Matiunin Mikhail):
///
/// * the print handler re-enters the zone `print` was called in (`zone.run`)
///   before emitting, so the event carries the options and the ambient scope it
///   belongs to. `self.run`, which `package:l` uses, drops back to the zone that
///   installed this specification and loses any [runTelemetryScope] below it.
/// * when [TelemetryOptions.handlePrint] is off, or no [onPrint] was given, it
///   forwards to `parent.print`. `self.print` would recurse forever (l issue
///   #20).
///
/// The console sink writes through `Zone.root.print`, outside this
/// specification, so rendering an event cannot be captured as a new one.
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
        zone.run<void>(() => capture(line));
      } else {
        parent.print(zone, line);
      }
    },
  ),
);
