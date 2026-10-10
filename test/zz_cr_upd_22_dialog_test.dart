// CR-22 · 启动更新弹窗永远不出现
//
// 缺陷：_dialogContext 用 Navigator.of(rootElement, rootNavigator: true) 探测，
// 而 WidgetsBinding.instance.rootElement 是根 Element，位于 MaterialApp **之上**。
// Navigator.of 只会向上找祖先，根 Element 之上没有 Navigator ⇒ 抛错 ⇒ catch
// 返回 null ⇒ run() 在 `if (ctx == null) return;` 静默退出 ⇒ 启动弹窗永远不出现，
// 而 _lastCheckAt 已经被写进去了，用户当天再也看不到它。
//
// 本文件两个用例：
//  A 实测根因：pump 一个 MaterialApp 后，Navigator.of(rootElement) 确实抛错；
//  B 回归：产品代码交出来的 context 必须真能把 dialog 弹出来。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/app_tray.dart';
import 'package:sourin_spike/ui/app_update_bootstrap.dart';

/// 和 shell.dart:1634 一样：把全局 key 挂到 MaterialApp 上
Future<void> _pumpShell(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    navigatorKey: AppTray.navigatorKey,
    home: const Scaffold(body: Text('shell')),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('CR-22A 根 Element 之上没有 Navigator（缺陷根因实测）', (tester) async {
    await _pumpShell(tester);

    final root = WidgetsBinding.instance.rootElement;
    expect(root, isNotNull);
    expect(root!.mounted, isTrue);

    Object? err;
    try {
      Navigator.of(root, rootNavigator: true);
    } catch (e) {
      err = e;
    }
    expect(err, isNotNull,
        reason: 'Navigator.of 只会找祖先；根 Element 上方没有 Navigator，必然抛错');
    // ignore: avoid_print
    print('[CR-22A] Navigator.of(rootElement) 抛出：' + err.toString().split('\n').first);
  });

  testWidgets('CR-22B 启动弹窗用的 context 必须真能弹出 dialog', (tester) async {
    await _pumpShell(tester);

    final ctx = AppUpdateBootstrap.debugDialogContext();
    expect(ctx, isNotNull,
        reason: '拿不到可弹窗的 context ⇒ run() 在 if (ctx == null) return 静默退出');

    unawaited(showDialog<void>(
      context: ctx!,
      builder: (_) => const AlertDialog(content: Text('update')),
    ).then((_) {}));
    await tester.pumpAndSettle();

    expect(find.text('update'), findsOneWidget,
        reason: '交出来的 context 必须真的有 Navigator 在它下面');
  });
}
