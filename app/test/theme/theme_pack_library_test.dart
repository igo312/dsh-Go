import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_app/theme_packs/theme_pack.dart';
import 'package:dsh_app/theme_packs/theme_pack_library.dart';
import 'package:flutter_test/flutter_test.dart';

const _signature = [137, 80, 78, 71, 13, 10, 26, 10];

Map<String, Object?> packJson({
  String id = 'christmas',
  String version = '1.0.0',
  bool withPreview = true,
  bool withExtras = false,
}) => {
  'schema': 1,
  'id': id,
  'name': {'zh': '圣诞限定', 'en': 'Christmas'},
  'version': version,
  'author': 'dsh-Go',
  'mode': 'system',
  'colors': {'accent': '#B4232C', 'neutralTint': '#14503C', 'highlight': '#C9973F'},
  'decorations': {'snow': true, 'whaleHat': true},
  'dates': {'from': '12-01', 'to': '12-26'},
  if (withPreview) 'preview': withExtras ? 'assets/preview.png' : 'preview.png',
};

List<int> jsonBytes(Map<String, Object?> json) => utf8.encode(jsonEncode(json));

/// A PNG header that satisfies the library's signature + IHDR check.
List<int> png(int width, int height, {int extra = 0}) {
  final bytes = Uint8List(45 + extra);
  bytes.setAll(0, _signature);
  final data = ByteData.sublistView(bytes);
  data.setUint32(8, 13); // IHDR length
  bytes.setAll(12, ascii.encode('IHDR'));
  data.setUint32(16, width);
  data.setUint32(20, height);
  bytes[24] = 8; // bit depth
  bytes[25] = 6; // RGBA
  data.setUint32(33, 0); // empty IEND chunk
  bytes.setAll(37, ascii.encode('IEND'));
  return bytes;
}

List<int> zipBytes(
  Map<String, List<int>> files, {
  CompressionType compression = CompressionType.deflate,
  String? password,
}) {
  final archive = Archive();
  files.forEach((name, bytes) {
    final file = ArchiveFile.bytes(name, bytes);
    if (compression != CompressionType.deflate) file.compression = compression;
    archive.add(file);
  });
  return ZipEncoder(password: password).encode(archive);
}

List<int> christmasZip({
  String version = '1.0.0',
  bool withExtras = false,
  int previewWidth = 64,
  int previewHeight = 64,
}) => zipBytes({
  'theme.json': jsonBytes(packJson(version: version, withExtras: withExtras)),
  (withExtras ? 'assets/preview.png' : 'preview.png'): png(previewWidth, previewHeight),
});

