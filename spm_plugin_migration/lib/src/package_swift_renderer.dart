import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:spm_plugin_migration/spm_plugin_migration.dart';

class PackageSwiftRenderInput {
  final PluginLanguage pluginLanguage;
  final String iosDeploymentTarget;
  final bool didAutoSplitMixedPlugin;
  final List<PodDependency> cocoaPodsDependencies;

  /// When `true`, the rendered `Package.swift` declares a local SwiftPM
  /// dependency on `FlutterFramework` (at `../FlutterFramework`) and wires it
  /// into every target's `dependencies:`. Set when the plugin's pubspec
  /// requires Flutter `>= 3.41`, where this package is expected to exist.
  final bool needsFlutterFramework;

  const PackageSwiftRenderInput({
    required this.pluginLanguage,
    required this.iosDeploymentTarget,
    required this.didAutoSplitMixedPlugin,
    required this.cocoaPodsDependencies,
    this.needsFlutterFramework = false,
  });
}

/// Renders `Package.swift` and derives Swift-target exclude paths for mixed ObjC layouts.
class PackageSwiftRenderer {
  final IosPluginContext context;
  final FileSystemUtils fs;

  const PackageSwiftRenderer({
    required this.context,
    required this.fs,
  });

  /// Renders `Package.swift` content for the detected plugin layout and
  /// migration mode (single target vs mixed split).
  String render(PackageSwiftRenderInput input) {
    final pluginName = context.pluginName;
    final libraryName = pluginName.replaceAll('_', '-');
    final isObjcPlugin = input.pluginLanguage.isObjcPlugin;
    final isMixedPlugin = input.pluginLanguage.isMixedPlugin;
    final iosDeploymentTarget = input.iosDeploymentTarget;
    final didAutoSplitMixedPlugin = input.didAutoSplitMixedPlugin;
    final swiftTargetExclude = isMixedPlugin
        ? _collectSwiftTargetExcludePaths(context.spmTargetDir)
        : const <String>[];
    final hasPrivacyManifest = context.spmPrivacyFile.existsSync();
    final hasAssetsDir = context.spmAssetsDir.existsSync() &&
        !fs.isDirectoryEmpty(context.spmAssetsDir);
    final hasResourcesDir = context.spmResourcesDir.existsSync() &&
        !fs.isDirectoryEmpty(context.spmResourcesDir);
    final hasLocalizedResources = _hasLprojDirectories(context.spmResourcesDir);
    final cocoaPodsDependencies = input.cocoaPodsDependencies;
    final needsFlutterFramework = input.needsFlutterFramework;
    final hasCocoaPodsModulemap =
        context.spmCocoapodsModulemapFile.existsSync() ||
            context.objcCocoapodsModulemapFile.existsSync();

    const flutterFrameworkProduct =
        '.product(name: "FlutterFramework", package: "FlutterFramework")';

    final packageDependenciesLine = needsFlutterFramework
        ? '    dependencies: [\n'
            '        .package(name: "FlutterFramework", path: "../FlutterFramework"),\n'
            '    ],'
        : '    dependencies: [],';

    String podDepsTodoBlock(String indent) {
      if (cocoaPodsDependencies.isEmpty) return '';
      final lines = <String>[
        '$indent// TODO: CocoaPods dependencies found in .podspec. Add SPM equivalents here:',
        ...cocoaPodsDependencies.map(
          (d) =>
              '$indent// - ${d.name}${d.constraint != null ? ' (${d.constraint})' : ''}',
        ),
      ];
      return '${lines.join('\n')}\n';
    }

    String swiftTargetDependenciesExpr() {
      final items = <String>[
        if (didAutoSplitMixedPlugin) '"${pluginName}_objc"',
        if (needsFlutterFramework) flutterFrameworkProduct,
      ];
      final hasCocoa = cocoaPodsDependencies.isNotEmpty;

      if (items.isEmpty && !hasCocoa) return '[]';
      // Keep the compact single-item form (matches pre-existing test expectations).
      if (items.length == 1 && !hasCocoa) return '[${items.single}]';

      final buf = StringBuffer('[\n');
      for (final item in items) {
        buf.write('                $item,\n');
      }
      if (hasCocoa) {
        buf.write(podDepsTodoBlock('                '));
      }
      buf.write('            ]');
      return buf.toString();
    }

    String excludeListExpr(List<String> items) =>
        '[${items.map((e) => '"$e"').join(', ')}]';

    String buildSwiftTargetBlock() {
      final lines = <String>[
        '        .target(',
        '            name: "$pluginName",',
        '            dependencies: ${swiftTargetDependenciesExpr()},',
      ];

      if (swiftTargetExclude.isNotEmpty) {
        lines.add(
            '            exclude: ${excludeListExpr(swiftTargetExclude)},');
      }

      final resources = <String>[
        if (hasAssetsDir) '.process("Assets")',
        if (hasResourcesDir) '.process("Resources")',
        if (hasPrivacyManifest) '.process("PrivacyInfo.xcprivacy")',
      ];
      if (resources.isNotEmpty) {
        lines.addAll([
          '            resources: [',
          ...resources.map((resource) => '                $resource,'),
          '            ],',
        ]);
      }

      if (!didAutoSplitMixedPlugin && isObjcPlugin && !isMixedPlugin) {
        if (hasCocoaPodsModulemap) {
          lines.add(
            '            exclude: ["include/cocoapods_$pluginName.modulemap"],',
          );
        }
        lines.addAll([
          '            cSettings: [',
          '                .headerSearchPath("include/$pluginName"),',
          '            ],',
        ]);
      }

      lines.add('        ),');
      return lines.join('\n');
    }

    String buildObjcTargetBlock() {
      final lines = <String>[
        '        .target(',
        '            name: "${pluginName}_objc",',
        '            path: "Sources/${pluginName}_objc",',
        '            publicHeadersPath: "include",',
      ];
      if (needsFlutterFramework) {
        lines.addAll([
          '            dependencies: [',
          '                $flutterFrameworkProduct,',
          '            ],',
        ]);
      }
      if (hasCocoaPodsModulemap) {
        lines.add(
          '            exclude: ["include/cocoapods_$pluginName.modulemap"],',
        );
      }
      lines.addAll([
        '            cSettings: [',
        '                .headerSearchPath("include/$pluginName"),',
        '            ],',
      ]);
      lines.add('        ),');
      return lines.join('\n');
    }

    final productTargets = didAutoSplitMixedPlugin
        ? '["$pluginName", "${pluginName}_objc"]'
        : '["$pluginName"]';

    final mixedNote = didAutoSplitMixedPlugin
        ? '        // NOTE: This package was auto-split into Swift + ObjC targets to avoid mixed-language SwiftPM limitations.\n'
            '        // See: https://stackoverflow.com/questions/51540665/swift-package-manager-mixed-language-source-files\n'
        : (isMixedPlugin
            ? '        // TODO: This package contains mixed Swift + Objective-C sources. SwiftPM may require splitting them into two targets (ObjC + Swift).\n'
                '        // See: https://stackoverflow.com/questions/51540665/swift-package-manager-mixed-language-source-files\n'
            : '');

    final targetsBlocks = <String>[
      if (mixedNote.isNotEmpty) mixedNote.trimRight(),
      if (didAutoSplitMixedPlugin) buildObjcTargetBlock(),
      buildSwiftTargetBlock(),
    ];

    final localizedHeader = hasLocalizedResources
        ? '    // TODO(spm-migration): Localized resources (*.lproj) detected. Verify defaultLocalization value.\n'
            '    defaultLocalization: "en",\n'
        : '';

    return '''
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "$pluginName",
${localizedHeader}    platforms: [
        .iOS("$iosDeploymentTarget"),
    ],
    products: [
        .library(name: "$libraryName", targets: $productTargets),
    ],
$packageDependenciesLine
    targets: [
${targetsBlocks.join('\n\n')}
    ]
)
''';
  }

