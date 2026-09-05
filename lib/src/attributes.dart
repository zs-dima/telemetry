/// The naming conventions this package checks in debug, and the one helper that
/// resolves a lazy attribute value.
///
/// Shared by `LogDraft`, which checks what a call site passes, and by
/// `Telemetry`, which checks the launch resource. The three patterns are
/// exported so an application's source-scanning test can assert the same rule
/// the runtime does, rather than a copy of it.
library;

/// An OpenTelemetry attribute key: lowercase, dot-namespaced, snake_case within
/// a segment, at least two segments (`app.pairing.attempt`).
final RegExp kAttributeKey = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$');

/// An event name: the same shape, for the same reason. It is an identity a
/// query groups on, as in `pairing.handshake.refused`.
final RegExp kEventName = kAttributeKey;

/// A product-analytics event name: one lowercase snake_case word, as in
/// `purchase_completed`. Not dotted, because Firebase and PostHog treat the
/// whole string as one opaque name out of a bounded set.
final RegExp kTrackName = RegExp(r'^[a-z][a-z0-9_]*$');

/// The first key of [attributes] that is not [kAttributeKey], or null when they
/// all are. Debug only; the caller wraps it in an `assert`.
String? firstInvalidKey(Map<String, Object?> attributes) {
  for (final key in attributes.keys) {
    if (!kAttributeKey.hasMatch(key)) return key;
  }
  return null;
}

/// [attributes] with every `Object Function()` value called once.
///
/// `slog`'s `LogValuer`: an expensive attribute is written as a closure and paid
/// for only when the event is built. A map with no closure is returned as it is,
/// which is the usual case.
Map<String, Object?> resolveAttributes(Map<String, Object?> attributes) {
  Map<String, Object?>? resolved;
  for (final MapEntry(:key, :value) in attributes.entries) {
    if (value is Object Function()) (resolved ??= Map<String, Object?>.of(attributes))[key] = value();
  }
  return resolved ?? attributes;
}
