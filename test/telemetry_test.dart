import 'dart:async';

import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

/// Records everything it is given.
final class _FakeSink implements TelemetrySink {
  _FakeSink({this.minLevel = LogLevel.trace, this.throws = false});

  final LogLevel minLevel;
  final bool throws;
  final List<LogEvent> events = <LogEvent>[];

  @override
  bool enabled(LogLevel level, int verbosity) => level >= minLevel;

  @override
  void handle(LogEvent event) {
    if (throws) throw StateError('sink is broken');
    events.add(event);
  }
}

final class _FakeToast implements ToastSink {
  final List<ToastRequest> requests = <ToastRequest>[];

  @override
  void toast(ToastRequest request) => requests.add(request);
}

final class _FakeEscalation implements EscalationSink {
  final List<({LogEvent event, LogLevel? level})> escalations = <({LogEvent event, LogLevel? level})>[];

  @override
  void escalate(LogEvent event, {LogLevel? level, StackTrace? stackTrace}) =>
      escalations.add((event: event, level: level));
}

final class _FakeTrack implements TrackSink {
  final List<({String name, Map<String, Object?> props})> tracked = <({String name, Map<String, Object?> props})>[];

  @override
  void track(String name, Map<String, Object?> props, LogEvent event) => tracked.add((name: name, props: props));
}

final class _FakeNotify implements NotifySink {
  final List<({Object kind, Map<String, Object?> args})> notified = <({Object kind, Map<String, Object?> args})>[];

  @override
  void notify(Object kind, Map<String, Object?> args, LogEvent event) => notified.add((kind: kind, args: args));
}

/// A sink that holds what it is given until it is flushed.
final class _FlushableSink implements TelemetrySink, Flushable {
  _FlushableSink({this.throws = false});

  final bool throws;
  final List<LogEvent> pending = <LogEvent>[];
  final List<LogEvent> written = <LogEvent>[];

  @override
  bool enabled(LogLevel level, int verbosity) => true;

  @override
  void handle(LogEvent event) => pending.add(event);

  @override
  Future<void> flush() async {
    if (throws) throw StateError('cannot write');
    written.addAll(pending);
    pending.clear();
  }
}

/// Logs from inside `handle`, which is a sink bug; the pipeline must survive it.
final class _RecursiveSink implements TelemetrySink {
  _RecursiveSink(this.telemetry);

  final Telemetry telemetry;
  int handled = 0;

  @override
  bool enabled(LogLevel level, int verbosity) => true;

  @override
  void handle(LogEvent event) {
    handled++;
    telemetry.i('Sink | handle | echo');
  }
}

