/// The `Area | operation | message` grammar, in one place.
///
/// Three modules read it: `LogEvent` for its accessors, `LogDraft` for the
/// convention check, and the console for the line it drops the area from.
/// Scanning with `indexOf` rather than `split` keeps a console line free of the
/// list a split allocates. Every cut lands on an ASCII `|` or at an end, so it
/// can never fall inside a surrogate pair.
// ignore_for_file: avoid-substring
library;

/// First segment of [body], trimmed; empty when it carries no `|`.
///
/// A body without a separator has no subsystem to name: it came from a bridge
/// or a captured `print`, and calling the whole line an area gives a crash
/// reporter one category per message.
String bodyArea(String body) {
  final bar = body.indexOf('|');
  if (bar < 0) return '';
  return body.substring(0, bar).trim();
}

/// Second segment of [body], trimmed; empty when there is none.
String bodyOperation(String body) {
  final first = body.indexOf('|');
  if (first < 0) return '';
  final second = body.indexOf('|', first + 1);
  return (second < 0 ? body.substring(first + 1) : body.substring(first + 1, second)).trim();
}

/// [body] without its message: `Area | operation`, the area alone when there is
/// no second segment, and empty when there is no separator at all.
String bodySite(String body) {
  final operation = bodyOperation(body);
  final area = bodyArea(body);
  return operation.isEmpty ? area : '$area | $operation';
}

/// [body] from after its first `|`, trimmed: `Control | lifecycle | disposed`
/// becomes `lifecycle | disposed`. A body with no `|` is returned whole.
String bodyWithoutArea(String body) {
  final bar = body.indexOf('|');
  if (bar < 0) return body;
  return body.substring(bar + 1).trimLeft();
}

/// Whether [body] carries at least `Area | operation`.
bool isCanonicalBody(String body) => bodyArea(body).isNotEmpty && bodyOperation(body).isNotEmpty;
