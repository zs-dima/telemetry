import 'dart:collection';

import 'package:telemetry/src/event.dart';
import 'package:telemetry/src/level.dart';

/// {@template log_buffer}
/// The last N events of this launch, in memory.
/// {@endtemplate}
///
/// The buffer has two lives, and [markDrained] is the switch between them.
/// Before a journal exists it is the only store, so it keeps everything from
/// [minLevel] up, which covers the boot; a journal sink drains those events when
/// it is built and calls [markDrained].
///
/// After the drain it keeps only [LogLevel.trace], which has no other home: a
/// journal floor is typically `debug` and the console floor `info` in release.
/// Keeping `debug` too would evict the trace ring within a minute of normal
/// traffic.
final class LogBuffer {
  /// {@macro log_buffer}
  LogBuffer({this.limit = 300, this.minLevel = LogLevel.debug, this.maxVerbosity = 6})
    : assert(limit > 0, 'limit must be positive');

  /// How many events are kept.
  final int limit;

  /// The lowest level the buffer keeps before the drain; `debug` by default, to
  /// match a journal's usual floor.
  final LogLevel minLevel;

  /// Highest `trace` tier the buffer keeps (1 = loud, 6 = a whisper).
  ///
  /// The buffer is the only home `trace` has, so without this dial the quietest
  /// tiers are built and stored on every call — and, being the loudest by
  /// volume, they evict the tier someone is actually reading. Lower it and
  /// `Telemetry.isEnabled` starts answering `false` for those tiers, so the
  /// event is never built at all.
  final int maxVerbosity;

  /// How many events are buffered.
  int get length => _events.length;

  /// The buffered events, oldest first.
  Iterable<LogEvent> get events => _events;

  final Queue<LogEvent> _events = Queue<LogEvent>();

  bool _drained = false;

  /// Whether the journal has taken over.
  bool get drained => _drained;

  /// Whether the buffer keeps events of [level] at [verbosity] on its own
  /// account.
  ///
  /// `trace` up to [maxVerbosity] always, since nothing else stores it and
  /// `Telemetry.isEnabled` must say so even when no sink wants it; plus
  /// everything from [minLevel] up, until [markDrained].
  bool guarantees(LogLevel level, [int verbosity = 0]) {
    if (level == .trace) return verbosity <= maxVerbosity;
    return !_drained && level >= minLevel;
  }

  /// The journal has adopted what was buffered; keep only what it cannot hold.
  ///
  /// Called by the code that builds the journal sink, right after draining it.
  /// Drops the boot's `debug` and `info` lines and leaves the `trace` ring.
  void markDrained() {
    _drained = true;
    _events.removeWhere((event) => event.level != .trace);
  }

  /// The journal is gone; the buffer keeps the boot again.
  ///
  /// The mirror of [markDrained], called when the journal sink is torn down: a
  /// retried boot needs a keeper for its own lines until a journal opens again.
  void undrain() => _drained = false;

  /// Adds [event] when the buffer is still the one keeping it.
  void add(LogEvent event) {
    if (!guarantees(event.level, event.verbosity)) return;
    if (_events.length >= limit) _events.removeFirst();
    _events.add(event);
  }

  /// Empties the buffer.
  void clear() => _events.clear();
}
