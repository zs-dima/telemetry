import 'dart:io' as io;

import 'package:telemetry/src/console/delegate.dart';
import 'package:telemetry/src/console/delegate_print.dart';
import 'package:telemetry/src/level.dart';

/// {@template vm_console_delegate}
/// Writes to `stdout` (and `stderr` for failures).
///
/// Only chosen when a terminal is attached: without one, `stdout` is a pipe
/// nobody drains under `flutter run`, and `print` is what reaches the developer.
/// Two streams, because `2>` is how a shell separates a failure from the run.
/// `Stdout` blocks, so the line before a native crash is out before this
/// returns.
/// {@endtemplate}
final class VmConsoleDelegate implements ConsoleDelegate {
  /// {@macro vm_console_delegate}
  const VmConsoleDelegate();

  @override
  void write(LogLevel level, String line) {
    if (level >= .error) {
      io.stderr.writeln(line);
    } else {
      io.stdout.writeln(line);
    }
  }
}

/// A stdout delegate when a terminal is attached, `print` otherwise.
ConsoleDelegate createConsoleDelegate() =>
    io.stdout.hasTerminal ? const VmConsoleDelegate() : const PrintConsoleDelegate();

/// Whether this environment renders ANSI escapes.
bool supportsAnsi() {
  final hasTerminal = io.stdout.hasTerminal;
  return ansiSupport(
    hasTerminal: hasTerminal,
    terminalSupportsAnsi: hasTerminal && io.stdout.supportsAnsiEscapes,
    environment: io.Platform.environment,
    isMobile: io.Platform.isAndroid || io.Platform.isIOS,
  );
}

/// The decision itself, as a function of what was observed.
///
/// Split from [supportsAnsi] so a test can drive every row of the table, which
/// it cannot do with the process itself.
///
/// In order:
///
/// * `NO_COLOR` wins over everything, including an attached terminal;
/// * `FORCE_COLOR` says yes, for a pipe read through a pager that renders
///   escapes;
/// * `TERM=dumb` says no;
/// * with a terminal, the terminal answers for itself;
/// * without one on a phone, the output goes to `flutter run` or the device
///   log, which both render escapes;
/// * without one anywhere else it is a file, a pipe or a CI log, where an
///   escape stays forever.
bool ansiSupport({
  required bool hasTerminal,
  required bool terminalSupportsAnsi,
  required Map<String, String> environment,
  required bool isMobile,
}) {
  if (environment.containsKey('NO_COLOR')) return false;
  if (environment.containsKey('FORCE_COLOR')) return true;
  if (environment['TERM'] == 'dumb') return false;
  if (hasTerminal) return terminalSupportsAnsi;
  return isMobile;
}
