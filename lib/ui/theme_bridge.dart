// ═══════════════════════════════════════════════════════════════════════
//  主题构建 —— 从自有调色板派生一套「角色齐全」的 Material 主题
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件解决过两个「不报错」的真缺陷（历史，勿删）
//
// ## 坑 ①：两套 Material 的 Theme 互相看不见（最严重）
//
// Flutter 3.47 把 Material 从 SDK 拆成独立包 `material_ui`，
// 而 `package:flutter/material` 还在（同一个 SDK 里两份源码），
// 于是**同一个 app 里可以同时存在两套 Material**。两套 `Theme` 是
// **不同的 InheritedWidget 类型**，互相看不见；`Theme.of` 找不到祖先就走兜底：
//
// ```dart
// return inheritedTheme?.theme.data ?? cupertinoTheme?.materialTheme
//        ?? ThemeData.fallback();     // ← 亮色！
// ```
//
// 症状（TV 截图量到的像素，全部精确等于 Material 3 亮色 baseline）：
// ```text
// 「设置」标题  #1D1B20（亮色 onSurface）对背景对比度 1.16:1  ✗
// ```
//
// **深色背景上写深色字，标题几乎看不见**，而且**不报错**：编译过、
// analyze 0 error、单测全绿 —— 只有看截图量像素才发现。
// ⇒ 铁律：生产代码只 import `package:material_ui/material_ui.dart`
//   （`test/theme_regression_test.dart` 全 lib 扫描守着）。
//
// ## 坑 ②：Material 的 ColorScheme 角色**有兜底值**，漏填就同色
//
// ```dart
// Color get surfaceContainerHighest => _surfaceContainerHighest ?? surface;
// Color get outlineVariant          => _outlineVariant ?? onBackground;
// ```
//
// 于是 UI 里 `surfaceContainerHighest.withValues(alpha: 0.3)` 画出来的
// 卡片底 = `surface@0.3 over surface` = **和背景一模一样，卡片消失**；
// `outlineVariant` 画的边框 = `onBackground` = **纯白 1px 亮线**。
//
// ⇒ 本文件的职责就是**把 UI 实际用到的角色逐个显式填上**。
//
// # 色值来源（不自己发明）
//
// 全部来自本项目已验证过的那套调色板：深色是原 forui `AppPalette.neutralDark`
// （已搬进 `app_palette.dart` 的 `AppPalette.dark`），浅色是原版 Vue 的
// `src/design/theme-light.css`（见 `app_theme.dart` 的 `LightTokens`）。
// 组件主题的尺寸/圆角逐值对齐移除 forui 之前的读数 —— 这次替换是
// **外科手术**，不是重新设计。

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'app_palette.dart';
import 'app_typeface.dart';
import 'tokens.dart';
import 'theme/theme_pack.dart';

// ★ task-50 候选 C2：二级页转场改为「用户选的风格」
//   ⚠️ 不能写在 `material_ui` 那行之前 —— dart 惯例：package import 在前，
//      相对 import 在后（中间空一行）。
import 'widgets/page_transition_route.dart';

/// 组件统一的圆角（= 原 forui `style.borderRadius.md`）
const _defaultRadius = 10.0;
const _radius = BorderRadius.all(Radius.circular(_defaultRadius));

RoundedSuperellipseBorder _shape({BorderSide side = BorderSide.none}) =>
    RoundedSuperellipseBorder(side: side, borderRadius: _radius);

