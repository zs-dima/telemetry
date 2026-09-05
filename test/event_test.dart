import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  late Telemetry telemetry;
  late FakeSink sink;
  setUp(() => (telemetry, sink) = pipeline());

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
      expect(event?.meta.containsKey('event.name'), isFalse, reason: 'the projection adds it; the record has a field');
    });

    test('the sequence numbers the events of one launch', () {
      telemetry
        ..i('Boot | step | one')
        ..i('Boot | step | two')
        ..i('Boot | step | three');

      expect(sink.events.map((event) => event.sequence), equals(<int>[0, 1, 2]));
    });

    test('copyWith replaces what it is given and keeps the rest, resource included', () {
      telemetry.resource = <String, Object?>{'app.version': '1.0.0'};
      final event = telemetry('Api | call | failed').meta({'rpc.path': '/x'}).error();
      final adopted = event!.copyWith(level: .warn, name: 'api.call.failed');

      expect(adopted.level, equals(LogLevel.warn));
      expect(adopted.name, equals('api.call.failed'));
      expect(adopted.body, equals('Api | call | failed'));
      expect(adopted.meta, equals({'rpc.path': '/x'}));
      expect(
        adopted.resource,
        equals({'app.version': '1.0.0'}),
        reason: 'a forwarded event keeps the launch it is from',
      );
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

    test('debug-level events reach the pipeline', () {
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
}
