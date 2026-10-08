// ═══════════════════════════════════════════════════════════════════════
//  按下反馈（缩放）—— task-44 A 项
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户要求
// ```text
// 6.动画效果加一下,多个动画效果
// ```
//
// # 为什么选这一处（判据映射）
// ```text
// 现状（2026-09-26 实测）：全仓 `AnimatedScale` 命中 = **0**
//   ⇒ 点卡片时**没有任何"按下去"的物理反馈**
//     （只有 `InkWell` 的水波纹，而水波纹在深色/自定义背景上常被裁掉）
//
// 判据① 有明确目的 → **反馈操作**（判据原话："反馈操作"）
//   ★ 这是交互里最基础的一条：用户点了，界面要**立刻**回应。
//     没有反馈的点击会让人怀疑"我点到了吗"，进而重复点击。
// 判据② 不拖慢操作 → **90ms 按下 / 150ms 回弹**
//   ★ 点击是**最高频**操作 ⇒ 走最低档（≤150ms）
// 判据③ 可被打断   → `AnimatedScale` 是隐式动画，天然可打断
// 判据④ 尊重 Reduce Motion → 走 `MotionPrefs.duration`
// 判据⑤ 用 Flutter 惯用法 → `AnimatedScale`（不手写 AnimationController）
// ```
//
// # ★ 为什么用 `AnimatedScale` 而不是 `AnimatedContainer`
// ```text
// `AnimatedContainer` 要写 `transform: Matrix4.identity()..scale(0.97)`
//   —— 每次 build 新建 Matrix4，且 `transform` 的变化需要
//      `Transform` 的相等性判断才能触发补间，容易"看起来没动画"。
// `AnimatedScale` 是**专用**组件（Flutter 2.5+），只吃一个 double
//   ⇒ 更不容易错、意图更清楚、性能更好（不必构造矩阵）。
// ★ 这正是本项目 tokens.dart 注释里说的"用惯用法"。
// ```
//
// # ⚠️ 为什么用 `Listener` 而不是 `GestureDetector`（★ 我第一版的论证是错的）
// ```text
// 【我原来写的】"`GestureDetector` 会抢走外层 InkWell 的 onTap"
// ⇒ ★★ **这个论证方向反了**。实测
//    （`.probe/probe_tests/zz_t44_gesture_arena_test.dart`）：
//      · 外层 GestureDetector(onTap) 包内层 GestureDetector(onTap)
//        ⇒ 点中心：**外层=0 / 内层=1** ⇒ **内层赢**（Flutter 竞技场规则）
//      · 而 `PressFeedback` 是**祖先**、`widget.child` 是**后代**
//        ⇒ 祖先**永远输给**后代 ⇒ 「我抢走子节点的点击」**结构上不可能**
// ```
// ⇒ ★ 真正的风险是**阻断**（不是"抢走"）：
// ```text
//   · `AbsorbPointer` ／ `IgnorePointer` ／ `HitTestBehavior.opaque`
//     ⇒ 这些会让**子节点根本收不到**指针事件
//   · ★ 而 `Listener` **不改变命中测试结果**（只是"顺带听一下"）
//     ⇒ 所以它确实是最安全的选择 ✓ —— 理由变了，**结论没变**
// ```
// ★ 教训：**"我选它的理由"也必须能被实测检验**。
//   那条错论证没导致错代码，但会误导后人（下一个人可能因为
//   "Listener 是为了防抢"而不敢换写法）。
//   ⇒ 所以这里写下**实测结论**，并保留"选 Listener"的结论。
// ★ 而"外层 onTap 仍触发"这条断言**有分辨力**：
//   红度证明 `m5_absorb`（把 child 包进 `AbsorbPointer`）**能让它变红** ✓
//   ⇒ 断言不是空的（已实测，见 `.probe/t44_redness.py`）。

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'motion_prefs.dart';

/// 给任意孩子加"按下缩小 / 松开回弹"的视觉反馈
///
/// ⚠️ **不消费手势** —— 外层原有的 `onTap` / `InkWell` 照常工作（见文件头）。
class PressFeedback extends StatefulWidget {
  const PressFeedback({
    super.key,
    required this.child,
    this.scale = 0.97,
    this.enabled = true,
  });

  final Widget child;

  /// 按下时缩到的比例（0.97 = 缩小 3%）
  ///
  /// ★ 为什么是 0.97 而不是 0.9：
  ///   海报卡片本身有圆角与阴影，缩太多会显得"卡片在跳"。
  ///   3% 是"能感觉到、但不刺眼"的经验值（Material 规范建议 0.95~0.98）。
  final double scale;

  /// 是否启用（默认开）
  final bool enabled;

  @override
  State<PressFeedback> createState() => _PressFeedbackState();
}

class _PressFeedbackState extends State<PressFeedback> {
  bool _down = false;

  /// 按下：90ms —— **`tokens.dart` 的 `Motion.press`**（权威定义在那边）
  ///
  /// ★ 按下必须是"因果**立刻**可见"的：超过 ~120ms 用户会觉得"点了没反应"
  ///   从而**重复点击**（`.probe/t44_redness.py` 的 m4 证明它真的在起作用）。
  static const Duration _downDur = Motion.press;

  /// 回弹：150ms —— **`Motion.fast`**（与既有"快速"档一致）
  ///
  /// ★ 回弹比按下**稍慢**是有意的：显得"有弹性"，
  ///   而按下更快是为了"立刻响应"。两者都在判据②的 ≤150ms 内。
  static const Duration _upDur = Motion.fast;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    /*
     * ★ 尊重 Reduce Motion（判据④）
     *
     * 开了 ⇒ 两个时长都变 `Duration.zero`
     *   ⇒ 缩放**瞬间**发生（仍然有"按下变小"这个**状态**，
     *     只是没有过渡）—— 这是正确的降级：
     *     ★ 反馈的**信息**（我点到了）保留了，只是**动效**去掉了。
     *   ⚠️ 这与"完全不缩放"不同：完全不缩放会**丢掉反馈信息**，
     *     那是"因无障碍而损失功能"，不是我们想要的。
     */
    final down = MotionPrefs.duration(context, _downDur);
    final up = MotionPrefs.duration(context, _upDur);

    return Listener(
      // ★ Listener 不消费事件（见文件头）——
      //   所以外层的 InkWell / GestureDetector 照常收到点击
      onPointerDown: (_) {
        if (!_down) setState(() => _down = true);
      },
      onPointerUp: (_) {
        if (_down) setState(() => _down = false);
      },
      // ★ 指针被取消（滑出/被抢）也要回弹，否则会**卡在按下态**
      onPointerCancel: (_) {
        if (_down) setState(() => _down = false);
      },
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: _down ? down : up,
        // 按下用 easeOut（快进快出），回弹用 easeOut 收尾更自然
        curve: MotionPrefs.curve(context, Curves.easeOut),
        child: widget.child,
      ),
    );
  }
}
