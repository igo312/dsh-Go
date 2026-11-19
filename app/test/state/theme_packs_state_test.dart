// The theme packs installed on the phone and the appearance state that
// chooses one: installing, applying its accent / neutral tint / mode, the
// preset and custom picks clearing it, a pack file going missing, and a
// listing that cannot be read surfacing as an error rather than an empty
// library. The real library is pointed at a temp folder here.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/theme_packs/theme_pack.dart';
import 'package:dsh_app/theme_packs/theme_pack_library.dart';
import 'package:dsh_app/state/theme_packs_state.dart';
import 'package:dsh_app/ui/theme/accent.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter/material.dart' show Color, ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui_config/support.dart' show FakeUiSource, until;

const _packId = 'christmas';
const _packAccent = Color(0xFFB4232C);
const _packTint = Color(0xFF14503C);
const _themePackKey = 'appearance.theme_pack';
const _themePackModeKey = 'appearance.theme_pack_mode';

/// A valid schema-1 pack, without a preview.
List<int> _packZip({String mode = 'dark'}) {
  final archive = Archive()
    ..add(
      ArchiveFile.bytes(
        'theme.json',
        utf8.encode(
          jsonEncode({
            'schema': 1,
            'id': _packId,
            'name': {'zh': '圣诞限定', 'en': 'Christmas'},
            'version': '1.0.0',
            'mode': mode,
            'colors': {'accent': '#B4232C', 'neutralTint': '#14503C'},
          }),
        ),
      ),
    );
  return ZipEncoder().encode(archive);
}

/// A library whose listing always fails like an unreadable folder would.
class _FailingLibrary extends ThemePackLibrary {
  _FailingLibrary(super.root);

