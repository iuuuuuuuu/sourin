// ═══════════════════════════════════════════════════════════════════════
//  CR-10 回归门禁：没有 toast 时，Esc 必须还能关掉弹窗
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷（两个，同一处代码）
//
// app_toast.dart 的 ToastDismissShortcut 原来是：
//
//   Shortcuts({escape: _DismissToastIntent},
//     Actions({_DismissToastIntent: CallbackAction(onInvoke: (_) {
//       AppToaster.maybeOf(context)?.dismissTop(); … })}))
//
//  ① CallbackAction **不覆写 isEnabled** ⇒ 默认恒 true。
//     SDK 语义已核对（shortcuts.dart:922-938 ShortcutsManager.handleKeypress）：
//     只有 action.isEnabled 为真才 return action.toKeyEventResult(...)（handled），
//     否则 return KeyEventResult.ignored 让事件沿焦点链继续往上走。
//     恒 true ⇒ 一条 toast 都没有时 Esc 也被判 handled。
//
//  ② 嵌套顺序反了：ToastDismissShortcut 挂在 AppToaster 的外面，
//     而 maybeOf 用 findAncestorStateOfType<_AppToasterState>()（app_toast.dart:96-97）
//     只往父里找，找不到自己的子节点 ⇒ dismissTop() 是死代码。
//
// # 判据：真实的用户后果，不数计数器
//
// ★ 第一版我数过一个全应用 Esc 计数器，放在 MaterialApp 外面。
//   那是**假门禁**，已作废：Esc 在 MaterialApp 内部就被 WidgetsApp 的
//   defaultShortcuts（app.dart:1272/1321/1351）接走，交给 ModalRoute 在
//   routes.dart:1197-1198 装的 Actions({DismissIntent: _DismissModalAction})，
//   它 invoke → Navigator.maybePop()，根本不回到我那个计数器。
//   证据：修好代码后再跑，appWideEsc 仍然是 0（.probe/cr/zz_cr_ui_green1004.txt）。
//
// 现在直接断言后果：屏幕上有弹窗时按 Esc，弹窗必须消失；
// 有 toast 时按 Esc，toast 必须消失。
// 这条路只依赖 SDK 自己的 Esc→DismissIntent 链路，
// 不依赖我自己搭的同构 handler，因此不会被 SDK 的优先级吃掉。
//
// 判据为什么对缺陷版本成立：缺陷版本里 ToastDismissShortcut 的 Focus
// 在焦点链上比 ModalRoute 的 Actions 更靠内（它包着 child），
// 且恒 enabled ⇒ 抢在 _DismissModalAction 之前 handled ⇒ 弹窗关不掉。
//
// ★ 用 find 判 pop 是否发生，不用 showDialog 返回值：
//   缺陷版本下返回值也是 null，无法区分被吃掉还是真关了。

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/app_toast.dart';

void main() {
  Widget app(Widget home) => MaterialApp(
    debugShowCheckedModeBanner: false,
    builder: (context, child) => ToastHost(child: child ?? const SizedBox()),
    home: home,
  );

  const plainHome = Scaffold(
    body: SizedBox.expand(
      child: Focus(autofocus: true, child: SizedBox()),
    ),
  );

  /// 焦点必须落在对话框那一层，否则 Esc 先被别的 Focus 接走。
  Widget hostWithDialog() => Builder(
    builder: (ctx) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showDialog<void>(
          context: ctx,
          builder: (dialogCtx) => AlertDialog(
            content: const Text('弹窗内容'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).maybePop(),
                child: const Text('好'),
              ),
            ],
          ),
        );
      });
      return plainHome;
    },
  );

  Widget hostWithToast() => Builder(
    builder: (ctx) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => showAppToast(ctx, '第一条'),
      );
      return plainHome;
    },
  );

  /// 排掉 AppToaster 的 100ms 心跳定时器（与判据无关，只是收尾干净）。
  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(seconds: 3));
  }

  testWidgets('★ 有弹窗且没有 toast 时 Esc 必须能关掉弹窗', (t) async {
    await t.pumpWidget(app(hostWithDialog()));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    expect(find.text('弹窗内容'), findsOneWidget,
        reason: '前置条件：弹窗在场');
    expect(find.text('第一条'), findsNothing,
        reason: '前置条件：本例没有 toast');

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    expect(
      find.text('弹窗内容'),
      findsNothing,
      reason: '★ 没有 toast 时 Esc 竟关不掉弹窗 —— ToastDismissShortcut 的 CallbackAction 恒 enabled，把 Esc 吃在自己这一层，事件不再沿焦点链往上走，全应用的 Esc→DismissIntent 彻底失效。',
    );

    await settle(t);
  });

  testWidgets('★ 有 toast 时 Esc 关掉最后一条 toast', (t) async {
    await t.pumpWidget(app(hostWithToast()));
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));

    expect(find.text('第一条'), findsOneWidget,
        reason: '前置条件：toast 在场');

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();

    expect(
      find.text('第一条'),
      findsNothing,
      reason: '★ 按 Esc 没关掉 toast —— 缺陷版本里 Shortcuts 挂在 AppToaster 外面，findAncestorStateOfType<_AppToasterState> 找不到子节点的 state ⇒ dismissTop 是死代码',
    );

    await settle(t);
  });

  testWidgets('★ 没有 toast 时按 Esc 不得凭空冒出 toast', (t) async {
    await t.pumpWidget(app(plainHome));
    await t.pump();

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    expect(find.text('第一条'), findsNothing,
        reason: 'Esc 只该 dismiss，不该 show');

    await settle(t);
  });
}
