// 设置 › 主题 › 主题包: importing a `.dshTheme.zip`, choosing it, replacing
// and removing it. The real library points at a temp folder; the file picker
// is replaced with bytes.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/theme_packs/theme_pack.dart';
import 'package:dsh_app/theme_packs/theme_pack_library.dart';
import 'package:dsh_app/state/theme_packs_state.dart';
import 'package:dsh_app/ui/settings/appearance/theme_pack_section.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// A 1 × 1 PNG that the image codec can really decode.
final _previewPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// A valid schema-1 pack. Preview and extras are what a test needs.
List<int> _packZip({
  String id = 'christmas',
  String name = '圣诞限定',
  String version = '1.0.0',
  String? author = 'dsh-Go',
  String mode = 'system',
  bool withPreview = true,
  bool withNotices = false,
  List<int>? preview,
}) {
  final json = <String, Object?>{
    'schema': 1,
    'id': id,
    'name': {'zh': name, 'en': 'Christmas'},
    'version': version,
    'author': ?author,
    'mode': mode,
    'colors': {'accent': '#B4232C', 'neutralTint': '#14503C', if (withNotices) 'highlight': '#C9973F'},
    if (withNotices) 'decorations': {'snow': true, 'whaleHat': true},
    if (withNotices) 'dates': {'from': '12-01', 'to': '12-26'},
    if (withPreview) 'preview': 'preview.png',
  };
  final archive = Archive()..add(ArchiveFile.bytes('theme.json', utf8.encode(jsonEncode(json))));
  if (withPreview) archive.add(ArchiveFile.bytes('preview.png', preview ?? _previewPng));
  return ZipEncoder().encode(archive);
}

/// A library whose first listing fails, like an unreadable folder, and which
/// reads fine when asked again.
class _FlakyLibrary extends ThemePackLibrary {
  _FlakyLibrary(super.root);

  int calls = 0;

  @override
  Future<List<ThemePackInstallation>> list() async {
    calls++;
    if (calls == 1) throw const ThemePackFormatException('storage', field: null, reason: 'unreadable');
    return super.list();
  }
}

Widget _app(List<Override> overrides, {double textScale = 1}) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: withTestFonts(buildLightTheme()),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: Scaffold(
      body: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: const SingleChildScrollView(
          child: SettingsSection(title: '主题包', children: [ThemePackSection()]),
        ),
      ),
    ),
  ),
);

/// Lets real file work (inspect, write, list) finish, pumping between attempts.
Future<void> _settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 120 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(done(), isTrue, reason: 'the expected state did not arrive');
  await tester.pump();
}

Future<ProviderContainer> _open(
  WidgetTester tester,
  Future<ThemePackPickResult> Function() picker, {
  List<Override> extra = const [],
  double textScale = 1,
  double width = 390,
  double height = 1000,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width * 2, height * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app([themePackPickerProvider.overrideWithValue(picker), ...extra], textScale: textScale));
  final container = ProviderScope.containerOf(tester.element(find.byType(ThemePackSection)));
  await _settle(tester, () => !container.read(installedThemePacksProvider).isLoading);
  return container;
}

