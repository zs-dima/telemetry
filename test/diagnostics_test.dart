/// What the package says about its own failures.
///
/// The reports go to `Zone.root.print`, which no zone can intercept, so the
/// suite spawns `test/support/report_diagnostics.dart` and reads its stdout.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/dart_sdk.dart';

void main() {
  test('a failure is reported once per cause, and the process survives all of them', () async {
    final result = await Process.run(
      dartExecutable(),
      <String>['run', 'test/support/report_diagnostics.dart'],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, isZero, reason: 'nothing the package reports may escape: ${result.stderr}');

    final stdout = result.stdout as String;
    // One line each, since a sink failure carries its stack trace on the lines
    // that follow.
    final reports = const LineSplitter().convert(stdout).where((line) => line.startsWith('Telemetry | ')).toList();

    expect(
      reports.where((line) => line.startsWith('Telemetry | sink FakeSink failed')),
      hasLength(2),
      reason: 'once for the first failure, and again once removeSink cleared the mark',
    );
    expect(
      reports.where((line) => line.contains('re-entered 3 deep')),
      hasLength(1),
      reason: 'the depth cap speaks once for the life of the instance',
    );
    expect(reports.where((line) => line.startsWith('Telemetry | flush | FlushableSink failed')), hasLength(1));
    expect(reports, hasLength(4), reason: 'and nothing else was reported');
  });
}
