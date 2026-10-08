// ═══════════════════════════════════════════════════════════════════════
//  动效偏好（无障碍）—— task-44 D 项
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要（用户要求"多个动画效果"，但动画有条硬边界）
//
// 用户原话：
// ```text
// 6.动画效果加一下,多个动画效果
// ```
//
// ★ 用户要的是"**更多动画**"，而本文件做的是"**某些情况下不播动画**" ——
//   看似相反，其实是同一条要求的**另一半**：
// ```text
// 动画是"锦上添花"，而"减少动态效果"是**无障碍必需**（前庭功能障碍者
// 会因动效产生眩晕/恶心）。系统开关打开时**必须**尊重。
// ⇒ ★ 加动画的同时尊重它，才是"专业地加动画"。
// ```
//
// # 现状（2026-09-26 实测）
// ```text
// 全仓 `disableAnimations` / `accessibleNavigation` 命中 = **0**
// ⇒ ★ 系统开了"减少动态效果"，我们**照样播所有动画**（真实缺陷）
// ```
//
// # 为什么不用 `MediaQuery.of(context)` 直接读
// ```text
// `MediaQuery.of` 在**没有 MediaQuery 祖先**时会**抛异常** ——
// widget 测试里很容易踩（我自己在别处踩过 "No MediaQuery widget"）。
// ⇒ 用 `maybeOf`（拿不到就按"不减少"处理 = 保持既有行为，不引入回归）。
// ```
//
// # ⚠️ 本文件只服务**新增**的动画
// ```text
// 既有 18 处 `Motion.*` 用法**不改**（跨多个别人的文件，会造成冲突）。
// ⇒ 我在报告里把"让既有动画也走 reduce"列为**建议**，不擅自做。
// ```

import 'package:material_ui/material_ui.dart';

import 'page_transition.dart';

/// 动效偏好的读取与降级（纯函数，无状态 —— 便于测试）
abstract final class MotionPrefs {
  /// 用户是否要求**减少动态效果**
  ///
  /// 读 `MediaQueryData.disableAnimations`（Windows 上对应
  /// 「设置 → 辅助功能 → 视觉效果 → 动画效果」关闭；
  /// Android 上对应「开发者选项 → 动画程序时长缩放」类开关）。
  ///
  /// ★ 拿不到 `MediaQuery` ⇒ 返回 `false`（= 不减少，保持既有行为）。
  ///   理由：**"读不到偏好"不等于"用户要求减少"** ——
  ///   若默认返回 `true`，在没有 MediaQuery 的环境（如某些 widget 测试）
  ///   动画会**静默全不播**，那是更难查的假象。
  static bool reduce(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// 按偏好降级一个时长：要求减少 ⇒ `Duration.zero`（动画**瞬间完成**）
  ///
  /// ⚠️ 用 `Duration.zero` 而不是"跳过动画" ——
  ///   隐式动画（`AnimatedX`）在 `Duration.zero` 时会**直接落到终值**，
  ///   语义上正是"不要动画，直接到位"。
  ///   ★ 而"跳过动画"若靠条件分支不渲染动画组件，会让
  ///     **组件子树在两种情况不同** ⇒ 可能引起状态丢失（更糟）。
  static Duration duration(BuildContext context, Duration d) =>
      reduce(context) ? Duration.zero : d;

  /// 同上，但用于"必须给 Curve"的场景
  ///
  /// 减少动效时用 `Curves.linear` —— 配合 `Duration.zero` 时曲线无意义，
  /// 但显式给出可避免调用方分支。
  static Curve curve(BuildContext context, Curve c) =>
      reduce(context) ? Curves.linear : c;

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★ task-55 追加（2026-09-26）—— 把"用户选的风格"与"系统偏好"合起来裁决
   * ══════════════════════════════════════════════════════════════════
   *
   * # 为什么需要这一层（两个维度必须分开，但不能各管各的）
   * ```text
   * ① 用户**主动选的**风格   → `PageTransitionStyleStore.current`
   *    （设置页里 6 个药丸，用户自己挑）
   * ② 系统**无障碍偏好**     → `MediaQueryData.disableAnimations`
   *    （Windows「减少动态效果」/ Android 动画缩放）
   *
   * ★ 若各管各的：用户在设置里选了"缩放"，而系统开着"减少动态效果"
   *   ⇒ 两个地方各自实现 ⇒ **很容易漏一处**（本项目已踩过"两处同构必须一起改"）
   * ⇒ 统一在**一个函数**里裁决：**系统偏好优先**（无障碍 > 装饰）
   * ```
   *
   * # ★ 为什么"系统优先"而不是"用户设置优先"
   * ```text
   * · 系统开关是**无障碍需求**（前庭功能障碍者会因动效眩晕）
   *   ⇒ 它表达的是"**不要给我动画**"，那是**硬约束**
   * · 用户在我们的设置里选的风格是**偏好**（想要哪种动画）
   *   ⇒ 当两者冲突时，**硬约束赢**
   * ★ 而这不损失功能：用户仍能在我们的设置里选"无动画"
   *   （那时两者一致，无冲突）
   * ```
   */

  /// 把"用户选的风格"按系统偏好裁决（★ 系统偏好优先）
  ///
  /// 系统要求减少动效 ⇒ 返回 [PageTransitionStyle.none]（**不加任何动画层**）。
  ///
  /// ⚠️ 返回 `none` 而不是"duration=0 的同一种风格"：
  ///   `PageTransition.apply` 对 `none` 是**直接返回 child**
  ///   ⇒ 零 widget 层、零 ticker ⇒ 真正"不动"（不是"动得很快"）。
  static PageTransitionStyle resolve(
    BuildContext context,
    PageTransitionStyle style,
  ) =>
      reduce(context) ? PageTransitionStyle.none : style;

  /// 同上，但直接读"用户当前选择"（省掉调用方取 notifier 的一步）
  ///
  /// ★ 只用于**不需要"立刻生效"**的场景（如页面首次构建）。
  ///   需要立刻生效的地方（shell 的 tab 切换）应自己监听
  ///   `PageTransitionStyleStore.current` —— 见那里的说明。
  static PageTransitionStyle resolvedCurrent(BuildContext context) =>
      resolve(context, PageTransitionStyleStore.current.value);
}
