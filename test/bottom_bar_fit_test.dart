// ══════════════════════════════════════════════════════════════════════
//  底栏 tab 必须在**任何宽度**下都完整可见（2026-09-30）
//  ★ 2026-10-09 task-3：底栏从 5 项变成 6 项（新增「已缓存」）⇒
//     本文件的 tab 数、逐字文案、以及「桌面 1280 仍 118/项、合计 590」
//     这条**外观锚点**都必须同步。锚点已按新布局重算（见用例④）。
// ══════════════════════════════════════════════════════════════════════
//
// # 这条测试要挡住的缺陷（Owner 手机实测）
//
// 手机（1080x2400 @ 420dpi ⇒ DPR 2.625 ⇒ 逻辑宽 **411.43**）底栏只画出
// **3 项**：发现 / 直播 / 追更 —— 「搜索」「设置」两个入口**画到屏幕外**，
// 用户根本没有这两个入口。
//
// 根因：`_tabWidth` 是**与可用宽度无关的常量**（`Device.isTv ? 152 : 118`），
// 5 × 118 = 590 远超手机可用宽度 ⇒ `Row(MainAxisSize.min)` 被约束夹住后
// 仍然从 x=0 往外画，第 4/5 项落到屏外；而 `RenderFlex` 默认
// `Clip.none` ⇒ **不裁剪、不报错、release 下也不打印 overflow**。
//
// # 为什么用「几何」测而不是「源码文本」测
//
// 本仓已有一批**静态文本断言**（`test/bottom_bar_reach_test.dart` 等），
// 它们能挡「结构被删掉」，但**挡不住这类缺陷** —— 缺陷不是"少了哪个符号"，
// 而是**布局算错了**。文本断言在缺陷存在时**全绿**（这正是它漏过去的原因）。
// ⇒ 判据必须与证据同层：**量真实的 `Rect`**。
//
// # 判据（都从"用户能不能看见"出发，与修法无关）
//
// ```text
// ① 5 个标签都在**玻璃面板**矩形内（面板 = 底栏真正可见的那块）
// ② 5 个标签都在**屏幕**内
// ③ 每个 tab 宽度 ≥ _minTabWidth（不许用"压成 1px"来假装修好）
// ④ 药丸与当前 tab **对齐**（左边界 + 宽度）—— 药具位置是纯算术算的，
//    宽度一变它最容易错位（`_pillLeft` 与 `SizedBox(width:)` 必须同源）
// ⑤ 宽屏/TV **不许回归**：桌面 1280 仍是 118/项、TV 960 仍是 152/项
// ```
//
// ⚠️ ⑤ 是**阴性/阳性对照**：只有"窄屏变好"而"宽屏也变了"不算修好 ——
//    宽屏是 Owner 已经验收过的外观，逐像素不该动。

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/spatial_nav.dart' show BottomBarMarker;

/// 与生产外壳一致的包装（照抄 `test/keepalive_test.dart:81-91`）
///
/// ⚠️ 缺 `Material` 层会让 `InkWell` 抛
///    `Null check operator used on a null value`，整页被换成 ErrorWidget
///    —— 而断言只会以"找不到 XX"失败，真因只在 stderr。
Widget _appWith({required Widget home}) {
  final theme = FTheme.neutral.dark.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (context, child) => FTheme(
      data: theme,
      child: child ?? const SizedBox(),
    ),
    home: home,
  );
}

