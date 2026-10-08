// ═══════════════════════════════════════════════════════════════════════
//  标题栏「地板色」主题一致性测试 —— 锁死 (239,239,239) 那个 bug
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个 bug 是什么（2026-09-25 真机像素取证，用户亲自指出）
//
// 用户原话：
// > 你看这深色模式下的状态栏显示正常吗?
//
// ```text
// 深色主题下：
//   标题栏 (x=500,y=16) = (239,239,239)   ← 浅灰（错的）
//   内容区 (x=1000,y=60) = (6,6,6)         ← 深色（对的）
// ```
// 96/116 张历史截图稳定复现。
//
// # 根因：**判断**对了，**取色**还在坑里
//
// `lib/shell.dart` 的 `MaterialApp.builder` 里原来写的是：
// ```dart
// color: brightness == Brightness.light
//     ? LightTokens.bgBase
//     : FTheme.of(context).colors.background,   // ← 这一行
// ```
// `brightness` 是**自己解析**的（对），但深色分支取色走 `FTheme.of(context)`，
// 而 builder 的 `context` 在 `FTheme` **上面**（`FTheme` 注入在 builder
// 的**返回值**里）。forui 的 `FTheme.of` 找不到祖先时**不抛异常**，
// 静默兜底成 `FTheme.neutral.light.touch`（forui `src/theme/theme.dart:140`）
// —— 也就是**浅色**，`background = #FFFFFF` 纯白。
//
// 实测日志（`lib/ab2_diag_probe.dart` 探针）：
// ```text
// [AB2] == builderCtx（FTheme 外面）==
// [AB2]   Theme.of(colorScheme.brightness)=Brightness.dark   ← Material 对
// [AB2]   FTheme.of(colors.brightness)=Brightness.light      ← forui 错
// [AB2]   GlassTheme.brightnessOf=Brightness.dark            ← 玻璃对
// ```
// 于是深色下地板是**纯白**，标题栏玻璃透出白底 → `(239,239,239)`。
//
// # 为什么之前"以为修好了"
//
// 旧注释只盯着 `Theme.of`（Material 那套）的坑，换成自己解析的
// `brightness` 之后就认为完事了 —— 但同一个表达式里还有**第二个独立
// 主题系统**（forui），它的 `FTheme.of` 有**一模一样**的
// "找不到祖先 → 静默浅色"行为。两套主题系统各踩一次，
// 是同一个坑的两个实例。
//
// # 为什么必须有测试守着
//
// 这个 bug 的全部特征是「**不报错**」：
// ```text
// 编译过 ✓   analyze 0 error ✓   单测全绿 ✓   能跑起来 ✓
// → 但深色下标题栏是一条浅灰横条
// ```
// 和 `test/theme_tokens_test.dart`（底栏白药丸）、
// `test/theme_regression_test.dart`（1.16:1 对比度）是**同一类**。
//
// ⚠️ 这里做的是**静态 + 数值**断言（不渲染 widget）：
//    `MaterialApp.builder` 里那棵树构造不出来（依赖核心 FFI / 数据目录）。
//    渲染级验证由真机截图负责 —— 两者互补：
//    静态断言保证"代码里不再有会兜底成浅色的取色"，
//    截图保证"渲染出来确实一致"。

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';

