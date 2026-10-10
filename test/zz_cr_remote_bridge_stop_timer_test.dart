// ═══════════════════════════════════════════════════════════════════════
//  门禁：RemoteBridge.stop() 必须**真的**取消那个 5 秒复查定时器
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这条门禁（它来自一条真实的环境红）
//
// `test/zz_t12_local_play_probe_test.dart` 的 `(b-0)` 曾红：
// ```text
// A Timer is still pending even after the widget tree was disposed.
// RemoteBridge._scheduleRecheck (lib/ui/remote_bridge.dart:429)
//   → _ensurePolling (lib/ui/remote_bridge.dart:416)
// ```
// 定性结论是「**夹具**漏了 stop()」，不是产品缺陷（见 t12 文件里那段注释）。
// 但「定性为夹具问题」只有在 `stop()` **确实是对的**时才成立 ——
// 所以必须有一条门禁把 `stop()` 的行为**钉死**：
// 否则哪天有人把 `stop()` 里的 `_timer?.cancel()` 删掉，
// t12 那条红会以「夹具又没 stop」的名义被再次误判。
//
// # 为什么不用 fake_async（★ 这一点很重要）
//
// `flutter_test` **不**导出 `fake_async`，而 `fake_async` 在 pubspec 里只是
// **传递依赖** ⇒ 直接 import 会触发 `depend_on_referenced_packages`
// （`lints/core.yaml` 启用了它，`flutter_lints` 把它 include 进来）。
// 为这条门禁去改 pubspec 是**扩大改动面**，不值当。
//
// ⇒ 改用 `dart:async` 的 `ZoneSpecification.createTimer`：自己开一个 zone
//   把「这段时间内建出来的每一个 Timer」都记下来，然后直接读它的
//   `Timer.isActive` —— 这正是 `FakeAsync.pendingTimers` 判定的**同一个事实**，
//   而且更强：能指名道姓说是**哪一个** timer 还活着。
//
// # ★ 为什么必须用 `t.runAsync`（踩过，记下来）
//
// `_ensurePolling` 的第一句是 `await SourinApi.remoteStatus()`，它要过 FFI
// 到 Rust 再回调。**回调走的是真实事件循环**（`NativeCallable.listener` 的消息端口）
// ⇒ 只 `pump()`（受控 fake 时钟）**永远等不到它** ⇒ 那个 5 秒定时器
// **根本不会被建出来** ⇒ 「stop() 之后没有 pending timer」变成**恒真**（假绿）。
// 实测：第一版只 `pump()`，`(made)` 是**空列表**，前提断言立刻判红 ——
// 这条前提断言正是为此存在的。
// ⇒ 照 `zz_t12_local_play_probe_test.dart` 的做法：`setGlobals` 在受控时钟里调
//   （这样续体落在 fake zone ⇒ 定时器能被观测到），再用 `t.runAsync` 转真实事件循环。
//
// # 反假绿：先证明「定时器真的被建出来了」
//
// 「stop() 之后没有 pending timer」有**两种**为真的方式：
// ```text
// ① 定时器建出来了，stop() 把它取消了      ← 我们要的
// ② 定时器**根本没建出来**（_ensurePolling 早退 / FFI 没回调）
// ```
// ② 就是本仓反复踩的那种假绿。所以每个用例都**先**断言
// 「5 秒那个 timer 确实被创建了、且还活着」，**再**断言 stop() 的效果。
// 撤掉任意一半，门禁都会红。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 复查间隔 —— 与 `remote_bridge.dart:200` 的 `_tickDisabledMs` 一致
const _recheckMs = 5000;

/// 一次被观测到的 `Timer` 创建
typedef _Made = ({Duration duration, Timer timer});

/// 在**自己的 zone** 里跑 [body]，把期间建出来的每个 `Timer` 都记进 [sink]
///
/// 关键：`_ensurePolling` 是 async，它的**续体跑在调用它的那个 zone** 里
/// ⇒ 只要 `setGlobals` 在这个 zone 里调，`_scheduleRecheck` 里那句
/// `Timer(...)` 就会经过下面的 `createTimer`。
T _recordTimers<T>(List<_Made> sink, T Function() body) {
  return runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, f) {
        final t = parent.createTimer(zone, duration, f);
        sink.add((duration: duration, timer: t));
        return t;
      },
    ),
  );
}

/// 造一个「遥控没开」的全局能力
///
/// 测试环境里没有 `sourin_core` dll / 核心没 start ⇒ `SourinApi.remoteStatus()`
/// 必然失败 ⇒ `_ensurePolling` 走 catch 分支（remote_bridge.dart:413-418）
/// ⇒ `_scheduleRecheck()` ⇒ 5 秒定时器。
/// **这正是 t12 那条红的路径**，不是人为构造的另一条路。
GlobalBridge _globals() => GlobalBridge(
      search: (String keyword) async {},
      loadHome: () async {},
    );

PlayerBridge _player() => PlayerBridge(
      getState: () => const RemoteState(),
      exec: (RemoteCommand cmd) async {},
    );

