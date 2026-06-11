import 'dart:io';

import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

bool _noopArc(String _, String __) => false;

void main() {
  final fs = FileSystemUtils(moveFile: _noopArc);
  group('ObjcRewriter.rewriteImportsToInclude', () {
    test('rewrites quoted #import "Header.h" to path under include/<plugin>/…',
        () async {
      await dir('objc/q', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin', [
                dir('include', [
                  dir('my_plugin', [
                    file('Foo.h', '// public\n'),
                  ]),
                ]),
                file('Impl.m', '#import "Foo.h"\n'),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final rewriter =
          ObjcRewriter(IosPluginContext(path('objc/q/ios'), 'my_plugin'), fs);
      rewriter.rewriteImportsToInclude(
        spmTargetDirOverride:
            Directory(path('objc/q/ios/my_plugin/Sources/my_plugin')),
        spmIncludeModuleDirOverride: Directory(
          path('objc/q/ios/my_plugin/Sources/my_plugin/include/my_plugin'),
        ),
      );

      expect(
        File(path('objc/q/ios/my_plugin/Sources/my_plugin/Impl.m'))
            .readAsStringSync(),
        '#import "./include/my_plugin/Foo.h"\n',
      );
    });

    test(
        'rewrites angle #import <…/Header.h> for local headers mapped by basename',
        () async {
      await dir('objc/a', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin', [
                dir('include', [
                  dir('my_plugin', [
                    file('Foo.h', '//\n'),
                  ]),
                ]),
                file('Api.mm', '#import <SubDir/Foo.h>\n'),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final rewriter =
          ObjcRewriter(IosPluginContext(path('objc/a/ios'), 'my_plugin'), fs);
      rewriter.rewriteImportsToInclude(
        spmTargetDirOverride:
            Directory(path('objc/a/ios/my_plugin/Sources/my_plugin')),
        spmIncludeModuleDirOverride: Directory(
          path('objc/a/ios/my_plugin/Sources/my_plugin/include/my_plugin'),
        ),
      );

      expect(
        File(path('objc/a/ios/my_plugin/Sources/my_plugin/Api.mm'))
            .readAsStringSync(),
        '#import <./include/my_plugin/Foo.h>\n',
      );
    });

    test('does not rewrite when the same basename exists in multiple headers',
        () async {
      await dir('objc/dup', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin', [
                dir('include', [
                  dir('my_plugin', [
                    dir('a', [
                      file('Foo.h', '// a\n'),
                    ]),
                    dir('b', [
                      file('Foo.h', '// b\n'),
                    ]),
                  ]),
                ]),
                file('Impl.m', '#import "Foo.h"\n'),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final rewriter =
          ObjcRewriter(IosPluginContext(path('objc/dup/ios'), 'my_plugin'), fs);
      rewriter.rewriteImportsToInclude(
        spmTargetDirOverride:
            Directory(path('objc/dup/ios/my_plugin/Sources/my_plugin')),
        spmIncludeModuleDirOverride: Directory(
          path('objc/dup/ios/my_plugin/Sources/my_plugin/include/my_plugin'),
        ),
      );

      expect(
        File(path('objc/dup/ios/my_plugin/Sources/my_plugin/Impl.m'))
            .readAsStringSync(),
        '#import "Foo.h"\n',
      );
    });

    test('does not rewrite .m files under include/', () async {
      await dir('objc/inc_skip', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin', [
                dir('include', [
                  dir('my_plugin', [
                    file('Foo.h', '// h\n'),
                    file('Nested.m', '#import "Foo.h"\n'),
                  ]),
                ]),
                dir('src', [
                  file('Other.m', '// ok\n'),
                ]),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final rewriter = ObjcRewriter(
        IosPluginContext(path('objc/inc_skip/ios'), 'my_plugin'),
        fs,
      );
      rewriter.rewriteImportsToInclude(
        spmTargetDirOverride:
            Directory(path('objc/inc_skip/ios/my_plugin/Sources/my_plugin')),
        spmIncludeModuleDirOverride: Directory(
          path(
            'objc/inc_skip/ios/my_plugin/Sources/my_plugin/include/my_plugin',
          ),
        ),
      );

      expect(
        File(path(
          'objc/inc_skip/ios/my_plugin/Sources/my_plugin/include/my_plugin/Nested.m',
        )).readAsStringSync(),
        '#import "Foo.h"\n',
      );
    });

    test('idempotent when run twice on the same tree', () async {
      await dir('objc/id_inc', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin', [
                dir('include', [
                  dir('my_plugin', [
                    file('Foo.h', '//\n'),
                  ]),
                ]),
                file('Impl.m', '#import "Foo.h"\n'),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final rewriter = ObjcRewriter(
          IosPluginContext(path('objc/id_inc/ios'), 'my_plugin'), fs);
      final target =
          Directory(path('objc/id_inc/ios/my_plugin/Sources/my_plugin'));
      final includeMod = Directory(
        path(
          'objc/id_inc/ios/my_plugin/Sources/my_plugin/include/my_plugin',
        ),
      );
      rewriter.rewriteImportsToInclude(
        spmTargetDirOverride: target,
        spmIncludeModuleDirOverride: includeMod,
      );
      rewriter.rewriteImportsToInclude(
        spmTargetDirOverride: target,
        spmIncludeModuleDirOverride: includeMod,
      );

      expect(
        File(path('objc/id_inc/ios/my_plugin/Sources/my_plugin/Impl.m'))
            .readAsStringSync(),
        '#import "./include/my_plugin/Foo.h"\n',
      );
    });
  });

  group('ObjcRewriter.rewriteExternalDependencyImports', () {
    const wrapped = '''#if __has_include(<SDWebImage/WebImage.h>)
#import <SDWebImage/WebImage.h>
#else
@import SDWebImage;
#endif
''';

    test('wraps external pod angle imports with __has_include / @import',
        () async {
      await dir('objc/ext', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin_objc', [
                file('Impl.m', '#import <SDWebImage/WebImage.h>\n'),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final rewriter =
          ObjcRewriter(IosPluginContext(path('objc/ext/ios'), 'my_plugin'), fs);
      rewriter.rewriteExternalDependencyImports(
        objcSourceDir: Directory(
          path('objc/ext/ios/my_plugin/Sources/my_plugin_objc'),
        ),
        externalDependencyNames: ['SDWebImage'],
      );

      expect(
        File(path('objc/ext/ios/my_plugin/Sources/my_plugin_objc/Impl.m'))
            .readAsStringSync(),
        wrapped,
      );
    });

    test('matches dependency module name before subspec slash', () async {
      await dir('objc/ext_sub', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('tgt', [
                file('Sdk.m', '#import <MySdk/Thing.h>\n'),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      ObjcRewriter(
        IosPluginContext(path('objc/ext_sub/ios'), 'my_plugin'),
        fs,
      ).rewriteExternalDependencyImports(
        objcSourceDir:
            Directory(path('objc/ext_sub/ios/my_plugin/Sources/tgt')),
        externalDependencyNames: ['MySdk/OptionalSubspec'],
      );

      expect(
        File(path('objc/ext_sub/ios/my_plugin/Sources/tgt/Sdk.m'))
            .readAsStringSync(),
        '''#if __has_include(<MySdk/Thing.h>)
#import <MySdk/Thing.h>
#else
@import MySdk;
#endif
''',
      );
    });

    test('idempotent for external dependency wrapping', () async {
      await dir('objc/ext_id', [
        dir('ios', [
          dir('my_plugin', [
            dir('Sources', [
              dir('my_plugin_objc', [
                file('Impl.m', '#import <SDWebImage/WebImage.h>\n'),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      final rewriter = ObjcRewriter(
          IosPluginContext(path('objc/ext_id/ios'), 'my_plugin'), fs);
      final dirToScan = Directory(
        path('objc/ext_id/ios/my_plugin/Sources/my_plugin_objc'),
      );
      rewriter.rewriteExternalDependencyImports(
        objcSourceDir: dirToScan,
        externalDependencyNames: ['SDWebImage'],
      );
      rewriter.rewriteExternalDependencyImports(
        objcSourceDir: dirToScan,
        externalDependencyNames: ['SDWebImage'],
      );

      expect(
        File(path('objc/ext_id/ios/my_plugin/Sources/my_plugin_objc/Impl.m'))
            .readAsStringSync(),
        wrapped,
      );
    });
  });

  group('fixtures via test_descriptor', () {
    test('validates final tree with file().validate', () async {
      await dir('objc/val', [
        dir('ios', [
          dir('plug', [
            dir('Sources', [
              dir('plug', [
                dir('include', [
                  dir('plug', [
                    file('X.h', '\n'),
                  ]),
                ]),
                file('main.m', '#import "X.h"\n'),
              ]),
            ]),
          ]),
        ]),
      ]).create();

      ObjcRewriter(IosPluginContext(path('objc/val/ios'), 'plug'), fs)
          .rewriteImportsToInclude(
        spmTargetDirOverride: Directory(path('objc/val/ios/plug/Sources/plug')),
        spmIncludeModuleDirOverride:
            Directory(path('objc/val/ios/plug/Sources/plug/include/plug')),
      );

      await file(
        'objc/val/ios/plug/Sources/plug/main.m',
        equals('#import "./include/plug/X.h"\n'),
      ).validate();
    });
  });
}
