@TestOn('browser')
library;

// The only thing that compiles `delegate_js.dart` under a real browser. It is
// selected by a conditional import on `dart.library.js_interop`, so the VM suite
// never sees it: a typo in one of the `external void warn(JSAny?)` bindings, or
// a level the switch forgot, would ship to the web build and be discovered by a
// developer looking at an empty console.
//
//   make test-web    # dart test -p chrome test/web

import 'package:telemetry/src/console/delegate_js.dart' as js_delegate;
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  group('the browser console delegate', () {
    test('is what the pipeline picks on the web', () {
      expect(js_delegate.createConsoleDelegate(), isA<js_delegate.JsConsoleDelegate>());
    });

    test('never claims ANSI support', () {
      // A browser console prints the escapes as text and colours by severity
      // itself, from the method the level picked.
      expect(js_delegate.supportsAnsi(), isFalse);
    });

    test('writes at every level without throwing', () {
      // The extension-type bindings over `window.console` are `external`, so a
      // wrong name is a runtime failure and nothing else catches it.
      const delegate = js_delegate.JsConsoleDelegate();
      for (final level in LogLevel.values) {
        expect(
          () => delegate.write(level, '[${level.prefix}] Web | console | ${level.name}'),
          returnsNormally,
        );
      }
    });

    test('the pipeline renders through it with no escapes', () {
      final telemetry = Telemetry(runId: 'run-web')
        ..addSink(ConsoleSink(options: const TelemetryOptions(showTime: false)));

      void writeEveryChannel() => telemetry
        ..i('Web | console | info')
        ..w('Web | console | warn')
        ..e('Web | console | error', error: StateError('boom'));

      expect(writeEveryChannel, returnsNormally);
    });
  });
}
