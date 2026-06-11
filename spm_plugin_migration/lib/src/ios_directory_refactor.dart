import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:spm_plugin_migration/spm_plugin_migration.dart';

class IosDirectoryRefactor {
  final IosPluginContext context;
  final FileSystemUtils fs;
  final PluginLanguage pluginLanguage;
  const IosDirectoryRefactor({
    required this.context,
    required this.fs,
    required this.pluginLanguage,
  });

  /// Moves legacy iOS plugin directories into the SwiftPM source layout and
  /// relocates ObjC headers/modulemap into `include/` when needed.
  void refact() {
    final classesDir = context.classesDir;
    final spmTargetDir = context.spmTargetDir;
    final spmIncludeDir = context.spmIncludeDir;
    final spmIncludeModuleDir = context.spmIncludeModuleDir;

    final assetsDir = context.assetsDir;
    final resourcesDir = context.resourcesDir;

    final hasObjcSources = pluginLanguage.hasObjcSources;

    fs.ensureDir(spmTargetDir);
    if (hasObjcSources) {
      fs.ensureDir(spmIncludeModuleDir);
    }
    _ensureGitignoreForSwiftPackage();

    // Move resources (Assets/Resources/Privacy) into Sources/<plugin_name>/...
    final spmAssetsDir = context.spmAssetsDir;
    if (assetsDir.existsSync()) {
      stdout.writeln('Moving $assetsDir → $spmAssetsDir ...');
      fs.moveDirChildren(assetsDir, spmAssetsDir);
      fs.deleteDirIfEmpty(assetsDir);
    }

    final spmResourcesDir = context.spmResourcesDir;
    if (resourcesDir.existsSync()) {
      stdout.writeln('Moving $resourcesDir → $spmResourcesDir ...');
      fs.moveDirChildren(resourcesDir, spmResourcesDir);
      fs.deleteDirIfEmpty(resourcesDir);
    }

    final privacyFile = context.privacyFile;
    final spmPrivacyFile = context.spmPrivacyFile;
    if (privacyFile != null) {
      stdout.writeln('Moving $privacyFile → $spmPrivacyFile');
      fs.moveFile(privacyFile, spmPrivacyFile);
    }

    // Move classes into Sources/<plugin_name>/...
    if (classesDir.existsSync()) {
      stdout.writeln('Moving $classesDir → $spmTargetDir ...');
      fs.moveDirChildren(classesDir, spmTargetDir);
      fs.deleteDirIfEmpty(classesDir);
    } else {
      stdout.writeln('No ios/Classes directory found (skipping sources move).');
    }

    // Objective-C specific: move public headers into include/<plugin_name>/...
    // and modulemaps into include/.
    if (hasObjcSources) {
      final publicHeadersToMove = <File>[];
      final modulemapsToMove = <File>[];
      // Collect all .h and .modulemap files that are not under include/.
      fs
          .listFilesRecursively(spmTargetDir)
          .where((f) => !p.isWithin(spmIncludeDir.path, f.path))
          .forEach(
        (f) {
          if (f.path.endsWith('.h')) {
            publicHeadersToMove.add(f);
          } else if (f.path.endsWith('.modulemap')) {
            modulemapsToMove.add(f);
          }
        },
      );

      if (publicHeadersToMove.isNotEmpty) {
        stdout.writeln('Relocating public headers → $spmIncludeDir ...');
        for (final f in publicHeadersToMove) {
          final relFromTarget = fs.posixRelativePath(
            f.path,
            from: spmTargetDir.path,
          );
          final dst = File(p.join(spmIncludeModuleDir.path, relFromTarget));
          fs.ensureDir(dst.parent);
          fs.moveFile(f, dst);
        }
      }

      if (modulemapsToMove.isNotEmpty) {
        stdout.writeln(
          'Relocating modulemap(s) → $spmIncludeDir ...',
        );
        modulemapsToMove.sort((a, b) => a.path.compareTo(b.path));
        final expectedBasename = 'cocoapods_${context.pluginName}.modulemap';
        final primary = modulemapsToMove.firstWhere(
          (f) => p.basename(f.path) == expectedBasename,
          orElse: () => modulemapsToMove.first,
        );

        final dst = context.spmCocoapodsModulemapFile;
        fs.ensureDir(dst.parent);
        fs.moveFile(primary, dst);

        for (final f in modulemapsToMove) {
          if (p.equals(f.path, primary.path)) continue;
          if (f.existsSync()) {
            f.deleteSync();
            stdout.writeln('Removed extra modulemap: ${f.path}');
          }
        }
      }
    }
  }

  void _ensureGitignoreForSwiftPackage() {
    fs.ensureDir(context.spmPackageDir);
    final file = File(p.join(context.spmPackageDir.path, '.gitignore'));
    final desired = <String>{'.build/', '.swiftpm/'};

    if (!file.existsSync()) {
      file.writeAsStringSync('${desired.join('\n')}\n');
      return;
    }

    final existingLines = file.readAsLinesSync();
    final existing = existingLines.map((l) => l.trim()).toSet();
    final toAdd = desired.where((l) => !existing.contains(l)).toList();
    if (toAdd.isEmpty) return;

    final separator =
        existingLines.isNotEmpty && existingLines.last.trim().isNotEmpty
            ? '\n'
            : '';
    file.writeAsStringSync(
      '${existingLines.join('\n')}$separator${toAdd.join('\n')}\n',
    );
  }

  /// Splits a mixed Swift+ObjC target into two SwiftPM targets and rewrites
  /// ObjC imports to the new include tree.
  bool autoSplitMixedPluginForSwiftPm() {
    final objcTargetDir = context.objcTargetDir;
    final objcIncludeModuleDir = context.objcIncludeModuleDir;
    final spmTargetDir = context.spmTargetDir;

    // If already split (directory exists and has at least one file), treat as done.
    if (objcTargetDir.existsSync() &&
        objcTargetDir
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .isNotEmpty) {
      return true;
    }

    // Only attempt split if we have sources directory already.
    if (!spmTargetDir.existsSync()) return false;

    stdout.writeln(
        'Auto-splitting mixed Swift+ObjC plugin into two SwiftPM targets...');
    fs.ensureDir(objcTargetDir);
    fs.ensureDir(objcIncludeModuleDir);

    // Move include/ (public headers + modulemap) to ObjC target.
    final includeDir = context.spmIncludeDir;
    if (includeDir.existsSync()) {
      fs.moveDirectory(
        includeDir,
        context.objcIncludeDir,
      );
    }

    // Move ObjC-family source files out of the Swift target.
    // Plugin wrapper `*Plugin.{h,m,mm,cpp}` is removed later and replaced with
    // a SwiftPM-only Swift wrapper file.
    for (final f in fs.listFilesRecursively(spmTargetDir).toList()) {
      if (p.isWithin(p.join(spmTargetDir.path, 'include'), f.path)) continue;
      if (!isObjcOrCppFamilyPath(f.path)) {
        continue;
      }
      final rel = fs.posixRelativePath(f.path, from: spmTargetDir.path);
      final dst = File(p.join(objcTargetDir.path, rel));
      fs.ensureDir(dst.parent);
      fs.moveFile(f, dst);
    }

    // Rewrite ObjC imports in the moved target to point to its include tree.
    final objcRewriter = ObjcRewriter(context, fs);
    objcRewriter.rewriteImportsToInclude(
      spmTargetDirOverride: objcTargetDir,
      spmIncludeModuleDirOverride: objcIncludeModuleDir,
    );

    return true;
  }
}
