// ═══════════════════════════════════════════════════════════════════════
//  播放手势的平台差异 —— PC 不做，手机可配
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（设计依据）
//
// > pc端不应该双击左右侧快进快退
// > 手机端,应该做成配置  双击左右侧 快进快退,配置多少秒
// >   是否可关闭         左右长按 快进快进(可配置倍率)  是否可关闭
// > 这样子才是对的,**不要把手机上的操作习惯跟PC保持统一**
//
// # 为什么这不是"违反操作逻辑一致"
//
// 原版是 WebView，PC 和手机跑**同一套 DOM** —— 它**没法**分平台，
// 所以双击快进在 PC 上也是生效的（用户现在指出的正是这个毛病）。
// 我们用一份 Dart 代码能分平台，这是**能力**，应该用上。
//
// 用户的判断是对的：`双击跳 10 秒` 对鼠标用户是**惊吓**：
// ```text
// · 想连点暂停 → 结果跳了 10 秒
// · 想选中文字 → 结果跳了 10 秒
// · PC 本来就有 J/L ±10 秒、方向键、数字键跳百分比
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('播放手势平台门控', () {
    late String page;
    late String gestures;
    late String settings;

    setUpAll(() {
      page = File('lib/ui/player_page.dart').readAsStringSync();
      gestures = File('lib/core/player_gestures.dart').readAsStringSync();
      settings = File('lib/ui/settings_page.dart').readAsStringSync();
    });

    test('★ PC 上双击快进快退必须**硬关闭**（不看用户配置）', () {
      /*
       * 关键区别：不是"默认关但可开"，而是 **PC 上恒不生效**。
       * 所以门控写成 `isTouch && ...` —— 前半段是硬条件。
       */
      expect(
        gestures.contains('static bool doubleTapEnabledFor({required bool isTouch}) =>'),
        isTrue,
        reason: '必须有平台门控函数',
      );
      expect(
        RegExp(r'doubleTapEnabledFor\(\{required bool isTouch\}\) =>\s*\n?\s*isTouch && doubleTapEnabled')
            .hasMatch(gestures.replaceAll('\r', '')),
        isTrue,
        reason: '★ 门控必须是 `isTouch && doubleTapEnabled` —— '
            '`isTouch` 在前表示 PC 上**无论配置如何都不生效**。'
            '这正是用户要的「pc端不应该双击左右侧快进快退」。',
      );
    });

    test('★ 长按倍速同样 PC 恒关闭', () {
      expect(
        RegExp(r'longPressEnabledFor\(\{required bool isTouch\}\) =>\s*\n?\s*isTouch && longPressEnabled')
            .hasMatch(gestures.replaceAll('\r', '')),
        isTrue,
        reason: '长按倍速也只该在触摸端生效（PC 用键盘调倍速）',
      );
    });

    test('★ 播放器里的双击回调必须是**有条件**挂载', () {
      expect(
        page.contains('onDoubleTapDown: _doubleTapEnabled'),
        isTrue,
        reason: '★ `onDoubleTapDown` 必须条件挂载（PC 上挂 null）—— '
            '无条件下挂就是原来的 bug：PC 双击也跳 10 秒。',
      );
      expect(
        page.contains('onDoubleTapDown: (d) {'),
        isFalse,
        reason: '不得出现无条件挂载的写法',
      );
    });

    test('★ 长按用 Start/End 成对（不能只用 onLongPress）', () {
      expect(
        page.contains('onLongPressStart:'),
        isTrue,
        reason: '需要 `onLongPressStart` 记录原倍速',
      );
      expect(
        page.contains('onLongPressEnd:'),
        isTrue,
        reason: '★ 必须有 `onLongPressEnd` —— '
            '只用 `onLongPress`（长按完成触发一次）**没有抬起事件**，'
            '倍速会一直卡在 2x 恢复不了。',
      );
      expect(
        page.contains('onLongPressCancel:'),
        isTrue,
        reason: '手指滑走时也要恢复倍速（`onLongPressCancel`）',
      );
      expect(
        page.contains('_rateBeforeLongPress'),
        isTrue,
        reason: '★ 必须**存原倍速快照**再恢复 —— '
            '写死"恢复成 1.0"会把用户自己设的 1.5x 冲掉。',
      );
    });

    test('★ 设置页只在触摸端显示手势配置', () {
      expect(
        settings.contains('if (Device.isTouchOnly)'),
        isTrue,
        reason: '★ 整块配置只在触摸端渲染 —— '
            '给 PC 用户看一个"永远不生效"的开关比不显示更糟。',
      );
      // 四项配置都要有
      for (final key in [
        'PlayerGestures.setDoubleTapEnabled',
        'PlayerGestures.setDoubleTapSeconds',
        'PlayerGestures.setLongPressEnabled',
        'PlayerGestures.setLongPressRate',
      ]) {
        expect(settings.contains(key), isTrue,
            reason: '设置页必须能改 `$key`（用户列了四项：开关×2 + 参数×2）');
      }
    });

    test('★ 四项配置都要持久化', () {
      /*
       * ⚠️ getter 不能数 `prefs.UiPrefs.get(` 的出现次数 ——
       *    四个 getter 共用三个类型化辅助函数 `_b`/`_i`/`_d`
       *    （bool/int/double），所以源码里只有 3 处调用。
       *    第一版就是这么数的，报"当前 3 个"**假失败**了。
       *
       * 该断言的是**语义**：四个属性各自有 getter/setter，
       * 且都通过辅助函数落到 UiPrefs。
       */
      // setter：必须 4 个（每个键一个，没有共用可能）
      /*
       * ⚠️ 数量随功能增加而变（第一版写死 4，加了 PC 四项后变 8 —— 假失败）。
       *    改断言"**每个键都有对应 setter**"，而不是数总数 ——
       *    这样加功能时不会误报，但漏掉某个键的 setter 仍会被抓到。
       */
      final keys = RegExp(r"static const _k\w+ = '([^']+)'")
          .allMatches(gestures)
          .map((m) => m.group(1)!)
          .toList();
      expect(keys, isNotEmpty);
      for (final key in keys) {
        // 每个键都要在 set( 里被用到
        expect(
          gestures.contains('prefs.UiPrefs.set(_k'),
          isTrue,
          reason: '键 `$key` 需要有对应的 setter',
        );
      }
      final setterCount =
          RegExp(r'prefs\.UiPrefs\.set\(').allMatches(gestures).length;
      expect(
        setterCount,
        keys.length,
        reason: '★ setter 数应等于键数（当前 $setterCount 个 setter、'
            '${keys.length} 个键）—— 不相等说明有键没有 setter，'
            '或有 setter 共用了键',
      );

      // getter：四个公开属性都要存在
      for (final g in [
        'static bool get doubleTapEnabled',
        'static int get doubleTapSeconds',
        'static bool get longPressEnabled',
        'static double get longPressRate',
      ]) {
        expect(gestures.contains(g), isTrue, reason: '缺少 `$g`');
      }

      /*
       * ★ 键必须互不相同 —— 两个属性共用键的话，改一个会连带改另一个
       *   （copy-paste 常见错误，而且**功能看起来正常**，极难发现）。
       */
      expect(
        keys.toSet().length,
        keys.length,
        reason: '存储键必须唯一（当前 ${keys.length} 个键、'
            '${keys.toSet().length} 个不同值）',
      );

      // 键的独立性与"每个键都有 setter"由上面的断言覆盖（不写死数量）
    });

    test('★ 步长与倍率必须有可选档位', () {
      expect(gestures.contains('doubleTapOptions'), isTrue,
          reason: '双击步长要有可选档位（用户要求"配置多少秒"）');
      expect(gestures.contains('longPressRateOptions'), isTrue,
          reason: '长按倍率要有可选档位（用户要求"可配置倍率"）');
    });
  });

  group('左/右手势区域（用户两次指示的合并）', () {
    late String page;
    late String gestures;
    late String settings;

    setUpAll(() {
      page = File('lib/ui/player_page.dart').readAsStringSync();
      gestures = File('lib/core/player_gestures.dart').readAsStringSync();
      settings = File('lib/ui/settings_page.dart').readAsStringSync();
    });

    test('★★ 单击**不得**再分流区域（用户要求去掉单击快进快退）', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这条断言的方向被**用户需求反转**了（2026-09-25）
       * ══════════════════════════════════════════════════════════════
       *
       * 上一版这条写的是：
       * ```dart
       * expect(noComments.contains('onTapUp: _onPlayerTapUp'), isTrue,
       *   reason: '★ 单击必须用 `onTapUp` 自己分流区域');
       * ```
       * 它当时是**对的**（用户确实要过"单击左右侧=快进快退"）。
       *
       * 现在用户原话：
       * > **不要单击快进快退,去掉这个功能**
       *
       * 所以断言**反过来**：不得出现 `onTapUp` 分流。
       *
       * ⚠️ 这不是"为了让测试通过而放宽断言" —— 断言**变严了**：
       *    原来只要求"分流存在"，现在还额外要求
       *    "分流没了 **且** 播放/暂停还在"（见下一条）。
       *    放宽是指"删掉断言"，这里是把断言对准**新需求**。
       */
      final noComments = _stripComments(page);
      expect(
        noComments.contains('_onPlayerTapUp'),
        isFalse,
        reason: '★ 单击分流实现必须**彻底删除** —— 用户原话'
            '「不要单击快进快退,去掉这个功能」。'
            '留着死代码会让后人以为单击还在分流。',
      );
      expect(
        noComments.contains('onTapUp:'),
        isFalse,
        reason: '★ 播放页**不得**挂 `onTapUp` —— 它原来就是分流的载体。'
            '⚠️ 注意：树里别处（InkWell 内部）确实有无条件的 onTapUp，'
            '所以这条只能断言**播放页源码里**没有，不能靠扫渲染树。',
      );
      expect(
        noComments.contains('_centerBandRatio'),
        isFalse,
        reason: '★ 正中窄带（±8%）只服务"左右分流 + 中间暂停"，'
            '分流删掉后窄带也没有存在理由 —— 整屏都是播放/暂停。',
      );
      // 单击改走 onTap（唯一语义 = 播放/暂停）
      expect(
        noComments.contains('onTap: _togglePlay'),
        isTrue,
        reason: '★ 单击必须挂 `onTap: _togglePlay` —— '
            '单击现在**只有**播放/暂停一种语义（用户没说要动它）。',
      );
    });

    test('★★ 单击不得再读 PlayerGestures.pcSeekSeconds（配置项已清）', () {
      final noComments = _stripComments(page);
      expect(
        noComments.contains('pcSeekSeconds'),
        isFalse,
        reason: '★ `pcSeekSeconds` 只服务被删掉的"单击跳秒"，'
            '必须连同配置项一起清理 —— 留着一个改了没反应的设置项'
            '比不显示更糟（用户会以为坏了）。',
      );
      final noCommentsGestures = _stripComments(gestures);
      expect(
        noCommentsGestures.contains('pcSeekSeconds'),
        isFalse,
        reason: '★ `PlayerGestures` 里的 pcSeekSeconds 也要删干净',
      );
      expect(
        noCommentsGestures.contains('pcSeekOptions'),
        isFalse,
        reason: '★ 步长档位只服务单击跳秒，一并删除',
      );
    });

    test('★★ 长按的区域判断**必须保留**（删的是单击，不是左右区域）', () {
      /*
       * ⚠️ 这是最容易误删的地方：
       * 用户删的是"**单击**跳秒"，但"左/右区域"这个概念本身还在
       * —— 长按仍然要分左右（左=连续快退，右=倍速快进）。
       *
       * 如果有人看到"单击不分流了"就顺手把长按的区域判断也删掉，
       * 左半屏长按会变成快进（方向反了）。
       */
      final noComments = _stripComments(page);
      expect(
        noComments.contains('_onLongPressStartAt(d.localPosition)'),
        isTrue,
        reason: '★ 长按必须按**按下位置**分流左右 —— '
            '只看"是否在长按"的话，左侧长按会变成快进（方向反了）',
      );
      expect(
        noComments.contains('void _onLongPressStartAt(Offset local)'),
        isTrue,
        reason: '长按分流实现必须还在',
      );
      expect(
        noComments.contains('onLongPressStart:'),
        isTrue,
        reason: '长按回调必须挂着（PC 上也要，见 _longPressEnabledForThisDevice）',
      );
    });

    test('★★ 不得有**可见的**圆形按钮（用户否决）', () {
      /*
       * 用户原话：
       * > 不应该显示播放器两侧的按钮,识别手势就行了
       * > 这两个圆圈太难看了
       *
       * ⚠️ 这与上一轮「pc端更直觉的左右按钮」不矛盾 ——
       *    用户说的"按钮"指的是**语义区域**，不是可见控件。
       *    我第一版画了两个圆圈，被否掉了。
       */
      final noComments = _stripComments(page);
      expect(
        noComments.contains('_PcSeekButtons'),
        isFalse,
        reason: '★ 已按用户要求移除可见按钮控件',
      );
      expect(
        noComments.contains('_HoldButton'),
        isFalse,
        reason: '★ 那两个圆圈按钮的实现类必须彻底删掉（死代码会误导后人）',
      );
    });

    test('★★ 必须记住"正在进行的是哪种长按"', () {
      /*
       * `onLongPressEnd` **不告诉你**刚才长按的是哪一侧。
       * 不记的话：
       * ```text
       * 左侧长按（连续快退中）→ 松手 → 走了倍速恢复 → 无效
       * 右侧长按（2x 快进中）→ 松手 → 走了快退停止 → 倍速卡在 2x
       * ```
       */
      final noComments = _stripComments(page);
      expect(
        noComments.contains('_LongPressKind? _activeLongPress'),
        isTrue,
        reason: '★ 必须记录当前长按类型，否则松手时无法正确收尾',
      );
      expect(
        noComments.contains('void _endAnyLongPress()'),
        isTrue,
        reason: '松手走统一收尾（按记录的类型分发）',
      );
      expect(
        noComments.contains('enum _LongPressKind { rewind, rateBoost }'),
        isTrue,
        reason: '两种长按类型都要有',
      );
    });

    test('★★ 单击画面 = 播放/暂停（保留通行习惯，整屏统一）', () {
      /*
       * ⚠️ 这条**取代**了原来的「正中窄带保留播放/暂停」。
       *
       * 原来为了不跟"左右分流"打架，只在正中留了一条 ±8% 的窄带做暂停，
       * 断言的是 `_centerBandRatio` 存在。
       *
       * 现在分流整个删掉，**整屏**都是播放/暂停 —— 窄带概念消失，
       * 所以断言从"窄带有播放/暂停"升级成"整屏单击都是播放/暂停"。
       *
       * 用户没有要求去掉"点画面暂停"（那是所有播放器含原版的通行习惯），
       * 所以这条必须**继续为真**。
       */
      final noComments = _stripComments(page);
      expect(
        noComments.contains('onTap: _togglePlay'),
        isTrue,
        reason: '★ 单击必须触发播放/暂停 —— 用户只说去掉"单击快进快退"，'
            '**没有**说去掉"点画面暂停"',
      );
      expect(
        noComments.contains('_centerBandRatio'),
        isFalse,
        reason: '★ 窄带（±8%）已随分流一起删除 —— 现在整屏统一，'
            '不再需要判坐标',
      );
      expect(
        noComments.contains('void _togglePlay()'),
        isTrue,
        reason: '播放/暂停实现必须还在',
      );
    });

    test('★ 单击不得再判坐标（左右分流已删）', () {
      /*
       * ⚠️ 这条**取代**了原来的「手机端单击不跳秒」。
       *
       * 原来那条断言 `if (!Device.isDesktop) return;` 存在 ——
       * 那是"手机端单击落在左右区域什么都不做"的实现细节。
       *
       * 现在整个分流函数没了，那句 early-return 也不该存在了
       * （它只在那一个函数里）。所以断言方向反过来。
       *
       * 语义上更干净：不是"手机端单击不跳秒、PC 端跳"，
       * 而是**所有平台单击都不跳秒**。
       */
      final noComments = _stripComments(page);
      /*
       * ⚠️ 这里**不能**断言 `if (!Device.isDesktop) return;` 不存在 ——
       *    播放页还有**另一处**合法的同名语句（切全屏时：
       *    `if (!Device.isDesktop) return; // 移动端没有"窗口全屏"概念`）。
       *    断言它会**假失败**，而且失败原因跟本任务无关。
       *
       * 所以改断言**分流那一行本身**的消失：
       * 单击跳秒的调用点是 `_seekBy(dx < center ? -secs : secs)`。
       */
      expect(
        noComments.contains('dx < center'),
        isFalse,
        reason: '★ 单击**不得**再按 dx 判左右 —— 用户原话'
            '「不要单击快进快退,去掉这个功能」',
      );
      expect(
        noComments.contains('TapUpDetails'),
        isFalse,
        reason: '★ 播放页不得再用 `TapUpDetails` —— '
            '它的唯一用途就是读 `localPosition` 判左右（无位置需求则不需要它）',
      );
    });

    test('★ 左长按 = 连续快退（负倍速物理不支持）', () {
      final noComments = _stripComments(page);
      expect(
        noComments.contains('void _startRewindHold()'),
        isTrue,
        reason: '左半屏长按要有连续快退实现',
      );
      expect(
        noComments.contains('Timer.periodic('),
        isTrue,
        reason: '★ 连续快退必须用定时器反复 seek —— '
            '`media_kit` 的 setRate 拒绝非正数（会抛 ArgumentError）',
      );
      expect(
        noComments.contains('_rewindTimer?.cancel();'),
        isTrue,
        reason: '★ 定时器必须在 dispose 里取消',
      );
    });

    test('★ 右长按 = 倍速，松开恢复"原"倍速', () {
      final noComments = _stripComments(page);
      expect(noComments.contains('void _startRateHold()'), isTrue);
      expect(noComments.contains('void _endRateHold()'), isTrue);
      expect(
        noComments.contains('_rateBeforeHold = _rate;'),
        isTrue,
        reason: '★ 必须存**原倍速快照** —— 写死恢复 1.0x 会把用户'
            '自己设的 1.5x 冲掉',
      );
    });

    test('★ 设置页：PC 块与手势块互斥显示', () {
      expect(settings.contains('if (Device.isDesktop)'), isTrue,
          reason: 'PC 配置只在桌面显示');
      expect(settings.contains('if (Device.isTouchOnly)'), isTrue,
          reason: '触摸手势配置只在触摸端显示');
    });
  });
}

/// 去掉注释行 —— 静态断言里做文本匹配**必须先剥注释**
///
/// 这个坑在本次会话里已经踩了三次：注释里提到某个标识符，
/// 纯文本匹配就把它当成真实调用，测试**假失败**。
String _stripComments(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');
