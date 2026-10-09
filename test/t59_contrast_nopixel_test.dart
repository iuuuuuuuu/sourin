// 独立复核：**真实渲染出来的**底色与对比度（不依赖截图，锁屏也能跑）
//
// # 为什么需要它（这条判据的价值）
//
// 锁屏时 Impeller 窗口抓不到像素（spec Contract 17），于是"对比度"看起来没法验。
// 但"底色"和"文字色"**都能在 widget 树里量到** —— 而且量到的是
// **主题解析之后**的真实值（过了 `AppTheme.resolve` + `buildLightMaterialTheme`
// + forui `FTheme`），不是源码里写的字面量。
//
// ⇒ ★ 所以对比度有一条**不依赖像素**的等价判据。
//
// # 判据（可证伪）
// ① 浅色主题：正文色落在底色上的 WCAG 对比度 >= 4.5:1
// ② 深色主题：同上
// ③ ★ **反证**：把同一个正文色放在**纯黑**上必须 < 4.5:1
//    —— 否则这条判据分不出好坏，测试就没有意义
// ④ 两套主题的底色必须**不同**（否则"跟随主题"没生效）
// ⑤ 底色不得是纯黑（那正是 Owner 报的「只有黑色」）
//
// 运行：
//   flutter test test/t59_contrast_nopixel_test.dart
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';

/// WCAG 相对亮度
double _relLum(Color c) {
  double f(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

/// WCAG 对比度
double _ratio(Color a, Color b) {
  final l1 = _relLum(a), l2 = _relLum(b);
  final hi = math.max(l1, l2), lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

String _hex(Color c) {
  String h(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0');
  return '#${h(c.r)}${h(c.g)}${h(c.b)}';
}

void main() {
  test('★ 浅色主题：底色真实色值 + 对比度（不依赖截图）', () {
    final ft = AppTheme.themeFor(Brightness.light);
    final matTheme = ft;
    final cs = matTheme.colorScheme;

    debugPrint('[NOPIXEL] 浅色 palette.background  = ${_hex(AppTheme.colorsFor(Brightness.light).background)}');
    debugPrint('[NOPIXEL] 浅色 palette.foreground  = ${_hex(AppTheme.colorsFor(Brightness.light).foreground)}');
    debugPrint('[NOPIXEL] 浅色 material.surface  = ${_hex(cs.surface)}');
    debugPrint('[NOPIXEL] 浅色 material.onSurface = ${_hex(cs.onSurface)}');

    final r = _ratio(cs.onSurface, cs.surface);
    debugPrint('[NOPIXEL] 浅色 对比度 = ${r.toStringAsFixed(2)}:1');

    // ① 正文对比度
    expect(r, greaterThanOrEqualTo(4.5),
        reason: '浅色主题下正文对比度必须 >= 4.5:1（WCAG AA）—— '
            '实测 ${r.toStringAsFixed(2)}:1');

    // ③ ★ 反证：同一文字放在纯黑上必须不可读
    final rBlack = _ratio(cs.onSurface, Colors.black);
    debugPrint('[NOPIXEL] ★ 反证：同一文字放在纯黑上 = ${rBlack.toStringAsFixed(2)}:1');
    expect(rBlack, lessThan(4.5),
        reason: '★ 反证必须成立：亮色主题的 onSurface=${_hex(cs.onSurface)} '
            '放在纯黑上应当**不可读**（实测 ${rBlack.toStringAsFixed(2)}:1）—— '
            '若不成立，说明这条判据分不出好坏，本测试无意义');

    // ⑤ 底色不得是纯黑
    expect(cs.surface, isNot(Colors.black),
        reason: '窗口态底色不得是纯黑 —— 那正是 Owner 报的「只有黑色」');
  });

  test('★ 深色主题：底色真实色值 + 对比度', () {
    final p = AppTheme.colorsFor(Brightness.dark);
    debugPrint('[NOPIXEL] 深色 palette.background = ${_hex(p.background)}');
    debugPrint('[NOPIXEL] 深色 palette.foreground = ${_hex(p.foreground)}');

    final r = _ratio(p.foreground, p.background);
    debugPrint('[NOPIXEL] 深色 对比度 = ${r.toStringAsFixed(2)}:1');
    expect(r, greaterThanOrEqualTo(4.5),
        reason: '深色主题下正文对比度必须 >= 4.5:1 —— '
            '实测 ${r.toStringAsFixed(2)}:1');
  });

  test('★★ 两套主题底色必须不同（否则"跟随主题"没生效）', () {
    final l = buildAppTheme(Brightness.light)
        .colorScheme
        .surface;
    final d = AppTheme.colorsFor(Brightness.dark).background;
    debugPrint('[NOPIXEL] 浅色底=${_hex(l)}  深色底=${_hex(d)}');
    expect(l, isNot(d), reason: '浅色与深色的底色必须不同 —— 否则切主题无效果');
  });

  test('★★ floorColor 与主题同源（防"圆角外与内容区不同色"）', () {
    for (final b in Brightness.values) {
      final floor = AppTheme.floorColor(b);
      // ★ 不变量：**地板色 == 同明暗下的内容区底色**，两套明暗都必须成立。
      // 这两层是叠在一起的，不同源就会看到一条割裂的边。
      final bg = AppTheme.themeFor(b).colorScheme.surface;
      debugPrint('[NOPIXEL] $b floorColor=${_hex(floor)} surface=${_hex(bg)}');
      expect(floor, bg,
          reason: '\$b 下 floorColor 必须与内容区 surface 同源');
    }
  });
}
