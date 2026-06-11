import 'dart:io';

import 'package:args/args.dart';

const _skipPods = {'Flutter', 'FlutterMacOS'};

enum _SpmStatus { ready, missing }

class _Pod {
  final String name;
  final Set<String> deps = <String>{};
  _Pod(this.name);
}

void main(List<String> args) {
  // cli
  final parser = getArgParser();
  late final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    exit(64);
  }

  if (results.flag('help')) {
    stdout.writeln('CocoaPods dependency graph analysis from Podfile.lock.\n');
    stdout.writeln(parser.usage);
    exit(0);
  }

  final podfilePath = results.option('lock-file')!;
  final pluginsDir =
      results.option('plugins-dir') ?? _derivePluginsDir(podfilePath);

  final podfile = File(podfilePath);
  if (!podfile.existsSync()) {
    stderr.writeln('Podfile.lock not found: $podfilePath');
    stderr.writeln('Run from the project root or pass an explicit path:\n'
        '  dart run analyze_pods.dart -l <Podfile.lock> [-s <.symlinks/plugins>]');
    exit(1);
  }

  // parse podfile.lock
  final pods = <String, _Pod>{};
  final appEntries = <String>{};
  _parse(podfile.readAsLinesSync(), pods, appEntries);

  // scan plugins for spm status
  final pluginStatus = <String, _SpmStatus>{};
  final pluginsRoot = Directory(pluginsDir);
  if (pluginsRoot.existsSync()) {
    _scanPlugins(pluginsRoot, pluginStatus);
  } else {
    stderr.writeln('WARNING: $pluginsDir not found. '
        'SPM status for plugins will not be shown. '
        'Run pod install so plugin symlinks are created.');
  }

  // scan pods for missing arm64-sim
  final missingArm64Sim = <String>{};
  final podsRoot = Directory(_derivePodsDir(podfilePath));
  if (podsRoot.existsSync()) {
    _scanXcframeworks(podsRoot, missingArm64Sim);
  }

  // build subgraph components
  final components = _findComponents(pods);
  components.sort((a, b) {
    final byLen = b.length.compareTo(a.length);
    if (byLen != 0) return byLen;
    return a.first.compareTo(b.first);
  });

  // print subgraphs with tags
  _printReport(components, pods, appEntries, pluginStatus, missingArm64Sim);
}

ArgParser getArgParser() => ArgParser(usageLineLength: 100)
  ..addOption(
    'lock-file',
    abbr: 'l',
    defaultsTo: 'ios/Podfile.lock',
    help: 'Path to Podfile.lock',
  )
  ..addOption(
    'plugins-dir',
    abbr: 's',
    help:
        '.symlinks/plugins directory (default: ios/.symlinks/plugins next to the lock file)',
  )
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Print usage');

String _derivePluginsDir(String podfileLockPath) {
  final f = File(podfileLockPath).absolute;
  // .../<project>/ios/Podfile.lock -> .../<project>/ios/.symlinks/plugins
  return '${f.parent.path}/.symlinks/plugins';
}

String _derivePodsDir(String podfileLockPath) {
  final f = File(podfileLockPath).absolute;
  return '${f.parent.path}/Pods';
}

void _scanPlugins(Directory root, Map<String, _SpmStatus> status) {
  for (final entry in root.listSync(followLinks: false)) {
    final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final resolved = Directory(entry.path);
    if (!resolved.existsSync()) continue; // broken symlink
    status[name] =
        _hasIosPackageSwift(resolved) ? _SpmStatus.ready : _SpmStatus.missing;
  }
}

