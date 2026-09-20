/// Provokes every failure the package reports about itself, in one process.
///
/// Spawned by `test/diagnostics_test.dart`. These reports go to
/// `Zone.root.print` so that the print capture in `runTelemetry` cannot feed a
/// broken pipeline back into itself; the cost is that no zone can intercept
/// them, and another process's stdout is the only place to read them back.
library;

import 'package:telemetry/telemetry.dart';

import 'fakes.dart';

Future<void> main() async {
  final broken = FakeSink(throws: true);
  Telemetry(runId: 'diag-sink')
    ..addSink(broken)
    ..i('Sink | handle | first')
    // The same sink, still broken: reported once and then silent.
    ..i('Sink | handle | second')
    ..removeSink(broken)
    // Registered again, it is a stranger again, so the next failure speaks.
    ..addSink(broken)
    ..i('Sink | handle | third');

  final deep = Telemetry(runId: 'diag-depth');
  deep
    ..addSink(RecursiveSink(deep))
    ..i('Depth | cap | first')
    // The cap is reported once for the life of the instance.
    ..i('Depth | cap | second');

  final unwritable = Telemetry(runId: 'diag-flush')
    ..addSink(FlushableSink(throws: true))
    ..i('Db | write | queued');
  await unwritable.close();
}
