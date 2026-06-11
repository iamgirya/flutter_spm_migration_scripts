import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

bool _noopArc(String _, String __) => false;

void main() {
  group('LanguageDetector', () {
    final fs = FileSystemUtils(moveFile: _noopArc);

    test('detects swift plugin when only Swift sources exist', () async {
      await dir('language_detector/swift_only', [
        dir('ios', [
          dir('my_plugin', [
            file('my_plugin.podspec', 'Pod::Spec.new do |s| end'),
            dir('Sources', [
              dir('my_plugin', [
                file('Plugin.swift', 'final class Plugin: FlutterPlugin {}'),
                dir('include', [
                  file('cocoapods_my_plugin.modulemap', 'module my_plugin {}'),
                ]),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final detector = LanguageDetector(
        IosPluginContext(path('language_detector/swift_only/ios'), 'my_plugin'),
        fs,
      );

      expect(detector.detect(), PluginLanguage.swift);
    });

    test('detects objectiveC plugin when only ObjC sources exist', () async {
      await dir('language_detector/objc_only', [
        dir('ios', [
          dir('Classes', [
            file('Plugin.m', '@implementation Plugin @end'),
          ]),
        ]),
      ]).create();

      final detector = LanguageDetector(
        IosPluginContext(path('language_detector/objc_only/ios'), 'my_plugin'),
        fs,
      );

      expect(detector.detect(), PluginLanguage.objectiveC);
    });

    test('detects mixed plugin when Swift and ObjC sources coexist', () async {
      await dir('language_detector/mixed', [
        dir('ios', [
          dir('Classes', [
            file('Plugin.swift', 'final class Plugin: FlutterPlugin {}'),
          ]),
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin', [
                file('Legacy.m', '@implementation Legacy @end'),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final detector = LanguageDetector(
        IosPluginContext(path('language_detector/mixed/ios'), 'my_plugin'),
        fs,
      );

      expect(detector.detect(), PluginLanguage.mixed);
    });
  });
}
