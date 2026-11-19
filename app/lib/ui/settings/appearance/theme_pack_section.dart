// 设置 › 主题 › 主题包: imported `.dshTheme.zip` packs, one row each (the
// preview, version and author, the chosen one said so), 导入主题, and removing
// one. Choosing a pack writes only `state/appearance_state.dart`; the palette
// and mode it brings are applied through the providers there.
//
// First version: a pack applies its accent, neutral tint and light/dark mode.
// Highlight, snow, whale hat and dates are parsed and mentioned when imported,
// but not drawn. A file is read into bytes first (8 MiB at most), then checked
// by `theme_packs/` before anything is stored.

import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/android_features.dart';
import '../../../state/appearance_state.dart';
import '../../../state/attachment_files_ohos.dart';
import '../../../theme_packs/theme_pack.dart';
import '../../../theme_packs/theme_pack_library.dart';
import '../../../state/theme_packs_state.dart';
import '../../bots/bot_sheets.dart' show confirmDelete;
import '../../common/app_dialog.dart';
import '../../theme/app_icons.dart';
import '../settings_widgets.dart';

/// What choosing a `.dshTheme.zip` brought back.
enum ThemePackPickStatus { picked, cancelled, tooLarge, unavailable }

class ThemePackPickResult {
  const ThemePackPickResult(this.status, [this.bytes])
    : assert(status == ThemePackPickStatus.picked ? bytes != null : bytes == null);

  ThemePackPickResult.picked(Uint8List bytes) : this(ThemePackPickStatus.picked, bytes);
  const ThemePackPickResult.cancelled() : this(ThemePackPickStatus.cancelled);
  const ThemePackPickResult.tooLarge() : this(ThemePackPickStatus.tooLarge);
  const ThemePackPickResult.unavailable() : this(ThemePackPickStatus.unavailable);

  final ThemePackPickStatus status;
  final Uint8List? bytes;
}

/// Chooses a theme pack file. Tests replace this with bytes of their own.
final themePackPickerProvider = Provider<Future<ThemePackPickResult> Function()>((ref) {
  return ref.watch(operatingSystemProvider) == 'ohos' ? _pickOhosThemePack : _pickPlatformThemePack;
});

/// Reads a picked file as bytes without ever holding more than the library
/// accepts. No temporary file: the bytes go straight to the inspector.
class _ThemePackTooLarge implements Exception {
  const _ThemePackTooLarge();
}

Future<Uint8List> _readThemePackStream(Stream<Uint8List> stream) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (chunk.length > themePackMaxZipBytes - bytes.length) throw const _ThemePackTooLarge();
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<ThemePackPickResult> _pickPlatformThemePack() async {
  final PlatformFile? picked;
  try {
    picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['zip']);
  } on MissingPluginException {
    return const ThemePackPickResult.unavailable();
  } on PlatformException {
    return const ThemePackPickResult.unavailable();
  }
  if (picked == null) return const ThemePackPickResult.cancelled();
  try {
    return ThemePackPickResult.picked(await _readThemePackStream(picked.readAsByteStream()));
  } on _ThemePackTooLarge {
    return const ThemePackPickResult.tooLarge();
  } on Object {
    return const ThemePackPickResult.unavailable();
  }
}

Future<ThemePackPickResult> _pickOhosThemePack() async {
  try {
    return await const OhosAttachmentFiles().consume<ThemePackPickResult>(
      limit: 1,
      maxFileBytes: themePackMaxZipBytes,
      maxTotalBytes: themePackMaxZipBytes,
      maxImageBytes: 0,
      allowEmpty: true,
      use: (entries) async {
        if (entries.isEmpty) return const ThemePackPickResult.cancelled();
        final entry = entries.first;
        if (entry.problem != null) {
          return entry.problem == 'file_too_large' || entry.problem == 'total_too_large'
              ? const ThemePackPickResult.tooLarge()
              : const ThemePackPickResult.unavailable();
        }
        try {
          return ThemePackPickResult.picked(await _readThemePackStream(entry.readAsByteStream()));
        } on _ThemePackTooLarge {
          return const ThemePackPickResult.tooLarge();
        } on Object {
          return const ThemePackPickResult.unavailable();
        }
      },
    );
  } on Object {
    return const ThemePackPickResult.unavailable();
  }
}