  /// Mirrors Swift-target `exclude:` derivation for mixed layouts.
  ///
  /// Defaults to [context.spmTargetDir]; override for tests or tooling.
  List<String> collectSwiftTargetExcludeForObjcFamily(
      {Directory? spmTargetDir}) {
    return _collectSwiftTargetExcludePaths(
        spmTargetDir ?? context.spmTargetDir);
  }

  List<String> _collectSwiftTargetExcludePaths(Directory spmTargetDir) {
    final exclude = <String>{};
    final includeDir = Directory(p.join(spmTargetDir.path, 'include'));
    if (includeDir.existsSync()) {
      exclude.add('include');
    }
    if (!spmTargetDir.existsSync()) return exclude.toList()..sort();

    for (final f in fs.listFilesRecursively(spmTargetDir)) {
      if (!isObjcOrCppFamilyPath(f.path)) {
        continue;
      }
      exclude.add(fs.posixRelativePath(f.path, from: spmTargetDir.path));
    }
    return exclude.toList()..sort();
  }
}

bool _hasLprojDirectories(Directory resourcesDir) {
  if (!resourcesDir.existsSync()) return false;
  for (final entity
      in resourcesDir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory &&
        p.basename(entity.path).toLowerCase().endsWith('.lproj')) {
      return true;
    }
  }
  return false;
}
