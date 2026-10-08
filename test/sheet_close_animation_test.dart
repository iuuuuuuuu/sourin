// ═══════════════════════════════════════════════════════════════════════
//  ①-A 选集面板：**关闭时也有动画**（task-28）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > 选集弹窗**关闭的时候没有动画效果**
//
// # 怎么证明"关闭有动画"（而不是瞬间消失）
//
// 判据不是"我调用了动画 API"，而是**逐帧读面板的真实位置/透明度**：
// ```text
// 瞬间消失（改前）  关闭后第 1 帧，面板**已经不在了**（找不到）
// 有动画（改后）    关闭后第 1 帧，面板**还在**，且位置/透明度在**变化**
//                   连续多帧都还在，直到动画结束才消失
// ```
// ★ 关键是**"关闭后仍然存在"** —— 这是 `if (flag)` 写法做不到的：
//   那个写法在 `flag = false` 的那一帧就把子树移除了。
//
// # ★★ 阳性对照（铁律②）
//
// "关闭后第 1 帧找不到面板"有两种解释：
// ```text
// ① 动画做完了（面板确实该消失）   ← 期望
// ② 面板压根没打开过               ← 仪器瞎了
// ```
// 所以每组都先证明**打开状态下能读到面板**，再看关闭时的行为。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/episode_strip.dart';

List<Episode> fakeEpisodes(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(id: 'ep$i', title: '第$i集', url: 'https://x.invalid/$i.m3u8'),
    ];

/// 一个能**外部切换 visible** 的宿主 —— 用来模拟播放页的开关
class _Host extends StatefulWidget {
  const _Host({required this.slideFrom});

  final Offset slideFrom;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool _visible = true;

