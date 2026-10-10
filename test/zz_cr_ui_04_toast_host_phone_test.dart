// ═══════════════════════════════════════════════════════════════════════
//  CR-04 回归门禁：手机端（Device.isTouchOnly）也必须挂上 ToastHost
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件锁住什么（CR-04 原文指出的缺陷）
//
// lib/shell.dart 的 MaterialApp.builder 里，ToastHost 只挂在**非手机**分支：
//
//   child: Device.isTouchOnly
//       ? SystemUiHost(brightness: brightness,
//           child: _TitleBarHost(child: child ?? const SizedBox()))   ← 手机端：没有 ToastHost
//       : RemoteBridgeHost(globals: _globals,
//           child: ToastHost(child: _TitleBarHost(child: child ?? ...)))  ← 只有这里有
//
// 而 showAppToast 的实现是
//
//   AppToaster.maybeOf(context)?.show(...)
//
// 找不到宿主就**静默返回**（设计如此：toast 是锦上添花，不该把调用方搞崩）。
// ⇒ 手机上**所有** toast 全部消失，而且**零报错、零测试红**。
// lib/ 里唯一的调用点是 settings_page.dart 的 _flash()（L622），
//   也就是手机端设置页的**全部**操作反馈都是死的。
//
// # 为什么不能用"源码里有没有 ToastHost"来判
//
// 桌面分支本来就有 ToastHost —— 那样这条门禁在有缺陷的代码上照样绿 = 假门禁。
// 这里真的把**生产本体** SourinApp 挂起来（Device.overrideKind(touchOnly)），
// 从**渲染出来的树**里找宿主，并且真的弹一条 toast。
//
// # 环境噪声（与 a1_tv_text_scale_test.dart 同源，处理方式逐字照抄）
//
//  1. 无核心（FFI 缺 sourin_core.dll）时 HomePage 必然抛异常 ⇒ 临时静音
//     FlutterError.onError + while (t.takeException() != null) {} 认领。
//     ⚠️ onError 必须在**测试体内**还原（addTearDown 太晚，实测报
//        '_pendingExceptionDetails != null'）。
//  2. RemoteBridge 是进程级单例，它的 5s 复查定时器活得比 widget 树长
//     （remote_bridge.dart 明说这是设计如此）⇒ 测试体结束前必须
//     RemoteBridge.instance.stop()，否则 flutter_test 的 '!timersPending'
//     断言会红。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/app_toast.dart';

void main() {
  setUp(() {
    Device.overrideKind(DeviceKind.touchOnly);
    addTearDown(() => Device.overrideKind(null));
  });

  testWidgets('★ 手机端（touchOnly）必须挂上 ToastHost', (t) async {
    final oldOnError = FlutterError.onError;
    FlutterError.onError = (details) {};
    await t.pumpWidget(const SourinApp());
    await t.pump();
    FlutterError.onError = oldOnError;
    while (t.takeException() != null) {}

    expect(
      find.byType(ToastHost),
      findsWidgets,
      reason: '★ 手机端分支（SystemUiHost）里没有 ToastHost ⇒ '
          'showAppToast 静默失效，设置页的所有反馈都没了',
    );

    RemoteBridge.instance.stop();
  });

  testWidgets('★ 手机端 showAppToast 真的弹得出来（行为级判据）', (t) async {
    final oldOnError = FlutterError.onError;
    FlutterError.onError = (details) {};
    await t.pumpWidget(const SourinApp());
    await t.pump();
    FlutterError.onError = oldOnError;
    while (t.takeException() != null) {}

    // 从**真实 ShellPage** 的 element 上取 context（与 _flash 的取法一致）
    final ctx = t.element(find.byType(ShellPage, skipOffstage: false));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      showAppToast(ctx, '手机端也能弹');
    });
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));

    expect(
      find.text('手机端也能弹'),
      findsOneWidget,
      reason: '★ 挂载了宿主却弹不出来 ⇒ 手机端 toast 链路是死的',
    );

    RemoteBridge.instance.stop();
  });
}
