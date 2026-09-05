// ANSI escapes and the per-level palette.
//
// Adapted from `package:l` by Plague Fox (WTFPL, https://pub.dev/packages/l).

import 'package:telemetry/src/level.dart';

/// ANSI Control Sequence Introducer.
const String kEsc = '\x1B[';

/// ANSI reset.
const String kReset = '${kEsc}0m';

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
