import 'package:telemetry/src/console/ansi.dart';
import 'package:telemetry/src/console/delegate.dart';
import 'package:telemetry/src/console/delegate_developer.dart' as developer_delegate;
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
/// [options] arrives with `printColors` already resolved against what the
/// destination can render, so a formatter only has to read it.
typedef ConsoleFormat = String Function(LogEvent event, TelemetryOptions options);

/// {@template console_sink}
/// Renders events for a human and hands them to the environment's console.
///
/// One line: `HH:MM:SS [I] Area | operation | message key=value key=value`,
/// with the error appended after ` | ` and the stack trace on the lines below it
/// for failures only. One line keeps the output greppable, since a multi-line
/// frame hides the context a filter would otherwise show; a value containing a
/// space, an `=` or a quote is quoted, so the `key=value` pairs stay parseable.
/// {@endtemplate}
final class ConsoleSink implements TelemetrySink {
  /// {@macro console_sink}
  ConsoleSink({TelemetryOptions? options, this.delegate, ConsoleFormat? format})
    : options = options ?? .defaults,
      _format = format ?? render;

  final ConsoleFormat _format;

  /// One delegate per destination, built on first use: `createConsoleDelegate`
  /// probes the environment (`stdout.hasTerminal`) and allocates, which is too
  /// much work to repeat per line.
  final Map<LogOutput, ConsoleDelegate> _delegates = <LogOutput, ConsoleDelegate>{};

  /// Whether each destination renders ANSI. Probed once, for the same reason.
  final Map<LogOutput, bool> _ansi = <LogOutput, bool>{};

  /// Fixed output destination; when null the delegate follows
  /// [TelemetryOptions.output] and the environment. Tests pass their own, and a
  /// delegate given here is trusted to render whatever [TelemetryOptions] asks
  /// for.
  final ConsoleDelegate? delegate;

  /// The options used when no zone supplies any.
  ///
  /// Settable: a dev menu that turns tracing on, or a test that quietens one
  /// suite, has nowhere else to say so. Zone options still win where they exist.
  TelemetryOptions options;

  TelemetryOptions get _options => currentTelemetryOptions() ?? options;

  @override
  bool enabled(LogLevel level, int verbosity) => _options.renders(level, verbosity, release: _kReleaseMode);

  @override
  void handle(LogEvent event) {
    final resolved = _resolveColors(_options);
    _delegateFor(resolved).write(event.level, _format(event, resolved));
  }

  /// The built-in renderer, so a custom [ConsoleFormat] can wrap it rather than
  /// reimplement it.
  static String render(LogEvent event, TelemetryOptions options) {
    final buffer = StringBuffer();
    if (options.showTime) {
      buffer
        ..write(_time(event.timestamp, millis: options.showMillis))
        ..write(' ');
    }
    final prefix = '[${event.level.prefix}]';
    buffer
      ..write(options.printColors ? colorize(event.level, prefix) : prefix)
      ..write(' ')
      ..write(event.body);

    // Attributes stay on the same line, `key=value`, so one grep finds the line
    // and its values.
    for (final MapEntry(:key, :value) in event.meta.entries) {
      buffer
        ..write(' ')
        ..write(key)
        ..write('=');
      _writeValue(buffer, value);
    }

    if (event.error case final Object error) {
      buffer
        ..write(' | ')
        ..write(error);
    }
    // Only failures get the trace: on anything lighter it buries the next line.
    if (event.level >= .error) {
      if (event.stackTrace case final StackTrace trace) {
        buffer
          ..writeln()
          ..write(trace);
      }
    }
    return buffer.toString();
  }

  /// [options] with `printColors` turned off where the destination cannot render
  /// ANSI: a browser console shows the escapes as garbage, DevTools stores them
  /// in the message, and a CI log keeps them forever.
  TelemetryOptions _resolveColors(TelemetryOptions options) {
    if (!options.printColors) return options;
    if (delegate != null) return options;
    final ansi = _ansi.putIfAbsent(
      options.output,
      () => switch (options.output) {
        .platform => platform_delegate.supportsAnsi(),
        .print => print_delegate.supportsAnsi(),
        .developer || .ignore => false,
      },
    );
    return ansi ? options : options.copyWith(printColors: false);
  }

  ConsoleDelegate _delegateFor(TelemetryOptions options) =>
      delegate ??
      _delegates.putIfAbsent(
        options.output,
        () => switch (options.output) {
          .platform => platform_delegate.createConsoleDelegate(),
          .print => print_delegate.createConsoleDelegate(),
          // The name is read once, from the options in force when DevTools
          // output is first used.
          .developer => developer_delegate.createConsoleDelegate(name: options.developerName),
          .ignore => ignore_delegate.createConsoleDelegate(),
        },
      );

  /// Local time: a console line is read against the developer's own wall clock.
  /// Everything that leaves the device carries [LogEvent.timestamp], in UTC.
  static String _time(DateTime utc, {required bool millis}) {
    final local = utc.toLocal();
    String pad(int value) => value.toString().padLeft(2, '0');
    final clock = '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
    return millis ? '$clock.${local.millisecond.toString().padLeft(3, '0')}' : clock;
  }

  /// Writes [value] as a logfmt field: bare when it is one word, quoted when a
  /// space, an `=` or a quote would otherwise break the pair apart.
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
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      // A quote or a backslash is escaped; a newline would end the line early.
      if (unit == 0x22 || unit == 0x5C) buffer.writeCharCode(0x5C);
      if (unit == 0x0A) {
        buffer.write(r'\n');
        continue;
      }
      buffer.writeCharCode(unit);
    }
    buffer.write('"');
  }

  static bool _needsQuotes(String text) {
    if (text.isEmpty) return true;
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      // space, ", =, newline, tab
      if (unit == 0x20 || unit == 0x22 || unit == 0x3D || unit == 0x0A || unit == 0x09) return true;
    }
    return false;
  }
}
