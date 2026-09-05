/// The delegate used when neither `dart:io` nor `dart:js_interop` is available.
///
/// A separate library rather than a second import of the print delegate: a
/// conditional import needs a default URI distinct from its named imports.
library;

export 'package:telemetry/src/console/delegate_print.dart'
    show PrintConsoleDelegate, createConsoleDelegate, wrapForPrint;
