// ═══════════════════════════════════════════════════════════════════════
//  task-38 我自己复核：`_open` 的三条行为 + 一个"面板不渲染"的根因证明
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么我要自己写一遍（不假定别人的测试写错了）
//
// 另一个代理的 `t38_login_autosopen_test.dart` 有两条在红：
// ```text
// 判据②：手动点「登录」仍能展开      → tap 找不到 '登录'
// 判据③：defaultOpen: true 仍生效    → _isExpanded == false（期望 true）
// ```
// 而这两条压的正是**我改的那段**（`_open` 的初始化与切换）。
// ⇒ 先独立复现，再下结论。
//
// # 独立复现的结论：**面板整块都没渲染**（不是展开逻辑错）
//
// 实测输出：
// ```text
// defaultOpen=true  TextField = 0
// 按钮文案: 收起=0 登录=0        ← ★★ 一个按钮都没有
// ```
// 根因（下面第 ① 组静态断言钉住）：`_load()` 在**没有真核心**的单元测试里
// 会 `await` 一个**永不完成**的 FFI 调用 ⇒ `_loading` 永远是 true
// ⇒ `build()` 第一条判断 `if (_loading) return Text('登录状态读取中…')`
//   **把整块面板替换掉了**。
//
// ⚠️ `_load()` 里**有**一个短路开关 `debugSessionStateOverride`：
//    非 null 时直接 `_loading = false; return;`。
//    他那两条红的用例**没传**它（5 个用例里只有 3 个传了）。
// ⇒ 那两条红**要修的是测试**（补 override），不是产品代码。
//
// # ★ 判据设计：不依赖按钮文案
//
// ```text
// ❌ `find.text('收起')` —— 依赖 `_open ? '收起' : '登录'` 的文案，
//                          文案一改测试就假红（我在 task-38 里刚踩过文本判据的坑）
// ✅ `find.byType(TextField)` —— 表单展开才有输入框（**行为**判据）
//    并配一条"被测对象存在"的自证断言（按钮数 > 0），
//    否则 `TextField == 0` 分不清"没展开"和"面板没渲染"
// ```
// ⚠️ 那正是本项目第 5/6 次假绿的形态：**"0" 有三种来源**（合规 / 判据不可达 /
//    被测对象不存在），断言本身区分不了。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/provider_login_panel.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

