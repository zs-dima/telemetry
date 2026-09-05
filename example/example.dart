// ignore_for_file: avoid_print

import 'package:telemetry/telemetry.dart';

/// Run it: `dart run example/example.dart`
///
/// `make compile-check` also builds it with every compiler the package supports:
///
/// ```sh
/// dart compile js   -o build/example.js   example/example.dart
/// dart compile wasm -o build/example.wasm example/example.dart
/// ```
void main() {
  final log = Telemetry(runId: 'example')
    // The bare letter for the level, in colour where a terminal renders it, and
    // one glyph per subsystem after it, with the area word dropped. None of this
    // reaches a journal or a crash reporter.
    ..addSink(
      ConsoleSink(
        options: const TelemetryOptions(
          levelTag: .letter,
          icon: AreaIcons(<String, String>{'App': '🚀', 'Sync': '🔄'}),
        ),
      ),
    )
    ..toastSink = const _PrintToasts()
    // What identifies this launch. It travels on every event as
    // `LogEvent.resource` and reaches a sink through `event.attributes`, but a
    // console line shows only what varied.
    ..resource = <String, Object?>{
      'service.name': 'example',
      'service.version': '1.0.0',
      'deployment.environment.name': 'development',
    }
    // One line.
    ..i('App | start | ready');

  // Context first, then independent channel actions. The body is the grouping key, everything
  // variable is an attribute, and `name` is the identity that survives a copy edit.
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

  // A sink stores the flat projection: the launch, the scope and the call site,
  // plus the identity and the exception.
  print('stored: ${log.buffer.events.last.attributes}');
}

final class _PrintToasts implements ToastSink {
  const _PrintToasts();

  @override
  void toast(ToastRequest request) => print('toast: ${request.text}');
}
