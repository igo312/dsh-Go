// Where theme packs live: one normalized zip per pack,
// `<root>/<id>.dshTheme.zip`, holding `theme.json` and the preview it names.
//
// A file from outside is checked before anything is read from it: the central
// directory is walked for names, entry kinds, duplicate names, compression
// and declared sizes; only then are `theme.json` and its preview decoded, and
// their real sizes checked again. Installs write a temporary file in the same
// folder and rename it over the old one. This file stays free of Flutter:
// callers inject the root folder.

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'theme_pack.dart';

/// The largest `.dshTheme.zip` accepted.
const themePackMaxZipBytes = 8 * 1024 * 1024;

/// The largest `theme.json` accepted.
const themePackMaxThemeJsonBytes = 64 * 1024;

/// The largest preview PNG accepted.
const themePackMaxPreviewBytes = 2 * 1024 * 1024;

/// The most central-directory entries accepted.
const themePackMaxEntries = 16;

/// The largest total declared expansion accepted.
const themePackMaxExpandedBytes = 8 * 1024 * 1024;

/// The largest preview width or height accepted.
const themePackMaxPreviewSide = 4096;

/// The largest preview pixel count accepted.
const themePackMaxPreviewPixels = 4000000;

/// What an inspection found: the parsed pack, its preview and the parts that
/// parse but are not applied yet.
class ThemePackInspection {
  const ThemePackInspection({required this.pack, required this.previewPng, required this.notices});

  final ThemePack pack;
  final Uint8List? previewPng;
  final List<ThemePackNotice> notices;
}

/// One pack already in the library.
class ThemePackInstallation {
  const ThemePackInstallation({required this.pack, required this.previewPng});

  final ThemePack pack;
  final Uint8List? previewPng;
}

/// The theme packs kept under [root].
class ThemePackLibrary {
  ThemePackLibrary(this.root);

  /// Where `<id>.dshTheme.zip` files are kept.
  final Directory root;

  /// The tail of the queue: installs, listings and removals run one at a time.
  Future<void> _queue = Future.value();