/// 认领一次 pump 期间积压的环境异常（无核心环境的 FFI 异常等）
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// 按**逻辑宽 × DPR** 摆好窗口，然后挂载整个 `ShellPage`
///
/// ⚠️⚠️ **必须设 `tester.view.physicalSize` / `devicePixelRatio`，
///    不能用 `setSurfaceSize`** —— 这是本测试第一次跑（6 个里 3 个假红）
///    的真正原因，记下来免得下次再踩：
///
/// ```text
/// setSurfaceSize(size)  只改**布局约束**（RenderView 的 ViewConfiguration）
/// FlutterView 的 metrics 它**不动** ⇒ MediaQuery.fromView 读到的还是
/// flutter_test 的默认值 **800 × 600 @ DPR 3.0**
/// ```
/// 于是生产代码里 `MediaQuery.of(context).size.width` 恒为 **800**，
/// 而同一棵树却按 411.43 布局 —— 测试量到的是
/// 「用 800 算出来的 tab 宽」配「411.43 的容器」，
/// 于是**修好的代码也报红**（TV 那条实测 pitch = 145.6 = `(800−72)/5`，
/// 正是 800 的铁证）。
///
/// 改 `tester.view.*` 之后布局与 MediaQuery **同时**变成目标窗口
/// ⇒ 测的是生产路径本身。
Future<void> _pumpShellAt(WidgetTester tester, Size logical,
    {double dpr = 1.0}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logical * dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
  await tester.pump();
  _claim(tester);
  await tester.pump(const Duration(milliseconds: 1500));
  _claim(tester);
}

/// 底栏标签的**逐字**文案（`AppTab` 的 label，也是交付契约）
///
/// ★ task-3 ⑲：与 `lib/shell.dart` 的 `enum AppTab` **逐项同序**。
///   加 tab 时这张表必须同步 —— 否则下面的「面板内」判据会漏掉新入口。
const _tabLabels = <String>['发现', '直播', '追更', '搜索', '已缓存', '设置'];

/// 底栏真正可见的那块玻璃面板
///
/// ⚠️ `skipOffstage: false` 是**必须的**，不是随手加的 ——
///    默认为 `true` 时元素树遍历会走 `_ViewportElement.debugVisitOnstageChildren`
///    → `RenderViewportBase.visitChildrenForSemantics`
///    （`viewport.dart:478` 那个 `parentData!` 空断言）⇒ 窄宽度下
///    `ShellPage` 里的滚动视图会在这个**测试仪器**里抛断言，
///    于是测试报的是仪器异常而**不是**我的几何判据（第一次跑 6/6 全红
///    就是这个原因，一半的"失败"是假红）。
///    `skipOffstage: false` 走另一条遍历路径（`visitChildren`）⇒ 绕开它。
Finder _panel() => find.descendant(
      of: find.byType(BottomBarMarker, skipOffstage: false),
      matching: find.byType(GlassContainer, skipOffstage: false),
      skipOffstage: false,
    );

/// 某个标签在**底栏里**的 `Finder`（避免匹配到内容区的同名文字）
Finder _labelIn(String text) => find.descendant(
      of: find.byType(BottomBarMarker, skipOffstage: false),
      matching: find.text(text, skipOffstage: false),
      skipOffstage: false,
    );

/// 打印一次完整几何（诊断用 —— 缺陷定位要靠这些数）
void _dump(WidgetTester tester, String tag) {
  final panel = tester.getRect(_panel().first);
  debugPrint('[$tag] surface=${tester.view.physicalSize} '
      'panel=$panel w=${panel.width.toStringAsFixed(2)}');
  for (final t in _tabLabels) {
    final r = tester.getRect(_labelIn(t).first);
    debugPrint('[$tag]   $t label=$r center=${r.center.dx.toStringAsFixed(2)}');
  }
}

