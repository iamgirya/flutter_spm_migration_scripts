import 'dart:io';

import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

import 'test_descriptor_helpers.dart';

void main() {
  group('applyMissingFrameworkImportsToContent', () {
    test('inserts Flutter when Flutter* types are used', () async {
      await transformFileCase(
        caseDir: 'swift_rw/flutter_needed',
        inputText: '''
class X {
  func f() {
    let _ = FlutterMethodChannel(name: "c")
  }
}
''',
        transform: applyMissingFrameworkImportsToContent,
        expectedOut: '''
import Flutter
class X {
  func f() {
    let _ = FlutterMethodChannel(name: "c")
  }
}
''',
      );
    });

    test('inserts Foundation for Dispatch* without Foundation/UIKit', () async {
      await transformFileCase(
        caseDir: 'swift_rw/dispatch',
        inputText: '''
class X {
  func f() {
    DispatchQueue.main.async { }
  }
}
''',
        transform: applyMissingFrameworkImportsToContent,
        expectedOut: '''
import Foundation
class X {
  func f() {
    DispatchQueue.main.async { }
  }
}
''',
      );
    });

    test('inserts UIKit for UI*, CA*, and CG*', () async {
      for (final entry in [
        ('ui', 'final class X { let v: UILabel }'),
        ('ca', 'final class X { let l = CALayer() }'),
        ('cg', 'final class X { let r = CGRect.zero }'),
      ]) {
        await transformFileCase(
          caseDir: 'swift_rw/UIKit_${entry.$1}',
          inputText: entry.$2,
          transform: applyMissingFrameworkImportsToContent,
          expectedOut: 'import UIKit\n${entry.$2}',
        );
      }
    });

    test('does not duplicate imports on second application', () async {
      await dir('swift_rw/idempotent_framework', [
        file('in.swift', '''
class X {
  func f() {
    let _ = FlutterMethodChannel(name: "c")
  }
}
'''),
      ]).create();

      final pIn = path('swift_rw/idempotent_framework/in.swift');
      final once =
          applyMissingFrameworkImportsToContent(File(pIn).readAsStringSync());
      final twice = applyMissingFrameworkImportsToContent(once);
      File(path('swift_rw/idempotent_framework/out')).writeAsStringSync(twice);

      const expectedOnce = '''
import Flutter
class X {
  func f() {
    let _ = FlutterMethodChannel(name: "c")
  }
}
''';
      File(path('swift_rw/idempotent_framework/expected'))
          .writeAsStringSync(expectedOnce);
      await file(
        path('swift_rw/idempotent_framework/out'),
        equals(expectedOnce),
      ).validate();
    });

    test('inserts imports after leading comments and blank lines', () async {
      await transformFileCase(
        caseDir: 'swift_rw/leading_comments',
        inputText: '''
// SPDX

// Banner

class X {
  let _ = FlutterMethodChannel(name: "x")
  let v: UILabel?
}
''',
        transform: applyMissingFrameworkImportsToContent,
        expectedOut: '''
// SPDX

// Banner

import UIKit
import Flutter
class X {
  let _ = FlutterMethodChannel(name: "x")
  let v: UILabel?
}
''',
      );
    });
  });

  group('applySwiftPackageObjcImportToContentIfReferenced', () {
    test('adds conditional import when Swift references ObjC symbols',
        () async {
      await dir('swift_rw/objc_add', [
        file(
          'Native.h',
          r'''
@interface OrbitApi : NSObject
@end
''',
        ),
        file(
          'in.swift',
          '''
final class Sink {
  func use(_ api: OrbitApi) {}
}
''',
        ),
      ]).create();

      final objc = File(path('swift_rw/objc_add/Native.h')).readAsStringSync();
      final symbols = extractObjcDeclaredSymbolsFromContent(objc);

      final swiftIn =
          File(path('swift_rw/objc_add/in.swift')).readAsStringSync();
      final out = applySwiftPackageObjcImportToContentIfReferenced(
        swiftIn,
        objcModuleName: 'orbit_objc',
        objcSymbols: symbols,
      );

      File(path('swift_rw/objc_add/out.swift')).writeAsStringSync(out);

      const expectedSwift = '''
#if SWIFT_PACKAGE
import orbit_objc
#endif
final class Sink {
  func use(_ api: OrbitApi) {}
}
''';
      await file(
        'swift_rw/objc_add/out.swift',
        equals(expectedSwift),
      ).validate();
    });

    test('does nothing when Swift does not reference ObjC symbols', () async {
      await dir('swift_rw/objc_skip', [
        file(
          'Unused.h',
          r'''
@interface Ghost : NSObject
@end
''',
        ),
        file('in.swift', 'struct Plain { let n = 1 }'),
      ]).create();

      final objc = File(path('swift_rw/objc_skip/Unused.h')).readAsStringSync();
      final symbols = extractObjcDeclaredSymbolsFromContent(objc);
      final swiftIn =
          File(path('swift_rw/objc_skip/in.swift')).readAsStringSync();

      final out = applySwiftPackageObjcImportToContentIfReferenced(
        swiftIn,
        objcModuleName: 'ghost_objc',
        objcSymbols: symbols,
      );
      File(path('swift_rw/objc_skip/out.swift')).writeAsStringSync(out);
      await file(
        path('swift_rw/objc_skip/out.swift'),
        equals(swiftIn),
      ).validate();
    });

    test('does not insert when unconditional import already present', () async {
      await transformFileCase(
        caseDir: 'swift_rw/objc_has_import',
        inputText: '''
import plugin_objc

final class Sink {
  func use(_ api: ExportedFace) {}
}
''',
        transform: (input) => applySwiftPackageObjcImportToContentIfReferenced(
          input,
          objcModuleName: 'plugin_objc',
          objcSymbols: {'ExportedFace'},
        ),
        expectedOut: '''
import plugin_objc

final class Sink {
  func use(_ api: ExportedFace) {}
}
''',
      );
    });

    test('inserts conditional block after existing imports and comments',
        () async {
      await transformFileCase(
        caseDir: 'swift_rw/objc_after_imports',
        inputText: '''
// Doc

import Foundation

final class Sink {
  func use(_ api: ExportedFace) {}
}
''',
        transform: (input) => applySwiftPackageObjcImportToContentIfReferenced(
          input,
          objcModuleName: 'plugin_objc',
          objcSymbols: {'ExportedFace'},
        ),
        expectedOut: '''
// Doc

import Foundation
#if SWIFT_PACKAGE
import plugin_objc
#endif

final class Sink {
  func use(_ api: ExportedFace) {}
}
''',
      );
    });

    test('idempotent when applied twice', () async {
      await dir('swift_rw/objc_twice', [
        file(
          'in.swift',
          'final class X { func f(_: ExportedFace?) {} }\n',
        ),
      ]).create();
      final s = {'ExportedFace'};
      final p = path('swift_rw/objc_twice/in.swift');
      final a = File(p).readAsStringSync();
      final once = applySwiftPackageObjcImportToContentIfReferenced(
        a,
        objcModuleName: 'p_objc',
        objcSymbols: s,
      );
      final twice = applySwiftPackageObjcImportToContentIfReferenced(
        once,
        objcModuleName: 'p_objc',
        objcSymbols: s,
      );
      File(path('swift_rw/objc_twice/out')).writeAsStringSync(twice);
      await file(path('swift_rw/objc_twice/out'), equals(once)).validate();
      expect(twice, contains('#if SWIFT_PACKAGE'));
    });
  });

  group('collectObjcDeclaredSymbolsFromObjcTarget', () {
    test('reads symbols from .h fixtures under descriptor directory', () async {
      await dir('swift_rw/objc_collect', [
        file(
          'stub.h',
          r'''
@interface CollectedThing : NSObject
@end
@implementation CollectedThing
@end
''',
        ),
      ]).create();

      final objcDir = Directory(path('swift_rw/objc_collect'));
      final rewriter = SwiftRewriter(FileSystemUtils());
      final merged = rewriter.collectObjcDeclaredSymbolsFromObjcTarget(objcDir);
      File(path('swift_rw/objc_collect/out'))
          .writeAsStringSync((merged.toList()..sort()).join(','));
      await file(
        path('swift_rw/objc_collect/out'),
        equals('CollectedThing'),
      ).validate();
    });
  });
}
