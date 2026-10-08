// ═══════════════════════════════════════════════════════════════════════
//  task-44：**时长实测证据**（Lead 判据②：≤300ms 的量化证明）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要单独一条
// ```text
// Lead 要求：「★ **时长实测**（≤ 300ms 的证据）」
// ★ 而我前面的测试只断言了"常量 ≤300ms"与"300ms 后已完成" ——
//   那是**间接**证据（读常量 + 读终态）。
// ⇒ 本文件做**直接**测量：**动画实际跑了多久**（从开始到落定）。
// ```
//
// # 怎么"直接测量"时长
// ```text
// widget 测试里时间由 `tester.pump(Duration)` 驱动 ⇒ 可以**逐帧推进**，
// 记录"opacity 首次达到终值"所经过的累计时长 —— 那就是**实际时长**。
// ★ 这比读常量强：若有人把 duration 传错、或曲线让它"提前到位"，
//   这里读到的**真实帧数**会不一样。
// ```
//
// # ★ 与判据②的关系
// ```text
// 判据②：不拖慢操作（总时长 ≤ 250-300ms；高频操作 ≤ 150ms）
// ⇒ 本文件对**每一处新增动画**给出实测毫秒数 + 是否满足分档
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/fade_in_sliver.dart';
import 'package:sourin_spike/ui/widgets/press_feedback.dart';

/// 逐帧推进，测出"opacity 从开始到达终值"的**实际**时长（毫秒）
///
/// 返回 `(实测毫秒, 经过的帧数)`；若在 [budget] 内未落定 ⇒ 返回 `(-1, frames)`
Future<(int, int)> measureFadeIn(
  WidgetTester t, {
  int budget = 1000,
  bool reduceMotion = false,
}) async {
  await t.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: CustomScrollView(
          slivers: [
            FadeInSliver(
              sliver: const SliverToBoxAdapter(
                child: SizedBox(height: 50, child: Text('X')),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  double? read() {
    final f = find.byType(SliverFadeTransition);
    if (f.evaluate().isEmpty) return null;
    return t.widget<SliverFadeTransition>(f.first).opacity.value;
  }

  var elapsed = 0;
  var frames = 0;
  // 每次推进 10ms（足够细，能分辨 90/150/200/260）
  while (elapsed < budget) {
    final v = read();
    if (v != null && v >= 0.999) return (elapsed, frames);
    await t.pump(const Duration(milliseconds: 10));
    elapsed += 10;
    frames++;
  }
  return (-1, frames);
}

/// 逐帧推进，测出"按下缩放从 1.0 落到 widget.scale"的实际时长
Future<(int, int)> measurePressDown(WidgetTester t, {int budget = 1000}) async {
  await t.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: false),
        child: Center(
          child: PressFeedback(
            child: GestureDetector(
              onTap: () {},
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

  double? read() {
    final tf = find.byType(Transform);
    if (tf.evaluate().isEmpty) return null;
    for (var i = 0; i < tf.evaluate().length; i++) {
      final s = t.widget<Transform>(tf.at(i)).transform.storage[0];
      if ((s - 1.0).abs() > 0.0005) return s;
    }
    return 1.0;
  }

  final g = await t.startGesture(t.getCenter(find.byType(PressFeedback)));
  await t.pump(Duration.zero);

  var elapsed = 0;
  var frames = 0;
  while (elapsed < budget) {
    final s = read();
    // 目标 0.97：落到 0.9705 以内算到位
    if (s != null && s <= 0.9705) {
      await g.up();
      await t.pump(const Duration(milliseconds: 300));
      return (elapsed, frames);
    }
    await t.pump(const Duration(milliseconds: 10));
    elapsed += 10;
    frames++;
  }
  await g.up();
  await t.pump(const Duration(milliseconds: 300));
  return (-1, frames);
}

void main() {
  group('★★ 时长实测（Lead 判据②：量化证据）', () {
    testWidgets('★ B 项：骨架→内容淡入的**实际**时长', (t) async {
      final (ms, frames) = await measureFadeIn(t);

      debugPrint('T44DUR|fade_in 实测 = ${ms}ms（$frames 帧）'
          ' ／ 常量 = ${FadeInSliver.defaultDuration.inMilliseconds}ms'
          ' ／ Motion.fade = ${Motion.fade.inMilliseconds}ms');

      expect(ms, greaterThan(0), reason: '★ 必须能在预算内测到落定');
      expect(
        ms,
        lessThanOrEqualTo(300),
        reason: '★★ 判据②：淡入必须 ≤300ms（实测 ${ms}ms）',
      );
      // ★ 实测应当**接近**常量（允许 1 帧粒度 = 10ms 的误差）
      expect(
        (ms - FadeInSliver.defaultDuration.inMilliseconds).abs() <= 20,
        isTrue,
        reason: '★ 实测(${ms}ms)应与常量'
            '(${FadeInSliver.defaultDuration.inMilliseconds}ms)接近 —— '
            '差太多说明实际用的不是那个常量',
      );
    });

    testWidgets('★ A 项：按下缩放的**实际**时长（高频 ⇒ ≤150ms）', (t) async {
      final (ms, frames) = await measurePressDown(t);

      debugPrint('T44DUR|press_down 实测 = ${ms}ms（$frames 帧）'
          ' ／ Motion.press = ${Motion.press.inMilliseconds}ms');

      expect(ms, greaterThan(0), reason: '★ 必须能测到落定');
      expect(
        ms,
        lessThanOrEqualTo(150),
        reason: '★★ 判据②：**高频操作**（点击）必须 ≤150ms（实测 ${ms}ms）',
      );
      expect(
        (ms - Motion.press.inMilliseconds).abs() <= 20,
        isTrue,
        reason: '★ 实测(${ms}ms)应接近 `Motion.press`'
            '(${Motion.press.inMilliseconds}ms)',
      );
    });

    testWidgets('★★ Reduce Motion 开 ⇒ 淡入**第 0 帧**落定（0ms）', (t) async {
      final (ms, frames) = await measureFadeIn(t, reduceMotion: true);
      debugPrint('T44DUR|fade_in + reduce = ${ms}ms（$frames 帧）');
      expect(ms, 0,
          reason: '★★ 判据④：开了 Reduce Motion ⇒ **0ms**（第 0 帧就到位）—— '
              '实测 ${ms}ms / $frames 帧');
    });

    testWidgets('★★ 常量分档自检（把判据②写进断言，防后人改坏）', (t) async {
      // ★ 这两条是"判据②"的**可执行形式** —— 若后人把值改大，这里立刻红
      expect(Motion.press.inMilliseconds, lessThanOrEqualTo(150),
          reason: '★ 按下反馈属**高频操作** ⇒ 必须 ≤150ms');
      expect(Motion.fade.inMilliseconds, lessThanOrEqualTo(300),
          reason: '★ 淡入属**过渡** ⇒ 必须 ≤300ms');
      // 且不应小到看不见（<60ms 视觉上等于瞬变）
      expect(Motion.press.inMilliseconds, greaterThanOrEqualTo(60),
          reason: '★ 按下反馈若 <60ms，视觉上等于**没有动画**（白做）');
      expect(Motion.fade.inMilliseconds, greaterThanOrEqualTo(120),
          reason: '★ 淡入若 <120ms，看起来就是"闪一下"（判据①达不到）');
    });
  });
}
