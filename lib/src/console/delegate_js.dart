import 'dart:js_interop';

import 'package:telemetry/src/console/delegate.dart';
import 'package:telemetry/src/level.dart';

// The console wrapper is an extension type over JSObject, which is itself one:
// that nesting is the js_interop binding pattern.
// ignore_for_file: avoid-nested-extension-types

/// The browser console.
@JS('console')
external _Console get _console;

extension type const _Console._(JSObject _) implements JSObject {
  external void debug(JSAny? arg);
  external void info(JSAny? arg);
  external void warn(JSAny? arg);
  external void error(JSAny? arg);
}

/// {@template js_console_delegate}
/// Writes to the browser console, one method per level.
///
/// The level picks the method, which is what makes the browser's own severity
/// filter and its collapsible stack traces work on these lines.
/// {@endtemplate}
final class JsConsoleDelegate implements ConsoleDelegate {
  /// {@macro js_console_delegate}
  const JsConsoleDelegate();

  @override
  void write(LogLevel level, String line) {
    final arg = line.toJS;
    switch (level) {
      case .trace:
      case .debug:
        _console.debug(arg);

      case .info:
        _console.info(arg);

      case .warn:
        _console.warn(arg);

      case .error:
      case .fatal:
        _console.error(arg);
    }
  }
}

/// The browser-console delegate.
ConsoleDelegate createConsoleDelegate() => const JsConsoleDelegate();

/// Never: a browser console prints an ANSI escape as garbage, and it colours by
/// severity itself.
bool supportsAnsi() => false;
