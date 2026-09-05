import 'package:telemetry/src/event.dart';

/// {@template report_throttle}
/// Decides which failures are worth reporting to a crash reporter.
///
/// Two deterministic rules, so unlike random sampling the first occurrence of
/// anything always gets through:
///
/// * a repeat of the same failure is suppressed for [dedupeWindow], so a failure
///   loop costs one report rather than one per iteration;
/// * at most [maxPerMinute] reports leave in any rolling minute.
///
/// Client-side, because a reporter-side limit still spends the device's radio.
/// {@endtemplate}
class ReportThrottle {
  /// {@macro report_throttle}
  ReportThrottle({this.dedupeWindow = const Duration(minutes: 5), this.maxPerMinute = 6});

  /// Elapsed time since this throttle was built.
  ///
  /// A monotonic clock rather than [DateTime.now]: an NTP correction or a user
  /// moving the clock back would otherwise suppress every report for a whole
  /// [dedupeWindow].
  ///
  /// It measures time the process was awake, so after a long sleep a repeat can
  /// be suppressed for longer than [dedupeWindow] in wall time. That is the
  /// right trade against a failure loop, which cannot run while the process
  /// does not.
  final Stopwatch _elapsed = Stopwatch()..start();

  /// The first wall-clock instant a caller supplied, if any. A test passes
  /// absolute times, measured against this origin so one scale is used.
  DateTime? _origin;

  /// Whether the first call supplied a [DateTime]. The stopwatch and an injected
  /// origin cannot be mixed on one instance: mixing them produced negative
  /// durations that silently suppressed everything.
  bool? _injected;

  final Map<String, Duration> _recent = <String, Duration>{};

  final List<Duration> _times = <Duration>[];

  /// How long a repeat of the same failure is suppressed after being reported.
  final Duration dedupeWindow;

  /// Hard ceiling on report volume in any rolling minute.
  final int maxPerMinute;

  /// Whether [event] should be reported now.
  ///
  /// Calling this records the decision, so ask once per event. [now] is a test
  /// seam: supply it for every call or for none.
  bool allow(LogEvent event, {DateTime? now}) {
    final at = _at(now);
    final key = identityOf(event);

    final last = _recent[key];
    if (last != null && at - last < dedupeWindow) return false;

    // Pruned before the ceiling, not after: a sustained storm trips the ceiling
    // on every call, and pruning afterwards let the map grow without bound.
    _recent.removeWhere((_, time) => at - time > dedupeWindow);
    _times.removeWhere((time) => at - time > const Duration(minutes: 1));
    if (_times.length >= maxPerMinute) return false;

    _recent[key] = at;
    _times.add(at);
    return true;
  }

  /// The identity two failures share when they are "the same failure".
  ///
  /// [LogEvent.name] when the call site set one, since it survives a copy edit
  /// to the body. Otherwise the body names the site, truncated to 80 units; the
  /// key only has to be stable, so a split surrogate pair is harmless. The error
  /// type separates causes at the same site.
  static String identityOf(LogEvent event) {
    final site = event.name ?? _prefix(event.body);
    return '$site#${event.error?.runtimeType}';
  }

  // ignore: avoid-substring
  static String _prefix(String body) => body.length <= 80 ? body : body.substring(0, 80);

  Duration _at(DateTime? now) {
    assert(
      _injected == null || _injected == (now != null),
      'ReportThrottle measures on one scale: supply `now` for every call, or for none. '
      'Mixing them compares a stopwatch reading with an offset from the first instant supplied.',
    );
    _injected = now != null;
    if (now == null) return _elapsed.elapsed;
    return now.difference(_origin ??= now);
  }
}
