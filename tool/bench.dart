// A benchmark, not a test: it prints numbers and asserts nothing, because a
// wall-clock threshold in CI is flaky.
//
// Run it compiled, with asserts off, which is what `make bench` does:
//
//   dart compile exe -o build/bench tool/bench.dart && build/bench
//
// Under `dart run` the convention checks are live and the figures are two to
// three times worse.
//
// ignore_for_file: avoid_print

import 'package:telemetry/telemetry.dart';

/// The signature every case below has. Named, because the lint asks.
typedef VoidCallback = void Function();

/// Swallows everything, so what is measured is the pipeline and not a console.
final class _NullSink implements TelemetrySink {
  const _NullSink();

  @override
  bool enabled(LogLevel level, int verbosity) => level >= .info;

  @override
  void handle(LogEvent event) {}
}

void main() {
  const rounds = 200000;

  // Nothing wants `debug`: no sink admits it, the buffer has been drained, and
  // the trace ring is off. This is the path a release build spends its time on.
  final quiet = Telemetry(runId: 'bench', buffer: LogBuffer(traceLimit: 0))..addSink(const _NullSink());
  quiet.buffer.markDrained();

  final live = Telemetry(runId: 'bench', buffer: LogBuffer(traceLimit: 0))..addSink(const _NullSink());
  live.buffer.markDrained();

  _report('disabled, shortcut   log.d(...)', rounds, () => quiet.d('Bench | disabled | shortcut'));
  _report(
    'disabled, fluent     log(...).meta(...).debug()',
    rounds,
    () => quiet('Bench | disabled | fluent').meta(const <String, Object?>{'bench.round.index': 1}).debug(),
  );
  _report('enabled,  shortcut   log.i(...)', rounds, () => live.i('Bench | enabled | shortcut'));
  _report(
    'enabled,  attributes log.i(..., meta: ...)',
    rounds,
    () => live.i('Bench | enabled | attributes', meta: const <String, Object?>{'bench.round.index': 1}),
  );
  // Entered once, around the whole loop, so the figure is the per-line cost of
  // the zone lookup and the merge rather than `runZoned` itself.
  live.scoped(
    const <String, Object?>{'bench.scope.name': 'outer'},
    () => _report('enabled,  inside a scope', rounds, () => live.i('Bench | scoped | line')),
  );
}

void _report(String what, int rounds, VoidCallback body) {
  // One warm-up pass, so the figure is steady-state rather than the JIT warming.
  for (var round = 0; round < rounds ~/ 10; round++) {
    body();
  }
  final watch = Stopwatch()..start();
  for (var round = 0; round < rounds; round++) {
    body();
  }
  watch.stop();
  final perOp = watch.elapsedMicroseconds * 1000 / rounds;
  print('${what.padRight(44)} ${perOp.toStringAsFixed(0).padLeft(6)} ns/op');
}
