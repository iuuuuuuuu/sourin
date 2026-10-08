// ═══════════════════════════════════════════════════════════════════════
//  主题桥 —— 把 forui 主题补成一个「完整可用」的 Material ColorScheme
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这个文件（2026-09-23 实测踩坑记录）
//
// ## 坑 ①：两套 Material 的 Theme 互相看不见（最严重）
//
// Flutter 3.47 把 Material 从 SDK 里拆成了独立包 `material_ui`。
// `package:flutter/material.dart` 还在（SDK 里两份源码），于是**同一个
// app 里可以同时存在两套 Material**。forui 0.27 依赖的是 `material_ui`。
//
// 当时 `shell.dart` 用的是 material_ui，其余 35 个 UI 文件用的是
// flutter/material —— 两套 `Theme` 是**不同的 InheritedWidget 类型**，
// 互相看不见。`flutter/material` 的 `Theme.of` 找不到祖先就走兜底：
//
// ```dart
// return inheritedTheme?.theme.data ?? cupertinoTheme?.materialTheme
//        ?? ThemeData.fallback();     // ← 亮色！
// ```
//
// 症状（TV 截图量到的像素，**全部精确等于 Material 3 亮色 baseline**）：
//
// ```text
// 「设置」标题    (29,27,32)    = #1D1B20  亮色 onSurface      对比度 1.16:1 ✗
// 源名正文        (73,69,79)    = #49454F  亮色 onSurfaceVariant
// 卡片边框        (202,196,208) = #CAC4D0  亮色 outlineVariant
// 开关 on         (103,80,164)  = #6750A4  亮色 primary
// 卡片底色        (76,74,77)    = #E6E0E9@0.3 over #0A0A0A
// ```
//
// **深色背景上写深色字，标题几乎看不见**。
// ★ 最难发现的地方：**它不报错**。`Theme.of` 有兜底值，所以编译过、
//   跑得起来、`flutter analyze` 0 error、单测全绿 —— 只有**看截图量像素**
//   才发现。修法：全部统一到 material_ui（见 test/material_split_test.dart）。
//
// ## 坑 ②：`toApproximateMaterialTheme()` 只填了一部分角色
//
// forui 那个转换方法只设了 primary/secondary/error/surface/onSurface/
// secondaryContainer，**其余角色全部留空**，而 Material 的 getter 有兜底：
//
// ```dart
// Color get surfaceContainerHighest => _surfaceContainerHighest ?? surface;
// Color get outlineVariant          => _outlineVariant ?? onBackground;
// Color get onSurfaceVariant        => _onSurfaceVariant ?? onSurface;
// ```
//
// 于是 UI 里 `colors.surfaceContainerHighest.withValues(alpha: 0.3)`
// 画出来的卡片底 = `surface@0.3 over surface` = **和背景一模一样，卡片消失**；
// `colors.outlineVariant` 画的边框 = `onBackground` = **纯白 1px 亮线**。
//
// 坑 ① 修好之前这两个症状被"亮色主题"掩盖着（亮色下卡片确实看得见）。
// 修好坑 ① 之后如果不补这个，卡片会**变得看不见** —— 这是必须一起做的第二步。
//
// # 色值来源（不自己发明）
//
// 全部取自 forui 自己的色板（`FColors.neutralDark`）+ 原版 Vue 的
// `src/design/tokens.css`，保持视觉连续：
//
// ```text
// forui foreground       #FAFAFA    正文
// forui mutedForeground  #A1A1A1    次要文字
// forui card             #171717    卡片底
// forui border           0x1AFFFFFF 边框（白 10%）
// forui error            #FF6467    错误
// 原版 --surface-1       white 5%   最轻的一层
// 原版 --surface-2       white 8%   卡片底（等价 forui card）
// 原版 --divider         white 7%   分隔线
// ```

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

// ★ task-50 候选 C2：二级页转场改为「用户选的风格」
//   ⚠️ 不能写在 `material_ui` 那行之前 —— 本文件有测试守着 import 顺序？没有。
//      但 dart 惯例：package import 在前，相对 import 在后（中间空一行）。
import 'widgets/page_transition_route.dart';

