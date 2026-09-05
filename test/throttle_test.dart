import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

LogEvent _event(String body, {Object? error, String? name}) =>
    .new(level: .error, body: body, name: name, timestamp: DateTime.now().toUtc(), runId: 'run', error: error);

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
      final throttle = ReportThrottle(maxPerMinute: 6);
      final start = DateTime.utc(2026);
      final allowed = <bool>[
        for (var i = 0; i < 100; i++) throttle.allow(_event('Distinct | failure | #$i'), now: start),
      ];

      expect(allowed.where((ok) => ok), hasLength(6));
    });

    test('the ceiling refills as the minute rolls forward', () {
      // The rolling-minute eviction had no deterministic coverage: the
      // ceiling test never moved the clock, so nothing expired.
      final throttle = ReportThrottle(maxPerMinute: 2, dedupeWindow: .zero);
      final start = DateTime.utc(2026);

      expect(throttle.allow(_event('A | one | failed'), now: start), isTrue);
      expect(throttle.allow(_event('B | two | failed'), now: start), isTrue);
      expect(throttle.allow(_event('C | three | failed'), now: start), isFalse, reason: 'the ceiling is full');

      final later = start.add(const Duration(seconds: 61));
      expect(throttle.allow(_event('C | three | failed'), now: later), isTrue, reason: 'the first two aged out');
      expect(throttle.allow(_event('D | four | failed'), now: later), isTrue);
      expect(throttle.allow(_event('E | five | failed'), now: later), isFalse);
    });

    test('the dedupe map is pruned during a storm, not after it', () {
      // The prune used to sit after the ceiling check, so it never ran while
      // the ceiling was tripped, which is when the map was growing.
      final throttle = ReportThrottle(maxPerMinute: 1, dedupeWindow: const Duration(minutes: 5));
      final start = DateTime.utc(2026);
      for (var i = 0; i < 100; i++) {
        throttle.allow(_event('Storm | failure | #$i'), now: start);
      }

      // Six minutes on, everything recorded during the storm is out of the
      // window, so the first failure of that storm is reportable again.
      final later = start.add(const Duration(minutes: 6));
      expect(throttle.allow(_event('Storm | failure | #0'), now: later), isTrue);
    });

    test('one instance measures on one clock', () {
      final throttle = ReportThrottle();
      expect(throttle.allow(_event('Api | call | failed'), now: DateTime.utc(2026)), isTrue);
      expect(() => throttle.allow(_event('Api | call | failed')), throwsA(isA<AssertionError>()));
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
      final throttle = ReportThrottle(dedupeWindow: const Duration(minutes: 5));
      final start = DateTime.utc(2026);

      expect(throttle.allow(_event('Api | call | failed'), now: start), isTrue);
      expect(
        throttle.allow(_event('Api | call | failed'), now: start.add(const Duration(minutes: 4))),
        isFalse,
        reason: 'still inside the window',
      );
      expect(throttle.allow(_event('Api | call | failed'), now: start.add(const Duration(minutes: 6))), isTrue);
    });
  });
}
