// ═══════════════════════════════════════════════════════════════════════
//  页面/内容切换动画风格（用户可选、可切换）—— task-55
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（逐字）
// ```text
// 6.动画效果加一下,多个动画效果
// ```
// 以及（任务下发时补的）：
// ```text
// 然后还有个动画效果,我说让你多做几个我来切换的,这个你也没做
// ```
//
// ★★★ 关键在「**多个**」+「**我来切换的**」：
// ```text
// 【我上一轮做错的】"在某处加了一个淡入"
//   ⇒ ★ 只有一个效果，而且用户**不能选** ⇒ 用户说"你也没做" ✓（他说得对）
// 【现在要做的】"做几种不同的效果，让用户在设置里自己挑"
// ```
//
// # 本文件提供什么
// ```text
// ① `PageTransitionStyle` —— 6 种风格（含"无动画"）
// ② 持久化（走 `UiPrefs`，与既有 18 个偏好同一机制）
// ③ `PageTransition.apply(...)` —— 把风格应用到一棵子树上
// ④ `PageTransitionStyleStore` —— 一个 `ValueNotifier`，
//    让"用户改了设置"能**立刻**通知到正在显示的页面（见文件末尾说明）
// ```
//
// # 为什么用 `UiPrefs` 而不是新机制
// ```text
// `lib/core/ui_prefs.dart` 已是本项目的"纯前端偏好"机制（键值对 + 自动落盘）：
//   UiPrefs.get(key) / set(key, value) / remove(key)
// ★ 而 `lib/core/player_gestures.dart` 已用同一套存 18 个偏好
//   ⇒ 照抄那个模式（`_s(key, fallback)` 读字符串）
// ⇒ ★ **零新机制**，而且与"片头片尾""PC 手势"这些偏好的**行为一致**
//   （同样的加载时机、同样的落盘时机）
// ```

import 'package:material_ui/material_ui.dart';

import '../../core/ui_prefs.dart';

/// 页面/内容切换的动画风格
///
/// ★ 顺序 = 设置页里药丸的显示顺序。
///   `slideRight` 放在**第一个**是因为它是**默认值**（= 既有观感），
///   用户打开设置时第一眼看到的就是"当前生效的那个"。
enum PageTransitionStyle {
  /// 右滑 + 淡入（★ **默认** —— 就是本项目**既有**的观感）
  ///
  /// ★ 为什么默认是它：用户要求"**不要改变当前观感**"。
  ///   改之前 `shell.dart` 的 tab 切换就是
  ///   `FadeTransition` + `SlideTransition(0.02*dir → 0)` ——
  ///   正是这一种。选它作默认 ⇒ **升级后用户看不出变化** ✓
  slideRight,

  /// 纯淡入淡出（无位移）
  fade,

  /// 从下往上滑入 + 淡入
  slideUp,

  /// 缩放（从小到大）+ 淡入
  zoom,

  /// 上浮 + 淡入（幅度比 `slideUp` 小，像"卡片轻轻浮起"）
  fadeUp,

  /// ★ **无动画**（直接切换）
  ///
  /// ★ 必须存在：用户要"切换"，就得能**关掉**。
  ///   而且它与系统级"减少动态效果"是**两个不同维度**：
  ///   · 这是**用户主动选择**的风格
  ///   · 那是**系统偏好**（无障碍）——见 `MotionPrefs`
  none,
}

/// 风格的中文名（设置页显示用）
extension PageTransitionStyleLabel on PageTransitionStyle {
  String get label => switch (this) {
        PageTransitionStyle.slideRight => '右滑',
        PageTransitionStyle.fade => '淡入',
        PageTransitionStyle.slideUp => '上滑',
        PageTransitionStyle.zoom => '缩放',
        PageTransitionStyle.fadeUp => '上浮',
        PageTransitionStyle.none => '无动画',
      };

  /// 一句话说明（设置页副标题，帮用户理解选了什么）
  String get hint => switch (this) {
        PageTransitionStyle.slideRight => '从右侧轻轻滑入（默认）',
        PageTransitionStyle.fade => '原地淡入，没有位移',
        PageTransitionStyle.slideUp => '从下方滑入',
        PageTransitionStyle.zoom => '由小变大',
        PageTransitionStyle.fadeUp => '轻轻上浮并淡入',
        PageTransitionStyle.none => '直接切换，不做动画',
      };
}

/// 风格的**持久化 + 当前值通知**
///
/// # 为什么需要 `ValueNotifier`（而不是只读 `UiPrefs`）
/// ```text
/// 用户要求「点了**立刻生效**」。
/// ★ 而 tab 切换动画发生在 `shell.dart` 里 —— 它不会因为
///   `UiPrefs` 变了就重建（`UiPrefs` 不是可监听的）。
/// ⇒ 用一个 `ValueNotifier` 作为"当前风格"的**唯一真相**：
///     设置页改了 ⇒ notifier 变 ⇒ 监听它的 shell 重建 ⇒ 立刻生效
/// ```
/// ⚠️ 它**不是**第二套真相：`UiPrefs` 是**持久化**，
///    本 notifier 是**运行期缓存** —— 启动时从 `UiPrefs` 初始化一次。
abstract final class PageTransitionStyleStore {
  /// `UiPrefs` 的键（沿用既有命名风格：`dsh.` 前缀）
  static const String prefKey = 'dsh.pageTransition';

