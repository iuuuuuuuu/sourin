// ═══════════════════════════════════════════════════════════════════════
//  t526 ★ 登录面板「扫码页签」—— 只在插件支持扫码时渲染
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要这条
//
// 面板在 2026-10-05 之前**没有**扫码页签，理由是「spike 的 Rust 侧没有
// provider_qr_login_start / provider_qr_login_poll」。命令层补齐后页签也补上了。
// 但补上之后有个必须守住的行为边界（原版 SettingsView.vue:3066 注释）：
// ```text
// 页签行**只在插件声明 login_qr_supported 时**渲染。
// 不支持的话只有一个页签，显示出来纯属噪音。
// ```
// ⇒ 本文件就守这一条：**支持 ⇒ 有两个页签；不支持 ⇒ 一个都没有**。
//
// # 为什么是运行时判据（不是 grep 源码）
//
// `settings_panels_test.dart` 已经用 `_code(src)` 做了静态接线断言
// （调了 providerQrLoginStart / providerQrLoginPoll、gate 在 loginQrSupported）。
// 但「静态上写了 gate」≠「运行时真的按 gate 分支」——
// 比如把 `if (_caps.loginQrSupported)` 写成恒真，静态断言照样全绿。
// ⇒ 这里用**真挂载 + 真找控件**来守。
//
// # 环境说明
//
// 单测环境没有 sourin_core.dll ⇒ `SourinCore.callAsync` 在 `_ensureBound()`
// 就抛 ⇒ `_startQrLogin()` 走 catch 分支，显示「二维码获取失败…」。
// 这**正好**是我们要的：它证明默认页签真的是**扫码**页签（否则不会去申请二维码）。
// 注意因此不会起轮询 Timer（拿不到 key ⇒ `_startQrPolling` 不被调用），
// 用例结束不会有 'A Timer is still pending'。

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/provider_login_panel.dart';

Widget _host(Widget child) {
  final theme = FTheme.neutral.dark.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (context, c) => FTheme(
      data: theme,
      child: c ?? const SizedBox(),
    ),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}


void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// 推几帧，让 postFrame 里的自动申请二维码跑完（并认领它抛出的异常）
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  _claim(tester);
  await tester.pump();
  _claim(tester);
  await tester.pump(const Duration(milliseconds: 100));
  _claim(tester);
}

