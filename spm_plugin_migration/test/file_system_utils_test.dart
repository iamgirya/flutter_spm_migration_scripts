import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:spm_plugin_migration/spm_plugin_migration.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart';

bool _noopArc(String _, String __) => false;

void main() {
  group('FileSystemUtils', () {
    test('moveDirectory moves full tree recursively', () async {
      const caseDir = 'fs_utils/rec_move';
      await dir(caseDir, [
        dir('src', [
          dir('nested', [
            file('a.txt', 'A'),
          ]),
          file('b.txt', 'B'),
        ]),
      ]).create();

      final fs = FileSystemUtils(moveFile: _noopArc);
      final srcDir = Directory(path('$caseDir/src'));
      final dstDir = Directory(path('$caseDir/dst'));
      fs.moveDirectory(srcDir, dstDir);

      expect(
        File(path('$caseDir/dst/nested/a.txt')).readAsStringSync(),
        'A',
      );
      expect(File(path('$caseDir/dst/b.txt')).readAsStringSync(), 'B');
      expect(srcDir.existsSync(), false);
    });

    test('moveFile does not overwrite an existing destination (idempotent)',
        () async {
      const caseDir = 'fs_utils/idemp_file';
      await dir(caseDir, [
        file('src.txt', 'new'),
        dir('dest', [
          file('t.txt', 'old'),
        ]),
      ]).create();

      final fs = FileSystemUtils(moveFile: _noopArc);
      final src = File(path('$caseDir/src.txt'));
      final dst = File(path('$caseDir/dest/t.txt'));
      fs.moveFile(src, dst);

      expect(src.existsSync(), true);
      expect(dst.readAsStringSync(), 'old');
    });

    test('deleteDirIfEmpty removes empty dir but not non-empty', () async {
      const caseDir = 'fs_utils/del_empty';
      await dir(caseDir, [
        dir('empty', []),
        dir('full', [
          file('x.txt', '1'),
        ]),
      ]).create();

      final fs = FileSystemUtils(moveFile: _noopArc);
      fs.deleteDirIfEmpty(Directory(path('$caseDir/empty')));
      fs.deleteDirIfEmpty(Directory(path('$caseDir/full')));

      expect(Directory(path('$caseDir/empty')).existsSync(), false);
      expect(Directory(path('$caseDir/full')).existsSync(), true);
    });

    test('findFirstFileByName respects excludeDirs', () async {
      const caseDir = 'fs_utils/find_exclude';
      await dir(caseDir, [
        dir('good', [
          file('PrivacyInfo.xcprivacy', 'ok'),
        ]),
        dir('bad', [
          file('PrivacyInfo.xcprivacy', 'no'),
        ]),
      ]).create();

      final exclude = Directory(path('$caseDir/bad')).path;
      final found = findFirstFileByName(
        Directory(path(caseDir)),
        'PrivacyInfo.xcprivacy',
        excludeDirs: {exclude},
      );

      expect(found, isNotNull);
      expect(p.basename(found!.parent.path), 'good');
      expect(found.readAsStringSync(), 'ok');
    });

    test('posixRelativePath uses posix-normalized relative segments', () async {
      const caseDir = 'fs_utils/posix';
      await dir(caseDir, [
        dir('from', [
          dir('sub', [
            file('x.txt', 'x'),
          ]),
        ]),
      ]).create();

      final fs = FileSystemUtils(moveFile: _noopArc);
      final fromAbs =
          p.normalize(Directory(path('$caseDir/from')).absolute.path);
      final fileAbs =
          p.normalize(File(path('$caseDir/from/sub/x.txt')).absolute.path);

      expect(fs.posixRelativePath(fileAbs, from: fromAbs), 'sub/x.txt');
    });

    test(
      'moveDirectory falls back to merging when destination already exists',
      () async {
        const caseDir = 'fs_utils/merge_existing_dst';
        await dir(caseDir, [
          dir('src', [
            file('incoming.txt', 'in'),
          ]),
          dir('dst', [
            file('existing.txt', 'ex'),
          ]),
        ]).create();

        final fs = FileSystemUtils(moveFile: _noopArc);
        fs.moveDirectory(
          Directory(path('$caseDir/src')),
          Directory(path('$caseDir/dst')),
        );

        expect(
          File(path('$caseDir/dst/incoming.txt')).readAsStringSync(),
          'in',
        );
        expect(
          File(path('$caseDir/dst/existing.txt')).readAsStringSync(),
          'ex',
        );
        expect(Directory(path('$caseDir/src')).existsSync(), false);
      },
    );

    test(
      'moveFile falls back to copy+delete when renameSync fails',
      () async {
        const caseDir = 'fs_utils/rename_fallback';
        await dir(caseDir, [
          dir('a', [
            file('x.txt', 'content'),
          ]),
          dir('b', []),
        ]).create();

        final from = File(path('$caseDir/a/x.txt'));
        final to = File(path('$caseDir/b/x.txt'));

        final fs = FileSystemUtils(
          moveFile: _noopArc,
          renameSync: (src, newPath) {
            if (p.equals(src.path, from.path) && p.equals(newPath, to.path)) {
              throw const FileSystemException('forced rename failure');
            }
            src.renameSync(newPath);
          },
        );

        fs.moveFile(from, to);

        expect(from.existsSync(), false);
        expect(to.readAsStringSync(), 'content');
      },
    );
  });
}
