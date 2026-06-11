import 'dart:io';

import 'package:path/path.dart' as p;

import '../spm_plugin_migration.dart';

bool _swiftFileHasStandaloneImport(String content, String moduleName) {
  return RegExp(
    r'^\s*import\s+' + RegExp.escape(moduleName) + r'\s*$',
    multiLine: true,
  ).hasMatch(content);
}

/// Applies [missingSwiftImports] rules: inserts `Foundation`, `UIKit`, `Flutter`
/// after leading blank lines and `//` comments, in canonical order, skipping
/// modules already imported.
String applyMissingFrameworkImportsToContent(String content) {
  final needed = missingSwiftImports(content);
  if (needed.isEmpty) return content;

  final lines = content.split('\n');

  var insertAt = _indexAfterLeadingCommentsAndBlankLines(lines);

  const importOrder = ['Foundation', 'UIKit', 'Flutter'];
  for (final importName in importOrder) {
    if (!needed.contains(importName)) {
      if (insertAt < lines.length &&
          lines[insertAt].trim() == 'import $importName') {
        insertAt += 1;
      }
      continue;
    }
    lines.insert(insertAt, 'import $importName');
    insertAt += 1;
  }

  return lines.join('\n');
}

/// Same leading-comment skip as import insertion; then skips consecutive
/// `import …` lines. Inserts `#if SWIFT_PACKAGE` / `import [module]` / `#endif`
/// when [objcSymbols] are referenced in [content] and there is no standalone
/// `import [objcModuleName]` line.
String applySwiftPackageObjcImportToContentIfReferenced(
  String content, {
  required String objcModuleName,
  required Set<String> objcSymbols,
}) {
  if (_swiftFileHasStandaloneImport(content, objcModuleName)) {
    return content;
  }

  final referenced = findReferencedSymbolsInSwiftContent(content, objcSymbols);
  if (referenced.isEmpty) return content;

  final lines = content.split('\n');
  var insertAt = _indexAfterLeadingCommentsAndBlankLines(lines);
  while (insertAt < lines.length &&
      RegExp(r'^\s*import\s+[A-Za-z_][A-Za-z0-9_]*\s*$')
          .hasMatch(lines[insertAt])) {
    insertAt += 1;
  }

  lines.insert(insertAt, '#if SWIFT_PACKAGE');
  lines.insert(insertAt + 1, 'import $objcModuleName');
  lines.insert(insertAt + 2, '#endif');
  return lines.join('\n');
}

int _indexAfterLeadingCommentsAndBlankLines(List<String> lines) {
  var insertAt = 0;
  while (insertAt < lines.length) {
    final t = lines[insertAt].trim();
    if (t.isEmpty || t.startsWith('//')) {
      insertAt += 1;
      continue;
    }
    break;
  }
  return insertAt;
}

/// Swift rewriter for SPM migration (`import Flutter`/UIKit/Foundation and
/// conditional ObjC target imports).
class SwiftRewriter {
  final FileSystemUtils fs;
  const SwiftRewriter(this.fs);

  /// Walks [.swift] files under [spmTargetDir], excluding `include/`, and adds
  /// framework imports where [missingSwiftImports] indicates they are needed.
  void ensureMissingFrameworkImportsInSwiftTarget(Directory spmTargetDir) {
    if (!spmTargetDir.existsSync()) return;

    var changedAny = false;
    for (final f in fs.listFilesRecursively(spmTargetDir)) {
      if (!f.path.endsWith('.swift')) continue;
      if (p.isWithin(p.join(spmTargetDir.path, 'include'), f.path)) continue;

      final original = f.readAsStringSync();
      final updated = applyMissingFrameworkImportsToContent(original);
      if (updated == original) continue;

      f.writeAsStringSync(updated);
      changedAny = true;
      final needed = missingSwiftImports(original);
      const importOrder = ['Foundation', 'UIKit', 'Flutter'];
      final added = importOrder.where(needed.contains).toList();
      print('Added `import ${added.join(', ')}` to: ${f.path}');
    }

    if (changedAny) {
      print('Swift files updated with missing imports.');
    }
  }

  /// Adds `#if SWIFT_PACKAGE import &lt;objcModuleName&gt; #endif` to Swift
  /// files in [swiftTargetDir] when they reference symbols declared in the
  /// ObjC-family sources under [objcTargetDir].
  void ensureSwiftPackageObjcImportsInSwiftTarget({
    required Directory swiftTargetDir,
    required Directory objcTargetDir,
    required String objcModuleName,
  }) {
    if (!swiftTargetDir.existsSync() || !objcTargetDir.existsSync()) return;

    final objcSymbols = collectObjcDeclaredSymbolsFromObjcTarget(objcTargetDir);
    if (objcSymbols.isEmpty) return;

    var changedAny = false;
    for (final swiftFile in fs.listFilesRecursively(swiftTargetDir)) {
      if (!swiftFile.path.endsWith('.swift')) continue;

      final content = swiftFile.readAsStringSync();
      if (_swiftFileHasStandaloneImport(content, objcModuleName)) continue;

      final referenced =
          findReferencedSymbolsInSwiftContent(content, objcSymbols);
      if (referenced.isEmpty) continue;

      swiftFile.writeAsStringSync(
        applySwiftPackageObjcImportToContentIfReferenced(
          content,
          objcModuleName: objcModuleName,
          objcSymbols: objcSymbols,
        ),
      );
      changedAny = true;

      final preview = referenced.toList()..sort();
      final shown = preview.take(5).join(', ');
      final suffix = preview.length > 5 ? ', ...' : '';
      stderr.writeln(
        'WARNING: Added `#if SWIFT_PACKAGE import $objcModuleName #endif` to '
        '${swiftFile.path} because it references ObjC symbols: '
        '$shown$suffix',
      );
    }

    if (changedAny) {
      print(
        'Swift files updated with `$objcModuleName` imports where ObjC symbols were referenced.',
      );
    }
  }

  /// Collects declared symbols from ObjC/C/C++ sources under [objcTargetDir]
  /// (same extensions as the migration script).
  Set<String> collectObjcDeclaredSymbolsFromObjcTarget(
      Directory objcTargetDir) {
    final objcSymbols = <String>{};
    if (!objcTargetDir.existsSync()) return objcSymbols;

    for (final file in fs.listFilesRecursively(objcTargetDir)) {
      final lower = file.path.toLowerCase();
      if (!(lower.endsWith('.h') ||
          lower.endsWith('.hh') ||
          lower.endsWith('.hpp') ||
          lower.endsWith('.m') ||
          lower.endsWith('.mm') ||
          lower.endsWith('.c') ||
          lower.endsWith('.cc') ||
          lower.endsWith('.cpp'))) {
        continue;
      }
      objcSymbols.addAll(
        extractObjcDeclaredSymbolsFromContent(file.readAsStringSync()),
      );
    }
    return objcSymbols;
  }
}
