import 'dart:io';

import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

Matcher matcherForExpected(Object expected) =>
    expected is Matcher ? expected : equals(expected as String);

/// Input under [caseDir]/in, output under [caseDir]/out, validated against
/// [expectedOut] (plain [String] or [Matcher]).
Future<void> transformFileCase({
  required String caseDir,
  required String inputText,
  required String Function(String input) transform,
  required Object expectedOut,
}) async {
  await dir(caseDir, [
    file('in', inputText),
  ]).create();
  final input = File(path('$caseDir/in')).readAsStringSync();
  File(path('$caseDir/out')).writeAsStringSync(transform(input));
  await file('$caseDir/out', matcherForExpected(expectedOut)).validate();
}
