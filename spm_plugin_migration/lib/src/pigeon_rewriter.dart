import 'dart:io';

import 'package:path/path.dart' as p;

/// Pigeon rewriter for SPM migration.
class PigeonRewriter {
  const PigeonRewriter();

  /// Rewrites Pigeon output paths from `ios/Classes/...` to SwiftPM-compatible
  /// `ios/<plugin>/Sources/...` locations.
  void updatePigeonInputFiles({
    required Directory pluginDir,
    required String pluginName,
    required bool hasObjcSources,
  }) {
    final candidates = <Directory>[
      Directory(p.join(pluginDir.path, 'pigeons')),
      Directory(p.join(pluginDir.path, 'pigeon')),
    ].where((d) => d.existsSync()).toList(growable: false);

    if (candidates.isEmpty) return;

    final files = <File>[
      for (final dir in candidates)
        ...dir
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
    ];

    if (files.isEmpty) return;

    var changedAny = false;
    for (final f in files) {
      final lines = f.readAsLinesSync();
      var changed = false;

      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final trimmed = line.trimLeft();
        if (trimmed.startsWith('//')) continue;

        final match = RegExp(
          r'''^(\s*)(swiftOut|objcHeaderOut|objcSourceOut)\s*:\s*(['"])([^'"]+)(['"])(.*)$''',
        ).firstMatch(line);
        if (match == null) continue;

        final indent = match.group(1)!;
        final key = match.group(2)!;
        final quote = match.group(3)!;
        final pathValue = match.group(4)!;
        final tailQuote = match.group(5)!;
        final tail = match.group(6)!;

        if (!pathValue.contains('ios/Classes/')) continue;

        final rest = pathValue.split('ios/Classes/')[1];
        String newPath;
        switch (key) {
          case 'swiftOut':
            newPath = 'ios/$pluginName/Sources/$pluginName/$rest';
          case 'objcSourceOut':
            newPath = 'ios/$pluginName/Sources/$pluginName/$rest';
          case 'objcHeaderOut':
            if (!hasObjcSources) {
              // If it's a Swift-only plugin, don't touch objcHeaderOut.
              continue;
            }
            newPath =
                'ios/$pluginName/Sources/$pluginName/include/$pluginName/$rest';
          default:
            continue;
        }

        final newLine = '$indent$key: $quote$newPath$tailQuote$tail';
        if (newLine != line) {
          lines[i] = newLine;
          changed = true;
        }
      }

      if (changed) {
        f.writeAsStringSync(lines.join('\n'));
        changedAny = true;
        print('Updated Pigeon file: ${f.path}');
      }
    }

    if (changedAny) {
      print(
        'Pigeon outputs updated to match iOS SwiftPM layout (see Flutter docs).',
      );
    }
  }
}
