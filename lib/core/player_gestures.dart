// ═══════════════════════════════════════════════════════════════════════
//  播放手势配置（手机端）—— 2026-09-24 用户明确需求
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（这是设计依据）
//
// > pc端不应该双击左右侧快进快退
// > 手机端,应该做成配置  双击左右侧 快进快退,配置多少秒
// >   是否可关闭         左右长按 快进快进(可配置倍率)  是否可关闭
// > 这样子才是对的,不要把手机上的操作习惯跟PC保持统一
//
// # 为什么必须分平台，不能"一套配置全平台通用"
//
// 两者是**不同的输入范式**，不是同一个功能的两种皮肤：
//
// ```text
// PC   鼠标 + 键盘。双击左右侧 = 误触（用户想选中文字/连点暂停，
//      结果跳了 10 秒）；而且键盘有 J/L/方向键，根本不需要手势
// 手机 只有触摸。没有键盘，手势是**唯一**的快速定位手段
// ```
// 用户说得对：**不该把手机的交互习惯套到 PC 上**。
//
// # 可配置项（照用户列的四条）
//
// ```text
// ① 双击左右侧快进快退   开/关
// ② 双击步长             5 / 10 / 15 / 30 秒
// ③ 长按左右侧倍速播放   开/关
// ④ 长按倍率             1.5x / 2x / 3x
// ```
// 四条都持久化（走 `UiPrefs`，与原版 localStorage 等价）。
//
// # ★ PC 端改用**屏幕上的左右按钮**（用户第二次细化，2026-09-24）
//
// 用户原话：
// > 而且pc端更直觉的左右按钮 单点是快进快退(可配置)
// > 长按是倍速,右是快进倍速(可配置) 左是 快退(可配置)
//
// 于是 PC 端的交互变成：
// ```text
// 左按钮  单击 → 快退 N 秒（可配）
//        长按 → **连续快退**（按住期间反复后退，可配每步秒数）
// 右按钮  单击 → 快进 N 秒（可配）
//        长按 → 倍速快进（可配倍率），松开恢复原速
// ```
//
// # ★★★ 但"单击"这一列被用户**删掉了**（2026-09-25）
//
// 用户原话：
// > **不要单击快进快退,去掉这个功能**
//
// 所以上面那张表里的**单击两行作废**，PC 端现在是：
// ```text
// 左半屏  长按 → 连续快退（每步可配）
// 右半屏  长按 → 倍速快进（可配倍率），松开恢复原速
// 整屏    单击 → 播放/暂停   ← 不再跳秒
// ```
// 对应地，`pcSeekSeconds` / `pcSeekOptions` / `defaultPcSeekSeconds`
// **整组删掉** —— 它们只服务被删掉的"单击跳秒"。
//
// ⚠️ 删除判据（别删错）：`pcSeekSeconds` 只在
//    `_onPlayerTapUp`（单击分流）里被读过**一次**，没有第二个消费者。
//    而同一块里的 `pcForwardRate` / `pcRewindStep` **仍被长按使用**，
//    所以必须保留 —— 详见下面每个 getter 的说明。
//
// # ⚠️ 「左长按 = 倒放」物理上做不到
//
// `media_kit` 的 `setRate` 明确拒绝非正数：
// ```dart
// // media_kit-1.2.6/lib/src/player/native/player/real.dart:801
// if (rate <= 0.0) {
//   throw ArgumentError.value(rate, 'rate', 'Must be greater than 0.0');
// }
// ```
// 底层 mpv 本身可以倒放（负 speed），但 media_kit 在 Dart 层拦掉了。
// 所以左长按做成**连续快退**（定时器反复 seek）——
// 这也是绝大多数播放器对"长按左键"的实现方式。

import 'package:flutter/services.dart';

import 'ui_prefs.dart' as prefs;

/// 播放手势配置
///
/// 只对**触摸端**生效（手机/TV 触摸）。PC 上这些手势一律关闭 ——
/// 见文件头的说明。
class PlayerGestures {
  // ── 存储键（带前缀，避免和别的偏好撞）──
  static const _kDoubleTapEnabled = 'player.gesture.doubleTap.enabled';
  static const _kDoubleTapSeconds = 'player.gesture.doubleTap.seconds';
  static const _kLongPressEnabled = 'player.gesture.longPress.enabled';
  static const _kLongPressRate = 'player.gesture.longPress.rate';

