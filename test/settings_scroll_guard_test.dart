// ═══════════════════════════════════════════════════════════════════════
//  ③ 设置页滚动位置守卫：代理判据 vs 显式「首次加载」标志
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户报的现象
//
// > 设置页我往下滑，会自动往上滚动
//
// # 根因（2026-09-25 实测定位，★ 推翻了两个候选假设）
//
// ## 候选 ① `ensureVisible` 抢滚动 —— **已排除**
// 静态可达性分析（`.probe/t3_reachability.py`）：
// ```text
// _scrollIntoView          spatial_nav.dart   ← 唯一调用点
//     ↑ moveFocus(dir)
//     ↑ 只有两个入口
// ① SpatialNavHandler.handle()  ← ★ 该类从未被实例化（死代码）
// ② shell.dart _onGlobalKey     ← ★ 门控 `if (!Device.needsFocusRing) return false;`
//                                  Device.needsFocusRing => isTv
//                                  真机日志实测 isTv=false ⇒ 桌面必然 return false
// ⇒ 桌面上 _scrollIntoView 不可达
// ```
// 且全 `lib/` 的滚轮/指针处理 = **0 处**
//（`onPointerSignal` / `PointerScrollEvent` / `PointerSignalEvent` /
//  `ScrollNotification` / `NotificationListener` 全为 0）
// ⇒ 鼠标滚轮没有任何代码路径能触发 `ensureVisible`。
//
// ## 候选 ② `_loading` 销毁 ListView —— **成立，且残留一个漏洞**
// `build()` 里：
// ```dart
// if (_loading) return const Center(child: CircularProgressIndicator());
// return Stack(children: [ListView(...)]);
// ```
// `_loading = true` 会把 ListView **整个替换**掉 ⇒ 滚动位置归零。
//
// 原判据是 `_providers.isEmpty` —— 它是"首次加载"的**代理**，两者不等价：
// ```text
// _providers.isEmpty == true 有两种可能：
//   ① 真的还没加载过            ← 该转圈
//   ② 加载过，但这次结果为空     ← ★ 不该转圈（会销毁 ListView → 滚动归零）
// ```
// ② 真实可达：核心重启 / 插件重载 / `listProviders()` 瞬时失败。
//
// # 本文件测什么
//
// 复刻生产代码的**真实结构**（含那个 `await`），验证三件事：
// ```text
// 组 A ★ 阳性对照：providers 非空 ⇒ 再次 loadAll 不得销毁 ListView，位置保住
// 组 B ★★ 漏洞：providers 变空 + 旧判据 ⇒ ListView 消失、位置归零
// 组 C ★★ 修法：显式 firstLoadDone ⇒ providers 变空也不再销毁 ListView
// ```
// ★ 组 A 是**阳性对照**：它不过，组 B 的"没复现"就不能当结论（铁律②）。
//
// # ⚠️⚠️ 写这个文件时踩的两个仪器坑（都留在这里，避免后人重踩）
//
// ## 坑 1：把 loadAll() 写成**同步**的 ⇒ 组 B 复现不出来（假阴性）
// ```text
// 症状：providers 变空 + loadAll ⇒ ListView消失=false   ← 与生产行为不符
// 原因：两个 setState 在**同一帧**内跑完，`_loading = true` 这个中间态
//       **从未被渲染**，所以 ListView 根本没被替换。
//       而生产代码在两者之间**有 `await Future.wait([...])`**
//       ⇒ 中间态会渲染一帧 ⇒ ListView 真的被替换。
// ⇒ 复刻不忠实 ⇒ "没复现"是**仪器错**，不是结论。
//
// ## 坑 2：改成 `await Future<void>.delayed(Duration.zero)` 后**测试挂死**
// ```text
// 症状：[still running after 600000ms]
// 原因：`testWidgets` 跑在 **fake-async zone**，`Future.delayed` 要
//       **推进时钟**（`tester.pump()`）才会完成；直接 `await` 它 ⇒ 永远等不到。
// ★ 这与本项目铁律 14（`toImage()` 不能直接 `await`）是**同一类**坑。
// ```
//
// ## 修法：用**可控的 Completer 闸门**代替定时器
// ```dart
// Completer<void> gate = Completer<void>()..complete();
// ...
// await gate.future;   // ← 由测试决定何时放行
// ```
// ⇒ 既能停在中间态观察，又不会死锁。
//
// ★ 通用教训：**要复现"中间态被渲染"的 bug，必须让那个中间态真的跨帧。**
//   同步代码复刻不出异步 bug。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// 复刻 `settings_page.dart` 的**旧**结构（代理判据 `_providers.isEmpty`）。
///
/// 对应生产代码：
/// ```text
/// bool _loading = true;                                     // L177
/// if (mounted && _providers.isEmpty) setState(...);         // L320（旧）
/// await Future.wait([...]);                                 // L328  ← ★ 关键
/// if (_loading) return const Center(...);                   // L1467
/// return Stack(children: [ListView(...)]);                  // L1471
/// ```
class ProxyPredicateRepro extends StatefulWidget {
  const ProxyPredicateRepro({super.key});
  @override
  State<ProxyPredicateRepro> createState() => ProxyPredicateReproState();
}

