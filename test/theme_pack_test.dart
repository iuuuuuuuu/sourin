// ═══════════════════════════════════════════════════════════════════════
//  主题包测试 —— 格式、容错、内置主题的对比度
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件最要紧的一条是「**坏主题包不能���应用搞崩**」
//
// Owner 要的是「外部插件式主题」，也就是用户会自己写 JSON、自己从网上
// 抄一个。那么「JSON 写错了」不是异常情况，是**常规情况**。
// 一份坏主题包如果能让应用起不来，这个功能就是负资产。

import 'dart:convert';
import 'dart:io';

import 'dart:math' as math;

import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_palette.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

double _lum(Color c) {
  double f(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

double contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 把**半透明**的前景合成到不透明背景上，再算对比度。
///
/// ⚠️ 为什么必须有这一步：`border` 这类角色在深色主题里是「白 10%」
///    （`#1AFFFFFF`）—— 直接拿它的 RGB 算亮度会得到「白 vs 黑」的荒谬读数
///    （21:1），于是"描边太亮"这条判据永远测不出东西。
///    而屏幕上真正看到的是**合成后**的那个颜色。
Color over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

void main() {
  setUp(() {
    // 隔离：主题包目录必须指向临时目录，绝不能碰用户的真实数据目录
    ThemePackStore.debugSetDataDir(
        Directory.systemTemp.createTempSync('sourin_themepack_test').path);
  });

  group('① 容错：坏输入必须降级 + 警告，绝不抛异常', () {
    test('空字符串', () {
      final r = ThemePackStore.importFromString('');
      expect(r.warnings, isNotEmpty);
      expect(r.pack.palette, isNotNull);
    });

    test('根本不是 JSON', () {
      final r = ThemePackStore.importFromString('这不是 JSON');
      expect(r.warnings, isNotEmpty, reason: '必须给出警告而不是静默');
    });

    test('JSON 但是个数组（不是对象）', () {
      final r = ThemePackStore.importFromString('[1,2,3]');
      expect(r.warnings, isNotEmpty);
    });

    test('空对象 {} —— 每个字段都缺', () {
      final r = ThemePackStore.importFromString('{}');
      // 全部字段缺失 = 全部用默认值，不该有任何"非法"警告
      expect(r.warnings.where((w) => w.contains('不是合法')),
          isEmpty,
          reason: '缺字段不是错误（用户只想换个名字也不行？），不该刷警告');
      expect(r.pack.palette, isNotNull);
    });

    test('★ 颜色值是垃圾 —— 那一项回落，其余照常', () {
      final r = ThemePackStore.importFromString(jsonEncode({
        'name': '半坏',
        'brightness': 'dark',
        'colors': {
          'primary': 'not-a-color', // 坏
          'background': '#101010', // 好
        },
      }));
      expect(r.warnings.where((w) => w.contains('primary')), isNotEmpty,
          reason: '必须点名是哪个字段坏了');
      expect(r.pack.palette.primary, isNot(const Color(0xFF101010)),
          reason: 'primary 坏了就该回落默认值');
      expect(r.pack.palette.background, const Color(0xFF101010),
          reason: '★ 没坏的那个字段必须照常生效 —— 不能"一个坏全盘丢"');
    });

    test('亮度写错 → 警告 + 按底色亮度推断', () {
      final r = ThemePackStore.importFromString(jsonEncode({
        'name': 'x',
        'brightness': 'purple', // 不存在的
        'colors': {'background': '#F0F0F0'}, // 亮底
      }));
      expect(r.warnings.where((w) => w.contains('brightness')), isNotEmpty);
      expect(r.pack.brightness, Brightness.light,
          reason: '写错了就该按底色亮度推断，而不是默认深色');
    });

    test('radius 超出范围 → 忽略 + 警告（不能画出一个 1000px 圆角）', () {
      final r = ThemePackStore.importFromString(
          '{"name":"x","brightness":"dark","radius":9999}');
      expect(r.warnings.where((w) => w.contains('radius')), isNotEmpty);
      expect(r.pack.radius, isNull, reason: '非法的 radius 不能被采纳');
    });

    test('buttonPadding 缺一半 → 忽略整项 + 警告', () {
      final r = ThemePackStore.importFromString(jsonEncode({
        'name': 'x',
        'brightness': 'dark',
        'buttonPadding': {'horizontal': 12}, // 缺 vertical
      }));
      expect(r.warnings.where((w) => w.contains('buttonPadding')), isNotEmpty);
      expect(r.pack.buttonPadding, isNull);
    });

    test('版本比本应用新 → 警告但仍可用', () {
      final r = ThemePackStore.importFromString(
          '{"version":9999,"name":"未来","brightness":"dark"}');
      expect(r.warnings.where((w) => w.contains('版本')), isNotEmpty);
      expect(r.pack.name, '未来', reason: '名字该照常读出来');
    });

    test('id / name 是空白串 → 用兜底值，不产生空 id', () {
      final r = ThemePackStore.importFromString(
          '{"id":"  ","name":"","brightness":"dark"}');
      expect(r.pack.id, isNotEmpty);
      expect(r.pack.name.trim(), isNotEmpty);
    });
  });

  group('② 往返：导出的 JSON 必须能被自己读回来', () {
    test('每套内置主题 round-trip 后逐色一致', () {
      for (final p in ThemePackStore.builtins) {
        final r = ThemePackStore.importFromString(jsonEncode(p.toJson()));
        expect(r.warnings, isEmpty,
            reason: '「${p.name}」导出的 JSON 自己读不回来，警告：${r.warnings}');
        expect(r.pack.palette.background, p.palette.background,
            reason: '「${p.name}」background 往返不一致');
        expect(r.pack.palette.primary, p.palette.primary,
            reason: '「${p.name}」primary 往返不一致');
        expect(r.pack.brightness, p.brightness);
        expect(r.pack.name, p.name);
      }
    });
  });

  group('③ 内置主题的对比度（每一套都要过 WCAG AA）', () {
    for (final p in ThemePackStore.builtins) {
      test('${p.name}（${p.brightness.name}）正文 ≥ 4.5:1', () {
        final r = contrast(p.palette.foreground, p.palette.background);
        expect(r, greaterThanOrEqualTo(4.5),
            reason: '「${p.name}」正文只有 ${r.toStringAsFixed(2)}:1');
      });

      test('${p.name} 次要文字 ≥ 3:1', () {
        final r = contrast(p.palette.mutedForeground, p.palette.background);
        expect(r, greaterThanOrEqualTo(3.0),
            reason: '「${p.name}」次要文字只有 ${r.toStringAsFixed(2)}:1');
      });

      test('${p.name} 主色按钮 ≥ 4.5:1', () {
        final r = contrast(p.palette.primaryForeground, p.palette.primary);
        expect(r, greaterThanOrEqualTo(4.5),
            reason: '「${p.name}」按钮 ${r.toStringAsFixed(2)}:1 —— '
                '这正是"纯色药丸看不见字"那类缺陷');
      });

      test('${p.name} 卡片底能从背景里分辨出来', () {
        final r = contrast(over(p.palette.card, p.palette.background),
            p.palette.background);
        expect(r, greaterThan(1.02),
            reason: '「${p.name}」卡片底 == 背景 ⇒ 卡片消失');
        expect(r, lessThan(3.0),
            reason: '「${p.name}」卡片底对比 ${r.toStringAsFixed(2)}:1 ⇒ 太重');
      });

      test('${p.name} 描边看得见但不刺眼', () {
        // ★ 必须先合成：深色主题的 border 是半透明白，直接算会得到假读数
        final solid = over(p.palette.border, p.palette.background);
        final r = contrast(solid, p.palette.background);
        expect(r, greaterThan(1.10),
            reason: '「${p.name}」合成后的描边只有 ${r.toStringAsFixed(3)}:1 '
                '⇒ 卡片/输入框的边界在屏幕上几乎看不出来');
        expect(r, lessThan(3.0),
            reason: '「${p.name}」描边 ${r.toStringAsFixed(2)}:1 ⇒ 太亮，会变成刺眼亮线');
      });
    }
  });

  group('④ 内置主题清单', () {
    test('至少 5 套，且第一套是深色（默认值）', () {
      expect(ThemePackStore.builtins.length, greaterThanOrEqualTo(5));
      expect(ThemePackStore.builtins.first.brightness, Brightness.dark,
          reason: '★ 默认必须是深色 —— Owner 深夜用，且交付实测的截图都是深色');
    });

    test('id 唯一（重复 id 会让选择落在错误的���一套上）', () {
      final ids = ThemePackStore.builtins.map((p) => p.id).toSet();
      expect(ids.length, ThemePackStore.builtins.length);
    });

    test('全部标记为 builtin（不可删除）', () {
      expect(ThemePackStore.builtins.every((p) => p.builtin), isTrue);
    });

    test('明暗两套都有（否则浅色系统下没得选）', () {
      expect(ThemePackStore.builtins.any((p) => p.brightness == Brightness.light),
          isTrue);
      expect(ThemePackStore.builtins.any((p) => p.brightness == Brightness.dark),
          isTrue);
    });
  });

  group('⑤ 存取与选择', () {
    test('内置主题在未选任何包时也全部可用（loadAll 不用等异步）', () {
      final all = ThemePackStore.loadAll();
      expect(all.length, greaterThanOrEqualTo(ThemePackStore.builtins.length));
    });

    test('选中 id 能被记住', () {
      ThemePackStore.select('builtin.forest');
      expect(ThemePackStore.selectedId, 'builtin.forest');
      expect(ThemePackStore.current().id, 'builtin.forest');
    });

    test('选中的 id 不存在时回落到第一套（不崩、不空白）', () {
      ThemePackStore.select('builtin.does-not-exist');
      expect(ThemePackStore.current().id, ThemePackStore.builtins.first.id);
    });

    test('删除内置主题包会被拒绝', () {
      expect(ThemePackStore.delete(ThemePackStore.builtins.first), isFalse);
    });

    test('导入的文件会落盘并出现在列表里', () {
      // ⚠️ 必须是 `<root>/themes/` —— `ThemePackStore.dir` 会在注入的目录
      //    **下面**再建一层 `themes/`，少这一层就等于把文件放到了
      //    目录外面（实测：loadAll 读不到，报"好包必须仍然被读出来"）。
      final root = Directory.systemTemp.createTempSync('sourin_themepack_file');
      // ⚠️ 必须**自己注入**这个 root：`importFromFile` 落到
      //    `ThemePackStore.dir`（= 注入目录下的 themes/），而 setUp 注入的是
      //    另一个临时目录 ⇒ 文件会落到 setUp 那棵树上，本用例当然找不到。
      ThemePackStore.debugSetDataDir(root.path);
      final dir = Directory('${root.path}${Platform.pathSeparator}themes')
        ..createSync(recursive: true);
      final src = File('${dir.path}/my-theme.json')
        ..writeAsStringSync(jsonEncode({
          'name': '我的主题',
          'brightness': 'dark',
          'colors': {'primary': '#8ED9A8'},
        }));

      final r = ThemePackStore.importFromFile(XFile(src.path));
      expect(r.warnings, isEmpty);

      final all = ThemePackStore.loadAll();
      final found = all.where((p) => p.id == 'my-theme').firstOrNull;
      expect(found, isNotNull, reason: '导入后必须能在列表里找到');
      expect(found!.name, '我的主题');
      expect(found.builtin, isFalse, reason: '外部包不是内置的，可以删');

      // 删掉它
      expect(ThemePackStore.delete(found), isTrue);
      expect(ThemePackStore.loadAll().where((p) => p.id == 'my-theme'), isEmpty);
    });

    test('★ 目录不可写 / 不可枚举 ⇒ 降级成「只有内置主题」，不抛异常', () {
      // polish agent 在合并前提出的一个真问题：主题页是**保活 tab**，
      // 可能��数据目录解析完成前就被打开，而 `loadAll()` 是同步的。
      // 那条路径没有覆盖 —— 而它恰好是最容易崩的地方。
      //
      // 期望行为（已写进实现，这里把它钉住）：
      //   目录建不出来 / 列不出来 ⇒ **只用内置主题**，绝不抛。
      //   理由：主题包是「锦上添花」。因为磁盘上一个只读目录就让应用
      //   起不来，是不可接受的 —— 而内置主题永远在。
      ThemePackStore.debugSetDataDir('/proc/definitely-not-writable/x');
      final all = ThemePackStore.loadAll();
      expect(all.length, ThemePackStore.builtins.length,
          reason: '拿不到外部包时应当恰好剩下内置的那几套');
      expect(all.every((p) => p.builtin), isTrue);

      // 选中一个不存在的包也不该崩
      ThemePackStore.select('whatever');
      expect(ThemePackStore.current().id, ThemePackStore.builtins.first.id);

      // 往不可写目录导入也不该抛（只是文件没落地）
      final r = ThemePackStore.importFromString(
          '{"name":"临时","brightness":"dark"}');
      expect(r.pack.name, '临时', reason: '导入本身仍然可用，只是不落盘');
    });

    test('★ 目录里的坏文件不能让 loadAll 抛异常', () {
      final root = Directory.systemTemp.createTempSync('sourin_themepack_bad');
      final dir = Directory('${root.path}${Platform.pathSeparator}themes')
        ..createSync(recursive: true);
      ThemePackStore.debugSetDataDir(root.path);
      File('${dir.path}/ok.json')
          .writeAsStringSync('{"name":"好包","brightness":"dark"}');
      File('${dir.path}/broken.json').writeAsStringSync('{这不是 JSON');
      File('${dir.path}/empty.json').writeAsStringSync('');
      // 非 json 后缀的文件必须被忽略（否则 users 目录里随便一个文件都会进列表）
      File('${dir.path}/notes.txt').writeAsStringSync('随便什么');

      final all = ThemePackStore.loadAll();
      expect(all.any((p) => p.id == 'ok'), isTrue,
          reason: '好包必须仍然被读出来');
      expect(all.where((p) => !p.builtin).length, 1,
          reason: '只有 ok.json 该进来（其余要么解析失败被降级，要么非 json 被忽略）');
    });
  });
}
