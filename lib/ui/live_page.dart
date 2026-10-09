// ═══════════════════════════════════════════════════════════════════════
//  直播页 —— 对齐原版 LiveView.vue（484 行）
// ═══════════════════════════════════════════════════════════════════════
//
// 频道列表 + 节目单 + 时移回看。
//
// # ★ 关于「能力位驱动」（原版文件头这么写，但**原版没实现**）
//
// 原版 `LiveView.vue:5` 的注释是：
// > 能力位驱动：Provider 声明 `capabilities.epg` / `timeshift` 才显示对应功能。
//
// 但**原版整个 586 行里没有任何一处读 `capabilities`**
// （全仓 grep 只在 `SettingsView.vue` 里有 9 处，直播页 0 处）。
// 它实际的判据是**数据驱动**的：
// ```ts
// epg.value = await liveApi.epg(activeProvider.value, ch.id);  // 失败就空
// ```
// 有 EPG 数据就显示节目单，没有就显示「暂无节目单」空态。
//
// 而本机真实数据里这两件事是等价的 —— 唯一声明 `epg` 的源
// （`.probe/testdata/plugins/cctv.js:374`）同时也实现了 `epg()`：
// ```js
// capabilities: { vod: true, live: true, epg: true, timeshift: true, … }
// async epg(channelId)  { … }
// async timeshift(…)    { … }
// ```
//
// ⚠️ 所以这里**不**加 `caps.epg == false → 隐藏节目单区` 那种判断：
//    在只声明 `live: true` 的源（`demo.js`）上，那会**多出**一块
//    原版没有的「暂无节目单」区域 —— 属于**改变交互**，不是补齐差异。
//    用户硬性要求「操作逻辑必须与原版一致」，故照原版做。
//
// 同理 `timeshift`：原版 `watchReplay` **不带时间区间**
// （`LiveView.vue:132`），`get_timeshift` 在原版全仓零调用
// （`src/api/index.ts:649` 只有定义）。接它属于新增功能，不在这里做。
//
// # ★ 两个从原版继承的行为（都有实测背景）
//
// ## ① 返回本页要**保留用户选中的频道**
//
// 原版注释：
// > 不能无脑「默认选中第一个频道」—— 用户切走又切回时，
// > 那样会把他在看的台**重置成第一个**，是很明显的体验倒退
// > （而且他不会意识到是刷新导致的）。所以返回本页时优先找回原来那个频道。
//
// ## ② 返回本页要**重新拉频道列表**（但保留选中）
//
// 原版注释：
// > 频道列表本身会变：启用/停用源、源新增频道、源失效被剔除。
// > 实测确认过问题：切走再切回，完全没有重新请求。

import '../ui/app_scaffold.dart';

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
// ★ 2026-09-25：不再需要 `HardwareKeyboard`（改用
//   `FocusManager.instance.addEarlyKeyEventHandler`）—— 见 `initState` 的长注释。
//   `KeyEventResult` 由 `material_ui`（widgets）导出，不在这里 show。
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

import '../core/device.dart';
// ★【C】需要 `Episode`（把频道映射成"选集项"装进 EpisodePanel）
//   ⚠️ 不单独 import `../core/models.dart` —— `sourin_api.dart` 已经
//      re-export 了它（analyze 会报 unnecessary_import）
import '../core/sourin_api.dart';
// ★ 为 `ShellScope` / `AppTab`（task-42 的双来源门控）——
//   ⚠️ 这是**循环 import**（shell.dart 也 import 本文件）。
//   Dart **允许**循环 import（编译期图，不是运行期初始化顺序问题），
//   只要没有"顶层非惰性初始化互相依赖"。实测 analyze 通过。
//   ★ 更干净的做法是把 `ShellScope` 抽到独立文件，但那要动 shell.dart
//     （不在本任务写入范围）⇒ 这里先用循环 import，并在报告里记录。
import '../shell.dart' show AppTab, ShellScope;
// ★★ 2026-09-26【C】复用**播放页的选集面板**（用户原话：
//    「直播页面可以看所有的直播,**就跟选集逻辑一样**,点击出来所有的直播」）
//    ⇒ ★ 复用 `EpisodePanel` 而不是新造一个"频道面板"：
//      形态（PC 右抽屉 / 手机底部 / 分组分块）+ 搜索 + 滚动全都已经有了。
//    ⚠️ episode_strip.dart **只读复用，不改它**（lead 明确：别人在改）
import 'widgets/episode_strip.dart';
import 'live_availability.dart';
import 'tokens.dart';
import 'widgets/cover_image.dart';
// ★ 2026-09-26【A】用户要求"删除掉节目单" ⇒ 不再 import
//   `widgets/collapsible_epg.dart` / `widgets/epg_panel.dart`
//   （那两个文件本身**保留** —— 别的页面可能还在用；只删本页的引用）
import 'widgets/live_embedded_player.dart';

/// 直播页
class LivePage extends StatefulWidget {
  const LivePage({
    super.key,
    this.onWatchLive,
    this.onWatchReplay,
    this.isTv = false,
    this.visible,
  });

  /// 看直播 → 进播放器
  ///
  /// ★★ 返回 `Future` —— **task-39 新增**（原来返回 void）
  ///
  /// # 为什么必须能 await
  /// ```text
  /// 直播页现在有**内嵌播放器**，而"全屏"是 push 一个独立 PlayerPage。
  /// 两个播放器同时存在 ⇒ **同时出声**（同一路流，回声/重音）。
  /// ⇒ 跳全屏前 pause 内嵌，**pop 回来**再续播。
  ///   ★ 那个"回来"的时机只能靠 `Navigator.push` 返回的 Future ——
  ///     它在 pop 时完成，是可靠的（lead 裁决 (a)）。
  /// ⇒ 所以这个回调必须把 push 的 Future 交出来。
  /// ```
  final Future<void> Function(String provider, String channelId, String name)?
      onWatchLive;

  /// 回看某条节目 → 进播放器
  final void Function(
    String provider,
    String channelId,
    String title,
    String episodeTitle,
  )? onWatchReplay;

  final bool isTv;

  /// ★★★ 本页是否**可见**（task-39 新增；task-41 保活后必需）
  ///
  /// # 为什么必须有这个口子
  /// ```text
  /// task-41 给 shell 加了"5 页保活" ⇒ 直播页**切走也不销毁**
  /// ⇒ ★ 内嵌播放器会在后台**继续出声**（用户切到首页还在放）
  /// ⇒ 所以需要"可见性"信号：不可见时 pause（不是 dispose）
  /// ```
  ///
  /// # 为什么是**注入**而不是自己读 ShellScope
  /// ```text
  /// task-41 的 `ShellScope.activeTabOf(context)` 还没落地。
  /// ★ lead 明确要求：可以留一个本地抽象，但**不要自己写一套**
  ///   （会和 task-41 重复）。
  /// ⇒ 所以这里只声明"我需要一个可见性信号"，
  ///   由 shell.dart 在接线时传 `ShellScope` 的值进来。
  ///   `null` = 没人管可见性（等价于"始终可见"）——
  ///   这样**测试与旧调用点不用改**（向后兼容）。
  /// ```
  ///
  /// ⚠️ 语义是"**可见**"不是"活跃"：保活页仍然 mounted 但不可见。
  ///    所以它只该决定"要不要跑副作用"（停播放器），
  ///    **不该**决定"要不要保留状态"。
  final ValueListenable<bool>? visible;

  @override
  State<LivePage> createState() => LivePageState();
}

class LivePageState extends State<LivePage> {
  List<LiveGroup> _groups = [];
  bool _loading = true;
  String _activeProvider = '';

  LiveChannel? _selected;
  // ★ 2026-09-26【A】用户要求"删除掉节目单" ⇒ `_epg` / `_epgLoading`
  //   / `_epgKey` / `_now` / `_clock` 全部移除（含取数与定时器）

  /// ★★ 2026-09-26【C】"所有直播"面板是否打开（用户要求"点击出来所有的直播"）
  ///
  /// ```text
  /// 用户原话（第 2 条后半）：
  ///   「直播页面可以看所有的直播,就跟选集逻辑一样,
  ///     点击出来所有的直播,然后上下按键在这里替换为切换直播」
  ///
  /// ★ 形态直接复用播放页的 `EpisodePanel`：
  ///   · PC ⇒ 右侧抽屉（`EpisodePanelStyle.rightDrawer`）
  ///   · 手机/TV ⇒ 底部抽屉（`bottomSheet`）
  ///   ⇒ 与"选集"**同一个组件** ⇒ 用户说的"就跟选集逻辑一样"是字面实现的
  /// ```
  bool _allChannelsOpen = false;

  // ══════════════════════════════════════════════════════════════════
  //  ★ task-39 新增状态
  // ══════════════════════════════════════════════════════════════════

  /// ★★ 可用性探测（动态判定"不可用" —— 见 `live_availability.dart` 的长注释）
  ///
  /// 为什么必须动态而不是硬编码"cctv 全不可用"：
  /// ```text
  /// 我实测 20/20 个 cctv 频道视频线全 DRM，但那只是**此刻快照**。
  /// 央视 CDN 会变；哪天加密取消了，硬编码过滤会让用户**永远看不到**
  /// ⇒ 永久性假阴性，比"多显示几个台"危险得多。
  /// ```
  final _probe = LiveAvailabilityProbe();

  /// 是否已探测过至少一轮（"还有多少没探完"的提示用）
  bool _probed = false;

  /// ★ 探测进度（已探 / 总数）—— 显示在"探测中"提示里，让用户知道
  ///   列表为什么还在变（48 个频道大约 0.2~1 秒）
  int _probeDone = 0;
  int _probeTotal = 0;

  /// ★★★ 内嵌播放器（用户要求"右侧放个播放器，默认打开就自动播"）
  final _embedKey = GlobalKey<LiveEmbeddedPlayerState>();

  /// 当前频道取到的**全部**流候选
  ///
  /// ★ 为什么要留着全部（而不是只留选中的那条）：
  ///   一个频道常常有多条线路（高清/标清/仅音频），用户可能想手动切 ——
  ///   而且**取流失败时**要能回退到别的线路（见 `_loadStream`）。
  List<StreamCandidate> _streams = [];

  /// 当前选用哪条线路
  StreamCandidate? _stream;

  /// 取流中
  bool _streamLoading = false;

  /// ★★★ 三个"暂停来源"标记 —— **必须独立**（语义完全不同）
  ///
  /// ```text
  /// _userPaused           用户按了暂停        → 切走切回**不要**自动播
  /// _pausedByHide         我们因不可见而暂停  → 恢复可见时续播
  /// _pausedForFullscreen  我们为进全屏而暂停  → pop 回来时续播
  /// ```
  /// ★ 为什么不能合并（混用会真出错）：
  /// ```text
  /// · 用 `_userPaused` 兼做全屏标记
  ///     ⇒ "用户暂停后跳全屏再回来"会被我们**自动播起来**（违背他的操作）
  /// · 用 `_pausedByHide` 兼做全屏标记
  ///     ⇒ 从全屏回来会**误判成"可见性恢复"**，
  ///       而那时若用户已切走 tab，就会在后台放声音
  /// ```
  /// ⇒ 结论：三个标记各自回答"**是谁按的暂停**"，这是溯源问题，
  ///    不能压成一个布尔。
  bool _userPaused = false;
  bool _pausedByHide = false;
  bool _pausedForFullscreen = false;

  /// ★★★ task-53【#4b】全屏里切过的台 —— pop 回来后**由本页接手播放**
  ///
  /// # 为什么需要（与 `_pausedForFullscreen` 是**两个**问题）
  /// ```text
  /// _pausedForFullscreen ：我们为进全屏而暂停了内嵌播放器
  /// 本字段             ：用户在全屏里按 ↑/↓ **换过台**
  /// ```
  /// 只靠前者会漏掉后半句：用户切到新台后 pop 回来，我们看到
  /// `_pausedForFullscreen == true` 就去 `resume()` —— 而内嵌播放器
  /// 手里还是**旧台的流**（或已被 stop）⇒ 用户听到的是**上一个台**。
  /// ⇒ 所以必须记住"回来该播哪个台"，回来后**重新取流**再播。
  ///
  /// ⚠️ 它与 `_selected` 的区别：`_selected` 是"用户选了哪个台"（列表高亮），
  ///    而本字段是"**内嵌播放器还没跟上**的那个待办"。
  ///    处理完必须清空（否则每次可见性变化都会重新取流）。
  LiveChannel? _pendingFullscreenChannel;

  /// ★ 2026-09-26【A】节目单删除后：`_now` / `_clock` 与那个每 30 秒的
  ///   `setState` 定时器**一并移除** —— 它们只服务"当前节目高亮"，
  ///   而保留一个周期性整页重建在**卡顿**问题上是纯负担。

  @override
  void initState() {
    super.initState();
    widget.visible?.addListener(_onVisibilityChanged);
    /*
     * ★★★ 注册**硬件键盘** handler（task-42 的真正修法）
     *
     * 它在**焦点树之前**跑 ⇒ 不依赖焦点在哪 ⇒
     * 用户鼠标点过底栏 tab 之后，方向键照样能切台。
     * ★ 详细推导见 `_onHardwareKey` 的注释（含实测证据）。
     */
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-25 修正：`addHandler` → `addEarlyKeyEventHandler`
     * ══════════════════════════════════════════════════════════════════
     *
     * # 真 bug（独立验证者 `fix-autoscroll` 用最小复现实测）
     *
     * ```text
     * Flutter `hardware_keyboard.dart` `_dispatchKeyEvent`：
     *     for (final handler in _handlers) {
     *       final bool thisResult = handler(event);
     *       handled = handled || thisResult;      // ★ 没有 break
     *     }
     * 同文件 `handleKeyData`：
     *     _hardwareKeyboard.handleKeyEvent(event);        // ← 跑 addHandler
     *     _dispatchKeyMessage(<KeyEvent>[event], null);   // ★ **无条件也跑**
     * ```
     * ⇒ `addHandler` 返回 `true` **不能中止派发**。
     *
     * 实测（`.probe/probe_tests/zz_v42_mechanism_test.dart`）：
     * ```text
     * VERIFY42O|hardware handler = 1 ／ Focus.onKeyEvent = 1 ／ 合计 = 2  ★★
     * VERIFY42P|early handler    = 1 ／ Focus.onKeyEvent = 0 ／ 合计 = 1  ← 对照
     * ```
     *
     * # 后果：按一次 ↓ **切两个台**
     * ```text
     * ① 本 handler 被调用 ⇒ cycleChannel(1) ⇒ return true（★ 但不中止）
     * ② 事件继续 → 焦点树 → 本页的 `Focus(onKeyEvent: _onKeyAny)` → `_onKey`
     *    ⇒ **又** cycleChannel(1)
     * ⇒ 用户按一下 ↓ 会跳过中间一个台
     * ```
     *
     * # ★ 这个坑 `shell.dart` 已经踩过并修了（L1966 逐字记录）
     * ```text
     * 「# 根因：`HardwareKeyboard.addHandler` 的返回值**不会**中止派发
     *   ⇒ 事件照样继续流到 FocusManager → 焦点树 →
     *     内建 DirectionalFocusIntent **再搬一次**
     *   # 修法：改用 `FocusManager` 的 early handler（返回值**真的**会中止）」
     * ```
     * ⇒ shell 3 处改用 `addEarlyKeyEventHandler`（L1953/L2008/L2361）。
     *   ★ 本页当时用的是**修之前**的 API ⇒ 同一个坑复发。
     *
     * # 为什么不是"删掉 `Focus(onKeyEvent:)` 那条路径"
     * ```text
     * 那会丢掉"焦点在页面内也能收到"的能力（且三层诊断日志也没了）。
     * early handler 中止派发 ⇒ 焦点树那条**自然不再跑** ⇒ 两条路径只剩一条。
     * ```
     */
    FocusManager.instance.addEarlyKeyEventHandler(_onEarlyKey);
    WidgetsBinding.instance.addPostFrameCallback((_) => loadAll());
  }

