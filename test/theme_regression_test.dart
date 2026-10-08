// ═══════════════════════════════════════════════════════════════════════
//  主题回归测试 —— 锁死「深色主题真的生效」
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它
//
// 这个 bug 的全部特征是「**不报错**」：
//
// ```text
// 编译过 ✓   flutter analyze 0 error ✓   单测全绿 ✓   能跑起来 ✓
// → 但深色背景上写的是深色字，标题对比度 1.16:1，几乎看不见
// ```
//
// 所以**必须有测试盯住"主题角色到底是什么值"**，否则下次
// （比如 forui 升级换掉 material_ui）会以同样的方式静默回归。
//
// # 测什么
//
// ```text
// ① 两套 Material 不能混用：lib/ 下不允许再出现 flutter/material
// ② 真实树里 Theme.of 拿到深色（而不是兜底亮色）
// ③ 关键角色的对比度达 WCAG AA 4.5:1
// ④ forui 没填的角色，buildMaterialTheme 必须补上（不能是"同色"）
// ```
//
// ⚠️ ③ 是**像素级**的：直接算前景/背景的 WCAG 对比度，
//    不是断言"颜色等于某个常量"—— 后者会在换主题时假绿。

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/theme_bridge.dart';

/// WCAG 相对亮度
double _lum(Color c) {
  double f(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

/// WCAG 对比度
double contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  final forui = FTheme.neutral.dark.desktop;
  final theme = buildMaterialTheme(forui);
  final cs = theme.colorScheme;

  // 背景就是 forui 的 background（#0A0A0A）
  final bg = forui.colors.background;

  group('① 两套 Material 不能混用', () {
    test('lib/ 下不允许出现 package:flutter/material.dart', () {
      final offenders = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final src = e.readAsStringSync();
        if (src.contains("import 'package:flutter/material.dart'")) {
          offenders.add(e.path);
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: '这些文件用的是 flutter/material，而 shell.dart 用的是 '
            'material_ui —— 两套 Theme 是**不同的 InheritedWidget**，'
            '页面会静默拿到 Material 3 亮色兜底主题（标题对比度 1.16:1）。'
            '统一改成 package:material_ui/material_ui.dart。\n'
            '违规文件：\n  ${offenders.join('\n  ')}',
      );
    });

    /*
     * ★ 这条是补的（2026-09-23 反向验证时发现的漏洞）
     *
     * 我一开始把「桥接正确」当成「修好了」—— 但那是两件事：
     * `buildMaterialTheme()` 写得再对，只要 `shell.dart` 没用它，
     * app 里跑的仍然是裸 `toApproximateMaterialTheme()`。
     *
     * 实测证据：把 shell.dart 换回裸调用，上面 10 个断言**全绿** ——
     * 因为它们测的都是桥接函数本身。这类"测了但没测到真实路径"的
     * 假绿比没有测试更危险。
     */
    test('★ shell.dart 必须真的用 buildMaterialTheme()（不能只测函数本身）', () {
      final src = File('lib/shell.dart').readAsStringSync();

      expect(
        src.contains('buildMaterialTheme('),
        isTrue,
        reason: 'shell.dart 必须用 buildMaterialTheme() 而不是裸的 '
            'toApproximateMaterialTheme()，否则卡片底会等于背景色、'
            '边框会变成纯白（见 ui/theme_bridge.dart 的坑 ②）',
      );

      // 真实入口里不允许再出现裸调用（注释里提到不算）
      final codeLines = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('*') && !l.trimLeft().startsWith('//'));
      final bare = codeLines.where((l) => l.contains('toApproximateMaterialTheme()'));
      expect(
        bare,
        isEmpty,
        reason: '真实代码里不该再有裸的 toApproximateMaterialTheme()：\n'
            '  ${bare.join('\n  ')}',
      );
    });
  });

  group('② 真实树里拿到深色', () {
    testWidgets('MaterialApp > FTheme > FScaffold 里 Theme.of 是深色', (tester) async {
      Brightness? brightness;
      Color? onSurface;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(forui),
          builder: (context, child) => FTheme(
            data: forui,
            child: FToaster(child: child ?? const SizedBox()),
          ),
          home: FScaffold(
            child: Builder(
              builder: (ctx) {
                brightness = Theme.of(ctx).colorScheme.brightness;
                onSurface = Theme.of(ctx).colorScheme.onSurface;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      expect(brightness, Brightness.dark,
          reason: '拿到亮色 = 主题没生效（就是那个 1.16:1 的 bug）');
      expect(onSurface, const Color(0xFFFAFAFA));
    });
  });

  group('③ 关键角色对比度达 WCAG AA', () {
    test('正文 onSurface ≥ 4.5:1', () {
      final r = contrast(cs.onSurface, bg);
      expect(r, greaterThanOrEqualTo(4.5),
          reason: 'onSurface=${cs.onSurface} on bg=$bg → ${r.toStringAsFixed(2)}:1');
    });

    test('次要文字 onSurfaceVariant ≥ 4.5:1', () {
      final r = contrast(cs.onSurfaceVariant, bg);
      expect(r, greaterThanOrEqualTo(4.5),
          reason: 'onSurfaceVariant=${cs.onSurfaceVariant} → ${r.toStringAsFixed(2)}:1');
    });

    test('错误色 error ≥ 4.5:1', () {
      final r = contrast(cs.error, bg);
      expect(r, greaterThanOrEqualTo(4.5),
          reason: 'error=${cs.error} → ${r.toStringAsFixed(2)}:1');
    });

    test('★ 次要文字不能等于正文（层级必须存在）', () {
      expect(cs.onSurfaceVariant, isNot(cs.onSurface),
          reason: 'forui 没给 onSurfaceVariant，兜底 = onSurface —— '
              '用它画次要文字会和正文一样亮，视觉层级消失');
      final r = contrast(cs.onSurfaceVariant, bg);
      expect(r, lessThan(contrast(cs.onSurface, bg)),
          reason: '次要文字应该比正文暗一档');
    });
  });

  group('④ forui 留空的角色必须补上', () {
    test('★ surfaceContainerHighest 不能等于 surface', () {
      expect(cs.surfaceContainerHighest, isNot(cs.surface),
          reason: '兜底 = surface → UI 里 `surfaceContainerHighest@0.3` '
              '画出来的卡片底和背景一模一样，卡片看不见');
      // 卡片底要真的比背景亮，但不能太亮
      final r = contrast(cs.surfaceContainerHighest, cs.surface);
      expect(r, greaterThan(1.0),
          reason: '卡片底要能从背景里分辨出来');
      expect(r, lessThan(3.0),
          reason: '卡片底是"微微抬起"，不该是高对比色块');
    });

    test('★ outlineVariant 不能是纯白', () {
      final r = contrast(cs.outlineVariant, bg);
      expect(r, lessThan(5.0),
          reason: 'outlineVariant=${cs.outlineVariant} → ${r.toStringAsFixed(2)}:1。'
              '兜底 = onBackground = onSurface = #FAFAFA，是纯白 1px 亮线，太刺眼');
      expect(r, greaterThan(1.0), reason: '但也要看得见');
    });

    test('errorContainer 是"能当底"的暗色，不是实心红', () {
      expect(cs.errorContainer, isNot(cs.error));
      final r = contrast(cs.errorContainer, bg);
      expect(r, lessThan(4.5),
          reason: '它是背景不是前景，不该是高对比');
    });
  });

  group('⑤ 与修复前的对照（记录 bug 的实际数值）', () {
    test('兜底亮色主题的对比度确实只有 1.16:1', () {
      // Material 3 亮色 baseline 的 onSurface
      const lightOnSurface = Color(0xFF1D1B20);
      final r = contrast(lightOnSurface, bg);
      expect(r, lessThan(1.5),
          reason: '这正是 TV 截图里量到的 (29,27,32) 像素，'
              '对比度 ${r.toStringAsFixed(2)}:1 —— 远低于 4.5:1');
    });
  });
}
