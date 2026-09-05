import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  late Telemetry telemetry;
  late FakeSink sink;
  setUp(() => (telemetry, sink) = pipeline());

  group('conventions', () {
    test('a body that is not Area | operation is refused where it is written', () {
      // Synchronous, so the stack points at the line that wrote the body, and
      // it fires whether or not anything consumes the level.
      expect(() => telemetry('interpolated for user 42'), throwsA(isA<AssertionError>()));
    });

    test('a lazy body is checked when it is built', () {
      expect(() => telemetry(() => 'interpolated for user 42').info(), throwsA(isA<AssertionError>()));
    });

    test('an attribute key that is not OpenTelemetry-named is refused', () {
      expect(() => telemetry('A | b | c').meta({'attempt': 3}), throwsA(isA<AssertionError>()));
    });

    test('an event name that is not dot-separated is refused', () {
      expect(() => telemetry('A | b | c').name('refused'), throwsA(isA<AssertionError>()));
    });

    test('a trace tier outside 1..6 is refused', () {
      expect(() => telemetry('A | b | c').verbosity(9), throwsA(isA<AssertionError>()));
    });

    test('an analytics name that is not one snake_case word is refused', () {
      expect(() => telemetry('A | b | c')..track('Purchase Completed'), throwsA(isA<AssertionError>()));
    });

    test('a bare resource key is refused', () {
      expect(() => telemetry.resource = <String, Object?>{'version': '1.0.0'}, throwsA(isA<AssertionError>()));
    });

    test('a bare scope key is refused', () {
      expect(() => telemetry.scoped(<String, Object?>{'path': '/x'}, noop), throwsA(isA<AssertionError>()));
    });

    test('strict: false lets a bridge log whatever it was given', () {
      telemetry.strict = false;
      expect(() => telemetry('interpolated for user 42').meta({'attempt': 3}).info(), returnsNormally);
    });

    test('lenient lets one line through without disarming the rest', () {
      // What `Telemetry.zoned` uses for a captured `print`.
      expect(() => LogDraft(telemetry, 'whatever was printed', lenient: true).debug(), returnsNormally);
      expect(() => telemetry('still refused'), throwsA(isA<AssertionError>()));
    });

    test('an attribute added after the log action is refused', () {
      final draft = telemetry('A | b | c')..info();
      expect(() => draft.meta({'app.late.key': 1}), throwsA(isA<AssertionError>()));
    });

    test('a cause added after the log action is refused', () {
      final draft = telemetry('A | b | c')..info();
      expect(() => draft.cause(StateError('late')), throwsA(isA<AssertionError>()));
    });

    test('a draft logs once, and a second action returns the first event', () {
      final draft = telemetry('A | b | c');
      final first = draft.info();
      // In release the assert is stripped; either way there must be no second
      // event with a second sequence number.
      expect(draft.warn, throwsA(isA<AssertionError>()));
      expect(sink.events, hasLength(1));
      expect(sink.events.single, same(first));
    });
  });
}
