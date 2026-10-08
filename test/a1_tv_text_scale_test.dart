/*
 * a1_tv_text_scale_test.dart —— task-11 ③ A1（TV 字号 ×1.25）的回归门
 *
 * # 为什么要单独有这个文件
 *
 * A1 的第一版**只判平台**：
 * ```dart
 * switch (defaultTargetPlatform) {
 *   TargetPlatform.android || TargetPlatform.fuchsia => AppMetrics.tvScale,
 *   _ => 1.0,
 * }
 * ```
 * ⇒ **安卓手机也被整体 ×1.25**（10 英尺原则 / 沙发距离这两条理由在手机上一条
 * 都不成立）。全仓 `grep tvScale|textScaleFor|_TextScaleHost` 在 `test\` 里
 * 当时是**零命中** —— 所以这个缺陷能一直活着：没有任何自动化断言看着它。
 *
 * # 为什么这条断言在 `flutter test` 里是「可红可绿」的（关键）
 *
 * SDK `foundation/_platform_io.dart` 里有一段 assert：
 * ```dart
 * assert(() {
 *   if (Platform.environment.containsKey('FLUTTER_TEST')) {
 *     result = platform.TargetPlatform.android;   // ← 强制成 android
 *   }
 *   return true;
 * }());
 * ```
 * ⇒ 跑 `flutter test` 时 `defaultTargetPlatform` **恒为 android**（与宿主是
 * Windows 无关）。所以：
 *   · 旧代码（只判平台）在这台机器上跑测试 ⇒ **恒**走放大分支 ⇒ 期望 16.0
 *     的断言**必红**（实测 20.0）；
 *   · 新代码（平台 **且** `Device.isTv`）⇒ 测试里 `isTv` 默认 false ⇒ 1.0 ⇒
 *     断言**绿**。
 * 这就是「这条断言真的钉住了那个缺陷」的证据，而不是一条怎么改都绿的摆设。
 *
 * # 为什么挂**真身** `SourinApp` 而不是复刻一层
 *
 * 缺陷就长在 `SourinApp.build` 的 `MaterialApp.builder → _TextScaleHost` 这
 * 一条链上。本项目已有过教训（`core_error_test.dart:43-47`）：「单测绿 ≠ 真机
 * 能用，因为**测试脚手架可能测的不是那个东西**」—— 复刻一层 builder 测的是
 * 复刻品。所以这里直接 `pumpWidget(const SourinApp())`，再从 `ShellPage` 的
 * element 上**读真正生效的那个 `TextScaler`**。
 *
 * # 环境噪声（两条，都必须显式收掉，否则测试**会红**）
 *
 * 1. 无核心（FFI 缺 dll）时 `HomePage` 必然抛异常 —— 与 `core_error_test.dart`
 *    同一处理：临时静音 `FlutterError.onError` + 事后 `takeException()` 认领。
 *    ⚠️ `onError` 必须在**测试体内**还原（`addTearDown` 太晚，见 `_pumpRealApp`）。
 * 2. `RemoteBridge` 是**进程级单例**，它的复查定时器（`remote_bridge.dart:429`
 *    `_scheduleRecheck`，5 秒一次）**活得比 widget 树长** —— 这是**设计如此**
 *    （`remote_bridge.dart:1305-1317` 明说「宿主 dispose 时**不**停桥，桥的生命周期
 *    与进程一致」）。但 `flutter_test` 会在测试体结束时断言
 *    `'!timersPending'`（`binding.dart:2543`）⇒ 必须由测试**显式** `stop()` 它，
 *    等价于「进程退出」。
 */
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/tokens.dart';

/// 挂**生产本体** `SourinApp`，等首帧稳定，并就地认领环境噪声。
///
/// ⚠️ `FlutterError.onError` **必须在测试体内还原**（不能用 `addTearDown`）：
///    `flutter_test` 的 `binding.dart:1912` 会在测试体结束时断言
///    「覆写过 `onError` 就必须自己还原」，用 `addTearDown` 还原太晚 ——
///    实测报 `'_pendingExceptionDetails != null'`。所以这里 mute → pump →
///    认领 → **立刻还原**，之后才轮到调用方去 `expect`。
Future<void> _pumpRealApp(WidgetTester t) async {
  final oldOnError = FlutterError.onError;
  FlutterError.onError = (details) {}; // 静音（见文件头「环境噪声」）

  await t.pumpWidget(const SourinApp());
  await t.pump();

  FlutterError.onError = oldOnError; // ★ 必须在 expect 之前
  // 认领 HomePage 在无核心环境下的异常（见文件头）
  while (t.takeException() != null) {}

  // ★ 收掉 RemoteBridge 的复查定时器（见文件头「环境噪声」第 2 条）。
  //   `stop()` 是**终态**（`_stopped = true` 不可逆）—— 在本测试文件里等价于
  //   「进程退出」，之后的用例也不会再挂定时器，正是我们要的。
  RemoteBridge.instance.stop();
}

