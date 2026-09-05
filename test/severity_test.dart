import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

/// The instant every event here carries.
final DateTime _at = DateTime.utc(2026, 9, 5, 14, 3, 7);

LogEvent _event(LogLevel level, {int verbosity = 0, String body = 'Rpc | call | ok'}) =>
    .new(level: level, body: body, verbosity: verbosity, timestamp: _at, runId: 'run');

void main() {
  group('the OpenTelemetry severity range', () {
    test('a level reads back from any number in its range', () {
      // Four numbers per level, so a row written by another exporter, or from
      // `LogEvent.severityNumber`, comes back as the level it was.
      const byNumber = <int, LogLevel>{
        1: .trace,
        4: .trace,
        5: .debug,
        8: .debug,
        12: .info,
        13: .warn,
        20: .error,
        21: .fatal,
        24: .fatal,
      };
      byNumber.forEach((number, level) => expect(LogLevel.fromValue(number), equals(level), reason: '$number'));
    });

    test('a name still works, and anything else degrades to info', () {
      expect(LogLevel.fromValue('warn'), equals(LogLevel.warn));
      expect(LogLevel.fromValue(LogLevel.fatal), equals(LogLevel.fatal));
      // 900 is WARNING on the package:logging scale and nothing on
      // OpenTelemetry's; such rows are migrated by the storage layer.
      for (final value in <Object?>[0, 25, 900, 'shout', null]) {
        expect(LogLevel.fromValue(value), equals(LogLevel.info), reason: '$value');
      }
    });

    test('a trace line spends the range on its tier', () {
      // The spec asks a source with several severities in one range to number
      // them by importance: tier 1 is the loudest trace there is, tier 6 the
      // quietest, and an untiered line the loudest of all.
      const byTier = <int, int>{0: 4, 1: 4, 2: 3, 3: 2, 4: 1, 5: 1, 6: 1};
      for (final MapEntry(key: dial, value: expected) in byTier.entries) {
        expect(_event(.trace, verbosity: dial).severityNumber, equals(expected), reason: 'tier $dial');
      }
    });

    test('every other level keeps the number of its own range', () {
      for (final level in LogLevel.values.where((candidate) => candidate != .trace)) {
        expect(_event(level).severityNumber, equals(level.severityNumber), reason: level.name);
      }
    });

    test('a stored severity number round-trips to the level it came from', () {
      for (final level in LogLevel.values) {
        for (var tier = 0; tier <= 6; tier++) {
          final record = _event(level, verbosity: level == .trace ? tier : 0);
          expect(LogLevel.fromValue(record.severityNumber), equals(level), reason: '${level.name} at tier $tier');
        }
      }
    });
  });

  group('site', () {
    test('is the body without its message', () {
      // The message segment is the one a call site writes freely, so it is where
      // a user-authored label or an interpolated value ends up.
      expect(_event(.info).site, equals('Rpc | call'));
      expect(_event(.info, body: 'Rpc | call').site, equals('Rpc | call'));
      expect(_event(.info, body: 'Rpc | call | a | b').site, equals('Rpc | call'));
    });

    test('falls back to the area when there is no operation', () {
      expect(_event(.info, body: 'Pairing | handshake').site, equals('Pairing | handshake'));
    });

    test('is empty when the body carries no separator at all', () {
      // A bridged line or a captured `print`: there is no subsystem in it, and
      // a breadcrumb category made of the whole message is one category each.
      expect(_event(.info, body: 'plain message').site, isEmpty);
    });
  });
}
