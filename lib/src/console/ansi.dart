// ANSI escapes and the per-level palette.
//
// Adapted from `package:l` (https://pub.dev/packages/l).
// MIT, Copyright (c) 2023 Matiunin Mikhail.

import 'package:telemetry/src/level.dart';

/// ANSI Control Sequence Introducer.
const String kEsc = '\x1B[';

/// ANSI reset.
const String kReset = '${kEsc}0m';

/// ANSI faint, for the parts that repeat from line to line: the time, the keys.
const String kDim = '${kEsc}2m';

/// Wraps [text] in faint.
String dim(String text) => '$kDim$text$kReset';

/// Wraps [text] in the ANSI style of [level].
String colorize(LogLevel level, String text) => '${_style(level)}$text$kReset';

String _style(LogLevel level) => switch (level) {
  // Bold red for the two that stop the app, plain red for a failed operation.
  .fatal => '${kEsc}1m${kEsc}31m',
  .error => '${kEsc}31m',
  .warn => '${kEsc}33m',
  .info => '${kEsc}32m',
  .debug => '${kEsc}36m',
  .trace => '${kEsc}90m',
};

/// One browser console call: a format string carrying `%c` markers, and the CSS
/// each marker applies to the rest of the line.
typedef BrowserLine = ({String format, List<String> styles});

/// [line] with its ANSI escapes turned into the browser console's `%c` styling,
/// or null when it carries none.
///
/// A browser ignores ANSI and styles through `%c`: every marker in the first
/// argument applies one CSS declaration from the arguments after it. The colours
/// are mid tones, so they read on a light and a dark console theme alike. A
/// literal `%` in the text is doubled, since the console reads the first
/// argument as a format string once anything follows it.
BrowserLine? browserStyled(String line) {
  if (!line.contains(kEsc)) return null;
  final format = StringBuffer();
  final styles = <String>[];
  var bold = false;
  String? color;
  var index = 0;
  while (index < line.length) {
    final escape = line.indexOf(kEsc, index);
    if (escape < 0) {
      _writeText(format, line, index, line.length);
      break;
    }
    _writeText(format, line, index, escape);
    // Escapes written back to back, such as bold then red, become one marker.
    var cursor = escape;
    while (line.startsWith(kEsc, cursor)) {
      final end = line.indexOf('m', cursor);
      if (end < 0) {
        _writeText(format, line, cursor, line.length);
        return (format: format.toString(), styles: styles);
      }
      // ignore: avoid-substring
      for (final code in line.substring(cursor + kEsc.length, end).split(';')) {
        switch (int.tryParse(code)) {
          case 0:
            bold = false;
            color = null;

          case 1:
            bold = true;

          case final int known when _kBrowserColors.containsKey(known):
            color = _kBrowserColors[known];

          case _:
            break;
        }
      }
      cursor = end + 1;
    }
    format.write('%c');
    styles.add('${color == null ? '' : 'color:$color;'}font-weight:${bold ? 'bold' : 'normal'}');
    index = cursor;
  }
  return (format: format.toString(), styles: styles);
}

/// The SGR codes [colorize] and [dim] write, as CSS colours.
const Map<int, String> _kBrowserColors = <int, String>{
  2: '#9a9a9a',
  31: '#e2504a',
  32: '#3a9e3a',
  33: '#c98a00',
  36: '#2aa198',
  90: '#8a8a8a',
};

void _writeText(StringBuffer buffer, String line, int start, int end) {
  if (start >= end) return;
  // ignore: avoid-substring
  final text = line.substring(start, end);
  buffer.write(text.contains('%') ? text.replaceAll('%', '%%') : text);
}
