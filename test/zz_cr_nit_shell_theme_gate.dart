// ═══════════════════════════════════════════════════════════════════════
//  ★ CR-28：shell.dart 主题绑定门禁（共享实现）
// ═══════════════════════════════════════════════════════════════════════
//
//  # 为什么门禁要单独抽出来
//
//  CR-28 指出旧断言 `src.contains('buildMaterialTheme(')` 是**假门禁**：
//  它会命中**注释**。实测 `lib/shell.dart` 里 `buildMaterialTheme(`
//  出现 **2 次，两次都在注释里**，代码里 **0 次** —— 而旧测试**照样绿**。
//  ⇒ 它守的是注释文本，不是代码。
//
//  # 铁律 170：同一纪律只能有一个实现
//
//  断言「shell.dart 把 AppTheme.themeFor() 生成的主题传给了 MaterialApp」
//  这件事，本仓**只能有一个实现** —— 就是本文件。
//  真门禁（`test/theme_regression_test.dart`）与它的反向验证
//  （`test/zz_cr_nit_theme_gate_not_false_test.dart`）**都 import 本文件**，
//  所以「测试用的门禁」和「门禁本身」不可能分叉。
//
//  # 为什么必须剥注释
//
//  剥注释只用仓里既有的那一个实现 `test/_support/strip_comments.dart`，
//  不抄第二份（10 个实现的教训就写在那个文件头上）。

import '_support/strip_comments.dart';

/// 「AppTheme.themeFor(brightness) 的结果真的挂到了 MaterialApp.theme 上」
///
/// 只匹配**剥掉注释之后**的代码（${[stripComments] 调用在下面）。
final RegExp kShellThemeBinding = RegExp(
  r'final materialTheme = AppTheme\.themeFor\(brightness\);'
  r'[\s\S]*?MaterialApp\([\s\S]*?theme:\s*materialTheme,',
);

/// 对 [rawSource]（`lib/shell.dart` 的原始文本）判这条门禁。
///
/// ⚠️ 入参是**原始**文本，剥注释在本函数内部做 —— 调用方无从忘记剥。
bool shellThemeBindingHasMatch(String rawSource) =>
    kShellThemeBinding.hasMatch(stripComments(rawSource));

/// 剥掉注释后的**真实代码**行里，出现裸 `toApproximateMaterialTheme()` 的行。
///
/// ⚠️ 旧实现是「按行首是否 `//` / `*` 粗筛」—— 那样行尾注释与
///    块注释里的代码都漏网。这里一律走 [stripComments]。
List<String> bareApproximateMaterialThemeLines(String rawSource) =>
    stripComments(rawSource)
        .split('\n')
        .where((l) => l.contains('toApproximateMaterialTheme()'))
        .toList();
