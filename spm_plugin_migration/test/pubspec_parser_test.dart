import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';

void main() {
  group('PubspecParser.requiresFlutterFrameworkSwiftPackage', () {
    test('true for flutter: ">=3.41"', () {
      const yaml = '''
name: pl
environment:
  sdk: ">=3.0.0 <4.0.0"
  flutter: ">=3.41"
''';
      expect(
        PubspecParser(yaml).requiresFlutterFrameworkSwiftPackage(),
        isTrue,
      );
    });

    test("true for flutter: '>=3.41'", () {
      const yaml = '''
environment:
  flutter: '>=3.41'
''';
      expect(
        PubspecParser(yaml).requiresFlutterFrameworkSwiftPackage(),
        isTrue,
      );
    });

    test('true for ">=3.41.0" patch-pinned form', () {
      const yaml = '''
environment:
  flutter: ">=3.41.0"
''';
      expect(
        PubspecParser(yaml).requiresFlutterFrameworkSwiftPackage(),
        isTrue,
      );
    });

    test('true for upper-bounded ">=3.41 <4.0.0"', () {
      const yaml = '''
environment:
  flutter: ">=3.41 <4.0.0"
''';
      expect(
        PubspecParser(yaml).requiresFlutterFrameworkSwiftPackage(),
        isTrue,
      );
    });

    test('true for newer minor (>=3.42)', () {
      const yaml = 'environment:\n  flutter: ">=3.42"\n';
      expect(
        PubspecParser(yaml).requiresFlutterFrameworkSwiftPackage(),
        isTrue,
      );
    });

    test('true for newer major (>=4.0)', () {
      const yaml = 'environment:\n  flutter: ">=4.0"\n';
      expect(
        PubspecParser(yaml).requiresFlutterFrameworkSwiftPackage(),
        isTrue,
      );
    });

    test('false for ">=3.40" (below threshold)', () {
      const yaml = 'environment:\n  flutter: ">=3.40"\n';
      expect(
        PubspecParser(yaml).requiresFlutterFrameworkSwiftPackage(),
        isFalse,
      );
    });

    test('false for ">=3.10"', () {
      const yaml = 'environment:\n  flutter: ">=3.10.0"\n';
      expect(
        PubspecParser(yaml).requiresFlutterFrameworkSwiftPackage(),
        isFalse,
      );
    });

    test('false for unbounded "any"', () {
      const yaml = 'environment:\n  flutter: any\n';
      expect(
        PubspecParser(yaml).requiresFlutterFrameworkSwiftPackage(),
        isFalse,
      );
    });

    test('false when flutter constraint is absent', () {
      const yaml = 'name: pl\nenvironment:\n  sdk: ">=3.0.0"\n';
      expect(
        PubspecParser(yaml).requiresFlutterFrameworkSwiftPackage(),
        isFalse,
      );
    });

    test(
      'false for caret syntax (not supported; opt-in only on explicit `>=`)',
      () {
        const yaml = 'environment:\n  flutter: "^3.41.0"\n';
        expect(
          PubspecParser(yaml).requiresFlutterFrameworkSwiftPackage(),
          isFalse,
        );
      },
    );

    test('not confused by a `flutter:` key inside dependencies block', () {
      const yaml = '''
name: pl
environment:
  sdk: ">=3.0.0"
dependencies:
  flutter:
    sdk: flutter
''';
      expect(
        PubspecParser(yaml).requiresFlutterFrameworkSwiftPackage(),
        isFalse,
      );
    });
  });
}