  /// 运行期的当前值（唯一真相 —— 见类文档）
  static final ValueNotifier<PageTransitionStyle> current =
      ValueNotifier<PageTransitionStyle>(_readPref());

  /// 从 `UiPrefs` 读（**只在启动/初始化时调**）
  ///
  /// ⚠️ 必须在 `UiPrefs.load()` **之后**调用，否则会拿到 fallback。
  ///    ⇒ 见 `syncFromPrefs()`（`UiPrefs.load` 完成后由外部调一次）。
  static PageTransitionStyle _readPref() {
    final v = UiPrefs.get(prefKey);
    if (v == null) return defaultStyle;
    // ★ 用 `name` 存（可读、可手改；不用 index —— 那会在枚举顺序变化时错位）
    for (final s in PageTransitionStyle.values) {
      if (s.name == v) return s;
    }
    // ★ 未知值（用户手改了 json / 降级）⇒ 回默认，**不崩**
    return defaultStyle;
  }

  /// ★ 默认值 = `slideRight`（= 本项目**既有**观感）
  static const PageTransitionStyle defaultStyle = PageTransitionStyle.slideRight;

  /// 用户在设置页选了新的风格 ⇒ **立刻生效** + 持久化
  static void set(PageTransitionStyle s) {
    if (current.value == s) return;   // 幂等：没变就不通知
    current.value = s;
    UiPrefs.set(prefKey, s.name);
  }

  /// `UiPrefs.load()` 完成后调一次，把磁盘值同步进 notifier
  ///
  /// # 为什么需要（否则"重启后设置失效"）
  /// ```text
  /// `current` 是 `static final` ⇒ 在**类首次被访问**时初始化。
  /// ★ 若它恰好在 `UiPrefs.load()` **之前**被访问（很可能：
  ///   shell 构建时就会读它）⇒ 读到的是空 ⇒ 用默认值
  ///   ⇒ ★ 用户重启后设置"丢失"（其实只是读早了）
  /// ⇒ 所以 `UiPrefs.load()` 之后**必须**再同步一次。
  /// ```
  static void syncFromPrefs() {
    current.value = _readPref();
  }

  /// 供测试重置（★ 只测试用；生产不调）
  @visibleForTesting
  static void resetForTest(PageTransitionStyle s) {
    current.value = s;
  }
}

/// 把风格应用到子树上
abstract final class PageTransition {
  /// 构造一个"按风格入场"的过渡
  ///
  /// - [animation]：0 → 1 的驱动（`CurvedAnimation` 也可）
  /// - [child]：被过渡的内容（★ 必须是**稳定实例**，否则它的 State 会重建）
  /// - [dir]：进入方向（+1 = 从右进，-1 = 从左进）；只有 `slideRight` 用它
  /// - [style]：风格；`null` ⇒ 用当前用户选择
  ///
  /// ★ **`none` 直接返回 child**（零 widget 层、零开销）——
  ///   而不是"用一个 duration=0 的动画"：后者仍会包两层 widget。
  static Widget apply({
    required Animation<double> animation,
    required Widget child,
    required PageTransitionStyle style,
    double dir = 1,
  }) {
    switch (style) {
      case PageTransitionStyle.none:
        // ★ 无动画：**不加任何 widget**（真·零开销）
        return child;

      case PageTransitionStyle.fade:
        return FadeTransition(opacity: animation, child: child);

      case PageTransitionStyle.slideRight:
        /*
         * ★ 与既有观感**逐字一致**（默认值必须是"看不出变化"）
         *
         * 改之前 `shell.dart`：
         *     SlideTransition(position: Tween(begin: Offset(0.02 * dir, 0),
         *                                   end: Offset.zero).animate(curved))
         * ⇒ 这里保持 **0.02** 与同一个 `dir` 语义。
         */
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(0.02 * dir, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );

      case PageTransitionStyle.slideUp:
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              // 从下方 0.06 处滑入（比右滑幅度大一点，否则"上滑"看不出来）
              begin: const Offset(0, 0.06),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );

      case PageTransitionStyle.zoom:
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            // 0.92 → 1.0（从"略小"放大；再小会像"弹窗"而不是"切换"）
            scale: Tween<double>(begin: 0.92, end: 1.0).animate(animation),
            child: child,
          ),
        );

      case PageTransitionStyle.fadeUp:
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              // 幅度只有 slideUp 的 1/3（"轻轻浮起"）
              begin: const Offset(0, 0.02),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
    }
  }

  /// 所有可选项（设置页用；顺序 = 枚举顺序）
  static const List<PageTransitionStyle> options = PageTransitionStyle.values;
}