/// 主题包: imported packs, the chosen one marked, 导入主题 and delete.
class ThemePackSection extends ConsumerStatefulWidget {
  const ThemePackSection({super.key});

  @override
  ConsumerState<ThemePackSection> createState() => _ThemePackSectionState();
}

class _ThemePackSectionState extends ConsumerState<ThemePackSection> {
  bool _busy = false;

  Future<void> _apply(ThemePack pack) => ref.read(appearanceProvider.notifier).selectThemePack(pack);

  Future<void> _import() async {
    if (_busy) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    try {
      final picked = await ref.read(themePackPickerProvider)();
      switch (picked.status) {
        case ThemePackPickStatus.cancelled:
          return;
        case ThemePackPickStatus.tooLarge:
          messenger?.showSnackBar(SnackBar(content: Text(l10n.themePackImportTooLarge)));
          return;
        case ThemePackPickStatus.unavailable:
          messenger?.showSnackBar(SnackBar(content: Text(l10n.themePackImportUnavailable)));
          return;
        case ThemePackPickStatus.picked:
          break;
      }
      final bytes = picked.bytes;
      if (bytes == null) return;

      final library = await ref.read(themePackLibraryProvider.future);
      final inspection = await library.inspect(bytes);
      if (!mounted) return;

      if (inspection.notices.isNotEmpty) {
        if (!await _confirmNotices(inspection.notices) || !mounted) return;
      }

      final installed = await ref.read(installedThemePacksProvider.future);
      if (!mounted) return;
      if (installed.any((installation) => installation.pack.id == inspection.pack.id)) {
        if (!await _confirmReplace(inspection.pack) || !mounted) return;
      }

      final result = await ref.read(installedThemePacksProvider.notifier).install(inspection);
      await ref.read(appearanceProvider.notifier).selectThemePack(result.pack);
      if (!mounted) return;
      final name = result.pack.name.forLocale(Localizations.localeOf(context).languageCode);
      messenger?.showSnackBar(
        SnackBar(content: Text(result.replaced ? l10n.themePackReplaced(name) : l10n.themePackImported(name))),
      );
    } on ThemePackFormatException catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text(_importErrorText(l10n, error))));
    } on Object {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.themePackImportUnavailable)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmNotices(List<ThemePackNotice> notices) async {
    final l10n = context.l10n;
    final items = notices
        .map((notice) => _noticeText(l10n, notice.code))
        .join(Localizations.localeOf(context).languageCode == 'en' ? ', ' : '、');
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.themePackNoticesTitle),
        content: SingleChildScrollView(child: Text(l10n.themePackNoticesBody(items))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.themePackNoticesConfirm)),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<bool> _confirmReplace(ThemePack pack) async {
    final l10n = context.l10n;
    final name = pack.name.forLocale(Localizations.localeOf(context).languageCode);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.themePackReplaceTitle),
        content: Text(l10n.themePackReplaceBody(name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.commonConfirm)),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _remove(ThemePackInstallation installation) async {
    if (_busy) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final name = installation.pack.name.forLocale(Localizations.localeOf(context).languageCode);
    final ok = await confirmDelete(context, title: l10n.themePackRemoveTitle, body: l10n.themePackRemoveBody(name));
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(installedThemePacksProvider.notifier).remove(installation.pack.id);
      if (!mounted) return;
      if (ref.read(appearanceProvider).themePackId == installation.pack.id) {
        await ref.read(appearanceProvider.notifier).clearThemePack();
        if (!mounted) return;
      }
      messenger?.showSnackBar(SnackBar(content: Text(l10n.themePackRemoved(name))));
    } on Object {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.themePackRemoveFailed(name))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final installed = ref.watch(installedThemePacksProvider);
    final appearance = ref.watch(appearanceProvider);
    final active = ref.watch(activeThemePackProvider);
    final language = Localizations.localeOf(context).languageCode;
    final packs = installed.value ?? const <ThemePackInstallation>[];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 2,
      children: [
        if (installed.hasError)
          SettingsTile(
            key: const ValueKey('theme-pack-list-failed'),
            icon: AppIcons.warning,
            tinted: false,
            title: l10n.themePackListFailed,
            onTap: () => unawaited(ref.read(installedThemePacksProvider.notifier).reload()),
          )
        else if (installed.hasValue) ...[
          for (final installation in packs)
            _installationRow(
              installation,
              language: language,
              selected: appearance.themePackId == installation.pack.id,
              active: active?.pack.id == installation.pack.id,
            ),
          if (appearance.themePackId != null && packs.every((i) => i.pack.id != appearance.themePackId))
            SettingsTile(
              key: const ValueKey('theme-pack-missing'),
              icon: AppIcons.warning,
              tinted: false,
              title: l10n.themePackMissing,
              onTap: () => unawaited(ref.read(appearanceProvider.notifier).clearThemePack()),
            ),
        ],
        SettingsTile(
          key: const ValueKey('theme-pack-import'),
          icon: AppIcons.add,
          tinted: false,
          title: l10n.themePackImport,
          subtitle: l10n.themePackImportHint,
          trailing: _busy
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : null,
          onTap: _busy ? null : () => unawaited(_import()),
        ),
      ],
    );
  }

  Widget _installationRow(
    ThemePackInstallation installation, {
    required String language,
    required bool selected,
    required bool active,
  }) {
    final l10n = context.l10n;
    final pack = installation.pack;
    final name = pack.name.forLocale(language);
    final author = pack.author;
    final subtitle = author == null || author.isEmpty ? pack.version : '${pack.version} · $author';
    final preview = installation.previewPng;
    final previewWidth = (28 * MediaQuery.devicePixelRatioOf(context)).round();
    return SettingsTile(
      key: ValueKey('theme-pack-${pack.id}'),
      icon: AppIcons.theme,
      tinted: false,
      title: name,
      subtitle: subtitle,
      value: selected ? Text(active ? l10n.themePackActive : l10n.themePackUnavailable) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (preview != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(
                preview,
                width: 28,
                height: 42,
                cacheWidth: previewWidth,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, error, stack) => SizedBox(
                  width: 28,
                  height: 42,
                  child: Icon(AppIcons.gallery, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          IconButton(
            key: ValueKey('theme-pack-delete-${pack.id}'),
            tooltip: l10n.commonDelete,
            onPressed: _busy ? null : () => unawaited(_remove(installation)),
            icon: const Icon(AppIcons.delete),
            iconSize: SettingsMetrics.lineGlyph,
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
      onTap: _busy ? null : () => unawaited(_apply(pack)),
    );
  }
}

String _noticeText(L10n l10n, String code) => switch (code) {
  'highlight_not_applied' => l10n.themePackNoticeHighlight,
  'snow_not_applied' => l10n.themePackNoticeSnow,
  'whaleHat_not_applied' => l10n.themePackNoticeWhaleHat,
  'dates_not_applied' => l10n.themePackNoticeDates,
  _ => code,
};

String _importErrorText(L10n l10n, ThemePackFormatException error) => switch (error.code) {
  'notAZip' => l10n.themePackImportNotZip,
  'noTheme' => l10n.themePackImportNoTheme,
  'badTheme' => l10n.themePackImportBadTheme(error.reason ?? error.field ?? ''),
  'tooLarge' => l10n.themePackImportTooLarge,
  'storage' => l10n.themePackImportStorage,
  _ => l10n.themePackImportUnavailable,
};
