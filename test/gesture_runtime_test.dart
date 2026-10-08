// ═══════════════════════════════════════════════════════════════════════
//  播放手势的平台差异 —— 直接跑**生产类**（不是复刻一份）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户要求（设计依据）
//
// > pc端不应该双击左右侧快进快退
// > 手机端,应该做成配置  双击左右侧 快进快退,配置多少秒
// >   是否可关闭         左右长按 快进快进(可配置倍率)  是否可关闭
// > 这样子才是对的,**不要把手机上的操作习惯跟PC保持统一**
//
// # ⚠️ 我第一版把这条测试写成了废测试
//
// 第一版我在测试里**复刻**了一份门控函数：
// ```dart
// GestureTapDownCallback? _gateDoubleTap({required bool isTouch}) =>
//     isTouch ? (_) {} : null;   // ← 这是测试自己写的，不是生产代码
// ```
// 然后断言"PC 上是 null"。它当然通过 —— 因为它测的是**我刚写的那行**，
// 而不是 `PlayerGestures`。生产代码改坏了它照样绿。
//
// 这正是我刚在标题栏那轮踩过的坑：**测了抽出来的影子，没测真实路径**。
//
// # 现在改成直接跑生产类
//
// `PlayerGestures` 是纯函数 + `UiPrefs` 读写，**没有 widget 依赖**，
// 可以在测试里直接调 —— 所以没有任何理由用影子实现。
//
// ```text
// 能直接调生产代码 → 就必须直接调（哪怕要搭一点环境）
// 实在调不了      → 才退而求其次读源码，并在注释里写明原因
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/player_gestures.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

void main() {
  group('播放手势平台门控（跑真实 PlayerGestures）', () {
    setUp(() {
      // 清掉可能残留的偏好，保证用例互不影响
      for (final k in [
        'player.gesture.doubleTap.enabled',
        'player.gesture.doubleTap.seconds',
        'player.gesture.longPress.enabled',
        'player.gesture.longPress.rate',
      ]) {
        UiPrefs.set(k, '');
      }
      // 空字符串在 `_b`/`_i`/`_d` 里会被 tryParse 失败 → 回落默认值，
      // 等价于"未设置"。这里再显式恢复一遍默认。
      PlayerGestures.setDoubleTapEnabled(true);
      PlayerGestures.setDoubleTapSeconds(PlayerGestures.defaultDoubleTapSeconds);
      PlayerGestures.setLongPressEnabled(true);
      PlayerGestures.setLongPressRate(PlayerGestures.defaultLongPressRate);
    });

    test('★★ PC 上双击快进恒不生效 —— 哪怕用户在设置里打开了', () {
      /*
       * 这是用户要求的核心语义：
       * > pc端不应该双击左右侧快进快退
       *
       * 关键在于"**哪怕配置为开**"—— 不是"默认关但可开"。
       * 所以先把配置设成开，再断言 PC 上仍然是 false。
       */
      PlayerGestures.setDoubleTapEnabled(true);

      expect(
        PlayerGestures.doubleTapEnabledFor(isTouch: false),
        isFalse,
        reason: '★ PC 上必须**恒为 false** —— 用户明确说「pc端不应该'
            '双击左右侧快进快退」。即使配置为开也不能生效：'
            'PC 有 J/L/方向键，双击那一跳对鼠标用户是误触。',
      );
    });

    test('★ 触摸端双击按配置生效，且能关掉', () {
      PlayerGestures.setDoubleTapEnabled(true);
      expect(PlayerGestures.doubleTapEnabledFor(isTouch: true), isTrue,
          reason: '触摸端默认开（手机没有键盘，手势是唯一快速定位手段）');

      PlayerGestures.setDoubleTapEnabled(false);
      expect(PlayerGestures.doubleTapEnabledFor(isTouch: true), isFalse,
          reason: '★ 用户要求「是否可关闭」—— 关掉后触摸端也不该生效');
    });

    test('★★ PC 上长按倍速恒不生效 —— 哪怕配置为开', () {
      PlayerGestures.setLongPressEnabled(true);
      expect(
        PlayerGestures.longPressEnabledFor(isTouch: false),
        isFalse,
        reason: 'PC 上长按倍速必须恒关（键盘能调倍速，且长按会误触）',
      );
    });

    test('★ 触摸端长按按配置生效，且能关掉', () {
      PlayerGestures.setLongPressEnabled(true);
      expect(PlayerGestures.longPressEnabledFor(isTouch: true), isTrue);

      PlayerGestures.setLongPressEnabled(false);
      expect(PlayerGestures.longPressEnabledFor(isTouch: true), isFalse,
          reason: '用户要求「是否可关闭」');
    });

    test('★ 双击步长可配置（用户要求"配置多少秒"）', () {
      for (final secs in PlayerGestures.doubleTapOptions) {
        PlayerGestures.setDoubleTapSeconds(secs);
        expect(PlayerGestures.doubleTapSeconds, secs,
            reason: '步长 $secs 秒应能读回');
      }

      PlayerGestures.setDoubleTapSeconds(15);
      expect(
        PlayerGestures.doubleTapStep(forward: true),
        const Duration(seconds: 15),
        reason: '快进应返回正数',
      );
      expect(
        PlayerGestures.doubleTapStep(forward: false),
        const Duration(seconds: -15),
        reason: '快退应返回负数（左侧）',
      );
    });

    test('★ 长按倍率可配置（用户要求"可配置倍率"）', () {
      for (final r in PlayerGestures.longPressRateOptions) {
        PlayerGestures.setLongPressRate(r);
        expect(PlayerGestures.longPressRate, r, reason: '倍率 $r x 应能读回');
      }
    });

    test('★ 默认值合理（用户没进设置前的手感）', () {
      expect(PlayerGestures.defaultDoubleTapSeconds, 10,
          reason: '默认 10 秒 —— 与原版「J L ±10 秒 · 双击左右侧同效」一致，'
              '不改变既有用户的手感');
      expect(PlayerGestures.defaultLongPressRate, 2.0,
          reason: '默认 2x —— 手机播放器的通行默认值');
      expect(PlayerGestures.doubleTapOptions, contains(10),
          reason: '10 秒必须是一个可选项 —— 否则老用户升上来会觉得"变快了"。');
    });
  });
}
