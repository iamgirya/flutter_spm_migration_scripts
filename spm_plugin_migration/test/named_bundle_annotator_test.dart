import 'dart:io';

import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

void main() {
  group('NamedBundleAnnotator.annotate', () {
    test('annotates ObjC .m file using URLForResource: with a named bundle',
        () async {
      await dir('nba/annotate_objc_url', [
        file(
          'Plugin.m',
          '''
#import "Plugin.h"

@implementation Plugin
- (NSBundle *)resourcesBundle {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSURL *url = [bundle URLForResource:@"MyPluginResources" withExtension:@"bundle"];
    return [NSBundle bundleWithURL:url];
}
@end
''',
        ),
      ]).create();

      NamedBundleAnnotator(FileSystemUtils()).annotate(
        sourceRoot: Directory(path('nba/annotate_objc_url')),
        bundleNames: const ['MyPluginResources'],
      );

      final out =
          File(path('nba/annotate_objc_url/Plugin.m')).readAsStringSync();
      final lines = out.split('\n');
      final todoIdx = lines.indexWhere(
        (l) => l.contains(
            'TODO(spm-migration): CocoaPods resource bundle name lookup detected'),
      );
      expect(todoIdx, greaterThanOrEqualTo(0));
      expect(
        lines[todoIdx + 1],
        contains('URLForResource:@"MyPluginResources"'),
      );
      final bundleForClassIdx = lines.indexWhere(
        (l) =>
            l.contains('bundleForClass:[self class]') &&
            !l.contains('URLForResource'),
      );
      expect(
        lines[bundleForClassIdx - 1],
        isNot(contains('TODO(spm-migration)')),
      );
    });

    test('annotates ObjC .h header that references a named bundle inline',
        () async {
      await dir('nba/annotate_objc_header', [
        file(
          'Plugin.h',
          '''
#import <Flutter/Flutter.h>

// Resolved at call time:
//   [[NSBundle bundleForClass:[Plugin class]] pathForResource:@"MyPluginResources" ofType:@"bundle"]
static NSString * const kPluginResourcesBundleName = @"MyPluginResources.bundle";

@interface Plugin : NSObject <FlutterPlugin>
@end
''',
        ),
      ]).create();

      NamedBundleAnnotator(FileSystemUtils()).annotate(
        sourceRoot: Directory(path('nba/annotate_objc_header')),
        bundleNames: const ['MyPluginResources'],
      );

      final out =
          File(path('nba/annotate_objc_header/Plugin.h')).readAsStringSync();
      expect(
        out,
        contains(
            'TODO(spm-migration): CocoaPods resource bundle name lookup detected'),
      );
    });

    test('annotation is idempotent across runs on Swift and ObjC sources',
        () async {
      await dir('nba/annotate_idempotent', [
        file(
          'A.swift',
          'let _ = Bundle.main.url(forResource: "x", withExtension: "bundle", subdirectory: "MyPluginResources")\n',
        ),
        file(
          'B.m',
          '@implementation B\n'
              '- (NSURL *)u { return [[NSBundle bundleForClass:[self class]] URLForResource:@"MyPluginResources" withExtension:@"bundle"]; }\n'
              '@end\n',
        ),
      ]).create();

      final annotator = NamedBundleAnnotator(FileSystemUtils());
      for (var i = 0; i < 2; i++) {
        annotator.annotate(
          sourceRoot: Directory(path('nba/annotate_idempotent')),
          bundleNames: const ['MyPluginResources'],
        );
      }

      final aOut =
          File(path('nba/annotate_idempotent/A.swift')).readAsStringSync();
      final bOut = File(path('nba/annotate_idempotent/B.m')).readAsStringSync();
      expect(
        'TODO(spm-migration): CocoaPods resource bundle name'
            .allMatches(aOut)
            .length,
        1,
      );
      expect(
        'TODO(spm-migration): CocoaPods resource bundle name'
            .allMatches(bOut)
            .length,
        1,
      );
    });

    test('skips ObjC files that only reference NSBundle without a named bundle',
        () async {
      const original = '''
@implementation NoNamedBundle
- (NSBundle *)b { return [NSBundle bundleForClass:[self class]]; }
@end
''';
      await dir('nba/annotate_noop', [
        file('Plain.m', original),
      ]).create();

      NamedBundleAnnotator(FileSystemUtils()).annotate(
        sourceRoot: Directory(path('nba/annotate_noop')),
        bundleNames: const ['MyPluginResources'],
      );

      final out = File(path('nba/annotate_noop/Plain.m')).readAsStringSync();
      expect(out, equals(original));
    });

    test('inserted TODO matches the indentation of the annotated line',
        () async {
      await dir('nba/indent', [
        file(
          'A.swift',
          'class A {\n'
              '    func f() {\n'
              '        let _ = Bundle.main.url(forResource: "x", inDirectory: "MyPluginResources")\n'
              '    }\n'
              '}\n',
        ),
        file(
          'B.m',
          '@implementation B\n'
              '- (void)load {\n'
              '\t[bundle URLForResource:@"MyPluginResources" withExtension:@"bundle"];\n'
              '}\n'
              '@end\n',
        ),
      ]).create();

      NamedBundleAnnotator(FileSystemUtils()).annotate(
        sourceRoot: Directory(path('nba/indent')),
        bundleNames: const ['MyPluginResources'],
      );

      final aLines =
          File(path('nba/indent/A.swift')).readAsStringSync().split('\n');
      final aTodoIdx =
          aLines.indexWhere((l) => l.contains('TODO(spm-migration)'));
      // 8-space indent of the bundle line, preserved on the TODO above it.
      expect(aLines[aTodoIdx], startsWith('        // TODO(spm-migration)'));
      expect(aLines[aTodoIdx + 1], startsWith('        let _ ='));

      final bLines =
          File(path('nba/indent/B.m')).readAsStringSync().split('\n');
      final bTodoIdx =
          bLines.indexWhere((l) => l.contains('TODO(spm-migration)'));
      // Tab-indented ObjC line — TODO should also start with the same tab.
      expect(bLines[bTodoIdx], startsWith('\t// TODO(spm-migration)'));
      expect(bLines[bTodoIdx + 1], startsWith('\t[bundle URLForResource'));
    });

    test('preserves trailing newline of files that had one', () async {
      const withTrailing =
          'let _ = Bundle.main.url(forResource: "x", inDirectory: "MyPluginResources")\n';
      const withoutTrailing =
          'let _ = Bundle.main.url(forResource: "x", inDirectory: "MyPluginResources")';

      await dir('nba/trailing_newline', [
        file('with_nl.swift', withTrailing),
        file('without_nl.swift', withoutTrailing),
      ]).create();

      NamedBundleAnnotator(FileSystemUtils()).annotate(
        sourceRoot: Directory(path('nba/trailing_newline')),
        bundleNames: const ['MyPluginResources'],
      );

      final with_ =
          File(path('nba/trailing_newline/with_nl.swift')).readAsStringSync();
      final without = File(path('nba/trailing_newline/without_nl.swift'))
          .readAsStringSync();

      expect(with_.endsWith('\n'), isTrue,
          reason:
              'File that originally ended with \\n should still end with \\n.');
      expect(without.endsWith('\n'), isFalse,
          reason: 'File without trailing newline should not gain one.');
    });

    test('does nothing when bundleNames list is empty', () async {
      const original =
          'let _ = Bundle.main.url(forResource: "x", inDirectory: "MyPluginResources")\n';
      await dir('nba/empty_bundle_names', [
        file('A.swift', original),
      ]).create();

      NamedBundleAnnotator(FileSystemUtils()).annotate(
        sourceRoot: Directory(path('nba/empty_bundle_names')),
        bundleNames: const [],
      );

      final out =
          File(path('nba/empty_bundle_names/A.swift')).readAsStringSync();
      expect(out, equals(original));
    });
  });
}
