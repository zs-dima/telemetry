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
  ///
  /// [clock] reads elapsed time since this throttle was built. The default is a
  /// [Stopwatch], monotonic on purpose: with [DateTime.now] an NTP correction or
  /// a user moving the clock back would suppress every report for a whole
  /// [dedupeWindow].
  ///
  /// A stopwatch measures time the process was awake, so after a long sleep a
  /// repeat can be suppressed for longer than [dedupeWindow] in wall time. That
  /// is the right trade against a failure loop, which cannot run while the
  /// process does not.
  ReportThrottle({this.dedupeWindow = const Duration(minutes: 5), this.maxPerMinute = 6, Duration Function()? clock})
    : _clock = clock ?? _stopwatch();

  /// A monotonic reading, one scale for the life of the instance.
  final Duration Function() _clock;

  final Map<String, Duration> _recent = <String, Duration>{};

  final List<Duration> _times = <Duration>[];

  /// How long a repeat of the same failure is suppressed after being reported.
  final Duration dedupeWindow;

  /// Hard ceiling on report volume in any rolling minute.
  final int maxPerMinute;

  /// Whether [event] should be reported now.
  ///
  /// Calling this records the decision, so ask once per event.
  bool allow(LogEvent event) {
    final at = _clock();
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
  /// [LogEvent.name] when the call site set one, so lines that say the same
  /// thing in different words are one failure. Otherwise the body, truncated to
  /// 80 units; a split surrogate pair is harmless, since the key only has to be
  /// stable within a run. The error type separates causes at the same site.
  ///
  /// The body rather than [LogEvent.site]: two outcomes of one operation are two
  /// failures, and merging them would hide the second for a whole window.
  static String identityOf(LogEvent event) {
    final site = event.name ?? _prefix(event.body);
    return '$site#${event.error?.runtimeType}';
  }

  // ignore: avoid-substring
  static String _prefix(String body) => body.length <= 80 ? body : body.substring(0, 80);

  /// The default clock: elapsed time since the throttle was built.
  static Duration Function() _stopwatch() {
    final elapsed = Stopwatch()..start();
    return () => elapsed.elapsed;
  }
}