  Future<T> _exclusive<T>(Future<T> Function() body) {
    final run = _queue.then((_) => body());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Validates a `.dshTheme.zip` without writing anything.
  Future<ThemePackInspection> inspect(Uint8List bytes, {String? sourceName}) async {
    if (bytes.length > themePackMaxZipBytes) {
      throw const ThemePackFormatException('tooLarge', field: 'zip', reason: 'the archive is larger than 8 MiB');
    }
    final entries = _readCentralDirectory(bytes, sourceName);
    if (entries.length > themePackMaxEntries) {
      throw const ThemePackFormatException('tooLarge', field: 'entries', reason: 'more than 16 entries');
    }

    final files = <String, _Entry>{};
    var expanded = 0;
    for (final entry in entries) {
      if (_isIgnoredName(entry.name)) continue;
      // Directory entries carry no data and are never extracted; they are
      // common in zips made by desktop tools and do not need to reject a pack.
      if (entry.isDirectory) continue;
      if (entry.isSymbolicLink) {
        throw ThemePackFormatException('badTheme', field: 'entries', reason: 'symbolic link: ${entry.name}');
      }
      _checkEntryName(entry.name);
      if (entry.isEncrypted) {
        throw ThemePackFormatException('badTheme', field: 'entries', reason: 'encrypted entry: ${entry.name}');
      }
      if (!entry.isSupportedCompression) {
        throw ThemePackFormatException('badTheme', field: 'entries', reason: 'unsupported compression: ${entry.name}');
      }
      if (files.containsKey(entry.name)) {
        throw ThemePackFormatException('badTheme', field: 'entries', reason: 'duplicate entry: ${entry.name}');
      }
      files[entry.name] = entry;
      expanded += entry.uncompressedSize;
      if (expanded > themePackMaxExpandedBytes) {
        throw const ThemePackFormatException(
          'tooLarge',
          field: 'entries',
          reason: 'declared expansion is larger than 8 MiB',
        );
      }
    }

    final themeEntry = files['theme.json'];
    if (themeEntry == null) {
      throw ThemePackFormatException(
        'noTheme',
        field: 'theme.json',
        reason: sourceName == null ? 'the archive has no theme.json' : '$sourceName has no theme.json',
      );
    }
    if (themeEntry.uncompressedSize > themePackMaxThemeJsonBytes) {
      throw const ThemePackFormatException('tooLarge', field: 'theme.json', reason: 'theme.json is larger than 64 KiB');
    }
    final themeBytes = _readEntry(themeEntry, 'theme.json', themePackMaxThemeJsonBytes);

    final ThemePackParseResult parsed;
    try {
      parsed = parseThemePackJson(themeBytes);
    } on ThemePackFormatException catch (error) {
      throw ThemePackFormatException('badTheme', field: error.field, reason: '${error.code}: ${error.reason ?? ''}');
    }

    Uint8List? preview;
    final previewPath = parsed.pack.previewPath;
    if (previewPath != null) {
      final previewEntry = files[previewPath];
      if (previewEntry == null) {
        throw const ThemePackFormatException(
          'badTheme',
          field: 'preview',
          reason: 'the named preview is not in the archive',
        );
      }
      if (previewEntry.uncompressedSize > themePackMaxPreviewBytes) {
        throw const ThemePackFormatException('tooLarge', field: 'preview', reason: 'the preview is larger than 2 MiB');
      }
      preview = _readEntry(previewEntry, 'preview', themePackMaxPreviewBytes);
      _checkPreviewPng(preview);
    }

    return ThemePackInspection(pack: parsed.pack, previewPng: preview, notices: parsed.notices);
  }

  /// Installs or replaces [inspection] under its id. The old file stays if
  /// writing the replacement fails.
  Future<({ThemePack pack, bool replaced})> install(ThemePackInspection inspection) => _exclusive(() async {
    final pack = inspection.pack;
    _checkId(pack.id);
    final preview = inspection.previewPng;
    if (pack.previewPath != null && preview == null) {
      throw const ThemePackFormatException(
        'badTheme',
        field: 'preview',
        reason: 'the pack names a preview but has none',
      );
    }

    final archive = Archive()..add(ArchiveFile.bytes('theme.json', encodeThemePackJson(pack)));
    if (pack.previewPath != null && preview != null) {
      archive.add(ArchiveFile.bytes(pack.previewPath!, preview));
    }
    final ZipEncoder encoder = ZipEncoder();
    final Uint8List data;
    try {
      data = Uint8List.fromList(encoder.encode(archive));
    } on Object catch (error) {
      throw ThemePackFormatException('storage', field: null, reason: 'could not build the archive: $error');
    }

    final target = File('${root.path}/${pack.id}.dshTheme.zip');
    final replaced = await target.exists();
    File? temporary;
    try {
      await root.create(recursive: true);
      temporary = File('${root.path}/.tmp-${pack.id}-${DateTime.now().microsecondsSinceEpoch}');
      final handle = await temporary.open(mode: FileMode.write);
      try {
        await handle.writeFrom(data);
        await handle.flush();
      } finally {
        await handle.close();
      }
      await temporary.rename(target.path);
      temporary = null;
    } on FileSystemException catch (error) {
      throw ThemePackFormatException('storage', field: null, reason: 'could not save ${pack.id}: ${error.message}');
    } finally {
      if (temporary != null) {
        try {
          await temporary.delete();
        } on FileSystemException {
          // The install already failed or the rename already moved it.
        }
      }
    }
    return (pack: pack, replaced: replaced);
  });

  /// Every valid pack in the library, ordered by id. Broken archives are
  /// skipped and left in place.
  Future<List<ThemePackInstallation>> list() => _exclusive(() async {
    final List<FileSystemEntity> entities;
    try {
      if (!await root.exists()) return const <ThemePackInstallation>[];
      entities = await root.list(followLinks: false).toList();
    } on FileSystemException catch (error) {
      throw ThemePackFormatException('storage', field: null, reason: 'could not list ${root.path}: ${error.message}');
    }

    final found = <ThemePackInstallation>[];
    for (final entity in entities) {
      if (entity is! File ||
          !entity.path.endsWith('.dshTheme.zip') ||
          entity.path.split('/').last.startsWith('.tmp-')) {
        continue;
      }
      try {
        if (await entity.length() > themePackMaxZipBytes) continue;
        final inspection = await inspect(await entity.readAsBytes(), sourceName: entity.path);
        found.add(ThemePackInstallation(pack: inspection.pack, previewPng: inspection.previewPng));
      } on ThemePackFormatException {
        // A broken file stays for its owner to replace or remove.
        continue;
      } on FileSystemException {
        continue;
      }
    }
    found.sort((a, b) => a.pack.id.compareTo(b.pack.id));
    return found;
  });

  /// Deletes only `<root>/<id>.dshTheme.zip`; an id that could escape the
  /// folder is refused.
  Future<void> remove(String id) => _exclusive(() async {
    _checkId(id);
    final file = File('${root.path}/$id.dshTheme.zip');
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      throw ThemePackFormatException('storage', field: null, reason: 'could not remove $id: ${error.message}');
    }
  });

