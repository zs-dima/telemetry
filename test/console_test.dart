import 'package:telemetry/src/console/ansi.dart';
import 'package:telemetry/src/console/delegate_vm.dart' as vm_delegate;
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

/// Keeps the lines a delegate was handed.
final class _Recording implements ConsoleDelegate {
  const _Recording(this.lines);
  final List<String> lines;

  @override
  void write(LogLevel level, String line) => lines.add(line);
}

/// The instant every rendered line in this suite is stamped with.
final DateTime _at = DateTime.utc(2026, 9, 5, 14, 3, 7, 42);

LogEvent _event({
  LogLevel level = .info,
  Map<String, Object?> meta = const <String, Object?>{},
  Map<String, Object?> resource = const <String, Object?>{},
  String? name,
}) => .new(
  level: level,
  body: 'Rpc | call | ok',
  name: name,
  meta: meta,
  resource: resource,
  timestamp: _at,
  runId: 'run',
);

void main() {
  group('rendering', () {
    const plain = TelemetryOptions(printColors: false, showTime: false);

    test('quotes a value only when a bare one would break the pair apart', () {
      final line = ConsoleSink.render(
        _event(
          meta: const <String, Object?>{
            'rpc.path': '/auth.v1/SignIn',
            'app.settings.value': 'dark mode',
            'db.query': 'a=b',
            'log.message': 'say "hi"',
            'app.route': null,
            'app.note': '',
          },
        ),
        plain,
      );

      expect(
        line,
        equals(
          '[I] Rpc | call | ok rpc.path=/auth.v1/SignIn app.settings.value="dark mode" '
          r'db.query="a=b" log.message="say \"hi\"" app.route=null app.note=""',
        ),
      );
    });

    test('a backslash is escaped whenever the value is quoted', () {
      expect(
        ConsoleSink.render(_event(meta: const <String, Object?>{'db.path': r'C:\Program Files\app'}), plain),
        equals(r'[I] Rpc | call | ok db.path="C:\\Program Files\\app"'),
      );
    });

    test('every character that would break the line is escaped', () {
      final line = ConsoleSink.render(
        _event(
          meta: const <String, Object?>{
            'log.newline': 'first\nsecond',
            // Unescaped, a carriage return overwrites the start of the line
            // that is being read.
            'log.carriage': 'first\rsecond',
            'log.tab': 'a\tb',
            // An escape sequence in a value would otherwise drive the
            // terminal it is printed to.
            'log.escape': '\u001b[2Jcleared',
          },
        ),
        plain,
      );

      expect(
        line,
        equals(
          r'[I] Rpc | call | ok log.newline="first\nsecond" log.carriage="first\rsecond" '
          r'log.tab="a\tb" log.escape="\u001b[2Jcleared"',
        ),
      );
      expect(line.contains('\n'), isFalse, reason: 'one event is one greppable line');
      expect(line.contains('\r'), isFalse);
      expect(line.contains('\u001b'), isFalse, reason: 'nothing in a value may reach the terminal as a command');
    });

    test('the body and the error text are sanitised too, and the stack trace is not', () {
      // A bridged body or a captured `print` can carry a newline, and an
      // exception's message is not composed by the app.
      final line = ConsoleSink.render(
        LogEvent(
          level: .error,
          body: 'Bridge | forwarded | first\nsecond',
          error: const FormatException('bad\rinput'),
          stackTrace: StackTrace.fromString('#0 one\n#1 two'),
          timestamp: _at,
          runId: 'run',
        ),
        plain,
      );

      expect(line, startsWith(r'[E] Bridge | forwarded | first\nsecond | FormatException: bad\rinput'));
      expect(line, endsWith('\n#0 one\n#1 two'), reason: 'only the trace may be multi-line');
    });

    test('the event name leads the attributes and the launch resource is absent', () {
      expect(
        ConsoleSink.render(
          _event(
            name: 'sync.upload.refused',
            meta: const <String, Object?>{'http.status_code': 429},
            resource: const <String, Object?>{'app.version': '1.0.0'},
          ),
          plain,
        ),
        equals('[I] Rpc | call | ok event.name=sync.upload.refused http.status_code=429'),
      );
    });

    test('the time is local, and milliseconds are opt-in', () {
      final local = _at.toLocal();
      String pad(int value) => value.toString().padLeft(2, '0');
      final clock = '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';

      expect(ConsoleSink.render(_event(), const TelemetryOptions(printColors: false)), startsWith('$clock [I]'));
      expect(
        ConsoleSink.render(_event(), const TelemetryOptions(printColors: false, showMillis: true)),
        startsWith('$clock.042 [I]'),
      );
    });

    test('colour is the tag, dim is the time and the keys, and nothing else', () {
      // The layout of `tint`, `zerolog` and `charmbracelet/log`: the level's
      // colour on the tag, the parts that repeat faint, the body and the values
      // bare.
      final line = ConsoleSink.render(
        _event(level: .error, meta: const <String, Object?>{'rpc.path': '/auth.v1/SignIn'}, name: 'rpc.failed'),
        .defaults,
      );

      expect(line, startsWith(kDim));
      expect(
        line,
        endsWith(
          '$kReset ${kEsc}31m[E]$kReset Rpc | call | ok '
          '${kDim}event.name=${kReset}rpc.failed ${kDim}rpc.path=$kReset/auth.v1/SignIn',
        ),
      );
      for (final level in LogLevel.values) {
        expect(colorize(level, 'x'), allOf(startsWith(kEsc), endsWith(kReset)), reason: '${level.name} has a style');
      }
    });

    test('a custom format replaces the renderer and can wrap it', () {
      final lines = <String>[];
      Telemetry(runId: 'run-fmt')
        ..addSink(
          ConsoleSink(
            options: plain,
            delegate: _Recording(lines),
            format: (event, options) => 'json:${ConsoleSink.render(event, options)}',
          ),
        )
        ..i('Rpc | call | ok');

      expect(lines.single, equals('json:[I] Rpc | call | ok'));
    });
  });

  group('level tag', () {
    const plain = TelemetryOptions(printColors: false, showTime: false);

    test('bracketed is the default', () {
      expect(ConsoleSink.render(_event(), plain), equals('[I] Rpc | call | ok'));
    });

    test('each preset has one text per level, and the texts of a preset are one width', () {
      for (final (tag, width) in <(LevelTag, int)>[(LevelTag.bracketed, 3), (LevelTag.letter, 1), (LevelTag.word, 5)]) {
        final texts = <String>[for (final level in LogLevel.values) tag.of(level)];
        expect(texts.toSet(), hasLength(LogLevel.values.length));
        expect(texts.map((text) => text.length).toSet(), equals(<int>{width}), reason: '$texts');
      }
      final glyphs = <String>[for (final level in LogLevel.values) LevelTag.glyph.of(level)];
      expect(glyphs.toSet(), hasLength(LogLevel.values.length));
    });

    test('the letter drops the brackets, the word spells the level out, the glyph draws it', () {
      expect(ConsoleSink.render(_event(), plain.copyWith(levelTag: .letter)), equals('I Rpc | call | ok'));
      expect(
        ConsoleSink.render(_event(level: .warn), plain.copyWith(levelTag: .word)),
        equals('WARN  Rpc | call | ok'),
      );
      expect(
        ConsoleSink.render(_event(level: .error), plain.copyWith(levelTag: .glyph)),
        equals('🚫 Rpc | call | ok'),
      );
    });

    test('a set of the app itself falls back to the bracketed letter', () {
      // ignore: avoid-missing-enum-constant-in-map, the fallback is what is under test
      const own = LevelTag(<LogLevel, String>{.info: 'ℹ'});
      expect(ConsoleSink.render(_event(), plain.copyWith(levelTag: own)), equals('ℹ Rpc | call | ok'));
      expect(ConsoleSink.render(_event(level: .error), plain.copyWith(levelTag: own)), equals('[E] Rpc | call | ok'));
    });

    test('the colour wraps whatever the tag is', () {
      final line = ConsoleSink.render(
        _event(level: .error),
        const TelemetryOptions(showTime: false, levelTag: .glyph),
      );
      expect(line, equals('${kEsc}31m🚫$kReset Rpc | call | ok'));
    });
  });

  group('icons', () {
    const plain = TelemetryOptions(printColors: false, showTime: false);
    const areas = AreaIcons(<String, String>{'Rpc': '🌍', 'Control': '🪢'});

    LogEvent lined(String body, {LogLevel level = .info}) =>
        .new(level: level, body: body, timestamp: _at, runId: 'run');

    test('no scheme adds nothing', () {
      expect(ConsoleSink.render(lined('Rpc | call | ok'), plain), equals('[I] Rpc | call | ok'));
    });

    test('an area scheme keeps the level tag, adds the glyph and drops the word', () {
      // The tag says the level, the glyph says the subsystem; neither can
      // stand in for the other.
      expect(
        ConsoleSink.render(lined('Control | lifecycle | disposed'), plain.copyWith(icon: areas)),
        equals('[I] 🪢 lifecycle | disposed'),
      );
      expect(
        ConsoleSink.render(lined('Control | handler | failed', level: .error), plain.copyWith(icon: areas)),
        equals('[E] 🪢 handler | failed'),
      );
    });

    test('a level glyph and an area glyph sit side by side', () {
      // Severity in the tag's column, subsystem after it, where a `package:l`
      // log put an emoji in the text.
      expect(
        ConsoleSink.render(
          lined('Control | lifecycle | disposed'),
          plain.copyWith(levelTag: .glyph, icon: areas),
        ),
        equals('💡 🪢 lifecycle | disposed'),
      );
    });

    test('an unmapped area gets no glyph and keeps its word', () {
      expect(
        ConsoleSink.render(lined('Pairing | handshake | ok'), plain.copyWith(icon: areas)),
        equals('[I] Pairing | handshake | ok'),
      );
    });

    test('replacesArea: false keeps the word beside the glyph', () {
      const kept = AreaIcons(<String, String>{'Control': '🪢'}, replacesArea: false);
      expect(
        ConsoleSink.render(lined('Control | lifecycle | disposed'), plain.copyWith(icon: kept)),
        equals('[I] 🪢 Control | lifecycle | disposed'),
      );
    });

    test('a body with no area is never cut', () {
      // A bridged line or a captured `print` has no `|` to drop.
      const anything = AreaIcons(<String, String>{'whatever was printed': '🪢'});
      expect(
        ConsoleSink.render(lined('whatever was printed'), plain.copyWith(icon: anything)),
        equals('[I] 🪢 whatever was printed'),
      );
    });

    test('the level tag keeps its colour next to an area glyph', () {
      final line = ConsoleSink.render(
        lined('Control | handler | failed', level: .error),
        const TelemetryOptions(showTime: false, levelTag: .letter, icon: areas),
      );

      expect(line, equals('${kEsc}31mE$kReset 🪢 handler | failed'));
    });

    test('a custom format sees the glyph, because render does the work', () {
      final lines = <String>[];
      Telemetry(runId: 'run-icon')
        ..addSink(
          ConsoleSink(
            options: plain.copyWith(icon: areas),
            delegate: _Recording(lines),
            format: (event, options) => 'json:${ConsoleSink.render(event, options)}',
          ),
        )
        ..i('Control | lifecycle | disposed');

      expect(lines.single, equals('json:[I] 🪢 lifecycle | disposed'));
    });
  });

  group('gating', () {
    test('renders answers the release question without reading the environment', () {
      const quiet = TelemetryOptions(minLevel: .info);
      expect(quiet.renders(.info, 0), isTrue);
      expect(quiet.renders(.debug, 0), isFalse);
      expect(quiet.renders(.error, 0, release: true), isFalse, reason: 'outputInRelease is off by default');

      const loud = TelemetryOptions(minLevel: .info, outputInRelease: true);
      expect(loud.renders(.error, 0, release: true), isTrue);
      expect(loud.renders(.debug, 0, release: true), isFalse, reason: 'the floor still applies in release');
    });

    test('maxVerbosity gates trace and leaves every other level alone', () {
      const options = TelemetryOptions(maxVerbosity: 3);
      expect(options.renders(.trace, 3), isTrue);
      expect(options.renders(.trace, 4), isFalse);
      expect(options.renders(.warn, 6), isTrue);
    });

    test('copyWith replaces one field and keeps the rest', () {
      const options = TelemetryOptions(minLevel: .warn, showMillis: true, developerName: 'auth');
      final quiet = options.copyWith(printColors: false);

      expect(quiet.printColors, isFalse);
      expect(quiet.minLevel, equals(LogLevel.warn));
      expect(quiet.showMillis, isTrue);
      expect(quiet.developerName, equals('auth'));
    });
  });

  group('the print destination', () {
    test('under `dart test` the platform delegate is the print one', () {
      expect(vm_delegate.createConsoleDelegate(), isA<PrintConsoleDelegate>());
    });

    test('a line longer than the wrap width is split into pieces', () {
      final long = 'x' * (kPrintWrapWidth * 2 + 5);
      final pieces = wrapForPrint(long);

      expect(pieces, hasLength(3), reason: 'Android truncates what it cannot take in one call');
      expect(pieces.first.length, equals(kPrintWrapWidth));
      expect(pieces.last.length, equals(5));
      expect(pieces.join(), equals(long));
    });

    test('a surrogate pair is never cut in half', () {
      // Split through the middle, each half is a lone surrogate and the
      // console's UTF-8 encoder renders it as U+FFFD.
      final line = '${'x' * (kPrintWrapWidth - 1)}🚀tail';
      final pieces = wrapForPrint(line);

      expect(pieces.first.length, equals(kPrintWrapWidth - 1), reason: 'the cut moved back a unit');
      expect(pieces.join(), equals(line));
      expect(pieces.last, startsWith('🚀'));
      for (final piece in pieces) {
        expect(piece.runes.contains(0xFFFD), isFalse);
      }
    });

    test('a stack trace is split one frame-line at a time', () {
      expect(
        wrapForPrint('Net | call | failed\n#0 one\n#1 two'),
        equals(<String>['Net | call | failed', '#0 one', '#1 two']),
      );
    });

    test('a short line is left whole', () {
      expect(wrapForPrint('Rpc | call | ok'), equals(<String>['Rpc | call | ok']));
    });
  });

  group('browser styling', () {
    test('a line with no escapes is left for the plain call', () {
      expect(browserStyled('[I] Rpc | call | ok'), isNull);
    });

    test('each escape becomes a marker and one CSS declaration', () {
      final line = ConsoleSink.render(_event(level: .error), const TelemetryOptions(showTime: false));
      final styled = browserStyled(line);

      expect(styled, isNotNull);
      expect(styled!.format, equals('%c[E]%c Rpc | call | ok'));
      expect(styled.styles, equals(<String>['color:#e2504a;font-weight:normal', 'font-weight:normal']));
      expect(styled.format.contains(kEsc), isFalse, reason: 'no escape survives the translation');
    });

    test('bold then red is one marker, and a reset drops both', () {
      final styled = browserStyled(ConsoleSink.render(_event(level: .fatal), const TelemetryOptions(showTime: false)));

      expect(styled!.format, equals('%c[F]%c Rpc | call | ok'));
      expect(styled.styles, equals(<String>['color:#e2504a;font-weight:bold', 'font-weight:normal']));
    });

    test('the dimmed time and keys get their own tone', () {
      final styled = browserStyled(
        ConsoleSink.render(_event(meta: const <String, Object?>{'rpc.path': '/x'}), .defaults),
      );

      expect(styled!.styles.first, equals('color:#9a9a9a;font-weight:normal'));
      expect(styled.format, contains('%crpc.path=%c/x'));
    });

    test('a percent in the text is doubled, since the console reads a format string', () {
      final styled = browserStyled(
        ConsoleSink.render(
          _event(meta: const <String, Object?>{'app.battery': '80%'}),
          const TelemetryOptions(showTime: false),
        ),
      );

      expect(styled!.format, endsWith('80%%'));
    });
  });

  group('colour resolution', () {
    test('a supplied delegate is trusted with whatever the options ask for', () {
      final lines = <String>[];
      Telemetry(runId: 'run-c')
        ..addSink(ConsoleSink(options: const TelemetryOptions(showTime: false), delegate: _Recording(lines)))
        ..i('Rpc | call | ok');

      expect(lines.single, startsWith(kEsc), reason: 'a test delegate decides for itself');
    });

    test('the destination never overrides printColors', () {
      // The sink asks nothing of the environment: only the app knows what reads
      // its output. A destination that shows escapes as text is paired with
      // `printColors: false` by the app that chose it.
      for (final output in <LogOutput>[.developer, .ignore]) {
        for (final colors in <bool>[true, false]) {
          final seen = <bool>[];
          Telemetry(runId: 'run-c2')
            ..addSink(
              ConsoleSink(
                options: TelemetryOptions(showTime: false, output: output, printColors: colors),
                format: (event, options) {
                  seen.add(options.printColors);
                  return '';
                },
              ),
            )
            ..i('Rpc | call | ok');

          expect(seen.single, equals(colors), reason: '${output.name} with printColors: $colors');
        }
      }
    });
  });

  group('the DevTools destination', () {
    test('carries the name it was built with', () {
      // The name is part of the key the sink caches delegates under, so a zone
      // that renames the logger builds its own.
      expect(const DeveloperConsoleDelegate(name: 'auth').name, equals('auth'));
      expect(const DeveloperConsoleDelegate().name, equals('app'));
    });
  });
}