Future<void> _tapImport(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('theme-pack-import')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _waitNotBusy(WidgetTester tester) =>
    _settle(tester, () => tester.widget<SettingsTile>(find.byKey(const ValueKey('theme-pack-import'))).onTap != null);

void main() {
  late Directory temp;
  late Directory root;
  late List<Override> rootOverride;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('theme-pack-section');
    root = Directory('${temp.path}/themes');
    rootOverride = [themePackRootProvider.overrideWithValue(() async => root)];
  });
  tearDown(() => temp.deleteSync(recursive: true));

  testWidgets('no packs: only the import row', (tester) async {
    final container = await _open(tester, () async => const ThemePackPickResult.cancelled(), extra: rootOverride);
    expect(container.read(installedThemePacksProvider).value, isEmpty);
    expect(find.byKey(const ValueKey('theme-pack-import')), findsOneWidget);
    expect(find.byType(SettingsTile), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-pack-list-failed')), findsNothing);
    expect(find.byKey(const ValueKey('theme-pack-missing')), findsNothing);
  });

  testWidgets('importing lists the pack and applies it right away', (tester) async {
    final bytes = Uint8List.fromList(_packZip(mode: 'dark'));
    final container = await _open(tester, () async => ThemePackPickResult.picked(bytes), extra: rootOverride);

    await _tapImport(tester);
    await _settle(tester, () => container.read(appearanceProvider).themePackId == 'christmas');

    expect(container.read(activeThemePackProvider)?.pack.id, 'christmas');
    final expected = AppAccent.derive(
      const Color(0xFFB4232C),
      neutralTint: const Color(0xFF14503C),
      id: 'theme-christmas',
      label: '圣诞限定',
    );
    expect(container.read(accentProvider).seed, expected.seed);
    expect(container.read(uiThemeModeProvider).value, ThemeMode.dark);

    expect(find.text('圣诞限定'), findsOneWidget);
    expect(find.text('1.0.0 · dsh-Go'), findsOneWidget);
    expect(find.text('使用中'), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-pack-delete-christmas')), findsOneWidget);
    expect(find.text('已导入「圣诞限定」'), findsOneWidget);
  });

  testWidgets('a preview that cannot decode falls back to an icon, not an exception', (tester) async {
    final broken = _previewPng.sublist(0, 33);
    final container = await _open(
      tester,
      () async => ThemePackPickResult.picked(Uint8List.fromList(_packZip(preview: broken))),
      extra: rootOverride,
    );

    await _tapImport(tester);
    await _settle(tester, () => container.read(appearanceProvider).themePackId == 'christmas');
    expect(container.read(activeThemePackProvider)?.pack.id, 'christmas');
    expect(find.byKey(const ValueKey('theme-pack-delete-christmas')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the same id asks before replacing; cancel keeps the old version', (tester) async {
    var bytes = Uint8List.fromList(_packZip(version: '1.0.0'));
    final container = await _open(tester, () async => ThemePackPickResult.picked(bytes), extra: rootOverride);
    await _tapImport(tester);
    await _settle(tester, () => container.read(appearanceProvider).themePackId == 'christmas');
    await _waitNotBusy(tester);

    bytes = Uint8List.fromList(_packZip(version: '2.0.0'));
    await _tapImport(tester);
    await _settle(tester, () => find.text('替换主题包？').evaluate().isNotEmpty);
    expect(find.text('已经导入过「圣诞限定」，替换后使用新版本。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await _settle(tester, () => find.text('替换主题包？').evaluate().isEmpty);
    expect(container.read(installedThemePacksProvider).value!.single.pack.version, '1.0.0');

    await _waitNotBusy(tester);
    await _tapImport(tester);
    await _settle(tester, () => find.text('替换主题包？').evaluate().isNotEmpty);
    await tester.tap(find.text('确认'));
    await _settle(tester, () => find.text('已替换「圣诞限定」').evaluate().isNotEmpty);
    expect(container.read(installedThemePacksProvider).value?.single.pack.version, '2.0.0');
    expect(find.text('2.0.0 · dsh-Go'), findsOneWidget);
  });

  testWidgets('notices are listed first; cancel installs nothing, confirming does', (tester) async {
    final bytes = Uint8List.fromList(_packZip(withNotices: true));
    final container = await _open(tester, () async => ThemePackPickResult.picked(bytes), extra: rootOverride);

    await _tapImport(tester);
    await _settle(tester, () => find.text('部分效果暂未生效').evaluate().isNotEmpty);
    expect(find.textContaining('轻雪'), findsOneWidget);
    expect(find.textContaining('小鲸鱼帽子'), findsOneWidget);
    expect(find.textContaining('点缀色'), findsOneWidget);
    expect(find.textContaining('日期范围'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await _settle(tester, () => find.text('部分效果暂未生效').evaluate().isEmpty);
    expect(container.read(installedThemePacksProvider).value, isEmpty);
    expect(container.read(appearanceProvider).themePackId, isNull);
    expect(find.byKey(const ValueKey('theme-pack-delete-christmas')), findsNothing);

    await _waitNotBusy(tester);
    await _tapImport(tester);
    await _settle(tester, () => find.text('部分效果暂未生效').evaluate().isNotEmpty);
    await tester.tap(find.text('仍然导入'));
    await _settle(tester, () => container.read(appearanceProvider).themePackId == 'christmas');
    expect(container.read(activeThemePackProvider)?.pack.id, 'christmas');
    expect(find.byKey(const ValueKey('theme-pack-delete-christmas')), findsOneWidget);
  });

  testWidgets('removing asks first, then clears the choice if it was in use', (tester) async {
    final bytes = Uint8List.fromList(_packZip());
    final container = await _open(tester, () async => ThemePackPickResult.picked(bytes), extra: rootOverride);
    await _tapImport(tester);
    await _settle(tester, () => container.read(appearanceProvider).themePackId == 'christmas');
    await _waitNotBusy(tester);

    await tester.tap(find.byKey(const ValueKey('theme-pack-delete-christmas')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('删除主题包？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await _settle(tester, () => find.text('已删除「圣诞限定」').evaluate().isNotEmpty);

    expect(container.read(appearanceProvider).themePackId, isNull);
    expect(container.read(activeThemePackProvider), isNull);
    expect(find.byKey(const ValueKey('theme-pack-delete-christmas')), findsNothing);
    expect(find.text('已删除「圣诞限定」'), findsOneWidget);
  });

  testWidgets('a listing that fails is a retry row, never an empty list', (tester) async {
    final library = _FlakyLibrary(root);
    final container = await _open(
      tester,
      () async => const ThemePackPickResult.cancelled(),
      extra: [
        themePackLibraryProvider.overrideWith((ref) async => library),
        themePackRootProvider.overrideWithValue(() async => root),
      ],
    );
    expect(container.read(installedThemePacksProvider).hasError, isTrue);
    expect(find.text('读取主题包失败，点此重试'), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-pack-import')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('theme-pack-list-failed')));
    await _settle(tester, () => !container.read(installedThemePacksProvider).hasError);
    expect(library.calls, 2);
    expect(find.text('读取主题包失败，点此重试'), findsNothing);
    expect(find.byKey(const ValueKey('theme-pack-import')), findsOneWidget);
  });

  testWidgets('narrow phone, large text, long names: nothing overflows', (tester) async {
    root.createSync(recursive: true);
    File('${root.path}/christmas.dshTheme.zip').writeAsBytesSync(
      _packZip(
        name: '冬日松林雪夜灯光节限定主题包',
        version: '123456789.123456789.123456789',
        author: '一个名字特别长的主题包作者',
        withPreview: true,
      ),
    );
    final container = await _open(
      tester,
      () async => const ThemePackPickResult.cancelled(),
      extra: rootOverride,
      textScale: 1.8,
      width: 320,
      height: 1200,
    );
    expect(container.read(installedThemePacksProvider).value, hasLength(1));
    expect(find.byKey(const ValueKey('theme-pack-delete-christmas')), findsOneWidget);
    expect(find.text('冬日松林雪夜灯光节限定主题包'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
