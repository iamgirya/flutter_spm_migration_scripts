import 'dart:io';

import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

Future<void> _writePackageSwift(
  String caseDir,
  PackageSwiftRenderer renderer,
  PackageSwiftRenderInput input,
) async {
  File(path('$caseDir/Package.swift')).writeAsStringSync(
    renderer.render(input),
  );
}

PackageSwiftRenderer _renderer(IosPluginContext context,
        [FileSystemUtils? fs]) =>
    PackageSwiftRenderer(
      context: context,
      fs: fs ?? FileSystemUtils(),
    );

PackageSwiftRenderInput _input({
  String iosDeploymentTarget = '13.0',
  PluginLanguage pluginLanguage = PluginLanguage.swift,
  bool didAutoSplitMixedPlugin = false,
  List<PodDependency> cocoaPodsDependencies = const [],
  bool needsFlutterFramework = false,
}) {
  return PackageSwiftRenderInput(
    pluginLanguage: pluginLanguage,
    iosDeploymentTarget: iosDeploymentTarget,
    didAutoSplitMixedPlugin: didAutoSplitMixedPlugin,
    cocoaPodsDependencies: cocoaPodsDependencies,
    needsFlutterFramework: needsFlutterFramework,
  );
}

void main() {
  group('PackageSwiftRenderer.render', () {
    test('Swift-only plugin: single target, empty dependencies', () async {
      await dir('psw/swift_only', [
        dir('ios', [
          dir('foo_bar', [
            dir('Sources', [
              dir('foo_bar', []),
            ]),
          ]),
        ]),
      ]).create();

      await _writePackageSwift(
        'psw/swift_only',
        _renderer(IosPluginContext(path('psw/swift_only/ios'), 'foo_bar')),
        _input(),
      );

      await file(
        'psw/swift_only/Package.swift',
        allOf([
          contains('// swift-tools-version: 5.9'),
          contains('import PackageDescription'),
          contains('let package = Package('),
          contains('name: "foo_bar"'),
          contains('.library(name: "foo-bar", targets: ["foo_bar"])'),
          contains('dependencies: [],'),
          contains('name: "foo_bar",'),
          isNot(contains('foo_bar_objc')),
          isNot(contains(
            '// TODO: This package contains mixed Swift + Objective-C sources',
          )),
        ]),
      ).validate();

      final text =
          File(path('psw/swift_only/Package.swift')).readAsStringSync();
      final swiftTargetIdx = text.indexOf('name: "foo_bar"');
      expect(swiftTargetIdx, greaterThan(-1));
      expect(text.contains('name: "foo_bar_objc"'), false);
    });

    test(
      'ObjC-only plugin: cSettings, headerSearchPath, optional modulemap exclude',
      () async {
        await dir('psw/objc_only_modulemap', [
          dir('ios', [
            dir('objc_plug', [
              dir('Sources', [
                dir('objc_plug', [
                  dir('include', [
                    file('cocoapods_objc_plug.modulemap', ''),
                  ]),
                ]),
              ]),
            ]),
          ]),
        ]).create();

        await _writePackageSwift(
          'psw/objc_only_modulemap',
          _renderer(IosPluginContext(
              path('psw/objc_only_modulemap/ios'), 'objc_plug')),
          _input(pluginLanguage: PluginLanguage.objectiveC),
        );

        await file(
          'psw/objc_only_modulemap/Package.swift',
          allOf([
            contains(
              'exclude: ["include/cocoapods_objc_plug.modulemap"],',
            ),
            contains('.headerSearchPath("include/objc_plug"),'),
            contains('cSettings: ['),
            isNot(contains('name: "objc_plug_objc"')),
          ]),
        ).validate();

        final text = File(path('psw/objc_only_modulemap/Package.swift'))
            .readAsStringSync();
        expect(
          text.indexOf('.headerSearchPath("include/objc_plug"),'),
          greaterThan(text.indexOf(
            'exclude: ["include/cocoapods_objc_plug.modulemap"],',
          )),
        );
      },
    );

    test('Mixed plugin without split: warning TODO + FS-derived excludes',
        () async {
      await dir('psw/mixed_no_split', [
        dir('ios', [
          dir('mix_pl', [
            dir('Sources', [
              dir('mix_pl', [
                dir('include', []),
                dir('mix_pl', [
                  file('mix_pl.m', ''),
                ]),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      await _writePackageSwift(
        'psw/mixed_no_split',
        _renderer(IosPluginContext(path('psw/mixed_no_split/ios'), 'mix_pl')),
        _input(pluginLanguage: PluginLanguage.mixed),
      );

      await file(
        'psw/mixed_no_split/Package.swift',
        allOf([
          contains(
            '// TODO: This package contains mixed Swift + Objective-C sources.',
          ),
          contains(
            'https://stackoverflow.com/questions/51540665/swift-package-manager-mixed-language-source-files',
          ),
          contains('exclude: ['),
          contains('"include"'),
          contains('"mix_pl/mix_pl.m"'),
          isNot(contains('.headerSearchPath("include/mix_pl"),')),
          isNot(contains('cocoapods_mix_pl.modulemap')),
        ]),
      ).validate();
    });

    test(
      'Mixed plugin auto-split: NOTE, two targets, Swift depends on ObjC target',
      () async {
        await dir('psw/mixed_split', [
          dir('ios', [
            dir('mx_pl', [
              dir('Sources', [
                dir('mx_pl', [
                  dir('include', []),
                ]),
              ]),
            ]),
          ]),
        ]).create();

        await _writePackageSwift(
          'psw/mixed_split',
          _renderer(IosPluginContext(path('psw/mixed_split/ios'), 'mx_pl')),
          _input(
            pluginLanguage: PluginLanguage.mixed,
            didAutoSplitMixedPlugin: true,
          ),
        );

        await file(
          'psw/mixed_split/Package.swift',
          allOf([
            contains(
              '// NOTE: This package was auto-split into Swift + ObjC targets',
            ),
            contains(
                '.library(name: "mx-pl", targets: ["mx_pl", "mx_pl_objc"])'),
            contains('path: "Sources/mx_pl_objc",'),
            contains('publicHeadersPath: "include",'),
            contains('name: "mx_pl_objc",'),
            contains('dependencies: ["mx_pl_objc"],'),
          ]),
        ).validate();

        final text =
            File(path('psw/mixed_split/Package.swift')).readAsStringSync();
        expect(
          text.indexOf('name: "mx_pl_objc",'),
          lessThan(text.indexOf('dependencies: ["mx_pl_objc"]')),
        );
      },
    );

    test('localized resources inject defaultLocalization + migration TODO',
        () async {
      await dir('psw/localized', [
        dir('ios', [
          dir('loc_pl', [
            dir('Sources', [
              dir('loc_pl', [
                dir('Resources', [
                  dir('en.lproj', [
                    file('Localizable.strings', ''),
                  ]),
                ]),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      await _writePackageSwift(
        'psw/localized',
        _renderer(IosPluginContext(path('psw/localized/ios'), 'loc_pl')),
        _input(),
      );

      await file(
        'psw/localized/Package.swift',
        allOf([
          contains(
            '// TODO(spm-migration): Localized resources (*.lproj) detected.',
          ),
          contains('defaultLocalization: "en",'),
        ]),
      ).validate();

      final text = File(path('psw/localized/Package.swift')).readAsStringSync();
      expect(text.indexOf('defaultLocalization:'),
          lessThan(text.indexOf('platforms:')));
    });

    test(
        'CocoaPods deps TODO appears inside Swift target dependencies (no split)',
        () async {
      await dir('psw/pods_no_split', [
        dir('ios', [
          dir('pod_pl', [
            dir('Sources', [
              dir('pod_pl', []),
            ]),
          ]),
        ]),
      ]).create();

      await _writePackageSwift(
        'psw/pods_no_split',
        _renderer(IosPluginContext(path('psw/pods_no_split/ios'), 'pod_pl')),
        _input(
          cocoaPodsDependencies: const [
            PodDependency('FirebaseCore', '>= 10.0'),
            PodDependency('FooKit', null),
          ],
        ),
      );

      await file(
        'psw/pods_no_split/Package.swift',
        allOf([
          contains('name: "pod_pl",'),
          contains(
            '// TODO: CocoaPods dependencies found in .podspec. Add SPM equivalents here:',
          ),
          contains('// - FirebaseCore (>= 10.0)'),
          contains('// - FooKit'),
        ]),
      ).validate();

      final text =
          File(path('psw/pods_no_split/Package.swift')).readAsStringSync();
      final depsTodoIdx = text.indexOf(
        '// TODO: CocoaPods dependencies found in .podspec',
      );
      final swiftTargetIdx = text.indexOf('name: "pod_pl",');
      expect(depsTodoIdx, greaterThan(swiftTargetIdx));
    });

    test('CocoaPods deps TODO after objc dependency reference when split',
        () async {
      await dir('psw/pods_split', [
        dir('ios', [
          dir('psp', [
            dir('Sources', [
              dir('psp', []),
            ]),
          ]),
        ]),
      ]).create();

      await _writePackageSwift(
        'psw/pods_split',
        _renderer(IosPluginContext(path('psw/pods_split/ios'), 'psp')),
        _input(
          pluginLanguage: PluginLanguage.mixed,
          didAutoSplitMixedPlugin: true,
          cocoaPodsDependencies: const [PodDependency('RxSwift', '~> 6')],
        ),
      );

      await file(
        'psw/pods_split/Package.swift',
        allOf([
          contains('"psp_objc",'),
          contains(
            '// TODO: CocoaPods dependencies found in .podspec. Add SPM equivalents here:',
          ),
          contains('// - RxSwift (~> 6)'),
        ]),
      ).validate();

      final text =
          File(path('psw/pods_split/Package.swift')).readAsStringSync();
      expect(
          text.indexOf('"psp_objc",'),
          lessThan(text.indexOf(
            '// TODO: CocoaPods dependencies found in .podspec',
          )));
    });

    test('resources and privacy manifest blocks preserve ordering', () async {
      await dir('psw/resources_privacy', [
        dir('ios', [
          dir('rp', [
            dir('Sources', [
              dir('rp', [
                dir('Resources', [
                  file('Localizable.strings', ''),
                ]),
                file('PrivacyInfo.xcprivacy', ''),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      await _writePackageSwift(
        'psw/resources_privacy',
        _renderer(IosPluginContext(path('psw/resources_privacy/ios'), 'rp')),
        _input(),
      );

      await file(
        'psw/resources_privacy/Package.swift',
        allOf([
          contains('.process("Resources")'),
          contains('.process("PrivacyInfo.xcprivacy")'),
        ]),
      ).validate();

      final text =
          File(path('psw/resources_privacy/Package.swift')).readAsStringSync();
      expect(
        text.indexOf('.process("Resources")'),
        lessThan(text.indexOf('.process("PrivacyInfo.xcprivacy")')),
      );
    });

    test('Assets directory is processed alongside Resources and Privacy',
        () async {
      await dir('psw/assets_resources_privacy', [
        dir('ios', [
          dir('arp', [
            dir('Sources', [
              dir('arp', [
                dir('Assets', [
                  file('image.png', ''),
                ]),
                dir('Resources', [
                  file('Localizable.strings', ''),
                ]),
                file('PrivacyInfo.xcprivacy', ''),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      await _writePackageSwift(
        'psw/assets_resources_privacy',
        _renderer(
          IosPluginContext(path('psw/assets_resources_privacy/ios'), 'arp'),
        ),
        _input(),
      );

      await file(
        'psw/assets_resources_privacy/Package.swift',
        allOf([
          contains('.process("Assets")'),
          contains('.process("Resources")'),
          contains('.process("PrivacyInfo.xcprivacy")'),
        ]),
      ).validate();

      final text = File(path('psw/assets_resources_privacy/Package.swift'))
          .readAsStringSync();
      expect(
        text.indexOf('.process("Assets")'),
        lessThan(text.indexOf('.process("Resources")')),
      );
    });

    test(
        'no stray blank line before "platforms:" when localized resources are absent',
        () async {
      await dir('psw/no_blank_line', [
        dir('ios', [
          dir('np', [
            dir('Sources', [
              dir('np', []),
            ]),
          ]),
        ]),
      ]).create();

      await _writePackageSwift(
        'psw/no_blank_line',
        _renderer(IosPluginContext(path('psw/no_blank_line/ios'), 'np')),
        _input(),
      );

      final text =
          File(path('psw/no_blank_line/Package.swift')).readAsStringSync();
      // The line immediately following `name: "np",` must be `    platforms: [`,
      // not an empty line followed by `platforms:`.
      expect(
        text,
        contains('name: "np",\n    platforms: ['),
      );
      expect(
        text,
        isNot(contains('name: "np",\n\n    platforms: [')),
      );
    });

    test(
        'needsFlutterFramework adds local package + product on Swift-only single target',
        () async {
      await dir('psw/ff_swift_only', [
        dir('ios', [
          dir('pl', [
            dir('Sources', [
              dir('pl', []),
            ]),
          ]),
        ]),
      ]).create();

      await _writePackageSwift(
        'psw/ff_swift_only',
        _renderer(IosPluginContext(path('psw/ff_swift_only/ios'), 'pl')),
        _input(needsFlutterFramework: true),
      );

      await file(
        'psw/ff_swift_only/Package.swift',
        allOf([
          contains(
            '.package(name: "FlutterFramework", path: "../FlutterFramework")',
          ),
          // Compact single-item target deps form.
          contains(
            'dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")],',
          ),
        ]),
      ).validate();
    });

    test(
        'needsFlutterFramework with auto-split adds product to both Swift and ObjC targets',
        () async {
      await dir('psw/ff_split', [
        dir('ios', [
          dir('pl', [
            dir('Sources', [
              dir('pl', [
                dir('include', []),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      await _writePackageSwift(
        'psw/ff_split',
        _renderer(IosPluginContext(path('psw/ff_split/ios'), 'pl')),
        _input(
          pluginLanguage: PluginLanguage.mixed,
          didAutoSplitMixedPlugin: true,
          needsFlutterFramework: true,
        ),
      );

      final text = File(path('psw/ff_split/Package.swift')).readAsStringSync();
      // Package-level dependency declared exactly once.
      expect(
        '.package(name: "FlutterFramework"'.allMatches(text).length,
        1,
      );
      // FlutterFramework product appears in both target dependency arrays
      // (Swift target + ObjC target).
      expect(
        '.product(name: "FlutterFramework", package: "FlutterFramework")'
            .allMatches(text)
            .length,
        2,
      );
      // Swift target still depends on the ObjC target alongside FlutterFramework.
      expect(text, contains('"pl_objc"'));
    });

    test(
        'needsFlutterFramework=false renders the original empty package-level deps',
        () async {
      await dir('psw/ff_off', [
        dir('ios', [
          dir('pl', [
            dir('Sources', [
              dir('pl', []),
            ]),
          ]),
        ]),
      ]).create();

      await _writePackageSwift(
        'psw/ff_off',
        _renderer(IosPluginContext(path('psw/ff_off/ios'), 'pl')),
        _input(),
      );

      await file(
        'psw/ff_off/Package.swift',
        allOf([
          contains('dependencies: [],'),
          isNot(contains('FlutterFramework')),
        ]),
      ).validate();
    });

    test('Assets-only target still emits .process("Assets")', () async {
      await dir('psw/assets_only', [
        dir('ios', [
          dir('ao', [
            dir('Sources', [
              dir('ao', [
                dir('Assets', [
                  file('image.png', ''),
                ]),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      await _writePackageSwift(
        'psw/assets_only',
        _renderer(IosPluginContext(path('psw/assets_only/ios'), 'ao')),
        _input(),
      );

      await file(
        'psw/assets_only/Package.swift',
        allOf([
          contains('resources: ['),
          contains('.process("Assets")'),
          isNot(contains('.process("Resources")')),
          isNot(contains('.process("PrivacyInfo.xcprivacy")')),
        ]),
      ).validate();
    });
  });

  group('PackageSwiftRenderer.collectSwiftTargetExcludeForObjcFamily', () {
    test('collects include directory and ObjC sources with stable sort',
        () async {
      await dir('psw/exclude_basic', [
        dir('include', []),
        dir('nested', [
          file('b.mm', ''),
        ]),
        file('Main.swift', ''),
        file('a.m', ''),
      ]).create();

      File(path('psw/exclude_basic/out.txt')).writeAsStringSync(
        PackageSwiftRenderer(
          context: IosPluginContext('_', '_'),
          fs: FileSystemUtils(),
        )
            .collectSwiftTargetExcludeForObjcFamily(
              spmTargetDir: Directory(path('psw/exclude_basic')),
            )
            .join('\n'),
      );

      await file(
        'psw/exclude_basic/out.txt',
        equals('a.m\ninclude\nnested/b.mm'),
      ).validate();
    });

    test('missing target directory yields empty exclude list', () async {
      await dir('psw/exclude_missing_root', [
        dir('include', []),
      ]).create();

      File(path('psw/exclude_missing_root/out.txt')).writeAsStringSync(
        PackageSwiftRenderer(
          context: IosPluginContext('_', '_'),
          fs: FileSystemUtils(),
        )
            .collectSwiftTargetExcludeForObjcFamily(
              spmTargetDir:
                  Directory(path('psw/exclude_missing_root/nonexistent')),
            )
            .join('\n'),
      );

      await file('psw/exclude_missing_root/out.txt', equals('')).validate();
    });
  });
}
