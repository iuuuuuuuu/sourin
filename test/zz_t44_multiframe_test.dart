// ═══════════════════════════════════════════════════════════════════════
//  task-44：**多帧证据**（证明"它真的在动"，而不只是"终态对"）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要（我自己指出的证据缺口）
// ```text
// 我交给 Lead 的真机截图是**静态**两张 ⇒ ★ 它**证明不了"在动"**：
//   一张"内容已显示"的图，与"内容瞬现"的图**看起来一样**。
// ⇒ ★ 判据必须落在**时间轴**上：证明"中间存在若干**不同的**状态"。
// ```
//
// # 本文件做什么
// ```text
// 逐帧记录 opacity / scale 的**完整序列**，并断言：
//   ① 序列长度 ≥ 3（不止起止两态 ⇒ 真的在渐变）
//   ② 序列**单调**（0 → 1 一路升，不来回跳）
//   ③ ★ **存在严格中间值**（既不是 0 也不是 1）
//   ④ 相邻帧差值 ≤ 合理上限（不是"某帧突然跳完"）
// ★ 这就是"多帧连拍"在 widget 测试里的等价物 —— 而且**比截图更精确**
//   （截图受编码/缩放影响，读的是**数值**）。
// ```
//
// # ★ 与"时长实测"的分工
// ```text
// zz_t44_duration_test.dart  → 测"**多久**落定"（判据②）
// 本文件                      → 测"**过程长什么样**"（判据①：真的在过渡）
// 两者互补：一个管时间，一个管形状。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/fade_in_sliver.dart';
import 'package:sourin_spike/ui/widgets/press_feedback.dart';

/// 逐帧采样 opacity，返回**完整序列**
Future<List<double>> traceFadeIn(
  WidgetTester t, {
  int frames = 24,
  int stepMs = 10,
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

  final seq = <double>[];
  final first = read();
  if (first != null) seq.add(first);
  for (var i = 0; i < frames; i++) {
    await t.pump(Duration(milliseconds: stepMs));
    final v = read();
    if (v != null) seq.add(v);
  }
  return seq;
}

/// 逐帧采样按下时的 scale
Future<List<double>> tracePressDown(WidgetTester t,
    {int frames = 16, int stepMs = 10}) async {
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
    double? plain;
    for (var i = 0; i < tf.evaluate().length; i++) {
      final s = t.widget<Transform>(tf.at(i)).transform.storage[0];
      plain ??= s;
      if ((s - 1.0).abs() > 0.0005) return s;
    }
    return plain;
  }

  final g = await t.startGesture(t.getCenter(find.byType(PressFeedback)));
  await t.pump(Duration.zero);

  final seq = <double>[];
  final first = read();
  if (first != null) seq.add(first);
  for (var i = 0; i < frames; i++) {
    await t.pump(Duration(milliseconds: stepMs));
    final v = read();
    if (v != null) seq.add(v);
  }
  await g.up();
  await t.pump(const Duration(milliseconds: 300));
  return seq;
}

/// 打印序列（便于把"形状"写进报告）
void dump(String tag, List<double> seq) {
  final s = seq.map((v) => v.toStringAsFixed(3)).join(' → ');
  debugPrint('T44FRAME|$tag|${seq.length} 帧|$s');
}

void main() {
  group('★★★ 多帧证据：证明"真的在动"（不只是终态对）', () {
    testWidgets('★★★ 淡入：序列单调上升，且存在严格中间值', (t) async {
      final seq = await traceFadeIn(t);
      dump('fade_in', seq);

      expect(seq.length, greaterThanOrEqualTo(3),
          reason: '★ 至少要采到 3 个状态（起 / 中 / 止）—— '
              '只有 2 个说明可能是瞬变');

      // ① 起止正确
      expect(seq.first, closeTo(0.0, 0.001), reason: '★ 首帧必须是 0');
      expect(seq.last, closeTo(1.0, 0.001), reason: '★ 末帧必须到 1');

      // ② ★ 存在**严格中间值**（这是"在动"的硬证据）
      final mids = seq.where((v) => v > 0.01 && v < 0.99).toList();
      expect(
        mids.length,
        greaterThanOrEqualTo(3),
        reason: '★★★ 必须存在 ≥3 个**严格中间态**（实测 ${mids.length} 个）—— '
            '这是"内容真的在渐显"的直接证据。'
            '若为 0，说明是"瞬现"（静态截图看不出区别，但这里能）',
      );

      // ③ ★ 单调不降（渐变不该来回跳）
      for (var i = 1; i < seq.length; i++) {
        expect(
          seq[i] >= seq[i - 1] - 0.001,
          isTrue,
          reason: '★★ 第 $i 帧(${seq[i]}) 比前一帧(${seq[i - 1]}) 小了 —— '
              '淡入必须**单调上升**（来回跳说明补间被反复重置）',
        );
      }

      // ④ ★ 不存在"单帧跳完"（相邻帧差 ≤ 0.35）
      for (var i = 1; i < seq.length; i++) {
        final d = seq[i] - seq[i - 1];
        expect(
          d <= 0.35,
          isTrue,
          reason: '★★ 第 $i 帧跳了 ${d.toStringAsFixed(3)} —— '
              '单帧跳 >0.35 说明那一段是"瞬变"而非渐变',
        );
      }
    });

    testWidgets('★★★ 按下：序列单调下降，且存在严格中间值', (t) async {
      final seq = await tracePressDown(t);
      dump('press_down', seq);

      expect(seq.length, greaterThanOrEqualTo(3));
      expect(seq.first, closeTo(1.0, 0.001), reason: '★ 初始必须不缩放');
      expect(seq.last, closeTo(0.97, 0.002), reason: '★ 末帧必须缩到位');

      final mids = seq.where((v) => v < 0.9995 && v > 0.9705).toList();
      expect(
        mids.length,
        greaterThanOrEqualTo(2),
        reason: '★★★ 必须存在 ≥2 个**严格中间态**（实测 ${mids.length} 个）—— '
            '证明是"渐缩"而不是"瞬跳"',
      );

      for (var i = 1; i < seq.length; i++) {
        expect(
          seq[i] <= seq[i - 1] + 0.001,
          isTrue,
          reason: '★★ 按下必须**单调缩小**（第 $i 帧回弹了说明状态被重置）',
        );
      }
    });

    testWidgets('★★★ 对照：Reduce Motion 开 ⇒ 序列**只有终值**（无中间态）',
        (t) async {
      final seq = await traceFadeIn(t, reduceMotion: true);
      dump('fade_in + reduce', seq);

      final mids = seq.where((v) => v > 0.01 && v < 0.99).toList();
      expect(
        mids.length,
        0,
        reason: '★★★ 开了 Reduce Motion ⇒ **不允许任何中间态**（实测 ${mids.length} 个）—— '
            '这条与"淡入有 ≥3 个中间态"形成**可观测对照**，'
            '两者合起来才证明"无障碍开关真的改变了行为"',
      );
      expect(seq.every((v) => v >= 0.999), isTrue,
          reason: '★ 且每一帧都必须是终值 1.0');
    });
  });
}