/// 页面转场（关掉那层 scrim）
///
/// # 为什么必须把 scrim 设成透明
///
/// Windows 的默认转场是 `ZoomPageTransitionsBuilder`，它在**离场路由**外面
/// 套了一层 `ColoredBox(color: secondaryAnimation.isAnimating ? surface : transparent)`。
/// 那层色块**铺满整个离场路由**（含顶部操作条）⇒ 用户看到"一条白/浅色把顶栏盖住"
/// （Owner 原话：「进播放页面的时候这个白色条会把顶部的操作条给覆盖掉」）。
///
/// ★ 只改转场这一处：`colorScheme.surface` 还被 Scaffold / Card / Dialog
///   当兜底底色用着，改它会让整个 UI 的底色消失。
///
/// ⚠️ `PageTransitionsTheme.builders` 是**直通 getter，不与 SDK 默认值合并**，
///    所以 android / fuchsia 必须**显式登记**，否则真机上用户选的转场风格
///    完全不生效、时长还退回 SDK 的 300ms（与底栏 260ms 不一致）。
PageTransitionsTheme buildPageTransitionsTheme() {
  return const PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      // `SourinPageTransitionsBuilder` **继承** Zoom：离场页仍放大 1.05，
      // scrim 的透明处理逐字不变，只是新页的入场风格改为「用户在设置里选的」。
      TargetPlatform.windows: SourinPageTransitionsBuilder(
        backgroundColor: Colors.transparent,
      ),
      TargetPlatform.linux: SourinPageTransitionsBuilder(
        backgroundColor: Colors.transparent,
      ),
      TargetPlatform.android: SourinPageTransitionsBuilder(
        backgroundColor: Colors.transparent,
      ),
      TargetPlatform.fuchsia: SourinPageTransitionsBuilder(
        backgroundColor: Colors.transparent,
      ),
    },
  );
}

/// 组装一套完整的 `ThemeData`
///
/// ⚠️ 深 / 浅是**两条独立分支**而不是一个按 brightness 分流后统一补色的
///    函数 —— 因为要补的角色不同（浅色要反过来设 surface / onSurface / 描边）。
///    ★ 所以**任何一处修复都必须在另一处同步做**，否则只有一半主题被修好。
ThemeData buildAppTheme(Brightness brightness, {ThemePack? pack}) {
  final td = brightness == Brightness.light
      ? _buildLight(pack?.palette)
      : _buildDark(pack?.palette);

  // 主题包可以微调**形状**，让不同调色板有自己的"性格"（圆角更方的科技风、
  // 更圆的卡片风）。只允许这两个参数 —— 字号/间距一放开，主题包就能把
  // 全站排版搞乱，那不叫"主题"叫"换皮"。
  final r = pack?.radius;
  if (r == null || r == _defaultRadius) return td;

  final radius = BorderRadius.all(Radius.circular(r));
  final shape = WidgetStateProperty.all(
      RoundedSuperellipseBorder(borderRadius: radius));
  return td.copyWith(
    cardTheme: td.cardTheme.copyWith(
      shape: RoundedSuperellipseBorder(
          borderRadius: radius, side: td.cardTheme.shape is OutlinedBorder
              ? (td.cardTheme.shape as OutlinedBorder).side
              : BorderSide.none),
    ),
    dialogTheme: DialogThemeData(
        shape: RoundedSuperellipseBorder(borderRadius: radius)),
    bottomSheetTheme: BottomSheetThemeData(
        shape: RoundedSuperellipseBorder(borderRadius: radius)),
    snackBarTheme: td.snackBarTheme.copyWith(
        shape: RoundedSuperellipseBorder(borderRadius: radius)),
    listTileTheme: ListTileThemeData(
        shape: RoundedSuperellipseBorder(borderRadius: radius)),
    chipTheme: ChipThemeData(shape: RoundedSuperellipseBorder(borderRadius: radius)),
    filledButtonTheme: FilledButtonThemeData(
        style: td.filledButtonTheme.style?.copyWith(shape: shape)),
    elevatedButtonTheme: ElevatedButtonThemeData(
        style: td.elevatedButtonTheme.style?.copyWith(shape: shape)),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: td.outlinedButtonTheme.style?.copyWith(shape: shape)),
    textButtonTheme: TextButtonThemeData(
        style: td.textButtonTheme.style?.copyWith(shape: shape)),
  );
}

