import 'dart:io';

import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

import 'test_descriptor_helpers.dart';

String _depsToText(List<PodDependency> deps) =>
    deps.map((d) => '${d.name}|${d.constraint ?? ''}').join('\n');

void main() {
  group('extractIosDeploymentTarget', () {
    test("reads s.ios.deployment_target = '13.0'", () async {
      await transformFileCase(
        caseDir: 'extract_ios_dt/deployment_13',
        inputText: '''
  s.ios.deployment_target = '13.0'
''',
        transform: (s) =>
            PodspecParser(s).extractIosDeploymentTarget() ?? '__NULL__',
        expectedOut: '13.0',
      );
    });

    test("reads s.platform = :ios, '12.0'", () async {
      await transformFileCase(
        caseDir: 'extract_ios_dt/platform_12',
        inputText: '''
  s.platform = :ios, '12.0'
''',
        transform: (s) =>
            PodspecParser(s).extractIosDeploymentTarget() ?? '__NULL__',
        expectedOut: '12.0',
      );
    });

    test('returns null if not found', () async {
      await transformFileCase(
        caseDir: 'extract_ios_dt/missing',
        inputText: 's.name = "foo"',
        transform: (s) =>
            PodspecParser(s).extractIosDeploymentTarget() ?? '__NULL__',
        expectedOut: '__NULL__',
      );
    });
  });

  group('extractCocoaPodsDependencies', () {
    test('parses dependency without constraint', () async {
      await dir('deps/unconstrained', [
        file('in', '''
  s.dependency 'Alamofire'
'''),
      ]).create();
      final deps = PodspecParser(
        File(path('deps/unconstrained/in')).readAsStringSync(),
      ).extractCocoaPodsDependencies();
      File(path('deps/unconstrained/out')).writeAsStringSync(_depsToText(deps));
      await file('deps/unconstrained/out', equals('Alamofire|')).validate();
    });

    test('parses dependency with constraint', () async {
      await dir('deps/constrained', [
        file('in', '''
  s.dependency "Foo", '~> 1.2.3'
'''),
      ]).create();
      final deps = PodspecParser(
        File(path('deps/constrained/in')).readAsStringSync(),
      ).extractCocoaPodsDependencies();
      File(path('deps/constrained/out')).writeAsStringSync(_depsToText(deps));
      await file(
        'deps/constrained/out',
        equals('Foo|~> 1.2.3'),
      ).validate();
    });

    test('removes duplicates by name + constraint', () async {
      await dir('deps/dedup', [
        file('in', '''
  s.dependency 'Bar'
  s.dependency 'Bar'
  s.dependency 'Bar', '~> 2.0'
  s.dependency 'Bar', '~> 2.0'
  s.dependency 'Bar'
'''),
      ]).create();
      final deps = PodspecParser(
        File(path('deps/dedup/in')).readAsStringSync(),
      ).extractCocoaPodsDependencies();
      File(path('deps/dedup/out')).writeAsStringSync(_depsToText(deps));
      await file(
        'deps/dedup/out',
        equals('Bar|\nBar|~> 2.0'),
      ).validate();
    });
  });

  group('extractResourceBundleNamesFromPodspec', () {
    test('extracts keys and returns sorted list', () async {
      await transformFileCase(
        caseDir: 'resource_bundles/multi',
        inputText: '''
  s.resource_bundles = { 'Zed' => [...], 'Alpha' => [...] }
''',
        transform: (s) =>
            PodspecParser(s).extractResourceBundleNamesFromPodspec().join('\n'),
        expectedOut: 'Alpha\nZed',
      );
    });

    test('supports resource_bundle (singular) form', () async {
      await transformFileCase(
        caseDir: 'resource_bundles/singular',
        inputText: '''
  s.resource_bundle = { "solo" => ['a'] }
''',
        transform: (s) =>
            PodspecParser(s).extractResourceBundleNamesFromPodspec().join('\n'),
        expectedOut: 'solo',
      );
    });
  });

  group('globToRegExp', () {
    final podspecParser = PodspecParser('');
    test('single * does not cross /', () async {
      await dir('glob/star', [
        file('pattern.txt', 'include/*.h'),
      ]).create();
      final pat = File(path('glob/star/pattern.txt')).readAsStringSync().trim();
      final re = podspecParser.globToRegExp(pat);
      File(path('glob/star/out')).writeAsStringSync(
        [
          'include/Foo.h:${re.hasMatch('include/Foo.h')}',
          'include/foo/Bar.h:${re.hasMatch('include/foo/Bar.h')}',
        ].join('\n'),
      );
      await file(
        'glob/star/out',
        equals('include/Foo.h:true\ninclude/foo/Bar.h:false'),
      ).validate();
    });

    test('** matches across path segments', () async {
      await dir('glob/dstar', [
        file('pattern.txt', '**/Headers/*.h'),
      ]).create();
      final pat =
          File(path('glob/dstar/pattern.txt')).readAsStringSync().trim();
      final re = podspecParser.globToRegExp(pat);
      File(path('glob/dstar/out')).writeAsStringSync(
        [
          'Pods/Headers/Foo.h:${re.hasMatch('Pods/Headers/Foo.h')}',
          'A/B/Headers/X.h:${re.hasMatch('A/B/Headers/X.h')}',
          'Foo.h:${re.hasMatch('Foo.h')}',
        ].join('\n'),
      );
      await file(
        'glob/dstar/out',
        equals(
          'Pods/Headers/Foo.h:true\nA/B/Headers/X.h:true\nFoo.h:false',
        ),
      ).validate();
    });

    test('? matches one non-slash character', () async {
      await dir('glob/qmark', [
        file('pattern.txt', 'src/?.h'),
      ]).create();
      final pat =
          File(path('glob/qmark/pattern.txt')).readAsStringSync().trim();
      final re = podspecParser.globToRegExp(pat);
      File(path('glob/qmark/out')).writeAsStringSync(
        [
          'src/X.h:${re.hasMatch('src/X.h')}',
          'src/ab.h:${re.hasMatch('src/ab.h')}',
        ].join('\n'),
      );
      await file(
        'glob/qmark/out',
        equals('src/X.h:true\nsrc/ab.h:false'),
      ).validate();
    });
  });
}