void main() {
  group('t526 ★ 扫码页签的渲染条件', () {
    testWidgets('★★★ 支持扫码（loginQrSupported: true）⇒ 两个页签都在',
        (tester) async {
      await tester.pumpWidget(_host(const ProviderLoginPanel(
        providerId: 'bilibili',
        providerName: '哔哩哔哩',
        caps: Capabilities(
          loginRequired: true,
          loginSupported: true,
          loginQrSupported: true,
        ),
        defaultOpen: true,
        debugSessionStateOverride: SessionState.expired,
      )));
      await _settle(tester);

      expect(find.text('扫码登录'), findsOneWidget,
          reason: '★ 插件支持扫码 ⇒ 必须有「扫码登录」页签');
      expect(find.text('其它方式'), findsOneWidget,
          reason: '★ 有扫码页签时必须有「其它方式」兜底');
      // 页签文案**不能**用「收起」—— 那两个字被
      // test/t38_login_autosopen_test.dart 的 _isExpanded() 当作「面板展开」的判据
      expect(find.text('收起'), findsOneWidget,
          reason: '★「收起」仍然是状态行那个开关按钮的文案，没被页签污染');
    });

    testWidgets('★★★ 支持扫码时**默认落在扫码页签**（不是表单）', (tester) async {
      await tester.pumpWidget(_host(const ProviderLoginPanel(
        providerId: 'bilibili',
        providerName: '哔哩哔哩',
        caps: Capabilities(
          loginRequired: true,
          loginSupported: true,
          loginQrSupported: true,
        ),
        defaultOpen: true,
        debugSessionStateOverride: SessionState.expired,
      )));
      await _settle(tester);

      // 无核心环境 ⇒ 申请二维码失败，落到「二维码获取失败…」这条文案。
      // ★ 它能证明「默认页签 = 扫码页签」：落 form 页签的话根本不会去申请。
      expect(find.text('二维码获取失败，请重试或切换到「其它方式」。'), findsWidgets,
          reason: '★ 默认应落在扫码页签（会去申请二维码）');
      // 而表单页签的内容（账号框 / Cookie 框）此时不该渲染
      expect(find.byType(TextField), findsNothing,
          reason: '★ 扫码页签下不该同时渲染表单输入框');
    });

    testWidgets('★★★ 不支持扫码（loginQrSupported: false）⇒ 页签行**整个不渲染**',
        (tester) async {
      await tester.pumpWidget(_host(const ProviderLoginPanel(
        providerId: 'cycani',
        providerName: '次元城',
        caps: Capabilities(loginRequired: true, loginSupported: true),
        defaultOpen: true,
        debugSessionStateOverride: SessionState.expired,
      )));
      await _settle(tester);

      expect(find.text('扫码登录'), findsNothing,
          reason: '★★★ 插件不支持扫码 ⇒ 不得渲染「扫码登录」页签（纯噪音）');
      expect(find.text('其它方式'), findsNothing,
          reason: '★★★ 只有一个页签时，页签行整体不渲染');
      // 表单仍然照常可用（入口没坏）
      expect(find.byType(TextField), findsWidgets,
          reason: '★ 表单页签必须照常渲染（页签行不渲染 ≠ 表单没了）');
    });

    testWidgets('★★ 收起状态（defaultOpen: false）⇒ 页签行也不渲染', (tester) async {
      await tester.pumpWidget(_host(const ProviderLoginPanel(
        providerId: 'bilibili',
        providerName: '哔哩哔哩',
        caps: Capabilities(
          loginRequired: true,
          loginSupported: true,
          loginQrSupported: true,
        ),
        debugSessionStateOverride: SessionState.expired,
      )));
      await _settle(tester);

      // 页签是**登录区**的一部分：没展开登录区就不该有页签
      // （原版页签在登录弹窗里，弹窗没开就没有页签）
      expect(find.text('扫码登录'), findsNothing,
          reason: '★ 面板收起时不得渲染页签（提供入口 ≠ 主动打扰）');
      expect(find.text('登录'), findsOneWidget,
          reason: '★ 收起态的入口按钮仍在');
    });

    testWidgets('★★★ 点「其它方式」⇒ 真的切到表单（默认页签不得每帧重设）',
        (tester) async {
      /*
       * # 这条守的是 t526 **设备端探针**实测抓到的缺陷
       *
       * 曾经的写法把默认页签塞在 `build()` 里：
       * ```dart
       * if (_caps.loginQrSupported) _tab = 'qr';   // ❌ 在 build() 里
       * ```
       * 每次重建都会把 `_tab` 掰回 `'qr'` ⇒ 用户点「其它方式」后，
       * `_switchToForm()` 的 `setState` 触发重建，重建又把 `_tab` 设回 `'qr'`
       * ⇒ **Cookie 表单永远出不来**（探针实测：点完 TextField 数 = 0）。
       *
       * 这尤其要命，因为 B站 插件自己的 `login_hint` 写着：
       * > 若扫码不可用，也可以切到「Cookie 导入」
       * ⇒ 兜底路径点不动 = 扫码一旦不可用（无摄像头 / 风控 / 接口变更）
       *   用户就**彻底登录不了**。
       *
       * 原版（SettingsView.vue:202）是开弹窗时设一次，不是每帧设。
       * 修法：挪到 `_load()` 尾巴那个 setState 里（caps 刚解析出来的那一刻）。
       *
       * # 为什么静态断言挡不住
       *
       * `settings_panels_test.dart` 只能看到「源码里有 `_switchToForm`」；
       * 这个缺陷是**运行时**的（点了没用），必须真挂载 + 真点击才能发现。
       */
      await tester.pumpWidget(_host(const ProviderLoginPanel(
        providerId: 'bilibili',
        providerName: '哔哩哔哩',
        caps: Capabilities(
          loginRequired: true,
          loginSupported: true,
          loginQrSupported: true,
        ),
        defaultOpen: true,
        debugSessionStateOverride: SessionState.expired,
      )));
      await _settle(tester);

      // 开局在扫码页签：表单输入框不该在
      expect(find.byType(TextField), findsNothing,
          reason: '★ 默认落在扫码页签');

      // 点「其它方式」
      await tester.tap(find.text('其它方式'));
      await _settle(tester);

      expect(find.byType(TextField), findsWidgets,
          reason: '★★★ 点「其它方式」必须真的切到表单 —— '
              '默认页签若在 build() 里重设，这里会是 0 个 TextField');
      expect(find.text('扫码登录'), findsOneWidget,
          reason: '★ 页签行仍在（可以再切回去）');

      // 再切回扫码页签，双向都要能走
      await tester.tap(find.text('扫码登录'));
      await _settle(tester);
      expect(find.byType(TextField), findsNothing,
          reason: '★★★ 切回扫码页签也要生效（两个方向都不能被重设吃掉）');
    });
  });
}
