// A theme pack is plain data read from a `theme.json` (docs/theme-packs).
// This file is pure Dart on purpose: no Flutter, no dart:ui, no Riverpod, no
// ui/ imports. Colors are 0xRRGGBB ints and named `accent`/`neutralTint`/
// `highlight` so whoever applies them maps them to the App's palette.
//
// Only accent, neutralTint and mode are applied by this first version. The
// rest parses, validates and gets a notice saying it is not applied yet.

import 'dart:convert';
import 'dart:typed_data';

/// How the pack wants the App's light/dark mode set.
enum ThemePackMode { system, light, dark }

/// One piece of text in the pack's two languages.
class ThemePackText {
  const ThemePackText(this.zh, [this.en]);

  /// Always present; falls back for any unsupported locale.
  final String zh;

  /// Optional; the schema rejects an empty string when present.
  final String? en;

  /// The text for a language tag such as `zh-Hans` or `en-US`.
  String forLocale(String languageCode) {
    if (languageCode.toLowerCase().startsWith('en')) {
      final english = en;
      if (english != null && english.isNotEmpty) return english;
    }
    return zh;
  }
}

/// An inclusive month/day window that may wrap across New Year.
class ThemePackDates {
  const ThemePackDates({required this.fromMonth, required this.fromDay, required this.toMonth, required this.toDay});

  final int fromMonth;
  final int fromDay;
  final int toMonth;
  final int toDay;

  /// Whether [local]'s month/day is inside the window. The year is ignored,
  /// and both ends count.
  bool contains(DateTime local) {
    final from = fromMonth * 100 + fromDay;
    final to = toMonth * 100 + toDay;
    final day = local.month * 100 + local.day;
    if (from <= to) return day >= from && day <= to;
    return day >= from || day <= to;
  }
}

/// Decorations the pack asks for but this version does not draw.
class ThemePackCapabilities {
  const ThemePackCapabilities({this.snow = false, this.whaleHat = false});

  final bool snow;
  final bool whaleHat;
}

/// A parsed-but-not-applied part of the pack, for the UI to mention.
class ThemePackNotice {
  const ThemePackNotice(this.code, this.field);

  /// Stable code, e.g. `snow_not_applied`.
  final String code;

  /// The `theme.json` field it came from, e.g. `decorations.snow`.
  final String field;
}

/// A validated theme pack.
class ThemePack {
  const ThemePack({
    required this.schema,
    required this.id,
    required this.name,
    required this.version,
    required this.mode,
    required this.accent,
    this.description,
    this.author,
    this.neutralTint,
    this.highlight,
    this.capabilities = const ThemePackCapabilities(),
    this.dates,
    this.previewPath,
  });

  final int schema;
  final String id;
  final ThemePackText name;
  final String version;
  final String? author;
  final ThemePackText? description;
  final ThemePackMode mode;

  /// 0xRRGGBB.
  final int accent;
  final int? neutralTint;
  final int? highlight;
  final ThemePackCapabilities capabilities;
  final ThemePackDates? dates;
  final String? previewPath;

  /// The schema-1 form of this pack, with only fields it represents. Used to
  /// store a normalized `theme.json`; absent optional values stay absent.
  Map<String, Object?> toJson() => {
    'schema': schema,
    'id': id,
    'name': {'zh': name.zh, if (name.en != null && name.en!.isNotEmpty) 'en': name.en},
    'version': version,
    if (author != null) 'author': author,
    if (description != null)
      'description': {
        if (description!.zh.isNotEmpty) 'zh': description!.zh,
        if (description!.en != null && description!.en!.isNotEmpty) 'en': description!.en,
      },
    'mode': mode.name,
    'colors': {
      'accent': _hex(accent),
      if (neutralTint != null) 'neutralTint': _hex(neutralTint!),
      if (highlight != null) 'highlight': _hex(highlight!),
    },
    if (capabilities.snow || capabilities.whaleHat)
      'decorations': {if (capabilities.snow) 'snow': true, if (capabilities.whaleHat) 'whaleHat': true},
    if (dates != null)
      'dates': {'from': _monthDay(dates!.fromMonth, dates!.fromDay), 'to': _monthDay(dates!.toMonth, dates!.toDay)},
    if (previewPath != null) 'preview': previewPath,
  };

  static String _hex(int rgb) => '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';

  static String _monthDay(int month, int day) =>
      '${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
}

/// Why a `theme.json` was turned away.
class ThemePackFormatException implements Exception {
  const ThemePackFormatException(this.code, {this.field, this.reason});

  /// Stable code: badJson, unknownField, missingField, wrongType, tooLong,
  /// unsupportedSchema, invalidId, invalidName, invalidVersion, invalidMode,
  /// invalidColor, invalidDates, invalidPreview.
  final String code;

  /// Dotted path to the offending field, e.g. `colors.accent`.
  final String? field;

