@Tags(<String>['analyzer'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The unused-draft guard is the analyzer, so this is the test for it.
///
/// A runtime guard cannot tell "never used" from "not used yet", since a draft
/// held across an `await` is the normal way to carry context. `@useResult` is
/// checked where the code is written but cannot prove itself from inside the
/// library, so this runs the analyzer over a fixture excluded from the
/// package's own analysis.
void main() {
  test(
    'a dropped builder is an unused_result, and a closed draft is not',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        <String>['analyze', '--format=json', 'test/analyzer/fixture/dropped_draft.dart'],
        workingDirectory: Directory.current.path,
      );

      final decoded = jsonDecode(result.stdout.toString()) as Map<String, Object?>;
      final diagnostics = (decoded['diagnostics']! as List<Object?>).cast<Map<String, Object?>>();
      final unused = diagnostics.where((diagnostic) => diagnostic['code'] == 'unused_result').toList();

      expect(
        unused,
        hasLength(6),
        reason:
            'one per dropped builder in `dropped()`, and none in `kept()`. '
            'Saw: ${diagnostics.map((diagnostic) => diagnostic['code']).toList()}',
      );
      // `dropped()` is the first function in the fixture; `kept()` follows it.
      final keptStarts = _lineOf(RegExp(r'^void kept\(\)'));
      expect(
        unused.map(_line),
        everyElement(lessThan(keptStarts)),
        reason: 'a draft closed by an action is never reported',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// The 1-based line a diagnostic points at.
int _line(Map<String, Object?> diagnostic) {
  final location = diagnostic['location']! as Map<String, Object?>;
  final range = location['range']! as Map<String, Object?>;
  final start = range['start']! as Map<String, Object?>;
  return start['line']! as int;
}

/// The 1-based line of the first fixture line matching [pattern].
int _lineOf(RegExp pattern) {
  final lines = File('test/analyzer/fixture/dropped_draft.dart').readAsLinesSync();
  for (final (index, line) in lines.indexed) {
    if (pattern.hasMatch(line)) return index + 1;
  }
  throw StateError('the fixture no longer contains ${pattern.pattern}');
}
