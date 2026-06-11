import 'dart:io';

import 'package:spm_plugin_migration/spm_plugin_migration.dart';

final _fs = FileSystemUtils();

/// Migrates a Flutter plugin iOS implementation from the legacy CocoaPods-only
/// layout to the Swift Package Manager compatible layout, while keeping CocoaPods
/// support working (by updating the `.podspec` paths).
///
/// Based on Flutter docs:
/// https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-plugin-authors
///
/// Usage:
///   dart bin/spm_plugin_migration.dart /abs/path/to/plugin
Future<void> main(List<String> args) async {
  if (args.length != 1 || args.single.trim().isEmpty) {
    stdout.writeln(
      'Usage:\n'
      '  dart bin/spm_plugin_migration.dart /abs/path/to/plugin\n',
    );
    exit(64);
  }

  final pluginRootPath = _fs.normalizePath(args.single);
  final pluginDir = Directory(pluginRootPath);

  final context = IosPluginContext.fromPackagePath(pluginRootPath);
  final pluginName = context.pluginName;
  final iosDir = context.iosDir;
  final podspec = context.podspecFile;

  stdout.writeln('Plugin: $pluginName');
  stdout.writeln('iOS dir: ${iosDir.path}');
  stdout.writeln('Podspec: ${context.podspecFile.path}');

  final podspecContent = podspec.readAsStringSync();
  final podspecParser = PodspecParser(podspecContent);
  final iosDeploymentTarget =
      podspecParser.extractIosDeploymentTarget() ?? '13.0';
  final detectedPodsDependencies = podspecParser.extractCocoaPodsDependencies();
  final declaredResourceBundleNames =
      podspecParser.extractResourceBundleNamesFromPodspec();

  // Plugins targeting Flutter >= 3.41 should declare a direct SwiftPM
  // dependency on the local FlutterFramework package (see Flutter docs).
  final pubspecFile = context.pubspecFile;
  final needsFlutterFramework = pubspecFile.existsSync() &&
      PubspecParser(pubspecFile.readAsStringSync())
          .requiresFlutterFrameworkSwiftPackage();
  if (needsFlutterFramework) {
    stdout.writeln(
      'Flutter >= 3.41 detected — adding local FlutterFramework SwiftPM dependency.',
    );
  }
  if (detectedPodsDependencies.isNotEmpty) {
    stdout.writeln(
      '\nNOTICE: Found CocoaPods dependencies in .podspec that must be manually ported to Swift Package Manager:',
    );
    for (final dep in detectedPodsDependencies) {
      stdout.writeln(
        '  - ${dep.name}${dep.constraint != null ? ' (${dep.constraint})' : ''}',
      );
    }
  }

  final classesDir = context.classesDir;
  final assetsDir = context.assetsDir;
  final resourcesDir = context.resourcesDir;
  final spmTargetDir = context.spmTargetDir;

  // Determine whether this is an Objective-C plugin (needs headers layout) or a
  // Swift plugin (no publicHeadersPath/cSettings needed).
  final languageDetector = LanguageDetector(context, _fs);
  var pluginLanguage = languageDetector.detect();

  stdout.writeln(
    'Detected language: ${pluginLanguage.isMixedPlugin ? 'Mixed (Objective-C + Swift)' : (pluginLanguage.isObjcPlugin ? 'Objective-C' : 'Swift')}',
  );
  if (pluginLanguage.isMixedPlugin) {
    stdout.writeln(
      '\nNOTICE: Mixed language plugin detected (Objective-C + Swift). '
      'Swift Package Manager may require splitting sources into two separate targets (ObjC target + Swift target).\n'
      'See: https://stackoverflow.com/questions/51540665/swift-package-manager-mixed-language-source-files\n',
    );
  }

  // If your plugin uses Pigeon, update its output paths to the new iOS layout.
  PigeonRewriter().updatePigeonInputFiles(
    pluginDir: pluginDir,
    pluginName: pluginName,
    hasObjcSources: pluginLanguage.hasObjcSources,
  );

  // Moving files from Classes into Sources/<plugin_name>
  final iosDirectoryRefactor = IosDirectoryRefactor(
    context: context,
    fs: _fs,
    pluginLanguage: pluginLanguage,
  );
  iosDirectoryRefactor.refact();

  final spmPackageDir = context.spmPackageDir;
  final spmIncludeDir = context.spmIncludeDir;
  final spmIncludeModuleDir = context.spmIncludeModuleDir;

  final objcRewriter = ObjcRewriter(context, _fs);
  final swiftRewriter = SwiftRewriter(_fs);
  final namedBundleAnnotator = NamedBundleAnnotator(_fs);
  final wrapperFileMapper = WrapperFileMapper(context: context, fs: _fs);

  // Try to leave mixed mode by converting legacy ObjC wrapper files.
  bool didConvertOnlyPluginObjcToSwift = false;
  bool didAutoSplitMixedPlugin = false;
  if (pluginLanguage.isMixedPlugin) {
    final onlyPluginObjcFiles =
        wrapperFileMapper.isOnlyPluginWrapperObjcFiles();

    if (onlyPluginObjcFiles) {
      didConvertOnlyPluginObjcToSwift =
          wrapperFileMapper.convertOnlyPluginObjcToSwiftSpecialCase();
    }

    if (!didConvertOnlyPluginObjcToSwift) {
      didAutoSplitMixedPlugin =
          iosDirectoryRefactor.autoSplitMixedPluginForSwiftPm();
    } else {
      pluginLanguage = PluginLanguage.swift;
    }

    if (didAutoSplitMixedPlugin) {
      stderr.writeln(
        '\nWARNING: Plugin was split into "${pluginName}" (Swift) and "${context.objcTargetName}" (ObjC) '
        'SwiftPM targets. Swift files that reference types declared in the ObjC target must add:\n'
        '    import ${context.objcTargetName}\n'
        'Missing this import causes "Cannot find type … in scope" compiler errors.',
      );

      swiftRewriter.ensureSwiftPackageObjcImportsInSwiftTarget(
        swiftTargetDir: spmTargetDir,
        objcTargetDir: context.objcTargetDir,
        objcModuleName: context.objcTargetName,
      );
    }
  }

  final hasSwiftSources = pluginLanguage.hasSwiftSources;
  final hasObjcSources = pluginLanguage.hasObjcSources;
  final isMixedPlugin = pluginLanguage.isMixedPlugin;

  if (!hasObjcSources) {
    _fs.removeDirIfExists(spmIncludeDir);
  }

  if (isMixedPlugin) {
    wrapperFileMapper.ensureSwiftPmRegistrationStub();
  }

  // Create/Update Package.swift.
  final packageSwift = context.packageSwift;
  final packageSwiftNewContent = PackageSwiftRenderer(
    context: context,
    fs: _fs,
  ).render(
    PackageSwiftRenderInput(
      pluginLanguage: pluginLanguage,
      iosDeploymentTarget: iosDeploymentTarget,
      didAutoSplitMixedPlugin: didAutoSplitMixedPlugin,
      cocoaPodsDependencies: detectedPodsDependencies,
      needsFlutterFramework: needsFlutterFramework,
    ),
  );

  if (packageSwift.existsSync()) {
    stderr.writeln(
      'WARNING: Package.swift already exists. Skipping update: ${packageSwift.path}',
    );
  } else {
    stdout.writeln('Creating Package.swift: ${packageSwift.path}');
    packageSwift.writeAsStringSync(packageSwiftNewContent);
  }

  // Swift: after moving sources into Sources/<plugin_name>, ensure `import Flutter`
  // exists where Flutter types are used. (Calling this earlier doesn't work
  // because Swift sources usually still live in ios/Classes at that point.)
  if (hasSwiftSources) {
    swiftRewriter.ensureMissingFrameworkImportsInSwiftTarget(spmTargetDir);
  }

  // Named CocoaPods resource bundle lookups need a TODO comment in both Swift
  // and ObjC sources (the annotator walks .swift/.m/.mm/.h/.hh).
  if (declaredResourceBundleNames.isNotEmpty) {
    namedBundleAnnotator.annotate(
      sourceRoot: spmPackageDir,
      bundleNames: declaredResourceBundleNames,
    );
  }

  // Objective-C: after moving headers into include/, update imports in .m/.mm
  // files to point to ./include/<plugin_name>/...
  if (hasObjcSources) {
    final dirToRewrite =
        didAutoSplitMixedPlugin ? context.objcTargetDir : spmTargetDir;
    final includeToUse = didAutoSplitMixedPlugin
        ? context.objcIncludeModuleDir
        : spmIncludeModuleDir;

    objcRewriter.rewriteImportsToInclude(
      spmTargetDirOverride: dirToRewrite,
      spmIncludeModuleDirOverride: includeToUse,
    );

    objcRewriter.rewriteExternalDependencyImports(
      objcSourceDir: dirToRewrite,
      externalDependencyNames: detectedPodsDependencies.map((d) => d.name),
    );
  }

  // Update podspec paths to point to ios/<plugin_name>/Sources/<plugin_name>/...
  stdout.writeln('Updating podspec paths for CocoaPods compatibility...');
  final podspecUpdater = PodspecUpdater(context, _fs);
  final podspecContentForUpdate = didConvertOnlyPluginObjcToSwift
      ? podspecUpdater.removeObjcSpecificLinesFromPodspec(podspecContent)
      : podspecContent;
  final modulemapForPodspec = didAutoSplitMixedPlugin
      ? context.objcCocoapodsModulemapFile
      : context.spmCocoapodsModulemapFile;
  final updatedPodspec = podspecUpdater.updatePodspecPaths(
    podspecContent: podspecContentForUpdate,
    pluginLanguage: pluginLanguage,
    addModuleMapLineIfMissing:
        hasObjcSources && modulemapForPodspec.existsSync(),
    addPublicHeadersLineIfMissing: hasObjcSources,
    didAutoSplitMixedPlugin: didAutoSplitMixedPlugin,
  );
  podspec.writeAsStringSync(updatedPodspec);
  stdout.writeln('Podspec updated.');

  // Cleanup empty legacy directories if they still exist.
  _fs.deleteDirIfEmpty(classesDir);
  _fs.deleteDirIfEmpty(assetsDir);
  _fs.deleteDirIfEmpty(resourcesDir);

  stdout.writeln('Done.');
}