// ═══════════════════════════════════════════════════════════════════════
//  组件主题（两套明暗共用）
// ═══════════════════════════════════════════════════════════════════════

/// 与明暗无关的**形状 / 尺寸**部分
///
/// 这里所有数值都等于移除 forui 之前的读数（实测 dump 对齐），
/// 所以「移除 forui」这一步在视觉上是零差异的。
ThemeData _shared(ThemeData base, AppPalette c, AppTypeface t) {
  WidgetStateProperty<OutlinedBorder?> shape = WidgetStateProperty.all(_shape());

  TextStyle btnText = TextStyle(
    fontFamily: t.fontFamily,
    fontFamilyFallback: t.fontFamilyFallback,
    fontSize: t.sm,
    fontWeight: FontWeight.w500,
    height: 1,
    leadingDistribution: TextLeadingDistribution.even,
  );

  // 原 forui 给所有按钮的内边距都是这一档
  const pad = EdgeInsets.symmetric(horizontal: 10, vertical: 11);

  WidgetStateProperty<Color?> dim(Color fg, Color disabledBg) =>
      WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.disabled) ? disabledBg : fg);
  Color soften(Color x, double a) => x.withValues(alpha: a);

  WidgetStateProperty<Color?> overlay(Color fg) =>
      WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.pressed)) return soften(fg, 0.10);
        if (s.contains(WidgetState.hovered)) return soften(fg, 0.08);
        if (s.contains(WidgetState.focused)) return soften(fg, 0.10);
        return null;
      });

  return base.copyWith(
    textTheme: t.toTextTheme(),
    // ★ forui 用的是 `NoSplash.splashFactory` —— 保留，否则每个按钮都会多出
    //   一圈 Material 默认的水波纹，与本项目自绘的按压反馈（press_feedback.dart）
    //   叠加成"双重反馈"。
    splashFactory: NoSplash.splashFactory,
    iconTheme: IconThemeData(color: c.primary, size: 20),
    dividerTheme: DividerThemeData(color: c.secondary, thickness: 1),

    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStateProperty.all(btnText),
        padding: WidgetStateProperty.all(pad),
        shape: shape,
        backgroundColor: dim(c.primary, soften(c.foreground, 0.12)),
        foregroundColor: dim(c.primaryForeground, soften(c.foreground, 0.38)),
        // ⚠️ `FilledButton.icon` **不读** foregroundColor 画图标 ——
        //    `iconColor` 是独立属性。只改前景的后果是「文字看得见了，
        //    ▶ 图标还是看不见」（详情页那两个按钮用的正是它）。
        iconColor: dim(c.primaryForeground, soften(c.foreground, 0.38)),
        overlayColor: overlay(c.primaryForeground),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStateProperty.all(btnText),
        padding: WidgetStateProperty.all(pad),
        shape: shape,
        backgroundColor: dim(c.secondary, soften(c.foreground, 0.12)),
        foregroundColor: dim(c.secondaryForeground, soften(c.foreground, 0.38)),
        iconColor: dim(c.secondaryForeground, soften(c.foreground, 0.38)),
        overlayColor: overlay(c.secondaryForeground),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStateProperty.all(btnText),
        padding: WidgetStateProperty.all(pad),
        shape: shape,
        side: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return BorderSide(color: c.disable(c.border));
          if (s.contains(WidgetState.hovered)) return BorderSide(color: c.hover(c.border));
          return BorderSide(color: c.border);
        }),
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.disabled) ? soften(c.foreground, 0.12) : c.background),
        foregroundColor: dim(c.foreground, soften(c.foreground, 0.38)),
        iconColor: dim(c.foreground, soften(c.foreground, 0.38)),
        overlayColor: overlay(c.foreground),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStateProperty.all(btnText),
        shape: shape,
        backgroundColor: WidgetStateProperty.all(Colors.transparent),
        foregroundColor: dim(c.foreground, soften(c.foreground, 0.38)),
        iconColor: dim(c.foreground, soften(c.foreground, 0.38)),
        overlayColor: overlay(c.foreground),
      ),
    ),

    // 卡片：零投影 + 1px 描边（forui 原样）
    cardTheme: CardThemeData(
      elevation: 0,
      color: c.card,
      shape: _shape(side: BorderSide(color: c.border)),
    ),

    dialogTheme: DialogThemeData(shape: _shape()),
    bottomSheetTheme: BottomSheetThemeData(shape: _shape()),
    snackBarTheme: SnackBarThemeData(
      shape: _shape(),
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: ListTileThemeData(shape: _shape()),
    chipTheme: ChipThemeData(shape: _shape()),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.primary,
      foregroundColor: c.primaryForeground,
      elevation: 0,
      shape: _shape(),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: shape,
        foregroundColor: dim(c.foreground, soften(c.foreground, 0.38)),
        overlayColor: overlay(c.foreground),
      ),
    ),

    navigationBarTheme: NavigationBarThemeData(indicatorShape: _shape()),
    navigationRailTheme: NavigationRailThemeData(indicatorShape: _shape()),
    navigationDrawerTheme: NavigationDrawerThemeData(indicatorShape: _shape()),

    // ══════════════════════════════════════════════════════════════════
    // ★ 里程碑 3：下面这些组件在里程碑 1/2 时**没有**被覆盖，
    //   全部落回 Material 3 默认 —— 于是它们是全站唯一「不是一套设计」
    //   的部分（Owner 第 11 条「别的都一般般」的直接来源之一）。
    //
    //   判据统一：**形状**跟卡片/按钮同一档圆角（`_shape()`），
    //   **配色**跟次级面同一族（`c.secondary` / `c.card`）。
    //   凡是「浮在内容之上」的（菜单 / 提示条 / 悬浮层）都要**有边界**，
    //   否则在深色页面上它会跟背景糊在一起。
    // ══════════════════════════════════════════════════════════════════

    menuTheme: MenuThemeData(
      // ⚠️ `MenuThemeData.style` 是 `MenuStyle`（**不是** `ButtonStyle`）——
      //   两者的差别正好在 `textStyle` / `foregroundColor` 这些项上，
      //   传错类型编译器会直接报出来，但很容易照着按钮那边抄。
      style: MenuStyle(
        shape: shape,
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.disabled) ? soften(c.foreground, 0.12) : c.card),
        // ★ 浮层必须有描边：深色下 `card` 与背景只差一档，没有描边时
        //   菜单会"融"进页面（这是最常见的"看起来不高级"来源）。
        side: WidgetStateProperty.all(BorderSide(color: c.border)),
        shadowColor: WidgetStateProperty.all(Colors.transparent),
        // ⚠️ `MenuStyle` 里这几个都是 `WidgetStateProperty<Color?>`（不是裸 Color）
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
      ),
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: c.card,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedSuperellipseBorder(
        borderRadius: _radius,
        side: BorderSide(color: c.border),
      ),
      textStyle: TextStyle(
        color: c.foreground,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
      ),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        // 反色：提示条是全站唯一的「反过来」的元素（前景当底）。
        // 这样它在任何底色上都能读，也一眼就与普通卡片区分开。
        color: c.foreground,
        borderRadius: Radii.rSm,
      ),
      textStyle: TextStyle(
        color: c.background,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.xs,
        height: 1.3,
      ),
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: Sp.x1),
      // 默认 Material 是**立即**弹出 —— 鼠标扫过一排图标会闪一片提示。
      waitDuration: const Duration(milliseconds: 500),
    ),

    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: TextStyle(
        color: c.foreground,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
      ),
      menuStyle: MenuStyle(
        shape: shape,
        backgroundColor: WidgetStateProperty.all(c.card),
        side: WidgetStateProperty.all(BorderSide(color: c.border)),
        shadowColor: WidgetStateProperty.all(Colors.transparent),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
      ),
    ),

    scrollbarTheme: ScrollbarThemeData(
      // ⚠️ 滚动条是**唯一**默认就在屏幕上、且天天都在看的控件 ——
      //   Material 默认那根 4px 硬边深色条在本项目里非常突兀。
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.dragged)
          ? c.mutedForeground
          : soften(c.mutedForeground, 0.55)),
      trackColor: WidgetStateProperty.all(Colors.transparent),
      // 静止时收窄、hover/拖动时加粗 —— 平时不抢视线，操作时够得着
      thickness: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.dragged) || s.contains(WidgetState.hovered) ? 6.0 : 4.0),
      // ⚠️ 这里是 `Radius?` 不是 `BorderRadius`（传 double 会编译失败）
      radius: const Radius.circular(Radii.full),
      interactive: true,
    ),

    tabBarTheme: TabBarThemeData(
      labelColor: c.primary,
      unselectedLabelColor: c.mutedForeground,
      indicatorColor: c.primary,
      // ★ 分隔线透明而不是默认的硬灰 —— 默认那条在深色下是一条亮线
      dividerColor: Colors.transparent,
      labelStyle: TextStyle(
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        fontWeight: FontWeights.semibold,
      ),
      unselectedLabelStyle: TextStyle(
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        fontWeight: FontWeights.regular,
      ),
    ),

    badgeTheme: BadgeThemeData(
      backgroundColor: c.error,
      textColor: c.background,
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.primary,
      linearTrackColor: c.secondary,
      circularTrackColor: c.secondary,
    ),

    expansionTileTheme: ExpansionTileThemeData(
      iconColor: c.mutedForeground,
      collapsedIconColor: c.mutedForeground,
      textColor: c.foreground,
      collapsedTextColor: c.foreground,
      // ★ 默认形状带一条分割线，深色下那是一条贯穿的亮线。
      //   改成无描边，由页面自己控制分隔（与 settings_kit 一致）。
      shape: const Border(),
      collapsedShape: const Border(),
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.disabled) ? c.disable(c.foreground) : c.foreground),
      trackColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.disabled)) return c.disable(c.secondary);
        return s.contains(WidgetState.selected) ? c.primary : c.secondary;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.disabled)) return c.disable(c.secondary);
        return s.contains(WidgetState.selected) ? c.primary : c.secondary;
      }),
    ),

    sliderTheme: SliderThemeData(
      activeTrackColor: c.primary,
      inactiveTrackColor: c.secondary,
      thumbColor: c.primary,
      overlayColor: soften(c.primary, 0.12),
      valueIndicatorColor: c.foreground,
      valueIndicatorTextStyle: TextStyle(
        color: c.background,
        fontFamily: t.fontFamily,
        fontSize: t.xs,
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      // 原 forui：普通态描边、聚焦转主色、禁用半透明、错误转红
      border: WidgetStateInputBorder.resolveWith((states) {
        final side = states.contains(WidgetState.error)
            ? BorderSide(color: states.contains(WidgetState.disabled) ? c.disable(c.error) : c.error)
            : states.contains(WidgetState.disabled)
                ? BorderSide(color: c.disable(c.border))
                : states.contains(WidgetState.focused)
                    ? BorderSide(color: c.primary)
                    : BorderSide(color: c.border);
        return OutlineInputBorder(borderSide: side, borderRadius: _radius);
      }),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: c.border),
        borderRadius: _radius,
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: c.primary),
        borderRadius: _radius,
      ),
      errorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: c.error),
        borderRadius: _radius,
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: c.error),
        borderRadius: _radius,
      ),
      disabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: c.disable(c.border)),
        borderRadius: _radius,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      hintStyle: TextStyle(
        color: c.mutedForeground,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        height: 1.3,
      ),
      labelStyle: TextStyle(
        color: c.mutedForeground,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        height: 1.3,
      ),
      floatingLabelStyle: TextStyle(
        color: c.foreground,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        fontWeight: FontWeight.w500,
        height: 1.3,
      ),
      errorStyle: TextStyle(
        color: c.error,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        height: 1.3,
      ),
      helperStyle: TextStyle(
        color: c.mutedForeground,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        height: 1.3,
      ),
    ),

    pageTransitionsTheme: buildPageTransitionsTheme(),
  );
}