  /// The central directory only: names, kinds, compression and declared
  /// sizes, without decompressing an entry.
  List<_Entry> _readCentralDirectory(Uint8List bytes, String? sourceName) {
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) {
      throw ThemePackFormatException(
        'notAZip',
        field: 'file',
        reason: sourceName == null ? 'not a zip archive' : '$sourceName is not a zip archive',
      );
    }
    final ZipDirectory directory;
    try {
      // Count headers with a streaming iterator first: a forged archive with
      // a huge central directory is rejected before the decoder allocates a
      // header object for every entry.
      var count = 0;
      for (final _ in ZipDirectory().headers(InputMemoryStream(bytes), verify: true, files: false)) {
        if (++count > themePackMaxEntries) {
          throw const ThemePackFormatException('tooLarge', field: 'entries', reason: 'more than 16 entries');
        }
      }
      directory = ZipDirectory()..read(InputMemoryStream(bytes), verify: true);
    } on ThemePackFormatException {
      rethrow;
    } on Object catch (error) {
      throw ThemePackFormatException(
        'notAZip',
        field: 'file',
        reason: sourceName == null ? 'not a zip archive: $error' : '$sourceName is not a zip archive: $error',
      );
    }
    if (directory.filePosition < 0) {
      throw ThemePackFormatException(
        'notAZip',
        field: 'file',
        reason: sourceName == null ? 'not a zip archive' : '$sourceName is not a zip archive',
      );
    }
    return [for (final header in directory.fileHeaders) _Entry(header)];
  }

  Uint8List _readEntry(_Entry entry, String field, int limit) {
    final Uint8List bytes;
    try {
      bytes = entry.header.file!.readBytes();
    } on Object catch (error) {
      throw ThemePackFormatException('badTheme', field: field, reason: 'could not read ${entry.name}: $error');
    }
    if (bytes.length > limit) {
      throw ThemePackFormatException(
        'tooLarge',
        field: field,
        reason: '${entry.name} is larger than ${limit ~/ 1024} KiB',
      );
    }
    return bytes;
  }

  void _checkPreviewPng(Uint8List bytes) {
    if (bytes.length < 33 ||
        bytes[0] != 0x89 ||
        bytes[1] != 0x50 ||
        bytes[2] != 0x4e ||
        bytes[3] != 0x47 ||
        bytes[4] != 0x0d ||
        bytes[5] != 0x0a ||
        bytes[6] != 0x1a ||
        bytes[7] != 0x0a) {
      throw const ThemePackFormatException('badTheme', field: 'preview', reason: 'the preview is not a PNG');
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(8) != 13 || String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') {
      throw const ThemePackFormatException('badTheme', field: 'preview', reason: 'the preview has no IHDR header');
    }
    final width = data.getUint32(16);
    final height = data.getUint32(20);
    if (width == 0 || height == 0) {
      throw const ThemePackFormatException('badTheme', field: 'preview', reason: 'the preview has no pixels');
    }
    if (width > themePackMaxPreviewSide ||
        height > themePackMaxPreviewSide ||
        width * height > themePackMaxPreviewPixels) {
      throw const ThemePackFormatException(
        'tooLarge',
        field: 'preview',
        reason: 'the preview is larger than 4096 px or 4M pixels',
      );
    }
  }

  void _checkEntryName(String name) {
    final unsafe =
        name.isEmpty ||
        name.contains('\x00') ||
        name.contains('\\') ||
        name.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(name) ||
        name.split('/').any((part) => part.isEmpty || part == '..');
    if (unsafe) {
      throw ThemePackFormatException('badTheme', field: 'entries', reason: 'unsafe entry name: $name');
    }
  }

  bool _isIgnoredName(String name) =>
      name == '.DS_Store' || name.endsWith('/.DS_Store') || name == '__MACOSX/' || name.startsWith('__MACOSX/');

  void _checkId(String id) {
    if (!RegExp(r'^[a-z][a-z0-9-]{1,47}$').hasMatch(id)) {
      throw const ThemePackFormatException('badTheme', field: 'id', reason: 'unsafe theme pack id');
    }
  }
}

/// The parts of a central-directory header this library judges.
class _Entry {
  _Entry(this.header);

  final ZipFileHeader header;

  String get name => header.filename;
  int get uncompressedSize => header.uncompressedSize;

  bool get isEncrypted => header.generalPurposeBitFlag & 0x41 != 0;

  bool get isSupportedCompression => header.compressionMethod == 0 || header.compressionMethod == 8;

  int get _unixMode => header.externalFileAttributes >> 16;

  bool get isSymbolicLink => header.versionMadeBy >> 8 == 3 && _unixMode & 0xf000 == 0xa000;

  bool get isDirectory =>
      name.endsWith('/') ||
      header.externalFileAttributes & 0x10 != 0 ||
      (header.versionMadeBy >> 8 == 3 && _unixMode & 0xf000 == 0x4000);
}
