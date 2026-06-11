import 'package:path/path.dart' as p;
import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

void main() {
  group('IosPluginContext.fromPackagePath', () {
    test('throws when ios directory is missing', () async {
      await dir('ios_context/no_ios', [
        file('pubspec.yaml', 'name: no_ios'),
      ]).create();

      expect(
        () => IosPluginContext.fromPackagePath(path('ios_context/no_ios')),
        throwsA(isA<Exception>()),
      );
    });

    test('reads plugin name from a single podspec', () async {
      await dir('ios_context/single', [
        dir('ios', [
          file('my_plugin.podspec', 'Pod::Spec.new do |s| end'),
        ]),
      ]).create();

      final context =
          IosPluginContext.fromPackagePath(path('ios_context/single'));

      expect(p.basename(context.path), 'ios');
      expect(context.pluginName, 'my_plugin');
      expect(p.basename(context.podspecFile.path), 'my_plugin.podspec');
    });

    test('uses first sorted podspec when there are multiple files', () async {
      await dir('ios_context/multiple', [
        dir('ios', [
          file('z_plugin.podspec', 'Pod::Spec.new do |s| end'),
          file('a_plugin.podspec', 'Pod::Spec.new do |s| end'),
        ]),
      ]).create();

      final context =
          IosPluginContext.fromPackagePath(path('ios_context/multiple'));

      expect(context.pluginName, 'a_plugin');
    });
  });

  group('IosPluginContext.privacyFile', () {
    test('ignores PrivacyInfo.xcprivacy inside generated SwiftPM target',
        () async {
      await dir('ios_context/privacy_exclude', [
        dir('ios', [
          file('my_plugin.podspec', 'Pod::Spec.new do |s| end'),
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin', [
                file('PrivacyInfo.xcprivacy', '{}'),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final context = IosPluginContext(
          path('ios_context/privacy_exclude/ios'), 'my_plugin');

      expect(context.privacyFile, isNull);
    });
  });
}