  /// Human-readable detail, for CLI output; [code] is the stable contract.
  final String? reason;

  @override
  String toString() =>
      'ThemePackFormatException($code${field == null ? '' : ', field: $field'}${reason == null ? '' : ': $reason'})';
}

/// A parsed pack plus what it asks for but this version does not apply.
class ThemePackParseResult {
  const ThemePackParseResult({required this.pack, required this.notices});

  final ThemePack pack;
  final List<ThemePackNotice> notices;
}

/// Parses the UTF-8 JSON bytes of a `theme.json`.
ThemePackParseResult parseThemePackJson(List<int> bytes) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on Object {
    throw const ThemePackFormatException('badJson', reason: 'theme.json is not UTF-8 JSON');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const ThemePackFormatException('wrongType', field: 'theme.json', reason: 'expected a JSON object');
  }
  return _parsePack(decoded);
}

/// The normalized schema-1 `theme.json` bytes for [pack].
Uint8List encodeThemePackJson(ThemePack pack) => utf8.encode(jsonEncode(pack.toJson()));

ThemePackParseResult _parsePack(Map<String, dynamic> json) {
  _rejectUnknown(json, const {
    'schema',
    'id',
    'name',
    'version',
    'author',
    'description',
    'mode',
    'colors',
    'decorations',
    'dates',
    'preview',
  }, '');

  final schema = _required(json, 'schema', '');
  if (schema is! int) _fail('wrongType', 'schema', 'expected integer');
  if (schema != 1) _fail('unsupportedSchema', 'schema', 'only schema 1 is supported');

  final id = _string(_required(json, 'id', ''), 'id');
  if (!RegExp(r'^[a-z][a-z0-9-]{1,47}$').hasMatch(id)) {
    _fail('invalidId', 'id', 'expected lower-case letters, digits and dashes');
  }

  final name = _parseName(_required(json, 'name', ''));

  final version = _string(_required(json, 'version', ''), 'version', allowEmpty: true);
  if (!RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(version)) {
    _fail('invalidVersion', 'version', 'expected x.y.z');
  }
  _checkLength(version, 32, 'version');

  String? author;
  if (json.containsKey('author')) {
    author = _string(json['author'], 'author');
    _checkLength(author, 64, 'author');
  }

  ThemePackText? description;
  if (json.containsKey('description')) {
    description = _parseDescription(json['description']);
  }

  final modeName = _string(_required(json, 'mode', ''), 'mode', allowEmpty: true);
  final mode = switch (modeName) {
    'system' => ThemePackMode.system,
    'light' => ThemePackMode.light,
    'dark' => ThemePackMode.dark,
    _ => _fail<ThemePackMode>('invalidMode', 'mode', 'expected system, light or dark'),
  };

  final colors = _map(_required(json, 'colors', ''), 'colors');
  _rejectUnknown(colors, const {'accent', 'neutralTint', 'highlight'}, 'colors');
  final accent = _parseColor(_required(colors, 'accent', 'colors'), 'colors.accent');
  final neutralTint = colors.containsKey('neutralTint')
      ? _parseColor(colors['neutralTint'], 'colors.neutralTint')
      : null;
  final highlight = colors.containsKey('highlight') ? _parseColor(colors['highlight'], 'colors.highlight') : null;

  var snow = false;
  var whaleHat = false;
  if (json.containsKey('decorations')) {
    final decorations = _map(json['decorations'], 'decorations');
    _rejectUnknown(decorations, const {'snow', 'whaleHat'}, 'decorations');
    if (decorations.containsKey('snow')) snow = _bool(decorations['snow'], 'decorations.snow');
    if (decorations.containsKey('whaleHat')) whaleHat = _bool(decorations['whaleHat'], 'decorations.whaleHat');
  }

  ThemePackDates? dates;
  if (json.containsKey('dates')) {
    final rawDates = _map(json['dates'], 'dates');
    _rejectUnknown(rawDates, const {'from', 'to'}, 'dates');
    if (!rawDates.containsKey('from') || !rawDates.containsKey('to') || rawDates.length != 2) {
      _fail('invalidDates', 'dates', 'from and to must be present together');
    }
    final from = _monthDay(rawDates['from'], 'dates.from');
    final to = _monthDay(rawDates['to'], 'dates.to');
    dates = ThemePackDates(fromMonth: from.$1, fromDay: from.$2, toMonth: to.$1, toDay: to.$2);
  }

  String? previewPath;
  if (json.containsKey('preview')) {
    previewPath = _previewPath(json['preview']);
  }

  final capabilities = ThemePackCapabilities(snow: snow, whaleHat: whaleHat);
  final pack = ThemePack(
    schema: 1,
    id: id,
    name: name,
    version: version,
    author: author,
    description: description,
    mode: mode,
    accent: accent,
    neutralTint: neutralTint,
    highlight: highlight,
    capabilities: capabilities,
    dates: dates,
    previewPath: previewPath,
  );

  return ThemePackParseResult(
    pack: pack,
    notices: [
      if (highlight != null) const ThemePackNotice('highlight_not_applied', 'colors.highlight'),
      if (snow) const ThemePackNotice('snow_not_applied', 'decorations.snow'),
      if (whaleHat) const ThemePackNotice('whaleHat_not_applied', 'decorations.whaleHat'),
      if (dates != null) const ThemePackNotice('dates_not_applied', 'dates'),
    ],
  );
}

