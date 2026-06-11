import 'dart:io';

import '../spm_plugin_migration.dart';

/// Walks source files under a root directory and inserts a `TODO(spm-migration)`
/// comment above every line that performs a CocoaPods named resource-bundle
/// lookup (declared via `s.resource_bundles` in the podspec).
///
/// Works on both Swift (`.swift`) and ObjC-family (`.m`, `.mm`, `.h`, `.hh`)
/// sources — the `//`-style comment is valid in both languages.
class NamedBundleAnnotator {
  final FileSystemUtils fs;
  const NamedBundleAnnotator(this.fs);

  static const _todoLine =
      '// TODO(spm-migration): CocoaPods resource bundle name lookup detected. '
      'Under SwiftPM resources are loaded from Bundle.module, not from a named *.bundle.';

  /// Annotates every line under [sourceRoot] that references one of
  /// [bundleNames] via a `Bundle`/`NSBundle` API. Idempotent.
  void annotate({
    required Directory sourceRoot,
    required List<String> bundleNames,
  }) {
    if (!sourceRoot.existsSync() || bundleNames.isEmpty) return;

    var annotated = 0;
    for (final file in fs.listFilesRecursively(sourceRoot)) {
      if (!_isAnnotatableSource(file.path)) continue;

      final originalContent = file.readAsStringSync();
      final lines = file.readAsLinesSync();
      final out = <String>[];
      var changed = false;
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (isNamedResourceBundleLookupLine(line, bundleNames)) {
          final hasTodoAbove = out.isNotEmpty &&
              out.last.contains('TODO(spm-migration):') &&
              out.last.contains('CocoaPods resource bundle name');
          if (!hasTodoAbove) {
            // Match the indentation of the annotated line so the comment
            // doesn't break visual flow inside indented scopes.
            final indent = RegExp(r'^[ \t]*').firstMatch(line)?.group(0) ?? '';
            out.add('$indent$_todoLine');
            changed = true;
            annotated += 1;
          }
          stderr.writeln(
            'WARNING: Named CocoaPods resource bundle lookup found in ${file.path}:${i + 1}. '
            'Added TODO(spm-migration) comment.',
          );
        }
        out.add(line);
      }
      if (changed) {
        // readAsLinesSync drops the trailing newline; restore it when the
        // original file had one, to avoid POSIX-style "no newline at EOF".
        var result = out.join('\n');
        if (originalContent.endsWith('\n')) result += '\n';
        file.writeAsStringSync(result);
      }
    }

    if (annotated > 0) {
      stderr.writeln(
        'WARNING: Added TODO(spm-migration) comments for $annotated named bundle lookup location(s).',
      );
    }
  }

  static bool _isAnnotatableSource(String filePath) {
    final lower = filePath.toLowerCase();
    return lower.endsWith('.swift') ||
        lower.endsWith('.m') ||
        lower.endsWith('.mm') ||
        lower.endsWith('.h') ||
        lower.endsWith('.hh');
  }
}
