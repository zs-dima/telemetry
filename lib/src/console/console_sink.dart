import 'package:telemetry/src/body.dart';
import 'package:telemetry/src/console/ansi.dart';
import 'package:telemetry/src/console/delegate.dart';
import 'package:telemetry/src/console/delegate_developer.dart'
    if (dart.library.js_interop) 'package:telemetry/src/console/delegate_developer_js.dart'
    as developer_delegate;
import 'package:telemetry/src/console/delegate_fallback.dart'
    if (dart.library.io) 'package:telemetry/src/console/delegate_vm.dart'
    if (dart.library.js_interop) 'package:telemetry/src/console/delegate_js.dart'
    as platform_delegate;
import 'package:telemetry/src/console/delegate_ignore.dart' as ignore_delegate;
import 'package:telemetry/src/console/delegate_print.dart' as print_delegate;
import 'package:telemetry/src/event.dart';
import 'package:telemetry/src/level.dart';
import 'package:telemetry/src/options.dart';
import 'package:telemetry/src/sink.dart';
import 'package:telemetry/src/zone.dart';

// ignore: do_not_use_environment, release detection without a Flutter import.
const bool _kReleaseMode = bool.fromEnvironment('dart.vm.product');

/// Renders [event] as the line a console shows.
///
/// [options] are the ones in force, zone overrides included.
typedef ConsoleFormat = String Function(LogEvent event, TelemetryOptions options);

/// {@template console_sink}
/// Renders events for a human and hands them to the environment's console.
///
/// One line: `HH:MM:SS [I] Area | operation | message key=value key=value`,
/// with the error after ` | ` and the stack trace below it for failures only.
/// One line stays greppable, where a multi-line frame hides the context a
/// filter would show.
///
/// [TelemetryOptions.levelTag] is the text that says the level, `[I]`, `I`,
/// `INFO` or a glyph, in the level's colour where the destination renders
/// colour, with the time and the keys dimmed. [TelemetryOptions.icon] adds a
/// subsystem glyph after the tag and drops the word for the area. Neither
/// touches the body a crash reporter groups on.
///
/// The attributes rendered are [LogEvent.meta] and `event.name`. The launch's
/// [LogEvent.resource] is left out, since a line should carry what varied. A
/// value containing a space, a quote, an `=` or a control character is quoted
/// and escaped, so the pairs stay machine-readable and a value cannot drive the
/// terminal it is printed to.
/// {@endtemplate}
final class ConsoleSink implements TelemetrySink {
  /// {@macro console_sink}
  ConsoleSink({TelemetryOptions? options, this.delegate, ConsoleFormat? format})
    : options = options ?? .defaults,
      _format = format ?? render;

  final ConsoleFormat _format;

  /// One delegate per destination, built on first use: `createConsoleDelegate`
  /// probes `stdout.hasTerminal` and allocates, which is too much per line.
  /// Keyed by the name too, so a zone that renames the DevTools logger gets its
  /// own delegate.
  final Map<(LogOutput, String), ConsoleDelegate> _delegates = <(LogOutput, String), ConsoleDelegate>{};

  /// Fixed output destination; when null the delegate follows
  /// [TelemetryOptions.output] and the platform.
  final ConsoleDelegate? delegate;

  /// The options used when no zone supplies any.
  ///
  /// Settable for a dev menu that turns tracing on, or a test that quietens one
  /// suite. Zone options still win where they exist.
  TelemetryOptions options;

  TelemetryOptions get _options => currentTelemetryOptions() ?? options;

  @override
  bool enabled(LogLevel level, int verbosity) => _options.renders(level, verbosity, release: _kReleaseMode);

  @override
  void handle(LogEvent event) {
    final current = _options;
    _delegateFor(current).write(event.level, _format(event, current));
  }

  /// The built-in renderer, so a custom [ConsoleFormat] can wrap it rather than
  /// reimplement it.
  static String render(LogEvent event, TelemetryOptions options) {
    final buffer = StringBuffer();
    final colors = options.printColors;
    if (options.showTime) {
      final clock = _time(event.timestamp, millis: options.showMillis);
      buffer
        ..write(colors ? dim(clock) : clock)
        ..write(' ');
    }
    // The tag says the level and carries the only colour on the line. The
    // subsystem glyph follows it: neither can stand in for the other.
    final tag = options.levelTag.of(event.level);
    buffer
      ..write(colors ? colorize(event.level, tag) : tag)
      ..write(' ');
    final glyph = options.icon?.of(event);
    if (glyph != null) {
      buffer
        ..write(glyph.glyph)
        ..write(' ');
    }
    // A bridged line or a captured `print` can carry a newline, and one event
    // has to stay one line. The area word is dropped when a glyph says it.
    _writeBare(buffer, glyph != null && !glyph.keepsArea ? bodyWithoutArea(event.body) : event.body);

    // Attributes stay on the line as `key=value`, so one grep finds the line and
    // its values. `event.name` leads, being the identity the rest describes.
    if (event.name case final String name) {
      _writeKey(buffer, 'event.name', colors: colors);
      _writeValue(buffer, name);
    }
    for (final MapEntry(:key, :value) in event.meta.entries) {
      _writeKey(buffer, key, colors: colors);
      _writeValue(buffer, value);
    }

    if (event.error case final Object error) {
      buffer.write(' | ');
      _writeBare(buffer, error.toString());
    }
    // Only failures get the trace, and it is the one part allowed to be
    // multi-line: folded into one line it is unreadable.
    if (event.level >= .error) {
      if (event.stackTrace case final StackTrace trace) {
        buffer
          ..writeln()
          ..write(trace);
      }
    }
    return buffer.toString();
  }

