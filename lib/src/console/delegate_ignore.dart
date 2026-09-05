import 'package:telemetry/src/console/delegate.dart';
import 'package:telemetry/src/level.dart';

/// {@template ignore_console_delegate}
/// Drops every line. Used by tests and by release builds that opt out of
/// console output.
/// {@endtemplate}
final class IgnoreConsoleDelegate implements ConsoleDelegate {
  /// {@macro ignore_console_delegate}
  const IgnoreConsoleDelegate();

  @override
  void write(LogLevel level, String line) {
    // Intentionally nothing.
  }
}

/// The no-op delegate.
ConsoleDelegate createConsoleDelegate() => const IgnoreConsoleDelegate();