void _scanXcframeworks(Directory podsRoot, Set<String> missing) {
  const skipDirs = {
    'Headers',
    'Local Podspecs',
    'Pods.xcodeproj',
    'Target Support Files',
  };
  for (final podDir in podsRoot.listSync(followLinks: false)) {
    if (podDir is! Directory) continue;
    final podName = podDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (podName.startsWith('.') || skipDirs.contains(podName)) continue;

    // Recursively find every *.xcframework inside the pod.
    final stack = <Directory>[podDir];
    while (stack.isNotEmpty) {
      final d = stack.removeLast();
      try {
        for (final e in d.listSync(followLinks: false)) {
          if (e is! Directory) continue;
          if (e.path.endsWith('.xcframework')) {
            final infoPlist = File('${e.path}/Info.plist');
            if (infoPlist.existsSync() &&
                !_hasIosArm64SimSlice(infoPlist.readAsStringSync())) {
              missing.add(podName);
            }
          } else {
            stack.add(e);
          }
        }
      } catch (_) {
        // Ignore permission errors.
      }
    }
  }
}

bool _hasIosArm64SimSlice(String plist) {
  // Each AvailableLibraries array entry is a separate <dict> describing one slice.
  // A slice counts as suitable when:
  //   SupportedPlatform == "ios"
  //   SupportedPlatformVariant == "simulator"
  //   SupportedArchitectures contains "arm64"
  final body = _plistArrayBody(plist, 'AvailableLibraries');
  if (body == null) return false;

  final dictRe = RegExp(r'<dict>(.*?)</dict>', dotAll: true);
  for (final m in dictRe.allMatches(body)) {
    final lib = m.group(1)!;
    if (_plistString(lib, 'SupportedPlatform') == 'ios' &&
        _plistString(lib, 'SupportedPlatformVariant') == 'simulator' &&
        _plistStringArray(lib, 'SupportedArchitectures').contains('arm64')) {
      return true;
    }
  }
  return false;
}

String? _plistArrayBody(String plist, String key) {
  final start = RegExp('<key>$key</key>\\s*<array>').firstMatch(plist);
  if (start == null) return null;
  var depth = 1;
  var i = start.end;
  while (i < plist.length && depth > 0) {
    final open = plist.indexOf('<array>', i);
    final close = plist.indexOf('</array>', i);
    if (close < 0) return null;
    if (open >= 0 && open < close) {
      depth++;
      i = open + '<array>'.length;
    } else {
      depth--;
      if (depth == 0) return plist.substring(start.end, close);
      i = close + '</array>'.length;
    }
  }
  return null;
}

String? _plistString(String body, String key) {
  return RegExp('<key>$key</key>\\s*<string>([^<]*)</string>')
      .firstMatch(body)
      ?.group(1);
}

List<String> _plistStringArray(String body, String key) {
  final m = RegExp('<key>$key</key>\\s*<array>(.*?)</array>', dotAll: true)
      .firstMatch(body);
  if (m == null) return const [];
  return RegExp(r'<string>([^<]*)</string>')
      .allMatches(m.group(1)!)
      .map((x) => x.group(1)!)
      .toList();
}

void _parse(
  List<String> lines,
  Map<String, _Pod> pods,
  Set<String> appEntries,
) {
  var section = '';
  _Pod? current;

  for (final raw in lines) {
    final line = raw.trimRight();
    if (line.isEmpty) continue;

    if (line.startsWith('PODS:')) {
      section = 'PODS';
      continue;
    }
    if (line.startsWith('DEPENDENCIES:')) {
      section = 'DEPS';
      continue;
    }
    if (line.startsWith('SPEC REPOS:') ||
        line.startsWith('EXTERNAL SOURCES:') ||
        line.startsWith('CHECKOUT OPTIONS:') ||
        line.startsWith('SPEC CHECKSUMS:') ||
        line.startsWith('PODFILE CHECKSUM:') ||
        line.startsWith('COCOAPODS:')) {
      section = 'OTHER';
      current = null;
      continue;
    }

    if (section == 'PODS') {
      // "  - Foo (1.0)" / "  - Foo (1.0):" — pod declaration (2 leading spaces).
      // "    - Bar (= 1.0)" — dependency of the current pod (4 leading spaces).
      if (line.startsWith('  - ') && !line.startsWith('    ')) {
        final name = _extractName(line.substring(4));
        if (_skipPods.contains(name)) {
          current = null;
          continue;
        }
        current = pods.putIfAbsent(name, () => _Pod(name));
      } else if (line.startsWith('    - ') && current != null) {
        final name = _extractName(line.substring(6));
        if (_skipPods.contains(name)) continue;
        current.deps.add(name);
        pods.putIfAbsent(name, () => _Pod(name));
      }
    } else if (section == 'DEPS') {
      if (line.startsWith('  - ')) {
        final name = _extractName(line.substring(4));
        if (_skipPods.contains(name)) continue;
        appEntries.add(name);
      }
    }
  }
}

