import 'package:telemetry/src/console/delegate.dart';
import 'package:telemetry/src/console/delegate_js.dart';

/// The DevTools destination, on the web.
///
/// `dart:developer`'s `log()` is a no-op in a browser: dart2js and dart2wasm
/// share a patch with an empty body, so routing there would drop every line.
/// The browser console filters by severity itself, and [name] has nowhere to go.
ConsoleDelegate createConsoleDelegate({String name = 'app'}) => const JsConsoleDelegate();
