import 'dart:io';

import 'package:path/path.dart' as p;

typedef MoveFile = bool Function(String fromPath, String toPath);

typedef RenameSyncFn = void Function(File src, String newPath);

/// Low-level file system helpers used by the migration CLI.
class FileSystemUtils {
  FileSystemUtils({
    MoveFile? moveFile,
    void Function(String message)? onMultiplePodspecWarning,
    RenameSyncFn? renameSync,
  })  : _moveFile = moveFile ?? _defaultMoveFile,
        _renameSync = renameSync ?? _defaultRenameSync;

  final MoveFile _moveFile;
  final RenameSyncFn _renameSync;

  static void _defaultRenameSync(File src, String newPath) {
    src.renameSync(newPath);
  }

  static bool _defaultMoveFile(String fromPath, String toPath) {
    File(fromPath).renameSync(toPath);
    return true;
  }

  /// Lists all files under [dir] recursively.
  Iterable<File> listFilesRecursively(Directory dir) sync* {
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) {
        yield entity;
      }
    }
  }

  /// Normalizes a path to an absolute, platform-canonical form.
  String normalizePath(String path) => p.normalize(p.absolute(path.trim()));

  /// Ensures [dir] exists, creating it recursively when missing.
  void ensureDir(Directory dir) {
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
  }

  /// Moves direct children from [from] into [to].
  void moveDirChildren(Directory from, Directory to) {
    ensureDir(to);
    final entries = from.listSync(followLinks: false);
    for (final e in entries) {
      final name = p.basename(e.path);
      final destPath = p.join(to.path, name);
      if (e is Directory) {
        moveDirectory(e, Directory(destPath));
      } else if (e is File) {
        moveFile(e, File(destPath));
      }
    }
  }

  /// Moves directory [src] to [dst], falling back to recursive merge move.
  void moveDirectory(Directory src, Directory dst) {
    ensureDir(dst.parent);
    if (!dst.existsSync()) {
      try {
        if (_moveFile(src.path, dst.path)) {
          return;
        }
        src.renameSync(dst.path);
        return;
      } on Object catch (_) {
        // fall back to manual move
      }
    }
    ensureDir(dst);
    for (final entity in src.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      final nextDst = p.join(dst.path, name);
      if (entity is Directory) {
        moveDirectory(entity, Directory(nextDst));
      } else if (entity is File) {
        moveFile(entity, File(nextDst));
      }
    }
    deleteDirIfEmpty(src);
  }

  /// Moves file [src] to [dst] without overwriting existing destination files.
  void moveFile(File src, File dst) {
    ensureDir(dst.parent);
    if (p.equals(src.path, dst.path)) {
      return;
    }
    if (dst.existsSync()) {
      // Assume re-run; don't overwrite.
      return;
    }
    if (_moveFile(src.path, dst.path)) {
      return;
    }
    try {
      _renameSync(src, dst.path);
    } on Object catch (_) {
      src
        ..copySync(dst.path)
        ..deleteSync();
    }
  }

  /// Deletes [dir] only when it exists and is empty.
  void deleteDirIfEmpty(Directory dir) {
    if (!dir.existsSync()) {
      return;
    }
    final entries = dir.listSync(followLinks: false);
    if (entries.isEmpty) {
      dir.deleteSync();
    }
  }

  /// Deletes [dir] recursively when it exists.
  void removeDirIfExists(Directory dir) {
    if (!dir.existsSync()) {
      return;
    }
    dir.deleteSync(recursive: true);
  }

  /// Returns POSIX-style relative path from [from] to [path].
  String posixRelativePath(String path, {required String from}) {
    final rel = p.relative(path, from: from);
    return p.posix.normalize(rel.split(p.separator).join('/'));
  }

  bool isDirectoryEmpty(Directory dir) {
    return dir
        .listSync(followLinks: false)
        .where((e) => !(e is File && e.path.endsWith('.gitkeep')))
        .isEmpty;
  }
}

/// Finds first file named [filename] under [root], skipping [excludeDirs].
File? findFirstFileByName(
  Directory root,
  String filename, {
  Set<String> excludeDirs = const {},
}) {
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) {
      if (excludeDirs.contains(entity.path)) {
        // can't stop recursion with listSync; ignore children by name match later
      }
      continue;
    }
    if (entity is File && p.basename(entity.path) == filename) {
      final isExcluded = excludeDirs.any((d) => p.isWithin(d, entity.path));
      if (!isExcluded) {
        return entity;
      }
    }
  }
  return null;
}

/// Returns `true` when [filePath] belongs to ObjC/C/C++ file family.
bool isObjcOrCppFamilyPath(String filePath, {bool includeModuleMap = true}) {
  final lower = filePath.toLowerCase();
  if (includeModuleMap && lower.endsWith('.modulemap')) {
    return true;
  }
  return _objcOrCppFamilyExtensions.any(lower.endsWith);
}

const Set<String> _objcOrCppFamilyExtensions = {
  '.m',
  '.mm',
  '.h',
  '.hh',
  '.hpp',
  '.hxx',
  '.c',
  '.cc',
  '.cpp',
  '.cxx',
};