String _extractName(String s) {
  if (s.endsWith(':')) s = s.substring(0, s.length - 1);
  s = s.trim();
  // Names with versions like 3.46.0+1 are fully quoted: "sqlite3 (3.46.0+1)".
  if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
    s = s.substring(1, s.length - 1);
  }
  final paren = s.indexOf('(');
  if (paren >= 0) s = s.substring(0, paren);
  s = s.trim();
  // Strip a stray quote left after the version was cut off.
  if (s.startsWith('"')) s = s.substring(1);
  if (s.endsWith('"')) s = s.substring(0, s.length - 1);
  return s.trim();
}

bool _hasIosPackageSwift(Directory pluginDir) {
  for (final platform in const ['ios', 'darwin']) {
    final platformDir = Directory('${pluginDir.path}/$platform');
    if (!platformDir.existsSync()) continue;
    try {
      for (final entry in platformDir.listSync(followLinks: false)) {
        if (entry is Directory &&
            File('${entry.path}/Package.swift').existsSync()) {
          return true;
        }
      }
    } catch (_) {
      // Ignore permission errors.
    }
  }
  return false;
}

List<List<String>> _findComponents(Map<String, _Pod> pods) {
  final undirected = <String, Set<String>>{
    for (final n in pods.keys) n: <String>{},
  };
  pods.forEach((node, pod) {
    for (final dep in pod.deps) {
      undirected[node]!.add(dep);
      undirected.putIfAbsent(dep, () => <String>{}).add(node);
    }
  });

  final visited = <String>{};
  final result = <List<String>>[];
  for (final start in pods.keys) {
    if (visited.contains(start)) continue;
    final stack = <String>[start];
    final component = <String>[];
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      if (!visited.add(node)) continue;
      component.add(node);
      for (final neighbour in undirected[node] ?? const <String>{}) {
        if (!visited.contains(neighbour)) stack.add(neighbour);
      }
    }
    component.sort();
    result.add(component);
  }
  return result;
}

