import 'dart:io';

import 'package:path/path.dart' as p;

import '../spm_plugin_migration.dart';

class IosPluginContext {
  final String path;
  final String pluginName;

  const IosPluginContext(this.path, this.pluginName);

  Directory get iosDir => Directory(path);

  /// `pubspec.yaml` lives at the plugin package root — one level above `ios/`.
  File get pubspecFile => File(p.join(iosDir.parent.path, 'pubspec.yaml'));

  File get podspecFile => File(p.join(iosDir.path, '$pluginName.podspec'));
  Directory get classesDir => Directory(p.join(iosDir.path, 'Classes'));
  Directory get assetsDir => Directory(p.join(iosDir.path, 'Assets'));
  Directory get resourcesDir => Directory(p.join(iosDir.path, 'Resources'));
  File? get privacyFile => findFirstFileByName(
        iosDir,
        'PrivacyInfo.xcprivacy',
        excludeDirs: {spmPackageDir.path},
      );

  Directory get spmPackageDir => Directory(p.join(iosDir.path, pluginName));
  File get packageSwift => File(p.join(spmPackageDir.path, 'Package.swift'));
  Directory get spmTargetDir =>
      Directory(p.join(spmPackageDir.path, 'Sources', pluginName));

  Directory get spmAssetsDir => Directory(p.join(spmTargetDir.path, 'Assets'));
  Directory get spmResourcesDir =>
      Directory(p.join(spmTargetDir.path, 'Resources'));

  File get spmPrivacyFile =>
      File(p.join(spmTargetDir.path, 'PrivacyInfo.xcprivacy'));
  Directory get spmIncludeDir =>
      Directory(p.join(spmTargetDir.path, 'include'));
  Directory get spmIncludeModuleDir =>
      Directory(p.join(spmIncludeDir.path, pluginName));

  String get objcTargetName => '${pluginName}_objc';

  Directory get objcTargetDir =>
      Directory(p.join(spmPackageDir.path, 'Sources', objcTargetName));
  Directory get objcIncludeDir =>
      Directory(p.join(objcTargetDir.path, 'include'));
  Directory get objcIncludeModuleDir =>
      Directory(p.join(objcIncludeDir.path, pluginName));

  /// CocoaPods-style module map under the Swift target `include/`.
  File get spmCocoapodsModulemapFile =>
      File(p.join(spmIncludeDir.path, 'cocoapods_$pluginName.modulemap'));

  /// Same module map path under the split ObjC target `include/`.
  File get objcCocoapodsModulemapFile =>
      File(p.join(objcIncludeDir.path, 'cocoapods_$pluginName.modulemap'));

  /// Builds iOS plugin context from plugin package root path by resolving
  /// `ios/` directory and primary `.podspec`.
  factory IosPluginContext.fromPackagePath(String path) {
    final iosDir = Directory(p.join(path, 'ios'));
    if (!iosDir.existsSync()) {
      throw Exception('ios/ directory not found at: ${iosDir.path}');
    }

    File _findPodspec(Directory iosDir) {
      final podspecs = iosDir
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => f.path.endsWith('.podspec'))
          .toList();
      if (podspecs.isEmpty) {
        throw Exception('No .podspec found in: ${iosDir.path}');
      }
      if (podspecs.length == 1) {
        return podspecs.single;
      }
      podspecs.sort((a, b) => a.path.compareTo(b.path));
      stderr.writeln(
        'WARNING: Multiple .podspec files found in ios/. Using: ${podspecs.first.path}',
      );
      return podspecs.first;
    }

    final podspec = _findPodspec(iosDir);

    final pluginName = p.basenameWithoutExtension(podspec.path);

    return IosPluginContext(iosDir.path, pluginName);
  }
}