ThemePackText _parseName(Object? value) {
  if (value is String) {
    _checkMinLength(value, 1, 'name', 'invalidName');
    _checkLength(value, 24, 'name');
    return ThemePackText(value);
  }
  if (value is Map<String, dynamic>) {
    _rejectUnknown(value, const {'zh', 'en'}, 'name');
    final zh = _string(_required(value, 'zh', 'name'), 'name.zh', allowEmpty: true);
    _checkMinLength(zh, 1, 'name.zh', 'invalidName');
    _checkLength(zh, 24, 'name.zh');
    String? en;
    if (value.containsKey('en')) {
      en = _string(value['en'], 'name.en', allowEmpty: true);
      _checkMinLength(en, 1, 'name.en', 'invalidName');
      _checkLength(en, 24, 'name.en');
    }
    return ThemePackText(zh, en);
  }
  _fail('wrongType', 'name', 'expected a string or {zh, en}');
}

ThemePackText _parseDescription(Object? value) {
  if (value is String) {
    final text = _string(value, 'description');
    _checkLength(text, 160, 'description');
    return ThemePackText(text);
  }
  if (value is Map<String, dynamic>) {
    _rejectUnknown(value, const {'zh', 'en'}, 'description');
    var zh = '';
    String? en;
    if (value.containsKey('zh')) {
      zh = _string(value['zh'], 'description.zh');
      _checkLength(zh, 160, 'description.zh');
    }
    if (value.containsKey('en')) {
      en = _string(value['en'], 'description.en');
      _checkLength(en, 160, 'description.en');
    }
    return ThemePackText(zh, en);
  }
  _fail('wrongType', 'description', 'expected a string or {zh, en}');
}

int _parseColor(Object? value, String field) {
  final text = _string(value, field);
  if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(text)) {
    _fail('invalidColor', field, 'expected #RRGGBB');
  }
  return int.parse(text.substring(1), radix: 16);
}

(int, int) _monthDay(Object? value, String field) {
  if (value is! String || value.isEmpty) _fail('invalidDates', field, 'expected MM-DD');
  final match = RegExp(r'^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$').firstMatch(value);
  if (match == null) _fail('invalidDates', field, 'expected MM-DD');
  final month = int.parse(match[1]!);
  final day = int.parse(match[2]!);
  // 2024 is a leap year, so 02-29 is accepted; any other overflow is caught.
  if (DateTime(2024, month, day).day != day) {
    _fail('invalidDates', field, 'not a real month/day');
  }
  return (month, day);
}

String _previewPath(Object? value) {
  final path = _string(value, 'preview', allowEmpty: true);
  if (path.isEmpty ||
      path.contains('\x00') ||
      path.contains('\\') ||
      path.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(path) ||
      !RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(path) ||
      !path.endsWith('.png') ||
      path.split('/').any((part) => part.isEmpty || part == '.' || part == '..')) {
    _fail('invalidPreview', 'preview', 'expected a safe relative .png path');
  }
  return path;
}

Map<String, dynamic> _map(Object? value, String field) {
  if (value is! Map<String, dynamic>) _fail('wrongType', field, 'expected an object');
  return value;
}

bool _bool(Object? value, String field) {
  if (value is! bool) _fail('wrongType', field, 'expected true or false');
  return value;
}

String _string(Object? value, String field, {bool allowEmpty = false}) {
  if (value is! String) _fail('wrongType', field, 'expected a string');
  if (!allowEmpty && value.isEmpty) _fail('wrongType', field, 'expected a non-empty string');
  return value;
}

Object? _required(Map<String, dynamic> json, String key, String path) {
  if (!json.containsKey(key)) _fail('missingField', path.isEmpty ? key : '$path.$key', 'required');
  return json[key];
}

void _checkLength(String value, int max, String field) {
  if (value.runes.length > max) _fail('tooLong', field, 'at most $max characters');
}

void _checkMinLength(String value, int min, String field, String code) {
  if (value.runes.length < min) _fail(code, field, 'at least $min character');
}

void _rejectUnknown(Map<String, dynamic> json, Set<String> allowed, String path) {
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      _fail('unknownField', path.isEmpty ? key : '$path.$key', 'unknown field');
    }
  }
}

Never _fail<T>(String code, String field, [String? reason]) =>
    throw ThemePackFormatException(code, field: field, reason: reason);
