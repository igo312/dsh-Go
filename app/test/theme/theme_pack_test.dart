import 'dart:convert';

import 'package:dsh_app/theme_packs/theme_pack.dart';
import 'package:flutter_test/flutter_test.dart';

/// The experiment's `theme.json`, kept inline so this test states the format.
Map<String, Object?> christmasJson() => {
  'schema': 1,
  'id': 'christmas',
  'name': {'zh': '圣诞限定', 'en': 'Christmas'},
  'version': '1.0.0',
  'author': 'dsh-Go',
  'description': {
    'zh': '松针绿、浆果红和香槟金；轻雪，小鲸鱼戴圣诞帽。',
    'en': 'Pine, berry and champagne gold; light snow and a Santa hat for the whale.',
  },
  'mode': 'system',
  'colors': {'accent': '#B4232C', 'neutralTint': '#14503C', 'highlight': '#C9973F'},
  'decorations': {'snow': true, 'whaleHat': true},
  'dates': {'from': '12-01', 'to': '12-26'},
  'preview': 'preview.png',
};

ThemePackParseResult parse(Map<String, Object?> json) => parseThemePackJson(utf8.encode(jsonEncode(json)));

ThemePackFormatException problem(Map<String, Object?> json) {
  try {
    parse(json);
  } on ThemePackFormatException catch (error) {
    return error;
  }
  fail('expected ThemePackFormatException');
}

Map<String, Object?> minimal() => {
  'schema': 1,
  'id': 'plain',
  'name': 'Plain',
  'version': '0.1.0',
  'mode': 'dark',
  'colors': {'accent': '#112233'},
};

