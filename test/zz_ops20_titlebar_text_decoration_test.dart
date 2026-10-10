/*
 * zz_ops20_titlebar_text_decoration_test.dart —— OPS-20 门禁
 * ═══════════════════════════════════════════════════════════════════════
 *
 * # 业主原话（逐字，m01667 第①条）
 *
 * > 「这个名字下面不要加下划线,太丑了难看」
 *
 * # 现象
 *
 * 标题栏里「源影」两个字下面有**两条黄线**（双下划线）。
 * 像素取证（.probe/ops/att_crop_128x46.png）：字形下方 y28 与 y31 两条
 * 纯黄 (246,247,89) 水平线，x34-58 ⇒ 双下划线、线距 3px。
 *
 * # 根因（两处 SDK 源码，都不是本仓库写的）
 *
 * ① material_ui 的 MaterialApp 把**自己的兜底样式**当 textStyle 传给 WidgetsApp：
 *      material_ui-1.6.0/lib/src/app.dart:45-54
 *        const TextStyle _errorTextStyle = TextStyle(
 *          color: Color(0xD0FF0000), fontFamily: 'monospace', fontSize: 48.0,
 *          fontWeight: FontWeight.w900,
 *          decoration: TextDecoration.underline,        // ← 下划线
 *          decorationColor: Color(0xFFFFFF00),          // ← 黄色
 *          decorationStyle: TextDecorationStyle.double, // ← 双线
 *          debugLabel: 'fallback style; consider putting your text in a Material',
 *        );
 *      同文件 :1034 / :1070 都是 `textStyle: _errorTextStyle,`
 * ② Flutter 把它装成**整棵树的根 DefaultTextStyle**：
 *      flutter/packages/flutter/lib/src/widgets/app.dart:1737-1738
 *        if (widget.textStyle != null) {
 *          result = DefaultTextStyle(style: widget.textStyle!, child: result);
 *        }
 * ③ 而标题栏挂在 MaterialApp.builder 里、**在 Navigator 之外**
 *    （lib/shell.dart:2087 / :2137 `_TitleBarHost(child: child ?? ...)`），
 *    这一支**没有任何 Material/Scaffold 祖先** ⇒ 最近的 DefaultTextStyle
 *    就是 ② 那个 _errorTextStyle。
 * ④ lib/shell.dart:5505 的 `Text('源影', style: TextStyle(...))` 是
 *    `inherit: true` 且**没写** decoration/decorationColor/decorationStyle
 *    ⇒ `TextStyle.merge` 逐字段 copyWith 时这三项**保持继承值**
 *    ⇒ 颜色被覆盖成 fgStrong（所以不是红的）、字号被覆盖（所以不是 48px），
 *      **但 underline + 黄 + double 全留着**。
 *
 * # 为什么必须有这条门禁
 *
 * 这个缺陷的全部特征是「不报错」：编译过 ✓ analyze 0 error ✓ 单测全绿 ✓
 * 能跑起来 ✓ —— 而且它**不在本仓库的代码里**（全仓
 * `git grep -n "TextDecorationStyle"` / `"decorationColor"` = 0 命中），
 * 是**继承**来的。所以静态文本断言抓不到它，必须**真实渲染**后
 * 从元素树里读**真正生效**的 TextStyle。
 *
 * # 为什么挂真身 SourinApp 而不是复刻一层
 *
 * 缺陷长在「MaterialApp.builder 的 child 就是 Navigator，而标题栏在它外面」
 * 这条**结构关系**上。复刻一层 builder 测的是复刻品 —— 本项目已有教训
 * （core_error_test.dart:43-47）。所以这里直接 pumpWidget(const SourinApp())。
 *
 * # 环境噪声（与 a1_tv_text_scale_test.dart 同一处理，两条都必须收掉）
 *
 * 1. 无核心（FFI 缺 dll）时 HomePage 必然抛异常 ⇒ 临时静音 FlutterError.onError
 *    并事后 takeException() 认领。⚠️ onError 必须在**测试体内**还原（addTearDown 太晚）。
 * 2. RemoteBridge 是进程级单例，它的复查定时器活得比 widget 树长 ⇒
 *    flutter_test 结束时断言 '!timersPending' 会红 ⇒ 必须显式 stop()。
 *
 * ⚠️ 本文件**不** import package:flutter/material.dart（lib/ 的禁用项；
 *    测试文件虽不在扫描范围，但同一棵树里混两套 Material 是 theme_regression_test
 *    文件头记录的 1.16:1 对比度 bug 的来源）。统一 material_ui。
 */

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/titlebar_visibility.dart';

