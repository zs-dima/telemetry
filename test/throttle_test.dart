import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

LogEvent _event(String body, {Object? error, String? name}) =>
    .new(level: .error, body: body, name: name, timestamp: DateTime.now().toUtc(), runId: 'run', error: error);

/// A clock the test moves by hand, in place of the stopwatch.
final class _Clock {
  Duration now = .zero;

  Duration read() => now;

  void advance(Duration by) => now += by;
}

void main() {
  group('ReportThrottle', () {
    test('the first occurrence of anything always gets through', () {
      final throttle = ReportThrottle();
      expect(throttle.allow(_event('Listener | alarm | siren failed')), isTrue);
    });

    test('a failure loop costs one report, not one per iteration', () {
      final throttle = ReportThrottle();
      final allowed = <bool>[for (var i = 0; i < 100; i++) throttle.allow(_event('Listener | alarm | siren failed'))];

      expect(allowed.where((ok) => ok), hasLength(1));
    });

    test('the same body with a different cause is a different failure', () {
      final throttle = ReportThrottle();

      expect(throttle.allow(_event('Api | call | failed', error: const FormatException())), isTrue);
      expect(throttle.allow(_event('Api | call | failed', error: StateError('other'))), isTrue);
      expect(throttle.allow(_event('Api | call | failed', error: const FormatException())), isFalse);
    });

    test('distinct failures still stop at the per-minute ceiling', () {
      final clock = _Clock();
      final throttle = ReportThrottle(maxPerMinute: 6, clock: clock.read);
      final allowed = <bool>[for (var i = 0; i < 100; i++) throttle.allow(_event('Distinct | failure | #$i'))];

      expect(allowed.where((ok) => ok), hasLength(6));
    });

    test('the ceiling refills as the minute rolls forward', () {
      // The rolling-minute eviction had no deterministic coverage: the
      // ceiling test never moved the clock, so nothing expired.
      final clock = _Clock();
      final throttle = ReportThrottle(maxPerMinute: 2, dedupeWindow: .zero, clock: clock.read);

      expect(throttle.allow(_event('A | one | failed')), isTrue);
      expect(throttle.allow(_event('B | two | failed')), isTrue);
      expect(throttle.allow(_event('C | three | failed')), isFalse, reason: 'the ceiling is full');

      clock.advance(const Duration(seconds: 61));
      expect(throttle.allow(_event('C | three | failed')), isTrue, reason: 'the first two aged out');
      expect(throttle.allow(_event('D | four | failed')), isTrue);
      expect(throttle.allow(_event('E | five | failed')), isFalse);
    });

    test('the dedupe map is pruned during a storm, not after it', () {
      // The prune used to sit after the ceiling check, so it never ran while
      // the ceiling was tripped, which is when the map was growing.
      final clock = _Clock();
      final throttle = ReportThrottle(maxPerMinute: 1, dedupeWindow: const Duration(minutes: 5), clock: clock.read);
      for (var i = 0; i < 100; i++) {
        throttle.allow(_event('Storm | failure | #$i'));
      }

      // Six minutes on, everything recorded during the storm is out of the
      // window, so the first failure of that storm is reportable again.
      clock.advance(const Duration(minutes: 6));
      expect(throttle.allow(_event('Storm | failure | #0')), isTrue);
    });

    test('a supplied clock replaces the stopwatch for the life of the instance', () {
      // There is no second scale to mix in: the constructor takes the clock, so
      // one that never advances ages nothing out, whatever the wall clock says.
      final clock = _Clock();
      final throttle = ReportThrottle(maxPerMinute: 100, dedupeWindow: const Duration(minutes: 5), clock: clock.read);
      final failure = _event('Api | call | failed');
      final decisions = <bool>[for (var attempt = 0; attempt < 2; attempt++) throttle.allow(failure)];

      expect(decisions, equals(<bool>[true, false]), reason: 'no time passes on the clock it was given');
    });

    test('two lines sharing an event name are one failure', () {
      // The body is prose and gets copy-edited; the name is what this key and
      // a fingerprint survive that on.
      final throttle = ReportThrottle();

      expect(throttle.allow(_event('Net | call | failed', name: 'net.call.failed')), isTrue);
      expect(throttle.allow(_event('Net | call | gave up', name: 'net.call.failed')), isFalse);
      expect(throttle.allow(_event('Net | call | gave up')), isTrue, reason: 'without a name the body is the key');
    });

    test('the dedupe window expires and the ceiling refills', () {
      final clock = _Clock();
      final throttle = ReportThrottle(dedupeWindow: const Duration(minutes: 5), clock: clock.read);
      final failure = _event('Api | call | failed');
      final decisions = <String, bool>{};

      decisions['first'] = throttle.allow(failure);
      clock.advance(const Duration(minutes: 4));
      decisions['inside the window'] = throttle.allow(failure);
      clock.advance(const Duration(minutes: 2));
      decisions['past the window'] = throttle.allow(failure);

      expect(decisions, equals(<String, bool>{'first': true, 'inside the window': false, 'past the window': true}));
    });
  });
}
