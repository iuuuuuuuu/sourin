// ═══════════════════════════════════════════════════════════════════════
//  底栏药丸主题令牌测试 —— 锁死「深色下不能是白底白字」（bug ③）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个 bug 是什么（2026-09-24 实测确认）
//
// `lib/shell.dart` 的 `_BottomBar` 里，**选中药丸**的渐变被**硬编码**成
// 浅色那一套值：
// ```dart
// colors: [
//   Colors.white.withValues(alpha: 0.96),
//   Colors.white.withValues(alpha: 0.80),
// ],
// ```
// 而**没有任何主题分支**。于是深色主题下：
// ```text
// 白色药丸（0.96/0.80 白） + 文字色 #FAFAFA
//   → 白底白字，选中的那个 tab 几乎看不见
// ```
//
// ## 实测像素（这是"纸面问题"与"真问题"的分界）
//
// ```text
// 底栏药丸        (250,250,250)   ← 白药丸，错
// 「我的」分段控件  (59,59,59)     ← 正确的那一个
// ```
// 同一屏里两个"选中药丸"，一个 250 一个 59 —— 差 4 倍亮度，
// 一眼就能看出哪个不对。
//
// ## 原版的两套值（`src/design/` 的 CSS 变量）
//
// ```css
// /* tokens.css（深色，默认） */
// --tab-pill-bg: linear-gradient(180deg,
//                  rgb(255 255 255 / 0.19),
//                  rgb(255 255 255 / 0.10));
//
// /* theme-light.css（浅色） */
// --tab-pill-bg: linear-gradient(180deg,
//                  rgb(255 255 255 / 0.96),
//                  rgb(255 255 255 / 0.80));
// ```
// 深色那套在 `#0A0A0A` 上合成后约 `(52,52,52)` —— 与「我的」分段控件的
// `(59,59,59)` 基本一致（那正是"对齐分段控件"这个设计意图）。
//
// # 为什么必须有测试守着
//
// 这个 bug 的全部特征是「**不报错**」：
// ```text
// 编译过 ✓   analyze 0 error ✓   单测全绿 ✓   能跑起来 ✓
// → 但深色主题下白底白字，用户根本看不出选中在哪一页
// ```
// 它和 `test/theme_regression_test.dart` 里那个 1.16:1 的对比度 bug
// 是**同一类**：只有"看截图量像素"或"断言令牌本身"才能发现。
//
// ⚠️ 这里做的是**静态 + 数值**断言（不渲染 widget）：
//    `_BottomBar` 是 `shell.dart` 的私有类，测试里构造不出来。
//    渲染级验证由真机截图（`.probe/` 下的取色脚本）负责 ——
//    两者互补：静态断言保证"代码里有分支"，截图保证"分支画对了"。

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

// ═══════════════════════════════════════════════════════════════════════
//  原版的两套值（权威，抄自 `src/design/tokens.css` / `theme-light.css`）
// ═══════════════════════════════════════════════════════════════════════

/// 深色：`--tab-pill-bg: linear-gradient(180deg, white/0.19, white/0.10)`
const _darkPillTop = 0.19;
const _darkPillBottom = 0.10;

/// 浅色：`--tab-pill-bg: linear-gradient(180deg, white/0.96, white/0.80)`
const _lightPillTop = 0.96;
const _lightPillBottom = 0.80;

/// 深色底栏的底色（`FTheme.neutral.dark` 的 background = `#0A0A0A`）
const _darkBarBg = Color(0xFF0A0A0A);

/// 实测像素：深色主题下量到的**错误**值（白药丸）
const _measuredWrongPill = Color(0xFFFAFAFA);

/// 实测像素：「我的」分段控件（**正确**的那一个）
const _measuredCorrectPill = Color(0xFF3B3B3B);

/// 把 `white @ alpha` 合成到 [bg] 上
Color _over(Color bg, double alpha) => Color.fromARGB(
      255,
      (bg.r * 255 * (1 - alpha) + 255 * alpha).round(),
      (bg.g * 255 * (1 - alpha) + 255 * alpha).round(),
      (bg.b * 255 * (1 - alpha) + 255 * alpha).round(),
    );

