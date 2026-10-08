// ═══════════════════════════════════════════════════════════════════════
//  task-44 B 项：骨架 → 内容 的淡入过渡（含 Reduce Motion）
// ═══════════════════════════════════════════════════════════════════════
//
// # 判据（全部**可观测**，不是"读了 flag"）
// ```text
// ① 首帧不透明 = 0（动画真的从透明开始）
// ② 中途存在**中间态**（不是瞬变）—— ★ 这是"真的有动画"的硬证据
// ③ 结束时不透明 = 1
// ④ ★ Reduce Motion 开 ⇒ **第 0 帧就到位**（没有中间态）
//    ★ 而且红度对照：不开时**必须**有中间态（否则 ④ 是空断言）
// ⑤ 时长 ≤ 300ms（Lead 判据②）
// ```
//
// # 为什么用 `Opacity` 的**实际值**做判据，而不是断言 `duration`
// ```text
// Lead 明确要求：
//   「widget 测试：把 `MediaQuery(disableAnimations: true)` 包上去
//     ⇒ ★ 断言**动画真的不播**（不只是 duration 为 0）
//     ★ 红度证明：不包时该断言必须**失败**
//     ⇒ 否则你只证明了"我读到了这个 flag"，没证明"动画被跳过了"」
// ★ 这与我在 task-42 抓到的"传了 tag 参数但没渲染"是**同族**问题：
//   **"设置了参数" ≠ "行为真的变了"**
// ⇒ 所以这里读的是**渲染树里 Opacity 的实际 opacity 值**。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/fade_in_sliver.dart';
import 'package:sourin_spike/ui/widgets/motion_prefs.dart';

/// 挂一个最小的 `CustomScrollView`，把孩子作为唯一 sliver
///
/// ★ 用**真实**的 `CustomScrollView`（而不是裸 `Column`）——
///   因为 `FadeInSliver` 的正确性**依赖于它在 sliver 上下文里工作**。
///   若用盒模型容器测，就测不到"sliver 包装是否合法"这件事
///   （那正是本组件最容易错的地方）。
///
/// # ★★★ 为什么末尾要 `pump()` 一次（消除 flaky）
/// ```text
/// 我第一版没有这次 pump，结果 m3 红度证明**时红时绿**（一次 passed、三次 failed）。
///
/// 根因：`TweenAnimationBuilder` 在 `pumpWidget` 内部会经历
/// "挂载 → 注册 ticker → 第一帧" 几个阶段。
/// `pumpWidget` 结束后动画可能**还没开始**（时间轴停在 0），
/// 也可能**已经推进了一帧**（取决于微型任务与帧调度的交错）。
/// ⇒ ★ 于是"首帧 opacity"读到的可能不是 0（而是已经涨了一点）
///   ⇒ 断言时红时绿。
//
/// ⇒ 修法：`pumpWidget` 之后再 `pump(Duration.zero)` **一次**，
///   把"挂载"这件事**确定性地**推进到"第一帧已渲染"。
///   ★ 这样读到的 opacity 就**确定**是"动画起点"（0，或 Reduce Motion 下的 1）。
/// ```
Future<void> pumpSliver(
  WidgetTester t,
  Widget sliver, {
  bool reduceMotion = false,
}) async {
  await t.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: CustomScrollView(
          slivers: [
            // 顶部留白，保证 sliver 有布局空间
            const SliverToBoxAdapter(child: SizedBox(height: 20)),
            sliver,
          ],
        ),
      ),
    ),
  );
  // ★ 确定性推进到"第一帧"（见上面的 flaky 分析）
  await t.pump(Duration.zero);
}

/// 读取渲染树里第一个 `Opacity` 的实际值
///
/// ⚠️ `SliverFadeTransition` 内部用的是 `RenderSliverAnimatedOpacity`，
///    **不是** `Opacity` widget ⇒ 要用 `find.byType(SliverFadeTransition)`
///    再读它的 `opacity.value`。
double? currentOpacity(WidgetTester t) {
  final f = find.byType(SliverFadeTransition);
  if (f.evaluate().isEmpty) return null;
  final w = t.widget<SliverFadeTransition>(f.first);
  return w.opacity.value;
}

/// 一个可辨识的 sliver 孩子
Widget subjectSliver() => const SliverToBoxAdapter(
      child: SizedBox(height: 100, child: Text('SUBJECT')),
    );