  /*
   * ★ 手机长按“快退”那一侧的每步秒数
   *
   * 为什么手机要**自己的**一个键：
   * 之前手机长按读的是 `pcRewindStep` —— 两个端共用一个值，
   * 于是“改 PC 的快退步长会连带改掉手机的”。用户明确要求两端
   * 不同的操作习惯，那就不能有这种隐式耦合。
   */
  static const _kLongPressRewindStep = 'player.gesture.longPress.rewindStep';

  /*
   * ── PC **键盘方向键**（用户 2026-09-25 明确要求）──
   *
   * > 在pc上,小键盘的左右按键 单击 应该是步数控制,长按是 快进快退
   * > 这两个都是可配置 可关闭的
   *
   * ★ 用户强调「这两个配置开关是单独配置的」——
   *   所以单击与长按各自一个开关，**不共用**（见 `PcArrowGesture`）。
   */
  static const _kPcArrowSeekEnabled = 'player.pcArrow.seek.enabled';
  static const _kPcArrowSeekSeconds = 'player.pcArrow.seek.seconds';
  static const _kPcArrowHoldEnabled = 'player.pcArrow.hold.enabled';
  static const _kPcArrowHoldRate = 'player.pcArrow.hold.rate';

  /*
   * ── PC 左右区域的长按（用户第二次细化）──
   *
   * ⚠️ 原来这里有**四个**键，现在只剩三个 ——
   *    `player.pcButtons.seekSeconds`（单击步长）已随"单击跳秒"一起删除
   *    （2026-09-25 用户要求）。剩下的三个都服务**长按**，全部保留。
   *
   * ⚠️ 已删掉的键**不做数据迁移**：老用户 localStorage 里那个残留值
   *    从此不再被读。留着不动是最安全的 —— 删数据反而有风险，
   *    而一个没人读的偏好项不会造成任何可见影响。
   */
  static const _kPcButtonsEnabled = 'player.pcButtons.enabled';
  static const _kPcForwardRate = 'player.pcButtons.forwardRate';
  static const _kPcRewindStep = 'player.pcButtons.rewindStep';

  // ── 默认值 ──
  //
  // ⚠️ 默认**开**（手机端）—— 用户没进设置前就能用上，
  //    这与"手势是触摸端唯一快速定位手段"的判断一致。
  //    但 PC 端不看这个值（见 `doubleTapEnabledFor`）。
  static const int defaultDoubleTapSeconds = 10;
  static const double defaultLongPressRate = 2.0;

  /// PC 右区域长按的默认倍率
  static const double defaultPcForwardRate = 2.0;

  /// PC 左区域长按「连续快退」的默认每步秒数
  static const int defaultPcRewindStep = 10;

  /// 双击步长的可选项（秒）
  ///
  /// 5 太碎、30 太粗，但都留着 —— 用户按自己习惯选。
  static const List<int> doubleTapOptions = [5, 10, 15, 30];

  /// PC 方向键**单击**步长默认值（秒）
  ///
  /// ★ 默认 5 是**刻意的**：改动前 PC 方向键就是硬编码 ±5 秒
  ///   （`_seekBy(widget.isTv ? -10 : -5)`）——
  ///   默认值不变才不会让老用户升上来觉得“手感变了”。
  static const int defaultPcArrowSeekSeconds = 5;

  /// PC 方向键**长按**倍率默认值
  static const double defaultPcArrowHoldRate = 2.0;

  /// PC 方向键单击步长的可选档位（秒）
  static const List<int> pcArrowSeekSecondsOptions = [2, 5, 10, 15, 30];

  /// PC 方向键长按倍率的可选档位
  static const List<double> pcArrowHoldRateOptions = [1.5, 2.0, 3.0, 4.0];

  /// 手机长按“快退”每步秒数的可选档位
  ///
  /// 与 `pcRewindStepOptions` 同档 —— 连续快退时步子太大会跳过内容。
  static const List<int> longPressRewindStepOptions = [2, 5, 10];

  /// 长按倍率的可选项
  static const List<double> longPressRateOptions = [1.5, 2.0, 2.5, 3.0];

  /// PC 右区域长按倍率的可选项
  static const List<double> pcForwardRateOptions = [1.25, 1.5, 2.0, 3.0];

