// ═══════════════════════════════════════════════════════════════════════
//  真实空间导航路径 —— 直接驱动 `lib/ui/spatial_nav.dart`（任务 AF）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须新增这个文件（2026-09-25 核实）
//
// 任务 AF 要求核实「TV 的 D-pad 在每个页面都能走通、且底栏可达」。
// 核实三个既有测试后发现的**覆盖漏洞**：
//
// ```text
// test/focus_narrow_test.dart       测 Flutter **内建**遍历，用手搓树
//                                   （该文件头注释自己也写明了这点）
// test/directional_focus_test.dart  同上：4 个用例全是手搓树 + 内建遍历
// test/bottom_bar_reach_test.dart   把 .dart **当文本读**做静态断言
//                                   （File(...).readAsStringSync()）—— 一行都不执行
// ```
//
// 用 Python 扫全仓 import 指令核实：真正 import `spatial_nav.dart` 的只有
// ```text
// lib/shell.dart              （生产）
// lib/tv_nav_probe.dart       （探针，必须真机跑）
// lib/tv_realkey_probe.dart   （探针，必须真机跑）
// ```
// —— **三个测试文件没有一个 import 它**。
//
// 也就是说生产那 800 行算法（两轮搜索 / 底栏守卫 / 交叉轴权重）
// 在单测里**一行都没被执行过**。这正是本项目踩过的坑：
// 「用手搓 Column 测自己的构造」—— 测试全绿，但测的不是发货代码。
//
// # 本文件测什么
//
// 直接 import 并调用**生产实现**：
// ```text
// moveFocus(NavDir)      真实几何邻居算法（含两轮搜索 / 底栏守卫）
// BottomBarMarker        底栏结构标记（原版 .tabbar）
// SpatialNavHandler      全局方向键接管（设备/页面/输入框三层守卫）
// ```
//
// # 断言纪律（本项目已 5 次「断言作用域错」）
//
// ```text
// ① 每个断言前先**证明起点成立**（焦点确实种上了）—— 否则断言恒真
// ② 断言按**实测值**写，不按"我以为的布局"写
// ③ 不断言 requestFocus 当帧生效（下一帧才生效），必须 pump
// ④ 几何必须**先算过**再写（见 ②③ 的验算注释）—— 否则测不到想测的机制
// ```
//
// # ⚠️ 本轮实测发现的**未修复缺陷**（不在本文件断言，见文件末）
//
// 用真实几何驱动 `moveFocus` 时发现两个可复现问题（详见末尾注释）。
// 它们**没有**在本文件里写成断言 —— 因为断言"错误行为"会把 bug 固化；
// 断言"正确行为"则会让本轮测试变红（且修复超出任务 AF 的文件归属）。
// 这里如实记录 + 复现脚本见末尾。

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/spatial_nav.dart';

/// 可聚焦块
///
/// ⚠️ 必须**显式**传 `focusNode` —— 不传的话 `requestFocus()` 静默无效，
///    测试会"通过"但什么都没测到（`focus_narrow_test.dart` 记过这个坑）。
class _Cell extends StatelessWidget {
  const _Cell({
    required this.node,
    required this.label,
    this.w = 100,
    this.h = 50,
  });

  final FocusNode node;
  final String label;
  final double w;
  final double h;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: w,
        height: h,
        child: Focus(focusNode: node, child: Text(label)),
      );
}

/// 把视口设成真实 TV 逻辑尺寸（960x540 = 1920x1080 @ dpr2）
///
/// # 为什么必须显式设（否则测不到真机那个 bug）
///
/// `flutter_test` 默认视口是 **800x600**。而本项目记录的 TV bug 是
/// 「底栏 tab 中心 x≈960，源条 pill 中心 x≈105 → cross=855 > 360 被挡」——
/// 这个数字只有在**宽屏**下才出现。用默认 800x600 测，
/// 几何对不上，等于又一次「取样框打偏」。
void _setTvViewport(WidgetTester t) {
  t.view.physicalSize = const Size(960, 540);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

/// 造一个方向键 KeyDownEvent（测 `SpatialNavHandler` 守卫契约用）
///
/// ⚠️ `timeStamp` 在这个 Flutter 版本是**必填**命名参数（实测编译错）。
KeyDownEvent _arrowDown() => const KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.arrowDown,
      logicalKey: LogicalKeyboardKey.arrowDown,
      timeStamp: Duration.zero,
    );