/// ★★★ 关掉页面转场那层「scrim」—— 修任务⑰⑤「播放页白色条盖住顶部操作条」
///
/// # 用户原话
///
/// > 进播放页面的时候这个白色条会把顶部的操作条给覆盖掉,
/// > 这个动画不太好看,有点影响观感
///
/// # 根因（读 Flutter 源码确认，不是猜）
///
/// Windows 的默认转场是 `ZoomPageTransitionsBuilder`
///（`page_transitions_theme.dart` 的 `_defaultBuilders`）：
/// ```dart
/// TargetPlatform.windows: ZoomPageTransitionsBuilder(),
/// ```
/// 它在**离场路由**外面套了一层 scrim：
/// ```dart
/// // ZoomPageTransitionsBuilder 内部
/// return ColoredBox(
///   color: secondaryAnimation.isAnimating
///       ? backgroundColor ?? ColorScheme.of(context).surface  // ★ 这一层
///       : Colors.transparent,
///   child: builder,
/// );
/// ```
/// 那层 `ColoredBox` **铺满整个离场路由**（含顶部操作条），
/// 所以用户看到"一条白/浅色把顶栏盖住"。
///
/// `surface` 在浅色主题下是 `#EEF0F6`（`LightTokens.bgBase`），
/// 深色下是 `#0A0A0A` —— 与用户说的"白色条"完全对上（他当时是浅色）。
///
/// # 修法：把 scrim 显式设成**透明**
///
/// `ZoomPageTransitionsBuilder` 收 `backgroundColor`；传
/// `Colors.transparent` 等于"不要那层 scrim"，但**保留**它本身的
/// 缩放 + 淡入动画。
///
/// ★ task-50 候选 C2（2026-09-30）：这里返回的 builder 已换成
///   `SourinPageTransitionsBuilder`（**继承** Zoom）——
///   scrim 的透明处理**逐字不变**，只是**新页**的入场风格
///   改为"用户在设置里选的那个"。详见 `widgets/page_transition_route.dart`。
///
/// ```text
/// 保留 Zoom 的缩放淡入  → 用户只是嫌"那条色块难看"，不是要取消动画
/// 去掉 scrim 色块      → 顶部操作条在转场期间不再被盖住
/// ```
///
/// ⚠️ **不要**用"把 `colorScheme.surface` 改透明"来修 ——
///    那个角色还被 Scaffold / Card / Dialog 的兜底底色用着，
///    改它会让整个 UI 的底色消失。只改**转场这一处**。
///
/// ⚠️ 深/浅**两套主题都要设**：`surface` 两套都不透明，
///    所以两套都有这层色块（浅色 = 白条，深色 = 黑条）。
PageTransitionsTheme buildPageTransitionsTheme() {
  return const PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      // 本机 Windows；Linux 在 SDK 里同为 Zoom
      //
      // ★ task-50 候选 C2：换成 `SourinPageTransitionsBuilder`
      //   —— 它**继承** `ZoomPageTransitionsBuilder`，所以：
      //     · `backgroundColor` 照旧是 `Colors.transparent`（本文件要修的
      //       「白色条」不会回来）；
      //     · 离场页仍放大 1.05（`transition_clip_titlebar_test.dart` 的
      //       红度证明依赖这一点）；
      //     · 但**新页**的入场风格改为「用户在设置里选的那个」
      //       （默认 `slideRight`；选「无动画」则时长 0）。
      TargetPlatform.windows: SourinPageTransitionsBuilder(
        backgroundColor: Colors.transparent,
      ),
      TargetPlatform.linux: SourinPageTransitionsBuilder(
        backgroundColor: Colors.transparent,
      ),
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ task-14 ⑨：Android / Fuchsia **必须显式登记**
       * ══════════════════════════════════════════════════════════════
       *
       * # 为什么（这是 Owner 第⑨条在 Android 上的**真根因**）
       *
       * `PageTransitionsTheme.builders` 是个**直通 getter**，
       * **不会**与 SDK 的 `_defaultBuilders` 合并：
       * ```text
       * material_ui-1.4.0/lib/src/page_transitions_theme.dart
       *   :790  Map<TargetPlatform, PageTransitionsBuilder> get builders
       *           => _builders;            // ← 直通，无合并
       * ```
       * 而查表处有**兜底**（同一文件 `:897-906`）：
       * ```text
       *   final matchingBuilder = widget.builders[platform] ?? switch (platform) {
       *     iOS                                  => Cupertino...,
       *     android || fuchsia || windows || macOS || linux
       *                                          => ZoomPageTransitionsBuilder(),
       *   };
       * ```
       * ⇒ 改前这里只登记了 `windows`/`linux`，**Android 真机上**
       *   `builders[TargetPlatform.android] == null` ⇒ 落到兜底的
       *   `ZoomPageTransitionsBuilder()`。后果两条：
       * ```text
       * ① 用户在「设置 → 动画效果 → 页面切换动画」里选的风格
       *    （右滑/淡入/上滑/缩放/上浮/无动画）**完全不生效** ——
       *    二级页永远是 Zoom 缩放淡入；
       * ② 时长变成 SDK 默认的 **300ms**
       *    （`widgets/page_transitions_builder.dart:66`
       *      `Duration get transitionDuration => const Duration(milliseconds: 300);`）
       *    ⇒ 与底栏切页的 260ms **不一样** ——
       *    这正是用户说的「点下面的底栏和设置页的二级页动画根本就不一样」。
       * ```
       *
       * # 为什么不是「把 `MaterialApp.platform` 钉成 windows」
       * ```text
       * 那样会**连带**改掉 Android 的：overscroll 指示器样式、
       * 文本选择工具条、滚动物理（BouncingScrollPhysics → Clamping）
       * —— 与本次任务毫无关系的三处行为回归。
       * ```
       *
       * # 与 task-17「白色条」的关系
       * `backgroundColor: Colors.transparent` 与 windows/linux 同值 ⇒
       * Android 上那层 `colorScheme.surface` 色块也不会回来。
       *
       * ⚠️ `fuchsia` 与 android 一起登记：SDK 的兜底 switch 把两者
       *    归在**同一臂**，我们这边也保持一致（Fuchsia 不是交付平台，
       *    但"要么一起、要么都不"比留一个洞好）。
       */
      TargetPlatform.android: SourinPageTransitionsBuilder(
        backgroundColor: Colors.transparent,
      ),
      TargetPlatform.fuchsia: SourinPageTransitionsBuilder(
        backgroundColor: Colors.transparent,
      ),
    },
  );
}

