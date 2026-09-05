/// The fakes every telemetry suite shares.
///
/// One library rather than a copy per file, so the fakes cannot drift apart.
library;

import 'package:meta/meta.dart';
import 'package:telemetry/telemetry.dart';

/// Records everything it is given.
final class FakeSink implements TelemetrySink {
  FakeSink({this.minLevel = LogLevel.trace, this.throws = false});

  final LogLevel minLevel;
  final bool throws;
  final List<LogEvent> events = <LogEvent>[];

  /// How many times the pipeline asked whether this sink wants a level.
  int asked = 0;

  @override
  bool enabled(LogLevel level, int verbosity) {
    asked++;
    return level >= minLevel;
  }

  @override
  void handle(LogEvent event) {
    if (throws) throw StateError('sink is broken');
    events.add(event);
  }
}

final class FakeToast implements ToastSink {
  FakeToast({this.throws = false});

  final bool throws;
  final List<ToastRequest> requests = <ToastRequest>[];

  @override
  void toast(ToastRequest request) {
    if (throws) throw StateError('the messenger is gone');
    requests.add(request);
  }
}

final class FakeEscalation implements EscalationSink {
  final List<({LogEvent event, LogLevel? level})> escalations = <({LogEvent event, LogLevel? level})>[];

  @override
  void escalate(LogEvent event, {LogLevel? level, StackTrace? stackTrace}) =>
      escalations.add((event: event, level: level));
}

final class FakeTrack implements TrackSink {
  final List<({String name, Map<String, Object?> props})> tracked = <({String name, Map<String, Object?> props})>[];

  @override
  void track(String name, Map<String, Object?> props, LogEvent event) => tracked.add((name: name, props: props));
}

final class FakeNotify implements NotifySink {
  final List<({Object kind, Map<String, Object?> args})> notified = <({Object kind, Map<String, Object?> args})>[];

  @override
  void notify(Object kind, Map<String, Object?> args, LogEvent event) => notified.add((kind: kind, args: args));
}

/// A sink that holds what it is given until it is flushed.
final class FlushableSink implements TelemetrySink, Flushable {
  FlushableSink({this.throws = false});

  final bool throws;
  final List<LogEvent> pending = <LogEvent>[];
  final List<LogEvent> written = <LogEvent>[];

  @override
  bool enabled(LogLevel level, int verbosity) => true;

  @override
  void handle(LogEvent event) => pending.add(event);

  @override
  Future<void> flush() async {
    if (throws) throw StateError('cannot write');
    written.addAll(pending);
    pending.clear();
  }
}

/// A toast destination that also holds work, for the flush fan-out.
final class FlushableToast implements ToastSink, Flushable {
  int flushes = 0;

  @override
  void toast(ToastRequest request) {}

  @override
  Future<void> flush() async => flushes++;
}

/// Logs from inside `handle`, which is a sink bug; the pipeline must survive it.
final class RecursiveSink implements TelemetrySink {
  RecursiveSink(this.telemetry);

  final Telemetry telemetry;
  int handled = 0;

  @override
  bool enabled(LogLevel level, int verbosity) => true;

  @override
  void handle(LogEvent event) {
    handled++;
    telemetry.i('Sink | handle | echo');
  }
}

/// Every instance is equal to every other. `removeSink` and `flush` must still
/// tell two of them apart.
@immutable
final class EqualSink implements TelemetrySink {
  const EqualSink(this.events);

  final List<LogEvent> events;

  @override
  int get hashCode => 0;

  @override
  bool enabled(LogLevel level, int verbosity) => true;

  @override
  void handle(LogEvent event) => events.add(event);

  @override
  bool operator ==(Object other) => other is EqualSink;
}

/// The pipeline a case runs against: a fresh facade and its recording sink.
(Telemetry, FakeSink) pipeline() {
  final sink = FakeSink();
  return (Telemetry(runId: 'run-1')..addSink(sink), sink);
}

/// A body for a scope that is never entered.
void noop() {}

/// A body that is not a `String`, to prove a lazy builder may return one.
final class Body {
  const Body();

  @override
  String toString() => 'Lazy | body | object';
}

/// Registers another sink from inside `handle`, which the dispatcher must
/// tolerate.
final class MutatingSink implements TelemetrySink {
  MutatingSink(this.telemetry, this.late);

  bool _added = false;

  final Telemetry telemetry;
  final TelemetrySink late;

  @override
  bool enabled(LogLevel level, int verbosity) => true;

  @override
  void handle(LogEvent event) {
    if (_added) return;
    _added = true;
    telemetry.addSink(late);
  }
}

final class RecordingDelegate implements ConsoleDelegate {
  const RecordingDelegate(this.lines);
  final List<String> lines;

  @override
  void write(LogLevel level, String line) => lines.add(line);
}

final class CapturingEscalation implements EscalationSink {
  const CapturingEscalation(this.traces);
  final List<StackTrace?> traces;

  @override
  void escalate(LogEvent event, {LogLevel? level, StackTrace? stackTrace}) => traces.add(stackTrace);
}