void main() {
  late Telemetry telemetry;
  late _FakeSink sink;

  setUp(() {
    sink = _FakeSink();
    telemetry = Telemetry(runId: 'run-1')..addSink(sink);
  });

  group('event model', () {
    test('carries body, attributes, level and a UTC timestamp', () {
      telemetry('Pairing | handshake | refused').meta({'app.pairing.attempt': 3}).warn();

      final event = sink.events.single;
      expect(event.body, equals('Pairing | handshake | refused'));
      expect(event.level, equals(LogLevel.warn));
      expect(event.meta, equals({'app.pairing.attempt': 3}));
      expect(event.timestamp.isUtc, isTrue, reason: 'a stamp that can leave the device is never local');
      expect(event.runId, equals('run-1'));
    });

    test('area and operation are derived from the canonical body', () {
      final event = telemetry('Pairing | handshake | refused by peer').info();
      expect(event?.area, equals('Pairing'));
      expect(event?.operation, equals('handshake'));
    });

    test('a body without separators still yields an area and an empty operation', () {
      // The convention check is what normally refuses this body; the accessors
      // still have to answer for a body that came from a bridge.
      telemetry.strict = false;
      final event = telemetry('plain message').info();
      expect(event?.area, equals('plain message'));
      expect(event?.operation, isEmpty);
    });

    test('the exception becomes OpenTelemetry attributes, not part of the body', () {
      final event = telemetry('Api | call | failed').cause(const FormatException('bad'), StackTrace.empty).error();

      expect(event?.body, equals('Api | call | failed'), reason: 'the body stays the grouping key');
      expect(event?.attributes['exception.type'], equals('FormatException'));
      expect(event?.attributes['exception.message'], contains('bad'));
    });

    test('the stack trace is not an attribute', () {
      // Journal rows and crash reports have a dedicated field for it.
      final event = telemetry('Api | call | failed')
          .cause(const FormatException('bad'), StackTrace.fromString('TRACE'))
          .error();

      expect(event?.stackTrace?.toString(), equals('TRACE'));
      expect(event?.attributes.keys, isNot(contains('exception.stacktrace')));
    });

    test('the event name is carried and surfaces as an attribute', () {
      final event = telemetry('Pairing | handshake | refused').name('pairing.handshake.refused').warn();

      expect(event?.name, equals('pairing.handshake.refused'));
      expect(event?.attributes['event.name'], equals('pairing.handshake.refused'));
    });

    test('the sequence numbers the events of one launch', () {
      telemetry
        ..i('Boot | step | one')
        ..i('Boot | step | two')
        ..i('Boot | step | three');

      expect(sink.events.map((event) => event.sequence), equals(<int>[0, 1, 2]));
    });

    test('copyWith replaces what it is given and keeps the rest', () {
      final event = telemetry('Api | call | failed').meta({'rpc.path': '/x'}).error();
      final adopted = event!.copyWith(level: .warn, name: 'api.call.failed');

      expect(adopted.level, equals(LogLevel.warn));
      expect(adopted.name, equals('api.call.failed'));
      expect(adopted.body, equals('Api | call | failed'));
      expect(adopted.meta, equals({'rpc.path': '/x'}));
      expect(adopted.timestamp, equals(event.timestamp));
    });
  });

  group('levels', () {
    test('map onto the OpenTelemetry and package:logging scales', () {
      expect(LogLevel.trace.severityNumber, equals(1));
      expect(LogLevel.debug.severityNumber, equals(5));
      expect(LogLevel.info.severityNumber, equals(9));
      expect(LogLevel.warn.severityNumber, equals(13));
      expect(LogLevel.error.severityNumber, equals(17));
      expect(LogLevel.fatal.severityNumber, equals(21));

      expect(LogLevel.debug.developerLevel, equals(500));
      expect(LogLevel.info.developerLevel, equals(800));
      expect(LogLevel.warn.developerLevel, equals(900));
      expect(LogLevel.error.developerLevel, equals(1000));
    });

    test('compare in both directions, in declaration order', () {
      const ordered = LogLevel.values;
      for (final (left, a) in ordered.indexed) {
        for (final (right, b) in ordered.indexed) {
          final pair = '${a.name}/${b.name}';
          expect(a > b, equals(left > right), reason: pair);
          expect(a >= b, equals(left >= right), reason: pair);
          expect(a < b, equals(left < right), reason: pair);
          expect(a <= b, equals(left <= right), reason: pair);
          expect(a.compareTo(b).sign, equals((left - right).sign), reason: pair);
        }
      }
    });

    test('fromValue reads names and OpenTelemetry numbers only', () {
      expect(LogLevel.fromValue('warn'), equals(LogLevel.warn));
      expect(LogLevel.fromValue(13), equals(LogLevel.warn));
      expect(LogLevel.fromValue(LogLevel.fatal), equals(LogLevel.fatal));
      // 900 is WARNING on the package:logging scale and nothing on
      // OpenTelemetry's; such rows are migrated by the storage layer.
      expect(LogLevel.fromValue(900), equals(LogLevel.info), reason: 'an unknown number degrades, it does not guess');
      expect(LogLevel.fromValue('shout'), equals(LogLevel.info));
      expect(LogLevel.fromValue(null), equals(LogLevel.info));
    });

    test('debug-level events reach the pipeline', () {
      // A debug line is dispatched like any other; nothing drops it first.
      telemetry.d('Control | transition | idle -> processing');
      expect(sink.events.single.level, equals(LogLevel.debug));
    });

    test('trace tiers are named, not numbered arguments', () {
      telemetry
        ..v1('Control | frame | built')
        ..v6('Control | dispose | PairingController');

      expect(sink.events.map((e) => e.verbosity), equals([1, 6]));
      expect(sink.events.every((e) => e.level == .trace), isTrue);
    });
  });

  group('dispatch', () {
    test('a disabled sink neither receives events nor evaluates a lazy message', () {
      // After the drain the buffer keeps only `trace`, so the sinks alone
      // decide whether `debug` is enabled.
      final quiet = Telemetry(runId: 'run-2')..addSink(_FakeSink(minLevel: .error));
      quiet.buffer.markDrained();
      var evaluated = false;

      quiet.d(() {
        evaluated = true;
        return 'expensive';
      });

      expect(evaluated, isFalse, reason: 'the message must not be built for a level nobody wants');
    });

    test('the fluent path checks Enabled too, and says so by returning null', () {
      final quiet = Telemetry(runId: 'run-2b')..addSink(_FakeSink(minLevel: .error));
      quiet.buffer.markDrained();
      var evaluated = false;

      final event = quiet(() {
        evaluated = true;
        return 'expensive';
      }).meta({'app.test.value': 1}).debug();

      expect(event, isNull);
      expect(evaluated, isFalse, reason: 'the draft must not snapshot for a level nobody wants');
    });

    test('a throwing sink does not stop the others', () {
      final healthy = _FakeSink();
      final broken = _FakeSink(throws: true);
      Telemetry(runId: 'run-3')
        ..addSink(broken)
        ..addSink(healthy)
        ..i('Boot | start | ok');

      expect(healthy.events, hasLength(1));
    });

    test('a sink registered while an event is dispatched does not break the run', () {
      final late = _FakeSink();
      final pipeline = Telemetry(runId: 'run-3b');
      pipeline
        ..addSink(_MutatingSink(pipeline, late))
        ..addSink(sink);

      expect(() => pipeline.i('Boot | start | ok'), returnsNormally);
      expect(sink.events, hasLength(1), reason: 'the list being iterated was the one read at entry');
      expect(late.events, isEmpty, reason: 'a sink added during dispatch sees the next event, not this one');

      pipeline.i('Boot | start | again');
      expect(late.events, hasLength(1));
    });

    test('a sink that logs from handle is stopped at the depth cap', () {
      final pipeline = Telemetry(runId: 'run-3c');
      final recursive = _RecursiveSink(pipeline);
      pipeline.addSink(recursive);

      expect(() => pipeline.i('Boot | start | ok'), returnsNormally);
      expect(recursive.handled, equals(3), reason: 'the cap is three levels deep');
    });

    test('removeSink stops delivery and clears the failure mark', () {
      final broken = _FakeSink(throws: true);
      final pipeline = Telemetry(runId: 'run-3d')
        ..addSink(broken)
        ..i('Boot | start | ok')
        ..removeSink(broken)
        ..i('Boot | start | again');
      expect(broken.events, isEmpty);

      // Re-registered, the sink is a stranger again: a transient failure that
      // was fixed must be able to report the next one.
      pipeline
        ..addSink(sink)
        ..i('Boot | start | third');
      expect(sink.events, hasLength(1));
    });

    test('emit delivers a record this pipeline did not compose', () {
      final foreign = LogEvent(
        level: .warn,
        body: 'Logging | forwarded | record',
        timestamp: DateTime.utc(2020),
        runId: 'somebody-else',
        meta: const <String, Object?>{'log.logger': 'cupertino_http'},
      );

      telemetry.emit(foreign);

      expect(identical(sink.events.single, foreign), isTrue);
      expect(sink.events.single.timestamp, equals(DateTime.utc(2020)), reason: 'a bridge keeps the record\'s own time');
      expect(telemetry.buffer.events.single.body, equals('Logging | forwarded | record'));
    });

    test('the buffer keeps the newest events within its limit', () {
      final small = Telemetry(runId: 'run-4', buffer: LogBuffer(limit: 2))
        ..addSink(sink)
        ..i('Boot | step | one')
        ..i('Boot | step | two')
        ..i('Boot | step | three');

      expect(
        small.buffer.events.map((e) => e.body),
        equals(['Boot | step | two', 'Boot | step | three']),
      );
    });

    test('the buffer records events logged before any sink exists', () {
      // The buffer answers `isEnabled` during boot, so this holds with no sink
      // at all and the lines survive to be drained into the journal.
      final booting = Telemetry(runId: 'run-4b')
        ..i('Boot | environment | loaded')
        ..d('Boot | database | opened')
        ..v6('Boot | frame | painted');

      expect(
        booting.buffer.events.map((e) => e.body),
        equals(<String>[
          'Boot | environment | loaded',
          'Boot | database | opened',
          'Boot | frame | painted',
        ]),
      );
    });

    test('after the drain the buffer keeps trace and nothing else', () {
      // The journal has the boot on disk now, and `trace` sits below every
      // sink's floor, so the ring becomes its only home.
      final booting = Telemetry(runId: 'run-4c')
        ..i('Boot | environment | loaded')
        ..v6('Boot | frame | painted');

      booting.buffer.markDrained();
      expect(booting.buffer.events.map((e) => e.body), equals(['Boot | frame | painted']));

      booting
        ..i('Users | list | ok')
        ..v1('Control | frame | built');
      expect(booting.buffer.events.map((e) => e.body), equals(['Boot | frame | painted', 'Control | frame | built']));
    });

    test('isEnabled answers before an event is built', () {
      expect(telemetry.isEnabled(.trace), isTrue);
      final bare = Telemetry(runId: 'run-5');
      expect(bare.isEnabled(.error), isTrue, reason: 'the buffer keeps debug and above with no sink at all');
      expect(bare.isEnabled(.trace, verbosity: 6), isTrue, reason: 'the buffer is the only home trace has');

      bare.buffer.markDrained();
      expect(bare.isEnabled(.error), isFalse, reason: 'the journal has it now; no sink, no consumer');
      expect(bare.isEnabled(.trace, verbosity: 6), isTrue, reason: 'trace still has nowhere else to go');
    });

    test('dispatch survives a closed event stream', () async {
      final closing = Telemetry(runId: 'run-5b')..addSink(sink);
      // The subscription lives as long as the closing instance under test.
      // ignore: avoid-unassigned-stream-subscriptions
      closing.events.listen((_) {});
      await closing.close();

      expect(() => closing.i('Boot | shutdown | late line'), returnsNormally);
      expect(sink.events.single.body, equals('Boot | shutdown | late line'));
    });

    test('the event stream carries what the sinks got', () async {
      final seen = <LogEvent>[];
      final subscription = telemetry.events.listen(seen.add);
      addTearDown(subscription.cancel);

      telemetry.i('Boot | start | ok');
      await Future<void>.delayed(.zero);

      expect(identical(seen.single, sink.events.single), isTrue);
    });
  });

  group('flush', () {
    test('writes through every sink that holds events', () async {
      final journal = _FlushableSink();
      final pipeline = Telemetry(runId: 'run-f')
        ..addSink(journal)
        ..i('Db | write | queued');
      expect(journal.written, isEmpty);

      await pipeline.flush();
      expect(journal.written.single.body, equals('Db | write | queued'));
    });

    test('a sink that cannot write does not stop the others, and close still completes', () async {
      final broken = _FlushableSink(throws: true);
      final journal = _FlushableSink();
      final pipeline = Telemetry(runId: 'run-f2')
        ..addSink(broken)
        ..addSink(journal)
        ..i('Db | write | queued');

      await expectLater(pipeline.close(), completes);
      expect(journal.written, hasLength(1));
    });
  });

  group('draft guards', () {
    test('a draft that names no channel is reported, not thrown', () async {
      Object? captured;
      await runZonedGuarded(
        () async {
          telemetry('Settings | save | forgotten').meta({'app.settings.key': 'theme'});
          await Future<void>.delayed(.zero);
        },
        (error, stackTrace) => captured = error,
      );

      expect(captured, isNull, reason: 'a forgotten terminal call must not arrive as an uncaught zone error');
      final reported = sink.events.single;
      expect(reported.body, equals('Telemetry | draft | unused'));
      expect(reported.level, equals(LogLevel.warn), reason: 'never error: it must not become a crash-reporter issue');
      expect(reported.meta['log.body'], equals('Settings | save | forgotten'));
    });

    test('a burst of unused drafts costs one microtask, not one each', () async {
      var scheduled = 0;
      runZoned(
        () {
          for (var index = 0; index < 5; index++) {
            telemetry('Settings | save | forgotten');
          }
        },
        zoneSpecification: ZoneSpecification(
          scheduleMicrotask: (self, parent, zone, callback) {
            scheduled++;
            parent.scheduleMicrotask(zone, callback);
          },
        ),
      );

      expect(scheduled, equals(1), reason: 'the guard is armed once per burst');
      await Future<void>.delayed(.zero);
      expect(sink.events, hasLength(5), reason: 'every dropped draft is still named');
    });

    test('a draft that was used is not reported', () async {
      telemetry('Settings | save | ok').info();
      await Future<void>.delayed(.zero);

      expect(sink.events.map((event) => event.body), equals(['Settings | save | ok']));
    });

    test('a draft logs at most once', () {
      final draft = telemetry('A | b | c')..info();
      expect(draft.warn, throwsA(isA<AssertionError>()));
    });

    test('strict refuses a body that is not Area | operation, and a bare attribute key', () {
      expect(() => telemetry('interpolated for user 42').info(), throwsA(isA<AssertionError>()));
      expect(() => telemetry('A | b | c').meta({'attempt': 3}), throwsA(isA<ArgumentError>()));
    });

    test('strict: false lets a bridge log whatever it was given', () {
      telemetry.strict = false;
      expect(() => telemetry('interpolated for user 42').meta({'attempt': 3}).info(), returnsNormally);
    });
  });

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

    test('the call site wins over the scope, and the scope over the resource', () {
      telemetry
        ..resource = {'app.version': '1.0.0', 'app.environment': 'dev'}
        ..scoped({'app.environment': 'staging', 'app.route': '/home'}, () {
          telemetry('Rpc | call | ok').meta({'app.route': '/settings'}).info();
        });

      expect(
        sink.events.single.meta,
        equals(<String, Object?>{'app.version': '1.0.0', 'app.environment': 'staging', 'app.route': '/settings'}),
      );
    });

    test('the resource travels on every event with no scope at all', () {
      telemetry
        ..resource = {'app.version': '1.0.0'}
        ..i('Boot | start | ok');

      expect(sink.events.single.meta, equals({'app.version': '1.0.0'}));
    });

    test('a scope reaches a draft that only named a channel', () async {
      final toast = _FakeToast();
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
  });

  group('clock and stack capture', () {
    test('the clock is a seam', () {
      final pinned = DateTime.utc(2026, 9, 5, 12, 30);
      telemetry
        ..clock = (() => pinned)
        ..i('Boot | start | ok');

      expect(sink.events.single.timestamp, equals(pinned));
    });

    test('a channel-only draft is stamped when the action ran, not when the microtask did', () async {
      final toast = _FakeToast();
      final stamps = <DateTime>[
        DateTime.utc(2026),
        DateTime.utc(2027),
      ];
      var index = 0;
      telemetry
        ..toastSink = toast
        ..clock = () => stamps[index++];

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

  group('channels', () {
    test('toast carries the localized description, never the developer body', () async {
      final toast = _FakeToast();
      telemetry.toastSink = toast;

      telemetry('Pairing | handshake | refused').description('Не удалось подключиться').toast(tone: .alert);
      await Future<void>.delayed(.zero);

      expect(toast.requests.single.text, equals('Не удалось подключиться'));
      expect(toast.requests.single.tone, equals(ToastTone.alert));
      expect(toast.requests.single.event.body, equals('Pairing | handshake | refused'));
    });

    test('the toast carries the same event the sinks received', () async {
      // One record per draft, so "Details" behind a toast opens the event the
      // sinks were given.
      final toast = _FakeToast();
      telemetry.toastSink = toast;

      telemetry('Db | write | failed').cause(StateError('closed')).description('Ошибка')
        ..warn()
        ..toast(tone: .alert);
      await Future<void>.delayed(.zero);

      expect(identical(toast.requests.single.event, sink.events.single), isTrue);
    });

    test('a toast without a log action is still journaled, once, after the cascade', () async {
      final toast = _FakeToast();
      telemetry.toastSink = toast;

      telemetry('Settings | save | failed').description('Не сохранилось').toast(tone: .alert);

      expect(sink.events, isEmpty, reason: 'the fallback runs after the cascade, not during it');
      await Future<void>.delayed(.zero);
      final logged = sink.events.single;
      expect(logged.level, equals(LogLevel.info));
      expect(logged.body, equals('Settings | save | failed'));
    });

    test('a cause makes the implicit fallback a warning, never an error', () async {
      // `error` is auto-reported, so deriving it from an attached exception
      // would file a crash-reporter issue for a forgotten `..warn()`.
      final toast = _FakeToast();
      telemetry.toastSink = toast;

      telemetry('Db | write | failed').cause(StateError('closed')).description('Ошибка').toast();

      await Future<void>.delayed(.zero);
      expect(sink.events.single.level, equals(LogLevel.warn));
    });

    test('an explicit log action wins over the fallback, in either cascade order', () async {
      final toast = _FakeToast();
      telemetry.toastSink = toast;

      telemetry('A | b | c').description('x')
        ..toast()
        ..warn();
      telemetry('D | e | f').description('y')
        ..warn()
        ..toast();

      await Future<void>.delayed(.zero);
      // Two drafts, one line each.
      expect(sink.events.map((e) => e.level), equals(<LogLevel>[.warn, .warn]));
    });

    test('escalate() forwards a warning but is a no-op for a logged error', () async {
      final escalation = _FakeEscalation();
      telemetry.escalationSink = escalation;

      telemetry('Net | retry | exhausted')
        ..warn()
        ..escalate();
      telemetry('Net | call | failed').cause(StateError('boom'))
        ..error()
        ..escalate();
      await Future<void>.delayed(.zero);

      expect(escalation.escalations, hasLength(1), reason: 'errors are auto-reported; a second send would duplicate');
      expect(escalation.escalations.single.event.level, equals(LogLevel.warn));
    });

    test('escalate() reads the level the draft ended on, in either cascade order', () async {
      // The check runs after the cascade, so `..escalate()..error()` cannot
      // escalate a warning and capture an issue for the same failure.
      final escalation = _FakeEscalation();
      telemetry.escalationSink = escalation;

      telemetry('Net | call | failed').cause(StateError('boom'))
        ..escalate()
        ..error();
      await Future<void>.delayed(.zero);

      expect(escalation.escalations, isEmpty, reason: 'the draft ended at error, which is auto-reported');
    });

    test('escalate(level:) marks this warning as an incident, and is honoured', () async {
      // The no-op check reads the event's own severity, not the override.
      final escalation = _FakeEscalation();
      telemetry.escalationSink = escalation;

      telemetry('Storage | quota | exceeded').cause(StateError('full'))
        ..warn()
        ..escalate(level: .error);
      await Future<void>.delayed(.zero);

      expect(escalation.escalations.single.level, equals(LogLevel.error));
      expect(
        escalation.escalations.single.event.level,
        equals(LogLevel.warn),
        reason: 'the journal keeps the real severity',
      );
    });

    test('escalate() forwards the stack trace it was given', () async {
      final traces = <StackTrace?>[];
      telemetry.escalationSink = _CapturingEscalation(traces);

      telemetry('Net | retry | exhausted')
        ..warn()
        ..escalate(stackTrace: StackTrace.fromString('EXPLICIT'));
      await Future<void>.delayed(.zero);

      expect(traces.single?.toString(), equals('EXPLICIT'));
    });

    test('the deprecated sentry() still forwards to escalate()', () async {
      final escalation = _FakeEscalation();
      telemetry.escalationSink = escalation;

      telemetry('Net | retry | exhausted')
        ..warn()
        // ignore: deprecated_member_use_from_same_package, avoid-deprecated-usage, the alias under test.
        ..sentry();
      await Future<void>.delayed(.zero);

      expect(escalation.escalations, hasLength(1));
    });

    test('track and notify reach their sinks with their payloads, and leave a journal line', () async {
      final track = _FakeTrack();
      final notify = _FakeNotify();
      telemetry
        ..trackSink = track
        ..notifySink = notify;

      telemetry('Paywall | purchase | completed')
        ..info()
        ..track('purchase_completed', props: {'sku': 'pro_yearly'});
      telemetry('Link | peer | ended')
        ..info()
        ..notify('linkPeerEnded', args: {'peer': 'alice'});

      await Future<void>.delayed(.zero);
      expect(track.tracked.single.name, equals('purchase_completed'));
      expect(track.tracked.single.props, equals({'sku': 'pro_yearly'}));
      expect(notify.notified.single.kind, equals('linkPeerEnded'));
      expect(notify.notified.single.args, equals({'peer': 'alice'}));
      expect(sink.events, hasLength(2));
    });
  });

  group('buffer lives', () {
    test('a retried boot buffers again after the journal is torn down', () {
      final retried = Telemetry(runId: 'run-1');
      addTearDown(retried.close);
      final buffer = retried.buffer;

      retried.i('Boot | step | done');
      expect(buffer.length, equals(1), reason: 'no sink yet, so the buffer is the only consumer');

      // The journal opened, took the boot, and left the ring to `trace`.
      buffer.markDrained();
      expect(buffer.length, isZero);
      retried.i('Boot | step | done');
      expect(buffer.length, isZero, reason: 'the journal holds it now');

      // The composition was then abandoned, taking the sink with it.
      buffer.undrain();
      retried.i('Boot | step | done');
      expect(buffer.length, equals(1), reason: 'the retry has no journal either, so the buffer is back on duty');
    });
  });

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

    test('zone options are visible to sinks that read them', () {
      final rendered = <String>[];
      final console = ConsoleSink(
        options: const TelemetryOptions(printColors: false, showTime: false),
        delegate: _RecordingDelegate(rendered),
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
            delegate: _RecordingDelegate(lines),
          ),
        );
    });

    test('is one greppable line with attributes inline', () {
      app.i('Rpc | call | ok', meta: {'rpc.path': '/auth.v1/SignIn', 'net.duration_ms': 42});

      expect(lines.single, equals('[I] Rpc | call | ok rpc.path=/auth.v1/SignIn net.duration_ms=42'));
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
            delegate: _RecordingDelegate(captured),
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
        delegate: _RecordingDelegate(lines),
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

/// Registers another sink from inside `handle`, which the dispatcher must
/// tolerate.
final class _MutatingSink implements TelemetrySink {
  _MutatingSink(this.telemetry, this.late);

  bool _added = false;

  final Telemetry telemetry;
  final TelemetrySink late;

  @override
  bool enabled(LogLevel level, int verbosity) => true;

  @override
  void handle(LogEvent event) {
    if (_added) return;
    _added = true;
    telemetry.addSink(late);
  }
}

final class _RecordingDelegate implements ConsoleDelegate {
  const _RecordingDelegate(this.lines);
  final List<String> lines;

  @override
  void write(LogLevel level, String line) => lines.add(line);
}

final class _CapturingEscalation implements EscalationSink {
  const _CapturingEscalation(this.traces);
  final List<StackTrace?> traces;

  @override
  void escalate(LogEvent event, {LogLevel? level, StackTrace? stackTrace}) => traces.add(stackTrace);
}
