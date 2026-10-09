// ═══════════════════════════════════════════════════════════════════════
//  空间导航三缺陷 + 自锁 —— **真路径**回归测试（任务 AN，2026-09-25）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须新建这个文件（我用 Python 扫过现有测试的覆盖情况）
//
// ```text
// test/probe_cleanup_test.dart（AF，5 条全绿）
//   import spatial_nav      1 处   ✓
//   moveFocus() 调用        5 处   ✓
//   primeFocus() 调用       0 处   ★★★ 缺陷② 完全没覆盖
//   SpatialNavHandler       6 处   ✓
//   BottomBarMarker         4 处   ✓
//   真实 MaterialApp        5 处   ✓
//   Navigator.push          0 处   ★ 路由切换路径没覆盖
// ```
// 而缺陷② 的**根因**恰恰只在"真实路由"里成立
// （`_ModalScopeState` 一挂载就持有主焦点 → 旧守卫必然提前返回）。
// 缺陷③ 与自锁同理：它们的触发点都不在"手搓一棵树"里。
//
// # 本文件与既有两个测试文件的分工（刻意不重复）
//
// ```text
// probe_cleanup_test.dart  基础契约（真实几何 + 生产实现）
// tv_dpad_real_test.dart   缺陷①的**危害**（居中布局 → 焦点被 scope 吃掉）
// 本文件（AN）             ★ 四条修复点的**逐条防复发断言**
//                         ① 候选池里不含容器（直接断言**根因**，不是症状）
//                         ② 真 Navigator.push + primeFocus + 路由观察者
//                         ③ 真 ShellPage 的 early handler → 一次按键**一格**
//                         ④ 自锁：不依赖按键的触发点真的把焦点种上
// ```
//
// ═══════════════════════════════════════════════════════════════════════
//  ★★ 断言纪律（本项目已 7 次「断言在错误范围上跑」）
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// ① 每个断言前先**证明起点成立** —— 否则断言恒真
// ② 断言**控件身份**（same / hasPrimaryFocus），不是"矩形变了"
//    「某个按键有反应」≠「这个按键完成了它该完成的事」
// ③ 必须用真实 MaterialApp + 真实 Navigator.push + 真实 ShellPage
//    （本项目踩过「用手搓 Column 测自己的构造」：测的全是 Flutter 内建遍历）
// ④ 每条断言都要**对修复前的代码报红** —— 见 .probe/an_redness.py
//    （它在**隔离副本**里做逆向还原，生产工程一字不改）
// ```
//
// # ★ 本文件里每一个"魔法数字/时序"都是**实测**出来的
//
// 写这个文件之前先跑了 8 组探针（`.probe/an_*_probe_test.dart`）把真实行为量出来，
// 因为本轮已经 7 次「断言在错误范围上跑」。两个**反直觉**的实测结论直接
// 改变了本文件的写法，都在对应用例的注释里写明了：
// ```text
// · `primeFocusSoon()` 后面必须 `pumpAndSettle()`，**不能**只 pump 一次
//   （只 pump 一次会看到"什么都没发生"，从而写出一个假的报红）
// · 真 ShellPage 的底栏 `_BottomItem` 带 `autofocus: on`，
//   所以"焦点是叶子"在撤掉修复后**依然成立**（不可证伪）——
//   必须换成"落点 = 候选里最靠上的那个"才有判别力
// ```
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/spatial_nav.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

