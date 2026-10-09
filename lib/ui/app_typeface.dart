// ═══════════════════════════════════════════════════════════════════════
//  AppTypeface —— 字号阶梯与字族（取代 forui 的 FTypeface / FTypography）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么是「照抄」而不是重新设计
//
// 移除 forui 是一次**外科手术**：字号体系已经在跑了，改它等于在同一次提交里
// 引入视觉变化（而这次的目标恰恰是「视觉不回退」）。所以这里逐个照抄
// forui 的桌面档（`typography.dart` 里 `FTypeface.inherit(touch: false)`）。
//
// # 字族为什么是「系统里的中英同族」
//
// forui 的主字族是它自带的 `Inter`，而 Inter 的 cmap **零中文覆盖** ——
// 界面上每一个汉字都是引擎回退到系统字体画的。本机 zh-CN 的回退族
// `Microsoft YaHei UI` 只有 400/700 两个真实面，于是同一行里
// 「汉字满粗、数字半粗」（Owner 原话：「字体大大小小 粗细不一」）。
//
// ⇒ 把主字族换成系统里**同时覆盖中英文**的族（雅黑 / Noto Sans CJK），
//   同一个字重请求在两个文种上落到同一个面。
//
// ⚠️ 用 `defaultTargetPlatform` 而不是 `Platform.isWindows` —— 前者在
//    widget 测试里可被 `ThemeData.platform` 覆盖，后者会读真实宿主 OS。

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// 字号阶梯（桌面档；与移除 forui 前逐值一致）
@immutable
class AppTypeface {
  const AppTypeface({
    required this.fontFamily,
    required this.fontFamilyFallback,
    required this.color,
  });

  /// 桌面端字族：Windows 用雅黑，其它端用 Android 自带的思源
  factory AppTypeface.forPlatform(Brightness brightness, {TargetPlatform? platform}) {
    final p = platform ?? defaultTargetPlatform;
    final family = p == TargetPlatform.windows
        ? 'Microsoft YaHei UI'
        : 'Noto Sans CJK SC';
    return AppTypeface(
      fontFamily: family,
      // 回退链：雅黑缺生僻字时往下找。
      // ⚠️ 刻意**不加** 'Inter' —— 它没有中文，加进去只会让拉丁与汉字又分到
      //    两个字族上（正是上面要修的那个问题）。
      fontFamilyFallback: const ['Microsoft YaHei', 'Noto Sans SC', 'Segoe UI'],
      color: brightness == Brightness.dark
          ? const Color(0xFFFAFAFA)
          : const Color(0xFF0A0A0A),
    );
  }

  final String fontFamily;
  final List<String> fontFamilyFallback;
  final Color color;

  TextStyle _s(double size, double height) => TextStyle(
        color: color,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontSize: size,
        height: height,
        leadingDistribution: TextLeadingDistribution.even,
      );

  double get xs3 => 8;
  double get xs2 => 10;
  double get xs => 12;
  double get sm => 14;
  double get md => 16;
  double get lg => 18;
  double get xl => 20;
  double get xl2 => 22;
  double get xl3 => 30;
  double get xl4 => 36;
  double get xl5 => 48;

  /// 展平成 Material 的 `TextTheme`
  ///
  /// ⚠️ `height: 1` 与 `textBaseline: alphabetic` 是**必须**的（forui 转换里
  ///    同样这么写）：Material 要求第一行 height 为 1，否则按钮/输入框会溢出；
  ///    `TextField` 还要求显式 baseline。
  TextTheme toTextTheme() => TextTheme(
        displayLarge: _s(xl4, 1),
        displayMedium: _s(xl3, 1),
        displaySmall: _s(xl2, 1),
        headlineLarge: _s(xl3, 1),
        headlineMedium: _s(xl2, 1),
        headlineSmall: _s(xl, 1),
        titleLarge: _s(lg, 1),
        titleMedium: _s(md, 1),
        titleSmall: _s(sm, 1),
        labelLarge: _s(md, 1),
        labelMedium: _s(sm, 1),
        labelSmall: _s(xs, 1),
        bodyLarge: _s(md, 1),
        bodyMedium: _s(sm, 1),
        bodySmall: _s(xs, 1),
      );

  /// 主题级的默认 `TextStyle`（`DefaultTextStyle` 兜底用）
  TextStyle get bodyStyle => _s(sm, 1.25);
}
