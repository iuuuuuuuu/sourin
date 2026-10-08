// ═══════════════════════════════════════════════════════════════════════
//  任务⑰⑤：播放页转场的「白色条」不再盖住顶部操作条
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > 进播放页面的时候这个白色条会把顶部的操作条给覆盖掉,
// > 这个动画不太好看,有点影响观感
//
// # 根因（读 Flutter / material_ui 源码确认）
//
// Windows 的默认转场是 `ZoomPageTransitionsBuilder`
//（`material_ui-1.4.0/lib/src/page_transitions_theme.dart` 的
//  `_defaultBuilders`），它会用
// `backgroundColor ?? Theme.of(context).colorScheme.surface` 铺一层 **scrim**：
// ```dart
// final Color enterTransitionBackgroundColor =
//     backgroundColor ?? Theme.of(context).colorScheme.surface;
// ```
// 那层色块铺满**离场路由**（含顶部操作条）→ 就是用户看到的"白色条"。
//
// # 本测试怎么证明修好了（不看动画，直接读颜色）
//
// ```text
// 修复前  backgroundColor == null → 兜底 ColorScheme.surface（不透明）
// 修复后  backgroundColor == Colors.transparent → alpha == 0
// ```
// "scrim 的 alpha == 0"是这条缺陷的**定义**：只要它不透明，就一定会盖住
// 下面的东西，与具体主题色值无关。
//
// ⚠️ 不断言"像素里没有白色"：那依赖具体主题色值和渲染时机，
//    容易变成"跟着实现改"的假测试。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/theme_bridge.dart';

void main() {
  group('任务⑰⑤ 转场 scrim 不得盖住顶部操作条', () {
    test('Windows/Linux 仍用 Zoom 转场，但 scrim 被显式设为透明', () {
      final t = buildPageTransitionsTheme();

      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        final b = t.builders[platform];
        expect(
          b,
          isA<ZoomPageTransitionsBuilder>(),
          reason: '$platform 仍应是 Zoom 转场'
              '（我们只去掉那层 scrim，不取消用户的缩放淡入动画）',
        );

        final bg = (b! as ZoomPageTransitionsBuilder).backgroundColor;
        expect(
          bg,
          isNotNull,
          reason: '$platform 必须**显式**给 backgroundColor —— '
              '留 null 会兜底成 ColorScheme.surface（不透明），'
              '那正是用户报的"白色条"',
        );
        expect(
          bg!.a,
          0.0,
          reason: '$platform 的 scrim 必须完全透明，'
              '否则它会铺满离场路由、盖住顶部操作条',
        );
        expect(bg, Colors.transparent);
      }
    });

    test('默认（不设 pageTransitionsTheme）确实会兜底成不透明 —— 证明这个修复有必要', () {
      // 反证：如果不做这个修复，Zoom 的 backgroundColor 就是 null，
      // 运行时会兜底成 colorScheme.surface（不透明）→ 白条出现。
      const raw = ZoomPageTransitionsBuilder();
      expect(
        raw.backgroundColor,
        isNull,
        reason: 'ZoomPageTransitionsBuilder 默认 backgroundColor 为 null，'
            '运行时兜底成不透明的 surface —— 这就是缺陷的机制',
      );
    });
  });
}
