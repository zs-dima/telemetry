@TestOn('browser')
library;

// The only thing that compiles `delegate_js.dart` under a real browser. A
// conditional import on `dart.library.js_interop` keeps it out of the VM suite,
// so a typo in an `external` binding would only surface in a web build.
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
      // A browser console prints escapes as text and colours by severity
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

    test('the DevTools destination lands here too', () {
      // `dart:developer`'s `log()` is a no-op in a browser (the dart2js patch
      // has an empty body), so routing `LogOutput.developer` there would drop
      // every line.
      final telemetry = Telemetry(runId: 'run-web')
        ..addSink(ConsoleSink(options: const TelemetryOptions(showTime: false, output: .developer)));

      expect(() => telemetry.i('Web | developer | routed'), returnsNormally);
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