void main() {
  group('★ 真实 spatial_nav 路径（不是手搓遍历）', () {
    testWidgets('① moveFocus(down)：源条 → 内容区（真实算法）', (t) async {
      _setTvViewport(t);
      final src = FocusNode();
      final poster = FocusNode();
      addTearDown(src.dispose);
      addTearDown(poster.dispose);

      /*
       * 几何（960x540）：
       * ```text
       * 源条 pill : (0,0)-(120,44)     cx=60,  bottom=44
       * 海报卡    : (0,48)-(148,248)   cx=74,  top=48
       * ```
       * 按 ↓：`poster.top(48) - src.bottom(44) = 4 >= MIN_ADVANCE(4)` ✓
       *       `cross = |74-60| = 14 <= 360` ✓
       * ★ 关键是**左侧对齐** —— 实测发现：若目标居中
       *   （cx≈屏幕中心），全屏 `FocusScopeNode` 会以更低成本赢走焦点
       *   （见文件末尾缺陷记录）。左侧对齐才能稳定测到真实卡片。
       */
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            SizedBox(
              height: 48,
              child:
                  Row(children: [_Cell(node: src, label: '源', w: 120, h: 44)]),
            ),
            Row(children: [_Cell(node: poster, label: '海报', w: 148, h: 200)]),
          ]),
        ),
      ));
      src.requestFocus();
      await t.pump();

      // ★ 先证明起点成立 —— 否则后面全是恒真断言
      expect(src.hasPrimaryFocus, isTrue, reason: '起点没种上，断言无意义');

      final moved = moveFocus(NavDir.down);
      await t.pump(); // requestFocus 下一帧才生效

      debugPrint('【① 真实 moveFocus】moved=$moved log=$spatialNavLog');
      expect(moved, isTrue, reason: '真实算法应该找到下方的海报');
      expect(poster.hasPrimaryFocus, isTrue,
          reason: '焦点应该真的落到海报上（不是落在某个全屏 scope 上）');
    });

    testWidgets('② 底栏可达：靠**第二轮搜索**落到底栏（BottomBarMarker）', (t) async {
      _setTvViewport(t);
      final content = FocusNode();
      final tabA = FocusNode();
      final tabB = FocusNode();
      addTearDown(content.dispose);
      addTearDown(tabA.dispose);
      addTearDown(tabB.dispose);

      /*
       * ★ 几何**先算过**才写（否则测不到"两轮搜索"这个机制）：
       * ```text
       * content : (0,100)-(148,300)    cx=74,  bottom=300
       * 底栏 tabA: (0,480)-(148,540)   cx=74   top=480
       * 底栏 tabB: (148,480)-(296,540) cx=222  top=480
       * ```
       * 从 content 按 ↓（`_verticalCrossLimit = 360`）：
       * ```text
       * tabA cross=|74-74|=0    -> 通过
       * tabB cross=|222-74|=148 -> 通过
       * ```
       * 两个 tab 的 cross **都没超限** —— 所以第一轮找不到它们
       * **只可能是因为被 `exclude: _isInBottomBar` 排除了**，
       * 这正是两轮搜索要验证的机制。
       *
       * ⚠️ 若用"底栏居中 + 源条靠左"（真机形状），cross=855 会**同时**
       *    超限 → 第二轮也找不到 → 那时测到的是另一个缺陷（见文件末尾），
       *    而不是"两轮搜索работает"。这里刻意分开。
       */
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            Column(children: [
              const SizedBox(height: 100),
              Row(children: [_Cell(node: content, label: '内容', w: 148, h: 200)]),
            ]),
            Positioned(
              left: 0,
              bottom: 0,
              child: BottomBarMarker(
                child: Row(children: [
                  _Cell(node: tabA, label: '发现', w: 148, h: 60),
                  _Cell(node: tabB, label: '直播', w: 148, h: 60),
                ]),
              ),
            ),
          ]),
        ),
      ));

      content.requestFocus();
      await t.pump();
      expect(content.hasPrimaryFocus, isTrue, reason: '起点没种上');

      final moved = moveFocus(NavDir.down);
      await t.pump();

      debugPrint('【② 底栏可达】moved=$moved log=$spatialNavLog');
      expect(moved, isTrue, reason: '内容区往下必须能落到底栏 —— 否则用户被困在首页');
      expect(tabA.hasPrimaryFocus, isTrue,
          reason: '焦点应该落在几何上最合适的 tabA（cross=0）');
      // ★ 证明走的是**第二轮**（第一轮排除了底栏）
      expect(spatialNavLog.join(' '), contains('允许落底栏（第二轮）'),
          reason: '必须由第二轮搜索救回底栏 —— 若第一轮就命中，说明 '
              'BottomBarMarker 排除没生效，底栏可达是"假通过"');
    });

    testWidgets('③ 底栏是最后一行：从底栏按 down 不动（防绕圈）', (t) async {
      _setTvViewport(t);
      final tab = FocusNode();
      final below = FocusNode();
      addTearDown(tab.dispose);
      addTearDown(below.dispose);

      /*
       * 复刻真机形状（底栏浮在内容之上，内容在它下面继续）：
       * ```text
       * 底栏 tab : (0,150)-(100,210)   中心 y=180
       * 内容     : (0,200)-(120,500)   中心 y=350  ← **几何上在底栏下方**
       * ```
       * 从 tab 按 ↓：`below` 中心 y=350 > 180+4 -> 是**合法候选**
       * （cross=|60-50|=10 也没超限）。
       * 所以焦点**会**被带走 —— 除非结构守卫生效。
       * 这才能证明守卫本身在起作用，而不是"本来就没候选"。
       */
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            Column(children: [
              const SizedBox(height: 200),
              Row(children: [_Cell(node: below, label: '底栏后面的内容', w: 120, h: 300)]),
            ]),
            Positioned(
              left: 0,
              top: 150,
              child: BottomBarMarker(
                child: _Cell(node: tab, label: '底栏', w: 100, h: 60),
              ),
            ),
          ]),
        ),
      ));

      tab.requestFocus();
      await t.pump();
      expect(tab.hasPrimaryFocus, isTrue, reason: '起点没种上');

      final moved = moveFocus(NavDir.down);
      await t.pump();

      debugPrint('【③ 底栏守卫】moved=$moved log=$spatialNavLog');
      expect(moved, isFalse,
          reason: '底栏是视觉上最底部那一排 —— 从它往下必须不动，'
              '否则焦点成环（真机实测连按 16 次 ↓ 停不下来）');
      expect(tab.hasPrimaryFocus, isTrue, reason: '焦点必须留在底栏上');
      expect(spatialNavLog.join(' '), contains('已在底栏 + 目标是内容区 -> 不动'),
          reason: '必须是被**结构守卫**拦下的 —— 而不是"没找到候选"');
    });

    testWidgets('④ SpatialNavHandler 三层守卫的契约', (t) async {
      final a = FocusNode();
      final b = FocusNode();
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            _Cell(node: a, label: 'a'),
            _Cell(node: b, label: 'b'),
          ]),
        ),
      ));
      a.requestFocus();
      await t.pump();
      expect(a.hasPrimaryFocus, isTrue, reason: '起点没种上');

      /*
       * 契约（见 `spatial_nav.dart` 的 `SpatialNavHandler.handle`）：
       * ```text
       * enabled() == false           -> false 放行（桌面不启用空间导航）
       * isTyping() == true           -> false 放行（输入框里要能移动光标）
       * isConsumedByPage() == true   -> false 放行（播放器自己用方向键）
       * 三者都放行                   -> true  **消费掉**
       * ```
       * 最后一条尤其重要：不消费的话事件会继续流到 `Scrollable`，
       * 变成"一边滚页面一边移焦点"。
       */
      final off = SpatialNavHandler(enabled: () => false);
      expect(off.handle(_arrowDown()), isFalse,
          reason: '桌面（enabled=false）必须放行方向键，否则播放器音量/快进全废');

      final typing =
          SpatialNavHandler(enabled: () => true, isTyping: () => true);
      expect(typing.handle(_arrowDown()), isFalse,
          reason: '输入框里必须放行 —— 否则用户没法在搜索框里移动光标');

      final byPage = SpatialNavHandler(
        enabled: () => true,
        isConsumedByPage: () => true,
      );
      expect(byPage.handle(_arrowDown()), isFalse,
          reason: '播放器自己要用方向键时必须放行');

      // 全部放行 -> 必须消费
      final live = SpatialNavHandler(enabled: () => true);
      expect(live.handle(_arrowDown()), isTrue,
          reason: '正常页面上方向键必须被消费掉 —— 否则一边滚页面一边移焦点');

      // 非方向键必须放行（不能把 Enter/Back 也吃掉）
      final enter = SpatialNavHandler(enabled: () => true);
      expect(
        enter.handle(const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: LogicalKeyboardKey.enter,
          timeStamp: Duration.zero,
        )),
        isFalse,
        reason: '只接管方向键 —— 其余按键照旧走焦点树',
      );
    });

    testWidgets('⑤ moveFocus 到边界时静默不动（不绕回第一个）', (t) async {
      _setTvViewport(t);
      final only = FocusNode();
      addTearDown(only.dispose);

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [_Cell(node: only, label: '唯一', w: 120, h: 60)]),
        ),
      ));
      only.requestFocus();
      await t.pump();
      expect(only.hasPrimaryFocus, isTrue, reason: '起点没种上');

      /*
       * 只有一个元素时按 ↓：没有"下方"的候选。
       * 原版注释：「否则 → 什么都不做（**不要绕回第一个，那很晕**）」。
       *
       * ⚠️ 实测提醒：`_collect()` 会把全屏 `FocusScopeNode`
       *    （View Scope / Navigator Scope，矩形 = 整屏）也算成候选，
       *    所以"只有一个元素"时**未必**真的没有候选 —— 见文件末尾缺陷。
       *    这里断言的是"**不会**把焦点移到那个唯一元素自己身上"，
       *    即不绕回，这对两种情况都成立。
       */
      final moved = moveFocus(NavDir.down);
      await t.pump();

      debugPrint('【⑤ 边界】moved=$moved log=$spatialNavLog');
      expect(only.hasPrimaryFocus, isTrue,
          reason: '到边界时焦点应保持不动（不绕回）');
    });
  });
}

