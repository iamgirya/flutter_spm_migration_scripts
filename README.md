# flutter_spm_migration_scripts

Dart CLI tools for migrating Flutter plugins from CocoaPods to Swift Package Manager (SwiftPM).

## Tools

### [`podfile_dependencies_analyze/`](podfile_dependencies_analyze/)

Read-only analysis tool. Parses `Podfile.lock`, builds the CocoaPods dependency graph, and prints a report showing how pods cluster into components, which Flutter plugins already have an SPM layout, and which binary xcframeworks are missing an iOS Simulator arm64 slice.

```sh
dart run podfile_dependencies_analyze.dart
```

Use this **before** migrating to understand your current CocoaPods dependency landscape.

---

### [`spm_plugin_migration/`](spm_plugin_migration/)

Automated migration tool. Rewrites a Flutter plugin's iOS directory from the legacy CocoaPods-only layout to the SwiftPM-compatible layout while keeping CocoaPods working in parallel. Handles source moves, header relocation, mixed Swift/ObjC splits, `Package.swift` generation, `.podspec` updates, and more.

```sh
dart run bin/spm_plugin_migration.dart /path/to/your/plugin
```

Use this **per plugin** once you've identified which plugins to migrate.