  /// 把 [_onHardwareKey] 的 `bool` 契约适配成 `KeyEventResult`
  ///
  /// `_onHardwareKey` 的语义是：
  /// ```text
  /// true  -> 这个按键我消费了（方向键且门控全过）
  /// false -> 放行给焦点树 / 平台
  /// ```
  /// `KeyEventResult` 的对应关系（与 `shell.dart` 的 `_onEarlyKey` 一致）：
  /// ```text
  /// true  -> KeyEventResult.handled   （★ 会**中止**焦点树派发）
  /// false -> KeyEventResult.ignored   （继续正常派发）
  /// ```
  /// ★ 单独写适配函数而不是把 `_onHardwareKey` 的返回值改成枚举 ——
  ///   后者的判定逻辑已被真机验证过，这里只做**类型转换**，一字不动。
  KeyEventResult _onEarlyKey(KeyEvent event) =>
      _onHardwareKey(event) ? KeyEventResult.handled : KeyEventResult.ignored;

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ 可见性（task-41 保活后必需）
  // ══════════════════════════════════════════════════════════════════

  /// 可见性变化 ⇒ 暂停/续播内嵌播放器
  ///
  /// # ★★ 两个标记缺一不可
  /// ```text
  /// 只用"不可见就暂停、可见就播" ⇒ 用户**自己按了暂停**再切走切回，
  ///   会被我们**自动播起来** ⇒ 违背用户意图。
  /// ⇒ 必须有 `_pausedByHide`（"是我们暂停的"）才续播。
  /// ```
  void _onVisibilityChanged() {
    if (!mounted) return;
    final visible = widget.visible?.value ?? true;
    /*
     * ★ 变可见时也要重新拿焦点（task-42）
     *
     * 保活后切走再切回，**焦点不会自动回来** —— 用户切回直播页
     * 按 ↓ 会没反应（那正是"上下键切不了"的一种成因）。
     */
    if (visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_pageFocus.hasFocus) {
          debugPrint('[LIVE-KEY] 切回本页 ⇒ 重新请求焦点（原来在 ${_focusOwner()}）');
          _pageFocus.requestFocus();
        }
      });
    }
    final st = _embedKey.currentState;
    if (st == null) return;
    if (!visible) {
      /*
       * ★★★ task-74 ⑤ 残余竞态修复：**无条件**置位
       *   （改前是 `if (st.isPlaying)` 才 pause + 置位）
       *
       * 实测 RED（改前读数）：`_openCurrent()` 在播放器侧 `_visibleNow`
       * 检查（live_embedded_player.dart:318）**通过之后**、在
       * `await p.open()` / `await p.play()` **期间**页面变不可见时，
       * 此处读到的 `st.isPlaying` 仍是 false ⇒ 整支不成立 ⇒ 不 pause、
       * 不置位 ⇒ 在途的 `p.play()` 完成后**隐藏页在播**
       * （实测：翻转后第 16 轮 ≈2062ms 起播，`pausedByHide` 全程 false）。
       *
       * 为什么不能只靠 `pause()`：
       *   `pause()` 只把 mpv 的 pause 置真，在途的 `await p.play()`
       *   会在其后完成并**覆盖掉 pause**；且 `_player == null` 时
       *   `pause()` 是**空操作**。
       * ⇒ 置位必须无条件（它记录"是**我们**暂停的"这个事实，供切回
       *   续播，见下方 `else if (_pausedByHide)`）；真正的兜底在
       *   播放器侧：`await p.play()` **之后**再查一次可见性。
       */
      unawaited(st.pause());
      _pausedByHide = true;
      debugPrint('[LIVE] 本页不可见 ⇒ 暂停内嵌播放器（切回时续播）');
    } else if (_pausedByHide) {
      _pausedByHide = false;
      /*
       * ★★ 只在"用户没主动暂停"时才续播
       *
       * ```text
       * 用户按了暂停 → 切走 → 切回
       *   若在这里无条件 resume() ⇒ 违背他刚做的操作
       * ⇒ 用 _userPaused 拦住。
       * ```
       * ⚠️ 注意顺序：先清 `_pausedByHide`（那是"我们暂停的"这个事实，
       *    现在恢复可见了它就没意义了），再判 `_userPaused`。
       */
      if (_userPaused) {
        debugPrint('[LIVE] 恢复可见，但用户此前主动暂停过 ⇒ 不自动续播');
        return;
      }
      unawaited(st.resume());
      debugPrint('[LIVE] 本页恢复可见 ⇒ 续播内嵌播放器');
    }
  }

  /// ★ 键盘 / 遥控方向键 → 切频道（循环）
  ///
  /// # 为什么用 `Focus.onKeyEvent` 而不是只靠 `spatial_nav.dart`
  /// ```text
  /// `spatial_nav` 是**空间导航**（几何找最近邻居）—— 解决"焦点该移到哪个控件"。
  /// 而直播页要的是**列表内相邻切换**（上一台/下一台 + 末尾循环），语义不同：
  ///   · 空间导航按**几何位置**跳，长列表里可能跳过一整屏
  ///   · 用户要的是"往下循环切换"（相邻 + 循环）
  /// ⇒ 页面自己的 Focus 先处理，返回 `handled` 吃掉事件。
  /// ```
  ///
  /// ⚠️ **遥控选中后必须滚进可视区** ——
  ///    task-3 会给 `spatial_nav` 的 `_scrollIntoView` 加"输入来源门控"
  ///    （只让键盘/遥控滚，不让鼠标滚轮滚，见铁律）。
  ///    ★ 本页**不依赖**那条路径：`_ChannelTile` 自己带
  ///      `Scrollable.ensureVisible`（见 `_LiveChannelTile`），
  ///      所以 task-3 改动本页不受影响 —— 但**遥控路径不能被关掉**
  ///      这条约束已写在 `spatial_nav.dart` 的注释里（见那里的说明）。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-25 补：这条路径**也必须过门控**（独立验证发现）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么（这是"切两个台"的**另一面**，而且更隐蔽）
     *
     * `focus_manager.dart` 的派发逻辑（L2256-2273）：
     * ```dart
     * switch (result) {
     *   case KeyEventResult.ignored:
     *     break;                        // ★ 不中止 ⇒ 继续走焦点树
     *   case KeyEventResult.handled:
     *     handled = true;
     * }
     * if (handled) return true;
     * // Walk the current focus from the leaf to the root ...   ← 焦点树
     * ```
     * ⇒ early handler 返回 **`ignored`** 时，焦点树**照走**
     *   （实测 `VERIFY42Q1|early 被调用 = 1` / `焦点树 onKeyEvent = 1`）。
     *
     * # 后果：门控**被绕过**
     * ```text
     * 门控挡住（比如"本页不可见"或"焦点在输入框"）⇒ early handler 返回 ignored
     *   ⇒ 焦点树照走 ⇒ **本函数的 onKeyEvent 被调用**
     *   ⇒ 而本函数原先**没有门控** ⇒ cycleChannel 仍然执行
     * ⇒ ★ 该挡住的时候没挡住（比"切两个台"更严重）
     * ```
     *
     * # 修法：复用**同一套**门控（不新造判据，避免两套真相）
     * ```text
     * ① `_isVisibleForKeys()` —— 本页可见
     * ② 最上层路由           —— 没被全屏播放页/详情页盖住
     * ③ 输入框守卫           —— 打字时不抢键
     * ★ 与 `_onHardwareKey` **完全同源** —— 两道入口、一套判据。
     * ```
     */
    if (!_isVisibleForKeys()) return KeyEventResult.ignored;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return KeyEventResult.ignored;
    if (_isTypingInField()) return KeyEventResult.ignored;
    /*
     * ★ 2026-09-26【C】门控 ④："所有直播"面板打开时放行 ——
     *   让 ↑/↓ 交给面板自己（在面板内移动选择），而不是切台。
     *   ⚠️ 与 `_onHardwareKey` 里的同一条**同源** ——
     *     两道入口必须用**同一套门控**（本文件既有的纪律，
     *     否则会出现"early 挡住了、焦点树没挡"的绕过）。
     */
    if (_allChannelsOpen) return KeyEventResult.ignored;

    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      cycleChannel(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      cycleChannel(-1);
      return KeyEventResult.handled;
    }
    // ←/→ 留给焦点/空间导航（不在这里消费）
    return KeyEventResult.ignored;
  }

  /// 焦点是否在输入框里（门控③ 的**共用**实现）
  ///
  /// ★ 抽成函数的原因：`_onHardwareKey` 与 `_onKey` **两条入口**都要用。
  ///   写在两处会变成**两套真相** —— 改一处忘另一处就会出现
  ///   "硬件路径挡住了、焦点树路径没挡"的漏洞（正是本次修的 bug 形态）。
  bool _isTypingInField() {
    final f = FocusManager.instance.primaryFocus;
    if (f?.context == null) return false;
    var typing = false;
    f!.context!.visitAncestorElements((el) {
      if (el.widget.runtimeType.toString() == 'EditableText') {
        typing = true;
        return false;
      }
      return true;
    });
    return typing;
  }

  /// ★★★ 三层诊断：`_onKey` 到底有没有被调用（task-42 复现"上下键切不了"）
  ///
  /// # 为什么要三层日志（lead 要求"分层判定，别只测切没切成"）
  /// ```text
  /// ① 焦点层：本页的 Focus 拿到焦点了吗？
  ///    ⇒ `_onKeyAny` 有没有被调用（**任何**键都打）
  /// ② 事件层：方向键到了吗？
  ///    ⇒ `_onKey` 里对 ↑/↓ 打点
  /// ③ 逻辑层：cycleChannel 被调了吗？列表非空吗？
  ///    ⇒ `cycleChannel` 里打点（含 list.length）
  /// ```
  /// ★ 三层各自一句日志 ⇒ 断在哪一层一目了然。
  ///   比"试了不行"精确得多（这正是 lead 的要求）。
  ///
  /// ⚠️ 只在**调试**时打（`kDebugMode` 之外也打 —— 生产要能诊断用户报的问题，
  ///    而这几行频率极低：一次按键一行）。
  KeyEventResult _onKeyAny(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      debugPrint('[LIVE-KEY] ① 焦点层：收到 ${event.logicalKey.keyLabel}');
    }
    return _onKey(node, event);
  }

  /// ★★★ 键盘接管（task-42：**真正修好**"上下键切不了"）
  ///
  /// # 实测出来的根因（`.probe/t42_repro3.py` / `t42_repro4.py`）
  /// ```text
  /// ① 用 SendInput 发 ↓（真实键盘路径）⇒ 只有 `[LIVE-KEY] 主动请求焦点` 一行
  /// ② 用 PostMessage 发 ↓ ⇒ **0 行**（见下面的仪器说明）
  /// ③ 日志里出现 `[NAV] home -> live` ⇒ ★★ **焦点在底栏 tab 上**
  /// ```
  /// ⇒ **根因：焦点不在直播页**。
  ///    用户用鼠标点底栏「直播」进页面 ⇒ **焦点留在那个 tab 上**
  ///    ⇒ 按 ↓ 走的是"底栏 tab 之间移动焦点"，根本到不了频道列表。
  ///
  /// # 为什么"Focus + autofocus"修不好
  /// ```text
  /// Flutter 的按键派发是「从 primaryFocus 沿**祖先链**向上冒泡」。
  /// 焦点在底栏时，底栏与直播页内容是**兄弟**关系 ——
  /// 我的 Focus **不在**那条祖先链上 ⇒ `onKeyEvent` 永远不会被调用。
  /// ★ 这也解释了为什么 `requestFocus()` 打了日志却没用：
  ///   我请求成功了，但用户**随后点底栏**又把焦点抢走了。
  /// ```
  ///
  /// # 为什么改用 `HardwareKeyboard.addHandler`
  /// ```text
  /// 它在**焦点树之前**跑（shell.dart 的 `_onGlobalKey` 也是这个机制）
  /// ⇒ 不依赖焦点在哪 ⇒ 鼠标点过底栏也照样能切台。
  /// ```
  ///
  /// # ⚠️ 与 shell 的 `_onGlobalKey` 的分工（**必须说清，否则会互相抢**）
  /// ```text
  /// shell 的 handler：`if (!Device.needsFocusRing) return false;`
  ///   ⇒ ★ **桌面直接放行** ⇒ 桌面只有我这一个处理者，不冲突
  ///   ⇒ 电视/遥控（needsFocusRing=true）时 shell 先消费 ↑/↓ 做空间导航
  ///      ⇒ ★ 电视上本 handler **收不到** ↑/↓
  /// ```
  /// ★★ 所以本修法**确定修好的是 PC**（用户提这条时用的就是 PC：
  ///    他同批还说"空格暂停/Enter 全屏"）。
  ///    电视上的方向键仍走 shell 的空间导航 —— 那是既有行为，
  ///    我没有擅自改动 shell（不在本任务写入范围）。
  ///    ⇒ 这一限制我会**如实写进报告**，不假装电视也好了。
  ///
  /// # ⚠️ 仪器说明（我踩过的坑，留给后人）
  /// ```text
  /// `PostMessage(WM_KEYDOWN)` 对 Flutter 窗口**完全无效**（实测 0 行日志）——
  /// Flutter 的 win32 embedder 走的是系统输入队列，不处理投递消息。
  /// ⇒ 测键盘必须用 `SendInput`（`.probe/t42_repro4.py` 里有实现）。
  /// ★ 我一开始用 PostMessage，得出过"键没接上"的错误结论。
  /// ```
  bool _onHardwareKey(KeyEvent event) {
    /*
     * ★★★ 无条件入口打点（**诊断的关键**）
     *
     * # 为什么这条必须有
     * ```text
     * 前面几轮我只能看到"某个键之后日志多了几行"，无法区分：
     *   · 我的 handler **压根没被调用**（注册/机制问题）
     *   · 被调用了但**门控挡掉**（可见性/路由/输入框）
     *   · 被调用了但**不是 ↑/↓**
     * ⇒ 入口处无条件打一行 ⇒ 一看就知道到没到这一层。
     * ★ 它是**真机排障的关键**：2026-09-25 实测就是靠它区分出
     *   "键进了 Flutter（入口打出来了）但被门控挡住（可见=false）"。
     * ```
     * ⚠️ 只在 KeyDownEvent 打（避免按下+抬起两行噪音）。
     */
    if (event is KeyDownEvent) {
      debugPrint('[LIVE-KEY] ⓪ 入口：硬件 handler 收到 '
          '${event.logicalKey.keyLabel}（可见=${_isVisibleForKeys()}）');
    }
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;

    /*
     * ── 门控 ①：本页必须可见 ──
     *
     * task-41 保活后本页切走**仍在树上**，不门控的话
     * 用户在首页按 ↓ 会把直播页的台切掉（很诡异）。
     *
     * ★★★ 2026-09-25 真机实测发现的**真根因**（这条最值钱）
     * ```text
     * 现象：真机上按 ↓ **完全没反应**，但日志有
     *       `[LIVE-KEY] ⓪ 入口：硬件 handler 收到 ↓（可见=false）`
     * ⇒ 键**进了 Flutter**（入口打出来了），**被我这一行挡住**。
     *
     * 为什么当时 `visible=false`（★ 事件已结案，现状是好的）：
     *   当时 shell.dart 的 `_syncVisibility();` 被一次**变异测试**
     *   临时替换成了注释（并发窗口期内正好被我扫到），
     *   ⇒ `_liveVisible` 停在初值 false ⇒ 门控永远生效。
     *   ★ **该变异已还原**：`shell.dart` 现在就是 `_syncVisibility();`
     *     （唯一提到那次变异的残留是 shell.dart 里那段**事故记录注释**，
     *       那是**有意保留**的知识，不是活的变异）。
     * ```
     * ⇒ ★ 教训（**与那次事故是否已修无关**）：
     *    **门控不能只依赖一个上游给的值** ——
     *    上游一坏，功能就全废，而且**静默**（日志只在入口有一行）。
     *    上游可能因为**任何**原因失真（重构中间态、变异测试、
     *    未来的接口调整），所以这里的双来源是**结构性防御**，
     *    不是"给某个已知 bug 打补丁"。
     *
     * # 修法：**权威来源优先**（★ 注意：不是"任一说可见就放行"）
     * ```text
     * ① `ShellScope` 拿得到 ⇒ ★ **只用它**
     *    （`return notifier.value == AppTab.live`）
     *    —— **不再看** `widget.visible`（它可能失真，正是本次事故的来源）
     * ② `ShellScope` 拿不到（页面不在其子树里，如独立 widget 测试）
     *    ⇒ 退回 `widget.visible`
     * ③ 两个都拿不到 ⇒ **放行**
     * ```
     * ⚠️ 我原来这段注释写的是「**任一说"可见"就放行**」—— **描述不准**：
     *    代码实际是"权威来源拿得到就**覆盖**旧签名"。
     *    ★ 而"覆盖"是**更好**的设计：两源冲突时**不犹豫**，直接信权威的那个
     *      （若真按"任一"，那个可能失真的旧值也能放行 ⇒ 事故会复发）。
     *    （此更正由 `fix-autoscroll` 指出，谢谢。）
     *
     * ⚠️ 关键取舍：**两个来源都不确定时**怎么办？
     * ```text
     * · 若按"必须为 true 才放行" ⇒ 上游一坏就全废（就是这次的事故）
     * · 若按"必须为 false 才挡" ⇒ 保活页在后台会抢键
     * ⇒ 我选：**都不确定时放行**（"拿不到"不等于"不可见"）。
     *   ★ 而"哪个页面该收键"还有**门控 ②（最上层路由）**兜底 ——
     *     它由 Navigator 直接给，**不依赖 shell**，是更硬的判据。
     * ```
     */
    if (!_isVisibleForKeys()) return false;

    /*
     * ── 门控 ②：本页必须是**最上层路由** ──
     *
     * 全屏播放页 / 详情页压在上面时，↑/↓ 是它们的（播放器是音量、
     * 详情页是选剧集）⇒ 不能抢。
     * ⚠️ 用 `ModalRoute.isCurrent` 而不是"有没有 push"——
     *    前者对"我上面盖了一层"判得准。
     */
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;

    /*
     * ── 门控 ③：有输入框在打字时放行 ──
     *
     * 与 shell 的 `_isTypingInTextField` 同样的理由：
     * 输入框里 ↑/↓ 该移动光标，不该切台。
     * ★ 用**共用**的 `_isTypingInField()` —— `_onKey`（焦点树路径）也用它，
     *   保证两条入口**同源**（见该函数的说明）。
     */
    if (_isTypingInField()) return false;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★【C】Esc / 返回键：**先关面板**（它是最上面那一层）
     * ══════════════════════════════════════════════════════════════════
     *
     * ```text
     * 与播放页 `_episodeSheetOpen` 的处置一致（player_page L4497）：
     *   面板是 `Positioned.fill` 盖在所有东西之上 ⇒ Esc 必须**先**关它，
     *   否则用户会看到"面板还开着，人却已经返回上一页/切走了"。
     * ★ 且 `EpisodeSheet` 内部**只在"第二层"**（完整网格）时才有
     *   `_EscLayer` 处理 Esc（见 episode_strip L1305/L1367）——
     *   桌面右抽屉**没有**那一层 ⇒ 必须由宿主（本页）处理。
     * ```
     *
     * ⚠️⚠️ **顺序很关键**：这一段必须在下面"面板打开 ⇒ return false"
     *    **之前** —— 否则面板一打开，Esc 就永远走不到这里
     *    （第一版我就是这么写的，等于**面板关不掉**）。
     *    ★ 这类"门控顺序"错误在静态分析里**看不出来**（analyze 是绿的），
     *      只能靠**追一遍控制流**发现。
     */
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.goBack) {
      if (_allChannelsOpen) {
        setState(() => _allChannelsOpen = false);
        return true;
      }
      return false; // 面板没开 ⇒ 不消费（留给 shell 的正常返回逻辑）
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ── 门控 ④（★ 2026-09-26【C】新增）："所有直播"面板打开时**放行**
     * ══════════════════════════════════════════════════════════════════
     *
     * ```text
     * 用户原话：「点击出来所有的直播,然后**上下按键在这里**替换为切换直播」
     *   ⇒ ★ "在这里"= **在面板里** —— 即 ↑/↓ 在面板内移动选择。
     *
     * ★★ 为什么必须加这道门控（不加就是**双重响应**）：
     *   本页的 early handler 跑在**焦点树之前**（`addEarlyKeyEventHandler`）
     *   ⇒ 它**先**看到 ↑/↓ ⇒ 若不禁用，会：
     *        ① `cycleChannel(1)` 立刻切台（页面级）
     *        ② 事件继续给焦点树 ⇒ 面板**也**移动了一格
     *      ⇒ ★ 一次按键**移动两格 + 立刻切台**（用户完全无法在面板里选）
     *
     * ★ 返回 `false`（= ignored）而不是 `true`：
     *   让事件**继续往下走**给焦点树 ⇒ 面板自己处理 ↑/↓。
     *   （这正是 `EpisodeSheet` 既有的方向键行为，见
     *    它内部的 `_focusCurrent` / `_scrollToCurrent`）
     * ```
     * ⚠️ 与门控 ②（`route.isCurrent`）**不同**：那个面板**不是**一条路由
     *   （它是本页内的 `Positioned.fill` 浮层）⇒ 那条门控**挡不住**它
     *   ⇒ ★ 必须单独有这一条。
     * ⚠️ 而它**必须在 Esc 处理之后** —— 见上面那条注释。
     */
    if (_allChannelsOpen) return false;

    if (k == LogicalKeyboardKey.arrowDown) {
      debugPrint('[LIVE-KEY] ② 事件层：硬件 handler 收到 ↓');
      cycleChannel(1);
      return true;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      debugPrint('[LIVE-KEY] ② 事件层：硬件 handler 收到 ↑');
      cycleChannel(-1);
      return true;
    }
    return false;
  }

  /// ★★★ 键盘门控用的"本页可见吗"（**双来源**，见 `_onHardwareKey` 的长注释）
  ///
  /// # 判据（按优先序）
  /// ```text
  /// ① `ShellScope.isActive(context, AppTab.live)` —— ★ 权威
  ///    `InheritedNotifier`（task-41 的正规接口）。
  ///    ★ 关键：它读的是 `_activeTab`（shell.dart 里**正常赋值**的那个），
  ///      **不依赖** shell 额外投影出来的那个 bool（`_liveVisible`）。
  ///      ⇒ 少一层派生，就少一处可能失真的地方。
  /// ② `widget.visible?.value` —— 兼容旧签名（**可能失真**，只作补充）
  /// ③ 两者都不确定 ⇒ **放行**
  ///    ★ "拿不到"不该当成"不可见"（与"探不到 ≠ 不可用"同族）。
  ///      而且下面还有"最上层路由"门控兜底，不会误伤别的页面。
  /// ```
  ///
  /// # 为什么要有"双来源"这层防御（**结构性理由，不是给某个 bug 打补丁**）
  /// ```text
  /// 2026-09-25 真机实测：键**进了 Flutter**（入口日志有），却被本门控挡住，
  /// 因为上游传进来的 `visible` 停在了初值 false
  /// （当时 shell 的投影调用处于一次**变异测试的临时态**，现已还原：
  ///   `shell.dart` 现在是 `_syncVisibility();`）。
  ///
  /// ★ 关键教训不是"那次事故"本身，而是：
  ///   **上游值可能因为任何原因失真** —— 重构中间态、变异测试、
  ///   将来的接口调整、并发编辑。若门控**只**依赖它，
  ///   一旦失真就是"功能静默全废"（日志只有入口那一行，很难查）。
  /// ⇒ 所以这里选"权威来源优先 + 拿不到则放行"，
  ///   并让"最上层路由"（Navigator 直接给，不依赖 shell）做硬兜底。
  /// ```
  bool _isVisibleForKeys() {
    // ① 权威来源：ShellScope
    //
    // ⚠️ 用 `dependOnInheritedWidgetOfExactType` 会注册依赖 ⇒
    //    在**按键回调**里调用是不合适的（那会触发重建，且回调不是 build 期）。
    //    ⇒ 用 `getInheritedWidgetOfExactType`（**只读一次，不注册依赖**）。
    //    ★ 这是本函数能安全地在 `_onHardwareKey` 里被调用的前提。
    final scope = context.getInheritedWidgetOfExactType<ShellScope>();
    final notifier = scope?.notifier;
    if (notifier != null) {
      // ShellScope 给出了明确答案 ⇒ 以它为准
      return notifier.value == AppTab.live;
    }
    // ② 退到旧签名
    final v = widget.visible?.value;
    if (v != null) return v;
    // ③ 两个都没有 ⇒ 放行（不确定 ≠ 不可见）
    return true;
  }

  /// 当前焦点在谁身上（诊断用 —— 只读，不改）
  ///
  /// ★ 用来回答"我的 Focus 到底有没有拿到焦点"（三层诊断的第①层）。
  String _focusOwner() {
    final f = FocusManager.instance.primaryFocus;
    if (f == null) return '无';
    return f.debugLabel ?? f.context?.widget.runtimeType.toString() ?? '${f.hashCode}';
  }

  @override
  void dispose() {
    // ★ 2026-09-26【A】`_clock?.cancel()` 已移除（定时器本身删了）
    /*
     * ★ 必须移除可见性监听（task-41 保活后生命周期变长，泄漏后果更明显）
     *
     * ⚠️ 内嵌播放器**不在这里 dispose** —— 它是 widget，
     *    由 Flutter 自己调 `LiveEmbeddedPlayerState.dispose()`
     *    （那里会 `player.dispose()` 释放解码器）。
     */
    widget.visible?.removeListener(_onVisibilityChanged);
    /*
     * ★ 与 `initState` 对应 —— 必须用 `removeEarlyKeyEventHandler`。
     *
     * ⚠️ 用 `HardwareKeyboard.instance.removeHandler(_onHardwareKey)` 会
     *    **静默失败**（那个 handler 从来没注册过）⇒ 泄漏 + 保活页继续抢键。
     *    ★ `shell.dart` L2363 也记着同一个坑。
     */
    FocusManager.instance.removeEarlyKeyEventHandler(_onEarlyKey);
    _pageFocus.dispose();
    super.dispose();
  }

  /// ★★★ 本页的焦点节点（task-42：修"上下键切不了"的关键）
  ///
  /// # 为什么不能只靠 `autofocus: true`
  /// ```text
  /// `autofocus` 只在"当前没有别的焦点"时生效。
  /// ★ 而 shell 有 `primeFocusSoon()` / `FocusPrimingObserver` ——
  ///   它们会在进页面时**主动把焦点种到第一个可聚焦控件**
  ///   （task-AI 为 TV 遥控做的，见 shell.dart 的长注释）。
  /// ⇒ 焦点被种走 ⇒ 我这层收不到方向键。
  /// ```
  /// ⇒ 用显式 node，并在**进页面 / 列表变化**时主动请求焦点。
  late final FocusNode _pageFocus = FocusNode(debugLabel: 'LivePage');

  /// 拉取直播频道列表
  ///
  /// [keepSelection] = true 时**保留用户当前选中的频道**（返回本页时用）。
  Future<void> loadAll({bool keepSelection = false}) async {
    /*
     * ★ 主动把焦点拿过来（task-42）
     *
     * 后一帧再抢 —— 那时 shell 的 `primeFocusSoon()` 已经跑完，
     * 我们才是最后一个动焦点的（顺序很重要，见 `_pageFocus` 的说明）。
     */
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_pageFocus.hasFocus) {
        debugPrint('[LIVE-KEY] 主动请求焦点（原来是 ${_focusOwner()}）');
        _pageFocus.requestFocus();
      }
    });
    final prevId = keepSelection ? _selected?.id : null;
    try {
      final groups = await SourinApi.getLiveChannels();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        if (groups.isNotEmpty) {
          _activeProvider = groups.first.provider;
        }
      });

      /*
       * ★★ 先探测可用性，**再**选频道
       *
       * 顺序很重要：若先选第一个频道，可能选中的是一个"视频线全 DRM"
       * 的台（cctv1 就是）⇒ 用户一进页面就看到黑屏 —— 正是他报的问题。
       * ⇒ 探测完再选，选到的第一个就是**能播的**。
       */
      unawaited(_probeAll());

      if (groups.isNotEmpty) {
        /*
         * ★ 不能无脑「默认选中第一个频道」
         *
         * 用户切走又切回时，那样会把他在看的台重置成第一个。
         * 所以优先找回原来那个频道（见文件头注释）。
         */
        final all = groups.expand((g) => g.channels).toList();
        final restored = prevId != null
            ? all.where((c) => c.id == prevId).firstOrNull
            : null;
        final target = restored ?? _firstVisible(all);
        /*
         * ★★★ task-82【Q4】：只有"**真的找回了原来那个台**"才算 restoring。
         *
         * ⚠️ 判据必须是 `restored != null`，**不能**只写 `keepSelection`：
         *   `keepSelection == true` 但 `restored == null` 时（原台已从源里
         *   消失）`target` 是 `_firstVisible(all)` —— 那是**换了一个台**。
         *   若那时也走 restoring 短路，就会留下"UI 选中新台、播放器还挂着
         *   旧台的流"这种**自相矛盾**的状态（比原来的 bug 更糟）。
         */
        if (target != null) {
          await _select(target, restoring: keepSelection && restored != null);
        }
      }
    } catch (e) {
      debugPrint('[LIVE] 加载直播频道失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// ★ 探测所有频道的可用性（动态判定"不可用"）
  ///
  /// 结果进 `_probe` 的 TTL 缓存 —— 10 分钟内重进不再探。
  Future<void> _probeAll({bool force = false}) async {
    if (_groups.isEmpty) return;
    final total = _groups.fold<int>(0, (n, g) => n + g.channels.length);
    if (mounted) setState(() => _probeTotal = total);
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-26【E】修「每个频道都 setState」—— 注释与代码原本**矛盾**
     * ══════════════════════════════════════════════════════════════════
     *
     * ```text
     * 原代码：
     *     // 不要每个频道都 setState —— 会卡（48 个频道 = 48 次重建）
     *     setState(() => _probeDone++);
     *   ⇒ ★ **注释说的正是它自己不该做的事** ——
     *     注释警告"48 次重建会卡"，而下一行就是**每个频道一次重建**。
     *
     * ★ 为什么这确实会卡（用户第 8 条「直播好像有点卡顿」）：
     *   探测并发数是 **8**（`LiveAvailabilityProbe.concurrency = 8`）
     *   ⇒ 8 个 worker 各自 `onProgress()` ⇒ 回调**密集且突发**
     *   ⇒ 每次 `setState` 都**重建整页**（含 `_ChannelList` 的 ListView）
     *   ⇒ 进页面那 1-2 秒里会连续重建 **N 次**（N = 频道数，本例 28）
     *
     * ★ 修法：**节流到「每 8 个频道一次」**（而非每个一次）
     *   ⇒ 重建次数 28 → 最多 4 次（约 -86%）
     *   ★ 而**进度显示仍然可用**：用户看到的是"已检查 x/28"，
     *     每 8 个一跳完全够（本来就是秒级的进度条）
     *   ★ 并且**完成时必然有一次精确的最终值**（下面收尾那次 setState）
     * ```
     * ⚠️ 阈值取 8 是**跟着并发数**走的：并发 8 ⇒ 每轮至少推进 8 个
     *   ⇒ 一次 setState 覆盖一轮，既不漏进度也不密。
     *
     * ⚠️⚠️ **必须用「本地已见计数」而不是「对 `_probeDone` 取模」**
     * ```text
     * ★ 我第一版写的是：
     *     if (_probeDone % progressStep != 0) return;
     *     setState(() => _probeDone++);
     *   ⇒ ★ **进度会永久冻在 1**！
     *     推导：_probeDone=0 ⇒ 0%8==0 ⇒ setState ⇒ 变成 **1**
     *           ⇒ 之后 1%8!=0 ⇒ **永远 return** ⇒ 计数器再也涨不上去
     *   ⇒ 而"重建次数少"这个**表面指标反而很好看**（只重建 1 次）
     *     ⇒ ★ 典型的"指标变好但功能坏掉"
     * ★ 我的**模拟脚本**发现了它（跑 28 次完成 ⇒ 只 1 次重建 ⇒ 可疑）
     *   ⇒ 正确写法：用**独立的自增计数器** `seen`（每次都涨），
     *     只把它的值**同步**给 `_probeDone`。
     * ```
     */
    const progressStep = 8;
    var seen = 0; // ★ 每个频道都涨（与"要不要重建"解耦）
    final n = await _probe.probe(
      _groups,
      force: force,
      onProgress: () {
        if (!mounted) return;
        seen++;
        // ★ 节流：只在跨过整数个 step 时才重建（见上面长注释）
        if (seen % progressStep != 0) return;
        setState(() => _probeDone = seen);
      },
    );
    if (!mounted) return;
    setState(() {
      // ★ 收尾：保证进度条走到 100%（否则会停在最后一个未跨 step 的值）
      _probeDone = _probeTotal;
      _probed = true;
    });
    if (n > 0) debugPrint('[LIVE] 可用性探测完成：新探 $n / 共 $total');
  }

  /// 第一个"默认该显示"的频道（跳过仅音频/不可用的）
  LiveChannel? _firstVisible(List<LiveChannel> all) {
    for (final c in all) {
      final a = _probe.cached(_providerOf(c), c.id);
      if (shouldShowByDefault(a ?? LiveAvailability.unknown)) return c;
    }
    return all.isNotEmpty ? all.first : null;
  }

  /// 频道属于哪个 provider（`_groups` 里反查）
  String _providerOf(LiveChannel c) {
    for (final g in _groups) {
      if (g.channels.any((x) => x.id == c.id)) return g.provider;
    }
    return _activeProvider;
  }

  /// 当前 provider 下的频道
  List<LiveChannel> get _currentChannels {
    final g = _groups.where((x) => x.provider == _activeProvider).firstOrNull;
    return g?.channels ?? const [];
  }

  /// ★★★ 列表里**实际要画**的频道（task-42：**跨源平铺**）
  ///
  /// # 用户原话（本轮 6 条之一）
  /// ```text
  /// 直播页面,左侧不再分组,直接平铺下去,然后把不能有画面的都直接删了(直播源)
  /// 比如现在的 央视网分组,平铺下去 以分组加 tag 作为标记
  /// ```
  ///
  /// # 与 task-39 的三个**行为变化**（都是用户明确要求）
  /// ```text
  /// ① **不再按源过滤**：原来只看 `_activeProvider` 一个源，
  ///    现在**所有启用的源混在一起**平铺（用户说"直接平铺下去"）
  /// ② **不再按 group 分栏**：原来画"分组标题 + 频道"，
  ///    现在每行右边一个 **tag** 显示它来自哪个源（用户说"以分组加 tag"）
  /// ③ ★★ **audioOnly 直接不显示**（不再是"默认隐藏 + 可展开"）
  ///    用户说"把不能有画面的都**直接删了**"—— 比 task-39 更强硬
  /// ```
  ///
  /// # 判定仍用 `live_availability.dart`（不重写一套）
  /// ```text
  /// playable    → 显示
  /// audioOnly   → ★ 不显示（用户要"删掉"）
  /// unavailable → 不显示
  /// unknown     → ★ 显示（探不到 ≠ 不可用 —— 铁律 51 的对偶）
  /// ```
  List<LiveChannel> get _visibleChannels {
    final out = <LiveChannel>[];
    for (final g in _groups) {
      // ★ 用户手动关掉的源：不显示它的频道（③ 的启停）
      if (!_providerEnabled(g.provider)) continue;
      for (final c in g.channels) {
        final a = _probe.cached(g.provider, c.id) ?? LiveAvailability.unknown;
        if (a == LiveAvailability.unavailable) continue;
        // ★★ task-42：audioOnly 也**直接删掉**（不再给"显示"开关）
        if (a == LiveAvailability.audioOnly) continue;
        out.add(c);
      }
    }
    return out;
  }

  /// 这个源是否启用（用户手动开关）
  ///
  /// ★ 默认启用；用户关掉后进 `_disabledProviders`（内存态 + 落盘由 API 负责）
  bool _providerEnabled(String provider) =>
      !_disabledProviders.contains(provider);

  /// 用户手动关掉的源
  ///
  /// ⚠️ 与"因为不可用被隐藏"**是两件事**，必须能区分：
  /// ```text
  /// 手动关掉      → chip 仍在，显示"已关闭"，用户能再打开
  /// 不可用被剔除  → chip 直接不显示（用户没关它，是它自己不能用）
  /// ```
  /// ★ 这也是 lead 在 task-42 描述里点名的交互风险。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ task-53【②】2026-09-26：本集合**现在是空的**（重要，别误解）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// ```text
  /// ① 启停的**写入点已挪到设置页**（用户第 4 条要求）⇒
  ///    本页**不再**往这里 add/remove ⇒ 它恒为空集
  /// ② 而"关掉的源不显示"这件事**仍然成立** —— 但由**核心**负责：
  ///    `get_live_channels` 已按 `disabled-providers.json` 过滤
  ///    （task-D 实测：隔离副本里 cctv 被 disabled ⇒ 返回里**没有它**）
  /// ⇒ ★ 所以 `_providerEnabled()` 现在**恒为 true**，
  ///    那几处 `if (!_providerEnabled(g.provider)) continue;` 是**冗余但无害**的。
  /// ```
  ///
  /// ★★ 为什么不删掉它（有意保留）
  /// ```text
  /// ① 它是**纵深防御**：若将来核心改为"不过滤、由 UI 过滤"，
  ///    这里立刻仍能工作（而不是那时候才发现过滤逻辑没了）
  /// ② ★ 删它要动 `_visibleChannels` / `_flatChannels` / `_providerHasVideo`
  ///    三处判据 —— 而**它们现在都是对的**（恒真 ⇒ 不过滤 ⇒ 与核心一致）
  ///    ⇒ ★ "为了让代码好看而改三处正确逻辑"是**负收益**
  /// ③ 而它现在**只被读、不被写** ⇒ 单一写入点（设置页）+ 单一真相（核心 json）
  ///    ⇒ 比原来"两处都能写"更干净
  /// ```
  ///
  /// ⚠️ 若将来有人要给本页加回"点 tag 启停"⇒ ★ **先读上面这段** ——
  ///    那会重新引入"两个写入点"，且用户**已经明确否定过**那个位置。
  final Set<String> _disabledProviders = {};

  /// ★★ 有**可播视频**频道的源（task-42 ②：整组不可用就不显示那个源）
  ///
  /// # 为什么要有这一层（用户说"把不能有画面的都直接删了(直播源)"）
  /// ```text
  /// ★ 他举的例子是「现在的 央视网分组」——
  ///   央视网（cctv）实测 20/20 个频道视频线全 DRM ⇒ **整组都不可用**
  /// ⇒ 那就不该在源列表里留着它（否则用户以为"这源能用但没台"）
  /// ```
  /// 判据：该源**至少有一个** playable 频道。
  /// ⚠️ 探测还没跑完时（`unknown`）**不能**判它不可用 ——
  ///    否则源会在探测过程中**闪烁消失**。
  bool _providerHasVideo(String provider) {
    final g = _groups.where((x) => x.provider == provider).firstOrNull;
    if (g == null || g.channels.isEmpty) return false;
    for (final c in g.channels) {
      final a = _probe.cached(provider, c.id);
      // 探到 playable ⇒ 确定有
      if (a == LiveAvailability.playable) return true;
      // 还没探到 ⇒ 保守认为"可能有"（避免闪烁）
      if (a == null || a == LiveAvailability.unknown) return true;
    }
    return false;
  }

  /// 平铺列表真正要显示的源（有视频 + 用户没关掉）
  List<LiveGroup> get _visibleProviders => _groups
      .where((g) => _providerHasVideo(g.provider))
      .toList(growable: false);

  /// ★★★ task-42：**平铺**的频道列表（跨源混合 + 每项带来源 tag）
  ///
  /// # 用户原话
  /// ```text
  /// 直播页面,左侧不再分组,直接平铺下去 …
  /// 平铺下去 以分组加 tag 作为标记
  /// ```
  /// ⇒ 不再有"分组标题行"，改成**每行行尾一个 tag**。
  ///
  /// # tag 显示什么
  /// ```text
  /// 用户说"以**分组**加 tag" —— 这里的"分组"指的是他前一句说的
  /// 「比如现在的 **央视网**分组」⇒ 即 **providerName**（源名），
  /// 不是频道的 `group` 字段。
  /// ★ 依据：他把"央视网"称作一个"分组"，而央视网是**源**。
  ///   （`cctv.js` 的 group 字段其实是"央视"/"国际"，不是"央视网"）
  /// ```
  ///
  /// # 排序
  /// ```text
  /// 按**源**分组连续排列（同一个源的频道挨着），而不是打乱混合 ——
  /// 虽然视觉上没有分组标题了，但"同源的台在一起"更符合直觉。
  /// ★ 用户说"直接平铺下去"，重点是**去掉分组标题**，不是"打乱顺序"。
  /// ```
  List<({LiveChannel channel, String tag})> get _flatChannels {
    final out = <({LiveChannel channel, String tag})>[];
    for (final g in _groups) {
      if (!_providerEnabled(g.provider)) continue;
      if (!_providerHasVideo(g.provider)) continue;
      for (final c in g.channels) {
        final a = _probe.cached(g.provider, c.id) ?? LiveAvailability.unknown;
        // ★ 用户要"把不能有画面的都直接删了" ⇒ audioOnly 也不显示
        if (a == LiveAvailability.audioOnly) continue;
        if (a == LiveAvailability.unavailable) continue;
        out.add((channel: c, tag: g.providerName));
      }
    }
    return out;
  }

  /// 一个频道是不是"仅音频"（用于播放器角标）
  bool _isAudioOnly(LiveChannel c) =>
      _probe.cached(_providerOf(c), c.id) == LiveAvailability.audioOnly;

  /// [restoring] = `true` 表示这是**切回本页时找回原来的台**
  /// （`loadAll(keepSelection: true)` 那条路），**不是**用户主动换台。
  ///
  /// ★★★ task-82【Q4】：两者必须区分 —— 见下面第一段短路。
  Future<void> _select(LiveChannel ch, {bool restoring = false}) async {
    final provider = _providerOf(ch);

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-82【Q4】用户**主动暂停过** ⇒ "找回原台"整段短路
     * ══════════════════════════════════════════════════════════════════
     *
     * # 缺陷（Owner 会在几分钟内撞上）
     * ```text
     * 用户按暂停 → 切到别的 tab → 切回直播页
     *   ⇒ 内嵌播放器**自己播起来了**，违背他刚按下的暂停。
     * ```
     *
     * # 根因链（逐环实测，不是推测）
     * ```text
     * shell 切回 ⇒ `loadAll(keepSelection: true)` ⇒ 这里 `_select(原台)`
     *   → 旧代码无条件 `_stream = null; _userPaused = false;`
     *   → 播放器 `didUpdateWidget` 看到 url 从 A 变成 null（`a != b`）
     *      ⇒ `live_embedded_player.dart:507` `stop()`
     *   → `_loadStream` 回来，`_stream` 从 null 变成 A'
     *   → 播放器 `didUpdateWidget` 又看到 null → A'（`a != b`）
     *      ⇒ `:509 open(...)` → `:403-404 await p.open(); await p.play();`
     *   ★ 而 `:403-404` **不看 `_userPaused`** ⇒ 必然起播。
     * 实测时序：`取到` 出现在 `不自动续播` 之后 **31–40 ms**。
     * ```
     *
     * # ★ 为什么修法是"短路"，而不是去改播放器
     * ```text
     * ① `lib/ui/widgets/live_embedded_player.dart` **不在本任务写入范围**
     *    ⇒ 不能给它加"暂停时不许 play()"的门控。
     * ② ★★ 但**根本不需要**改它 —— 播放器 `didUpdateWidget:496-498`
     *    的判据是 **url**（`final a = oldWidget.stream?.url;`）：
     *    `a == b` 时**整段不执行** ⇒ 不 `open`、不 `play`。
     *    ⇒ 只要让 `_stream` 的 **url 保持不变**，播放器就**永远不会**
     *      走到 `play()`。这就是"播放器侧不起播"的等价实现，
     *      而且完全落在本文件里。
     * ③ ★ 语义上也是对的：暂停时我们**只 pause、没有 stop** ——
     *    流在播放器里**还开着**。切回来要的是"续播那条流"，
     *    **重取一遍反而是错的那一步**（它会换 url ⇒ 触发 open/play）。
     * ```
     *
     * # ⚠️ 边界：这里**不**重取流，代价是什么（如实写）
     * ```text
     * 若这条流在暂停期间**已经死了**，用户按播放会看到旧画面/报错，
     * 需要他自己换台（或再切一次 tab）才会重新取流。
     * ★ 这是**有意**的取舍：宁可"续播一条可能已死的流"，
     *   也不要"替他起播" —— 后者违背他的操作，前者只是不新鲜。
     * ```
     */
    if (restoring && _userPaused) {
      setState(() => _selected = ch);
      /*
       * ★★★ 2026-10-08（Owner 第 3 条）：「保留原流」必须**同时保证静默**
       *
       * # 为什么这条 pause 不能省
       * ```text
       * 本分支的语义是「用户此前主动暂停过 ⇒ 保留原流、不重取、不起播」，
       * 但**不重取/不起播 ≠ 不出声**：
       *   切走时 `_onVisibilityChanged` 只调了 `st.pause()`（mpv 的 pause 位），
       *   而此刻可见性投影刚翻成 true ⇒ 那条 `:409` 的 resume() 已经把它
       *   **重新出声**了（shell 的 `_syncVisibility()` 先跑、`loadAll` 后跑）。
       * ⇒ 走到这里时播放器**正在响**，而本分支后面直接 return
       *   ⇒ 用户听到「突然有声音」，然后被这条 return 之后的静默状态骗成
       *     「再没声音」（其实一直在响，只是没有新画面/进度在动）。
       * ⇒ 必须显式再 pause 一次，把「保留原流」这件事做实。
       * ```
       *
       * ⚠️ 判空：`_embedKey.currentState` 在首帧/未挂载时是 null
       *    （与 `_onVisibilityChanged` 的写法一致）。
       */
      final st = _embedKey.currentState;
      if (st != null) unawaited(st.pause());
      debugPrint('[LIVE] 切回本页：用户此前主动暂停过 ⇒ 保留原流、不重取、不起播');
      return;
    }

    setState(() {
      _selected = ch;
      // ★ 换台 ⇒ 清掉上一条流（避免播放器还挂着上一个台的声音）
      _streams = [];
      _stream = null;
      _streamLoading = true;
      // ★ 换台是用户的主动行为 ⇒ 清掉"用户暂停"标记（他要看新台）
      _userPaused = false;
    });

    /*
     * ★★★ 用户要求【A】"删除掉节目单" ⇒ 这里**不再取 EPG**
     *
     * ```text
     * 原来：`unawaited(_loadStream(...))` 与 `await getEpg(...)` **并发**
     * 现在：只取流
     * ★ 收益（用户第 8 条问"直播卡顿"）：切台少一次 IPC + 一次插件 JS 执行
     *   ⇒ 首帧更快；且不再有"节目单迟到"引起的额外 setState/重建
     * ```
     */
    unawaited(_loadStream(provider, ch.id));
  }

  /// ★ 取这个频道的流，并选出**第一条能播的**线路
  ///
  /// # 为什么必须"选能播的"而不是 `list.first`
  /// ```text
  /// cctv1 的返回顺序是 [高清(drm) , 标清(drm) , 仅音频(可播)]
  /// 用 list.first ⇒ 拿到 drm 那条 ⇒ 播放器黑屏
  ///   ★ 这正是 `player_page.dart` 那条日志的成因
  /// ⇒ 与它保持一致：`list.find((x) => !x.drm_protected) ?? list[0]`
  /// ```
  Future<void> _loadStream(String provider, String channelId) async {
    try {
      final list = await SourinApi.getLiveStream(provider, channelId);
      if (!mounted || _selected?.id != channelId) return;
      final playable = list.where((s) => s.isPlayable).toList();
      setState(() {
        _streams = list;
        // ★ 优先带视频的线路；都没有才退回音频线（至少能听）
        _stream = playable.where((s) => !isAudioOnlyLine(s)).firstOrNull ??
            playable.firstOrNull;
        _streamLoading = false;
      });
      debugPrint('[LIVE] $channelId 取到 ${list.length} 条线路，'
          '可播 ${playable.length}，选用 ${_stream?.displayName ?? "无"}');
    } catch (e) {
      debugPrint('[LIVE] 取流失败 $channelId: $e');
      if (!mounted || _selected?.id != channelId) return;
      setState(() {
        _streams = [];
        _stream = null;
        _streamLoading = false;
      });
    }
  }

  // ══════════════════════════════════════════════════════════════════
  //  ★★ 循环切换频道（用户要求"往下循环切换"）
  // ══════════════════════════════════════════════════════════════════

  /// 切换频道
  ///
  /// [delta] `+1` 下一个、`-1` 上一个。
  ///
  /// # ★ 循环语义（用户明确说"循环"）
  /// ```text
  /// 最后一个按"下一个" ⇒ 回到第一个
  /// 第一个按"上一个"   ⇒ 跳到最后一个
  /// ```
  /// ★ 与 `player_page` 的"下一集"**有意不同** ——
  ///   那里到最后一集是**什么都不做**（`_nextEpisode == null`）。
  ///   直播是连续观看场景，卡在末尾没有意义。
  ///
  /// # 在**可见**频道里循环（不是全部频道）
  /// 隐藏掉的台（仅音频/不可用）不该被切到 —— 否则用户按 ↓
  /// 会跳到一个"看不到的台"，感觉像卡住了。
  void cycleChannel(int delta) {
    final next = _neighborChannel(delta);
    if (next == null) return;
    unawaited(_select(next));
  }

  /// ★★★ task-53【#4b】算出"相邻的下一个台" —— ★ **纯查询，不起播**
  ///
  /// # 为什么必须把它从 `cycleChannel` 里拆出来（不是"为整洁而拆"）
  ///
  /// 播放页（全屏直播）按 ↑/↓ 要切台，而**两个页面各有分工**：
  /// ```text
  /// 本页   ：唯一知道"哪些台可见"（探针缓存 TTL + 启用态 + audioOnly 过滤）
  /// 播放页 ：唯一持有正在出声的那个 mpv
  /// ```
  /// ⇒ 本页只回答"**下一个是哪个**"，由播放页去播。
  ///
  /// ⚠️ **不能**让播放页直接调 `cycleChannel`（我第一版就是这么写的）：
  /// ```text
  /// `cycleChannel` → `_select` → `_loadStream` ⇒ 内嵌播放器
  ///   `didUpdateWidget` 看到 url 变了 ⇒ `open()` + **`play()`**
  /// ⇒ 而此刻播放页**也在播**（用户就在全屏里）
  /// ⇒ ★★ 两个 mpv 同时出声 = 回声/重音
  ///    （这正是 `_watchLive` 那段注释拼命要防的东西）
  /// ```
  ///
  /// ★ 而把它拆出来后，**两处共用同一份取模算式**（铁律 170：
  ///   一条纪律一个实现）—— 不会出现"直播页循环、播放页越界"。
  LiveChannel? _neighborChannel(int delta) {
    final list = _visibleChannels;
    // ③ 逻辑层
    debugPrint('[LIVE-KEY] ③ 逻辑层：cycleChannel($delta) 列表=${list.length} 个'
        '（当前选中=${_selected?.id ?? "无"}）');
    if (list.isEmpty) return null;
    final cur = _selected;
    var i = cur == null ? -1 : list.indexWhere((c) => c.id == cur.id);
    if (i < 0) {
      // 当前选中的不在可见列表里（比如是隐藏的仅音频台）⇒ 从头开始
      i = 0;
    } else {
      // ★ 取模实现循环（Dart 的 % 对负数返回非负，正是我们要的）
      i = (i + delta) % list.length;
    }
    debugPrint('[LIVE-KEY]    ⇒ 切到第 $i 个：${list[i].name}');
    return list[i];
  }

  /// ★★★ task-53【#4b】播放页在全屏里按了 ↑/↓ ⇒ 本页**只改选中**，不起播
  ///
  /// 返回给播放页的目标（`null` = 没有可切的台 ⇒ 播放页会给用户一个提示）。
  ///
  /// # 为什么**不**在这里 `_select`（关键设计）
  /// ```text
  /// 全屏时本页是**不可见**的（被 PlayerPage 盖住），但有两点硬约束：
  /// ① 此刻出声的是播放页那个 mpv ⇒ 本页**绝不能**起播（会双声）
  /// ② 但**选中高亮必须跟着走** —— 用户 pop 回来看列表时，
  ///    当前正在播的台必须是高亮那个（否则他看到"我明明切了，列表还停在旧台"）
  /// ⇒ 所以：改 `_selected` + **清掉 `_stream`**（让内嵌播放器停掉旧台的声）
  ///    并记下 `_pendingFullscreenChannel`，等 pop 回来再接手播放。
  /// ```
  ({String provider, LiveChannel channel})? stepChannelForFullscreen(int delta) {
    final next = _neighborChannel(delta);
    if (next == null) return null;
    return _adoptChannelForFullscreen(next);
  }

  /// ★★★ task-53【③】把**当前可见频道列表**交给播放页（供"所有直播"面板）
  ///
  /// 返回 `(channels, index)`；`null` = 没有可显示的频道。
  ///
  /// # 为什么由本页回答（而不是播放页自己去查）
  /// ```text
  /// 与 `stepChannelForFullscreen` **同一条理由**（见它的长注释）：
  /// "哪些台可见"依赖 `LiveAvailabilityProbe` 的 TTL 缓存 + `_disabledProviders`
  /// + audioOnly/unavailable 过滤 ⇒ 播放页自己算一遍 = **两套真相**
  ///   ⇒ 面板里会列出"其实不能播"的台，或漏掉能播的台。
  /// ★ 本页的 `_visibleChannels` 是**唯一真相**（铁律 170）。
  /// ```
  ///
  /// ⚠️ 只读：**不改** `_selected`、**不起播** —— 纯查询，可任意次调用。
  ({List<LiveChannel> channels, int index})? channelsForFullscreen() {
    final list = _visibleChannels;
    if (list.isEmpty) return null;
    final cur = _selected;
    var i = cur == null ? -1 : list.indexWhere((c) => c.id == cur.id);
    if (i < 0) i = 0; // 选中的不在可见列表里（如被隐藏的仅音频台）⇒ 从第一个开始
    /*
     * ⚠️ **不打日志**（有意）——
     *   调用方 `player_page.dart` 在 `build` 里调它（`data: _liveChannels()`），
     *   而播放中 `_position` 每 tick 都 `setState`（`player_page.dart:1626`）
     *   ⇒ 在这里 `debugPrint` 会**每几百毫秒刷一行**，把真机排障的日志淹掉
     *     （我第一版就是打了的 —— 实测会发现日志里全是它）。
     * ★ 需要取证时看 `_adoptChannelForFullscreen` 那行（只在**真的换台**时打）。
     */
    return (channels: list, index: i);
  }

  /// ★★★ task-53【③】播放页在"所有直播"面板里**点选了某个台**
  ///
  /// 与 `stepChannelForFullscreen` **共用** `_adoptChannelForFullscreen`
  /// （铁律 170：一条纪律一个实现）—— 否则"点选"与"上下键"两条路
  /// 迟早会分叉出不同的行为（比如一个清线路、一个不清 ⇒ 双声）。
  ///
  /// 返回 `null` = 这个台不在可见列表里（正常不会发生：列表就是本页给的）。
  ({String provider, LiveChannel channel})? pickChannelForFullscreen(
    LiveChannel channel,
  ) {
    final inList = _visibleChannels.any((c) => c.id == channel.id);
    if (!inList) {
      debugPrint('[LIVE-KEY] 全屏点选：${channel.name} 不在可见列表里 ⇒ 忽略');
      return null;
    }
    debugPrint('[LIVE-KEY] 全屏点选 ⇒ ${channel.name}');
    return _adoptChannelForFullscreen(channel);
  }

  /// ★ "采纳某个台"的**唯一实现**（↑/↓ 与点选**共用**）
  ///
  /// # 为什么**不**在这里 `_select`（关键设计）
  /// ```text
  /// 全屏时本页是**不可见**的（被 PlayerPage 盖住），但有两点硬约束：
  /// ① 此刻出声的是播放页那个 mpv ⇒ 本页**绝不能**起播（会双声）
  /// ② 但**选中高亮必须跟着走** —— 用户 pop 回来看列表时，
  ///    当前正在播的台必须是高亮那个（否则他看到"我明明切了，列表还停在旧台"）
  /// ⇒ 所以：改 `_selected` + **清掉 `_stream`**（让内嵌播放器停掉旧台的声）
  ///    并记下 `_pendingFullscreenChannel`，等 pop 回来再接手播放。
  /// ```
  ({String provider, LiveChannel channel}) _adoptChannelForFullscreen(
    LiveChannel next,
  ) {
    final provider = _providerOf(next);
    debugPrint('[LIVE-KEY] 全屏切台 ⇒ ${next.name}（provider=$provider）'
        '：本页只改选中，起播交给播放页');

    setState(() {
      _selected = next;
      /*
       * ★ 清空线路 ⇒ 内嵌播放器 `didUpdateWidget` 看到 `b == null` 会 `stop()`
       *   ⇒ 旧台的声音立刻停（不会一边全屏新台、一边后台旧台）。
       */
      _streams = [];
      _stream = null;
      _streamLoading = true;
      // ★ 换台是主动行为 ⇒ 清掉"用户暂停"（与 `_select` 同一条纪律）
      _userPaused = false;
    });
    _pendingFullscreenChannel = next;
    return (provider: provider, channel: next);
  }

  // ★ 2026-09-26【A】`_fmtTime` 已移除（只被节目单/回看标题使用）

  /// 进全屏播放器 —— ★ 带**音频焦点交接**（lead 裁决 (a)）
  ///
  /// # 为什么不能直接 push（那样会双声）
  /// ```text
  /// 本页有内嵌播放器在放；push 出的 PlayerPage 也会 open 同一路流。
  /// 两个 mpv 实例同时解码输出 ⇒ **回声/重音**，用户立刻能听出来。
  /// ```
  ///
  /// # 三个必须（lead 明确要求，逐条对应下面代码）
  /// ```text
  /// ① `_pausedForFullscreen` **独立于** `_userPaused`
  ///    语义不同：
  ///      _userPaused          = "用户按了暂停"（他的意图）
  ///      _pausedForFullscreen = "我为了全屏让路的暂停"（我们的行为）
  ///    ★ 混用 ⇒ "用户暂停后跳全屏再回来"会被自动播起来（违背他的操作）
  ///
  /// ② 续播前**再检查一次可见性**
  ///    用户可能从全屏**直接切走 tab**（没回到直播页）⇒ 那时不该播
  ///
  /// ③ `await` 期间本页可能被 dispose
  ///    ⇒ `if (!mounted) return;`
  ///    ★ 而且内嵌播放器那时可能也已 dispose ⇒ 不能盲目调 pause/play
  ///      （`LiveEmbeddedPlayerState` 里有 `_disposed` 守卫，但这里也要防）
  /// ```
  Future<void> _watchLive() async {
    final s = _selected;
    if (s == null) return;
    final cb = widget.onWatchLive;
    if (cb == null) return;

    final embedded = _embedKey.currentState;

    // ① 跳转前暂停内嵌（只在它真的在放时才暂停/记标记）
    final wasPlaying = embedded?.isPlaying ?? false;
    if (wasPlaying) {
      await embedded?.pause();
      _pausedForFullscreen = true;
      debugPrint('[LIVE] 进全屏 ⇒ 暂停内嵌播放器（返回时续播）');
    }

    // ② 等全屏页真正 pop（Future 在 pop 时完成）
    //
    // ⚠️ provider 用 `_providerOf(s)` 反查 —— 不能直接用 `_activeProvider`：
    //    频道可能属于**别的**源（用户在播放页期间切了源）。
    await cb(_providerOf(s), s.id, s.name);

    // ③ 回来后（可能已 dispose / 已切走 tab / 用户手动暂停过）
    if (!mounted) return;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-53【#4b】优先处理"全屏里切过台"
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须排在 `_pausedForFullscreen` **之前**
     * ```text
     * 全屏里切了台 ⇒ `_stream` 已被清空（我们主动 stop 了内嵌播放器）
     *   ⇒ 此刻 `resume()` 是**无意义的**（没有流可播）
     *   ⇒ 正确动作是 `_select(新台)`：它自己会取流并起播
     * ★ 顺序反了的表现：用户切了台再退出全屏，回来看到**旧台的画面**
     *   （或黑屏），得再点一下列表才恢复。
     * ```
     *
     * ⚠️ `_pausedForFullscreen` 仍要清 —— 它是"为全屏让路"的事实，
     *    现在已经不在全屏了，留着会污染下一次可见性变化。
     */
    final pending = _pendingFullscreenChannel;
    if (pending != null) {
      _pendingFullscreenChannel = null;
      _pausedForFullscreen = false;
      final visible0 = widget.visible?.value ?? true;
      if (!visible0) {
        debugPrint('[LIVE] 从全屏返回，但本页已不可见 ⇒ 不接手播放'
            '（${pending.name}）');
        return;
      }
      debugPrint('[LIVE] 从全屏返回 ⇒ 接手播放全屏里切到的台：${pending.name}');
      await _select(pending);
      return;
    }

    if (!_pausedForFullscreen) return;
    _pausedForFullscreen = false;

    final visible = widget.visible?.value ?? true;
    if (!visible) {
      debugPrint('[LIVE] 从全屏返回，但本页已不可见 ⇒ 不续播');
      return;
    }
    if (_userPaused) {
      debugPrint('[LIVE] 从全屏返回，但用户此前主动暂停过 ⇒ 不续播');
      return;
    }
    final st = _embedKey.currentState;
    if (st == null) return;
    await st.resume();
    debugPrint('[LIVE] 从全屏返回 ⇒ 续播内嵌播放器');
  }

  /// ★ 2026-09-26【A】`_watchReplay(EpgEntry)` 已移除 ——
  ///   节目单删除后没有入口能触发回看（`onWatchReplay` **构造参数保留**，
  ///   因为 `shell.dart` 仍在传，而 shell 不在本任务写入范围）。
  ///
  /// ★ `_fmtTime` 也一并移除（它只被节目单与回看标题用）。

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.of(context).size.width < 900;

    if (_loading) {
      /*
       * ★ 加载骨架 —— 原版是**两栏骨架**（`LiveView.vue:162-165`）
       *
       * ```html
       * <div v-if="loading" class="live-layout">
       *   <div class="skeleton" style="height: 400px" />   ← 左：频道列表
       *   <div class="skeleton" style="height: 400px" />   ← 右：节目单
       * </div>
       * ```
       *
       * 原来这里是一个居中转圈。转圈的**布局跳动**很明显：
       * 转圈消失后两栏才出现，页面从"居中一个小圆"突然变成
       * 左 268px + 右自适应 —— 骨架能把这个跳动消掉。
       *
       * ⚠️ 用 `IgnorePointer` 包住：骨架期间不允许交互，
       *    否则用户可能在半成品布局上点到不该点的东西。
       */
      return IgnorePointer(
        child: ListView(
          clipBehavior: Clip.antiAlias,
          // ⚠️ 不能加 `const` —— `Sp.bottomBarInset` 是 getter（TV/非 TV 不同值）
          // ★ 内容带（t509）：原版 `LiveView.vue:153 <div class="container">` 那一层
          //   —— 整页只有这一个 `.container`，页头与 `.live-layout` 都是它的子节点、
          //   自身**没有**横向内边距（`LiveView.vue` 的 28 条 scoped 规则里无 horizontal
          //   padding）⇒ 本页是 **×1**，不像首页分区轨道那样 ×2。
          //   `Layout.horizontalInsetOf` 一次给出两层：居中留白 + 容器内边距。
          padding: Layout.horizontalInsetOf(context) +
              EdgeInsets.only(
                top: Sp.x8,
                bottom: Sp.bottomBarInset,
              ),
          children: [
            const _PageHead(channelCount: 0, showEpgHint: false),
            const SizedBox(height: Sp.x5),
            // ★ 内容带（t509）：原来这里是 `AppMetrics.contentPadding`（24）
            //   —— 那一层已由上面 `ListView.padding` 的 `Layout.horizontalInsetOf` 提供，
            //   留着会变成 ×2（TV 上会从 72 变 96，与原版不符）。
            Padding(
              padding: EdgeInsets.zero,
              child: isNarrow
                  ? const Column(
                      children: [
                        SizedBox(height: 320, child: _PanelSkeleton()),
                        SizedBox(height: Sp.x5),
                        _PanelSkeleton(),
                      ],
                    )
                  : const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 268,
                          height: 520,
                          child: _PanelSkeleton(),
                        ),
                        SizedBox(width: Sp.x5),
                        Expanded(child: _PanelSkeleton()),
                      ],
                    ),
            ),
          ],
        ),
      );
    }

    if (_currentChannels.isEmpty) {
      return const _EmptyState(
        icon: Icons.live_tv_outlined,
        title: '没有可用的直播源',
        desc: '在设置中启用一个支持直播的内容源',
      );
    }

    final list = _ChannelList(
      providers: _visibleProviders,
      enabledProviders: {
        for (final g in _groups)
          if (_providerEnabled(g.provider)) g.provider,
      },
      channels: _flatChannels,
      selectedId: _selected?.id,
      /*
       * ★ 2026-09-26【②】`onToggleProvider` **已移除** ——
       *   用户要求把"直播源启停"挪到设置页（第 4 条原话），
       *   所以本页的源标签条改成**只读**（见 `_ChannelList` 里那段说明）。
       *
       * ⚠️ 但**能力没丢**：
       *   · 设置页「JS 插件」里每张源卡片的启用/停用走**同一个**
       *     `setProviderEnabled`
       *   · 而核心**已按 disabled 过滤** `get_live_channels`
       *     （task-D 实测：隔离副本里 cctv 被 disabled ⇒ 返回里**没有它**）
       *   ⇒ ★ 设置页改完，本页下次 `loadAll()` 自然生效 —— **不需要**本地镜像
       *
       * ⚠️ 那 `_disabledProviders` 为什么**还留着**？
       *   它仍是本页的**显示**依据（`enabledProviders` 用它决定标签高亮）。
       *   ★ 而它现在**只由 `loadAll()` 从核心同步**，不再由本页写入
       *     ⇒ 单一写入点（设置页），单一真相（核心的 json）—— 更干净。
       */
      onPickChannel: _select,
    );

    /*
     * ── 右侧：内嵌播放器 + 节目单 ──
     *
     * ★ task-39 布局（用户原话）：
     * > 所支持的直播列表在左边占满高度，右侧放个播放器
     * > 默认选中第一个，默认打开就自动直播开始播放
     *
     * ⚠️ EPG（节目单）**不许默默删掉**（已有功能）——
     *    lead 裁决【设计点 3】= A（放播放器下方）+ **可折叠**
     *    （因为 cctv 被隐藏后 EPG 会整块空）。
     */
    final player = LiveEmbeddedPlayer(
      key: _embedKey,
      /*
       * ★★ task-74 ⑤ 回归修复：把**可见性信号**交给播放器自己。
       *
       * 为什么必须传：原生重活延后 380ms ⇒ 这段窗口里 `_player == null`
       * ⇒ `isPlaying` 恒 false ⇒ 本页 `_onVisibilityChanged()` 若靠
       * `st.isPlaying` 判断就永不成立（**已改为无条件置位**，
       * 见 `_onVisibilityChanged()` 里那段 task-74 ⑤ 残余竞态说明）
       * ⇒ 380ms 后 `_create()` 会把已切走的页面播起来（有声音）。
       * 播放器据此**抑制起播**，恢复可见时自己补播
       * （`pause()`/`resume()` 的既有语义不变）。
       */
      visible: widget.visible,
      stream: _stream,
      title: _selected?.name ?? '未选择频道',
      subtitle: _selected == null
          ? null
          : (_streamLoading
              ? '取流中…'
              : _isAudioOnly(_selected!)
                  ? '仅音频'
                  : _selected!.group),
      audioOnly: _selected != null && !_streamLoading && _isAudioOnly(_selected!),
      onToggleFullscreen: _selected == null ? null : _watchLive,
      onError: (msg) => debugPrint('[LIVE] 内嵌播放器报错: $msg'),
      /*
       * ★★ 用户要求【B】：双击进全屏
       *   判据与播放页同源（`PlayerGestures.doubleTapEnabledFor`）：
       *   触摸端双击**不**进全屏（那是"左右快进快退"的语义位），
       *   PC/TV 双击 = 全屏。
       *   ★ 传入 `Device.isTouchOnly` —— 与播放页 `_isTouchGestureTarget`
       *     用的是**同一个来源**（`widget.isTouchOnly`）。
       */
      isTouchOnly: Device.isTouchOnly,
      /*
       * ★ 把"用户自己按了暂停"上报给本页 ——
       *   这样可见性变化时**不会**把它自动播起来（尊重用户意图）。
       *   lead 明确要求这个行为（"记住用户的暂停意图"）。
       */
      onUserPause: (paused) {
        /*
         * ★★★ 2026-10-08（Owner 第 3 条）：**可见性门控**
         *
         * # 为什么必须有这一层
         * ```text
         * 播放器侧的 `onUserPause` 只看它自己的 `p.state.playing`
         * （Dart 侧标志，**不等于真实出声**），而且会在
         * 「我们因不可见而 pause」时被**误触发** ——
         * 于是 `_userPaused` 被置真，而它**没有任何复位路径**
         * （除了换台）。
         * ⇒ 切回本页时 `_onVisibilityChanged` 的 `if (_userPaused) return`
         *   会把自动续播**永久拦住** = 用户报的「然后再没声音」。
         * ```
         *
         * ⚠️ 判据与播放器侧 `live_embedded_player.dart` 的 `_visibleNow`
         *    **同一套**：`widget.visible?.value ?? true`
         *    （信号缺失时视为可见 —— 与那边一致，不能一边 true 一边 false）。
         * ⚠️ 门控**只挡写入**，不挡「用户恢复播放」：页面可见时
         *    paused == false 照旧能清掉标记。
         */
        if (!(widget.visible?.value ?? true)) {
          debugPrint('[LIVE] 本页不可见 ⇒ 忽略播放器上报的用户暂停($paused)');
          return;
        }
        if (_userPaused == paused) return;
        _userPaused = paused;
        debugPrint('[LIVE] 用户${paused ? "暂停" : "恢复"}了直播');
      },
    );

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-26 用户实测要求【A】：**删掉节目单**
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 直播删除掉节目单,左侧固定,右侧就一个播放器也固定
     *
     * ⇒ 本页**不再渲染** `EpgPanel` / `CollapsibleEpg`（连同产生它们的
     *   `epg` 变量与 `openOnce` 那一步）。
     *
     * ★ 为什么**连取数也删**（不只是不显示）：
     * ```text
     * ① 切台时 `_select` 里那次 `getEpg` 是**并发**发的（见该处注释），
     *    但仍占一次 IPC + 一次插件 JS 执行
     * ② 不显示却继续取 ⇒ **纯浪费**，且用户看不到任何收益
     * ③ 用户第 8 条问"直播卡顿" —— 少一次每台必发的 RPC 对首帧有正贡献
     * ⇒ 一并删掉取数（`_epg` / `_epgLoading` / `_epgKey` / `_now` / `_clock`）
     * ```
     *
     * ⚠️ **只删直播页的**：详情页/其它页若需要 EPG，与本页无关
     *   （`SourinApi.getEpg` 本身**保留**，没删）。
     *
     * ⚠️ `onWatchReplay` 这个**构造参数保留**（`shell.dart` 仍在传，
     *   而 shell 不在我的写入范围）—— 本页不再使用它，但签名不变。
     *   同理 `_watchLive` 仍被播放器的全屏按钮用（`onToggleFullscreen`）。
     */

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-26【C】"所有直播"面板（复用播放页的「选集」组件）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话（第 2 条后半）：
     * > 直播页面可以看所有的直播,**就跟选集逻辑一样**,
     * > 点击出来所有的直播,然后**上下按键在这里替换为切换直播**
     *
     * # 为什么复用 `EpisodePanel` 而不是新造
     * ```text
     * 用户说的"就跟选集逻辑一样" ⇒ **字面复用**同一个组件最贴合。
     * 它已经具备：PC 右抽屉 / 手机·TV 底部抽屉 / 分段 / 搜索 / 自动滚到当前项
     * ★ 而"上下键切换"也**天然可用** —— `EpisodeSheet` 自己就是
     *   一列可聚焦的项（`_focusCurrent` / `_scrollToCurrent`），
     *   方向键在其中移动是它既有行为。
     * ```
     *
     * # ★ 频道 → `Episode` 的映射（为什么可以这样映射）
     * ```text
     * `Episode{id,title,url,index}` 与 `LiveChannel{id,name,...}` 的语义可对齐：
     *   Episode.id    ← LiveChannel.id     （选谁 ⇒ 我们能唯一定位频道）
     *   Episode.title ← LiveChannel.name   （显示名）
     *   Episode.url   ← null               （直播不需要"每集一个 url"，
     *                                        取流仍走 getLiveStream）
     *   Episode.index ← 位置序号            （面板用它做"当前项"高亮）
     * ★ 而且面板**并发**不需要知道这是"集"还是"频道" —— 它只渲染列表。
     * ⚠️ 不改 `Episode` 模型（在 `lib/core/models.dart`，归别的任务）。
     * ```
     *
     * # ★★ 数据源：**全部可见频道**（不是只能按源取）
     * ```text
     * 我【D】实测过：`get_live_channels` 的 `provider` 参数**被忽略**
     * （三次调用返回逐字节相同）⇒ 无法"按源取频道"。
     * ★ 用户要的正是"可以看**所有**的直播" ⇒ 列**全部可见频道**即可，
     *   并在每项上**标出它来自哪个源**（`title` 里带 tag）。
     * ```
     */
    final allChannelEntries = _flatChannels;
    final allEpisodes = <Episode>[
      for (var i = 0; i < allChannelEntries.length; i++)
        Episode(
          id: allChannelEntries[i].channel.id,
          // ★ 带来源 tag —— 与左栏列表同一口径（`_FlatEntry.tag`）
          title: '${allChannelEntries[i].channel.name}'
              '  · ${allChannelEntries[i].tag}',
          index: i,
        ),
    ];
    // 当前选中的索引（面板要据此高亮 + 自动滚到它）
    final curIdx = _selected == null
        ? 0
        : allChannelEntries.indexWhere((e) => e.channel.id == _selected!.id);

    /*
     * ★ 线路选择（只有**多于一条可播线路**时才显示）
     *
     * # 为什么需要
     * ```text
     * cctv1 返回 [高清(drm) / 标清(drm) / 仅音频(可播)]
     *   ⇒ 可播的只有一条 ⇒ 不显示切换器（没得选）
     * 但别的源常有 高清/标清/备用 多条可播线
     *   ⇒ 用户需要能在"清晰但可能卡"和"糊但流畅"之间选
     * ```
     * ★ 只列**可播**的 —— 列上 DRM 线路等于给用户一个必然黑屏的按钮。
     */
    final playableLines = _streams.where((s) => s.isPlayable).toList();
    final lineSwitcher = playableLines.length > 1
        ? Padding(
            padding: const EdgeInsets.only(top: Sp.x2),
            child: Wrap(
              spacing: Sp.x2,
              runSpacing: Sp.x2,
              children: [
                for (final s in playableLines)
                  _LineChip(
                    label: s.displayName,
                    active: s.url == _stream?.url,
                    onTap: () => setState(() => _stream = s),
                  ),
              ],
            ),
          )
        : const SizedBox.shrink();

    /*
     * ★★ 整页包一层 `Focus` —— 方向键切频道（循环）
     *
     * # 为什么要一个**自己**的 Focus
     * ```text
     * spatial_nav 的 handler 跑在焦点树**之前**（HardwareKeyboard），
     * 它按**几何位置**找邻居。直播页要的是"相邻频道 + 末尾循环"，
     * 不是"跳到一个几何上更近的控件"。
     * ⇒ 本页先用 onKeyEvent 处理 ↑/↓，返回 handled 吃掉事件。
     *   ★ 注意 `KeyEventResult.handled` 只对**本 Focus 子树内**的事件生效；
     *     spatial_nav 是全局 handler，所以本页必须真的抢到焦点
     *     （`autofocus: true` + 点列表时焦点进来）。
     * ```
     *
     * ⚠️ 与 task-3 的关系：他给 `spatial_nav._scrollIntoView` 加"输入来源门控"
     *    （只让键盘/遥控滚，不让鼠标滚轮滚）。
     *    ★ **遥控/键盘导航必须保留滚动** —— 本页的遥控切台靠
     *      `_ChannelTile` 自己的 `Scrollable.ensureVisible` 保证可见，
     *      不依赖 spatial_nav 那条路径，但 task-3 不能把遥控整体关掉。
     */
    /*
     * ★★★ task-42 修「上下键切不了」—— 关键改动
     *
     * # 原来为什么可能收不到键（任务级的坑）
     * ```text
     * 我 task-39 只写了 `Focus(autofocus: true, onKeyEvent: _onKey)`。
     * ★ 但 `autofocus` **只在"没人抢焦点"时才生效** ——
     *   而 shell 里 `primeFocusSoon()` / `FocusPrimingObserver`
     *   会在进页面时**主动把焦点种到第一个可聚焦控件**上
     *   （那是 task-AI 为 TV 遥控做的，见 shell.dart 的长注释）。
     * ⇒ 焦点被种到别处 ⇒ 我的 Focus 只是**祖先链上的一层**，
     *   而方向键会被**更近的那个** Focus（比如某个 InkWell）先消费/冒泡到别处。
     * ```
     *
     * # 修法：用**显式 FocusNode** + 进页面/列表变化时主动请求焦点
     * ```text
     * · 显式 node ⇒ 我能控制它何时拿焦点（autofocus 不够）
     * · `onKeyEvent` 挂在 node 上 ⇒ 只要焦点在**我这层或我子树内**
     *   就能收到（Flutter 沿祖先链冒泡）
     * · 加 `_onKeyAny` 做**三层诊断**打点 ⇒ 下次再出问题能立刻定位
     * ```
     *
     * ⚠️ `skipTraversal: true` + `canRequestFocus: true`：
     *    本层是**拦截器**（要收方向键），但它不该成为 Tab 遍历的一站
     *    （否则用户按 Tab 会停在整页容器上，很奇怪）。
     */
    return Focus(
      focusNode: _pageFocus,
      autofocus: true,
      onKeyEvent: _onKeyAny,
      skipTraversal: true,
      // ★★【C】`Stack` 是为了让"所有直播"面板**叠在本页之上**
      //   （见下面 `Positioned.fill` 那段的长注释）
      child: Stack(
        children: [
      Padding(
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 用户要求【A】：「左侧固定，右侧就一个播放器也固定」
         * ══════════════════════════════════════════════════════════════
         *
         * ```text
         * 原来：外层是 `ListView`（整页可滚）
         *   ⇒ 滚一下页头就跑了，左右两栏**跟着一起滚**
         *   ⇒ 用户说的"固定"就是反对这个
         * 现在：外层改成 **`Padding` + `Column`** ⇒ 整页**不滚动**
         *   · 左栏：自己内部滚（`_ChannelList` 自带 ListView）
         *   · 右栏：播放器 + 线路切换，**高度固定**
         * ```
         * ⚠️ 为什么不是 `SingleChildScrollView`：那仍然"整页可滚"，
         *    只是把溢出交给它 —— 用户要的是**不滚**（两栏各自固定）。
         */
        // ★ 内容带（t509）：原版 `LiveView.vue:153 <div class="container">`
        //   —— 本页**只有一个** `.container`，`.page-head`（:154）与
        //   `.live-layout`（:174）都是它的子节点、自身无横向内边距
        //   ⇒ 本页是 **×1**（首页分区轨道才是 ×2）。
        //   `Layout.horizontalInsetOf` = 居中留白 + 容器内边距（一次给全）。
        padding: Layout.horizontalInsetOf(context) +
            EdgeInsets.only(
              top: Sp.x8,
              bottom: Sp.bottomBarInset,
            ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 页头 ──
            _PageHead(
              channelCount: _visibleChannels.length,
              // ★ 节目单已删 ⇒ 不再显示"支持节目单与回看"提示
              showEpgHint: false,
              // ★★【C】"所有直播"入口（有频道才给 —— 没频道时点开是空面板）
              onShowAll: allEpisodes.isEmpty
                  ? null
                  : () => setState(() => _allChannelsOpen = true),
            ),

            // ── 探测进度（列表会陆续出现，必须让用户知道为什么）──
            if (_probed == false && _probeTotal > 0)
              Padding(
                padding: const EdgeInsets.only(top: Sp.x2),
                child: Text(
                  '正在检查频道可用性 $_probeDone/$_probeTotal …',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: Sp.x5),

            /*
             * ★★ 主体：`Expanded` 让它吃掉剩余高度 ⇒ 两栏**都固定**在视口内
             *    （没有 Expanded 时 Column 会按内容高度铺，可能溢出）
             */
            Expanded(
              child: isNarrow
                  ? _buildNarrowBody(list, player, lineSwitcher)
                  : _buildWideBody(list, player, lineSwitcher),
            ),
          ],
        ),
        ),
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 2026-09-26【C】"所有直播"面板（覆盖层）
         * ══════════════════════════════════════════════════════════════
         *
         * ```text
         * 用户原话：「点击出来所有的直播,然后上下按键在这里替换为切换直播」
         *
         * ★ 用 `EpisodePanel`（播放页"选集"的同一个组件）⇒ 形态自动分流：
         *     PC ⇒ 右侧抽屉 ／ 手机·TV ⇒ 底部抽屉
         * ★ 并复用 `SheetTransition` 让**关闭也有动画**
         *   （播放页 task-28 ①-A 踩过：直接移除子树 ⇒ 关闭没动画）
         *
         * ⚠️ **不** import `player_page.dart` 的 `PlayerPanelTheme`
         *   （那会把整个播放页拉进本页的依赖图）。
         *   ★ 而主题**本来就有** —— `shell.dart:1079` 的
         *     `MaterialApp.builder` 里全局注入了 `AppThemeHost(data: materialTheme)`
         *     ⇒ `EpisodePanel` 里的 `FTheme.of(context)` 能正常工作。
         *     （已核：`episode_strip.dart` 用了 7 处 `FTheme.of(context)`）
         * ⚠️ `currentIndex: curIdx` —— **↑/↓ 切台后高亮会自动跟随**
         *   （`EpisodeSheet` 里 `active: i == widget.currentIndex` +
         *    `didUpdateWidget` 自动滚动 —— 实测它在两处都实现了）
         * ```
         */
        Positioned.fill(
          child: SheetTransition(
            visible: _allChannelsOpen,
            slideFrom: Device.isDesktop
                ? const Offset(24, 0)
                : const Offset(0, 24),
            child: EpisodePanel(
              episodes: allEpisodes,
              currentIndex: curIdx,
              onPick: (ep) {
                // ★ 选中 ⇒ 切台 + 关面板（与"选集"点一下就走同一体验）
                final hit = allChannelEntries
                    .where((e) => e.channel.id == ep.id)
                    .firstOrNull;
                setState(() => _allChannelsOpen = false);
                if (hit != null) unawaited(_select(hit.channel));
              },
              onClose: () => setState(() => _allChannelsOpen = false),
            ),
          ),
        ),
      ],
      ),
    );
  }

  /// 窄屏（手机/竖屏）：播放器在上 → 列表在下（自身可滚）
  ///
  /// ★ 用户【A】的"固定"主要针对桌面；窄屏仍是**上下**结构（不是左右分栏）
  ///   （手机上强行左右分栏会挤成两条缝，lead 早有要求"别为桌面搞坏手机"）。
  ///
  /// ★ 2026-09-30【task-92】Owner 要求**调换位置**（逐字）：
  ///   > 直播页面改为节目栏在下面,播放窗口挪到上面去,也就是调换一下位置
  ///   ⇒ 播放器挪到**上**、频道列表挪到**下**。
  ///   `lineSwitcher` 跟着播放器走（与宽屏 `Column(min, [player, lineSwitcher])`
  ///   同一约定：它是播放器的线路控件，不能与播放器分开）。
  Widget _buildNarrowBody(Widget list, Widget player, Widget lineSwitcher) {
    // ★ 内容带（t509）：原来这里是 `AppMetrics.contentPadding`（24）
    //   —— 已由页根的 `Layout.horizontalInsetOf` 提供，留着会变成 ×2。
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          // ★ 播放器在上（task-92 调换）：宽度 = 屏宽 − 两侧 contentPadding，
          //   高度由 AspectRatio 的 16:9 决定
          AspectRatio(aspectRatio: 16 / 9, child: player),
          lineSwitcher,
          const SizedBox(height: Sp.x5),
          // 列表在下，吃掉剩余高度 —— 自身可滚
          Expanded(child: list),
        ],
      ),
    );
  }

  /// 宽屏：播放器在**左** + 频道列表在**右**（固定宽 300），**两栏都在视口内不滚**
  ///
  /// ```text
  /// 用户原话："左侧固定,右侧就一个播放器也固定"
  ///   ★ 2026-09-30【task-92】Owner 又要求**调换左右**（逐字）：
  ///     > 窄屏幕修改就行了,宽屏改为  播放器在左侧,列表在右侧
  ///     ⇒ 播放器在**左**、频道列表在**右**（列表仍固定宽 300）。
  ///   · 播放器那栏：`Expanded` 给它**满宽**、内层 `Center` 吃满高度 ⇒ 固定
  ///   · 列表那栏：`SizedBox(width: 300)`，高度由父级满高约束给出 ⇒ 固定
  ///     （列表**自己内部**滚 —— 那是列表该有的行为，不是"整页滚"）
  /// ✔ 原来用 `LayoutBuilder` 手算 `listH`（视口高 − 页头 − 底栏 − 72）
  ///   ★ 现在改用 `Expanded`（父级已经是满高的 Column）⇒ **不再估算**，
  ///     少一处"估算高度"就少一处随字体/字号漂移的风险。
  /// ```
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-09-26【#5】右栏高度**必须与左栏对齐**（用户第 5 条）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// 用户原话：
  /// ```text
  /// > 直播页面,右侧的直播播放器高度没有跟左边对齐高度
  /// ```
  ///
  /// # 修前的实测读数（1280x800 宽屏，探针真机跑的，不是我估算）
  /// ```text
  /// 左栏（频道列表）    : 300.0 x **728.0**
  /// 右栏（播放器 16:9） : 912.0 x **513.0**
  /// ⇒ 高度差 = **215.0 px**（左栏比右栏高 41.9%）
  /// ```
  /// ⇒ 用户看到的正是"右边播放器比左边列表**矮一截**，底下空一块"。
  ///
  /// # 为什么会差（结构原因，不是算错了）
  /// ```text
  /// 左栏 `_ChannelList` 的根是 `Column(mainAxisSize: max)` + `Expanded(ListView)`
  ///   ⇒ 它**吃满**父级给的高度 ⇒ 728
  /// 右栏是 `AspectRatio(16/9)` —— 它的高度由**宽度**决定：
  ///   912 ÷ 16 × 9 = **513**（与宽度绑死，与可用高度无关）
  /// ⇒ ★ 两者**必然**不等：一个跟高度走，一个跟宽度走。
  /// ```
  ///
  /// # 修法：保留 16:9，让**右栏容器**吃满高度（多出来的空间做黑边）
  /// ```text
  /// 候选 A：把右栏拉满高度 ⇒ 视频就**变形**了（912x728 = 1.25:1，不是 16:9）
  /// 候选 B：把左栏砍到 513 ⇒ 列表白白少 215px（用户要的是"左侧固定"）
  /// 候选 C（采用）：右栏容器吃满 728，视频**按 16:9 居中** ⇒
  ///         上下各留 ~107px 黑边（letterbox，与播放器内部黑边同色）
  ///         ⇒ ★ 两栏的**上下边界完全对齐**，而画面比例一个像素都没变
  /// ```
  /// ★ 为什么不去挤左栏（候选 B 看起来"更简单"）：
  ///   用户上一条刚说过「左侧固定,右侧就一个播放器也固定」——
  ///   把列表砍矮正好是**反着做**，而列表矮 215px 就要多滚 215px。
  ///
  /// ⚠️ 黑底 `ColoredBox` **不是装饰**：没有它，视频居中后上下露出的
  ///    是**页面背景**（浅色主题下是灰白），看起来像"播放器缺了一块"。
  ///    有了它，整块右栏读起来是**一个播放器面板**（与 `ClipRRect`
  ///    同一个圆角 ⇒ 与 `LiveEmbeddedPlayer` 自己的圆角完全重合，不打架）。
  ///
  /// ⚠️ 窄屏分支（`_buildNarrowBody`）**不需要**这套机制 —— 那里是上下结构，
  ///    播放器宽度就是屏幕宽，`AspectRatio` 满宽铺开本来就没有"对齐"问题。
  ///    （2026-09-30【task-92】窄屏只调换了播放器/列表的上下顺序，机制不变。）
  Widget _buildWideBody(Widget list, Widget player, Widget lineSwitcher) {
    // ★ 内容带（t509）：同 `_buildNarrowBody` —— 那一层已由页根提供。
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          /*
           * ★ 左栏（task-92 调换后 = 原来的右栏）：**吃满高度**（与右栏等高）
           *   + 视频按 16:9 居中
           *
           * `Expanded` 在这里是给**宽度**用的（Row 的主轴）；让它**满高**的是
           * 里面那层 `Center`（在高度有界且未设 heightFactor 时会吃满 maxHeight）
           * ⇒ 见下面 `Center` 的说明。
           */
          Expanded(
            child: ClipRRect(
              borderRadius: Radii.rLg,
              child: ColoredBox(
                // ★ 黑边颜色与播放器内部黑边一致 ⇒ 两者的接缝看不出来
                color: Colors.black,
                child: Center(
                  /*
                   * ★ `Center` + `AspectRatio` = "能多大就多大，但保持比例"
                   *
                   * `AspectRatio` 在**宽松**约束下的行为（读 Flutter 实现）：
                   *   先试满宽 → 高 = 宽/16*9 ≤ 可用高 ⇒ 取该宽x该高
                   *   （若可用高更小，它会反过来按高算宽 ⇒ **永不溢出**）
                   * ⇒ 这正是 letterbox 语义，且**不需要**我们手算任何数字。
                   */
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AspectRatio(aspectRatio: 16 / 9, child: player),
                      lineSwitcher,
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: Sp.x5),
          // ★ 右栏（task-92 调换后 = 原来的左栏）：固定宽 + 满高（内部自滚）
          SizedBox(width: 300, child: list),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  频道列表
// ═══════════════════════════════════════════════════════════════════════

/// ★★★ task-42：平铺列表的一项（频道 + 它的来源 tag）
///
/// # 为什么用 record 而不是给 `LiveChannel` 加字段
/// ```text
/// `LiveChannel` 在 `lib/core/models.dart` —— 那个文件**归别的任务**
/// （task-42 写入范围明确排除它）。
/// ★ 而且"来自哪个源"是**列表展示需要的信息**，不是频道的固有属性
///   （同一个频道理论上可能被多个源提供）。
/// ⇒ 用轻量 record 在**渲染层**组合，不改数据模型。
/// ```
typedef _FlatEntry = ({LiveChannel channel, String tag});

class _ChannelList extends StatelessWidget {
  const _ChannelList({
    required this.providers,
    required this.enabledProviders,
    required this.channels,
    required this.selectedId,
    required this.onPickChannel,
  });

  /// 有可播视频的源（②：整组不可用的源不出现）
  final List<LiveGroup> providers;

  /// 当前**启用**的源 id 集合（③：单独启停）
  ///
  /// ★ task-53【②】：启停**已挪到设置页** ⇒ 这里只用于**标签的视觉区分**
  ///   （启用的源用主色、关闭的用弱化色），**不再**有可点的开关。
  final Set<String> enabledProviders;

  /// ★ 平铺的频道（跨源混合，每项带来源 tag）
  final List<_FlatEntry> channels;

  final String? selectedId;

  final ValueChanged<LiveChannel> onPickChannel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: Radii.rLg,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        children: [
          /*
           * ════════════════════════════════════════════════════════════
           * ★★★ task-53【②】源标签条：**从"开关"改回"只读展示"**
           * ════════════════════════════════════════════════════════════
           *
           * 用户原话（第 4 条）：
           * ```text
           * > 直播 配置源的开启**不是**上面出现 tag 点击开关的,
           * > 是有个配置的地方,可以配置 **放在设置页面吧**
           * ```
           *
           * # 变更历史（为什么这里改过三次）
           * ```text
           * task-39：chip = **筛选**（一次只看一个源）
           * task-42：用户要"平铺" ⇒ 筛选没意义 ⇒ chip 改成**开关**
           *          （用户当时说"直播源要支持单独的开启与关闭"）
           * task-53：★ 用户**否定了开关长在这里** ——
           *          "配置"该在**设置页**，不该长在**内容页**
           * ```
           *
           * ★★ 关键：用户否定的是**位置**，不是**能力**
           * ```text
           * · 能力（单独启停某个直播源）⇒ ★ **保留**，已挪到设置页
           *   （`settings_page.dart` 的 JS 插件列表，走**同一个**
           *    `setProviderEnabled` ⇒ 两处天然一致）
           * · 位置 ⇒ ★ 本页不再提供"点击开关"
           * ```
           *
           * ⚠️ 但**不能整行删掉** —— 用户仍需知道"这些频道来自哪些源"
           *   （task-42 用户原话："以分组加 tag 作为标记"）。
           *   ⇒ 所以保留**只读**的源名，去掉可点性。
           *   ★ 若整行删除，用户就失去了"我在看哪些源"的信息。
           */
          if (providers.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView.separated(
                clipBehavior: Clip.antiAlias,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: Sp.x3,
                  vertical: Sp.x2,
                ),
                itemCount: providers.length,
                separatorBuilder: (_, __) => const SizedBox(width: Sp.x2),
                itemBuilder: (context, i) {
                  final g = providers[i];
                  final on = enabledProviders.contains(g.provider);
                  /*
                   * ★ 只读标签：**没有 InkWell / onTap** ——
                   *   启停请去 设置 → JS 插件（2026-09-28 起直播源已并入）。
                   *   ⚠️ 保留 `on` 的视觉区分：关掉的源仍可能在列表里
                   *     短暂出现（启停是异步的），用弱化色表达。
                   */
                  return Center(
                    child: Tooltip(
                      // ★ 提示里**指明去哪配置** —— 否则用户会在这里反复点
                      message: '${g.providerName}（在 设置 → JS 插件 里配置）',
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Sp.x3,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: on
                              ? colors.primary.withValues(alpha: 0.16)
                              : null,
                          borderRadius: Radii.rFull,
                          border: Border.all(
                            color: on
                                ? colors.primary
                                : colors.outlineVariant,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              on
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 13,
                              color: on
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              g.providerName,
                              style: TextStyle(
                                fontSize: FontSizes.cap,
                                color: on
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

          // ── 频道（★ task-42：**平铺**，不再分组）──
          Expanded(
            child: ListView(
              clipBehavior: Clip.antiAlias,
              padding: const EdgeInsets.all(Sp.x3),
              children: [
                for (final entry in channels)
                  _ChannelTile(
                    channel: entry.channel,
                    // ★ tag = 它来自哪个源（用户说"以分组加 tag 作为标记"）
                    tag: entry.tag,
                    active: entry.channel.id == selectedId,
                    onTap: () => onPickChannel(entry.channel),
                  ),
                /*
                 * ★ 全被剔除时的空态 —— 不能只留一片空白
                 *
                 * 否则用户看到"列表是空的"，第一反应是"源坏了"。
                 */
                if (channels.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Sp.x5),
                    child: Text(
                      '这些直播源的频道都没有可播放的画面'
                      '（视频线路受内容方保护）。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 线路选择小胶囊（高清 / 标清 / 备用…）
///
/// ★ 只在**多于一条可播线路**时出现（见 `lineSwitcher` 的构造处）
class _LineChip extends StatelessWidget {
  const _LineChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: Radii.rFull,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 4),
        decoration: BoxDecoration(
          color: active ? colors.primary.withValues(alpha: 0.16) : null,
          borderRadius: Radii.rFull,
          border: Border.all(
            color: active ? colors.primary : colors.outlineVariant,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: active ? colors.primary : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 频道行（task-42：平铺 + 行尾来源 tag）
class _ChannelTile extends StatefulWidget {
  const _ChannelTile({
    required this.channel,
    required this.active,
    required this.onTap,
    this.tag,
  });

  final LiveChannel channel;
  final bool active;
  final VoidCallback onTap;

  /// ★★ task-42：来源 tag（用户要求"以分组加 tag 作为标记"）
  ///
  /// 显示在行尾，表明这个频道来自哪个源（如「央视网」/「IPTV 直播」）。
  final String? tag;

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
  /// ★★★ task-82【Q3】本行的焦点节点 —— **由本类显式持有**
  ///
  /// # 为什么必须自己持有（不能让 `InkWell` 内部造）
  /// ```text
  /// 不给 `InkWell` 传 `focusNode:` 时，节点由它内部创建，
  /// 外部**拿不到句柄** ⇒ 想实现"焦点环落在正在播放的那一行"就无从下手。
  /// ★ 本项目已有同一范式：`episode_strip.dart:521-525` 逐字记着
  ///   「`Focus` 的自动聚焦在 `skipTraversal`/重建时不可靠 ⇒
  ///    必须显式 `requestFocus()`」，那里也是**自己持有 node**。
  /// ```
  late final FocusNode _node = FocusNode(
    debugLabel: 'chan-${widget.channel.id}',
  );

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ChannelTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    /*
     * ★★ 变成"选中"时**把自己滚进可视区**（task-39）
     *
     * # 为什么必须（用户会以为按键没反应）
     * ```text
     * 列表可能比容器高（iptv 有 28 个频道）。
     * 用户按 ↓ 切到第 20 个台时，它在**屏幕外** ——
     * 高亮跑了但看不见 ⇒ 体验上就是"按了没反应"。
     * ```
     *
     * # ★ 为什么用**自己的** ensureVisible 而不靠 spatial_nav
     * ```text
     * task-3 要给 `spatial_nav._scrollIntoView` 加"输入来源门控"
     * （只让键盘/遥控滚，不让鼠标滚轮滚）。
     * ⇒ 本页**不依赖**那条路径 ⇒ task-3 改动本页不受影响。
     * ★ 也正因如此，我在 `spatial_nav.dart` 里写明了
     *   "遥控/键盘导航必须保留滚动"这条约束（见那里的长注释）。
     * ```
     *
     * ⚠️ 用 `addPostFrameCallback` —— 刚 setState 完还没布局，
     *    立刻 ensureVisible 会拿到旧位置。
     */
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = context;
        if (!ctx.mounted) return;
        /*
         * ★★★ task-82【Q3】把**焦点环搬到本行** —— 让焦点跟着选中走
         *
         * # 为什么只能这么做（不能去拦 shell）
         * ```text
         * SDK `focus_manager.dart:2249-2254`：early handler **全部**依次执行，
         *   某条返回 handled **不会**中断这个循环；`:2271-2273` 之后才决定
         *   是否跳过焦点树。
         * ⇒ 一次 ↓ 有**两个** early handler 都在跑：
         *     · 本页 `:316` `_onHardwareKey` ⇒ `cycleChannel(1)`（选中 +1）
         *     · `shell.dart:2162` `_onGlobalKey` ⇒ `moveFocus(↓)`（焦点 +1）
         * ★ 而 shell 的 `moveFocus` 在本文件里**拦不住**（`lib/shell.dart`
         *   不在本任务写入范围）。⇒ 唯一可行的修法是：
         *   **让焦点环跟着选中走** —— 选中哪一行，焦点就落到哪一行。
         * ```
         *
         * # 为什么必须在这个 post-frame 回调里（顺序是判据的一部分）
         * ```text
         * 两个 early handler 都在**按键事件里**同步跑完，shell 的
         *   `moveFocus` 是**后**一个 `requestFocus()`；而 `requestFocus()`
         *   是**微任务**生效（SDK `focus_manager.dart:1936 _markNeedsUpdate`
         *   → `scheduleMicrotask(_applyFocusChange)`）。
         * 本回调在**帧末**执行 ⇒ 我们是最后一个动焦点的 ⇒ 必然覆盖它。
         * （与 `_pageFocus` 注释里那条"顺序很重要"同一手法。）
         * ```
         *
         * # ⚠️ 已知边界（如实记录，不假装已覆盖）
         * ```text
         * `ListView(children:)` 的 Element **惰性挂载** —— 实测 TV 上 56 个
         *   频道只有 **6–7 行**在树里（`sliver_multi_box_adaptor.dart:418-421`
         *   的 `visitChildrenForSemantics` 只访问已布局的子节点）。
         * ⇒ 选中的行若落在**挂载窗口之外**，它没有 State ⇒ 本回调根本不会
         *   跑 ⇒ 那一格的焦点仍留在 shell 选中的行上。
         * ★ 这一段**没有**修好，已写进交付说明的"未证/未覆盖"一节。
         * ```
         */
        if (_node.canRequestFocus) _node.requestFocus();
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final channel = widget.channel;
    final active = widget.active;

    return InkWell(
      onTap: widget.onTap,
      /*
       * ★★★ task-82【Q3】把**本行自己的** node 交给 `InkWell`
       *
       * 不传时节点由 `InkWell` 内部创建，外部拿不到句柄 ⇒
       * 上面 `didUpdateWidget` 里的 `_node.requestFocus()` 就**永远
       * 打在一个不在焦点树里的节点上**（等于没写）。
       * ★ 这一行是"焦点跟随选中"能成立的**前提**。
       */
      focusNode: _node,
      borderRadius: Radii.rSm,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x2,
          vertical: Sp.x2,
        ),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: active ? colors.primary.withValues(alpha: 0.14) : null,
          borderRadius: Radii.rSm,
        ),
        child: Row(
          children: [
            // ── logo（无图时显示前 4 个字）──
            SizedBox(
              width: 34,
              height: 34,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: channel.logo != null && channel.logo!.isNotEmpty
                    ? coverImage(
                        context,
                        url: channel.logo!,
                        // 上面的 `SizedBox` 就是 34×34，硬编码且无 LayoutBuilder
                        layoutWidth: 34,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => _logoText(colors),
                      )
                    : _logoText(colors),
              ),
            ),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Text(
                channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? colors.primary : colors.onSurface,
                ),
              ),
            ),
            /*
             * ★★★ task-42：来源 tag（用户要求"以分组加 tag 作为标记"）
             *
             * # 用户原话
             * ```text
             * 直播页面,左侧不再分组,直接平铺下去 …
             * 平铺下去 以分组加 tag 作为标记
             * ```
             * ⇒ 去掉分组标题行，改成**每行行尾**一个来源标签。
             *
             * # ⚠️ 我第一版**加了字段却忘了渲染**（真 bug，差点交付）
             * ```text
             * 我在 `_ChannelTile` 上加了 `final String? tag`，
             * 构造处也传了 `tag: entry.tag`，
             * ★ 但 build() 里**从来没有用它** —— analyze 也不报错
             *   （写进字段但没读，Dart 不警告 —— 它是 public final）。
             * ⇒ 截图验收时才看出来：列表里**没有 tag**。
             * ⇒ 教训：**"传了参数"≠"画出来了"** —— 必须看渲染结果。
             * ```
             */
            if (widget.tag != null && widget.tag!.isNotEmpty) ...[
              const SizedBox(width: Sp.x2),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest.withValues(alpha: 0.8),
                  borderRadius: Radii.rSm,
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Text(
                  widget.tag!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _logoText(ColorScheme colors) {
    // 原版：`ch.name.slice(0, 4)`
    // ⚠️ 用 `widget.channel`（本类是 StatefulWidget，字段在 widget 上）
    final n = widget.channel.name;
    final t = n.length > 4 ? n.substring(0, 4) : n;
    return ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Text(
          t,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}


// ═══════════════════════════════════════════════════════════════════════
//  页头 / 骨架
// ═══════════════════════════════════════════════════════════════════════

/// 页头 —— 原版 `.page-head`（`LiveView.vue:154-160`）
///
/// ```html
/// <h1 class="page-title">直播</h1>
/// <p class="page-sub t-secondary">
///   {{ currentChannels.length }} 个频道
///   <template v-if="epg.length">· 支持节目单与回看</template>
/// </p>
/// ```
///
/// ⚠️ 抽成控件是为了**加载骨架能复用同一份页头** ——
///    原版加载态下页头也照样渲染（`v-if="loading"` 只包住 `.live-layout`，
///    页头在它外面）。加载时频道数还不知道，原版会显示「0 个频道」，
///    这里保持一致（不额外做"隐藏页头"那种原版没有的分支）。
class _PageHead extends StatelessWidget {
  const _PageHead({
    required this.channelCount,
    required this.showEpgHint,
    this.onShowAll,
  });

  final int channelCount;
  final bool showEpgHint;

  /// ★★ 2026-09-26【C】"所有直播"入口（用户要求"点击出来所有的直播"）
  ///
  /// null = 不显示按钮（加载骨架里传 null —— 那时还没有频道可选）。
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // ★ 内容带（t509）：`_PageHead` 的两个用点（骨架 `:1594` 与主路径 `:1913`）
    //   都直接挂在**已经有内容带**的滚动体上 ⇒ 这里归零，否则变成 ×2。
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '直播',
                  style: TextStyle(
                    fontSize: FontSizes.xl,
                    fontWeight: FontWeights.semibold,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: Sp.x1),
                Text(
                  '$channelCount 个频道${showEpgHint ? " · 支持节目单与回看" : ""}',
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          /*
           * ★★【C】"所有直播"按钮 —— 用户原话：
           *   「直播页面可以看所有的直播,就跟选集逻辑一样,点击出来所有的直播」
           * ⇒ 放在页头右侧（与"选集"在播放页的位置语义一致：一个入口，
           *   点开就是全部列表）。
           *
           * ⚠️ 本页**不 import forui**（`FButton` 来自 forui）——
           *   本页既有控件（`_LineChip` / 源启停 chip）全是**自绘 InkWell**
           *   ⇒ ★ 沿用本页既有风格，不引入第二个控件体系
           *     （与"两套 Theme 串台"是同一类风险：多一个来源就多一处不一致）。
           */
          if (onShowAll != null)
            Tooltip(
              message: '看所有直播频道',
              child: InkWell(
                onTap: onShowAll,
                borderRadius: Radii.rFull,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Sp.x3,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: Radii.rFull,
                    border: Border.all(color: colors.outlineVariant),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.list_alt,
                        size: 16,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '所有直播',
                        style: TextStyle(
                          fontSize: FontSizes.sm,
                          color: colors.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 面板骨架 —— 原版 `.skeleton`（`LiveView.vue:163-164`，两块 400px 高的）
///
/// 原版骨架是**整块**灰底（不是"一行行假卡片"）—— 这里保持一致：
/// 假卡片会让用户以为内容已经加载出来了，只是在等图。
class _PanelSkeleton extends StatelessWidget {
  const _PanelSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.onSurface.withValues(alpha: 0.05),
        borderRadius: Radii.rLg,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.desc,
  });

  final IconData icon;
  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 56,
              color: colors.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: Sp.x4),
            Text(
              title,
              style: TextStyle(
                fontSize: FontSizes.base,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: Sp.x2),
            Text(
              desc,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: FontSizes.sm,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
