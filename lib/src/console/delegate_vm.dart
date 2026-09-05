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
