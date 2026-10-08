// ═══════════════════════════════════════════════════════════════════════
//  TV 遥控器方向键 —— **真路径**回归测试（任务 AI，2026-09-25）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须新建这个文件
//
// 本项目的方向键测试曾经**全部测不到生产代码**（AF 用 Python 扫全仓 import
// 核实，我已独立复核）：
// ```text
// focus_narrow_test.dart        import spatial_nav=False  测 Flutter 内建遍历
// directional_focus_test.dart   import spatial_nav=False  同上
// bottom_bar_reach_test.dart    import spatial_nav=False  把 .dart 当【文本】读
// ```
// 真正 import `lib/ui/spatial_nav.dart` 的只有生产代码和真机探针 ——
// 那 1000 多行空间导航算法在单测里**一行都没被执行过**。
// 这正是本项目踩过的「用手搓 Column 测自己的构造」：测试和实现各说各话。
//
// # 与 `probe_cleanup_test.dart` 的分工
//
// ```text
// probe_cleanup_test.dart  基础契约（真实几何 + 生产实现）
// 本文件                    ★ 两个**真实缺陷**的防复发断言
//                          ★ 刻意用**更真实的树**（真路由 / 真按键 / 真按钮）
// ```
//
// # 断言纪律（沿用本项目已踩过的教训）
//
// ```text
// ① 每个断言前先**证明起点成立** —— 否则断言恒真（"断言作用域错"踩过 5 次）
// ② 断言必须**可证伪**：修复前的代码要能报红（脚本见 .probe/ai_redness_proof.py）
// ③ 不断言 requestFocus 当帧生效 —— 必须 pump 后读**真实** primaryFocus
// ④ 「某个按键有反应」≠「这个按键完成了它该完成的事」——
//    永远断言**焦点落在了正确的那个控件上**，不是"矩形变了"
// ```
import 'dart:io';

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
    super.key,
    required this.node,
    required this.label,
    this.w = 100,
    this.h = 40,
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

