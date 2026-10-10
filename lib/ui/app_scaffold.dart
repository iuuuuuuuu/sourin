// ═══════════════════════════════════════════════════════════════════════
//  外壳布局（取代 forui 的 FScaffold）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不直接用 Material 的 `Scaffold`
//
// `Scaffold` 自带 AppBar / FAB / Drawer / Snackbar 宿主 / 底部栏插槽，
// 而本项目的外壳是：一条自绘标题栏（挂在 `MaterialApp.builder`，见 shell.dart）
// + 若干页 + 一条悬浮的液态玻璃底栏（浮在**内容之上**，好让玻璃背后有海报可折射）。
// ⇒ 用 Scaffold 的话那些插槽全是摆设，却要额外付一次 `Material` 画底 + 遮罩。
//
// # 与原 forui 版的**逐项对应**（保持像素不回退）
//
// ```text
// FTheme.data + FSheets   → 无（本项目不用 forui 的 sheet 体系）
// backgroundColor         → 同名参数
// childPad: false         → 永远为 false（forui 默认 true 会给内容加左右各 12px，
//                            本项目早已显式关掉；见 shell.dart 的记录）
// resizeToAvoidBottomInset→ 同名参数
// ```

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart';

/// 页面外壳
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    required this.child,
    this.backgroundColor,
    this.header,
    this.sidebar,
    this.footer,
    this.resizeToAvoidBottomInset = true,
    super.key,
  });

  /// 主内容区
  final Widget child;

  /// 页面底色
  final Color? backgroundColor;

  final Widget? header;
  final Widget? sidebar;
  final Widget? footer;

  /// 软键盘弹出时是否让 body 避开
  final bool resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    var body = child;
    if (resizeToAvoidBottomInset) {
      final bottom = MediaQuery.viewInsetsOf(context).bottom;
      if (bottom > 0) {
        body = Padding(padding: EdgeInsets.only(bottom: bottom), child: body);
      }
    }

    Widget column = Column(
      children: [
        if (header != null) header!,
        Expanded(child: body),
        if (footer != null) footer!,
      ],
    );

    if (sidebar != null) {
      column = Row(
        children: [
          ColoredBox(color: backgroundColor ?? const Color(0xFF000000), child: sidebar!),
          Expanded(child: column),
        ],
      );
    }

    if (backgroundColor != null) {
      column = ColoredBox(color: backgroundColor!, child: column);
    }
    return column;
  }
}

/// 把一套 [ThemeData] 注入子树（取代 forui 的 `FTheme`）
///
/// ⚠️ 这一层**不是**多余的：播放页用它把浮层面板强制成深色皮肤，
///    与外层的主题无关（见 `player_page.dart`）。
class AppThemeHost extends StatelessWidget {
  const AppThemeHost({required this.data, required this.child, super.key});

  final ThemeData data;
  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(data: data, child: child);
}