/// 可聚焦块
///
/// ⚠️ 必须**显式**传 `focusNode` —— 不传的话 `requestFocus()` 静默无效，
///    测试会"通过"但什么都没测到（`focus_narrow_test.dart` 记过这个坑）。
class _Cell extends StatelessWidget {
  const _Cell({
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
/// # 为什么必须显式设（否则缺陷①根本触发不到）
///
/// `flutter_test` 默认视口是 **800x600**，屏幕中心是 (400,300)。
/// 而缺陷①的触发条件是「当前焦点中心靠近**屏幕中心**」——
/// 视口不对，几何就算不对，等于**取样框打偏**。
void _tvViewport(WidgetTester t) {
  t.view.physicalSize = const Size(960, 540);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

/// 整屏矩形（960x540 视口下）
const Rect _fullScreen = Rect.fromLTRB(0, 0, 960, 540);

/// 取某个焦点节点的矩形（拿不到返回 null）
Rect? _rectOf(FocusNode n) {
  final ro = n.context?.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

/// 取当前主焦点的「结构身份 + 矩形」——**可判读**的证据输出
///
/// 只报矩形无法断言"焦点到了哪个控件"（本项目已踩过），
/// 所以类型、是否 scope、子节点数一起打出来。
String _describe(FocusNode? n) {
  if (n == null) return '<null>';
  return '${n.debugLabel ?? n.runtimeType}'
      '(isScope=${n is FocusScopeNode}, kids=${n.children.length}, '
      'rect=${_rectOf(n)})';
}

/// 焦点树里**矩形 = 整屏**的那些节点
///
/// # 为什么必须自己走一遍树（而不是"看候选池里有没有 960x540"）
///
/// 只断言"候选池里没有整屏矩形"有一个漏洞：**万一候选池是空的**，
/// 这条断言**恒真**。所以必须同时证明"这些容器**确实存在**于树上"——
/// 它们是真实存在、且**满足 `_collect()` 的其余条件**的节点，
/// 只是被叶子判据挡掉了。
///
/// 实测（960x540，真实 MaterialApp）这些节点有 11 个：
/// ```text
/// View Scope / Navigator Scope / _ModalScopeState Focus Scope
/// 以及 FocusTraversalGroup / Shortcuts / Navigator 等中间层
/// ```
/// 它们**全都**满足 `canRequestFocus && !skipTraversal` ——
/// 所以修复前它们全都会混进候选池（这正是缺陷①）。
List<({FocusNode node, Rect rect})> _fullScreenNodes() {
  final out = <({FocusNode node, Rect rect})>[];
  void walk(FocusNode n) {
    for (final c in n.children) {
      final r = _rectOf(c);
      if (r != null && r.width >= 959 && r.height >= 539) {
        out.add((node: c, rect: r));
      }
      walk(c);
    }
  }

  walk(FocusManager.instance.rootScope);
  return out;
}

/// 把 3 个可聚焦控件**横向排开**（喂给内建 `DirectionalFocusIntent` 用）
///
/// 从 A 按 → 时：内建遍历走 A -> B（再按一次才到 C）。
/// 所以"是不是又前进了一格"在这个布局下**可判读**。
///
/// ⚠️ `Stack` 必须放在**有界**的盒子里（`SizedBox`）——
///    直接塞进 `Column` 会抛 `A Stack requires bounded constraints`，
///    那会让测试以"有异常"失败，测的就变成布局而不是方向键了（实测踩到）。
Widget _threeInARow(FocusNode a, FocusNode b, FocusNode c) => SizedBox(
      width: 300,
      height: 40,
      child: Stack(
        children: [
          Positioned(left: 0, top: 0, child: _Cell(node: a, label: 'A')),
          Positioned(left: 100, top: 0, child: _Cell(node: b, label: 'B')),
          Positioned(left: 200, top: 0, child: _Cell(node: c, label: 'C')),
        ],
      ),
    );

/// `shell.dart` 的 `_onGlobalKey` 对方向键的**契约**
///
/// # 为什么要在测试里复刻它
///
/// `_onGlobalKey` 是私有的，测试调不到。而缺陷③ 的**根因**是
/// 「同一份契约换一个注册 API，行为就不一样了」——
/// 要证明这一点就必须能把**同一份判定逻辑**接到两条注册路径上。
///
/// 契约（照抄 `shell.dart` 的文档与实现）：
/// ```text
/// 方向键   -> true   （消费掉，防止 Scrollable 同时滚页面）
/// 其余按键 -> false  （放行给焦点树 / 播放器快捷键 / 输入框）
/// ```
/// 方向键分支里调用的是**生产实现** `moveFocus`，不是另写一套算法。
bool _arrowContract(KeyEvent e) {
  if (e is! KeyDownEvent) return false;
  final k = e.logicalKey;
  final isArrow = k == LogicalKeyboardKey.arrowUp ||
      k == LogicalKeyboardKey.arrowDown ||
      k == LogicalKeyboardKey.arrowLeft ||
      k == LogicalKeyboardKey.arrowRight;
  if (!isArrow) return false;
  moveFocus(NavDir.right);
  return true;
}

/// 同一个契约的 `KeyEventResult` 版本（= `shell.dart` 的 `_onEarlyKey`）
KeyEventResult _arrowContractEarly(KeyEvent e) =>
    _arrowContract(e) ? KeyEventResult.handled : KeyEventResult.ignored;

/// 在 `initState` 里调 `primeFocusSoon()` —— **一字不差地复刻** `shell.dart:1236`
///
/// # 为什么不能"直接调一次 primeFocusSoon"
///
/// 实测（探针 Y2 / Z1）：`primeFocusSoon()` 的成败**取决于它被调用的时刻**。
/// 在 `pumpWidget` 之后再手动调一次（那时已经多跑了一帧），
/// 回调里读到的 `primaryFocus` 会是 `null`（一个转瞬即逝的中间态），
/// `requestFocus()` 种下去的焦点随后被路由的 `ModalScope` **覆盖掉** ——
/// 于是测试看到"什么都没发生"，而生产里**根本没有这个时刻**
/// （`shell.dart` 只在 `initState` 里调一次）。
///
/// 所以测试必须复刻**生产的生命周期位置**，而不是"随便找个时机调一下"。
/// 否则测的是"我调用时机选错了"，不是"这个修复有没有用"。
class _PrimeOnInit extends StatefulWidget {
  const _PrimeOnInit({required this.child});

  final Widget child;

  @override
  State<_PrimeOnInit> createState() => _PrimeOnInitState();
}

class _PrimeOnInitState extends State<_PrimeOnInit> {
  @override
  void initState() {
    super.initState();
    // ★ 与 `shell.dart` 的 `_ShellPageState.initState` 里的那一行完全一致
    primeFocusSoon();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  缺陷①：`_collect()` 把全屏 `FocusScopeNode` 当候选
  // ═══════════════════════════════════════════════════════════════════
  //
  // 修法：`bool _isLeafFocusTarget(FocusNode n) => n.children.isEmpty;`
  //       （`spatial_nav.dart:249`，用在 `_collect()` 的候选过滤里）
  //
  // # 为什么这一组断言的是**根因**而不是症状
  //
  // 症状是"焦点不动"。但同一个全屏 scope 换个布局就会以**别的**方式
  // 造成危害（比如把 `primeFocus` 的落点抢走）——
  // 那时"焦点不动"这个症状根本不会出现，防复发断言就失效了。
  // 所以必须直接看到**候选集合本身**。
  group('★ 缺陷①：候选池里不能有容器（断言根因）', () {
    testWidgets('①-A 候选池里【不含】任何矩形 = 整屏的节点', (t) async {
      _tvViewport(t);
      final a = FocusNode(debugLabel: 'A');
      final b = FocusNode(debugLabel: 'B');
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      /*
       * 几何（960x540）：两个控件都**横向居中**（cx=480）。
       * 这正是缺陷①的触发形状 —— 当前焦点中心靠近屏幕中心时
       * `cross` 趋近 0，全屏 scope 必然以最低成本赢走这次移动。
       */
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
      expect(a.hasPrimaryFocus, isTrue, reason: '起点没种上，断言无意义');

      // 驱动一次真实导航，让 `_collect()` 跑起来并同步候选池
      moveFocus(NavDir.down);
      await t.pump();

      final containers = _fullScreenNodes();
      debugPrint('【①-A】候选池=${spatialNavCandidates}');
      debugPrint('【①-A】树上的全屏容器 ${containers.length} 个：'
          '${containers.map((e) => _describe(e.node)).join(" | ")}');

      /*
       * ★★ 前置：证明这些容器**真的存在**。
       *
       * 没有这一条的话，下面"候选池里没有整屏矩形"可能是因为
       * **根本没收集到任何东西**（恒真）——
       * 那正是本项目反复踩的「断言在错误范围上跑」。
       */
      expect(containers, isNotEmpty,
          reason: '前置：真实 MaterialApp 树上必然有全屏容器'
              '（View Scope / Navigator Scope / ModalScope 等）。'
              '若这里为空，说明取值方式错了，下面的断言恒真');
      expect(containers.any((e) => e.node is FocusScopeNode), isTrue,
          reason: '前置：其中必须有 FocusScopeNode —— 那才是缺陷①的主角');

      // 候选池必须非空（否则"没有整屏矩形"是假通过）
      expect(spatialNavCandidates, isNotEmpty,
          reason: '前置：候选池不该是空的，否则这条断言恒真');

      /*
       * ★★ 核心断言：候选池里不能出现**任何一个**容器的矩形。
       *
       * 修复前 `_collect()` 的条件是 `canRequestFocus && !skipTraversal`，
       * 而上面这些容器**全都满足** —— 它们的矩形会直接进候选池。
       * 实测修复前候选池里就有 (0,0,960,540)。
       */
      for (final c in containers) {
        expect(spatialNavCandidates, isNot(contains(c.rect)),
            reason: '★ 候选池里出现了容器 ${_describe(c.node)} 的矩形 ${c.rect} —— '
                '这就是缺陷①：`FocusScopeNode` 混进了候选池，'
                '它的整屏矩形会在代价函数下赢走焦点');
      }
    });

    testWidgets('①-B 候选数量 = 真控件数量（容器一个都不算）', (t) async {
      _tvViewport(t);
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

      debugPrint('【①-B】候选=${spatialNavCandidates} '
          '容器数=${_fullScreenNodes().length}');

      /*
       * ★ 页面上只有 **2 个**真控件，候选就必须**正好 2 个**。
       *
       * # 为什么计数断言在这里**有判别力**（不是"脆弱的魔数"）
       *
       * 修复前混进来的是**固定的一组框架容器**（实测 11 个全屏节点里
       * 有 3 个 `FocusScopeNode`，其余是中间层），它们**与布局无关**。
       * 而"真控件数量"由本测试自己写死 —— 两边都是确定的，
       * 所以这个数字**能区分**"2 个真控件"和"2 个真控件 + N 个容器"。
       *
       * ⚠️ 若将来 Flutter 的框架树增删了中间层，这个数字会变 ——
       *    那时**先看 ①-A**（它按"矩形=整屏"动态取容器，不依赖魔数），
       *    再更新这里。
       */
      expect(spatialNavCandidates.length, 2,
          reason: '★ 页面上只有 2 个可聚焦控件，候选池就必须只有 2 个。'
              '修复前这里会大于 2（框架容器混进来了）—— '
              '实测的容器节点见 ①-A 的 debugPrint');
    });

    testWidgets('①-C 危害：焦点居中时，方向键必须让 primaryFocus **真的**变', (t) async {
      _tvViewport(t);
      final mid = FocusNode(debugLabel: '正中');
      final target = FocusNode(debugLabel: '下方目标');
      addTearDown(mid.dispose);
      addTearDown(target.dispose);

      /*
       * ★ 几何**先算过**才写（否则触发不到缺陷）：
       * ```text
       * 正中     : (430,200)-(530,260)   cx=480  cy=230  bottom=260
       * 下方目标 : (430,460)-(530,500)   cx=480  top=460
       * 全屏scope: (0,0)-(960,540)       cx=480  cy=270
       * ```
       * 按 ↓ 的代价（`_crossWeightVertical = 0.25`）：
       * ```text
       * 下方目标   = main(460-260=200) + cross(0)x0.25 = 200
       * 全屏 scope = main(0-260 -> clamp 0) + cross(0)x0.25 = 0   ← ★ 必然赢
       * ```
       * `cross` 必须是 0（横向居中）才会触发 —— 这也是**真机首页
       * 测不出来**的原因：首页元素都在左侧，cross 很大，scope 赢不了。
       */
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            Positioned(
              left: 430,
              top: 460,
              child: _Cell(node: target, label: '下方目标'),
            ),
            Positioned(
              left: 430,
              top: 200,
              child: SizedBox(
                width: 100,
                height: 60,
                child: Focus(focusNode: mid, child: const Text('正中')),
              ),
            ),
          ]),
        ),
      ));
      mid.requestFocus();
      await t.pump();
      expect(mid.hasPrimaryFocus, isTrue, reason: '起点没种上，断言无意义');

      // ★ 前置：证明"横向居中 + 纵向偏离屏幕中心"确实成立
      //   —— 否则 centerDelta < MIN_ADVANCE(4)，scope 不是候选，断言不可证伪
      final midRect = _rectOf(mid)!;
      expect(midRect.center.dx, 480.0,
          reason: '前置：必须横向居中（cross=0 才会触发缺陷）');
      expect((midRect.center.dy - 270).abs(), greaterThanOrEqualTo(4.0),
          reason: '前置：必须纵向偏离屏幕中心 —— 否则 scope 连候选都不是');

      final before = FocusManager.instance.primaryFocus;
      final moved = moveFocus(NavDir.down);
      await t.pump();
      await t.pump();

      debugPrint('【①-C】moved=$moved 起点=${_describe(before)} '
          '终点=${_describe(FocusManager.instance.primaryFocus)}');

      /*
       * ★★ 核心：`moveFocus` 的返回值**不足以**说明焦点动了。
       *
       * 修复前实测：
       * ```text
       * moved=true                       ← 返回值说"我请求移焦了"
       * 选中=(0,0,960,540)               ← 选中的是全屏 scope
       * 目标 hasPrimaryFocus=false       ← 焦点**一步都没走**
       * ```
       * 这正是本项目那条纪律：「某个按键有反应」≠「这个按键完成了它该完成的事」。
       */
      expect(moved, isTrue, reason: '下方有卡片，算法应该找到它');
      expect(FocusManager.instance.primaryFocus, same(target),
          reason: '★ 主焦点必须**就是**下方目标控件本身'
              '（不是某个矩形碰巧一样的容器）。修复前它会被全屏 scope 抢走');
      expect(target.hasPrimaryFocus, isTrue, reason: '同上');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  缺陷②：`primeFocus` 的触发分支不可达 → 新路由上方向键失灵
  // ═══════════════════════════════════════════════════════════════════
  //
  // 修法：`if (cur != null && _isLeafFocusTarget(cur)) return false;`
  //       （`spatial_nav.dart:1303`，旧写法是 `if (cur != null) return false;`）
  //
  // # 为什么必须用**真实 Navigator.push**
  //
  // 旧注释把根因写成「详情页里没有地方设过焦点 → primaryFocus == null」。
  // 实测**推翻了它**：路由的 `ModalScope` 一挂载就自动持有主焦点，
  // 所以 `primaryFocus` **永远不是 null**。这个事实**只有真实路由树**才有 ——
  // 手搓的裸树里 `primaryFocus` 真的是 null，旧守卫反倒会"生效"，
  // 于是测试全绿而线上全挂。这正是本项目踩过的
  // 「用手搓 Column 测自己的构造」。
  group('★ 缺陷②：真实 Navigator.push 后 primeFocus 真的种上焦点', () {
    /// 造一个"首页 + 可 push 的详情页"的真实路由环境
    ///
    /// # 为什么首页**必须**先 `requestFocus()`
    ///
    /// 实测（探针 Z2）：如果首页从不请求焦点，那么 push 之后
    /// 老路由的 `ModalScope` 会变成 `skipTraversal=true`（被新路由顶掉），
    /// 而新路由的 `ModalScope` 那一刻**还没有子节点** ——
    /// 于是它满足叶子判据（`children.isEmpty`），`primeFocus()` 提前返回。
    ///
    /// 也就是说：**缺陷② 只在"上一个页面有焦点"时才暴露**。
    /// 而真机上用户进详情页之前一定在首页选过片（有焦点），
    /// 所以先 `requestFocus()` 才是**真机路径**，不是人为制造条件。
    Future<void> mountHome(
      WidgetTester t,
      FocusNode homeBtn,
      FocusNode detailLeft,
      FocusNode detailRight,
    ) async {
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: Scaffold(
          body: Center(child: _Cell(node: homeBtn, label: '首页控件')),
        ),
      ));
      homeBtn.requestFocus();
      await t.pump();
      expect(homeBtn.hasPrimaryFocus, isTrue, reason: '起点没种上');

      /*
       * ★ 详情页控件放**顶部**：
       * ```text
       * 详情左 : (0,0)-(100,40)       ← 最靠上 -> prime 的落点
       * 详情右 : (190,0)-(290,40)
       * 首页   : (430,250)-(530,290)
       * ```
       * `primeFocus` 取"最靠上再最靠左"（原版 `focusFirst` 语义）
       * -> 详情左（top=0 胜过首页的 250）。
       */
      nav.currentState!.push(MaterialPageRoute<void>(
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
    }

    testWidgets('②-A 前置事实：push 后 primaryFocus 是**容器 scope**，不是 null',
        (t) async {
      _tvViewport(t);
      final homeBtn = FocusNode(debugLabel: '首页控件');
      final dl = FocusNode(debugLabel: '详情左');
      final dr = FocusNode(debugLabel: '详情右');
      addTearDown(homeBtn.dispose);
      addTearDown(dl.dispose);
      addTearDown(dr.dispose);

      await mountHome(t, homeBtn, dl, dr);

      final cur = FocusManager.instance.primaryFocus;
      debugPrint('【②-A】push 后 primaryFocus=${_describe(cur)}');

      /*
       * ★★ 这一条是**缺陷②的根因证据**，也是本组其余断言的前提。
       *
       * 旧注释写「详情页里没有地方设过焦点 → primaryFocus == null」——
       * 实测**推翻了它**：`_ModalScopeState` 一挂载就持有主焦点。
       */
      expect(cur, isNotNull,
          reason: '★ 真实路由树里 primaryFocus **不是** null —— 它被 '
              '_ModalScopeState 持有。若这里变成 null，说明 Flutter 行为变了，'
              '依赖"为 null"的旧守卫反倒会生效，判据需要重新核对');
      expect(cur, isA<FocusScopeNode>(),
          reason: '★ 进新路由后主焦点是个**容器**，不是任何用户能看见的控件');
      expect(cur!.children.isEmpty, isFalse,
          reason: '★ 而且这个容器**有子节点** —— 这正是叶子判据能区分它的原因'
              '（`_isLeafFocusTarget` = `children.isEmpty`）');
      expect(dl.hasPrimaryFocus, isFalse,
          reason: '前置：详情页确实没有任何地方设过焦点（本缺陷的触发条件）');
    });

    testWidgets('②-B primeFocus() 必须真的把焦点种到详情页控件上（身份断言）',
        (t) async {
      _tvViewport(t);
      final homeBtn = FocusNode(debugLabel: '首页控件');
      final dl = FocusNode(debugLabel: '详情左');
      final dr = FocusNode(debugLabel: '详情右');
      addTearDown(homeBtn.dispose);
      addTearDown(dl.dispose);
      addTearDown(dr.dispose);

      await mountHome(t, homeBtn, dl, dr);
      expect(dl.hasPrimaryFocus, isFalse, reason: '前置：详情页还没焦点');

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★ 内部可证伪性证明：把**修复前的守卫**复现出来
       * ══════════════════════════════════════════════════════════════
       *
       * `spatial_nav.dart` 修复前写的是：
       * ```dart
       * bool primeFocus() {
       *   final cur = FocusManager.instance.primaryFocus;
       *   if (cur != null) return false;      // ★ 缺陷②的直接原因
       *   return _primeTarget() != null;
       * }
       * ```
       * 这里把那个判据原样复现成一个局部函数 —— **不是为了调用它**，
       * 而是为了在断言里**显式证明"修复前在这里就会提前返回"**。
       * 这样"为什么需要这个修复"就变成了可执行的证据，
       * 而不是注释里的一句话。
       */
      bool preFixGuardBailsOut() =>
          FocusManager.instance.primaryFocus != null; // 旧写法只看"非空"

      debugPrint('【②-B】修复前的守卫会提前返回吗？'
          '${preFixGuardBailsOut()}  (true = 缺陷②成立)');

      expect(preFixGuardBailsOut(), isTrue,
          reason: '★ 修复前的守卫 `if (cur != null) return false;` 在这里'
              '**必然提前返回** —— 因为 ModalScope 已经持有主焦点。'
              '也就是说修复前的 `primeFocus()` 永远种不上焦点。'
              '若这里变成 false，说明 Flutter 行为变了、缺陷②不再成立');

      // ── 生产实现：必须真的种上 ──
      final primed = primeFocus();
      await t.pump();

      debugPrint('【②-B】primeFocus()=$primed 终点='
          '${_describe(FocusManager.instance.primaryFocus)}');

      expect(primed, isTrue,
          reason: '★ 生产 `primeFocus()` 必须返回 true。'
              '修复前（旧守卫）这里返回 false —— '
              '这就是上面那条内部对照的结论');
      expect(FocusManager.instance.primaryFocus, same(dl),
          reason: '★ 主焦点必须**就是**详情页左上角那个控件（身份断言）。'
              '只断言"焦点变了"不够 —— 它也可能落在首页残留控件上，'
              '那正是真机"卡在反复打开详情页"的成因');
      expect(dl.hasPrimaryFocus, isTrue, reason: '同上');
      expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()),
          reason: '★ 落点必须是**叶子控件**，不能又是容器');
      expect(dr.hasPrimaryFocus, isFalse,
          reason: '落点是"最靠上最靠左"的那一个 —— 只能是详情左');
      expect(homeBtn.hasPrimaryFocus, isFalse,
          reason: '★ 绝不能种回首页 —— 那等于焦点留在了上一个路由上');
    });

    testWidgets('②-C 真实 FocusPrimingObserver：进详情页后焦点**自动**落到详情页控件',
        (t) async {
      _tvViewport(t);
      final homeBtn = FocusNode(debugLabel: '首页控件');
      final dl = FocusNode(debugLabel: '详情左');
      final dr = FocusNode(debugLabel: '详情右');
      addTearDown(homeBtn.dispose);
      addTearDown(dl.dispose);
      addTearDown(dr.dispose);

      /*
       * ★ 这一条测的是**生产接线**：`shell.dart:1050` 把
       *   `FocusPrimingObserver()` 挂在 `MaterialApp.navigatorObservers` 上。
       *
       * 只测 `primeFocus()` 本身是不够的 —— 它可能"函数是对的，
       * 但从来没人调用"。真机上"进详情页遥控器失灵"的**本体**
       * 恰恰是"没人调用"（旧守卫让调用变成空操作）。
       */
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: nav,
        navigatorObservers: <NavigatorObserver>[FocusPrimingObserver()],
        home: Scaffold(
          body: Center(child: _Cell(node: homeBtn, label: '首页控件')),
        ),
      ));
      homeBtn.requestFocus();
      await t.pump();
      expect(homeBtn.hasPrimaryFocus, isTrue, reason: '起点没种上');

      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Column(children: [
            Row(children: [
              _Cell(node: dl, label: '详情左'),
              const SizedBox(width: 90),
              _Cell(node: dr, label: '详情右'),
            ]),
          ]),
        ),
      ));
      await t.pumpAndSettle();

      final afterPush = FocusManager.instance.primaryFocus;
      debugPrint('【②-C】push 后（未手动 prime、未按任何键）'
          'primaryFocus=${_describe(afterPush)}');

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这一条守的是一个**修好的真缺陷**（任务 AN 发现并修复）
       * ══════════════════════════════════════════════════════════════
       *
       * # 修复前的 `FocusPrimingObserver` 是**空操作**
       *
       * 旧写法只排一帧：
       * ```dart
       * void _prime() {
       *   WidgetsBinding.instance.addPostFrameCallback((_) => primeFocus());
       * }
       * ```
       * 而那一帧**必然**被守卫挡下 —— 因为 `didPush` 的回调跑在
       * **路由转场动画的第 1 帧**，那时焦点还在**老路由**的叶子上。
       * 逐帧取证（`.probe/an_obs11_probe_test.dart`）：
       * ```text
       * push 同帧       pf=首页(真控件)                  ← 焦点还在老路由
       * postFrame#1     进入 pf=首页  kids.isEmpty=true  → 守卫返回 false（正确！）
       * pump#0          pf=_ModalScopeState Focus Scope  ← ★ 转场在这里把它顶掉
       * pump#1..settle  pf=容器（再也没有东西来种）
       * ```
       * 守卫第 1 帧拒绝是**对的**（那一刻焦点确实是可用起点），
       * 错的是"只试一次" —— 真正的机会窗口在它后面。
       *
       * # A/B 对照证据（`.probe/an_obs12_probe_test.dart`，同一场景跑两遍）
       *
       * ```text
       * 【有 observer】 push 后 pf=_ModalScopeState Focus Scope  dl=false
       * 【无 observer】 push 后 pf=_ModalScopeState Focus Scope  dl=false   ← 逐字节相同
       * ```
       * **加不加这个 observer，行为完全一样** —— 它写在那儿但从未起过作用。
       *
       * # 修法：有界重试，成功即停
       *
       * 停止条件只有 `primeFocus()` 返回 true（真的种上了），
       * 最多 8 帧（新页面真没有可聚焦控件时不会无限排帧）。
       * 修完之后的同一条 A/B：
       * ```text
       * 【有 observer】 push 后 pf=详情左  dl=true    ★ 焦点自动到位
       * 【无 observer】 push 后 pf=容器     dl=false
       * ```
       *
       * ⚠️ 重试**不会**抢用户已选焦点：每一轮都要过 `primeFocus()`
       *    的同一个守卫（"焦点是叶子就不动手"）。
       *    上面第 1 次返回 false 正是这个守卫在起作用。
       */
      expect(afterPush, isNotNull, reason: '★ 进详情页后不能没有焦点');
      expect(afterPush, isNot(isA<FocusScopeNode>()),
          reason: '★ 不能停在容器上 —— 容器在算法眼里等价于"没有焦点"'
              '（起点矩形 = 整屏，任何方向都没有合法邻居）');
      expect(afterPush, same(dl),
          reason: '★★ 焦点必须**自动**落到详情页左上角那个控件上 —— '
              '**不需要用户先按一次方向键**。'
              '修复前 observer 是空操作，这里会是 ModalScope 容器；'
              '那意味着用户进详情页后**看不到焦点环**，'
              '不知道遥控器能往哪走（虽然按一下方向键能靠 moveFocus 兜底救回来）');
      expect(dl.hasPrimaryFocus, isTrue, reason: '同上');
      expect(homeBtn.hasPrimaryFocus, isFalse,
          reason: '★★ 焦点**不能留在首页控件上** —— '
              '那正是真机实测到的"每轮 ENTER 都在重复打开详情页"'
              '（焦点还在首页卡片上，ENTER 就一直打在它身上）');
    });