void main() {
  group('① FadeInSliver 基本行为（动画真的播了）', () {
    testWidgets('★★ 首帧 opacity=0 ⇒ 中途有中间态 ⇒ 结束 =1', (t) async {
      await pumpSliver(t, FadeInSliver(sliver: subjectSliver()));

      // ① 首帧：应当从 0 开始
      final first = currentOpacity(t);
      expect(first, isNotNull, reason: '★ 必须能读到 SliverFadeTransition');
      expect(
        first,
        0.0,
        reason: '★★ 第一帧 opacity 必须是 0 —— 否则"淡入"根本不存在'
            '（这正是 `AnimatedOpacity` 会踩的坑：初值==目标值 ⇒ 不播）',
      );

      // ② 中途：必须有中间态（这是"真的有动画"的硬证据）
      await t.pump(const Duration(milliseconds: 100));
      final mid = currentOpacity(t);
      expect(
        mid,
        isNotNull,
      );
      expect(
        mid! > 0.0 && mid < 1.0,
        isTrue,
        reason: '★★★ 100ms 时必须处于**中间态**（实测=$mid）—— '
            '若这里是 0 或 1，说明动画是**瞬变**（要么没播、要么已结束）',
      );

      // ③ 结束：应当到 1
      await t.pump(const Duration(milliseconds: 200));
      expect(
        currentOpacity(t),
        1.0,
        reason: '★ 动画结束后 opacity 必须回到 1（否则内容永久半透明）',
      );
    });

    testWidgets('★ 时长 ≤ 300ms（Lead 判据②）', (t) async {
      // 直接断言常量（客观值），并加一条"到 300ms 时必定已完成"
      expect(
        FadeInSliver.defaultDuration.inMilliseconds <= 300,
        isTrue,
        reason: '★ 默认时长必须 ≤300ms，实测 '
            '${FadeInSliver.defaultDuration.inMilliseconds}ms',
      );

      await pumpSliver(t, FadeInSliver(sliver: subjectSliver()));
      // 300ms 之后一定已完成
      await t.pump(const Duration(milliseconds: 300));
      expect(currentOpacity(t), 1.0,
          reason: '★ 300ms 时动画必须已经结束（判据②：不拖慢操作）');
    });

    testWidgets('★ 可被打断：动画中途用户滚动不抛异常（判据③）', (t) async {
      await pumpSliver(t, FadeInSliver(sliver: subjectSliver()));
      await t.pump(const Duration(milliseconds: 50));

      // 中途滚动
      await t.drag(find.byType(CustomScrollView), const Offset(0, -40));
      await t.pump(const Duration(milliseconds: 50));

      // 不抛异常即算通过；且 opacity 仍在合法区间
      final v = currentOpacity(t);
      expect(v, isNotNull);
      expect(v! >= 0.0 && v <= 1.0, isTrue,
          reason: '★ 中断后 opacity 必须仍在 [0,1]（不能越界）');
    });
  });

  group('② ★★★ Reduce Motion（判据④）—— 断言"行为"而非"flag"', () {
    testWidgets('★★ disableAnimations=true ⇒ **第 0 帧就到位**（无中间态）',
        (t) async {
      await pumpSliver(
        t,
        FadeInSliver(sliver: subjectSliver()),
        reduceMotion: true,
      );

      /*
       * ★★★ 这是本组最关键的断言。
       *
       * Lead 的要求：「断言**动画真的不播**（不只是 duration 为 0）」
       * ⇒ 判据：**第一帧就已经是终值 1.0**
       *   （若动画会播，第一帧必然是 0）
       */
      expect(
        currentOpacity(t),
        1.0,
        reason: '★★★ Reduce Motion 打开时，第一帧就必须是 1.0 —— '
            '若这里是 0，说明动画**仍然会播**（那只证明了"读到了 flag"）',
      );

      // 再推几帧，确认**始终**是 1（没有任何中间态）
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 30));
        expect(
          currentOpacity(t),
          1.0,
          reason: '★★ Reduce Motion 下不允许出现任何中间态（第 ${i + 1} 帧）',
        );
      }
    });

    testWidgets('★★★ 红度对照：**不**开时必须有中间态 ⇒ 证明上面的断言有分辨力',
        (t) async {
      /*
       * ★ 这条是"红度证明"的核心：
       *   若"开了 Reduce Motion"和"没开"的行为**一样**，
       *   那上面那条断言就是**空的**（永远为真）。
       * ⇒ 这里证明：**不开**时第一帧是 0（有动画）
       *   ⇒ 与"开了时第一帧是 1"形成**可观测的差异**
       */
      await pumpSliver(
        t,
        FadeInSliver(sliver: subjectSliver()),
        reduceMotion: false,
      );

      expect(
        currentOpacity(t),
        0.0,
        reason: '★★★ 不开 Reduce Motion 时第一帧必须是 0（有动画）—— '
            '否则"开了就没动画"这条断言无法区分两种情况（空断言）',
      );
    });

    testWidgets('★ MotionPrefs.reduce 直接读 flag（单元层）', (t) async {
      // 开了
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Builder(
              builder: (c) => Text('${MotionPrefs.reduce(c)}'),
            ),
          ),
        ),
      );
      expect(find.text('true'), findsOneWidget);

      // 关了
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: false),
            child: Builder(
              builder: (c) => Text('${MotionPrefs.reduce(c)}'),
            ),
          ),
        ),
      );
      expect(find.text('false'), findsOneWidget);
    });

    testWidgets('★ 没有 MediaQuery 祖先时**不抛异常**且按"不减少"处理',
        (t) async {
      /*
       * ★ 这条守的是一个**真实风险**：
       * `MediaQuery.of` 在没有祖先时**抛异常** ⇒ 会让页面直接崩。
       * ⇒ 我用的是 `maybeOf`（拿不到 = 不减少 = 保持既有行为）。
       */
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (c) => Text('${MotionPrefs.reduce(c)}'),
          ),
        ),
      );
      expect(
        find.text('false'),
        findsOneWidget,
        reason: '★ 拿不到 MediaQuery ⇒ 必须返回 false（不减少）—— '
            '若默认 true，动画会在无 MediaQuery 环境**静默全不播**（更难查）',
      );
    });
  });
}
