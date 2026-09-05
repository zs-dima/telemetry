import 'dart:io' as io;

import 'package:telemetry/src/console/delegate.dart';
import 'package:telemetry/src/console/delegate_print.dart';
import 'package:telemetry/src/level.dart';

/// {@template vm_console_delegate}
/// Writes to `stdout` (and `stderr` for failures).
///
/// Only chosen when a terminal is attached: without one, `stdout` is a pipe
/// nobody drains under `flutter run`, and `print` is what reaches the developer.
/// Two streams rather than one, because a terminal writes both unbuffered and
/// interleaves them correctly, and `2>` is how a shell separates a failure from
/// the run.
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
///
/// A terminal answers for itself. Without one the output is `flutter run`, which
/// does render them — unless the environment says otherwise: `NO_COLOR` is the
/// cross-tool opt-out and `TERM=dumb` is the ancient one, and a CI log is
/// usually one of the two.
bool supportsAnsi() {
  if (io.stdout.hasTerminal) return io.stdout.supportsAnsiEscapes;
  final environment = io.Platform.environment;
  return !environment.containsKey('NO_COLOR') && environment['TERM'] != 'dumb';
}