/// 把 forui 主题转成一个**角色齐全**的 Material 主题
///
/// 直接调 `theme.toApproximateMaterialTheme()` 会留一堆空角色，
/// 那些角色的 getter 兜底值恰好会让「卡片底 = 背景色」「边框 = 纯白」。
/// 这里把 UI 实际用到的角色都显式填上。
///
/// ⚠️ 本函数**只处理深色**。浅色走 `app_theme.dart` 的
///    `buildLightMaterialTheme` —— 两者是**独立的两个函数**（不是一个
///    按 brightness 分支的共用函数），因为要补的角色不同
///    （浅色要反过来设 surface / onSurface / 描边）。
///    ★ 所以**任何一处修复都必须在另一处同步做**，否则只有一半主题被修好。
///    这一次的「播放按钮看不见」就同时存在于两套主题里（见 [_withFixedButtons]）。
ThemeData buildMaterialTheme(FThemeData theme) {
  final base = theme.toApproximateMaterialTheme();
  final c = theme.colors;

  // 卡片底：forui 的 card (#171717)，比背景 #0A0A0A 亮一档
  const card = Color(0xFF171717);

  // 边框：forui 的 border 是 0x1AFFFFFF（白 10%）。
  // ⚠️ ColorScheme 的边框角色**不能带 alpha** —— 它会被当实色画。
  //    这里按背景 #0A0A0A 把白 10% 合成成实色 #222222，
  //    观感与 forui 的 `colors.border` 一致。
  const borderSolid = Color(0xFF222222);

  return fixButtonContrast(
    base.copyWith(
      /*
       * ★ 转场 scrim 透明（修任务⑰⑤）—— 详见 [buildPageTransitionsTheme]
       */
      pageTransitionsTheme: buildPageTransitionsTheme(),
      colorScheme: base.colorScheme.copyWith(
        // ── 表面层级（坑 ② 的主角）──
        surfaceContainerLowest: const Color(0xFF060606),
        surfaceContainerLow: const Color(0xFF0D0D0D),
        surfaceContainer: const Color(0xFF111111),
        surfaceContainerHigh: card,
        surfaceContainerHighest: card,

        // ── 文字层级 ──
        // forui 没给 onSurfaceVariant，兜底 = onSurface（#FAFAFA）。
        // 用它画"次要文字"就和正文一样亮，层级消失。
        // 这里用 forui 的 mutedForeground（#A1A1A1，对比度 7.66:1）。
        onSurfaceVariant: c.mutedForeground,

        // ── 边框 ──
        outline: borderSolid,
        outlineVariant: borderSolid,

        // ── 错误容器 ──
        // 兜底 errorContainer = error = #FF6467（实心红），
        // 而 UI 里是 `errorContainer.withValues(alpha: 0.35)` 当"淡红底"用 ——
        // 实心红 @35% 太重。给一个真正适合做底的暗红。
        errorContainer: const Color(0xFF3A1416),
        onErrorContainer: const Color(0xFFFFB4B6),

        // ── 其余兜底（避免将来用到时又是"同色"）──
        primaryContainer: const Color(0xFF2A2A2A),
        onPrimaryContainer: c.foreground,
        secondaryContainer: const Color(0xFF262626),
        onSecondaryContainer: c.secondaryForeground,
        tertiary: c.primary,
        /*
         * ★ `tertiary` 被设成了 `c.primary`（#E5E5E5），但 forui 转换时
         *   `onTertiary` 兜底成了 `#FAFAFA` —— 于是
         *   `contrast(tertiary, onTertiary) = 1.21:1`（几乎不可见）。
         *
         * 这正是「同色对」家族的**第四个**成员（前三个是 FilledButton 的
         * 深/浅两套 + FilledButton 的 `iconColor`）。补上让它自洽 ——
         * "背景很亮、前景也很亮"的色对早晚会以同样的方式咬人。
         */
        onTertiary: c.primaryForeground,
        surfaceTint: Colors.transparent,
        inverseSurface: c.foreground,
        onInverseSurface: c.background,
      ),
    ),
  );
}