/// 把 `AppPalette` 注入 `ThemeData` 的扩展位
ThemeData _withColors(ThemeData base, AppPalette c) =>
    base.copyWith(extensions: [c]);

// ═══════════════════════════════════════════════════════════════════════
//  深色
// ═══════════════════════════════════════════════════════════════════════

ThemeData _buildDark([AppPalette? override]) {
  final c = override ?? AppPalette.dark;
  final t = AppTypeface.forPlatform(Brightness.dark);

  // 边框角色**不能带 alpha** —— ColorScheme 的描边会被当实色画。
  // 这里按背景 #0A0A0A 把 `border`（白 10%）合成成实色 #222222，观感一致。
  const borderSolid = Color(0xFF222222);
  // 卡片底比背景亮一档（= AppPalette.dark.card = #171717）
  const card = Color(0xFF171717);

  final base = ThemeData(useMaterial3: true, brightness: Brightness.dark);
  final cs = c.toColorScheme().copyWith(
    // ── 表面层级（坑 ② 的主角）──
    surfaceContainerLowest: const Color(0xFF060606),
    surfaceContainerLow: const Color(0xFF0D0D0D),
    surfaceContainer: const Color(0xFF111111),
    surfaceContainerHigh: card,
    surfaceContainerHighest: card,

    // ── 文字层级 ──
    // 兜底的 onSurfaceVariant = onSurface，用它画次要文字层级会消失
    onSurfaceVariant: c.mutedForeground,

    // ── 描边 ──
    outline: borderSolid,
    outlineVariant: borderSolid,

    // ── 错误容器 ──
    // 兜底 errorContainer = error（实心红），而 UI 里拿它 @35% 当"淡红底"用，
    // 实心红太重。给一个真正适合做底的暗红。
    errorContainer: const Color(0xFF3A1416),
    onErrorContainer: const Color(0xFFFFB4B6),

    // ── 其余兜底（避免将来用到时又是"同色"）──
    primaryContainer: const Color(0xFF2A2A2A),
    onPrimaryContainer: c.foreground,
    secondaryContainer: const Color(0xFF262626),
    onSecondaryContainer: c.secondaryForeground,
    tertiary: c.primary,
    // ⚠️ `tertiary` 与 `onTertiary` 必须成对给：只给 tertiary 时兜底的
    //    onTertiary 是亮色 ⇒ 「背景很亮、前景也很亮」（实测 1.21:1，几乎不可见）。
    onTertiary: c.primaryForeground,
    surfaceTint: Colors.transparent,
    inverseSurface: c.foreground,
    onInverseSurface: c.background,
  );

  return _withColors(
    _shared(base.copyWith(colorScheme: cs), c, t),
    c,
  );
}

