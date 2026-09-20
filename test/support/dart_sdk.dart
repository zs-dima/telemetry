/// Finding the `dart` a suite can spawn.
library;

import 'dart:io';

/// The SDK's `dart`, which is NOT `Platform.resolvedExecutable` under
/// `flutter test`: there the runner is `flutter_tester`, and
/// `flutter_tester analyze` never returns, so a test that spawns it spends its
/// whole timeout waiting (2026-09-20).
String dartExecutable() {
  final resolved = Platform.resolvedExecutable;
  if (RegExp(r'[\\/]dart(\.exe)?$').hasMatch(resolved)) return resolved;
  // Forward slashes: `dart:io` takes them on Windows too.
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    final sdk = '$flutterRoot/bin/cache/dart-sdk/bin/dart';
    for (final candidate in <String>[sdk, '$sdk.exe']) {
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return 'dart';
}
