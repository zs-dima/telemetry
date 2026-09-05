import 'package:telemetry/src/event.dart';

/// {@template report_throttle}
/// Decides which failures are worth reporting to a crash reporter.
///
/// Two deterministic rules; unlike random sampling, the first occurrence of
/// anything always gets through:
///
/// * a repeat of the same failure is suppressed for [dedupeWindow], so a failure
///   loop costs one report rather than one per iteration;
/// * at most [maxPerMinute] reports leave in any rolling minute, whatever the
///   mix of failures.
///
/// Client-side, because a reporter-side limit still spends the device's radio on
/// every discarded event.
/// {@endtemplate}
class ReportThrottle {
  /// {@macro report_throttle}
  ReportThrottle({this.dedupeWindow = const Duration(minutes: 5), this.maxPerMinute = 6});

  /// Elapsed time since this throttle was built.
  ///
  /// A monotonic clock, not [DateTime.now]: an NTP correction or a user moving
  /// the device clock backwards would otherwise suppress every report for a
  /// whole [dedupeWindow], and the moment a device's clock is wrong is not a
  /// good moment to stop reporting.
  final Stopwatch _elapsed = Stopwatch()..start();

  /// The first wall-clock instant a caller supplied, if any. Tests pass absolute
  /// times; they are measured against this origin so the arithmetic below stays
  /// on one scale.
  DateTime? _origin;

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

    _times.removeWhere((time) => at - time > const Duration(minutes: 1));
    if (_times.length >= maxPerMinute) return false;

    _recent
      ..[key] = at
      // Entries older than the window are dead weight; the map cannot grow.
      ..removeWhere((_, time) => at - time > dedupeWindow);
    _times.add(at);
    return true;
  }

  /// The identity two failures share when they are "the same failure".
  ///
  /// [LogEvent.name] when the call site set one, since that is the identifier
  /// meant to outlive a copy edit to the body. Otherwise the body names the site
  /// (`Area | operation`), truncated to 80 units; the key only needs to be
  /// stable, so a split surrogate pair is harmless. The error type separates
  /// causes at the same site.
  static String identityOf(LogEvent event) {
    final site = event.name ?? _prefix(event.body);
    return '$site#${event.error?.runtimeType}';
  }

  // ignore: avoid-substring
  static String _prefix(String body) => body.length <= 80 ? body : body.substring(0, 80);

  Duration _at(DateTime? now) {
    if (now == null) return _elapsed.elapsed;
    return now.difference(_origin ??= now);
  }
}
