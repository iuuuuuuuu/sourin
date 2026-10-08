@Tags(['native-media'])
library;

// ═══════════════════════════════════════════════════════════════════════
//  ★ 本文件被标记为 `native-media`（默认不跑）—— 原因见下
// ═══════════════════════════════════════════════════════════════════════
//
// 本文件调用 `MediaKit.ensureInitialized()`，它会加载 **libmpv-2.dll**。
// 实测：在 `flutter test` 的 flutter_tester 进程里加载该原生库，
// 会**偶发 native 崩溃**（访问违例 c0000005，进程退出码 79）。
//
// ```text
// 失败形态：整文件用例一起 `did not complete`（不是单用例失败）
// 实测崩溃率：加载 libmpv 6/25；不加载 0/25（干净交错 A/B）
// 与并发无关：串行 8 次里红 5 次；单文件串行也红（1/5）
// ```
//
// ★ 完整证据链与已排除清单：`.probe/native-media-tests.md`
// ★ 标签配置：`dart_test.yaml`
//
// 手动跑（改播放器 / media_kit 相关代码时**应该**跑一遍）：
// ```powershell
// flutter test test/ --tags native-media --concurrency=1
// ```
//
// ⚠️ `--concurrency=1` 并不能避免崩溃，只是让输出更易读。
// ═══════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════
//  PC 键盘方向键：单击 = 步数控制，长按 = 快进快退（task-15 验收）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（需求）
//
// > 在pc上,**小键盘的左右按键 单击 应该是步数控制**,**长按是 快进快退**
// > 这两个都是**可配置 可关闭**的,
// > 然后在手机上, 只需要 **长按左右两侧,快进快退 可配置**
//
// # 用户对测试的硬约束
//
// > **「不要再操作我的鼠标,你想别的方式去测试,别影响我的工作」**
//
// 所以这个文件**完全不碰窗口/鼠标/前台焦点**：
// ```text
// ✗ SetForegroundWindow / SetCursorPos / mouse_event / SetWindowPos
// ✓ tester.sendKeyDownEvent / sendKeyRepeatEvent / sendKeyUpEvent
// ```
// 这恰好也是**更有力**的证据 —— 它驱动的是**真实 PlayerPage 的
// 真实 `_onKey`**，而不是"我读源码看到有这么一行"。
//
// # ★ 这里为什么能挂载真 PlayerPage（上一轮以为做不到）
//
// 本仓库多处注释写着「真跑 PlayerPage 要 media_kit + 平台通道（重且脆）」，
// 我一开始也照抄了这个判断。实测**不成立**：
// ```text
// ① media_kit 需要 libmpv-2.dll —— 仓库自己就带着
//    （build/windows/x64/libmpv/libmpv-2.dll），
//    用 MediaKit.ensureInitialized(libmpv: <path>) 显式指过去即可
// ② RemoteBridge 会留一个 5 秒复查定时器 —— 调一次 stop() 即可
// ```
// 两行准备之后 `PlayerPage` 正常构建，`sendKeyEvent` 正常到达 `_onKey`。
// 所以"调不了生产代码，只能读源码"这个退路在本文件里**不需要**。
//
// # ★ 为什么必须是真的 PlayerPage 而不是复刻一个
//
// 本次改动的**行为**分散在三处（`_onKey` 里的拦截、`_startPcArrowHold`、
// `dispose` 收尾），任何一处漏接都会让功能半好：
// ```text
// 拦截漏了      -> 走回硬编码 ±5 秒，配置改了没反应
// 长按没接      -> 只有单击能跳秒，长按永远是普通单击
// dispose 没接  -> 按着方向键退出，倍速永远卡在 3x
// ```
// 复刻一份测试壳会把这三处**全部测不到**。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/player_gestures.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 挂载**真实** PlayerPage（桌面：`isTv=false, isTouchOnly=false`）
///
/// 不 `pumpAndSettle`：播放器会持续产生定时器/帧，settle 永远不返回。
/// 只 pump 固定几帧 —— 足以让 `autofocus` 的 `Focus` 拿到焦点，
/// 从而让 `sendKeyEvent` 走进 `_onKey`。
Future<void> mountPlayer(WidgetTester t) async {
  await t.pumpWidget(
    const MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '方向键验收',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// TV 场景（遥控器也是方向键，见下面第 5 组）
Future<void> mountTv(WidgetTester t) async {
  await t.pumpWidget(
    const MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: 'TV 验收',
        isTv: true,
        isTouchOnly: false,
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// 手机场景（触摸端）
Future<void> mountPhone(WidgetTester t) async {
  await t.pumpWidget(
    const MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '手机验收',
        isTv: false,
        isTouchOnly: true,
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// 把挂起的定时器**在用例体内**跑完
///
/// # 为什么必须这样（实测踩到的坑）
///
/// `_seekBy` / `_flash` 会起 1.2 秒的提示定时器，`_showControls` 会起 3 秒的
/// 隐藏定时器。`flutter_test` 在用例**结束时**断言 "没有挂起的定时器"：
/// ```text
/// A Timer is still pending even after the widget tree was disposed.
/// ```
/// ⚠️ 用 `addTearDown` 里 pump **不行** —— 那个钩子在
///    `_verifyInvariants` **之后**才跑（我第一版就是这么写的，仍然报错）。
///    必须在用例**返回之前**把时间推过去。
Future<void> drainTimers(WidgetTester t) async {
  /*
   * ══════════════════════════════════════════════════════════════
   * ★ 为什么要 pump **足够长**的假时间（实测踩到）
   * ══════════════════════════════════════════════════════════════
   *
   * 这个用例会在**两种环境**下被跑，而两者的定时器集合不同：
   * ```text
   * 没有 sourin_core.dll  → `_load()` 快速失败，只有 _flash / _showControls 的定时器
   * 有   sourin_core.dll  → 多一个 `SourinApi.resolveStream` 的 FFI 调用，
   *                            它带 `timeout(120s)`（core/ffi.dart:364）
   * ```
   * 后者在用例结束时仍然 pending →
   * flutter_test 报“A Timer is still pending”→ **17 条全挂**。
   *
   * ★ 这是**环境差异而不是行为差异**：本文件要验的是方向键分派，
   *   两种环境下走的是**同一条代码路径**。所以把时间推过去即可，
   *   不需要（也不应该）去改产品代码里的超时。
   */
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
  RemoteBridge.instance.stop();
}

/// 复位所有手势偏好到默认（用例之间互不影响）
void resetGesturePrefs() {
  for (final k in [
    'player.gesture.doubleTap.enabled',
    'player.gesture.doubleTap.seconds',
    'player.gesture.longPress.enabled',
    'player.gesture.longPress.rate',
    'player.gesture.longPress.rewindStep',
    'player.pcButtons.enabled',
    'player.pcButtons.forwardRate',
    'player.pcButtons.rewindStep',
    'player.pcArrow.seek.enabled',
    'player.pcArrow.seek.seconds',
    'player.pcArrow.hold.enabled',
    'player.pcArrow.hold.rate',
  ]) {
    UiPrefs.remove(k);
  }
  PlayerGestures.setPcArrowSeekEnabled(true);
  PlayerGestures.setPcArrowSeekSeconds(
    PlayerGestures.defaultPcArrowSeekSeconds,
  );
  PlayerGestures.setPcArrowHoldEnabled(true);
  PlayerGestures.setPcArrowHoldRate(PlayerGestures.defaultPcArrowHoldRate);
}

void main() {
  setUpAll(() {
    /*
     * ① 让 media_kit 找到仓库自带的 libmpv。
     *    路径取自 `build/windows/x64/libmpv/`（Windows 构建产物目录）。
     */
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() {
    /*
     * ② 掐掉 RemoteBridge 的 5 秒复查定时器。
     *    它是**应用级**单例（搜索页也要用），不掐掉的话每个用例结束时
     *    flutter_test 都会报 "A Timer is still pending"。
     */
    RemoteBridge.instance.stop();
    resetGesturePrefs();
  });

  tearDown(() {
    RemoteBridge.instance.stop();
    resetGesturePrefs();
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 单击 = 步数控制（跳配置的秒数）
  // ═══════════════════════════════════════════════════════════════════
  group('① PC ←/→ 单击 = 步数控制', () {
    testWidgets('★ 单击跳的秒数**读配置**（不是硬编码 ±5）', (t) async {
      /*
       * 这是"可配置"的核心证据。
       *
       * 改配置前后**各按一次**：如果代码里还是硬编码 ±5，
       * 两次读数会一样 —— 那种"配置项存在但没人读"的假功能
       * 只有对比才能抓到。
       */
      PlayerGestures.setPcArrowSeekSeconds(30);
      await mountPlayer(t);

      final before = debugPlayerPositionSeconds();
      expect(before, isNotNull, reason: '★ 必须能读到真实播放位置 —— '
          '否则下面的"跳了多少"无从判起（空断言比没断言更危险）');

      // 一次完整的轻点：down + up
      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));

      /*
       * ════════════════════════════════════════════════════════════════
       * ★★ “读配置”的**直接证据**：闪现提示里的秒数
       * ════════════════════════════════════════════════════════════════
       *
       * `_seekBy` 会 `_flash('快进 ${seconds}s')` —— 所以提示文案里就带着
       * **实际用的那个秒数**。把配置设成 30 秒，若提示里出现
       * '30s'，就证明它真的读了配置；写死的 5 会是 '5s'。
       *
       * ⚠️ 为什么不用位置差值做判据：`_seekBy` 对 target 做了 clamp
       *    （不能超出 duration），而起播初期 duration 还是 0 ——
       *    位置差值会被夹成 0，看起来像“没跳”（假失败）。
       */
      expect(
        debugPlayerLastTip(),
        contains('30s'),
        reason: '★★ 单击必须跳**配置的** 30 秒 —— '
            '提示里是 5s 就说明还是硬编码值，配置项是假的',
      );
      expect(
        debugPlayerSeekByCalls(),
        1,
        reason: '★ 单击右方向键必须**恰好**触发一次 seek —— '
            '0 次说明按键没被处理（`_onKey` 的拦截漏了），'
            '2 次说明 down/repeat 被重复计数',
      );
      await drainTimers(t);
    });

    testWidgets('★ 改了步长，单击仍然只跳一次（配置生效但不重复）', (t) async {
      PlayerGestures.setPcArrowSeekSeconds(2);
      await mountPlayer(t);

      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await t.pump(const Duration(milliseconds: 30));
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await t.pump(const Duration(milliseconds: 30));

      expect(debugPlayerSeekByCalls(), 1);
      // 左键是快退方向（`_flash` 文案可读）
      expect(debugPlayerLastTip(), contains('快退'),
          reason: '左方向键单击必须是**快退**方向');
      await drainTimers(t);
    });

    testWidgets('★ 关掉「单击」开关后，单击**不再跳秒**', (t) async {
      PlayerGestures.setPcArrowSeekEnabled(false);
      await mountPlayer(t);

      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));

      expect(
        debugPlayerSeekByCalls(),
        0,
        reason: '★ 用户要求「可关闭」—— 关掉后按键**不应该有任何 seek**。'
            '⚠️ 注意这里必须**消费掉**事件而不是放行：放行的话它会落到'
            '下面那段硬编码 ±5 秒，开关就成了摆设。',
      );
      await drainTimers(t);
    });

    testWidgets('★ ↑/↓ 音量**不受影响**（用户没让改）', (t) async {
      await mountPlayer(t);

      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
      await t.pump(const Duration(milliseconds: 30));
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
      await t.pump(const Duration(milliseconds: 30));

      expect(
        debugPlayerSeekByCalls(),
        0,
        reason: '★ ↑ 是**音量**键（task-15 第 5 条：保持不动）—— '
            '它绝不能被当成快进/快退处理',
      );
      await drainTimers(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 长按 = 快进快退（倍率）
  // ═══════════════════════════════════════════════════════════════════
  group('② PC ←/→ 长按 = 快进快退', () {
    testWidgets('★★ 长按右方向键 → 倍速切到配置值；松手 → 恢复原倍速', (t) async {
      PlayerGestures.setPcArrowHoldRate(3.0);
      await mountPlayer(t);

      /*
       * ★ 快照取**播放器回报**的倍速（即“按住之前的原倍速”），
       *   而不是 `_lastRateRequest` —— 后者在**首次**长按前还是 null。
       */
      final rateBefore = debugPlayerRate();
      expect(rateBefore, isNotNull, reason: '必须能读到真实倍速');

      // 按住：down 之后系统持续发 repeat
      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));

      expect(
        debugPlayerRequestedRate(),
        3.0,
        reason: '★ 长按（收到 `KeyRepeatEvent`）必须把倍速切到**配置值** —— '
            '这是"长按是快进"的唯一可观测结果',
      );
      expect(debugPlayerPcArrowState(), contains('holding=true'));

      // 继续 repeat 不应该反复叠加速度
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));
      expect(debugPlayerRequestedRate(), 3.0, reason: '重复事件不应改变已生效的倍率');

      // 松开 → 恢复
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));

      expect(
        debugPlayerRequestedRate(),
        rateBefore,
        reason: '★ 松手必须**恢复按住之前的原倍速** —— '
            '写死恢复 1.0x 会把用户自己设的倍速冲掉',
      );
      await drainTimers(t);
    });

    testWidgets('★ 长按左方向键 → 连续快退（定时器在跑）；松手 → 停止', (t) async {
      await mountPlayer(t);

      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await t.pump(const Duration(milliseconds: 30));
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
      await t.pump(const Duration(milliseconds: 30));

      expect(
        debugPlayerRewindTimerActive(),
        isTrue,
        reason: '★ 左方向键长按 = **连续快退**。底层 `media_kit` 的 setRate '
            '拒绝非正数（无法倒放），所以实现是定时器反复 seek —— '
            '「定时器在跑」就是这个功能的可观测证据',
      );

      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await t.pump(const Duration(milliseconds: 30));

      expect(
        debugPlayerRewindTimerActive(),
        isFalse,
        reason: '★ 松手必须**停下**连续快退 —— 否则会一直往回跳',
      );
      await drainTimers(t);
    });

    testWidgets('★ 关掉「长按」开关后，长按**不再变速**', (t) async {
      PlayerGestures.setPcArrowHoldEnabled(false);
      await mountPlayer(t);

      final rateBefore = debugPlayerRequestedRate();
      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));

      expect(debugPlayerRequestedRate(), rateBefore,
          reason: '★ 用户要求「可关闭」—— 关掉长按后倍速不该变');
      expect(debugPlayerRewindTimerActive(), isFalse);
      await drainTimers(t);
    });

    testWidgets('★ 松手后状态清空（不会卡住下一次长按）', (t) async {
      await mountPlayer(t);
      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 10));
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 10));
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));

      expect(debugPlayerPcArrowState(), contains('holding=false'));
      expect(debugPlayerPcArrowState(), contains('dir=0'),
          reason: '★ 松手后方向必须清零 —— 否则下一次长按会被'
              '「已在长按中」挡掉，表现为"第二次长按没反应"');

      // 再按一次仍应生效
      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 10));
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 10));
      expect(debugPlayerRequestedRate(), PlayerGestures.pcArrowHoldRate);
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));
      await drainTimers(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ ★★ 两个开关**各自独立**（用户强调）
  // ═══════════════════════════════════════════════════════════════════
  group('③ ★★ 单击开关与长按开关互相独立', () {
    testWidgets('★★ 关掉「单击」不影响「长按」', (t) async {
      PlayerGestures.setPcArrowSeekEnabled(false); // 单击关
      PlayerGestures.setPcArrowHoldEnabled(true); // 长按开
      await mountPlayer(t);

      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 20));
      expect(debugPlayerSeekByCalls(), 0, reason: '单击已关 → 按下不跳秒');

      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 20));
      expect(
        debugPlayerRequestedRate(),
        PlayerGestures.pcArrowHoldRate,
        reason: '★★ 单击关掉后**长按仍必须生效** —— '
            '这正是用户强调的「这两个配置开关是单独配置的」。'
            '如果实现里共用一个开关，这里会失败。',
      );

      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 20));
      await drainTimers(t);
    });

    testWidgets('★★ 关掉「长按」不影响「单击」', (t) async {
      PlayerGestures.setPcArrowSeekEnabled(true); // 单击开
      PlayerGestures.setPcArrowHoldEnabled(false); // 长按关
      await mountPlayer(t);

      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 20));
      expect(
        debugPlayerSeekByCalls(),
        1,
        reason: '★★ 长按关掉后**单击仍必须生效**（反方向同样要独立）',
      );

      final rate = debugPlayerRequestedRate();
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 20));
      expect(debugPlayerRequestedRate(), rate, reason: '长按已关 → 不变速');

      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 20));
      await drainTimers(t);
    });

    testWidgets('★ 两个都关 → 方向键完全无动作（但也不漏给硬编码 ±5）', (t) async {
      PlayerGestures.setPcArrowSeekEnabled(false);
      PlayerGestures.setPcArrowHoldEnabled(false);
      await mountPlayer(t);

      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 20));
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 20));
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 20));

      expect(
        debugPlayerSeekByCalls(),
        0,
        reason: '★ 两个开关都关时**一次 seek 都不该有**。'
            '⚠️ 这条专门抓"关掉后事件被放行、落到旧硬编码 ±5 秒"的回归 —— '
            '那种情况下计数器会变成 1。',
      );
      expect(
        debugPlayerRequestedRate(),
        isNot(PlayerGestures.pcArrowHoldRate),
        reason: '两个开关都关 → 不应请求倍速',
      );
      await drainTimers(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ ★★ 手机长按读**手机自己的**配置（不是 PC 的）
  // ═══════════════════════════════════════════════════════════════════
  group('④ ★★ 手机长按读手机配置', () {
    testWidgets('★★ 手机长按倍率 = `longPressRate`，**不是** `pcArrowHoldRate`', (t) async {
      /*
       * 这是 task-15 明确要求的一条：原来手机长按读的是 PC 的配置
       * （`pcForwardRate`），两端隐式耦合。这里把两个值**设成不同**，
       * 然后断言手机用的是自己那个 —— 只有这样才能真正区分。
       *
       * 若把两个值设成相同，测试**永远通过**（无法区分读的是哪个），
       * 那是典型的空断言。
       */
      PlayerGestures.setLongPressRate(1.5); // 手机
      PlayerGestures.setPcArrowHoldRate(4.0); // PC（故意不同）
      PlayerGestures.setLongPressEnabled(true);
      await mountPhone(t);

      expect(
        PlayerGestures.longPressRate,
        isNot(PlayerGestures.pcArrowHoldRate),
        reason: '前提：两个配置值必须不同，否则本用例无从区分',
      );

      // 手机：长按右半屏（用 GestureDetector 的 long press）
      final center = t.getCenter(find.byType(PlayerPage));
      final right = center + const Offset(200, 0);
      final g = await t.startGesture(right);
      await t.pump(const Duration(milliseconds: 700)); // 超过长按阈值
      await t.pump(const Duration(milliseconds: 50));

      expect(
        debugPlayerRequestedRate(),
        1.5,
        reason: '★★ 手机长按必须读**手机自己的** `longPressRate`(1.5)，'
            '而不是 PC 的 `pcArrowHoldRate`(4.0)。读错的话这里会是 4.0。',
      );

      await g.up();
      await t.pump(const Duration(milliseconds: 50));
      expect(debugPlayerRequestedRate(), 1.0, reason: '松手恢复原速');
      await drainTimers(t);
    });

    testWidgets('★ 手机长按左半屏读手机的 `longPressRewindStep`', (t) async {
      PlayerGestures.setLongPressRewindStep(2); // 手机
      PlayerGestures.setPcRewindStep(10); // PC（故意不同）
      PlayerGestures.setLongPressEnabled(true);
      await mountPhone(t);

      expect(PlayerGestures.longPressRewindStep, isNot(PlayerGestures.pcRewindStep),
          reason: '前提：两个快退步长必须不同才能区分');

      final center = t.getCenter(find.byType(PlayerPage));
      final left = center - const Offset(200, 0);
      final g = await t.startGesture(left);
      await t.pump(const Duration(milliseconds: 700));
      await t.pump(const Duration(milliseconds: 50));

      expect(
        debugPlayerRewindTimerActive(),
        isTrue,
        reason: '★ 手机左半屏长按 = 连续快退',
      );
      expect(debugPlayerLastTip(), contains('快退'));

      await g.up();
      await t.pump(const Duration(milliseconds: 50));
      expect(debugPlayerRewindTimerActive(), isFalse);
      await drainTimers(t);
    });

    testWidgets('★ 手机关掉长按 → 长按无动作（可关闭）', (t) async {
      PlayerGestures.setLongPressEnabled(false);
      await mountPhone(t);

      final center = t.getCenter(find.byType(PlayerPage));
      final g = await t.startGesture(center + const Offset(200, 0));
      await t.pump(const Duration(milliseconds: 700));
      await t.pump(const Duration(milliseconds: 50));

      /*
       * ★ 断言是 `isNull` 而不是 `== 1.0`。
       *
       * 关掉开关后，长按回调**根本没有挂载**（`onLongPressStart: null`），
       * 所以连一次倍速请求都不该发生 —— `_lastRateRequest` 保持 null。
       * `== 1.0` 是错的：它会"通过"于一种坏实现（回调仍在跑、
       * 只是恰好请求了 1.0x）。null 才是"真的什么都没做"。
       */
      expect(
        debugPlayerRequestedRate(),
        isNull,
        reason: '★ 用户要求手机长按「可关闭」—— 关掉后**一次倍速请求都不该有**',
      );
      expect(debugPlayerRewindTimerActive(), isFalse,
          reason: '关掉后也不该有连续快退定时器');

      await g.up();
      await t.pump(const Duration(milliseconds: 50));
      await drainTimers(t);
    });

    testWidgets('★ PC 上键盘方向键**不**读手机配置', (t) async {
      /*
       * 反方向也要验一次：PC 长按读的是 `pcArrowHoldRate`。
       * 两个值设成不同，断言 PC 用的是自己那个。
       */
      PlayerGestures.setLongPressRate(1.5); // 手机
      PlayerGestures.setPcArrowHoldRate(4.0); // PC
      await mountPlayer(t);

      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 20));
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 20));

      expect(
        debugPlayerRequestedRate(),
        4.0,
        reason: '★★ PC 方向键长按必须读 PC 的配置(4.0)，'
            '不是手机的 `longPressRate`(1.5)',
      );

      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 20));
      await drainTimers(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ TV 不回归（遥控器也是方向键）
  // ═══════════════════════════════════════════════════════════════════
  group('⑤ TV 方向键不回归', () {
    testWidgets('★ TV 上方向键**仍然**跳秒（走原有 ±10 秒逻辑）', (t) async {
      /*
       * 设计决定：TV **保持现状**（不套用 PC 那套单击/长按状态机）。
       *
       * 理由：
       * ```text
       * ① 用户这次说的是「在**pc**上」—— 没提 TV
       * ② 遥控器长按是**系统层面**的重复键，不同遥控器/盒子行为不一致，
       *    在 TV 上引入"长按=倍速"会把一个稳定的行为变得不可预测
       * ③ TV 现有行为（±10 秒）已被 `isTv ? -10 : -5` 固化并经过实测
       * ```
       * 所以只要钉住"TV 上单击仍然跳秒、且只跳一次"即可 —— 不回归。
       */
      await mountTv(t);

      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));

      expect(
        debugPlayerSeekByCalls(),
        1,
        reason: '★ TV 方向键必须仍然跳秒（本次**不能**影响 TV）',
      );
      expect(debugPlayerRewindTimerActive(), isFalse,
          reason: 'TV 上不该进 PC 那套长按状态机');
      await drainTimers(t);
    });

    testWidgets('★ TV 上方向键**不**读 PC 的方向键配置', (t) async {
      PlayerGestures.setPcArrowSeekEnabled(false); // 关掉 PC 的单击
      await mountTv(t);

      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 30));

      expect(
        debugPlayerSeekByCalls(),
        1,
        reason: '★ 关掉**PC**的开关不应影响 TV —— '
            'TV 的遥控器方向键是独立的键位体系',
      );
      await drainTimers(t);
    });
  });
}
