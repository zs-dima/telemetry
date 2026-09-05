import 'dart:async';

import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  late Telemetry telemetry;
  late FakeSink sink;
  setUp(() => (telemetry, sink) = pipeline());

  group('zone', () {
    test('print inside the zone becomes one debug event and does not recurse', () {
      telemetry.zoned(() {
        // ignore: avoid_print, the behaviour under test.
        print('hello from print');
      });

      final captured = sink.events.single;
      expect(captured.body, equals('hello from print'));
      expect(
        captured.level,
        equals(LogLevel.debug),
        reason: 'info is the breadcrumb floor; a captured print must not become one',
      );
      expect(captured.meta['log.source'], equals('print'));
    });

    test('a captured print carries the scope it was printed in', () {
      // The handler re-enters the zone `print` was called in, so an inner
      // scope is still in force; re-entering the installing zone would drop it.
      telemetry.zoned(() {
        telemetry.scoped({'rpc.path': '/sync.v1/Upload'}, () {
          // ignore: avoid_print, the behaviour under test.
          print('server said no');
        });
      });

      expect(sink.events.single.meta['rpc.path'], equals('/sync.v1/Upload'));
    });

    test('handlePrint: false forwards to the parent zone instead of capturing', () {
      final printed = <String>[];
      runZoned(
        () => telemetry.zoned(
          () {
            // ignore: avoid_print, the behaviour under test.
            print('untouched');
          },
          options: const TelemetryOptions(handlePrint: false),
        ),
        zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => printed.add(line)),
      );

      expect(printed, equals(['untouched']));
      expect(sink.events, isEmpty);
    });

    test('runTelemetry without a print handler still carries the options', () {
      final printed = <String>[];
      runZoned(
        () => runTelemetry(
          () {
            expect(currentTelemetryOptions()?.minLevel, equals(LogLevel.warn));
            // ignore: avoid_print, the behaviour under test.
            print('passed through');
          },
          options: const TelemetryOptions(minLevel: .warn),
        ),
        zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => printed.add(line)),
      );

      expect(printed, equals(['passed through']));
      expect(currentTelemetryOptions(), isNull, reason: 'the options do not leak out of the zone');
    });

    test('a zone can change the console icon for its body only', () {
      final lines = <String>[];
      final console = ConsoleSink(
        options: const TelemetryOptions(printColors: false, showTime: false),
        delegate: RecordingDelegate(lines),
      );
      final app = Telemetry(runId: 'run-icon')..addSink(console);

      app.zoned(
        () => app.i('Control | lifecycle | disposed'),
        options: const TelemetryOptions(
          printColors: false,
          showTime: false,
          icon: AreaIcons(<String, String>{'Control': '🪢'}),
        ),
      );
      app.i('Control | lifecycle | disposed');

      expect(lines, equals(<String>['[I] 🪢 lifecycle | disposed', '[I] Control | lifecycle | disposed']));
    });

    test('zone options are visible to sinks that read them', () {
      final rendered = <String>[];
      final console = ConsoleSink(
        options: const TelemetryOptions(printColors: false, showTime: false),
        delegate: RecordingDelegate(rendered),
      );
      final app = Telemetry(runId: 'run-6')..addSink(console);

      app.zoned(
        () => app.i('Boot | ready | ok'),
        options: const TelemetryOptions(minLevel: .warn, printColors: false),
      );
      app.i('Boot | ready | again');

      expect(rendered, hasLength(1), reason: 'the zone raised the console threshold for its body only');
      expect(rendered.single, contains('Boot | ready | again'));
    });
  });

  group('console rendering', () {
    late List<String> lines;
    late Telemetry app;

    setUp(() {
      lines = <String>[];
      app = Telemetry(runId: 'run-7')
        ..addSink(
          ConsoleSink(
            options: const TelemetryOptions(printColors: false, showTime: false),
            delegate: RecordingDelegate(lines),
          ),
        );
    });

    test('is one greppable line with attributes inline', () {
      app.i('Rpc | call | ok', meta: {'rpc.path': '/auth.v1/SignIn', 'net.duration_ms': 42});

      expect(lines.single, equals('[I] Rpc | call | ok rpc.path=/auth.v1/SignIn net.duration_ms=42'));
    });

    test('shows the event name and hides the launch resource', () {
      app
        ..resource = <String, Object?>{'app.version': '1.0.0'}
        ..call('Sync | upload | refused').name('sync.upload.refused').meta({'http.status_code': 429}).warn();

      expect(lines.single, equals('[W] Sync | upload | refused event.name=sync.upload.refused http.status_code=429'));
    });

    test('appends the stack trace only for failures', () {
      app
        ..w('Net | retry | slow', stackTrace: StackTrace.fromString('W-TRACE'))
        ..e('Net | call | failed', error: StateError('x'), stackTrace: StackTrace.fromString('E-TRACE'));

      expect(lines.first, isNot(contains('W-TRACE')), reason: 'a warning with a trace buries the next line');
      expect(lines.last, contains('E-TRACE'));
    });

    test('maxVerbosity gates trace tiers and nothing else', () {
      final captured = <String>[];
      Telemetry(runId: 'run-8')
        ..addSink(
          ConsoleSink(
            options: const TelemetryOptions(showTime: false, printColors: false, maxVerbosity: 3),
            delegate: RecordingDelegate(captured),
          ),
        )
        ..v1('Control | frame | built')
        ..v5('Control | dispose | quiet')
        // A verbosity tier above `trace` does not gate the line itself.
        ..call('Storage | quota | low').verbosity(5).warn();

      expect(captured.map((line) => line.split(' | ').first), equals(['[T] Control', '[W] Storage']));
    });

    test('the options are settable, so a dev menu can turn tracing on', () {
      final console = ConsoleSink(
        options: const TelemetryOptions(printColors: false, showTime: false, minLevel: .warn),
        delegate: RecordingDelegate(lines),
      );
      final pipeline = Telemetry(runId: 'run-9')
        ..addSink(console)
        ..i('Boot | ready | ok');
      expect(lines, isEmpty);

      console.options = const TelemetryOptions(printColors: false, showTime: false, minLevel: .trace);
      pipeline.i('Boot | ready | again');
      expect(lines.single, contains('Boot | ready | again'));
    });
  });
}
