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
      final allowed = <bool>[for (var i = 0; i < 100; i++) throttle.allow(_event('Distinct failure #$i'))];

      expect(allowed.where((ok) => ok), hasLength(6));
    });

    test('two lines sharing an event name are one failure', () {
      // The body is prose and gets copy-edited; the name is what a fingerprint
      // and this key are meant to survive that on.
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