  /// PC 左区域长按「连续快退」每步秒数的可选项
  ///
  /// 比原来的单击步长小一档更实用（连续快退时步子太大会跳过内容）。
  static const List<int> pcRewindStepOptions = [2, 5, 10];

  static bool _b(String key, bool fallback) {
    final v = prefs.UiPrefs.get(key);
    if (v == null) return fallback;
    return v == '1';
  }

  static int _i(String key, int fallback) {
    final v = prefs.UiPrefs.get(key);
    if (v == null) return fallback;
    return int.tryParse(v) ?? fallback;
  }

  static double _d(String key, double fallback) {
    final v = prefs.UiPrefs.get(key);
    if (v == null) return fallback;
    return double.tryParse(v) ?? fallback;
  }

  // ── 读 ──

  /// 双击左右侧快进快退是否启用（**触摸端**）
  static bool get doubleTapEnabled => _b(_kDoubleTapEnabled, true);

  /// 双击步长（秒）
  static int get doubleTapSeconds =>
      _i(_kDoubleTapSeconds, defaultDoubleTapSeconds);

  /// 长按左右侧倍速播放是否启用（**触摸端**）
  static bool get longPressEnabled => _b(_kLongPressEnabled, true);

  /// 长按时的播放倍率
  static double get longPressRate => _d(_kLongPressRate, defaultLongPressRate);

  // ── PC 左右区域的长按 ──

  /// PC 左右区域手势是否启用
  ///
  /// ⚠️ 现在它只管**长按**了（单击跳秒已按用户要求删除）——
  ///    名字里的 "Buttons" 是历史遗留（曾经真的画过两个圆圈按钮，
  ///    后来用户否决了可见控件，改成纯手势区域，见文件头）。
  static bool get pcButtonsEnabled => _b(_kPcButtonsEnabled, true);

  /// PC 右区域长按的倍率
  static double get pcForwardRate =>
      _d(_kPcForwardRate, defaultPcForwardRate);

  /// PC 左区域长按「连续快退」的每步秒数
  static int get pcRewindStep => _i(_kPcRewindStep, defaultPcRewindStep);

  // ── PC 键盘方向键 ──

  /// PC 方向键**单击**是否做步数控制
  static bool get pcArrowSeekEnabled => _b(_kPcArrowSeekEnabled, true);

  /// PC 方向键单击跳多少秒
  static int get pcArrowSeekSeconds =>
      _i(_kPcArrowSeekSeconds, defaultPcArrowSeekSeconds);

  /// PC 方向键**长按**是否做快进快退
  static bool get pcArrowHoldEnabled => _b(_kPcArrowHoldEnabled, true);

  /// PC 方向键长按快进的倍率
  static double get pcArrowHoldRate =>
      _d(_kPcArrowHoldRate, defaultPcArrowHoldRate);

  /// 手机长按左侧「连续快退」的每步秒数（**手机自己的**）
  static int get longPressRewindStep =>
      _i(_kLongPressRewindStep, defaultPcRewindStep);

  // ── 写 ──

  static void setDoubleTapEnabled(bool v) =>
      prefs.UiPrefs.set(_kDoubleTapEnabled, v ? '1' : '0');

  static void setDoubleTapSeconds(int v) =>
      prefs.UiPrefs.set(_kDoubleTapSeconds, '$v');

  static void setLongPressEnabled(bool v) =>
      prefs.UiPrefs.set(_kLongPressEnabled, v ? '1' : '0');

  static void setLongPressRate(double v) =>
      prefs.UiPrefs.set(_kLongPressRate, '$v');

  static void setPcButtonsEnabled(bool v) =>
      prefs.UiPrefs.set(_kPcButtonsEnabled, v ? '1' : '0');

  static void setPcForwardRate(double v) =>
      prefs.UiPrefs.set(_kPcForwardRate, '$v');

  static void setPcRewindStep(int v) =>
      prefs.UiPrefs.set(_kPcRewindStep, '$v');

  static void setPcArrowSeekEnabled(bool v) =>
      prefs.UiPrefs.set(_kPcArrowSeekEnabled, v ? '1' : '0');

  static void setPcArrowSeekSeconds(int v) =>
      prefs.UiPrefs.set(_kPcArrowSeekSeconds, '$v');

  static void setPcArrowHoldEnabled(bool v) =>
      prefs.UiPrefs.set(_kPcArrowHoldEnabled, v ? '1' : '0');