  void setVisible(bool v) => setState(() => _visible = v);

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          /*
           * ⚠️ **不包 `FTheme`** —— 与 `episode_drawer_test.dart` 一致。
           *
           * `EpisodePanel` 内部用 `FTheme.of(context)` 取色，
           * 没有祖先时会**静默兜底**（forui 的默认主题）。
           * 本文件验的是**几何/动画**（位移、透明度、挂载状态），
           * 与配色无关 —— 所以不需要真实主题，少一层依赖更稳。
           *
           * ★ 而且构造 `FThemeData()` 本身还要传 `colors` / `touch`，
           *   在测试里拼一个假主题只会引入无关的失败点。
           */
          body: Stack(
            children: [
              Positioned.fill(
                child: SheetTransition(
                  visible: _visible,
                  slideFrom: widget.slideFrom,
                  child: EpisodePanel(
                    episodes: fakeEpisodes(5),
                    currentIndex: 0,
                    onPick: (_) {},
                    onClose: () {},
                    isDesktopOverride: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

/// 面板是否还在树上
///
/// ⚠️ 用 `EpisodePanel`（而不是某段文字）—— 面板在**退出动画期间**
///    仍然挂着，这正是要判定的东西。
bool panelPresent() => find.byType(EpisodePanel).evaluate().isNotEmpty;

/// 读 SheetTransition **自己那层**施加的位移
///
/// # ⚠️ 为什么不能"取绝对值最大的那个"（我第二版就错在这）
///
/// 诊断探针打出来是 `Transform 个数 = 3`：
/// ```text
/// 打开状态  [(0.0,0.0), (0.0,0.0), (0.0,0.0)]
/// +80ms     [(0.0,0.7), (0.0,0.0), (0.0,0.0)]   ← 宿主那层
/// +120ms    [(0.0,16.3), (0.0,0.0), (0.0,0.0)]
/// ```
/// 我以为"只有宿主在动"，于是第二版改成"取绝对值最大的" ——
/// **错了**：`EpisodeSheet` 内部**自己也有**一个进入动画
/// （`TweenAnimationBuilder` 从 24 → 0），刚打开时它那个是 **24**，
/// 比宿主的 0 大 ⇒ 我的读取器抓到了**面板自己的**动画，
/// 于是阳性对照报 "Expected: less than 0.01, Actual: 24.0"。
///
/// # 正确做法：按**树层级**取 —— 宿主的 Transform 是**最外层**那个
///
/// `SheetTransition.build` 的结构是：
/// ```text
/// SheetTransition
///   └ AnimatedBuilder
///       └ Opacity            ← 宿主
///           └ Transform      ← ★ 宿主（最外层）
///               └ IgnorePointer
///                   └ child = EpisodePanel
///                       └ ... EpisodeSheet 内部的 Transform（更深）
/// ```
/// 所以用 `find.descendant` 会同时匹配到内外两层；
/// 要区分它们，按 **element 深度**取最小的那个（深度小 = 更外层）。
///
/// ⚠️ 我没有用 `find.byType(Transform).first` —— 那是靠遍历顺序，
///    而遍历顺序不是文档承诺的（第一版"碰巧"对，不可依赖）。
Offset currentOffset(WidgetTester t) {
  final f = find.descendant(
    of: find.byType(SheetTransition),
    matching: find.byType(Transform),
  );
  final els = f.evaluate().toList();
  if (els.isEmpty) return Offset.zero;
  // 取**深度最小**（= 最外层）的那个
  Element? best;
  var bestDepth = 1 << 30;
  for (final e in els) {
    var d = 0;
    e.visitAncestorElements((_) {
      d++;
      return true;
    });
    if (d < bestDepth) {
      bestDepth = d;
      best = e;
    }
  }
  final m = t.widget<Transform>(find.byWidget(best!.widget)).transform;
  return Offset(m.storage[12], m.storage[13]);
}

/// 读 SheetTransition **自己那层**施加的透明度（同样取最外层）
double currentOpacity(WidgetTester t) {
  final f = find.descendant(
    of: find.byType(SheetTransition),
    matching: find.byType(Opacity),
  );
  final els = f.evaluate().toList();
  if (els.isEmpty) return 1.0;
  Element? best;
  var bestDepth = 1 << 30;
  for (final e in els) {
    var d = 0;
    e.visitAncestorElements((_) {
      d++;
      return true;
    });
    if (d < bestDepth) {
      bestDepth = d;
      best = e;
    }
  }
  return t.widget<Opacity>(find.byWidget(best!.widget)).opacity;
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ★★ 阳性对照：先证明"打开时能读到面板"
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('★★★ 阳性对照：visible=true 时面板**在**，且位移/透明度为"在位"值',
      (t) async {
    await t.pumpWidget(const _Host(slideFrom: Offset(24, 0)));
    await t.pump();

    expect(panelPresent(), isTrue,
        reason: '★★ 阳性对照：打开状态下面板必须存在 —— '
            '这一条不过，下面所有"关闭后还在"的判定都无意义');

    // 在位时不该有位移、不该半透明
    expect(currentOffset(t).dx.abs(), lessThan(0.01),
        reason: '★ 在位时位移应为 0（进入动画由子组件自己跑，宿主不掺和）');
    expect(currentOpacity(t), closeTo(1.0, 0.01),
        reason: '★ 在位时应当完全不透明');

    // 让子组件自己的进入动画跑完（避免 pending 动画影响后面的用例）
    await t.pump(Motion.base);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 核心：关闭时**逐帧都还在**，且位移/透明度在变
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('★★★ 关闭后第 1 帧：面板**仍然存在**（不是瞬间消失）',
      (t) async {
    await t.pumpWidget(const _Host(slideFrom: Offset(24, 0)));
    await t.pump();
    await t.pump(Motion.base); // 让进入动画跑完

    // ── 关闭 ──
    final state = t.state<_HostState>(find.byType(_Host));
    state.setVisible(false);
    await t.pump(); // ★ 只推一帧

    expect(
      panelPresent(),
      isTrue,
      reason: '★★★ 用户报的 bug：关闭时**不能瞬间消失** —— '
          '第 1 帧面板必须还在（正在播退出动画）。'
          '若这里为 false，说明又回到了 `if (flag)` 那种硬切',
    );

    // 让动画跑完
    await t.pump(Motion.base);
    await t.pump(Motion.base);
  });

  testWidgets('★★★ 关闭过程中：位移**逐渐增大**（真的在滑出）', (t) async {
    await t.pumpWidget(const _Host(slideFrom: Offset(24, 0)));
    await t.pump();
    await t.pump(Motion.base);

    final state = t.state<_HostState>(find.byType(_Host));
    state.setVisible(false);

    // 逐帧采样位移 —— 必须**单调增大**（往右滑出）
    final offsets = <double>[];
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 40));
      if (!panelPresent()) break;
      offsets.add(currentOffset(t).dx);
    }

    expect(offsets.length, greaterThanOrEqualTo(2),
        reason: '★★ 至少要采到 2 帧 —— 只有 1 帧就说明是瞬间消失');
    for (var i = 1; i < offsets.length; i++) {
      expect(
        offsets[i],
        greaterThanOrEqualTo(offsets[i - 1]),
        reason: '★★ 退出动画必须**单调**滑出（第 $i 帧 ${offsets[i]} '
            '不应小于上一帧 ${offsets[i - 1]}）',
      );
    }
    expect(offsets.last, greaterThan(0),
        reason: '★★ 动画结束时必须有实际位移（否则等于没动）');

    await t.pump(Motion.base);
    await t.pump(Motion.base);
  });

  testWidgets('★★ 关闭过程中：透明度**逐渐降低**（淡出）', (t) async {
    await t.pumpWidget(const _Host(slideFrom: Offset(24, 0)));
    await t.pump();
    await t.pump(Motion.base);

    final state = t.state<_HostState>(find.byType(_Host));
    state.setVisible(false);

    final opacities = <double>[];
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 40));
      if (!panelPresent()) break;
      opacities.add(currentOpacity(t));
    }

    expect(opacities.length, greaterThanOrEqualTo(2));
    for (var i = 1; i < opacities.length; i++) {
      expect(
        opacities[i],
        lessThanOrEqualTo(opacities[i - 1] + 0.001),
        reason: '★ 淡出必须单调（第 $i 帧 ${opacities[i]} '
            '不应大于上一帧 ${opacities[i - 1]}）',
      );
    }

    await t.pump(Motion.base);
    await t.pump(Motion.base);
  });

  testWidgets('★★ 动画跑完后：面板**真的卸载**（不能永久留着）', (t) async {
    await t.pumpWidget(const _Host(slideFrom: Offset(24, 0)));
    await t.pump();
    await t.pump(Motion.base);

    final state = t.state<_HostState>(find.byType(_Host));
    state.setVisible(false);

    // 推足够长的时间让动画跑完
    await t.pump(Motion.base);
    await t.pump(Motion.base);
    await t.pump(Motion.base);

    expect(panelPresent(), isFalse,
        reason: '★ 动画结束后必须卸载 —— 否则那层会**永久挡着**播放器，'
            '用户点画面没反应');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 方向：底部抽屉要往下滑（不能都往右）
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('★ 底部抽屉（手机）退出时**往下**滑，不是往右', (t) async {
    await t.pumpWidget(const _Host(slideFrom: Offset(0, 24)));
    await t.pump();
    await t.pump(Motion.base);

    final state = t.state<_HostState>(find.byType(_Host));
    state.setVisible(false);

    /*
     * ★★ 采样必须**累积推进**，单次大 pump 读不到（我第一版踩了）
     *
     * 诊断探针（`.probe/probe_tests/zz_diag_sheet2_test.dart`）实测：
     * ```text
     * 单次 pump(120ms)  → dy = 0.0    ← ★ 一次推 120ms，动画没动
     * 累积 20+40+80ms   → dy = 0.7
     * 累积 +120ms       → dy = 16.3   ← 同样的总时长，累积就对了
     * ```
     * 原因：`AnimationController` 的**第一次 tick 只是"启动"**——
     * 它在这一帧把 `lastElapsedDuration` 建立起来，**位移仍是 0**；
     * 真正的插值从**下一帧**才开始。所以必须推**至少两帧**。
     *
     * ⚠️ 这与"曲线起步平"是**两件事**，我第一版把它们混为一谈了：
     * ```text
     * 曲线平（Cubic(0.22,1,0.36,1)）→ 起步慢，但第 2 帧就该有非 0 值
     * 首帧只启动（本原因）        → 第 1 帧**恒为 0**，与曲线无关
     * ```
     * 所以修法是**多推几帧**，而不是"等更久"。
     */
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 40));
    }

    if (panelPresent()) {
      final o = currentOffset(t);
      expect(o.dy, greaterThan(0),
          reason: '★ 底部抽屉必须**往下**滑出（与进入方向一致）');
      expect(o.dx.abs(), lessThan(0.01),
          reason: '★ 底部抽屉不该有横向位移');
    }

    await t.pump(Motion.base);
    await t.pump(Motion.base);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★★ 退出动画期间**不吃点击**（否则用户以为卡住）
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('★★ 退出动画期间不吃点击（否则用户以为"点了没反应"）',
      (t) async {
    await t.pumpWidget(const _Host(slideFrom: Offset(24, 0)));
    await t.pump();
    await t.pump(Motion.base);

    final state = t.state<_HostState>(find.byType(_Host));
    state.setVisible(false);
    await t.pump(const Duration(milliseconds: 60));

    if (panelPresent()) {
      final ip = find.descendant(
        of: find.byType(SheetTransition),
        matching: find.byType(IgnorePointer),
      );
      expect(ip.evaluate(), isNotEmpty,
          reason: '★ 退出期间必须有 `IgnorePointer` 包着');
      expect(t.widget<IgnorePointer>(ip.first).ignoring, isTrue,
          reason: '★★ 退出动画期间必须**忽略**点击 —— '
              '否则用户点画面没反应，会以为卡住了然后连点');
    }

    await t.pump(Motion.base);
    await t.pump(Motion.base);
  });
}
