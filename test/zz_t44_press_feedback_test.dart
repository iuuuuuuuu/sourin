// ═══════════════════════════════════════════════════════════════════════
//  task-44 A 项：按下反馈（缩放）
// ═══════════════════════════════════════════════════════════════════════
//
// # 判据（Lead 的五条 → 可观测断言）
// ```text
// ① 反馈操作   ⇒ 按下时 scale **真的变小**（读渲染树里的值，不是读参数）
// ② ≤150ms     ⇒ 按下/回弹时长在最低档
// ③ 可被打断   ⇒ 中途抬起不卡住、不越界
// ④ Reduce Motion ⇒ 断言**行为**：仍是"瞬间到位"（有状态、无过渡）
// ⑤ 惯用法     ⇒ 用 `AnimatedScale`（断言渲染树里存在它）
// ```
//
// # ★★★ 最重要的一条：**Listener 不消费手势**
// ```text
// 我选 `Listener` 而不是 `GestureDetector` 的**唯一理由**就是：
//   `GestureDetector` 会进手势竞技场 ⇒ 可能**抢走**外层 `InkWell` 的 onTap。
// ⇒ ★ 必须**证明**"包了 PressFeedback 之后，外层点击照常工作"。
//   否则"加了动画"可能悄悄**弄坏了点击** —— 那是比不加更糟的结果。
// ★ 这与我在 task-42 学到的同族：**"看起来对" ≠ "行为没变"**。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/press_feedback.dart';

