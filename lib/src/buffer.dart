import 'dart:collection';

import 'package:telemetry/src/event.dart';
import 'package:telemetry/src/level.dart';

/// {@template log_buffer}
/// The last events of this launch, in memory.
/// {@endtemplate}
///
/// Two rings, because the two kinds of line have opposite lifetimes.
///
/// The first keeps everything from [minLevel] up, [limit] deep. Before a journal
/// exists it is the only store, which covers the boot. A journal sink drains it
/// and calls [markDrained], after which it keeps nothing.
///
/// The second keeps `trace`, [traceLimit] deep, for the whole launch. Trace has
/// no other home, a journal floor being `debug` and a release console floor
/// `info`, and it is also the loudest thing in the process. In one shared ring a
/// second of tracing evicted the boot before the journal could adopt it.
final class LogBuffer {
  /// {@macro log_buffer}
  LogBuffer({this.limit = 300, this.minLevel = LogLevel.debug, this.traceLimit = 100, this.maxVerbosity = 6})
    : assert(limit >= 0, 'limit cannot be negative'),
      assert(traceLimit >= 0, 'traceLimit cannot be negative');

  final Queue<LogEvent> _traces = Queue<LogEvent>();

  /// How many events from [minLevel] up are kept before the drain. Zero keeps
  /// none, as [traceLimit] does for the trace ring.
  final int limit;

  /// The lowest level the first ring keeps; `debug` by default, to match a
  /// journal's usual floor.
  final LogLevel minLevel;

  /// How many `trace` lines are kept, for the whole launch. Zero refuses trace
  /// altogether, so `Telemetry.isEnabled` answers `false` when no sink wants it
  /// either and the event is never built.
  final int traceLimit;

  /// Highest `trace` tier kept (1 = loud, 6 = a whisper).
  ///
  /// The noise dial. Below it an event is not built at all, rather than built
  /// and dropped.
  final int maxVerbosity;

  /// How many events are buffered, in both rings.
  int get length => _events.length + _traces.length;

  final Queue<LogEvent> _events = Queue<LogEvent>();

  /// The buffered events, oldest first, the two rings merged by
  /// [LogEvent.sequence] so a reader sees the order they happened in.
  ///
  /// A snapshot: a journal draining this list logs while it drains, and an
  /// iteration over the live rings would fail halfway.
  List<LogEvent> get events {
    if (_traces.isEmpty) return List<LogEvent>.of(_events);
    if (_events.isEmpty) return List<LogEvent>.of(_traces);
    return _merged();
  }

  bool _drained = false;

  /// Whether the journal has taken over.
  bool get drained => _drained;

  /// Whether the buffer keeps events of [level] at [verbosity] on its own
  /// account.
  ///
  /// `trace` up to [maxVerbosity] while [traceLimit] leaves room for it, since
  /// nothing else stores it, plus everything from [minLevel] up until
  /// [markDrained]. A zero [limit] refuses the first ring the way a zero
  /// [traceLimit] refuses the second.
  bool guarantees(LogLevel level, [int verbosity = 0]) {
    if (level == .trace) return traceLimit > 0 && verbosity <= maxVerbosity;
    return limit > 0 && !_drained && level >= minLevel;
  }

  /// The journal has adopted what was buffered; the first ring stands down.
  ///
  /// Called by the code that builds the journal sink, right after draining it.
  /// The trace ring is untouched, since the journal does not store it.
  ///
  /// The hand-over is synchronous: read [events], call this, register the sink,
  /// then write the snapshot. An `await` between the first two steps loses what
  /// was logged in between, since this clears the ring.
  void markDrained() {
    _drained = true;
    _events.clear();
  }

  /// The journal is gone; the buffer keeps the boot again.
  ///
  /// The mirror of [markDrained], called when the journal sink is torn down. A
  /// retried boot needs a keeper until a journal opens again.
  void undrain() => _drained = false;

  /// Adds [event] to the ring that keeps it, if either does.
  void add(LogEvent event) {
    if (!guarantees(event.level, event.verbosity)) return;
    if (event.level == .trace) {
      if (_traces.length >= traceLimit) _traces.removeFirst();
      _traces.add(event);
      return;
    }
    if (_events.length >= limit) _events.removeFirst();
    _events.add(event);
  }

  /// Empties both rings.
  void clear() {
    _events.clear();
    _traces.clear();
  }

  /// Whether [left] belongs before [right]: by sequence, then by timestamp.
  ///
  /// The timestamp settles the tie a bridge creates, since a hand-built event
  /// that was never given `nextSequence()` carries the default zero.
  static bool _before(LogEvent left, LogEvent right) =>
      left.sequence == right.sequence ? !left.timestamp.isAfter(right.timestamp) : left.sequence < right.sequence;

  /// The two rings interleaved. Each is already in sequence order, so this is a
  /// merge rather than a sort.
  List<LogEvent> _merged() {
    final merged = <LogEvent>[];
    final left = _events.iterator..moveNext();
    final right = _traces.iterator..moveNext();
    var hasLeft = true;
    var hasRight = true;
    while (hasLeft && hasRight) {
      if (_before(left.current, right.current)) {
        merged.add(left.current);
        hasLeft = left.moveNext();
      } else {
        merged.add(right.current);
        hasRight = right.moveNext();
      }
    }
    while (hasLeft) {
      merged.add(left.current);
      hasLeft = left.moveNext();
    }
    while (hasRight) {
      merged.add(right.current);
      hasRight = right.moveNext();
    }
    return merged;
  }
}