/// 从 `ShellPage` 的 element 上读**真正生效**的字号系数。
///
/// 这条链是：`View` → `MediaQuery.fromView`（最外层）→ `MaterialApp.builder`
/// → `_TextScaleHost`（覆写 `textScaler`）→ `FTheme` → … → `ShellPage`。
/// `ShellPage` 在链的**下游**，所以读到的就是屏幕上真正用的那个值。
double _liveTextScale(WidgetTester t) {
  final ctx = t.element(find.byType(ShellPage, skipOffstage: false));
  return MediaQuery.textScalerOf(ctx).scale(16.0);
}

void main() {
  group('A1 端到端：真正挂上去的 TextScaler（挂生产本体 SourinApp）', () {
    testWidgets('安卓手机（isTv=false）**不许**放大 —— ★ 这就是第一版的缺陷', (t) async {
      Device.overrideKind(DeviceKind.touchOnly);
      addTearDown(() => Device.overrideKind(null));

      await _pumpRealApp(t);

      expect(
        defaultTargetPlatform,
        TargetPlatform.android,
        reason: '前置条件：flutter test 下 defaultTargetPlatform 被强制成 android'
            '（SDK foundation/_platform_io.dart 的 FLUTTER_TEST 分支）—— '
            '没有这条，本文件下面所有断言都失去意义',
      );
      expect(Device.isTv, isFalse, reason: '前置条件：手机形态');

      expect(
        _liveTextScale(t),
        16.0,
        reason: '★ 第一版 A1 在这里会给出 20.0（只判平台 ⇒ 安卓手机也 ×1.25）。'
            '手机上没有「10 英尺原则」，字号不许放大',
      );
      expect(AppMetrics.effectiveTextScale, 1.0, reason: '唯一真源也必须是 1.0');
    });

    testWidgets('安卓 TV（isTv=true）**必须**放大到 1.25', (t) async {
      Device.overrideKind(DeviceKind.tv);
      addTearDown(() => Device.overrideKind(null));

      await _pumpRealApp(t);

      expect(Device.isTv, isTrue, reason: '前置条件：TV 形态（用 overrideKind 模拟，'
          '本机没有 Android TV —— 与 episode_strip_test.dart 同一手法）');
      expect(
        _liveTextScale(t),
        20.0,
        reason: '16px × 1.25 = 20px —— TV 上「真的挂上去了」的读数',
      );
      expect(AppMetrics.effectiveTextScale, AppMetrics.tvScale);
    });

    testWidgets('桌面平台（windows）**恒 1.0**，即使 isTv 被误判成 true', (t) async {
      // ⚠️ `debugDefaultTargetPlatformOverride` 必须在**测试体内**还原：
      //    `flutter_test` 会在测试体结束时断言
      //    「The value of a foundation debug variable was changed by the test」
      //    （`foundation/debug.dart:45` `debugAssertAllFoundationVarsUnset`）——
      //    用 `addTearDown` 还原太晚（实测报 `_verifyInvariants`）。
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      Device.overrideKind(DeviceKind.tv);

      await _pumpRealApp(t);

      final scale = _liveTextScale(t);

      debugDefaultTargetPlatformOverride = null; // ★ 必须在 expect 之前
      Device.overrideKind(null);

      expect(
        scale,
        16.0,
        reason: '★ Windows 上「一个像素都不会变」是 A1 的硬要求（原版 device.ts '
            '只在 leanback 设备上放大）',
      );
    });
  });

  group('A1 唯一真源：AppMetrics.effectiveTextScale', () {
    test('平台是**必要**条件：桌面平台即使 isTv=true 也返回 1.0', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      Device.overrideKind(DeviceKind.tv);

      final v = AppMetrics.effectiveTextScale;

      debugDefaultTargetPlatformOverride = null;
      Device.overrideKind(null);

      expect(v, 1.0);
    });

    test('设备是**必要**条件：android 平台但 isTv=false 返回 1.0', () {
      expect(defaultTargetPlatform, TargetPlatform.android);
      Device.overrideKind(DeviceKind.touchOnly);
      addTearDown(() => Device.overrideKind(null));

      expect(AppMetrics.effectiveTextScale, 1.0);
    });

    test('两个都满足才放大', () {
      expect(defaultTargetPlatform, TargetPlatform.android);
      Device.overrideKind(DeviceKind.tv);
      addTearDown(() => Device.overrideKind(null));

      expect(AppMetrics.effectiveTextScale, 1.25);
    });

    test('★ 卡片文字区高度与字号**同源**（不许各写一份）', () {
      Device.overrideKind(DeviceKind.tv);
      addTearDown(() => Device.overrideKind(null));

      expect(
        AppMetrics.cardTextScale,
        AppMetrics.effectiveTextScale,
        reason: '第一版 cardTextScale 自己写 Device.isTv ? tvScale : 1.0，而挂上去的'
            '看平台 ⇒ 手机上是「文字大了、承载高度没大」的错配（RenderFlex 溢出）',
      );
      expect(
        AppMetrics.posterMetaHeight(titleLines: 2),
        closeTo(
          (AppMetrics.posterMetaOther + AppMetrics.posterTitleLine * 2) * 1.25,
          1e-9,
        ),
      );
    });
  });

  group('A1 接线（读源码字符串，与 window_bounds_test.dart 同一手法）', () {
    test('shell.dart：判定已交给唯一真源，缺陷形状不复存在', () {
      final src = File('lib/shell.dart').readAsStringSync();

      expect(
        src.contains('TargetPlatform.android || TargetPlatform.fuchsia => AppMetrics.tvScale'),
        isFalse,
        reason: '★ 这一行**就是**第一版的缺陷本体（只判平台）—— 它不许回来',
      );
      expect(
        src.contains('return AppMetrics.effectiveTextScale;'),
        isTrue,
        reason: '_TextScaleHost.scaleOf 必须只取用唯一真源',
      );
      expect(
        src.contains('TextScaler.linear(want)'),
        isTrue,
        reason: '挂上去的必须是**判定出来的那个值** want',
      );
      expect(
        src.contains('const TextScaler.linear(AppMetrics.tvScale)'),
        isFalse,
        reason: '★ 写死常量就是「判定的值」与「生效的值」两个真源（第一版的形状）',
      );
    });

    test('shell.dart：平台符号已从 foundation import 的 show 列表里摘掉', () {
      final src = File('lib/shell.dart').readAsStringSync();
      final i = src.indexOf("import 'package:flutter/foundation.dart'");
      expect(i, greaterThan(-1), reason: '找不到 foundation import');
      final line = src.substring(i, src.indexOf(';', i) + 1);
      expect(
        line.contains('defaultTargetPlatform'),
        isFalse,
        reason: '★ 改完 scaleOf 后 shell.dart 里这两个符号只剩注释提及 ⇒ '
            'show 列表留着它们就是 unused import（analyzer 会报）',
      );
      expect(line.contains('TargetPlatform'), isFalse);
      expect(
        line.contains('ValueNotifier'),
        isTrue,
        reason: 'ValueNotifier 在本文件仍在用（_liveChannelStep / _activeTab …）',
      );
    });

    test('tokens.dart：唯一真源存在，且 cardTextScale 引用它', () {
      final src = File('lib/ui/tokens.dart').readAsStringSync();

      expect(src.contains('static double get effectiveTextScale {'), isTrue);
      expect(
        src.contains('static double get cardTextScale => effectiveTextScale;'),
        isTrue,
        reason: '承载高度必须与真正挂上去的 TextScaler 同源',
      );
      expect(
        src.contains('static double get cardTextScale => Device.isTv'),
        isFalse,
        reason: '★ 这就是第一版「两个真源」的另一半',
      );
      expect(
        src.contains("import 'package:flutter/foundation.dart'"),
        isTrue,
        reason: 'widgets.dart 不导出 TargetPlatform / defaultTargetPlatform —— '
            '必须自己 import foundation（SDK widgets.dart:18 的 show 列表里没有它们）',
      );
    });
  });
}
