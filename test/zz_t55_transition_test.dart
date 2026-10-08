// ═══════════════════════════════════════════════════════════════════════
//  task-55：多种动画效果 + 可切换（用户原话「多做几个我来切换的」）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户要求（逐字）
// ```text
// 6.动画效果加一下,多个动画效果
// 然后还有个动画效果,我说让你多做几个我来切换的,这个你也没做
// ```
//
// # 本文件证明什么（每条都对应一个"用户会问"的问题）
// ```text
// ① 「真的有多种吗？」      ⇒ 枚举里 ≥5 种 + 每种**渲染形状不同**（逐帧读数）
// ② 「我真的能切换吗？」    ⇒ `set()` 改 notifier + 写 UiPrefs
// ③ 「切换后真的变了吗？」  ⇒ ★★ 同一次过渡，换风格 ⇒ **帧序列不同**（硬证据）
// ④ 「重启后还在吗？」      ⇒ `syncFromPrefs()` 从 UiPrefs 读回
// ⑤ 「能关掉吗？」          ⇒ `none` ⇒ **不包任何 widget**（真·零开销）
// ⑥ 「系统减少动效时呢？」  ⇒ `MotionPrefs.resolve` 强制 `none`
// ```
//
// # ★★★ 判据设计的核心（避免"假通过"）
// ```text
// 只断言"widget 树里有 FadeTransition"是**弱判据** ——
//   它证明"我包了组件"，不证明"动画形状真的不同"。
// ★ 所以我**逐帧采样**每种风格的**可观测几何量**：
//     · opacity      （FadeTransition 的当前值）
//     · 位移 offset  （SlideTransition 的当前值）
//     · 缩放 scale   （ScaleTransition 的当前值）
//   ⇒ 不同风格的**序列不同** ⇒ 这才是"真的有多种"的证据
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/motion_prefs.dart';
import 'package:sourin_spike/ui/widgets/page_transition.dart';

/// ★★★ 用**最小包装**而不是 `MaterialApp`（这是我在本文件里踩到的第一个坑）
///
/// # 为什么不能用 `MaterialApp`
/// ```text
/// 我第一版用 `MaterialApp(home: PageTransition.apply(...))`，结果：
///   T55SHAPE|fade|1.00→1.00 …        ← ★ opacity 恒为 1（应该 0→1）
///   Expected: no matching candidates
///   Actual: Found **4** widgets with type "FadeTransition"
/// ★ 根因：`MaterialApp` **自带**路由过渡（它内部就有 FadeTransition/
///   SlideTransition），而 `find.byType(...)` 会**连它的一起找到** ⇒
///   `.first` 拿到的可能是**路由的**那个，而不是我 `apply()` 包的那个。
/// ⇒ ★ 判据**测错了对象**（看起来"动画没播"，其实是读错了 widget）。
/// ```
/// ⇒ 修法：用 `Directionality + MediaQuery` 这个**最小**包装 ——
///   它不引入任何过渡 widget ⇒ `find.byType` 只会找到**我的**。
Widget _wrap(Widget child, {bool reduceMotion = false}) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: child,
      ),
    );

/// 采一帧：把当前过渡的**可观测几何量**读出来
///
/// 返回 `(opacity, dx, dy, scale)`；缺哪个就填该量的"中性值"。
({double opacity, double dx, double dy, double scale}) sample(WidgetTester t) {
  var opacity = 1.0;
  var dx = 0.0;
  var dy = 0.0;
  var scale = 1.0;

  final f = find.byType(FadeTransition);
  if (f.evaluate().isNotEmpty) {
    opacity = t.widget<FadeTransition>(f.first).opacity.value;
  }
  final s = find.byType(SlideTransition);
  if (s.evaluate().isNotEmpty) {
    final o = t.widget<SlideTransition>(s.first).position.value;
    dx = o.dx;
    dy = o.dy;
  }
  final sc = find.byType(ScaleTransition);
  if (sc.evaluate().isNotEmpty) {
    scale = t.widget<ScaleTransition>(sc.first).scale.value;
  }
  return (opacity: opacity, dx: dx, dy: dy, scale: scale);
}