/// 框架兜底样式的**特征值**（material_ui-1.6.0/lib/src/app.dart:45-54）
///
/// ⚠️ 断言这几个值而**不是**断言"颜色等于某个主题常量"：
///    后者会在换主题时假绿（theme_regression_test.dart 文件头的教训）。
const Color _kFallbackDecorationColor = Color(0xFFFFFF00);
const Color _kFallbackTextColor = Color(0xD0FF0000);
const double _kFallbackFontSize = 48.0;
const String _kFallbackFontFamily = 'monospace';

/// 挂**生产本体** `SourinApp`，等首帧稳定，并就地认领环境噪声。
///
/// ⚠️ `FlutterError.onError` **必须在测试体内还原**（不能用 addTearDown）：
///    flutter_test 的 binding.dart:1912 会在测试体结束时断言
///    「覆写过 onError 就必须自己还原」—— 实测报 '_pendingExceptionDetails != null'。
Future<void> _pumpRealApp(WidgetTester t) async {
  final oldOnError = FlutterError.onError;
  FlutterError.onError = (details) {}; // 静音（见文件头「环境噪声」1）

  await t.pumpWidget(const SourinApp());
  await t.pump();

  FlutterError.onError = oldOnError; // ★ 必须在 expect 之前
  while (t.takeException() != null) {} // 认领 HomePage 在无核心环境下的异常

  // ★ 收掉 RemoteBridge 的复查定时器（见文件头「环境噪声」2）。
  RemoteBridge.instance.stop();
}

/// 取某个 `Text` **真正渲染用**的那个 `TextStyle`。
///
/// # 为什么读 `RenderParagraph` 而不是读源码字符串
///
/// 这是本文件**唯一**的判据形态。派发书明令：
/// > ★ 禁止用「读源码字符串」当判据（那种门禁会被注释/换行骗过）
///
/// 而且本缺陷**根本不在仓库源码里** —— 它是继承来的，
/// 静态文本断言**永远**抓不到。只有读渲染层的样式才是真判据。
///
/// `Text` 在 build 里做的是
/// `DefaultTextStyle.of(context).style.merge(style)`（inherit 为 true 时），
/// 结果直接成为 `RichText` 的 `TextSpan.style` ⇒ 这里读到的就是屏幕上用的那个。
TextStyle _renderedStyle(WidgetTester t, String text) {
  final finder = find.text(text);
  expect(
    finder,
    findsOneWidget,
    reason: '前置条件：树里必须恰好有一个 Text($text) —— '
        '找不到/找到多个都说明测试树结构变了，下面的断言会失去意义',
  );
  final para = t.renderObject<RenderParagraph>(finder);
  final style = para.text.style;
  expect(style, isNotNull, reason: '前置条件：RenderParagraph 的 TextSpan 必须带样式');
  return style!;
}