// ═══════════════════════════════════════════════════════════════════════
//  浅色
// ═══════════════════════════════════════════════════════════════════════

/// 浅色主题的语义色（照抄原版 `theme-light.css`）
class LightTokens {
  /// `--bg-base: #eef0f6`
  static const bgBase = Color(0xFFEEF0F6);

  /// `--bg-elevated: #ffffff`
  static const bgElevated = Color(0xFFFFFFFF);

  /// `--text-primary: rgb(16 18 26 / 0.93)`
  ///
  /// ⚠️ 不是纯黑 —— 原版注释：「不能纯黑（刺眼）」。合成后约 `#1E2028`。
  static const textPrimary = Color(0xFF1E2028);

  /// `--text-secondary: rgb(16 18 26 / 0.60)` → 约 `#70727A`
  static const textSecondary = Color(0xFF70727A);

  /// `--divider: rgb(16 18 26 / 0.07)` → 约 `#DFE1E8`
  static const divider = Color(0xFFDFE1E8);

  /// `--glass-stroke: rgb(16 18 26 / 0.045)`
  static const glassStroke = Color(0xFFE4E6EC);

  /// `--brand-1: #3b6fe0`（浅色下比深色**略深**，保证白底对比度）
  static const brand = Color(0xFF3B6FE0);