/// 用**给定风格**跑一次完整的 0→1 过渡，返回逐帧序列
///
/// ★ 用真实的 `AnimationController`（与 shell 里同样的驱动方式）——
///   而不是"直接给个 AlwaysStoppedAnimation"（那测不到补间过程）。
Future<List<({double opacity, double dx, double dy, double scale})>> trace(
  WidgetTester t,
  PageTransitionStyle style, {
  int frames = 12,
  int stepMs = 25,
  double dir = 1,
}) async {
  final c = AnimationController(
    vsync: t,
    duration: const Duration(milliseconds: 300),
    value: 0,
  );
  addTearDown(c.dispose);

  await t.pumpWidget(
    _wrap(
      PageTransition.apply(
        animation: c,
        style: style,
        dir: dir,
        child: const SizedBox(width: 100, height: 100),
      ),
    ),
  );

  final seq = <({double opacity, double dx, double dy, double scale})>[];
  seq.add(sample(t));          // ★ 第 0 帧（补间尚未开始）
  c.forward(from: 0);
  for (var i = 0; i < frames; i++) {
    await t.pump(Duration(milliseconds: stepMs));
    seq.add(sample(t));
  }
  /*
   * ★★ 必须再推一帧到"动画结束之后"（否则末帧不是终值）
   *
   * # 我踩到的（本文件第二个坑）
   * ```text
   * 我原来只推 frames=12 帧 × 25ms = **300ms** —— 那正好等于动画时长。
   * ★ 而 `pump(300ms)` 之后 controller 停在 **t=1.0 之前的一瞬**
   *   （实测末帧 opacity=0.9167，即 11/12 ≈ 0.917）——
   *   因为第一帧 `sample()` 是在 `forward()` **之前**采的（t=0），
   *   所以 12 次 pump 只覆盖到 11/12 的进度。
   * ⇒ 断言"末帧 = 终值"失败（看起来像"动画没走完"，其实是**采样窗口短了**）。
   * ```
   * ⇒ 修法：显式再推一个"远超时长"的量（`duration + 100ms`），
   *   确保控制器**已经完成** ⇒ 末帧就是终值。
   */
  await t.pump(const Duration(milliseconds: 400));
  seq.add(sample(t));          // ★ 终帧（动画已完成）
  return seq;
}

