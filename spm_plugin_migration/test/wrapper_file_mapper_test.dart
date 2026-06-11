import 'dart:io';

import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

bool _noopArc(String _, String __) => false;

void main() {
  group('WrapperFileMapper', () {
    final fs = FileSystemUtils(moveFile: _noopArc);

    test('isOnlyPluginWrapperObjcFiles returns true for Plugin.m + Plugin.h',
        () async {
      await dir('wrapper_mapper/only_wrapper', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin', [
                file('MyPlugin.m', '@implementation MyPlugin @end'),
                dir('include', [
                  file('MyPlugin.h', '@interface MyPlugin : NSObject @end'),
                ]),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final mapper = WrapperFileMapper(
        context: IosPluginContext(
            path('wrapper_mapper/only_wrapper/ios'), 'my_plugin'),
        fs: fs,
      );

      expect(mapper.isOnlyPluginWrapperObjcFiles(), isTrue);
    });

    test(
        'isOnlyPluginWrapperObjcFiles returns false when extra objc file exists',
        () async {
      await dir('wrapper_mapper/extra_objc', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin', [
                file('MyPlugin.m', '@implementation MyPlugin @end'),
                file('Extra.mm', '@implementation Extra @end'),
                dir('include', [
                  file('MyPlugin.h', '@interface MyPlugin : NSObject @end'),
                ]),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final mapper = WrapperFileMapper(
        context: IosPluginContext(
            path('wrapper_mapper/extra_objc/ios'), 'my_plugin'),
        fs: fs,
      );

      expect(mapper.isOnlyPluginWrapperObjcFiles(), isFalse);
    });

    test('detects Swift plugin class name from Objective-C wrapper content',
        () {
      final mapper = WrapperFileMapper(
        context: const IosPluginContext('ios', 'my_plugin'),
        fs: fs,
      );
      const wrapperContent = '''
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftMyPlugin registerWithRegistrar:registrar];
}
''';

      expect(
        mapper.detectSwiftPluginClassFromObjcWrapperContent(wrapperContent),
        'SwiftMyPlugin',
      );
    });

    test('detects FlutterPlugin-conforming class from Swift source file',
        () async {
      await dir('wrapper_mapper/swift_class_detection', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin', [
                file(
                  'Plugin.swift',
                  '''
import Flutter

public final class FancyPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}
''',
                ),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final mapper = WrapperFileMapper(
        context: IosPluginContext(
            path('wrapper_mapper/swift_class_detection/ios'), 'my_plugin'),
        fs: fs,
      );

      expect(
        mapper.detectSwiftFlutterPluginClass(
          Directory(
            path(
                'wrapper_mapper/swift_class_detection/ios/my_plugin/Sources/my_plugin'),
          ),
        ),
        'FancyPlugin',
      );
    });

    test('creates swift registration stub and removes legacy wrapper files',
        () async {
      await dir('wrapper_mapper/stub_generation', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin', [
                file(
                  'MyPlugin.m',
                  '''
@implementation MyPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftMyPlugin registerWithRegistrar:registrar];
}
@end
''',
                ),
                file('MyPlugin+SwiftPM.swift', '// legacy'),
                dir('include', [
                  file('MyPlugin.h', '@interface MyPlugin : NSObject @end'),
                ]),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final mapper = WrapperFileMapper(
        context: IosPluginContext(
            path('wrapper_mapper/stub_generation/ios'), 'my_plugin'),
        fs: fs,
      );

      mapper.ensureSwiftPmRegistrationStub();

      final stubPath = path(
        'wrapper_mapper/stub_generation/ios/my_plugin/Sources/my_plugin/MyPlugin.swift',
      );
      expect(File(stubPath).existsSync(), isTrue);
      expect(
        File(stubPath).readAsStringSync(),
        contains('SwiftMyPlugin.register(with: registrar)'),
      );
      expect(
        File(
          path(
            'wrapper_mapper/stub_generation/ios/my_plugin/Sources/my_plugin/MyPlugin+SwiftPM.swift',
          ),
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          path(
            'wrapper_mapper/stub_generation/ios/my_plugin/Sources/my_plugin/MyPlugin.m',
          ),
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          path(
            'wrapper_mapper/stub_generation/ios/my_plugin/Sources/my_plugin/include/MyPlugin.h',
          ),
        ).existsSync(),
        isFalse,
      );
    });

    test(
        'convertOnlyPluginObjcToSwiftSpecialCase embeds additional @interface '
        'blocks from the header in a multi-line comment under the TODO',
        () async {
      const headerWithExtras = '''
#import <Flutter/Flutter.h>

@interface MyPlugin : NSObject <FlutterPlugin>
@end

@interface MyPluginEvent : NSObject
@property (nonatomic, copy) NSString *name;
- (instancetype)initWithName:(NSString *)name;
@end

@interface MyPluginConfig : NSObject
@property (nonatomic, assign) NSInteger limit;
@end
''';

      await dir('wrapper_mapper/extra_interfaces', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin', [
                file(
                  'MyPlugin.m',
                  '''
@implementation MyPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftMyPlugin registerWithRegistrar:registrar];
}
@end
''',
                ),
                dir('include', [
                  file('MyPlugin.h', headerWithExtras),
                ]),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final mapper = WrapperFileMapper(
        context: IosPluginContext(
            path('wrapper_mapper/extra_interfaces/ios'), 'my_plugin'),
        fs: fs,
      );

      expect(mapper.convertOnlyPluginObjcToSwiftSpecialCase(), isTrue);

      final swiftPath = path(
        'wrapper_mapper/extra_interfaces/ios/my_plugin/Sources/my_plugin/MyPlugin.swift',
      );
      final swiftContent = File(swiftPath).readAsStringSync();

      expect(
        swiftContent,
        contains(
            '// TODO: additional interfaces were detected in MyPlugin.h. Add Swift equivalents for them.'),
      );
      // Block comment opens and closes.
      expect(swiftContent, contains('/*\n'));
      expect(swiftContent, contains('\n*/'));
      // Additional interface bodies are quoted verbatim.
      expect(swiftContent, contains('@interface MyPluginEvent : NSObject'));
      expect(
        swiftContent,
        contains('- (instancetype)initWithName:(NSString *)name;'),
      );
      expect(swiftContent, contains('@interface MyPluginConfig : NSObject'));
      // The plugin wrapper's own @interface is NOT quoted (it is replaced by
      // the generated Swift class above).
      expect(
        swiftContent,
        isNot(contains('@interface MyPlugin : NSObject <FlutterPlugin>')),
      );
      // Sanity: TODO appears before the block comment.
      expect(
        swiftContent.indexOf('// TODO: additional interfaces'),
        lessThan(swiftContent.indexOf('/*')),
      );
    });

    test(
        'convertOnlyPluginObjcToSwiftSpecialCase omits the TODO when the header '
        'declares only the plugin wrapper @interface', () async {
      await dir('wrapper_mapper/no_extra_interfaces', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin', [
                file(
                  'MyPlugin.m',
                  '@implementation MyPlugin\n'
                      '+ (void)registerWithRegistrar:'
                      '(NSObject<FlutterPluginRegistrar>*)registrar {\n'
                      '  [SwiftMyPlugin registerWithRegistrar:registrar];\n'
                      '}\n'
                      '@end\n',
                ),
                dir('include', [
                  file(
                    'MyPlugin.h',
                    '@interface MyPlugin : NSObject <FlutterPlugin>\n@end\n',
                  ),
                ]),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final mapper = WrapperFileMapper(
        context: IosPluginContext(
            path('wrapper_mapper/no_extra_interfaces/ios'), 'my_plugin'),
        fs: fs,
      );

      expect(mapper.convertOnlyPluginObjcToSwiftSpecialCase(), isTrue);

      final swiftContent = File(path(
        'wrapper_mapper/no_extra_interfaces/ios/my_plugin/Sources/my_plugin/MyPlugin.swift',
      )).readAsStringSync();

      expect(swiftContent, isNot(contains('// TODO: additional interfaces')));
      expect(swiftContent, isNot(contains('/*')));
    });
  });
}
