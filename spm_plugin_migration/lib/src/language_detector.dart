import 'dart:io';

import '../spm_plugin_migration.dart';

enum PluginLanguage { swift, objectiveC, mixed }

extension PluginLanguageBool on PluginLanguage {
  bool get isMixedPlugin => this == PluginLanguage.mixed;
  bool get isSwiftPlugin => this == PluginLanguage.swift;
  bool get isObjcPlugin => this == PluginLanguage.objectiveC;
  bool get hasSwiftSources =>
      this == PluginLanguage.swift || this == PluginLanguage.mixed;
  bool get hasObjcSources =>
      this == PluginLanguage.objectiveC || this == PluginLanguage.mixed;
}

class LanguageDetector {
  final IosPluginContext context;
  final FileSystemUtils fs;
  const LanguageDetector(this.context, this.fs);

  /// Detects plugin language by scanning legacy `Classes/` and current
  /// `Sources/<plugin>/` trees for Swift and ObjC-family files.
  PluginLanguage detect() {
    final classesDir = context.classesDir;
    final spmTargetDir = context.spmTargetDir;

    final classesFiles = classesDir.existsSync()
        ? fs.listFilesRecursively(classesDir).toList(growable: false)
        : const <File>[];
    final spmTargetFiles = spmTargetDir.existsSync()
        ? fs.listFilesRecursively(spmTargetDir).toList(growable: false)
        : const <File>[];
    final allNativeFiles = <File>[...classesFiles, ...spmTargetFiles];

    final hasObjcSources = allNativeFiles.any(
      (f) => isObjcOrCppFamilyPath(f.path, includeModuleMap: false),
    );
    final hasSwiftSources =
        allNativeFiles.any((f) => f.path.endsWith('.swift'));
    // "Mixed" plugins exist (ObjC + Swift in the same plugin).
    // We treat them as ObjC for header/include handling, but also as Swift
    // for things like .arcignore and source_files patterns.
    final isObjcPlugin = hasObjcSources;
    final isMixedPlugin = hasObjcSources && hasSwiftSources;

    return isMixedPlugin
        ? PluginLanguage.mixed
        : isObjcPlugin
            ? PluginLanguage.objectiveC
            : PluginLanguage.swift;
  }
}
