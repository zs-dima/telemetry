import 'dart:async';

import 'package:telemetry/src/console/delegate.dart';
import 'package:telemetry/src/level.dart';

/// How long a printed line may be before it is split.
///
/// Android's logger rate-limits and drops output, which is why Flutter's own
/// `debugPrintThrottled` wraps at this width. A release build with the console
/// on is read through `adb logcat`, and the line that gets dropped there is the
/// stack trace of the failure being chased.
const int kPrintWrapWidth = 800;

/// {@template print_console_delegate}
/// Writes through `Zone.root.print`, one call per line and per
/// [kPrintWrapWidth] characters.
///
/// The root zone: the print interceptor lives in a child zone, so printing from
/// here can never be captured and fed back as a new event.
/// {@endtemplate}
final class PrintConsoleDelegate implements ConsoleDelegate {
  /// {@macro print_console_delegate}
  const PrintConsoleDelegate();

  @override
  void write(LogLevel level, String line) {
    if (line.length <= kPrintWrapWidth && !line.contains('\n')) {
      Zone.root.print(line);
      return;
    }
    for (final piece in wrapForPrint(line)) {
      Zone.root.print(piece);
    }
  }
}

/// Splits [line] into the pieces one `print` call may carry: one per newline,
/// then one per [kPrintWrapWidth] characters.
///
/// A function rather than a private step, because `Zone.root.print` cannot be
/// intercepted — that is the whole reason for using it — so this is the seam a
/// test can hold.
List<String> wrapForPrint(String line) {
  final pieces = <String>[];
  for (final part in line.split('\n')) {
    if (part.length <= kPrintWrapWidth) {
      pieces.add(part);
      continue;
    }
    for (var start = 0; start < part.length; start += kPrintWrapWidth) {
      final end = start + kPrintWrapWidth;
      // ignore: avoid-substring
      pieces.add(part.substring(start, end < part.length ? end : part.length));
    }
  }
  return pieces;
}

/// Fallback used when no platform library is available.
ConsoleDelegate createConsoleDelegate() => const PrintConsoleDelegate();

/// `print` reaches a terminal or `flutter run`, both of which render ANSI.
bool supportsAnsi() => true;
