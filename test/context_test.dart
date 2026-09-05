import 'dart:async';

import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  late Telemetry telemetry;
  late FakeSink sink;
  setUp(() => (telemetry, sink) = pipeline());

  group('context', () {
    test('scope attributes reach every event logged inside it', () {
      telemetry.scoped({'rpc.path': '/auth.v1/SignIn'}, () => telemetry.i('Rpc | call | ok'));

      expect(sink.events.single.meta, equals({'rpc.path': '/auth.v1/SignIn'}));
    });

    test('scope survives an await', () async {
      await telemetry.scoped({'rpc.path': '/auth.v1/SignIn'}, () async {
        await Future<void>.delayed(.zero);
        telemetry.i('Rpc | call | ok');
      });

      expect(sink.events.single.meta['rpc.path'], equals('/auth.v1/SignIn'));
    });

    test('a nested scope merges, and the inner one wins', () {
      telemetry.scoped({'rpc.path': '/outer', 'app.route': '/home'}, () {
        telemetry.scoped({'rpc.path': '/inner'}, () => telemetry.i('Rpc | call | ok'));
      });

      expect(sink.events.single.meta, equals({'rpc.path': '/inner', 'app.route': '/home'}));
    });

    test('the call site wins over the scope', () {
      telemetry.scoped({'app.route': '/home'}, () {
        telemetry('Rpc | call | ok').meta({'app.route': '/settings'}).info();
      });

      expect(sink.events.single.meta, equals({'app.route': '/settings'}));
    });

    test('a scope reaches a draft that only named a channel', () async {
      final toast = FakeToast();
      telemetry.toastSink = toast;

      telemetry.scoped({'app.route': '/settings'}, () {
        telemetry('Settings | save | failed').description('Не сохранилось').toast(tone: .alert);
      });
      await Future<void>.delayed(.zero);

      expect(sink.events.single.meta['app.route'], equals('/settings'));
    });

    test('an attribute value may be a callback, resolved once and only if logged', () {
      var calls = 0;
      telemetry('Db | query | slow').meta({
        'db.plan': () {
          calls++;
          return 'SCAN users';
        },
      }).info();

      expect(sink.events.single.meta['db.plan'], equals('SCAN users'));
      expect(calls, equals(1));
    });
  });

  group('resource', () {
    test('is a field of its own, not repeated in the event attributes', () {
      telemetry
        ..resource = {'app.version': '1.0.0', 'app.environment': 'dev'}
        ..i('Boot | start | ok', meta: <String, Object?>{'app.boot.step': 'environment'});

      final event = sink.events.single;
      expect(event.resource, equals({'app.version': '1.0.0', 'app.environment': 'dev'}));
      expect(event.meta, equals({'app.boot.step': 'environment'}), reason: 'meta is what varied');
      expect(
        event.attributes,
        equals({'app.version': '1.0.0', 'app.environment': 'dev', 'app.boot.step': 'environment'}),
        reason: 'a sink stores the flat projection',
      );
    });

    test('is the same object on every event, not a copy each', () {
      telemetry
        ..resource = {'app.version': '1.0.0'}
        ..i('Boot | step | one')
        ..i('Boot | step | two');

      expect(identical(sink.events.first.resource, sink.events.last.resource), isTrue);
      expect(identical(sink.events.first.resource, telemetry.resource), isTrue);
    });

    test('a scope or a call site may shadow a resource key in the projection only', () {
      telemetry.resource = {'app.environment': 'dev'};
      telemetry.scoped({'app.environment': 'staging'}, () => telemetry.i('Boot | start | ok'));

      final event = sink.events.single;
      expect(event.attributes['app.environment'], equals('staging'), reason: 'the nearer answer wins');
      expect(event.resource['app.environment'], equals('dev'), reason: 'the launch still knows what it is');
    });

    test('a callback in the resource is resolved once, when it is set', () {
      var calls = 0;
      telemetry
        ..resource = {
          'app.version': () {
            calls++;
            return '1.0.0';
          },
        }
        ..i('Boot | step | one')
        ..i('Boot | step | two');

      expect(calls, equals(1), reason: 'a closure left in the resource would be paid for by every sink, every event');
      expect(sink.events.last.resource['app.version'], equals('1.0.0'));
    });

    test('is unmodifiable once set', () {
      telemetry.resource = {'app.version': '1.0.0'};
      expect(() => telemetry.resource['app.version'] = '2.0.0', throwsUnsupportedError);
    });
  });

  group('trace correlation', () {
    test('the trace in flight travels on the event', () {
      telemetry
        // Parenthesised: an arrow body would otherwise swallow the cascade.
        ..traceContext = (() => (traceId: 'abc123', spanId: 'def456'))
        ..i('Rpc | call | ok');

      final event = sink.events.single;
      expect(event.traceId, equals('abc123'));
      expect(event.spanId, equals('def456'));
    });

    test('no provider leaves the slots empty', () {
      telemetry.i('Rpc | call | ok');

      final event = sink.events.single;
      expect(event.traceId, isNull);
      expect(event.spanId, isNull);
    });

    test('a provider that says there is no trace leaves them empty too', () {
      telemetry
        ..traceContext = (() => null)
        ..i('Rpc | call | ok');

      expect(sink.events.single.traceId, isNull);
    });

    test('a channel-only draft keeps the trace it acted inside, not the one a microtask later', () async {
      // The span the call site was in has ended by the time the fan-out runs;
      // reading the provider then would correlate the line to the wrong request.
      final toast = FakeToast();
      // A one-slot holder rather than a captured local, so the span can end
      // between the action and the fan-out.
      final span = <String?>['while-acting'];
      telemetry
        ..toastSink = toast
        ..traceContext = (() => span.first == null ? null : (traceId: span.first!, spanId: null));

      telemetry('Sync | upload | refused').description('Занято').toast(tone: .alert);
      span[0] = null;
      await Future<void>.delayed(.zero);

      expect(sink.events.single.traceId, equals('while-acting'));
    });
  });

  group('clock and stack capture', () {
    test('the clock is a seam, and its answer is normalised to UTC', () {
      final pinned = DateTime.utc(2026, 9, 5, 12, 30);
      telemetry
        ..clock = pinned.toLocal
        ..i('Boot | start | ok');

      final stamp = sink.events.single.timestamp;
      expect(stamp, equals(pinned));
      expect(stamp.isUtc, isTrue);
    });

    test('a disabled fluent chain never reads the clock', () {
      // The gate comes first, so a level nobody wants costs a draft and
      // nothing else: no clock, no trace provider, no snapshot.
      var reads = 0;
      final quiet = Telemetry(runId: 'run-c', buffer: LogBuffer(traceLimit: 0))
        ..clock = (() {
          reads++;
          return DateTime.utc(2026);
        });
      quiet.buffer.markDrained();

      final event = quiet('Control | frame | built').meta({'app.frame.index': 1}).debug();

      expect(event, isNull);
      expect(reads, isZero);
    });

    test('a channel-only draft is stamped when the action ran, not when the microtask did', () async {
      final toast = FakeToast();
      final stamps = <DateTime>[DateTime.utc(2026), DateTime.utc(2027)];
      var index = 0;
      telemetry
        ..toastSink = toast
        ..clock = (() => stamps[index++]);

      telemetry('Settings | save | failed').description('Ошибка').toast(tone: .alert);
      await Future<void>.delayed(.zero);

      expect(sink.events.single.timestamp, equals(DateTime.utc(2026)), reason: 'the first clock read is the action');
    });

    test('stackTraceAtLevel fills a missing trace from that level up', () {
      telemetry
        ..stackTraceAtLevel = .error
        ..w('Net | retry | slow')
        ..e('Net | call | failed');

      expect(sink.events.first.stackTrace, isNull, reason: 'below the floor nothing is captured');
      expect(sink.events.last.stackTrace, isNotNull);
    });

    test('stackTraceAtLevel never replaces the trace the failure came with', () {
      telemetry.stackTraceAtLevel = .warn;
      telemetry('Net | call | failed').cause(StateError('x'), StackTrace.fromString('ORIGINAL')).error();

      expect(sink.events.single.stackTrace?.toString(), equals('ORIGINAL'));
    });
  });
}
