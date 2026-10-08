// ═══════════════════════════════════════════════════════════════════════
//  任务㉑⑪ 选集：PC 右侧抽屉 + 自动滚到当前集 + 搜索
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > 这个选集,我希望pc操作是点击然后**右侧出现抽屉**进行选集,
// > 如果有上百集,我希望**自动滚动到当前所观看的集的位置**,
// > 并且**支持搜索**。手机和tv你自己想想交互
//
// # 三端设计（我的判断 + 理由）
//
// ```text
// PC    右侧抽屉 + 搜索        ← 用户明确要求
//        · 贴右边，不挡画面主体（居中弹窗挡的正是用户最想看的中间）
//        · 限宽 380（4 列集号胶囊），再宽就开始挡主体
//        · 全高，像一条真正的侧栏
// 手机  保持底部抽屉           ← 手指从下往上够得着；
//        · 手机上"右侧抽屉"要横跨拇指行程，够不到右边
// TV    保持横向一行 + 分卷弹出 ← 遥控器走 500 集要按 500 次，
//        · 网格还要额外算上下行，比横向一行更糟
//        · TV 不加搜索框（遥控器输入文字体验极差）
// ```
//
// # ★★ “TV 不加搜索框”这一条，上一版**只是口号**（已修）
//
// 写下上面那张表时，`_needsSearch` 其实**只看集数**：
// ```dart
// bool get _needsSearch => widget.episodes.length > kEpisodeSearchAfter;
// ```
// 而手机和 TV 走的是**同一个** `EpisodeSheet(style: bottomSheet)`，
// 所以 120 集的 TV **也会看到一个搜索框** —— 而遥控器打不了字。
// 更糟的是 `TextField` 会**吃掉方向键**：TV 用户焦点一旦落上去，
// 就再也选不了集。**一个能把 TV 卡死的控件，比没有更难用。**
//
// 现在真的做了门控（`episode_strip.dart::_needsSearch` 加了
// `&& !Device.needsFocusRing`），并由**专门的测试**钉住：
// ```text
// test/episode_search_platform_test.dart
//   TV     120 集 → TextField = 0
//   手机   120 集 → TextField = 1
//   桌面   120 集 → TextField = 1
// ```
// ★ 以后改 `_needsSearch` 时跑那个文件 —— 它会在门控被摘掉时变红。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/episode_strip.dart';

Episode ep(int i) => Episode(
      id: 'ep-$i',
      title: i % 7 == 0 ? '特别篇 $i' : '第 $i 集',
    );

/// 造 [n] 集（从 1 开始编号）
List<Episode> eps(int n) => [for (var i = 1; i <= n; i++) ep(i)];