void main() {
  group('★ 底栏 6 个 tab 在任何宽度下都要完整可见', () {
    testWidgets('① 手机宽度 411.43：6 个入口全在面板内（Owner 缺陷现场）',
        (tester) async {
      // 1080 / 2.625 = 411.43 逻辑宽、2400 / 2.625 = 914.29 逻辑高
      // —— Owner 手机（emulator-5556, 1080x2400 @420dpi）的真实 metrics
      await _pumpShellAt(tester, const Size(411.43, 914.29), dpr: 2.625);
      _dump(tester, 'phone-411');

      final panel = tester.getRect(_panel().first);
      for (final t in _tabLabels) {
        final label = _labelIn(t);
        expect(label, findsOneWidget, reason: '底栏里找不到「$t」');
        final r = tester.getRect(label);
        expect(
          r.left >= panel.left - 0.5 && r.right <= panel.right + 0.5,
          isTrue,
          reason: '「$t」被画到玻璃面板外（面板 $panel，标签 $r）'
              '—— 用户看不见这个入口',
        );
      }
    });

    testWidgets('② 每个 tab 的宽度 ≥ 44 逻辑 px（不许靠压扁冒充修好）',
        (tester) async {
      await _pumpShellAt(tester, const Size(411.43, 914.29), dpr: 2.625);

      // 用相邻标签中心的**间距**当 tab 宽度（等宽 + 居中 ⇒ 间距 = 宽度）
      final centers = <double>[
        for (final t in _tabLabels) tester.getRect(_labelIn(t).first).center.dx,
      ];
      for (var i = 1; i < centers.length; i++) {
        final pitch = centers[i] - centers[i - 1];
        debugPrint('[pitch] ${_tabLabels[i - 1]}→${_tabLabels[i]} '
            '= ${pitch.toStringAsFixed(2)}');
        expect(pitch, greaterThanOrEqualTo(44.0),
            reason: '第 ${i + 1} 个 tab 只有 ${pitch.toStringAsFixed(1)} 宽'
                '—— 图标 21 + 两字标签 21 放不下');
      }
    });

    testWidgets('③ 药丸与当前 tab 对齐（宽度改了最容易错位）', (tester) async {
      await _pumpShellAt(tester, const Size(411.43, 914.29), dpr: 2.625);

      // 首页是初始 tab ⇒ 药丸应在第 0 项上，左边界 == 面板左边界
      final panel = tester.getRect(_panel().first);
      final first = tester.getRect(_labelIn('发现').first);
      final pitch = tester.getRect(_labelIn('直播').first).center.dx -
          first.center.dx;

      // 药丸 = AnimatedPositioned 里那个 DecoratedBox
      // （同样必须 `skipOffstage: false`，理由见 `_panel()` 的说明）
      final pillFinder = find.descendant(
        of: find.byType(BottomBarMarker, skipOffstage: false),
        matching: find.byType(AnimatedPositioned, skipOffstage: false),
        skipOffstage: false,
      );
      debugPrint('[pill] AnimatedPositioned 命中 ${pillFinder.evaluate().length} 个');
      final pillRect = tester.getRect(pillFinder.first);
      debugPrint('[pill] rect=$pillRect  firstLabelCenter=${first.center.dx} '
          'pitch=${pitch.toStringAsFixed(2)}');

      // 药丸中心应落在第 0 项中心附近（误差 < tab 宽度的 15%）
      expect((pillRect.center.dx - first.center.dx).abs(),
          lessThan(pitch * 0.15),
          reason: '药丸没跟着 tab 走（药丸 $pillRect，第 0 项中心 ${first.center.dx}）');
      expect(pillRect.left, greaterThanOrEqualTo(panel.left - 0.5));
    });

    testWidgets('④ 阴性对照：桌面 1280 宽仍是 118/项、合计 708（不许回归）',
        (tester) async {
      await _pumpShellAt(tester, const Size(1280, 800));
      _dump(tester, 'desktop-1280');

      final centers = <double>[
        for (final t in _tabLabels) tester.getRect(_labelIn(t).first).center.dx,
      ];
      final pitch = centers[1] - centers[0];
      debugPrint('[desktop-1280] pitch=${pitch.toStringAsFixed(3)}');
      expect(pitch, closeTo(118.0, 0.01),
          reason: '桌面宽屏下 tab 宽度必须还是 118（已验收过的外观）');

      final panel = tester.getRect(_panel().first);
      // ★ task-3 ⑲：6×118 = 708 —— 118/项这个**舒适上限**没变（用例⑤ 的 TV
      //   分支仍是 152，见下），变的只是**项数**；合计 590 → 708 是项数带来的
      //   必然结果，不是几何回归。
      expect(panel.width, closeTo(708.0, 0.01),
          reason: '桌面宽屏下面板宽度必须还是 6×118 = 708');
    });

    testWidgets('⑤ 阳性对照：TV 960 宽仍是 152/项（Device.isTv 分支没被破坏）',
        (tester) async {
      Device.overrideKind(DeviceKind.tv);
      addTearDown(() => Device.overrideKind(null));
      await _pumpShellAt(tester, const Size(960, 540), dpr: 2.0);
      _dump(tester, 'tv-960');

      final centers = <double>[
        for (final t in _tabLabels) tester.getRect(_labelIn(t).first).center.dx,
      ];
      final pitch = centers[1] - centers[0];
      debugPrint('[tv-960] pitch=${pitch.toStringAsFixed(3)}');
      expect(pitch, closeTo(152.0, 0.01), reason: 'TV 分支必须还是 152');
    });

    testWidgets('⑥ 极窄 320 逻辑宽（最小 Android 手机）仍要 5 项可见',
        (tester) async {
      await _pumpShellAt(tester, const Size(320, 640));
      _dump(tester, 'phone-320');

      final panel = tester.getRect(_panel().first);
      for (final t in _tabLabels) {
        final r = tester.getRect(_labelIn(t).first);
        expect(r.left >= panel.left - 0.5 && r.right <= panel.right + 0.5,
            isTrue,
            reason: '320 宽下「$t」跑到面板外（面板 $panel，标签 $r）');
      }
    });

    // ══════════════════════════════════════════════════════════════════
    //  ⑦⑧ 下界分支：这条判据是**补**上来的，因为上面 6 个用例全都够不着
    //     它 —— 用例⑥ 名字写着「极窄」，可 320 宽下算出的 tab 宽是 49.6，
    //     **仍是等分值**，`_tabWidthMin = 44` 根本没有生效。
    //
    //  ★ 缺口（由 fix-autoscroll 独立发现、我复算确认）：
    //      下界生效后 `5 × 44 = 220` 会**超过**可用宽度，于是第 4/5 项
    //      又一次被画到屏外 —— 与 Owner 报的那个缺陷**同一类**，
    //      只是换了个更窄的宽度。而 `RenderFlex` 是 `Clip.none`
    //      ⇒ 不裁剪、不报错、release 也不打印 ⇒ 照样静默。
    //
    //  阈值：`5 × 44 + 72 = 292` ⇒ **任何逻辑宽 < 292 都会溢出**。
    //
    //  ★ 这不是纸面推演，是**用户能碰到的**：
    //      · Windows：把窗口拖窄（这个版本可以任意拖）
    //      · Android：分屏 / 自由窗口 —— 手机 411.43 对半分 ≈ 205
    //    ⇒ 两个用例都要，205 是被真实场景选中的那个数。
    //
    //  ⚠️ 判据仍然是「标签在面板内」，与修法无关：
    //     极窄时**可见性优先于舒适下限** —— 44 px 的"好看"不能让位给
    //     "入口彻底消失"。下面两例在修复前必须是**红**的（否则这条
    //     判据没有分辨力，等于没写）。
    // ══════════════════════════════════════════════════════════════════

    testWidgets('⑦ 分屏 240 逻辑宽：5 项仍要全在面板内（下界必须让位）',
        (tester) async {
      await _pumpShellAt(tester, const Size(240, 480));
      _dump(tester, 'phone-240');

      final panel = tester.getRect(_panel().first);
      for (final t in _tabLabels) {
        final label = _labelIn(t);
        expect(label, findsOneWidget, reason: '底栏里找不到「$t」');
        final r = tester.getRect(label);
        expect(
          r.left >= panel.left - 0.5 && r.right <= panel.right + 0.5,
          isTrue,
          reason: '240 宽下「$t」跑到面板外（面板 $panel，标签 $r）'
              '—— 5×44 = 220 > 240−72 = 168，下界把 tab 挤出了屏',
        );
      }
    });

    testWidgets('⑧ 分屏 205 逻辑宽（411.43 对半）：5 项仍要全在面板内',
        (tester) async {
      await _pumpShellAt(tester, const Size(205, 600));
      _dump(tester, 'phone-205');

      final panel = tester.getRect(_panel().first);
      for (final t in _tabLabels) {
        final label = _labelIn(t);
        expect(label, findsOneWidget, reason: '底栏里找不到「$t」');
        final r = tester.getRect(label);
        expect(
          r.left >= panel.left - 0.5 && r.right <= panel.right + 0.5,
          isTrue,
          reason: '205 宽下「$t」跑到面板外（面板 $panel，标签 $r）',
        );
      }
    });
  });
}
