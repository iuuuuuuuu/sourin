// ═══════════════════════════════════════════════════════════════════════
//  task-38 验收（由 fix-file-dialog 独立复核）：expired **不再自动展开**
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
// ```text
// 像次元城支持自动登录的应该**无感登录**，哔哩哔哩如果遇到片源
// 需要会员或者登录，**这时候才提示出来**（账号过期也是同理）
// ```
// ⇒ 提示的触发点应该是「**内容需要**」，不是「**会话状态**」
//
// # ★★★ 这条要复现的旧行为
// ```dart
// // 旧代码（已被 task-38 删除）
// if (_state == SessionState.expired) _open = true;   // ← 失效就自动展开
// ```
//
// # ★★★ 为什么**必须**用运行时判据（不能 grep 源码）
//
// 我核实了：那行被删的代码**仍然逐字留在注释里**：
// ```text
// lib/ui/widgets/provider_login_panel.dart L333
//   * if (_state == SessionState.expired) _open = true;
// （在 `/* ... */` 块注释里，作为"原代码是"的说明）
// ```
// ⇒ ★ 任何 `src.contains('if (_state == SessionState.expired) _open = true;')`
//   断言在**修好之后照样通过**（注释里有），在**退回旧代码后也通过**（代码里有）
//   ⇒ **完全没有分辨力**。
// ★ 这与 project 铁律 69（"断言要盯住值从哪来，不能只盯调用点长什么样"）
//   和铁律 79（"记事件本身，不要记日志"）同族，
//   但是**第三种形态**：**判据目标同时存在于"代码"与"注释"里**。
//
// # 本文件的双侧判据（Lead 指定，缺一不可）
// ```text
// ① expired 状态 ⇒ 面板**仍然收起**（`_open == false`）
//    ★ 这是 task-38 修的东西
// ② ★ 手动点「登录」**仍能展开**（`_open == true`）
//    ★ 这是"入口没丢" —— 只测 ① 的话，把入口整个删掉也能通过
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/provider_login_panel.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (context, c) => AppThemeHost(
      data: theme,
      child: c ?? const SizedBox(),
    ),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// 读面板的 `_open`（用私有字段不可直接访问 ⇒ 从 UI 反推）
///
/// ★ 为什么从 UI 反推而不是读私有字段：
/// ```text
/// `_open` 决定两件**可观测**的事：
///   ① 按钮文案：`_open ? '收起' : '登录'`
///   ② 展开区是否存在（`if (_open && !loggedIn) ...`，里面有用户名输入框）
/// ```
/// ★ 从 UI 反推是**同源**的（用户看到的就是这个），
///   而 `find.byType(TextField)` 更是**行为级**判据（真的画出来了吗）。
bool _isExpanded(WidgetTester tester) =>
    find.text('收起').evaluate().isNotEmpty;