void main() {
  late Directory temp;
  late Directory root;
  late ThemePackLibrary library;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('theme-pack-library');
    root = Directory('${temp.path}/themes');
    library = ThemePackLibrary(root);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<ThemePackFormatException> problem(Future<Object?> Function() body) async {
    try {
      await body();
    } on ThemePackFormatException catch (error) {
      return error;
    }
    fail('expected ThemePackFormatException');
  }

  group('inspect', () {
    test('reads a valid zip without writing anything', () async {
      final inspection = await library.inspect(Uint8List.fromList(christmasZip()));

      expect(inspection.pack.id, 'christmas');
      expect(inspection.pack.name.zh, '圣诞限定');
      expect(inspection.pack.accent, 0xB4232C);
      expect(inspection.previewPng, isNotNull);
      expect(inspection.notices, hasLength(4));
      expect(await root.exists(), isFalse);
    });

    test('ignores macOS metadata entries', () async {
      final bytes = zipBytes({
        '__MACOSX/': [],
        '__MACOSX/._theme.json': utf8.encode('junk'),
        '.DS_Store': utf8.encode('junk'),
        'theme.json': jsonBytes(packJson()),
        'preview.png': png(8, 8),
        'nested/.DS_Store': utf8.encode('junk'),
      });
      final inspection = await library.inspect(Uint8List.fromList(bytes));
      expect(inspection.pack.id, 'christmas');
    });

    test('requires a zip and a root theme.json', () async {
      final notZip = await problem(() => library.inspect(Uint8List.fromList([1, 2, 3, 4])));
      expect(notZip.code, 'notAZip');
      expect(notZip.field, 'file');

      final noTheme = await problem(() => library.inspect(Uint8List.fromList(zipBytes({'preview.png': png(4, 4)}))));
      expect(noTheme.code, 'noTheme');
      expect(noTheme.field, 'theme.json');

      final empty = await problem(() => library.inspect(Uint8List.fromList(zipBytes({}))));
      expect(empty.code, 'noTheme');
    });

    test('normalizes model errors to badTheme and keeps the field', () async {
      final invalidJson = {...packJson(), 'mode': 'auto'};
      final error = await problem(
        () => library.inspect(
          Uint8List.fromList(zipBytes({'theme.json': jsonBytes(invalidJson), 'preview.png': png(4, 4)})),
        ),
      );
      expect(error.code, 'badTheme');
      expect(error.field, 'mode');
      expect(error.reason, contains('invalidMode'));
    });

    test('rejects an oversized archive before decoding', () async {
      final bytes = Uint8List(themePackMaxZipBytes + 1);
      final error = await problem(() => library.inspect(bytes));
      expect(error.code, 'tooLarge');
      expect(error.field, 'zip');
    });

    test('rejects more than 16 entries', () async {
      final files = <String, List<int>>{'theme.json': jsonBytes(packJson(withPreview: false))};
      for (var i = 0; i < 16; i++) {
        files['extra-$i.txt'] = utf8.encode('x');
      }
      final error = await problem(() => library.inspect(Uint8List.fromList(zipBytes(files))));
      expect(error.code, 'tooLarge');
      expect(error.field, 'entries');
    });

    test('rejects a theme.json over 64 KiB', () async {
      final error = await problem(
        () => library.inspect(Uint8List.fromList(zipBytes({'theme.json': Uint8List(themePackMaxThemeJsonBytes + 1)}))),
      );
      expect(error.code, 'tooLarge');
      expect(error.field, 'theme.json');
    });

    test('rejects a declared expansion over 8 MiB', () async {
      final bytes = zipBytes({
        'theme.json': jsonBytes(packJson(withPreview: false)),
        'big.bin': Uint8List(themePackMaxExpandedBytes + 1),
      });
      expect(bytes.length, lessThan(themePackMaxZipBytes));
      final error = await problem(() => library.inspect(Uint8List.fromList(bytes)));
      expect(error.code, 'tooLarge');
      expect(error.field, 'entries');
    });

    test('rejects unsafe entry names', () async {
      for (final name in ['../escape.txt', '/absolute.txt', 'C:/windows.txt', 'a/../../b.txt']) {
        final bytes = zipBytes({'theme.json': jsonBytes(packJson(withPreview: false)), name: utf8.encode('x')});
        final error = await problem(() => library.inspect(Uint8List.fromList(bytes)));
        expect(error.code, 'badTheme', reason: name);
        expect(error.field, 'entries');
      }
    });

    test('rejects duplicate names', () async {
      // Archive.add() replaces a same-named file, so overwrite the second
      // entry's name after adding it to keep both central-directory records.
      final archive = Archive()
        ..add(ArchiveFile.bytes('theme.json', jsonBytes(packJson(withPreview: false))))
        ..add(ArchiveFile.bytes('other.txt', utf8.encode('x')));
      archive.modifyAtIndex(1, ArchiveFile.bytes('theme.json', jsonBytes(packJson(withPreview: false))));
      final error = await problem(() => library.inspect(Uint8List.fromList(ZipEncoder().encode(archive))));
      expect(error.code, 'badTheme');
      expect(error.reason, contains('duplicate'));
    });

    test('ignores directory entries but rejects symbolic links', () async {
      final directory = Archive()
        ..add(ArchiveFile.bytes('theme.json', jsonBytes(packJson(withExtras: true))))
        ..add(ArchiveFile.directory('assets/'))
        ..add(ArchiveFile.bytes('assets/preview.png', png(64, 64)));
      final accepted = await library.inspect(Uint8List.fromList(ZipEncoder().encode(directory)));
      expect(accepted.pack.previewPath, 'assets/preview.png');
      expect(accepted.previewPng, isNotNull);

      final link = Archive()
        ..add(ArchiveFile.bytes('theme.json', jsonBytes(packJson(withPreview: false))))
        ..add(ArchiveFile.symlink('link', 'theme.json'));
      final linkError = await problem(() => library.inspect(Uint8List.fromList(ZipEncoder().encode(link))));
      expect(linkError.code, 'badTheme');
      expect(linkError.reason, contains('symbolic link'));
    });

    test('rejects encrypted entries', () async {
      final bytes = zipBytes({'theme.json': jsonBytes(packJson(withPreview: false))}, password: 'secret');
      final error = await problem(() => library.inspect(Uint8List.fromList(bytes)));
      expect(error.code, 'badTheme');
      expect(error.reason, contains('encrypted'));
    });

    test('rejects an unsupported compression method', () async {
      final bytes = zipBytes({
        'theme.json': jsonBytes(packJson(withPreview: false)),
      }, compression: CompressionType.bzip2);
      final error = await problem(() => library.inspect(Uint8List.fromList(bytes)));
      expect(error.code, 'badTheme');
      expect(error.reason, contains('unsupported compression'));
    });

    test('a declared preview must be present and a PNG', () async {
      final missing = await problem(
        () => library.inspect(Uint8List.fromList(zipBytes({'theme.json': jsonBytes(packJson())}))),
      );
      expect(missing.code, 'badTheme');
      expect(missing.field, 'preview');
      expect(missing.reason, contains('not in the archive'));

      final corrupt = await problem(
        () => library.inspect(
          Uint8List.fromList(
            zipBytes({
              'theme.json': jsonBytes(packJson()),
              'preview.png': [1, 2, 3],
            }),
          ),
        ),
      );
      expect(corrupt.code, 'badTheme');
      expect(corrupt.field, 'preview');
      expect(corrupt.reason, contains('not a PNG'));
    });

    test('caps preview bytes and pixels', () async {
      final tooManyBytes = await problem(
        () => library.inspect(
          Uint8List.fromList(
            zipBytes({'theme.json': jsonBytes(packJson()), 'preview.png': Uint8List(themePackMaxPreviewBytes + 1)}),
          ),
        ),
      );
      expect(tooManyBytes.code, 'tooLarge');
      expect(tooManyBytes.field, 'preview');

      final tooManyPixels = await problem(
        () => library.inspect(Uint8List.fromList(christmasZip(previewWidth: 3000, previewHeight: 2000))),
      );
      expect(tooManyPixels.code, 'tooLarge');
      expect(tooManyPixels.field, 'preview');

      final tooWide = await problem(
        () => library.inspect(Uint8List.fromList(christmasZip(previewWidth: 4097, previewHeight: 1))),
      );
      expect(tooWide.code, 'tooLarge');
    });
  });

  group('install, list and remove', () {
    test('installs a normalized archive with only theme.json and its preview', () async {
      final preview = png(64, 64);
      final bytes = zipBytes({
        'theme.json': jsonBytes(packJson(withExtras: true)),
        'assets/preview.png': preview,
        'notes.txt': utf8.encode('not stored'),
        'assets/other.bin': utf8.encode('not stored'),
      });
      final inspection = await library.inspect(Uint8List.fromList(bytes));
      final result = await library.install(inspection);

      expect(result.replaced, isFalse);
      expect(result.pack.id, 'christmas');
      final target = File('${root.path}/christmas.dshTheme.zip');
      expect(await target.exists(), isTrue);

      final stored = ZipDecoder().decodeBytes(await target.readAsBytes());
      expect({for (final file in stored) file.name}, {'theme.json', 'assets/preview.png'});
      final storedJson = parseThemePackJson(stored.findFile('theme.json')!.content);
      expect(storedJson.pack.id, 'christmas');
      expect(stored.findFile('assets/preview.png')!.content, preview);
    });

    test('replaces the same id and reports it', () async {
      await library.install(await library.inspect(Uint8List.fromList(christmasZip())));
      final second = await library.install(await library.inspect(Uint8List.fromList(christmasZip(version: '1.1.0'))));
      expect(second.replaced, isTrue);

      final listed = await library.list();
      expect(listed, hasLength(1));
      expect(listed.single.pack.version, '1.1.0');
    });

    test('lists installed packs by id with their previews', () async {
      await library.install(await library.inspect(Uint8List.fromList(christmasZip())));
      await library.install(
        await library.inspect(
          Uint8List.fromList(zipBytes({'theme.json': jsonBytes(packJson(id: 'alpha', withPreview: false))})),
        ),
      );

      final listed = await library.list();
      expect([for (final installation in listed) installation.pack.id], ['alpha', 'christmas']);
      expect(listed.last.previewPng, isNotNull);
      expect(listed.first.previewPng, isNull);
      expect(listed.last.pack.name.zh, '圣诞限定');
    });

    test('skips broken archives without deleting them', () async {
      await library.install(await library.inspect(Uint8List.fromList(christmasZip())));
      final broken = File('${root.path}/broken.dshTheme.zip')..writeAsBytesSync([1, 2, 3]);

      final listed = await library.list();
      expect(listed.map((installation) => installation.pack.id), ['christmas']);
      expect(await broken.exists(), isTrue);
    });

    test('ignores a leftover install temp file', () async {
      root.createSync(recursive: true);
      File('${root.path}/.tmp-christmas-123').writeAsBytesSync(christmasZip());
      expect(await library.list(), isEmpty);
    });

    test('removes only the archive for the id', () async {
      await library.install(await library.inspect(Uint8List.fromList(christmasZip())));
      final kept = File('${root.path}/notes.txt')..writeAsStringSync('keep me');

      await library.remove('christmas');
      expect(await File('${root.path}/christmas.dshTheme.zip').exists(), isFalse);
      expect(await kept.exists(), isTrue);
      expect(await library.list(), isEmpty);

      await library.remove('christmas');
    });

    test('refuses ids that could leave the root', () async {
      final outside = File('${temp.path}/escape.dshTheme.zip')..writeAsStringSync('untouched');
      for (final id in ['../escape', '..', 'A', 'a/b']) {
        final error = await problem(() => library.remove(id));
        expect(error.code, 'badTheme', reason: id);
      }
      expect(await outside.exists(), isTrue);
      expect(await outside.readAsString(), 'untouched');
    });

    test('leaves no files outside the themes root', () async {
      await library.install(await library.inspect(Uint8List.fromList(christmasZip())));

      final files = await temp.list(recursive: true).where((entity) => entity is File).cast<File>().toList();
      expect(files, isNotEmpty);
      for (final file in files) {
        expect(file.path, startsWith('${root.path}/'));
        expect(file.path, isNot(contains('.tmp-')));
      }
      expect(await root.list().map((entity) => entity.path.split('/').last).toList(), ['christmas.dshTheme.zip']);
    });

    test('turns storage failures into the storage code', () async {
      final blocked = File('${temp.path}/blocked')..writeAsStringSync('not a directory');
      final inspection = await library.inspect(Uint8List.fromList(christmasZip()));
      final error = await problem(() => ThemePackLibrary(Directory(blocked.path)).install(inspection));
      expect(error.code, 'storage');
    });

    test('serializes installs so concurrent ones do not interleave', () async {
      final first = library.install(await library.inspect(Uint8List.fromList(christmasZip(version: '1.0.0'))));
      final second = library.install(await library.inspect(Uint8List.fromList(christmasZip(version: '2.0.0'))));
      await Future.wait([first, second]);

      final listed = await library.list();
      expect(listed, hasLength(1));
      expect(listed.single.pack.version, '2.0.0');
    });
  });
}