  /// `--brand-2: #8b4de8`
  static const brand2 = Color(0xFF8B4DE8);

  static const error = Color(0xFFD93025);
  static const errorContainer = Color(0xFFFCE8E6);

  /// 次级容器（`--surface-2` 合成值）
  static const surface2 = Color(0xFFF5F7FA);
}

ThemeData _buildLight([AppPalette? override]) {
  final t = AppTypeface.forPlatform(Brightness.light);

  // 浅色板的默认值从 LightTokens 派生 —— 每个值都有原版 CSS 变量作出处。
  //
  // ⚠️ 主题包给了 `override` 时**完全用它**，不再逐字段覆盖 ——
  //    否则「用户在浅色主题包里配了 background」会被这行悄悄改回
  //    `LightTokens.bgBase`，表现为"导入的主题包不生效"。
  final c = override ??
      AppPalette.light.copyWith(
    background: LightTokens.bgBase,
    foreground: LightTokens.textPrimary,
    mutedForeground: LightTokens.textSecondary,
    secondary: const Color(0xFFE8EAF0),
    secondaryForeground: LightTokens.textPrimary,
    muted: const Color(0xFFE8EAF0),
    card: LightTokens.bgElevated,
    // ⚠️ 描边要**反过来**（原版要点 ⑤）：深色用白描边提亮边缘，
    //    浅色必须用深色描边才有轮廓。
    border: LightTokens.glassStroke,
    primary: LightTokens.brand,
    primaryForeground: Colors.white,
    error: LightTokens.error,
  );

  final base = ThemeData(useMaterial3: true, brightness: Brightness.light);
  final cs = c.toColorScheme().copyWith(
    // ── 表面层级（浅色下「越高越白」，与深色相反）──
    surfaceContainerLowest: LightTokens.bgElevated,
    surfaceContainerLow: LightTokens.bgElevated,
    surfaceContainer: LightTokens.bgElevated,
    surfaceContainerHigh: const Color(0xFFF7F8FB),
    surfaceContainerHighest: LightTokens.surface2,

    onSurfaceVariant: LightTokens.textSecondary,

    outline: LightTokens.glassStroke,
    outlineVariant: LightTokens.divider,

    primary: LightTokens.brand,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFDCE6FB),
    onPrimaryContainer: const Color(0xFF10305E),

    error: LightTokens.error,
    onError: Colors.white,
    errorContainer: LightTokens.errorContainer,
    onErrorContainer: const Color(0xFF5F1410),

    secondary: const Color(0xFFE8EAF0),
    onSecondary: LightTokens.textPrimary,
    // ★ `secondaryContainer` / `onSecondaryContainer` 必须与 `secondary`
    //   同源，否则 `FilledButton.tonal` 看起来"没跟着主题走"。
    secondaryContainer: const Color(0xFFE8EAF0),
    onSecondaryContainer: LightTokens.textPrimary,
    tertiary: LightTokens.brand2,
    onTertiary: Colors.white,
    surfaceTint: Colors.transparent,
    inverseSurface: LightTokens.textPrimary,
    onInverseSurface: LightTokens.bgBase,
  );

  return _withColors(
    _shared(base.copyWith(colorScheme: cs), c, t),
    c,
  );
}