/// 真实 TV 逻辑尺寸（960x540 = 1920x1080 @ dpr2）
///
/// `flutter_test` 默认是 **800x600**。缺陷①的触发条件是"当前焦点中心靠近
/// **屏幕中心**"，用默认视口算出来的中心是 (400,300)，与 TV 的 (480,270)
/// 不同 —— 几何对不上就等于**取样框打偏**。
void _setTvViewport(WidgetTester t) {
  t.view.physicalSize = const Size(960, 540);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

/// 取当前主焦点的"结构身份 + 矩形"，用于**可判读**的证据输出
///
/// 只报矩形无法断言"焦点到了哪个控件"（本项目已踩过）——
/// 所以类型、是否 scope、祖先链一起打出来。
String _describe(FocusNode? n) {
  if (n == null) return '<null>';
  final ro = n.context?.findRenderObject();
  Rect? r;
  if (ro is RenderBox && ro.hasSize) {
    r = ro.localToGlobal(Offset.zero) & ro.size;
  }
  return '${n.debugLabel ?? "?"}(isScope=${n is FocusScopeNode}, rect=$r)';
}

/// 整屏矩形（960x540 视口下）
const Rect _fullScreen = Rect.fromLTRB(0, 0, 960, 540);

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  缺陷①：`_collect()` 把全屏 `FocusScopeNode` 当候选
  // ═══════════════════════════════════════════════════════════════════
  group('★ 缺陷① 全屏 scope 抢走导航', () {
    testWidgets('① 焦点在屏幕中心时，方向键**真的**改变 primaryFocus', (t) async {
      _setTvViewport(t);
      final top = FocusNode(debugLabel: '顶部按钮');
      final below = FocusNode(debugLabel: '下方卡片');
      addTearDown(top.dispose);
      addTearDown(below.dispose);

      /*
       * ★ 几何**先算过**才写（否则根本触发不到缺陷）：
       * ```text
       * 顶部按钮  : (430,0)-(530,40)      cx=480  bottom=40   ← 屏幕**水平中心**
       * 下方卡片  : (430,200)-(530,240)   cx=480  top=200
       * 全屏 scope: (0,0)-(960,540)       cx=480  cy=270
       * ```
       * 按 ↓ 的代价（`_crossWeightVertical = 0.25`）：
       * ```text
       * 下方卡片   = main(200-40=160) + cross(0)x0.25 = 160
       * 全屏 scope = main(0-40 -> clamp 0) + cross(0)x0.25 = 0   ← ★ 必然赢
       * ```
       * `cross` 必须是 0 才会触发 —— 这也是**真机首页测不出来**的原因：
       * 首页元素都在左侧（源条 pill、左侧海报卡），cross 很大，scope 赢不了。
       */
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            Center(child: _Cell(node: top, label: '顶部')),
            const SizedBox(height: 160),
            Center(child: _Cell(node: below, label: '下方')),
          ]),
        ),
      ));

      top.requestFocus();
      await t.pump();

      // ★ 先证明起点成立 —— 否则后面全是恒真断言
      expect(top.hasPrimaryFocus, isTrue, reason: '起点没种上，断言无意义');

      final beforeNode = FocusManager.instance.primaryFocus;
      expect(beforeNode, same(top), reason: '起点必须是那个居中控件');

      final moved = moveFocus(NavDir.down);
      await t.pump(); // requestFocus 下一帧才生效
      await t.pump();

      debugPrint('【缺陷①】moved=$moved log=$spatialNavLog');
      debugPrint('【缺陷①】起点=${_describe(beforeNode)}');
      debugPrint('【缺陷①】终点=${_describe(FocusManager.instance.primaryFocus)}');

      /*
       * ★★ 核心断言：`moveFocus` 的返回值**不足以**说明焦点动了。
       *
       * 修复前实测：
       * ```text
       * moved=true                       ← 返回值说"我请求移焦了"
       * 选中=(0,0,960,540)               ← 选中的是全屏 scope
       * 下方卡片 hasPrimaryFocus=false   ← 焦点**一步都没走**
       * ```
       * 这正是本项目那条纪律：「某个按键有反应」≠「这个按键完成了它该完成的事」。
       */
      expect(moved, isTrue, reason: '下方有卡片，算法应该找到它');
      expect(below.hasPrimaryFocus, isTrue,
          reason: '★ 焦点必须**真的**落到下方卡片上。'
              '修复前它会被全屏 scope 抢走 —— 那时这条断言报红');
      expect(FocusManager.instance.primaryFocus, same(below),
          reason: '主焦点必须**就是**目标控件本身（不是某个矩形碰巧一样的容器）');
    });

    testWidgets('② 候选池里**不含**矩形 = 整屏的节点', (t) async {
      _setTvViewport(t);
      final a = FocusNode(debugLabel: 'A');
      final b = FocusNode(debugLabel: 'B');
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            Center(child: _Cell(node: a, label: 'A')),
            const SizedBox(height: 160),
            Center(child: _Cell(node: b, label: 'B')),
          ]),
        ),
      ));
      a.requestFocus();
      await t.pump();

      moveFocus(NavDir.down);
      await t.pump();

      debugPrint('【缺陷① 候选池】${spatialNavCandidates.join(" ")}');

      /*
       * ★★ 这一条断言的是**根因**，不是症状。
       *
       * 只断言"焦点没动"是不够的：同一个全屏 scope 换个布局就会以
       * 别的方式造成危害（比如把 `primeFocus` 的落点抢走），
       * 而那时"焦点没动"这个症状**根本不会出现**，防复发断言就失效了。
       *
       * 真实树上矩形 = 整屏的节点是这几个容器：
       * ```text
       * View Scope / Navigator Scope / _ModalScopeState Focus Scope
       * ```
       * 它们能承载焦点，但**不是用户能看见的控件** —— 焦点落在上面
       * 对用户来说就等于"没动"。
       */
      expect(spatialNavCandidates, isNotEmpty,
          reason: '前置：候选池不该是空的，否则这条断言恒真');
      for (final r in spatialNavCandidates) {
        expect(r, isNot(_fullScreen),
            reason: '★ 候选池里出现了整屏矩形 $r —— '
                '这是容器（FocusScopeNode）混进了候选，不是真控件');
      }
      // 反过来证明"确实收到了真控件"，避免"一个都没收到"式的假通过
      expect(spatialNavCandidates.any((r) => r.width == 100 && r.height == 40),
          isTrue,
          reason: '候选池里必须有那两个 100x40 的真控件 —— '
              '否则"没有整屏矩形"只是因为**什么都没收集到**');
    });

    testWidgets('③ 三个真实容器都不是候选（View/Navigator/ModalScope）', (t) async {
      _setTvViewport(t);
      final only = FocusNode(debugLabel: '唯一控件');
      addTearDown(only.dispose);

      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: _Cell(node: only, label: '唯一'))),
      ));
      only.requestFocus();
      await t.pump();

      moveFocus(NavDir.right);
      await t.pump();

      /*
       * 页面上只有 1 个真控件，但焦点树里有 **3 个**全屏容器。
       * 修复前："候选=4"（1 真 + 3 容器）；修复后必然只有 1。
       *
       * ★ 计数断言在这里是**有判别力**的：容器数量是固定的 3 个，
       *   不像"27 个真控件"那种会随布局变化的数字。
       */
      debugPrint('【缺陷① 纯计数】候选=${spatialNavCandidates.length} '
          '${spatialNavCandidates.join(" ")}');
      expect(spatialNavCandidates.length, 1,
          reason: '★ 页面上只有 1 个可聚焦控件，候选就必须只有 1 个。'
              '修复前这里会是 4（多出 View/Navigator/ModalScope 三个全屏容器）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  缺陷②：`primeFocus` 的触发分支不可达 → 新路由上方向键失灵
  // ═══════════════════════════════════════════════════════════════════
  group('★ 缺陷② 新路由上方向键失灵', () {
    testWidgets('④ 真实 Navigator.push 后，primaryFocus 是 scope 而**不是** null',
        (t) async {
      _setTvViewport(t);
      final homeBtn = FocusNode(debugLabel: '首页控件');
      final detailLeft = FocusNode(debugLabel: '详情左');
      final detailRight = FocusNode(debugLabel: '详情右');
      addTearDown(homeBtn.dispose);
      addTearDown(detailLeft.dispose);
      addTearDown(detailRight.dispose);

      final navKey = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: Scaffold(body: Center(child: _Cell(node: homeBtn, label: '首页'))),
      ));
      homeBtn.requestFocus();
      await t.pump();
      expect(homeBtn.hasPrimaryFocus, isTrue, reason: '起点没种上');

      navKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Column(children: [
            Row(children: [
              _Cell(node: detailLeft, label: '详情左'),
              const SizedBox(width: 90),
              _Cell(node: detailRight, label: '详情右'),
            ]),
          ]),
        ),
      ));
      await t.pumpAndSettle();

      final afterPush = FocusManager.instance.primaryFocus;
      debugPrint('【缺陷②】push 之后 primaryFocus=${_describe(afterPush)}');

      /*
       * ★★ 这条断言是**缺陷②的根因证据**，也是本测试组其余断言的前提。
       *
       * 修复前的注释把原因写成「详情页里没有地方设过焦点 → primaryFocus == null」。
       * 实测**推翻了它**：路由的 `ModalScope` 一挂载就自动持有主焦点，
       * 所以它**永远不是 null** —— 旧守卫 `if (cur != null) return false`
       * 必然提前返回，`shell.dart` 里 `if (primaryFocus == null) primeFocus()`
       * 更是**永远进不去的死分支**。
       */
      expect(FocusManager.instance.primaryFocus, isNotNull,
          reason: '★ 真实路由树里 primaryFocus **不是** null —— '
              '它被 _ModalScopeState 持有。'
              '若这里变成 null，说明 Flutter 行为变了，'
              '依赖"为 null"的旧守卫反倒会生效 —— 判据需要重新核对');
      expect(afterPush, isA<FocusScopeNode>(),
          reason: '★ 进新路由后主焦点是个**容器**（_ModalScopeState Focus Scope），'
              '不是任何用户能看见的控件');
      expect(detailLeft.hasPrimaryFocus, isFalse,
          reason: '前置：详情页确实没有任何地方设过焦点（本缺陷的触发条件）');
    });

    testWidgets('⑤ push 之后直接按方向键：焦点**真的能动到详情页控件**', (t) async {
      _setTvViewport(t);
      final homeBtn = FocusNode(debugLabel: '首页控件');
      final detailLeft = FocusNode(debugLabel: '详情左');
      final detailRight = FocusNode(debugLabel: '详情右');
      addTearDown(homeBtn.dispose);
      addTearDown(detailLeft.dispose);
      addTearDown(detailRight.dispose);

      final navKey = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: Scaffold(body: Center(child: _Cell(node: homeBtn, label: '首页'))),
      ));
      homeBtn.requestFocus();
      await t.pump();

      /*
       * ★ 几何：详情页控件放**顶部**，首页控件在中间（Center）。
       * ```text
       * 详情左 : (0,0)-(100,40)      cy=20   ← 最靠上 -> prime 的落点
       * 详情右 : (190,0)-(290,40)    cy=20   与"详情左"同排 -> cross=0
       * 首页   : (430,250)-(530,290) cy=270
       * ```
       * `primeFocus` 取"最靠上再最靠左" = 详情左（top=0 胜过首页的 250）。
       * 之后按 → ：crossLimit = max(40,1)x1.4 = 56，
       * 详情右 与详情左**同一排**（cy 都是 20）-> cross=0 ✓ 通过。
       */
      navKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Column(children: [
            Row(children: [
              _Cell(node: detailLeft, label: '详情左'),
              const SizedBox(width: 90),
              _Cell(node: detailRight, label: '详情右'),
            ]),
          ]),
        ),
      ));
      await t.pumpAndSettle();

      expect(detailLeft.hasPrimaryFocus, isFalse, reason: '前置：详情页还没焦点');

      /*
       * ★★ 关键：**不手动调 primeFocus**，直接按方向键。
       *
       * 这正是真机上的顺序 —— 用户进详情页后按的是方向键，
       * 而不是"先让 App 把焦点放好"。所以修复必须发生在
       * `moveFocus` 内部（原版也是内联在 `onKeyDown` 里的）。
       */
      final moved = moveFocus(NavDir.right);
      await t.pump();
      await t.pump();

      debugPrint('【缺陷②】moved=$moved log=$spatialNavLog');
      debugPrint('【缺陷②】终点=${_describe(FocusManager.instance.primaryFocus)}');
      debugPrint('【缺陷②】primedRect=$spatialNavPrimedRect');

      /*
       * 修复前实测输出：
       * ```text
       * moved=false
       * log: 方向=right 不符=4 比较=0 | 没有可用邻居 -> 不动（不绕回）
       * ```
       * 因为起点矩形 = 全屏 scope 的 (0,0,960,540)，
       * 从整屏中心出发任何方向都没有合法邻居 —— 用户看到的就是"遥控器失灵"。
       */
      expect(moved, isTrue,
          reason: '★ 进详情页后按方向键必须能移动。修复前起点是全屏 scope，'
              '实测 moved=false —— 这就是"进了详情页方向键完全没反应"');
      expect(detailRight.hasPrimaryFocus, isTrue,
          reason: '★ 焦点必须落在**详情页右边那个控件**上。'
              '只断言"焦点变了"不够 —— 它也可能落在首页残留控件上，'
              '那正是真机反复打开详情页的成因');

      /*
       * ★ 证明走的是**新分支**（"起点是容器 -> 先 prime"），而不是碰巧。
       *
       * 「方向键能动了」有两种成因，回归风险完全不同：
       * ```text
       * A. 焦点本来就落在真控件上 → 正常算邻居
       * B. 起点是容器 → 先 prime 再算邻居（★ 本次修复新增的分支）
       * ```
       * 只看"焦点动了"分不出这两者，而 B 一旦退化，症状和修复前**一模一样**。
       */
      expect(spatialNavPrimedRect, isNotNull,
          reason: '★ 这一步必须是由"起点是容器 -> 先 prime"这条新分支完成的。'
              '若为 null，说明焦点不知何时已经落在真控件上 —— '
              '那测的就不是本缺陷的修复路径了');
      expect(spatialNavPrimedRect, isNot(_fullScreen),
          reason: '种下的焦点必须是真控件，不能又是整屏容器');
    });

    testWidgets('⑥ 真按钮 + 真 ENTER：确认键激活的必须是**详情页**的按钮', (t) async {
      _setTvViewport(t);

      var homeOpens = 0;
      var detailActivations = 0;

      /*
       * ⚠️ 必须给按钮**显式** `focusNode`。
       *
       * `TextButton` 内部会自建一个 `Focus`，但那个节点拿不到
       * （`Focus.of(buttonContext)` 会抛 "does not contain a Focus widget" ——
       * 实测踩到）。而本测试要断言"ENTER 打在了哪个按钮上"，
       * 所以必须能**指名道姓**地种焦点、读状态。
       */
      final homeBtn = FocusNode(debugLabel: '首页按钮');
      final detailBtn = FocusNode(debugLabel: '详情页按钮');
      addTearDown(homeBtn.dispose);
      addTearDown(detailBtn.dispose);

      final navKey = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('home-btn'),
              focusNode: homeBtn,
              onPressed: () {
                homeOpens++;
                navKey.currentState!.push(MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: Column(children: [
                      TextButton(
                        key: const ValueKey('detail-btn'),
                        focusNode: detailBtn,
                        onPressed: () => detailActivations++,
                        child: const Text('详情页按钮'),
                      ),
                    ]),
                  ),
                ));
              },
              child: const Text('首页卡片'),
            ),
          ),
        ),
      ));

      // ① 用真 ENTER 打开详情页（复刻"遥控器 OK 进详情页"）
      homeBtn.requestFocus();
      await t.pump();
      expect(homeBtn.hasPrimaryFocus, isTrue, reason: '起点没种上');

      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();

      expect(homeOpens, 1, reason: '前置：ENTER 必须能打开详情页（真路径）');
      debugPrint('【缺陷② ENTER】进详情页后 '
          'primaryFocus=${_describe(FocusManager.instance.primaryFocus)}');

      /*
       * ★★ 真机实测到的症状（AF 观察）：
       * ```text
       * 用方向键进播放页时，日志显示每轮 ENTER 都在重复
       * [NAV] 打开详情: cycani:2209  —— 卡在反复打开详情页
       * ```
       * 因为详情页是新路由、焦点没被放上去 → ENTER 一直打在**首页卡片**上。
       *
       * 这里把那个症状写成断言：详情页的按钮必须能收到 ENTER。
       *
       * ⚠️ 只按 ENTER 还不够 —— 必须先让"起点是容器 -> 先 prime"生效，
       *    所以这里先按一次方向键（真机顺序也是这样）。
       */
      final moved = moveFocus(NavDir.right);
      await t.pump();
      await t.pump();
      debugPrint('【缺陷② ENTER】移动 moved=$moved log=$spatialNavLog');

      final opensBefore = homeOpens;
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();

      debugPrint('【缺陷② ENTER】homeOpens=$homeOpens '
          'detailActivations=$detailActivations detailBtnHasFocus='
          '${detailBtn.hasPrimaryFocus}');

      expect(detailActivations, 1,
          reason: '★ 详情页上的 ENTER 必须激活**详情页**的按钮。'
              '修复前焦点还在容器上，ENTER 什么都不会激活（激活数=0）');
      expect(homeOpens, opensBefore,
          reason: '★★ ENTER **不能**再打在首页卡片上 —— '
              '那正是真机"卡在反复打开详情页"的症状');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  底栏可达性（两轮搜索 + BottomBarMarker）—— 真路径
  // ═══════════════════════════════════════════════════════════════════
  group('★ 底栏可达（真路径 + 结构标记）', () {
    testWidgets('⑦ 内容区按 down 落到底栏，且**必须**由第二轮搜索救回', (t) async {
      _setTvViewport(t);
      final content = FocusNode(debugLabel: '内容');
      final tabA = FocusNode(debugLabel: '底栏A');
      final tabB = FocusNode(debugLabel: '底栏B');
      addTearDown(content.dispose);
      addTearDown(tabA.dispose);
      addTearDown(tabB.dispose);

      /*
       * ★ 几何先算过（否则测不到"两轮搜索"这个机制）：
       * ```text
       * content  : (0,100)-(148,300)   cx=74   bottom=300
       * 底栏 tabA : (0,480)-(148,540)  cx=74   top=480
       * 底栏 tabB : (148,480)-(296,540) cx=222 top=480
       * ```
       * 从 content 按 ↓（`_verticalCrossLimit = 360`）：
       * ```text
       * tabA cross=|74-74|=0     -> 通过
       * tabB cross=|222-74|=148  -> 通过
       * ```
       * 两个 tab 的 cross **都没超限** —— 所以第一轮找不到它们
       * **只可能是因为被 `exclude: _isInBottomBar` 排除了**。
       * 这正是两轮搜索要验证的机制：若第一轮就命中，
       * 说明 `BottomBarMarker` 结构排除失效，底栏可达是"假通过"。
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
      await t.pump();

      debugPrint('【底栏可达】moved=$moved log=$spatialNavLog');
      expect(moved, isTrue, reason: '内容区往下必须能落到底栏 —— 否则用户被困在首页');
      expect(tabA.hasPrimaryFocus, isTrue,
          reason: '★ 焦点必须落在几何上最合适的 tabA（cross=0），'
              '不是"底栏里随便哪个 tab"');
      expect(spatialNavLog.join(' '), contains('允许落底栏（第二轮）'),
          reason: '★ 必须由**第二轮**搜索救回底栏 —— 若第一轮就命中，'
              '说明 BottomBarMarker 的结构排除没生效，底栏可达是"假通过"');
    });

    testWidgets('⑧ 底栏是最后一行：从底栏按 down 不动（防绕圈）', (t) async {
      _setTvViewport(t);
      final tab = FocusNode(debugLabel: '底栏');
      final below = FocusNode(debugLabel: '底栏后面的内容');
      addTearDown(tab.dispose);
      addTearDown(below.dispose);

      /*
       * 复刻真机形状（底栏**浮在**内容之上，内容在它下面继续）：
       * ```text
       * 底栏 tab : (0,150)-(100,210)  中心 y=180
       * 内容     : (0,200)-(120,500)  中心 y=350   ← 几何上在底栏**下方**
       * ```
       * 从 tab 按 ↓：`below` 中心 y=350 > 180+4 -> 是**合法候选**。
       * 所以焦点**会**被带走 —— 除非结构守卫生效。
       * 这才能证明守卫在起作用，而不是"本来就没候选"。
       */
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            Column(children: [
              const SizedBox(height: 200),
              Row(children: [
                _Cell(node: below, label: '底栏后面的内容', w: 120, h: 300),
              ]),
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
      await t.pump();

      debugPrint('【底栏守卫】moved=$moved log=$spatialNavLog');
      expect(moved, isFalse,
          reason: '底栏是视觉上最底部那一排 —— 从它往下必须不动，'
              '否则焦点成环（真机实测连按十几次 ↓ 停不下来）');
      expect(tab.hasPrimaryFocus, isTrue, reason: '焦点必须留在底栏上');
      expect(spatialNavLog.join(' '), contains('已在底栏 + 目标是内容区 -> 不动'),
          reason: '必须是被**结构守卫**拦下的 —— 而不是"没找到候选"');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  居中布局：缺陷①到底能吃掉哪些方向（可证伪性核实）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么要写这一组（2026-09-25 我用 redness proof 抓到自己的空测试）
  //
  // 我一开始按"缺陷① = 焦点在屏幕中心就会被吃掉"写了一个
  // **四个方向全测**的循环。跑 redness proof（撤掉修复再跑）时发现：
  // ```text
  // ⑤ ⑥ 报红 ✓   —— 缺陷②
  // ① ② ③ 报红 ✓ —— 缺陷①
  // ⑨ up/down/left/right 四个 —— **全都没报红** ✗
  // ```
  // 也就是说那四条**不可证伪**（修复前后都是绿的）。
  //
  // # 根因：缺陷①只在 **up / down** 上成立
  //
  // 因为主轴推进量 `main` 的算法在横向和纵向上**不一样**：
  // ```text
  // 左右: main = r.left - from.right        ← **边**判据
  //       scope 的 left=0，而任何真控件的 right > 0
  //       -> main = 0 - from.right < -4  -> 方向不符，被跳过
  //
  // 上下: centerDelta = |cy - fromCy|        ← **中心点**判据
  //       scope 的 cy=270，控件在屏幕上半部时 fromCy < 270
  //       -> centerDelta ≥ 4 -> 通过！
  // ```
  // 所以左/右方向上全屏 scope **从来不是候选**（不是"没赢"，是"没参赛"）。
  //
  // # 这个区分是**有价值的**，不是补丁
  //
  // ```text
  // up / down  -> 可证伪：修复前必红（真控件被"离屏幕中心更近"的 scope 赢走）
  // left/right -> 不可证伪：修复前后都绿，属于**回归哨兵**（防止将来
  //               main 判据被改成中心点制之后缺陷①从这两个方向复活）
  // ```
  // 如实分开标注，而不是把四条都写成"防复发"——
  // 那会让读者以为左右方向也验证了缺陷①。
  group('★ 居中布局：缺陷①能吃掉的方向（up/down，可证伪）', () {
    /*
     * 几何（★ 每个数字都是**算过**的，不是摆好看的）
     *
     * 缺陷①成立需要同时满足三件事：
     * ```text
     * ① 当前焦点**横向**居中  -> scope 的 cross = |480 - cx| 才会小
     * ② 当前焦点**纵向偏离**屏幕中心 270 至少 4px
     *    -> 否则 down/up 的 centerDelta < MIN_ADVANCE(4)，
     *       scope 连候选都不是（这一点我踩过：cy=270 时测试**不可证伪**）
     * ③ scope 的代价 < 真控件的代价
     * ```
     *
     * 所以 up 和 down 的 mid 位置**不一样**：
     * ```text
     * down 用例: mid 在中心**上方**(cy=230) -> centerDelta(270-230=40) ≥ 4 ✓
     * up   用例: mid 在中心**下方**(cy=310) -> centerDelta(310-270=40) ≥ 4 ✓
     * ```
     * 两者都是「横向居中」（这才是缺陷的本体：cross≈0）。
     *
     * scope 的代价（`_crossWeightVertical = 0.25`）：
     * ```text
     * main = 0 - from.bottom < 0  -> clamp 到 0
     * cross = |480 - 480| = 0
     * cost = 0 + 0x0.25 = 0
     * 真控件 = main(200) + 0x0.25 = 200
     * ```
     * 0 < 200 -> scope 必赢 -> 修复前这**两条都会报红**。
     */
    for (final entry in const {'up': NavDir.up, 'down': NavDir.down}.entries) {
      testWidgets('⑨ 横向居中的控件按 ${entry.key} 能走到真实邻居', (t) async {
        _setTvViewport(t);
        final mid = FocusNode(debugLabel: '正中');
        final target = FocusNode(debugLabel: '目标-${entry.key}');
        addTearDown(mid.dispose);
        addTearDown(target.dispose);

        final d = entry.value;
        final isUp = d == NavDir.up;
        // mid: 横向居中(cx=480)；up 时在中心下方，down 时在中心上方
        final midTop = isUp ? 280.0 : 200.0; // cy = 310 / 230
        final body = Stack(children: [
          Positioned(
            // 目标在**同一列**（cx=480）-> cross=0，是合法邻居
            left: 430,
            top: isUp ? 40 : 460,
            child: _Cell(node: target, label: '目标-${entry.key}'),
          ),
          Positioned(
            left: 430,
            top: midTop,
            child: SizedBox(
              width: 100,
              height: 60,
              child: Focus(focusNode: mid, child: const Text('正中')),
            ),
          ),
        ]);

        await t.pumpWidget(MaterialApp(home: Scaffold(body: body)));
        mid.requestFocus();
        await t.pump();
        expect(mid.hasPrimaryFocus, isTrue, reason: '起点没种上');

        // ★ 前置：证明"mid 横向居中 + 纵向偏离中心"确实成立
        //   —— 否则这条断言不可证伪（cy=270 时 scope 不是候选）
        final midBox = t.renderObject<RenderBox>(
          find.ancestor(
            of: find.text('正中'),
            matching: find.byType(SizedBox),
          ).first,
        );
        final midRect =
            midBox.localToGlobal(Offset.zero) & midBox.size;
        debugPrint('【⑨ ${entry.key}】mid=$midRect');
        expect(midRect.center.dx, 480.0, reason: '前置：必须横向居中');
        expect((midRect.center.dy - 270).abs(), greaterThanOrEqualTo(4.0),
            reason: '前置：必须纵向偏离屏幕中心 —— '
                '否则 centerDelta < MIN_ADVANCE，scope 不是候选，断言不可证伪');

        final moved = moveFocus(d);
        await t.pump();
        await t.pump();

        debugPrint('【⑨ ${entry.key}】moved=$moved log=$spatialNavLog');
        expect(moved, isTrue, reason: '${entry.key} 方向有邻居，必须能走到');
        expect(target.hasPrimaryFocus, isTrue,
            reason: '★ 焦点必须落到 ${entry.key} 方向的那个真控件上。'
                '修复前它会被全屏 scope 吃掉：'
                'moved=true 但 primaryFocus 仍是原节点 —— 与缺陷①①同源');
      });
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  回归哨兵：左右方向（**刻意标注为不可证伪**）
  // ═══════════════════════════════════════════════════════════════════
  group('☆ 回归哨兵（左右方向，修复前后都绿，不是缺陷①的证据）', () {
    /*
     * 这组**不能**用来证明缺陷①修好了 —— 见上面推导：
     * 左右方向用**边**判据（`main = r.left - from.right`），
     * 全屏 scope 的 `left=0` 必然让 `main` 为负 -> 它压根不是候选。
     *
     * 留着它的唯一价值：万一将来有人把上下/左右的 `main` 判据统一成
     * "中心点制"，缺陷①会从左右方向复活，这几条会立刻报红。
     */
    for (final entry in const {'left': NavDir.left, 'right': NavDir.right}.entries) {
      testWidgets('⑩ 屏幕中部的控件按 ${entry.key} 能走到真实邻居（哨兵）', (t) async {
        _setTvViewport(t);
        final mid = FocusNode(debugLabel: '正中');
        final target = FocusNode(debugLabel: '目标-${entry.key}');
        addTearDown(mid.dispose);
        addTearDown(target.dispose);

        final d = entry.value;
        final body = Stack(children: [
          Positioned(
            // 同一行（cy 对齐）保证 cross=0
            left: d == NavDir.left ? 100 : 700,
            top: 240,
            child: _Cell(node: target, label: '目标-${entry.key}'),
          ),
          Positioned(
            left: 400,
            top: 240,
            child: SizedBox(
              width: 100,
              height: 60,
              child: Focus(focusNode: mid, child: const Text('正中')),
            ),
          ),
        ]);

        await t.pumpWidget(MaterialApp(home: Scaffold(body: body)));
        mid.requestFocus();
        await t.pump();
        expect(mid.hasPrimaryFocus, isTrue, reason: '起点没种上');

        final moved = moveFocus(d);
        await t.pump();
        await t.pump();

        debugPrint('【⑩ ${entry.key}】moved=$moved log=$spatialNavLog');
        expect(moved, isTrue, reason: '${entry.key} 方向有邻居，必须能走到');
        expect(target.hasPrimaryFocus, isTrue,
            reason: '焦点必须落到 ${entry.key} 方向的那个真控件上');
      });
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 一次按键只移动一格（AH 的真机发现，任务 AI 复现并修）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 真机现象（我自己的 TV 实测日志，不是转述）
  //
  // ```text
  // [NAV] dir=NavDir.right 移动到 _BottomItem... | 选中=(252,450,404,522) | 已 requestFocus
  // [NAV] 帧后确认: ... 实际矩形=(404,450,556,522) 一致=false
  // ```
  // `选中` 与 `实际` 差 **152px = 正好一个 tab 宽度** ——
  // 算法选对了，但**有第二个搬运方**把它又推了一格。
  //
  // # 根因（Flutter SDK 源码）
  //
  // `HardwareKeyboard.addHandler` 的返回值**不会**中止派发
  // （`hardware_keyboard.dart` 里 `handled = handled || thisResult`，**不 break**），
  // 所以 `shell.dart` 的 `_onGlobalKey` 返回 `true` 之后，事件**照样**
  // 流到焦点树 → 内建 `DirectionalFocusIntent` **再搬一次**。
  //
  // # 为什么这组“必须在真机上才算数”，这里只能测**可测的那一半**
  //
  // `flutter_test` 里**没有** `HardwareKeyboard` 的物理派发链路
  // （`t.sendKeyEvent` 走的是测试绑定自己那条路），
  // 所以"两个 handler 都跑"这个现象**在单测里复现不出来**。
  //
  // 能测、且**值得**测的是：**机制本身**——
  // ```text
  // FocusManager.addEarlyKeyEventHandler 返回 handled
  //   -> 焦点树被跳过 -> DirectionalFocusIntent 不触发
  // ```
  // 这正是修复所依赖的那个性质。它一旦失效（比如将来有人改回 addHandler，
  // 或者 Flutter 改了 early handler 的语义），**这条会报红**。
  group('★ 一次按键只移动一格（early handler 的真正中止能力）', () {
    testWidgets('⑪ early handler 返回 handled 时，内建方向键遍历**不会**再移动一格',
        (t) async {
      _setTvViewport(t);
      final a = FocusNode(debugLabel: 'A');
      final b = FocusNode(debugLabel: 'B');
      final c = FocusNode(debugLabel: 'C');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      addTearDown(c.dispose);

      /*
       * 三个**横向排开**的控件，专门喂给内建 `DirectionalFocusIntent`：
       * ```text
       * A : (0,250)-(100,290)
       * B : (200,250)-(300,290)
       * C : (400,250)-(500,290)
       * ```
       * 从 A 按 → 时，内建遍历会走 A -> B（再按一次才到 C）。
       * 所以"是不是又前进了一格"在这个布局下**可判读**。
       */
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            Positioned(left: 0, top: 250, child: _Cell(node: a, label: 'A')),
            Positioned(left: 200, top: 250, child: _Cell(node: b, label: 'B')),
            Positioned(left: 400, top: 250, child: _Cell(node: c, label: 'C')),
          ]),
        ),
      ));
      a.requestFocus();
      await t.pump();
      expect(a.hasPrimaryFocus, isTrue, reason: '起点没种上');

      var calls = 0;
      KeyEventResult early(KeyEvent e) {
        calls++;
        // 复刻 shell.dart 的契约：方向键 -> handled（消费并中止）
        return KeyEventResult.handled;
      }

      FocusManager.instance.addEarlyKeyEventHandler(early);
      addTearDown(() => FocusManager.instance.removeEarlyKeyEventHandler(early));

      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      await t.pump();

      debugPrint('【⑪】early handler 调用次数=$calls '
          '焦点=${_describe(FocusManager.instance.primaryFocus)}');

      expect(calls, greaterThan(0),
          reason: '前置：early handler 必须被调到，否则这条断言恒真');
      expect(a.hasPrimaryFocus, isTrue,
          reason: '★ early handler 返回 handled 后，焦点树**整段被跳过** —— '
              '焦点必须一动不动。若这里变成 b/c，说明中止能力失效',
          );
    });

    testWidgets('⑫ 生产注册用的是 early handler 而**不是** HardwareKeyboard',
        (t) async {
      /*
       * 这一条是**静态契约**断言：直接查源码文本。
       *
       * # 为什么必须用文本断言（这个项目恰恰踩过"读文本"的坑）
       *
       * AF 发现 `bottom_bar_reach_test.dart` 把 .dart 当文本读做断言 ——
       * 那是**坏**的，因为它**替代**了行为测试（一行都不执行）。
       * 但"读文本"本身不是错的，错的是**用它冒充行为验证**。
       *
       * 这里它测的性质天生就是**静态**的：
       * 「`shell.dart` 里注册的是哪个 API」——
       * 它没有可观察的运行时行为（真要观察就得跑真机）。
       * 所以用文本断言是**合适的**，而且它正是防"改回 addHandler"的哨兵。
       *
       * ⚠️ 必须**剥注释**再匹配 —— 本项目铁律：
       *    `Select-String` 会命中注释，"判断有没有调用"必须剥注释。
       *    我的修复注释里就写着 `addHandler` 这个词（解释为什么不用它），
       *    不剥注释的话这条断言会**永远为真**（假通过）。
       */
      final src = File('lib/shell.dart').readAsStringSync();
      final code = src
          .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
          .replaceAll(RegExp(r'//[^\n]*'), '');

      expect(code, contains('FocusManager.instance.addEarlyKeyEventHandler('),
          reason: '★ 必须用 early handler 注册 —— 只有它的返回值能真正中止派发');
      expect(code, isNot(contains('HardwareKeyboard.instance.addHandler(')),
          reason: '★★ 不能再用 HardwareKeyboard.addHandler —— '
              '它的返回值不中止派发，会导致"一次按键移动两格"（真机实测）');
      expect(code, contains('removeEarlyKeyEventHandler('),
          reason: '注册与注销必须配对，否则页面销毁后 handler 仍活着');
    });
  });
}
