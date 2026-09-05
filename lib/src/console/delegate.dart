import 'package:telemetry/src/level.dart';

/// Writes a rendered line somewhere the developer can see it.
///
/// One implementation per environment, selected by conditional import, so output
/// behaves correctly on a VM terminal, in a browser console and under
/// `flutter run` alike.
abstract interface class ConsoleDelegate {
  /// Writes [line], which is already formatted; [level] lets a delegate pick
  /// the right console channel (`console.warn`, `developer.log(level:)`).
  void write(LogLevel level, String line);
}