/// 让**真实**事件循环转几圈 —— 等 FFI 的失败回调到达（照 t12 的做法）
///
/// ⚠️ 不能用 `pumpAndSettle`：它靠把定时器「耗掉」来收场，
///    那样即使 `stop()` 是坏的，用例也会绿（本仓明令禁止的收法）。
Future<void> _letRealLoopRun(WidgetTester t) async {
  await t.runAsync(() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  await t.pump();
}

/// 把桥唤醒并**等到那个 5 秒复查定时器真的建出来**
///
/// 返回观测到的 timer 列表；调用方负责断言前提。
Future<List<_Made>> _wakeAndWaitForRecheck(WidgetTester t) async {
  final made = <_Made>[];
  // setGlobals 会 `_stopped = false`（remote_bridge.dart:312）并唤醒轮询
  _recordTimers(made, () => RemoteBridge.instance.setGlobals(_globals()));
  await t.pump();
  await _letRealLoopRun(t);
  await t.pump();

  final recheck =
      made.where((m) => m.duration.inMilliseconds == _recheckMs).toList();
  debugPrint('BRIDGE-GATE 观测到的 timer = '
      '${made.map((m) => m.duration.inMilliseconds).toList()}；'
      '其中 ${_recheckMs}ms 的有 ${recheck.length} 个');
  return recheck;
}

void main() {
  setUp(() {
    // 归零：单例**跨用例存活**（这正是那条红的成因），先停一次
    RemoteBridge.instance.stop();
  });

  tearDown(() {
    RemoteBridge.instance.stop();
  });

  testWidgets('① ★ 门禁本体：stop() 必须真的取消那个 5 秒复查定时器', (t) async {
    final recheck = await _wakeAndWaitForRecheck(t);

    // ── ★ 前提（反假绿第一半）：它**真的**被建出来了，而且活着 ──
    // 0 个 = FFI 没回调 / _ensurePolling 早退 ⇒ 后面那句「取消了」是恒真
    expect(recheck, hasLength(1),
        reason: '★★★ 前提：必须恰好建出 1 个 ${_recheckMs}ms 复查定时器。'
            '0 个说明 _ensurePolling 没走到 _scheduleRecheck ⇒ '
            '本用例会假绿（t12 那条红的路径没被走到）');
    expect(recheck.single.timer.isActive, isTrue,
        reason: '★ 前提：刚建出来时必须还活着 —— 否则测的不是同一个东西');

    // ── 被测行为 ──
    RemoteBridge.instance.stop();
    await t.pump();

    debugPrint('BRIDGE-GATE ① stop() 之后 isActive='
        '${recheck.single.timer.isActive}');
    // ★ 这就是那条红的根因：只要这句为真，widget 用例收尾时
    //   FakeAsync 就会报 "A Timer is still pending..."
    expect(recheck.single.timer.isActive, isFalse,
        reason: '★★★ stop() 必须取消待定定时器（remote_bridge.dart:361 的 '
            '`_timer?.cancel()`）—— 它不生效时 t12 探针会以 '
            '"A Timer is still pending" 判红');

    // ★ 第二重判据：此刻若还有 pending timer，框架收尾自己会判红
  });

  testWidgets('② 对照组（反假绿另一半）：**不** stop() 时它确实还活着', (t) async {
    /*
     * 与 ① 同一个观测手法、同一条唤醒路径、同一个计时器 ——
     * **唯一的差别就是有没有 stop()**。
     * ⇒ ① 与 ② 一红一绿的差别只能来自 stop()，不可能是别的因素。
     * 若把 stop() 改成空实现，① 会红而 ② 仍绿（② 本来就是「不 stop」）。
     */
    final recheck = await _wakeAndWaitForRecheck(t);
    expect(recheck, hasLength(1), reason: '★ 前提同 ①');

    // 不 stop，直接看
    await t.pump();
    debugPrint('BRIDGE-GATE ② 未 stop 时 isActive='
        '${recheck.single.timer.isActive}');
    expect(recheck.single.timer.isActive, isTrue,
        reason: '★★ 未调 stop() 时定时器**必须**还在 —— '
            '否则 ① 的绿是恒真的（本用例就是它的对照组）');

    // 收尾：不 stop 的话用例会因「真的有 pending timer」被框架判红
    //（那正是本用例要证明的事实，但会让文件变红）
    RemoteBridge.instance.stop();
    await t.pump();
    expect(recheck.single.timer.isActive, isFalse, reason: '收尾自检');
  });

  testWidgets('③ stop() 之后不许再排新定时器（_stopped 是终态守卫）', (t) async {
    await _wakeAndWaitForRecheck(t);
    RemoteBridge.instance.stop();
    await t.pump();

    // 之后任何「唤醒」入口都不许再排 —— 否则「停了又活」= 泄漏复活
    final after = <_Made>[];
    _recordTimers(after, () {
      RemoteBridge.instance.notifyEnabled(); // remote_bridge.dart:352-356
      RemoteBridge.instance.setPlayer(_player()); // remote_bridge.dart:318-322
    });
    await t.pump();
    await _letRealLoopRun(t);

    debugPrint('BRIDGE-GATE ③ stop() 之后新建 timer = '
        '${after.map((m) => m.duration.inMilliseconds).toList()}');
    expect(after, isEmpty,
        reason: '★★★ stop() 之后 notifyEnabled/setPlayer 都不许再排定时器 '
            '（_scheduleRecheck/_schedule 的 `if (_stopped ...) return;` 守卫）');
  });
}