void main() {
  group('task-38 ★ 设置页登录面板：expired 不自动展开（运行时判据）', () {
    testWidgets('★★★ 判据①：`expired` ⇒ 面板**仍然收起**（可达判据）',
        (tester) async {
      /*
       * ★★★ 这条判据的前世今生（很重要，不要删）
       *
       * 我第一版写的是"初始收起 + 入口在"，没有传 override。
       * 红度验证时我把旧代码塞回 `_load()`：
       * ```dart
       * if (_state == SessionState.expired) _open = true;
       * ```
       * ⇒ 测试**仍然全绿**！
       *
       * 根因（实测查清）：无核心环境下
       * ```text
       * providerSessionStateWire 抛 → catchError → st = null
       *   ⇒ _state = (s != null) ? active : **notRequired**
       *   ⇒ 永远到不了 `expired`
       *   ⇒ 注入的 `if (_state == expired) ...` **永不触发**
       * ```
       * ⇒ ★★ 那是**空断言**：不是靠"逻辑被删了"通过，
       *   而是靠"**那个状态根本不可达**"通过。
       *
       * ⇒ 修法：给面板加了 `debugSessionStateOverride`
       *   （`@visibleForTesting`，非 null 时**短路 FFI**）。
       *   现在 `expired` **可达**了 ⇒ 这条判据才真有分辨力。
       *
       * ★ 一般教训（已写进铁律 83）：
       *   **被测状态不可达时，判据会假绿** ——
       *   注入回归也不变红，因为回归的**前提条件同样达不到**。
       */
      await tester.pumpWidget(_host(const ProviderLoginPanel(
        providerId: 'cycani',
        providerName: '次元城',
        caps: Capabilities(loginRequired: true, loginSupported: true),
        debugSessionStateOverride: SessionState.expired,
      )));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 600));
      _claim(tester);

      /*
       * ★ 前置核对：确认 override **真的生效**（否则下面又是空断言）
       *
       * ⚠️ 我第一版断言的是"登录已失效"——**错了**（实测距红）。
       * 用 `.probe/probe_tests/zz_t38_dump_test.dart` 把真实文案 dump 出来才看清：
       * ```text
       * DUMP38| "需要登录"          ← ★ 实际渲染的
       * DUMP38| "登录"
       * DUMP38| "该源需要登录后才能播放"
       * DUMP38| TextField 数 = 0
       * ```
       * 原因（设计如此，不是 bug）：`_describe` L519
       * ```text
       * `_caps.loginRequired && _session == null` → 「需要登录」（引导第一次登录）
       * 有会话但已失效             → 「登录已失效」（说清发生了什么）
       * ```
       * ⇒ 本测试只传了 override（**没有会话**）⇒ 按设计就应该是「需要登录」。
       * ★ 教训：**断言文案前先 dump 真实值**，不要根据"应该是"推。
       *   （我若不 dump 就会去改产品代码来迁就测试 —— 那是本末倒置。）
       */
      expect(find.text('需要登录'), findsWidgets,
          reason: '★ 前置：override=expired 且无会话 ⇒ 按设计应显示「需要登录」\n'
              '  若这条失败 ⇒ override 没生效 ⇒ 下面的断言又是空的');

      /*
       * ★★ 关键：证明 override **真的短路了 FFI**（不仅仅是“没报错”）
       *
       * 在无核心环境下，若不短路 ⇒ `providerSessionStateWire` 抛
       * ⇒ `_state` 变成 `notRequired` ⇒ 提示文案会是 `notRequired` 那一套。
       * ★ 而 `notRequired` 的文案与 `expired` **不同** ⇒ 断言文案就能区分两者。
       */
      expect(find.text('该源需要登录后才能播放'), findsWidgets,
          reason: '★ 这是 `expired` + `loginRequired` 的提示 —— '
              '若 override 没生效（走了 catchError）就不会是这句');

      // ★★★ 真判据：expired 也**不自动展开**
      expect(_isExpanded(tester), isFalse,
          reason: '★★★ `expired` 时面板必须**仍然收起**。\n'
              '  旧代码是 `if (_state == SessionState.expired) _open = true;`\n'
              '  ⇒ 若这条失败，说明那行又回来了（task-38 被退回）');

      // ★ 但入口仍在（"不自动展开" ≠ "不能展开"）
      expect(find.text('登录'), findsOneWidget,
          reason: '★ 入口必须仍在（提供入口 ≠ 主动打扰）');
    });

    testWidgets('★★★ 判据②：手动点「登录」**仍能展开**（入口没丢）', (tester) async {
      await tester.pumpWidget(_host(const ProviderLoginPanel(
        providerId: 'cycani',
        providerName: '次元城',
        caps: Capabilities(loginRequired: true, loginSupported: true),
        /*
         * ★ 补 `debugSessionStateOverride`（同伴建议，Lead 采纳）
         *
         * # 为什么补（以下是我**实测**的结论，不是照搬）
         *
         * 不传 override 时，`_load()` 里的 FFI `await` 在无核心环境
         * 走 `catchError` → `_state = notRequired`。面板**仍会渲染**
         * （因为本测试**传了 `caps:`** → 跳过 `listProviders()`）。
         *
         * 但 `notRequired` 并**不代表**真实场景（真实场景是有会话/已失效），
         * 而且它靠的是"异常被吞掉"——那是**环境偶然**，不是我想测的状态。
         * ⇒ 传 `expired` 让**前提可说明、可复现**，不再依赖"无核心刚好抛异常"。
         *
         * ★ 而且这里传 `expired` **更贴近真实**：用户点「登录」
         *   通常就是因为登录态出了问题。
         */
        debugSessionStateOverride: SessionState.expired,
      )));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 600));
      _claim(tester);

      /*
       * ★★ 自证断言（铁律 85：任何 0/不存在的断言必须先证明对象存在）
       *
       * ⚠️ 不加这条的话下面 `_isExpanded(tester) == false` 有**三种**成立方式：
       * ```text
       * ① 合规的 0     —— 确实没展开（我们要的）
       * ② 没测到的 0   —— 判据不可达
       * ③ 面板没渲染的 0 —— 连被测对象都不存在
       * ```
       * ⇒ 先证明「登录」按钮**存在** ⇒ 上面的 0 才只能是 ①。
       */
      expect(find.text('登录'), findsOneWidget,
          reason: '★ 自证：面板必须**真的渲染了**（有「登录」按钮）。\n'
              '  若这条失败 ⇒ 面板没渲某（如 `_loading` 卡住）⇒ '
              '下面的"未展开"是废话');

      expect(_isExpanded(tester), isFalse, reason: '前置：初始收起');

      // ★★★ 手动点击 —— 这条证明"入口没丢"
      await tester.tap(find.text('登录'));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 300));
      _claim(tester);

      expect(_isExpanded(tester), isTrue,
          reason: '★★★ 点「登录」必须**能展开**（`_open = !_open`）。\n'
              '  若这里失败 ⇒ 有人把"不自动展开"改成了"不能展开" ⇒ '
              '用户**找不到地方登录**（那是比原 bug 更严重的问题）');

      // ★ 展开区里的输入框真的画出来了（行为级证据，不只是文案变了）
      expect(find.byType(TextField), findsWidgets,
          reason: '★ 展开后必须出现输入框（用户名/密码）—— '
              '这是"真的展开了"而不是"文案变成收起"');
    });

    testWidgets('★★ 判据③：`defaultOpen: true` 仍然生效（失败页弹窗那条路径没坏）',
        (tester) async {
      /*
       * ★ 为什么这条也要测
       *
       * task-38 的改动是"**不自动展开**"，但 `defaultOpen` 是**显式请求展开**
       * （播放失败页的弹窗传 `true` —— 那时用户**确实**要处理登录）。
       * ⇒ 若有人分不清这两者，顺手把 `defaultOpen` 也弄没，
       *   那么"播放失败 → 提示登录"这条路径就断了。
       * ★ 又要**双侧**：不自动展开 ✓ **同时** 显式请求仍生效 ✓
       */
      await tester.pumpWidget(_host(const ProviderLoginPanel(
        providerId: 'bilibili',
        providerName: '哔哩哔哩',
        defaultOpen: true,
        caps: Capabilities(loginRequired: true, loginSupported: true),
        /*
         * ★ 同判据②：补 override 让前提可说明。
         *
         * 这条模拟的是「**播放失败 → 弹出登录**」那条路径：
         * 用户在那一刻**确实**要处理登录 ⇒ 弹窗传 `defaultOpen: true`。
         * 而他之所以看到弹窗，通常就是因为会话**已失效**。
         * ⇒ 传 `expired` 比 notRequired **更贴近该场景**。
         */
        debugSessionStateOverride: SessionState.expired,
      )));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 600));
      _claim(tester);

      /*
       * ★ 自证（铁律 85）：这条断言的是"展开了"（非 0），
       *   但仍然要先证明面板渲染了 ——
       *   否则"展开了"可能来自**错的面板**或残留状态。
       */
      expect(find.text('登录'), findsOneWidget,
          reason: '★ 自证：面板必须真的渲染了（有「登录」/「收起」按钮）');

      expect(_isExpanded(tester), isTrue,
          reason: '★★ `defaultOpen: true`（失败页弹窗传的）必须**仍然展开**。\n'
              '  它表达的是"用户此刻确实要处理登录"，与"自动展开"是两回事');
    });

    testWidgets('★★★ 判据①（子路径覆盖）：expired 的**三条子路径**全都不自动展开', (tester) async {
      /*
       * ★ owner 建议①②：`expired` 有**三条**走法（文案不同）
       * ⇒ 只测一条只覆盖一半。本测试**三条全走**。
       *
       * # 三条子路径（用 `.probe/probe_tests/zz_t38_subpaths_test.dart` **dump 出来的真实文案**）
       * ```text
       * [1] loginRequired=true,  canAutoLogin=false
       *       ⇒ 「需要登录」+ 「该源需要登录后才能播放」
       *          ← 因为 `_caps.loginRequired && _session == null` 优先命中
       * [2] loginRequired=false, canAutoLogin=true
       *       ⇒ 「登录已失效」+ 「正在自动重新登录，直接播放即可恢复」
       * [3] loginRequired=false, canAutoLogin=false
       *       ⇒ 「登录已失效」+ 「需重新登录（可能需要验证码）」
       * ```
       *
       * # ★★ 为什么**不需要** owner 建议的 `debugSessionOverride`
       * ```text
       * 分支条件是 `_caps.loginRequired && _session == null`，
       * 而 `loginRequired` **本来就是构造参数**（通过 `caps:` 传）。
       * ⇒ 只要传 `loginRequired: false` + `loginSupported: true`
       *   （后者保住 `showLoginEntry`）就能走到 `expiredHintFor` 的两个分支。
       * ⇒ ★ α）已经足够；β）**少改别人的文件**（风险更低）。
       * ```
       */
      final cases = <({String tag, Capabilities caps, String expectText})>[
        (
          tag: 'sub1',
          caps: const Capabilities(loginRequired: true, loginSupported: true),
          expectText: '该源需要登录后才能播放',
        ),
        (
          tag: 'sub2',
          caps: const Capabilities(loginSupported: true, canAutoLogin: true),
          expectText: '正在自动重新登录',
        ),
        (
          tag: 'sub3',
          caps: const Capabilities(loginSupported: true, canAutoLogin: false),
          expectText: '需重新登录',
        ),
      ];

      for (final c in cases) {
        /*
         * ★★ 必须给**唯一 key** —— 否则 Flutter **复用** Element，
         *   `initState` 不再跑 ⇒ `_caps` 停在第一个值 ⇒ 后两个配置**根本没生效**。
         *   （我在 `.probe` dump 时重踩了这个坑：三次输出完全相同）
         *   ⇒ 与铁律 83 同族：**被测配置不可达 ⇒ 判据空转**。
         */
        await tester.pumpWidget(_host(ProviderLoginPanel(
          key: ValueKey<String>(c.tag),
          providerId: 'p',
          providerName: 'P',
          caps: c.caps,
          debugSessionStateOverride: SessionState.expired,
        )));
        await tester.pump();
        _claim(tester);
        await tester.pump(const Duration(milliseconds: 500));
        _claim(tester);

        // ★★ 自证断言（铁律 78）：先证明"面板真的渲染了 + 状态真的到了"
        expect(find.text('登录'), findsOneWidget,
            reason: '自证[$c.tag]：面板必须真的渲染了（否则下面的"不展开"又是空的）');
        expect(find.textContaining(c.expectText), findsWidgets,
            reason: '自证[$c.tag]：override 必须真的生效 —— '
                '应出现文案"\${c.expectText}"。\n'
                '  若这条失败 ⇒ 配置没生效 ⇒ 下面的断言是空的');

        // ★★★ 真判据：这一条子路径也**不自动展开**
        expect(_isExpanded(tester), isFalse,
            reason: '★★★ [$c.tag] `expired`（\${c.caps.loginRequired ? "loginRequired" : "canAutoLogin=\${c.caps.canAutoLogin}"}）'
                '时面板必须**仍然收起**');
      }
    });

    testWidgets('★★ 判据④：`showLoginEntry == false` ⇒ 面板**自己整个不显示**',
        (tester) async {
      /*
       * ★ 这条覆盖 `_load` 里的早退分支（L285-290）：
       * ```dart
       * if (!_caps.showLoginEntry) { setState(() => _loading = false); return; }
       * ```
       * ⇒ 不需要登录的源，面板**完全不该出现**。
       */
      await tester.pumpWidget(_host(const ProviderLoginPanel(
        providerId: 'demo',
        providerName: '演示源',
        caps: Capabilities(), // 两个能力位都 false ⇒ showLoginEntry == false
      )));
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 600));
      _claim(tester);

      expect(find.text('登录'), findsNothing,
          reason: '★ 不需要登录的源 ⇒ 不该有「登录」按钮');
      expect(find.text('收起'), findsNothing, reason: '也不该是展开态');
    });
  });
}
