import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:spm_plugin_migration/spm_plugin_migration.dart';

class WrapperFileMapper {
  final IosPluginContext context;
  final FileSystemUtils fs;

  const WrapperFileMapper({
    required this.context,
    required this.fs,
  });

  /// Returns `true` when the only ObjC files are legacy Flutter wrapper files
  /// (`*Plugin.m/.mm` + `*Plugin.h`), so they can be replaced with Swift.
  bool isOnlyPluginWrapperObjcFiles() {
    final spmTargetDir = context.spmTargetDir;

    if (!spmTargetDir.existsSync()) return false;
    final includeRoot = p.join(spmTargetDir.path, 'include');

    final allObjcLike = fs.listFilesRecursively(spmTargetDir).where((f) {
      final lower = f.path.toLowerCase();
      return lower.endsWith('.m') ||
          lower.endsWith('.mm') ||
          lower.endsWith('.h');
    }).toList(growable: false);

    if (allObjcLike.isEmpty) return false;

    final outsideInclude =
        allObjcLike.where((f) => !p.isWithin(includeRoot, f.path)).toList();
    final insideInclude =
        allObjcLike.where((f) => p.isWithin(includeRoot, f.path)).toList();

    final pluginM = outsideInclude
        .where(
          (f) =>
              p.basename(f.path).endsWith('Plugin.m') ||
              p.basename(f.path).endsWith('Plugin.mm'),
        )
        .toList(growable: false);
    final pluginH = allObjcLike
        .where((f) => p.basename(f.path).endsWith('Plugin.h'))
        .toList(growable: false);

    // Requirement: only two ObjC files in the plugin: *Plugin.m and *Plugin.h.
    // Note: Plugin.h is typically relocated into include/, so we count headers in
    // include as well.
    final totalCount = outsideInclude.length + insideInclude.length;
    final hasOnlyTwo =
        totalCount == 2 && pluginM.length == 1 && pluginH.length == 1;
    if (!hasOnlyTwo) return false;

    // Ensure the non-header file is exactly the Plugin.m/.mm.
    final othersOutside =
        outsideInclude.where((f) => f.path != pluginM.single.path).toList();
    if (othersOutside.isNotEmpty) return false;

    return true;
  }

  /// Converts the ObjC wrapper-only special case into a Swift wrapper and
  /// deletes legacy ObjC wrapper files.
  bool convertOnlyPluginObjcToSwiftSpecialCase() {
    final spmTargetDir = context.spmTargetDir;

    final objcImpl = fs.listFilesRecursively(spmTargetDir).where((f) {
      final base = p.basename(f.path);
      return base.endsWith('Plugin.m') || base.endsWith('Plugin.mm');
    }).toList(growable: false);
    final objcHeader = fs
        .listFilesRecursively(spmTargetDir)
        .where((f) => p.basename(f.path).endsWith('Plugin.h'))
        .toList(growable: false);

    if (objcImpl.length != 1 || objcHeader.length != 1) {
      return false;
    }

    final implFile = objcImpl.single;
    final headerFile = objcHeader.single;
    final implContent = implFile.readAsStringSync();
    final implClassMatch = RegExp(
      r'@implementation\s+([A-Za-z_][A-Za-z0-9_]*)',
    ).firstMatch(implContent);
    final objcPluginClass =
        implClassMatch?.group(1) ?? p.basenameWithoutExtension(implFile.path);

    final swiftPluginClass =
        detectSwiftPluginClassFromObjcWrapperContent(implContent) ??
            detectSwiftFlutterPluginClass(spmTargetDir) ??
            objcPluginClass;
    final registerCall = '$swiftPluginClass.register(with: registrar)';

    final additionalInterfaceBlocks = _extractAdditionalObjcInterfaceBlocks(
      headerContent: headerFile.readAsStringSync(),
      excludeClassName: objcPluginClass,
    );

    final swiftWrapperFile = File(
      p.join(spmTargetDir.path, '$objcPluginClass.swift'),
    );
    if (!swiftWrapperFile.existsSync()) {
      final extraTodo = additionalInterfaceBlocks.isNotEmpty
          ? '\n// TODO: additional interfaces were detected in ${p.basename(headerFile.path)}. Add Swift equivalents for them.\n'
              '/*\n'
              '${additionalInterfaceBlocks.join('\n\n')}\n'
              '*/\n'
          : '';
      swiftWrapperFile.writeAsStringSync('''
import Flutter
import Foundation

@objc($objcPluginClass)
public class $objcPluginClass: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        $registerCall
    }
}$extraTodo
''');
      stdout.writeln(
          'Added special-case Swift wrapper: ${swiftWrapperFile.path}');
    }

    // Remove ObjC wrapper files so plugin proceeds as Swift-only migration.
    if (implFile.existsSync()) {
      implFile.deleteSync();
    }
    if (headerFile.existsSync()) {
      headerFile.deleteSync();
    }
    fs.deleteDirIfEmpty(headerFile.parent);

    stdout.writeln(
      'Applied special mixed-case conversion: replaced ${p.basename(implFile.path)} / ${p.basename(headerFile.path)} with $objcPluginClass.swift',
    );
    return true;
  }