    testWidgets('②-C2 真实 FocusPrimingObserver：**返回上一页**后焦点要回到真控件',
        (t) async {
      _tvViewport(t);
      final homeBtn = FocusNode(debugLabel: '首页控件');
      final dl = FocusNode(debugLabel: '详情左');
      final dr = FocusNode(debugLabel: '详情右');
      addTearDown(homeBtn.dispose);
      addTearDown(dl.dispose);
      addTearDown(dr.dispose);

      /*
       * ★ 这一条覆盖 `FocusPrimingObserver.didPop`。
       *
       * # 为什么必须单独测 pop（不是"顺带"）
       *
       * `didPop` 的注释写着：
       * > 返回上一页后，原来那页的焦点可能被销毁了 -> 也要重新种
       *
       * 这是**另一条真实路径**：真机上用户看完详情按返回，
       * 如果焦点没被重新种上，首页的方向键就失灵了 ——
       * 而 `didPush` 那几条断言**完全覆盖不到**它。
       */
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: nav,
        navigatorObservers: <NavigatorObserver>[FocusPrimingObserver()],
        home: Scaffold(
          body: Center(child: _Cell(node: homeBtn, label: '首页控件')),
        ),
      ));
      homeBtn.requestFocus();
      await t.pump();
      expect(homeBtn.hasPrimaryFocus, isTrue, reason: '起点没种上');

      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Column(children: [
            Row(children: [
              _Cell(node: dl, label: '详情左'),
              const SizedBox(width: 90),
              _Cell(node: dr, label: '详情右'),
            ]),
          ]),
        ),
      ));
      await t.pumpAndSettle();

      // 复刻真机顺序：进详情页后按一次方向键 -> 焦点落到详情页
      final moved = moveFocus(NavDir.right);
      await t.pump();
      await t.pump();
      expect(moved, isTrue, reason: '前置：详情页里方向键必须能动');
      expect(dr.hasPrimaryFocus, isTrue, reason: '前置：焦点已落到详情页');

      // ★ 返回上一页
      nav.currentState!.pop();
      await t.pumpAndSettle();

      debugPrint('【②-C2】pop 后 primaryFocus='
          '${_describe(FocusManager.instance.primaryFocus)} '
          '候选=${spatialNavCandidates}');

      expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()),
          reason: '★ 返回后焦点不能停在容器上');
      expect(homeBtn.hasPrimaryFocus, isTrue,
          reason: '★ 返回上一页后焦点必须重新落回**首页那个控件**上。'
              '若留在详情页的节点上（或停在容器上），'
              '用户在首页按方向键就会失灵 —— 这正是 didPop 要修的问题');
    });

    testWidgets('②-C3 对照：**没有** observer 时焦点就停在容器上（证明 observer 在干活）',
        (t) async {
      _tvViewport(t);
      final homeBtn = FocusNode(debugLabel: '首页控件');
      final dl = FocusNode(debugLabel: '详情左');
      final dr = FocusNode(debugLabel: '详情右');
      addTearDown(homeBtn.dispose);
      addTearDown(dl.dispose);
      addTearDown(dr.dispose);

      /*
       * ★★ 这是 ②-C 的**反证**（与 ③-B/③-C 同一个手法）。
       *
       * # 为什么必须有这一条
       *
       * ②-C 断言"焦点自动落到详情左"。但如果**没有 observer 也能落到**，
       * 那 ②-C 就**不可证伪**（测的是别的东西在起作用）。
       * 本用例把 observer 拿掉，其余一字不改：
       * ```text
       * 有 observer -> pf=详情左   dl=true     ← ②-C
       * 无 observer -> pf=容器     dl=false    ← 本用例
       * ```
       * 两边一对比，"observer 真的在干活"就成了**可执行的事实**。
       *
       * 实测（`.probe/an_obs12_probe_test.dart`）修复前后各跑过一遍：
       * ```text
       * 修复前：【有】容器  【无】容器   ← 逐字节相同 = observer 是空操作
       * 修复后：【有】详情左 【无】容器   ← ★ 本用例守的就是这个差值
       * ```
       */
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: nav,
        // ★ 刻意**不挂** FocusPrimingObserver
        home: Scaffold(
          body: Center(child: _Cell(node: homeBtn, label: '首页控件')),
        ),
      ));
      homeBtn.requestFocus();
      await t.pump();
      expect(homeBtn.hasPrimaryFocus, isTrue, reason: '起点没种上');

      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Column(children: [
            Row(children: [
              _Cell(node: dl, label: '详情左'),
              const SizedBox(width: 90),
              _Cell(node: dr, label: '详情右'),
            ]),
          ]),
        ),
      ));
      await t.pumpAndSettle();

      final afterPush = FocusManager.instance.primaryFocus;
      debugPrint('【②-C3 无 observer】push 后 primaryFocus=${_describe(afterPush)}');

      expect(afterPush, isA<FocusScopeNode>(),
          reason: '★★ 没有 observer 时，焦点必然停在路由的 `ModalScope` 容器上 —— '
              '这是"路由转场把焦点顶掉"的直接证据。'
              '若这里变成了详情页控件，说明有别的东西在种焦点，'
              '那 ②-C 的结论就不能归功于 observer 了（判据需重新核对）');
      expect(dl.hasPrimaryFocus, isFalse,
          reason: '★ 没有 observer 就**没有**任何东西主动种焦点');

      /*
       * ★ 而且这个状态是**真的有问题**的：用户这时按 ENTER
       *   什么都不会发生（焦点在容器上，不是可激活的控件）。
       *   这正是"进详情页遥控器失灵"的原始症状。
       *
       * ⚠️ 注意：按**方向键**仍然能靠 `moveFocus` 的兜底分支救回来
       *    （见 ②-D）—— 所以本用例只断言"没有 observer 时焦点不在详情页"，
       *    不断言"按方向键也没用"（那会是错的）。
       */
      final moved = moveFocus(NavDir.right);
      await t.pump();
      await t.pump();
      debugPrint('【②-C3 无 observer】按 RIGHT moved=$moved '
          '终点=${_describe(FocusManager.instance.primaryFocus)}');
      expect(moved, isTrue,
          reason: '★ 兜底仍然有效：即使 observer 没种上，'
              '第一次按方向键也能靠 `moveFocus` 的"起点是容器 -> 先 prime"救回来。'
              '两层保障缺一不可 —— 但兜底救不回"用户还没按键时看不到焦点环"');
      expect(FocusManager.instance.primaryFocus, same(dr),
          reason: '★ 兜底把焦点送到了详情右（从"详情左"这个 prime 落点往右一格）');
    });

    testWidgets('②-D 新路由上直接按方向键：焦点必须能走到**详情页**控件', (t) async {
      _tvViewport(t);
      final homeBtn = FocusNode(debugLabel: '首页控件');
      final dl = FocusNode(debugLabel: '详情左');
      final dr = FocusNode(debugLabel: '详情右');
      addTearDown(homeBtn.dispose);
      addTearDown(dl.dispose);
      addTearDown(dr.dispose);

      await mountHome(t, homeBtn, dl, dr);
      expect(dl.hasPrimaryFocus, isFalse, reason: '前置：详情页还没焦点');

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

      debugPrint('【②-D】moved=$moved log=$spatialNavLog');
      debugPrint('【②-D】primedRect=$spatialNavPrimedRect '
          '终点=${_describe(FocusManager.instance.primaryFocus)}');

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
      expect(FocusManager.instance.primaryFocus, same(dr),
          reason: '★ 焦点必须落在**详情页右边那个控件**上。'
              '只断言"焦点变了"不够 —— 它也可能落在首页残留控件上');

      /*
       * ★ 证明走的是**新分支**（"起点是容器 -> 先 prime"），而不是碰巧。
       *
       * 「方向键能动了」有两种成因，回归风险完全不同：
       * ```text
       * A. 焦点本来就落在真控件上 → 正常算邻居
       * B. 起点是容器 → 先 prime 再算邻居（★ 本次修复新增的分支）
       * ```
       * 只看"焦点动了"分不出这两者，而 B 一旦退化，
       * 症状和修复前**一模一样**，只是更难发现（因为"能动"过）。
       */
      expect(spatialNavPrimedRect, isNotNull,
          reason: '★ 这一步必须由"起点是容器 -> 先 prime"这条分支完成。'
              '若为 null，说明焦点不知何时已落在真控件上 —— '
              '那测的就不是本缺陷的修复路径了');
      expect(spatialNavPrimedRect, isNot(_fullScreen),
          reason: '种下的焦点必须是真控件，不能又是整屏容器');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  缺陷③：一次 RIGHT 前进两格（AH 真机发现，AI 修复）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 真机现象（`[NAV]` 追踪）：
  // ```text
  // [NAV] dir=NavDir.right 移动到 _BottomItem... | 选中=(252,450,404,522)
  // [NAV] 帧后确认: ... 实际矩形=(404,450,556,522) 一致=false
  // ```
  // `选中` 与 `实际` 相差正好**一个 tab 的宽度**（152px）——
  // 算法选对了，但**有第二个搬运方**把它又推了一格。
  //
  // 根因：`HardwareKeyboard.addHandler` 的返回值**不会**中止派发
  // （SDK `hardware_keyboard.dart:626`：`handled = handled || thisResult`，**不 break**），
  // 所以 `_onGlobalKey` 返回 `true` 之后，事件照样流到焦点树 →
  // 内建 `DirectionalFocusIntent` **再搬一次**。
  //
  // 修法：改用 `FocusManager.instance.addEarlyKeyEventHandler`
  //       （SDK `focus_manager.dart:2271`：early handler 返回 handled → `return true`，
  //        焦点树整段被跳过）。
  group('★ 缺陷③：一次方向键只前进一格', () {
    /// 把真实 `ShellPage` 挂在一个可容纳测试控件的树里
    ///
    /// # 为什么用 `coreError`
    ///
    /// 真实首页（`home_page.dart`）在测试视口下会抛 11 个布局异常
    /// （`SliverGeometry` 的 layoutExtent 越界 + material_ui 的
    /// `StretchingOverscrollIndicator` 空指针），会让测试以"有异常"失败 ——
    /// 那测的就变成首页布局，不是方向键了。
    ///
    /// `coreError` 路径把内容区换成错误页，**结构干净**，而
    /// `initState` 里那两件与本任务有关的事**一字不差**：
    /// ```text
    /// primeFocusSoon()                          （自锁修复）
    /// FocusManager.addEarlyKeyEventHandler(...) （缺陷③修复）
    /// ```
    /// 底栏也照常挂载（所以"一次按键走两格"的判定环境是真实的）。
    Future<void> mountShellWithRow(
      WidgetTester t,
      FocusNode a,
      FocusNode b,
      FocusNode c,
    ) async {
      _tvViewport(t);
      // ★ TV 设备：`_onGlobalKey` 的第一道门控就是 `Device.needsFocusRing`
      Device.overrideKind(DeviceKind.tv);
      addTearDown(() => Device.overrideKind(null));

      final theme = AppTheme.themeFor(Brightness.dark);
      await t.pumpWidget(MaterialApp(
        theme: theme,
        builder: (ctx, child) =>
            AppThemeHost(data: theme, child: child ?? const SizedBox()),
        home: Column(children: [
          _threeInARow(a, b, c),
          const Expanded(
            child:
                ShellPage(coreError: 'PathAccessException: Permission denied'),
          ),
        ]),
      ));
      // 让 shell 的 initState + 首帧 + `primeFocusSoon()` 都跑完
      await t.pump(const Duration(milliseconds: 100));
    }

    testWidgets('③-A 真实 ShellPage 注册的 early handler：A → B（不是 C）', (t) async {
      final a = FocusNode(debugLabel: 'A');
      final b = FocusNode(debugLabel: 'B');
      final c = FocusNode(debugLabel: 'C');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      addTearDown(c.dispose);

      await mountShellWithRow(t, a, b, c);

      /*
       * ★ 必须**在 shell 挂载之后**再种起点。
       *
       * shell 的 `primeFocusSoon()` 会往 `addPostFrameCallback` 里排一次
       * `primeFocus()` —— 上面那个 `pump(100ms)` 已经让它跑完了，
       * 所以此刻种焦点不会被它抢走。
       */
      a.requestFocus();
      await t.pump();
      expect(a.hasPrimaryFocus, isTrue, reason: '起点没种上，断言无意义');

      debugPrint('【③-A】起点 A rect=${_rectOf(a)} '
          'primaryFocus=${_describe(FocusManager.instance.primaryFocus)}');

      /*
       * ★★ 只发**一次** RIGHT。
       *
       * `sendKeyEvent` 走的是 `KeyEventSimulator` → `KeyEventManager`
       * → `HardwareKeyboard.handleKeyEvent` → `_dispatchKeyMessage`
       * → `FocusManager.handleKeyMessage` —— 与真机**同一条链路**
       * （实测确认：`_defaultTransitMode = keyDataThenRawKeyData`，
       *  所以两条路径都会跑到）。
       */
      final handled = await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      await t.pump();

      debugPrint('【③-A】handled=$handled log=$spatialNavLog');
      debugPrint('【③-A】终点=${_describe(FocusManager.instance.primaryFocus)}');

      expect(handled, isTrue,
          reason: '方向键必须被消费掉 —— 否则事件会继续流到 Scrollable，'
              '变成"一边滚页面一边移焦点"');

      /*
       * ★★ 核心断言：**控件身份**，不是矩形。
       *
       * 真机日志里"期望矩形 vs 实际矩形"是最初的判读方式，
       * 但矩形容易被"另一个碰巧同样宽的元素"误判。
       * 这里直接断言 `primaryFocus` **就是** B 这个节点。
       */
      expect(FocusManager.instance.primaryFocus, same(b),
          reason: '★ 一次 RIGHT 只能从 A 走到 B。'
              '修复前（HardwareKeyboard.addHandler）会走到 C —— '
              '因为 addHandler 的返回值不中止派发，'
              '内建 DirectionalFocusIntent 又搬了一次');
      expect(b.hasPrimaryFocus, isTrue, reason: '同上');
      expect(c.hasPrimaryFocus, isFalse,
          reason: '★★ C 绝不能拿到焦点 —— 那正是真机上'
              '"选中=(252,450,404,522) 实际=(404,450,556,522)"的一格之差');
      expect(a.hasPrimaryFocus, isFalse, reason: '焦点必须离开 A');
    });

    testWidgets('③-B 机制对照：同一份契约接到**旧**注册 API 上就会走两格', (t) async {
      _tvViewport(t);
      final a = FocusNode(debugLabel: 'A');
      final b = FocusNode(debugLabel: 'B');
      final c = FocusNode(debugLabel: 'C');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      addTearDown(c.dispose);

      /*
       * ⚠️ 本用例**刻意不挂 ShellPage** —— 它是**对照实验**，
       *    证明缺陷③的机制，而不是在测生产路径（生产路径见 ③-A）。
       *
       * # 为什么值得留着这个"测 bug"的用例
       *
       * 它是 ③-A 的**反证**：
       * ```text
       * 同一个布局、同一份方向键契约、同一次 sendKeyEvent
       *   接到 HardwareKeyboard.addHandler  -> 走两格（C）   ← 缺陷③
       *   接到 FocusManager.addEarlyKey...  -> 走一格（B）   ← 修复
       * ```
       * 没有这一条的话，③-A 的"一格"可能只是"布局本来就走不了两格"
       * （假通过）。有了它，③-A 的结论才有对照。
       *
       * 它同时也把"为什么必须换 API"钉成了**可执行的事实**：
       * 将来若有人改回 `addHandler`，③-A 会立刻报红，
       * 而这一条会继续绿着，说明"改回去就会两格"这个因果关系没变。
       */
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: _threeInARow(a, b, c))),
      ));
      a.requestFocus();
      await t.pump();
      expect(a.hasPrimaryFocus, isTrue, reason: '起点没种上');

      HardwareKeyboard.instance.addHandler(_arrowContract);
      addTearDown(() => HardwareKeyboard.instance.removeHandler(_arrowContract));

      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      await t.pump();

      debugPrint('【③-B】addHandler 路径 终点='
          '${_describe(FocusManager.instance.primaryFocus)}');

      expect(FocusManager.instance.primaryFocus, same(c),
          reason: '★ 这就是缺陷③：`HardwareKeyboard.addHandler` 返回 true '
              '**不中止派发**（SDK `hardware_keyboard.dart:626` 只是 '
              '`handled = handled || thisResult`），所以事件继续流到焦点树，'
              '内建 DirectionalFocusIntent 又搬了一格。'
              '若这里变成 B，说明 Flutter 改了派发语义 —— '
              '那缺陷③的根因推导需要重新核对（而 ③-A 的修复仍然是对的）');
    });

    testWidgets('③-C 机制对照：early handler 返回 handled 时焦点树被整段跳过', (t) async {
      _tvViewport(t);
      final a = FocusNode(debugLabel: 'A');
      final b = FocusNode(debugLabel: 'B');
      final c = FocusNode(debugLabel: 'C');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      addTearDown(c.dispose);

      // ⚠️ 同 ③-B：对照实验（不挂 ShellPage），证明 early handler 的中止能力
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: _threeInARow(a, b, c))),
      ));
      a.requestFocus();
      await t.pump();
      expect(a.hasPrimaryFocus, isTrue, reason: '起点没种上');

      FocusManager.instance.addEarlyKeyEventHandler(_arrowContractEarly);
      addTearDown(() =>
          FocusManager.instance.removeEarlyKeyEventHandler(_arrowContractEarly));

      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      await t.pump();

      debugPrint('【③-C】early 路径 终点='
          '${_describe(FocusManager.instance.primaryFocus)}');

      expect(FocusManager.instance.primaryFocus, same(b),
          reason: '★ early handler 返回 handled 后，焦点树**整段被跳过** —— '
              '内建 DirectionalFocusIntent 不触发，所以只走一格');
      expect(c.hasPrimaryFocus, isFalse, reason: '★ 不能走到 C');
    });

    testWidgets('③-D 非方向键必须放行（early handler 不能把 Enter 也吃掉）', (t) async {
      _tvViewport(t);
      final a = FocusNode(debugLabel: 'A');
      final b = FocusNode(debugLabel: 'B');
      final c = FocusNode(debugLabel: 'C');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      addTearDown(c.dispose);

      // ★ 直接量契约本身（`shell.dart` 的 `_onEarlyKey` = 这个契约的适配器）
      expect(
        _arrowContractEarly(const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowRight,
          logicalKey: LogicalKeyboardKey.arrowRight,
          timeStamp: Duration.zero,
        )),
        KeyEventResult.handled,
        reason: '方向键必须 handled —— 否则 Scrollable 会同时滚页面',
      );
      expect(
        _arrowContractEarly(const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: LogicalKeyboardKey.enter,
          timeStamp: Duration.zero,
        )),
        KeyEventResult.ignored,
        reason: '★ 只接管方向键 —— 其余按键必须放行。'
            '不放行的话遥控器确认键/播放器快捷键/输入框打字全废',
      );
      expect(
        _arrowContractEarly(const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.arrowRight,
          logicalKey: LogicalKeyboardKey.arrowRight,
          timeStamp: Duration.zero,
        )),
        KeyEventResult.ignored,
        reason: '★ 只认 KeyDown —— KeyUp 放行，否则长按/组合键行为会异常',
      );

      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: _threeInARow(a, b, c))),
      ));
      a.requestFocus();
      await t.pump();

      // 真发一次 ENTER：焦点必须**不动**（它不该走空间导航那条路）
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(FocusManager.instance.primaryFocus, same(a),
          reason: '★ ENTER 不是方向键，不能触发空间导航移焦');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  自锁：没有可用起点 → 按键无效 → 永远好不了
  // ═══════════════════════════════════════════════════════════════════
  //
  // 修法：`primeFocusSoon()` —— 在 `addPostFrameCallback` 里种一次焦点，
  //       **不依赖任何按键**（`shell.dart:1236` 开机 + `FocusPrimingObserver` 进路由）。
  //
  // # 死锁的完整链条（AI 读 SDK 找到的）
  //
  // ```text
  // primaryFocus 没有可用起点（null 或容器）
  //   -> FocusManager 丢弃按键 / moveFocus 没有起点
  //   -> moveFocus 不被调用 -> primeFocus 不被调用
  //   -> 永远是那个状态          ★ 按多少次方向键都没用
  // ```
  // 唯一的破局手段（种焦点）本身要靠按键触发，而按键恰恰被挡掉了。
  //
  // # ⚠️ 一条实测出来的**时序纪律**（写这一组时踩到，必须记下来）
  //
  // `primeFocusSoon()` 是 `addPostFrameCallback` —— 它的回调**在下一帧的
  // 帧尾**才跑，而回调里 `requestFocus()` 又要**再下一帧**才生效。所以：
  // ```text
  // primeFocusSoon(); await t.pump();          -> 回调跑完了，但焦点**还没变**
  // primeFocusSoon(); await t.pumpAndSettle(); -> 焦点真的种上了  ★ 用这个
  // ```
  // 我第一版只 pump 一次，看到的是"什么都没发生"——
  // 那会让我写出一条**假报红**的断言（以为修复失效，其实是没等够帧）。
  group('★ 自锁：不依赖按键的触发点必须真的把焦点种上', () {
    testWidgets('④-A 真实 MaterialApp 冷启动：`initState` 里的 primeFocusSoon 种上了',
        (t) async {
      _tvViewport(t);
      final rawA = FocusNode(debugLabel: '无primeA');
      final rawB = FocusNode(debugLabel: '无primeB');
      final a = FocusNode(debugLabel: '冷A');
      final b = FocusNode(debugLabel: '冷B');
      addTearDown(rawA.dispose);
      addTearDown(rawB.dispose);
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      /*
       * ══════════════════════════════════════════════════════════════
       * 第 ① 步：先量**没有** prime 时的冷启动状态（= 自锁的状态）
       * ══════════════════════════════════════════════════════════════
       *
       * ★ 这一步必须**单独挂一棵树**来做。
       *
       * 我第一版把"量 before"和"量 after"写在同一个 `pumpWidget` 里 ——
       * 结果 `initState` 的 `primeFocusSoon()` 在 `pumpWidget` 返回前
       * 就已经把焦点种好了，`before` 直接读到了 `冷A`，
       * 于是"前置：焦点是容器"那条断言**必然报红**（实测踩到）。
       *
       * 教训：**要对比两个状态，就得真的造出两个状态** ——
       * 不能在同一个已经被修好的树上假装它还没修。
       */
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            _Cell(node: rawA, label: '无primeA'),
            _Cell(node: rawB, label: '无primeB'),
          ]),
        ),
      ));
      await t.pump();

      final before = FocusManager.instance.primaryFocus;
      debugPrint('【④-A】没有 prime 时 primaryFocus=${_describe(before)}');

      /*
       * ★★ 冷启动时 `primaryFocus` **不是 null** —— 它是 `_ModalScopeState` 容器。
       *
       * 这一点是整个自锁的**关键**：旧守卫 `if (cur != null) return false`
       * 恰恰因为这个"非 null"而永远提前返回。
       * 而旧注释把根因写成"primaryFocus == null"—— 方向正好相反。
       */
      expect(before, isNotNull,
          reason: '★ 冷启动时 primaryFocus **不是** null（是 ModalScope 容器）。'
              '若这里变成 null，说明 Flutter 行为变了、判据要重新核对');
      expect(before, isA<FocusScopeNode>(),
          reason: '★ 它是一个**容器**，不是用户能看见的控件 —— '
              '所以"有焦点"和"有可用起点"是两件事');
      expect(before!.children.isEmpty, isFalse,
          reason: '★ 它有子节点 —— 所以叶子判据（`children.isEmpty`）'
              '**不会**在这里提前返回，`primeFocus()` 才会真的动手');
      expect(rawA.hasPrimaryFocus, isFalse,
          reason: '★ 前置：没有任何东西种过焦点 —— 这就是自锁的状态'
              '（用户按方向键不会有任何反应）');

      /*
       * ★★ 内部可证伪性证明（与 ②-B 同一个手法）：
       *    把修复前的守卫复现出来，显式证明"修复前在这里就会提前返回"。
       */
      bool preFixGuardBailsOut() =>
          FocusManager.instance.primaryFocus != null;
      expect(preFixGuardBailsOut(), isTrue,
          reason: '★ 修复前的守卫 `if (cur != null) return false;` 在这里'
              '**必然提前返回** —— 冷启动永远种不上焦点，这正是自锁。'
              '修复后守卫变成 `cur != null && _isLeafFocusTarget(cur)`，'
              '而此刻 cur 是个**有子节点的容器**，所以不再提前返回');

      /*
       * ══════════════════════════════════════════════════════════════
       * 第 ② 步：换上**生产位置**调用 `primeFocusSoon()` 的树
       * ══════════════════════════════════════════════════════════════
       *
       * ★★ 必须用 [_PrimeOnInit] 复刻 `shell.dart:1236` 的**调用位置**
       *    （`initState` 里），而不是"pumpWidget 之后再手动调一次"。
       *
       * # 为什么这个区别是决定性的（我第一版就在这里踩了坑）
       *
       * 我第一版写成"先 pump 一次，再调 `primeFocusSoon()`"，结果
       * 断言报红、看起来像"修复失效"。实测（探针 Y2 / Z1）发现
       * **那是我自己造出来的时刻**：
       * ```text
       * initState 里调（生产位置）      -> 冷A ✓  焦点真的种上了
       * pumpWidget 之后再手动调          -> 容器 ✗  回调里读到 primaryFocus==null
       * ```
       * 差别在于：`primeFocusSoon()` 排的回调**读到什么**。
       * 多跑一帧之后会撞上一个转瞬即逝的中间态（`primaryFocus == null`），
       * 那时 `primeFocus()` 虽然返回 true，种下的焦点随即被路由的
       * `ModalScope` 覆盖 —— 而**生产里根本没有这个时刻**
       * （`shell.dart` 只在 `initState` 里调一次）。
       *
       * ⇒ 教训：测试必须复刻生产的**生命周期位置**，不能"随便找个时机调一下"。
       *    否则测的是"我调用时机选错了"，不是"这个修复有没有用"。
       */
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: _PrimeOnInit(
            child: Column(children: [
              _Cell(node: a, label: '冷A'),
              _Cell(node: b, label: '冷B'),
            ]),
          ),
        ),
      ));
      await t.pumpAndSettle();

      final after = FocusManager.instance.primaryFocus;
      debugPrint('【④-A】initState 里 primeFocusSoon 之后='
          '${_describe(after)} 候选=${spatialNavCandidates}');

      /*
       * ★★ 核心断言：焦点必须**真的**落在叶子控件上。
       *
       * 修复前（旧守卫）这里仍然是 ModalScope 容器 ——
       * 于是按键被丢弃/没有起点，用户按多少次方向键都没用。
       */
      expect(after, isNotNull, reason: '★ 不能是 null');
      expect(after, isNot(isA<FocusScopeNode>()),
          reason: '★ 不能是容器 —— 容器在算法眼里等价于"没有焦点"'
              '（起点矩形 = 整屏，任何方向都没有合法邻居）。'
              '第 ① 步已经证明"没有 prime 时就是容器"，'
              '这一条就是那个差值的另一半');
      expect(after!.children.isEmpty, isTrue,
          reason: '★ 必须是**叶子**（`_isLeafFocusTarget` 的判据），'
              '否则它不会被 `_collect()` 当成候选，导航照样走不通');
      expect(after, same(a),
          reason: '★ 必须是几何上"最靠上最靠左"的那个控件（冷A）。'
              '身份断言 —— 不是"某个矩形差不多的东西"');
      expect(a.hasPrimaryFocus, isTrue, reason: '同上');
    });

    testWidgets('④-B 种上焦点之后，导航才第一次能移动（对照）', (t) async {
      _tvViewport(t);
      final a = FocusNode(debugLabel: '冷A');
      final b = FocusNode(debugLabel: '冷B');
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: _PrimeOnInit(
            child: Column(children: [
              _Cell(node: a, label: '冷A'),
              _Cell(node: b, label: '冷B'),
            ]),
          ),
        ),
      ));
      await t.pumpAndSettle();

      /*
       * 这一条量的是**修好之后**的正常路径：先 prime，再导航。
       * 对照组是 ④-A —— 没有 prime 时焦点就停在容器上。
       *
       * 这里刻意**不用** `moveFocus` 来"顺带 prime"：
       * `moveFocus` 内部有"起点是容器 -> 先 prime"的兜底分支
       * （缺陷②的调用侧修法），它会自己救回来，于是掩盖了
       * "没有 ④-A 这一步会怎样"。要单独测 prime 的贡献，
       * 就得把两步分开量。
       */
      final primed = FocusManager.instance.primaryFocus;
      debugPrint('【④-B】prime 之后=${_describe(primed)}');
      expect(primed, same(a),
          reason: '★ 不依赖按键的触发点必须真的把焦点种上（冷A）—— '
              '这是 ④-A 的结论，这里当**前置**用');
      expect(primed, isNot(isA<FocusScopeNode>()),
          reason: '★ 前置：焦点必须已经在叶子上，否则下面测的是兜底分支');

      // 现在导航才走得动
      final moved = moveFocus(NavDir.down);
      await t.pump();
      await t.pump();
      debugPrint('【④-B】moveFocus(down)=$moved '
          '终点=${_describe(FocusManager.instance.primaryFocus)}');

      expect(moved, isTrue,
          reason: '★ 焦点种在真控件上之后，方向键必须能找到邻居。'
              '若焦点仍在容器上（起点 = 整屏），任何方向都没有合法邻居');
      expect(FocusManager.instance.primaryFocus, same(b),
          reason: '★ 必须落到下方那个控件上（身份断言）');
      expect(b.hasPrimaryFocus, isTrue, reason: '同上');
    });

    testWidgets('④-C primeFocusSoon 不会把用户已经选好的焦点抢走', (t) async {
      _tvViewport(t);
      final a = FocusNode(debugLabel: 'A');
      final b = FocusNode(debugLabel: 'B');
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      /*
       * ★ 用 [_PrimeOnInit] 复刻生产位置（见 ④-A 的说明）。
       *
       * # 为什么这一条特别重要
       *
       * `primeFocusSoon` 会在**每次进新路由**时被调用（observer 那 4 个钩子）。
       * 如果守卫写错（比如无条件种焦点），用户正在看的焦点就会被
       * "最靠上最靠左"那个控件抢走 —— 那是比原缺陷更烦人的 bug。
       *
       * ⚠️ 本用例的 `initState` 版本里，`primeFocusSoon()` 排在
       *    **用户 `requestFocus()` 之前**（`initState` 比任何用户操作都早）。
       *    所以它**必然**会种一次 —— 那是正确的（冷启动本来就该种）。
       *    真正要验的是**之后**再调时不再动手。
       */
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: _PrimeOnInit(
            child: Column(children: [
              _Cell(node: a, label: 'A'),
              _Cell(node: b, label: 'B'),
            ]),
          ),
        ),
      ));
      await t.pumpAndSettle();

      // 冷启动那次 prime 应该把焦点放在最靠上的 A 上
      expect(a.hasPrimaryFocus, isTrue,
          reason: '前置：冷启动那次 prime 应该把焦点放在最靠上的 A 上');

      // 用户把焦点移到**第二个**控件上
      b.requestFocus();
      await t.pump();
      expect(b.hasPrimaryFocus, isTrue, reason: '起点没种上');

      /*
       * ★★ 现在再触发一次（模拟"又进了一个路由"）——
       *    焦点已经在真控件上，必须**什么都不做**。
       */
      primeFocusSoon();
      await t.pumpAndSettle();

      debugPrint('【④-C】再次 primeFocusSoon 后='
          '${_describe(FocusManager.instance.primaryFocus)}');

      expect(FocusManager.instance.primaryFocus, same(b),
          reason: '★ 焦点已经在真控件上时，`primeFocusSoon` 必须**什么都不做**。'
              '抢走用户已选焦点比"没种上"更糟');
      expect(a.hasPrimaryFocus, isFalse,
          reason: '★ 不能跳回 A —— 那是"最靠上"的那个，'
              '说明守卫退化成"无条件种焦点"了');
      expect(primeFocus(), isFalse,
          reason: '★ 同步版本也必须返回 false（"我不需要动手"）—— '
              '这个返回值就是守卫的直接证据');
    });

    testWidgets('④-D 真实 ShellPage 冷启动：焦点必须落在**最靠上**的真控件上',
        (t) async {
      _tvViewport(t);
      Device.overrideKind(DeviceKind.tv);
      addTearDown(() => Device.overrideKind(null));

      final theme = AppTheme.themeFor(Brightness.dark);
      await t.pumpWidget(MaterialApp(
        theme: theme,
        builder: (ctx, child) =>
            AppThemeHost(data: theme, child: child ?? const SizedBox()),
        home: const ShellPage(coreError: 'PathAccessException: Permission denied'),
      ));
      await t.pump(const Duration(milliseconds: 100));

      final focus = FocusManager.instance.primaryFocus;
      debugPrint('【④-D】ShellPage 冷启动后 primaryFocus=${_describe(focus)}');
      debugPrint('【④-D】候选=${spatialNavCandidates}');

      /*
       * ★★ 这一条测的是**生产接线**：`shell.dart:1236` 的
       *    `primeFocusSoon()` 真的在 `initState` 里被调用了。
       *
       * # ⚠️ 为什么断言"最靠上"而不是只断言"是叶子"（实测踩到）
       *
       * 真实 `ShellPage` 的底栏 `_BottomItem` 带 `autofocus: on`
       * （`shell.dart:3815`）—— 它**自己**就会把焦点放到当前 tab 上。
       * 所以"焦点是叶子"这个弱断言**在撤掉 `primeFocusSoon()` 之后
       * 依然成立**，属于**不可证伪**的空断言（我第一次就是这么写的，
       * 用 redness proof 才抓到）。
       *
       * 而 `primeFocus()` 的落点规则是"几何上最靠上再最靠左"
       * （原版 `focusFirst` 语义）—— 在错误页布局下，最靠上的是
       * 内容区那个"重新尝试启动"按钮（y≈436），
       * 而底栏 tab 在 y≈450。**两者相差 14px，可判读**。
       * 所以"落点 = 候选里最靠上的那个"才能把
       * `primeFocusSoon()` 的贡献单独指认出来。
       */
      expect(focus, isNotNull, reason: '★ 冷启动后不能没有焦点');
      expect(focus, isNot(isA<FocusScopeNode>()),
          reason: '★ 不能停在容器上 —— 那等于"遥控器失灵"');
      expect(focus!.children.isEmpty, isTrue,
          reason: '★ 必须是叶子（可导航的起点）');

      final candidates = List<Rect>.from(spatialNavCandidates);
      expect(candidates, isNotEmpty,
          reason: '前置：候选池不能是空的，否则下面的比较恒真');
      candidates.sort((x, y) {
        final dy = x.top.compareTo(y.top);
        if (dy != 0) return dy;
        return x.left.compareTo(y.left);
      });
      final topMost = candidates.first;
      final focusRect = _rectOf(focus);
      debugPrint('【④-D】最靠上的候选=$topMost 实际焦点矩形=$focusRect');

      expect(focusRect, topMost,
          reason: '★ `primeFocusSoon()` 的落点是"最靠上最靠左"的候选。'
              '若这里落在底栏 tab 上，说明 shell 开机那次 prime 没生效，'
              '焦点是被底栏的 `autofocus` 拿走的 —— '
              '那正是自锁修复缺失时的表现');
    });
  });
}

