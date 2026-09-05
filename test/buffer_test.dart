import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

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

    test('a whisper above the ceiling is never built at all', () {
      // Without the ceiling the quietest tiers are the loudest by volume, and
      // they evict the tier somebody is actually reading.
      final pipeline = Telemetry(runId: 'run-v', buffer: LogBuffer(limit: 4, maxVerbosity: 3));
      var evaluated = false;

      expect(pipeline.isEnabled(.trace, verbosity: 6), isFalse);
      pipeline.v6(() {
        evaluated = true;
        return 'Control | dispose | quiet';
      });
      expect(evaluated, isFalse);

      pipeline
        ..v1('Control | frame | built')
        ..v6('Control | dispose | quiet')
        ..v3('Control | build | scheduled');
      expect(
        pipeline.buffer.events.map((event) => event.verbosity),
        equals(<int>[1, 3]),
        reason: 'the loud tiers keep their places in the ring',
      );
    });

    test('the ring drops the oldest first and clear empties it', () {
      final buffer = LogBuffer(limit: 2);
      for (final body in <String>['Boot | step | one', 'Boot | step | two', 'Boot | step | three']) {
        buffer.add(LogEvent(level: .info, body: body, timestamp: DateTime.now().toUtc(), runId: 'run'));
      }

      expect(buffer.events.map((event) => event.body), equals(<String>['Boot | step | two', 'Boot | step | three']));
      expect(buffer.length, equals(2));
      buffer.clear();
      expect(buffer.length, isZero);
    });
  });
}
