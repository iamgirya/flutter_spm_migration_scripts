import 'dart:io';

import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

void main() {
  group('missingSwiftImports', () {
    test('adds Flutter when Flutter* symbols present and Flutter not imported',
        () async {
      await dir('swift_imports/flutter_needed', [
        file('in.swift', '''
class X {
  func f() {
    let _ = FlutterMethodChannel(name: "c")
  }
}
'''),
      ]).create();
      final content = File(path('swift_imports/flutter_needed/in.swift'))
          .readAsStringSync();
      final got = missingSwiftImports(content).join('\n');
      File(path('swift_imports/flutter_needed/out')).writeAsStringSync(got);
      await file('swift_imports/flutter_needed/out', contains('Flutter'))
          .validate();
    });

    test('does not add Foundation when UIKit is already imported', () async {
      await dir('swift_imports/uikit_no_foundation', [
        file('in.swift', '''
import UIKit

class X {
  func f() {
    DispatchQueue.main.async { }
  }
}
'''),
      ]).create();
      final content = File(path('swift_imports/uikit_no_foundation/in.swift'))
          .readAsStringSync();
      final got = missingSwiftImports(content).join('\n');
      File(path('swift_imports/uikit_no_foundation/out'))
          .writeAsStringSync(got);
      await file(
        'swift_imports/uikit_no_foundation/out',
        isNot(contains('Foundation')),
      ).validate();
    });

    test('suggests UIKit for UI*, CA*, and CG* type patterns', () async {
      await dir('swift_imports/ui_patterns', [
        file('ui.txt', 'let v: UILabel'),
        file('ca.txt', 'let l = CALayer()'),
        file('cg.txt', 'let r = CGRect.zero'),
      ]).create();

      for (final name in ['ui', 'ca', 'cg']) {
        final text = File(path('swift_imports/ui_patterns/$name.txt'))
            .readAsStringSync();
        final got = missingSwiftImports(text).join('\n');
        File(path('swift_imports/ui_patterns/out_$name'))
            .writeAsStringSync(got);
        await file(
          'swift_imports/ui_patterns/out_$name',
          contains('UIKit'),
        ).validate();
      }
    });
  });

  group('extractObjcDeclaredSymbolsFromContent', () {
    test(
        'extracts symbols from @interface, @implementation, @protocol, NS_ENUM',
        () async {
      await dir('objc_syms/basic', [
        file('in.m', r'''
@interface FooThing : NSObject
@end
@implementation BarThing
@end
@protocol BazProto
@end
typedef NS_ENUM(NSInteger, MyEnumKind) {
  MyEnumKindA = 0,
};
'''),
      ]).create();
      final content = File(path('objc_syms/basic/in.m')).readAsStringSync();
      final symbols = extractObjcDeclaredSymbolsFromContent(content).toList()
        ..sort();
      File(path('objc_syms/basic/out')).writeAsStringSync(symbols.join('\n'));
      await file(
        'objc_syms/basic/out',
        equals(
          [
            'BarThing',
            'BazProto',
            'FooThing',
            'MyEnumKind',
          ].join('\n'),
        ),
      ).validate();
    });
  });

  group('findReferencedSymbolsInSwiftContent', () {
    test('returns symbols only on whole-word matches', () async {
      await dir('ref_swift/whole_word', [
        file('in.swift', 'let x = FooThingExtra(FooThing())'),
        file('symbols.txt', 'FooThing\nBar'),
      ]).create();
      final content =
          File(path('ref_swift/whole_word/in.swift')).readAsStringSync();
      final symLines =
          File(path('ref_swift/whole_word/symbols.txt')).readAsLinesSync();
      final symbols = symLines.where((l) => l.isNotEmpty).toSet();
      final got = findReferencedSymbolsInSwiftContent(content, symbols).toList()
        ..sort();
      File(path('ref_swift/whole_word/out')).writeAsStringSync(got.join('\n'));
      await file('ref_swift/whole_word/out', equals('FooThing')).validate();
    });

    test('does not treat substrings of other identifiers as matches', () async {
      await dir('ref_swift/no_substring', [
        file('in.swift', 'struct NotFooThing { }'),
      ]).create();
      final content =
          File(path('ref_swift/no_substring/in.swift')).readAsStringSync();
      final got = findReferencedSymbolsInSwiftContent(content, {'FooThing'})
          .toList()
        ..sort();
      File(path('ref_swift/no_substring/out'))
          .writeAsStringSync(got.join('\n'));
      await file('ref_swift/no_substring/out', isEmpty).validate();
    });
  });

  group('isNamedResourceBundleLookupLine', () {
    const bundleNames = ['MyPluginResources'];

    test('true when line has lookup API and quoted bundle name', () async {
      await dir('bundle_line/true_cases', [
        file('a.txt',
            'Bundle.main.path(forResource: "img", ofType: "png", inDirectory: "MyPluginResources")'),
        file('b.txt',
            "pathForResource('foo', ofType: 'txt', inDirectory: 'MyPluginResources')"),
        file('c.txt',
            'try Bundle.main.url(forResource: "nib", withExtension: "bundle", subdirectory: "MyPluginResources")'),
        // ObjC: camelCase selector URLForResource:withExtension: with a named bundle.
        file('d.txt',
            '[[NSBundle bundleForClass:[self class]] URLForResource:@"MyPluginResources" withExtension:@"bundle"];'),
      ]).create();

      for (final id in ['a', 'b', 'c', 'd']) {
        final line =
            File(path('bundle_line/true_cases/$id.txt')).readAsStringSync();
        final v = isNamedResourceBundleLookupLine(line, bundleNames);
        File(path('bundle_line/true_cases/result_$id'))
            .writeAsStringSync(v.toString());
        await file('bundle_line/true_cases/result_$id', equals('true'))
            .validate();
      }
    });

    test('false when bundle name is absent from the line', () async {
      await dir('bundle_line/false_cases', [
        file('a.txt', 'Bundle.main.path(forResource: "img", ofType: "png")'),
        file('b.txt', 'let _ = NSBundle.mainBundle()'),
      ]).create();

      for (final id in ['a', 'b']) {
        final line =
            File(path('bundle_line/false_cases/$id.txt')).readAsStringSync();
        final v = isNamedResourceBundleLookupLine(line, bundleNames);
        File(path('bundle_line/false_cases/result_$id'))
            .writeAsStringSync(v.toString());
        await file('bundle_line/false_cases/result_$id', equals('false'))
            .validate();
      }
    });
  });
}
