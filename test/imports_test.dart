// A program on this client must have no way to open the logbook's directory
// and append past the service's checks, so nothing lib/ or bin/ reaches, in
// this package or any other, may be is_logbook. This walks the whole import
// graph from every file there.
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

final _directive = RegExp(
  r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

void main() {
  test('nothing in lib/ or bin/ reaches package:is_logbook', () async {
    final starts = [
      for (final dir in ['lib', 'bin'])
        if (Directory(dir).existsSync())
          for (final entity in Directory(dir).listSync(recursive: true))
            if (entity is File && entity.path.endsWith('.dart'))
              entity.absolute.uri,
    ];
    expect(starts, isNotEmpty);

    final seen = <Uri>{};
    final writerReachedFrom = <String>[];
    final todo = [...starts];
    while (todo.isNotEmpty) {
      final file = todo.removeLast();
      if (!seen.add(file)) continue;
      final source = File.fromUri(file).readAsStringSync();
      for (final match in _directive.allMatches(source)) {
        final target = Uri.parse(match[1]!);
        if (target.isScheme('dart')) continue;
        if (target.isScheme('package')) {
          if (target.pathSegments.first == 'is_logbook') {
            writerReachedFrom.add('$file -> $target');
            continue;
          }
          final resolved = await Isolate.resolvePackageUri(target);
          if (resolved == null) fail('$file: cannot resolve $target');
          todo.add(resolved);
        } else {
          todo.add(file.resolveUri(target));
        }
      }
    }

    expect(writerReachedFrom, isEmpty);
    // The walk really left this package: the format is reached.
    expect(
      seen.any((f) => f.path.contains('is_logbook_format')),
      isTrue,
      reason: '$seen',
    );
  });
}