/// 剥掉注释行（静态断言里做文本匹配**必须先剥注释**）
///
/// 这个坑在本项目里踩过至少四次：注释里提到某个标识符，
/// 纯文本匹配就把它当成真实代码，测试假绿/假红。
/// ⚠️ 本文件的**修复说明注释里就写了 `FTheme.of(context)`** ——
///    不剥注释的话下面那条"禁止"断言会**假红**。
String _code(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

/// 取 `lib/shell.dart` 里 `MaterialApp.builder` 那一段的**代码**（已剥注释）
///
/// # 为什么按区域切片
///
/// `shell.dart` 有 3200 行，别处也有合法的 `FTheme.of(context)`
/// （例如 `_CustomTitleBar` / `_BottomItem` / `_BottomPalette.of`）——
/// 那些都在 `FTheme` **下方**，是正确的。
/// 整文件 grep 会把它们误报成"builder 里的取色"。
///
/// 区域 = `builder: (context, child) =>` 起、到 `theme:` 那行之前。
/// 这正是"`context` 看不到 `FTheme`"的**全部**范围。
String _builderCode(String shellSrc) {
  final start = shellSrc.indexOf('builder: (context, child)');
  if (start < 0) return '';
  // 切到 `child: child` 之前的那个 `);`（即 builder 的收尾）
  final end = shellSrc.indexOf('onGenerateRoute', start);
  return _code(shellSrc.substring(start, end < 0 ? shellSrc.length : end));
}

void main() {
  late String shellSrc;
  late String builderSrc;
  late String builderCode;

  setUpAll(() {
    shellSrc = File('lib/shell.dart').readAsStringSync();
    builderSrc = _builderCode(shellSrc);
    builderCode = _code(builderSrc);
  });

  group('★ 切片前提（否则下面全是假绿）', () {
    test('真的取到了 builder 那一段', () {
      expect(builderSrc, isNotEmpty,
          reason: '取不到 `builder: (context, child)` —— shell.dart 结构变了，'
              '切片函数要跟着改（否则本文件所有断言都会假绿）');
      expect(builderSrc.contains('WindowFrame'), isTrue,
          reason: 'builder 切片应含窗口外框');
      expect(builderSrc.contains('_TitleBarHost'), isTrue,
          reason: '★ builder 切片**必须**含标题栏宿主 —— 本 bug 就在它附近');
      expect(builderSrc.contains('RemoteBridgeHost'), isTrue,
          reason: 'builder 切片应含遥控桥挂载点（与标题栏同一层）');
      // 反向：不该把文件后面别的东西切进来
      expect(builderSrc.contains('class _CustomTitleBar'), isFalse,
          reason: '切片应停在 builder 结束处，不含类定义');
    });
  });

  group('★★★ 地板色必须走「自己解析的 brightness」，不能问 FTheme', () {
    test('★★★ builder 里不得用 `FTheme.of(context)` / `Theme.of(context)` 取色', () {
      /*
       * 这是本 bug 的**唯一**判据，也是它唯一的防复发机制。
       *
       * `builder` 的 `context` 在 `FTheme` 和 `Theme` **上面** ——
       * 两个 `X.of(context)` 都会**静默**兜底成浅色（都不抛异常）：
       * ```text
       * Theme.of        → ThemeData.fallback()（Material 3 亮色）
       * FTheme.of       → FTheme.neutral.light.touch（forui 亮色）
       * ```
       * 所以这里断言的是**"在这个范围内一次都不许出现"**，
       * 而不是"用对了值"—— 因为用对值这件事无法靠文本断言保证，
       * 但"不许出现"可以。
       */
      for (final forbidden in const ['FTheme.of(context)', 'Theme.of(context)']) {
        expect(builderCode.contains(forbidden), isFalse,
            reason: '''
★★★ `MaterialApp.builder` 里出现了 `$forbidden` —— 这正是 (239,239,239) 那个 bug 的成因。

builder 的 context 在主题注入点**上面**，`$forbidden` 会**静默**兜底成浅色：
```text
MaterialApp
 ├ builder(context, child)   ← 这个 context 不是主题的子孙
 │   └ FTheme(data: theme)   ← 注入在 builder 的**返回值**里
 └ theme: materialTheme
```

【修法】用 `AppTheme.floorColor(brightness)`（`ui/app_theme.dart`）——
它只认传进来的 brightness，与 `MaterialApp.theme` **同源**：
```dart
final brightness = AppTheme.resolve(
  systemBrightness: MediaQuery.platformBrightnessOf(context),
);
// ...
color: AppTheme.floorColor(brightness),
```
''');
      }
    });

    test('★★★ 地板色必须由 `AppTheme.floorColor(brightness)` 提供', () {
      expect(builderCode.contains('AppTheme.floorColor(brightness)'), isTrue,
          reason: '★ builder 的地板色必须走 `AppTheme.floorColor(brightness)`。'
              '这是"判断与取色同源"的唯一保证 —— 只判断对、取色仍问主题系统，'
              '就会重演 (239,239,239)（判断对、取色错，所以看着像已修好）。');
    });
  });

  group('★★ floorColor 自身的三条不变量', () {
    test('★★ 深色下 = forui 深色 background（与内容区 FScaffold 同源）', () {
      /*
       * 内容区 `FScaffold` 画的是 `colors.background`
       * （forui `src/widgets/scaffold.dart:194`）——
       * 所以地板色**必须**是同一个值，否则两者必然不一致。
       */
      final dark = AppTheme.floorColor(Brightness.dark);
      expect(dark, AppTheme.themeFor(Brightness.dark).colors.background,
          reason: '深色地板色必须等于 forui 深色 background —— '
              '这正是内容区 FScaffold 画的那一层，两者必须同源');
      // forui neutralDark.background = #0A0A0A
      expect(dark, const Color(0xFF0A0A0A),
          reason: 'forui neutralDark.background 是 #0A0A0A');
    });

    test('★★★ 深色下**绝不能**是浅色（回归判据）', () {
      final dark = AppTheme.floorColor(Brightness.dark);
      /*
       * 这条是**直接**冲着这个 bug 来的：
       * 兜底成 `FTheme.neutral.light.touch` 时 background = #FFFFFF。
       * 用"亮度"而不是"等于白"来断言 —— 将来 forui 换了浅色档位
       * （比如改成 #FAFAFA）这条仍然有效。
       */
      final lum = _relativeLuminance(dark);
      expect(lum, lessThan(0.2),
          reason: '''
★★★ 深色主题的地板色是**亮的**（相对亮度 $lum）—— (239,239,239) 那个 bug 回来了。

症状：标题栏玻璃透出这块亮地板 → 浅灰横条压在深色内容上
（实测标题栏 (239,239,239) / 内容区 (6,6,6)）。

成因九成是取色走了主题系统的**静默浅色兜底**：
```text
FTheme.of(context) → FTheme.neutral.light.touch → background #FFFFFF
Theme.of(context)  → ThemeData.fallback()       → 亮色
```
修法：只认 `AppTheme.resolve(...)` 算出来的 brightness。
''');
    });

    test('★ 浅色下 = LightTokens.bgBase（**不是** forui 的纯白）', () {
      final light = AppTheme.floorColor(Brightness.light);
      expect(light, LightTokens.bgBase,
          reason: '浅色地板必须是原版 --bg-base: #eef0f6 那一档带蓝的浅灰');
      /*
       * 为什么不能图省事用 `themeFor(light).colors.background`：
       * forui `neutralLight.background` 是**纯白 #FFFFFF**，
       * 而玻璃是"半透明白叠在底色上"—— 白叠白等于没有色差，
       * 玻璃会整个消失。这条在本项目里已经踩过一次。
       */
      expect(light, isNot(const Color(0xFFFFFFFF)),
          reason: '★ 浅色地板不能是纯白 —— 白叠白会让玻璃完全消失');
      expect(light, isNot(AppTheme.themeFor(Brightness.light).colors.background),
          reason: '★ 浅色**故意**不用 forui 的 background（它是纯白）');
    });

    test('★ 深色与浅色地板必须真的不同（否则切换无效）', () {
      expect(AppTheme.floorColor(Brightness.dark),
          isNot(AppTheme.floorColor(Brightness.light)),
          reason: '两档地板色相同 = 切主题时标题栏不变，正是本 bug 的表现');
    });

    test('★ 两档地板色的明暗方向必须相反（不是"都偏暗"之类的假分支）', () {
      final dl = _relativeLuminance(AppTheme.floorColor(Brightness.dark));
      final ll = _relativeLuminance(AppTheme.floorColor(Brightness.light));
      expect(ll, greaterThan(dl),
          reason: '浅色地板必须比深色地板亮 —— 否则分支接反了');
    });
  });

  group('★ 结构不变量（防止同类坑在别处复发）', () {
    test('★ floorColor 不得读 BuildContext（结构上保证不会兜底）', () {
      /*
       * 这是这个修法的**全部要害**：签名里没有 `BuildContext`，
       * 就不可能在内部去问任何 `X.of(context)` —— 从类型上排除了
       * "拿到浅色兜底"的可能。将来有人想"顺手"加个 context 参数，
       * 这条会红。
       */
      final appThemeSrc = File('lib/ui/app_theme.dart').readAsStringSync();
      final code = _code(appThemeSrc);
      expect(code.contains('static Color floorColor(Brightness b)'), isTrue,
          reason: '★ `floorColor` 必须只收 `Brightness`，不收 `BuildContext` —— '
              '收了 context 就会有人去问主题系统，坑就回来了');
      expect(code.contains('floorColor(BuildContext'), isFalse,
          reason: '★ `floorColor` 不得收 `BuildContext`');
    });

    test('★ shell.dart 不得 import package:flutter/material.dart', () {
      // 复用 theme_tokens_test.dart 的同款断言（这里再守一道，
      // 因为本 bug 的成因正是"两套主题系统"）
      final imports = shellSrc
          .split('\n')
          .where((l) => l.trimLeft().startsWith('import '))
          .join('\n');
      expect(imports.contains("package:flutter/material.dart"), isFalse,
          reason: '★ shell.dart 必须用 package:material_ui/material_ui.dart');
      expect(imports.contains('package:material_ui/material_ui.dart'), isTrue,
          reason: '★ shell.dart 必须 import material_ui');
    });
  });
}

/// WCAG 相对亮度（用于"这颜色是不是亮的"这类断言）
///
/// 为什么不用 `Color.computeLuminance()`：那个返回的是线性化后的值，
/// 而这里要的是"肉眼看着亮不亮"的直觉判据，用 WCAG 的
/// 0.2126R + 0.7152G + 0.0722B（对 sRGB 先做 gamma 还原）更贴近
/// "会不会看起来像一条浅色横条"。
double _relativeLuminance(Color c) {
  double ch(double v) {
    v = v / 255.0;
    return v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * ch(c.r * 255) +
      0.7152 * ch(c.g * 255) +
      0.0722 * ch(c.b * 255);
}
