import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:spm_plugin_migration/spm_plugin_migration.dart';

/// Objective-C source edits for SwiftPM migration: include paths and
/// external Pods module imports.
class ObjcRewriter {
  final IosPluginContext context;
  final FileSystemUtils fs;
  const ObjcRewriter(this.context, this.fs);

  /// After moving headers into include/, rewrite imports in .m/.mm files to
  /// point under [spmIncludeModuleDir].
  ///
  /// Skips any [File] whose path lies under `[spmTargetDir]/include/`.
  void rewriteImportsToInclude({
    Directory? spmTargetDirOverride,
    Directory? spmIncludeModuleDirOverride,
  }) {
    final spmTargetDir = spmTargetDirOverride ?? context.spmTargetDir;
    final spmIncludeModuleDir =
        spmIncludeModuleDirOverride ?? context.spmIncludeModuleDir;

    final byBasename = <String, String>{};
    final byBasenameLower = <String, String>{};
    final duplicates = <String>{};
    final duplicatesLower = <String>{};
    for (final f in fs.listFilesRecursively(spmIncludeModuleDir)) {
      if (!f.path.endsWith('.h')) {
        continue;
      }
      final base = p.basename(f.path);
      final baseLower = base.toLowerCase();
      final relFromInclude = fs.posixRelativePath(
        f.path,
        from: spmIncludeModuleDir.path,
      );
      if (byBasename.containsKey(base)) {
        duplicates.add(base);
      } else {
        byBasename[base] = relFromInclude;
      }
      if (byBasenameLower.containsKey(baseLower)) {
        duplicatesLower.add(baseLower);
      } else {
        byBasenameLower[baseLower] = relFromInclude;
      }
    }
    for (final d in duplicates) {
      byBasename.remove(d);
    }
    for (final d in duplicatesLower) {
      byBasenameLower.remove(d);
    }
    if (byBasename.isEmpty) {
      return;
    }

    final includeRoot = p.join(spmTargetDir.path, 'include');
    final importQuoteRe = RegExp(r'''^\s*#import\s+"([^"]+\.h)"\s*$''');
    final importAngleRe = RegExp(r'''^\s*#import\s+<([^>]+\.h)>\s*$''');

    for (final f in fs.listFilesRecursively(spmTargetDir)) {
      if (!(f.path.endsWith('.m') || f.path.endsWith('.mm'))) {
        continue;
      }
      if (p.isWithin(includeRoot, f.path)) {
        continue;
      }

      final originalContent = f.readAsStringSync();
      final lines = f.readAsLinesSync();
      var changed = false;
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        String? header;

        final m1 = importQuoteRe.firstMatch(line);
        if (m1 != null) {
          header = m1.group(1);
        } else {
          final m2 = importAngleRe.firstMatch(line);
          if (m2 != null) {
            header = m2.group(1);
          }
        }

        if (header == null) {
          continue;
        }

        final base = p.basename(header);
        final rel = byBasename[base] ?? byBasenameLower[base.toLowerCase()];
        if (rel == null) {
          continue;
        }

        final fromDir = p.dirname(f.path);
        var prefix = p.relative(spmIncludeModuleDir.path, from: fromDir);
        prefix = p.posix.normalize(prefix.split(p.separator).join('/'));
        if (!prefix.startsWith('.')) {
          prefix = './$prefix';
        }
        final newPath = '$prefix/$rel';
        final replaced = line.replaceFirst(header, newPath);
        if (replaced != line) {
          lines[i] = replaced;
          changed = true;
        }
      }
      if (changed) {
        var result = lines.join('\n');
        if (originalContent.endsWith('\n')) result += '\n';
        f.writeAsStringSync(result);
      }
    }
  }

  /// Wrap `#import <Pod/…>` lines for declared CocoaPods dependencies in
  /// `__has_include` / `@import` blocks for SwiftPM builds.
  void rewriteExternalDependencyImports({
    required Directory objcSourceDir,
    required Iterable<String> externalDependencyNames,
  }) {
    if (!objcSourceDir.existsSync()) return;

    final depNames = externalDependencyNames
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    final depModuleNames = depNames.map((e) => e.split('/').first).toSet();

    if (depNames.isEmpty && depModuleNames.isEmpty) return;

    final importRe = RegExp(r'^\s*#import\s+<([^>]+)>\s*$');

    for (final f in fs.listFilesRecursively(objcSourceDir)) {
      final lower = f.path.toLowerCase();
      if (!(lower.endsWith('.m') ||
          lower.endsWith('.mm') ||
          lower.endsWith('.h'))) {
        continue;
      }

      final originalContent = f.readAsStringSync();
      final lines = f.readAsLinesSync();
      final out = <String>[];
      var changed = false;
      var i = 0;

      while (i < lines.length) {
        final line = lines[i];
        final match = importRe.firstMatch(line);
        if (match == null) {
          out.add(line);
          i += 1;
          continue;
        }

        final imported = match.group(1)!;
        final importedDep = imported.split('/').first;

        final isExternalDepImport = depNames.contains(importedDep) ||
            depModuleNames.contains(importedDep);
        if (!isExternalDepImport) {
          out.add(line);
          i += 1;
          continue;
        }

        if (i > 0 && lines[i - 1].contains('#if __has_include(<$imported>)')) {
          out.add(line);
          i += 1;
          continue;
        }

        final moduleName = importedDep;
        out
          ..add('#if __has_include(<$imported>)')
          ..add('#import <$imported>')
          ..add('#else')
          ..add('@import $moduleName;')
          ..add('#endif');
        changed = true;
        i += 1;
      }

      if (changed) {
        var result = out.join('\n');
        if (originalContent.endsWith('\n')) result += '\n';
        f.writeAsStringSync(result);
        print('Updated external dependency imports in: ${f.path}');
      }
    }
  }
}
