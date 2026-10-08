// ═══════════════════════════════════════════════════════════════════════
//  task-80 验收探针：搜索页 / 浏览页 的「骨架 → 内容」淡入
// ═══════════════════════════════════════════════════════════════════════
//
// # 验收口径（Lead m01832 的**加严版**）
// ```text
// ① 运行时 `tester.pump(Duration)` 推中间态：
//      t=0 / t=45ms / t=90ms / t=150ms 读到**四个不同的值**
// ② 阴性对照：Reduce Motion 开 ⇒ 四个时刻读数**完全相同**
// ③ 若 90ms 与 150ms 读数无法区分 ⇒ 如实报「仪器分辨率不足」，
//    **不许**把"两次读数一样"写成"时长 ≤150ms"
// ```
//
// # ★★ 为什么不能只断言 `Motion.fade.inMilliseconds <= 300`
// ```text
// 那是**恒等式**：常量本身就写死 200，断言 200 <= 300 永远为真。
// 它与"动画到底播没播"**毫无关系** —— analyze 免费就能给你这个"证据"。
// ⇒ 本探针读的是**渲染树里 `SliverFadeTransition.opacity.value` 的实测值**，
//   不是任何常量、也不是任何 flag。
// ```
//
// # ★★ 采样纪律：为什么是「轮询挂载 + 一次稳定帧」而不是死数 pump 次数
// ```text
// 两个页面挂载淡入 sliver 的**帧号不确定**：
//   · 搜索页：靠 `debugFeedHit` → `setState` ⇒ 下一帧才重建到结果分支
//   · 浏览页：靠 `addPostFrameCallback(_init)` → await FFI(必抛) → finally setState
//             ⇒ 要经过若干个微任务回合才落到空态分支
// ⇒ 死数 pump 次数会把"挂载帧"数错，而**数错一帧就整体偏移 45ms**
//   （读数全错，却依然"看起来像"四个不同的值 ⇒ 假绿）。
//
// ⇒ 本探针的纪律：
//     1) **轮询**（每次 `pump()` 不带时长 ⇒ 假时钟**不前进**）直到
//        `FadeInSliver` 真的出现在树里 —— 记下用了几帧；
//     2) 再 `pump()` **一次**作为稳定帧，让 ticker 走完它的**第一跳**
//        （`Ticker._startTime ??= timeStamp` ⇒ 第一跳 elapsed 恒为 0）；
//     3) 从这一刻起才把 t=0 记为零点，之后三次 `pump(Duration)` 的累计
//        时长就是 45 / 90 / 150ms。
//   ★ 因为第 1、2 步全程 `Duration.zero`，假时钟停在原地 ⇒
//     "零点"是**被找到的**，不是**被猜的**。
// ```
//
// # ★★ 为什么读数必须同时有「阳性对照」和「阴性对照」
// ```text
// 只测"动画开着时四刻不同"是不够的 —— 万一读数函数读的是个常量、
// 或者它读到了**别的** sliver 的 opacity，四刻不同也可能是巧合。
// ⇒ ② 把 Reduce Motion 打开（`MotionPrefs.duration` ⇒ `Duration.zero`）：
//     同一个探针、同一条采样路径，读数**必须塌成同一个值**。
//   ①② 一起才证明：探针测的是"动画播没播"，而不是"widget 在不在"。
// ```
//
// # ★ 读数目标怎么定位（为什么不用裸 `find.byType(SliverFadeTransition)`）
// ```text
// `SliverFadeTransition` 是 Flutter 自带 widget，别的组件也可能用。
// ⇒ 先 `find.byType(FadeInSliver)`（**我们自己的**包装器）定位，
//   再取它**后代**里的 `SliverFadeTransition` ⇒ 读到的必然是本页那个。
//   （两页各自的分支都是 `else` 互斥的 ⇒ 同时最多挂载 1 个。）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/browse_page.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/widgets/fade_in_sliver.dart';

// ══════════════════════════════════════════════════════════════════════════
// 脚手架
// ══════════════════════════════════════════════════════════════════════════

