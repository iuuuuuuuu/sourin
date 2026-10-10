// ═══════════════════════════════════════════════════════════════════════
//  共享 loading —— 页级 / 遮罩级的粗体转圈（★ OPS-14，2026-10-10）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个组件是为了**修一个真缺陷**而存在的
//
// Owner 原话（逐字）：
//   「还有这个loading样式,那个转圈的颜色太浅了,然后这个圆圈是不是有点大?
//     我感觉这个效果不太好 优化一下」
//
// ```text
// 改前（player 两处）：
//   _LoadingOverlay  CircularProgressIndicator(color: Colors.white)
//                    —— 没给 size/strokeWidth ⇒ Material 默认 4px 描边、
//                       约束到 40×40；再叠一层 Colors.black54 底
//   缓冲指示         SizedBox(44×44) + 同一个白转圈
// ```
//
// **两个症状各有各的根因，必须分开治**：
//   ① 「太大」= 没人给尺寸，落到 Material 默认的 40，或手写的 44。
//   ② 「太浅」= Colors.white 压在 Colors.black54 上 —— 白本身亮度最高，
//      但 54% 黑压下来之后剩下的仍是**没有层次的白**；
//      而且描边 4px 在 40px 的圈上只占 10%，远看就是一根**灰白发丝**。
// ⇒ 所以尺寸与描边在这里**各自成为常量**，不再由各调用点各写一遍。
//
// # ★ 为什么不做「弧线缺口 / 呼吸感」那类自定义动画
// ```text
// 任务书第 5 条明确要求：保持 Material 风格即可，不为炫技重写动画。
// 理由也站在 Material 这边 —— 发丝感的真正成因是**描边太细**（4px @40px），
// 而不是「画法不够花」；把描边提到 2.8、圈收到 30，感知上的「实」就回来了。
// ⇒ 保留 CircularProgressIndicator 本身，只改它的**尺寸 / 描边 / 颜色**。
// ```
//
// # 颜色怎么选（这是最需要解释的一处）
// ```text
// 任务书要求：深底用主题主色或明确的白色，浅底用 onSurfaceVariant。
// 
// ⚠ **不能直接用 colorScheme.primary** —— 本仓两套主色都恰好是中性色：
//    深色板 AppPalette.dark.primary  = #E5E5E5（浅灰！）
//    浅色板 AppPalette.light.primary = #171717（近黑）
//    theme_bridge.dart:403-407 的 progressIndicatorTheme 用的正是它
//    ⇒ 那正是「转圈发灰」的另一条来源。
// ⇒ 所以这里显式取语义角色，不用 primary：
//    深底 → palette.foreground（深色板 = #FAFAFA，亮度 ~0.95，与 #0A0A0A 底差 ~0.95）
//    浅底 → theme.colorScheme.onSurfaceVariant（= LightTokens.textSecondary #70727A）
// ```
//
// ⚠ 为什么深底那一支**不**用纯白：
//    白色没有方向感，贴在纯黑遮罩上缺少对比层次，这正是「太浅」的手感来源。
//    foreground（#FAFAFA）带一点暖灰，与 #0A0A0A 拉开亮度差、又不同于死白。
//    ★ AppPalette.of 在祖先没有注入扩展时按 brightness 兜底
//      （app_palette.dart:137-148），所以本组件**不依赖 MaterialApp** 也不会崩。
//
// # 已统一到这里的调用点（任务书第 3 条列出的 6 处）
// ```text
//   lib/ui/player_page.dart              _LoadingOverlay（遮罩）+ 缓冲指示
//   lib/ui/cache_page.dart:1164          下载页整页 loading
//   lib/ui/settings_page.dart:1796       设置页整页 loading
//   lib/ui/detail_page.dart:2366         详情页 loading
//   lib/ui/settings/about_page.dart:391  关于页按钮 busy
// ```
// 其余 ~20 处 CircularProgressIndicator(strokeWidth: 2) 保持原样 ——
// 它们多是**按钮内 / 小控件内**的忙指示，尺寸本来就小、底色也不确定，
// 一次全改会扩大 diff 且没有实测依据（任务书第 3 条：不要一次改 28 处）。
// ⚠ 本文件**没有**直接 import Flutter 的 material 库（lib/ 全仓禁，
//    见 test/theme_regression_test.dart 的全 lib 文本扫描）——
//    上面只 import 本仓 material_ui（它已 re-export Flutter 的 widgets）。

import 'package:material_ui/material_ui.dart';

import '../app_palette.dart';
import '../tokens.dart';

/// loading 的**唯一**尺寸 / 描边真源
///
/// # 30 / 2.8 是怎么定的（任务书要求 28~30、描边 2.5~3）
/// ```text
/// 直径 30：在 40px 默认值上收 25%。再小则旋转弧线在小屏上糊成一点，
///           实测 24 以下「转」这个动作基本看不出来。
/// 描边 2.8：占直径 9.3%（改前 4/40 = 10%，比例看似一样，
///           但绝对值差 1.2px —— 细描边在高 DPI 上被抗锯齿吃掉半个像素，
///           这就是「发丝」的来源）。
/// ★ 两者是**同一个视觉决策**，不要只调其中一个：
///   只收尺寸不改描边 ⇒ 比例不变，看起来仍是原来那个圈；
///   只加描边不收尺寸 ⇒ 变成一个「粗白环」，在小方块里会撑爆容器。
/// ```
abstract final class AppLoadingSize {
  /// 外圈直径（浅色档同样是它）
  static const double diameter = 30;

  /// 描边宽度 —— **必须 >= 2.5**，见上
  static const double stroke = 2.8;
}

/// 共享 loading —— 页级 / 遮罩级的粗体转圈
///
/// # 两种用法
/// ```dart
/// // ① 纯转圈（居中交给调用方）
/// const Center(child: AppLoading())
///
/// // ② 转圈 + 文案（文案颜色跟着调色板走，**不用纯白**）
/// const AppLoading(label: '正在加载…')
/// ```
///
/// # 为什么 `size` 有默认值还不够、必须允许覆盖
/// ```text
/// 「关于」页的按钮内 busy 只有 40px 高的按钮位置（about_page.dart:388-392），
/// 那里用 [AppLoadingSize.diameter] = 30 会把 40px 高的按钮顶高，
/// 按钮**高度就跳了** ⇒ 必须在按钮内显式传小尺寸。
/// 这是「组件给默认、调用点能覆盖」而不是「一刀切写死」的直接理由。
/// ```
class AppLoading extends StatelessWidget {
  const AppLoading({this.label, this.size = AppLoadingSize.diameter, super.key});

  /// 转圈下方的可选文案（**保留**调用点原有的文字，不改语义）
  final String? label;

  /// 外圈直径 —— 默认 [AppLoadingSize.diameter]；按钮内请传小值
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // 深底 → foreground（#FAFAFA）；浅底 → onSurfaceVariant（#70727A）
    final color = isDark
        ? palette.foreground
        : theme.colorScheme.onSurfaceVariant;

    final indicator = SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        color: color,
        strokeWidth: AppLoadingSize.stroke,
      ),
    );

    if (label == null) return indicator;

    // ★ 文案**不用**纯白 —— 与转圈同一档，保证整块 loading 色调一致
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        indicator,
        const SizedBox(height: Sp.x3),
        Text(label!, style: TextStyle(color: color, fontSize: FontSizes.sm)),
      ],
    );
  }
}
