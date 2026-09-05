import 'dart:async';

import 'package:meta/meta.dart';
import 'package:telemetry/src/console/delegate.dart';
import 'package:telemetry/src/level.dart';

/// How long a printed line may be before it is split, in UTF-16 code units.
///
/// Android's logger takes about 4 KB per call and truncates the rest, and what
/// gets truncated in `adb logcat` is the stack trace being chased. A thousand
/// code units stays under 4 KB even at three bytes per character in UTF-8.
///
/// Flutter's `debugPrintThrottled` solves the neighbouring problem, pacing
/// output to 12K characters per second, and wraps only when a caller passes a
/// width. This is the width, not the pace: a console sink should not hold lines
/// back.
const int kPrintWrapWidth = 1000;

/// {@template print_console_delegate}
/// Writes through `Zone.root.print`, one call per line and per
/// [kPrintWrapWidth] code units.
///
/// The print interceptor lives in a child zone, so printing from the root can
/// never be captured and fed back as a new event.
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
/// then one per [kPrintWrapWidth] code units, never through a surrogate pair.
///
/// A function rather than a private step: `Zone.root.print` cannot be
/// intercepted, which is the reason for using it, so this is the test seam.
@visibleForTesting
List<String> wrapForPrint(String line) {
  final pieces = <String>[];
  for (final part in line.split('\n')) {
    if (part.length <= kPrintWrapWidth) {
      pieces.add(part);
      continue;
    }
    var start = 0;
    while (start < part.length) {
      var end = start + kPrintWrapWidth;
      if (end >= part.length) {
        end = part.length;
      } else if (_isHighSurrogate(part.codeUnitAt(end - 1))) {
        // The cut landed between the halves of one character. Split a unit
        // earlier, so no piece carries a lone surrogate the console's UTF-8
        // encoder would turn into U+FFFD.
        end -= 1;
      }
      // ignore: avoid-substring
      pieces.add(part.substring(start, end));
      start = end;
    }
  }
  return pieces;
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

/// Fallback used when no platform library is available.
ConsoleDelegate createConsoleDelegate() => const PrintConsoleDelegate();
