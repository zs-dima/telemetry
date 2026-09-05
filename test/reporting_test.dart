import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

/// One line as a recorder saw it.
typedef _Sent = ({String body, LogLevel level});

/// The policy of [ReportingSink] with a notebook where the vendor would be.
final class _Recorder extends ReportingSink {
  _Recorder({super.breadcrumbLevel, super.captureLevel});

  final List<String> breadcrumbs = <String>[];
  final List<_Sent> captures = <_Sent>[];
  final List<_Sent> reports = <_Sent>[];

  @override
  void breadcrumb(LogEvent event) => breadcrumbs.add(event.body);

  @override
  void capture(LogEvent event, LogLevel level, StackTrace? stackTrace) =>
      captures.add((body: event.body, level: level));

  @override
  void report(LogEvent event, LogLevel level) => reports.add((body: event.body, level: level));
}

void main() {
  late Telemetry telemetry;
  late _Recorder reporter;

  setUp(() {
    reporter = _Recorder();
    telemetry = Telemetry(runId: 'run-r')
      ..addSink(reporter)
      ..escalationSink = reporter;
  });

  group('ReportingSink', () {
    test('everything from the breadcrumb floor up leaves a trail', () {
      telemetry
        ..i('Auth | signIn | ok')
        ..w('Net | retry | slow');

      expect(reporter.breadcrumbs, equals(<String>['Auth | signIn | ok', 'Net | retry | slow']));
      expect(reporter.captures, isEmpty, reason: 'a warning is not an incident');
    });

    test('below the breadcrumb floor nothing is offered at all', () {
      final quiet = _Recorder(breadcrumbLevel: .warn);
      Telemetry(runId: 'run-r2')
        ..addSink(quiet)
        ..i('Auth | signIn | ok')
        ..w('Net | retry | slow');

      expect(quiet.breadcrumbs, equals(<String>['Net | retry | slow']));
    });

    test('a failure is a breadcrumb and an incident, in that order', () {
      telemetry.e('Net | call | failed', error: StateError('boom'));

      expect(reporter.breadcrumbs, equals(<String>['Net | call | failed']));
      expect(reporter.captures.single.level, equals(LogLevel.error));
    });

    test('a failure loop costs one incident, not one per iteration', () {
      for (var attempt = 0; attempt < 20; attempt++) {
        telemetry.e('Net | call | failed', error: StateError('boom'));
      }

      expect(reporter.captures, hasLength(1));
      expect(reporter.breadcrumbs, hasLength(20), reason: 'the trail keeps every attempt; only the issue is deduped');
    });

    test('an escalated warning is a structured log, not an incident', () async {
      telemetry('Net | retry | exhausted')
        ..warn()
        ..escalate();
      await Future<void>.delayed(.zero);

      expect(reporter.reports.single.level, equals(LogLevel.warn));
      expect(reporter.captures, isEmpty);
    });

    test('an escalation that overrides the level to error is an incident', () async {
      telemetry('Storage | quota | exceeded').cause(StateError('full'))
        ..warn()
        ..escalate(level: .error);
      await Future<void>.delayed(.zero);

      expect(reporter.captures.single.level, equals(LogLevel.error));
      expect(reporter.reports, isEmpty);
    });

    test('the escalated incident shares the throttle with the automatic path', () async {
      telemetry.e('Net | call | failed', error: StateError('boom'));
      telemetry('Net | call | failed').cause(StateError('boom'))
        ..warn()
        ..escalate(level: .error);
      await Future<void>.delayed(.zero);

      expect(reporter.captures, hasLength(1), reason: 'one failure cannot spend two reports');
    });

    test('captureLevel moves the line between a log and an incident', () {
      final strict = _Recorder(captureLevel: .fatal);
      Telemetry(runId: 'run-r3')
        ..addSink(strict)
        ..e('Net | call | failed', error: StateError('boom'))
        ..f('Boot | step | failed', error: StateError('worse'));

      expect(strict.captures.map((capture) => capture.body), equals(<String>['Boot | step | failed']));
    });

    test('the event name is what the throttle keys on once it is set', () {
      telemetry
        ..e('Net | call | failed', error: StateError('boom'))
        ..call('Net | call | failed after retry').name('net.call.failed').cause(StateError('boom')).error()
        ..call('Net | call | gave up').name('net.call.failed').cause(StateError('boom')).error();

      expect(
        reporter.captures.map((capture) => capture.body),
        equals(<String>['Net | call | failed', 'Net | call | failed after retry']),
        reason: 'the two lines sharing a name are one failure, however the prose differs',
      );
    });
  });
}
