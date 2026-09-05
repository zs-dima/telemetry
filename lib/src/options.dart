import 'package:meta/meta.dart';
import 'package:telemetry/src/level.dart';

/// Where the console sink writes.
enum LogOutput {
  /// The platform's own console: `stdout` on the VM (when a terminal is
  /// attached), `window.console` on the web. Keeps browser level filtering
  /// working.
  platform,

  /// `Zone.root.print`: always available, never captured by this package's own
  /// print interceptor.
  print,

  /// `dart:developer` `log()`, which the DevTools Logging view reads.
  developer,

  /// Nothing. Used by tests and by release builds that opt out.
  ignore,
}

/// {@template telemetry_options}
/// Console behaviour for the current zone.
///
/// Zone-scoped rather than global so a test, a background isolate or a nested
/// `runTelemetry` can tighten or silence output without touching the sinks.
/// {@endtemplate}
@immutable
final class TelemetryOptions {
  /// The defaults used when no zone supplies options.
  static const TelemetryOptions defaults = TelemetryOptions();

  /// {@macro telemetry_options}
  const TelemetryOptions({
    this.minLevel = LogLevel.trace,
    this.maxVerbosity = 6,
    this.handlePrint = true,
    this.printColors = true,
    this.outputInRelease = false,
    this.output = LogOutput.platform,
    this.showTime = true,
    this.showMillis = false,
    this.developerName = 'app',
  });

  /// Events below this level are not rendered to the console; other sinks are
  /// unaffected.
  final LogLevel minLevel;

  /// Highest `trace` verbosity tier still rendered; 1 is loud, 6 is a whisper.
  final int maxVerbosity;

  /// Whether `print` inside the telemetry zone becomes an event.
  final bool handlePrint;

  /// ANSI colours, where the destination renders them.
  ///
  /// The sink turns them off by itself for a browser console, for DevTools, and
  /// for a terminal that says it does not want them (`NO_COLOR`, `TERM=dumb`);
  /// this only has to say whether they are wanted at all.
  final bool printColors;

  /// Whether the console sink writes in release builds.
  final bool outputInRelease;

  /// Console destination.
  final LogOutput output;

  /// Whether the rendered line is prefixed with a timestamp.
  final bool showTime;

  /// Whether that timestamp carries milliseconds. Off by default: the extra four
  /// characters are only worth it when ordering inside a second is the question.
  final bool showMillis;

  /// The logger name `dart:developer` shows in the DevTools Logging view.
  ///
  /// Read once, when the `developer` delegate is first built.
  final String developerName;

  /// Whether the console sink should render an event of [level]/[verbosity].
  ///
  /// [maxVerbosity] gates `trace` only: verbosity is the noise dial of tracing,
  /// so a tier set on a warning must not hide the warning. [release] is the
  /// build kind, passed in rather than read from the environment so a test can
  /// pin the release behaviour.
  bool renders(LogLevel level, int verbosity, {bool release = false}) {
    if (release && !outputInRelease) return false;
    return level >= minLevel && (level != .trace || verbosity <= maxVerbosity);
  }

  /// A copy with the given fields replaced.
  TelemetryOptions copyWith({
    LogLevel? minLevel,
    int? maxVerbosity,
    bool? handlePrint,
    bool? printColors,
    bool? outputInRelease,
    LogOutput? output,
    bool? showTime,
    bool? showMillis,
    String? developerName,
  }) => .new(
    minLevel: minLevel ?? this.minLevel,
    maxVerbosity: maxVerbosity ?? this.maxVerbosity,
    handlePrint: handlePrint ?? this.handlePrint,
    printColors: printColors ?? this.printColors,
    outputInRelease: outputInRelease ?? this.outputInRelease,
    output: output ?? this.output,
    showTime: showTime ?? this.showTime,
    showMillis: showMillis ?? this.showMillis,
    developerName: developerName ?? this.developerName,
  );
}