  static void setPcArrowHoldRate(double v) =>
      prefs.UiPrefs.set(_kPcArrowHoldRate, '$v');

  static void setLongPressRewindStep(int v) =>
      prefs.UiPrefs.set(_kLongPressRewindStep, '$v');

  // ── 平台门控（**核心**）──

  /// 该平台上「双击左右侧快进快退」是否生效
  ///
  /// # 为什么 PC 上恒为 false（不看用户配置）
  ///
  /// 用户原话：**「pc端不应该双击左右侧快进快退」**。
  /// 不是"默认关闭但可以打开"，而是**PC 上不该有这个行为**：
  /// ```text
  /// · 用户双击往往是误触（想连点暂停、想选中文字）
  /// · PC 有键盘：J/L ±10 秒、方向键、数字键跳百分比
  /// · 双击一下跳 10 秒，对鼠标用户是**惊吓**而非便利
  /// ```
  /// 所以这里硬编码 false —— **连设置项都不给**（PC 上不显示这一块），
  /// 避免用户开了之后觉得"怎么这么难用"。
  ///
  /// ⚠️ 这与你之前定的「操作逻辑必须和原版完全一致」不冲突：
  ///    原版是 WebView，PC 和手机跑的是**同一套 DOM**，
  ///    所以它没法分平台。我们能用同一份 Dart 代码分平台，
  ///    这是**能力**，应该用上。
  static bool doubleTapEnabledFor({required bool isTouch}) =>
      isTouch && doubleTapEnabled;

  /// 该平台上「长按倍速播放」是否生效
  ///
  /// 同上：PC 恒 false。PC 用数字键/`.``,` 调倍速，不需要长按。
  static bool longPressEnabledFor({required bool isTouch}) =>
      isTouch && longPressEnabled;

  /// 该平台上「PC 左右区域手势」是否生效
  ///
  /// 只桌面生效 —— 手机/TV 上有触摸手势和遥控器。
  ///
  /// ⚠️ 它现在只管**长按**（单击跳秒已按用户要求删除，2026-09-25）。
  static bool pcButtonsEnabledFor({required bool isDesktop}) =>
      isDesktop && pcButtonsEnabled;

  /// 该平台上 PC 方向键**单击步数**是否生效
  ///
  /// ★ 与 `pcArrowHoldEnabledFor` 是**两个独立的开关** ——
  ///   用户原话：「这两个配置开关是单独配置的」。
  static bool pcArrowSeekEnabledFor({required bool isDesktop}) =>
      isDesktop && pcArrowSeekEnabled;

  /// 该平台上 PC 方向键**长按快进快退**是否生效
  static bool pcArrowHoldEnabledFor({required bool isDesktop}) =>
      isDesktop && pcArrowHoldEnabled;

  /// 双击步长（按方向带符号）—— 只在启用时有意义
  ///
  /// [forward] true = 右侧（快进），false = 左侧（快退）
  static Duration doubleTapStep({required bool forward}) => Duration(
        seconds: forward ? doubleTapSeconds : -doubleTapSeconds,
      );
}


// ═══════════════════════════════════════════════════════════════════════
//  PC 键盘方向键：单击 = 步数控制，长按 = 快进快退（用户 2026-09-25）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > 我的意思是在pc上,**小键盘的左右按键 单击 应该是步数控制**,
// > **长按是 快进快退**
// > 这两个都是**可配置 可关闭**的
//
// # 为什么判定逻辑放在这里，而不是写在 `player_page.dart::_onKey` 里
//
// `_onKey` 是 `_PlayerPageState` 的**私有方法**，而真跑一个 `PlayerPage`
// 要 media_kit + 平台通道（重且脆 —— `episode_strip_test.dart` 的头注释
// 自己写了这一点）。本仓库的既定规则（见 `gesture_runtime_test.dart` 头）：
//
// ```text
// 能直接调生产代码 -> 就必须直接调（哪怕要搭一点环境）
// 实在调不了      -> 才退而求其次读源码，并在注释里写明原因
// ```
//
// 所以"单击还是长按"这个判定做成**无 Flutter 依赖的纯逻辑**，
// 测试直接喂真事件序列给这个类 —— 不是复刻一份影子实现。
//
// # 为什么要用状态机，而不是"看见 KeyRepeatEvent 就当长按"
//
// 因为**两个开关是独立的**（用户强调「这两个配置开关是单独配置的」）。
// 独立的语义落在这里：
// ```text
// 关掉「单击」  -> down 不跳秒，但 repeat 仍能进长按     （长按不受影响）
// 关掉「长按」  -> down 跳秒，但 repeat 被忽略          （单击不受影响）
// ```
// 把开关判断写在状态机内部，才能让"独立"这件事**可测**；
// 散在 `_onKey` 里的 `if` 是测不到的。
//
// # 一次「按住」的完整事件序列
//
// ```text
// 轻点   down ──────────────── up           -> stepSeek（一次）
// 长按   down ── repeat repeat ... ── up    -> stepSeek, holdStart, holdEnd
// ```
//
// ★ 单击**立即**在 down 上执行（零延迟）——
//   若改成"等 500ms 看有没有 repeat 再决定"，每一次轻点都会顿一下，
//   而方向键步进是高频操作，那点延迟手感上很明显。
//   代价是长按时会先跳一步再进倍速 —— **这是刻意的**：
//   它同时给了"按键已生效"的即时反馈，与多数播放器一致。

