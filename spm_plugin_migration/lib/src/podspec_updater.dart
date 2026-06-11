import '../spm_plugin_migration.dart';

class PodspecUpdater {
  final IosPluginContext context;
  final FileSystemUtils fs;
  const PodspecUpdater(this.context, this.fs);

  /// Rewrites podspec source/header/modulemap/resource paths for the SwiftPM
  /// migration layout while preserving CocoaPods compatibility.
  String updatePodspecPaths({
    required String podspecContent,
    required PluginLanguage pluginLanguage,
    required bool addModuleMapLineIfMissing,
    required bool addPublicHeadersLineIfMissing,
    bool didAutoSplitMixedPlugin = false,
  }) {
    final pluginName = context.pluginName;
    final hasObjcSources = pluginLanguage.hasObjcSources;
    final hasSwiftSources = pluginLanguage.hasSwiftSources;
    final hasPrivacyManifest = context.spmPrivacyFile.existsSync();

    final lines = podspecContent.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#')) {
        // Never modify commented podspec lines.
        continue;
      }

      // Replace Classes/ → plugin_name/Sources/plugin_name/
      var updated = line.replaceAllMapped(
        RegExp(r'''(['"])Classes/'''),
        (m) => '${m.group(1)}$pluginName/Sources/$pluginName/',
      );

      // Replace Resources/ and Assets/ similarly if referenced directly.
      updated = updated.replaceAllMapped(
        RegExp(r'''(['"])(Resources|Assets)/'''),
        (m) => '${m.group(1)}$pluginName/Sources/$pluginName/${m.group(2)}/',
      );

      // Bare `'PrivacyInfo.xcprivacy'` references (typical in `s.resources`)
      // must be rewritten to the new SwiftPM-layout path — the file was moved
      // out of ios/ into Sources/<plugin>/ by IosDirectoryRefactor.
      if (hasPrivacyManifest) {
        updated = updated.replaceAllMapped(
          RegExp(r'''(['"])PrivacyInfo\.xcprivacy(['"])'''),
          (m) =>
              '${m.group(1)}$pluginName/Sources/$pluginName/PrivacyInfo.xcprivacy${m.group(2)}',
        );
      }

