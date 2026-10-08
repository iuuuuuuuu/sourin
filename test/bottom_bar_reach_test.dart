// ═══════════════════════════════════════════════════════════════════════
//  底栏可达性 —— 遥控器能不能换页
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的是什么（2026-09-23 实测抓到的真 bug）
//
// TV 上连按 `↓`，焦点轨迹：
// ```text
// #1 (12,469,199,540)   底栏第 1 个 tab
// #2 (36,202,184,468)   海报行
// #3 (36,101,184,367)   海报行（滚动后）
// #4..#6 在两个矩形间来回
// #7 (12,469,199,540)   ← 绕回底栏
// #8..#16 (12,469,199,540)  停住
// ```
// 前半段是"在内容里绕圈"，**底栏是切换 tab 的唯一入口**，
// 到不了底栏就等于**用户被困在首页**。
//
// # 两个根因（都已修）
//
// ## ① 底栏被交叉轴阈值挡在外面
//
// `↓` 时交叉轴（横向）上限是 `VERTICAL_CROSS_LIMIT = 360`。
// 底栏 tab 中心 x ≈ 960（屏幕中点），而源条 pill 中心 x ≈ 105：
// ```text
// cross = |960 - 105| = 855 > 360  -> 底栏永远进不了候选
// ```
// 修法照抄原版：**两轮搜索** —— 先在内容区找，找不到才允许落底栏。
//
// ## ② 底栏下面还有内容 → 绕圈
//
// 候选按 y 排序一眼可见：
// ```text
//  271,  36-148x266    海报行 1
//  469,  12-187x71     底栏 5 个 tab
//  605,  36-148x266    海报行 2（在底栏值域下方，因为它是浮着的）
// ```
// 从底栏按 ↓ 会找到 y=605 的海报 —— 于是形成环。
//
// 原版的规则（`spatialNav.ts` L788-793）：
// ```js
// if (dir === "down" && curInTabbar && !nextInTabbar) return;  // 不动
// ```
// > 底栏在视觉上永远是最底部的一排，它下面**不该有任何东西**。
// > ⚠️ 只拦 ↓（不拦 ↑）—— 从底栏按 ↑ 回到内容区是**符合直觉**的。
//
// # ⚠️ 为什么用**结构标记**而不是几何判断
//
// 我第一版用"矩形底边在屏幕最下方 15% 内"认底栏，在 960x540 的 TV 上
// 阈值 = 459，而一张 `(36,202,184,468)` 的**海报卡** bottom=468 > 459
// —— **误判**。原版用的是 `c.el.closest(".tabbar")`（结构判据），
// 永远不会因为屏幕尺寸而判错。这里用 `BottomBarMarker` 照做。
//
// 教训：**几何阈值在不同分辨率/布局下必然出错**。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('底栏可达性（静态断言真实路径）', () {
    late String nav;
    late String shell;

    setUpAll(() {
      nav = File('lib/ui/spatial_nav.dart').readAsStringSync();
      shell = File('lib/shell.dart').readAsStringSync();
    });

    test('★ 必须有底栏结构标记（不能用几何判断）', () {
      expect(
        nav.contains('class BottomBarMarker'),
        isTrue,
        reason: '必须用结构标记认底栏 —— 几何阈值（"在屏幕下方 X%"）'
            '实测在 960x540 上把海报卡误判成底栏。',
      );
      expect(
        nav.contains('el.widget is BottomBarMarker'),
        isTrue,
        reason: '`_isInBottomBar` 必须向上找 `BottomBarMarker` 祖先，'
            '等价于原版的 `el.closest(".tabbar")`。',
      );
      expect(
        shell.contains('BottomBarMarker('),
        isTrue,
        reason: 'shell 必须真的把底栏包进 `BottomBarMarker` —— '
            '否则标记是空的，判定永远为 false。',
      );
    });

    test('★ ↓ 必须两轮搜索：先在内容区找，找不到才落底栏', () {
      expect(
        nav.contains('exclude: (c) => _isInBottomBar(c.node)'),
        isTrue,
        reason: '第一轮必须**排除底栏**只在内容区找 —— '
            '照抄原版 `findNeighbor(cur, pool, dir, inTabbar)`。',
      );
      expect(
        nav.contains('内容区没邻居 -> 允许落底栏'),
        isTrue,
        reason: '第一轮找不到时必须有第二轮（不带排除）—— '
            '否则底栏会被 `crossLimit` 永久挡在外面（实测 cross=855 > 360）。',
      );
    });

    test('★ 底栏是最后一行：从底栏按 ↓ 不动（防绕圈）', () {
      expect(
        nav.contains('已在底栏 + 目标是内容区 -> 不动'),
        isTrue,
        reason: '必须拦住"从底栏往下走进内容区"—— 否则焦点成环，'
            '用户按 16 次 ↓ 都停不下来（实测过）。'
            '原版：`if (dir === "down" && curInTabbar && !nextInTabbar) return;`',
      );
      expect(
        nav.contains('curInBottomBar && !_isInBottomBar(best.node)'),
        isTrue,
        reason: '守卫条件必须是"当前在底栏 且 目标不在底栏" —— '
            '只拦 ↓（不拦 ↑），因为从底栏按 ↑ 回内容区符合直觉。',
      );
    });

    test('★ 找不到邻居时不绕回第一个', () {
      expect(
        nav.contains('没有可用邻居 -> 不动（不绕回）'),
        isTrue,
        reason: '原版注释：「否则 → 什么都不做（**不要绕回第一个，那很晕**）」。',
      );
    });
  });
}