Widget host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (context, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// 状态行右侧那个切换按钮（用 widget 判定，**不依赖文案**）
Finder switchButton() => find.byWidgetPredicate((w) =>
    w is TextButton &&
    w.child is Text &&
    const ['登录', '收起'].contains((w.child! as Text).data));

/// 按钮总数（"被测对象存在"的自证判据）
int buttonCount(WidgetTester tester) => find
    .byWidgetPredicate((w) => w is TextButton && w.child is Text)
    .evaluate()
    .length;

void main() {
  group('① 根因证明（静态）：没有真核心时 `_loading` 会永远 true', () {
    test('★★★ `build()` 在 `_loading` 时**替换掉整块面板**', () {
      /*
       * 这条用**静态断言**而不是 widget 测试，理由：
       * ```text
       * 要复现"面板没渲染"，就得让 `_load()` 真的去 await 那个 FFI ——
       * 而那个 pending 的调用会留下**未完成的回调**，
       * flutter_test 在测试结束时报 `!timersPending`（本项目已知问题，
       * 根因在 RemoteBridgeHost）。
       * ⇒ 用一个确定性的静态断言把"机制"钉住更可靠，也更快。
       * ```
       */
      final src =
          File('lib/ui/widgets/provider_login_panel.dart').readAsStringSync();

      // ① build 的第一道门是 _loading
      final buildIdx = src.indexOf('Widget build(BuildContext context)');
      expect(buildIdx > 0, isTrue, reason: '应能找到 build()');
      final loadingGate = src.indexOf('if (_loading)', buildIdx);
      expect(
        loadingGate > buildIdx,
        isTrue,
        reason: '★ `build()` 必须有 `_loading` 分支 —— 它是"整块面板被替换"的来源',
      );
      expect(
        src.substring(loadingGate, loadingGate + 220).contains('登录状态读取中'),
        isTrue,
        reason: '★ `_loading` 时渲染的是「登录状态读取中…」而不是面板正文',
      );

      // ② `_load()` 里必须有 override 注入（否则无核心时永远 loading）
      final loadIdx = src.indexOf('Future<void> _load() async {');
      expect(loadIdx > 0, isTrue, reason: '应能找到 _load()');
      final overrideIdx =
          src.indexOf('widget.debugSessionStateOverride', loadIdx);
      expect(
        overrideIdx > loadIdx,
        isTrue,
        reason: '★★★ `_load()` 里必须有 `debugSessionStateOverride` 注入 —— '
            '没有它，单元测试里那次 FFI await 永不完成 ⇒ `_loading` 永远 true '
            '⇒ 面板只渲染「读取中」⇒ 所有"找按钮/找输入框"的断言都无从谈起',
      );

      /*
       * ③ ★★ 注入必须**与真实路径共用同一个出口**（不能提前 return）
       *
       * 这是 task-38 复核抓到的**假绿**根因：
       * ```dart
       * // ❌ 旧写法：提前 return ⇒ 下面那段 setState 永不执行
       * if (override != null) {
       *   setState(() { _state = override; _loading = false; });
       *   return;                        // ← 被测代码（auto-expand 原址）到不了
       * }
       * ```
       * ⇒ 用 override 测 `expired` 时走的是短路分支，
       *   把 `if (_state == expired) _open = true;` 恢复回去**测试照样绿**（实测）。
       *
       * 现在是"只替换数据来源、共用尾部 setState"：
       * ```dart
       * final (s, st) = override != null
       *     ? (null, override.wire)
       *     : await (...FFI...);
       * ...
       * setState(() { ... });   // ★ 唯一出口，override 与真实路径都走这里
       * ```
       */
      expect(
        src.contains('override.wire'),
        isTrue,
        reason: '★★ 注入应"只替换数据来源"（`override.wire` 当 st 用）—— '
            '这样后续解析/赋值**全部共用**真实路径的代码',
      );
      // ★ 反向断言：不能有"注入分支里自己 setState 再 return"的旧写法
      final injectSeg = src.substring(overrideIdx, overrideIdx + 700);
      expect(
        RegExp(r'if \(override != null\) \{[\s\S]{0,200}?return;')
            .hasMatch(injectSeg),
        isFalse,
        reason: '★★★ 注入分支**绝不能提前 return** —— '
            '那会让尾部 setState（含被测的 `_open` 逻辑）永不执行 ⇒ 假绿。'
            '（实测：恢复 auto-expand 变异在旧写法下 GREEN，在新写法下 RED）',
      );
    });
  });

  group('② 四个行为（传 override ⇒ 走可达路径）', () {
    testWidgets('★ defaultOpen: true ⇒ 表单**立即展开**（失败页弹窗那条路径）',
        (tester) async {
      await tester.pumpWidget(host(const ProviderLoginPanel(
        providerId: 'bilibili',
        providerName: '哔哩哔哩',
        defaultOpen: true,
        caps: Capabilities(loginRequired: true, loginSupported: true),
        // ★ 关键：短路 `_load()`（否则永远停在"读取中"，见第 ① 组）
        debugSessionStateOverride: SessionState.notRequired,
      )));
      await tester.pump();
      claim(tester);
      await tester.pump(const Duration(milliseconds: 600));
      claim(tester);

      // ★ 自证：被测对象（按钮）存在 —— 否则下面的 0 分不清"没展开"和"没渲染"
      expect(buttonCount(tester), greaterThan(0),
          reason: '★ 自证断言：面板必须真的渲染出按钮。'
              '若为 0，下面那条 TextField 判断就是**空洞的**（面板没渲染）');

      expect(
        find.byType(TextField),
        findsWidgets,
        reason: '★★ `defaultOpen: true`（播放失败页弹窗传的）必须让表单**立即展开**。'
            '若失败 ⇒ "播放失败 → 提示登录"那条路径断了',
      );
    });

    testWidgets('★ defaultOpen: false ⇒ 初始**不展开**（设置页不再自动打扰）',
        (tester) async {
      await tester.pumpWidget(host(const ProviderLoginPanel(
        providerId: 'bilibili',
        providerName: '哔哩哔哩',
        defaultOpen: false,
        caps: Capabilities(loginRequired: true, loginSupported: true),
        debugSessionStateOverride: SessionState.notRequired,
      )));
      await tester.pump();
      claim(tester);
      await tester.pump(const Duration(milliseconds: 600));
      claim(tester);

      expect(buttonCount(tester), greaterThan(0),
          reason: '★ 自证断言：面板必须渲染（否则下面那条 0 是空洞的）');
      expect(find.byType(TextField), findsNothing,
          reason: '★ `defaultOpen: false`（设置页内嵌）⇒ 初始收起');
    });

    testWidgets('★★★ 点「登录」⇒ 能展开（入口没丢）', (tester) async {
      await tester.pumpWidget(host(const ProviderLoginPanel(
        providerId: 'bilibili',
        providerName: '哔哩哔哩',
        defaultOpen: false,
        caps: Capabilities(loginRequired: true, loginSupported: true),
        debugSessionStateOverride: SessionState.notRequired,
      )));
      await tester.pump();
      claim(tester);
      await tester.pump(const Duration(milliseconds: 600));
      claim(tester);

      expect(buttonCount(tester), greaterThan(0), reason: '★ 自证：面板已渲染');
      expect(find.byType(TextField), findsNothing, reason: '前置：初始收起');
      expect(switchButton(), findsWidgets,
          reason: '★ 状态行右侧必须有切换按钮（"提供入口"vs"主动打扰"的区别）');

      await tester.tap(switchButton().first);
      await tester.pump();
      claim(tester);
      await tester.pump(const Duration(milliseconds: 300));
      claim(tester);

      expect(
        find.byType(TextField),
        findsWidgets,
        reason: '★★★ 点「登录」必须**能展开** —— 若失败 ⇒ 有人把"不自动展开"'
            '改成了"不能展开" ⇒ 用户找不到地方登录（比原 bug 更严重）',
      );
    });

    testWidgets('★★★ expired 状态时**仍然收起**（= 本次修复的目标）',
        (tester) async {
      /*
       * ★ 目标状态的正向验证（用 override 让 expired 可达）：
       *   与另一个代理的判据① 同一个意思，但这里用 TextField 判（行为级）。
       */
      await tester.pumpWidget(host(const ProviderLoginPanel(
        providerId: 'cycani',
        providerName: '次元城',
        defaultOpen: false,
        caps: Capabilities(loginRequired: true, loginSupported: true),
        debugSessionStateOverride: SessionState.expired,
      )));
      await tester.pump();
      claim(tester);
      await tester.pump(const Duration(milliseconds: 600));
      claim(tester);

      expect(buttonCount(tester), greaterThan(0), reason: '★ 自证：面板已渲染');
      expect(
        find.byType(TextField),
        findsNothing,
        reason: '★★★ `expired` 时**不得**自动展开 —— 这正是用户报的问题'
            '（"明明不需要验证码就可以自动登录，还提示验证码"）。'
            '触发点应该是"内容需要"（点播失败那一刻），不是"会话状态"',
      );
    });
  });
}