/// PC 方向键收到的**键盘事件**类型
///
/// ⚠️ `holdTimeout` 不是 Flutter 的事件，是**超时兜底**：
///    少数平台不发 `KeyRepeatEvent`（或者被输入法/系统设置关掉了重复），
///    只靠 repeat 判定的话那些机器上长按永远不会触发。
///    所以按下时同时起一个计时器，谁先到算谁。
enum PcArrowEvent {
  /// 首次按下
  down,

  /// 系统按键重复（Flutter 的 `KeyRepeatEvent`）
  repeat,

  /// 超时兜底（见上）
  holdTimeout,

  /// 松开（Flutter 的 `KeyUpEvent`）
  up,
}

/// PC 方向键这次事件**应该执行什么**
enum PcArrowAction {
  /// 什么都不做（对应功能被关掉了，或事件不该有动作）
  none,

  /// 单击步数控制：按 `pcArrowSeekSeconds` 跳一步
  stepSeek,

  /// 长按开始：切到 `pcArrowHoldRate` 倍速（左方向键则是连续快退）
  holdStart,

  /// 长按结束：恢复原倍速
  holdEnd,
}

/// PC 方向键「单击 / 长按」的判定状态机
///
/// 无 Flutter 依赖（`LogicalKeyboardKey` 需要 `package:flutter/services.dart`，
/// 那会让这个配置层被 UI 层绑住）—— 所以方向用 `-1`/`+1` 表示，
/// 由调用方把 `LogicalKeyboardKey.arrowLeft` 映射过来。
///
/// 配置是**读实时值**（不是构造时快照）：与文件里其它 getter 一致 ——
/// 用户在设置页改完应当**立即**生效，不需要重进播放页。
class PcArrowGesture {
  /// 当前按住的方向：`-1` 左、`+1` 右、`0` 没按住
  int _dir = 0;

  /// 当前这一次按住**是否已经进入长按**
  bool _holding = false;

  /// 当前按住的方向（`0` = 没按）
  int get direction => _dir;

  /// 当前是否处于长按中（播放页据此判断松手要不要恢复倍速）
  bool get isHolding => _holding;

  /// 喂一个事件，返回该执行的动作
  ///
  /// [direction] `-1` = 左方向键（快退），`+1` = 右方向键（快进）
  PcArrowAction handle({
    required int direction,
    required PcArrowEvent event,
  }) {
    switch (event) {
      case PcArrowEvent.down:
        /*
         * 已经在按住时又来一个 down：忽略。
         *
         * 正常不会发生（Flutter 不会连发 KeyDownEvent），但
         * 「按着不放并且另一个方向键也按下」时，系统的行为在
         * 不同平台上不一致 —— 与其猜，不如明确"第一个按下的赢"，
         * 否则会出现两个方向的倍速叠加这种荒唐结果。
         */
        if (_dir != 0) return PcArrowAction.none;
        _dir = direction;
        _holding = false;
        // 单击**立即**执行（见文件里关于"零延迟"的说明）
        return PlayerGestures.pcArrowSeekEnabled
            ? PcArrowAction.stepSeek
            : PcArrowAction.none;

      case PcArrowEvent.repeat:
      case PcArrowEvent.holdTimeout:
        if (_dir == 0) return PcArrowAction.none; // 没先按下 -> 不该有动作
        if (_holding) return PcArrowAction.none; // 已经长按了，不重复触发
        if (!PlayerGestures.pcArrowHoldEnabled) return PcArrowAction.none;
        _holding = true;
        return PcArrowAction.holdStart;

      case PcArrowEvent.up:
        if (_dir == 0) return PcArrowAction.none;
        final wasHolding = _holding;
        _dir = 0;
        _holding = false;
        // 只有真的进过长按才需要恢复倍速
        return wasHolding ? PcArrowAction.holdEnd : PcArrowAction.none;
    }
  }