void main() {
  group('valid pack', () {
    test('reads the Christmas pack and its colors', () {
      final result = parse(christmasJson());
      final pack = result.pack;

      expect(pack.schema, 1);
      expect(pack.id, 'christmas');
      expect(pack.name.zh, '圣诞限定');
      expect(pack.name.en, 'Christmas');
      expect(pack.name.forLocale('zh-Hans'), '圣诞限定');
      expect(pack.name.forLocale('en-US'), 'Christmas');
      expect(pack.version, '1.0.0');
      expect(pack.author, 'dsh-Go');
      expect(pack.description?.zh, contains('松针绿'));
      expect(pack.description?.en, contains('Pine'));
      expect(pack.mode, ThemePackMode.system);
      expect(pack.accent, 0xB4232C);
      expect(pack.neutralTint, 0x14503C);
      expect(pack.highlight, 0xC9973F);
      expect(pack.capabilities.snow, isTrue);
      expect(pack.capabilities.whaleHat, isTrue);
      expect(pack.dates?.fromMonth, 12);
      expect(pack.dates?.fromDay, 1);
      expect(pack.dates?.toMonth, 12);
      expect(pack.dates?.toDay, 26);
      expect(pack.previewPath, 'preview.png');
    });

    test('notices name every parsed-but-unapplied field', () {
      final notices = parse(christmasJson()).notices;
      expect(
        [for (final notice in notices) notice.code],
        ['highlight_not_applied', 'snow_not_applied', 'whaleHat_not_applied', 'dates_not_applied'],
      );
      expect(
        [for (final notice in notices) notice.field],
        ['colors.highlight', 'decorations.snow', 'decorations.whaleHat', 'dates'],
      );
    });

    test('a minimal pack has no notices', () {
      final result = parse(minimal());
      expect(result.notices, isEmpty);
      expect(result.pack.neutralTint, isNull);
      expect(result.pack.highlight, isNull);
      expect(result.pack.dates, isNull);
      expect(result.pack.previewPath, isNull);
      expect(result.pack.description, isNull);
      expect(result.pack.author, isNull);
      expect(result.pack.capabilities.snow, isFalse);
      expect(result.pack.capabilities.whaleHat, isFalse);
    });

    test('false decorations produce no notices', () {
      final json = minimal()..['decorations'] = {'snow': false, 'whaleHat': false};
      expect(parse(json).notices, isEmpty);
    });

    test('each applied extra produces exactly its own notice', () {
      expect(parse(minimal()..['colors'] = {'accent': '#112233', 'neutralTint': '#445566'}).notices, isEmpty);
      expect(
        [
          for (final n in parse(minimal()..['colors'] = {'accent': '#112233', 'highlight': '#ABCDEF'}).notices) n.code,
        ],
        ['highlight_not_applied'],
      );
      expect(
        [
          for (final n in parse(minimal()..['decorations'] = {'snow': true}).notices) n.code,
        ],
        ['snow_not_applied'],
      );
      expect(
        [
          for (final n in parse(minimal()..['decorations'] = {'whaleHat': true}).notices) n.code,
        ],
        ['whaleHat_not_applied'],
      );
      expect(
        [
          for (final n in parse(minimal()..['dates'] = {'from': '01-01', 'to': '01-02'}).notices) n.code,
        ],
        ['dates_not_applied'],
      );
    });
  });

  group('bilingual text', () {
    test('an absent English name falls back to Chinese', () {
      final pack = parse(minimal()..['name'] = {'zh': '中文'}).pack;
      expect(pack.name.forLocale('en-US'), '中文');
      expect(pack.name.forLocale('fr'), '中文');
    });

    test('an empty English name is rejected by the schema', () {
      final error = problem(minimal()..['name'] = {'zh': '中文', 'en': ''});
      expect(error.code, 'invalidName');
      expect(error.field, 'name.en');
    });

    test('a plain name has no English and falls back', () {
      final pack = parse(minimal()).pack;
      expect(pack.name.zh, 'Plain');
      expect(pack.name.en, isNull);
      expect(pack.name.forLocale('en'), 'Plain');
    });

    test('counts Unicode code points, not UTF-16 units', () {
      final atLimit = minimal()..['name'] = '🐳' * 24;
      expect(parse(atLimit).pack.name.zh.runes.length, 24);

      final overLimit = minimal()..['name'] = '🐳' * 25;
      final error = problem(overLimit);
      expect(error.code, 'tooLong');
      expect(error.field, 'name');
    });

    test('description can be a plain string or an object', () {
      expect(parse(minimal()..['description'] = '一句话').pack.description?.zh, '一句话');
      expect(
        parse(minimal()..['description'] = {'en': 'only English'}).pack.description?.forLocale('en'),
        'only English',
      );
    });
  });

  group('schema and unknown fields', () {
    test('schema must be 1', () {
      expect(problem(minimal()..['schema'] = 2).code, 'unsupportedSchema');
      expect(problem(minimal()..['schema'] = 2).field, 'schema');
      expect(problem(minimal()..['schema'] = '1').code, 'wrongType');
      expect(problem(minimal()..remove('schema')).code, 'missingField');
    });

    test('unknown top-level and nested fields are rejected with their path', () {
      final top = problem(minimal()..['glow'] = true);
      expect(top.code, 'unknownField');
      expect(top.field, 'glow');

      final color = problem(minimal()..['colors'] = {'accent': '#112233', 'glow': '#000000'});
      expect(color.code, 'unknownField');
      expect(color.field, 'colors.glow');

      final decoration = problem(minimal()..['decorations'] = {'snow': false, 'glitter': true});
      expect(decoration.code, 'unknownField');
      expect(decoration.field, 'decorations.glitter');

      final date = problem(minimal()..['dates'] = {'from': '01-01', 'to': '01-02', 'year': 2026});
      expect(date.code, 'unknownField');
      expect(date.field, 'dates.year');

      final name = problem(minimal()..['name'] = {'zh': '中文', 'ja': '日本語'});
      expect(name.code, 'unknownField');
      expect(name.field, 'name.ja');
    });
  });

  group('identity fields', () {
    test('id follows the schema pattern', () {
      expect(parse(minimal()..['id'] = 'ab').pack.id, 'ab');
      for (final id in ['A', 'Abc', '1abc', '-abc', 'a_b', 'a b', 'a' * 49]) {
        final error = problem(minimal()..['id'] = id);
        expect(error.code, 'invalidId', reason: id);
        expect(error.field, 'id');
      }
      expect(problem(minimal()..['id'] = 7).code, 'wrongType');
    });

    test('name must be present, non-empty and at most 24 characters', () {
      expect(problem(minimal()..remove('name')).code, 'missingField');
      expect(problem(minimal()..['name'] = '').code, 'invalidName');
      expect(problem(minimal()..['name'] = {'en': 'English'}).code, 'missingField');
      expect(problem(minimal()..['name'] = {'zh': ''}).code, 'invalidName');
      expect(problem(minimal()..['name'] = 3).code, 'wrongType');
      expect(problem(minimal()..['name'] = {'zh': '中文', 'en': 'e' * 25}).code, 'tooLong');
    });

    test('version is x.y.z', () {
      for (final version in ['1.0.0', '12.34.56']) {
        expect(parse(minimal()..['version'] = version).pack.version, version);
      }
      for (final version in ['1.0', 'v1.0.0', '1.0.0-beta', '1.0.0.0', '']) {
        final error = problem(minimal()..['version'] = version);
        expect(error.code, 'invalidVersion', reason: version);
        expect(error.field, 'version');
      }
      final tooLong = problem(minimal()..['version'] = '1.${'0' * 30}.0');
      expect(tooLong.code, 'tooLong');
      expect(tooLong.field, 'version');
    });

    test('author and description lengths are capped', () {
      expect(parse(minimal()..['author'] = 'a' * 64).pack.author, 'a' * 64);
      final author = problem(minimal()..['author'] = 'a' * 65);
      expect(author.code, 'tooLong');
      expect(author.field, 'author');

      expect(parse(minimal()..['description'] = 'd' * 160).pack.description?.zh, 'd' * 160);
      final description = problem(minimal()..['description'] = 'd' * 161);
      expect(description.code, 'tooLong');
      expect(description.field, 'description');

      final english = problem(minimal()..['description'] = {'zh': '中', 'en': 'd' * 161});
      expect(english.code, 'tooLong');
      expect(english.field, 'description.en');
    });
  });

  group('mode and colors', () {
    test('mode is one of system, light, dark', () {
      for (final mode in ['system', 'light', 'dark']) {
        expect(parse(minimal()..['mode'] = mode).pack.mode.name, mode);
      }
      expect(problem(minimal()..['mode'] = 'auto').code, 'invalidMode');
      expect(problem(minimal()..['mode'] = 1).code, 'wrongType');
      expect(problem(minimal()..remove('mode')).code, 'missingField');
    });

    test('accent is required and colors are #RRGGBB', () {
      expect(parse(minimal()..['colors'] = {'accent': '#abcdef'}).pack.accent, 0xABCDEF);
      expect(problem(minimal()..remove('colors')).code, 'missingField');
      expect(problem(minimal()..['colors'] = {}).code, 'missingField');
      expect(problem(minimal()..['colors'] = {'accent': 'B4232C'}).code, 'invalidColor');
      expect(problem(minimal()..['colors'] = {'accent': '#B4232'}).code, 'invalidColor');
      expect(problem(minimal()..['colors'] = {'accent': '#GGGGGG'}).code, 'invalidColor');
      expect(problem(minimal()..['colors'] = {'accent': '#B4232C', 'highlight': 'red'}).code, 'invalidColor');
      final error = problem(minimal()..['colors'] = {'accent': '#B4232C', 'neutralTint': '#12'});
      expect(error.field, 'colors.neutralTint');
      expect(error.code, 'invalidColor');
    });
  });

  group('dates', () {
    test('from and to must come together', () {
      expect(problem(minimal()..['dates'] = {'from': '12-01'}).code, 'invalidDates');
      expect(problem(minimal()..['dates'] = {'to': '12-31'}).code, 'invalidDates');
      expect(problem(minimal()..['dates'] = {}).code, 'invalidDates');
      expect(problem(minimal()..['dates'] = {'from': null, 'to': null}).code, 'invalidDates');
      expect(problem(minimal()..['dates'] = {'from': '', 'to': '12-31'}).code, 'invalidDates');
      expect(parse(minimal()..['dates'] = {'from': '12-01', 'to': '12-31'}).pack.dates?.fromDay, 1);
    });

    test('rejects malformed and impossible month/days but allows 02-29', () {
      for (final dates in [
        {'from': '13-01', 'to': '12-31'},
        {'from': '00-01', 'to': '12-31'},
        {'from': '02-30', 'to': '03-01'},
        {'from': '04-31', 'to': '05-01'},
        {'from': '2-3', 'to': '03-01'},
        {'from': '12/01', 'to': '12-31'},
      ]) {
        final error = problem(minimal()..['dates'] = dates);
        expect(error.code, 'invalidDates', reason: '$dates');
      }
      final leap = parse(minimal()..['dates'] = {'from': '02-29', 'to': '03-01'});
      expect(leap.pack.dates?.fromDay, 29);
    });

    test('contains includes both ends and wraps across New Year', () {
      final wrap = parse(minimal()..['dates'] = {'from': '12-01', 'to': '01-31'}).pack.dates!;
      expect(wrap.contains(DateTime(2026, 12, 1)), isTrue);
      expect(wrap.contains(DateTime(2026, 12, 31)), isTrue);
      expect(wrap.contains(DateTime(2027, 1, 1)), isTrue);
      expect(wrap.contains(DateTime(2027, 1, 31)), isTrue);
      expect(wrap.contains(DateTime(2026, 11, 30)), isFalse);
      expect(wrap.contains(DateTime(2027, 2, 1)), isFalse);

      final inside = parse(minimal()..['dates'] = {'from': '03-01', 'to': '03-31'}).pack.dates!;
      expect(inside.contains(DateTime(2026, 3, 1)), isTrue);
      expect(inside.contains(DateTime(2026, 3, 31)), isTrue);
      expect(inside.contains(DateTime(2026, 4, 1)), isFalse);

      final oneDay = parse(minimal()..['dates'] = {'from': '06-15', 'to': '06-15'}).pack.dates!;
      expect(oneDay.contains(DateTime(2026, 6, 15)), isTrue);
      expect(oneDay.contains(DateTime(2026, 6, 16)), isFalse);
    });
  });

  group('preview', () {
    test('accepts a safe relative .png path', () {
      expect(parse(minimal()..['preview'] = 'assets/preview.png').pack.previewPath, 'assets/preview.png');
    });

    test('rejects traversal, absolute paths, backslashes and non-PNG names', () {
      for (final preview in [
        '../preview.png',
        'a/../preview.png',
        './preview.png',
        '/preview.png',
        'C:/preview.png',
        r'a\preview.png',
        'a//preview.png',
        'preview.jpg',
        'preview.png/',
        '',
        '预览.png',
      ]) {
        final error = problem(minimal()..['preview'] = preview);
        expect(error.code, 'invalidPreview', reason: preview);
        expect(error.field, 'preview');
      }
      expect(problem(minimal()..['preview'] = 3).code, 'wrongType');
    });
  });

  group('JSON', () {
    test('rejects malformed UTF-8 JSON and non-objects', () {
      expect(
        () => parseThemePackJson([0xff, 0xfe]),
        throwsA(isA<ThemePackFormatException>().having((e) => e.code, 'code', 'badJson')),
      );
      expect(
        () => parseThemePackJson(utf8.encode('{')),
        throwsA(isA<ThemePackFormatException>().having((e) => e.code, 'code', 'badJson')),
      );
      expect(
        () => parseThemePackJson(utf8.encode('[]')),
        throwsA(isA<ThemePackFormatException>().having((e) => e.code, 'code', 'wrongType')),
      );
    });

    test('normalized output keeps what it represents', () {
      final pack = parse(christmasJson()).pack;
      final again = parseThemePackJson(encodeThemePackJson(pack)).pack;
      expect(again.id, pack.id);
      expect(again.name.zh, pack.name.zh);
      expect(again.name.en, pack.name.en);
      expect(again.accent, pack.accent);
      expect(again.neutralTint, pack.neutralTint);
      expect(again.highlight, pack.highlight);
      expect(again.capabilities.snow, isTrue);
      expect(again.capabilities.whaleHat, isTrue);
      expect(again.dates?.toDay, 26);
      expect(again.previewPath, 'preview.png');
    });
  });
}
