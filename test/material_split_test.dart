// ═══════════════════════════════════════════════════════════════════════
//  决定性实验：flutter/material 与 material_ui 是两个不同的 Theme
// ═══════════════════════════════════════════════════════════════════════
//
// # 背景（2026-09-23 从 TV 截图倒推出来的）
//
// TV 截图里量到的像素，**每一个都精确等于 Material 3 亮色 baseline**：
//
// ```text
// 「设置」标题   (29,27,32)   = #1D1B20  亮色 onSurface
// 「内容源」标题 (29,27,32)   = #1D1B20  亮色 onSurface
// 源名正文       (73,69,79)   = #49454F  亮色 onSurfaceVariant
// 卡片边框       (202,196,208)= #CAC4D0  亮色 outlineVariant
// 开关 on        (103,80,164) = #6750A4  亮色 primary
// 卡片底色       (76,74,77)   = #E6E0E9@0.3 over #0A0A0A  亮色 surfaceContainerHighest
// ```
//
// 而 `FTheme.neutral.dark.desktop.toApproximateMaterialTheme()` 给的是
// 深色（onSurface = #FAFAFA，18.97:1）—— 单测已经证明转换本身没错。
//
// 所以只能是：**真实 app 里 `Theme.of(context)` 根本没拿到那个主题**。
//
// # 机制
//
// forui 0.27.0 的依赖是 `material_ui: ^1.0.0` —— Flutter 把 Material
// 从 SDK 里拆出来成了独立包。于是仓库里同时存在**两套** Material：
//
// ```text
// shell.dart        → import 'package:material_ui/material_ui.dart'
//                     MaterialApp / Theme 是 material_ui 的
// lib/ui/**.dart    → import 'package:flutter/material.dart'
//                     Theme.of 找的是 flutter/material 的 _InheritedTheme
// ```
//
// 两套 `Theme` 是**不同的 InheritedWidget 类型**，互相看不见。
// `flutter/material` 的 `Theme.of` 找不到祖先就走兜底：
//
// ```dart
// return inheritedTheme?.theme.data ?? cupertinoTheme?.materialTheme
//        ?? ThemeData.fallback();   // ← 亮色
// ```
//
// 这就是「主题明明设了深色，文字却是深色」的全部原因。
//
// # 这个测试同时证明「诊断」和「修法」
//
// ```text
// ① 用 material_ui 的 MaterialApp + flutter/material 的 Theme.of
//    → 拿到亮色（复现 bug）
// ② 用 material_ui 的 MaterialApp + material_ui 的 Theme.of
//    → 拿到深色（证明「统一到 material_ui」就是修法）
// ```

import 'package:flutter/material.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' as mu;

void main() {
  final theme = FTheme.neutral.dark.desktop;

  testWidgets('① 复现：material_ui 的 MaterialApp 里，flutter/material 的 Theme.of 拿到亮色',
      (tester) async {
    fm.Brightness? brightness;
    fm.Color? onSurface;
    mu.Brightness? muBrightness;

    await tester.pumpWidget(
      mu.MaterialApp(
        theme: theme.toApproximateMaterialTheme(),
        home: fm.Builder(
          builder: (ctx) {
            // ★ 这一行就是 lib/ui/**.dart 里每一处 `Theme.of(context)` 的处境
            brightness = fm.Theme.of(ctx).colorScheme.brightness;
            onSurface = fm.Theme.of(ctx).colorScheme.onSurface;
            // 对照组：同一个 context，material_ui 的 Theme.of 是对的
            muBrightness = mu.Theme.of(ctx).colorScheme.brightness;
            return const fm.SizedBox();
          },
        ),
      ),
    );

    fm.debugPrint('=== ① 复现（页面用 flutter/material）===');
    fm.debugPrint('  fm.Theme.of().brightness  = $brightness   ← 期望 light（bug）');
    fm.debugPrint('  fm.Theme.of().onSurface   = $onSurface');
    fm.debugPrint('  mu.Theme.of().brightness  = $muBrightness   ← 期望 dark');

    expect(brightness, fm.Brightness.light,
        reason: 'flutter/material 的 Theme.of 找不到 material_ui 的 Theme 祖先，'
            '兜底成 ThemeData.fallback()（亮色）—— 这就是 bug 本身');
    expect(onSurface, const fm.Color(0xFF1D1B20),
        reason: '#1D1B20 正是 TV 截图上量到的「设置」标题像素 (29,27,32)');
    expect(muBrightness, mu.Brightness.dark);
  });

  testWidgets('② 修法：页面改用 material_ui 的 Theme.of 就拿到深色',
      (tester) async {
    mu.Brightness? brightness;
    mu.Color? onSurface;
    mu.Color? surfaceContainerHighest;

    await tester.pumpWidget(
      mu.MaterialApp(
        theme: theme.toApproximateMaterialTheme(),
        home: mu.Builder(
          builder: (ctx) {
            brightness = mu.Theme.of(ctx).colorScheme.brightness;
            onSurface = mu.Theme.of(ctx).colorScheme.onSurface;
            surfaceContainerHighest =
                mu.Theme.of(ctx).colorScheme.surfaceContainerHighest;
            return const mu.SizedBox();
          },
        ),
      ),
    );

    fm.debugPrint('=== ② 修法（页面用 material_ui）===');
    fm.debugPrint('  mu.Theme.of().brightness  = $brightness');
    fm.debugPrint('  mu.Theme.of().onSurface   = $onSurface   ← 期望 #FAFAFA');
    fm.debugPrint('  mu.Theme.of().surfaceContainerHighest = $surfaceContainerHighest');

    expect(brightness, mu.Brightness.dark);
    expect(onSurface, const mu.Color(0xFFFAFAFA),
        reason: 'forui 深色的 foreground');
  });

  testWidgets('③ 修法在 FTheme + FToaster 全套壳里依然成立', (tester) async {
    mu.Brightness? brightness;
    mu.Color? onSurface;

    await tester.pumpWidget(
      mu.MaterialApp(
        theme: theme.toApproximateMaterialTheme(),
        // 与 shell.dart 的 builder 逐字一致
        builder: (context, child) => FTheme(
          data: theme,
          child: FToaster(child: child ?? const mu.SizedBox()),
        ),
        home: mu.Builder(
          builder: (ctx) {
            brightness = mu.Theme.of(ctx).colorScheme.brightness;
            onSurface = mu.Theme.of(ctx).colorScheme.onSurface;
            return const mu.SizedBox();
          },
        ),
      ),
    );

    fm.debugPrint('=== ③ 修法在真实壳里（含 FTheme/FToaster）===');
    fm.debugPrint('  mu.Theme.of().brightness  = $brightness');
    fm.debugPrint('  mu.Theme.of().onSurface   = $onSurface');

    expect(brightness, mu.Brightness.dark,
        reason: 'FTheme/FToaster 不拦截 Material 的 Theme，应仍为深色');
    expect(onSurface, const mu.Color(0xFFFAFAFA));
  });
}
