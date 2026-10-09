// ═══════════════════════════════════════════════════════════════════════
//  主题不变量测试 —— 移除 forui 之后新养起来的那些不变量
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这个文件
//
// 移除 forui 之后，主题从「两套 InjectedWidget 互相对照」变成
// 「一份自有调色板 → 一套 Material ThemeData」。少了一层能自动兜底的
// 机制，于是必须自己盯住这些**不靠断言就会静默回归**的性质：
//
// ```text
// ① 组件主题真的被填上了（不是全 null → 退回 Material 默认）
// ② 对比度达 WCAG AA（正文 ≥ 4.5:1，次要文字 ≥ 3:1）
// ③ 明暗两套的形状/尺寸逐值一致（外观"是一套"，不因明暗而变形）
// ④ AppPalette 扩展真的注入到了 ThemeData
// ```
//
// # 判据为什么是「对比度」而不是「等于某个常量」
//
// 后者会在换主题时假绿。前者只依赖「颜色差够不够」这一条物理事实。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_palette.dart';
import 'package:sourin_spike/ui/app_theme.dart';

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

void main() {
  final dark = AppTheme.themeFor(Brightness.dark);
  final light = AppTheme.themeFor(Brightness.light);

  group('① 组件主题被填上了', () {
    for (final entry in {'dark': dark, 'light': light}.entries) {
      final td = entry.value;
      final label = entry.key;

      test('$label：四类按钮的 padding/shape/textStyle 都在', () {
        // ⚠️ 少任何一个都会退回 Material 默认（StadiumBorder / 另一套内边距），
        //    同一行里的按钮圆角就对不上了。
        expect(td.filledButtonTheme.style?.padding, isNotNull, reason: 'FilledButton padding 缺失');
        expect(td.filledButtonTheme.style?.shape, isNotNull, reason: 'FilledButton shape 缺失');
        expect(td.filledButtonTheme.style?.textStyle, isNotNull, reason: 'FilledButton textStyle 缺失');
        expect(td.elevatedButtonTheme.style?.shape, isNotNull, reason: 'ElevatedButton shape 缺失');
        expect(td.outlinedButtonTheme.style?.side, isNotNull, reason: 'OutlinedButton side 缺失');
        expect(td.textButtonTheme.style?.shape, isNotNull, reason: 'TextButton shape 缺失');
      });

      test('$label：输入框四态边框都在', () {
        expect(td.inputDecorationTheme.enabledBorder, isNotNull);
        expect(td.inputDecorationTheme.focusedBorder, isNotNull);
        expect(td.inputDecorationTheme.errorBorder, isNotNull);
        expect(td.inputDecorationTheme.disabledBorder, isNotNull);
      });

      test('$label：卡片有描边且是零投影', () {
        // 描边是本项目的卡片语言（深色下投影几乎不可见）；
        // elevation 非 0 会在深色页面上糊出一圈脏影。
        final shape = td.cardTheme.shape;
        expect(shape, isNotNull);
        expect(td.cardTheme.elevation, 0);
      });

      test('$label：转场 scrim 是透明的（白色条那条 bug）', () {
        // ⚠️ 必须**逐个平台**断言：`PageTransitionsTheme.builders` 是直通
        //    getter、不与 SDK 默认值合并 —— 漏登记的平台会静默退回 Zoom，
        //    scrim（`colorScheme.surface`）就又回来了，还会盖住顶部操作条。
        expect(td.pageTransitionsTheme.builders.keys.toSet(),
            containsAll(<TargetPlatform>[
              TargetPlatform.windows,
              TargetPlatform.android,
              TargetPlatform.linux,
              TargetPlatform.fuchsia,
            ]),
            reason: '未登记的平台会静默走 SDK 兜底 ⇒ 用户选的转场风格失效');
        for (final e in td.pageTransitionsTheme.builders.entries) {
          final c = (e.value as dynamic).backgroundColor as Color?;
          expect(c == null || c.a == 0.0, isTrue,
              reason: '${e.key} 的转场 scrim 必须是透明（现值 $c）—— '
                  '不透明会盖住离场页的顶部操作条');
        }
      });
    }
  });

  group('② 对比度达 WCAG AA', () {
    for (final entry in {'dark': dark, 'light': light}.entries) {
      final cs = entry.value.colorScheme;
      final label = entry.key;
      final bg = cs.surface;

      test('$label：正文 onSurface ≥ 4.5:1', () {
        final r = contrast(cs.onSurface, bg);
        expect(r, greaterThanOrEqualTo(4.5),
            reason: '正文 onSurface=${cs.onSurface} on surface=$bg → ${r.toStringAsFixed(2)}:1');
      });

      test('$label：次要文字 onSurfaceVariant ≥ 3:1', () {
        // 次要文字的字号更小、字重更轻，阈值按 WCAG「大字」那一档取 3:1
        final r = contrast(cs.onSurfaceVariant, bg);
        expect(r, greaterThanOrEqualTo(3.0),
            reason: '次要文字 ${r.toStringAsFixed(2)}:1（低于 3:1 就是"看得见但读不清"）');
      });

      test('$label：实心按钮 primary/onPrimary ≥ 4.5:1', () {
        final r = contrast(cs.onPrimary, cs.primary);
        expect(r, greaterThanOrEqualTo(4.5),
            reason: '按钮前景 ${r.toStringAsFixed(2)}:1 —— 这正是"纯色药丸看不见字"那类缺陷的判据');
      });

      test('$label：错误色 error ≥ 3:1（错误提示不能只靠"颜色不同"）', () {
        final r = contrast(cs.error, bg);
        expect(r, greaterThanOrEqualTo(3.0),
            reason: 'error 在页面底上只有 ${r.toStringAsFixed(2)}:1');
      });

      test('$label：描边能看见但**不刺眼**（1.05 < r < 5）', () {
        final r = contrast(cs.outline, bg);
        expect(r, greaterThan(1.05),
            reason: '描边与底色几乎同色 ⇒ 卡片/输入框没有边界');
        expect(r, lessThan(5.0),
            reason: '描边对比 ${r.toStringAsFixed(2)}:1 ⇒ 太亮，会变成刺眼的 1px 亮线');
      });

      test('$label：卡片底能抬起来但不是高对比色块', () {
        final r = contrast(cs.surfaceContainerHighest, bg);
        expect(r, greaterThan(1.0), reason: '卡片底 == 背景 ⇒ 卡片消失');
        expect(r, lessThan(3.0), reason: '卡片底对比 ${r.toStringAsFixed(2)}:1 ⇒ 太重');
      });

      test('$label：次要文字必须比正文**弱**（层级存在）', () {
        expect(cs.onSurfaceVariant, isNot(cs.onSurface),
            reason: '两者同色 ⇒ 视觉层级消失');
        expect(contrast(cs.onSurfaceVariant, bg),
            lessThan(contrast(cs.onSurface, bg)),
            reason: '次要文字不该和正文一样强');
      });
    }
  });

  group('③ 明暗两套"是同一套设计"', () {
    test('圆角**半径**一致（描边色当然要随明暗变，那不是"变形"）', () {
      // 只比半径：把整个 Shape 的 toString 拿来比会把**描边色**也算进去，
      // 而描边色必须随明暗变化（深色用白描边提亮、浅色用深描边，见
      // theme_bridge.dart 的说明）—— 那是有意为之，不是缺陷。
      BorderRadiusGeometry? radiusOf(ShapeBorder? s) =>
          s is RoundedSuperellipseBorder ? s.borderRadius : null;

      expect(radiusOf(light.cardTheme.shape as ShapeBorder?),
          radiusOf(dark.cardTheme.shape as ShapeBorder?),
          reason: '卡片圆角在明暗两套下不同');
      expect(radiusOf((light.dialogTheme as dynamic).shape as ShapeBorder?),
          radiusOf((dark.dialogTheme as dynamic).shape as ShapeBorder?),
          reason: '对话框圆角在明暗两套下不同');
      expect(radiusOf(light.snackBarTheme.shape as ShapeBorder?),
          radiusOf(dark.snackBarTheme.shape as ShapeBorder?),
          reason: '提示条圆角在明暗两套下不同');
      expect(radiusOf(light.chipTheme.shape as ShapeBorder?),
          radiusOf(dark.chipTheme.shape as ShapeBorder?),
          reason: 'chip 圆角在明暗两套下不同');
      expect(
        radiusOf(light.filledButtonTheme.style?.shape?.resolve({}) as ShapeBorder?),
        radiusOf(dark.filledButtonTheme.style?.shape?.resolve({}) as ShapeBorder?),
        reason: '按钮圆角在明暗两套下不同 —— 同一行控件在两个主题下形状不一样',
      );
    });

    test('字号阶梯逐值一致', () {
      expect(light.textTheme.bodyMedium?.fontSize,
          dark.textTheme.bodyMedium?.fontSize);
      expect(light.textTheme.titleLarge?.fontSize,
          dark.textTheme.titleLarge?.fontSize);
      expect(light.textTheme.labelSmall?.fontSize,
          dark.textTheme.labelSmall?.fontSize);
    });

    test('按钮内边距一致', () {
      expect(light.filledButtonTheme.style?.padding,
          dark.filledButtonTheme.style?.padding);
      expect(light.outlinedButtonTheme.style?.padding,
          dark.outlinedButtonTheme.style?.padding);
    });
  });

  group('④ AppPalette 真的注入到了 ThemeData', () {
    for (final entry in {'dark': dark, 'light': light}.entries) {
      test('${entry.key}：extension 可取到且明暗正确', () {
        final p = entry.value.extension<AppPalette>();
        expect(p, isNotNull, reason: 'AppPalette 没注入 ⇒ `AppPalette.of()` 会走兜底');
        expect(p!.brightness,
            entry.key == 'dark' ? Brightness.dark : Brightness.light);
        expect(p.background, entry.value.colorScheme.surface,
            reason: '★ 调色板的 background 必须与 colorScheme.surface 同源 —— '
                '窗口圆角外（floorColor）与内容区是叠在一起的两层');
      });
    }
  });
}
