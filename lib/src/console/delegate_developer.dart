import 'dart:developer' as developer;

import 'package:telemetry/src/console/delegate.dart';
import 'package:telemetry/src/level.dart';

/// {@template developer_console_delegate}
/// Writes through `dart:developer`'s `log()`.
///
/// The DevTools Logging view reads this, and its `level:` is the
/// `package:logging` 0-2000 scale that [LogLevel.developerLevel] holds, so no
/// translation table is needed.
/// {@endtemplate}
final class DeveloperConsoleDelegate implements ConsoleDelegate {
  /// {@macro developer_console_delegate}
  const DeveloperConsoleDelegate({this.name = 'app'});

  /// The logger name shown in DevTools.
  final String name;

  @override
  void write(LogLevel level, String line) => developer.log(line, level: level.developerLevel, name: name);
}

/// The `dart:developer` delegate, named [name] in DevTools.
ConsoleDelegate createConsoleDelegate({String name = 'app'}) => DeveloperConsoleDelegate(name: name);
