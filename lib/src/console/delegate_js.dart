import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:telemetry/src/console/ansi.dart';
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
///
/// ANSI means nothing here, so a styled line is translated into the console's
/// own `%c` styling, which is how a browser colours output.
/// {@endtemplate}
final class JsConsoleDelegate implements ConsoleDelegate {
  /// {@macro js_console_delegate}
  const JsConsoleDelegate();

  @override
  void write(LogLevel level, String line) {
    final method = switch (level) {
      .trace || .debug => 'debug',
      .info => 'info',
      .warn => 'warn',
      .error || .fatal => 'error',
    };
    final styled = browserStyled(line);
    if (styled == null) {
      _plain(method, line);
      return;
    }
    // One argument per `%c` marker, which is more than a typed binding can
    // declare, so the call is made by name.
    _console.callMethodVarArgs(method.toJS, <JSAny?>[
      styled.format.toJS,
      for (final style in styled.styles) style.toJS,
    ]);
  }

  void _plain(String method, String line) {
    final arg = line.toJS;
    switch (method) {
      case 'debug':
        _console.debug(arg);

      case 'info':
        _console.info(arg);

      case 'warn':
        _console.warn(arg);

      case _:
        _console.error(arg);
    }
  }
}

/// The browser-console delegate.
ConsoleDelegate createConsoleDelegate() => const JsConsoleDelegate();