void main() {
  setUp(() {
    // 每个用例从默认值开始（避免相互污染）
    PageTransitionStyleStore.resetForTest(
      PageTransitionStyleStore.defaultStyle,
    );
  });

  // ══════════════════════════════════════════════════════════════════
  group('① 「真的有多种吗？」—— 每种风格的形状必须不同', () {
    testWidgets('★★ 枚举里至少 5 种（含"无动画"）', (t) async {
      expect(
        PageTransition.options.length,
        greaterThanOrEqualTo(5),
        reason: '★ 用户说"**多做几个**" ⇒ 至少 5 种（含关掉的那个）',
      );
      expect(
        PageTransition.options,
        contains(PageTransitionStyle.none),
        reason: '★★ 用户说"我来切换的" ⇒ **必须能关掉**'
            '（只能开不能关不算"切换"）',
      );
    });

    testWidgets('★★★ 六种风格的**帧序列互不相同**（这是"多种"的硬证据）',
        (t) async {
      final traces = <PageTransitionStyle, String>{};
      for (final s in PageTransitionStyle.values) {
        final seq = await trace(t, s);
        // 把序列压成字符串指纹（含 opacity/位移/缩放）
        traces[s] = seq
            .map((v) => '${v.opacity.toStringAsFixed(2)},'
                '${v.dx.toStringAsFixed(3)},'
                '${v.dy.toStringAsFixed(3)},'
                '${v.scale.toStringAsFixed(3)}')
            .join('|');
        debugPrint('T55SHAPE|${s.name}|${seq.first.opacity.toStringAsFixed(2)}'
            '→${seq.last.opacity.toStringAsFixed(2)}'
            ' dx=${seq.first.dx.toStringAsFixed(3)}'
            ' dy=${seq.first.dy.toStringAsFixed(3)}'
            ' sc=${seq.first.scale.toStringAsFixed(2)}');
      }

      // ★ 两两比较：不允许任意两种的序列完全相同
      final names = traces.keys.toList();
      for (var i = 0; i < names.length; i++) {
        for (var j = i + 1; j < names.length; j++) {
          expect(
            traces[names[i]],
            isNot(equals(traces[names[j]])),
            reason: '★★★ `${names[i].name}` 与 `${names[j].name}` 的'
                '**帧序列完全相同** ⇒ 用户选了两个却看到一样的动画'
                '（那就是"假的多选一"）',
          );
        }
      }
    });

    testWidgets('★★ 各自的**特征量**正确（位移/缩放/纯淡入各就各位）',
        (t) async {
      // fade：首帧 opacity=0，**无位移、无缩放**
      final fade = await trace(t, PageTransitionStyle.fade);
      expect(fade.first.opacity, closeTo(0, 0.01));
      expect(fade.first.dx.abs(), lessThan(0.001), reason: '淡入不该有位移');
      expect(fade.first.scale, closeTo(1.0, 0.001), reason: '淡入不该有缩放');

      // slideRight：**有水平位移**（dir=+1 ⇒ 从右侧进来 ⇒ dx > 0）
      final sr = await trace(t, PageTransitionStyle.slideRight, dir: 1);
      expect(sr.first.dx, greaterThan(0), reason: '右滑首帧应在右侧（dx>0）');
      expect(sr.first.dy.abs(), lessThan(0.001), reason: '右滑不该有纵向位移');

      // slideRight 的 dir=-1 ⇒ 从左侧进来
      final sl = await trace(t, PageTransitionStyle.slideRight, dir: -1);
      expect(sl.first.dx, lessThan(0), reason: 'dir=-1 ⇒ 首帧在左侧（dx<0）');

      // slideUp：**有纵向位移**（从下往上 ⇒ dy > 0）
      final su = await trace(t, PageTransitionStyle.slideUp);
      expect(su.first.dy, greaterThan(0), reason: '上滑首帧应在下方（dy>0）');

      // zoom：**有缩放**（<1 起）
      final zm = await trace(t, PageTransitionStyle.zoom);
      expect(zm.first.scale, lessThan(1.0), reason: '缩放首帧应小于 1');

      // fadeUp：有**小幅**纵向位移（比 slideUp 小）
      final fu = await trace(t, PageTransitionStyle.fadeUp);
      expect(fu.first.dy, greaterThan(0));
      expect(
        fu.first.dy,
        lessThan(su.first.dy),
        reason: '★ "上浮"幅度必须**小于**"上滑"（否则两种看起来一样）',
      );

      // 全部终帧都应"就位"
      for (final seq in [fade, sr, su, zm, fu]) {
        expect(seq.last.opacity, closeTo(1.0, 0.01));
        expect(seq.last.dx.abs(), lessThan(0.001));
        expect(seq.last.dy.abs(), lessThan(0.001));
        expect(seq.last.scale, closeTo(1.0, 0.01));
      }
    });

    testWidgets('★★★ none ⇒ **完全不包任何动画 widget**（真·零开销）',
        (t) async {
      await t.pumpWidget(
        _wrap(
          PageTransition.apply(
            animation: const AlwaysStoppedAnimation<double>(0.5),
            style: PageTransitionStyle.none,
            child: const Text('X'),
          ),
        ),
      );
      expect(
        find.byType(FadeTransition),
        findsNothing,
        reason: '★★ `none` 必须是"直接返回 child" —— '
            '若仍包 `FadeTransition`（哪怕 duration=0），'
            '那就不是"关掉"，只是"动得快"',
      );
      expect(find.byType(SlideTransition), findsNothing);
      expect(find.byType(ScaleTransition), findsNothing);
      expect(find.text('X'), findsOneWidget, reason: '★ 内容必须照常显示');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  group('② 「我真的能切换吗？」—— 切换 + 持久化', () {
    testWidgets('★★ 切换后 notifier 变 + 写进 UiPrefs', (t) async {
      // 先清掉，确保测的是"真的写了"
      UiPrefs.remove(PageTransitionStyleStore.prefKey);

      expect(PageTransitionStyleStore.current.value,
          PageTransitionStyleStore.defaultStyle,
          reason: '★ 初始必须是默认值（= 现状观感）');

      PageTransitionStyleStore.set(PageTransitionStyle.zoom);

      expect(PageTransitionStyleStore.current.value, PageTransitionStyle.zoom,
          reason: '★★ notifier 必须立刻变（这是"立刻生效"的机制）');
      expect(
        UiPrefs.get(PageTransitionStyleStore.prefKey),
        PageTransitionStyle.zoom.name,
        reason: '★★ 必须写进 UiPrefs（否则重启后丢失）—— '
            '★ 用 `name` 而不是 index（index 会在枚举顺序变化时错位）',
      );

      /*
       * ★★ 必须把 `UiPrefs` 的**延迟落盘定时器**推完
       *
       * # 我踩到的（本文件第三个坑，两层）
       * ```text
       * 第一层：报错 `A Timer is still pending after the widget tree was disposed`
       *   ⇒ 根因：`UiPrefs.set()` → `_flushSoon()` 起了一个
       *     `Future.delayed(300ms)`（**debounce**，把多次写合并成一次落盘）。
       *     `flutter_test` 在用例结束时会断言"没有挂起的定时器"。
       *   ★ 这不是产品 bug（debounce 是**故意**的：避免频繁写盘），
       *     而是**测试必须收尾**。
       *
       * 第二层：我加了 `await UiPrefs.flush()` 但**仍然报 pending** ——
       *   ★ 因为 `flush()` **不取消** `_pending`（它只负责"写盘"），
       *     那个 300ms 的 `Future.delayed` 依然挂在事件循环上。
       * ```
       * ⇒ 修法：**等那个 300ms 过去**（`tester.pump(350ms)` 推进假时钟）。
       *   ★ 在 `testWidgets` 里 `pump(Duration)` 会推进 `FakeAsync` 的时钟
       *     ⇒ 定时器自然到期、`_pending` 被清空 ⇒ 用例可以正常结束。
       */
      await t.pump(const Duration(milliseconds: 350));
      await UiPrefs.flush();
    });

    testWidgets('★★ 幂等：设成同一个值不重复通知', (t) async {
      PageTransitionStyleStore.resetForTest(PageTransitionStyle.fade);
      var notifications = 0;
      void listener() => notifications++;
      PageTransitionStyleStore.current.addListener(listener);
      addTearDown(
        () => PageTransitionStyleStore.current.removeListener(listener),
      );

      PageTransitionStyleStore.set(PageTransitionStyle.fade); // 同值
      expect(notifications, 0,
          reason: '★ 同值不该通知（否则每次进设置页都会触发一次全树重建）');

      PageTransitionStyleStore.set(PageTransitionStyle.slideUp); // 不同值
      expect(notifications, 1, reason: '★ 真变了才通知');

      // ★ 收尾：`set()` 真变了那次会写 UiPrefs ⇒ 推完它的 debounce 定时器
      //   （见"切换后 notifier 变"那条的详细说明）
      await t.pump(const Duration(milliseconds: 350));
      await UiPrefs.flush();
    });

    testWidgets('★★★ 「重启后还在吗？」—— syncFromPrefs 从磁盘读回', (t) async {
      /*
       * ★ 这条模拟**重启**：磁盘里有值，但 notifier 还是默认值
       *   （因为 `static final` 初始化早于 `UiPrefs.load`）。
       */
      UiPrefs.set(PageTransitionStyleStore.prefKey,
          PageTransitionStyle.slideUp.name);
      PageTransitionStyleStore.resetForTest(PageTransitionStyle.slideRight);

      // ★ 这一步就是 shell.dart 里 `UiPrefs.load()` 之后调的那句
      PageTransitionStyleStore.syncFromPrefs();

      expect(
        PageTransitionStyleStore.current.value,
        PageTransitionStyle.slideUp,
        reason: '★★★ 必须从 UiPrefs 读回 —— 否则"重启后设置失效"'
            '（用户会以为"没保存"）',
      );
      await t.pump(const Duration(milliseconds: 350));   // ★ 收尾：推完 debounce 定时器
      await UiPrefs.flush();
    });

    testWidgets('★ 磁盘值损坏（手改了 json）⇒ 回默认，不崩', (t) async {
      UiPrefs.set(PageTransitionStyleStore.prefKey, 'THIS_IS_NOT_A_STYLE');
      PageTransitionStyleStore.syncFromPrefs();
      expect(
        PageTransitionStyleStore.current.value,
        PageTransitionStyleStore.defaultStyle,
        reason: '★ 未知值必须**优雅回退**到默认（不能崩、不能留空）',
      );
      await t.pump(const Duration(milliseconds: 350));   // ★ 收尾
      await UiPrefs.flush();
    });
  });

  // ══════════════════════════════════════════════════════════════════
  group('③ 系统"减少动态效果"（无障碍）', () {
    testWidgets('★★★ 系统要求减少 ⇒ resolve 强制 none（不管用户选了什么）',
        (t) async {
      late PageTransitionStyle got;
      await t.pumpWidget(
        _wrap(
          Builder(builder: (c) {
            got = MotionPrefs.resolve(c, PageTransitionStyle.zoom);
            return const SizedBox();
          }),
          reduceMotion: true,
        ),
      );
      expect(
        got,
        PageTransitionStyle.none,
        reason: '★★★ 系统开了"减少动态效果" ⇒ 即使用户选了缩放，也**不许播** —— '
            '无障碍是硬约束（前庭功能障碍者会因动效眩晕）',
      );
    });

    testWidgets('★★ 对照：系统没开 ⇒ 用户的选法**原样生效**', (t) async {
      late PageTransitionStyle got;
      await t.pumpWidget(
        _wrap(
          Builder(builder: (c) {
            got = MotionPrefs.resolve(c, PageTransitionStyle.zoom);
            return const SizedBox();
          }),
        ),
      );
      expect(
        got,
        PageTransitionStyle.zoom,
        reason: '★★ 对照必须成立 —— 否则上面那条"强制 none"无法区分'
            '"因为系统偏好"还是"因为代码总是返回 none"（空断言）',
      );
    });
  });
}
