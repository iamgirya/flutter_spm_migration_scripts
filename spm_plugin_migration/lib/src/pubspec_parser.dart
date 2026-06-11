/// Light-touch reader for plugin `pubspec.yaml`.
///
/// Only extracts what the migration script needs (currently: the Flutter SDK
/// lower bound). Avoids pulling in a YAML dependency — the lines we care about
/// follow a narrow, well-known shape.
class PubspecParser {
  final String content;
  const PubspecParser(this.content);

  /// `true` when `pubspec.yaml` declares a Flutter SDK constraint whose lower
  /// bound is at least 3.41 — the version where `FlutterFramework` became
  /// available as a local Swift Package and plugins should depend on it
  /// directly instead of relying on the embedding to expose Flutter symbols.
  ///
  /// Matches `flutter: ">=3.41"`, `flutter: '>=3.41'`, `flutter: ">=3.41.0"`,
  /// `flutter: ">=3.41 <4.0.0"` and so on. Other constraint forms (`any`,
  /// caret syntax, unpinned) return `false` — opt in only on explicit `>=`.
  bool requiresFlutterFrameworkSwiftPackage() {
    final match = RegExp(
      r'''^\s*flutter:\s*['"]\s*>=\s*(\d+)\.(\d+)''',
      multiLine: true,
    ).firstMatch(content);
    if (match == null) return false;
    final major = int.tryParse(match.group(1)!);
    final minor = int.tryParse(match.group(2)!);
    if (major == null || minor == null) return false;
    return major > 3 || (major == 3 && minor >= 41);
  }
}
