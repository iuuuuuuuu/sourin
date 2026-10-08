// ═══════════════════════════════════════════════════════════════════════
//  任务㉑⑪ 搜索框的**设备门控**：TV 不给，手机给
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件
//
// 用户要求「支持搜索」，但**遥控器打不了字**。本仓库的设计注释早就承诺：
// > 所以 TV 不加搜索框（遥控器输入文字体验极差）
//    —— `test/episode_drawer_test.dart` 的三端说明
//
// ★ 但那份承诺**一直没被代码兑现**（我实测发现）：
// ```text
// 改之前 episode_strip.dart:1444
//   bool get _needsSearch => widget.episodes.length > kEpisodeSearchAfter;
//   ← 只看集数，没有任何设备门控
// 而手机与 TV 走的是【同一个】 EpisodeSheet(style: bottomSheet)
//   → 120 集的 TV 也会看到一个搜索框
// ```
//
// # 为什么"多一个搜索框"比"少一个控件"更糟
//
// `TextField` 会**吃掉方向键**（拿去移动光标）。TV 用户一旦把焦点落到
// 搜索框上，遥控器就**再也选不了集**了 —— 那比根本没有搜索框更难用。
// 所以这条门控不是"少给个功能"，是**防止一个能把 TV 卡死的控件**。
//
// # 判据用能力检测，不硬编码平台
//
// `Device.needsFocusRing`（= `isTv`）已经是本文件用了 6 处的既有判据
// （焦点环 / 回车键等），沿用它不会引入第二套"什么算 TV"的标准。
// ⚠️ 不能用 `!Device.isDesktop`：那会把**手机**也排除掉，而手机打字很方便。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/episode_strip.dart';

Episode _ep(int i) => Episode(id: 'ep-$i', title: '第 $i 集');
List<Episode> _eps(int n) => [for (var i = 1; i <= n; i++) _ep(i)];

/// 挂载**手机/TV 共用的那个** bottomSheet 形态
///
/// ★ 为什么直接挂 `EpisodeSheet` 而不是 `EpisodePanel`：
///   手机和 TV 用的是**同一个** `EpisodeSheet(style: bottomSheet)`
///   （见 `EpisodePanel.build` 的分流），所以它是**能力检测的收口点** ——
///   在这里断言，手机与 TV 两条路都被覆盖到，不会漏。
Future<void> _mountBottomSheet(
  WidgetTester t, {
  required int count,
}) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));

  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: EpisodeSheet(
          episodes: _eps(count),
          currentIndex: 0,
          onPick: (_) {},
          onClose: () {},
          asDialog: false,
          style: EpisodePanelStyle.bottomSheet,
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  tearDown(() => Device.overrideKind(null)); // 每例跑完还原，别污染别的测试

  group('任务㉑⑪ 搜索框按设备能力门控', () {
    testWidgets('★★ TV（遥控器）120 集 → **没有**搜索框', (t) async {
      Device.overrideKind(DeviceKind.tv);
      await _mountBottomSheet(t, count: 120);

      expect(
        find.byType(TextField),
        findsNothing,
        reason: '★★ TV **绝不能**有搜索框 —— 遥控器无法输入，'
            '而且 `TextField` 会吃掉方向键：TV 用户焦点一旦落上去，'
            '就再也选不了集（比没有搜索框更难用）。',
      );
    });

    testWidgets('★ 手机（触摸端）120 集 → **有**搜索框（用户要求）', (t) async {
      Device.overrideKind(DeviceKind.touchOnly);
      await _mountBottomSheet(t, count: 120);

      expect(
        find.byType(TextField),
        findsOneWidget,
        reason: '★ 用户明确要求「支持搜索」—— 手机打字很方便，'
            '绝不能因为给 TV 加门控而连带把手机的搜索也关掉。',
      );
    });

    testWidgets('★ 桌面 120 集 → 有搜索框', (t) async {
      Device.overrideKind(DeviceKind.desktop);
      await _mountBottomSheet(t, count: 120);

      expect(find.byType(TextField), findsOneWidget,
          reason: '★ 桌面是搜索功能的主场景（用户说的就是 PC）');
    });

    testWidgets('★ 集数 ≤ 30 时**任何**设备都不显示（阈值仍然有效）', (t) async {
      Device.overrideKind(DeviceKind.desktop);
      await _mountBottomSheet(t, count: 12);
      expect(find.byType(TextField), findsNothing,
          reason: '12 集的剧摆个搜索框是噪音 —— 阈值 $kEpisodeSearchAfter 仍要生效');
    });

    testWidgets('★ 手机在阈值边界上：30 集不显示、31 集显示', (t) async {
      Device.overrideKind(DeviceKind.touchOnly);

      await _mountBottomSheet(t, count: kEpisodeSearchAfter);
      expect(find.byType(TextField), findsNothing,
          reason: '恰好等于阈值时不显示（判据是 `>` 不是 `>=`）');

      await _mountBottomSheet(t, count: kEpisodeSearchAfter + 1);
      expect(find.byType(TextField), findsOneWidget,
          reason: '刚过阈值就要显示 —— 边界不能差一格');
    });
  });
}