void _printReport(
  List<List<String>> components,
  Map<String, _Pod> pods,
  Set<String> appEntries,
  Map<String, _SpmStatus> pluginStatus,
  Set<String> missingArm64Sim,
) {
  const border = 60;
  final nontrivial = components.where((c) => c.length > 1).toList();
  final trivial = components.where((c) => c.length == 1).toList();

  if (pluginStatus.isNotEmpty || missingArm64Sim.isNotEmpty) {
    print('Legend: [SPM ✓] — Flutter plugin with Package.swift; '
        '[SPM ✗] — Flutter plugin without Package.swift; '
        '[!! arm64-sim] — xcframework missing the iOS arm64 simulator slice.');
    print('');
  }

  for (var i = 0; i < nontrivial.length; i++) {
    final comp = nontrivial[i];
    final compSet = comp.toSet();
    final entries = appEntries.where(compSet.contains).toList()..sort();

    print('┌─── Subgraph #${i + 1}  [${comp.length} nodes] ───');
    print('│  Entry points [APP]: '
        '${entries.isEmpty ? "(none — transitive only)" : entries.join(", ")}');
    print('│');

    final shown = <String>{};
    final roots = entries.isEmpty ? comp : entries;
    final rootsAreApp = entries.isNotEmpty;

    for (var j = 0; j < roots.length; j++) {
      final lines = <String>[];
      _renderTree(
        roots[j],
        prefix: '',
        isRoot: true,
        isLast: true,
        output: lines,
        shown: shown,
        pods: pods,
        isApp: rootsAreApp,
        pluginStatus: pluginStatus,
        missingArm64Sim: missingArm64Sim,
      );
      for (final l in lines) {
        print('│  $l');
      }
      if (j < roots.length - 1) print('│');
    }

    print('└${'─' * border}');
    print('');
  }

  if (trivial.isNotEmpty) {
    final names = trivial.map((c) => c.single).toList()..sort();
    final apps = names.where(appEntries.contains).toList();
    final orphans = names.where((n) => !appEntries.contains(n)).toList();

    final ready = <String>[];
    final missing = <String>[];
    final native = <String>[];
    for (final n in apps) {
      switch (pluginStatus[n]) {
        case _SpmStatus.ready:
          ready.add(n);
          break;
        case _SpmStatus.missing:
          missing.add(n);
          break;
        case null:
          native.add(n);
          break;
      }
    }

    print('┌─── Trivial subgraphs [${trivial.length}] ───');
    String suffix(String n) {
      final m = _statusMarker(pluginStatus[n]);
      final arm = _arm64SimMarker(n, missingArm64Sim);
      final parts = [m, arm].where((s) => s.isNotEmpty).join(' ');
      return parts.isEmpty ? '' : '  $parts';
    }

    if (ready.isNotEmpty) {
      print('│  [APP] Flutter plugins with Package.swift '
          '[SPM ✓] (${ready.length}):');
      for (final n in ready) {
        print('│    • $n${suffix(n).replaceFirst('  [SPM ✓]', '')}');
      }
    }
    if (missing.isNotEmpty) {
      print('│  [APP] Flutter plugins without Package.swift '
          '[SPM ✗] (${missing.length}):');
      for (final n in missing) {
        print('│    • $n${suffix(n).replaceFirst('  [SPM ✗]', '')}');
      }
    }
    if (native.isNotEmpty) {
      print('│  [APP] native iOS pods (${native.length}):');
      for (final n in native) {
        print('│    • $n${suffix(n)}');
      }
    }
    if (orphans.isNotEmpty) {
      print('│  No entry point (${orphans.length}):');
      for (final n in orphans) {
        print('│    • $n${suffix(n)}');
      }
    }
    print('└${'─' * border}');
    print('');
  }
}

String _statusMarker(_SpmStatus? s) {
  switch (s) {
    case _SpmStatus.ready:
      return '[SPM ✓]';
    case _SpmStatus.missing:
      return '[SPM ✗]';
    case null:
      return '';
  }
}

String _arm64SimMarker(String name, Set<String> missing) {
  // Subspecs (Foo/Bar) inherit the parent pod status.
  final top = name.split('/').first;
  return missing.contains(top) ? '[!! arm64-sim]' : '';
}

void _renderTree(
  String name, {
  required String prefix,
  required bool isRoot,
  required bool isLast,
  required List<String> output,
  required Set<String> shown,
  required Map<String, _Pod> pods,
  required bool isApp,
  required Map<String, _SpmStatus> pluginStatus,
  required Set<String> missingArm64Sim,
}) {
  final connector = isRoot ? '' : (isLast ? '└── ' : '├── ');
  final appPrefix = isApp ? '[APP] ' : '';
  final spm = _statusMarker(pluginStatus[name]);
  final arm = _arm64SimMarker(name, missingArm64Sim);
  final tags = [spm, arm].where((s) => s.isNotEmpty).join(' ');
  final spmSuffix = tags.isEmpty ? '' : '  $tags';

  if (shown.contains(name)) {
    output.add('$prefix$connector$appPrefix$name$spmSuffix  [↑]');
    return;
  }
  shown.add(name);
  output.add('$prefix$connector$appPrefix$name$spmSuffix');

  final children = (pods[name]?.deps.toList() ?? const <String>[])..sort();
  for (var i = 0; i < children.length; i++) {
    final isLastChild = i == children.length - 1;
    final childPrefix = prefix + (isRoot ? '' : (isLast ? '    ' : '│   '));
    _renderTree(
      children[i],
      prefix: childPrefix,
      isRoot: false,
      isLast: isLastChild,
      output: output,
      shown: shown,
      pods: pods,
      isApp: false,
      pluginStatus: pluginStatus,
      missingArm64Sim: missingArm64Sim,
    );
  }
}