class ProxyPredicateReproState extends State<ProxyPredicateRepro> {
  bool loading = true;
  List<String> providers = [];

  /// ★ 闸门：模拟生产代码 L328 那个 `await`。由测试放行。
  Completer<void> gate = Completer<void>()..complete();

  /// ★ 与**旧**生产代码逐字相同的判据
  Future<void> loadAll() async {
    if (mounted && providers.isEmpty) setState(() => loading = true);
    await gate.future; // ← 对应 L328 的 await
    if (!mounted) return;
    setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    // ★ 与 settings_page.dart:1467-1469 逐字相同
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      children: [
        for (var i = 0; i < 100; i++)
          SizedBox(height: 60, child: Text('item $i')),
      ],
    );
  }
}

/// 复刻**修好后**的结构（显式 `firstLoadDone`）。
class ExplicitFlagRepro extends StatefulWidget {
  const ExplicitFlagRepro({super.key});
  @override
  State<ExplicitFlagRepro> createState() => ExplicitFlagReproState();
}

class ExplicitFlagReproState extends State<ExplicitFlagRepro> {
  bool loading = true;
  List<String> providers = [];
  bool firstLoadDone = false;
  Completer<void> gate = Completer<void>()..complete();

  Future<void> loadAll() async {
    // ★ 修法：判据是"首次加载还没完成"，不是"列表为空"
    if (mounted && !firstLoadDone) setState(() => loading = true);
    await gate.future;
    if (!mounted) return;
    setState(() {
      loading = false;
      firstLoadDone = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      children: [
        for (var i = 0; i < 100; i++)
          SizedBox(height: 60, child: Text('item $i')),
      ],
    );
  }
}

double _pixels(WidgetTester t) =>
    t.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

/// 滚到 ~3000 并返回位置
Future<double> _scrollDown(WidgetTester t) async {
  await t.drag(find.byType(ListView), const Offset(0, -3000));
  await t.pumpAndSettle();
  return _pixels(t);
}

void main() {
  group('③ 设置页滚动位置：代理判据的漏洞', () {
    testWidgets('组 A ★ 阳性对照：providers 非空 ⇒ 位置必须保住', (t) async {
      final key = GlobalKey<ProxyPredicateReproState>();
      await t.pumpWidget(MaterialApp(home: ProxyPredicateRepro(key: key)));

      // 首次加载（生产里 listProviders() 返回 26 个源）
      key.currentState!.providers = List.generate(26, (i) => 'p$i');
      await key.currentState!.loadAll();
      await t.pumpAndSettle();

      final pos1 = await _scrollDown(t);
      expect(pos1, greaterThan(1000), reason: '先确认真的滚下去了');

      // 切回设置页会再调一次（shell.dart 的 tab 激活回调）
      await key.currentState!.loadAll();
      await t.pumpAndSettle();

      expect(
        _pixels(t),
        pos1,
        reason: '★★ 阳性对照：providers 非空时 loadAll 不得销毁 ListView，'
            '滚动位置必须原样保住 —— 这一条证明"守卫确实在起作用"，'
            '否则组 B 的"没复现"不能当结论（铁律②）',
      );
    });

    testWidgets('组 B ★★ 漏洞：providers 瞬时变空 ⇒ ListView 被销毁、位置归零',
        (t) async {
      final key = GlobalKey<ProxyPredicateReproState>();
      await t.pumpWidget(MaterialApp(home: ProxyPredicateRepro(key: key)));

      key.currentState!.providers = List.generate(26, (i) => 'p$i');
      await key.currentState!.loadAll();
      await t.pumpAndSettle();
      final pos1 = await _scrollDown(t);
      expect(pos1, greaterThan(1000));

      // ★ 关闸门 + providers 变空（核心重启 / 插件重载 / 瞬时失败）
      key.currentState!.gate = Completer<void>();
      key.currentState!.providers = [];
      final pending = key.currentState!.loadAll();
      await t.pump(); // 渲染中间态：loading = true

      expect(
        find.byType(ListView).evaluate().isEmpty,
        isTrue,
        reason: '★ 漏洞成立：providers 空 ⇒ loading=true ⇒ '
            'build() 返回 Center ⇒ ListView 被整个替换',
      );

      key.currentState!.gate.complete();
      await pending;
      await t.pumpAndSettle();

      expect(
        _pixels(t),
        0.0,
        reason: '★★ 滚动位置归零 —— 这正是用户报的「往下滑自动往上滚」。'
            '代理判据 `_providers.isEmpty` 无法区分'
            '「还没加载过」和「加载过但结果为空」',
      );
    });

    testWidgets('组 C ★★ 修法有效：显式 firstLoadDone ⇒ 变空也不再销毁 ListView',
        (t) async {
      final key = GlobalKey<ExplicitFlagReproState>();
      await t.pumpWidget(MaterialApp(home: ExplicitFlagRepro(key: key)));

      key.currentState!.providers = List.generate(26, (i) => 'p$i');
      await key.currentState!.loadAll();
      await t.pumpAndSettle();
      final pos1 = await _scrollDown(t);

      // 同样让 providers 变空 —— 但判据不是"列表为空"
      key.currentState!.gate = Completer<void>();
      key.currentState!.providers = [];
      final pending = key.currentState!.loadAll();
      await t.pump();

      expect(
        find.byType(ListView).evaluate().isNotEmpty,
        isTrue,
        reason: '★ 修法有效：providers 变空也不再销毁 ListView',
      );

      key.currentState!.gate.complete();
      await pending;
      await t.pumpAndSettle();

      expect(_pixels(t), pos1, reason: '★ 滚动位置保住');
    });

    testWidgets('组 D ★ 首次加载仍要转圈（别修一个坏一个）', (t) async {
      final key = GlobalKey<ExplicitFlagReproState>();
      await t.pumpWidget(MaterialApp(home: ExplicitFlagRepro(key: key)));

      // 首次：还没加载过 ⇒ 必须显示转圈
      expect(
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty,
        isTrue,
        reason: '★ 首次加载必须有加载态 —— 不能为了修滚动 bug 把转圈删了',
      );

      key.currentState!.gate = Completer<void>();
      final pending = key.currentState!.loadAll();
      await t.pump();
      expect(
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty,
        isTrue,
        reason: '★ 首次加载期间（await 中）必须还在转圈',
      );

      key.currentState!.gate.complete();
      await pending;
      await t.pumpAndSettle();
      expect(
        find.byType(ListView).evaluate().isNotEmpty,
        isTrue,
        reason: '首次加载完成后应显示列表',
      );
    });
  });
}