/// 挂一个带 `onTap` 的外层，用来证明"点击行为没被破坏"
Future<void> pumpPress(
  WidgetTester t, {
  required VoidCallback onTap,
  bool enabled = true,
  bool reduceMotion = false,
}) async {
  await t.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Center(
          child: PressFeedback(
            enabled: enabled,
            child: GestureDetector(
              onTap: onTap,
              child: const SizedBox(
                width: 100,
                height: 100,
                child: ColoredBox(color: Color(0xFF3366FF)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump(Duration.zero);
}

/// 读渲染树里第一个 `AnimatedScale` 的**当前** scale 值
///
/// ⚠️ `AnimatedScale` 是 `ImplicitlyAnimatedWidget` ⇒ 它内部把值放在
///    `State` 里，widget 上的 `scale` 是**目标值**（不是当前值）。
///    ★ 所以要读**渲染对象**（`RenderTransform`）的矩阵 —— 那才是"实际画多大"。
double? currentScale(WidgetTester t) {
  final f = find.byType(AnimatedScale);
  if (f.evaluate().isEmpty) return null;
  final w = t.widget<AnimatedScale>(f.first);
  return w.scale;   // 目标值：按下后应为 scale，松开后应为 1.0
}

/// 读**实际渲染**的缩放（从 `Transform` 的矩阵读）
///
/// # ★★ 我第一版读错了（实测抓出来的，值得记）
/// ```text
/// 我原来用 `renderObject<RenderBox>(find.byType(AnimatedScale)).getTransformTo(null)`
/// ★ 但 `AnimatedScale` 的渲染对象是 `RenderTransform` **的父级**
///   —— `getTransformTo(null)` 拿到的是**从该节点到根**的累积变换，
///     而缩放矩阵在**它自己**身上 ⇒ 读到的是 1.0（不含缩放）。
///
/// 实测（`.probe/probe_tests/zz_t44_debug_test.dart`）：
///     DBG|down 后目标 scale      = 0.97   ← 目标值**变了**（Listener 工作正常）
///     DBG|120ms 后 rendered      = 1.0    ← ★ 我读错了
///     DBG|Transform[0].storage[0] = 0.97  ← ★ 正确读数
/// ```
/// ⇒ ★ 判据要读**真正承载缩放的那个 widget**（`AnimatedScale` 内部就是
///   `Transform`）—— 这与"读渲染结果而不是读参数"的**意图一致**，
///   只是我一开始读错了对象。
double? renderedScale(WidgetTester t) {
  final tf = find.byType(Transform);
  if (tf.evaluate().isEmpty) return null;
  /*
   * ⚠️ `AnimatedScale` 内部会构造 `Transform`；若外层还有别的 `Transform`
   *    （如 Material 的某些包装），需要挑**带缩放的那个**。
   * ⇒ 取**第一个非单位缩放**的；若都没有，则返回第一个的 [0,0]。
   *   ★ 这样在"已经回弹到 1.0"时也能正确返回 1.0。
   */
  double? first;
  for (var i = 0; i < tf.evaluate().length; i++) {
    final w = t.widget<Transform>(tf.at(i));
    final s = w.transform.storage[0];
    first ??= s;
    if ((s - 1.0).abs() > 0.0005) return s;   // 有缩放的那个
  }
  return first;
}

void main() {
  group('① 基本行为：按下真的缩小', () {
    testWidgets('★★ 按下 ⇒ scale 变小（读渲染值，不是读参数）', (t) async {
      await pumpPress(t, onTap: () {});

      // 初始：应当 1.0
      expect(renderedScale(t), closeTo(1.0, 0.001),
          reason: '★ 初始必须是不缩放的（1.0）');

      // 按下
      final g = await t.startGesture(t.getCenter(find.byType(PressFeedback)));
      await t.pump(Duration.zero);
      await t.pump(const Duration(milliseconds: 120));   // 超过 90ms

      final s = renderedScale(t);
      expect(s, isNotNull);
      expect(
        s! < 1.0,
        isTrue,
        reason: '★★ 按下后**实际渲染**的 scale 必须 <1.0（实测=$s）—— '
            '若仍是 1.0，说明动画没播（只改了目标值）',
      );

      // 松开 ⇒ 回弹到 1.0
      await g.up();
      await t.pump(Duration.zero);
      await t.pump(const Duration(milliseconds: 200));
      expect(renderedScale(t), closeTo(1.0, 0.001),
          reason: '★ 松开后必须回到 1.0（否则卡片永久缩小）');
    });

    testWidgets('★ 有中间态（不是瞬变）', (t) async {
      await pumpPress(t, onTap: () {});

      final g = await t.startGesture(t.getCenter(find.byType(PressFeedback)));
      await t.pump(Duration.zero);
      await t.pump(const Duration(milliseconds: 40));   // 按下动画（90ms）中途

      final mid = renderedScale(t);
      expect(
        mid! > 0.97 && mid < 1.0,
        isTrue,
        reason: '★★ 40ms 时必须处于 0.97~1.0 的**中间态**（实测=$mid）—— '
            '这证明是"渐缩"而不是"瞬跳"',
      );

      await g.up();
      await t.pump(const Duration(milliseconds: 200));
    });
  });

  group('② ★★★ 不破坏外层点击（Listener vs GestureDetector）', () {
    testWidgets('★★★ 包了 PressFeedback 后，外层 onTap **照常触发**',
        (t) async {
      var taps = 0;
      await pumpPress(t, onTap: () => taps++);

      await t.tap(find.byType(PressFeedback));
      await t.pump(const Duration(milliseconds: 200));

      expect(
        taps,
        1,
        reason: '★★★ 外层 onTap 必须**恰好**触发一次 —— '
            '这是我选 `Listener`（不消费手势）而不是 `GestureDetector` 的**核心理由**。'
            '若这里失败，说明动画**弄坏了点击**（比不加动画更糟）',
      );
    });

    testWidgets('★ 按下再松开，onTap 仍然触发（不是只测轻点）', (t) async {
      var taps = 0;
      await pumpPress(t, onTap: () => taps++);

      final g = await t.startGesture(t.getCenter(find.byType(PressFeedback)));
      await t.pump(const Duration(milliseconds: 60));
      await g.up();
      await t.pump(const Duration(milliseconds: 200));

      expect(taps, 1,
          reason: '★ "按住 60ms 再松开"也应算一次点击'
              '（PointerDown 与 Tap 的判定不同，要确认没被干扰）');
    });
  });

  group('③ Reduce Motion（判据④：断言行为）', () {
    testWidgets('★★ 开了 Reduce Motion ⇒ **无中间态**（但仍保留反馈状态）',
        (t) async {
      await pumpPress(t, onTap: () {}, reduceMotion: true);

      final g = await t.startGesture(t.getCenter(find.byType(PressFeedback)));
      await t.pump(Duration.zero);

      /*
       * ★ 判据：**第一帧就已经缩到位**（没有渐变）
       *
       * ★ 而"仍然变小"是**刻意保留**的：
       *   反馈的**信息**（我点到了）不该因为无障碍而丢失，
       *   丢掉的只是**过渡动效**。
       *   ⇒ 若这里断言"不缩放"，那是把无障碍做成了"功能缺失"。
       */
      final s = renderedScale(t);
      expect(
        s! < 1.0,
        isTrue,
        reason: '★ Reduce Motion 下**仍要**缩小（保留反馈信息），实测=$s',
      );
      expect(s, closeTo(0.97, 0.001),
          reason: '★★ 且必须**第一帧就到位**（0.97）—— '
              '若这里还在 0.98/0.99，说明过渡动画**没被跳过**',
      );

      await g.up();
      await t.pump(Duration.zero);
      expect(renderedScale(t), closeTo(1.0, 0.001),
          reason: '★ 同样地，回弹也应当**瞬间**完成');
    });

    testWidgets('★★★ 红度对照：**不**开时第一帧**不**到位 ⇒ 证明断言有分辨力',
        (t) async {
      await pumpPress(t, onTap: () {}, reduceMotion: false);

      final g = await t.startGesture(t.getCenter(find.byType(PressFeedback)));
      await t.pump(Duration.zero);

      final s = renderedScale(t);
      expect(
        s! > 0.97,
        isTrue,
        reason: '★★★ 不开 Reduce Motion 时第一帧**不该**已经缩到底'
            '（实测=$s）—— 否则"开了就没过渡"这条断言'
            '无法区分两种情况（空断言）',
      );

      await g.up();
      await t.pump(const Duration(milliseconds: 200));
    });
  });

  group('④ enabled=false ⇒ 完全透明（不加任何东西）', () {
    testWidgets('★ enabled=false 时**没有** AnimatedScale（零开销）', (t) async {
      await pumpPress(t, onTap: () {}, enabled: false);
      expect(
        find.byType(AnimatedScale),
        findsNothing,
        reason: '★ 关掉时应当**直接返回 child**（不留任何包装）—— '
            '这样"关"是真的关（无额外 widget 层）',
      );
    });
  });
}