void main() {
  setUp(() => titleBarVisible.value = true);
  tearDown(() => titleBarVisible.value = true);

  group('OPS-20 ① 真身 SourinApp：标题栏「源影」不许有下划线', () {
    testWidgets('★ 从渲染树读到的 TextStyle.decoration 必须是 TextDecoration.none',
        (t) async {
      // 前置条件：非桌面平台 _TitleBarHost 直接返回 child（shell.dart:5230），
      // 标题栏**根本不渲染** —— 那样下面的断言就成了空断言。
      expect(
        kIsDesktop,
        isTrue,
        reason: '前置条件：kIsDesktop 为假时 _TitleBarHost 不渲染标题栏'
            '（lib/shell.dart:5230 `if (!kIsDesktop) return widget.child;`），'
            '本文件所有断言都会失去意义',
      );

      await _pumpRealApp(t);

      final style = _renderedStyle(t, '源影');

      expect(
        style.decoration,
        TextDecoration.none,
        reason: '★★ 业主原话：「这个名字下面不要加下划线,太丑了难看」。\n'
            '实测到的 decoration 见上方 actual —— 它不是仓库代码写的'
            '（全仓 TextDecorationStyle / decorationColor 0 命中），'
            '是从 material_ui 的 _errorTextStyle '
            '（material_ui-1.6.0/lib/src/app.dart:45-54）经 '
            'WidgetsApp 的根 DefaultTextStyle '
            '（flutter/lib/src/widgets/app.dart:1737-1738）继承来的：'
            '标题栏在 MaterialApp.builder 里、Navigator **之外**'
            '（lib/shell.dart:2087 / :2137），这一支没有 Material 祖先。',
      );

      // 三条「兜底样式签名」—— 只补 decoration 但漏掉另两条的半吊子修法会被抓出来
      expect(
        style.decorationStyle,
        isNot(TextDecorationStyle.double),
        reason: '双下划线是兜底样式的 signature（像素取证：y28/y31 两条黄线）',
      );
      expect(
        style.decorationColor,
        isNot(_kFallbackDecorationColor),
        reason: '兜底下划线是纯黄 0xFFFFFF00（像素取证实测 (246,247,89)）',
      );
      expect(
        style.fontSize,
        isNot(_kFallbackFontSize),
        reason: '★ 兜底字号 48px：若这里读到 48.0，说明这个 Text **整体**'
            '还在继承兜底样式，而不是"只漏了 decoration"',
      );
      expect(
        style.fontFamily,
        isNot(_kFallbackFontFamily),
        reason: '★ 兜底字体 monospace：读到它就说明整支还在吃 _errorTextStyle',
      );
      expect(
        style.color,
        isNot(_kFallbackTextColor),
        reason: '兜底字色是半透明红 0xD0FF0000',
      );
    });

    testWidgets('★ 机制：标题栏那一支**自己**钉死了默认文字样式（不是只治一个 Text）',
        (t) async {
      expect(kIsDesktop, isTrue, reason: '前置条件同用例①');

      await _pumpRealApp(t);

      // 读标题文字**所在位置**真正生效的 DefaultTextStyle ——
      // 即「这一支里任何没写 decoration 的 Text 会拿到什么」。
      final ctx = t.element(find.text('源影'));
      final ambient = DefaultTextStyle.of(ctx).style;

      expect(
        ambient.decoration,
        TextDecoration.none,
        reason: '★★ 标题栏这一支的**环境**默认样式必须是显式的 '
            'TextDecoration.none。只给 Text(源影) 单独补一行 decoration '
            '是「治一个 Text」——下一个在这支里加 Text 的人会**再踩一次**'
            '（settings_sub_page.dart:17 注释里描述的那一行就是同一支）。',
      );
      expect(
        ambient.fontSize,
        isNot(_kFallbackFontSize),
        reason: '★ 环境默认字号若还是 48.0，说明这一支还在继承 _errorTextStyle',
      );
      expect(
        ambient.fontFamily,
        isNot(_kFallbackFontFamily),
        reason: '★ 环境默认字体若还是 monospace，说明这一支还在继承 _errorTextStyle',
      );
      expect(
        ambient.decorationColor,
        isNot(_kFallbackDecorationColor),
        reason: '★ 环境默认下划线色若还是纯黄，说明这一支还在继承 _errorTextStyle',
      );
      expect(
        ambient.decorationStyle,
        isNot(TextDecorationStyle.double),
        reason: '★ 环境默认下划线样式若还是 double，说明这一支还在继承 _errorTextStyle',
      );
    });
  });

  group('OPS-20 ② 反向验证：本门禁**不是**空断言', () {
    /*
     * 这一组**故意不挂生产代码**，只复刻「标题栏在 Navigator 之外、
     * 没有 Material 祖先」这一个结构关系，证明：
     *   · 兜底样式在这个环境里**真的**会挂到那种 Text 上（缺陷可复现）；
     *   · 本文件的读取器（RenderParagraph.text.style）**真的**看得见它。
     *
     * 若哪天 Flutter/material_ui 不再传 _errorTextStyle（或换成不含下划线的
     * 兜底），这条会红 —— 那是**好事**：它说明用例①的判据需要重新评估，
     * 而不是"悄悄变成恒真"。
     */
    testWidgets('★ 复刻结构：Navigator 之外的 Text 确实吃到双下划线兜底样式',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: const SizedBox(),
        builder: (context, child) => Column(
          children: [
            // ★ 与 lib/shell.dart:5505 同一个位置关系：builder 里、Navigator 之外
            const Text('源影'),
            Expanded(child: child ?? const SizedBox()),
          ],
        ),
      ));
      await t.pump();

      final style = _renderedStyle(t, '源影');

      expect(
        style.decoration,
        TextDecoration.underline,
        reason: '★ 这就是缺陷本体：material_ui 的 _errorTextStyle '
            '（app.dart:45-54）经 WidgetsApp 的根 DefaultTextStyle '
            '（flutter/lib/src/widgets/app.dart:1737-1738）落到这里。'
            '读不到它 = 用例①的读取器是瞎的，那才是真的危险',
      );
      expect(style.decorationStyle, TextDecorationStyle.double);
      expect(style.decorationColor, _kFallbackDecorationColor);
      expect(style.fontSize, _kFallbackFontSize);
      expect(style.fontFamily, _kFallbackFontFamily);
    });
  });
}
