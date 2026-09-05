import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

LogEvent _event(String body, {LogLevel level = .info, int verbosity = 0, int sequence = 0}) => .new(
  level: level,
  body: body,
  verbosity: verbosity,
  sequence: sequence,
  timestamp: DateTime.now().toUtc(),
  runId: 'run',
);

void main() {
  group('LogBuffer', () {
    test('keeps everything from its floor up until the journal takes over', () {
      final buffer = LogBuffer();

      expect(buffer.guarantees(.debug), isTrue);
      expect(buffer.guarantees(.error), isTrue);
      buffer.markDrained();
      expect(buffer.guarantees(.debug), isFalse, reason: 'the journal holds it now');
      expect(buffer.guarantees(.trace), isTrue, reason: 'trace has no other home');
    });

    test('maxVerbosity is the ceiling on the tiers the ring keeps', () {
      final buffer = LogBuffer(maxVerbosity: 3);

      expect(buffer.guarantees(.trace, 1), isTrue);
      expect(buffer.guarantees(.trace, 3), isTrue);
      expect(buffer.guarantees(.trace, 4), isFalse);
      expect(buffer.guarantees(.warn, 6), isTrue, reason: 'verbosity is the noise dial of tracing, nothing else');
    });

    test('traceLimit: 0 refuses trace altogether', () {
      // The only setting that turns tracing off: a `trace()` with no tier has
      // verbosity 0, which every `maxVerbosity` admits.
      final buffer = LogBuffer(traceLimit: 0);

      expect(buffer.guarantees(.trace), isFalse);
      expect(buffer.guarantees(.trace, 6), isFalse);
      expect(buffer.guarantees(.info), isTrue);
    });

    test('a trace above the ceiling is never built', () {
      final pipeline = Telemetry(runId: 'run-v', buffer: LogBuffer(maxVerbosity: 3));
      var evaluated = false;

      expect(pipeline.isEnabled(.trace, verbosity: 6), isFalse);
      pipeline.v6(() {
        evaluated = true;
        return 'Control | dispose | quiet';
      });
      expect(evaluated, isFalse);
    });

    test('tracing cannot evict the boot', () {
      // Why the rings are separate: one `v1` per frame used to push the boot's
      // `info` lines out of a shared ring within a second.
      final buffer = LogBuffer(limit: 4, traceLimit: 2);
      final pipeline = Telemetry(runId: 'run-b', buffer: buffer)
        ..i('Boot | environment | loaded')
        ..i('Boot | database | opened');
      for (var frame = 0; frame < 50; frame++) {
        pipeline.v1('Control | frame | built');
      }

      expect(
        buffer.events.where((event) => event.level == .info).map((event) => event.body),
        equals(<String>['Boot | environment | loaded', 'Boot | database | opened']),
      );
      expect(buffer.events.where((event) => event.level == .trace), hasLength(2), reason: 'the noise evicts itself');
    });

    test('limit: 0 keeps nothing and throws nothing', () {
      // The mirror of `traceLimit: 0`. It used to reach `removeFirst` on an
      // empty ring, which threw out of every log call in release.
      final buffer = LogBuffer(limit: 0);

      expect(buffer.guarantees(.error), isFalse);
      expect(() => buffer.add(_event('Boot | step | failed', level: .error)), returnsNormally);
      expect(buffer.events, isEmpty);
      expect(buffer.guarantees(.trace), isTrue, reason: 'the trace ring has its own limit');
    });

    test('two rings tie on sequence and the timestamp settles it', () {
      // A bridge that forgets `nextSequence()` leaves the default zero on every
      // record; without the tie-break those sorted ahead of everything.
      final early = DateTime.utc(2026, 9, 5, 10);
      final buffer = LogBuffer()
        ..add(
          LogEvent(
            level: .info,
            body: 'Bridge | forwarded | second',
            timestamp: early.add(const Duration(minutes: 1)),
            runId: 'run',
          ),
        )
        ..add(LogEvent(level: .trace, body: 'Control | frame | painted', verbosity: 1, timestamp: early, runId: 'run'));

      expect(
        buffer.events.map((event) => event.body),
        equals(<String>['Control | frame | painted', 'Bridge | forwarded | second']),
      );
    });

    test('events is a snapshot, so a sink may log while a journal drains it', () {
      // A journal drains this list and logs its own lines as it goes; iterating
      // the live rings would fail halfway through the drain.
      final buffer = LogBuffer()
        ..add(_event('Boot | step | one', sequence: 1))
        ..add(_event('Boot | step | two', sequence: 2));
      final drained = buffer.events;

      buffer.add(_event('Boot | step | three', sequence: 3));

      expect(drained, hasLength(2), reason: 'the snapshot is what it was when it was taken');
      expect(buffer.length, equals(3), reason: 'while the buffer moved on');
      for (final event in drained) {
        expect(event.body, isNotEmpty, reason: 'and it iterates whatever the buffer does next');
      }
    });

    test('the two rings come out in the order they happened', () {
      final buffer = LogBuffer(limit: 4, traceLimit: 4);
      Telemetry(runId: 'run-o', buffer: buffer)
        ..i('Boot | step | one')
        ..v1('Control | frame | a')
        ..i('Boot | step | two')
        ..v1('Control | frame | b');

      expect(
        buffer.events.map((event) => event.body),
        equals(<String>['Boot | step | one', 'Control | frame | a', 'Boot | step | two', 'Control | frame | b']),
      );
      expect(buffer.events.map((event) => event.sequence), equals(<int>[0, 1, 2, 3]));
    });

    test('the drain leaves the trace ring alone', () {
      final buffer = LogBuffer(limit: 4, traceLimit: 4);
      final pipeline = Telemetry(runId: 'run-d', buffer: buffer)
        ..i('Boot | step | one')
        ..v1('Control | frame | a');

      buffer.markDrained();
      expect(buffer.events.map((event) => event.body), equals(<String>['Control | frame | a']));

      pipeline
        ..i('Users | list | ok')
        ..v1('Control | frame | b');
      expect(
        buffer.events.map((event) => event.body),
        equals(<String>['Control | frame | a', 'Control | frame | b']),
        reason: 'the journal has the rest',
      );
    });

    test('each ring drops the oldest first, and clear empties both', () {
      final buffer = LogBuffer(limit: 2, traceLimit: 1);
      for (final (index, body) in <String>['Boot | step | one', 'Boot | step | two', 'Boot | step | three'].indexed) {
        buffer.add(_event(body, sequence: index));
      }
      buffer
        ..add(_event('Control | frame | a', level: .trace, verbosity: 1, sequence: 3))
        ..add(_event('Control | frame | b', level: .trace, verbosity: 1, sequence: 4));

      expect(
        buffer.events.map((event) => event.body),
        equals(<String>['Boot | step | two', 'Boot | step | three', 'Control | frame | b']),
      );
      expect(buffer.length, equals(3));
      buffer.clear();
      expect(buffer.length, isZero);
      expect(buffer.events, isEmpty);
    });
  });
}