// ═══════════════════════════════════════════════════════════════════════
//  ⚠️ 本文件**没有**覆盖的那几条（如实记录，不假装覆盖了）
// ═══════════════════════════════════════════════════════════════════════
//
// # ① `primaryFocus == null` → 按键被 `FocusManager` **整个丢弃**
//
// `spatial_nav.dart:1366-1383` 引了 SDK 源码：
// ```dart
// // focus_manager.dart:2241  handleKeyMessage
// if (FocusManager.instance.primaryFocus == null) {
//   return false;                       // ★★ 所有 handler 一个都不跑
// }
// ```
// 这是自锁链条里最硬的一环（连 early handler 都到不了）。
//
// ## 为什么单测里**造不出来**
//
// 实测（探针 P4，`.probe/an_probe_test.dart`）：
// ```text
// 真实 MaterialApp + 空页面   primaryFocus = _ModalScopeState Focus Scope  ← 不是 null
// 于是 earlyCalls +2 / hwCalls +2 —— 按键**没有被丢弃**
// ```
// 也就是说：**只要 `MaterialApp` 挂上了，`primaryFocus` 就永远不是 null**
// （路由的 `ModalScope` 持有它）。要造出 null 得用**裸树**
// （没有 MaterialApp / Navigator），而裸树里 `_collect()` 又收不到
// 真实路由的控件 —— 那测的就不是生产环境了（正是本项目禁止的
// 「用手搓树测自己的构造」）。
//
// ⇒ 这一环**只能在真机上验证**。单测覆盖的是它的**等价后果**：
//    `primaryFocus` 是容器时，算法眼里与"没有焦点"完全等价
//    （起点矩形 = 整屏，任何方向都没有合法邻居）—— 见 ④-A / ④-B。
//
// # ② `shell.dart` 里那个 `primaryFocus == null` 分支是**死分支**
//
// `shell.dart:1606` 的
// ```dart
// if (FocusManager.instance.primaryFocus == null) {
//   final primed = primeFocus();
//   ...
// }
// ```
// 与上面同一个理由：`primaryFocus` 永不为 null ⇒ 这段**永远进不去**。
//
// 本文件**不对它做断言** —— 断言一个不可达分支既无法证伪，
// 又会给人"这里被测过了"的错觉。它该做的是被**删掉**
// （属生产改动，不在本任务的文件归属内，**已上报**）。
//
// # ③ `FocusPrimingObserver` 的 `didPush` 在**路由动画第一帧**就跑完了
//
// 实测（探针 U1 / AD）：`didPush` 里排的 `addPostFrameCallback`
// 执行时，**新路由的控件还没进候选池**（`_collect()` 只看到老路由那 1 个），
// 而此刻焦点还在老路由的叶子上 → 守卫正确地拒绝动手。
// **紧接着**转场把焦点顶到 `ModalScope` 容器上 —— 那才是该动手的时机。
//
// ## ★ 这一条**已经修好**（任务 AN，`lib/ui/spatial_nav.dart`）
//
// `FocusPrimingObserver._prime()` 改成**有界重试**（成功即停，最多 8 帧），
// 于是第 2 帧抓到了那个机会窗口。见 ②-C 的完整推导与 A/B 证据。
//
// 修好之前它是**空操作**（A/B 逐字节相同），所以这一条从"已知限制"
// 变成了"已修复 + 有测试守着"。
//
// ⚠️ 仍然**没有**覆盖的：`maxPrimeTries` 用尽后的行为
//    （新页面真的没有可聚焦控件，比如纯文本页）。
//    那时 observer 会静默放弃 —— 这是**正确**的（没东西可种），
//    但要测它就得造一个"新路由没有任何 Focus 控件"的场景，
//    而那种场景下"焦点没种上"和"种不上"无法区分，
//    断言会退化成"什么都没发生"（恒真）。故不测。
//
// # ④ 本文件**不**断言 `shell.dart` 里那个 `primaryFocus == null` 死分支
//
// 见上面第 ② 条：断言一个不可达分支既无法证伪，又会给人
// "这里被测过了"的错觉。它该做的是被**删掉** ——
// 属生产改动，**不在本任务的文件归属内**（`shell.dart` 归代理 AM）。
//
// # ⑤ 真机上"`primaryFocus == null` → 按键被整个丢弃"这一环
//
// 只能在真机验证（见第 ① 条）。单测覆盖它的**等价后果**（④-A/④-B）。
//
// ═══════════════════════════════════════════════════════════════════════
//  ★ 可证伪性证明（redness proof）—— 每一条断言都真的报红过
// ═══════════════════════════════════════════════════════════════════════
//
// 脚本：`.probe/an_redness.py`（在**隔离副本**里做逆向还原，生产工程一字不改）
//
// ```text
// 撤销的修复点                     报红的用例
// ─────────────────────────────  ─────────────────────────────────────────
// ①_collect_leaf（叶子判据）       ①-A ①-B ①-C ②-B ②-C ②-C2 ②-C3 ②-D
//                                 ④-A ④-B ④-C ④-D          （12 条）
// ②_prime_guard（primeFocus 守卫） ②-B ②-C ④-A              （3 条）
// ②_movefocus_inline（调用侧兜底） ②-C3 ②-D                  （2 条）
// ③_early_handler（early 注册）    ③-A                       （1 条）
// 自锁_primeFocusSoon（开机种焦点） ④-D                       （1 条）
// 观察者重试（有界重试）            ②-C                       （1 条）
// ```
//
// ⚠️ 每条都**核对了报红原因**，确认是预期的机制，而不是"碰巧红了"：
// ```text
// ③-A  Expected B / Actual C   ← 正是"一次按键走两格"（缺陷③本体）
// 自锁 Expected (0,0,100,40) / Actual (100,450,252,522)
//                              ← 焦点落在底栏 tab 上（被 autofocus 拿走）
// 观察者 Expected not FocusScopeNode / Actual ModalScope
//                              ← 焦点停在容器上（不可导航）
// ```