      lines[i] = updated;
    }

    var out = lines.join('\n');

    // If podspec already has a too-broad `source_files` (like `**/*`), narrow it.
    // Otherwise CocoaPods may treat resources (e.g. `Contents.json` in xcassets)
    // as source files and fail during `pod install`.
    out = normalizePodspecSourceFiles(
      out,
      hasObjcSources: hasObjcSources,
      hasSwiftSources: hasSwiftSources,
    );

    // Ensure source_files points to the new path if it still references Classes.
    // If the podspec doesn't have source_files, add a conservative one.
    if (!RegExp(r'^\s*s\.source_files\s*=', multiLine: true).hasMatch(out)) {
      final insert = hasObjcSources
          ? (hasSwiftSources
              ? "  s.source_files = '$pluginName/Sources/**/*.{h,m,mm,cpp,swift}'\n"
              : "  s.source_files = '$pluginName/Sources/$pluginName/**/*.{h,m,mm,cpp}'\n")
          : "  s.source_files = '$pluginName/Sources/$pluginName/**/*.swift'\n";
      out = insertBeforeFinalEnd(out, insert);
    }

    if (hasObjcSources && addPublicHeadersLineIfMissing) {
      final objcSourcesTarget =
          didAutoSplitMixedPlugin ? '${pluginName}_objc' : pluginName;
      final publicHeadersLine =
          "  s.public_header_files = '$pluginName/Sources/$objcSourcesTarget/include/**/*.h'";
      final re = RegExp(r'^\s*s\.public_header_files\s*=.*$', multiLine: true);
      if (re.hasMatch(out)) {
        out = out.replaceAll(re, publicHeadersLine);
      }
    }

    if (hasObjcSources) {
      final objcSourcesTarget =
          didAutoSplitMixedPlugin ? '${pluginName}_objc' : pluginName;
      final moduleMapLine =
          "  s.module_map = '$pluginName/Sources/$objcSourcesTarget/include/cocoapods_$pluginName.modulemap'\n";

      // If the podspec already had a module_map line, rewrite it to match the
      // renamed location we create during migration.
      final moduleMapRe = RegExp(r'^\s*s\.module_map\s*=.*$', multiLine: true);
      if (moduleMapRe.hasMatch(out)) {
        out = out.replaceAll(moduleMapRe, moduleMapLine.trimRight());
      } else if (addModuleMapLineIfMissing) {
        out = insertBeforeFinalEnd(out, moduleMapLine);
      }
    }

    // Only add resource_bundles for privacy if it isn't present already (don't
    // risk overriding custom resource_bundles hashes).
    if (hasPrivacyManifest) {
      final hasResourceBundles = RegExp(
        r'^\s*s\.resource_bundles\s*=',
        multiLine: true,
      ).hasMatch(out);
      final hasCommentedResourceBundles = RegExp(
        r'^\s*#\s*s\.resource_bundles\s*=',
        multiLine: true,
      ).hasMatch(out);

      if (!hasResourceBundles && !hasCommentedResourceBundles) {
        out = insertBeforeFinalEnd(
          out,
          "  s.resource_bundles = {'${pluginName}_privacy' => ['$pluginName/Sources/$pluginName/PrivacyInfo.xcprivacy']}\n",
        );
      }
    }

    return out;
  }

  /// Narrows overly broad `s.source_files` patterns to file-type-aware globs.
  String normalizePodspecSourceFiles(
    String podspec, {
    required bool hasObjcSources,
    required bool hasSwiftSources,
  }) {
    final pluginName = context.pluginName;
    final re = RegExp(
      r'''^(\s*)s\.source_files\s*=\s*(['"])([^'"]+)\2\s*$''',
      multiLine: true,
    );

    String replacementForBroad(String indent) {
      if (hasObjcSources && hasSwiftSources) {
        return "${indent}s.source_files = '$pluginName/Sources/**/*.{h,m,mm,cpp,swift}'";
      }
      if (hasObjcSources) {
        return "${indent}s.source_files = '$pluginName/Sources/$pluginName/**/*.{h,m,mm,cpp}'";
      }
      return "${indent}s.source_files = '$pluginName/Sources/$pluginName/**/*.swift'";
    }

    return podspec.replaceAllMapped(re, (m) {
      final indent = m.group(1) ?? '';
      final value = (m.group(3) ?? '').trim();

      // Don't touch commented lines (regex anchors on `s.` so this is defensive).
      if (value.startsWith('#')) return m.group(0)!;

      final isBroad = value.endsWith('/**/*') ||
          value.contains('/**/*') ||
          value.endsWith('**/*');
      final alreadyConstrained = value.contains('{') ||
          value.contains('}.') ||
          value.contains('**/*.') ||
          value.contains('.swift');

      if (isBroad && !alreadyConstrained) {
        return replacementForBroad(indent);
      }

      return m.group(0)!;
    });
  }

  /// Inserts [insertion] immediately before the final `end` in podspec text.
  String insertBeforeFinalEnd(String content, String insertion) {
    final endRe = RegExp(r'^\s*end\s*$', multiLine: true);
    final matches = endRe.allMatches(content).toList();
    if (matches.isEmpty) {
      return '$content\n$insertion';
    }
    final last = matches.last;
    return content.replaceRange(last.start, last.start, insertion);
  }

  /// Removes ObjC-only podspec directives for Swift-only migration mode.
  String removeObjcSpecificLinesFromPodspec(String podspec) {
    final lines = podspec.split('\n');
    final filtered = lines.where((line) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#')) return true;
      if (RegExp(r'^s\.public_header_files\s*=').hasMatch(trimmed))
        return false;
      if (RegExp(r'^s\.module_map\s*=').hasMatch(trimmed)) return false;
      return true;
    }).toList(growable: false);
    return filtered.join('\n');
  }
}
