import 'dart:async';

import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  late Telemetry telemetry;
  late FakeSink sink;
  setUp(() => (telemetry, sink) = pipeline());

  group('dispatch', () {
    test('a disabled sink neither receives events nor evaluates a lazy message', () {
      // After the drain the buffer keeps only `trace`, so the sinks alone
      // decide whether `debug` is enabled.
      final quiet = Telemetry(runId: 'run-2')..addSink(FakeSink(minLevel: .error));
      quiet.buffer.markDrained();
      var evaluated = false;

      quiet.d(() {
        evaluated = true;
        return 'expensive';
      });

      expect(evaluated, isFalse, reason: 'the message must not be built for a level nobody wants');
    });

    test('the fluent path checks Enabled too, and says so by returning null', () {
      final quiet = Telemetry(runId: 'run-2b')..addSink(FakeSink(minLevel: .error));
      quiet.buffer.markDrained();
      var evaluated = false;

      final event = quiet(() {
        evaluated = true;
        return 'expensive';
      }).meta({'app.test.value': 1}).debug();

      expect(event, isNull);
      expect(evaluated, isFalse, reason: 'the draft must not snapshot for a level nobody wants');
    });

    test('a lazy body may return any object', () {
      final event = telemetry(() => const Body()).info();
      expect(event?.body, equals('Lazy | body | object'));
    });

    test('a throwing sink does not stop the others', () {
      final healthy = FakeSink();
      final broken = FakeSink(throws: true);
      Telemetry(runId: 'run-3')
        ..addSink(broken)
        ..addSink(healthy)
        ..i('Boot | start | ok');

      expect(healthy.events, hasLength(1));
    });

    test('a sink whose gate throws is contained like one whose handle throws', () {
      // `enabled` is asked inside the same guard as `handle`: a broken gate must
      // not take the failure to the line that called `log.i`.
      final healthy = FakeSink();
      final pipeline = Telemetry(runId: 'run-3g')
        ..addSink(FakeSink(throwsFromEnabled: true))
        ..addSink(healthy);

      expect(() => pipeline.i('Boot | start | ok'), returnsNormally);
      expect(healthy.events, hasLength(1), reason: 'the sinks after it still got the event');
      expect(pipeline.isEnabled(.info), isTrue, reason: 'a sink that cannot answer does not want it');
    });

    test('a sink registered while an event is dispatched does not break the run', () {
      final late = FakeSink();
      final pipeline = Telemetry(runId: 'run-3b');
      pipeline
        ..addSink(MutatingSink(pipeline, late))
        ..addSink(sink);

      expect(() => pipeline.i('Boot | start | ok'), returnsNormally);
      expect(sink.events, hasLength(1), reason: 'the list being iterated was the one read at entry');
      expect(late.events, isEmpty, reason: 'a sink added during dispatch sees the next event, not this one');

      pipeline.i('Boot | start | again');
      expect(late.events, hasLength(1));
    });

    test('a sink that logs from handle is stopped at the depth cap', () {
      final pipeline = Telemetry(runId: 'run-3c');
      final recursive = RecursiveSink(pipeline);
      pipeline.addSink(recursive);

      expect(() => pipeline.i('Boot | start | ok'), returnsNormally);
      expect(recursive.handled, equals(3), reason: 'the cap is three levels deep');
    });

    test('removeSink stops delivery and clears the failure mark', () {
      final broken = FakeSink(throws: true);
      final pipeline = Telemetry(runId: 'run-3d')
        ..addSink(broken)
        ..i('Boot | start | ok')
        ..removeSink(broken)
        ..i('Boot | start | again')
        // Re-registered, the sink is a stranger again: a failure that was
        // fixed must be able to report the next one.
        ..addSink(sink)
        ..i('Boot | start | third');
      expect(broken.events, isEmpty);
      expect(sink.events, hasLength(1));
      expect(pipeline.buffer.length, equals(3));
    });

    test('sinks lists what is registered, in order, and cannot be edited', () {
      // Both apps kept their own bookkeeping to answer "is my sink still the
      // live one"; this is the answer.
      final console = FakeSink();
      final journal = FakeSink();
      final pipeline = Telemetry(runId: 'run-3s')
        ..addSink(console)
        ..addSink(journal);

      expect(pipeline.sinks, equals(<TelemetrySink>[console, journal]));

      pipeline.removeSink(console);
      expect(pipeline.sinks, equals(<TelemetrySink>[journal]));
      expect(() => pipeline.sinks.add(console), throwsUnsupportedError);
    });

    test('removeSink tells two equal sinks apart', () {
      // Two sinks that compare equal are still two places an event has to
      // reach.
      final firstEvents = <LogEvent>[];
      final secondEvents = <LogEvent>[];
      final first = EqualSink(firstEvents);
      Telemetry(runId: 'run-3e')
        ..addSink(first)
        ..addSink(EqualSink(secondEvents))
        ..removeSink(first)
        ..i('Boot | start | ok');

      expect(firstEvents, isEmpty);
      expect(secondEvents, hasLength(1), reason: 'the other instance was never registered for removal');
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

    test('emit enriches nothing, the resource included', () {
      telemetry
        ..resource = <String, Object?>{'app.version': '1.0.0'}
        ..emit(
          LogEvent(level: .info, body: 'Bridge | forwarded | record', timestamp: DateTime.utc(2020), runId: 'other'),
        );

      expect(sink.events.single.resource, isEmpty, reason: 'the event is taken as given; a bridge passes its own');
    });

    test('the buffer keeps the newest events within its limit', () {
      final small = Telemetry(runId: 'run-4', buffer: LogBuffer(limit: 2))
        ..addSink(sink)
        ..i('Boot | step | one')
        ..i('Boot | step | two')
        ..i('Boot | step | three');

      expect(small.buffer.events.map((e) => e.body), equals(['Boot | step | two', 'Boot | step | three']));
    });

    test('the buffer records events logged before any sink exists', () {
      // The buffer answers `isEnabled` during boot, so the lines survive with
      // no sink at all.
      final booting = Telemetry(runId: 'run-4b')
        ..i('Boot | environment | loaded')
        ..d('Boot | database | opened')
        ..v6('Boot | frame | painted');

      expect(
        booting.buffer.events.map((e) => e.body),
        equals(<String>['Boot | environment | loaded', 'Boot | database | opened', 'Boot | frame | painted']),
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

    test('the quick path asks each sink once, not twice', () {
      // The shortcut gates, then hands the draft a `gated` flag so it does not
      // repeat the same O(sinks) question.
      final counted = FakeSink(minLevel: .info);
      final pipeline = Telemetry(runId: 'run-5c')..addSink(counted);
      pipeline.buffer.markDrained();

      pipeline.i('Boot | start | ok');

      expect(counted.asked, equals(2), reason: 'once to decide, once as the event is delivered');
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

    test('a listener on the stream does not switch a gated level back on', () async {
      // If subscribing counted as wanting an event, a debug overlay would undo
      // every floor the buffer and the sinks agreed on.
      final quiet = Telemetry(runId: 'run-5d', buffer: LogBuffer(traceLimit: 0));
      quiet.buffer.markDrained();
      final subscription = quiet.events.listen((_) {});
      addTearDown(subscription.cancel);

      expect(quiet.isEnabled(.error), isFalse);
      expect(quiet.isEnabled(.trace, verbosity: 1), isFalse);
    });
  });

  group('flush', () {
    test('writes through every sink that holds events', () async {
      final journal = FlushableSink();
      final pipeline = Telemetry(runId: 'run-f')
        ..addSink(journal)
        ..i('Db | write | queued');
      expect(journal.written, isEmpty);

      await pipeline.flush();
      expect(journal.written.single.body, equals('Db | write | queued'));
    });

    test('reaches a channel destination that holds work too', () async {
      final messenger = FlushableToast();
      final pipeline = Telemetry(runId: 'run-f3')..toastSink = messenger;

      await pipeline.flush();
      expect(messenger.flushes, equals(1));
    });

    test('a sink that cannot write does not stop the others, and close still completes', () async {
      final broken = FlushableSink(throws: true);
      final journal = FlushableSink();
      final pipeline = Telemetry(runId: 'run-f2')
        ..addSink(broken)
        ..addSink(journal)
        ..i('Db | write | queued');

      await expectLater(pipeline.close(), completes);
      expect(journal.written, hasLength(1));
    });
  });
}
