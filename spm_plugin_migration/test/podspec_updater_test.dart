import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

const _baseFlags = (
  hasPrivacyManifest: false,
  addModuleMapLineIfMissing: false,
  addPublicHeadersLineIfMissing: false,
);

PluginLanguage _pluginLanguage({
  required bool hasObjcSources,
  required bool hasSwiftSources,
}) {
  if (hasObjcSources && hasSwiftSources) return PluginLanguage.mixed;
  if (hasObjcSources) return PluginLanguage.objectiveC;
  return PluginLanguage.swift;
}

PodspecUpdater _podspecUpdater(
  String iosDir,
  String pluginName, {
  required bool hasPrivacyManifest,
}) {
  if (hasPrivacyManifest) {
    final privacy = File(
      p.join(
          iosDir, pluginName, 'Sources', pluginName, 'PrivacyInfo.xcprivacy'),
    );
    privacy.createSync(recursive: true);
    privacy.writeAsStringSync('<?xml version="1.0"?><plist></plist>');
  }
  return PodspecUpdater(
    IosPluginContext(iosDir, pluginName),
    FileSystemUtils(),
  );
}

Future<void> _writeUpdatedPodspec({
  required String caseDir,
  required String Function(String text) apply,
}) async {
  final text = File(path('$caseDir/in.podspec')).readAsStringSync();
  File(path('$caseDir/out.podspec')).writeAsStringSync(apply(text));
}

