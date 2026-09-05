import 'package:meta/meta.dart';
import 'package:telemetry/src/event.dart';

/// {@template console_glyph}
/// What a scheme adds to a console line: a glyph for the subsystem after the
/// level tag, and whether the word for the area is still written.
/// {@endtemplate}
///
/// The tag says the level and the glyph says which part of the app is talking,
/// so neither can stand in for the other. With [keepsArea] false the word goes,
/// since the glyph now says it: `[I] 🪢 lifecycle | disposed`. With it true the
/// line reads `[I] 🪢 Control | lifecycle | disposed`.
@immutable
final class ConsoleGlyph {
  /// {@macro console_glyph}
  const ConsoleGlyph(this.glyph, {this.keepsArea = false});

  /// The characters to print, usually one emoji.
  final String glyph;

  /// Whether the `Area | ` segment of the body is still written.
  final bool keepsArea;
}

/// A glyph for the subsystem on a console line, after the level tag.
///
/// A console choice only: the journal, the crash reporter and the breadcrumb
/// trail never see it, and the body stays `Area | operation | message`.
/// `charmbracelet/log` calls this a prefix; here it is looked up per event, so
/// one map covers an app.
///
/// An interface rather than a function, so a scheme fits in a
/// `const TelemetryOptions(...)`: `const AreaIcons({...})`, or a class of the
/// app's own that reads `event.name` or a meta key instead.
///
/// Most terminals draw an emoji two columns wide and some fonts draw a few one
/// wide, so pick glyphs of one width. The forms with a variation selector
/// (`⚠️`, `⚙️`) align better than the bare ones.
abstract interface class ConsoleIcon {
  /// The glyph for [event], or null to add nothing to its line.
  ConsoleGlyph? of(LogEvent event);
}

/// {@template area_icons}
/// One glyph per subsystem, the first segment of the body, after the level
/// tag, with the word for the area dropped since the glyph says it:
///
/// ```
/// [I] 🏗 init | first launch
/// [I] 🌍 call | ok rpc.path=/auth.v1/SignIn
/// [E] 🪢 handler | failed control.controller=PairingController | Bad state: …
/// ```
///
/// An area that is not in the map gets no glyph and keeps its word, so a line
/// always carries its subsystem. `replacesArea: false` keeps the word on every
/// line, which a log grepped by area wants.
/// {@endtemplate}
final class AreaIcons implements ConsoleIcon {
  /// {@macro area_icons}
  const AreaIcons(this.byArea, {this.replacesArea = true});

  /// The glyph for each area, keyed by the first `|`-separated segment of the
  /// body, trimmed: `{'Boot': '🏗', 'Rpc': '🌍'}`.
  final Map<String, String> byArea;

  /// Whether a glyph from [byArea] stands in for the word, so the console drops
  /// `Area | ` from the line.
  final bool replacesArea;

  @override
  ConsoleGlyph? of(LogEvent event) {
    final glyph = byArea[event.area];
    if (glyph == null) return null;
    return ConsoleGlyph(glyph, keepsArea: !replacesArea);
  }
}
