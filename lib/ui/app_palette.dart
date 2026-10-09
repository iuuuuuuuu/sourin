// ═══════════════════════════════════════════════════════════════════════
//  AppPalette —— 自有的语义调色板（取代 forui 的 FColors）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有它
//
// 移除 forui 后，界面里到处是 `FTheme.of(context).colors.xxx`。
// 那些角色（正文 / 次要文字 / 卡片底 / 描边 …）本身是对的，
// 而且**已经被本项目验证过**（见 `theme_regression_test.dart` 的对比度断言），
// 所以这里**照抄 forui neutral 那一套色值**，只把「取色的容器」换掉：
//
// ```text
// FTheme.of(context).colors.primary  →  AppPalette.of(context).primary
// ```
//
// # 两个刻意的设计
//
// ① 它是 `ThemeExtension` 而不是全局单例 —— 这样「主题跟随系统」以及
//    将来里程碑 2 的「多套调色板」都能通过 Theme 传播，页面只管 `of(context)`。
//
// ② 命名与 forui 保持一致（`foreground` / `mutedForeground` / `card` …），
//    这样机械替换时不会看错，且读旧代码的人不用重新建立映射。

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart';

/// 一套完整的语义色
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.barrier,
    required this.background,
    required this.foreground,
    required this.primary,
    required this.primaryForeground,
    required this.secondary,
    required this.secondaryForeground,
    required this.muted,
    required this.mutedForeground,
    required this.error,
    required this.card,
    required this.border,
  });

  final Brightness brightness;

  /// 模态遮罩（对话框 / 抽屉背后的那层）
  final Color barrier;

  /// 页面底色
  final Color background;

  /// 正文色
  final Color foreground;

  /// 主色（选中 / 强调）
  final Color primary;

  /// 主色之上的文字
  final Color primaryForeground;

  /// 次级面（比背景亮一档的填充）
  final Color secondary;

  /// 次级面之上的文字
  final Color secondaryForeground;

  /// 弱化填充（禁用态 / 占位）
  final Color muted;

  /// 次要文字
  final Color mutedForeground;

  final Color error;

  /// 卡片底
  final Color card;

  /// 描边
  final Color border;

  /// ★ 深色中性板
  ///
  /// 色值逐个照抄 forui `AppPalette.neutralDark`（`colors.dart:165`），
  /// 保证移除 forui **不改任何观感**。
  static const dark = AppPalette(
    brightness: Brightness.dark,
    barrier: Color(0x7A000000),
    background: Color(0xFF0A0A0A),
    foreground: Color(0xFFFAFAFA),
    primary: Color(0xFFE5E5E5),
    primaryForeground: Color(0xFF171717),
    secondary: Color(0xFF262626),
    secondaryForeground: Color(0xFFFAFAFA),
    muted: Color(0xFF262626),
    mutedForeground: Color(0xFFA1A1A1),
    error: Color(0xFFFF6467),
    card: Color(0xFF171717),
    border: Color(0x1AFFFFFF),
  );

  /// ★ 浅色中性板（forui `AppPalette.neutralLight`，`colors.dart:144`）
  ///
  /// ⚠️ 界面上真正生效的浅色是 `buildLightMaterialTheme()` 里那份
  ///    （原版 `theme-light.css` 的 `--bg-base: #eef0f6` 那一套），
  ///    这份中性板只作为「浅色语义角色的兜底来源」。
  static const light = AppPalette(
    brightness: Brightness.light,
    barrier: Color(0x33000000),
    background: Color(0xFFFFFFFF),
    foreground: Color(0xFF0A0A0A),
    primary: Color(0xFF171717),
    primaryForeground: Color(0xFFFAFAFA),
    secondary: Color(0xFFF5F5F5),
    secondaryForeground: Color(0xFF171717),
    muted: Color(0xFFF5F5F5),
    mutedForeground: Color(0xFF737373),
    error: Color(0xFFE7000B),
    card: Color(0xFFFFFFFF),
    border: Color(0xFFE5E5E5),
  );

  /// 当前主题的语义色
  ///
  /// ⚠️ 找不到祖先时**不静默兜底成浅色**（forui 与 Material 都这么干，
  ///    并且都不报错 —— 本项目已经为这个坑付过一次代价，见
  ///    `test/titlebar_theme_test.dart`）：这里直接抛，让问题在开发期暴露。
  static AppPalette of(BuildContext context) {
    final ext = Theme.of(context).extension<AppPalette>();
    assert(ext != null, 'AppPalette 未注入：这一层在 MaterialApp 之外。');
    if (ext != null) return ext;
    return Theme.of(context).brightness == Brightness.dark ? dark : light;
  }

  /// 展平成 Material `ColorScheme`（角色补全由 `theme_bridge.dart` 负责）
  ColorScheme toColorScheme() => ColorScheme(
        brightness: brightness,
        primary: primary,
        onPrimary: primaryForeground,
        secondary: secondary,
        onSecondary: secondaryForeground,
        error: error,
        onError: Color.alphaBlend(foreground, error),
        surface: background,
        onSurface: foreground,
      );

  /// 深色下 hover 时把颜色提亮一点（桌面端指针反馈）
  Color hover(Color c) =>
      brightness == Brightness.dark ? _lighten(c, 0.075) : _darken(c, 0.05);

  /// 禁用态：半透明
  Color disable(Color c) => c.withValues(alpha: 0.5);

  static Color _lighten(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness + amount).clamp(0.0, 1.0)).toColor();
  }

  static Color _darken(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness - amount).clamp(0.0, 1.0)).toColor();
  }

  @override
  AppPalette copyWith({
    Brightness? brightness,
    Color? barrier,
    Color? background,
    Color? foreground,
    Color? primary,
    Color? primaryForeground,
    Color? secondary,
    Color? secondaryForeground,
    Color? muted,
    Color? mutedForeground,
    Color? error,
    Color? card,
    Color? border,
  }) =>
      AppPalette(
        brightness: brightness ?? this.brightness,
        barrier: barrier ?? this.barrier,
        background: background ?? this.background,
        foreground: foreground ?? this.foreground,
        primary: primary ?? this.primary,
        primaryForeground: primaryForeground ?? this.primaryForeground,
        secondary: secondary ?? this.secondary,
        secondaryForeground: secondaryForeground ?? this.secondaryForeground,
        muted: muted ?? this.muted,
        mutedForeground: mutedForeground ?? this.mutedForeground,
        error: error ?? this.error,
        card: card ?? this.card,
        border: border ?? this.border,
      );

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      barrier: l(barrier, other.barrier),
      background: l(background, other.background),
      foreground: l(foreground, other.foreground),
      primary: l(primary, other.primary),
      primaryForeground: l(primaryForeground, other.primaryForeground),
      secondary: l(secondary, other.secondary),
      secondaryForeground: l(secondaryForeground, other.secondaryForeground),
      muted: l(muted, other.muted),
      mutedForeground: l(mutedForeground, other.mutedForeground),
      error: l(error, other.error),
      card: l(card, other.card),
      border: l(border, other.border),
    );
  }
}

extension AppPaletteX on BuildContext {
  /// `context.appPalette` —— 比 `AppPalette.of(context)` 短，
  /// 替换 forui 时读起来一一对应。
  AppPalette get appPalette => AppPalette.of(this);
}
