import 'package:path/path.dart' as p;

class PodDependency {
  final String name;
  final String? constraint;
  const PodDependency(this.name, this.constraint);
}

class PodspecParser {
  final String podspecContent;
  const PodspecParser(this.podspecContent);

  /// Extracts declared `resource_bundles` names from podspec content.
  List<String> extractResourceBundleNamesFromPodspec() {
    final result = <String>{};
    final assignmentRe = RegExp(
      r'^\s*s\.resource_bundles?\s*=\s*(\{[\s\S]*?\})\s*$',
      multiLine: true,
    );
    final keyRe = RegExp(r'''['"]([^'"]+)['"]\s*=>''');

    for (final assignment in assignmentRe.allMatches(podspecContent)) {
      final mapExpr = assignment.group(1);
      if (mapExpr == null) continue;
      for (final m in keyRe.allMatches(mapExpr)) {
        final name = m.group(1)?.trim();
        if (name != null && name.isNotEmpty) {
          result.add(name);
        }
      }
    }

    return result.toList()..sort();
  }

  /// Extracts non-Flutter CocoaPods dependencies and their optional version
  /// constraints from `s.dependency` lines.
  List<PodDependency> extractCocoaPodsDependencies() {
    final deps = <PodDependency>[];

    final excludedPods = ['Flutter', 'FlutterMacOS'];

    final depRe = RegExp(
      r'''^\s*s\.dependency\s+['"]([^'"]+)['"](?:\s*,\s*['"]([^'"]+)['"])?''',
      multiLine: true,
    );
    for (final m in depRe.allMatches(podspecContent)) {
      final name = m.group(1)?.trim();
      if (name == null || name.isEmpty) {
        continue;
      }
      final constraint = m.group(2)?.trim();

      if (excludedPods.contains(name)) {
        continue;
      }
      deps.add(PodDependency(name, constraint));
    }

    // Deduplicate by name+constraint.
    final seen = <String>{};
    final result = <PodDependency>[];
    for (final d in deps) {
      final key = '${d.name}::${d.constraint ?? ''}';
      if (seen.add(key)) {
        result.add(d);
      }
    }
    return result;
  }

  /// Converts a podspec-style glob pattern (`*`, `**`, `?`) into `RegExp`.
  RegExp globToRegExp(String glob) {
    // Very small subset: supports *, **, and ?.
    final normalized = p.posix.normalize(glob);
    final sb = StringBuffer('^');
    var i = 0;
    while (i < normalized.length) {
      final ch = normalized[i];
      if (ch == '*') {
        final isDoubleStar =
            (i + 1 < normalized.length) && normalized[i + 1] == '*';
        if (isDoubleStar) {
          sb.write('.*');
          i += 2;
        } else {
          sb.write('[^/]*');
          i += 1;
        }
        continue;
      }
      if (ch == '?') {
        sb.write('[^/]');
        i += 1;
        continue;
      }
      sb.write(RegExp.escape(ch));
      i += 1;
    }
    sb.write(r'$');
    return RegExp(sb.toString());
  }

  /// Returns iOS deployment target declared in podspec, if present.
  String? extractIosDeploymentTarget() {
    // Common forms:
    // - s.ios.deployment_target = '13.0'
    // - s.platform = :ios, '13.0'
    final iosDeploymentRe = RegExp(
      r'''^\s*s\.ios\.deployment_target\s*=\s*['"]([^'"]+)['"]\s*$''',
      multiLine: true,
    );
    final m1 = iosDeploymentRe.firstMatch(podspecContent);
    if (m1 != null) {
      return m1.group(1)?.trim();
    }

    final platformRe = RegExp(
      r'''^\s*s\.platform\s*=\s*:ios\s*,\s*['"]([^'"]+)['"]\s*$''',
      multiLine: true,
    );
    final m2 = platformRe.firstMatch(podspecContent);
    if (m2 != null) {
      return m2.group(1)?.trim();
    }

    return null;
  }
}
