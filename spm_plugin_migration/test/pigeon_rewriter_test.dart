import 'dart:io';

import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

void main() {
  group('PigeonRewriter.updatePigeonInputFiles', () {
    const rewriter = PigeonRewriter();

    test('rewrites swift/objc outputs from ios/Classes to SwiftPM layout',
        () async {
      await dir('pigeon_rewriter/objc', [
        dir('plugin', [
          dir('pigeons', [
            file('api.dart', '''
@ConfigurePigeon(PigeonOptions(
  swiftOut: 'ios/Classes/messages.g.swift',
  objcSourceOut: "ios/Classes/messages.g.m",
  objcHeaderOut: 'ios/Classes/messages.g.h',
))
class Api {}
'''),
          ]),
        ]),
      ]).create();

      rewriter.updatePigeonInputFiles(
        pluginDir: Directory(path('pigeon_rewriter/objc/plugin')),
        pluginName: 'my_plugin',
        hasObjcSources: true,
      );

      final content = File(path('pigeon_rewriter/objc/plugin/pigeons/api.dart'))
          .readAsStringSync();
      expect(
        content,
        contains(
            "swiftOut: 'ios/my_plugin/Sources/my_plugin/messages.g.swift'"),
      );
      expect(
        content,
        contains(
          'objcSourceOut: "ios/my_plugin/Sources/my_plugin/messages.g.m"',
        ),
      );
      expect(
        content,
        contains(
          "objcHeaderOut: 'ios/my_plugin/Sources/my_plugin/include/my_plugin/messages.g.h'",
        ),
      );
    });

    test('keeps objcHeaderOut unchanged for Swift-only plugins', () async {
      await dir('pigeon_rewriter/swift_only', [
        dir('plugin', [
          dir('pigeon', [
            file('api.dart', '''
@ConfigurePigeon(PigeonOptions(
  objcHeaderOut: 'ios/Classes/messages.g.h',
))
'''),
          ]),
        ]),
      ]).create();

      rewriter.updatePigeonInputFiles(
        pluginDir: Directory(path('pigeon_rewriter/swift_only/plugin')),
        pluginName: 'my_plugin',
        hasObjcSources: false,
      );

      final content =
          File(path('pigeon_rewriter/swift_only/plugin/pigeon/api.dart'))
              .readAsStringSync();
      expect(content, contains("objcHeaderOut: 'ios/Classes/messages.g.h'"));
    });

    test('does not rewrite commented output configuration lines', () async {
      await dir('pigeon_rewriter/comments', [
        dir('plugin', [
          dir('pigeons', [
            file('api.dart', '''
// swiftOut: 'ios/Classes/should_not_change.swift'
// objcSourceOut: 'ios/Classes/should_not_change.m'
'''),
          ]),
        ]),
      ]).create();

      rewriter.updatePigeonInputFiles(
        pluginDir: Directory(path('pigeon_rewriter/comments/plugin')),
        pluginName: 'my_plugin',
        hasObjcSources: true,
      );

      final content =
          File(path('pigeon_rewriter/comments/plugin/pigeons/api.dart'))
              .readAsStringSync();
      expect(content, contains('ios/Classes/should_not_change.swift'));
      expect(content, isNot(contains('ios/my_plugin/Sources')));
    });
  });
}
