// ═══════════════════════════════════════════════════════════════════════
//  骨架 ⇄ 内容 的淡入过渡 —— task-44 B 项
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户要求
// ```text
// 6.动画效果加一下,多个动画效果
// ```
//
// # 为什么选这一处（判据映射）
// ```text
// 现状（实测 lib/ui/home_page.dart L653 / L667）：
//     if (_loading)   SliverToBoxAdapter(child: _SkeletonSections())
//     if (!_loading)  SliverList(...)
//   ⇒ ★ 两者是**硬 if 切换**：骨架**瞬间消失**、内容**瞬间出现**
//     ⇒ 视觉上"闪一下"，用户分不清"内容加载好了"还是"画面抖了"
//
// 判据① 有明确目的 → **引导注意 + 表达层级**（告诉用户"内容就绪了"）
// 判据② 不拖慢操作 → **200ms**（≤300ms；且加载本来就是等待态，不占额外时间）
// 判据③ 可被打断   → 隐式补间**不劫持手势**，用户滚动/点击立刻响应
// 判据④ 尊重 Reduce Motion → 走 `MotionPrefs.duration`
// 判据⑤ 用 Flutter 惯用法 → `TweenAnimationBuilder` + **`SliverFadeTransition`**
// ```
//
// # ★★★ 关键设计：必须用 `SliverFadeTransition`，不能用 `Opacity`
// ```text
// `CustomScrollView.slivers:` 只接受 **sliver**。
// ⇒ 若用盒模型的 `Opacity` / `AnimatedOpacity` 包住内容：
//     · 要么编译不过（放进 slivers:）
//     · 要么得先套 `SliverToBoxAdapter` ⇒ ★ 那会把 `SliverList` **整体**
//       变成一个盒模型孩子 ⇒ **丢掉 sliver 的懒加载与 sticky**（性能回归）
//
// ⇒ ★ 正解：`SliverFadeTransition`（Flutter 自带，`transitions.dart:682`）
//   它是 `SingleChildRenderObjectWidget`、child 是 **sliver**
//   ⇒ 淡入的同时**完全保留** `SliverList` 的懒加载 ✓
// ```
//
// # 为什么要 `TweenAnimationBuilder` 而不是 `AnimatedOpacity`
// ```text
// `SliverAnimatedOpacity` / `AnimatedOpacity` 都需要"目标值**变化**"来触发补间；
// 而这里是**首次挂载**（从无到有）⇒ 初值 == 目标值 ⇒ **不会播**。
// ⇒ 用 `TweenAnimationBuilder<double>(tween: Tween(0, 1))`：
//   它在**首帧**就开始补间 ⇒ 天然就是"出现"动画。
// ★ 这正是 `shell.dart` 的 `_KeepAliveTransition` 选择的同一方案
//   （那里注释也解释了同一问题），保持一致。
// ```
//
// # 为什么把"淡入"做成**包装 sliver**而不是"切换两个 sliver"
// ```text
// 两条分支（骨架 / 内容）都在 `slivers:` 列表里，是**兄弟**关系。
// ★ 让**每一侧各自**做出现动画 ⇒
//     · 骨架侧：淡出（当它被移除时由框架处理，或干脆瞬移）
//     · 内容侧：淡入（本类负责）
//   ⇒ 视觉上就是"交叉溶解"，而且**两侧的 sliver 类型都不变** ✓
// ```

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'motion_prefs.dart';

/// 一个 **sliver** 包装：让孩子在首帧淡入（0 → 1）
///
/// ⚠️ 只接受 **sliver** 作为 child（`SliverList` / `SliverToBoxAdapter` / …）。
///    它**不**创建盒模型层 ⇒ 不会破坏懒加载。
class FadeInSliver extends StatelessWidget {
  const FadeInSliver({
    super.key,
    required this.sliver,
    this.duration,
    this.enabled = true,
  });

  /// 被包装的 sliver（如 `SliverList`、`SliverToBoxAdapter`）
  final Widget sliver;

  /// 覆盖默认时长（默认 200ms）
  final Duration? duration;

  /// 是否启用动画（`false` ⇒ 直接以终值出现，用于"不该播"的场景）
  ///
  /// ★ 与"Reduce Motion"是**两个不同维度**：
  ///   前者是**我们的**决定（某处不想播），后者是**用户**的偏好。
  final bool enabled;

  /// 200ms —— 现在的**权威定义在 `tokens.dart` 的 `Motion.fade`**
  ///
  /// 判据②：≤300ms ✓
  /// ★ 为什么不用 `Motion.base`(260)：骨架→内容是**每次进首页都要经历**的，
  ///   260ms 会让"看到内容"显得比实际慢。
  ///   200ms 是"能看清是个过渡，又不觉得在等"的经验值。
  ///
  /// # ★ task-44 C 项：为什么改成引用 `Motion.fade`
  /// ```text
  /// 我第一版把它写在**本文件**里（`Duration(milliseconds: 200)`）
  /// ⇒ ★ 那是"继续增加散落" —— 本项目已有 33 处裸 Duration，
  ///   同一个 260ms 有 `Motion.base` 和字面量两种写法。
  /// ⇒ 现在指向 `tokens.dart` 的 `Motion.fade`（**理由也写在那边**，
  ///   与其它动效时长放在一起）✓
  /// ```
  /// ⚠️ 保留本常量（而不是各处直接用 `Motion.fade`）是为了
  ///    让本组件**可独立指定时长**（构造参数 `duration` 已有此用途）。
  static const Duration defaultDuration = Motion.fade;

  @override
  Widget build(BuildContext context) {
    /*
     * ★ 尊重 Reduce Motion（判据④）
     *
     * 减少动效时 `dur == Duration.zero` ⇒ `TweenAnimationBuilder` 在
     * **第一帧**就落到终值（opacity=1）——
     * 语义正是"不要动画，直接到位"。
     * ★ 而**子树结构不变**（仍是同一个 sliver 包在 SliverFadeTransition 里），
     *   所以不会因为分支不同而丢状态。
     */
    final dur = enabled
        ? MotionPrefs.duration(context, duration ?? defaultDuration)
        : Duration.zero;

    return TweenAnimationBuilder<double>(
      // 0 → 1：首帧即开始补间（初值 ≠ 终值）
      tween: Tween<double>(begin: 0, end: 1),
      duration: dur,
      curve: MotionPrefs.curve(context, Curves.easeOut),
      builder: (context, t, child) {
        return SliverFadeTransition(
          opacity: AlwaysStoppedAnimation<double>(t.clamp(0.0, 1.0)),
          sliver: child,
        );
      },
      // ★ 把 sliver 作为 `child` 传进去 ⇒ builder 不会每帧重建它
      //   （这是 `TweenAnimationBuilder` 的 child 优化，判据③性能）
      child: sliver,
    );
  }
}