  ConsoleDelegate _delegateFor(TelemetryOptions options) {
    final fixed = delegate;
    if (fixed != null) return fixed;
    final key = (options.output, options.developerName);
    // Looked up rather than `putIfAbsent`, which allocates its closure on every
    // line for a map that holds one entry after the first.
    final cached = _delegates[key];
    if (cached != null) return cached;
    return _delegates[key] = switch (options.output) {
      .platform => platform_delegate.createConsoleDelegate(),
      .print => print_delegate.createConsoleDelegate(),
      .developer => developer_delegate.createConsoleDelegate(name: options.developerName),
      .ignore => ignore_delegate.createConsoleDelegate(),
    };
  }

  /// Local time, since a console line is read against the developer's own
  /// clock. What leaves the device carries [LogEvent.timestamp], in UTC.
  static String _time(DateTime utc, {required bool millis}) {
    final local = utc.toLocal();
    String pad(int value) => value.toString().padLeft(2, '0');
    final clock = '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
    return millis ? '$clock.${local.millisecond.toString().padLeft(3, '0')}' : clock;
  }

  /// Writes ` key=`, dimmed when [colors] is on: keys repeat from line to line,
  /// values do not.
  static void _writeKey(StringBuffer buffer, String key, {required bool colors}) {
    buffer.write(' ');
    if (colors) buffer.write(kDim);
    buffer
      ..write(key)
      ..write('=');
    if (colors) buffer.write(kReset);
  }

  /// Writes [value] as a logfmt field: bare when it is one plain word, quoted
  /// when a space, a quote, an `=` or a control character would otherwise break
  /// the pair apart.
  static void _writeValue(StringBuffer buffer, Object? value) {
    if (value == null) {
      buffer.write('null');
      return;
    }
    final text = value.toString();
    if (!_needsQuotes(text)) {
      buffer.write(text);
      return;
    }
    buffer.write('"');
    _escapeInto(buffer, text, quoted: true);
    buffer.write('"');
  }

  /// Writes free text, the body or an error message, escaping only what would
  /// break the line. Quotes and spaces are prose here and stay as they are.
  static void _writeBare(StringBuffer buffer, String text) => _escapeInto(buffer, text, quoted: false);

  /// Copies [text] into [buffer], escaping what has to be escaped and writing
  /// everything else in runs. Most values need nothing and cost one `write`.
  static void _escapeInto(StringBuffer buffer, String text, {required bool quoted}) {
    var start = 0;
    for (var index = 0; index < text.length; index++) {
      final escape = _escapeFor(text.codeUnitAt(index), quoted: quoted);
      if (escape == null) continue;
      // ignore: avoid-substring
      if (index > start) buffer.write(text.substring(start, index));
      buffer.write(escape);
      start = index + 1;
    }
    if (start == 0) {
      buffer.write(text);
      return;
    }
    // ignore: avoid-substring
    if (start < text.length) buffer.write(text.substring(start));
  }

  /// The escape for [unit], or null when it may be written as it is.
  static String? _escapeFor(int unit, {required bool quoted}) => switch (unit) {
    0x22 when quoted => r'\"',
    0x5C when quoted => r'\\',
    0x0A => r'\n',
    0x0D => r'\r',
    0x09 => r'\t',
    // Every other C0 control and DEL. An ESC in a value would otherwise drive
    // the terminal, from data the app did not write.
    _ when unit < 0x20 || unit == 0x7F => '\\u${unit.toRadixString(16).padLeft(4, '0')}',
    _ => null,
  };

  static bool _needsQuotes(String text) {
    if (text.isEmpty) return true;
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      // space, ", =, and any control character
      if (unit == 0x20 || unit == 0x22 || unit == 0x3D || unit < 0x20 || unit == 0x7F) return true;
    }
    return false;
  }
}