  /// 清空状态（播放页 dispose / 失焦时调，避免倍速卡住）
  ///
  /// ⚠️ 返回是否**需要恢复倍速** —— 调用方据此决定要不要收尾，
  ///    不能直接丢掉：用户按着方向键时切走页面，
  ///    倍速会永远停在 3x。
  bool reset() {
    final wasHolding = _holding;
    _dir = 0;
    _holding = false;
    return wasHolding;
  }
}


/// 长按判定的超时兜底时长
///
/// 与 Flutter 的 `kLongPressTimeout`（500ms）同值 —— 保持"长按"在
/// 触摸手势与键盘按键上**手感一致**，用户不需要学两套时间。
///
/// ⚠️ 它只做兜底：正常路径是系统发 `KeyRepeatEvent`（约 500ms 后开始）。
///    少数平台/输入法不发重复事件，那时靠这个计时器兜底，
///    否则那些机器上长按**永远不会触发**。
const Duration kPcArrowHoldDelay = Duration(milliseconds: 500);

/// PC 方向键的路由器：把 Flutter 的按键事件翻译成 [PcArrowAction]
///
/// # 为什么需要这一层
///
/// [PcArrowGesture] 只认"方向 + 事件类型"这种抽象输入，好处是无 Flutter
/// 依赖、好测；但 `player_page.dart::_onKey` 拿到的是
/// `LogicalKeyboardKey` 与 `KeyDownEvent/KeyRepeatEvent/KeyUpEvent`。
/// 翻译这一步**也是生产逻辑**（映射错了整个功能就是坏的），
/// 所以它同样放在这里被测试直接覆盖，而不是散在 `_onKey` 里。
class PcArrowKeyRouter {
  final PcArrowGesture _gesture = PcArrowGesture();

  /// 当前是否在长按中
  bool get isHolding => _gesture.isHolding;

  /// 当前按住的方向（`0` = 没按）
  int get direction => _gesture.direction;

  /// 是不是本路由器负责的键（只接管 ←/→）
  ///
  /// ⚠️ ↑/↓ 是**音量**，用户明确没让改（task-15 第 5 条），
  ///    所以这里不能把它们一起接管 —— 否则音量键会静默失效。
  static bool isArrowKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight;

  /// 方向：左 = `-1`（快退），右 = `+1`（快进），其它 = `0`
  static int directionOf(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.arrowLeft) return -1;
    if (k == LogicalKeyboardKey.arrowRight) return 1;
    return 0;
  }

  /// Flutter 事件 -> [PcArrowEvent]
  ///
  /// ⚠️ `KeyRepeatEvent` 不是 `KeyDownEvent` 的子类（两者都直接继承
  ///    `KeyEvent`），所以**必须单独判**。漏判的话长按永远不会触发 ——
  ///    这正是原来"键盘长按完全没处理"的表现。
  static PcArrowEvent? eventOf(KeyEvent e) {
    if (e is KeyDownEvent) return PcArrowEvent.down;
    if (e is KeyRepeatEvent) return PcArrowEvent.repeat;
    if (e is KeyUpEvent) return PcArrowEvent.up;
    return null;
  }

  /// 喂一个真实按键事件，返回该执行的动作
  PcArrowAction handleKeyEvent(KeyEvent event) {
    final dir = directionOf(event.logicalKey);
    if (dir == 0) return PcArrowAction.none;
    final ev = eventOf(event);
    if (ev == null) return PcArrowAction.none;
    return _gesture.handle(direction: dir, event: ev);
  }

  /// 超时兜底（`kPcArrowHoldDelay` 到点时调用）
  PcArrowAction handleHoldTimeout({required int direction}) =>
      _gesture.handle(direction: direction, event: PcArrowEvent.holdTimeout);

  /// 清空状态；返回是否需要在收尾时恢复倍速
  bool reset() => _gesture.reset();
}
