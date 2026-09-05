// ignore_for_file: avoid_print

import 'package:telemetry/telemetry.dart';

/// Run it: `dart run example/example.dart`
///
/// It also has to survive every compiler the package claims to support, which is
/// what `make compile-check` does:
///
/// ```sh
/// dart compile js   -o build/example.js   example/example.dart
/// dart compile wasm -o build/example.wasm example/example.dart
/// ```
void main() {
  final log = Telemetry(runId: 'example')
    ..addSink(ConsoleSink())
    ..toastSink = const _PrintToasts()
    // What identifies this launch, on every event from here on.
    ..resource = <String, Object?>{'app.version': '1.0.0', 'app.environment': 'example'}
    // One line.
    ..i('App | start | ready');

  // Context first, then independent channel actions. The body is the grouping key; everything
  // variable goes into attributes, and `name` is the identity that outlives a copy edit.
  log('Sync | upload | refused')
      .name('sync.upload.refused')
      .meta(<String, Object?>{'http.status_code': 429, 'sync.attempt': 3})
      .cause(StateError('rate limited'))
      .description('The server is busy, try again in a minute')
    ..warn()
    ..toast(tone: .alert);

  // A scope names the context once, for everything logged inside it.
  log.scoped(<String, Object?>{'rpc.path': '/sync.v1/Upload'}, () {
    log
      ..d('Sync | upload | retrying')
      ..i('Sync | upload | done');
  });
}

final class _PrintToasts implements ToastSink {
  const _PrintToasts();

  @override
  void toast(ToastRequest request) => print('toast: ${request.text}');
}
