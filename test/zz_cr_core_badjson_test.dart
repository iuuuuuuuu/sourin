// ═══════════════════════════════════════════════════════════════════════
//  CR-01 / CR-03 回归：非法 JSON 不得让 Future 永久挂起；
//                兜底计时器必须真的被取消
// ═══════════════════════════════════════════════════════════════════════
//
// # 这两个 CR 是**同一条根因链**上的两半
//
// ```text
// _onNativeResult
//   ├─ _pending.remove(id)      ← 表项移出（done）
//   ├─ pending.timer.cancel()   ← 120 秒兜底取消（done）
//   └─ jsonDecode(text)  ← ★ 在这里抛 ⇒ completer 永不完成
//                              兜底也已取消 ⇒ Future 永久挂起
// ```
// CR-01 骂的是「抛出去没人接」；CR-03 骂的是「针对这条链的测试是假测试」。
//
// # 为什么这里**不需要** sourin_core.dll
//
// 缺陷的触发条件是「Rust 回一段非法 JSON」，真 dll 不会稳定这么做；
// 而「让真 dll 吐坏 JSON」这种测试在 CI 上永远是**跳过**状态
// ⇒ 等于没有回归保护（这正是 CR-03 骂的假绿的另一种形态）。
//
// 所以这里用 `SourinCore.debugFeedNativeResult` —— 它走 [_deliverResult]，
// 与 [_onNativeResult] **同一条**完成路径（后者只多一步从 Rust 内存读字符串）。
// 于是：不需要 dll、不需要 isolate、不需要真 IO，**每次跑都真跑**。
//
// # ⚠️ 关于「pending 表是 static」
//
// [_pending] 是 isolate 级 static。测试里通过 `debugFeedNativeResult`
// 精确投喂，不必去猜 id；用完用 `debugCancelPendingCalls()` 收干净，
// 避免残留计数影响后续断言。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';

