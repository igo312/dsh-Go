import 'dart:async';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../theme_packs/theme_pack.dart';
import 'theme_packs_state.dart';
import '../ui/theme/accent.dart';

/// 配色从哪来。
enum AccentSource {
  /// 六套预设之一([AppearanceSettings.presetId])。
  preset,

  /// 用户挑的颜色([AppearanceSettings.customColor]),过对比度守卫。
  custom,

  /// 系统壁纸取色(Android 12 起)。
  wallpaper,
}

/// 外观设置里的配色部分。外观模式(浅 / 深 / 跟随系统)仍在
/// `settings_state.dart` 的 `themeMode`,只是界面挪到了外观页。
class AppearanceSettings {
  const AppearanceSettings({
    this.source = AccentSource.preset,
    this.presetId = 'mist',
    this.customColor = defaultCustom,
    this.loaded = false,
    this.themePackId,
    this.themePackMode,
  });

  final AccentSource source;

  /// 最近一次选的预设;切到自定义 / 壁纸再切回来时用。
  final String presetId;

  /// 自定义色(ARGB),守卫之前的原色。
  final int customColor;
  final bool loaded;

  /// 选中的主题包 id(见 `theme_packs/`);null 时用 [source] 那套。
  final String? themePackId;

  /// 主题包指定的明暗模式;只覆盖模式,不写 `settings_state.dart` 的
  /// `themeMode`。null 时用设置里的。
  final ThemeMode? themePackMode;

  /// 自定义色的初值:一抹灰调的苔绿(色相 140°),第一次打开时和六套预设
  /// 都不撞。
  static const defaultCustom = 0xFF5F7A55;

  AppearanceSettings copyWith({
    AccentSource? source,
    String? presetId,
    int? customColor,
    bool? loaded,
    String? themePackId,
    ThemeMode? themePackMode,
    bool clearThemePack = false,
  }) => AppearanceSettings(
    source: source ?? this.source,
    presetId: presetId ?? this.presetId,
    customColor: customColor ?? this.customColor,
    loaded: loaded ?? this.loaded,
    themePackId: clearThemePack ? null : (themePackId ?? this.themePackId),
    themePackMode: clearThemePack ? null : (themePackMode ?? this.themePackMode),
  );
}

class AppearanceController extends Notifier<AppearanceSettings> {
  static const _sourceKey = 'appearance.accent_source';
  static const _presetKey = 'appearance.preset';
  static const _customKey = 'appearance.custom_color';
  static const _themePackKey = 'appearance.theme_pack';
  static const _themePackModeKey = 'appearance.theme_pack_mode';

  /// 当前配色的浅色主色(ARGB),给原生通知的强调色读
  /// (`DynamicColorPlugin.kt` 的 `ThemeAccent`)。
  static const notifyColorKey = 'appearance.notify_color';

  late Future<void> _loaded;

  @override
  AppearanceSettings build() {
    _loaded = _load();
    return const AppearanceSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final source = AccentSource.values.asNameMap()[prefs.getString(_sourceKey)] ?? AccentSource.preset;
      state = AppearanceSettings(
        source: source,
        presetId: AppAccent.preset(prefs.getString(_presetKey)).id,
        customColor: prefs.getInt(_customKey) ?? AppearanceSettings.defaultCustom,
        loaded: true,
        themePackId: prefs.getString(_themePackKey),
        themePackMode: ThemeMode.values.asNameMap()[prefs.getString(_themePackModeKey)],
      );
    } catch (_) {
      // No preferences backend (tests): the default palette.
      state = state.copyWith(loaded: true);
    }
  }

  /// 存在读完之后:启动后马上改的值不会被晚到的读取盖掉。
  Future<void> _save(AppearanceSettings next, Future<void> Function(SharedPreferences prefs) write) async {
    await _loaded;
    state = next.copyWith(loaded: true);
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {
      // Kept for this run only.
    }
  }

  Future<void> selectPreset(String id) =>
      _save(state.copyWith(source: AccentSource.preset, presetId: id, clearThemePack: true), (p) async {
        await p.setString(_sourceKey, AccentSource.preset.name);
        await p.setString(_presetKey, id);
        await p.remove(_themePackKey);
        await p.remove(_themePackModeKey);
      });

  /// 选中自定义;[color] 给了就同时换颜色(色相条、推荐色)。
  Future<void> selectCustom([int? color]) =>
      _save(state.copyWith(source: AccentSource.custom, customColor: color, clearThemePack: true), (p) async {
        await p.setString(_sourceKey, AccentSource.custom.name);
        if (color != null) await p.setInt(_customKey, color);
        await p.remove(_themePackKey);
        await p.remove(_themePackModeKey);
      });

  Future<void> selectWallpaper() =>
      _save(state.copyWith(source: AccentSource.wallpaper, clearThemePack: true), (p) async {
        await p.setString(_sourceKey, AccentSource.wallpaper.name);
        await p.remove(_themePackKey);
        await p.remove(_themePackModeKey);
      });

  /// 关掉跟随壁纸:回到上一次的预设。
  Future<void> leaveWallpaper() => selectPreset(state.presetId);

  /// 选中主题包:强调色、中性色和明暗模式都由它决定。预设 / 自定义色
  /// 原样留着,清掉主题包后回得去。
  Future<void> selectThemePack(ThemePack pack) {
    final mode = _themeModeFor(pack.mode);
    return _save(state.copyWith(themePackId: pack.id, themePackMode: mode), (p) async {
      await p.setString(_themePackKey, pack.id);
      await p.setString(_themePackModeKey, mode.name);
    });
  }

  /// 不用主题包了,回到 [source] 那套配色。
  Future<void> clearThemePack() => _save(state.copyWith(clearThemePack: true), (p) async {
    await p.remove(_themePackKey);
    await p.remove(_themePackModeKey);
  });

  /// 只改主题包带来的模式覆盖;没选主题包时不动,设置里的模式也不写。
  Future<void> setThemePackMode(ThemeMode mode) async {
    if (state.themePackId == null) return;
    await _save(state.copyWith(themePackMode: mode), (p) => p.setString(_themePackModeKey, mode.name));
  }

  static ThemeMode _themeModeFor(ThemePackMode mode) => switch (mode) {
    ThemePackMode.system => ThemeMode.system,
    ThemePackMode.light => ThemeMode.light,
    ThemePackMode.dark => ThemeMode.dark,
  };
}

