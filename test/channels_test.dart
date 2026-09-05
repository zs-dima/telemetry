import 'dart:async';

import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  late Telemetry telemetry;
  late FakeSink sink;
  setUp(() => (telemetry, sink) = pipeline());

  group('channels', () {
    test('toast carries the localized description, never the developer body', () async {
      final toast = FakeToast();
      telemetry.toastSink = toast;

      telemetry('Pairing | handshake | refused').description('Не удалось подключиться').toast(tone: .alert);
      await Future<void>.delayed(.zero);

      expect(toast.requests.single.text, equals('Не удалось подключиться'));
      expect(toast.requests.single.tone, equals(ToastTone.alert));
      expect(toast.requests.single.event.body, equals('Pairing | handshake | refused'));
    });

    test('toast reads the description the draft ends with, whatever the cascade order', () async {
      // The analyzer refuses a discarded builder, so this shape cannot be
      // written by accident; the runtime still has to be right for a build that
      // suppressed it.
      final toast = FakeToast();
      telemetry.toastSink = toast;
      final draft = telemetry('Settings | save | failed')..toast(tone: .alert);
      // A cascade section would be `unused_result`, a separate statement is
      // `cascade_invocations`: there is no clean way to write this shape.
      // ignore: unused_result, cascade_invocations
      draft.description('Не сохранилось');
      await Future<void>.delayed(.zero);

      expect(toast.requests.single.text, equals('Не сохранилось'));
    });

    test('a toast with no text at all falls back to the body rather than throwing', () async {
      final toast = FakeToast();
      telemetry.toastSink = toast;

      telemetry('Settings | save | failed').toast();
      await Future<void>.delayed(.zero);

      expect(toast.requests.single.text, equals('Settings | save | failed'));
    });

    test('the toast carries the same event the sinks received', () async {
      // One record per draft, so "Details" behind a toast opens the event the
      // sinks were given.
      final toast = FakeToast();
      telemetry.toastSink = toast;

      telemetry('Db | write | failed').cause(StateError('closed')).description('Ошибка')
        ..warn()
        ..toast(tone: .alert);
      await Future<void>.delayed(.zero);

      expect(identical(toast.requests.single.event, sink.events.single), isTrue);
    });

    test('a channel that throws neither escapes nor stops the others', () async {
      // An uncaught error from the fan-out would reach the app's zone handler
      // as a defect, for a toast whose messenger went away.
      Object? captured;
      final track = FakeTrack();
      telemetry
        ..toastSink = FakeToast(throws: true)
        ..trackSink = track;

      await runZonedGuarded(
        () async {
          telemetry('Paywall | purchase | completed').description('Готово')
            ..info()
            ..toast()
            ..track('purchase_completed');
          await Future<void>.delayed(.zero);
        },
        (error, stackTrace) => captured = error,
      );

      expect(captured, isNull, reason: 'a broken channel is a diagnostic, not an uncaught error');
      expect(track.tracked, hasLength(1), reason: 'the channels after it still ran');
    });

    test('a toast without a log action is still journaled, once, after the cascade', () async {
      final toast = FakeToast();
      telemetry.toastSink = toast;

      telemetry('Settings | save | failed').description('Не сохранилось').toast(tone: .alert);

      expect(sink.events, isEmpty, reason: 'the fallback runs after the cascade, not during it');
      await Future<void>.delayed(.zero);
      final logged = sink.events.single;
      expect(logged.level, equals(LogLevel.info));
      expect(logged.body, equals('Settings | save | failed'));
    });

    test('a cause makes the implicit fallback a warning, never an error', () async {
      // `error` is captured by a reporting sink, so deriving it from an attached
      // exception would file an incident for a forgotten `..warn()`.
      final toast = FakeToast();
      telemetry.toastSink = toast;

      telemetry('Db | write | failed').cause(StateError('closed')).description('Ошибка').toast();

      await Future<void>.delayed(.zero);
      expect(sink.events.single.level, equals(LogLevel.warn));
    });

    test('an explicit log action wins over the fallback, in either cascade order', () async {
      final toast = FakeToast();
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

    test('escalate() forwards whatever the level, and lets the sink decide', () async {
      // The draft used to swallow an escalation at `error` or above, guessing
      // the reporting sink had captured it; that is `captureLevel`'s business.
      final escalation = FakeEscalation();
      telemetry.escalationSink = escalation;

      telemetry('Net | retry | exhausted')
        ..warn()
        ..escalate();
      telemetry('Net | call | failed').cause(StateError('boom'))
        ..error()
        ..escalate();
      await Future<void>.delayed(.zero);

      expect(escalation.escalations.map((e) => e.event.level), equals(<LogLevel>[.warn, .error]));
    });

    test('escalate() sees the level the draft ended on, in either cascade order', () async {
      final escalation = FakeEscalation();
      telemetry.escalationSink = escalation;

      telemetry('Net | call | failed').cause(StateError('boom'))
        ..escalate()
        ..error();
      await Future<void>.delayed(.zero);

      expect(escalation.escalations.single.event.level, equals(LogLevel.error));
    });

    test('escalate(level:) forwards the override without changing the record', () async {
      final escalation = FakeEscalation();
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
      telemetry.escalationSink = CapturingEscalation(traces);

      telemetry('Net | retry | exhausted')
        ..warn()
        ..escalate(stackTrace: StackTrace.fromString('EXPLICIT'));
      await Future<void>.delayed(.zero);

      expect(traces.single?.toString(), equals('EXPLICIT'));
    });

    test('track and notify reach their sinks with their payloads, and leave a journal line', () async {
      final track = FakeTrack();
      final notify = FakeNotify();
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

    test('a channel named after the fan-out still fires, once', () async {
      // A draft held across an `await` and then given another channel: the
      // fan-out re-arms, and the second pass reuses the event it already built.
      final (late, journal) = pipeline();
      final messenger = FakeToast();
      final inbox = FakeNotify();
      late
        ..toastSink = messenger
        ..notifySink = inbox;

      final draft = late('Sync | upload | refused').description('Try again')
        ..warn()
        ..toast();
      await pumpEventQueue();

      draft.notify('inbox.sync');
      await pumpEventQueue();

      expect(messenger.requests, hasLength(1));
      expect(inbox.notified.single.kind, equals('inbox.sync'));
      expect(journal.events, hasLength(1), reason: 'one event, whatever the channels do afterwards');
    });

    test('a payload is copied at the call, not read at the fan-out', () async {
      final track = FakeTrack();
      telemetry.trackSink = track;
      final props = <String, Object?>{'sku': 'pro_yearly'};

      telemetry('Paywall | purchase | completed')
        ..info()
        ..track('purchase_completed', props: props);
      props['sku'] = 'mutated';
      await Future<void>.delayed(.zero);

      expect(track.tracked.single.props, equals({'sku': 'pro_yearly'}));
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
}
