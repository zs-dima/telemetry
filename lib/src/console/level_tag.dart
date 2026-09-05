import 'package:meta/meta.dart';
import 'package:telemetry/src/level.dart';

/// {@template level_tag}
/// The text that stands for the level on a console line, per level.
///
/// One token after the time, coloured where the destination renders colour: red
/// for `error`, yellow for `warn`, green for `info`.
///
/// * [bracketed], `[I]`: the default, and what a log without colour greps best.
/// * [letter], `I`: the bare letter, once colour says the level.
/// * [word], `INFO`: what `tracing`, `slog` and `charmbracelet/log` print,
///   padded to five so the body starts in one column.
/// * [glyph], `💡`: the level as an emoji, as `package:logger` shows it.
///
/// A set of the app's own is a map, `LevelTag({LogLevel.info: 'ℹ', ...})`, and a
/// level it leaves out falls back to `[I]`. Keep one set's texts one width,
/// since the body starts after them.
/// {@endtemplate}
@immutable
final class LevelTag {
  /// `[T] [D] [I] [W] [E] [F]`.
  static const LevelTag bracketed = LevelTag(<LogLevel, String>{
    .trace: '[T]',
    .debug: '[D]',
    .info: '[I]',
    .warn: '[W]',
    .error: '[E]',
    .fatal: '[F]',
  });

  /// `T D I W E F`.
  static const LevelTag letter = LevelTag(<LogLevel, String>{
    .trace: 'T',
    .debug: 'D',
    .info: 'I',
    .warn: 'W',
    .error: 'E',
    .fatal: 'F',
  });

  /// `TRACE DEBUG INFO WARN ERROR FATAL`, each five wide.
  static const LevelTag word = LevelTag(<LogLevel, String>{
    .trace: 'TRACE',
    .debug: 'DEBUG',
    .info: 'INFO ',
    .warn: 'WARN ',
    .error: 'ERROR',
    .fatal: 'FATAL',
  });

  /// `🔍 🐞 💡 ⚠️ 🚫 ❗`.
  static const LevelTag glyph = LevelTag(<LogLevel, String>{
    .trace: '🔍',
    .debug: '🐞',
    .info: '💡',
    .warn: '⚠️',
    .error: '🚫',
    .fatal: '❗',
  });

  /// {@macro level_tag}
  const LevelTag(this.byLevel);

  /// The text per level.
  final Map<LogLevel, String> byLevel;

  /// The text for [level].
  String of(LogLevel level) => byLevel[level] ?? '[${level.prefix}]';
}
