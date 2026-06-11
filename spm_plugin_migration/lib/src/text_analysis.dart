/// Returns the set of framework names that should be imported but are not yet
/// present in [content].
///
/// Covers:
/// - `Foundation` — when `Dispatch*` types are used and neither Foundation nor
///   UIKit (which transitively includes Foundation) is already imported.
/// - `UIKit` — when `UI*` (UIKit), `CA*` (QuartzCore), or `CG*`
///   (CoreGraphics) types are used; all three are reachable via `import UIKit`
///   on iOS.
/// - `Flutter` — when any `Flutter*` type is referenced.
Set<String> missingSwiftImports(String content) {
  bool hasImport(String name) => RegExp(
        r'^\s*import\s+' + RegExp.escape(name) + r'\s*$',
        multiLine: true,
      ).hasMatch(content);

  final result = <String>{};

  // Foundation: Dispatch* types. Skipped when UIKit is already present because
  // UIKit transitively imports Foundation.
  if (RegExp(r'\bDispatch(Queue|Date|Group|Semaphore|WorkItem|BarrierFlag)\b')
          .hasMatch(content) &&
      !hasImport('Foundation') &&
      !hasImport('UIKit')) {
    result.add('Foundation');
  }

  // UIKit: covers UIKit (UI*), QuartzCore (CA*), and CoreGraphics (CG*).
  if ((RegExp(r'\bUI[A-Z][A-Za-z0-9_]*\b').hasMatch(content) ||
          RegExp(r'\bCA[A-Z][A-Za-z0-9_]*\b').hasMatch(content) ||
          RegExp(r'\bCG[A-Z][A-Za-z0-9_]*\b').hasMatch(content)) &&
      !hasImport('UIKit')) {
    result.add('UIKit');
  }

  // Flutter
  if (RegExp(r'\bFlutter[A-Za-z0-9_]+\b').hasMatch(content) &&
      !hasImport('Flutter')) {
    result.add('Flutter');
  }

  return result;
}

Set<String> extractObjcDeclaredSymbolsFromContent(String content) {
  final symbols = <String>{};
  final patterns = <RegExp>[
    RegExp(r'@interface\s+([A-Za-z_][A-Za-z0-9_]*)'),
    RegExp(r'@implementation\s+([A-Za-z_][A-Za-z0-9_]*)'),
    RegExp(r'@protocol\s+([A-Za-z_][A-Za-z0-9_]*)'),
    RegExp(
        r'typedef\s+NS_(?:ENUM|OPTIONS)\s*\([^,]+,\s*([A-Za-z_][A-Za-z0-9_]*)'),
  ];
  for (final re in patterns) {
    for (final m in re.allMatches(content)) {
      final symbol = m.group(1)?.trim();
      if (symbol != null && symbol.isNotEmpty) {
        symbols.add(symbol);
      }
    }
  }
  return symbols;
}

Set<String> findReferencedSymbolsInSwiftContent(
  String content,
  Iterable<String> symbols,
) {
  final found = <String>{};
  for (final symbol in symbols) {
    if (symbol.isEmpty) continue;
    final symbolRe = RegExp('\\b${RegExp.escape(symbol)}\\b');
    if (symbolRe.hasMatch(content)) {
      found.add(symbol);
    }
  }
  return found;
}

bool isNamedResourceBundleLookupLine(
  String line,
  Iterable<String> bundleNames,
) {
  final lineHasBundleName = bundleNames.any(
    (name) => line.contains('"$name"') || line.contains("'$name'"),
  );
  if (!lineHasBundleName) return false;

  return line.contains('forResource') ||
      line.contains('pathForResource') ||
      line.contains('url(forResource') ||
      // ObjC selector form is camelCase (`URLForResource:withExtension:`),
      // which the case-sensitive `forResource` substring above does not match.
      line.contains('URLForResource') ||
      line.contains('Bundle(') ||
      line.contains('NSBundle') ||
      line.contains('.bundle');
}