// ═══════════════════════════════════════════════════════════════════════
//  ⚠️ 本轮实测发现的两个未修复缺陷（2026-09-25，任务 AF）
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷 ①：`_collect()` 把**全屏 FocusScopeNode** 当成可聚焦候选
//
// `_collect()` 的过滤条件是
// ```dart
// if (child.canRequestFocus && !child.skipTraversal) { ... }
// ```
// 而 Flutter 的 `FocusScopeNode`（`View Scope` / `Navigator Scope` /
// `_ModalScopeState Focus Scope`）**满足这个条件**，且它们的 RenderBox
// 矩形是**整屏** `(0,0,960,540)`。
//
// 后果（实测，960x540）：
// ```text
// 当前焦点 = (380,200,580,260)（屏幕正中的卡片）
// 按 ↓  ->  选中=(0,0,960,540)  ← 全屏 scope 赢了
// moved=true 但 primaryFocus 仍是原节点  ->  **焦点根本没动**
// ```
// 因为"屏幕中心"到"整屏矩形中心"的 cross ≈ 0、main 也小，
// 成本必然低于任何真实元素 —— 只要当前焦点在**屏幕中心附近**，
// 全屏 scope 就会赢走这次移动，而 `requestFocus()` 打在 scope 上
// 对用户没有任何可见效果。
//
// ★ 触发条件：当前焦点元素的中心**靠近屏幕中心**（cross 小）。
//   左侧对齐的内容（源条 pill、靠左的海报卡）不受影响 —— 这也是
//   真机探针一直没抓到的原因（首页元素都在左侧）。
//
// # 缺陷 ②：`primeFocus()` 的触发分支在真实壳里**不可达**，且选错目标
//
// `shell.dart:1479` 的守卫是 `if (FocusManager.instance.primaryFocus == null)`，
// 但实测（MaterialApp 路由树）：
// ```text
// 未请求任何焦点时 primaryFocus = _ModalScopeState Focus Scope  ← 不是 null
// ```
// 路由的 ModalScope 一挂载就自动持有主焦点 → 该分支**永不进入**。
//
// 而即使手动制造出 `primaryFocus == null`（裸树，无 MaterialApp）：
// ```text
// primeFocus() => true
// 但 a=false b=false，primaryFocus = "View Scope"  ← 焦点落在了全屏 scope 上
// ```
// 即 `primeFocus` 同样被缺陷 ① 影响 —— `_collect()` 排序后
// "最靠上最靠左"的候选是全屏 scope（top=0,left=0），它排在真实元素前面。
//
// # 为什么本轮**不修**
//
// ```text
// ① 文件归属：修复点在 `lib/ui/spatial_nav.dart`，不在任务 AF 允许改的
//    文件清单里（AF 只能改 sourin_api.dart / nullpath_probe.dart /
//    确认无用的 probe / 本测试文件）。
// ② 风险：`_collect()` 的过滤条件是空间导航的核心，改动会影响
//    5 个并行代理正在依赖的行为；且真机探针需要重跑。
// ③ 断言纪律：把"错误行为"写成断言 = 固化 bug；
//    写成"正确行为"= 本轮测试变红。两者都不可取 ——
//    所以如实记录，交由 Owner / 后续任务决定。
// ```
//
// # 复现方式（已实测确认，非推测）
//
// 在 960x540 视口下，把内容**居中**（`Center`）而不是靠左对齐，
// 然后调用 `moveFocus(NavDir.down)` —— `spatialNavLog` 会打印
// `选中=(0,0,960,540)`，且目标节点 `hasPrimaryFocus == false`。
// 靠左对齐时一切正常（本文件 ①②③ 即用靠左几何，故为绿）。