/// 取 `shell.dart` 里**底栏那一段**的源码
///
/// 为什么按区域切片而不是整文件 grep：`shell.dart` 有 3000 行，
/// 别处也有 `Colors.white.withValues(...)`（标题栏、玻璃卡片等）。
/// 整文件匹配会把那些误报成"底栏药丸"。
///
/// 区域 = `class _BottomBar` 起、到文件末尾：
/// ```text
/// class _BottomBar          选中药丸 + 五个 tab 的容器
/// double get _tabWidth      tab 宽度（药丸位置用它算）
/// double _pillLeft          药丸左偏移
/// class _BottomItem         单个 tab（**文字/图标色在这里**）
/// class _BottomItemState
/// ```
/// ⚠️ `_BottomItem` **必须**在区域内 —— 底栏的文字色在它里面，
///    只切 `_BottomBar` 会让"文字色"那类断言在空处匹配（假绿/假红）。
///    实测踩过：`_BottomBar` 切片里 `colors.foreground` 一次都不出现。
String _bottomBarSource(String shellSrc) {
  final start = shellSrc.indexOf('class _BottomBar extends StatelessWidget');
  if (start < 0) return '';
  return shellSrc.substring(start);
}

/// 剥掉注释行（静态断言里做文本匹配**必须先剥注释**）
///
/// 这个坑在本项目里踩过至少四次：注释里提到某个标识符，
/// 纯文本匹配就把它当成真实代码，测试假绿/假红。
String _code(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

void main() {
  late String shellSrc;
  late String barSrc;
  late String barCode;

  setUpAll(() {
    shellSrc = File('lib/shell.dart').readAsStringSync();
    barSrc = _bottomBarSource(shellSrc);
    barCode = _code(barSrc);
  });

  group('③ 底栏选中药丸必须按主题分支', () {
    test('★ 切片前提：真的取到了 `_BottomBar` 及其 item 的源码', () {
      /*
       * 先证明"切片函数本身是好的" —— 否则下面的断言可能在
       * 一个空字符串上跑，全是假绿（这个项目踩过：
       * "测了但没测到真实路径"比没测更危险）。
       *
       * ⚠️ 实测踩过一次：第一版把切片停在 `class _BottomItem` 之前，
       *    结果 `colors.foreground` 一次都不出现 —— 而底栏的文字色
       *    **恰恰在 `_BottomItem` 里**。断言于是在错误的范围上跑。
       */
      expect(barSrc, isNotEmpty,
          reason: '取不到 `class _BottomBar` —— shell.dart 结构变了，'
              '切片函数要跟着改（否则本文件所有断言都会假绿）');
      expect(barSrc.contains('_tabWidth'), isTrue,
          reason: '切片应覆盖到药丸位置计算');
      expect(barSrc.contains('class _BottomItem'), isTrue,
          reason: '★ 切片**必须**含 `_BottomItem` —— 底栏的文字/图标色在它里面');
      expect(barSrc.contains('colors.foreground'), isTrue,
          reason: '★ 底栏文字色用的是主题角色 `colors.foreground`；'
              '切不到它就说明区域取错了');
      // 反向：不该把别的窗口控件切进来
      expect(barSrc.contains('class _WinButton'), isFalse,
          reason: '切片从 `_BottomBar` 开始，不该含标题栏的按钮');
    });

    test('★★★ 药丸渐变**不能**是硬编码单一值（必须按主题分支）', () {
      /*
       * ★★★ 这是 bug ③ 的核心断言。
       *
       * 判定方式：把"浅色那一对值"和"深色那一对值"都在 `_BottomBar`
       * 的代码里找一遍。**两对都必须在** —— 只有一对就说明没分支。
       *
       * ```text
       * 修之前：只有 white/0.96 + white/0.80  → 深色下白药丸
       * 修之后：两对都在，按 brightness 选
       * ```
       */
      /*
       * ⚠️ 匹配的是 `alpha: 0.96` 这种**带前缀的完整片段**，不是裸数字。
       *
       * 为什么（P3 实测发现的假绿风险）：切片现在覆盖到文件末尾，
       * 而 `_BottomItem` 里有一句**无关**的
       * ```dart
       * widget.colors.foreground.withValues(alpha: 0.10)   // 焦点态背景
       * ```
       * 如果只匹配裸串 `'0.10'`，那么只要深色药丸的**上端**
       * （`alpha: 0.19`）写进去了，`hasDarkPair` 就会被这句无关代码
       * 凑成 true —— 药丸下端哪怕仍写着 0.80 也照样绿。
       * 锚定 `alpha: ` 前缀后，两个值必须**真的**是药丸渐变的参数。
       */
      final hasLightPair =
          barCode.contains('alpha: 0.96') && barCode.contains('alpha: 0.80');
      final hasDarkPair =
          barCode.contains('alpha: 0.19') && barCode.contains('alpha: 0.10');

      expect(
        hasLightPair && hasDarkPair,
        isTrue,
        reason: '★★★ 底栏药丸的渐变**必须有两套值**（按主题分支）。\n'
            '  浅色对（0.96 / 0.80）存在: $hasLightPair\n'
            '  深色对（0.19 / 0.10）存在: $hasDarkPair\n'
            '\n'
            '【修法】`lib/shell.dart` 的 `_BottomBar.build` 里，把\n'
            '```dart\n'
            'colors: [\n'
            '  Colors.white.withValues(alpha: 0.96),\n'
            '  Colors.white.withValues(alpha: 0.80),\n'
            '],\n'
            '```\n'
            '改成按亮度取两套值，例如：\n'
            '```dart\n'
            '// 原版两套（src/design/tokens.css + theme-light.css）\n'
            'final isLight = Theme.of(context).brightness == Brightness.light;\n'
            'final pillTop = isLight ? 0.96 : 0.19;\n'
            'final pillBottom = isLight ? 0.80 : 0.10;\n'
            'colors: [\n'
            '  Colors.white.withValues(alpha: pillTop),\n'
            '  Colors.white.withValues(alpha: pillBottom),\n'
            '],\n'
            '```\n'
            '\n'
            '【为什么必须修】实测像素：深色主题下底栏药丸量到 '
            '`(250,250,250)`，而同屏「我的」分段控件是 `(59,59,59)` ——\n'
            '白药丸 + `#FAFAFA` 文字 = **白底白字**，用户看不出选中在哪一页。\n'
            '深色值合成到 `#0A0A0A` 上约 `(52,52,52)`，才与分段控件一致。\n'
            '\n'
            '⚠️ 这条**现在会红是预期的** —— 代理 L2 正在改 `shell.dart` '
            '落地这个修复。本测试的作用是把它变成"有测试守着的已知问题"。',
      );
    });

    test('★★★ 必须有亮度/主题分支（不能只换值不分主题）', () {
      /*
       * 上一条只证明"两套值都在文件里" —— 但如果两套值被写成一个
       * 永远只走其中一条的表达式，断言照样绿。
       * 所以这条要求**真的有一个按亮度分支的判据**。
       */
      final hasBranch = barCode.contains('Brightness.light') ||
          barCode.contains('Brightness.dark') ||
          RegExp(r'isLight|isDark|brightness').hasMatch(barCode);

      expect(
        hasBranch,
        isTrue,
        reason: '★★★ `_BottomBar` 里必须有按亮度（或主题）分支的判据。\n'
            '推荐 `Theme.of(context).brightness == Brightness.light` ——\n'
            '⚠️ 注意必须用 `package:material_ui/material_ui.dart` 的 `Theme`：\n'
            'Flutter 3.47 拆了 material，混用 `flutter/material` 会让\n'
            '`Theme.of` 走兜底亮色（那个 1.16:1 的 bug，见 '
            '`test/theme_regression_test.dart`）。',
      );
    });

    test('★ 文字色必须走主题角色（`colors.*`）—— 契约记录，不是 bug ③ 的核心', () {
      /*
       * # ⚠️ 这条曾经是**假红**（P3 修正，2026-09-23 实测）
       *
       * 第一版把文字色也当成"必须按亮度分支"，理由是原版 `--tab-fg`
       * 在两套主题里取值相反：
       * ```text
       * 深色 rgb(255 255 255 / .76)   浅色 rgb(16 18 26 / .62)
       * ```
       * 但那个判据在本项目里是**错的** —— 实测报：
       * ```text
       * ✗ barCode 里找不到 colors.foreground / colors.primary / …
       * ```
       * 而 `_BottomItem` **明明**就在 `_BottomBar` 后面几行、
       * 也明明写着 `widget.colors.foreground`。错的是**切片函数**：
       * `_bottomBarSource()` 切到 `\ndouble get ` 为止（即 `_tabWidth`），
       * 而 `_BottomItem` 在 `_tabWidth` **之后** —— 根本没切进来。
       *
       * 也就是说错的不是 `shell.dart`，是**判据自己**。
       * 一个测不到真实路径的断言比没有断言更危险（本项目已踩过多次
       * 假绿/假红），所以这里**降级成契约记录**：
       * 只断言"文字色来自 forui 的主题角色"，不再要求它按亮度分支。
       *
       * # 为什么 `colors.foreground` 本来就是对的
       *
       * `FColors` **自带 `brightness`**（`forui/src/theme/colors.dart:32`
       * 的 `required final Brightness brightness`）——
       * 即 `FTheme.of(context).colors` 取到的角色**已经跟随主题**了，
       * 不需要再写一次 `isLight ? 白 : 黑`。
       * 真正需要分支的只有**药丸渐变**：它是"白叠加多少"这个与主题
       * 无关的原始 alpha，forui 没有对应角色。
       */
      final usesThemeRole = barCode.contains('colors.foreground') ||
          barCode.contains('colors.primary') ||
          barCode.contains('colors.mutedForeground') ||
          barCode.contains('colors.primaryForeground') ||
          barCode.contains('widget.colors.');
      expect(
        usesThemeRole,
        isTrue,
        reason: '★ 底栏文字/图标色必须来自主题角色（`colors.*`）—— '
            '`FColors` 自带 `brightness`，取到的角色天然跟随主题。'
            '写死成常量才会出现"深色药丸 + 深色文字"那种反过来的白底白字。',
      );
    });
  });

  group('③ 数值对照（这一组**无论修没修都该绿** —— 它记录 bug 的实际数值）', () {
    test('★ 深色药丸合成后必须与「我的」分段控件基本一致', () {
      /*
       * 这是"修好之后应该长什么样"的量化目标。
       * 原版深色值合成到 `#0A0A0A` 上：
       * ```text
       * top:    white 0.19 → 0.19*255 + 0.81*10 ≈ 57
       * bottom: white 0.10 → 0.10*255 + 0.90*10 ≈ 35
       * ```
       * 而实测「我的」分段控件是 `(59,59,59)` —— 顶部那一端几乎精确吻合，
       * 这就是"对齐分段控件"这个设计意图的来源。
       */
      final top = _over(_darkBarBg, _darkPillTop);
      final bottom = _over(_darkBarBg, _darkPillBottom);

      // 顶端要接近分段控件的实测值（±8 容差，覆盖渐变/合成误差）
      final segR = (_measuredCorrectPill.r * 255).round();
      expect(
        (top.r * 255).round(),
        closeTo(segR, 8),
        reason: '深色药丸顶端合成值应≈分段控件 $segR（原版设计意图就是对齐它）',
      );

      // 深色药丸必须**远暗于**白药丸
      expect((top.r * 255).round(), lessThan(100),
          reason: '深色药丸顶端必须明显暗于白（0.19 白 ≈ 57）');
      expect((bottom.r * 255).round(), lessThan((top.r * 255).round()),
          reason: '渐变方向是"上亮下暗"（180deg）');

      // 打印出来，便于与截图对照
      debugPrint('[P2] 深色药丸合成: top=$top bottom=$bottom '
          '（分段控件实测 $_measuredCorrectPill）');
    });

    test('★ 记录 bug 的实际数值：白药丸 0.96 合成后是 (250,250,250)', () {
      /*
       * 这一条把 bug 的**症状数值**写进测试 —— 它是"这个 bug 确实存在"
       * 的证据，也是回归时的对照基准。
       *
       * 深色底栏上铺 0.96 的白：
       * ```text
       * 0.96*255 + 0.04*10 = 244.8 + 0.4 ≈ 245
       * ```
       * 实测量到 `(250,250,250)`（差几像素来自玻璃层叠加）。
       * 无论哪种，都是**接近纯白** —— 而文字是 `#FAFAFA`，
       * 于是白底白字。
       */
      final wrong = _over(_darkBarBg, _lightPillTop);
      final wrongR = (wrong.r * 255).round();

      expect(wrongR, greaterThan(230),
          reason: '浅色值铺在深色底上必然接近纯白 —— 这就是 bug ③ 的成因');
      expect(
        wrongR,
        closeTo((_measuredWrongPill.r * 255).round(), 12),
        reason: '与实测像素 $_measuredWrongPill 应当吻合（容差 12，'
            '差异来自玻璃层的叠加）',
      );

      // 白药丸与文字的对比度 —— 量化"看不见"到什么程度
      final contrast = _contrast(wrong, const Color(0xFFFAFAFA));
      debugPrint('[P2] 白药丸 $_measuredWrongPill vs 文字 #FAFAFA → '
          '对比度 ${contrast.toStringAsFixed(2)}:1');
      expect(contrast, lessThan(1.5),
          reason: '白药丸 + #FAFAFA 文字 = 对比度 <1.5:1，'
              '远低于 WCAG AA 的 4.5:1 —— 这就是"白底白字"的量化定义');
    });

    test('★ 两套值的亮度差足够大（不是"看着差不多"）', () {
      /*
       * 防一种假修法：把深色值写成 0.90/0.85 这种"稍微暗一点" ——
       * 那样代码里确实有两个值，但深色下仍然是白药丸。
       *
       * 正确的深色值合成后必须**不到浅色值的一半亮度**。
       */
      final light = (_over(_darkBarBg, _lightPillTop).r * 255);
      final dark = (_over(_darkBarBg, _darkPillTop).r * 255);
      expect(dark, lessThan(light / 3),
          reason: '深色药丸（$dark）必须远暗于浅色值铺深色底（$light）—— '
              '写成 0.85 这种"稍微暗一点"是假修');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ③-b 跨控件一致性：三个「选中药丸」各自分支，且**值本来就不一样**
  // ═════════════════════════════════════════════════════════════════════

  group('③-b 跨控件一致性（防「照抄正在出错的参照物」这个陷阱）', () {
    /*
     * # 为什么要单独一组（这是本轮最有价值的教训）
     *
     * 项目里有**三个**「选中药丸」，原版给了**两套不同的值**：
     * ```text
     * 底栏 tab 栏      --tab-pill-bg    深色 white 0.19→0.10  浅色 white 0.96→0.80（渐变）
     * 「我的」分段控件  --tab-pill-bg    同上（**共用同一套令牌**，有意为之）
     * 首页源切换条     --srcbar-pill-bg 深色 white 0.17       浅色 white 1.0（**单一值**）
     * ```
     * ⚠️ 源条**不是**渐变、也**不是** 0.96/0.80 —— 它是 `var(--surface-4)`。
     *
     * # 已经踩过的坑（真实发生过）
     *
     * `source_bar.dart` 的作者看到"源条药丸 (30,32,40) vs 底栏药丸 (249,249,249)
     * 差得远"，于是决定"照抄底栏那两行"。**观察是对的，结论是错的**：
     * ```text
     * 他照抄的那个参照物（底栏）**自己就是坏的** —— 同一个 bug ③
     * （底栏硬编码浅色值、无主题分支）
     * → 于是 bug 从一个控件被"复制"到了第二个控件
     * ```
     * ★ 教训：**修 A 的时候不要把 A 当成"正确样板"去抄 B** ——
     *   先确认 A 自己是对的（它有主题分支吗？值有出处吗？）。
     *
     * 所以这组断言要固化的认知是：**它们本来就该不同**。
     */

    late String sourceBarCode;
    late String shelfCode;

    setUpAll(() {
      sourceBarCode = _code(File('lib/ui/widgets/source_bar.dart').readAsStringSync());
      shelfCode = _code(File('lib/ui/widgets/my_shelf.dart').readAsStringSync());
    });

    /// 源条药丸（原版 `--srcbar-pill-bg: var(--surface-4)`）
    const srcDark = 0.17; // tokens.css:249  --surface-4
    const srcLight = 1.0; // theme-light.css:89 --surface-4

    test('★ 权威对照表：源条的值**本来就不等于**底栏的值（记录进测试防误读）', () {
      /*
       * 纯数据断言（永远绿）—— 它的价值是**把原版的意图写进测试**：
       * 下次有人想"统一成一套"时，会先看到这条。
       *
       * 原版 `tokens.css:333-336` 那句注释容易被误读：
       * > ⚠️ 保留独立的 `--srcbar-pill-*` 令牌名……但现在两边的**值是一样的**
       * >    —— 有意为之，保证视觉统一。
       *
       * 这里的"两边"指的是 **`--srcbar-pill-bg` 与 `--surface-4` 相同**，
       * **不是**与 `--tab-pill-bg` 相同。原版措辞歧义，已核实。
       */
      expect(srcDark, isNot(_darkPillTop),
          reason: '源条深色值 ($srcDark) 与底栏深色值 ($_darkPillTop) **不该相等**');
      expect(srcLight, isNot(_lightPillTop),
          reason: '源条浅色值 ($srcLight) 与底栏浅色值 ($_lightPillTop) **不该相等**');

      // 量化差异：源条比底栏**更实**（浅色下直接纯白，不是 0.96 的透白）
      expect(srcLight, greaterThan(_lightPillTop),
          reason: '源条浅色是**纯白实底**（--surface-4 = white/1），'
              '比底栏的 0.96 透白更实 —— 这是原版有意的区别');
      debugPrint('[P2] 药丸值对照：底栏深 ${_darkPillTop}→${_darkPillBottom} / '
          '源条深 $srcDark | 底栏浅 ${_lightPillTop}→${_lightPillBottom} / '
          '源条浅 $srcLight');
    });

    test('★「我的」分段控件是**正确的双套参照物**（原版说"应先找已有同类控件对齐"）', () {
      /*
       * 原版 `tokens.css:324-326` 的教训：
       * > **这个项目里已经有好几个"选中药丸"了**（底部 tab 栏、
       * >   「我的」分段控件）。做新的之前应该先找**已有的同类控件**对齐，
       * >   而不是自己发明一套材质。
       *
       * `my_shelf.dart` 的 `_ShelfPalette.of(isLight)` 就是那个
       * **做对了的**样板：两套值各一份，一个 `isLight` 分支全搞定。
       * 所以它是**唯一可以照抄的参照物**（底栏当时自己还是坏的）。
       */
      for (final v in ['alpha: 0.96', 'alpha: 0.80', 'alpha: 0.19', 'alpha: 0.10']) {
        expect(shelfCode.contains(v), isTrue,
            reason: '★ `_ShelfPalette` 必须两套值都在（缺 $v）—— '
                '它是这个项目里**唯一做对了**的药丸参照物，'
                '底栏/源条修复时应以它为样板');
      }
      expect(
        RegExp(r'isLight|Brightness').hasMatch(shelfCode),
        isTrue,
        reason: '★ `_ShelfPalette.of(bool isLight)` 的分支判据必须存在',
      );
    });

    test('★★★ 源条不得**照抄底栏的浅色值**（那正是把 bug 复制过去的形态）', () {
      /*
       * ★ 这条是"防重犯"的核心断言。
       *
       * 重犯的形态很具体：有人看到"两个药丸差得远"，于是把源条改成
       * ```dart
       * Colors.white.withValues(alpha: 0.96),
       * Colors.white.withValues(alpha: 0.80),
       * ```
       * —— 那两行**逐字就是底栏的 bug**（硬编码浅色值、无分支）。
       *
       * ⚠️ 修好之后源条应当：
       * ```text
       * 深色 white 0.17（单一值，不是渐变）
       * 浅色 white 1.0
       * ```
       * 所以这条断言"源条里不得出现底栏那一对值"，
       * 并且必须有它**自己的**值。
       */
      final copiedLightPair = sourceBarCode.contains('alpha: 0.96') &&
          sourceBarCode.contains('alpha: 0.80');
      expect(
        copiedLightPair,
        isFalse,
        reason: '★★★ `source_bar.dart` **不得**照抄底栏的 `0.96 / 0.80`。\n'
            '\n'
            '【为什么】那是**底栏自己的 bug**（硬编码浅色值、无主题分支）。\n'
            '原版源条用的是**另一套令牌**：\n'
            '```css\n'
            '/* tokens.css:338 */        --srcbar-pill-bg: var(--surface-4);\n'
            '/* tokens.css:249   深色 */  --surface-4: rgb(255 255 255 / 0.17);\n'
            '/* theme-light.css:89 浅色 */ --surface-4: rgb(255 255 255 / 1);\n'
            '```\n'
            '即 **深色 0.17（单一值，不是渐变）/ 浅色 1.0**。\n'
            '\n'
            '【修法】\n'
            '```dart\n'
            'final isLight = Theme.of(context).brightness == Brightness.light;\n'
            '// 原版 --srcbar-pill-bg = var(--surface-4)\n'
            'final pillAlpha = isLight ? 1.0 : 0.17;\n'
            'gradient: active\n'
            '    ? LinearGradient(colors: [\n'
            '        Colors.white.withValues(alpha: pillAlpha),\n'
            '        Colors.white.withValues(alpha: pillAlpha),\n'
            '      ])\n'
            '    : null,\n'
            '```\n'
            '⚠️ 同时 `source_bar.dart` 里那句「药丸**恒为白色**（深浅主题都是）」\n'
            '   的注释与它下面的固定深色文字 `#1E2028` 也要一起改 ——\n'
            '   修好后深色药丸是 0.17（暗的），文字色必须反过来。\n'
            '\n'
            '⚠️ 这条**现在会红是预期的** —— 已派代理修 `source_bar.dart` + '
            '`test/source_bar_test.dart:470` 那条锁死错误行为的断言。',
      );

      // 它必须有自己的值（不是删掉渐变就算修好 —— 那会丢掉"选中"信号）
      expect(
        sourceBarCode.contains('alpha: 0.17') || sourceBarCode.contains('0.17'),
        isTrue,
        reason: '★ 源条必须有**它自己的**深色值 `0.17`（原版 `--surface-4`）—— '
            '只把渐变删掉不算修好，那会丢掉"哪个源被选中"这个信号',
      );
    });
  });

  group('③ 项目铁律：不得混用两套 Material', () {
    test('★ shell.dart 不得 import package:flutter/material.dart', () {
      /*
       * Flutter 3.47 把 Material 拆成 `material_ui` 包。
       * 混用会让 `Theme.of` 走**兜底亮色** —— 那正是
       * `test/theme_regression_test.dart` 里 1.16:1 那个 bug。
       *
       * 这里重复断言一次是有意的：**本次修复要往 `_BottomBar` 里加
       * `Theme.of(context)`**，而那正是最容易顺手 import 错的地方。
       */
      expect(
        shellSrc.contains("import 'package:flutter/material.dart'"),
        isFalse,
        reason: '★ shell.dart 必须用 package:material_ui/material_ui.dart',
      );
      expect(
        shellSrc.contains("import 'package:material_ui/material_ui.dart'"),
        isTrue,
        reason: '★ 必须显式 import material_ui',
      );
    });
  });
}

/// WCAG 相对亮度
double _lum(Color c) {
  double f(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

/// WCAG 对比度
double _contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