/// 与 `test/t73_search_order_test.dart` 的 `host` 同款，多一个 `reduceMotion`
/// （阴性对照要的 `disableAnimations`）。
///
/// ⚠️ 这里的 `MediaQuery` 位于 `MaterialApp.home` **之内** ⇒ 比 `MaterialApp`
///    自己插的那个更深 ⇒ 对被测页面**生效**。
Widget host(Widget child, Size size, {bool reduceMotion = false}) {
  final theme = FTheme.neutral.light.desktop;
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: MediaQuery(
      data: MediaQueryData(size: size, disableAnimations: reduceMotion),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Scaffold(body: child),
      ),
    ),
  );
}

Future<void> sizeView(WidgetTester t, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

/// 树里挂了几个**我们的**淡入包装器
int fadeCount(WidgetTester t) => find.byType(FadeInSliver).evaluate().length;

/// 读**我们这个** `FadeInSliver` 里 `SliverFadeTransition` 的实际不透明度
///
/// ⚠️ `SliverFadeTransition` 内部是 `RenderSliverAnimatedOpacity`，
///    **不是** `Opacity` widget ⇒ 必须从 widget 上读 `opacity.value`。
///
/// ★ 返回 `null` 表示"树里根本没有" —— 调用方**必须**先断言它非空，
///   否则"没动画"和"没挂载"看起来一模一样（铁律 149 同族陷阱）。
double? currentOpacity(WidgetTester t) {
  final f = find.descendant(
    of: find.byType(FadeInSliver),
    matching: find.byType(SliverFadeTransition),
  );
  if (f.evaluate().isEmpty) return null;
  return t.widget<SliverFadeTransition>(f.first).opacity.value;
}

/// 一次读数，**自带"读数目标真的在"的前置断言**
double readAt(WidgetTester t, String tag, int ms) {
  final n = fadeCount(t);
  expect(
    n,
    greaterThan(0),
    reason: '★★ 铁律 149：读数前必须确认 `FadeInSliver` 真在树里'
        '（$tag @${ms}ms，实测 n=$n）—— 否则"读不到"会被当成"读到了 0"',
  );
  final v = currentOpacity(t);
  expect(v, isNotNull, reason: '★ $tag @${ms}ms：`FadeInSliver` 在，'
      '但它后代里没有 `SliverFadeTransition`');
  expect(v!.isFinite, isTrue, reason: '★ $tag @${ms}ms：读数不是有限数（$v）');
  return v;
}

String fmt(double v) => v.toStringAsFixed(6);

/// 四个读数里**最小的两两间距** = 本探针的实际**分辨率**
double minPairwiseGap(List<double> v) {
  var m = double.infinity;
  for (var i = 0; i < v.length; i++) {
    for (var j = i + 1; j < v.length; j++) {
      final d = (v[i] - v[j]).abs();
      if (d < m) m = d;
    }
  }
  return m;
}

/// ★ 核心：从"淡入 sliver 刚挂载"起，取 t=0 / 45 / 90 / 150ms 四个读数
///
/// 返回 `(读数, 轮询了几帧才挂载)`。
Future<(List<double>, int)> sampleFour(WidgetTester t, String tag) async {
  // ── 1) 轮询挂载（`pump()` 不带时长 ⇒ 假时钟不前进）──
  var pumps = 0;
  while (fadeCount(t) == 0) {
    pumps++;
    if (pumps > 60) {
      fail('★★ $tag：轮询 $pumps 帧仍未挂载 `FadeInSliver` '
          '—— 探针前提不成立（分支没走到），不是"动画没播"');
    }
    await t.pump();
  }

  // ── 2) 稳定帧：让 ticker 走完第一跳（elapsed 恒为 0）──
  await t.pump();

  // ── 3) 四刻读数 ──
  final out = <double>[];
  out.add(readAt(t, tag, 0));
  await t.pump(const Duration(milliseconds: 45));
  out.add(readAt(t, tag, 45));
  await t.pump(const Duration(milliseconds: 45));
  out.add(readAt(t, tag, 90));
  await t.pump(const Duration(milliseconds: 60));
  out.add(readAt(t, tag, 150));
  return (out, pumps);
}

// ══════════════════════════════════════════════════════════════════════════
// 报告（落盘成证据文件）
// ══════════════════════════════════════════════════════════════════════════

final List<String> report = <String>[];

void note(String s) {
  report.add(s);
  // ignore: avoid_print
  print(s);
}

// ══════════════════════════════════════════════════════════════════════════
// 被测数据
// ══════════════════════════════════════════════════════════════════════════

const String kW = '鬼灭之刃';
const Size kViewport = Size(1200, 900);

MediaItem item(String title, [String id = 'p:1']) =>
    MediaItem(id: id, title: title);

SearchStreamEvent hit(String provider, List<MediaItem> items) =>
    SearchStreamEvent(
      kind: SearchEventKind.hit,
      provider: provider,
      providerName: provider,
      items: items,
    );

/// 把搜索页推到「结果」分支（**走真实代码路径**，不是另写一份渲染）
///
/// `_totalProviders == 0` 会挡住整个结果区 ⇒ 必须先 `debugSetProviderCount`
/// （`flutter test` 里 `listProviders()` 必抛 ⇒ 它恒为 0）。
Future<SearchPageState> seedSearch(WidgetTester t) async {
  await sizeView(t, kViewport);
  await t.pumpWidget(host(const SearchPage(), kViewport));
  await t.pump();
  final st = t.state<SearchPageState>(find.byType(SearchPage));
  st.debugSetProviderCount(4);
  st.debugBeginSearch(kW);
  await t.pump();
  return st;
}

void main() {
  tearDownAll(() {
    final f = File('.probe/t80a_four_points.txt');
    f.writeAsStringSync('${report.join('\n')}\n');
    // ignore: avoid_print
    print('★ 读数已落盘：${f.absolute.path}');
  });

  // ══════════════════════════════════════════════════════════════════════
  group('① 搜索页：骨架 → 结果 的淡入（四刻读数）', () {
    testWidgets('★★ 四刻读数互不相同 + 前置/后置对照', (t) async {
      final st = await seedSearch(t);

      // ── 前置：现在必须在**骨架**分支，且骨架**没有**淡入包装 ──
      note('【搜索页】骨架阶段 fadeCount = ${fadeCount(t)}（期望 0：骨架是立刻反馈，不加淡入）');
      expect(
        fadeCount(t),
        0,
        reason: '★ 前置：`_searching && _hits.isEmpty` 时是骨架分支，'
            '它**不该**被 `FadeInSliver` 包（包了就是延迟反馈，与骨架存在的目的相反）',
      );

      // ── 喂一个 hit ⇒ 走真实 `_addHit` 路径 ⇒ 切到结果分支 ──
      st.debugFeedHit(hit('p1', [item(kW, 'p1:1'), item('鬼灭之刃 柱训练篇', 'p1:2')]));

      final (pts, pumps) = await sampleFour(t, '搜索页');

      note('');
      note('══════ 搜索页 · 骨架 → 结果 ══════');
      note('轮询 $pumps 帧后挂载（挂载帧不确定 ⇒ 必须轮询，不能猜）');
      note('t=  0ms  opacity = ${fmt(pts[0])}');
      note('t= 45ms  opacity = ${fmt(pts[1])}');
      note('t= 90ms  opacity = ${fmt(pts[2])}');
      note('t=150ms  opacity = ${fmt(pts[3])}');
      note('四刻最小两两间距 = ${fmt(minPairwiseGap(pts))}  ← 本探针实测分辨率');
      note('90ms 与 150ms 的间距 = ${fmt((pts[2] - pts[3]).abs())}');

      // ── ① 四个不同的值 ──
      expect(
        pts.toSet().length,
        4,
        reason: '★★ ① 四刻读数必须**互不相同**（实测 '
            '${pts.map(fmt).join(" / ")}）—— 相同就说明没有中间态',
      );

      // ── ①' 严格递增（0 → 1 的淡入）──
      for (var i = 1; i < pts.length; i++) {
        expect(
          pts[i],
          greaterThan(pts[i - 1]),
          reason: '★ ① 读数必须严格递增：'
              't=${[0, 45, 90, 150][i]}ms 的 ${fmt(pts[i])} '
              '不大于 t=${[0, 45, 90, 150][i - 1]}ms 的 ${fmt(pts[i - 1])}',
        );
      }

      // ── ①'' 起点必须是 0（"从透明开始"）──
      expect(
        pts[0],
        0.0,
        reason: '★★ ① 首帧必须是 0 —— 否则"淡入"根本不存在'
            '（这正是 `AnimatedOpacity` 会踩的坑：初值 == 目标值 ⇒ 不播）',
      );

      // ── ①''' 45ms / 90ms 必须是**真正的中间态**（既非 0 也非 1）──
      for (final i in <int>[1, 2]) {
        expect(
          pts[i] > 0.0 && pts[i] < 1.0,
          isTrue,
          reason: '★★★ ① t=${[0, 45, 90, 150][i]}ms 必须处于**中间态**'
              '（实测=${fmt(pts[i])}）—— 这是"真的有动画"的硬证据',
        );
      }

      // ── ③ 90ms 与 150ms 必须可区分（否则要如实报分辨率不足）──
      expect(
        (pts[2] - pts[3]).abs(),
        greaterThan(0.0),
        reason: '★ ③ 90ms 与 150ms 读数相同 ⇒ 必须如实报「仪器分辨率不足」，'
            '**不许**写成「时长 ≤150ms」',
      );

      // ── 后置：150ms 时还没到 1（动画确实 200ms），再推 100ms 必须到 1 ──
      expect(
        pts[3],
        lessThan(1.0),
        reason: '★ 后置：150ms < 200ms 总时长 ⇒ 还没到终值',
      );
      await t.pump(const Duration(milliseconds: 100));
      final end = readAt(t, '搜索页', 250);
      note('t=250ms  opacity = ${fmt(end)}  ← 终值');
      expect(end, 1.0, reason: '★ 后置：越过 200ms 总时长后必须到 1');

      // ── ② 阴性对照：同一采样路径，Reduce Motion 开 ──
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('★★ ② 阴性对照：Reduce Motion 开 ⇒ 四刻读数完全相同', (t) async {
      await sizeView(t, kViewport);
      await t.pumpWidget(host(const SearchPage(), kViewport, reduceMotion: true));
      await t.pump();
      final st = t.state<SearchPageState>(find.byType(SearchPage));
      st.debugSetProviderCount(4);
      st.debugBeginSearch(kW);
      await t.pump();
      st.debugFeedHit(hit('p1', [item(kW, 'p1:1'), item('鬼灭之刃 柱训练篇', 'p1:2')]));

      final (pts, pumps) = await sampleFour(t, '搜索页/ReduceMotion');

      note('');
      note('══════ 搜索页 · 阴性对照（disableAnimations=true）══════');
      note('轮询 $pumps 帧后挂载（与阳性对照同一条采样路径）');
      note('t=  0ms  opacity = ${fmt(pts[0])}');
      note('t= 45ms  opacity = ${fmt(pts[1])}');
      note('t= 90ms  opacity = ${fmt(pts[2])}');
      note('t=150ms  opacity = ${fmt(pts[3])}');
      note('四刻最小两两间距 = ${fmt(minPairwiseGap(pts))}  ← 必须 = 0');

      expect(
        pts.toSet().length,
        1,
        reason: '★★ ② 阴性对照：Reduce Motion 开 ⇒ `MotionPrefs.duration` 返回 '
            '`Duration.zero` ⇒ **第 0 帧就到位**，四刻读数必须**完全相同**'
            '（实测 ${pts.map(fmt).join(" / ")}）',
      );
      expect(
        pts[0],
        1.0,
        reason: '★ ② "不播"的语义是**直接以终值出现**（opacity=1），不是"停在 0"',
      );

      await t.pumpWidget(const SizedBox());
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('① 浏览页：骨架 → 空态 的淡入（四刻读数）', () {
    testWidgets('★★ 四刻读数互不相同（骨架阶段无包装 + 落空态分支）', (t) async {
      await sizeView(t, kViewport);
      await t.pumpWidget(
        host(const BrowsePage(provider: 'demo', title: '电影'), kViewport),
      );

      // ── 前置：第 1 帧必须是骨架（`_loading` 初值 true），且骨架无包装 ──
      note('【浏览页】第 1 帧 fadeCount = ${fadeCount(t)}（期望 0：骨架分支不包淡入）');
      expect(
        fadeCount(t),
        0,
        reason: '★ 前置：`_loading` 初值 true ⇒ 第 1 帧是骨架分支，不该有淡入包装',
      );

      // ── 之后 `_init()` 必抛（无核心 DLL）⇒ `finally` 把 `_loading` 置 false
      //    ⇒ 落**空态**分支 ⇒ 那个 `FadeInSliver` 真实挂载。
      //    ★ 这条路径是**生产代码自己走出来的**，不需要任何注入口。
      final (pts, pumps) = await sampleFour(t, '浏览页');

      note('');
      note('══════ 浏览页 · 骨架 → 空态 ══════');
      note('轮询 $pumps 帧后挂载（`_init()` 要过若干微任务回合才 setState）');
      note('t=  0ms  opacity = ${fmt(pts[0])}');
      note('t= 45ms  opacity = ${fmt(pts[1])}');
      note('t= 90ms  opacity = ${fmt(pts[2])}');
      note('t=150ms  opacity = ${fmt(pts[3])}');
      note('四刻最小两两间距 = ${fmt(minPairwiseGap(pts))}  ← 本探针实测分辨率');
      note('90ms 与 150ms 的间距 = ${fmt((pts[2] - pts[3]).abs())}');

      expect(
        pts.toSet().length,
        4,
        reason: '★★ ① 四刻读数必须互不相同（实测 ${pts.map(fmt).join(" / ")}）',
      );
      for (var i = 1; i < pts.length; i++) {
        expect(
          pts[i],
          greaterThan(pts[i - 1]),
          reason: '★ ① 读数必须严格递增（第 $i 项）',
        );
      }
      expect(pts[0], 0.0, reason: '★★ ① 首帧必须是 0');
      for (final i in <int>[1, 2]) {
        expect(
          pts[i] > 0.0 && pts[i] < 1.0,
          isTrue,
          reason: '★★★ ① t=${[0, 45, 90, 150][i]}ms 必须是中间态'
              '（实测=${fmt(pts[i])}）',
        );
      }
      expect(
        (pts[2] - pts[3]).abs(),
        greaterThan(0.0),
        reason: '★ ③ 90ms 与 150ms 必须可区分，否则如实报「仪器分辨率不足」',
      );
      await t.pump(const Duration(milliseconds: 100));
      final end = readAt(t, '浏览页', 250);
      note('t=250ms  opacity = ${fmt(end)}  ← 终值');
      expect(end, 1.0, reason: '★ 后置：越过 200ms 后必须到 1');

      await t.pumpWidget(const SizedBox());
    });

    testWidgets('★★ ② 阴性对照：Reduce Motion 开 ⇒ 四刻读数完全相同', (t) async {
      await sizeView(t, kViewport);
      await t.pumpWidget(
        host(
          const BrowsePage(provider: 'demo', title: '电影'),
          kViewport,
          reduceMotion: true,
        ),
      );

      final (pts, pumps) = await sampleFour(t, '浏览页/ReduceMotion');

      note('');
      note('══════ 浏览页 · 阴性对照（disableAnimations=true）══════');
      note('轮询 $pumps 帧后挂载（与阳性对照同一条采样路径）');
      note('t=  0ms  opacity = ${fmt(pts[0])}');
      note('t= 45ms  opacity = ${fmt(pts[1])}');
      note('t= 90ms  opacity = ${fmt(pts[2])}');
      note('t=150ms  opacity = ${fmt(pts[3])}');
      note('四刻最小两两间距 = ${fmt(minPairwiseGap(pts))}  ← 必须 = 0');

      expect(
        pts.toSet().length,
        1,
        reason: '★★ ② 阴性对照：四刻读数必须完全相同'
            '（实测 ${pts.map(fmt).join(" / ")}）',
      );
      expect(pts[0], 1.0, reason: '★ ② 直接以终值出现');

      await t.pumpWidget(const SizedBox());
    });
  });
}
