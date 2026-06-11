import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

/// End-to-end test: runs the actual `bin/spm_plugin_migration.dart` script
/// against a synthetic plugin that exercises every major code path:
/// Swift sources, ObjC wrapper + extra ObjC source, headers, Assets,
/// Resources, PrivacyInfo, named CocoaPods resource_bundles lookups (in both
/// Swift and ObjC), an external pod dependency, and the mixed-language
/// auto-split into Swift + ObjC SwiftPM targets.
void main() {
  test('full migration of a mixed Swift+ObjC plugin produces expected layout',
      () async {
    const pluginName = 'some_plugin';
    const objcTargetName = 'some_plugin_objc';
    const bundleName = 'SomePluginResources';

    final podspec = '''
Pod::Spec.new do |s|
  s.name             = '$pluginName'
  s.version          = '0.0.1'
  s.summary          = 'A test plugin.'
  s.homepage         = 'http://example.com'
  s.license          = { :type => 'MIT' }
  s.author           = { 'You' => 'you@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.resource_bundles = { '$bundleName' => ['Assets/**/*', 'Resources/**/*'] }
  s.resources        = ['PrivacyInfo.xcprivacy']
  s.dependency 'Flutter'
  s.dependency 'SomeExtPod', '~> 1.0'
  s.platform = :ios, '14.0'
  s.ios.deployment_target = '14.0'
end
''';

    const somePluginH = '''
#import <Flutter/Flutter.h>

@interface SomePlugin : NSObject <FlutterPlugin>
@end
''';

    // Wrapper that delegates registration to a Swift implementation, plus an
    // intra-plugin ObjC import — this should be rewritten to `./include/...`.
    const somePluginM = '''
#import "SomePlugin.h"
#import "ExtraNative.h"

@implementation SomePlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftSomePlugin registerWithRegistrar:registrar];
}
@end
''';

    const extraNativeH = '''
#import <Foundation/Foundation.h>

@interface ExtraNative : NSObject
- (NSBundle *)resourcesBundle;
@end
''';

    // Extra ObjC source that uses BOTH a named-bundle URLForResource: lookup
    // (must get a TODO annotation) and an external pod angle-import (must get
    // a __has_include guard).
    const extraNativeM = '''
#import "ExtraNative.h"
#import <SomeExtPod/SomeExtPod.h>

@implementation ExtraNative
- (NSBundle *)resourcesBundle {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSURL *url = [bundle URLForResource:@"$bundleName" withExtension:@"bundle"];
    return [NSBundle bundleWithURL:url];
}
@end
''';

    // Swift entry point that references the ObjC type (forces the autoSplit
    // path to add `#if SWIFT_PACKAGE import some_plugin_objc #endif`), uses
    // Flutter (forces missing-import injection), and looks up a named bundle.
    const mainSwift = '''
class SwiftSomePlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let _ = Bundle.main.url(forResource: "icon", withExtension: "png", subdirectory: "$bundleName")
        let channel = FlutterMethodChannel(name: "some_plugin", binaryMessenger: registrar.messenger())
        let instance = SwiftSomePlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        _ = ExtraNative()
    }
}
''';

    await dir('e2e', [
      dir(pluginName, [
        dir('ios', [
          file('$pluginName.podspec', podspec),
          dir('Classes', [
            file('SomePlugin.h', somePluginH),
            file('SomePlugin.m', somePluginM),
            file('ExtraNative.h', extraNativeH),
            file('ExtraNative.m', extraNativeM),
            file('MainSwift.swift', mainSwift),
            file(
              'cocoapods_$pluginName.modulemap',
              'module ${pluginName}_objc {\n'
                  '    umbrella header "ExtraNative.h"\n'
                  '    export *\n'
                  '}\n',
            ),
          ]),
          dir('Assets', [
            file('icon.png', 'PNG-DATA'),
          ]),
          dir('Resources', [
            file('strings.json', '{"hello":"world"}'),
          ]),
          file('PrivacyInfo.xcprivacy',
              '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n'),
        ]),
      ]),
    ]).create();

    final pluginRoot = path('e2e/$pluginName');

    // Locate the script package root (where bin/spm_plugin_migration.dart
    // lives) by walking up from the test file.
    final scriptPackageDir = _findScriptPackageDir();

    final result = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/spm_plugin_migration.dart', pluginRoot],
      workingDirectory: scriptPackageDir,
    );

    expect(
      result.exitCode,
      0,
      reason: 'Script exited non-zero.\nSTDOUT:\n${result.stdout}\n'
          'STDERR:\n${result.stderr}',
    );

    // --- Filesystem layout ----------------------------------------------------

    // Original legacy directories are emptied/removed.
    expect(
        Directory(p.join(pluginRoot, 'ios', 'Classes')).existsSync(), isFalse,
        reason: 'ios/Classes should be removed after migration.');
    expect(
        Directory(p.join(pluginRoot, 'ios', 'Assets')).existsSync(), isFalse);
    expect(Directory(p.join(pluginRoot, 'ios', 'Resources')).existsSync(),
        isFalse);

    final spmRoot = p.join(pluginRoot, 'ios', pluginName);
    final swiftTarget = p.join(spmRoot, 'Sources', pluginName);
    final objcTarget = p.join(spmRoot, 'Sources', objcTargetName);

    // Swift target keeps the Swift source + resources, no ObjC.
    expect(File(p.join(swiftTarget, 'MainSwift.swift')).existsSync(), isTrue);
    expect(
        File(p.join(swiftTarget, 'Assets', 'icon.png')).existsSync(), isTrue);
    expect(File(p.join(swiftTarget, 'Resources', 'strings.json')).existsSync(),
        isTrue);
    expect(File(p.join(swiftTarget, 'PrivacyInfo.xcprivacy')).existsSync(),
        isTrue);
    expect(
      Directory(p.join(swiftTarget, 'include')).existsSync(),
      isFalse,
      reason: 'include/ should have moved to the split ObjC target.',
    );

    // ObjC target keeps the additional ObjC source + its public header. The
    // legacy ObjC wrapper (SomePlugin.h/.m) is removed by
    // `_cleanupLegacyObjcPluginWrappers` after the Swift stub is generated.
    expect(File(p.join(objcTarget, 'ExtraNative.m')).existsSync(), isTrue);
    expect(
      File(p.join(objcTarget, 'include', pluginName, 'ExtraNative.h'))
          .existsSync(),
      isTrue,
    );
    expect(
      File(p.join(objcTarget, 'SomePlugin.m')).existsSync(),
      isFalse,
      reason: 'Legacy ObjC wrapper SomePlugin.m should be removed.',
    );
    expect(
      File(p.join(objcTarget, 'include', pluginName, 'SomePlugin.h'))
          .existsSync(),
      isFalse,
    );

    // CocoaPods modulemap relocated under ObjC target's include/.
    expect(
      File(p.join(objcTarget, 'include', 'cocoapods_$pluginName.modulemap'))
          .existsSync(),
      isTrue,
    );

    // Generated SwiftPM registration stub replaces the removed ObjC wrapper.
    expect(
      File(p.join(swiftTarget, 'SomePlugin.swift')).existsSync(),
      isTrue,
      reason: 'ensureSwiftPmRegistrationStub should create SomePlugin.swift.',
    );

    // --- Package.swift --------------------------------------------------------

    final packageSwift =
        File(p.join(spmRoot, 'Package.swift')).readAsStringSync();
    expect(packageSwift, contains('// swift-tools-version: 5.9'));
    expect(packageSwift, contains('.iOS("14.0")'));
    expect(
      packageSwift,
      contains('targets: ["$pluginName", "$objcTargetName"]'),
    );
    expect(packageSwift, contains('name: "$objcTargetName"'));
    expect(packageSwift, contains('publicHeadersPath: "include"'));
    expect(
      packageSwift,
      contains('.headerSearchPath("include/$pluginName")'),
    );
    // Swift target depends on the ObjC target after the auto-split. With
    // CocoaPods deps present the array is multi-line, so check both pieces.
    expect(packageSwift, contains('"$objcTargetName"'));
    expect(packageSwift, contains('// - SomeExtPod (~> 1.0)'));
    // All three resource entries on the Swift target.
    expect(packageSwift, contains('.process("Assets")'));
    expect(packageSwift, contains('.process("Resources")'));
    expect(packageSwift, contains('.process("PrivacyInfo.xcprivacy")'));
    // Auto-split notice.
    expect(
      packageSwift,
      contains('auto-split into Swift + ObjC targets'),
    );

    // --- TODOs for named CocoaPods resource_bundles ---------------------------

    final mainSwiftOut =
        File(p.join(swiftTarget, 'MainSwift.swift')).readAsStringSync();
    expect(
      mainSwiftOut,
      contains(
          'TODO(spm-migration): CocoaPods resource bundle name lookup detected'),
    );
    final extraNativeMOut =
        File(p.join(objcTarget, 'ExtraNative.m')).readAsStringSync();
    expect(
      extraNativeMOut,
      contains(
          'TODO(spm-migration): CocoaPods resource bundle name lookup detected'),
    );
    // TODO sits right above the URLForResource line.
    final extraLines = extraNativeMOut.split('\n');
    final todoIdx = extraLines.indexWhere(
      (l) => l.contains('TODO(spm-migration): CocoaPods resource bundle name'),
    );
    expect(todoIdx, greaterThanOrEqualTo(0));
    expect(extraLines[todoIdx + 1], contains('URLForResource:@"$bundleName"'));

    // --- ObjC import rewriting & external-pod __has_include wrapping --------

    // Intra-plugin ObjC import rewritten to ./include/<plugin>/...
    expect(
      extraNativeMOut,
      contains('#import "./include/$pluginName/ExtraNative.h"'),
    );
    // External pod angle-import wrapped in __has_include / @import fallback.
    expect(
      extraNativeMOut,
      contains('__has_include(<SomeExtPod/SomeExtPod.h>)'),
    );

    // --- Swift→ObjC cross-target import was injected ------------------------

    expect(
      mainSwiftOut,
      allOf(
        contains('#if SWIFT_PACKAGE'),
        contains('import $objcTargetName'),
        contains('#endif'),
        // Flutter/Foundation also injected for symbols used in source.
        contains('import Flutter'),
      ),
    );

    // --- Podspec updates ----------------------------------------------------

    final updatedPodspec =
        File(p.join(pluginRoot, 'ios', '$pluginName.podspec'))
            .readAsStringSync();
    expect(
      updatedPodspec,
      allOf(
        // Source paths rewritten to the new SwiftPM layout.
        contains('$pluginName/Sources/$pluginName'),
        // ObjC publicHeader line added.
        contains('public_header_files'),
        // CocoaPods modulemap reference present (for ObjC interop under pods).
        contains('module_map'),
        // PrivacyInfo path rewritten — bare `'PrivacyInfo.xcprivacy'` would
        // dangle after the file moved into Sources/<plugin>/.
        contains("'$pluginName/Sources/$pluginName/PrivacyInfo.xcprivacy'"),
      ),
    );
    expect(
      updatedPodspec,
      isNot(contains("s.resources        = ['PrivacyInfo.xcprivacy']")),
      reason: 'Bare PrivacyInfo.xcprivacy reference must be rewritten.',
    );

    // --- Package.swift formatting ------------------------------------------

    expect(
      packageSwift,
      isNot(contains('name: "$pluginName",\n\n    platforms: [')),
      reason: 'No stray blank line between name and platforms.',
    );

    // --- TODO indentation matches the annotated line -----------------------

    final extraNativeMLines = extraNativeMOut.split('\n');
    final extraTodoLine = extraNativeMLines.firstWhere(
      (l) => l.contains('TODO(spm-migration): CocoaPods resource bundle name'),
    );
    // ObjC body lines are 4-space indented in the fixture.
    expect(extraTodoLine, startsWith('    // TODO(spm-migration)'));

    // --- Trailing newline preserved on annotated files ---------------------

    expect(extraNativeMOut.endsWith('\n'), isTrue);
    expect(mainSwiftOut.endsWith('\n'), isTrue);

    // --- SPM package .gitignore --------------------------------------------

    final gitignore = File(p.join(spmRoot, '.gitignore')).readAsStringSync();
    expect(gitignore, contains('.build/'));
    expect(gitignore, contains('.swiftpm/'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// Resolves the script package root (the directory containing
/// `bin/spm_plugin_migration.dart`). `dart test` sets the cwd to the package
/// root, so we start there and walk up to be robust to nested invocations.
String _findScriptPackageDir() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File(p.join(dir.path, 'bin', 'spm_plugin_migration.dart'))
        .existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'Could not locate spm_plugin_migration package root from ${Directory.current.path}',
  );
}