/// 挂载面板并返回（可控 isDesktop）
Future<void> mount(
  WidgetTester tester, {
  required int count,
  required int currentIndex,
  required bool isDesktop,
  void Function(Episode)? onPick,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: EpisodePanel(
          episodes: eps(count),
          currentIndex: currentIndex,
          onPick: onPick ?? (_) {},
          onClose: () {},
          isDesktopOverride: isDesktop,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('任务㉑⑪ PC：必须是**右侧抽屉**（用户要求）', () {
    testWidgets('★ 桌面形态下，面板贴在窗口右侧', (tester) async {
      await mount(tester, count: 40, currentIndex: 0, isDesktop: true);

      // 面板的白色盒子 = 最外层那个宽 380 的 Container
      final boxes = find.byType(Container).evaluate().where((e) {
        final w = e.renderObject;
        return w is RenderBox && w.hasSize && w.size.width > 300;
      }).toList();
      expect(boxes, isNotEmpty, reason: '找不到面板容器 —— 测试是空的');

      final box = boxes.last.renderObject! as RenderBox;
      final panelRight = box.localToGlobal(Offset(box.size.width, 0)).dx;
      /*
       * ⚠️ 视口宽度**不要**从 `binding.window` / `view.physicalSize` 取：
       *    前者是旧 API（恒返回默认 800x600），后者不受
       *    `setSurfaceSize` 影响 —— 两者都会算出 screenW=800
       *    而真实布局宽度是 1280，产生**假失败**。
       *
       *    正确做法：直接量 Scaffold 的渲染尺寸（= 真实视口）。
       */
      final screenW = tester.getSize(find.byType(Scaffold)).width;
      final screenRect = tester.getRect(find.byType(Scaffold));

      // ★ 判据：面板**右边缘**必须贴到窗口右边（允许 1px 误差）
      expect(
        (panelRight - (screenRect.left + screenW)).abs() <= 1.0,
        isTrue,
        reason: '★ 右侧抽屉的右边缘必须贴住窗口右边 —— '
            'panelRight=$panelRight 视口右边=${screenRect.left + screenW}。'
            '停在中间说明还是"居中弹窗"，没有改成抽屉。',
      );
    });

    testWidgets('★ 抽屉限宽：不能宽到挡住画面主体', (tester) async {
      await mount(tester, count: 40, currentIndex: 0, isDesktop: true);

      final wide = find.byType(Container).evaluate().where((e) {
        final w = e.renderObject;
        return w is RenderBox && w.hasSize && w.size.width > 200;
      }).toList();
      final box = wide.last.renderObject! as RenderBox;
      expect(
        box.size.width <= 400,
        isTrue,
        reason: '★ 抽屉宽度必须 ≤400（当前 ${box.size.width}）—— '
            '太宽就退化成"居中弹窗挡画面"了',
      );
    });

    testWidgets('★ 手机形态仍是底部抽屉（不要跟着变成右侧）', (tester) async {
      await mount(tester, count: 40, currentIndex: 0, isDesktop: false);

      final wide = find.byType(Container).evaluate().where((e) {
        final w = e.renderObject;
        return w is RenderBox && w.hasSize && w.size.width > 300;
      }).toList();
      final box = wide.last.renderObject! as RenderBox;
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      // ⚠️ 同"桌面"那条：视口尺寸从 Scaffold 量（`view` 不受 setSurfaceSize 影响）
      final screenRect = tester.getRect(find.byType(Scaffold));
      final screenBottom = screenRect.top + screenRect.height;

      expect(
        (bottom - screenBottom).abs() <= 40,
        isTrue,
        reason: '★ 手机端必须仍从**底部**弹出（bottom=$bottom '
            '视口底=$screenBottom）—— '
            '手机上右侧抽屉够不到（拇指行程横跨整屏）',
      );
    });
  });

  group('任务㉑⑪ 搜索（用户要求）', () {
    testWidgets('★ 集数够多时出现搜索框，输入后过滤', (tester) async {
      await mount(tester, count: 120, currentIndex: 0, isDesktop: true);

      expect(find.byType(TextField), findsOneWidget,
          reason: '★ 120 集必须显示搜索框（阈值 $kEpisodeSearchAfter）');

      // 搜「第 37 集」
      await tester.enterText(find.byType(TextField), '37');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('第 37 集'), findsWidgets,
          reason: '★ 搜 37 应能搜到第 37 集');
      expect(find.text('第 12 集'), findsNothing,
          reason: '★ 不匹配的集不该出现');
    });

    testWidgets('★★ 搜索必须**跨卷**（这是最容易做错的一点）', (tester) async {
      /*
       * 120 集 + chunkSize 100 → 分成 [1-100] 和 [101-120] 两卷。
       * 默认显示第 1 卷。若搜索**只在当前卷内**过滤，
       * 输入「115」会什么都搜不到（115 在第 2 卷）——
       * 用户会以为搜索坏了。
       *
       * ★ 这就是"搜索必须跨卷"的原因。
       */
      await mount(tester, count: 120, currentIndex: 0, isDesktop: true);

      await tester.enterText(find.byType(TextField), '115');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text('第 115 集'),
        findsWidgets,
        reason: '★★ 第 115 集在第 2 卷（101-120），当前显示的是第 1 卷 —— '
            '搜索必须**跨卷**才能找到它。只在当前卷里搜 = 用户以为搜索坏了。',
      );
    });

    testWidgets('★ 搜索能匹配**标题**（不只是集号）', (tester) async {
      await mount(tester, count: 120, currentIndex: 0, isDesktop: true);

      // eps() 里 i%7==0 的标题是「特别篇 i」
      await tester.enterText(find.byType(TextField), '特别篇');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('特别篇 7'), findsWidgets,
          reason: '★ 搜标题关键词应能命中');
      expect(find.text('第 8 集'), findsNothing,
          reason: '不匹配的集不该出现');
    });

    testWidgets('★ 清空搜索后恢复显示', (tester) async {
      await mount(tester, count: 120, currentIndex: 0, isDesktop: true);

      await tester.enterText(find.byType(TextField), '37');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('第 12 集'), findsNothing);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('第 12 集'), findsWidgets,
          reason: '★ 清空后应恢复显示当前卷的全部集数');
    });

    testWidgets('★ 集数少时**不**显示搜索框（别加噪音）', (tester) async {
      await mount(tester, count: 12, currentIndex: 0, isDesktop: true);
      expect(find.byType(TextField), findsNothing,
          reason: '12 集的剧摆个搜索框是噪音（阈值 $kEpisodeSearchAfter）');
    });
  });

  group('任务㉑⑪ 自动滚动到当前集（用户要求）', () {
    testWidgets('★ 当前集在很后面时，打开就要能看到它', (tester) async {
      /*
       * 用户原话：
       * > 如果有上百集,我希望**自动滚动到当前所观看的集的位置**
       *
       * 判据：当前集那一格必须**真的在视口内**（它的全局 y 落在面板范围内）。
       */
      await mount(tester, count: 120, currentIndex: 92, isDesktop: true);

      final tile = find.text('第 93 集'); // 0 基 92 → 显示"第 93 集"
      expect(tile, findsWidgets,
          reason: '★ 当前集必须被渲染出来（不能被懒构建跳过）');

      final box = tester.getRect(tile.first);
      expect(
        box.top >= 0 && box.bottom <= 800,
        isTrue,
        reason: '★ 当前集（第 93 集）必须在**视口内** —— '
            'rect=$box。不在视口内说明"自动滚动到当前集"没生效。',
      );
    });

    testWidgets('★ 集数少（无分卷）时当前集同样可见', (tester) async {
      await mount(tester, count: 30, currentIndex: 25, isDesktop: true);
      final tile = find.text('第 26 集');
      expect(tile, findsWidgets, reason: '当前集必须被渲染');
      final box = tester.getRect(tile.first);
      expect(box.top >= 0 && box.bottom <= 800, isTrue,
          reason: '30 集也该自动滚到第 26 集（rect=$box）');
    });
  });
}