  @override
  Future<List<ThemePackInstallation>> list() async =>
      throw const ThemePackFormatException('storage', field: null, reason: 'unreadable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late Directory temp;
  late Directory root;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('theme-packs-state');
    root = Directory('${temp.path}/themes');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  ProviderContainer container({UiConfigSource? uiSource}) {
    final c = ProviderContainer(
      overrides: [
        themePackRootProvider.overrideWithValue(() async => root),
        uiConfigSourceBuilderProvider.overrideWithValue((ref, host) => uiSource),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> appearanceLoaded(ProviderContainer c) async {
    c.read(appearanceProvider);
    await until(() => c.read(appearanceProvider).loaded);
  }

  Future<ThemePackInstallation> install(ProviderContainer c) async {
    final library = await c.read(themePackLibraryProvider.future);
    final inspection = await library.inspect(Uint8List.fromList(_packZip()));
    await c.read(installedThemePacksProvider.notifier).install(inspection);
    final installed = await c.read(installedThemePacksProvider.future);
    return installed.single;
  }

  AppAccent expectedAccent() =>
      AppAccent.derive(_packAccent, neutralTint: _packTint, id: 'theme-$_packId', label: '圣诞限定');

  test('installs a pack; selecting it applies accent, neutral tint and mode; a cold start keeps it', () async {
    final c = container();
    await appearanceLoaded(c);

    final installed = await install(c);
    expect(installed.pack.id, _packId);
    expect(installed.pack.accent, 0xB4232C);
    expect(installed.pack.neutralTint, 0x14503C);

    await c.read(appearanceProvider.notifier).selectThemePack(installed.pack);
    expect(c.read(appearanceProvider).themePackId, _packId);
    expect(c.read(appearanceProvider).themePackMode, ThemeMode.dark);
    await until(() => c.read(activeThemePackProvider) != null);
    expect(c.read(activeThemePackProvider)!.pack.id, _packId);

    final accent = c.read(accentProvider);
    final expected = expectedAccent();
    expect(accent, expected);
    expect(accent.id, 'theme-$_packId');
    expect(accent.seed, expected.seed);
    expect(
      accent.tintHue,
      isNot(closeTo(AppAccent.derive(_packAccent, id: 'plain').tintHue, 1)),
      reason: 'the neutralTint moves the neutrals hue',
    );
    expect(c.read(uiThemeModeProvider).value, ThemeMode.dark);

    // Cold start: the same preferences, a new container, the same folder.
    final prefs = await SharedPreferences.getInstance();
    final stored = <String, Object>{};
    for (final key in [_themePackKey, _themePackModeKey]) {
      final value = prefs.getString(key);
      if (value != null) stored[key] = value;
    }
    expect(stored, {_themePackKey: _packId, _themePackModeKey: 'dark'});
    SharedPreferences.setMockInitialValues(stored);

    final restarted = container();
    await appearanceLoaded(restarted);
    expect(restarted.read(appearanceProvider).themePackId, _packId);
    expect(restarted.read(appearanceProvider).themePackMode, ThemeMode.dark);
    await until(() => restarted.read(activeThemePackProvider) != null);
    expect(restarted.read(accentProvider), expected);
  });

  test('a preset, custom or wallpaper choice clears the pack and its preferences', () async {
    final c = container();
    await appearanceLoaded(c);
    final installed = await install(c);
    final controller = c.read(appearanceProvider.notifier);
    final prefs = await SharedPreferences.getInstance();

    for (final change in <Future<void> Function()>[
      () => controller.selectPreset('amber'),
      () => controller.selectCustom(),
      () => controller.selectWallpaper(),
    ]) {
      await controller.selectThemePack(installed.pack);
      expect(c.read(appearanceProvider).themePackId, _packId);
      expect(prefs.getString(_themePackKey), _packId);
      expect(prefs.getString(_themePackModeKey), 'dark');

      await change();
      expect(c.read(appearanceProvider).themePackId, isNull);
      expect(c.read(appearanceProvider).themePackMode, isNull);
      expect(c.read(activeThemePackProvider), isNull);
      expect(prefs.getString(_themePackKey), isNull);
      expect(prefs.getString(_themePackModeKey), isNull);
    }
  });

  test('removing the chosen pack falls back to the base palette and the settings mode', () async {
    final c = container();
    await appearanceLoaded(c);
    c.read(settingsProvider);
    await until(() => c.read(settingsProvider).loaded);
    await c.read(settingsProvider.notifier).setThemeMode(ThemeMode.light);

    final installed = await install(c);
    await c.read(appearanceProvider.notifier).selectThemePack(installed.pack);
    await until(() => c.read(activeThemePackProvider) != null);
    expect(c.read(uiThemeModeProvider).value, ThemeMode.dark);

    await c.read(installedThemePacksProvider.notifier).remove(_packId);
    expect(await c.read(installedThemePacksProvider.future), isEmpty);
    expect(c.read(activeThemePackProvider), isNull);
    expect(c.read(accentProvider), AppAccent.mist);
    expect(c.read(uiThemeModeProvider).value, ThemeMode.light);
    expect(c.read(appearanceProvider).themePackId, _packId, reason: 'the choice stays stored');
  });

  test('a pack whose file is gone no longer applies, and its mode stops overriding', () async {
    final c = container();
    await appearanceLoaded(c);
    final installed = await install(c);
    await c.read(appearanceProvider.notifier).selectThemePack(installed.pack);
    await until(() => c.read(activeThemePackProvider) != null);

    File('${root.path}/$_packId.dshTheme.zip').deleteSync();
    await c.read(installedThemePacksProvider.notifier).reload();
    expect(await c.read(installedThemePacksProvider.future), isEmpty);

    expect(c.read(activeThemePackProvider), isNull);
    expect(c.read(accentProvider), AppAccent.mist);
    expect(c.read(appearanceProvider).themePackId, _packId, reason: 'kept for when the pack is back');
    expect(c.read(uiThemeModeProvider).value, ThemeMode.system, reason: 'the settings mode, not the pack\'s');
  });

  test('the pack mode overrides the setting; setThemePackMode only touches the pack', () async {
    final c = container();
    await appearanceLoaded(c);
    c.read(settingsProvider);
    await until(() => c.read(settingsProvider).loaded);
    await c.read(settingsProvider.notifier).setThemeMode(ThemeMode.light);
    expect(c.read(uiThemeModeProvider).value, ThemeMode.light);

    final installed = await install(c);
    await c.read(appearanceProvider.notifier).selectThemePack(installed.pack);
    await until(() => c.read(activeThemePackProvider) != null);
    expect(c.read(uiThemeModeProvider).value, ThemeMode.dark);

    await c.read(appearanceProvider.notifier).setThemePackMode(ThemeMode.system);
    expect(c.read(uiThemeModeProvider).value, ThemeMode.system);
    expect(c.read(settingsProvider).themeMode, ThemeMode.light, reason: 'the setting is not written');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'light');
    expect(prefs.getString(_themePackModeKey), 'system');

    // Without a pack the setter does nothing at all.
    await c.read(appearanceProvider.notifier).clearThemePack();
    await c.read(appearanceProvider.notifier).setThemePackMode(ThemeMode.dark);
    expect(c.read(appearanceProvider).themePackMode, isNull);
    expect(prefs.getString(_themePackModeKey), isNull);
    expect(c.read(uiThemeModeProvider).value, ThemeMode.light);
  });

  test('ui.json theme.mode still wins over the pack', () async {
    final local = FakeUiSource();
    final c = container(uiSource: local);
    addTearDown(c.listen(uiOverridesProvider, (_, _) {}).close);
    addTearDown(c.listen(uiThemeModeProvider, (_, _) {}).close);
    await appearanceLoaded(c);
    final installed = await install(c);
    await c.read(appearanceProvider.notifier).selectThemePack(installed.pack);
    await until(() => c.read(activeThemePackProvider) != null);
    expect(c.read(uiThemeModeProvider).value, ThemeMode.dark);

    local.text('{"version": 1, "theme": {"mode": "light"}}');
    await until(() => c.read(uiOverridesProvider).config.themeMode != null);
    final mode = c.read(uiThemeModeProvider);
    expect(mode.value, ThemeMode.light);
    expect(mode.fromUiJson, isTrue);
  });

  test('a library listing that fails is an error, not an empty list', () async {
    final c = ProviderContainer(
      overrides: [themePackLibraryProvider.overrideWith((ref) async => _FailingLibrary(root))],
    );
    addTearDown(c.dispose);
    c.listen(installedThemePacksProvider, (_, _) {});
    await until(() => c.read(installedThemePacksProvider).hasError);
    var state = c.read(installedThemePacksProvider);
    expect(state.hasValue, isFalse);
    expect(state.isLoading, isFalse, reason: 'an error is not something to keep waiting for');
    expect(state.error, isA<ThemePackFormatException>());

    // The same after an explicit refresh.
    await c.read(installedThemePacksProvider.notifier).reload();
    await until(() => c.read(installedThemePacksProvider).hasError);
    state = c.read(installedThemePacksProvider);
    expect(state.hasValue, isFalse);
    expect(state.error, isA<ThemePackFormatException>());
  });
}