void main() {
  group('updatePodspecPaths', () {
    test(
        'replaces Classes/, Resources/, and Assets/ prefixes; skips commented lines',
        () async {
      await dir('upd/replace_paths', [
        file('in.podspec', '''
Pod::Spec.new do |s|
  s.source_files = 'Classes/**/*.swift'
  s.resources = 'Resources/*.png'
  s.assets = 'Assets/catalog.xcassets'
  # s.source_files = 'Classes/**/*.m'
  # s.resources = 'Resources/ignored.png'
end
'''),
      ]).create();

      final iosDir = path('upd/replace_paths/_ios');
      final updater = _podspecUpdater(
        iosDir,
        'my_plugin',
        hasPrivacyManifest: _baseFlags.hasPrivacyManifest,
      );
      await _writeUpdatedPodspec(
        caseDir: 'upd/replace_paths',
        apply: (t) => updater.updatePodspecPaths(
          podspecContent: t,
          pluginLanguage: _pluginLanguage(
            hasObjcSources: false,
            hasSwiftSources: false,
          ),
          addModuleMapLineIfMissing: _baseFlags.addModuleMapLineIfMissing,
          addPublicHeadersLineIfMissing:
              _baseFlags.addPublicHeadersLineIfMissing,
        ),
      );

      await file(
        'upd/replace_paths/out.podspec',
        allOf([
          contains("s.source_files = 'my_plugin/Sources/my_plugin/**/*.swift'"),
          contains(
              "s.resources = 'my_plugin/Sources/my_plugin/Resources/*.png'"),
          contains(
              "s.assets = 'my_plugin/Sources/my_plugin/Assets/catalog.xcassets'"),
          contains("# s.source_files = 'Classes/**/*.m'"),
          contains("# s.resources = 'Resources/ignored.png'"),
        ]),
      ).validate();
    });

    test(
        'rewrites bare PrivacyInfo.xcprivacy in s.resources to the SwiftPM-layout path',
        () async {
      await dir('upd/privacy_resources', [
        file('in.podspec', '''
Pod::Spec.new do |s|
  s.resources = ['PrivacyInfo.xcprivacy']
  s.resource_bundles = { 'X' => ['Assets/**/*'] }
  # s.resources = ['PrivacyInfo.xcprivacy']
end
'''),
      ]).create();

      final updater = _podspecUpdater(
        path('upd/privacy_resources/_ios'),
        'my_plugin',
        hasPrivacyManifest: true,
      );
      await _writeUpdatedPodspec(
        caseDir: 'upd/privacy_resources',
        apply: (t) => updater.updatePodspecPaths(
          podspecContent: t,
          pluginLanguage: _pluginLanguage(
            hasObjcSources: false,
            hasSwiftSources: true,
          ),
          addModuleMapLineIfMissing: false,
          addPublicHeadersLineIfMissing: false,
        ),
      );

      await file(
        'upd/privacy_resources/out.podspec',
        allOf([
          // Bare reference rewritten to new path.
          contains(
              "s.resources = ['my_plugin/Sources/my_plugin/PrivacyInfo.xcprivacy']"),
          // Commented line untouched.
          contains("# s.resources = ['PrivacyInfo.xcprivacy']"),
          // No double-prefix slip-up like '.../Sources/my_plugin/my_plugin/...'.
          isNot(contains('my_plugin/my_plugin/PrivacyInfo')),
        ]),
      ).validate();
    });

    test(
        'leaves PrivacyInfo.xcprivacy untouched when the privacy manifest is absent',
        () async {
      await dir('upd/privacy_resources_off', [
        file('in.podspec', '''
Pod::Spec.new do |s|
  s.resources = ['PrivacyInfo.xcprivacy']
end
'''),
      ]).create();

      final updater = _podspecUpdater(
        path('upd/privacy_resources_off/_ios'),
        'my_plugin',
        hasPrivacyManifest: false,
      );
      await _writeUpdatedPodspec(
        caseDir: 'upd/privacy_resources_off',
        apply: (t) => updater.updatePodspecPaths(
          podspecContent: t,
          pluginLanguage: _pluginLanguage(
            hasObjcSources: false,
            hasSwiftSources: true,
          ),
          addModuleMapLineIfMissing: false,
          addPublicHeadersLineIfMissing: false,
        ),
      );

      await file(
        'upd/privacy_resources_off/out.podspec',
        contains("s.resources = ['PrivacyInfo.xcprivacy']"),
      ).validate();
    });

    test('inserts s.source_files before final end when line is absent',
        () async {
      await dir('upd/insert_source', [
        file('in.podspec', '''
Pod::Spec.new do |s|
  s.name = 'my_plugin'
end
'''),
      ]).create();

      final updater = _podspecUpdater(
        path('upd/insert_source/_ios'),
        'my_plugin',
        hasPrivacyManifest: _baseFlags.hasPrivacyManifest,
      );
      await _writeUpdatedPodspec(
        caseDir: 'upd/insert_source',
        apply: (t) => updater.updatePodspecPaths(
          podspecContent: t,
          pluginLanguage: _pluginLanguage(
            hasObjcSources: false,
            hasSwiftSources: false,
          ),
          addModuleMapLineIfMissing: _baseFlags.addModuleMapLineIfMissing,
          addPublicHeadersLineIfMissing:
              _baseFlags.addPublicHeadersLineIfMissing,
        ),
      );

      final out =
          File(path('upd/insert_source/out.podspec')).readAsStringSync();
      final lines = out.split('\n');
      final endIdx = lines.lastIndexWhere((l) => l.trim() == 'end');
      final sourceIdx = lines.indexWhere(
        (l) =>
            l.contains('s.source_files') &&
            l.contains('my_plugin/Sources/my_plugin'),
      );
      File(path('upd/insert_source/order.txt')).writeAsStringSync(
        '${sourceIdx >= 0}\n${sourceIdx < endIdx}',
      );

      await file(
        'upd/insert_source/out.podspec',
        contains("  s.source_files = 'my_plugin/Sources/my_plugin/**/*.swift'"),
      ).validate();
      await file('upd/insert_source/order.txt', equals('true\ntrue'))
          .validate();
    });

    test('inserts ObjC source_files pattern when plugin is ObjC-only',
        () async {
      await dir('upd/insert_objc', [
        file('in.podspec', '''
Pod::Spec.new do |s|
  s.name = 'my_plugin'
end
'''),
      ]).create();

      final updater = _podspecUpdater(
        path('upd/insert_objc/_ios'),
        'my_plugin',
        hasPrivacyManifest: _baseFlags.hasPrivacyManifest,
      );
      await _writeUpdatedPodspec(
        caseDir: 'upd/insert_objc',
        apply: (t) => updater.updatePodspecPaths(
          podspecContent: t,
          pluginLanguage: _pluginLanguage(
            hasObjcSources: true,
            hasSwiftSources: false,
          ),
          addModuleMapLineIfMissing: _baseFlags.addModuleMapLineIfMissing,
          addPublicHeadersLineIfMissing:
              _baseFlags.addPublicHeadersLineIfMissing,
        ),
      );

      await file(
        'upd/insert_objc/out.podspec',
        contains(
          "  s.source_files = 'my_plugin/Sources/my_plugin/**/*.{h,m,mm,cpp}'",
        ),
      ).validate();
    });

    test(
        'rewrites public_header_files and module_map for ObjC; inserts module_map if missing',
        () async {
      await dir('upd/objc_rewrite', [
        file('with_both.podspec', '''
Pod::Spec.new do |s|
  s.name = 'my_plugin'
  s.source_files = '**/*'
  s.public_header_files = 'old/**/*.h'
  s.module_map = 'wrong.modulemap'
end
'''),
        file('no_module.podspec', '''
Pod::Spec.new do |s|
  s.name = 'my_plugin'
  s.source_files = 'foo/**/*'
end
'''),
      ]).create();

      final objcUpdater = _podspecUpdater(
        path('upd/objc_rewrite/_ios'),
        'my_plugin',
        hasPrivacyManifest: _baseFlags.hasPrivacyManifest,
      );
      final t1 =
          File(path('upd/objc_rewrite/with_both.podspec')).readAsStringSync();
      File(path('upd/objc_rewrite/out_rewrite.podspec')).writeAsStringSync(
        objcUpdater.updatePodspecPaths(
          podspecContent: t1,
          pluginLanguage: _pluginLanguage(
            hasObjcSources: true,
            hasSwiftSources: false,
          ),
          addModuleMapLineIfMissing: true,
          addPublicHeadersLineIfMissing: true,
        ),
      );

      await file(
        'upd/objc_rewrite/out_rewrite.podspec',
        allOf([
          contains(
            "s.public_header_files = "
            "'my_plugin/Sources/my_plugin/include/**/*.h'",
          ),
          contains(
            "s.module_map = "
            "'my_plugin/Sources/my_plugin/include/cocoapods_my_plugin.modulemap'",
          ),
          isNot(contains('wrong.modulemap')),
        ]),
      ).validate();

      final t2 =
          File(path('upd/objc_rewrite/no_module.podspec')).readAsStringSync();
      File(path('upd/objc_rewrite/out_insert.podspec')).writeAsStringSync(
        objcUpdater.updatePodspecPaths(
          podspecContent: t2,
          pluginLanguage: _pluginLanguage(
            hasObjcSources: true,
            hasSwiftSources: false,
          ),
          addModuleMapLineIfMissing: true,
          addPublicHeadersLineIfMissing: false,
        ),
      );

      await file(
        'upd/objc_rewrite/out_insert.podspec',
        contains(
          "s.module_map = "
          "'my_plugin/Sources/my_plugin/include/cocoapods_my_plugin.modulemap'",
        ),
      ).validate();
    });

    test(
        'rewrites existing module_map even when addModuleMapLineIfMissing is false',
        () async {
      await dir('upd/objc_modulemap_rewrite_without_insert', [
        file('in.podspec', '''
Pod::Spec.new do |s|
  s.name = 'my_plugin'
  s.module_map = 'legacy/path/custom.modulemap'
end
'''),
      ]).create();

      final updater = _podspecUpdater(
        path('upd/objc_modulemap_rewrite_without_insert/_ios'),
        'my_plugin',
        hasPrivacyManifest: _baseFlags.hasPrivacyManifest,
      );
      await _writeUpdatedPodspec(
        caseDir: 'upd/objc_modulemap_rewrite_without_insert',
        apply: (t) => updater.updatePodspecPaths(
          podspecContent: t,
          pluginLanguage: _pluginLanguage(
            hasObjcSources: true,
            hasSwiftSources: false,
          ),
          addModuleMapLineIfMissing: false,
          addPublicHeadersLineIfMissing: false,
        ),
      );

      await file(
        'upd/objc_modulemap_rewrite_without_insert/out.podspec',
        allOf([
          contains(
            "s.module_map = 'my_plugin/Sources/my_plugin/include/cocoapods_my_plugin.modulemap'",
          ),
          isNot(contains('legacy/path/custom.modulemap')),
        ]),
      ).validate();
    });

    test(
        'adds privacy resource_bundles when manifest flag set and none present',
        () async {
      await dir('upd/privacy_add', [
        file('in.podspec', '''
Pod::Spec.new do |s|
  s.name = 'my_plugin'
  s.source_files = 'my_plugin/Sources/my_plugin/**/*.swift'
end
'''),
      ]).create();

      final privacyUpdater = _podspecUpdater(
        path('upd/privacy_add/ios'),
        'my_plugin',
        hasPrivacyManifest: true,
      );
      await _writeUpdatedPodspec(
        caseDir: 'upd/privacy_add',
        apply: (t) => privacyUpdater.updatePodspecPaths(
          podspecContent: t,
          pluginLanguage: _pluginLanguage(
            hasObjcSources: false,
            hasSwiftSources: false,
          ),
          addModuleMapLineIfMissing: false,
          addPublicHeadersLineIfMissing: false,
        ),
      );

      await file(
        'upd/privacy_add/out.podspec',
        contains(
          "s.resource_bundles = {'my_plugin_privacy' => "
          "['my_plugin/Sources/my_plugin/PrivacyInfo.xcprivacy']}",
        ),
      ).validate();
    });

    test('does not add resource_bundles when line is only in a comment',
        () async {
      await dir('upd/privacy_skip', [
        file('in.podspec', '''
Pod::Spec.new do |s|
  s.name = 'my_plugin'
  s.source_files = 'my_plugin/Sources/my_plugin/**/*.swift'
  # s.resource_bundles = { 'foo' => [] }
end
'''),
      ]).create();

      final privacyUpdater = _podspecUpdater(
        path('upd/privacy_skip/ios'),
        'my_plugin',
        hasPrivacyManifest: true,
      );
      await _writeUpdatedPodspec(
        caseDir: 'upd/privacy_skip',
        apply: (t) => privacyUpdater.updatePodspecPaths(
          podspecContent: t,
          pluginLanguage: _pluginLanguage(
            hasObjcSources: false,
            hasSwiftSources: false,
          ),
          addModuleMapLineIfMissing: false,
          addPublicHeadersLineIfMissing: false,
        ),
      );

      await file(
        'upd/privacy_skip/out.podspec',
        isNot(contains('my_plugin_privacy')),
      ).validate();
    });
  });

  group('normalizePodspecSourceFiles', () {
    test('narrows overly broad **/* pattern', () async {
      await dir('norm/broad', [
        file('in.podspec',
            "Pod::Spec.new do |s|\n  s.source_files = '**/*'\nend\n"),
      ]).create();
      final norm = PodspecUpdater(
        IosPluginContext('_ios', 'x'),
        FileSystemUtils(),
      );
      final t = File(path('norm/broad/in.podspec')).readAsStringSync();
      File(path('norm/broad/out.podspec')).writeAsStringSync(
        norm.normalizePodspecSourceFiles(
          t,
          hasObjcSources: false,
          hasSwiftSources: false,
        ),
      );
      await file(
        'norm/broad/out.podspec',
        allOf([
          contains("s.source_files = 'x/Sources/x/**/*.swift'"),
          isNot(contains("= '**/*'")),
        ]),
      ).validate();
    });

    test('leaves already-specific patterns unchanged', () async {
      await dir('norm/specific', [
        file('in.podspec',
            "Pod::Spec.new do |s|\n  s.source_files = 'Pkg/**/*.swift'\nend\n"),
      ]).create();
      final norm = PodspecUpdater(
        IosPluginContext('_ios', 'x'),
        FileSystemUtils(),
      );
      final t = File(path('norm/specific/in.podspec')).readAsStringSync();
      File(path('norm/specific/out.podspec')).writeAsStringSync(
        norm.normalizePodspecSourceFiles(
          t,
          hasObjcSources: false,
          hasSwiftSources: false,
        ),
      );
      await file(
        'norm/specific/out.podspec',
        contains("s.source_files = 'Pkg/**/*.swift'"),
      ).validate();
    });

    test(
        'rewrites bare PrivacyInfo.xcprivacy references to the new SwiftPM path '
        'when the privacy manifest exists in the SwiftPM layout', () async {
      await dir('upd/privacy_resources', [
        file('in.podspec', '''
Pod::Spec.new do |s|
  s.name             = 'my_plugin'
  s.source_files     = 'Classes/**/*'
  s.resources        = ['PrivacyInfo.xcprivacy']
  # s.resources      = ['PrivacyInfo.xcprivacy']
end
'''),
      ]).create();

      final updater = _podspecUpdater(
        path('upd/privacy_resources/_ios'),
        'my_plugin',
        hasPrivacyManifest: true,
      );
      await _writeUpdatedPodspec(
        caseDir: 'upd/privacy_resources',
        apply: (t) => updater.updatePodspecPaths(
          podspecContent: t,
          pluginLanguage: _pluginLanguage(
            hasObjcSources: false,
            hasSwiftSources: true,
          ),
          addModuleMapLineIfMissing: false,
          addPublicHeadersLineIfMissing: false,
        ),
      );

      await file(
        'upd/privacy_resources/out.podspec',
        allOf([
          // Bare reference rewritten.
          contains(
            "s.resources        = ['my_plugin/Sources/my_plugin/PrivacyInfo.xcprivacy']",
          ),
          // Commented line untouched.
          contains("# s.resources      = ['PrivacyInfo.xcprivacy']"),
        ]),
      ).validate();
    });

    test(
        'leaves PrivacyInfo references that already carry a directory prefix '
        'alone (those are routed through the Classes/Resources/Assets rules)',
        () async {
      await dir('upd/privacy_prefixed', [
        file('in.podspec', '''
Pod::Spec.new do |s|
  s.resources = ['Resources/PrivacyInfo.xcprivacy']
end
'''),
      ]).create();

      final updater = _podspecUpdater(
        path('upd/privacy_prefixed/_ios'),
        'my_plugin',
        hasPrivacyManifest: true,
      );
      await _writeUpdatedPodspec(
        caseDir: 'upd/privacy_prefixed',
        apply: (t) => updater.updatePodspecPaths(
          podspecContent: t,
          pluginLanguage: _pluginLanguage(
            hasObjcSources: false,
            hasSwiftSources: true,
          ),
          addModuleMapLineIfMissing: false,
          addPublicHeadersLineIfMissing: false,
        ),
      );

      await file(
        'upd/privacy_prefixed/out.podspec',
        contains(
          "s.resources = ['my_plugin/Sources/my_plugin/Resources/PrivacyInfo.xcprivacy']",
        ),
      ).validate();
    });
  });

  group('removeObjcSpecificLinesFromPodspec', () {
    test('removes only s.public_header_files and s.module_map; keeps comments',
        () async {
      await dir('rmobjc/basic', [
        file('in.podspec', '''
  s.name = 'p'
  s.public_header_files = 'a/**/*.h'
  s.module_map = 'b.modulemap'
  # s.public_header_files = should stay
  # s.module_map = also stay
  s.other = 1
'''),
      ]).create();
      final rm = PodspecUpdater(
        IosPluginContext('_ios', 'p'),
        FileSystemUtils(),
      );
      final t = File(path('rmobjc/basic/in.podspec')).readAsStringSync();
      File(path('rmobjc/basic/out.podspec'))
          .writeAsStringSync(rm.removeObjcSpecificLinesFromPodspec(t));
      await file(
        'rmobjc/basic/out.podspec',
        allOf([
          isNot(contains("s.public_header_files = 'a/**/*.h'")),
          isNot(contains("s.module_map = 'b.modulemap'")),
          contains('# s.public_header_files = should stay'),
          contains('# s.module_map = also stay'),
          contains("s.other = 1"),
        ]),
      ).validate();
    });
  });
}
