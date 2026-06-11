# spm_plugin_migration

A Dart CLI that migrates a Flutter plugin's iOS implementation from the legacy
CocoaPods-only layout to the Swift Package Manager (SwiftPM) compatible layout,
while keeping CocoaPods working in parallel.

It automates the manual steps described in the Flutter docs:
[Adding Swift Package Manager support to a plugin](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-plugin-authors).

## Usage

```sh
dart run bin/spm_plugin_migration.dart /abs/path/to/your/plugin
```

The script edits the plugin in place. Review the diff before committing.

## What the script does

- Parses `<plugin>.podspec` to extract iOS deployment target, CocoaPods dependencies, and declared `resource_bundles` names.
- Reads `pubspec.yaml` to detect a Flutter SDK lower bound of `>=3.41` (enables the local `FlutterFramework` SwiftPM dependency).
- Detects the plugin language (Swift / Objective-C / Mixed) by scanning `ios/Classes/` and any existing SwiftPM sources.
- Moves sources from `ios/Classes/` into `ios/<plugin>/Sources/<plugin>/`.
- Moves `ios/Assets/`, `ios/Resources/`, and `PrivacyInfo.xcprivacy` into the new SwiftPM layout.
- Relocates Objective-C public headers into `Sources/<plugin>/include/<plugin>/`.
- Relocates and deduplicates `*.modulemap` files into `Sources/<plugin>/include/`.
- For mixed plugins with only `*Plugin.{h,m}` ObjC wrapper files: converts them into a Swift wrapper and drops the ObjC files.
- For mixed plugins with additional ObjC sources: auto-splits the package into two SwiftPM targets (`<plugin>` Swift + `<plugin>_objc` ObjC).
- Generates a SwiftPM registration stub (`<PluginClass>.swift`) when the legacy ObjC wrapper is removed.
- Rewrites intra-plugin ObjC `#import "Foo.h"` lines to `#import "./include/<plugin>/Foo.h"`.
- Wraps external pod angle-imports in `__has_include` / `@import` fallbacks for SwiftPM builds.
- Injects `#if SWIFT_PACKAGE / import <plugin>_objc / #endif` into Swift files that reference symbols declared in the split ObjC target.
- Inserts missing framework imports (`Flutter`, `Foundation`, `UIKit`) into Swift files based on the types they actually use.
- Renders `Package.swift` with the correct targets, `resources` (`Assets`, `Resources`, `PrivacyInfo.xcprivacy`), `publicHeadersPath`, `cSettings.headerSearchPath`, exclude lists, and CocoaPods dependency TODOs.
- Adds a local `FlutterFramework` SwiftPM dependency at the package and target level when `pubspec.yaml` declares Flutter `>=3.41`.
- Annotates lines that look up a named CocoaPods `resource_bundle` (in both Swift and Objective-C sources) with a `TODO(spm-migration)` comment.
- Updates `Pigeon` output paths in `dart_options.dart` files to match the new SwiftPM layout.
- Updates the `.podspec` (`source_files`, `public_header_files`, `module_map`, paths in `resources` / `resource_bundles`, and the `PrivacyInfo.xcprivacy` reference) to keep CocoaPods builds working from the new layout.
- Adds `.gitignore` entries (`.build/`, `.swiftpm/`) inside the generated SwiftPM package directory.
- Cleans up empty legacy directories and leftover wrapper files.

## What the script does NOT do

The script **does not** look up Swift Package Manager equivalents for CocoaPods
dependencies, alternative bundle resolution APIs, or Swift translations of
additional Objective-C `@interface` declarations.

Instead, it surfaces these as `// TODO` comments in `Package.swift`, the
generated Swift wrapper, or the affected source files. You still need to:

- Replace `// TODO: CocoaPods dependencies found in .podspec ...` with real SwiftPM `.package(...)` / `.product(...)` entries.
- Resolve `// TODO(spm-migration): CocoaPods resource bundle name lookup detected ...` by switching to `Bundle.module` (Swift) or the equivalent SwiftPM module bundle accessor (Objective-C).
- Provide Swift equivalents (or keep ObjC bridging) for any `// TODO: additional interfaces were detected in ... .h` comments.
- Verify `defaultLocalization` and any `*.lproj` resource layout flagged by `// TODO(spm-migration): Localized resources ...`.
