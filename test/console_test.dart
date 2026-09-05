import 'package:telemetry/src/console/ansi.dart';
import 'package:telemetry/src/console/delegate_print.dart' as print_delegate;
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

LogEvent _event({LogLevel level = .info, Map<String, Object?> meta = const <String, Object?>{}}) =>
    .new(level: level, body: 'Rpc | call | ok', meta: meta, timestamp: _at, runId: 'run');

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

    test('a newline inside a value stays on the line', () {
      final line = ConsoleSink.render(_event(meta: const <String, Object?>{'log.message': 'first\nsecond'}), plain);

      expect(line, equals(r'[I] Rpc | call | ok log.message="first\nsecond"'));
      expect(line.contains('\n'), isFalse, reason: 'one event is one greppable line');
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

    test('colours wrap the level prefix and nothing else', () {
      final line = ConsoleSink.render(_event(level: .error), const TelemetryOptions(showTime: false));

      expect(line, startsWith(kEsc));
      expect(line, contains('$kReset Rpc | call | ok'));
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
      // Imported directly rather than through the conditional import, which is
      // the only way a suite can name the file it means.
      expect(vm_delegate.createConsoleDelegate(), isA<print_delegate.PrintConsoleDelegate>());
    });

    test('a line longer than the wrap width is split into pieces', () {
      final long = 'x' * (print_delegate.kPrintWrapWidth * 2 + 5);
      final pieces = print_delegate.wrapForPrint(long);

      expect(pieces, hasLength(3), reason: 'Android drops what it cannot take in one call');
      expect(pieces.first.length, equals(print_delegate.kPrintWrapWidth));
      expect(pieces.last.length, equals(5));
      expect(pieces.join(), equals(long));
    });

    test('a stack trace is split one frame-line at a time', () {
      expect(
        print_delegate.wrapForPrint('Net | call | failed\n#0 one\n#1 two'),
        equals(<String>['Net | call | failed', '#0 one', '#1 two']),
      );
    });

    test('a short line is left whole', () {
      expect(print_delegate.wrapForPrint('Rpc | call | ok'), equals(<String>['Rpc | call | ok']));
    });

    test('print renders ANSI; the VM answer depends on the terminal', () {
      expect(print_delegate.supportsAnsi(), isTrue);
      expect(vm_delegate.supportsAnsi(), isA<bool>());
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

    test('DevTools never gets escapes, whatever printColors says', () {
      final seen = <bool>[];
      Telemetry(runId: 'run-c2')
        ..addSink(
          ConsoleSink(
            // No delegate: the sink resolves colours against the destination,
            // and `dart:developer` stores the escapes in the message.
            options: const TelemetryOptions(showTime: false, output: .developer),
            format: (event, options) {
              seen.add(options.printColors);
              return '';
            },
          ),
        )
        ..i('Rpc | call | ok');

      expect(seen.single, isFalse);
    });

    test('the ignore destination is silent and colourless', () {
      final seen = <bool>[];
      Telemetry(runId: 'run-c3')
        ..addSink(
          ConsoleSink(
            options: const TelemetryOptions(showTime: false, output: .ignore),
            format: (event, options) {
              seen.add(options.printColors);
              return 'dropped';
            },
          ),
        )
        ..i('Rpc | call | ok');

      expect(seen.single, isFalse);
    });
  });
}
