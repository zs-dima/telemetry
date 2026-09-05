import 'package:telemetry/src/level.dart';

/// Writes a rendered line somewhere the developer can see it.
///
/// One implementation per environment, selected by conditional import: a VM
/// terminal, a browser console, `flutter run`.
abstract interface class ConsoleDelegate {
  /// Writes [line], which is already formatted; [level] lets a delegate pick
  /// the right console channel (`console.warn`, `developer.log(level:)`).
  void write(LogLevel level, String line);
}
