import 'dart:io';

import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

bool _noopArc(String _, String __) => false;

void main() {
  group('IosDirectoryRefactor.refact', () {
    test('moves sources/resources and relocates objc headers/modulemap',
        () async {
      await dir('ios_refactor/full', [
        dir('ios', [
          dir('Classes', [
            file('Plugin.m', '@implementation Plugin @end'),
            file('Plugin.h', '@interface Plugin : NSObject @end'),
            file('cocoapods_my_plugin.modulemap', 'module my_plugin {}'),
          ]),
          dir('Assets', [
            file('asset.txt', 'asset'),
          ]),
          dir('Resources', [
            file('resource.txt', 'resource'),
          ]),
          file('PrivacyInfo.xcprivacy', '{}'),
        ]),
      ]).create();

      final fs = FileSystemUtils(moveFile: _noopArc);
      final context =
          IosPluginContext(path('ios_refactor/full/ios'), 'my_plugin');
      final refactor = IosDirectoryRefactor(
        context: context,
        fs: fs,
        pluginLanguage: PluginLanguage.objectiveC,
      );

      refactor.refact();

      expect(
        File(path(
          'ios_refactor/full/ios/my_plugin/Sources/my_plugin/Plugin.m',
        )).existsSync(),
        isTrue,
      );
      expect(
        File(path(
          'ios_refactor/full/ios/my_plugin/Sources/my_plugin/include/my_plugin/Plugin.h',
        )).existsSync(),
        isTrue,
      );
      expect(
        File(path(
          'ios_refactor/full/ios/my_plugin/Sources/my_plugin/include/cocoapods_my_plugin.modulemap',
        )).existsSync(),
        isTrue,
      );
      expect(
        File(path(
          'ios_refactor/full/ios/my_plugin/Sources/my_plugin/Assets/asset.txt',
        )).readAsStringSync(),
        'asset',
      );
      expect(
        File(path(
          'ios_refactor/full/ios/my_plugin/Sources/my_plugin/Resources/resource.txt',
        )).readAsStringSync(),
        'resource',
      );
      expect(
        File(path(
          'ios_refactor/full/ios/my_plugin/Sources/my_plugin/PrivacyInfo.xcprivacy',
        )).existsSync(),
        isTrue,
      );
      expect(Directory(path('ios_refactor/full/ios/Classes')).existsSync(),
          isFalse);
      expect(Directory(path('ios_refactor/full/ios/Assets')).existsSync(),
          isFalse);
      expect(Directory(path('ios_refactor/full/ios/Resources')).existsSync(),
          isFalse);
      expect(
        File(path('ios_refactor/full/ios/my_plugin/.gitignore'))
            .readAsStringSync(),
        allOf(contains('.build/'), contains('.swiftpm/')),
      );
    });

    test('keeps canonical cocoapods modulemap and removes extra modulemaps',
        () async {
      await dir('ios_refactor/modulemap_cleanup', [
        dir('ios', [
          dir('Classes', [
            file('Plugin.m', '@implementation Plugin @end'),
            file('Plugin.h', '@interface Plugin : NSObject @end'),
            file('cocoapods_my_plugin.modulemap', 'module my_plugin {}'),
            file('legacy.modulemap', 'module legacy {}'),
          ]),
        ]),
      ]).create();

      final fs = FileSystemUtils(moveFile: _noopArc);
      final context = IosPluginContext(
          path('ios_refactor/modulemap_cleanup/ios'), 'my_plugin');
      final refactor = IosDirectoryRefactor(
        context: context,
        fs: fs,
        pluginLanguage: PluginLanguage.objectiveC,
      );

      refactor.refact();

      expect(
        File(path(
          'ios_refactor/modulemap_cleanup/ios/my_plugin/Sources/my_plugin/include/cocoapods_my_plugin.modulemap',
        )).existsSync(),
        isTrue,
      );
      expect(
        File(path(
          'ios_refactor/modulemap_cleanup/ios/my_plugin/Sources/my_plugin/legacy.modulemap',
        )).existsSync(),
        isFalse,
      );
      expect(
        File(path(
          'ios_refactor/modulemap_cleanup/ios/my_plugin/Sources/my_plugin/include/legacy.modulemap',
        )).existsSync(),
        isFalse,
      );
    });
  });

  group('IosDirectoryRefactor.autoSplitMixedPluginForSwiftPm', () {
    test(
        'splits mixed Swift+ObjC plugin, moves include/ to ObjC target and '
        'rewrites imports without crashing on moved-away include dir',
        () async {
      await dir('ios_refactor/autosplit', [
        dir('ios', [
          dir('Classes', [
            file('Plugin.h', '@interface Plugin : NSObject @end'),
            file(
              'Plugin.m',
              '#import "Plugin.h"\n'
                  '@implementation Plugin @end\n',
            ),
            file(
              'SwiftFile.swift',
              'import Foundation\n'
                  'class SwiftFile {}\n',
            ),
          ]),
        ]),
      ]).create();

      final fs = FileSystemUtils(moveFile: _noopArc);
      final context =
          IosPluginContext(path('ios_refactor/autosplit/ios'), 'my_plugin');
      final refactor = IosDirectoryRefactor(
        context: context,
        fs: fs,
        pluginLanguage: PluginLanguage.mixed,
      );

      refactor.refact();
      final didSplit = refactor.autoSplitMixedPluginForSwiftPm();

      expect(didSplit, isTrue);

      // Swift file stays in Swift target.
      expect(
        File(path(
          'ios_refactor/autosplit/ios/my_plugin/Sources/my_plugin/SwiftFile.swift',
        )).existsSync(),
        isTrue,
      );
      // ObjC source moves to split ObjC target.
      expect(
        File(path(
          'ios_refactor/autosplit/ios/my_plugin/Sources/my_plugin_objc/Plugin.m',
        )).existsSync(),
        isTrue,
      );
      // Public header lives under ObjC target's include/<plugin>/.
      expect(
        File(path(
          'ios_refactor/autosplit/ios/my_plugin/Sources/my_plugin_objc/include/my_plugin/Plugin.h',
        )).existsSync(),
        isTrue,
      );
      // Swift target's include/ is gone after the move.
      expect(
        Directory(path(
          'ios_refactor/autosplit/ios/my_plugin/Sources/my_plugin/include',
        )).existsSync(),
        isFalse,
      );
      // Imports in moved ObjC file are rewritten to point into ObjC target's
      // include tree (regression: previously crashed with PathNotFoundException
      // because rewriteImportsToInclude used stale Swift-target defaults).
      final pluginMContent = File(path(
        'ios_refactor/autosplit/ios/my_plugin/Sources/my_plugin_objc/Plugin.m',
      )).readAsStringSync();
      expect(pluginMContent, contains('./include/my_plugin/Plugin.h'));
    });

    test('is idempotent: returns true without re-splitting when already split',
        () async {
      await dir('ios_refactor/autosplit_idempotent', [
        dir('ios', [
          dir('Classes', [
            file('Plugin.h', '@interface Plugin : NSObject @end'),
            file('Plugin.m', '#import "Plugin.h"\n@implementation Plugin @end'),
            file('SwiftFile.swift', 'class SwiftFile {}'),
          ]),
        ]),
      ]).create();

      final fs = FileSystemUtils(moveFile: _noopArc);
      final context = IosPluginContext(
        path('ios_refactor/autosplit_idempotent/ios'),
        'my_plugin',
      );
      final refactor = IosDirectoryRefactor(
        context: context,
        fs: fs,
        pluginLanguage: PluginLanguage.mixed,
      );

      refactor.refact();
      expect(refactor.autoSplitMixedPluginForSwiftPm(), isTrue);
      // Second call: should detect the existing split and short-circuit.
      expect(refactor.autoSplitMixedPluginForSwiftPm(), isTrue);
    });
  });
}