/// ★★★ 修掉 forui `toApproximateMaterialTheme()` 里 **按钮配色的复制粘贴 bug**
///
/// # 症状（用户可见）：详情页「播放」按钮是一块纯黑药丸，图标和文字都看不见
///
/// 实测像素（代理 T 的截图 `.probe/t-d1-btn.png`，浅色主题下的详情页操作行）：
/// ```text
/// 「播放」按钮  背景 rgb(23,23,23)  = #171717   ← 纯黑
///              文字 rgb(23,23,23)  = #171717   ← 与背景**完全相同**
///              → 对比度 1.00:1  （WCAG AA 要求 ≥ 4.5:1）
/// 同一行的「收藏」「追更」「换源」三个 OutlinedButton 都正常可见
/// ```
///
/// # 根因（**不是** colorScheme 缺 `primary` / `onPrimary`）
///
/// 这两个角色其实**是有值的** —— forui 的转换方法自己设了
/// （`forui-0.27.0/src/theme/theme_data.dart:1023-1024`）：
/// ```dart
/// primary:   colors.primary,
/// onPrimary: colors.primaryForeground,
/// ```
/// 深色下是 `#E5E5E5` / `#171717` → **14.23:1**，完全正常。
/// 所以「补 primary / onPrimary」**修不好这个 bug**（实测：深色 14.23:1）。
///
/// 真正坏的是同一个方法里另外预置的 **`filledButtonTheme`**
/// （`forui-0.27.0/src/theme/theme_data.dart:1148-1164`）：
/// ```dart
/// filledButtonTheme: FilledButtonThemeData(
///   style: ButtonStyle(
///     backgroundColor: .resolveWith((states) =>
///         buttonStyles.**primary**.base.decoration.resolve(...).color
///         ?? colors.secondary),                    // ← 背景取 primary
///     foregroundColor: .resolveWith((states) =>
///         buttonStyles.**secondary**.base.contentStyle.textStyle.resolve(...).color
///         ?? colors.secondaryForeground),          // ← ★ 前景却取 secondary（漏改）
///   ),
/// ),
/// ```
/// 前景那一行取的是 **secondary** 的样式，而 forui 的 neutral 主题里
/// `colors.secondary` 与 `colors.primary` 恰好**同值**，于是
/// `secondaryForeground` 正好等于按钮背景本身：
///
/// | 主题 | 按钮背景（buttonStyles.primary） | 按钮前景（**secondary**Foreground） | 对比度 |
/// |---|---|---|---|
/// | 浅色 | `#171717` | `#171717` | **1.00:1** ← 纯黑药丸 |
/// | 深色 | `#E5E5E5` | `#FAFAFA` | **1.21:1** ← 纯白药丸 |
///
/// `MaterialApp` **优先采用 theme 里的 ButtonStyle**（`ThemeData.filledButtonTheme`
/// 的优先级高于 `_FilledButtonDefaultsM3`），所以即使 colorScheme 完全正确，
/// 按钮也拿不到它 —— 这就是这个 bug 藏得深的原因。
///
/// # 为什么只覆盖**颜色**、保留 forui 的其余样式
///
/// ```text
/// 保留 padding / shape / textStyle → 按钮的圆角、内边距、字重与
///                                    forui 自己的按钮一致（视觉连续）
/// 整个丢掉（new ButtonStyle()）    → FilledButton 退回 Material 的
///                                    StadiumBorder 与另一套内边距，
///                                    同一行里和 OutlinedButton 的圆角就对不上
/// ```
///
/// # 实测结果（`.probe/z-fix-choice.log` 与 `test/theme_contrast_test.dart`）
///
/// ```text
///          修复前            修复后
/// 浅色     1.00:1  ✗   →    4.63:1  ✓   #3B6FE0 底 + #FFFFFF 字
/// 深色     1.21:1  ✗   →   14.23:1  ✓   #E5E5E5 底 + #171717 字
/// ```
///
/// ⚠️ 取值直接用 `colorScheme.primary` / `onPrimary` —— 与 Material 3 的
///    `_FilledButtonDefaultsM3`（`filled_button_defaults_m3.g.dart:31,40`）
///    逐字一致，也就是"按钮本该有的样子"。
///    **不自己发明色值**：浅色的 `primary` 是 `LightTokens.brand`（原版
///    `--brand-1`），深色的 `primary` 是 forui 的 `colors.primary`。
ThemeData fixButtonContrast(ThemeData base) {
  final cs = base.colorScheme;

  return base.copyWith(
    // ── FilledButton（实心按钮 = 详情页的「播放」）──
    filledButtonTheme: FilledButtonThemeData(
      style: _recolor(
        base.filledButtonTheme.style,
        cs,
        cs.primary,
        cs.onPrimary,
      ),
    ),

    /*
     * ── ElevatedButton（浮起按钮）──
     *
     * ⚠️ forui 给它的是 `buttonStyles.secondary`，那一对**本身是对的**
     *    （实测浅色 16.44:1 / 深色 14.50:1，都达标）。
     *
     * 之所以还要显式对齐，是因为 ElevatedButton 的**规范**配色是
     * `primaryContainer` / `onPrimaryContainer`（Material 3 的
     * `_ElevatedButtonDefaultsM3`），而那是**我们**在 colorScheme 里
     * 补的角色。不显式对齐的话，将来有人改 `primaryContainer`
     * 会发现按钮完全不跟着变 —— 又是一次"改了没反应"的静默困惑。
     *
     * 实测修后：浅色 #DCE6FB/#10305E → 10.43:1；深色 #2A2A2A/#FAFAFA → 13.75:1。
     */
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: _recolor(
        base.elevatedButtonTheme.style,
        cs,
        cs.primaryContainer,
        cs.onPrimaryContainer,
      ),
    ),
  );
}

