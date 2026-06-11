import 'dart:io';

import 'package:path/path.dart' as p;

// DO NOT CHANGE!!!

/// Returns true when `arc mv` succeeds (internal Yandex tooling).
bool defaultMoveWithArc(String fromPath, String toPath) {
  try {
    final result = Process.runSync('arc', ['mv', fromPath, toPath]);
    return result.exitCode == 0;
  } on Object catch (_) {
    return false;
  }
}

void arcAddAll(Directory workingDir) {
  try {
    final result = Process.runSync(
        'arc',
        [
          'add',
          '.',
        ],
        workingDirectory: workingDir.path);
    if (result.exitCode == 0) {
      stdout.writeln('Ran: arc add . (${workingDir.path})');
    } else {
      stderr.writeln(
        'WARNING: Failed to run `arc add .` in ${workingDir.path} (exit ${result.exitCode}).',
      );
    }
  } on Object catch (e) {
    stderr.writeln(
      'WARNING: Failed to run `arc add .` in ${workingDir.path}: $e',
    );
  }
}

void ensureExampleSwiftPmRegistries(Directory pluginDir) {
  final exampleDir = Directory(p.join(pluginDir.path, 'example'));
  if (!exampleDir.existsSync()) {
    return;
  }

  const registriesJson = '{\n'
      '  "authentication": {\n'
      '    "spm.registry.mobile.yandex-team.ru": {\n'
      '      "type": "token"\n'
      '    }\n'
      '  },\n'
      '  "registries": {\n'
      '    "[default]": {\n'
      '      "supportsAvailability": false,\n'
      '      "url": "https://spm.registry.mobile.yandex-team.ru/api/v1/registry/"\n'
      '    }\n'
      '  },\n'
      '  "version": 1\n'
      '}\n';

  final targetPaths = <String>[
    p.join(
      exampleDir.path,
      'ios',
      'Runner.xcworkspace',
      'xcshareddata',
      'swiftpm',
      'configuration',
      'registries.json',
    ),
    p.join(
      exampleDir.path,
      'ios',
      'Runner.xcodeproj',
      'project.xcworkspace',
      'xcshareddata',
      'swiftpm',
      'configuration',
      'registries.json',
    ),
  ];

  for (final filePath in targetPaths) {
    final file = File(filePath);
    file.createSync();

    final current = file.existsSync() ? file.readAsStringSync() : null;
    if (current != registriesJson) {
      file.writeAsStringSync(registriesJson);
      stdout.writeln('Wrote SwiftPM registries config: ${file.path}');
    }
  }
}