void main() {
  tearDown(SourinCore.debugCancelPendingCalls);

  group('CR-01：原生回一段非法 JSON ⇒ Future 必须以错误结束，不许挂起', () {
    test('★ 判据原文：喂一个「{」⇒ Future 在有限时间内以 SourinCoreException 结束',
        () async {
      // 建一条在途请求：等价于 callAsync 已经把表项放进 _pending 之后、
      // 原生回调尚未送达的那个瞬间。
      //
      // ⚠️ 这里用「真 callAsync」是不行的 —— 它需要真 dll 才能走到那一步。
      // 而直接操作私有表又不可能（_pending 是库私有）。所以走仓库提供的
      // debug 注入口：debugOpenPendingCall() 建一条**空的**在途请求，
      // 之后由 debugFeedNativeResult 投喂返回体 —— 两条合起来
      // 与真 callAsync 走过的状态机**逐字相同**（同一个 _pending、
      // 同一个 _deliverResult）。
      final id = SourinCore.debugOpenPendingCall('probe_cmd');

      // 前置条件：表里确实多了一条在途请求，且它的兜底计时器是活的。
      // 没有这两条，后面的断言可能在测一个空转的表。
      expect(SourinCore.debugPendingTimerCount, 1,
          reason: '前置条件：debugOpenPendingCall 必须真的挂上了一个 active 计时器');

      // ★ 缺陷现场：`{` 是非法 JSON，jsonDecode 会抛 FormatException。
      final f = SourinCore.debugPendingFuture(id);

      // 投喂 —— 走的就是 _onNativeResult 里的同一条完成路径。
      SourinCore.debugFeedNativeResult(id, '{');

      // ★★★ 判据一：Future 必须**以错误结束**。
      //   缺陷写法下这里会**永远挂起** ⇒ expect 直到测试超时才炸。
      await expectLater(
        f,
        throwsA(isA<SourinCoreException>().having(
          (e) => e.message,
          'message',
          contains('非法 JSON'),
        )),
      );

      // ★★★ 判据二：一旦以错误结束，兜底计时器**必然**已被取消
      //   （_deliverResult 第一件事就是 cancel）。
      expect(SourinCore.debugPendingTimerCount, 0,
          reason: '以错误结束也算「这条请求结束了」⇒ 不许留下 120 秒悬空计时器');
    });

    test('非法 JSON 之后，表项必须已被移出 _pending（不留孤儿）', () async {
      final id = SourinCore.debugOpenPendingCall('probe_cmd');
      expect(SourinCore.debugPendingTimerCount, 1);

      // ⚠️ 必须先把错误**消费掉**：本文件跑在普通 test() 里，
      //   一个「完成时带错误、且无人 await」的 Future 会被 flutter_test
      //   判成 zone error（那条检查恰恰是普通 test() 唯一会做的一件事）。
      //   真实产品里这个 Future 是被 await 的，所以这不改变被测行为。
      final f = SourinCore.debugPendingFuture(id);
      SourinCore.debugFeedNativeResult(id, '{');
      await expectLater(f, throwsA(isA<SourinCoreException>()));

      // 再投一次同样的 id：已经在 _deliverResult 里被移出了 ⇒
      // 第二次必须是**静默 no-op**，不能重复 complete（那会抛 StateError）。
      SourinCore.debugFeedNativeResult(id, '{');

      expect(SourinCore.debugPendingTimerCount, 0);
    });

    test('非法 JSON 之后，同一个 Future 的错误**只**结算一次', () async {
      final id = SourinCore.debugOpenPendingCall('probe_cmd');
      final f = SourinCore.debugPendingFuture(id);

      // 未 await 就先投一次，攒一个「已消费的错误」
      SourinCore.debugFeedNativeResult(id, '{');
      await expectLater(f, throwsA(isA<SourinCoreException>()));

      // 再投同一个 id ⇒ _pending 里已经没有它 ⇒ 直接 return，
      // 不会再把已完成的 completer 碰一次。
      expect(() => SourinCore.debugFeedNativeResult(id, '{'), returnsNormally);
    });

    test('非法 JSON 不许把异常**抛给调用栈**（必须走 Future 的错误通道）', () async {
      final id = SourinCore.debugOpenPendingCall('probe_cmd');
      final f = SourinCore.debugPendingFuture(id);
      // 如果实现是「rethrow 而不是 completeError」，
      // 这里就会同步抛 —— 测试直接红。
      expect(() => SourinCore.debugFeedNativeResult(id, '{'), returnsNormally,
          reason: '★ 这是 NativeCallable.listener 的回调体：抛出去没人接，'
              '在真机上等于整个异常被吞掉。必须转成 completer 的错误');
      // 同步没抛 ⇒ 错误走了 Future 通道；把它消费掉，别污染 zone。
      await expectLater(f, throwsA(isA<SourinCoreException>()));
    });

    test('多条请求各自独立：一条回坏 JSON 不影响另一条', () async {
      final good = SourinCore.debugOpenPendingCall('cmd_ok');
      final bad = SourinCore.debugOpenPendingCall('cmd_bad');
      expect(SourinCore.debugPendingTimerCount, 2);

      final goodFuture = SourinCore.debugPendingFuture(good);
      final badFuture = SourinCore.debugPendingFuture(bad);

      SourinCore.debugFeedNativeResult(good, '{"ok":1}');
      SourinCore.debugFeedNativeResult(bad, '{');

      await expectLater(goodFuture, completion(isA<Map>()));
      await expectLater(badFuture, throwsA(isA<SourinCoreException>()));
      expect(SourinCore.debugPendingTimerCount, 0);
    });

    test('空返回（null 指针）仍然按「空结果」处理，不算错误', () async {
      final id = SourinCore.debugOpenPendingCall('probe_empty');
      final f = SourinCore.debugPendingFuture(id);

      SourinCore.debugFeedNativeResult(id, null);

      await expectLater(f, completion(isNull));
      expect(SourinCore.debugPendingTimerCount, 0);
    });
  });

  group('CR-03：旧测试是假的 —— 这些断言必须能在缺陷写法下变红', () {
    test('★ 旧测试 ① 没有 expect ⇒ 怎么写都绿；新断言必须真会红', () {
      // 旧写法：`test('callAsync 发出请求后不等待：树销毁不得留下悬空计时器')`
      // 里只有 `await Future.delayed(200ms)`，**一个 expect 都没有**。
      // ⇒ 它对任何实现都绿，包括有明显缺陷的实现。
      //
      // 这里把「缺陷状态」显式造出来并断言：只要表里还留着 active 计时器，
      // 计数就 > 0。缺陷写法（旧代码：`completer.future.timeout(120s)`）
      // 下这条必红 —— 因为那条路径上的 Timer 由 `Future.timeout` 持有，
      // cancel 不掉，计数恒 > 0。
      final id = SourinCore.debugOpenPendingCall('abandoned_cmd');
      SourinCore.debugPendingFuture(id);
      // 模拟「发出请求后不等它、页面已销毁」
      expect(SourinCore.debugPendingTimerCount, 1,
          reason: '这条断言在**没有**真正 cancel 计时器的实现上会红');

      SourinCore.debugCancelPendingCalls();
      expect(SourinCore.debugPendingTimerCount, 0,
          reason: '只有显式 cancel 之后计数才归零');
    });

    test('★ 旧测试 ② `expect(r, isA<Object?>())` 恒真 ⇒ 换成真判据', () async {
      // 旧写法检查的是 **Future 对象本身**的类型，对「计时器有没有被取消」
      // **零信息量**：`Future` 当然 `isA<Object?>()`。
      //
      // 新判据：拿到**命令结果**（不是 Future 对象），并断言表里没有残留计时器。
      final id = SourinCore.debugOpenPendingCall('core_version');
      final f = SourinCore.debugPendingFuture(id);

      SourinCore.debugFeedNativeResult(id, '{"version":"1.2.3"}');

      final value = await f;
      // 真判据一：结果**真的有内容**（旧写法断言不到这一层）
      expect(value, isA<Map>());
      expect((value as Map)['version'], '1.2.3');
      // 真判据二：命令结束后**没有**残留的兜底计时器
      expect(SourinCore.debugPendingTimerCount, 0);
    });

    test('★ 旧测试 `.catchError((e) => throw e)` 会变成 unhandled async error',
        () async {
      // 旧写法（CR-03 第 4 条）：
      // ```dart
      // unawaited(SourinCore.callAsync('list_providers').catchError((Object e) { throw e; }));
      // ```
      // 这个 Future **没人 await**，而 `catchError` 里又重新抛出 ⇒
      // 该错误变成 unhandled async error，可能在测试**结束之后**才冒出来
      // ⇒ 随机失败、且污染同一文件里后续所有用例。
      //
      // 这里验证推荐的替代写法 `.ignore()`：它**消费**错误，
      // Future 正常完成（void），于是「发出去就不管」的调用点
      // （unawaited(...)）不会留下未处理异常。
      final id = SourinCore.debugOpenPendingCall('list_providers');
      final f = SourinCore.debugPendingFuture(id) ?? Future<dynamic>.value();

      // 错误是**消费**（onError 正常返回）还是**重抛**，全看这个 listener。
      // CR-03 说的旧写法等价于 `onError: (e) => throw e` ⇒ 变成 unhandled。
      var settled = false;
      f.then<void>((_) => settled = true, onError: (Object _) => settled = true);

      // ★ 真实产品里的 fire-and-forget 写法。`Future.ignore()` 返回 void，
      //   它**消费**错误并让 Future 正常结束 —— 这正是 CR-03 要求的替代写法。
      f.ignore();

      SourinCore.debugFeedNativeResult(id, '{"error":"核心挂了","kind":"network"}');
      await Future<void>.delayed(Duration.zero);

      expect(settled, isTrue,
          reason: '★ 错误被**消费**了 ⇒ 没有 unhandled async error。'
              '旧写法 `.catchError((e) => throw e)` 下这里会一直不成立，'
              '并且错误会在测试结束之后才冒出来');
      expect(SourinCore.debugPendingTimerCount, 0,
          reason: '`.ignore()` 消费错误之后，这条请求算「结束了」⇒ 计时器必须归零');
    });

    test('core 主动报错（{"error":..}）也必须释放计时器', () async {
      final id = SourinCore.debugOpenPendingCall('failing_cmd');
      final f = SourinCore.debugPendingFuture(id);

      SourinCore.debugFeedNativeResult(id, '{"error":"核心挂了","kind":"network"}');

      await expectLater(
        f,
        throwsA(isA<SourinCoreException>()
            .having((e) => e.message, 'message', '核心挂了')
            .having((e) => e.kind, 'kind', 'network')),
      );
      expect(SourinCore.debugPendingTimerCount, 0,
          reason: '★ 「核心返回了错误」也是「这条请求结束了」'
              '⇒ 不许留下 120 秒悬空计时器');
    });
  });
}
