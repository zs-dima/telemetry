import 'package:meta/meta.dart';
import 'package:telemetry/src/console/icons.dart';
import 'package:telemetry/src/console/level_tag.dart';
import 'package:telemetry/src/level.dart';

/// Where the console sink writes.
enum LogOutput {
  /// The platform's own console: `stdout` on the VM when a terminal is attached,
  /// `window.console` on the web, where level filtering keeps working.
  platform,

  /// `Zone.root.print`: always available, never captured by this package's own
  /// print interceptor.
  print,

  /// `dart:developer` `log()`, which the DevTools Logging view reads.
  ///
  /// On the web that function is a no-op, since dart2js and dart2wasm share a
  /// patch with an empty body, so the console sink sends this to the browser
  /// console instead.
  developer,

  /// Nothing. Used by tests and by release builds that opt out.
  ignore,
}

/// {@template telemetry_options}
/// Console behaviour for the current zone.
///
/// Zone-scoped rather than global, so a test or a nested `runTelemetry` can
/// tighten or silence output without touching the sinks.
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
    this.levelTag = LevelTag.bracketed,
    this.icon,
  });

  /// Events below this level are not rendered to the console; other sinks are
  /// unaffected.
  final LogLevel minLevel;

  /// Highest `trace` verbosity tier still rendered; 1 is loud, 6 is a whisper.
  final int maxVerbosity;

  /// Whether `print` inside the telemetry zone becomes an event.
  final bool handlePrint;

  /// ANSI colours: the level tag in its level's colour, the time and the
  /// attribute keys dimmed, nothing else.
  ///
  /// Honoured as written, on every destination, the way `package:l` does it.
  /// A Flutter app has no terminal of its own, so no probe can answer for it.
  /// Say true where what reads the output renders escapes: a terminal, Chrome's
  /// console, the VS Code debug console. Say false where it shows them as text:
  /// the DevTools Logging view, and a browser console read in Firefox or
  /// Safari. A CLI that may be redirected passes `stdout.supportsAnsiEscapes`.
  final bool printColors;

  /// Whether the console sink writes in release builds.
  ///
  /// Release means `dart.vm.product`, which Flutter and `dart compile` define in
  /// release. A plain `dart run` never does, so a pure-Dart binary counts as a
  /// debug build here and writes regardless.
  final bool outputInRelease;

  /// Console destination.
  final LogOutput output;

  /// Whether the rendered line is prefixed with a timestamp.
  final bool showTime;

  /// Whether that timestamp carries milliseconds. Off by default; worth it when
  /// ordering inside one second is the question.
  final bool showMillis;

  /// The text that says the level: `[I]` by default, `LevelTag.letter` for the
  /// bare `I` where colour carries the level, `LevelTag.word` for `INFO`,
  /// `LevelTag.glyph` for `💡`, or a map of the app's own.
  final LevelTag levelTag;

  /// A glyph for the subsystem after the level tag: `const AreaIcons({...})`,
  /// one per area, with the word for the area dropped since the glyph says it.
  /// Null adds nothing.
  ///
  /// The console only: the journal, the crash reporter and the breadcrumb trail
  /// are given [LogEvent.body], which stays `Area | operation | message`. A
  /// glyph in the body would reach all three and take the place of the area.
  final ConsoleIcon? icon;

  /// The logger name `dart:developer` shows in the DevTools Logging view.
  ///
  /// Part of the key the sink caches delegates under, so a zone that renames the
  /// logger gets its own.
  final String developerName;

  /// Whether the console sink should render an event of [level]/[verbosity].
  ///
  /// [maxVerbosity] gates `trace` only, so a tier set on a warning cannot hide
  /// the warning. [release] is passed in rather than read from the environment,
  /// so a test can pin it.
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
    LevelTag? levelTag,
    ConsoleIcon? icon,
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
    levelTag: levelTag ?? this.levelTag,
    icon: icon ?? this.icon,
  );
}
