# `podfile_dependencies_analyze.dart`

Read-only tool that **analyzes** the CocoaPods dependency graph from `Podfile.lock` and prints a report. It does not modify project files.

## Usage

```text
dart run podfile_dependencies_analyze.dart [-l <Podfile.lock>] [-s <.symlinks/plugins>]
```

- Defaults: `ios/Podfile.lock` for `--lock-file`, and `ios/.symlinks/plugins` derived from the lock file’s directory when `--plugins-dir` is omitted.
- If the plugin symlinks directory is missing (e.g. no `pod install` yet), stderr shows a warning; the report is still built from the lock file, but without SPM readiness markers for plugins.

## What it does

1. **Parses `Podfile.lock`**: `PODS` (pod hierarchy and dependencies) and `DEPENDENCIES` (direct app dependencies). Skips `Flutter` and `FlutterMacOS`.
2. **Builds a graph** of pods and finds **connected components** (isolated dependency islands).
3. **Scans Flutter plugins** under `.symlinks/plugins`: for each plugin folder, checks whether `ios` or `darwin` contains a nested directory with `Package.swift` (SwiftPM-ready plugin layout).
4. **Scans `Pods/`** next to `Podfile.lock`: finds `.xcframework` bundles and, via `Info.plist`, checks for an **iOS Simulator arm64** slice (`SupportedPlatform` / `SupportedPlatformVariant` / `SupportedArchitectures`). Pods missing that slice are tagged `[!! arm64-sim]`.
5. **Prints a report**: for non-trivial components, dependency trees rooted at `[APP]` entry points; for trivial single-pod components, grouped lists with the same SPM and arm64-sim markers.

## Purpose

Quickly see how pods cluster, which plugins already ship an SPM layout, and where binary xcframeworks may break Apple Silicon simulator builds.