  /// Ensures a SwiftPM registration stub exists and removes legacy wrapper
  /// variants that are no longer needed.
  void ensureSwiftPmRegistrationStub() {
    final spmTargetDir = context.spmTargetDir;
    final pluginName = context.pluginName;
    if (!spmTargetDir.existsSync()) return;
    final objcTargetDir = context.objcTargetDir;

    final objcPluginClass = _detectObjcPluginWrapperClassInDir(spmTargetDir) ??
        _detectObjcPluginWrapperClassInDir(objcTargetDir) ??
        '${pluginName[0].toUpperCase()}${pluginName.substring(1)}Plugin';

    final swiftPluginClass = detectSwiftPluginClassFromObjcWrapperDirs([
          spmTargetDir,
          objcTargetDir,
        ]) ??
        detectSwiftFlutterPluginClass(spmTargetDir) ??
        objcPluginClass;
    final call = '$swiftPluginClass.register(with: registrar)';

    final file = File(p.join(spmTargetDir.path, '$objcPluginClass.swift'));
    final legacyFile = File(
      p.join(spmTargetDir.path, '${objcPluginClass}+SwiftPM.swift'),
    );
    if (!file.existsSync()) {
      file.writeAsStringSync('''
import Flutter
import Foundation

@objc($objcPluginClass)
public class $objcPluginClass: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        $call
    }
}
''');
      stdout.writeln('Added SwiftPM registration stub: ${file.path}');
    }

    if (legacyFile.existsSync()) {
      legacyFile.deleteSync();
      stdout.writeln(
          'Removed legacy SwiftPM registration stub: ${legacyFile.path}');
    }

    _cleanupLegacyObjcPluginWrappers(
      objcPluginClass: objcPluginClass,
      dirs: [spmTargetDir, objcTargetDir],
    );
  }

  /// Scans ObjC wrapper files in [dirs] and returns the Swift plugin class name
  /// used in `registerWithRegistrar` if found.
  String? detectSwiftPluginClassFromObjcWrapperDirs(List<Directory> dirs) {
    for (final dir in dirs) {
      if (!dir.existsSync()) continue;
      for (final f in fs.listFilesRecursively(dir)) {
        if (!f.path.endsWith('Plugin.m') && !f.path.endsWith('Plugin.mm')) {
          continue;
        }
        final detected = detectSwiftPluginClassFromObjcWrapperContent(
          f.readAsStringSync(),
        );
        if (detected != null) {
          return detected;
        }
      }
    }
    return null;
  }

  /// Extracts Swift plugin class name from an ObjC wrapper implementation body.
  String? detectSwiftPluginClassFromObjcWrapperContent(String content) {
    // Typical Flutter ObjC wrapper call:
    // [SwiftMyPlugin registerWithRegistrar:registrar];
    final re = RegExp(
      r'\[\s*([A-Za-z_][A-Za-z0-9_]*)\s+registerWithRegistrar\s*:\s*registrar\s*\]',
    );
    final m = re.firstMatch(content);
    return m?.group(1);
  }

  /// Finds the first Swift class that conforms to `FlutterPlugin`.
  String? detectSwiftFlutterPluginClass(Directory swiftTargetDir) {
    if (!swiftTargetDir.existsSync()) return null;
    final re = RegExp(
      r'\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*[^\n\{]*\bFlutterPlugin\b',
    );
    for (final f in fs.listFilesRecursively(swiftTargetDir)) {
      if (!f.path.endsWith('.swift')) continue;
      final content = f.readAsStringSync();
      final m = re.firstMatch(content);
      if (m != null) return m.group(1);
    }
    return null;
  }

  String? _detectObjcPluginWrapperClassInDir(Directory dir) {
    if (!dir.existsSync()) return null;
    final implRe = RegExp(r'@implementation\s+([A-Za-z_][A-Za-z0-9_]*)');
    final pluginMFiles = fs
        .listFilesRecursively(dir)
        .where(
            (f) => f.path.endsWith('Plugin.m') || f.path.endsWith('Plugin.mm'))
        .toList(growable: false);
    for (final f in pluginMFiles) {
      final content = f.readAsStringSync();
      final m = implRe.firstMatch(content);
      if (m != null) return m.group(1);
    }
    // Fallback: use basename without extension.
    if (pluginMFiles.isNotEmpty) {
      return p.basenameWithoutExtension(pluginMFiles.first.path);
    }
    return null;
  }

  /// Extracts `@interface … @end` blocks from an ObjC header, excluding the
  /// block whose class name matches [excludeClassName] (the plugin wrapper
  /// itself, which is being replaced by a Swift wrapper).
  static List<String> _extractAdditionalObjcInterfaceBlocks({
    required String headerContent,
    required String excludeClassName,
  }) {
    final re = RegExp(
      r'@interface\s+([A-Za-z_][A-Za-z0-9_]*)[\s\S]*?@end',
    );
    return re
        .allMatches(headerContent)
        .where((m) => m.group(1) != excludeClassName)
        .map((m) => m.group(0)!.trim())
        .toList(growable: false);
  }

  void _cleanupLegacyObjcPluginWrappers({
    required String objcPluginClass,
    required List<Directory> dirs,
  }) {
    final basenames = <String>{
      '$objcPluginClass.m',
      '$objcPluginClass.mm',
      '$objcPluginClass.h',
    };

    for (final dir in dirs) {
      if (!dir.existsSync()) continue;
      for (final f in fs.listFilesRecursively(dir).toList()) {
        if (!basenames.contains(p.basename(f.path))) continue;
        f.deleteSync();
        fs.deleteDirIfEmpty(f.parent);
        stdout.writeln('Removed legacy ObjC wrapper file: ${f.path}');
      }
    }
  }
}
