// Checks a `.dshTheme.zip` the way the library does, without installing it.
//
//   cd app && dart run tool/theme_pack_check.dart <file.dshTheme.zip>
//
// Exit codes: 0 pass (warnings included), 1 format/IO error, 2 usage error.
// Plain `key: value` lines, no JSON, no network and no files written.

import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/theme_packs/theme_pack.dart';
import 'package:dsh_app/theme_packs/theme_pack_library.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    _usage('expected exactly one .dshTheme.zip path');
    return;
  }
  final path = args.single;
  if (!path.endsWith('.dshTheme.zip')) {
    _usage('not a .dshTheme.zip file: $path');
    return;
  }
  final file = File(path);
  if (!await file.exists()) {
    _usage('file does not exist: $path');
    return;
  }

  final Uint8List bytes;
  try {
    if (await file.length() > themePackMaxZipBytes) {
      _failure(const ThemePackFormatException('tooLarge', field: 'zip', reason: 'the archive is larger than 8 MiB'));
      return;
    }
    bytes = await file.readAsBytes();
  } on FileSystemException catch (error) {
    _failure(ThemePackFormatException('storage', reason: 'could not read $path: ${error.message}'));
    return;
  }

  final ThemePackInspection inspection;
  try {
    inspection = await ThemePackLibrary(Directory.systemTemp).inspect(bytes, sourceName: path);
  } on ThemePackFormatException catch (error) {
    _failure(error);
    return;
  }

  final pack = inspection.pack;
  final parsedOnly = <String>[
    for (final notice in inspection.notices)
      switch (notice.code) {
        'highlight_not_applied' => 'highlight',
        'snow_not_applied' => 'snow',
        'whaleHat_not_applied' => 'whaleHat',
        'dates_not_applied' => 'dates',
        _ => notice.code,
      },
  ];

  stdout
    ..writeln('ok: true')
    ..writeln('id: ${pack.id}')
    ..writeln('name: ${pack.name.forLocale('zh')}')
    ..writeln('version: ${pack.version}')
    ..writeln('mode: ${pack.mode.name}')
    ..writeln('applied: accent, neutralTint, mode');
  if (parsedOnly.isNotEmpty) stdout.writeln('parsedOnly: ${parsedOnly.join(', ')}');
  for (final notice in inspection.notices) {
    stdout.writeln('warning: ${notice.code} ${notice.field}');
  }
}

void _failure(ThemePackFormatException error) {
  stderr
    ..writeln('ok: false')
    ..writeln('error: ${error.code}');
  if (error.field != null) stderr.writeln('field: ${error.field}');
  stderr.writeln('reason: ${error.reason ?? error.code}');
  exitCode = 1;
}

void _usage(String reason) {
  stderr
    ..writeln('usage: dart run tool/theme_pack_check.dart <file.dshTheme.zip>')
    ..writeln('reason: $reason');
  exitCode = 2;
}