final appearanceProvider = NotifierProvider<AppearanceController, AppearanceSettings>(AppearanceController.new);

/// 系统的壁纸取色(Android 12+ 的 `system_accent1_*`)。低版本、取不到时为
/// null,外观页据此整行不显示「跟随壁纸」。
class DynamicColorChannel {
  const DynamicColorChannel([this._methods = const MethodChannel('dsh/dynamic_color')]);

  final MethodChannel _methods;

  /// 壁纸主色(accent1 的中间调);不支持时 null。
  Future<Color?> wallpaperAccent() async {
    try {
      final palette = await _methods.invokeMapMethod<String, Object?>('palette');
      final value = palette?['accent'] ?? palette?['accentLight'];
      return value is int ? Color(value) : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

final dynamicColorChannelProvider = Provider<DynamicColorChannel>((ref) => const DynamicColorChannel());

/// 壁纸主色;App 回到前台时重读(用户可能刚换了壁纸)。
final wallpaperAccentProvider = FutureProvider<Color?>((ref) {
  final listener = AppLifecycleListener(onResume: ref.invalidateSelf);
  ref.onDispose(listener.dispose);
  return ref.watch(dynamicColorChannelProvider).wallpaperAccent();
});

/// 当前选中且还装着的主题包;没选、列表还没读出来、或文件不在了时为 null。
/// 首版不看 `dates`。
final activeThemePackProvider = Provider<ThemePackInstallation?>((ref) {
  final id = ref.watch(appearanceProvider.select((s) => s.themePackId));
  if (id == null) return null;
  final installed = ref.watch(installedThemePacksProvider);
  for (final installation in installed.value ?? const <ThemePackInstallation>[]) {
    if (installation.pack.id == id) return installation;
  }
  return null;
});

/// 当前生效的配色。壁纸色还没读到(或读不到)时先用上一次的预设。
final accentProvider = Provider<AppAccent>((ref) {
  final s = ref.watch(appearanceProvider);
  final active = ref.watch(activeThemePackProvider);
  final AppAccent accent;
  if (active != null) {
    final pack = active.pack;
    final neutralTint = pack.neutralTint;
    accent = AppAccent.derive(
      Color(pack.accent),
      neutralTint: neutralTint == null ? null : Color(neutralTint),
      id: 'theme-${pack.id}',
      label: pack.name.forLocale(AppLocale.current.languageCode),
    );
  } else {
    final preset = AppAccent.preset(s.presetId);
    accent = switch (s.source) {
      AccentSource.preset => preset,
      AccentSource.custom => AppAccent.derive(Color(s.customColor)),
      AccentSource.wallpaper => switch (ref.watch(wallpaperAccentProvider).value) {
        final c? => AppAccent.derive(c, id: AppAccent.wallpaperId, label: appL10n.stateWallpaper),
        null => preset,
      },
    };
  }
  if (s.loaded) unawaited(_publishNotifyColor(accent));
  return accent;
});

int? _published;

/// 原生通知读这个值给小图标着色;只在变了时写。
Future<void> _publishNotifyColor(AppAccent accent) async {
  final argb = accent.seed.toARGB32();
  if (_published == argb) return;
  _published = argb;
  try {
    await (await SharedPreferences.getInstance()).setInt(AppearanceController.notifyColorKey, argb);
  } catch (_) {
    // Tests: no backend.
  }
}
