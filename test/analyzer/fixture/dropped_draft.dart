// The fixture the analyzer guard test runs `dart analyze` over. Excluded from
// this package's own analysis (see `analysis_options.yaml`), because half of it
// is meant to fail.
//
// ignore_for_file: avoid_print
import 'package:telemetry/telemetry.dart';

final Telemetry log = Telemetry(runId: 'fixture');

/// Every builder here is dropped: each line must be an `unused_result`.
void dropped() {
  log('A | b | c');
  log('A | b | c').meta(<String, Object?>{'app.x.y': 1});
  log('A | b | c').cause(StateError('x'));
  log('A | b | c').description('x');
  log('A | b | c').name('a.b.c');
  log('A | b | c').verbosity(2);
}

/// Every draft here is closed by an action: none of it may be reported.
void kept() {
  log('A | b | c').info();
  log('A | b | c').meta(<String, Object?>{'app.x.y': 1}).warn();
  log('A | b | c').cause(StateError('x')).description('x')
    ..error()
    ..toast(text: 'x');
  final draft = log('A | b | c').name('a.b.c');
  draft.info();
  log.i('A | b | c');
}