/// 只把 [base] 的**颜色相关属性**换成修正值，其余（padding / shape / textStyle）原样保留
///
/// # 关键：**disabled 状态必须保留灰度反馈**
///
/// ⚠️ 第一版我用的是 `WidgetStatePropertyAll<Color>`（所有状态同一个值），
///    那会**干掉禁用态的变灰** —— 因为 Material 的解析顺序是
///    `widget.style ?? theme.style ?? defaultStyle`
///    （`material_ui/src/button_style_button.dart:388-393`），
///    theme 里的值一旦是"所有状态都返回同一个常量"，就**永远不会**
///    走到 `_FilledButtonDefaultsM3` 里那个 disabled 分支。
///    而 forui 原来那份 style 是**有** disabled 变体的
///    （`colors.disable(colors.primary)`），所以那会是一次**视觉回归**。
///
/// 所以这里逐状态给值，且 disabled 的取值**照抄 Material 3 的规范**
/// （`filled_button_defaults_m3.g.dart:28-41,99-101`）：
/// ```text
/// 背景  disabled → onSurface @12%
/// 前景  disabled → onSurface @38%
/// ```
/// 这样启用态用我们修正的色，禁用态与"Material 本来会给的"完全一致 ——
/// **没有引入任何新视觉**。
///
/// # 为什么用 `merge(base)` 而不是 `base.copyWith(...)`
///
/// `ButtonStyle.copyWith` 的语义是 `新值 ?? 旧值` —— 传 `null` **清不掉**
/// 旧值（没法把 forui 那份错误的 `overlayColor` 置空）。
/// 而 `merge` 是 `this.x ?? other.x`：把我们这份（只含颜色）放前面、
/// forui 那份放后面，就得到「颜色用我们的，其余用 forui 的」。
ButtonStyle _recolor(ButtonStyle? base, ColorScheme cs, Color bg, Color fg) {
  /// Material 3 对禁用态的统一处理：把 `onSurface` 降透明度
  Color dim(double alpha) => cs.onSurface.withValues(alpha: alpha);

  final colors = ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith<Color>(
      (states) => states.contains(WidgetState.disabled) ? dim(0.12) : bg,
    ),
    foregroundColor: WidgetStateProperty.resolveWith<Color>(
      (states) => states.contains(WidgetState.disabled) ? dim(0.38) : fg,
    ),
    /*
     * ⚠️ `iconColor` 必须一起给。
     *
     * `FilledButton.icon`（详情页那两个按钮用的就是它）**不读
     * foregroundColor 画图标** —— material_ui 的
     * `_FilledButtonDefaultsM3.iconColor` 是**独立**的一个属性
     * （`filled_button_defaults_m3.g.dart:97-113`）。
     * 只改 foregroundColor 的后果是「文字看得见了，▶ 图标还是看不见」。
     */
    iconColor: WidgetStateProperty.resolveWith<Color>(
      (states) => states.contains(WidgetState.disabled) ? dim(0.38) : fg,
    ),
    /*
     * pressed / hovered 的叠加层。
     *
     * forui 那份是从**错误的前景**算出来的（见 [fixButtonContrast] 的说明），
     * 所以必须覆盖掉。取值照 Material 3 规范（用修正后的前景色）：
     * ```text
     * pressed  0.1    hovered  0.08    focused  0.1    其余 null
     * ```
     */
    overlayColor: WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.pressed)) {
        return fg.withValues(alpha: 0.1);
      }
      if (states.contains(WidgetState.hovered)) {
        return fg.withValues(alpha: 0.08);
      }
      if (states.contains(WidgetState.focused)) {
        return fg.withValues(alpha: 0.1);
      }
      return null;
    }),
  );

  // `this ?? other`：颜色用我们的，padding / shape / textStyle 用 forui 的
  return colors.merge(base);
}
