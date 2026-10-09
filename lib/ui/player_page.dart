// ═══════════════════════════════════════════════════════════════════════
//  播放器 —— 对齐原版 PlayerView.vue（4775 行）的**操作逻辑**
// ═══════════════════════════════════════════════════════════════════════
//
// # 技术栈替换
//
// ```text
// 原版：ArtPlayer + hls.js（WebView2 里的 <video>）
// 本版：media_kit（libmpv）—— 原生解码，支持 HEVC 硬解
// ```
// **操作逻辑、快捷键、提示文案全部照抄原版**，只换底层播放器。
//
// # ★★ 快捷键表（原版 `design/device.ts` 的 DESKTOP_HINTS）
//
// ```text
// 空格     播放 / 暂停
// ← →      快退 / 快进 5 秒
// J L      ±10 秒 · 双击左右侧同效
// 0–9      跳转到百分比
// ↑ ↓      音量 · M 静音 · 滚轮同效
// F        全屏 · P 画中画
// , .      减速 / 加速
// N        下一集
// ```
// ⚠️ 这份表**同时用于**实际按键处理与「快捷键提示」浮层 ——
//    两处必须是同一份数据，否则会出现"提示里有的键按了没反应"。
//
// # ★ TV 是**另一套**键位（不是照搬键盘）
//
// ```text
// 确认     播放 / 暂停
// ← →      快退 / 快进 10 秒      ← 注意是 10 秒，桌面是 5 秒
// ↑ ↓      音量
// 返回     退出播放 / 返回上一页
// ```
// 原版注释：
// > 遥控器只有方向键 + 确认 + 返回，没有 J/L/数字/F 这些键。
// > 所以文案必须重写，不能照搬。
//
// # ★ 直播要**过滤掉**这些提示
//
// ```text
// 快退 / 百分比 / 减速
// ```
// 原版注释：
// > 直播不能快进/跳转 —— 列出来只会让人白试。
//
// # ★★ 记忆播放位置（原版实测踩过的坑）
//
// ```text
// ① 每 5 秒落一次盘（不是每帧 —— 那会写爆 SQLite）
// ② 退出/切集/换源前**立刻**落一次（`reportProgress(immediate: true)`）
// ③ 时长用**真实时长**（applyRealDuration），不是元数据里的
// ```
// 原版注释：
// > 元数据的 duration 常常不准（尤其 HLS），
// > 用它算百分比会让"续播位置"偏到离谱的地方。

import 'dart:async';
import 'dart:io';
// ★★★ task-22 P1-11：`videoZoomToMpv()` 要把百分比换成 mpv 的 `video-zoom`
//   （log2），为此只需要 `log` —— `dart:math` 不进面板，只在本文件用。
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
/*
 * ★★ task-53【#4b-④】滚轮调音量需要这三个：
 *   `PointerSignalEvent` / `PointerScrollEvent` / `GestureBinding`
 *
 * ⚠️ 它们**不在** `material_ui` 的导出里（实测：加了本行才 analyze 通过）。
 *   `material_ui` 是项目对 Flutter 拆包后的封装，只导出它自己用到的部分；
 *   而指针信号（滚轮）属于手势层。
 * ★ 用 `show` 精确导入 —— 与文件里 `flutter/services.dart` 那行的风格一致，
 *   避免把整个 gestures 命名空间拉进来造成符号歧义（`material_ui` 里
 *   也有 `PointerEvent` 一类的名字）。
 */
import 'package:flutter/gestures.dart'
    show GestureBinding, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/services.dart';
/*
 * ★★★ task-25 C：`@visibleForTesting` 来自 foundation。
 *
 * ⚠️ 为什么**必须显式 import**：`material_ui.dart` 把 flutter 的 widgets
 *    原样再导出一遍，而那条链上的 foundation 出口是**收窄**的 ——
 *    实测 <FLUTTER_SDK>/packages/flutter/lib/widgets.dart:18
 *    逐字是 `export 'foundation.dart' show Brightness, UniqueKey;`
 *    ⇒ `visibleForTesting` **不在**其中，靠传递导出拿不到。
 * ★ 全仓先例：lib/core/clip_download.dart:63 就是直接 import
 *    `package:flutter/foundation.dart`（它的 :420 用了 @visibleForTesting）。
 */
import 'package:flutter/foundation.dart';
/*
 * ★ ①-B 需要 `FTheme`（把播放页里的浮层面板包成深色皮肤）
 *
 * ⚠️ 这里 import forui 是**必要**的：项目禁止的是
 *    `package:flutter/material.dart`（两套 Material 会串台），
 *    而 forui 本来就是项目的主题来源（`MaterialApp.builder` 里注入）。
 *    本文件只用到 `FTheme` 这一个 widget，不引入任何 Material 实现。
 */
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_log.dart';
import '../core/clip_download.dart';
import '../core/danmaku.dart';
import '../core/device.dart';
// ★ task-38：为了 `SourinCoreException.kind`（结构化错误类别）
//
// `sourin_api.dart` 里没有导出这个类型（它在 ffi.dart 定义），
// 而 `_isAuthError` 现在**优先**用结构化 kind 判"是不是登录问题"，
// 不再只靠 `toString()` 里找词。
// ★ task-31 ④⑤：B 站弹幕导入（④） + assrt 在线字幕（⑤）
import '../core/bili/bili_api.dart';
import '../core/bili/bili_auto_update.dart';
import '../core/bili/bili_bind.dart';
import '../core/ffi.dart';
import '../core/pip.dart';
import '../core/player_gestures.dart';
import '../core/sourin_api.dart';
import '../core/ui_prefs.dart';
import 'app_theme.dart';
import 'remote_bridge.dart';
import 'titlebar_visibility.dart';
import 'media_session.dart';
import 'cast/cast_button.dart';
import 'player/episode_panel.dart';
import 'player/player_bottom_bar.dart';
import 'player/player_more_menu.dart';
import 'player/player_popover.dart';
import 'subtitle/subtitle_panel.dart';
import 'tokens.dart';
import 'widgets/bili_import_dialog.dart';
import 'widgets/danmaku_overlay.dart';
import 'widgets/danmaku_settings_dialog.dart';
import 'widgets/episode_strip.dart';
import 'widgets/motion_prefs.dart';
import 'widgets/overlay_motion.dart';
import 'widgets/player_settings_sheet.dart';
import 'widgets/provider_login_panel.dart';
import 'widgets/provider_name.dart';
import 'widgets/skip_marker_dialog.dart';
import 'widgets/source_switch_dialog.dart';
import '../ui/app_scaffold.dart';
import '../ui/app_theme.dart';

/// 把播放页里的**浮层面板**包成深色皮肤（task-28 ①-B）
///
/// ══════════════════════════════════════════════════════════════════════
/// 用户原话
/// ══════════════════════════════════════════════════════════════════════
///
/// > 播放器页面**整体黑色**，弹窗**白色**，**不适配**
///
/// # 为什么"不适配"（根因）
///
/// 播放页是**纯黑**的（`Scaffold(backgroundColor: Colors.black)`），
/// 而浮层面板取色走的是 `FTheme.of(context)` —— 那是
/// **应用级主题**（用户可能选了浅色，或者系统是浅色）：
/// ```text
/// 全屏黑播放页  +  一块 #FAFAFA 的浅色面板
///               =  ★ 用户说的"不适配"
/// ```
/// 更糟的是**深色用户也会遇到**：面板跟着 `MaterialApp.theme` 走，
/// 而那由 `AppTheme.mode` 决定 —— 用户选「跟随系统」而系统是浅色时，
/// 播放页仍然是纯黑（**播放器就该是黑的**），面板却是白的。
///
/// # 为什么选"深色皮肤"而不是其它候选
///
/// ```text
/// 候选 A ★ 深色皮肤（本实现）
///    · 与播放页一致；不刺眼（全屏观影时突然一块白最刺眼）
///    · 零新依赖、零性能开销
///
/// 候选 B 毛玻璃（liquid_glass_widgets）
///    · 黑底上的毛玻璃**没有可折射的内容**（背后就是纯黑视频）
///      ⇒ 实测效果接近"半透明黑"，与 A 几乎一样却多一层开销
///      ⇒ 收益不抵复杂度，不做
///
/// 候选 C 保持浅色 + 加暗色遮罩
///    · 遮罩只能压暗**面板外**的区域，面板本身还是白的
///      ⇒ 没解决用户说的问题，只是把黑边压得更黑
/// ```
///
/// # ★ 为什么是"包一层 FTheme"而不是"改面板内部的取色"
///
/// ```text
/// ① 面板有三处（选集 / 线路 / 播放设置），改内部要动 3 个文件
///    且 `EpisodePanel` 还被**别的页面**复用（详情页也用）
///    —— 那些页面是浅色的，不能一起改黑
/// ② `FTheme` 是 `InheritedWidget`，**作用域天然是本子树**
///    ⇒ 只影响播放页里挂的这几个面板，别处一个像素都不变
/// ③ 面板内部的 `FTheme.of(context)` **一个字都不用改**
/// ```
///
/// ⚠️ 用 `AppTheme.themeFor(Brightness.dark)` 而不是硬编码色值 ——
///    与 `MaterialApp.theme` **同源**，将来调深色令牌时两处一起变。
class PlayerPanelTheme extends StatelessWidget {
  const PlayerPanelTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      AppThemeHost(data: AppTheme.themeFor(Brightness.dark), child: child);
}

/// 快捷键提示项（与 [kDesktopHints] / [kTvHints] 同源）
class HintItem {
  const HintItem({required this.keys, required this.text});

  final List<String> keys;
  final String text;
}

/// 桌面：键盘快捷键（**照抄原版 `DESKTOP_HINTS`**）
const kDesktopHints = <HintItem>[
  HintItem(keys: ['空格'], text: '播放 / 暂停'),
  HintItem(keys: ['←', '→'], text: '快退 / 快进 5 秒'),
  HintItem(keys: ['J', 'L'], text: '±10 秒 · 双击左右侧同效'),
  HintItem(keys: ['0', '–', '9'], text: '跳转到百分比'),
  HintItem(keys: ['↑', '↓'], text: '音量 · M 静音 · 滚轮同效'),
  HintItem(keys: ['F'], text: '全屏 · P 画中画'),
  HintItem(keys: [',', '.'], text: '减速 / 加速'),
  HintItem(keys: ['N'], text: '下一集'),
  HintItem(keys: ['S'], text: '截图'),
];

/// TV：遥控器键位（**照抄原版 `TV_HINTS`**）
const kTvHints = <HintItem>[
  HintItem(keys: ['确认'], text: '播放 / 暂停'),
  HintItem(keys: ['←', '→'], text: '快退 / 快进 10 秒'),
  HintItem(keys: ['↑', '↓'], text: '音量'),
  HintItem(keys: ['返回'], text: '退出播放 / 返回上一页'),
];

/// 直播时 ↑/↓ 的提示文案（★★ task-53【#4b】）
///
/// # 为什么必须改（原来是**假提示**，且是本次需求的核心）
///
/// 用户要「直播进入全屏…可以上下切换」⇒ 直播时 ↑/↓ 的语义**变了**，
/// 而提示浮层是**同一份数据**渲染的（见文件头：
/// 「这份表同时用于实际按键处理与快捷键提示 —— 两处必须是同一份数据，
///   否则会出现"提示里有的键按了没反应"」）。
/// ⇒ 只改按键不改文案 = 提示在骗人；只改文案不改按键 = 更糟。
///
/// ★ 按端分开：TV 遥控器**没有** M 键、也没有滚轮
///   ⇒ 给 TV 写「M 静音 · 滚轮音量」等于把键盘键位摆在遥控用户面前
///     （原版注释明确反对："对遥控用户毫无意义"）。
const kLiveArrowHintDesktop = '切换直播 · M 静音 · 滚轮音量';
const kLiveArrowHintTv = '切换直播';

/// 按当前端取提示条目
///
/// 手机端返回空数组 → 调用方直接不渲染
/// （原版注释：手机端**完全没有**，没键盘，列出来纯占空间）。
List<HintItem> hintsFor({
  required bool isTv,
  required bool isTouchOnly,
  required bool isLive,
}) {
  final src = isTv ? kTvHints : (isTouchOnly ? <HintItem>[] : kDesktopHints);
  if (!isLive) return src;
  /*
   * 直播不能快进/跳转 —— 列出来只会让人白试
   * （进度条本身也是禁用的）。
   *
   * ★★ task-53【#4b】：其中 ↑/↓ 那一条**不是删掉，是换语义** ——
   *   直播时 ↑/↓ 切频道（见 `_onKey` 的 arrowUp/arrowDown 分支），
   *   所以文案要跟着换，且按端分开（TV 没有 M / 滚轮）。
   *   ⚠️ 判据用 `contains('音量')` 而不是 `keys.contains('↑')`：
   *      前者绑的是**能力描述**（这条讲的是音量），后者绑的是键位 ——
   *      哪天 ↑/↓ 挪到别的条目上，绑键位的写法会**改错条目**。
   */
  return src
      .where(
        (h) =>
            !h.text.contains('快退') &&
            !h.text.contains('百分比') &&
            !h.text.contains('减速'),
      )
      .map(
        (h) => h.text.contains('音量')
            ? HintItem(
                keys: h.keys,
                text: isTv ? kLiveArrowHintTv : kLiveArrowHintDesktop,
              )
            : h,
      )
      .toList();
}

/// 选一个「打开片段缓存目录」的平台策略（★ task-25 C）
///
/// 返回值（`test/t68_android_adapt_test.dart` 逐字断言这四个）：
///
///     'explorer'   Windows：资源管理器
///     'open'       macOS：open
///     'xdg-open'   Linux：xdg-open
///     'copy-path'  其它（Android / iOS / Fuchsia …）：没有文件管理器入口
///
/// # 为什么抽成顶层函数（而不是留在 _openClipDir 里）
///
/// `Platform.isWindows` / `isMacOS` / `isLinux` 是 const 静态 getter，
/// 在 flutter_tester 里恒等于**宿主**平台（Windows）⇒ 安卓那一支永远
/// 进不去，单测里根本走不到「不支持」的 else 分支，也就钉不住它的行为。
/// 抽成三个 bool 入参的纯函数之后，四种组合都能直接测。
///
/// ⚠️ 桌面三分支**必须保留**：Windows 交付链正在用
///    （`.probe/t24/AUDIT.md` 台账第 32 行记录的就是这一处）。
@visibleForTesting
String clipDirOpenStrategy({
  required bool isWindows,
  required bool isMacOS,
  required bool isLinux,
}) {
  if (isWindows) return 'explorer';
  if (isMacOS) return 'open';
  if (isLinux) return 'xdg-open';
  return 'copy-path';
}

/// ★★★ task-22 P1-11：百分比 → mpv `video-zoom` 的换算（纯函数）
///
/// # mpv 的 `video-zoom` 是 **log2 缩放系数**
///
/// ```text
/// video-zoom =  1  → 放大到 2 倍（200%）
/// video-zoom =  0  → 原始比例（100%）
/// video-zoom = -1  → 缩小到 1/2（50%）
/// ```
///
/// 用户看到的（面板档位 / 底栏滑条）是**百分比** ⇒ `zoom = log2(pct/100)`。
///
/// # 为什么抽成顶层纯函数
///
/// 与 [clipDirOpenStrategy] 同一条理由：真机上拖滑条读 `video-zoom` 属于
/// 取证（要真播放器），而这条换算是纯数学 —— 抽出来之后单测能直接钉住
/// 50/100/200 三个边界，不必挂真播放器。
@visibleForTesting
double videoZoomToMpv(double pct) => math.log(pct / 100) / math.ln2;

/// 播放页
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.provider,
    required this.id,
    required this.title,
    this.cover,
    this.episodeId,
    this.episodeTitle,
    this.sourceCode,
    this.episodes = const [],
    this.episodeIndex,
    this.liveChannelId,
    this.onLiveChannelStep,
    this.onLiveChannels,
    this.onLiveChannelPick,
    this.isTv = false,
    this.isTouchOnly = false,
    /*
   * ★★★ task-2【④】右侧详情栏此刻是否**真的可见**（用户第 15 条）。
   *
   * 错在哪：底栏那枚「选集」按钮曾经只由「有没有剧集」把门 ⇒ 非全屏但**右侧详情栏
   * 已经摆在旁边**时，详情栏里本来就有「选集」标题 + 剧集网格（detail_page.dart:2266
   * 的 _bodyEpisodes），再在底栏放一枚就是**重复入口白占位**。用户原话：
   * 「在非全屏状态下,选集的按钮不应该出现占位置」。
   *
   * 为什么用这个判据、且由宿主传：判据 = 「右侧详情栏可见」，它只有 media_page.dart
   * 知道（Row 是它拼的：media_page.dart:1005 的 (fullscreen || wide) ? Row(...) : Column(...)，
   * 再叠加 :1015 的 if (!fullscreen) SizedBox(width: detailW, child: detailPanel)）
   * ⇒ 右侧详情栏可见 ⇔ !fullscreen && wide(>=900)。播放页自己**抄不出**这个条件：
   * 它拿不到 narrow 分支里「详情区被挪到播放器下方」这件事，也不知道 fullscreen 的权威值。
   * 所以判据由宿主算好、以布尔传进来（单一数据源，见 media_page.dart:729）。
   *
   * ★ 默认值**必须** false：默认 false = hasEpisodes 不受影响 = 底栏照旧显示选集按钮。
   *   若默认成 true，所有没显式传参的路径（尤其是从历史记录 push 进播放页，
   *   shell.dart:4524 那条）会**静默少掉唯一的切集入口**。
   *
   * ★ 禁止改写成「非全屏就一律隐藏」：窄屏（Column 分支）时右侧**没有**详情栏，
   *   详情区在播放器下方、不构成重复入口，此时必须**仍然显示**选集按钮。
   */
    this.hasRightDetailBar = false,
    /*
     * ★★★ task-12 ④（2026-10-09）：本地文件路径（绝对路径）。
     *
     * null = 走原来的网络解析 —— **逐字节不变**（所有既有构造点都不用改）。
     * 非 null = `initState` 短路成 `file://` 起播，**完全不调 `_load()`**。
     *
     * # 为什么需要它（实测根因）
     * ```text
     * `_load()`（:2921）是唯一生产起播入口，且**无条件**走
     *   `SourinApi.resolveStream` -> Rust `playback.rs:160-164 registry.route()`
     * 而本地文件没有 provider 可路由 => 必然报「无法路由」=> 本地文件永远播不了。
     * ```
     *
     * # 为什么不加在 `_load()` 里（lead 裁决「路 A」）
     * ```text
     * `_load()` 里 `final List<StreamCandidate> list;` 是**确定赋值**结构，
     * 在里面插第三支 = 改那个 if/else 的**形状**（那是我刚收完 task-8 的地方）。
     * 在 `initState` 短路 => `_load()` 的字节一行不动 => 零冲突、零回归风险。
     * ```
     *
     * ⚠️ 值的来源：`shell.dart:4773` 已经判完「有旁文件走在线 / 没旁文件走本地」
     *    再经 `media_page.dart:874` 逐字转发上来。本页**不再重判**。
     */
    this.localPath,
  });

  final String provider;
  final String id;
  final String title;
  final String? cover;
  final String? episodeId;
  final String? episodeTitle;
  final String? sourceCode;
  final List<Episode> episodes;
  final int? episodeIndex;

  /// 非空 = 直播模式（禁进度条、过滤部分提示）
  final String? liveChannelId;

  /// ★★★ task-53【#4b】直播时 ↑/↓ 切频道（用户第 4 条，**第二次强调**）
  ///
  /// ```text
  /// 用户原话：
  /// > 直播进入全屏还是没办法像选集一样切换直播,而且我说的切换,是指的,
  /// > 直播进入全屏播放的状态下,然后可以上下切换,然后还可以切换直播
  /// > **不是指 在直播页面(未进入全屏)加一个所有直播的按钮进行切换的**
  /// ```
  ///
  /// # 语义（★ 逐字对齐 `live_page.dart::cycleChannel` 的方向）
  /// ```text
  /// ↑ ⇒ delta = -1（上一个台）
  /// ↓ ⇒ delta = +1（下一个台）
  /// ```
  /// ⚠️ 方向**必须**与 `live_page.dart:450-457` 一致 ——
  ///    同一件事在两页里方向相反，是"按了往上却往下走"那种最难查的 bug。
  ///
  /// # 为什么是**回调**而不是在这里自己取频道列表
  /// ```text
  /// 候选方案：播放页自己调 `getLiveChannels()` + 探可用性 + 算相邻台。
  /// ★ 否掉它的理由（不是"麻烦"，是**正确性**）：
  ///   直播页的"可见频道"依赖 `LiveAvailabilityProbe` 的 TTL 缓存
  ///   （10 分钟）、`_disabledProviders`、以及探到的 audioOnly/unavailable
  ///   ⇒ 播放页自己算一遍 = **两套真相** ⇒ 必然出现
  ///     「全屏里按 ↓ 切到了一个直播页列表里根本没有的台」。
  /// ★ 而 `live_page.dart` **本来就已经实现了**这个能力
  ///   （`cycleChannel` + `_visibleChannels`），且是用户上一轮验收过的。
  /// ⇒ 复用它的实现，本页只负责"把 ↑/↓ 翻译成一个方向"。
  /// ```
  ///
  /// # ⚠️ 为什么**不**复用 shell 的 `_liveChannelStep`（ValueNotifier）
  /// ```text
  /// 那条通路是 task-39 给**遥控**用的（`liveChannelStep: (d) => _liveChannelStep.value = d`）。
  /// ★ 实测确认它对本需求**不可用** —— `ValueNotifier` 会**去重相等的值**：
  ///     flutter/src/foundation/change_notifier.dart:558
  ///         set value(T newValue) { if (_value == newValue) return; ... }
  ///   ⇒ 连按两次 ↓（delta 都是 +1）⇒ **第二次不通知**
  ///   ⇒ 用户连按两下只切一个台。
  ///   ★ `shell.dart:2438-2440` 的注释**正是**在记这个坑
  ///     （"第二次不通知 ⇒ 监听者必须收到就执行一次"）——
  ///     那是给遥控的"脉冲"约定，而这里是"每按一次都要切一个台"。
  /// ⇒ 所以走**直接回调**。
  /// ```
  ///
  /// # ★★★ 为什么回调**返回**新频道，而不是"让直播页自己切"
  /// ```text
  /// 候选（lead 原方案）：回调里调 `_liveKey.currentState?.cycleChannel(delta)`
  ///   ⇒ ★ 那样会把**隐藏的直播页**切掉 —— 而它有个内嵌播放器：
  ///     ① 全屏播放器**不会**跟着换台（它在播自己的流）⇒ 用户按了没反应
  ///     ② `cycleChannel` → `_select` → `_loadStream` ⇒ 内嵌播放器
  ///        `didUpdateWidget` 看到 url 变了 ⇒ `open()` + **`play()`**
  ///        ⇒ ★★ **两个 mpv 同时出声**（正是 `_watchLive` 拼命防的回声/重音）
  /// ⇒ 正确分工：
  ///     直播页只回答"**下一个台是哪个**"（它有探针缓存/启用态，是唯一真相）
  ///     本页负责"**我**去播那个台"（mpv 在本页）
  ///   而直播页在切台时**只改选中、不起播**（见 `_adoptForFullscreen`），
  ///   等 pop 回来再接手播放 ⇒ 任何时刻只有**一个**播放器出声。
  /// ```
  ///
  /// # 与其它键的关系（★ 不改动点播行为）
  /// ```text
  /// 直播 + 有本回调 ⇒ ↑/↓ 切台（不再调音量）
  /// 其余一切情况    ⇒ ↑/↓ 仍是音量（已验收，原样不动）
  /// ```
  /// ⚠️ 判据用**两个**（`_isLive && onLiveChannelStep != null`）：
  ///    回调可空 ⇒ 没接线的调用点（测试、回看、其它路由）**行为完全不变**。
  final ({String provider, LiveChannel channel})? Function(int delta)?
  onLiveChannelStep;

  /// ★★★ task-53【③】取**全部可见直播频道**（用户第 3 条）
  ///
  /// ```text
  /// 用户原话（逐字）：
  /// > 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
  /// ```
  /// ⇒ 要的是：**在直播播放页里，像"选集"那样打开一个列表看所有频道**。
  ///
  /// # 与 `onLiveChannelStep` 的分工（★ 两件事，别混）
  /// ```text
  /// onLiveChannelStep   = **上下键直接切台**（#4b，已验收）
  /// onLiveChannels      = **打开列表看全部**（#3，本条）
  /// onLiveChannelPick   = **点列表里某一项 ⇒ 切过去**
  /// ⇒ 用户两条都要：「能直接切」+「能打开列表看」。
  /// ```
  ///
  /// # ★ 为什么由直播页回答（唯一真相）
  /// ```text
  /// 与 `onLiveChannelStep` **同一条理由**：`_visibleChannels` 依赖
  /// `LiveAvailabilityProbe` 的 TTL 缓存 + `_disabledProviders` +
  /// audioOnly/unavailable 过滤 ⇒ 播放页自己查 = **两套真相**
  ///   ⇒ 面板里会列出"其实不能播"的台，或漏掉能播的台。
  /// ```
  ///
  /// ⚠️ 可空 ⇒ 没接线的调用点（测试/点播/回看）**行为完全不变**：
  ///    `_isLive && onLiveChannels != null` 才显示「所有直播」按钮。
  final ({List<LiveChannel> channels, int index})? Function()? onLiveChannels;

  /// ★★★ task-53【③】在"所有直播"面板里**点选了某个台** ⇒ 返回该台的信息
  ///
  /// 返回 `null` = 直播页不认这个台（不在它的可见列表里）。
  ///
  /// # ★ 为什么与 `onLiveChannelStep` **分开**两个回调
  /// ```text
  /// 候选：合并成一个 `onLiveChannelAction({int? delta, LiveChannel? pick})`。
  /// ★ 否掉：两个参数互斥却都出现在签名里 ⇒ 调用方可以传两个/都不传，
  ///   类型系统**管不到** ⇒ 又多一类"静默走错分支"的 bug。
  /// ⇒ 宁可两个各自单一职责的回调（与 `_prevEpisode`/`_nextEpisode` 同一风格）。
  /// ```
  final ({String provider, LiveChannel channel})? Function(LiveChannel channel)?
  onLiveChannelPick;

  final bool isTv;
  final bool isTouchOnly;

  /// ★★★ task-12 ④：本地文件**绝对路径**（见构造参数处的完整说明）。
  ///
  /// ⚠️ 与 `isTv` / `isTouchOnly` 一样是**可选**的 ——
  ///    不传即 null，所有既有构造点走的字节完全不变。
  final String? localPath;

  /// ★★★ task-2【④】右侧详情栏此刻是否真的可见 —— 由宿主（media_page.dart）算好传进来。
  ///
  /// 详细推导见构造参数处 this.hasRightDetailBar 的长注释。这里只钉三条：
  /// · 判据不许在播放页重算（它看不见 narrow 分支与 fullscreen 权威值）；
  /// · 默认 **false**（= 照旧显示选集按钮），改默认值等于静默砍掉切集入口；
  /// · 唯一的消费点在 _PlayerPageState.build 里
  ///   hasEpisodes: _episodes.length > 1 && !widget.hasRightDetailBar。
  final bool hasRightDetailBar;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

/// 当前进行中的长按类型（左半屏连续快退 / 右半屏倍速快进）
///
/// ⚠️ 必须是**顶层** enum —— Dart 不允许在类里声明 enum
///    （我第一版塞进了 State 类内部，编译报
///     `Enums can't be declared inside classes`）。
enum _LongPressKind { rewind, rateBoost }

/// 四个方向键 —— `_onKey` 里判断"要不要让给选集面板"用
///
/// ⚠️ **不能加 `const`**：`LogicalKeyboardKey` 重写了 `==`
///    （它按 keyId 比较，不是按标识），而 Dart 规定
///    「const Set 的元素不能重写 `==`」——
///    加了会直接编译报错 `const_set_element_type_mismatch` 那一类。
///    这里只是个查表用的集合，非 const 没有任何代价。
final _arrowKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
};

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin
    implements MediaSession {
  late final Player _player;
  late final VideoController _controller;

  /// 候选流（多清晰度/多线路）
  List<StreamCandidate> _streams = [];
  StreamCandidate? _current;

  bool _loading = true;
  String? _error;

  /// ★★ 失败错误的**结构化类别**（来自 `SourinCoreException.kind`，2026-09-25 task-38）
  ///
  /// # 为什么需要它（本轮发现的问题）
  ///
  /// `_error` 是**字符串** —— 而 `SourinCoreException` **本来就带 `kind`**
  /// （`lib/core/ffi.dart`：`network` / `unauthorized` / `not_found` /
  /// `unsupported` / `other`，由 `ffi.rs` 的 `err_json` 一路带过来）。
  ///
  /// 但这里 4 处赋值全写成 `_error = e.toString()` —— **`kind` 被字符串吞掉了**，
  /// 于是 `_isAuthError` 只能回头去 `contains('unauthorized')`
  /// （在 `toString()` 拼出来的 `SourinCoreException(unauthorized): …` 里找词）。
  ///
  /// ⚠️ 那种判据的脆弱之处：**插件换个措辞就静默失效**
  ///    （不是抛错、不是变红，而是"登录按钮不出现了"）。
  ///
  /// ⚠️ `null` 表示"这个错误没有结构化类别"（例如本页自己拼的中文串，
  ///    或 `media_kit` 的播放错误）→ 调用方**必须**回退到字符串判据。
  String? _errorKind;

  /// 直播只剩音频线路时的**非阻断提示**（不是错误）
  ///
  /// 用户报「cctv看得到但是点开黑屏」的根因：央视视频轨被 DRM 加密，
  /// 三条线路里只有「仅音频」能播 → 有声无画面。
  /// 原版会明确告知（`PlayerView.vue:4281-4299`），我们之前是静默开播。
  ///
  /// ⚠️ 为什么不用 `_error`：`_startPlayback()` 开头会把它清成 null
  ///    （`_error` 的语义是"起播失败"），所以这条提示必须是独立字段，
  ///    才能与"正在正常播放"并存。
  String? _liveAudioOnlyNotice;

  /// 「播放失败」的**非阻断**横幅文案（★ 2026-10-08，Owner 第 9 条）
  ///
  /// # 补的是什么
  ///
  /// Owner 第 9 条截图（u9_1c91d6a6.png）：
  /// ```text
  /// 播放失败
  /// Failed to open http://127.0.0.1:63534/s/18dc2c90fcf9b1f03f3446afdd80/.
  /// ```
  /// 这条 mpv 原文**只能在"从未出过画面"时**才配得上全屏 `_ErrorOverlay`。
  /// 一旦已经出过画面，再来的 `stream.error` 只是一次**可恢复的**抖动
  /// （换清晰度重开、缓冲重试、单帧解码报错都会发），
  /// 用全屏遮罩把正在看的画面盖掉 = 用户报的"看着看着突然播放失败"。
  ///
  /// ⇒ 判据是 [_sawFirstFrame]：出过画面 ⇒ 走这条**非阻断**横幅，
  ///   画面继续，用户能自己决定要不要换线路。
  ///
  /// ⚠️ 与 `_error` 分开的理由同 [_liveAudioOnlyNotice]：
  ///    `_error` 的语义是"起播失败"，它和"正在播放"是**互斥**的。
  String? _playbackFailure;

  /// 本次起播是否**已经确认出过画面**（`stream.width` 首次非空）
  ///
  /// # 为什么需要它（而不是"看 `_error` 是不是空"）
  ///
  /// `media_kit` 的 `stream.error` 只有**白名单前缀**才发
  /// （`media_kit-1.2.6/lib/src/player/native/player/real.dart:2085-2119`），
  /// 而且**同一个错误在整条生命周期里都可能来**：
  /// ```text
  /// 起播阶段：mpv 打不开 → 该给全屏错误（用户什么都没看到，必须解释）
  /// 播放中：  换流/重连/单帧解码失败 → 只该给一条横幅（画面还在）
  /// ```
  /// 两者用同一句 `_error = e` 处理，就是把"可恢复抖动"当成"致命失败"。
  ///
  /// ⚠️ 用 `stream.width`（`Stream<int?>`，见
  ///    `media_kit-1.2.6/lib/src/models/player_stream.dart:88`）
  ///    而不是 `player.state.width`：前者是**事件**，能区分
  ///    "这一刻有画面"和"刚才有画面"；后者只反映当前值。
  bool _sawFirstFrame = false;

  /// 「画面输出层没建起来」的**非阻断提示**（不是错误）
  ///
  /// # 补的是什么
  ///
  /// 交付说明 `README-交付说明.md:126-129` 自己承认过这个缺口：
  /// > 输出层建不起来时没有任何降级、也没有用户可见的报错，全程静默
  ///
  /// 具体场景：`mpv` 解析出了视频轨（demux 成功），但 `vo` 建不起来
  /// （典型是 `Could not create a GL context.` / `Failed initializing
  /// any suitable GPU context!`）。此时**画面永远是黑的、声音正常、
  /// 时间在走**，而客户端一句话都不说 —— 用户只会认为「客户端坏了」。
  ///
  /// ⚠️ 为什么 `_error` 收不到：`media_kit` 只把**白名单前缀**的日志
  ///    转成 `stream.error`（`media_kit-1.2.6/lib/src/player/native/player/real.dart:2085-2119`），
  ///    而 `vo/gpu` / `vo/gpu/opengl` **不在白名单里** ⇒ 这类失败
  ///    被库静默丢掉。所以必须自己探。
  ///
  /// # 判据（五臂实测得出，见 `.probe\t376_matrix.py`）
  ///
  /// ```text
  /// hasVideoTrack = player.state.videoParams.dw != null   ← Dart 侧
  /// voConfigured  = mpv 属性 'vo-configured' == 'yes'      ← mpv 侧
  /// 告警 = hasVideoTrack && !voConfigured
  /// ```
  ///
  /// ★ 为什么必须是这两个的**组合**：
  ///   * `vo-configured` 单独用 → 每个「合法无视频」的电台都会被判成故障
  ///     （纯音频臂上它是 `yes`，而 Android 失败臂上是 `no`，方向正好相反）。
  ///   * `videoParams.dw` 单独用 → 失败臂上它也是真（Dart 侧是
  ///     `mpv_observe_property` 事件推送的**残留**，不是「此刻有输出」的证据）。
  ///
  /// ⚠️ 不要用库自报的「首帧已渲染」当判据：`controller.rect > 1x1` 与
  ///    `waitUntilFirstFrameRendered` 在**失败臂上依然为真**（Android 的
  ///    `rect` 由 `VideoOutputManager.SetSurfaceSize` 回填，而该调用在
  ///    GL 上下文建不起来时仍然"成功"）。
  ///
  /// ⚠️ 与 `_error` 分开的理由同 `_liveAudioOnlyNotice`：`_startPlayback()`
  ///    开头会把 `_error` 清成 null，而这条提示的语义是
  ///    「起播**成功**了，但画面出不来」，必须与「正在播放」并存。
  bool _videoOutputDead = false;

  /// 画面输出层看门狗的代次号（每次起播自增，旧的那一轮自行放弃）
  int _videoOutputToken = 0;

  bool _buffering = false;

  /// 当前播放位置 / 时长（秒）
  Duration _position = Duration.zero;

  /// ★ 2026-10-09（Owner 第 10 条「很多地方卡卡的」）：播放位置的**局部**真源
  ///
  /// # 为什么要有它（改前的实测）
  /// ```text
  /// 改前：`_onPositionTick` 每跨一秒 `setState(() {})` **一次** ⇒
  ///   整棵 1.6 万行的播放页重建 —— 底栏那一小块时间变了，
  ///   却把弹幕层、顶栏、所有浮层都重排一遍。
  /// 改后：位置只写进这个 notifier，底栏用 `ValueListenableBuilder` 单独重建；
  ///   **整页不再因为时间前进而重建**。
  /// ```
  ///
  /// ⚠️ `_position` 字段**保留**（seek / 续播 / 快退 / 弹幕判定都读它，
  ///    且读的是**最新值**，语义不变）；这个 notifier 只承担"通知 UI 重画"。
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier<Duration>(
    Duration.zero,
  );
  Duration _duration = Duration.zero;

  /// 真实时长（从流里读出来的，不是元数据的）
  ///
  /// 原版注释：
  /// > 元数据的 duration 常常不准（尤其 HLS），
  /// > 用它算百分比会让"续播位置"偏到离谱的地方。
  Duration _realDuration = Duration.zero;

  bool _playing = false;
  double _volume = 100;

  // ── task-18 ③④⑤：片段下载 / 日志 ──
  //
  // 真正的状态（并发上限 / 缓存上限）在 ClipDownloader、日志在 AppLog，
  // 两边都是**进程级单例**；这里只放本页面要画的东西。
  /// 正在下载的**文件名**集合（按名字去重，**不是**全局互斥）
  ///
  /// ★ 2026-10-04 订正（Lead 审计 team-message-914508ce，【中】第 2 条）：
  ///   这里**原先**是 `bool _clipDownloading = false;`，配上 `_downloadClip()`
  ///   开头的 `if (_clipDownloading) return;` —— 一个**全局**重入守卫。
  ///
  ///   后果：UI 路径上永远只有 1 个下载在跑 ⇒ `ClipDownloader.maxObservedActive`
  ///   恒 ≤ 1 ⇒ 并发上限滑杆在**真实 UI 路径**上不可观测，而
  ///   `lib/ui/settings/playback_page.dart` 里那句「用户把并发调到 1，再点两次
  ///   下载，第二个就**真的**在等第一个」因此是**错的**（第二次点击被守卫吞掉，
  ///   根本进不到池子）。
  ///
  ///   现在改成**按流地址（url）去重**：同一集的同一条流重复点不会重复下
  ///   （提示「已经在下载了」），换一集 / 换源再点就是**真的并发** —— 两个
  ///   `ClipDownloader.download()` 一起进池子，滑杆从此在 UI 上可观测。
  ///   面板按钮也**不再**在下载中禁用（见
  ///   `widgets/player_settings_sheet.dart` 里那段说明）。
  ///
  ///   ★ 2026-10-04 第二次订正（Lead 裁决 team-message-c3274cd8 第 1 条）：
  ///     去重键**起初**用的是 `_clipFileName`（文件名）—— android-phone 在
  ///     源码里发现它在标题为空时回落成 `clip.mp4`（见 _clipFileName），
  ///     两个**无标题**的集会撞名 ⇒ 第二次点被挡掉，去重反而误伤。
  ///     现在键 = `st.url`：同一集的**真正身份**是那条流。
  ///     · 同一集、同一 url 重复点 → 挡掉（设计意图）；
  ///     · 同一集**换源**后 url 变了 → 放行（那是另一条流，本来就该各自下）；
  ///     · 文件名继续只当「下载文件叫什么」，不再承担身份职责。
  ///     为什么不用 url 的 hash：`Set<String>` 存原串零额外成本（发请求本来
  ///     就要用它），hash 只多一次可读性更差的转换。
  final Set<String> _clipRunning = <String>{};

  /// 有任何一个下载在跑（面板据此显示「下载中…」）
  bool get _clipDownloading => _clipRunning.isNotEmpty;

  /// 本次会话里至少成功下载过一次（面板据此显示「已下载」而不是每次都像第一次）
  ///
  /// ★ 换集 / 换源时会跟着 `_skipMarker` 一起清零 —— 否则用户下载第 1 集后
  ///   切到第 2 集，面板仍显示「已下载」（Lead 审计【低】第 4 条）。
  bool _clipDownloaded = false;

  /// 上一次下载失败的原因（null = 没失败过）
  String? _clipDownloadError;
  bool _muted = false;
  double _rate = 1.0;

  /// 控制条是否可见（鼠标移动/按键后显示，几秒后自动隐藏）
  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// 指针**是否还在本页内**（`MouseRegion.onEnter` / `onExit` 维护）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-10-09（task-16）Owner 原话（附截图）：
  /// ```text
  /// > 全屏左上角这个单独的返回icon,还没消失
  /// ```
  /// 截图里控制条**已全部收起**，但左上角仍挂着一枚返回箭头。
  ///
  /// # 为什么需要这个字段（根因：两个目标被写进了同一段代码）
  /// ```text
  /// 目标 A（缺陷 2 修复时定的）：顶栏箭头淡出时，悬浮键**交叉淡化淡入**
  ///         —— 目的是「两枚箭头不同屏」（同一条 _controlsFade，opacity 之和恒为 1）。
  /// 目标 B（Owner 现在要的）：控制条收起后，画面上**不该有任何残留控件**。
  ///
  /// A 要求「控制条藏 ⇒ 悬浮键出现」，B 要求「控制条藏 ⇒ 什么都不显示」。
  /// ⇒ 两者在数学上冲突：A 的终态（opacity = 1 - 0 = 1）恰好是 B 的最糟状态。
  /// ```
  ///
  /// # 解法：给「常驻」补一个**独立的**判据，而不是动那条交叉淡化
  /// ```text
  /// 控制条可见              ⇒ 顶栏那枚（现状不变，opacity = f）
  /// 控制条隐藏 + 指针在页内 ⇒ 悬浮键（用户要找返回口）← 这才是当初设计它的本意
  /// 控制条隐藏 + 指针离开   ⇒ ★ 什么都不画（本次修的）
  /// ```
  /// 即悬浮键 opacity = `(1 - f) × hover`：`1 - f` 那一半**一个字节都没动**
  /// ⇒ 交叉淡化契约（t118 ⑩）与「任意时刻最多一枚箭头」都保持。
  ///
  /// ⚠️ 为什么是 `onEnter`/`onExit` 而不是复用 `onHover`：
  ///    `onHover` **只在指针移动时**触发，指针一旦静止就不再有事件
  ///    ⇒ 用它维护「在不在」会永远停在最后一次移动的位置（假 true）。
  ///    `onEnter`/`onExit` 由 `RenderMouseRegion.handleEvent` 按
  ///    `MouseTrackerAnnotation` 的进出派发，**与移动无关** ⇒ 指针静止也正确。
  ///
  /// ⚠️ 它**故意不参与** `_showControls()` 那条「值没变就不 setState」的守卫：
  ///    这里 `if (v == _pointerInside) return;` 只在**真的翻转**时重建，
  ///    所以「鼠标一进一出」最多各重建一次 —— 不会像 `onHover` 那样
  ///    每次移动都重建整页（见 `_showControls()` 里 60 次移动 = 60 次重建 的实测）。
  bool _pointerInside = false;

  /// 指针进入本页（`MouseRegion.onEnter`）—— 见 [_pointerInside] 的长注释
  void _onPointerEnter() {
    if (_pointerInside) return;
    setState(() => _pointerInside = true);
  }

  /// 指针离开本页（`MouseRegion.onExit`）—— 见 [_pointerInside] 的长注释
  void _onPointerExit() {
    if (!_pointerInside) return;
    setState(() => _pointerInside = false);
  }

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ 2026-10-08（Owner 第 9 条）控制条**淡入淡出**
   * ══════════════════════════════════════════════════════════════════
   *
   * 用户原话：
   * > 视频播放页,播放器的控件不会主动消失,一直在显示,需要处理一下,
   * > 我的要求是,鼠标悬浮到控件的区域晃动,就应该把控件都显示出来,
   * > 然后指定时间后再自动消失,**要有动画喔**;
   * > 然后单击操作,播放暂停也是一样的,也要显示控件,
   * > 然后也是指定时间后再自动消失,要有动画喔,这里处理是一样的
   *
   * # 为什么不能在 build 里就地开一个 AnimationController
   * ```text
   * build 里 new 控制器 ⇒ 每次重建都换一个 ⇒ 动画永远从 0 重来；
   * 而本页 build 每次鼠标移动都可能跑（_showControls 只是有值守卫，
   * 不是「不重建」）⇒ 必须把控制器放在 State 上，生命周期 = 本页。
   * ```
   *
   * ⚠️ 为什么**必须**在 State 初始化时就给 value: 1：
   *    _controlsAnim.value 要镜像 _controlsVisible（初值 true ⇒ 1.0），
   *    否则**第一帧**会从 0 淡入 —— 那是「启动时闪一下」的老毛病
   *    （与 _KeepAliveTransition 的 _c 用 value: 1 同一条纪律）。
   */
  late final AnimationController _controlsAnim = AnimationController(
    vsync: this,
    duration: Motion.base,
    value: 1,
  );

  /// 控制条的过渡层动画（曲线与二级页链/底栏链**同源**：Motion.easeOut）
  late final Animation<double> _controlsFade = CurvedAnimation(
    parent: _controlsAnim,
    curve: MotionPrefs.curve(context, Motion.easeOut),
    reverseCurve: MotionPrefs.curve(context, Motion.easeOut),
  );

  /// 把 _controlsVisible 的**目标态**应用到动画控制器上
  ///
  /// # 为什么统一走这一个函数
  /// ```text
  /// 控制条的显隐有多个写入点（_showControls 的显示/隐藏、面板开关、
  /// _togglePlay…）。任何一个漏了「同步动画」，那个路径就会变成**硬切**
  /// （而用户明确要求「要有动画」）
  /// ⇒ 全部收敛到这里：将来新增写入点只会漏「调用」，
  ///   不会漏「某个动画分支」。
  /// ```
  void _applyControlsMotion() {
    final target = _controlsVisible ? 1.0 : 0.0;
    /*
     * ★ Reduce Motion（无障碍「减少动态效果」）：时长被解析成 0 时
     *   _controlsAnim.duration 就是零 ⇒ forward/reverse 同帧到位，
     *   等价于硬切 —— 不需要在这里再写一遍 if。
     */
    _controlsAnim.duration = MotionPrefs.duration(context, Motion.base);
    if (_controlsAnim.value == target) return;
    if (target == 1.0) {
      _controlsAnim.forward();
    } else {
      _controlsAnim.reverse();
    }
  }

  /// 指向**播放页自己那个** `GestureDetector`（探针用，2026-09-25）
  ///
  /// # 为什么需要它
  ///
  /// 交付实测要断言"单击不再分流"（`onTapUp` 没挂）。但扫整棵渲染树
  /// 找 `onTapUp` 是**无效**的 —— `InkWell` 内部无条件挂着它，
  /// 而控制条里全是 `InkWell`，所以树里**永远**能找到一个 `onTapUp`。
  ///
  /// 用 key 精确定位到播放页自己那个 detector，读它的真实字段。
  /// 见 `debugPlayerOwnGestureState()`。
  final GlobalKey _gestureKey = GlobalKey();

  /// 两枚返回箭头的定位锚点（探针用，2026-10-09，缺陷 2）
  ///
  /// ★ 交叉淡化的正确性**不能**靠「代码里传了 fade」来证明 ——
  /// 那只是声明，不是读数。真正的判据有两条，都要实测：
  ///   ① 两枚箭头的**矩形位置**必须重合（同一枚箭头的两个位置）；
  ///   ② 任意中间帧两者 **不透明度之和 ≈ 1**（不许出现「两个都看得见」）。
  /// 由 `debugPlayerBackArrowGeometry()` 读出来。
  final GlobalKey _topBarBackKey = GlobalKey();

  /// 播放页根 `Focus` 的节点（task-42）
  ///
  /// 用途：让硬件层兜底能判断"焦点是否已在本页子树里"（见 `_focusIsInsideThisPage`）。
  /// ⚠️ 显式 node 必须在 `dispose()` 里释放。
  final FocusNode _pageFocusNode = FocusNode(debugLabel: 'PlayerPage');

  /*
   * ★★★ PC 键盘方向键的状态机（用户 2026-09-25 要求）
   *
   * > 在pc上,小键盘的左右按键 单击 应该是步数控制,长按是 快进快退
   * > 这两个都是可配置 可关闭的
   *
   * 判定逻辑在 `core/player_gestures.dart::PcArrowKeyRouter`
   * （纯逻辑、无 widget 依赖）—— 这样测试能**直接驱动生产代码**，
   * 而不是在测试里复刻一份影子实现。
   */
  final PcArrowKeyRouter _pcArrow = PcArrowKeyRouter();

  /// 长按判定的**超时兜底**计时器
  ///
  /// 正常路径是系统发 `KeyRepeatEvent`；但少数平台/输入法
  /// 不发重复事件，那些机器上只靠 repeat 判定就**永远不会触发长按**。
  Timer? _pcArrowHoldTimer;

  /// 累计调用 `_seekBy` 的次数（**只读探针**，2026-09-25）
  ///
  /// `_seekBy` 是"单击跳秒"的唯一执行路径。实测靠它判断
  /// "单击有没有触发 seek" —— 比只看播放位置更直接（见
  /// `debugPlayerSeekByCalls()` 的说明）。
  ///
  /// ⚠️ 它**只增不减、不参与任何逻辑**，纯诊断用。
  int _seekByCalls = 0; // ★ 只读探针

  /// 累计**真正执行**的切集次数（**只读探针**，task-28 ①-C）
  ///
  /// # 为什么必须有这个计数器（用户报的 bug 要它才能定论）
  ///
  /// 用户原话：
  /// > 明明没有下一集，却还是**请求**下一集，这是 bug
  ///
  /// # ★ 判据必须是"行为层"，不能是"显示层"
  ///
  /// ```text
  /// 显示层：最后一集时「下一集」按钮是不是灰的   ← 只能证明按钮的样子
  /// 行为层：最后一集时到底有没有【真的切集】      ← 用户报的是这个
  /// ```
  /// 光看按钮看不出"有没有请求" —— 必须有一个**因果链上最直接**的读数。
  ///
  /// # 为什么计数点放在 `_gotoEpisode` 的**入口**
  ///
  /// 本项目所有"切集"最终都汇流到 `_gotoEpisode`（实测枚举过）：
  /// ```text
  /// ① _gotoNextEpisode()      → 走它
  /// ② N 快捷键                → 走 ①
  /// ③ 倒计时「立即播放」       → 走 ①
  /// ④ 遥控 next_episode       → 走 ①
  /// ⑤ 控制条按钮              → onPressed: hasNext ? onNext : null → 走 ①
  /// ```
  /// ⚠️ 计数点**不能放在按钮的 onTap 里** —— 那只证明"按钮被点了"，
  ///    不能证明"切集动作发生了"（按钮可能是 null、可能被 if 挡住）。
  ///    放在 `_gotoEpisode` 入口 = 数的是**动作本身**，且遥控触发的也算。
  ///
  /// ⚠️ 它**只增不减、不参与任何逻辑**，纯诊断用（与 `_seekByCalls` 同一模式）。
  int _gotoEpisodeCalls = 0; // ★ 只读探针

  /// 累计**尝试**切集但被"没有下一集/上一集"挡回去的次数（只读探针）
  ///
  /// 与 `_gotoEpisodeCalls` 配对，用来区分两种"没切"：
  /// ```text
  /// 最后一集点「下一集」→ 该计数 +1，_gotoEpisodeCalls 不变
  ///                      ⇒ 判据【拦住了】—— 这是期望行为
  /// 最后一集点「下一集」→ 两个计数都 +1
  ///                      ⇒ ★ 判据失效（真 bug）
  /// ```
  /// 有了这两个数，"拦住了"和"根本没触发"才区分得开。
  int _blockedNavCalls = 0; // ★ 只读探针

  /// 最近一次**手势/方向键**要求的播放倍速（探针用）
  ///
  /// # 为什么不能直接断言 `_rate`（实测确认）
  ///
  /// `_rate` 是由 `_player.stream.rate` 回填的（见 `_bindPlayerStreams`）。
  /// 而在 `flutter test` 里，原生 media_kit 播放器**不发任何事件**
  /// （实测：按住方向键后 `_rate` 仍然是 1.0）——
  /// 那样的断言**永远为真**，是空断言。
  ///
  /// 所以记“**我们要求了多少**”。这恰好就是本次要验的行为：
  /// ```text
  /// 长按 -> 必须要求**配置值**（不是写死的）
  /// 松手 -> 必须要求**回到原值**（不是写死 1.0）
  /// ```
  double? _lastRateRequest;

  /// 请求一个新倍速（记录 + 转发）
  ///
  /// 指向播放器的入口收敛到这一处，下面四个长按函数都走它 ——
  /// 以后新加手势时不会漏记。
  void _requestRate(double r) {
    _lastRateRequest = r;
    _player.setRate(r);
  }

  /// 累计调用 `_togglePlay` 的次数（**只读探针**，2026-09-25）
  ///
  /// 与 `_seekByCalls` 配对：理想结果是单击后 `togglePlay +1 且 seekBy +0`。
  int _togglePlayCalls = 0;

  /// 累计调用 `_toggleFullscreen` 的次数（★ task-42 只读探针）
  ///
  /// 见 `debugPlayerFullscreenCalls()` 的说明：**计数**比布尔值可靠 ——
  /// 布尔值在"切两次"后会回到原值，测试会误判成"没反应"。
  int _fullscreenCalls = 0;

  /// 正在截图（**防重入**）
  ///
  /// 为什么必须有：media_kit 1.2.6 的 `Player.screenshot()` 内部
  /// `await waitForPlayerInitialization` —— 播放器进 `idle-active` 之前
  /// 那个 future **永远不会完成**（real.dart:1383-1385 是唯一的 complete()）。
  /// 连按两次就会堆两个永不返回的调用。
  bool _shotBusy = false;

  /// 累计调用 `_takeScreenshot` 的次数（★ task-21 P1-30 只读探针）
  ///
  /// 与 `_fullscreenCalls` 同理：**计数**比布尔值可靠 ——
  /// 布尔值在"点两次"后会回到原值，测试会误判成"没反应"。
  int _screenshotCalls = 0;

  /// ★★★ task-22 P1-5：底栏「画面缩放」长按浮层（滑动条卡片）
  ///
  /// 与 `_hintsOpen` 同级的**同类浮层**：都挂在底栏那一层，都是
  /// `Positioned` 铺满宽度。加进 `_anySheetOpen` 之后，它开着的时候
  /// Enter 不会误触全屏、Esc 会先收掉它。
  bool _zoomOpen = false;

  /// ★★★ task-22 P1-11：当前画面缩放（**百分比**，100 = 原始比例）
  ///
  /// 为什么存百分比而不是 mpv 那个 log2 值：面板的档位、底栏滑条的量程
  /// 都是百分比，用户看到的也是百分比 —— 换算只发生在
  /// `videoZoomToMpv()` / `_applyVideoZoom()` 这两处。
  double _videoZoomPct = 100;

  /// 快捷键提示浮层
  bool _hintsOpen = false;

  /// 剧集面板
  bool _episodeSheetOpen = false;

  /// 线路面板
  bool _streamSheetOpen = false;

  /// ★★★ task-53【③】「所有直播」频道列表面板（用户第 3 条）
  ///
  /// ```text
  /// 用户原话：> 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
  /// ```
  /// ⚠️ 只在直播（`_isLive && widget.onLiveChannels != null`）时才可能为 true。
  bool _liveChannelsOpen = false;

  /// 下一集倒计时（秒，0 = 未启动）
  int _nextCountdown = 0;
  Timer? _countdownTimer;

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 底栏「悬浮小窗」popover（Owner 2026-10-09 第 12 条）
  // ═══════════════════════════════════════════════════════════════════
  //
  //  倍速 / 线路 / 字幕 / 音轨 / 弹幕 / 更多 —— 这些「选择类」操作
  //  不再走弹窗或抽屉，改为贴在按钮旁的小卡片（B 站 / 腾讯视频那一档）。
  //
  //  ★ 一份真值源：同时只可能有一个 popover 开着。Esc / 遥控器返回键
  //    只要 `close()` 就能把当前那个关掉（见 `_onEarlyKey`）。
  final PopoverController _popover = PopoverController();

  /// 片头/片尾跳过点
  SkipMarker? _skipMarker;

  /// 是否已触发过片头跳过（避免反复跳）
  bool _introSkipped = false;

  /// 是否已触发过片尾跳过
  bool _outroSkipped = false;

  /// 待跳转位置（换集/换源后续播用）
  Duration? _pendingSeek;

  /// 进度落盘节流
  Timer? _progressTimer;
  Duration _lastSavedPosition = Duration.zero;

  /// 当前剧集下标
  late int _epIndex = widget.episodeIndex ?? 0;

  /*
   * ★★★ 这些做成**可变状态**而不是直接读 widget
   *
   * # 为什么（换源的需要）
   *
   * `_episodes` / `widget.provider` / `widget.id` 都是 `final`
   * —— 换源后它们全变了，但 widget 改不了。
   *
   * 而换源是**原地**的（原版注释：「原地换源继续播」），
   * 不能重建整个播放器页（那会黑屏一下、还要重新协商解码器）。
   *
   * 所以把"会随换源改变"的东西提成 state：
   * ```text
   * _episodes    新源的剧集列表
   * _provider    新源的 id
   * _contentId   新源的内容 id
   * _sourceCode  新源的首个线路
   * ```
   * 初始化时从 widget 取，换源时整批替换。
   */
  late List<Episode> _episodes = widget.episodes;
  late String _provider = widget.provider;
  late String _contentId = widget.id;
  late String? _sourceCode = widget.sourceCode;

  /// ★★★ task-53【#4b】当前正在看的直播频道 id
  ///
  /// # 为什么不能直接用 `widget.liveChannelId`
  /// ```text
  /// 它是 `final`（widget 不可变），而**在播放页里切台**要求它可改
  /// —— `_isLive`、`getLiveStream` 的目标、顶栏标题全都读它。
  /// ★ 与 `_provider`/`_contentId` 同一个理由（那段注释已经解释过
  ///   "会变的东西必须提成 state"），只是切台比换源更频繁。
  /// ```
  /// ⚠️ 语义是"**当前播放的**频道"，不是"进来时那个频道"——
  ///    初始值仍取自 widget，所以进播放页那一刻的行为**完全不变**。
  late String? _liveChannelId = widget.liveChannelId;

  /// ★★★ task-53【#4b】当前标题（与 `_liveChannelId` 同步更新）
  ///
  /// ```text
  /// `widget.title` 是 `final`，而切台后顶栏必须显示**新台名** ——
  /// 否则用户按 ↓ 换了台，顶上还写着上一个台的名字（看起来像"没切成"）。
  /// ```
  /// ⚠️ 只替换**渲染/上报**处读的 `widget.title`（顶栏、遥控状态）。
  ///    其余读 `widget.title` 的地方是"写库用的标题"（保存进度/片头片尾/
  ///    跳过点 key）—— 那些**全是点播专用**（直播那几处早就有
  ///    `if (_isLive) return;` 守卫），所以不改它们也不会写错。
  ///    ★ 不改是为了**收窄改动面**：每一处都动会扩大回归风险，
  ///      而它们的守卫已经保证了直播下不可达。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ task-72【④】上面那条「收窄改动面」的判断**已被实测推翻**
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # Owner 原话（逐字）
  /// ```text
  /// > 我点击这个换源,还显示出来这个空白的,也没自动搜,也没填充
  /// ```
  ///
  /// # ★ 决定性证据：**同一屏**，顶栏有标题、弹层拿到空串
  /// ```text
  /// 顶栏显示「无职转生 第三季 … / 第01集」  ← 读的是本字段 `_title`（非空）
  /// 而「换源」弹层的输入框是**灰色占位符**「关键词（可修改后重搜）」
  ///     ← 它由 `widget.title` 初始化（source_switch_dialog.dart:171）
  /// ⇒ 同一个画面一处有、一处空 ⇒ `widget.title` 的确是空串
  /// ```
  /// 因果链（三个症状同一个根因）：
  /// ```text
  /// player_page.dart:3021   title: widget.title        ← 空串
  /// source_switch_dialog.dart:172  TextEditingController(text: widget.title)
  /// source_switch_dialog.dart:190  addPostFrameCallback((_) => _run())
  /// source_switch_dialog.dart:210  if (kw.isEmpty) return;  ← ★★ 静默返回、零请求
  /// ⇒ 「空白」+「不自动搜」+「不填充」全是这一条
  /// ```
  ///
  /// # 为什么"有 `_isLive` 守卫"没能兜住
  /// ```text
  /// 守卫只保证"直播下不可达"，但本 bug 发生在**点播**路径上 ——
  /// 合并页入口（`shell.dart` 的 `_mediaRoute()`）**不知道标题**，
  /// 传的是 `title: ''`（见那里的注释）⇒ 那几处守卫**一个都不触发**。
  /// ⇒ 结论：守卫与"标题是否为空"是**两个正交的维度**，
  ///   前者成立**不能**推出后者安全。★ 这就是上面那条判断错在哪。
  /// ```
  late String _title = widget.title;

  /// ★★★ task-72【④】传参 / 写库一律用这个「活标题」，**不读构造参数**
  ///
  /// 与 L2820（`_saveProgress`）**同一条纪律、同一个写法**：
  /// ```text
  /// 写库读活值 ⇒ 保留 `widget.title` 作兜底
  /// ```
  /// 兜底是必要的：直播 / 遥控等路径可能直接构造
  /// `PlayerPage(title: …)` 而**从不走** `updateDisplayTitle` ⇒
  /// 那时 `_title` 与 `widget.title` 同值，取哪个都对。
  String get _liveTitle => _title.isNotEmpty ? _title : widget.title;

  /// ★★★ 当前作品的封面（2026-09-26 第二轮新增）
  ///
  /// # 为什么必须有这个字段（Owner 报的「播放记录显示 ？ 」的根因之一）
  ///
  /// ```text
  /// `widget.cover` 是 `final`；而合并页的入口 `shell.dart` 的 `_mediaRoute()`
  /// **根本没传 cover**（它连标题都不知道 —— 见那里的注释）⇒ `widget.cover` 恒为 null。
  /// ⇒ `_saveProgress` 写库时 `cover: widget.cover` ⇒ **写进库的就是 null**
  /// ⇒ 播放记录列表渲染不出封面 ⇒ 显示成一个「？」占位。
  /// ```
  /// 而封面**其实已经到了** —— 详情加载完时 `MediaPage._onDetailLoaded(d)`
  /// 手里就有 `d.cover`，只是 `updateDisplayTitle` 当时**只转发标题**。
  ///
  /// ⇒ 所以补这个字段 + 让 [updateDisplayTitle] 能带上它。
  ///   与 [_title] **同一条纪律**：只影响渲染与写库，**绝不触碰流**。
  ///
  /// ⚠️ 语义与 [_title] 对称：`null` = "还不知道"（此时写库要**保留旧值**，
  ///    不能把库里已有的封面清掉 —— 见 `_saveProgress` 的注释）。
  ///
  /// ⚠️ 必须 `late` + 在 `initState` 里赋值（**不能**写成
  ///    `late String? _cover = widget.cover;`）——
  ///    字段初始化器里**读不到 `widget`**（`implicit_this_reference_in_initializer`，
  ///    `flutter analyze` 当场报错）。[_title] 之所以能那样写，
  ///    是因为它在**声明处**用了 `late` 且 Dart 对 `late` 的初始化器
  ///    求值时机不同 —— 但那个写法同样脆弱，这里按报错提示改成显式赋值。
  String? _cover;

  /// 当前**站点**的显示名（task-32）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// 用户原话
  /// ══════════════════════════════════════════════════════════════════
  /// > 播放页和详情页都不能看到当前播放源是哪一个
  ///
  /// # 原版对照（★ 结论：原版**没有**这个显示）
  ///
  /// `PlayerView.vue` 的模板从 L4165 开始，整个模板里 `provider`
  /// **只出现 2 次**（L4181/L4182），都是传给换源弹层的 props
  /// —— 没有任何一处把站点名渲染给用户。
  ///
  /// 全仓 grep `providerName` 的**渲染点**只有三处，全都不在这两页：
  /// ```text
  /// LiveView.vue:185        {{ g.providerName }}      直播页
  /// SearchView.vue:100      搜索结果分组
  /// SourceSwitchDialog.vue:320 / PluginConfigDialog.vue:149   弹层
  /// ```
  ///
  /// ⇒ 所以这是**超出原版功能对等**的一处增强，由用户明确要求
  ///   （"播放页...不能看到当前播放源是哪一个"）。
  ///
  /// # 为什么显示在**顶栏**而不是别处
  ///
  /// 顶栏是原版 `metabar`（`PlayerView.vue:4350`）在我们这套
  /// **沉浸式 overlay 版式**里的对应物 —— 那里正是原版放
  /// "当前标题 / 集名 / 线路标签"的地方。复用同一个位置，
  /// 不新造一个信息区。
  ///
  /// # 为什么是站点名而不是线路名
  ///
  /// 与详情页同一口径（见 `detail_page.dart::_providerName`）：
  /// 用户说的"源"= **站点**（cycani / tyyszy / cctv）。
  /// 站内的线路/清晰度由底部栏「线路」按钮那个面板回答。
  ///
  /// ⚠️ 换源（`_switchSource`）会改 `_provider` —— 那时必须**重新取**
  ///    名字，否则顶栏会一直显示旧站名（详见 `_switchSource` 里的调用）。
  String? _providerName;

  /// 全屏状态
  bool _fullscreen = false;

  /// ★ 画中画状态
  ///
  /// 原版是 `hk.add("KeyP", () => { if (art) art.pip = !art.pip; })` ——
  /// 用 ArtPlayer 内置的 pip（底层是浏览器的 `<video>.requestPictureInPicture()`）。
  ///
  /// ⚠️ media_kit **没有内置 PiP**（翻过源码确认），所以走平台侧实现：
  /// ```text
  /// Windows  缩窗 + 置顶 + 不进任务栏
  /// Android  enterPictureInPictureMode（API 26+）
  /// ```
  bool _pipActive = false;
  bool _pipSupported = false;

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 播放设置面板（字幕 / 音轨 / 连播策略）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 原版把这些交给 ArtPlayer 的 `setting: true` 内置面板
  // （`PlayerView.vue:3436`）加上四个自定义 settings 项
  // （`PlayerView.vue:3475-3514`）。我们是 libmpv 后端，
  // 那些设置项要自己给一个入口 —— 所以有 `_settingsOpen`。
  //
  // 面板**不持有播放状态**（见 `player_settings_sheet.dart` 文件头），
  // 宿主把当前值传进去、把改动落到 mpv。

  /// 设置面板是否打开
  bool _settingsOpen = false;

  /*
   * ★★★ task-25 D / 2026-10-08：面板的显示**只有一个真源**，没有镜像 bool
   *
   * `_settingsOpen`  面板是否该画（**唯一真源**，onClose / Esc 都只改它）
   *
   * # 为什么不再留一个 `_settingsPortalShown` 镜像（曾经有过，已删）
   *
   * 最初留它，是为了把 `OverlayPortalController.show()` 收敛成幂等
   * （show() 里有 `assert(schedulerPhase != persistentCallbacks)`，
   *  build 期间调会炸）。但它**会过期**，而一旦过期就造成第 3 条那个
   * 「点齿轮无反应、底栏也回不来」且**不可自愈**的故障：
   *
   * ```text
   * portal 的 Element 被重建（挂载点两侧都有条件子件，见 :9272 的注释）
   *   ⇒ controller 的可见状态不跟随（overlay.dart:1675-1684 的契约）
   *   ⇒ 镜像仍是 true ⇒ show() 被吞 ⇒ 面板永远画不出来
   * ```
   *
   * ⇒ 现在**直接问 controller**（`isShowing` 是它自己维护的真实状态，
   *   不存在过期问题），镜像就没有存在理由了。
   *
   * ⚠️ `_settingsOpen == false` 时 overlayChildBuilder 直接返回
   *    `SizedBox.shrink()` ⇒ 面板一定不渲染（这条没变）。
   */

  /// rootOverlay 上的播放设置面板（★ task-25 D）
  ///
  /// ⚠️ 它是**常驻**的（不随 `_settingsOpen` 创建/销毁）：`OverlayPortal` 的
  ///    控制器必须在**构造期**就存在，否则第一次 false→true 时会新建一个
  ///    「从没 show 过」的控制器 ⇒ 面板永远不出现。
  /// ⚠️ `OverlayPortalController` 没有 `dispose()`（overlay.dart:1685-1773）
  ///    ⇒ `dispose()` 里不需要收它。
  final OverlayPortalController _settingsPortal = OverlayPortalController();

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ dandanplay 弹幕（task-13 ⑦）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 用户原话：
  // > 接入一下 dandanplay 的弹幕功能
  //
  // 核心层在 core/danmaku.dart（协议 / 签名 / 解析 / 排版），
  // 渲染层在 widgets/danmaku_overlay.dart（自驱帧循环），
  // 面板在 widgets/danmaku_settings_dialog.dart（纯 UI）。
  // 这里只做**接线**：起播取一次、叠一层、底栏两个入口。

  /// 弹幕总开关（dsh.danmaku.enabled，默认关）
  ///
  /// ⚠️ 默认**关**：原版弹幕是 ArtPlayer 自带的，我们这是外部服务，
  ///    默认开会在用户还没填凭证时先弹一堆 403 提示。
  bool _danmakuEnabled = false;

  /// 弹幕设置面板是否打开
  bool _danmakuSheetOpen = false;

  /// 正在取弹幕
  bool _danmakuLoading = false;

  /// 上一次取弹幕的失败原因（null = 没有）
  ///
  /// ★ 原样保留 X-Error-Message 等原文（见 DanmakuException.detail）
  DanmakuException? _danmakuError;

  /// 当前挂载的弹幕（已按时间排序，已叠加 shift）
  List<DanmakuComment> _danmakuComments = const <DanmakuComment>[];

  /// HTTP 客户端（懒建；凭证改了必须重建 —— appId/appSecret 是构造快照）
  DandanplayClient? _danmakuClient;

  /// 上一次取弹幕的结果摘要（给面板与角标显示）
  String _danmakuStatus = '';

  /// 取弹幕的并发令牌（换集时旧的响应必须被丢掉）
  int _danmakuFetchToken = 0;

  /// 面板的状态快照（面板是纯 UI，所有读写都经过宿主）
  DanmakuSettingsState _danmakuSettings = DanmakuSettingsState.fromPrefs();

  /*
   * ══════════════════════════════════════════════════════════════════
   *  ★★★ task-31 ④：哔哩哔哩弹幕（导入 + 绑定 + 自动更新）
   * ══════════════════════════════════════════════════════════════════
   *
   * 与 dandanplay 的关系：**同一时刻只有一个源在工作**。
   * ```text
   * 绑了 B 站 ⇒ `_loadDanmakuNamed` 里 B 站优先，dandanplay 一条请求都不发
   * 没绑     ⇒ 行为与接线前**逐字节相同**（新代码全部走 BiliPrefs 判据）
   * 解绑     ⇒ 下次起播自动退回 dandanplay
   * ```
   * 两条路的产物都是 `DanmakuComment` ⇒ 渲染层（DanmakuOverlay /
   * DanmakuTrackAllocator）**零改动**。
   */
  /// 「哔哩哔哩弹幕」面板是否打开
  bool _biliSheetOpen = false;

  /// 面板的状态快照（面板是纯 UI，所有读写都经过宿主）
  BiliImportState _biliState = const BiliImportState();

  /// B 站 HTTP 客户端（懒建 —— 没绑过的用户一个连接池都不建）
  BiliApi? _biliApi;

  /// 绑定时缓存下来的视频信息（P 列表 / 标题）
  ///
  /// ⚠️ `bindFromInput` 只回 `BiliBindOutcome`、**不回** `BiliVideoInfo`
  ///    （见 `.probe/bili/INTEGRATION.md` §4.4）⇒ 宿主自己再拉一次。
  ///    代价是多一个请求（服务端有缓存，实测 ~200 ms），
  ///    好处是**不动** `bili_bind.dart`（动了已跑绿的 t70 得跟着改）。
  BiliVideoInfo? _biliInfoCache;

  /// 当前这一集实际用的 cid（0 = 没有）
  int _biliCid = 0;

  /// ★ 打开面板那一刻的 `_danmakuFetchToken`
  ///
  /// 面板里的「导入并绑定 / 立即更新」都要判"这一集还是不是我打开面板时
  /// 那一集" —— 令牌变了就说明中途换过集，那次操作的结果必须丢掉
  /// （与 `_danmakuFetchToken` 同一条规矩）。
  int _biliPanelToken = 0;

  /// ★★★ task-31 ⑤：「在线搜索字幕」（assrt.net）面板是否打开
  bool _subtitlePanelOpen = false;

  /// 已加载的**外挂字幕**（面板要显示文件名；null = 没有）
  ///
  /// ⚠️ 只用于「显示 + 记录」—— 真正加载进 mpv 的是 `sub-add` 命令，
  ///    这个对象是给"我加载过什么"留证据的（也让 applyStyle 能在
  ///    重新打开面板时标出它）。
  SubtitleTrack? _externalSubtitle;

  /// 所有可用轨的列表（`player.stream.tracks`）
  Tracks _tracks = const Tracks();

  /// 面板上要显示成"选中"的字幕轨 id
  ///
  /// 与 `_currentTrack.subtitle.id` **分开**是必要的：
  /// mpv 在"用户选了某条轨"和"自动选中"之间会来回变（手册明确说
  /// track selection 的行为 "tends to change around with each mpv release"），
  /// 面板显示我们自己记的值更稳。
  String _sidChosen = 'auto';

  /// 当前音轨 id
  String _aidChosen = 'auto';

  /// ★ 交给遥控桥的那个 [PlayerBridge] 实例（用于 dispose 时**精确**注销）
  ///
  /// 存下来而不是 dispose 里现场 new 一个：`clearPlayer(b)` 靠
  /// `identical` 判断"桥持有的还是不是我"，现场构造的必然不等于它 ——
  /// 那样会退化成"无条件清"，换页重叠时会误伤新注册的播放页。
  PlayerBridge? _remotePlayerBridge;

  /// 用户**手动**选过字幕轨吗
  ///
  /// 手动选过之后就不再自动选第一条真实轨 —— 否则「关闭字幕」
  /// 会在下一次轨列表刷新时被自动改回来，等于这个操作无效。
  bool _pickSubtitleMadeByUser = false;

  /// 从 mpv **读回来**的字幕样式值（面板显示用）
  ///
  /// 为什么不写死默认值：mpv 的 `sub-font-size` 默认值在版本间变过
  /// （老版本是 55，新版本是 38）—— 写死就等于**悄悄改了用户的观感**。
  /// 打开面板前先把当前值读出来，面板只负责改、不负责猜。
  Map<String, String> _mpvStyle = {};

  /// 面板要显示的 mpv 样式属性
  ///
  /// ⚠️ 注意别名关系（mpv 手册）：
  /// ```text
  /// sub-border-size  是 sub-outline-size 的别名
  /// sub-border-color 是 sub-outline-color 的别名
  /// ```
  /// 用**短名**读回来即可，mpv 两个名字指向同一个属性。
  static const _styleKeys = <String>[
    'sub-ass-override',
    'sub-font',
    'sub-font-size',
    'sub-color',
    'sub-border-color',
    'sub-border-size',
    'sub-margin-y',
  ];

  // ── 连播策略（照抄原版 `stores/player.ts` 的四个偏好）──
  //
  // 原版存 localStorage（`dsh.playprefs`）；我们的对应物是 `UiPrefs`
  // （同样是**纯前端偏好**，丢了最多是回到默认值）。
  // ⚠️ 默认值与原版一字不差：
  // ```text
  // endAction            autoNext（自动连播）
  // countdownBeforeNext  true
  // keepSourceOnNext     true
  // autoSkip             true
  // ```

  /// 播放完一集之后干什么
  PlayEndAction _endAction = PlayEndAction.autoNext;

  /// ★★★ task-22 P2-9：解码模式（Auto / HW+ / HW / SW）
  ///
  /// 默认 = `HwdecMode.auto` ⇒ `--hwdec=auto-safe`，与改前的行为**逐字一致**。
  /// 白名单校验见 `_loadPlayPrefs()`（坏偏好回落到 auto，不抛）。
  HwdecMode _hwdecMode = HwdecMode.auto;

  /// 连播前是否先倒计时
  bool _countdownBeforeNext = true;

  /// 连播是否沿用线路
  ///
  /// ⚠️ 原版这个开关**没有接进任何播放逻辑**（全仓库 grep
  /// `keepSourceOnNext` 只有声明/持久化/面板三处）。我们照抄它的
  /// 完整行为：能存、能读、显示当前值，但**不假装它改变了什么**。
  bool _keepSourceOnNext = true;

  /// 是否自动跳过片头（原版 `prefs.autoSkip`，默认 true）
  bool _autoSkip = true;

  /// 全局音量偏好（原版 `prefs.lastVolume`，默认 1.0）
  double _lastVolume = 1.0;

  /// ★★★ 2026-09-27：用户**上一次真的动手调音量**的时刻
  ///
  /// # 这个字段修的是一个**会改坏用户设置**的真 bug
  ///
  /// ## 现场证据（真机）
  /// ```text
  /// ui-prefs.json 的 dsh.playprefs.lastVolume：**0.75 → 1.0**
  /// 写入时间 2026-09-27 **09:03:20**
  /// 那一刻**没有任何人操作音量** —— 只有我在跑客户端做验证
  /// ```
  ///
  /// ## 根因（已用离线探针证明）
  /// ```text
  /// `_bindPlayerStreams()` 里的监听**无条件**把任何音量广播都当"用户调的"：
  ///     _player.stream.volume.listen((v) {
  ///       if (!_muted && v > 0) _savePlayPref('lastVolume', (v/100).toString());
  ///     });
  ///
  /// ⇒ 而 mpv 在播放器刚创建时会广播它自己的**默认音量 100**
  ///   （`_muted` 默认 false，100 > 0 ⇒ 条件成立）
  /// ⇒ ★ 于是 "1.0" 被写进用户的偏好，而**用户从没碰过音量**
  /// ```
  /// 离线探针逐字输出（`.probe/probe_tests/probe_volume_pref_test.dart`）：
  /// ```text
  /// [PROBE]  两次 set 之后文件 = {"…":"0.75"}   ← 有后续正确值时能自愈
  /// [PROBE2] lastVolume = **1.0**               ← ★ 只要一次假广播就永久覆盖
  /// ```
  ///
  /// ## 为什么判据是「**用户发起的**」而不是「不是我们发起的」
  ///
  /// ```text
  /// 我第一版想用「一次性的 _volumeSetByUs 标记」跳过我们自己的回声，
  /// ★ 但那挡不住 mpv 的**默认广播** —— 它既不是用户调的、也不是我们的回声：
  ///     顺序 A：先收到 100（mpv 默认）⇒ 消费掉标记
  ///             再收到  75（我们的回声）⇒ 标记已失效 ⇒ 写回 0.75 ✓
  ///     顺序 B：先收到  75（我们的回声）⇒ 消费掉标记
  ///             再收到 100（mpv 默认）⇒ ★ 写回 **1.0** ✗
  ///   ⇒ 它**依赖广播顺序** —— 而那是不确定的 ⇒ 脆的修复
  /// ```
  /// ⇒ 改成**白名单**：只有用户在 UI 上真的动过手，才允许写偏好。
  ///   ```text
  ///   用户动手的三个入口（全都会走到 setVolume），但**只有两处盖时间戳**：
  ///     _volumeBy()     键盘 ↑/↓ 与滚轮        ⇒ 盖
  ///     onVolume:       底栏音量滑杆            ⇒ 盖
  ///     _toggleMute()   静音按钮                ⇒ **不盖**（见下）
  ///   ⇒ 监听器只认"最近盖过戳"的广播
  ///   ```
  ///   ⚠️ 旧注释把 `_toggleMute()` 一并列进"三个入口"，却又在它自己的注释里
  ///     写着"这里**不盖**时间戳是刻意的" —— 两处自相矛盾，会误导后来的人。
  ///     以**代码事实**为准：`_toggleMute()` 不盖戳。原因是它恢复的
  ///     "静音前音量"用户并没有重新调过，不该被当成一次用户动作。
  ///
  /// ⚠️ 用**时间窗**（而不是"一次性的布尔"）是因为：
  ///    用户把音量调到**同一个值**时 mpv 幂等、**不发**广播
  ///    ⇒ 布尔标记会一直挂着，把之后某条无关广播误判成用户行为。
  ///    时间窗会自动过期，没有这个残留问题。
  DateTime? _lastUserVolumeAction;

  /// ★★★ 静音前用户真实拥有的音量（缺陷 1 / 11 的修复核心）
  ///
  /// # 错在哪（改之前）
  /// ```text
  /// _toggleMute() 原句： _player.setVolume(_muted ? _volume : 0);
  ///   而 _volumeBy() 在音量归零时会把 _muted 置真，音量监听器也把 _volume 写成 0
  ///   ⇒ 静音之后再点一次，_volume 已经是 0
  ///   ⇒ 实际执行的是 setVolume(0) ⇒ ★ 永远没声音
  ///   ⇒ 而 _muted 却被翻成 false ⇒ 图标显示"未静音"、实际全静音（UI 在说谎）
  ///   唯一能救回来的操作是把底栏音量滑杆拖一下。
  /// ```
  /// # 为什么必须是**独立快照**而不是读 _volume
  /// ```text
  /// _volume 是"当前音量"的镜像，静音时它合法地等于 0
  ///   ⇒ 拿它当"恢复目标"等于把 0 恢复成 0
  /// ⇒ 必须在**压 0 之前**单独记下用户原本的音量。
  /// ```
  /// ⚠️ 静音期间用户拖滑杆要**同步更新**本快照（否则取消静音会恢复到过期值）——
  ///    见音量监听器里 _muted 那条分支与底栏 onVolume 的处理。
  /// ⚠️ 它**不是**偏好：不落盘、不写 lastVolume，只活在本页 State 里。
  double? _volumeBeforeMute;
  // ══════════════════════════════════════════════════════════════════
  // ★★ 缺陷 13：缓冲区间（进度条上"已经下载到哪"）
  // ══════════════════════════════════════════════════════════════════
  //
  // 数据流（单向）：
  // ```text
  // mpv demuxer-cache-time / -duration
  //   -> _BufferPoller（500ms，值变才回调）
  //   -> _bindBufferPoller 的回调里做**交叉校验**
  //   -> setState(_bufferedRange)
  //   -> _BottomBar(buffered:) -> _ProgressSlider 叠一条缓冲条
  // ```

  /// 当前缓冲区间；null = 没有读数（或校验不过）⇒ **不画**
  BufferedRange? _bufferedRange;

  _BufferPoller? _bufferPoller;

  /// mpv 的 `cache-buffering-state`（0..100）；只给探针读，不参与绘制
  double? _bufferStatePercent;

  /// 缓冲条的真实几何（GlobalKey 取 RenderBox）；只给探针用
  final GlobalKey _bufferBarKey = GlobalKey();

  // ══════════════════════════════════════════════════════════════════
  // ★★ 音量下发的**唯一出口**（缺陷 1 / 11 的配套改造）
  // ══════════════════════════════════════════════════════════════════
  //
  // # 为什么要把 setVolume 收敛到一个方法
  //
  // 生产语义**逐字不变**（本方法就是 `_player.setVolume(v)` 的一层转发），
  // 目的是给探针留一个**不改生产行为**的短路点：
  // ```text
  // 探针宿主里 _player 永远建不起来（flutter_test 里没有 libmpv-2.dll）
  //   => 只要走到 _player.setVolume 就是 LateInitializationError
  //   => 静音状态机（_muted / _volumeBeforeMute / 下发值）就无法断言
  // ⇒ 探针把 _probeNoAudio 置真，让"下发"这一步变成可记录的纯标记。
  // ```
  //
  // ⚠️ `_probeNoAudio` 生产恒为 false（没有任何生产代码写它），
  //    所以生产的音量行为与改造前**逐字一致** —— 这不是迁就探针的假实现。
  //
  /// 探针专用：为真时跳过真实下发（★ 生产代码从不写它，恒为 false）
  bool _probeNoAudio = false;

  /// 音量下发的唯一出口（生产 = _player.setVolume 的纯转发）
  void _sendVolume(double v) {
    // ★ 探针短路：只影响测试，生产分支逐字等价于 _player.setVolume(v)
    // ★ 探针打点：记录"实际下发值"，用于断言"取消静音绝不下发 0"
    _probeVolumeWrites.add(v);
    if (_probeNoAudio) return;
    _player.setVolume(v);
  }

  /// 用户动作后，多久内的音量广播算"这次动作的回声"
  static const _kVolumeEchoWindow = Duration(seconds: 2);

  /// 全局倍速偏好（原版 `prefs.lastSpeed`，默认 1.0）
  double _lastRate = 1.0;

  /// 本次会话**是否已经续播过**（防止重复 seek）
  ///
  /// 进入播放页只续播一次；换集/换源走 `_pendingSeek` 那条路（已实现）。
  bool _resumedThisSession = false;

  /// 本次起播的续播 seek **是否已经做过**
  ///
  /// ⚠️ 与 `_resumedThisSession` 是**两件事**，不能合并：
  /// ```text
  /// _resumedThisSession   "读进度这件事做过没有"（在 _prepareResume 里置位）
  /// _resumeSeekDone       "seek 这件事做过没有"（在 _seekAfterReady 里置位）
  /// ```
  /// 合并的后果：`_prepareResume` 置位后 `_seekAfterReady` 会**直接 return**，
  /// 续播永远不执行 —— 那正是本次实测抓到的 bug 的另一种形态。
  bool _resumeSeekDone = false;

  /// 起播代次（每次 `_startPlayback` 自增）
  ///
  /// # 为什么需要
  ///
  /// 续播 seek 是**异步等时长**的（见 `_seekAfterReady`）。用户在这段
  /// 等待里换了线路/切了集，就会有两个 `_seekAfterReady` 同时在跑：
  /// ```text
  /// ① 旧的那个等到时长后 seek 到**上一集的秒数** → 串集
  /// ② 新的那个再 seek 一次 → 画面跳两下
  /// ```
  /// 用代次号作废旧的：`token != _seekToken` 就直接放弃。
  int _seekToken = 0;

  /// hwdec 取证的代次号（每次 `_startPlayback` 自增）
  ///
  /// # 为什么不复用 `_seekToken`
  ///
  /// `_seekToken` 只在**有续播位置时**才自增（见 `_startPlayback` 里
  /// `if (pending != null && ...)` 那一段）。首次进入播放页通常没有
  /// 续播位置 → 它永远停在 0 → 代次保护形同虚设。
  /// hwdec 取证是**每次起播都要做**的，所以需要自己的、无条件自增的代次。
  int _hwdecToken = 0;

  // ═══════════════════════════════════════════════════════════════════
  //  ★★ 起播阶段计时（task-24：用户要「播放提速」，先量化再动手）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么必须先做这一步（而不是直接去改缓冲参数）
  //
  // 用户原话：
  // > 提速我指的是播放视频的时候的提速
  // 即「点开一个源，视频半天起不来 / 播放中卡顿缓冲」。
  //
  // 但「慢」有好几个完全不同的位置，**优化手段也完全不同**：
  // ```text
  // ① resolve_stream 慢     → 插件 JS / 网络请求 → 改 mpv 缓冲【毫无用处】
  // ② mpv open→首帧 慢      → 连接 CDN / 解封装 / 首帧解码
  //                           → 改缓冲【可能有用】，或预连接
  // ③ 流代理额外开销        → 多一跳 + 每请求新建 client
  //                           → 改 mpv 缓冲【毫无用处】
  // ```
  // 不先量就动手 = 猜。项目里已经因此踩过坑（`VERIFY-LESSONS.md` 错误④：
  // 「最像嫌疑人的往往不是真凶」—— `ensureVisible` 背黑锅那次）。
  //
  // # 打点方式
  //
  // 用**单调时钟**（`DateTime.now()` 差值），在关键位置记 `Stopwatch` 分段：
  // ```text
  // t0  用户点播放（_load 进入）
  // t1  resolve_stream / get_live_stream 返回（拿到候选地址）
  // t2  _startPlayback 进入（含 open 之前的所有 await）
  // t3  player.open() 返回（mpv 已 canplay）
  // t4  首个视频帧真的出来（stream.width 首次非空）
  // ```
  // 每段单独打印，**并且**打一行汇总表，方便直接对比慢源/快源。
  //
  // ⚠️ 只在 `PLAYBACK_TIMING=true` 时输出 —— 正式构建零开销、零日志噪音。
  //    与既有的 `kGestureProbe` 同一个模式（见文件末 `_probeLog`）。
  Stopwatch? _bootWatch;

  /// 阶段打点（仅 `PLAYBACK_TIMING=true` 时输出）
  ///
  /// [stage] 是阶段名，[detail] 是补充信息（源名/地址等）。
  /// 时间取自 `_bootWatch`（在 `_load()` 进入时 `start()`）。
  void _bootMark(String stage, [String detail = '']) {
    if (!kPlaybackTiming) return;
    final w = _bootWatch;
    if (w == null) return;
    final ms = w.elapsedMilliseconds;
    debugPrint(
      '[TIMING] +${ms}ms  $stage${detail.isEmpty ? '' : '  ($detail)'}',
    );
  }

  /// 首帧等待的代次号（与 `_hwdecToken` 同一个用途：换流后作废旧等待）
  int _firstFrameToken = 0;

  /// 等**首个视频帧**出来，然后打点（task-24 阶段计时用）
  ///
  /// # 为什么不用 `open()` 返回当"首帧"
  ///
  /// `open()` 返回只说明 mpv **canplay**（可以开始播），
  /// 此时解码器可能还没吐出第一帧 —— 用户看到的仍是黑屏/转圈。
  /// 真正"起来了"是 `stream.width` 首次变成非空（视频参数已知 = 解码链就绪）。
  ///
  /// # 为什么不 await（不阻塞起播）
  ///
  /// 它最多等 30 秒。await 在这里会把 `_loading = false` 一起拖住 ——
  /// 为了打一行日志拖慢起播不值得（与 `_reportHwdecAfterReady` 同一个理由）。
  Future<void> _reportFirstFrame(int token) async {
    if (!kPlaybackTiming) return;
    const step = Duration(milliseconds: 50);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var tick = 0;
    while (DateTime.now().isBefore(deadline)) {
      // 用户换流了 → 这次等待作废（否则会拿新流的时间打"属于上一集"的点）
      if (token != _firstFrameToken || !mounted) return;
      final w = _player.state.width;
      if (w != null && w > 0) {
        final h = _player.state.height;
        _bootMark('④ 首个视频帧', '${w}x$h');
        // 汇总行：一眼能对比慢源/快源
        debugPrint(
          '[TIMING] ★ 起播总耗时 ${_bootWatch?.elapsedMilliseconds}ms '
          '(resolve+open+首帧)',
        );
        return;
      }
      /*
       * ★★ 每 1 秒采一次 mpv 内部状态（task-24 定位"卡在哪"）
       *
       * # 为什么必须采这些（而不是只看总耗时）
       *
       * 总耗时只告诉我们"慢"，**不告诉我们为什么慢**：
       * ```text
       * cache-speed ≈ 0        → 网络没数据（上游慢 / 代理卡住）
       * cache-speed 很大但没帧  → 数据到了但解码/封装慢（moov 在文件尾？）
       * demuxer-cache-duration 在涨 → 在填缓冲（mpv 的 cache-secs 在等）
       * ```
       * 这三种原因的**修法完全不同**，不区分就动手 = 猜。
       */
      if (tick % 20 == 0) {
        await _dumpMpvDiag(tick ~/ 20);
      }
      tick++;
      await Future<void>.delayed(step);
    }
    if (token == _firstFrameToken) {
      _bootMark('④ 首帧超时', '30s 内没出视频帧');
    }
  }

  /// 采样 mpv 内部状态（诊断"卡在哪一段"）
  ///
  /// 只读属性，**不改变任何行为** —— 诊断不能干扰被测对象。
  Future<void> _dumpMpvDiag(int n) async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      Future<String> prop(String k) async {
        try {
          final v = await native.getProperty(k);
          return v.toString();
        } catch (_) {
          return '?';
        }
      }

      final speed = await prop('cache-speed');
      final bufState = await prop('cache-buffering-state');
      final cacheDur = await prop('demuxer-cache-duration');
      final fileFormat = await prop('file-format');
      final paused = await prop('core-idle');
      debugPrint(
        '[TIMING-DIAG #$n] '
        'speed=$speed B/s  buffering=$bufState%  '
        'cacheDur=$cacheDur s  format=$fileFormat  idle=$paused',
      );
    } catch (e) {
      debugPrint('[TIMING-DIAG] 采样失败: $e');
    }
  }

  bool get _isLive => _liveChannelId != null;

  @override
  void initState() {
    super.initState();
    /*
     * ★ 2026-09-26 第二轮：封面初值取自构造参数
     *
     * ⚠️ 必须在 `initState` 里赋值，**不能**写成字段初始化器
     *    `late String? _cover = widget.cover;` —— 那个写法会报
     *    `implicit_this_reference_in_initializer`（实测 analyze 报过）。
     */
    _cover = widget.cover;
    /*
     * ★ 把当前 state 登记给探针（2026-09-25）
     *
     * 交付实测要断言「单击左右半屏**播放位置没有跳变**」——
     * 那就必须能读到**真实播放页**的 `_position`，而不是重新 new 一个
     * 播放器自己测自己（那是测影子，不是测真实路径）。
     *
     * 登记是**幂等**的：同时只可能有一个播放页在树上（路由是全屏 push）。
     */
    _livePlayerState = this;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 硬件层键盘兜底（task-42，用户点名要的键位）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 然后播放页面要支持空格暂停/播放,enter 和 双击 进入/退出 全屏
     *
     * # 为什么需要（真机实测抓到的，不是推测）
     * ```text
     * 真机（SendInput 自检 ==2、前台断言 True）：
     *   键盘 空格/Enter/F/J/L ⇒ **0 条** [PLAYER-KEY]
     *   鼠标双击              ⇒ ★ 有效（[PLAYER-KEY] 双击 ⇒ 切换全屏，
     *                               窗口 1328x848 → 2608x1488 真全屏）
     *   ★ 而**全局 handler 收到了键**（直播页的 [LIVE-KEY] ⓪ 入口有打点）
     * ⇒ 结论：键**进了 Flutter**，但本页 `Focus(onKeyEvent: _onKey)` **收不到**
     * ```
     * # 根因（与直播页**完全同形**）
     * ```text
     * 用户是从**直播页/详情页 push 进来**的 ⇒ 焦点可能仍留在**上一页**
     * （底栏 tab / 列表格子）。
     * ★ Flutter 按键派发 = 从 `primaryFocus` 沿**祖先链**向上冒泡 ⇒
     *   上一页的焦点与本页的 `Focus` 是**兄弟**关系 ⇒ `_onKey` 永不调用。
     * ```
     *
     * # 修法：`HardwareKeyboard.addHandler`
     * ```text
     * 它在**焦点树之前**跑 ⇒ 不依赖焦点在哪。
     * ★ 这是我在直播页验证过的同一个修法（那边日志证明有效）。
     * ```
     *
     * # ⚠️ 三道门控（**不能省**，见 `_onHardwareKey` 的实现）
     * ```text
     * ① 弹窗/浮层全关（本页自己的浮层优先）
     * ② 本页必须是**最上层路由**（ModalRoute.isCurrent）
     *    ★ 这条同时解决"与直播页的 handler 抢键"：
     *      直播页被 push 覆盖后 `isCurrent == false` ⇒ 它自己让路
     * ③ 输入框里打字时放行
     * ```
     * ⚠️ **不**依赖 `widget.visible` 那种"上游给的值"作主判据 ——
     *    task-42 的事故（`_liveVisible` 被变异冻住）证明了它会失真。
     *
     * # ★★★ 为什么是 `addEarlyKeyEventHandler` 而不是 `addHandler`（2026-09-25 修）
     *
     * ```text
     * `HardwareKeyboard.addHandler` 的返回值**不会中止派发** ——
     * 事件照样继续流到 `FocusManager` → 焦点树。
     * （`shell.dart` L1953 逐字记录过这个坑，我一开始没读到。）
     *
     * ★ 直播页就因此中了招：一次按键 ⇒ 硬件路径 + 焦点路径**都**处理
     *   ⇒ 切两个台（真机日志铁证：一次 `⓪ 入口` 却两次 `cycleChannel`）。
     *
     * ★ 本页**当时没有**双触发 —— 因为我加了 `_focusIsInsideThisPage` 守卫
     *   让两条路径互斥。但那是**逻辑性保证**（靠条件写对），
     *   而 early handler 是**结构性保证**（机制上不可能重复处理）。
     * ⇒ 按"优先用机制排除、而不是用条件排除"的原则，改用 early handler。
     *   守卫**保留**（它仍有价值：判断"该不该我兜底"），
     *   但即使守卫将来被改坏，也不会出现双触发。
     * ```
     */
    FocusManager.instance.addEarlyKeyEventHandler(_onEarlyKey);

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 把播放页的两个能力交给局域网遥控（2026-09-25 —— task-14 F）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 修之前：遥控的播放控制**整条链路是断的**
     *
     * ```text
     * PlayerBridge { getState(), exec(cmd) }   ← 播放页该交出的两个能力
     * RemoteBridge.setPlayer(b)  remote_bridge.dart:283   ★ 全仓库零调用
     * ⇒ _player == null
     * ⇒ 手机端 14 条命令全部被丢弃（落到「没有播放器」分支）：
     *    toggle_play / prev_episode / next_episode / goto_episode / seek /
     *    seek_to / switch_source / set_volume / toggle_mute /
     *    skip_config_open / skip_preview / skip_confirm / skip_clear /
     *    skip_toggle_auto
     * ⇒ 而且手机端**选集面板永远不显示**（episodes 恒为空）
     * ```
     * 用户看到的就是「手机上点了没反应」。
     *
     * # 为什么在 `initState` 注册
     *
     * 播放页是**全屏 push 的路由**，同一时刻只可能有一个在树上 ——
     * 所以"注册"天然是幂等的，不需要引用计数。
     * 放在这里（而不是 `build`）的理由与 [RemoteBridgeHost] 一致：
     * `build` 会被主题切换等触发**多次**，每次都注册会不停重置桥的
     * `_lastSig`（心跳去重失效 → 上报次数暴涨，正是原版"卡顿"的成因）。
     *
     * ⚠️ 这里**不 await**、也**不读 `context`** —— `initState` 里读
     *    `MediaQuery` 之类是不安全的（本项目 `primeFocusSoon` 那类坑）。
     *    桥只保存闭包，真正取值发生在它自己的 tick 里（那时早就建好了）。
     */
    _remotePlayerBridge = PlayerBridge(
      getState: _remoteGetState,
      exec: _remoteExec,
    );
    RemoteBridge.instance.setPlayer(_remotePlayerBridge!);
    /*
     * 真机实测取证：把**播放页自己那个** GestureDetector 的实际挂载状态
     * 打进日志（`GESTURE_PROBE=true` 时）。
     *
     * ⚠️ 这里读的是**刚构建出来的** widget —— 但 `initState` 时还没 build，
     *    所以延到首帧后读（见 `_probeGestureMount`）。
     */
    WidgetsBinding.instance.addPostFrameCallback((_) => _probeGestureMount());

    /*
     * ★ 收起自绘标题栏（2026-09-24）
     *
     * 对齐原版 `.titlebar.is-hidden`（`App.vue` 里 `route.name === "player"`
     * 时置 hidden）：
     * ```css
     * .titlebar.is-hidden { opacity: 0; transform: translateY(-100%);
     *                       pointer-events: none; }
     * ```
     * 原版注释解释理由：
     * > 需求是「播放不默认全屏」，但播放时仍应最大化利用空间 ——
     * > 隐藏这条栏就是最直接的做法（返回按钮在播放器自己的顶栏里）。
     *
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 但桌面端**不能照抄这条**（2026-09-24 用户纠正）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 播放器页面没有顶部的那个可拖动 缩小 放大 关闭的那个操作条,
     * > 影响体验,在桌面端播放页面 无法拖动窗口
     *
     * # 为什么原版能隐藏、我们不能
     *
     * 原版是 **WebView 里的网页**，它的"窗口"由 Tauri 管：
     * ```text
     * 原版：标题栏隐藏后，Tauri 的原生窗口**仍然可拖**
     *       （用户还能拖系统装饰区 / Alt+Space 菜单 / Win+方向键）
     * 我们：标题栏就是**唯一**的拖动区（titleBarStyle: hidden 去掉了系统标题栏）
     *       → 隐藏它 = 窗口彻底拖不动
     * ```
     * 也就是说原版隐藏的只是一条**视觉条**，而对我们来说那是**功能条**。
     *
     * ⚠️ 我上一轮的错误：看到用户说「详情页**和播放页**都没有操作条」，
     *    修好了详情页，却给播放页加了主动隐藏 —— **恰好把用户要的拿掉了**。
     *    用户的诉求是「**要**操作条」，不是「不要」。
     *
     * # 所以：保持显示
     *
     * 播放页的 `_TopBar`（返回/标题/提示）在**内容区**顶部，
     * 与窗口标题栏不冲突 —— 一个管窗口、一个管播放。
     * 想要沉浸看片用「全屏」（见 `_toggleFullscreen`）。
     */
    // titleBarVisible 保持 true（不隐藏）—— 桌面端必须留可拖动区。

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 但要把它压暗 —— 修用户报的「进播放页还是上面会闪出来白条」
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 进入播放页还是上面会闪出来白条
     * > 我觉得……那个白条可能跟顶部的自定义操作条有关系,
     * > 然后吧 其实还有点丑
     *
     * ★ 用户的猜测**是对的**。实测（`.probe/real_player_capture.py`）：
     * ```text
     * 首页标题栏  #e7eaf2 / #e8ebf3   ← 浅色液态玻璃
     * ```
     * 标题栏挂在 `MaterialApp.builder`（`Navigator` **之外**），
     * 所以它**永远压在所有路由之上**。播放页背景是纯黑
     * （`Scaffold(backgroundColor: Colors.black)`），
     * 于是顶部那条 40px 的**浅色玻璃**就成了用户看到的"白条"。
     *
     * # 为什么不能像原版那样隐藏
     *
     * 原版 `TitleBar.vue`：`hidden.value = route.name === 'player'`。
     * 但原版是 WebView，窗口由 Tauri 管，隐藏后**仍可拖**。
     * 我们 `titleBarStyle: hidden` 去掉了系统标题栏 ——
     * 这条标题栏是**唯一**的拖动区（上面 602-604 行记录的用户原话
     * 就是为这件事纠正的）。
     *
     * ⇒ **保留功能、压暗颜色**：还能拖 / 最小化 / 最大化 / 关闭，
     *    但视觉上与黑色播放页融为一体。
     *
     * ⚠️ **必须与 `dispose` 成对**（见下面 dispose 里的复位）——
     *    漏了的话返回首页后标题栏一直是黑的。
     */
    titleBarDark.value = true;

    /*
     * ⚠️ 硬解必须在 Player 创建**之后**用 setProperty 设置
     *
     * `PlayerConfiguration` **没有** hwdec 字段（实测确认）。
     * 不设置的话 Android 上默认**不开硬解** ——
     * 表现是 HEVC 软解，CPU 跑满、4K 卡顿。
     */
    _player = Player(
      configuration: const PlayerConfiguration(
        /*
         * ★ `libass: true` 是 ASS 字幕开关
         *
         * media_kit **默认关闭**。我们的源大量用 ASS（带样式/特效），
         * 不开的话字幕完全不显示（不是显示得不好看，是**没有**）。
         *
         * ⚠️⚠️ Android 上光开这个**不够**（2026-09-23 实测抓到）
         *
         * media_kit 的文档原文：
         * > On Android, this option requires [libassAndroidFont] to be set.
         *
         * 源码（`real.dart` L2328）的条件是**三个都要**：
         * ```dart
         * if (Platform.isAndroid &&
         *     configuration.libass &&
         *     configuration.libassAndroidFont != null &&
         *     configuration.libassAndroidFontName != null) { ... }
         * ```
         * 不满足时它**什么都不做** —— 而 mpv 在 Android 上默认
         * 拿不到系统字体（fontconfig 不生效），所以 **libass 渲染失败**。
         *
         * 实测表现（Android 上）：
         * ```text
         * 编码: hevc 1920x1080        ← 视频正常
         * 字幕轨 2 条                 ← 轨道能枚举
         * ★ 字幕真的在渲染（读到文本）✗ ← 但屏幕上没有字
         * ```
         *
         * # 为什么不 bundle 一个中文字体
         *
         * ```text
         * ① 体积：最小的中文字体 SimsunExtG.ttf 也要 3.4 MB，
         *    而硬指标③要求 Android 包尽量小
         * ② 授权：Windows 自带的 msyh/simhei/simsun 是**微软专有字体**，
         *    不能随应用分发
         * ```
         *
         * # 解法：用 Android 自带的 NotoSansCJK
         *
         * 实测确认系统里有：
         * ```text
         * /system/fonts/NotoSansCJK-Regular.ttc
         * /system/fonts/NotoSerifCJK-Regular.ttc
         * ```
         * 那是 **Apache 2.0** 授权，且已经在设备上 ——
         * 零体积增量、零授权风险。
         *
         * 通过 `libassAndroidFontName` 让 mpv 用这个名字找字体
         *（注意：要的是**字体名**，不是文件名）。
         */
        libass: true,
        // 缓冲调小一点，直播换台更快
        bufferSize: 32 * 1024 * 1024,
      ),
    );
    _controller = VideoController(_player);

    /*
     * ★ 连播策略 / 音量倍速偏好 —— 必须在起播**之前**读出来
     *
     * 原版在创建 ArtPlayer 时就带上偏好（`PlayerView.vue:3434`）：
     * ```ts
     * volume: prefs.lastVolume ?? 1,
     * ```
     * 起播后再设会有一个"先满音量再变小"的突跳，用户能听出来。
     */
    _loadPlayPrefs();
    _loadDanmakuPrefs();

    _setHwdec();
    _bindPlayerStreams();
    _initPip();
    /*
     * ★ 取当前站点的显示名（task-32）
     *
     * 走本地注册表（无网络），与起播**并行** —— 不 await，不阻塞首帧。
     * 拿不到就不渲染那个 pill（不是渲染空的）。
     */
    unawaited(_loadProviderName());

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-12 ④（2026-10-09）：本地文件**短路** —— 完全不调 `_load()`
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须在这里短路（而不是在 `_load()` 里加分支）
     * ```text
     * `_load()` 是唯一生产起播入口，且**无条件**走
     *   `SourinApi.resolveStream` -> Rust `playback.rs:160-164 registry.route()`
     * 本地文件没有 provider 可路由 => 必然报「无法路由: local:...」。
     *
     * 而 `_load()` 里 `final List<StreamCandidate> list;` 是**确定赋值**结构，
     * 在里面插第三支 = 改那个 if/else 的**形状**（那是我刚收完 task-8 的地方）。
     * ⇒ 在这一层短路 => `_load()` 的字节**一行不动** => 零冲突、零回归风险。
     * ```
     *
     * # ★ 判据是「真的没调」，不是「调了但提前 return」
     * ```text
     * 后者（提前 return）仍会走完 `_bootWatch` / `setState(_loading=true)` 那一串，
     * 而且更重要的是：**`resolveStream` 会被执行** => 断网/无 provider 时照样报错。
     * ⇒ 验收里那条「断网也能播」查的就是这一点。
     * ```
     *
     * # 为什么用 `widget.provider` / `widget.id` 而不是自己判
     * ```text
     * `shell.dart:4758-4759` 已经保证了：
     *   有旁文件 => provider = 站点 id，id = 站点 contentId（走在线）
     *   没旁文件 => provider = **'local'**（kLocalProvider），id = 规范化路径
     * ⇒ 「走在线还是走本地」这个裁决**在 shell 已经做完**，本页**不再重判**
     *   （重复实现必然两边不一致）。`_provider`/`_contentId` 的 late 初值
     *   （:1049-1050）本来就取自 widget => 拿到 local 就会走 local 命名空间。
     * ```
     *
     * # ★★ 为什么进度能落 `local` 命名空间（不需要额外代码）
     * ```text
     * `_provider`/`_contentId` 是 state 字段（:1049-1050 从 widget 取初值），
     * `_prepareResume` 读 `getProgress(_provider, _contentId)`、
     * `_saveProgress` 写同一对 => 读写**自动**都在 local 空间。
     * ⇒ 在线作品的进度不会被污染（反向控制那条验收查这个）。
     * ```
     */
    if (widget.localPath != null) {
      /*
       * 时序：与 `_load()` 的同步段保持一致（`_bootWatch` 必须在首个 await 前）。
       * ⚠️ 这里**只**做「起播」，不做 `resolveStream`。
       */
      _bootWatch = Stopwatch()..start();
      _bootMark('① 点播放', '本地文件 $_provider/$_contentId');
      setState(() {
        _loading = true;
        _error = null;
        _errorKind = null;
        _sawFirstFrame = false;
        _playbackFailure = null;
      });
      unawaited(_bootLocalFile());
    } else {
      // ← 原来那行（现在是 else 分支）——**逐字节不变**
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  /// ★★★ task-12 ④：本地文件的起播路径（`initState` 短路后走这里）。
  ///
  /// 与 `_load()` 的差别只有**取候选地址**那一步：
  /// ```text
  /// _load()      ：resolveStream(provider, contentId)  ← 走网络 + 插件 JS + 路由
  /// _bootLocalFile：StreamCandidate(url: file://...)   ← 零网络，mpv 原生吃 file://
  /// ```
  /// 之后的 `_prepareResume()` -> `_startPlayback()` -> `_loadSkipMarker()`
  /// **同一套**（续播/首帧/跳过片头全部复用，不手抄副本）。
  ///
  /// # ★★ task-12 ④ 改动 B：为什么要接受 [path] 参数
  /// ```text
  /// 有**两条**路会走到本地起播：
  ///   ① 进页面就播（`initState` 短路）—— 路径来自 `widget.localPath`（构造期）；
  ///   ② 页内**换集/换文件**（`applySession`）—— 路径来自 `req.localPath`（后到的请求）。
  /// 第 ② 条发生在页面**已经建好之后**，读 `widget.localPath` 会永远拿到「进来那一集」。
  /// ⇒ 让本方法接受一个路径，两条路共用**同一份实现**
  ///   （不手抄副本 —— 抄一份就必然有第二处要同步维护）。
  /// ```
  ///
  /// ⚠️ 默认值取 `widget.localPath`：调用方只在「换到另一个本地文件」时才需要显式传。
  Future<void> _bootLocalFile({String? path}) async {
    final filePath = path ?? widget.localPath;
    // ① 换集那条路可能传 null（切换回在线）—— 调用方应自己分流，这里防御性兜住
    if (filePath == null) return;
    try {
      /*
       * ★ 判据：`models.dart:822` 的 isPlayable 只判 `!drmProtected && url.isNotEmpty`
       *   => file:// 天然过闸，不需要任何特殊处理。
       * ⚠️ drmProtected 默认 false（StreamCandidate 的默认值）。
       */
      final candidate = StreamCandidate(
        url: Uri.file(filePath).toString(),
        kind: 'local',
      );
      _bootMark('② 拿到候选地址', '1 条 · 首条 playable=${candidate.isPlayable}');
      if (!mounted) return;
      setState(() => _streams = <StreamCandidate>[candidate]);

      /*
       * ⚠️ 顺序与 `_load()` 一致：`_prepareResume` 必须在 `_startPlayback` 之前
       *    —— 后者会消费 `_pendingSeek`，放到后面等于「先从头播再跳」（画面会闪回去）。
       */
      await _prepareResume();
      await _startPlayback(candidate);
      await _loadSkipMarker();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _errorKind = _kindOf(e);
          _loading = false;
          _playbackFailure = null;
        });
      }
    }
  }

  /// 取当前站点的显示名（task-32）
  ///
  /// ⚠️ 换源后会再次调用（`_provider` 变了）—— 见 `_switchSource`。
  Future<void> _loadProviderName() async {
    final id = _provider;
    final n = await providerDisplayName(id);
    /*
     * ★ 代次保护：换源是**异步**的，两次调用可能乱序返回。
     *   用"发起时的 id 是否仍是当前 id"作判据 —— 过期的那次直接丢弃，
     *   否则顶栏可能停在旧站名（本项目在 `_seekAfterReady` 踩过同类坑）。
     */
    if (!mounted || id != _provider) return;
    setState(() => _providerName = n);
  }

  /// 从 [UiPrefs] 读连播策略 / 音量 / 倍速
  ///
  /// # 为什么用 UiPrefs 而不是新加一个存储
  ///
  /// 原版这些偏好存在 localStorage 的 `dsh.playprefs` 里，
  /// 理由是（原版 `stores/player.ts` 注释）：
  /// > 这些是**播放器专属**的用户偏好，页面切换/会话切换都不该重置。
  ///
  /// 我们的对应物就是 `UiPrefs`（`core/ui_prefs.dart`，同样是
  /// "纯前端偏好 → JSON 文件"）。**不新增依赖、不新增存储层**。
  ///
  /// ⚠️ 键名沿用原版语义（`dsh.playprefs.*`）而不是照抄原版的
  ///    "整个对象塞进一个 key" —— 我们这边没有 JSON 嵌套读取的便利。
  void _loadPlayPrefs() {
    final end = UiPrefs.get('dsh.playprefs.endAction');
    _endAction = PlayEndAction.values.firstWhere(
      (a) => a.wire == end,
      // 白名单校验：localStorage/文件可能被旧版本写坏，
      // 非法值会让"播放完"什么都不做（原版同样做了白名单校验）
      orElse: () => PlayEndAction.autoNext,
    );
    _countdownBeforeNext =
        UiPrefs.get('dsh.playprefs.countdownBeforeNext') != '0';
    _keepSourceOnNext = UiPrefs.get('dsh.playprefs.keepSourceOnNext') != '0';
    _autoSkip = UiPrefs.get('dsh.playprefs.autoSkip') != '0';

    final v = double.tryParse(UiPrefs.get('dsh.playprefs.lastVolume') ?? '');
    // 范围校验（原版同样做了：0–1 之外的值会让播放器静音或爆音）
    _lastVolume = (v != null && v >= 0 && v <= 1) ? v : 1.0;

    final r = double.tryParse(UiPrefs.get('dsh.playprefs.lastSpeed') ?? '');
    // 原版的合法区间是 0.25–4
    _lastRate = (r != null && r >= 0.25 && r <= 4) ? r : 1.0;

    /*
     * ★★★ task-22 P2-9：解码模式（偏好里存的是 mpv 的 `wire` 字符串）
     *
     * `HwdecMode.fromWire()` 内部就是白名单校验：读不到 / 写坏了 → auto。
     * 注意这里**只恢复状态**，真正的下发在 `_setHwdec()`（它每次起播都跑）。
     */
    _hwdecMode = HwdecMode.fromWire(UiPrefs.get('dsh.playprefs.hwdecMode'));

    /*
     * ★★★ task-22 P1-11：画面缩放百分比
     *
     * 范围校验 50–200（与底栏滑条的量程一致）：
     * 越界值会让画面缩到看不见或糊成一团，属于「偏好被写坏」。
     */
    final z = double.tryParse(UiPrefs.get('dsh.playprefs.videoZoom') ?? '');
    _videoZoomPct = (z != null && z >= 50 && z <= 200) ? z : 100;

    // 起播即生效（与上面的注释对应）
    /*
     * ⚠️ **不**盖 `_lastUserVolumeAction` —— 这是**我们**发起的，
     *    不是用户调的（见 `_lastUserVolumeAction` 的长注释）。
     *    mpv 的默认音量广播会在这之后到达，它会被白名单挡掉 ⇒ 不写偏好。
     */
    _sendVolume(_lastVolume * 100);
    if (_lastRate != 1.0) _player.setRate(_lastRate);
  }

  /// 把一个偏好写回 [UiPrefs]
  void _savePlayPref(String key, String value) {
    UiPrefs.set('dsh.playprefs.$key', value);
  }

  /// 读弹幕偏好（dsh.danmaku.*，键与范围见 core/danmaku.dart 的 DanmakuConfig）
  ///
  /// 与 _loadPlayPrefs 同一原则：**起播前**读出来，起播后再改会有突跳。
  void _loadDanmakuPrefs() {
    _danmakuEnabled = DanmakuConfig.enabled;
    _danmakuSettings = DanmakuSettingsState.fromPrefs();
  }

  /// 配置硬件解码（**只配置，不读值**）
  ///
  /// # 各平台后端不同（实测确认）
  ///
  /// ```text
  /// Windows  d3d11va      实测 hwdec-current = "d3d11va-copy"，CPU 0.06 核
  /// Android  mediacodec   真机有硬件 HEVC 解码器时可用
  /// macOS    videotoolbox
  /// ```
  /// 用 `auto-safe` 让 mpv 自己挑 —— 它会在硬解不可用时**安全回退**到软解，
  /// 而不是像 `auto` 那样可能选到不稳定的组合。
  ///
  /// # ⚠️ 这里**不再**读 `hwdec-current`（2026-09-24 修的真 bug）
  ///
  /// 本函数在 `initState` 里调用，此刻**还没有 open()** ——
  /// `hwdec-current` 是 mpv 的**运行时属性**，没有媒体/解码器时它是
  /// **空字符串**。原先在这里读，日志永远是：
  /// ```text
  /// [PLAYER] hwdec-current =          ← 空的，等于没有硬解证据
  /// ```
  /// 「设置 hwdec」是**配置**，越早越好（open 之前设才对）；
  /// 而「读 hwdec-current」是**取证**，必须等解码器真的建起来。
  /// 两件事被混在一个函数里，就是本 bug 的根因。
  /// 读取挪到 [_reportHwdecAfterReady]。
  Future<void> _setHwdec() async {
    try {
      final native = _player.platform;
      if (native is NativePlayer) {
        /*
         * ★★★ task-22 P2-9：解码模式
         *
         * `auto` 这一支**必须**保留字面量 `auto-safe` —— 它同时被
         * `test/hwdec_timing_test.dart:167` 与 `test/skip_marker_test.dart:482`
         * 逐字断言（那是配置，不是取证）。其余三档直接用档位表里的
         * `wire`（HW+ → `auto` / HW → `auto-copy` / SW → `no`）。
         *
         * ⚠️ 这里**只下发、不回读** —— 回读 `hwdec-current` 属于取证，
         *    必须留在 `_reportHwdecAfterReady()`（它跑在 `open()` 之后）。
         *    把两件事混在一处就是硬指标①记的那个根因。
         */
        if (_hwdecMode == HwdecMode.auto) {
          await native.setProperty('hwdec', 'auto-safe');
        } else {
          await native.setProperty('hwdec', _hwdecMode.wire);
        }

        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 允许跨源播放列表 —— 修任务⑰⑧「直播黑屏」的第 2 个原因
         * ══════════════════════════════════════════════════════════════
         *
         * # 怎么发现的（实测，先修好 Referer 之后仍然黑屏）
         *
         * 用**真实 Player** 播央视标清线路，把 `stream.error` / `stream.log`
         * 打出来：
         * ```text
         * PLAYER-ERROR Refusing to load potentially unsafe URL from a playlist.
         * PLAYER-ERROR Use the --load-unsafe-playlists option to load it anyway.
         * PLAYER-LOG   lavf: avformat_open_input() failed
         * PLAYER-STATE duration=0 position=0 buffering=true    ← ★ 黑屏
         * ```
         * 也就是说央视的 `.m3u8` **主播放列表**里引用了**另一个主机**上的
         * 子播放列表 —— mpv 认为"播放列表引用了外部 URL"**不安全**，
         * 默认**拒绝加载**。
         *
         * # 为什么必须开（而不是"保持默认更安全"）
         *
         * ```text
         * 流地址来自**用户自己安装的插件**（cctv.js 等），
         * 本来就是要播放任意第三方 CDN 的内容 ——
         * 不开这个选项等于"所有走主/子播放列表的直播全废"。
         * 这里没有引入新的信任边界：插件本来就能返回任意 URL。
         * ```
         *
         * # 实测效果（同一条央视 URL）
         *
         * ```text
         * 不开 → Refusing to load potentially unsafe URL  （卡死，黑屏）
         * 开了 → 该报错消失，继续去解析子播放列表
         *        （后面若还失败，是**另一层**原因，见下）
         * ```
         *
         * ⚠️ 它**不是万能药**：开了之后央视这条继续走到
         *    `Cannot open file '/ldcctvwbnd/ldcctv1_2_hd.m3u8'` ——
         *    那是该 CDN 返回了**主列表内嵌的绝对路径**，
         *    属于上游/网络层面的问题（本机到该 CDN 也不稳定）。
         *    如实记录，不把它说成"已完全修好"。
         */
        await native.setProperty('load-unsafe-playlists', 'yes');
        debugPrint('[PLAYER] mpv: hwdec=auto-safe, load-unsafe-playlists=yes');
      }
    } catch (e) {
      debugPrint('[PLAYER] 设置 hwdec 失败（回退软解）: $e');
    }
    await _setSubtitleFont();
    // ★ ④：每次起播都把「缓存上限」真正下发到 mpv。
    //   放在这里（`_setHwdec()` 末尾）是因为它是**唯一**每次起播都跑的
    //   初始化点（`initState` :1569 调用，与 `_bindPlayerStreams()` 并列）。
    //   不调它的话，用户在设置页拖滑杆只会改到磁盘上的偏好值，
    //   mpv 仍用构造期的 `bufferSize`（:1552 32MB）和它自己的默认
    //   `cache-dir`（不在 <dataDir>\mpv-cache 里，我们清不掉）。
    await _applyMpvCacheSettings();
    /*
     * ★★★ task-22 P1-11：画面缩放同样是**逐文件**属性
     *
     * mpv 的 `video-zoom` 在换文件时会复位 ⇒ 必须在每次起播时重新下发。
     * 放在这里与 `_applyMpvCacheSettings()` 同理：`_setHwdec()` 是**唯一**
     * 每次起播都跑的初始化点（`initState` 调用，与 `_bindPlayerStreams()` 并列）。
     */
    await _applyVideoZoom();
  }

  /// ④ 把「缓存上限」写进 mpv 的解复用缓存属性（片段缓存之外的第二个落点）
  ///
  /// # 为什么构造期传值不够，必须运行时再设一遍
  ///
  /// `PlayerConfiguration.bufferSize` 确实会映射到 mpv 的
  /// `demuxer-max-bytes` / `demuxer-max-back-bytes`（media_kit
  /// `real.dart:2425-2426`），但那张属性表**只在 `Player.open()` 里
  /// 应用一次**（`real.dart:2445-2446`）。用户在设置页拖完滑杆时
  /// 播放器**早就活着**了 —— 构造期传值管不到，必须 `setProperty`
  /// 再来一次。
  ///
  /// # 为什么用 demuxer-max-bytes 而不是 bufferSize
  ///
  /// 同一条实测：`bufferSize` 只是那两个属性的**来源**，改 `bufferSize`
  /// 需要重建 Player（正在播的片子会断）；`setProperty` 是运行时接口。
  ///
  /// # 失败怎么办
  ///
  /// `setProperty` 的返回值被 media_kit **丢弃**（`real.dart:1223-1246`），
  /// 设不进去**不会抛异常**。所以这里只负责「把值发出去」，真正的判据
  /// 是 `_readMpvCacheSettings()` 的回读 —— 读不到（空串）就是失败，
  /// **不猜**。
  Future<void> _applyMpvCacheSettings() async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      final dir = await ClipDownloader.mpvCacheDir();
      final props = ClipDownloader.mpvCacheProperties(dir);
      for (final p in props) {
        await native.setProperty(p.$1, p.$2);
      }
      final parts = <String>[];
      for (final p in props) {
        parts.add('${p.$1}=${p.$2}');
      }
      // 顺手报一下这个目录当前多大 —— 只读，不改变行为
      final used = await ClipDownloader.mpvCacheBytes();
      debugPrint(
        '[PLAYER] mpv 缓存属性已下发: ${parts.join(', ')}'
        '（目录现占 ${ClipDownloader.humanBytes(used)}）',
      );
    } catch (e) {
      debugPrint('[PLAYER] 下发 mpv 缓存属性失败: $e');
    }
  }

  /// ★★★ task-22 P2-9：把**当前**解码模式下发给 mpv（用户切档时走这条）
  ///
  /// 为什么不复用 [_setHwdec]：那一个被 `test/hwdec_timing_test.dart`
  /// 逐行审计（「配置与取证必须分离」），而且它一次要下发 `hwdec` /
  /// `load-unsafe-playlists` / 字幕字体 / 缓存属性四组东西。
  /// 切档只需要动**一个**属性，所以另开一条：
  Future<void> _applyHwdecToMpv() async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      await native.setProperty('hwdec', _hwdecMode.wire);
      debugPrint('[PLAYER] mpv: hwdec=${_hwdecMode.wire}（${_hwdecMode.label}）');
    } catch (e) {
      debugPrint('[PLAYER] 切换解码模式失败: $e');
    }
  }

  /// ★★★ task-22 P1-11：把当前缩放百分比下发到 mpv 的 `video-zoom`
  ///
  /// `video-zoom` 是**逐文件**属性（换文件时 mpv 会复位）⇒ 除了切档/拖条，
  /// 每次起播也要重新下发（见 `_setHwdec()` 末尾与 `_startPlayback()`）。
  Future<void> _applyVideoZoom() async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      // 100% ⇒ 0.000000，写下去等价于「复位」（mpv 的默认就是 0）
      final v = videoZoomToMpv(_videoZoomPct).toStringAsFixed(6);
      await native.setProperty('video-zoom', v);
      debugPrint('[PLAYER] mpv: video-zoom=$v（${_videoZoomPct.round()}%）');
    } catch (e) {
      debugPrint('[PLAYER] 下发画面缩放失败: $e');
    }
  }

  /// 回读 mpv 的 `video-zoom`，换算回百分比
  ///
  /// ⚠️ 读不到 ⇒ **不改** `_videoZoomPct`（面板/底栏显示「读不到」）——
  ///    与 `_readMpvStyle()` 同一条规矩：读不到就说读不到，不塞猜测值。
  Future<void> _readVideoZoom() async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      final s = await native.getProperty('video-zoom');
      final v = double.tryParse(s.trim());
      if (v == null) return;
      final pct = (100 * math.pow(2, v)).toDouble().clamp(50.0, 200.0);
      if (!mounted) return;
      setState(() => _videoZoomPct = pct.toDouble());
    } catch (e) {
      debugPrint('[PLAYER] 读画面缩放失败: $e');
    }
  }

  /// ★★★ task-22 P1-11：改画面缩放（百分比，50–200）
  ///
  /// 两个入口共用同一个落点：
  /// ```text
  /// ① 设置面板的预设档位（点一下，save = true）
  /// ② 底栏长按浮层的滑动条（拖动中 save = false，松手才 save = true）
  /// ```
  ///
  /// 为什么拖动中不写偏好：一帧一次 `UiPrefs.set` 会在一次拖动里写几十次
  /// （`UiPrefs` 的落盘是 300ms 合并的，但那仍然是几十次无意义的脏标记）。
  void _setVideoZoom(double pct, {bool save = true}) {
    final v = pct.clamp(50.0, 200.0).toDouble();
    if (v != _videoZoomPct) setState(() => _videoZoomPct = v);
    unawaited(_applyVideoZoom());
    if (save) _savePlayPref('videoZoom', v.round().toString());
  }

  /// ★★★ task-22 P2-9：切解码模式（设置面板点档位时调）
  ///
  /// 偏好里存的是 mpv 的取值（`auto-safe` / `auto` / `auto-copy` / `no`）——
  /// 与 `PlayEndAction` 一样存 `wire` 而不是下标，档位表以后加档也不会读串。
  void _setHwdecMode(HwdecMode m) {
    if (m == _hwdecMode) return;
    setState(() => _hwdecMode = m);
    _savePlayPref('hwdecMode', m.wire);
    unawaited(_applyHwdecToMpv());
  }

  /// 回读 mpv 的三个缓存属性（原始串），诊断与探针共用
  ///
  /// ★ 判据：`getProperty` 读不到时 media_kit 返回**空串**且**不抛**
  /// （`real.dart:1278`）⇒ 空串一律如实记为空串，绝不把「没读到」
  /// 当成「设对了」。解析交给 `ClipDownloader.parseMpvByteSize`。
  Future<Map<String, String>> _readMpvCacheSettings() async {
    final out = <String, String>{};
    final native = _player.platform;
    if (native is! NativePlayer) return out;
    for (final k in ClipDownloader.kMpvCacheKeys) {
      try {
        final raw = await native.getProperty(k);
        out[k] = raw;
      } catch (_) {
        out[k] = '';
      }
    }
    return out;
  }

  /// 等**解码器真的建起来**之后再读 `hwdec-current` 并打印
  ///
  /// # 为什么不能"挪到 open() 之后读一次"就完事
  ///
  /// `await _player.open(...)` **返回 ≠ 解码链就绪**。实测（本次交付
  /// 同一批 bug）：`open()` 返回时 `duration` 还是 0，解码器也还没选好。
  /// 所以固定的"open 之后读一次"很可能**依然是空字符串**。
  /// 同类问题在 [PlayerPage] 里已有一处：见 `_seekAfterReady` 的注释
  ///（seek 发太早会被加载复位吃掉）。
  ///
  /// # 就绪信号的选择
  ///
  /// ```text
  /// videoParams 有值    ← 首选：视频轨已解析、解码器已选定
  ///                      （mpv 的 video-params 在解码器初始化后才填充）
  /// ```
  /// 不用 `duration > 0`：音频流的 duration 先于视频解码器就绪，
  /// 那样可能在 `hwdec-current` 还是空的时候就误判"已就绪"。
  ///
  /// # 参数与边界
  ///
  /// ```text
  /// 轮询上限   12 秒（与 _seekAfterReady 一致）—— 超时就如实打印当时的值
  /// 轮询间隔   250ms
  /// 只做一次   由 _hwdecReported 保证（换集/换源不重复刷日志）
  /// 串流保护   用 `_hwdecToken` 代次号，换流后旧的等待作废
  /// ```
  ///
  /// # ⚠️ 不许为了"日志好看"而伪造
  ///
  /// 超时或读到 `no` 就**照原样打印**。硬指标①要的是真实证据，
  /// 打印一个假的 `d3d11va-copy` 比空值更糟。
  Future<void> _reportHwdecAfterReady(int token) async {
    // Windows 才有 d3d11va；其它平台后端不同，但读法一样，所以不排除
    final native = _player.platform;
    if (native is! NativePlayer) return;

    /*
     * 等 `video-params` 就绪。
     *
     * ⚠️ 这里**直接问 mpv 要属性**，而不是等 `stream.videoParams` 流 ——
     *    流的广播可能发生在 `_bindPlayerStreams()` 订阅之前（open 很快
     *    就返回时），那样会**永远等不到**下一次广播（流不重放）。
     *    轮询属性则无论时序如何都能读到当前真值。
     */
    var waited = 0;
    var ready = false;
    while (waited < 48) {
      if (token != _hwdecToken) {
        // 用户已换集/换源，这次取证作废
        debugPrint('[PLAYER] hwdec 取证已过期（用户换了流），放弃');
        return;
      }
      try {
        final vp = await native.getProperty('video-params');
        // mpv 在没有视频轨/解码器时返回空串
        if (vp.isNotEmpty) {
          ready = true;
          break;
        }
      } catch (_) {
        // 属性还没建好时可能抛错 —— 当作"未就绪"继续等
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      waited++;
    }

    try {
      /*
       * ★ 硬指标①的证据行 —— 格式不要改，验收脚本按这个前缀 grep。
       *
       * 无论就绪与否都读一次并如实打印：`ready=false` 时打出来的
       * 空值/`no` 本身就是"这个平台没硬解"的真实结论。
       */
      final cur = await native.getProperty('hwdec-current');
      // ignore: lines_longer_than_80_chars
      debugPrint(
        '[PLAYER] hwdec-current = $cur'
        '（就绪=${ready ? "是" : "否，等待 ${waited * 250}ms 超时"}）',
      );
    } catch (e) {
      debugPrint('[PLAYER] 读 hwdec-current 失败: $e');
    }
  }

  /// 画面输出层看门狗：**输出层建不起来**时把 `_videoOutputDead` 立起来
  ///
  /// # 为什么必须有它（交付说明自己承认的缺口）
  ///
  /// `README-交付说明.md:126-129`：
  /// > 输出层建不起来时没有任何降级、也没有用户可见的报错，全程静默
  ///
  /// 这不是理论问题 —— `.probe\t376_report_android-video.txt` 是实测：
  /// `vo=gpu` 时 mpv 打 `Could not create a GL context.` /
  /// `Failed initializing any suitable GPU context!`，
  /// **画面永远是黑的、声音正常、时间在走、一句提示都没有**。
  ///
  /// # 判据（五臂实测，`.probe\t376_matrix.py` ⇒ `pass=14 fail=0`）
  ///
  /// ```text
  /// hasVideoTrack = _player.state.videoParams.dw != null   ← Dart 侧
  /// voConfigured  = mpv 属性 'vo-configured' == 'yes'      ← mpv 侧
  /// 告警 = hasVideoTrack && !voConfigured
  /// ```
  ///
  /// ★ 为什么**不能**只用一个信号（五臂表在 `.probe\t376_matrix.txt`）：
  ///   * 只用 `vo-configured` → 纯音频臂（合法无视频）上它是 `yes`，
  ///     而 Android 失败臂上是 `no`。单用会把**每个只有音频的电台**
  ///     判成故障。
  ///   * 只用 `videoParams.dw` → 失败臂上它也是真（它是
  ///     `mpv_observe_property` 事件推送的**残留**，只证明"曾经解析出
  ///     视频轨"，不证明"此刻有输出"）。
  ///
  /// ⚠️ 更不能用 `controller.rect > 1x1` / `waitUntilFirstFrameRendered`：
  ///    这两个是 `media_kit_video` 自己用来决定"要不要画 Texture"的判据
  ///    （`video_texture.dart:427-437`），而实测它们在**失败臂上依然为真**
  ///    （Android 的 `rect` 由 `VideoOutputManager.SetSurfaceSize` 回填，
  ///    该调用在 GL 上下文建不起来时仍然"成功"）。
  ///
  /// # 时序（★ 决定必须轮询，不能只读一次）
  ///
  /// 成功臂 `android-video-ok` 的 `vo-confirmed` 是 **t=1980ms 才变 yes**
  /// （首个采样 t=1143ms 时还是 `no`）⇒ 读一次就判会把正常播放误报成故障。
  /// 这里给 10 秒预算（40 × 250ms），远超实测的 1980ms。
  ///
  /// ⚠️ 没有视频轨（纯音频流）时**不告警** —— 那是合法状态，不是故障。
  Future<void> _watchVideoOutput(int token) async {
    final native = _player.platform;
    if (native is! NativePlayer) return;

    Future<bool> voConfigured() async {
      try {
        final v = await native.getProperty('vo-configured');
        return v == 'yes';
      } catch (_) {
        // 属性还没建好时可能抛错 —— 当作"还没配好"继续等
        return false;
      }
    }

    var waited = 0;
    while (waited < 40) {
      // 用户换集/换源/退出 → 这一轮作废
      if (token != _videoOutputToken || !mounted) return;
      if (_player.state.videoParams.dw != null) {
        if (await voConfigured()) {
          // 画面正常，收工
          debugPrint(
            '[PLAYER] 画面输出层就绪'
            '（vo-configured=yes，等了 ${waited * 250}ms）',
          );
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      waited++;
    }

    // 超时：最后再判一次，避免把"刚好在最后一刻起来"误报
    if (token != _videoOutputToken || !mounted) return;
    final hasVideo = _player.state.videoParams.dw != null;
    final ok = await voConfigured();
    if (token != _videoOutputToken || !mounted) return;
    if (!hasVideo || ok) return;

    /*
     * ★ 如实打日志（诊断"是上游还是本机"全靠它）。
     *
     * ⚠️ 这里**不重试、不换 vo** —— `.probe\t376_report_android-video.txt`
     *    同族实测：`opengl-es=no` 让 mpv 改走 Desktop GL 后**同样失败**
     *    （`Could not bind API!` / `Failed initializing any suitable GPU
     *    context!`）。换一个 VO 重试只会把黑屏时间拉长，所以正确的
     *    做法是**告诉用户**，而不是假装能修。
     */
    debugPrint(
      '[PLAYER] ★ 画面输出层未能初始化'
      '（有视频轨但 vo-configured≠yes，等了 ${waited * 250}ms）'
      ' —— 音频正常，画面不会有',
    );
    setState(() => _videoOutputDead = true);
  }

  /// 探针用：直接置"输出层已死"（**仅供 `lib\t377_banner_probe.dart` 渲染验证**）
  ///
  /// 真失败需要一台"GL 上下文建不起来"的机器；但横幅**渲染对不对**
  /// （位置/文案/不盖画面/按钮可点）是独立的另一件事，必须能在任何机器上验证。
  /// 生产代码里没有调用点。
  void debugSetVideoOutputDead(bool v) {
    setState(() => _videoOutputDead = v);
  }

  /// ★★★ Android 字幕字体（2026-09-23 实测抓到的真问题）
  ///
  /// # 问题
  ///
  /// Android 上 `libass: true` **不生效** —— 屏幕上没有字幕。
  ///
  /// media_kit 源码（`real.dart` L2328）的条件是三个都要满足：
  /// ```dart
  /// if (Platform.isAndroid &&
  ///     configuration.libass &&
  ///     configuration.libassAndroidFont != null &&      // ← 资源名
  ///     configuration.libassAndroidFontName != null) {  // ← 字体名
  /// ```
  /// 它内部会 `AndroidAssetLoader.load()` 一个**打包进 assets 的 .ttf**，
  /// 然后把 `sub-fonts-dir` 指向解出来的目录。
  ///
  /// # 为什么不照它做（bundle 字体）
  ///
  /// ```text
  /// ① 体积：最小的中文字体 SimsunExtG.ttf 也要 3.4 MB，
  ///    而硬指标③要求 Android 包尽量小
  /// ② 授权：Windows 自带的 msyh/simhei/simsun 是**微软专有字体**，
  ///    不能随应用分发
  /// ```
  ///
  /// # 解法：直接用 Android 系统自带的 CJK 字体
  ///
  /// 实测确认设备上有（**Apache 2.0** 授权，已预装）：
  /// ```text
  /// /system/fonts/NotoSansCJK-Regular.ttc
  /// /system/fonts/NotoSerifCJK-Regular.ttc
  /// ```
  /// 所以绕过 media_kit 的 asset 路径，**自己设 mpv 属性**：
  /// ```text
  /// sub-fonts-dir  → 让 fontconfig 去系统字体目录找
  /// sub-font       → 指定用哪个（CJK 那个）
  /// ```
  /// 零体积增量、零授权风险。
  Future<void> _setSubtitleFont() async {
    if (!Platform.isAndroid) return;
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;

      /*
       * ⚠️ `config=yes` 是前提 —— mpv 默认不读 fontconfig 配置，
       *    不打开的话 `sub-fonts-dir` 不生效。
       */
      await native.setProperty('config', 'yes');
      await native.setProperty('sub-fonts-dir', '/system/fonts');
      /*
       * 字体**名**（不是文件名）——
       * NotoSansCJK-Regular.ttc 里家族名是 "Noto Sans CJK SC"。
       */
      await native.setProperty('sub-font', 'Noto Sans CJK SC');
      debugPrint('[PLAYER] Android 字幕字体已指向 /system/fonts');
    } catch (e) {
      debugPrint('[PLAYER] 设置字幕字体失败（字幕可能不显示）: $e');
    }
  }

  void _bindPlayerStreams() {
    _player.stream.playing.listen((v) {
      if (mounted) setState(() => _playing = v);
      // 缺陷 13：暂停时不轮询缓冲属性
      if (v) {
        _bufferPoller?.start();
      } else {
        _bufferPoller?.stop();
      }
    });
    _player.stream.position.listen(_onPositionTick);
    _player.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() {
        _duration = d;
        // 真实时长以流里的为准（元数据不准）
        if (d > Duration.zero) _realDuration = d;
      });
    });
    _player.stream.buffering.listen((v) {
      if (mounted) setState(() => _buffering = v);
    });
    _player.stream.volume.listen((v) {
      /*
       * ★★★ 缺陷 11 实测（2026-10-09）暴露的行为细节：
       *    setVolume(0) 之后 mpv 回流的可能仍是 **0**（而不是用户真实音量）。
       *    原来这里无条件把 _volume 写成广播值，于是静音期间 _volume 被写成 0 ⇒
       *      ① 底栏 onVolume 滑杆（muted ? 0 : volume）显示的就是 0；
       *      ② 拖到同一个值时 mpv 幂等、不发广播，那条兜底路径随之失效。
       *    两条都会让取消静音恢复不出正确音量 —— 正是用户报的
       *    「必须拖音量条才恢复」。
       *    ⇒ 静音期间**不接受 0 广播**改写 _volume：0 在这里语义上是「静音」，
       *      不是一个音量值（音量本身另有 _volumeBeforeMute 快照兜着）。
       */
      if (!(_muted && v <= 0) && mounted) setState(() => _volume = v);
      /*
       * ★ 记住音量（原版 `PlayerView.vue:3983`）
       *
       * 原版注释：
       * > 用户调的是"播放器的音量"，下次打开还是这个音量。
       * ⚠️ 静音时**不记** —— 否则用户下次进来是静音的，
       *    而且他不知道自己什么时候"设过"静音（很难联想到）。
       *
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-09-27：只记「**用户真的动手调过**」的那一次
       * ══════════════════════════════════════════════════════════════
       *
       * # 不设白名单会怎样（真机实测，**已改坏过用户的设置**）
       * ```text
       * ui-prefs.json 的 dsh.playprefs.lastVolume：0.75 → **1.0**
       * 写入时间 09:03:20 —— 那一刻**没有任何人操作音量**
       * ```
       * 根因：mpv 在播放器刚创建时会广播它自己的**默认音量 100**
       * ⇒ 那条广播进了这里 ⇒ `!_muted && 100>0` 成立 ⇒
       * ★ 把 "1.0" 写进用户偏好（覆盖掉他存的 0.75）。
       *
       * 离线探针逐字输出（`.probe/probe_tests/probe_volume_pref_test.dart`）：
       * ```text
       * [PROBE]  两次 set 之后文件 = {"…":"0.75"}   ← 有后续正确值时能自愈
       * [PROBE2] lastVolume = **1.0**               ← ★ 只要一次假广播就永久覆盖
       * ```
       *
       * ⚠️ 判据是「**用户发起的**」而**不是**「不是我们发起的」——
       *    后者挡不住 mpv 的默认广播，而且依赖广播顺序（不确定 ⇒ 脆）。
       *    完整推理见 `_lastUserVolumeAction` 的长注释。
       */
      /*
       * ★★★ 2026-09-27：只记「**用户真的动手调过**」的那一次
       *
       * 见 `_lastUserVolumeAction` 的长注释 —— 不设这个白名单，
       * mpv 的**默认音量广播(100)** 会把用户存的 0.75 覆盖成 1.0
       * （真机实测：09:03:20 被改坏，而那一刻没人碰过音量）。
       */
      final acted = _lastUserVolumeAction;
      final isUserEcho =
          acted != null &&
          DateTime.now().difference(acted) < _kVolumeEchoWindow;
      if (isUserEcho && !_muted && v > 0) {
        _lastVolume = v / 100;
        _savePlayPref('lastVolume', _lastVolume.toString());
      } else if (_muted && isUserEcho && v > 0) {
        /*
         * ★★★ 缺陷 1 / 11：静音期间用户调音量，必须**同步更新**静音前快照
         *
         * ```text
         * 静音时用户把滑杆从 0 拖到 40
         *   => 取消静音要恢复的应该是 40，而不是静音**之前**的旧值
         *   => 不同步的话，用户会看到「我明明调了 40，一点取消静音又变回 80」
         * ```
         *
         * ⚠️ 只同步**快照**，**不写偏好** —— 静音状态下的音量不是用户想长期
         *    保留的习惯（取消静音后会以快照为准，那时才算一次真正的用户动作）。
         */
        _volumeBeforeMute = v;
      } else if (!isUserEcho) {
        /*
         * ★ 打点：非用户发起的音量广播**不写偏好** ——
         *   否则真机排障时看不出"为什么我的音量设置被改了"。
         *   （本项目吃过"静默分支无法排障"的亏，见 `_onHardwareKey` 的入口打点。）
         */
        debugPrint(
          '[PLAYER] 音量广播 $v 非用户发起 ⇒ 不写偏好'
          '（存的是 ${_lastVolume * 100}）',
        );
      }
    });
    _player.stream.rate.listen((v) {
      if (mounted) setState(() => _rate = v);
      // ★ 记住倍速（原版 `PlayerView.vue:3989`）—— 连播时沿用
      _lastRate = v;
      _savePlayPref('lastSpeed', v.toString());
    });
    /*
     * ★ 轨道列表（字幕 / 音轨）—— 起播后才会填充
     *
     * 必须**监听**而不是 open 之后读一次：HLS / MP4 的轨列表是在
     * 解复用完成后才有的，`open()` 返回时往往还是空的
     *（`delivery_test.dart` 实测：要等 1–2 秒才能枚举到字幕轨）。
     */
    _player.stream.tracks.listen((t) {
      if (!mounted) return;
      setState(() {
        _tracks = t;
        /*
         * ★ 起播后**自动选中第一条真实字幕轨**
         *
         * # 为什么必须显式选
         *
         * mpv 的 `sid` 默认是 `auto`，但只要文件里有字幕轨它就该显示 ——
         * 现实是**不一定**：实测（`delivery_test.dart`）出现过
         * ```text
         * sub-visibility = "yes"  sid = "no"    ← 有轨但没选
         * ```
         * 那种情况下屏幕上没有字，用户只会以为"这个源没字幕"。
         *
         * # 为什么只在"没选过"时做
         *
         * 用户手动关掉字幕（选「关闭」）后，如果每次轨列表刷新都
         * 重新选上，那"关字幕"就成了一个无效操作。
         */
        if (_sidChosen == 'auto' && !_pickSubtitleMadeByUser) {
          final real = t.subtitle
              .where((s) => s.id != 'auto' && s.id != 'no')
              .toList();
          if (real.isNotEmpty) {
            _sidChosen = real.first.id;
            _applySubtitleTrack(real.first.id, userInitiated: false);
          }
        }
      });
    });
    // 当前选中的三条轨（用户点「关闭字幕」时 mpv 会把 sid 变成 no）
    //
    // ⚠️ 这里**不保存整个 Track 对象** —— 面板显示"选中哪条"用的是
    //    `_sidChosen` / `_aidChosen`（我们自己记的）。
    //    原因是 mpv 的 track selection 在"用户选的"和"自动选的"之间
    //    会来回变（mpv 手册原话：the behavior tends to change around with
    //    each mpv release），拿它当显示源会出现"面板上选中的和我点的不一样"。
    _player.stream.track.listen((t) {
      if (!mounted) return;
      setState(() {
        if (!_pickSubtitleMadeByUser) _sidChosen = t.subtitle.id;
        _aidChosen = t.audio.id;
      });
    });
    /*
     * ★★★ 2026-10-08（Owner 第 9 条）：错误**分两类**处理
     *
     * 判据是 [_sawFirstFrame] —— 出过画面说明播放**真的起来过**，
     * 此刻来的 `stream.error` 是一次可恢复抖动（换流重开 / 缓冲重试 /
     * 单帧解码报错都会发），用全屏 `_ErrorOverlay` 盖掉画面就是
     * 用户报的"看着看着突然播放失败"。
     * 反之（从未出过画面）该给全屏错误 —— 用户什么都没看到，必须解释。
     */
    _player.stream.error.listen((e) {
      if (!mounted) return;
      /*
       * ★ 落盘：这条错误**必须**能在事后看到。
       *
       * Owner 第 9 条给的只有一张截图（`Failed to open http://127.0.0.1:63534/s/…`），
       * 而那个端口随进程退出就失效 ⇒ **事后无法回连**，只能靠当时留下的字。
       * 之前全走 `debugPrint` ⇒ Release 版什么都没有。
       */
      AppLog.write('PLAY', _sawFirstFrame ? '播放中断（已有画面，非阻断）：$e' : '起播失败：$e');
      setState(() {
        if (_sawFirstFrame) {
          _playbackFailure = e;
        } else {
          _error = e;
        }
      });
    });
    /*
     * ★ 记录"出过画面"这个事实（Owner 第 9 条的判据输入）
     *
     * `stream.width` 在**没有视频轨时发 null**（real.dart:337-338 /
     * :536-537 是它复位的地方）⇒ 只有非空且 > 0 才算"真的有画面"。
     * 出画面后把之前那条非阻断横幅收掉 —— 已经恢复了就不该继续吓用户。
     */
    _player.stream.width.listen((w) {
      if (!mounted) return;
      if (w == null || w <= 0) return;
      /*
       * 只有"已经是正常播放中"这一种情况才早退（避免每帧都重建）。
       *
       * ⚠️ 判据里**必须**带上 ${_error} —— 否则「起播时先报错、随后画面又出来了」
       *    这条路会把全屏错误层**永久留在屏幕上**：画面在底下正常播，
       *    用户却只能看到一个"播放失败"，而且没有任何办法关掉它。
       */
      if (_sawFirstFrame && _playbackFailure == null && _error == null) return;
      /*
       * ★ 落一行日志：Owner 第 9 条的复现全靠它。
       *
       * 有这行之后，"播放失败"那条横幅的时间戳就能和它对齐 ——
       * 「失败发生在出画面**之前**还是**之后**」是二分这条缺陷的唯一判据，
       * 而在此之前这个事实**只存在于内存里**，用户报问题时拿不到任何东西
       * （AppLog 是产品里唯一的日志基础设施，见 core/app_log.dart 文件头）。
       */
      AppLog.write(
        'PLAY',
        '首帧已出（${w}x${_player.state.height}）—— '
            '此刻之后的 stream.error 按"可恢复中断"处理，不再盖全屏',
      );
      setState(() {
        _sawFirstFrame = true;
        // ★ 有画面了 ⇒ 之前那条"起播失败"已经不成立，全屏错误层必须撤掉
        _error = null;
        _errorKind = null;
        _loading = false;
        _playbackFailure = null;
      });
    });
    _player.stream.completed.listen((done) {
      if (done && mounted) _onEnded();
    });
    // 缺陷 13：接上缓冲区间轮询器（内部会看 kBufferRangeMode 决定是否真的读属性）
    _bindBufferPoller();
  }

  /// ★★★ task-72【④】位置 tick 的**唯一**处理点
  ///
  /// # 为什么抽成方法（而不是写在 `listen` 的闭包里）
  ///
  /// 抽出来才能被**探针/测试直接驱动**：
  /// `debugPlayerPushPositionForProbe()` 走的就是这里
  /// ⇒ "100 次 tick 只重建 1 次"这条断言测的是**生产代码本身**，
  ///   而不是测试里另写一份逻辑（另写一份必然漂 —— 铁律 170）。
  ///
  /// # 改前是什么样
  /// ```dart
  /// _player.stream.position.listen((p) {
  ///   if (!mounted) return;
  ///   setState(() => _position = p);   // ★ 每个 tick 一次整页重建
  ///   _maybeSkip(p);
  ///   _scheduleSave(p);
  /// });
  /// ```
  /// 而 `time-pos` 是 mpv 的属性观察器**原样转发**的
  /// （`media_kit-1.2.6/lib/src/player/native/player/real.dart:1564-1570`，
  /// media_kit 内部**没有**采样/节流）⇒ 播放中每秒数次整页重建。
  ///
  /// # 为什么按"秒"节流是**零视觉损失**的
  ///
  /// 底栏时间显示 = `_fmt(position)` = `MM:SS`
  ///（`player_page.dart:8200-8206`），进度条按
  /// `position.inMilliseconds / duration.inMilliseconds` 取值 ——
  /// **两者都只在一秒变化时才看得出差别**。
  ///
  /// # ★ 为什么不牺牲读值语义（这是与"节流"最容易搞混的地方）
  ///
  /// `_position` 本身**每个 tick 都更新**（下面那行赋值，无条件）——
  /// 只有 `setState` 被守卫。
  /// ⇒ seek / 续播 / 片头片尾判定 / 快退 读到的仍是**最新值**，
  ///   不存在"为了省重建而让状态变旧"的代价。
  void _onPositionTick(Duration p) {
    if (!mounted) return;
    debugPlayerPositionTicks++; // ★ 仅探针计数（task-72 ④ 量化）
    final secChanged = p.inSeconds != _position.inSeconds;
    _position = p; // ★ 无条件更新（读值语义不变）
    if (secChanged) {
      debugPlayerPositionSetStates++; // ★ 仅探针计数
      /*
       * ★★★ 2026-10-09：这里**不再 setState**。
       *
       * 改前 `setState(() {})` 触发的是**整页**重建，而这次变化只影响
       * 底栏的时间与进度条 —— 其余 1.6 万行（弹幕层、顶栏、浮层、描边）
       * 一行都不需要重排。
       * ⇒ 只通知 notifier，由底栏那一小块 `ValueListenableBuilder` 重建。
       * 实测读数见交付报告（改前 1 次/秒整页重建 → 改后 0 次）。
       */
      _positionNotifier.value = p;
      // ★ task-13 ⑦ 面板开着时刷一次弹幕实时读数（每秒一次，开销可忽略）
      if (_danmakuSheetOpen) _refreshDanmakuReadout();
    }
    _maybeSkip(p);
    _scheduleSave(p);
  }

  Future<void> _load() async {
    /*
     * ★ 阶段计时起点（task-24）—— 必须在第一个 await 之前
     *   见 `_bootMark` 的说明：用户点播放到首帧拆成 4 段。
     */
    _bootWatch = Stopwatch()..start();
    _bootMark('① 点播放', _isLive ? '直播' : '点播 $_provider/$_contentId');

    setState(() {
      _loading = true;
      _error = null;
      _errorKind = null;
      // ★ 新一轮起播 ⇒ 上一轮的"出过画面"与非阻断横幅全部作废
      _sawFirstFrame = false;
      _playbackFailure = null;
    });

    try {
      final List<StreamCandidate> list;
      if (_isLive) {
        list = await SourinApi.getLiveStream(_provider, _liveChannelId!);
      } else {
        list = await SourinApi.resolveStream(
          _provider,
          _contentId,
          req: widget.sourceCode != null || widget.episodeId != null
              ? PlayRequest(
                  sourceCode: _sourceCode,
                  episodeId: widget.episodeId,
                )
              : null,
        );
      }

      /*
       * ★ 阶段②：拿到候选地址 —— 这一段是**插件 JS + 网络请求**的耗时。
       *
       * ⚠️ 它和 mpv 完全无关。若这一段占了大头，那优化方向是
       *    插件/预解析，**改 mpv 缓冲一点用都没有**（见 `_bootMark` 的表）。
       */
      _bootMark(
        '② 拿到候选地址',
        '${list.length} 条 · 首条 playable=${list.where((s) => s.isPlayable).isNotEmpty}',
      );

      if (!mounted) return;
      setState(() => _streams = list);

      /*
       * ★ 挑第一个**能播**的候选（跳过 DRM）
       *
       * 原版注释解释了为什么**不按清晰度排序**：
       * > 原版是取第一个非 DRM 的候选。**排序是产品决定** ——
       * > 如果这里偷偷按清晰度重排，用户看到的默认清晰度就会
       * > 和原版不一致（违反「操作逻辑保持一致」）。
       */
      final first = list.where((s) => s.isPlayable).firstOrNull;
      if (first == null) {
        setState(() {
          _error = list.isEmpty ? '该内容没有可播放的地址' : '所有线路都不可播（可能受 DRM 保护）';
          _loading = false;
        });
        return;
      }

      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ 不许"静默播成黑屏" —— 直播只剩音频线路时必须如实告知
       * ══════════════════════════════════════════════════════════════════
       *
       * # 用户报的就是这个（「cctv看得到但是点开黑屏」）
       *
       * 实测核心层对 `get_live_stream(cctv, cctv1)` 返回三条（已核对原始 JSON）：
       * ```text
       * ① 高清   drm_protected: true    ← 被 isPlayable 过滤
       * ② 标清   drm_protected: true    ← 被过滤
       * ③ 仅音频 drm_protected: 缺失     ← ★ 只有它通过 → 被选中
       * ```
       * 于是播放器打开的是**纯音频**流 —— 用户听到声音、画面全黑。
       *
       * # 独立验证（ffmpeg，与 mpv 完全不同的解码器）
       *
       * ```text
       * 纯音频线  Stream #0:0: Audio: aac …   ← ★ 根本没有 video 流 ⇒ 必然黑屏
       * 高清线    250 帧但 386 条解码错误：
       *           [h264] error while decoding MB 9 0, bytestream 42177
       *           [dec] corrupt decoded frame
       *           [h264] Cannot use next picture in error concealment
       *           [h264] Reference 3 >= 3
       *           ↑ 与 cctv.js 注释里"实测 video 轨 61~80 个解码错误"完全吻合
       * 本地对照  450 帧、0 错误                          ← 证明这套判据有效
       * ```
       * ⇒ **视频轨确实被加密**（插件标 `drmProtected: true` 是对的），
       *   音频轨是唯一能正常播的 —— 与原版 `PlayerView.vue:1929`
       *   （`list.find((x) => !x.drm_protected) ?? list[0]`）行为一致。
       *
       * # 那还缺什么
       *
       * 原版会**明确告诉用户**（`PlayerView.vue:4281-4299`）：
       * ```text
       * 「这是内容方（央视）对直播视频轨的加密，客户端无法绕过」
       * 「改听「仅音频」」/「返回」
       * ```
       * 我们之前是**直接开播、什么都不说** —— 用户只看到黑屏，
       * 只会认为"客户端坏了 / 我的源不能播"。
       *
       * ⚠️ 这条提示**不能写进 `_error`** —— `_startPlayback()`
       *    开头就会 `_error = null`（它表示"起播失败"），
       *    写进去会被立刻清掉。所以用独立的 `_liveAudioOnlyNotice`，
       *    由它自己的横幅渲染，与播放状态并存。
       */
      final playableLines = list.where((s) => s.isPlayable).toList();
      final hasDrmVideo = list.any(
        (s) => s.drmProtected && (s.quality == '高清' || s.quality == '标清'),
      );
      final onlyAudioPlayable =
          playableLines.isNotEmpty &&
          !playableLines.any((s) => s.quality == '高清' || s.quality == '标清');
      final audioOnlyNotice = (_isLive && hasDrmVideo && onlyAudioPlayable)
          ? first.displayName
          : null;
      if (audioOnlyNotice != null) {
        debugPrint(
          '[PLAYER] 直播：视频线路全部受 DRM 保护，'
          '只剩「$audioOnlyNotice」可播 —— 会黑屏但有声，必须告知用户',
        );
      }
      if (mounted) {
        setState(() => _liveAudioOnlyNotice = audioOnlyNotice);
      }

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 记忆播放位置 —— 起播**之前**读上次看到哪儿了
       * ══════════════════════════════════════════════════════════════
       *
       * # 这里原来漏掉了什么（本次补的最大缺口）
       *
       * `_saveProgress` 一直在**写**（5 秒一次 + 退出时立刻落盘），
       * 但**没有任何地方读回来** —— 全仓库 grep `getProgress`：
       * ```text
       * lib/ui/detail_page.dart:221   ← 详情页用来显示"看到 12:34"
       * lib/ui/player_page.dart       ← ✗ 一次都没有
       * ```
       * 所以用户"看了 20 分钟退出 → 再点进来"**永远从第 0 秒开始**。
       *
       * # 与原版的对齐
       *
       * 原版 `PlayerView.vue:1918` 在 resolveStreams **之后**、
       * startPlayback **之前**调 `await prepareResume()`，
       * 由它把位置写进 `pendingSeekTime`（`PlayerView.vue:1951-1986`）。
       * 这里照抄同一个顺序与同一个时机。
       *
       * ⚠️ 必须在 `_startPlayback` **之前** —— 它会消费 `_pendingSeek`
       *    并 seek。放到后面就等于"先从头播，再跳"，用户会看到画面闪回去。
       */
      await _prepareResume();

      await _startPlayback(first);
      await _loadSkipMarker();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          // ★ 结构化类别（能从 SourinCoreException 拿到就记下来）
          _errorKind = _kindOf(e);
          _loading = false;
          // ★ 全屏错误与非阻断横幅**不许同屏**（两条都是"出事了"）
          _playbackFailure = null;
        });
      }
    }
  }

  /// ★ 读上次的播放进度，写进 `_pendingSeek`（供 `_startPlayback` seek）
  ///
  /// # 逐条对齐原版 `prepareResume()`（`PlayerView.vue:1951-1986`）
  ///
  /// ```text
  /// ① 直播不续播            → if (!s || s.liveChannelId) return
  /// ② 被其他集覆盖的不算      → episode_id 与本集不一致就丢弃
  ///                             （下一集的进度不该串到这一集）
  /// ③ 快看完了不续播          → position < duration - 10
  /// ④ 刚点开不续播            → position > 5
  /// ```
  /// ③ 照抄（剩不到 10 秒还跳过去，用户会以为"播完了"）。
  /// ④ **不照抄** —— 原因见下面 `pos <= 0` 那段的注释
  /// （我们的 PlayerPage 没有「继续观看」传参，照抄会让"看 3 秒就退"
  /// 永远回 0，表现得像功能坏了）。这是**唯一的偏差**，报告里单列。
  Future<void> _prepareResume() async {
    // ① 直播没有进度概念
    if (_isLive) return;
    // 本次会话已经续播过（重复调用会覆盖用户当前的播放位置）
    if (_resumedThisSession) return;

    /*
     * ⓪ 重试路径：错误浮层的「重试」会再走一遍 `_load()`
     *
     * 那一刻用户已经看了若干分钟，**必须保持当前位置** ——
     * 既不能回到 0，也不该被服务端存的旧进度覆盖
     *（服务端进度是 5 秒才落一次盘，比内存里的位置旧）。
     */
    if (_position > Duration.zero) {
      _pendingSeek = _position;
      _resumedThisSession = true;
      debugPrint('[PLAYER] 重试：保持当前位置 ${_position.inSeconds}s');
      return;
    }

    try {
      final p = await SourinApi.getProgress(_provider, _contentId);
      if (p == null) return;

      /*
       * ② 按**集号**校验，避免上一集的进度串到这一集
       *
       * 原版：`if (p.episode_id && s.episodeId && p.episode_id !== s.episodeId) return;`
       * 我们的对应物是当前集的 id（`_episodes` 优先，回退到 widget 传来的）。
       */
      final curEpId = _epIndex < _episodes.length
          ? _episodes[_epIndex].id
          : widget.episodeId;
      if (p.episodeId != null && curEpId != null && p.episodeId != curEpId) {
        debugPrint('[PLAYER] 进度属于另一集（${p.episodeId} ≠ $curEpId），不续播');
        return;
      }

      final pos = p.position;
      /*
       * ⚠️ 这里是**与原版唯一的偏差**，如实说明
       *
       * 原版的守卫是 `p.position > 5` —— 因为原版从详情页点
       * 「继续观看」进来时会**显式传 location**（那条路不需要续播）。
       *
       * 我们的 `PlayerPage` **没有** `location` 参数（进播放器只有
       * "点海报/点播放"一条路），照抄 `> 5` 的后果是：
       * ```text
       * 用户看了 3 秒 → 退出（进度已落盘 3 秒）
       *            → 再进来 → 3 不大于 5 → 从 0 开始
       *            → 反复几次，用户认定「记忆播放位置是坏的」
       * ```
       * 所以改成 `> 0`：**有记录就复原**。对"看了两小时"的主场景
       * 两者完全等价（都远大于 5），只在"刚点开就退"这种边角上更符合直觉。
       *
       * 真正要防的"误续播"由上面 ③（快看完）和 ②（集号不匹配）覆盖。
       */
      if (pos <= 0) return;

      // ③ 快看完了不续播（原版：`p.position < p.duration - 10`）
      if (p.duration > 0 && pos >= p.duration - 10) {
        debugPrint('[PLAYER] 上次已看到 $pos/${p.duration}s（快结束），从头播');
        return;
      }

      /*
       * ④ 写入待跳转位置
       *
       * 原版这里同时记了 `pendingSeekRatio`（比例，喂给成品播放器）和
       * `pendingSeekTime`（秒数，喂给转码的 `-ss`）。
       * 我们**没有转码那条路**（libmpv 原生硬解，不存在"从第 0 秒
       * 开始转"的问题），所以只需要秒数。
       */
      _pendingSeek = Duration(seconds: pos);
      _resumedThisSession = true;
      debugPrint('[PLAYER] ★ 检测到上次进度 ${pos}s，将续播');
    } catch (e) {
      // 读进度失败不该影响播放（原版：`catch { /* 无进度不影响播放 */ }`）
      debugPrint('[PLAYER] 读播放进度失败（按从头播处理）: $e');
    }
  }

  Future<void> _startPlayback(StreamCandidate st) async {
    setState(() {
      _current = st;
      _loading = true;
      _error = null;
      _errorKind = null;
      // 换流后旧的判决作废（看门狗靠代次号自行放弃）
      _videoOutputDead = false;
      // ★ 换了条流 ⇒ "出过画面"要重新判定（新流可能根本打不开）
      _sawFirstFrame = false;
      _playbackFailure = null;
    });

    try {
      /*
       * ★ 用 `Player.open` 而不是 `setMedia` + `play`
       *
       * open 会等流真正就绪（canplay）—— 这样 `_loading = false`
       * 的时机才准确（用户看到的是"真的开始播了"）。
       */
      /*
       * ★★★ 必须把 `st.headers` 一起传给播放器 —— 修任务⑰⑧「直播黑屏」
       *
       * # 用户原话
       *
       * > 直播为什么不能看?我做的是插件,为什么不能播放我的源?
       * > （澄清后）cctv看得到但是点开黑屏
       *
       * # 根因（实测，不是推断）
       *
       * 原代码是 `Media(st.url)` —— **只传 url，headers 全丢**。
       * 而直播和点播**不一样**：
       * ```text
       * 点播 resolve_stream(154,...)
       *   url = http://127.0.0.1:56008/s/...   ← 核心层已做本地代理，防盗链在代理里处理
       *   → 不传 headers 也能播
       *
       * 直播 get_live_stream(cctv, cctv1)
       *   url = https://ldncctv...myqcloud.com/...   ← ★ 原始地址，**没有代理**
       *   headers = [["Referer","https://tv.cctv.com/"]]
       *   → ★ 必须有 Referer，否则 403
       * ```
       * 实测（curl 同一条 m3u8）：
       * ```text
       * 不带 Referer  → HTTP 403 已禁止
       * 带 Referer    → HTTP 200 + 合法 m3u8
       *   #EXTM3U
       *   #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=960x540
       *   /ldcctvwbnd/ldcctv1_2_hd.m3u8
       * ```
       * 403 对 mpv 就是"打不开这个流" → 用户看到**黑屏**（不是错误弹窗，
       * 因为 `open()` 失败被 catch 成 `_error`，而直播页那层没显示出来）。
       *
       * # 为什么用 `st.httpHeaders`（而不是自己拼 Map）
       *
       * media_kit 的参数名是 **`httpHeaders`**（读源码确认，
       * `media_kit-1.2.6/lib/src/models/media/media_native.dart:104-113`）：
       * ```dart
       * Media(
       *   String resource, {
       *   Map<String, dynamic>? extras,
       *   Map<String, String>? httpHeaders,   // ★ 就是它
       *   ...
       * })
       * ```
       * `StreamCandidate.httpHeaders` 负责把核心层的有序列表
       * `[[k,v],...]` 转成这个 Map（见 `models.dart`）。
       *
       * ⚠️ headers 为空时传 `const {}` 与不传等价 —— media_kit 用
       *    `?? cache[...]` 兜底，空 Map 不会破坏任何东西。
       */
      await _player.open(Media(st.url, httpHeaders: st.httpHeaders));
      /*
       * ★★★ task-22 P1-11：`video-zoom` 是**逐文件**属性 —— mpv 换文件时会
       *   把它复位。只在 `_setHwdec()` 里下发一次是不够的（换集后缩放就没了），
       *   所以起播这条路上再补一次。
       */
      unawaited(_applyVideoZoom());
      /*
       * ★ 阶段③：`open()` 返回 = mpv 已 canplay（可以开始播）。
       *
       * ⚠️ 这**不等于**用户看到画面 —— 解码器可能还没吐第一帧。
       *    真正的"起来了"是阶段④（`stream.width` 非空）。
       *    两者之差 = **首帧解码 + 缓冲填充**的耗时，那才是"卡着不起来"的主体。
       */
      _bootMark('③ player.open() 返回', 'kind=${st.kind}');
      /*
       * ★ 打出**真实地址**（task-24 诊断必需）
       *
       * 要判断"是上游慢还是我们代理慢"，必须能拿同一个 URL 做
       * 直连 vs 走代理 的对照实验（curl 计时）。不打出来就只能猜。
       *
       * ⚠️ 只在 `PLAYBACK_TIMING=true` 时输出 —— 地址带时效签名，
       *    不该出现在正式日志里。
       */
      if (kPlaybackTiming) {
        debugPrint('[TIMING] 起播地址 = ${st.url}');
      }
      debugPrint(
        '[PLAYER] open: kind=${st.kind} drm=${st.drmProtected} '
        'headers=${st.httpHeaders}',
      );
      /*
       * ★★ 落盘一行**起播现场**（★ 2026-10-08，Owner 第 9 条）
       *
       * # 为什么必须落盘
       * ```text
       * Owner 给的第 9 条证据只有一张截图：
       *   播放失败 / Failed to open http://127.0.0.1:63534/s/18dc2c90fcf9b1f03f3446afdd80/.
       * 那个端口由 streamproxy 随机分配、**随进程退出就失效**
       *   ⇒ 事后无法回连、无法复现，只能靠当时留下的字。
       * ```
       *
       * # 为什么这里可以打完整地址（而 debugPrint 那行不行）
       * ```text
       * 上面 `[TIMING]` 那行**故意**受 `kPlaybackTiming` 门控 ——
       * 它的用途是给人做 curl 对照实验，不需要长期留档。
       * 这一行不同：它是**故障现场**，落盘才有意义（AppLog 会按天滚），
       * 而且 Owner 要诊断的就是这条地址。
       *
       * ⚠️ 只打地址与 kind：**不打** `st.httpHeaders` ——
       *    那是防盗链头，可能含 cookie/token（产品日志要能安全地交出去）。
       * ```
       */
      AppLog.write(
        'PLAY',
        '起播 kind=${st.kind} drm=${st.drmProtected} url=${st.url}',
      );

      /*
       * ★★ 硬指标①取证：**open() 之后**才读 `hwdec-current`
       *
       * # 为什么必须在这里（2026-09-24 修的真 bug）
       *
       * `hwdec-current` 是 mpv 的**运行时属性** —— 没有媒体、解码器
       * 还没初始化时它是**空字符串**。原先在 `initState`（`_setHwdec`
       * 里）读，此时还没 open，日志永远是 `hwdec-current = `（空）。
       *
       * # 为什么是 unawaited（不阻塞起播）
       *
       * 它内部要**轮询等解码器就绪**（最多 12 秒）。如果 await 在这里，
       * `_loading = false`（用户看到的"开始播了"）就要等 12 秒 ——
       * 为了打一行日志拖慢起播是不值得的。用 `unawaited` 让它自己跑。
       *
       * ⚠️ 每次起播都自增代次号：换集/换源后旧的那次等待必须作废，
       *    否则它会拿着新流的状态去打一条"属于上一集"的日志。
       */
      unawaited(_reportHwdecAfterReady(++_hwdecToken));

      /*
       * ★ 阶段④：等首个视频帧（task-24）
       *
       * 与 hwdec 取证并列 —— 都是"起播后异步观测"，都不阻塞 `_loading`。
       * 代次号同样自增：换集/换源后旧的等待作废。
       */
      unawaited(_reportFirstFrame(++_firstFrameToken));

      /*
       * ★★★ 画面输出层看门狗（交付说明 `:126-129` 承认的静默缺口）
       *
       * 与上面两条并列 —— 都是"起播后异步观测"，都不阻塞 `_loading`。
       * `media_kit` 只把**白名单前缀**的日志转成 `stream.error`
       * （`media_kit-1.2.6/lib/src/player/native/player/real.dart:2085-2119`），
       * 而 `vo/gpu` / `vo/gpu/opengl` **不在白名单里** ⇒ 输出层失败
       * 被库静默丢掉，只能自己探（判据见 `_watchVideoOutput` 的文档）。
       */
      unawaited(_watchVideoOutput(++_videoOutputToken));

      /*
       * ★★ DASH 音视频分离（B 站 1080P 必然如此）
       *
       * 原版注释：
       * > 音轨也要走同一个代理（同样的 headers），
       * > 否则表现是「画面正常但完全没声音，且不报错」。
       *
       * libmpv 支持 `audio-add` —— 把外挂音轨加进来。
       */
      if (st.audioUrl != null && st.audioUrl!.isNotEmpty) {
        try {
          final native = _player.platform;
          if (native is NativePlayer) {
            await native.setProperty('audio-file', st.audioUrl!);
            debugPrint('[PLAYER] 已挂载外挂音轨（DASH 分离）');
          }
        } catch (e) {
          debugPrint('[PLAYER] 挂载外挂音轨失败: $e');
        }
      }

      /*
       * ★★★ 恢复待跳转位置（换集/换源/记忆播放位置续播）
       *
       * ══════════════════════════════════════════════════════════════
       * ⚠️⚠️ 必须**等时长出来**再 seek，而且只 seek 一次
       * ══════════════════════════════════════════════════════════════
       *
       * # 实测抓到的真 bug（2026-09-24，本次交付实测）
       *
       * 原来这里就是一句 `await _player.seek(target);`，日志打
       * `[PLAYER] 已续播到 276s` —— **日志说成功，画面上却是 00:29**。
       *
       * 用 `sub-visibility` 那种"读属性"的办法验不出来（seek 本身不报错），
       * 是**截进度条**才看出来的。
       *
       * # 根因：seek 发得太早，被随后的加载复位吃掉了
       *
       * `Player.open()` 在 media_kit 里只等到 `playlist-pos` 之类就返回，
       * **`duration` 此时还是 0**（实测：seek 那一刻 `_realDuration` 为 0）。
       * 于是：
       * ```text
       * ① 对 duration=0 的流 seek(276s) → mpv 排队，但还没 demux 完
       * ② 紧接着 `audio-file` 挂外挂音轨 → mpv 重新初始化音频链
       * ③ 音视频链重建时**播放位置被复位到 0**
       * ④ 用户看到的就是"从头开始播"（实测 00:29 ≈ 起播后的正常推进）
       * ```
       * 而日志是 seek 调用**返回后**就打的 —— 所以它永远是"成功"的。
       *
       * # 修法：轮询等时长，再 seek
       *
       * ```text
       * ① 等 `duration > 0`（最多 12 秒）—— 那时 demux 已完成，
       *    音频链也重建完了，seek 不会再被复位
       * ② **只 seek 一次**（用 `_resumeSeekDone` 标志）
       * ```
       *
       * ⚠️ 为什么不能"每来一次 duration 就 seek 一次"：
       *    那会在用户已经手动拖到别处之后又把他拽回去 ——
       *    表现为"我拖了进度条它自己弹回来"。
       *
       * ⚠️ 为什么不直接 `await Future.delayed(3s)` 了事：
       *    慢的源（HLS / 大 MP4）3 秒还没 demux 完，快的源白等 3 秒。
       *    轮询是"该等多久等多久"。
       */
      final pending = _pendingSeek;
      if (pending != null && pending > Duration.zero) {
        _pendingSeek = null;
        /*
         * 每次起播拿一个新的代次号，同时把"已 seek"标志复位 ——
         * 换集/换源后**必须能再续播一次**（新集有自己的进度）。
         */
        _resumeSeekDone = false;
        unawaited(_seekAfterReady(pending, ++_seekToken));
      }

      if (mounted) setState(() => _loading = false);
      _showControls();
      /*
       * ★ 2026-10-08（Owner 第 9 条）：起播成功 ⇒ 立刻装上「3 秒后自动隐藏」。
       *
       * _showControls() 自己也会装（见 _armHideTimer 的说明），这里再装一次
       * 是**幂等**的（先 cancel 再建）—— 但语义上必须显式写出来：
       * 「起播了 ⇒ 3 秒后控件自己收起来」这条契约就钉在这一行上，
       * 将来谁把 _showControls() 里的装载挪走，这条也不会跟着丢。
       */
      _armHideTimer();
      _startProgressSaver();
      // ★ task-13 ⑦ 起播成功后再取弹幕（此时 _duration 才有值）
      unawaited(_loadDanmaku());

      /*
       * ★ 起播后把样式应用一次（含外挂字幕）
       *
       * # 为什么不能只在新流打开前设
       *
       * `sub-file` / `sub-font` 这些属性有两类行为：
       * ```text
       * 文件级（per-file）  sub-file / sub-visibility 等 → **换文件时被重置**
       * 全局（global）      sub-font / sub-color 等样式 → 跨文件保留
       * ```
       * mpv 手册「Per-File Options」明确写了 file-local 选项在换文件时
       * 会被复位。所以每次起播都要重设一遍，否则"第二集没字幕"。
       */
      unawaited(_applySubtitleStyle());
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          // ★ 结构化类别（能从 SourinCoreException 拿到就记下来）
          _errorKind = _kindOf(e);
          _loading = false;
        });
      }
    }
  }

  /// 等流就绪（拿到 duration）后再 seek 到 [target]
  ///
  /// # 为什么必须有这个函数（实测抓到的真 bug）
  ///
  /// 见 `_startPlayback` 里那段长注释：**seek 发得太早会被加载复位吃掉**，
  /// 而日志永远显示"已续播到 Ns"（seek 调用本身不报错）。
  ///
  /// # 参数与边界
  ///
  /// ```text
  /// 轮询上限   12 秒 —— 超过就当"这个源拿不到时长"，直接 seek 一次兜底
  /// 轮询间隔   250ms —— 比 duration 流的触发频率低，不会空转
  /// 夹取       目标超过真实时长时夹到 duration（新源可能更短）
  /// 只做一次   由 _resumeSeekDone 保证
  /// ```
  Future<void> _seekAfterReady(Duration target, int token) async {
    if (_resumeSeekDone) return;
    _resumeSeekDone = true;

    // 等 duration 出来（最多 12 秒）
    var waited = 0;
    while (waited < 48 && _duration <= Duration.zero && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      waited++;
    }
    if (!mounted) return;

    /*
     * ⚠️ 等待期间用户可能换了线路/切了集 —— 那时这次 seek 已经**过期**，
     *    必须放弃（否则会把上一集的秒数 seek 到新流上 = 串集）。
     */
    if (token != _seekToken) {
      debugPrint('[PLAYER] 续播 seek 已过期（用户换了流），放弃');
      return;
    }

    final dur = _realDuration > Duration.zero ? _realDuration : _duration;
    /*
     * 夹取到真实时长内。
     *
     * ⚠️ 目标超过时长时**不能**直接 seek —— 有的源会 seek 到结尾然后
     *    立刻触发 `completed`（用户一进来就"播放结束 + 连播倒计时"）。
     */
    var t = target;
    if (dur > Duration.zero && t > dur) t = dur;
    // 留 1 秒余量，避免正好落在结尾
    if (dur > Duration.zero && t >= dur) {
      t = dur - const Duration(seconds: 1);
    }
    if (t < Duration.zero) t = Duration.zero;

    try {
      await _player.seek(t);
      debugPrint(
        '[PLAYER] ★ 续播已生效: ${t.inSeconds}s '
        '（等时长 ${(waited * 250)}ms, duration=${dur.inSeconds}s）',
      );
    } catch (e) {
      debugPrint('[PLAYER] 续播 seek 失败: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 字幕（轨道切换 / 外挂文件 / ASS 样式）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 原版对照（必须如实说明）
  //
  // 原版 `PlayerView.vue` 全仓库 grep `subtitle` / `sub-file` / `sid` /
  // `sub-font` **一处都没有** —— 它把播放器能力交给了 ArtPlayer 的
  // `setting: true` 内置面板，而 ArtPlayer 的内置面板**只有**
  // 播放速度 / 画面比例 / 镜像 / 清晰度（没有字幕、没有音轨）。
  //
  // 也就是说：**字幕轨切换 / 外挂字幕 / ASS 样式在原版里不存在**。
  //
  // 我们是 libmpv 后端，mpv 原生支持这些 —— 本次是**能力补齐**。
  // 底下的属性名全部来自 mpv 手册（`DOCS/man/options.rst`），
  // 不是猜的：
  // ```text
  // sid                Display the subtitle stream specified by <ID>
  // sub-add <file>     Add a subtitle file to the list of external subtitles
  // sub-file=<file>    CLI/config 别名，等于 sub-files-append
  // sub-visibility     Toggle subtitle visibility
  // sub-font-size      unit is the size in scaled pixels at a window height of 720
  // sub-color          r/g/b，each component in the range 0.0 to 1.0
  // sub-border-color   alias for sub-outline-color
  // sub-border-size    alias for sub-outline-size
  // sub-margin-y       distance from the bottom
  // sub-ass-override   no|yes|scale|force|strip
  // ```

  /// 选一条字幕轨（`"no"` = 关闭字幕）
  ///
  /// [userInitiated] 为 false 时表示"起播自动选第一条真实轨" ——
  /// 那种情况不设置 `_pickSubtitleMadeByUser`（用户没做选择）。
  Future<void> _applySubtitleTrack(
    String id, {
    required bool userInitiated,
  }) async {
    try {
      /*
       * ⚠️ 用 mpv 的 `sid` 属性而不是 media_kit 的 `setSubtitleTrack`
       *
       * 两条路都通，但 `setSubtitleTrack` 走的是 `_Track.id` →
       * `_setPropertyString('sid', track.id)`，中间多一层状态同步；
       * 而面板给的本来就是**裸 id 字符串**（`"no"` / `"1"` / `"auto"`），
       * 直接用属性更直接，也不依赖 media_kit 对"伪轨道"的处理方式。
       *
       * 项目先例：`delivery_test.dart:823` 也验证过
       * `setSubtitleTrack(const SubtitleTrack('auto', null, null))` 这条路 ——
       * 两条都能用，这里选**少一层**的。
       */
      final native = _player.platform;
      if (native is! NativePlayer) return;
      await native.setProperty('sid', id);
      /*
       * 选了具体轨就确保可见性打开
       *
       * `sub-visibility=no` 时即使 sid 指向有效轨也**不显示** ——
       * 用户从"关闭"切回某条轨时，不重开可见性就还是看不到字。
       */
      if (id != 'no') {
        await native.setProperty('sub-visibility', 'yes');
      }
      debugPrint('[PLAYER] 字幕轨 → $id');
    } catch (e) {
      debugPrint('[PLAYER] 切换字幕轨失败: $e');
    }
  }

  /// 加载**外挂字幕文件**（面板选完文件后回调）
  ///
  /// # 为什么用 `sub-add` 而不是 `setProperty('sub-file', path)`
  ///
  /// mpv 手册：
  /// > ``--sub-file`` is a CLI/config file only alias for ``--sub-files-append``.
  ///
  /// `sub-file` 是**追加**语义的别名，重复设置会**累积**（加载 3 个文件
  /// 就有 3 条外挂轨）。而我们要的是"换一条外挂字幕"，
  /// 所以用 `sub-add` 命令的 `select` 模式：
  /// ```text
  /// sub-add <url> [<flags> [<title> [<lang>]]]
  ///   flags: select  → 加进来并**立刻选中**
  /// ```
  /// 这样加载后自动切到新字幕（用户的直接意图就是"我要用这条"）。
  Future<void> _loadExternalSubtitle(String path) async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;

      /*
       * ⚠️ 先把已有的外挂轨删掉，避免累积
       *
       * `sub-remove` 删的是"当前选中的外挂字幕轨"。
       * 只在**确实加载过**时删（第一次加载时 sid 可能指向内嵌轨，
       * 删掉会把内嵌字幕弄丢）。
       */
      if (_externalSubtitle != null) {
        try {
          await native.command(['sub-remove']);
          debugPrint('[PLAYER] 已移除上一条外挂字幕');
        } catch (e) {
          debugPrint('[PLAYER] 移除旧外挂字幕失败（忽略）: $e');
        }
      }

      await native.command(['sub-add', path, 'select', '外挂字幕', 'auto']);
      await native.setProperty('sub-visibility', 'yes');

      if (mounted) {
        setState(() {
          _externalSubtitle = SubtitleTrack.uri(path, title: '外挂字幕');
          // 加载后 mpv 会把 sid 指到新轨，面板显示"已选中"
          _pickSubtitleMadeByUser = true;
        });
      }
      debugPrint('[PLAYER] ★ 外挂字幕已加载: $path');
      _flash('已加载外挂字幕');
    } catch (e) {
      debugPrint('[PLAYER] 加载外挂字幕失败: $e');
      // 如实报错 —— 静默失败会让用户以为"点了没反应"
      _flash('加载字幕失败：$e');
    }
  }

  /// 移除已加载的外挂字幕
  Future<void> _removeExternalSubtitle() async {
    try {
      final native = _player.platform;
      if (native is NativePlayer) {
        await native.command(['sub-remove']);
      }
    } catch (e) {
      debugPrint('[PLAYER] 移除外挂字幕失败: $e');
    }
    if (mounted) setState(() => _externalSubtitle = null);
    _flash('已移除外挂字幕');
  }

  /// 把面板里改的样式落到 mpv，并记进 `_mpvStyle`（面板立刻回显）
  Future<void> _setMpvStyle(String property, String value) async {
    try {
      final native = _player.platform;
      if (native is NativePlayer) {
        await native.setProperty(property, value);
      }
      if (mounted) {
        setState(() => _mpvStyle = {..._mpvStyle, property: value});
      }
      debugPrint('[PLAYER] 字幕样式 $property = $value');
    } catch (e) {
      debugPrint('[PLAYER] 设置 $property 失败: $e');
      _flash('设置失败：$e');
    }
  }

  /// 从 mpv **读回**当前样式值（打开面板前调）
  ///
  /// # 为什么不写死默认值
  ///
  /// mpv 的 `sub-font-size` 默认值在不同版本间变过（老版本 55、新版本 38）。
  /// 面板若写死一个数，用户一打开面板就会看到"我的字号被改了" ——
  /// 而且**没有做任何操作**。读回来才是诚实的。
  ///
  /// ⚠️ 读不到的项**不放**进 map（面板会显示"读不到"并禁用那一项），
  ///    而不是塞一个猜测值进去。
  Future<void> _readMpvStyle() async {
    final out = <String, String>{};
    try {
      final native = _player.platform;
      if (native is NativePlayer) {
        for (final k in _styleKeys) {
          try {
            final v = await native.getProperty(k);
            if (v.trim().isNotEmpty) out[k] = v.trim();
          } catch (_) {
            // 单个属性读不到不影响其它项
          }
        }
      }
    } catch (e) {
      debugPrint('[PLAYER] 读字幕样式失败: $e');
    }
    if (mounted) setState(() => _mpvStyle = out);
  }

  /// 起播后重设一遍**外挂字幕 + 样式**（mpv 换文件会复位 file-local 项）
  Future<void> _applySubtitleStyle() async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      // 外挂字幕是 file-local 的 —— 换集后必须重新 add
      final ext = _externalSubtitle;
      if (ext != null) {
        await native.command(['sub-add', ext.id, 'select', '外挂字幕', 'auto']);
        debugPrint('[PLAYER] 换集后重新挂载外挂字幕');
      }
      // 样式项（global）虽然会保留，但重设一次是幂等的、零代价
      for (final e in _mpvStyle.entries) {
        await native.setProperty(e.key, e.value);
      }
    } catch (e) {
      debugPrint('[PLAYER] 重设字幕样式失败（忽略）: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 音轨切换
  // ═══════════════════════════════════════════════════════════════════
  //
  // 原版同样**没有**这个 UI（见上面字幕那段的说明）。原版唯一的音轨
  // 处理是 DASH 音视频分离时的"外挂音轨"（`attachAudioTrack`，
  // `PlayerView.vue:1197`），那是**自动挂载**，不是"让用户选"。
  //
  // mpv 侧：
  // ```text
  // aid            Select audio track. auto selects the default, no disables audio.
  // track-list     全部轨（media_kit 已解析成 Tracks 对象）
  // ```

  /// 切一条音轨
  Future<void> _applyAudioTrack(String id) async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      await native.setProperty('aid', id);
      if (mounted) setState(() => _aidChosen = id);
      debugPrint('[PLAYER] 音轨 → $id');
    } catch (e) {
      debugPrint('[PLAYER] 切换音轨失败: $e');
    }
  }

  /// 把 media_kit 的轨列表转成面板要的 `PlayerTrackOption`
  ///
  /// # 为什么把 `auto` / `no` 放在**最前面**
  ///
  /// media_kit 的 `Tracks` 默认值里就有这两条伪轨道
  /// （`Tracks(subtitle: [SubtitleTrack('auto',...), SubtitleTrack('no',...)])`）。
  /// 它们不是真轨而是**控制项**：
  /// ```text
  /// auto  让 mpv 自己挑（手册：auto selects the default）
  /// no    关闭（手册：no disables subtitles）
  /// ```
  /// `delivery_test.dart:786-807` 记过这个坑：直接把 `tracks.subtitle.first`
  /// 当成"第一条字幕"会选中 `auto`，如果真实轨不在第一位就会**选到 `no`**
  /// （关闭字幕），表现为"字幕怎么都不出来"。
  ///
  /// 所以：**伪轨排前面**（用户一眼能看到"自动/关闭"），真轨排后面。
  List<PlayerTrackOption> _subtitleOptions() {
    final out = <PlayerTrackOption>[
      const PlayerTrackOption(id: 'auto', label: '自动'),
      const PlayerTrackOption(id: 'no', label: '关闭'),
    ];
    var n = 0;
    for (final s in _tracks.subtitle) {
      // 跳过伪轨（已经手工加了）
      if (s.id == 'auto' || s.id == 'no') continue;
      n++;
      out.add(
        PlayerTrackOption(
          id: s.id,
          label: (s.title == null || s.title!.trim().isEmpty)
              ? '字幕 $n'
              : s.title!.trim(),
          hint: _trackHint(s.language, s.codec),
        ),
      );
    }
    return out;
  }

  /// 音轨选项（同上）
  List<PlayerTrackOption> _audioOptions() {
    final out = <PlayerTrackOption>[
      const PlayerTrackOption(id: 'auto', label: '自动'),
      const PlayerTrackOption(id: 'no', label: '关闭'),
    ];
    var n = 0;
    for (final a in _tracks.audio) {
      if (a.id == 'auto' || a.id == 'no') continue;
      n++;
      out.add(
        PlayerTrackOption(
          id: a.id,
          label: (a.title == null || a.title!.trim().isEmpty)
              ? '音轨 $n'
              : a.title!.trim(),
          hint: _trackHint(a.language, a.codec),
        ),
      );
    }
    return out;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★ popover 的数据供给（2026-10-09，Owner 第 12 条）
  // ═══════════════════════════════════════════════════════════════════
  //
  //  清晰度 / 线路 / 字幕音轨这三类「选择类」操作现在都从弹窗改成了
  //  底栏上方的小面板。选项**直接复用**已有的 `_subtitleOptions()` /
  //  `_audioOptions()` / `_streams` —— 不另建一份映射，否则两处一定漂。

  /// 清晰度 / 线路的 popover 选项
  ///
  /// ⚠️ `_streams` 既是「线路」也是「清晰度」的那份数据（一条线路对应一种清晰度），
  ///   所以两枚按钮看到的是同一张表 —— 但入口分开：用户按「清晰度」想到的是
  ///   画质档位，按「线路」想到的是源。**表一样、入口不同**是 B 站的形态。
  List<PopoverOption<String>> _qualityPopoverOptions() {
    final cur = _current;
    return [
      for (final s in _streams)
        PopoverOption<String>(
          value: s.url,
          label: s.label ?? s.quality ?? '默认线路',
          hint: s.quality,
          checked: cur != null && cur.url == s.url,
        ),
    ];
  }

  /// 按 url 切流（popover 里选中一项 ⇒ 与旧抽屉同一动作）
  void _pickQualityByLabel(String url) {
    for (final s in _streams) {
      if (s.url == url) {
        unawaited(_startPlayback(s));
        return;
      }
    }
  }

  /// 字幕 / 音轨的分组 popover
  Map<String, List<PopoverOption<String>>> _trackPopoverGroups() {
    final subs = _sidChosen;
    final aud = _aidChosen;
    return {
      '字幕': [
        for (final o in _subtitleOptions())
          PopoverOption<String>(
            value: o.id,
            label: o.label,
            hint: o.hint,
            checked: subs == o.id,
          ),
      ],
      '音轨': [
        for (final o in _audioOptions())
          PopoverOption<String>(
            value: o.id,
            label: o.label,
            hint: o.hint,
            checked: aud == o.id,
          ),
      ],
    };
  }

  void _pickTrackFromPopover(String group, String id) {
    if (group == '字幕') {
      unawaited(_applySubtitleTrack(id, userInitiated: true));
    } else {
      unawaited(_applyAudioTrack(id));
    }
  }

  /// 投屏那一项（**用真的 CastButton**，不是一枚自己画的图标 ——
  /// 代理、扫描电视、状态轮询都在它内部，见 cast_button.dart 的类文档）
  MoreMenuEntry? get castEntry {
    final url = _current?.url ?? '';
    if (url.isEmpty) return null;
    return MoreMenuEntry(
      label: '投屏',
      icon: Icons.cast,
      onTap: _openCast,
      trailing: CastButton(
        url: url,
        headers: _current?.httpHeaders ?? const <String, String>{},
        title: _castTitle,
        iconSize: 16,
      ),
    );
  }

  /// 选集面板这一端是**右侧侧栏**还是**底部面板**
  ///
  /// ★ 判据（几何，不是设备类型）：**宽 ≥ 高**（横屏）走侧栏，竖屏走底部面板。
  ///   手机横屏（915×412）与桌面、TV 都落进侧栏那一支 —— 它们都是"旁边还有地方"。
  bool _episodePanelIsDrawer(BuildContext context) {
    final s = MediaQuery.sizeOf(context);
    return s.width >= s.height;
  }

  /// 「更多」浮层的分组清单
  ///
  /// ★ 每一次调用都**现算**（不缓存）—— 组里有哪些项取决于集数 / 直播 / 画中画
  ///   是否可用，缓存会显示过期项。整页每 tick 重建时也无所谓：
  ///   这只是一堆不可变的小对象，分配成本可忽略。
  List<MoreMenuGroup> _moreMenuGroups(BuildContext context) {
    return [
      MoreMenuGroup('画面', [
        MoreMenuEntry(
          label: '截图',
          icon: Icons.photo_camera,
          onTap: () => unawaited(_takeScreenshot()),
        ),
        MoreMenuEntry(
          label: '画面缩放',
          icon: Icons.zoom_in_map,
          hint: '${_videoZoomPct.round()}%',
          onTap: () => setState(() => _zoomOpen = !_zoomOpen),
        ),
        if (_pipSupported)
          MoreMenuEntry(
            label: _pipActive ? '退出画中画' : '画中画',
            icon: _pipActive
                ? Icons.picture_in_picture_alt
                : Icons.picture_in_picture_alt_outlined,
            onTap: () => unawaited(_togglePip()),
          ),
        if (castEntry case final e?) e,
      ]),
      MoreMenuGroup('播放', [
        MoreMenuEntry(
          label: '播放设置',
          icon: Icons.settings,
          onTap: () => unawaited(_openSettings()),
        ),
        if (!_isLive)
          MoreMenuEntry(
            label: '字幕搜索',
            icon: Icons.search,
            onTap: () => _openSubtitlePanel(),
          ),
        MoreMenuEntry(
          label: '换源',
          icon: Icons.travel_explore,
          onTap: () => unawaited(_openSwitchSource()),
        ),
      ]),
      MoreMenuGroup('弹幕', [
        MoreMenuEntry(
          label: _danmakuEnabled ? '关闭弹幕' : '开启弹幕',
          icon: _danmakuEnabled ? Icons.subtitles : Icons.subtitles_off,
          onTap: () => unawaited(_toggleDanmaku()),
        ),
        MoreMenuEntry(
          label: '弹幕设置',
          icon: Icons.tune,
          hint: _danmakuLoading ? '加载中…' : null,
          onTap: _openDanmakuSettings,
        ),
      ]),
      if (!_isLive)
        MoreMenuGroup('剧集', [
          MoreMenuEntry(
            label: '片头片尾',
            icon: Icons.content_cut,
            onTap: () => unawaited(_openSkipDialog()),
          ),
          if (_prevEpisode != null)
            MoreMenuEntry(
              label: '上一集',
              icon: Icons.skip_previous,
              onTap: () => unawaited(_gotoPrevEpisode()),
            ),
          if (_nextEpisode != null)
            MoreMenuEntry(
              label: '下一集',
              icon: Icons.skip_next,
              onTap: () => unawaited(_gotoNextEpisode()),
            ),
          if (_isLive && widget.onLiveChannels != null)
            MoreMenuEntry(
              label: '所有直播',
              icon: Icons.live_tv,
              onTap: _toggleLiveChannels,
            ),
        ]),
    ];
  }

  /// 拼「语言 · 编码」这一小行提示（两者都没有时返回 null）
  String? _trackHint(String? lang, String? codec) {
    final parts = <String>[];
    if (lang != null && lang.trim().isNotEmpty && lang != 'null') {
      parts.add(lang.trim());
    }
    if (codec != null && codec.trim().isNotEmpty && codec != 'null') {
      parts.add(codec.trim());
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 播放设置面板
  // ═══════════════════════════════════════════════════════════════════

  /// 打开设置面板
  ///
  /// # 为什么打开前要**先读一遍** mpv 样式
  ///
  /// 见 `_readMpvStyle` 的注释：不读的话面板只能猜默认值，
  /// 而 mpv 的默认值在版本间变过 —— 猜就等于"打开面板就改了用户观感"。
  ///
  /// # 为什么**不**暂停播放（与「片头片尾」弹窗的区别）
  ///
  /// 原版的 `openSkipDialog` 会暂停（因为它开了**第二个播放器**做预览，
  /// 不暂停会有两个声音）。设置面板里没有第二个播放器，
  /// 用户调字号时**需要看着画面**才知道调得对不对 —— 暂停反而没法调。
  /// 这一点与原版不冲突：原版 ArtPlayer 的设置面板也是**不暂停**的。
  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ dandanplay 弹幕（task-13 ⑦）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 用户原话：
  // > 接入一下 dandanplay 的弹幕功能
  //
  // 分工：core/danmaku.dart = 协议/签名/解析/排版；
  //       widgets/danmaku_overlay.dart = 自驱帧循环的渲染层；
  //       widgets/danmaku_settings_dialog.dart = 纯 UI 面板；
  //       **这里** = 接线 + 状态归属（一次请求的 loading/error/结果）。

  /// 拿弹幕客户端（懒建）
  ///
  /// ⚠️ appId / appSecret 是 `DandanplayClient` 的**构造快照**
  ///    （见 core/danmaku.dart 的 ctor）⇒ 用户在面板里改了凭证，
  ///    必须把旧实例 close 掉重建，否则改了等于没改。
  DandanplayClient _ensureDanmakuClient() {
    final c = _danmakuClient;
    if (c != null) return c;
    final n = DandanplayClient();
    _danmakuClient = n;
    return n;
  }

  /// 凭证改了 ⇒ 必须重建客户端（构造快照的原因见上）
  void _resetDanmakuClient() {
    _danmakuClient?.close();
    _danmakuClient = null;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  task-18 ③④⑤：片段下载 / 日志
  // ═══════════════════════════════════════════════════════════════════

  /// 下载时给文件起的名字。
  ///
  /// 直接复用 [_danmakuFileName]：它做的就是「标题去掉扩展名」，
  /// 而 StreamCandidate（core/models.dart:692）**没有** fileName 字段
  /// （能力限制，见上面那段注释）—— 所以下载文件名只能由标题推。
  String get _clipFileName {
    final base = _danmakuFileName.trim();
    final safe = base.isEmpty ? 'clip' : base;
    return '$safe.mp4';
  }

  /// ③ 的**真实调用方**：把当前这一集的流下载进片段缓存目录。
  ///
  /// 用的是**当前流**（_current）的 url 与 headers —— 与播放器同一条地址，
  /// 这样服务端要的 Referer / UA 一个都不少（理由见 _startPlayback）。
  Future<void> _downloadClip() async {
    final st = _current;
    if (st == null) {
      _flash('还没有可下载的流（先起播）');
      return;
    }
    final name = _clipFileName; // 只当「下载文件叫什么」
    final key = st.url; // ★ 去重键 = 流地址（同一集的真正身份）
    /*
     * ★ 按**流地址**去重，不是全局互斥 —— 理由见 _clipRunning 的注释。
     *   同一集的同一条流重复点：这里挡掉并如实提示；
     *   换一集 / 换源再点：放行，于是两个 download() 真的同时在池子里跑。
     */
    if (_clipRunning.contains(key)) {
      _flash('这一集已经在下载了');
      return;
    }
    setState(() {
      _clipRunning.add(key);
      _clipDownloadError = null;
    });
    AppLog.write(
      'DL',
      '开始下载 $name'
          '（并发 ${ClipDownloader.concurrencyLabel(ClipDownloader.concurrency)}）'
          '（同时在跑 ${_clipRunning.length} 个）',
    );
    try {
      final r = await ClipDownloader.download(
        url: st.url,
        fileName: name,
        headers: st.headers,
      );
      AppLog.write(
        'DL',
        '完成 ${r.path}（${r.bytes} 字节 / ${r.elapsed.inMilliseconds}ms）',
      );
      if (!mounted) return;
      setState(() {
        _clipDownloaded = true;
        _clipDownloadError = null;
      });
      _flash('已下载 ${r.mb.toStringAsFixed(1)} MB');
    } catch (e) {
      AppLog.write('DL', '失败：$e');
      if (!mounted) return;
      setState(() => _clipDownloadError = '$e');
      _flash('下载失败');
    } finally {
      if (mounted) {
        setState(() => _clipRunning.remove(key));
      } else {
        // 页面已经销毁：不再 setState，但集合必须清掉（本页对象可能被复用）
        _clipRunning.remove(key);
      }
    }
  }

  /// 在系统文件管理器里打开片段缓存目录。
  ///
  /// ⚠️ 这是**本仓库第一处** spawn 外部进程（全 lib grep Process.run /
  ///    Process.start / explorer = 0 命中）。为什么还是要做：③ 下载完
  ///    之后如果用户看不到那个文件，「下载成功」就只是一句文本，
  ///    他没法自己验证 —— 而这个按钮能让文件真的出现在眼前。
  Future<void> _openClipDir() async {
    try {
      final dir = await ClipDownloader.cacheDir();
      final d = Directory(dir);
      if (!await d.exists()) await d.create(recursive: true);
      final strategy = clipDirOpenStrategy(
        isWindows: Platform.isWindows,
        isMacOS: Platform.isMacOS,
        isLinux: Platform.isLinux,
      );
      if (strategy == 'explorer') {
        await Process.run('explorer', [d.path]);
      } else if (strategy == 'open') {
        await Process.run('open', [d.path]);
      } else if (strategy == 'xdg-open') {
        await Process.run('xdg-open', [d.path]);
      } else {
        /*
         * ★★★ task-25 C：安卓等**没有桌面文件管理器入口**的平台。
         *
         * 改前这里只 `_flash('当前平台不支持打开目录：$dir')` 就 return ——
         * 用户点了按钮只看到一句「不支持」，既没打开也没拿到路径。
         * 这正是 `.probe/t24/AUDIT.md` 台账第 32 行的「未适配」。
         *
         * # 为什么落在「复制路径」而不是 Intent / FileProvider
         * 那条路要动 `android/app/src/main/AndroidManifest.xml`、
         * 新增 `res/xml/file_paths.xml`、改 `MainActivity.kt` ——
         * 三处都在本任务的写域之外（Lead 裁决），且 `share_plus`
         * 不在依赖里（不许新增依赖）。
         *
         * ⚠️ 路径是**应用私有目录**（/data/user/0/<pkg>/files/clip-cache），
         *    别的应用打不开它；但复制到剪贴板至少让用户能贴到别处用，
         *    比「一无所获」是**可用行为**。
         */
        await Clipboard.setData(ClipboardData(text: d.path));
        AppLog.write('DL', '打开缓存目录（本平台无文件管理器入口，已复制路径）$dir');
        _flash('已复制路径：$dir');
        return;
      }
      AppLog.write('DL', '打开缓存目录 $dir');
    } catch (e) {
      _flash('打开目录失败：$e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  task-21 P1-30：视频截图（底栏相机按钮 / PC 键 S 的同一个落点）
  // ═══════════════════════════════════════════════════════════════════

  /// 截图当前画面，存进 `<dataDir>/shots/shot-<日期>-<时间>.jpg`。
  ///
  /// # 为什么落点是「控制条按钮 + S 键」两处，而不是播放设置面板
  /// 截图**没有任何可选项**（没有"存到哪 / 存多大 / 什么格式"）。
  /// 面板里放一行「截图」等于把一个动作藏进设置里 —— 原版 ArtPlayer
  /// 也没有把它放进齿轮面板。见 PLAN §3.1。
  ///
  /// # 为什么失败路径这么多
  /// media_kit 1.2.6 的 `Player.screenshot()`（real.dart:1165）有三个
  /// 必须显式接住的形态：
  /// ```text
  /// ① 没有画面（还没渲染出帧）→ 返回 **null**，不抛异常
  /// ② 播放器已 dispose        → 抛 AssertionError('[Player] has been disposed')
  /// ③ format 非法             → 抛 ArgumentError（我们传固定合法值，永不触发，
  ///                             但仍然落 catch —— 将来谁改了那个值也不会静默）
  /// ```
  /// 还有第四个：不是异常，但同样致命 —— `await waitForPlayerInitialization`
  /// 在播放器进 `idle-active` 之前**永不完成** ⇒ 用 [_shotBusy] 防重入。
  ///
  /// # 为什么提示里必须给**完整路径**
  /// 同 `_exportLog()` 的铁律：只说"已截图"而不说存到哪，用户没法自己验证 ——
  /// 这个按钮的全部价值就是那个文件真的存在。
  Future<void> _takeScreenshot() async {
    if (_shotBusy) return;
    _shotBusy = true;
    _screenshotCalls++; // ★ 只读探针
    try {
      // `includeLibassSubtitles: true` —— 让硬字幕也进画面
      // （`libass: true` 已经在 PlayerConfiguration 里开了）。
      // ⚠️ Android 侧还缺 `libassAndroidFont` / `libassAndroidFontName`
      // （本项目从未设置），所以 **Android 大概率带不上字幕** ——
      // 这一点在报告里如实标注为能力限制，不假装两端一致。
      final Uint8List? bytes = await _player.screenshot(
        format: 'image/jpeg',
        includeLibassSubtitles: true,
      );
      if (bytes == null || bytes.isEmpty) {
        AppLog.write('DL', '截图失败：screenshot() 返回空（还没有画面）');
        _flash('截图失败：还没有画面');
        return;
      }
      final dir = await ClipDownloader.shotsDir();
      final f = await ClipDownloader.uniqueShotFile(Directory(dir));
      await f.writeAsBytes(bytes, flush: true);
      AppLog.write(
        'DL',
        '截图 ${f.path}（${bytes.length} 字节，位置 ${_position.inSeconds}s）',
      );
      _flash('已截图 ${bytes.length} 字节 → ${f.path}');
      _showControls();
    } catch (e) {
      AppLog.write('DL', '截图失败：$e');
      _flash('截图失败：$e');
    } finally {
      _shotBusy = false;
    }
  }

  /// 当前这集拿去匹配弹幕库的文件名
  ///
  /// # 为什么只能按文件名匹配（能力限制，不是 bug）
  ///
  /// dandanplay 的 `POST /api/v2/match` 要的是**真实视频文件**的
  /// 文件名 + 前 16MB 的 MD5 + 文件大小；而我们这边
  /// `StreamCandidate`（core/models.dart）只有一条**流地址**，
  /// 既拿不到 fileHash 也拿不到 fileSize ⇒ 只能退化成
  /// `matchMode: fileNameOnly` 的"只看文件名"匹配。
  ///
  /// 去掉扩展名：dandanplay 库里存的是「某某 第01集.mp4」这种，
  /// 而我们这边的 `title` 是「某某 第01集」——带上扩展名反而匹配不到。
  String get _danmakuFileName {
    final t = _liveTitle.trim();
    final dot = t.lastIndexOf('.');
    if (dot > 0 && dot < t.length - 1 && t.length - dot <= 6) {
      return t.substring(0, dot);
    }
    return t;
  }

  /// 起播后取一次弹幕（不阻塞播放）
  Future<void> _loadDanmaku() => _loadDanmakuNamed(_danmakuFileName);

  /// 按指定文件名取一次弹幕
  ///
  /// ⚠️ **没配凭证也照发**：本地短路会把 dandanplay 的
  ///    `X-Error-Message` 这条唯一能说明"为什么失败"的信息永久埋掉
  ///    （见 core/danmaku.dart 文件头的错误透传策略）。
  Future<void> _loadDanmakuNamed(String fileName) async {
    if (!_danmakuEnabled) return;
    /*
     * ★★★ task-31 ④：绑了 B 站 ⇒ **B 站优先**，dandanplay 一条请求都不发。
     *
     * 没绑（或这一集没有 cid）⇒ 直接往下走 —— 行为与接线前**逐字节相同**。
     * 解绑后下一次起播就自动退回 dandanplay。
     */
    final biliBind = loadBinding(widget.provider, widget.id);
    if (biliBind != null && !biliBind.isEmpty) {
      final cid = biliBind.cidFor(_epIndex);
      if (cid > 0) {
        await _loadBiliDanmaku(cid);
        return;
      }
      /*
       * ★★ Owner 第 9 条（2026-10-09）：绑了 B 站、但这一集没有 cid ⇒ **必须说出来**
       *
       * # 改前这里是**静默**落空（`}` 直接闭合）
       * ```text
       * 用户绑了 B 站 ⇒ 下面 dandanplay 那条必定没有凭证 ⇒ 403 ⇒
       *   _flash('弹幕失败：Missing Authentication Headers ｜ 弹幕服务没收到凭证…')
       * 用户看到这句会以为「B 站要登录」——**完全不是**。
       * 真实原因是「这一集没匹配到分 P」⇒ 两件事必须分开说。
       * ```
       *
       * # ★ 为什么"B 站搜索免登录"不是问题所在（诊断时先排除了这条）
       * ```text
       * lib/core/bili/bili_api.dart:3 记着：B 站搜索接口本来就免登录，
       * 未登录一样能搜。所以用户报的「未登录应该都能搜索」**本来就成立** ——
       * 挡路的从来不是登录态，而是「绑定了 B 站之后就不再走搜索」这条路。
       * ```
       *
       * # 为什么是 _flash 而不是角标/弹窗
       * 与下面那条失败提示**同一条通道**（`_flash` → `_tip` → `_TipBubble`）：
       * 用户先看到「已改用 dandanplay」，紧接着看到 dandanplay 的失败 ——
       * 两句话连起来才是一个完整因果，用户就知道该去查分 P 而不是去登录 B 站。
       *
       * ⚠️ 这句话**逐字**是 `test/zz_t3_flash_probe_test.dart:46` 的 `kTipFallThrough`，
       *    改一个字那个探针就会红（它是**故意**钉住这条文案的）。
       */
      _flash('B 站弹幕：这一集没匹配到分 P（cid），已改用 dandanplay');
    }

    /*
     * ★★★ 2026-10-09（Owner：「bilibili都支持搜索了,也选择了,但就是没显示弹幕这个流程有问题」）
     *
     * # 这里补上**缺失的那一步**：没绑定时自动去 B 站搜一次
     * ```text
     * 改前的两条路：
     *   ① 有绑定      ⇒ 用绑定（走上面那个 if）；
     *   ② 没绑定      ⇒ **直接落到下面的 dandanplay** ——
     *      而 dandanplay 要 AppId/AppSecret，没配就 403
     *      ⇒ 屏幕上那句「弹幕失败：Missing Authentication Headers」。
     *
     * 用户看到的观感就是「B 站明明能搜、我也选了，怎么还是没弹幕」——
     * 因为**自动这条路压根没走搜索**：搜索只有用户手动点面板才会触发。
     * ```
     *
     * # 为什么免登录就能搜（不是"登录了才行"）
     * ```text
     * 实测 2026-10-09（无 Cookie）：
     *   comment.bilibili.com/279786.xml → 200，1200 条弹幕
     * B 站搜索与弹幕 XML **都免登录** ⇒ 缺的从来不是登录态，是这一步。
     * ```
     *
     * # 失败要**如实**、且不挡 dandanplay
     * ```text
     * autoBindBySearch 返回 null（没匹配到 / 网络失败）⇒ 什么都不说，
     * 继续往下走 dandanplay —— 行为与改前**完全一致**，
     * 不会因为多了这一步而让原本能用 dandanplay 的用户变差。
     * ```
     */
    if (_danmakuEnabled && biliBind == null) {
      final ok = await _autoBindBili();
      if (ok) return;
    }
    final token = ++_danmakuFetchToken;
    final client = _ensureDanmakuClient();
    if (mounted) {
      setState(() {
        _danmakuLoading = true;
        _danmakuError = null;
        _danmakuSettings = _danmakuSettings.copyWith(
          loading: true,
          clearError: true,
        );
      });
    }
    try {
      final res = await client.loadFor(
        fileName: fileName,
        videoDuration: _duration.inSeconds,
      );
      if (!mounted || token != _danmakuFetchToken) return;
      setState(() {
        _danmakuComments = res.comments;
        _danmakuStatus = res.summary;
        _danmakuError = null;
        _danmakuErrorAt = null;
        _danmakuLoading = false;
        _danmakuSettings = _danmakuSettings.copyWith(
          loading: false,
          clearError: true,
          status: res.summary,
        );
      });
    } on DanmakuException catch (e) {
      if (!mounted || token != _danmakuFetchToken) return;
      setState(() {
        _danmakuComments = const <DanmakuComment>[];
        _danmakuStatus = '';
        _danmakuError = e;
        _danmakuErrorAt = DateTime.now();
        _danmakuLoading = false;
        _danmakuSettings = _danmakuSettings.copyWith(
          loading: false,
          error: e,
          status: '',
        );
      });
      /*
       * ★ 把原文直接糊在画面上（角标）+ 在面板的"详情"里给全文
       *
       * 不吞、不改写、不翻译成"网络错误" —— 用户要看到的是
       * dandanplay 自己说的那句话（例如 Missing Authentication Headers）。
       */
      _armDanmakuBadgeExpiry();
      final why = e.xErrorMessage.isNotEmpty ? e.xErrorMessage : e.message;
      /*
       * ★★ Owner 第 1 条（2026-10-08）：报错要**可操作**
       *
       * 用户截图里只有一句「弹幕失败：Missing Authentication Headers」——
       * 那是 dandanplay 自己说的话，它没错，但**用户看不懂要做什么**。
       * 现在 `DanmakuException.hint`（core/danmaku.dart）会把 403/401 翻成
       * 中文指引（缺凭证 / 凭证不对），这里把**标题**带在提示条上，
       * 全文与一键入口在「弹幕设置」面板里（见那里的 `_errorSection`）。
       *
       * ⚠️ 不把 hint.text 全文塞进提示条：它有一两百字，而提示条 1.2 秒
       *    就消失 —— 塞进去等于没写。标题 + 面板入口才是能用的形态。
       */
      final h = e.hint;
      /*
       * ★★ Owner 第 9 条：点明**这句失败是谁的凭证**
       *
       * # 为什么非加不可（Lead 追加 2）
       * ```text
       * 走到这一行 = dandanplay 这条路失败了。而**绑了 B 站的用户**
       * 看到「弹幕服务没收到凭证」会去 B 站找 AppId —— 找错地方，
       * 因为 B 站那侧压根不用填 AppId（bili_api.dart:3：搜索免登录）。
       * 「没收到凭证」这四个字里的"凭证"指的是 **dandanplay 开放平台**
       * 的 AppId/AppSecret，必须写出来，否则提示是**指向错误**的。
       * ```
       *
       * ⚠️ 括号里那半句**逐字**是 `test/zz_t3_flash_probe_test.dart:43` 的
       *    `kTipAfter`（完整句是「弹幕失败：…（打开弹幕设置可一键处理；
       *    这是 dandanplay 的凭证，与 B 站弹幕无关）」）。
       * ⚠️ 公共前缀 `'弹幕失败：… （打开弹幕设置可一键处理'` **一个字符都没动** ——
       *    那是 t100/t103 既有断言面（探针 :147-149 专门守着这条）。
       */
      _flash(
        h == null
            ? '弹幕失败：$why'
            : '弹幕失败：$why ｜ ${h.title}（打开弹幕设置可一键处理；这是 dandanplay 的凭证，与 B 站弹幕无关）',
      );
    } catch (e) {
      if (!mounted || token != _danmakuFetchToken) return;
      _armDanmakuBadgeExpiry();
      final wrapped = DanmakuException(e.toString());
      setState(() {
        _danmakuComments = const <DanmakuComment>[];
        _danmakuStatus = '';
        _danmakuError = wrapped;
        _danmakuErrorAt = DateTime.now();
        _danmakuLoading = false;
        _danmakuSettings = _danmakuSettings.copyWith(
          loading: false,
          error: wrapped,
          status: '',
        );
      });
      _flash('弹幕失败：$e');
    }
  }

  /// 面板开着时把渲染层的实时读数刷进面板（每秒一次，开销可忽略）
  void _refreshDanmakuReadout() {
    if (!mounted || !_danmakuSheetOpen) return;
    final st = debugDanmakuLastStats;
    final n = st?.visible ?? 0;
    final lanes = st?.laneCount ?? 0;
    final dropped = st?.dropped ?? 0;
    if (n == _danmakuSettings.count &&
        lanes == _danmakuSettings.lanes &&
        dropped == _danmakuSettings.dropped) {
      return;
    }
    setState(() {
      _danmakuSettings = _danmakuSettings.copyWith(
        count: n,
        lanes: lanes,
        dropped: dropped,
      );
    });
  }

  /// 底栏「弹幕」按钮：开 / 关
  Future<void> _toggleDanmaku() async {
    final next = !_danmakuEnabled;
    DanmakuConfig.setEnabled(next);
    if (!next) _danmakuFetchToken++; // 丢弃在途响应
    setState(() {
      _danmakuEnabled = next;
      _danmakuSettings = _danmakuSettings.copyWith(enabled: next);
      if (!next) {
        _danmakuComments = const <DanmakuComment>[];
        _danmakuError = null;
        _danmakuStatus = '';
        _danmakuLoading = false;
      }
    });
    if (next) {
      _flash('弹幕已开启');
      await _loadDanmaku();
    } else {
      _flash('弹幕已关闭');
    }
  }

  /// 执行 `DanmakuHint.action`（Owner 第 1 条）
  ///
  /// 面板只把 `DanmakuHintAction` 原样递出来，**开关谁**由宿主决定 ——
  /// 面板不认识 `_danmakuSheetOpen` / `_biliSheetOpen`，也不该认识。
  ///
  /// ★ 缺凭证那条指引**两个开关都是 true**：用户可能选"去申请凭证"，
  ///   也可能选"改用 B 站弹幕"（后者不需要那对凭证）。两个面板都给，
  ///   让用户自己选 —— 直接把他扔进某一个里等于替他做了决定。
  void _runDanmakuHintAction(DanmakuHintAction a) {
    if (a.openDanmakuSettings) _openDanmakuSettings();
    if (a.openBiliSheet) _openBiliSheet();
  }

  /// 打开弹幕设置面板（不暂停播放 —— 与播放设置面板同一原则）
  void _openDanmakuSettings() {
    final st = debugDanmakuLastStats;
    setState(() {
      _danmakuSheetOpen = true;
      _danmakuSettings = DanmakuSettingsState.fromPrefs().copyWith(
        loading: _danmakuLoading,
        error: _danmakuError,
        status: _danmakuStatus,
        count: st?.visible ?? 0,
        lanes: st?.laneCount ?? 0,
        dropped: st?.dropped ?? 0,
      );
    });
  }

  void _setDanmakuEnabled(bool v) {
    DanmakuConfig.setEnabled(v);
    setState(() {
      _danmakuEnabled = v;
      _danmakuSettings = _danmakuSettings.copyWith(enabled: v);
    });
    if (v) {
      unawaited(_loadDanmaku());
    } else {
      _danmakuFetchToken++;
      setState(() {
        _danmakuComments = const <DanmakuComment>[];
        _danmakuError = null;
        _danmakuStatus = '';
        _danmakuLoading = false;
      });
    }
  }

  void _setDanmakuAppId(String v) {
    DanmakuConfig.setAppId(v);
    _resetDanmakuClient();
    setState(() => _danmakuSettings = _danmakuSettings.copyWith(appId: v));
  }

  void _setDanmakuAppSecret(String v) {
    DanmakuConfig.setAppSecret(v);
    _resetDanmakuClient();
    setState(() => _danmakuSettings = _danmakuSettings.copyWith(appSecret: v));
  }

  void _setDanmakuFontScale(double v) {
    DanmakuConfig.setFontScale(v);
    setState(() => _danmakuSettings = _danmakuSettings.copyWith(fontScale: v));
  }

  void _setDanmakuOpacity(double v) {
    DanmakuConfig.setOpacity(v);
    setState(() => _danmakuSettings = _danmakuSettings.copyWith(opacity: v));
  }

  void _setDanmakuSpeed(double v) {
    DanmakuConfig.setSpeed(v);
    setState(() => _danmakuSettings = _danmakuSettings.copyWith(speed: v));
  }

  void _setDanmakuArea(double v) {
    DanmakuConfig.setArea(v);
    setState(() => _danmakuSettings = _danmakuSettings.copyWith(area: v));
  }

  void _clearDanmakuCredentials() {
    DanmakuConfig.clearCredentials();
    _resetDanmakuClient();
    _danmakuFetchToken++;
    setState(() {
      _danmakuSettings = _danmakuSettings.copyWith(
        appId: '',
        appSecret: '',
        clearError: true,
      );
      _danmakuComments = const <DanmakuComment>[];
      _danmakuError = null;
      _danmakuStatus = '';
      _danmakuLoading = false;
    });
    _flash('已清除弹幕凭证');
  }

  void _reloadDanmaku() {
    if (!_danmakuEnabled) {
      // 面板里直接点「重新取一次」= 用户就是想要弹幕 ⇒ 顺手开开关
      _setDanmakuEnabled(true);
      return;
    }
    unawaited(_loadDanmaku());
  }

  /// 弹幕层左上角的角标（**只在加载中 / 失败时**出现）
  ///
  /// 成功时不显示 —— 用户要看的是画面，不是「N 条弹幕」。
  /// 失败时必须显示：否则用户只会觉得"弹幕坏了"，
  /// 而实际上往往只是没填 AppId（原文见 core/danmaku.dart 的错误透传策略）。
  String? get _danmakuBadge {
    if (!_danmakuEnabled) return null;
    if (_danmakuLoading) return '弹幕加载中…';
    /*
     * ★★★ 2026-10-09（Owner：「这个弹幕失败一直也不消失」）
     *
     * # 用户报的是哪一条
     * ```text
     * 截图上是两条**叠在一起**的：
     *   ① _flash 那条（「…（打开弹幕设置可一键处理；这是 dandanplay 的凭证…）」）
     *      —— 它 1.2 秒就消失，不是用户说的那个；
     *   ② ★ 本角标 —— 它**故意常驻**（见下面 4601 的旧注释），
     *      而用户读作「一直也不消失」。
     * ```
     *
     * # 为什么"常驻"这个设计本身是错的
     * ```text
     * 旧注释的理由是"失败时必须显示，否则用户只会觉得弹幕坏了"。
     * 那个理由**在刚失败时成立**，但它没说"显示多久"。
     * 弹幕角标画在**画面上**，永久糊在那里 = 用户每看一集都被它挡一次；
     * 而用户其实**已经知道了**（他看过一眼了）。
     * ```
     *
     * # 改法：给失败态一个**会自己走掉**的形态
     * ```text
     * 失败 ⇒ 记下失败时刻，角标显示 [kDanmakuBadgeFailMs] 毫秒后自动隐藏。
     * 用户点一下角标 ⇒ 立刻隐藏（不用等）。
     * 下一次起播/换集 ⇒ 重新计时（新的一集该重新告诉他一次）。
     * ```
     *
     * ⚠️ "加载中"那条**不参与**计时：它本来就该在加载完自动消失，
     *    加超时反而会让慢网络下的正常加载被误判成"卡住了"。
     */
    if (_danmakuErrorAt != null &&
        DateTime.now().difference(_danmakuErrorAt!) >
            const Duration(milliseconds: kDanmakuBadgeFailMs)) {
      return null;
    }
    final e = _danmakuError;
    if (e != null) {
      final raw = e.xErrorMessage.isNotEmpty ? e.xErrorMessage : e.message;
      /*
       * ★★ Owner 第 1 条：角标**常驻**，所以能比提示条多给一个标题
       *   （「弹幕服务没收到凭证」比「Missing Authentication Headers」
       *   多告诉用户一件事：**这是凭证问题**）。
       * ⚠️ 仍然只给标题、不给全文 —— 角标画在视频画面上，
       *    全文会把画面糊住（见 danmaku_overlay.dart 的 `_badge`）。
       */
      final h = e.hint;
      return h == null ? '弹幕失败：$raw' : '弹幕失败：$raw ｜ ${h.title}';
    }
    if (_danmakuComments.isEmpty) {
      return _danmakuStatus.isEmpty ? null : '没有弹幕';
    }
    return null;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ task-31 ④：哔哩哔哩弹幕
  //
  //  面板（`BiliImportDialog`）是**纯 UI** —— 它自己不发请求、不读偏好，
  //  所有网络与落盘都在这一节里。这与 `DanmakuSettingsDialog` 同一分工。
  // ═══════════════════════════════════════════════════════════════════

  /// B 站 HTTP 客户端（懒建）
  ///
  /// ⚠️ 与 `_ensureDanmakuClient()` 分开：两个源的超时/追踪策略不同，
  ///    而且**没绑过的用户不该建这个连接池**。
  BiliApi _ensureBiliApi() => _biliApi ??= BiliApi();

  /// 打开「哔哩哔哩弹幕」面板
  void _openBiliSheet() {
    final b = loadBinding(widget.provider, widget.id);
    final manual = isManualBinding(widget.provider, widget.id);
    /*
     * ★ 用户上次手选的 P —— 直接用 `BiliPrefs.pageKey` 读写
     *
     * ⚠️ `bili_bind.dart` 里**没有** `loadPage/savePage`（只有键名工厂）。
     *    不往那边加函数：那是 t70 已跑绿的文件，而且这个键**只有播放页
     *    的这一个面板用**，加进 core 反而是把一个 UI 细节塞进模型层。
     */
    final page =
        int.tryParse(
          UiPrefs.get(BiliPrefs.pageKey(widget.provider, widget.id)) ?? '',
        ) ??
        0;
    setState(() {
      _biliSheetOpen = true;
      /*
       * ★ 同时收起弹幕设置面板
       *
       * 两个都是 `Positioned.fill` 的全屏 scrim，同时开着会让层序变成
       * 「谁后画的谁在上面」这种隐式规则 —— 而 Esc 链是显式的、只按一个
       * 顺序走 ⇒ 用户按 Esc 关掉的可能不是他看见的那一层。
       * 同一时刻只留一个 scrim，两处规则才对得上。
       */
      _danmakuSheetOpen = false;
      /*
       * ★ 记下「打开面板时是哪一集」
       *
       * 面板里的「导入并绑定 / 立即更新」会先比这个令牌 —— 中途换过集
       * 就说明那次操作的结果已经过时，必须丢掉（与 `_danmakuFetchToken`
       * 同一条规矩）。不记的话会出现「切到第 5 集了，面板却报第 3 集
       * 的弹幕条数」。
       */
      _biliPanelToken = _danmakuFetchToken;
      _biliState = _biliState.copyWith(
        loading: false,
        clearError: true,
        binding: b,
        clearBinding: b == null,
        pages: _biliInfoCache?.pages ?? const <BiliPage>[],
        selectedPage: page,
        episodeIndex: _epIndex,
        episodeTitle: _currentEpisodeTitle ?? '',
        episodeCount: _episodes.length,
        autoUpdate: biliAutoUpdateEnabled(),
        intervalMinutes: biliAutoUpdateInterval(),
        comments: _biliCid > 0 ? _danmakuComments.length : 0,
        /*
         * ★ Owner 第 2 条：每次开面板都把上一次的搜索结果清掉
         *
         * 留着的话，用户换了集再开面板，看到的是**上一集关键词**的
         * 结果列表 —— 点一条就绑到错误的视频上。宁可空着让他重搜。
         */
        searchResults: const <BiliSearchItem>[],
        /*
         * ★★★ 2026-10-09（Owner：「获取弹幕 bilibili和弹弹都应该支持 自动填入名字」）
         *
         * # 改前是空串，用户每次都要手打一遍剧名
         * ```text
         * 上面那条注释说的是"清掉**上一次搜索结果**"（对，那必须清）；
         * 但它把**关键词**也一起清了 ⇒ 用户打开面板看到的是空搜索框，
         * 得自己重新敲一遍标题 —— 而他正在看的这一集叫什么，
         * 应用明明知道（`_liveTitle`）。
         * ```
         *
         * # 为什么预填 `_liveTitle` 而不是 `_danmakuFileName`
         * ```text
         * `_danmakuFileName` 是给 dandanplay 的 match 用的（去掉了扩展名，
         * 有时还带"第01集"这种后缀）；而**搜索**要的是**作品名**，
         * 带上集数反而搜不准。`_liveTitle` 就是标题栏上那串，最贴近用户认知。
         * ```
         *
         * ⚠️ 用户点「搜索」前可以随便改 —— 这只是**预填**，不是锁定。
         */
        searchKeyword: _liveTitle.trim(),
        trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
      );
    });
    /*
     * ★ 手动绑过 ⇒ 顺手把 P 列表补上（面板要画「第几 P」那一行）
     *
     * ⚠️ 只查缓存里有没有，**不主动发请求** —— 打开面板不该有网络副作用
     *    （与 `DanmakuSettingsDialog` 同一条规矩）。
     */
    if (b != null && !b.isEmpty && _biliInfoCache == null && manual) {
      unawaited(_biliRefreshInfo(b));
    }
  }

  /// 补一次视频信息（P 列表 / 标题）
  ///
  /// ⚠️ `bindFromInput` 只回 `BiliBindOutcome`、**不回** `BiliVideoInfo`
  ///    （`.probe/bili/INTEGRATION.md` §4.4 自认的设计小瑕疵）。
  ///    给 `BiliBindOutcome` 加字段要动 `bili_bind.dart` 并让已跑绿的 t70
  ///    跟着改 ⇒ **不采**；这里多拉一次（服务端有缓存，实测 ~200 ms）。
  Future<void> _biliRefreshInfo(BiliBinding b) async {
    try {
      final ref = BiliRef(bvid: b.bvid, aid: b.aid);
      final info = await _ensureBiliApi().videoInfo(ref);
      if (!mounted) return;
      setState(() {
        _biliInfoCache = info;
        _biliState = _biliState.copyWith(
          info: info,
          pages: info.pages,
          trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
        );
      });
    } catch (e) {
      /*
       * ★ 补信息失败**不算绑定失败**
       *
       * 绑定本身（cid 对应表）已经落盘了，弹幕照样能拉 —— 只是面板上
       * 「第几 P」那一行暂时画不出来。把它报成错误会让用户以为绑定没成。
       */
      debugPrint('[BILI] 视频信息补拉失败（不影响绑定）: $e');
    }
  }

  /// 用户点了「搜索」（Owner 第 2 条）
  ///
  /// ★ 搜索**不落盘、不绑定** —— 它只把结果列表画出来，点其中一条才走
  ///   `_biliImport`（面板里那一格缩略图就是干这个的）。
  ///
  /// ⚠️ 令牌判据与 `_biliImport` 同一条：面板是"哪一集"打开的，
  ///   中途换集后回来的结果必须丢掉（否则会绑到错的那一集）。
  Future<void> _biliSearch(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    final token = _biliPanelToken;
    setState(() {
      _biliState = _biliState.copyWith(
        loading: true,
        busyLabel: '正在搜 B 站…',
        clearError: true,
        searchKeyword: kw,
        searchResults: const <BiliSearchItem>[],
      );
    });
    try {
      final list = await _ensureBiliApi().searchVideos(kw);
      if (!mounted || token != _biliPanelToken) return;
      setState(() {
        _biliState = _biliState.copyWith(
          loading: false,
          searchResults: list,
          trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
        );
      });
    } on DanmakuException catch (e) {
      if (!mounted || token != _biliPanelToken) return;
      setState(() {
        _biliState = _biliState.copyWith(
          loading: false,
          error: e,
          searchResults: const <BiliSearchItem>[],
          trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
        );
      });
    } catch (e) {
      if (!mounted || token != _biliPanelToken) return;
      _biliFail('搜索失败：$e');
    }
  }

  /// 用户点了「导入并绑定」
  Future<void> _biliImport(String input, int page) async {
    final token = _biliPanelToken;
    setState(() {
      _biliState = _biliState.copyWith(
        input: input,
        loading: true,
        busyLabel: '正在解析并绑定…',
        clearError: true,
      );
    });
    try {
      final api = _ensureBiliApi();
      final outcome = await bindFromInput(
        api: api,
        input: input,
        provider: widget.provider,
        id: widget.id,
        localTitle: _liveTitle,
        episodeTitles: [for (final e in _episodes) e.title],
        forcedPage: page,
        forcedEpisode: page > 0 ? _epIndex : -1,
        manual: true,
      );
      if (!mounted) return;
      /*
       * ★ 面板开着的时候用户换了集 ⇒ 这次导入的结果已经过时
       *
       * 绑定**照样落盘**（那是全局的，与集无关），但面板上的
       * 「当前这一集 / 条数」不能再往上写 —— 写了就是在撒谎。
       */
      if (token != _biliPanelToken) {
        debugPrint('[BILI] 导入完成时已经换集 ⇒ 不更新面板读数');
        setState(() {
          _biliState = _biliState.copyWith(
            loading: false,
            binding: outcome.binding,
          );
        });
        return;
      }
      await _biliRefreshInfo(outcome.binding);
      if (!mounted) return;
      final r = await _biliFetch(outcome.binding, force: true);
      if (!mounted) return;
      setState(() {
        _biliState = _biliState.copyWith(
          loading: false,
          binding: outcome.binding,
          info: _biliInfoCache,
          pages: _biliInfoCache?.pages ?? const <BiliPage>[],
          result: r,
          selectedPage: page,
          episodeIndex: _epIndex,
          episodeTitle: _currentEpisodeTitle ?? '',
          episodeCount: _episodes.length,
          comments: r.total,
          trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
        );
      });
      _biliApplyComments(r);
    } on ArgumentError catch (e) {
      // ★ 解析失败 ⇒ 一个请求都没发（`bindFromInput` 第一行就抛）
      _biliFail('没认出 BV 号 / av 号 / 链接：${e.message}');
    } catch (e) {
      _biliFail('$e');
    }
  }

  /// 取一次 B 站弹幕（**这一集**的 cid）
  ///
  /// 与 `_loadBiliDanmaku` 的分工：
  /// ```text
  /// _biliFetch        ⇒ 给**面板**用（要 BiliUpdateResult 的 added/removed）
  /// _loadBiliDanmaku  ⇒ 给**起播**用（要令牌 + loading + 错误角标那套骨架）
  /// ```
  Future<BiliUpdateResult> _biliFetch(
    BiliBinding b, {
    bool force = false,
  }) async {
    final cid = b.cidFor(_epIndex);
    if (cid <= 0) {
      return const BiliUpdateResult(
        cid: 0,
        total: 0,
        added: 0,
        removed: 0,
        fromCache: false,
        changed: false,
        error: '这一集还没有绑定 B 站弹幕',
      );
    }
    return updateDanmaku(
      api: _ensureBiliApi(),
      cid: cid,
      force: force,
      intervalMinutes: biliAutoUpdateInterval(),
    );
  }

  /// 起播时按 cid 取一次 B 站弹幕（照抄 dandanplay 那套骨架）
  ///
  /// ⚠️ 令牌判据**不能省** —— 换集后旧的响应必须被丢掉，
  ///    否则第 5 集会短暂显示第 3 集的弹幕。
  /// 自动搜 B 站 → 绑定 → 取弹幕。成功返回 true（调用方据此 return）。
  ///
  /// 判据与设计见 `_loadDanmakuNamed` 里那段长注释（为什么需要这一步、
  /// 为什么免登录成立、失败为什么要静默）。这里只补**执行**细节：
  ///
  /// ```text
  /// ① 标题取 `_liveTitle`（与 dandanplay 那条路同一个来源，保证两边一致）
  /// ② 集名用 `_episodes` 的标题（分 P 对齐要靠它）
  /// ③ 成功 ⇒ 落盘 + 立刻用刚拿到的 cid 拉弹幕（不多发一次请求）
  /// ```
  ///
  /// ⚠️ 整个过程**不 flash 任何"正在搜索"**：起播时的提示条是给失败用的，
  ///    搜索成功的话用户直接看到弹幕出现，那才是最好的反馈。
  Future<bool> _autoBindBili() async {
    final title = _liveTitle.trim();
    if (title.isEmpty) return false;
    try {
      final api = _ensureBiliApi();
      final outcome = await autoBindBySearch(
        api: api,
        provider: widget.provider,
        id: widget.id,
        localTitle: title,
        episodeTitles: [for (final e in _episodes) e.title],
      );
      if (outcome == null || !outcome.ok) return false;
      final cid = outcome.binding.cidFor(_epIndex);
      if (cid <= 0) return false;
      if (!mounted) return true;
      // 自动匹配成功 ⇒ 让面板与卡片也能看到这次绑定（不静默改状态）
      debugPrint('[BILI] 自动匹配成功：${outcome.reason} cid=$cid');
      await _loadBiliDanmaku(cid);
      return true;
    } catch (e) {
      /*
       * ★ 这里**必须**吞掉异常。
       *
       * 自动匹配是"锦上添花"：失败就退回 dandanplay（改前的行为），
       * 绝不能因为多了这一步而让原本能用的路径变差。
       * 但要留日志 —— 本项目的一贯纪律是"可以降级，不许静默"。
       */
      debugPrint('[BILI] 自动匹配失败（退回 dandanplay）：$e');
      return false;
    }
  }

  Future<void> _loadBiliDanmaku(int cid) async {
    final token = ++_danmakuFetchToken;
    if (mounted) {
      setState(() {
        _danmakuLoading = true;
        _danmakuError = null;
        _danmakuSettings = _danmakuSettings.copyWith(
          loading: true,
          clearError: true,
        );
      });
    }
    final r = await updateDanmaku(
      api: _ensureBiliApi(),
      cid: cid,
      force: true,
      intervalMinutes: biliAutoUpdateInterval(),
    );
    if (!mounted || token != _danmakuFetchToken) return;
    if (!r.ok) {
      final e = DanmakuException(r.error);
      setState(() {
        _danmakuComments = r.comments;
        _danmakuStatus = '';
        _danmakuError = e;
        _danmakuLoading = false;
        _danmakuSettings = _danmakuSettings.copyWith(
          loading: false,
          error: e,
          status: '',
        );
      });
      _flash('弹幕失败：${r.error}');
      return;
    }
    setState(() {
      _danmakuComments = r.comments;
      _danmakuStatus = r.summary;
      _danmakuError = null;
      _danmakuLoading = false;
      _danmakuSettings = _danmakuSettings.copyWith(
        loading: false,
        clearError: true,
        status: r.summary,
      );
    });
    _biliCid = cid;
    markBiliSynced();
  }

  /// 把一次更新的结果落到渲染层
  ///
  /// ★ 与 `_loadBiliDanmaku` 的区别：这里**不动 loading / 错误角标** ——
  ///   面板里的「立即更新」是用户主动点的一次刷新，失败了在**面板里**说，
  ///   不该把画面上的弹幕清掉（那会让用户以为弹幕坏了）。
  void _biliApplyComments(BiliUpdateResult r) {
    if (!r.ok) {
      _flash('弹幕失败：${r.error}');
      return;
    }
    if (!mounted) return;
    setState(() {
      _danmakuComments = r.comments;
      _danmakuStatus = r.summary;
      _danmakuError = null;
      _danmakuEnabled = true;
    });
    _biliCid = r.cid;
    markBiliSynced();
  }

  /// 自动刷新（切集 / 集列表变了时调用）
  ///
  /// `shouldAutoUpdate` 已经把「开关关了 / 缓存还新鲜」两条判掉 ⇒ 这里
  /// 只管拿到绑定、按当前集算 cid、取一次。
  Future<void> _biliAutoRefresh() async {
    final b = loadBinding(widget.provider, widget.id);
    if (b == null || b.isEmpty) return;
    final cid = b.cidFor(_epIndex);
    if (cid <= 0) return;
    if (!shouldAutoUpdate(cid: cid)) return;
    final r = await _biliFetch(b);
    if (!mounted) return;
    if (!r.ok) {
      debugPrint('[BILI] 自动刷新失败（保留旧弹幕）: ${r.error}');
      return;
    }
    _biliApplyComments(r);
    if (_biliSheetOpen) {
      setState(() {
        _biliState = _biliState.copyWith(
          result: r,
          comments: r.total,
          episodeIndex: _epIndex,
          episodeTitle: _currentEpisodeTitle ?? '',
          episodeCount: _episodes.length,
        );
      });
    }
  }

  /// 面板里选了第几 P
  void _biliSelectPage(int page) {
    UiPrefs.set(BiliPrefs.pageKey(widget.provider, widget.id), '$page');
    setState(() {
      _biliState = _biliState.copyWith(selectedPage: page);
    });
  }

  /// 面板里开关了「自动更新」
  void _biliSetAutoUpdate(bool v) {
    setBiliAutoUpdateEnabled(v);
    setState(() {
      _biliState = _biliState.copyWith(autoUpdate: v);
    });
  }

  /// 面板里改了「自动更新间隔」（分钟，core 侧夹 5~1440）
  void _biliSetInterval(int minutes) {
    setBiliAutoUpdateInterval(minutes);
    setState(() {
      _biliState = _biliState.copyWith(
        intervalMinutes: biliAutoUpdateInterval(),
      );
    });
  }

  /// 面板里点了「立即更新」
  Future<void> _biliUpdateNow() async {
    final b = _biliState.binding;
    if (b == null || b.isEmpty) return;
    final token = _biliPanelToken;
    setState(() {
      _biliState = _biliState.copyWith(
        loading: true,
        busyLabel: '正在重拉弹幕…',
        clearError: true,
      );
    });
    final r = await _biliFetch(b, force: true);
    if (!mounted) return;
    setState(() {
      _biliState = _biliState.copyWith(
        loading: false,
        result: r,
        comments: r.total,
        trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
      );
    });
    if (token != _biliPanelToken) return;
    _biliApplyComments(r);
  }

  /// 面板里点了「解除绑定」
  ///
  /// ★ 解绑后**下一次起播**就自动退回 dandanplay（`_loadDanmakuNamed` 里
  ///   那条 B 站优先分支查不到绑定了）。这里顺手把画面上的弹幕也清掉 ——
  ///   留着会让用户以为解绑没生效。
  void _biliUnbind() {
    clearBinding(widget.provider, widget.id);
    setState(() {
      _biliState = const BiliImportState();
      _biliInfoCache = null;
      _biliCid = 0;
      _danmakuComments = const <DanmakuComment>[];
      _danmakuStatus = '';
      _danmakuError = null;
    });
    _flash('已解除 B 站弹幕绑定');
  }

  /// 面板里的一次失败（把面板切回可操作态 + 提示一句）
  void _biliFail(String msg) {
    if (!mounted) return;
    setState(() {
      _biliState = _biliState.copyWith(
        loading: false,
        error: DanmakuException(msg),
        trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
      );
    });
    _flash(msg);
  }

  /// 打开「在线搜索字幕」（assrt.net）面板 —— ★ task-31 ⑤
  ///
  /// ⚠️ 先收起播放设置面板：它是 `Positioned.fill` 的全屏 scrim，
  ///    不关的话用户只会在设置面板上看到一层更暗的遮罩，
  ///    然后「返回」会先把字幕面板关掉 —— 观感像卡住了。
  void _openSubtitlePanel() {
    setState(() {
      _settingsOpen = false;
      _danmakuSheetOpen = false;
      _subtitlePanelOpen = true;
    });
    // ⚠️ 这里**故意不调** `_hideSettingsPortal()`：设置面板的真源是
    //   `_settingsOpen`，它变 false 后 portal 子树返回 `SizedBox.shrink()`，
    //   遮罩自然消失（与 `onClose: () => setState(() => _settingsOpen = false)`
    //   同款，Lead 裁决②）。
    //   ★ 而且 `test\t68_android_adapt_test.dart:364` 把「_hideSettingsPortal
    //   的**调用**」钉成恰好 2 处（关面板助手 + 面板 X）——多一处门禁就红。
  }

  /// 探针用：只改弹幕开关，**不发请求**
  ///
  /// 与 [debugPlayerSetDanmakuEnabledForProbe] 配套 ——
  /// 写成实例方法是为了不产生
  /// `invalid_use_of_protected_member`（在类外调 setState 会报）。
  void debugDanmakuSetEnabledOnly(bool v) {
    if (!mounted) return;
    setState(() => _danmakuEnabled = v);
  }

  /// 探针用：塞一组**本地构造的**弹幕进渲染层（同时把开关打开）
  ///
  /// 见顶层 [debugPlayerSetDanmakuCommentsForProbe] 的说明：
  /// 没有 AppId/AppSecret 时真实链路必然 403，
  /// 渲染/滚动/泳道分配只能靠本地数据独立验证。
  void debugDanmakuSetComments(List<DanmakuComment> cs) {
    if (!mounted) return;
    setState(() {
      _danmakuComments = cs;
      _danmakuEnabled = true;
    });
  }

  /// 打开「播放设置」面板（齿轮）
  ///
  /// ★★★ 桌面端第 3 条：**纯 UI 动作必须排在两次 mpv 回读之前**
  ///
  /// # Owner 报（截图 + 原话）
  /// ```text
  /// > 不知道点了什么，下面一栏就不显示了，上面还显示 下面就不显示了
  /// > 原来是点了 设置(字幕/音轨/连播) 这个按钮，点了之后无反应，
  /// > 然后下面这页直接没了
  /// ```
  ///
  /// # 根因（改前，实测复现）
  /// ```dart
  /// await _readMpvStyle();    // 7 个属性，每个一次 await native.getProperty
  /// await _readVideoZoom();   // 又一次 await native.getProperty
  /// setState(() => _settingsOpen = true);   // ← 到不了
  /// ```
  /// `native.getProperty` 走的是 **FFI 调用**，mpv 侧只要不回应
  ///（卡住 / 进程已崩 / 还没就绪）这两个 await 就**永不返回** ⇒
  /// `_settingsOpen` 恒为 false。与此同时：
  /// ```text
  /// ① 底栏的 3 秒自动隐藏计时器照常到点（:7171）⇒ 底栏整条收掉
  ///    （底栏门控含 !_settingsOpen，而它还是 false —— 计时器不背这个锅）
  /// ② 顶栏只看 `_controlsVisible || _canUseFloatingBack`（:8842），
  ///    **不看** `_settingsOpen` ⇒ 顶栏留着
  /// ```
  /// ⇒ 屏幕上就是「上面还显示、下面一栏没了、点齿轮无反应」——与截图逐条吻合。
  ///
  /// ★ 实测读数（`.probe\zz_settings_v7.txt`；flutter_tester 里 mpv 属性读天然不返回，
  ///   正好是这条缺陷的**免费夹具**）：
  /// ```text
  /// T10b 点后立即      | open=false sheet=0 gear=0 bar=0
  /// T10d 真实等待 5s 后 | open=false sheet=0 gear=0 bar=0   ← 面板永不出现，底栏没了
  /// T11  探针直调后     | open=true  sheet=1 gear=0 bar=0   ← 跳过 mpv 读 ⇒ 面板正常
  /// ```
  ///
  /// # 为什么「先开面板、回读降级为后台刷新」是**安全**的
  /// ```text
  /// ① 两个读函数结尾都是 `if (mounted) setState(...)`（:3336 / :2088）
  ///    ⇒ 读到了自然刷新面板，只是晚几帧
  /// ② 面板本来就有「读不到」的显示分支（`onChanged: fontSize == null` 禁用、
  ///    `hint: '读不到'`，见 test/player_capability_test.dart:664-674）
  ///    ⇒ 设计上**本来就允许** mpv 值缺失
  /// ⇒ 把「阻塞式回读」排在「打开面板」之前是**纯排序错误**，不是有意的取舍。
  ///
  /// ⚠️ 不要改成 `await ...timeout(...)` 的折中写法：那只是把
  ///    「永不返回」换成「永远卡 400ms」—— 用户点齿轮仍要等一下，
  ///    而这里根本**没有必要**等（面板不需要这些值才能画出来）。
  Future<void> _openSettings() async {
    // ① 纯 UI 动作先落地 —— 不依赖任何 mpv 往返
    setState(() => _settingsOpen = true);
    _showSettingsPortal();

    // ② 回读降级为**后台**刷新：读到了自己 setState 进面板
    //    （task-22 P1-11：面板里的「画面缩放」要显示当前值；
    //      读不到就不改 `_videoZoomPct`，面板会显示「读不到」而不是假装 100%）
    unawaited(_readMpvStyle());
    unawaited(_readVideoZoom());
  }

  /// 让挂到 rootOverlay 的播放设置面板**真的显示出来**（★ task-25 D）
  ///
  /// ⚠️ 必须**真的调** `show()`：`OverlayPortal` 在 `_zOrderIndex == null` 时
  ///    直接 `return _OverlayPortal(overlayLocation: null, overlayChild: null, …)`
  ///    （flutter/lib/src/widgets/overlay.dart:2092-2098）⇒ 只声明式地写
  ///    `if (_settingsOpen)` 在 overlayChildBuilder 里，面板**永远不会出现**。
  ///
  /// ⚠️ 幂等性由 controller 自己保证：show() 里有
  ///    `assert(schedulerPhase != persistentCallbacks)`（build 期间调用会炸），
  ///    但**重复调用本身无害** —— 直接问 `isShowing` 就够了。
  void _showSettingsPortal() {
    /*
     * ★★ 判据用 controller 的**真实**状态（`isShowing`），**不再**用镜像 bool。
     *
     * # 为什么删掉了那个镜像（2026-10-08，第 3 条）
     * ```text
     * 旧实现：`if (_settingsPortalShown) return;` —— 镜像是自己记的，会过期。
     *   portal 的 Element 若被重建（挂载点两侧都有条件子件，见 :9272 注释），
     *   controller 的可见状态不跟随（overlay.dart:1675-1684 的契约），
     *   而镜像还是 true ⇒ show() 被吞 ⇒ 面板**再也画不出来**，且不可自愈。
     *
     * 现在：`isShowing` 是 controller 自己维护的真实状态，不存在过期问题；
     *   Element 重建后它如实变成 false ⇒ 这次 show() 一定会真的发出去。
     * ```
     *
     * 挂载点另有常量 Key（Element 根本不再被重建），这两层是互补的保险。
     */
    if (_settingsPortal.isShowing) return;
    _settingsPortal.show();
  }

  /// 打开播放设置面板（★ task-25 D 只读探针的唯一入口）
  ///
  /// ⚠️ 为什么写成 State 的成员，而不是像本文件其它探针那样在**外面**
  ///    `s.setState(() => s._settingsOpen = true)`：那样会多一条
  ///    `invalid_use_of_protected_member`（`setState` 是 protected）。
  ///    本文件本来就有 5 条同类 warning（既有探针），我不想再加第 6 条。
  void debugOpenSettingsForProbe() {
    setState(() => _settingsOpen = true);
    _showSettingsPortal();
  }

  /// ★★★ 2026-10-08（Owner 追加：顶栏与底栏联动）
  ///
  /// 把「停手 3 秒后自动隐藏」这条规则**同步**跑完 —— 判据与
  /// `_armHideTimer()` 里那个 `Timer` 回调**逐字相同**：
  /// ```text
  /// if (mounted && _playing && !_hintsOpen && !_zoomOpen) {
  ///   setState(() => _controlsVisible = false);
  ///   _applyControlsMotion();
  /// }
  /// ```
  /// ★ 存在的意义：widget 测试里用 `pump(3s)` 推进 `Timer` 之后，
  ///   还要再 pump 若干帧才能让 260ms 的淡出动画走完，**帧数不好钉**；
  ///   这里直接走同一条代码路径，读数与真机一致且**确定性**。
  ///
  /// ⚠️ 必须在 State 里（而不是像其它探针那样从外面改私有字段）：
  ///    `setState` 是 protected，外面改会多一条 warning。
  /// ★ popover 层 —— 由**页面**挂在整屏那个 Stack 里（与底栏是兄弟）
  ///
  /// # 为什么不挂在底栏内部（这是实测出来的，不是设计偏好）
  /// ```text
  /// 底栏在页面里是 `Positioned(bottom:0)`、高约 106px 的一个盒子。
  /// 面板若作为它的子件，能长到的上界就被那 106px 卡死。
  /// 实测（无头截图，1440×900）：popover 展开后的 PNG 与「没展开」的 PNG
  /// **md5 完全相同** —— 一像素都没画出来，而 widget 树里 `PlayerMoreMenu`
  /// 确实存在 ⇒ 问题出在**几何/裁剪**，不在逻辑。
  /// ⇒ 提到同一个 Stack 里当兄弟：面板从底栏上沿往上长，
  ///   而那个 Stack 是整屏（`SizedBox.expand`）⇒ 不会被任何祖先裁掉。
  /// ```
  PlayerBottomBar? _bottomBarWidget;

  Widget buildPopoverLayer() =>
      _bottomBarWidget?.buildPopoverLayer() ?? const SizedBox.shrink();

  /// ★ 截图/几何用：打开选集面板（走**生产**那条 `_episodeSheetOpen` 真源）
  ///
  /// # 为什么要探针而不是 `t.tap`
  /// ```text
  /// flutter_tester 里 PlayerPage 整棵树的**指针回调不被调用**（见 test/t98
  /// 文件头）⇒ `t.tap(find.text('更多'))` 打不动底栏。
  /// ⇒ 探针直接改**生产**的那个字段 / 控制器，验的就是生产那条路径。
  /// ```
  bool debugOpenEpisodesForProbe() {
    if (!mounted) return false;
    setState(() => _episodeSheetOpen = true);
    return _episodeSheetOpen;
  }

  /// 展开某一个 popover（走**生产**那个 `PopoverController`）
  bool debugOpenPopoverForProbe(String id) {
    if (!mounted) return false;
    _popover.toggle(id);
    return _popover.openId == id;
  }

  /// ★ 截图专用：清掉起播错误并把控制条**钉在显示态**
  ///
  /// # 为什么需要它
  /// ```text
  /// 无头截图环境里没有核心库 ⇒ `_load()` 必然失败 ⇒ `_error != null`
  /// ⇒ 底栏那条门控（`_error == null`）不成立 ⇒ 截图里**根本没有底栏**，
  ///   截出来只是一张「播放失败」的全屏图。
  /// ```
  /// ⚠️ 它**只**改 UI 状态，不碰播放器、不发任何请求。
  bool debugForceBarsForShot() {
    if (!mounted) return false;
    setState(() {
      _error = null;
      _loading = false;
      _playing = true;
      _controlsVisible = true;
      _duration = const Duration(hours: 1, minutes: 42, seconds: 7);
    });
    _applyControlsMotion();
    return true;
  }

  void debugAutoHideControlsForProbe() {
    _autoHideNow();
  }

  /// 把 `_playing` 直接置位（★ 2026-10-08 顶栏联动回归用）
  ///
  /// # 为什么必须有它
  /// ```text
  /// `_autoHideNow()` 的第一条判据是 `_playing` —— 那是**对的**
  /// （暂停时不该收控制条）。
  /// 而 flutter_tester 里没有真网络 ⇒ 起播必然失败 ⇒ `_playing` 恒 false
  /// ⇒ 不置位的话「自动隐藏」这条路径**在测试里根本走不到**，
  ///   而那正是本次要验的东西。
  /// ```
  /// ⚠️ 只置这一个 bool，**不动** `_player` / 位置 / 时长 ——
  ///    测试要的是「判据成立」，不是伪造播放。
  void debugSetPlayingForProbe(bool v) {
    if (!mounted) return;
    setState(() => _playing = v);
  }

  /// 模拟一次「鼠标在控制条区域晃动」—— 走**生产**那条 `_showControls()`
  void debugHoverControlsForProbe() {
    if (!mounted) return;
    _showControls();
  }

  /// ★ task-16 探针入口：直接置「指针是否在页内」
  ///
  /// # 为什么必须由测试来置，而不能靠 `t.tap` / 真鼠标
  /// ```text
  /// `flutter_tester` 里 PlayerPage 整棵树的**指针事件回调都不被调用**
  /// （本仓已记录在 `test/t118` 文件头与 `t98`）—— 也就是说
  /// `MouseRegion.onEnter` / `onExit` 在测试里**永远不会**被派发。
  /// ⇒ 不提供这条入口，判据③（指针离开 ⇒ 不画）在测试里根本走不到，
  ///   而它正是本次要验的东西。
  /// ```
  ///
  /// ★ 它走的是**与 onEnter/onExit 同一对方法**（`_onPointerEnter` /
  ///   `_onPointerExit`），不是测试自己写一遍置位 —— 与
  ///   `debugAutoHideControlsForProbe` 同一条纪律：
  ///   探针验的必须是**生产路径**。
  ///
  /// ⚠️ 放在 State 里（`setState` 是 protected，从外面改会多一条 warning）。
  void debugSetPointerInsideForProbe(bool v) {
    if (v) {
      _onPointerEnter();
    } else {
      _onPointerExit();
    }
  }

  /// 收起 rootOverlay 上的播放设置面板（Esc / 关闭按钮 / dispose 都走这里）
  void _hideSettingsPortal() {
    // ★ 与 `_showSettingsPortal` 同款：先清镜像，再看 controller 的**真实**状态。
    //   若 controller 已经不显示了，就别再 hide() —— 未 attach 且
    //   `_zOrderIndex == null` 时 `hide()` 里的 `assert(_zOrderIndex != null)`
    //   会炸（overlay.dart:1748）。
    if (!_settingsPortal.isShowing) return;
    _settingsPortal.hide();
  }

  /// Esc 收起播放设置面板的**全部**动作（Owner 第 3 条的自愈也在这里）
  ///
  /// # 为什么抽成一个方法（2026-10-08）
  /// ```text
  /// Esc 链的长度**本身**是被测试钉住的：三条既有断言在「Esc 分支之后
  /// 700 字符」的窗口里找 `else if (_settingsOpen)` / `_zoomOpen` /
  /// `_episodeSheetOpen`（t73:248-274、t78:448-457、capability:1003-1016）。
  /// 那是**先截断成 700 字符**再 indexOf ⇒ 针尾被切掉就返回 -1。
  /// 实测：_episodeSheetOpen 偏移 692 + 针长 25 = 717 > 700 ⇒ 红。
  /// ```
  /// 把三步收进这里之后，链上只剩一行调用，六个偏移全部退回 700 以内
  /// （余量 290+）—— 以后要解释这三步，写在这段注释里就行，
  /// **不要再往那条链里塞注释**。
  ///
  /// # 三步各自为什么必须有
  /// ```text
  /// ① setState(_settingsOpen = false)
  ///      面板的**真源**（挂载点 overlayChildBuilder 门控的就是它）。
  /// ② _hideSettingsPortal()
  ///      面板挂在 rootOverlay 上，只 setState 不够：overlayChildBuilder
  ///      虽然会返回 SizedBox.shrink()，但 portal 仍占着 theater
  ///      （task-25 D）。⚠️ 全文件**只许有两处调用**（本助手 + 面板 X 的
  ///      onClose），test/t68_android_adapt_test.dart:364 钉成恰好 2 次。
  /// ③ _showControls()  ← Owner 第 3 条的自愈
  ///      用户报的现象：
  ///        > 点了 设置(字幕/音轨/连播) 这个按钮，点了之后无反应，
  ///        > 然后下面这页直接没了
  ///      底栏门控里有 `!_settingsOpen` ⇒ 面板一旦「开着但画不出来」，
  ///      底栏就永远不回来，屏幕上只剩顶栏。关面板这个动作无论面板
  ///      刚才是否真的画出来，都要把底栏叫回来（_showControls 自带
  ///      "值没变就不重建"的守卫，见那里的注释，代价接近零）。
  /// ```
  void _closeSettingsFromEsc() {
    setState(() => _settingsOpen = false);
    _hideSettingsPortal();
    _showControls();
  }

  /// 播放设置面板的 portal 子树（★ task-25 D）
  ///
  /// ⚠️ 这里**只**决定「画不画」—— 面板的**真源**始终是 `_settingsOpen`，
  ///    而「显示/隐藏」由 `_settingsPortal.show()/hide()` 负责（见它们的注释）。
  ///    `_settingsOpen == false` 时返回零尺寸 ⇒ 面板一定不渲染
  ///    （Lead 裁决②：onClose 只改 `_settingsOpen`，不需要别的镜像）。
  ///
  /// # 安全区由**面板自己**让（不在这里包 Padding）
  /// ```text
  /// PlayerSettingsSheet.build 的第一行就是 `Positioned.fill`。
  /// 若在这里包一层 Padding/Positioned，那个 ParentDataWidget 会与
  /// 面板自己的 `Positioned.fill` **争同一个 StackParentData** ——
  /// 内层后应用，外层设的 top/bottom 会被覆盖成 0（等于没让）。
  /// ```
  /// ⇒ 安全区 Padding 放在面板内部（`player_settings_sheet.dart` 的
  ///   `player-settings-safe-area` 那一层），本函数只负责挂载。
  Widget _buildSettingsPortalChild(BuildContext context) {
    if (!_settingsOpen) return const SizedBox.shrink();
    return PlayerSettingsSheet(
      isLive: _isLive,
      subtitleTracks: _subtitleOptions(),
      audioTracks: _audioOptions(),
      currentSubtitleId: _sidChosen,
      currentAudioId: _aidChosen,
      externalSubtitleName: _externalSubtitle?.id.split(RegExp(r'[\\/]')).last,
      mpvStyle: _mpvStyle,
      endAction: _endAction,
      countdownBeforeNext: _countdownBeforeNext,
      keepSourceOnNext: _keepSourceOnNext,
      autoSkip: _autoSkip,
      rate: _rate,
      isPlaying: _playing,
      clipDownloading: _clipDownloading,
      clipDownloaded: _clipDownloaded,
      clipDownloadError: _clipDownloadError,
      /*
       * ★ ③ 的落点：面板把「用户选了第几档」交回来，
       *   真正存下来的是 ClipDownloader（进程级单例）。
       *   setState 之后面板会重画，重新读到新档位。
       */
      onSetConcurrency: (v) {
        setState(() => ClipDownloader.setConcurrency(v));
      },
      onDownloadClip: () => unawaited(_downloadClip()),
      onOpenClipDir: () => unawaited(_openClipDir()),
      onPickSubtitle: (id) {
        /*
         * ★ 用户手动选了字幕轨 → 记下来
         *
         * 记下的作用是**阻止自动选轨**：否则下一次轨列表
         * 刷新时又会被自动选回第一条真实轨，
         * 「关闭字幕」就成了一个无效操作。
         */
        _pickSubtitleMadeByUser = true;
        setState(() => _sidChosen = id);
        unawaited(_applySubtitleTrack(id, userInitiated: true));
      },
      onPickAudio: (id) => unawaited(_applyAudioTrack(id)),
      onLoadSubtitleFile: (path) => unawaited(_loadExternalSubtitle(path)),
      onRemoveExternalSubtitle: () => unawaited(_removeExternalSubtitle()),
      // ★★★ task-31 ⑤：在线搜索字幕（assrt.net）面板入口
      onOpenSubtitleSearch: _openSubtitlePanel,
      onSetMpvProperty: (k, v) => unawaited(_setMpvStyle(k, v)),
      onSetEndAction: (a) {
        setState(() => _endAction = a);
        _savePlayPref('endAction', a.wire);
      },
      onSetCountdown: (v) {
        setState(() => _countdownBeforeNext = v);
        _savePlayPref('countdownBeforeNext', v ? '1' : '0');
      },
      onSetKeepSource: (v) {
        setState(() => _keepSourceOnNext = v);
        _savePlayPref('keepSourceOnNext', v ? '1' : '0');
      },
      onSetAutoSkip: (v) {
        setState(() => _autoSkip = v);
        _savePlayPref('autoSkip', v ? '1' : '0');
        /*
         * ★ 打开自动跳过时**重置"已跳过"标志**
         *
         * 与「片头片尾」弹窗保存后的处理同理：用户刚打开开关，
         * 但 `_introSkipped` 可能在本会话早先已经被置过 true
         * （那时开关是关的、根本没跳）—— 不重置的话
         * 打开开关后**本集不会跳**，用户会以为开关没用。
         */
        if (v) {
          _introSkipped = false;
          _outroSkipped = false;
        }
      },
      /*
       * ★ task-21 P1-8：倍速落到与底栏 `onRate`（:7881）**同一个落点**
       *   —— `_player.setRate`。面板不写偏好、不碰 `_lastRateRequest`：
       *   `_player.stream.rate` 的回调（:2159-2163）会回填 `_rate`
       *   并写 `lastSpeed`，面板只需重画。
       */
      onSetRate: (r) => _player.setRate(r),
      // ★★★ task-22 P2-9 / P1-11：解码模式 + 画面缩放
      hwdecMode: _hwdecMode,
      onSetHwdecMode: _setHwdecMode,
      videoZoom: _videoZoomPct,
      onSetVideoZoom: (v) => _setVideoZoom(v),
      /*
       * ★★ 2026-10-08（Owner 第 3 条）：关面板时顺手把底栏叫回来。
       *
       * 底栏门控里有 `!_settingsOpen` ⇒ 面板一旦"开着但画不出来"
       * （第 3 条那个 Element 重建 + 镜像过期的缺陷），底栏就永远不回来。
       * 这条自愈让「关掉面板」这个动作一定能把控制条恢复 —— 见
       * `_openSettings()` 与 Esc 分支的同款说明。
       */
      onClose: () {
        setState(() => _settingsOpen = false);
        _hideSettingsPortal();
        _showControls();
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  进度落盘（记忆播放位置）
  // ═══════════════════════════════════════════════════════════════════

  void _startProgressSaver() {
    _progressTimer?.cancel();
    /*
     * ★ 每 5 秒落一次盘（不是每帧）
     *
     * 原版注释：
     * > 每帧写会写爆 SQLite。
     * 而且 position 流的触发频率是每秒数次 —— 必须节流。
     */
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _saveProgress();
    });
  }

  void _scheduleSave(Duration p) {
    // 位置变化超过 5 秒才考虑落盘（配合上面的定时器，双保险）
    if ((p - _lastSavedPosition).abs() > const Duration(seconds: 5)) {
      // 不立即写 —— 交给定时器，避免频繁 IO
    }
  }

  /// 落盘进度
  ///
  /// [immediate] 用于退出/切集/换源前 —— 那些时刻必须**立刻**保存，
  /// 否则用户切走时最后几秒的进度会丢。
  Future<void> _saveProgress({bool immediate = false}) async {
    if (_isLive) return; // 直播没有进度概念
    if (_duration <= Duration.zero) return;

    final pos = _position.inSeconds;
    // 位置太小不记（避免"刚点开就存了 2 秒"污染继续观看列表）
    if (pos < 5 && !immediate) return;

    _lastSavedPosition = _position;

    final ep = _epIndex < _episodes.length ? _episodes[_epIndex] : null;

    try {
      await SourinApi.saveProgress(
        _provider,
        _contentId,
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 2026-09-26 第二轮：这里原来写的是 `widget.title` / `widget.cover`
         * ══════════════════════════════════════════════════════════════
         *
         * # 那是「播放记录显示 ？」的根因（Owner 报的）
         *
         * ```text
         * `widget.title` / `widget.cover` 是 **final 构造参数**；
         * 而合并页的入口 `shell.dart` 的 `_mediaRoute()` 传的是
         *   `title: ''`、**根本没有 cover**（那一刻详情还没加载，标题确实不知道）
         * ⇒ 这两个值**恒为空** ⇒ 每次保存进度都往库里写**空标题 + 空封面**
         * ⇒ 播放记录列表渲染不出名字与封面 ⇒ 显示成一个「？」
         * ```
         * ★ 实测用户真实库（`.probe/ROOTCAUSE-panel-and-history.md`）：
         *   3 条记录 `title = ''` 且 `cover = NULL` —— 正是这么来的。
         *
         * # 而真值其实**已经到了**
         *
         * ```text
         * MediaPage._onDetailLoaded(d) ⇒ updateDisplayTitle(d.title, cover: d.cover)
         *                              ⇒ _title / _cover   ← ★ 就是上面那两个字段
         * ```
         * ⇒ 修法：**写库读活值**（`_title` / `_cover`），不再读构造参数。
         *
         * ⚠️ 但仍然要**保留 `widget.*` 作为兜底**：
         *   直播/遥控等路径可能直接构造 `PlayerPage(title:, cover:)`
         *   而从不走 `updateDisplayTitle` ⇒ 那时 `_title` 与 `widget.title` 同值，
         *   取哪个都对；用 `??`/空串判断兜底只是让"没走详情页的路径"也正确。
         */
        title: _title.isNotEmpty ? _title : widget.title,
        cover: _cover ?? widget.cover,
        episodeId: ep?.id ?? widget.episodeId,
        episodeTitle: ep?.title ?? widget.episodeTitle,
        position: pos,
        duration: _realDuration.inSeconds > 0
            ? _realDuration.inSeconds
            : _duration.inSeconds,
      );
    } catch (e) {
      debugPrint('[PLAYER] 保存进度失败: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  片头 / 片尾跳过
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _loadSkipMarker() async {
    if (_isLive) return;
    try {
      final m = await SourinApi.getSkipMarker(_provider, widget.id);
      if (mounted) setState(() => _skipMarker = m);
    } catch (e) {
      debugPrint('[PLAYER] 读跳过点失败: $e');
    }
  }

  /// 播放位置变化时检查要不要跳
  void _maybeSkip(Duration pos) {
    final m = _skipMarker;
    if (m == null || _isLive) return;

    /*
     * ★ 全局「自动跳过片头」开关（原版 `autoSkipOn`，默认 true）
     *
     * 原版 `applySkipMarkers()` 的第一行就是：
     * ```ts
     * if (!v || !s || isLive.value || !autoSkipOn.value) return;
     * ```
     * 关掉之后**不自动跳**（用户仍可在设置面板里看到自己设的片头片尾）。
     *
     * ⚠️ 没有这一条的话，播放设置面板里那个「自动跳过片头」开关
     *    就是个**死开关** —— 能拨但什么都不影响。
     */
    if (!_autoSkip) return;

    final sec = pos.inSeconds;

    // ── 片头 ──
    if (!_introSkipped && m.introEnd != null) {
      final start = m.introStart ?? 0;
      final end = m.introEnd!;
      if (sec >= start && sec < end) {
        _introSkipped = true;
        debugPrint('[PLAYER] 跳过片头 $start → $end');
        _player.seek(Duration(seconds: end));
        _flash('已跳过片头');
        return;
      }
    }

    // ── 片尾 ──
    if (!_outroSkipped && m.outroStart != null) {
      final start = m.outroStart!;
      if (sec >= start) {
        _outroSkipped = true;
        debugPrint('[PLAYER] 到达片尾起点 $start');
        /*
         * ★ 片尾不直接跳 —— 而是**启动下一集倒计时**
         *
         * 原版逻辑：让用户有机会看完片尾/片尾曲。
         * 倒计时结束才自动下一集。
         */
        _startNextCountdown();
      }
    }
  }

  /// 下一集倒计时
  ///
  /// # 倒计时秒数：**5 秒**（与原版 3 秒不同 —— 单列的理由）
  ///
  /// 原版 `startNextCountdown()`（`PlayerView.vue:2736-2746`）是 3 秒。
  /// 我们保持 5 秒，因为 5 是**已交付并验收过**的行为（本轮任务明确写了
  /// 「片头片尾自动跳过已实现」在验收清单里），而 3→5 这种改动属于
  /// 交互变更、不在本次授权范围内。**如实单列**，不偷偷改。
  void _startNextCountdown() {
    if (_nextEpisode == null) return;
    _countdownTimer?.cancel();
    setState(() => _nextCountdown = 5);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _nextCountdown--);
      if (_nextCountdown <= 0) {
        t.cancel();
        _gotoNextEpisode();
      }
    });
  }

  void _cancelNextCountdown() {
    _countdownTimer?.cancel();
    if (mounted) setState(() => _nextCountdown = 0);
  }

  /// 播放结束 —— **照抄原版 `onEnded()`（`PlayerView.vue:2748-2785`）**
  ///
  /// # 原版按「播放完」偏好分三路
  ///
  /// ```ts
  /// switch (prefs.endAction) {
  ///   case "singleLoop": v.currentTime = 0; v.play();           // 单集循环
  ///   case "autoNext":   倒计时 或 直接下一集 / "已是最后一集"       // 自动连播
  ///   case "stop":       flashTip("已播放完毕");                  // 播完停止
  /// }
  /// ```
  ///
  /// # 这里原来漏了什么（本次补的缺口）
  ///
  /// 旧实现只有一句 `if (_nextEpisode != null) _startNextCountdown();` ——
  /// 也就是说：**不管用户选什么，行为都是"自动连播"**。
  /// 「单集循环」和「播完停止」两个选项以及「连播前倒计时」开关
  /// 都**没有落地**（而且旧版连面板都没有，用户根本改不了）。
  ///
  /// # 为什么 `singleLoop` 用 `seek(0)` + `play()`
  ///
  /// 与浏览器里 `v.currentTime = 0; v.play()` 语义一一对应。
  /// media_kit 没有"重播"API，`seek(Duration.zero)` 就是它的等价物。
  void _onEnded() {
    debugPrint('[PLAYER] 播放结束（endAction=${_endAction.wire}）');

    // 直播没有"播完"这回事（原版 `onEnded` 第一行就是 `if (isLive.value) return;`）
    if (_isLive) return;

    switch (_endAction) {
      case PlayEndAction.singleLoop:
        // 单集循环：回到 0 接着播（原版 flashTip("单集循环")）
        unawaited(_player.seek(Duration.zero));
        unawaited(_player.play());
        _flash('单集循环');

      case PlayEndAction.autoNext:
        if (_nextEpisode == null) {
          // 原版：flashTip("已是最后一集")
          _flash('已是最后一集');
          return;
        }
        /*
         * ★ 「连播前倒计时」开关在这里生效（原版 2778 行）
         *
         * ```ts
         * if (prefs.countdownBeforeNext) startNextCountdown();
         * else gotoEpisode(nextEpisode.value);
         * ```
         */
        if (_countdownBeforeNext) {
          _startNextCountdown();
        } else {
          unawaited(_gotoNextEpisode());
        }

      case PlayEndAction.stop:
        // 原版：flashTip("已播放完毕") —— 停在最后一帧
        _flash('已播放完毕');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 跨源换源（原地换源继续播）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 与详情页的换源**不同**：这里是**原地**换源继续播，
  // 而详情页是跳到新源的详情页（因为详情页要重新选集/选线路）。
  //
  // 原版注释：
  // > 用户选了另一个源的同一部内容 → **原地换源继续播**
  //
  // # 保留进度的三个要点（照抄原版）
  //
  // ```text
  // ① 用**当前真实进度**而不是弹层传进来的旧值
  //    —— 弹层是在打开时读的 position，用户可能又看了几分钟才点选
  // ② 按**集号**匹配（不是下标）—— 各源的剧集列表长度/缺集不同
  // ③ 匹配不到就退到第 1 集，并**明确告知**（不静默）
  // ```
  Future<void> _openSwitchSource() async {
    /*
     * ★ 换源前先把进度落盘（避免丢）
     *
     * 原版：`void reportProgress(true);` —— 换源会替换整个会话，
     * 不先存的话最后这几分钟的进度就没了。
     */
    await _saveProgress(immediate: true);

    if (!mounted) return;
    final pick = await showSourceSwitchDialog(
      context,
      /*
       * ★★★ task-72【④】这里原来写的是 `widget.title` ⇒ **空串**
       *
       * 三个症状（弹层空白 / 不自动搜 / 不填充）同一个根因 ——
       * 弹层拿到空串 ⇒ `_kw` 空 ⇒ `_run()` 首行 `if (kw.isEmpty) return;`
       * ⇒ 静默返回、**一个请求都不发**。详见 `_liveTitle` 的文档注释。
       */
      title: _liveTitle,
      currentProvider: _provider,
      currentProviderName: _provider,
      // ★ 传**当前真实进度**
      episodeIndex: _epIndex + 1,
      position: _position.inSeconds,
    );
    if (pick == null || !mounted) return;

    await _applySwitch(pick);
  }

  /// 打开「设置片头片尾」弹窗
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 原版 `PlayerView.vue::openSkipDialog` 的两条关键行为
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// ## ① 弹窗里**同时**编辑四个端点
  ///
  /// 不是"先选设片头还是设片尾"—— 参照图就是一个弹窗里两个区间。
  /// （原版第一版是分两步的，Owner 否掉了。）
  ///
  /// ## ② 打开时**暂停主播放器**
  ///
  /// 原版注释：
  /// > 为什么：弹窗里的预览是**独立**的，主播放器如果继续播，
  /// > 用户会看到两个画面不同步（而且白耗流量）。
  /// > 关掉弹窗后**不自动恢复播放** —— 让用户自己按
  /// > （避免"关掉就突然响了"）。
  ///
  /// ⚠️ 注意是"暂停"而**不是**"把主播放器 seek 到预览位置" ——
  ///    预览完全独立（见 `SkipMarkerDialog` 文件头）。
  ///
  /// ## ③ 直播不能设
  ///
  /// 原版第一行就是 `if (isLive.value) return;` ——
  /// 直播没有"片头片尾"的概念（流是线性的）。
  Future<void> _openSkipDialog() async {
    // ③ 直播不适用
    if (_isLive) return;

    /*
     * ② 暂停主播放器（不是 seek —— 预览是独立的）
     *
     * ⚠️ task-57 修正：**关掉后要恢复播放**
     *
     * # 原来的行为（已改）
     *
     * 这里原本写着「关掉后**不自动恢复** —— 与原版一致（避免"关掉就突然响了"）」。
     * 但实测发现这会让用户以为**播放被搞坏了**：
     * ```text
     * 用户调完片头片尾 → 关掉弹窗 → 回到播放页 → ★ 视频是**停着的**
     * ⇒ "这个设置把播放搞停了"
     * ```
     * ★ 而"避免突然响了"那个顾虑**不成立**：我们恢复的是**用户自己
     *   打开弹窗前就在播**的状态（`_wasPlaying`），不是擅自开始播。
     *   若用户打开前是暂停的，关掉后**仍然暂停**。
     *
     * # 为什么**不 seek 回原位**
     *
     * 暂停期间主播放器的位置**没有变**（暂停了就不前进），
     * 所以"回到原位置"是**自然**的 —— 显式 seek 反而会引入
     * 一次跳变/重新缓冲（本仓在 HLS 上踩过 seek 触发重新取分片）。
     * ⇒ ★ 只 `play()`，不 `seek()`。
     *   这也同时满足 Owner 的「不跟底层的进行联动」——
     *   我们**从不**把预览的位置写回主播放器。
     */
    final wasPlaying = _playing;
    /*
     * ★ 记下打开弹窗**之前**的位置 —— 只用于**诊断**（见关闭时那段）
     *
     * 我们不 seek 回这个位置（不 seek 才满足 Owner 的"不联动"），
     * 但把它打出来能证明"暂停期间位置确实没动"。
     * 若它漂了 ⇒ 说明有别的路径在动主播放器 ⇒ 那是一条要查的线索。
     */
    final posBeforeDialog = _position;
    if (_playing) await _player.pause();
    if (!mounted) return;

    /*
     * 预览用的流地址
     *
     * 优先用**当前正在播的那条**（`_current?.url`）——
     * 用户看到的就是他正在看的画质/线路。
     * 没有的话回退到第一条可播的。
     *
     * ⚠️ 这里**必须**传真实的流地址 —— 弹窗会用它起**独立的**预览播放器。
     *    这是 Owner 明确要求的形态（见 `skip_marker_dialog.dart` 文件头
     *    L28-40），**不是**可选实现细节。
     *    task-57 我一度改成"抓帧宿主"（方案 D），已回退 —— 理由见下。
     */
    final url =
        _current?.url ??
        (_streams.isNotEmpty
            ? _streams
                  .firstWhere((x) => x.isPlayable, orElse: () => _streams.first)
                  .url
            : '');
    if (url.isEmpty) {
      _flash('没有可用的播放地址，无法预览');
      return;
    }

    final r = await showAppDialog<SkipMarkerResult>(
      context: context,
      // 弹窗内自带预览，用 barrier 半透明遮住播放器（原版也是）
      barrierDismissible: true,
      builder: (_) => SkipMarkerDialog(
        provider: _provider,
        id: widget.id,
        // ★ task-72【④】活标题（弹窗里要**显示**给用户看）
        title: _liveTitle,
        /*
         * ★★★ task-57 回退记录：这里**曾经**改成"抓帧宿主"（方案 D）——
         * 即让弹窗 seek **主播放器**再抓一帧。**已回退**，理由三条：
         * ```text
         * ① Owner **逐字否过**"联动主播放器"（见 skip_marker_dialog.dart
         *    文件头 L28-40）—— 而 D 恰好就是被否掉的那一版
         * ② D 的唯一理由（"消除两个播放器抢流"）已被**两次实测否定**：
         *    我 6/6 轮未复现 + fix-window-shadow 双向 A/B 也否定
         * ③ D 的三条后果**必然发生**（改主播放器进度 / 拖动反复取分片 /
         *    手机上更糟 —— Owner 原话里专门点了手机）
         * ⇒ 收益（未证实的 bug）< 代价（必然发生 + 违背 Owner）
         * ```
         * ★ 而真正让用户说"不能用"的是**预览区黑 15 秒且无提示**（实测），
         *   那个 bug 与"用哪个播放器"**无关**（等的是网络 + 解码）——
         *   修在 `skip_marker_dialog.dart` 的加载提示里。
         */
        streamUrl: url,
        /*
         * ⚠️ 用 `_realDuration` 而不是 `_duration`：
         *    前者是流真的报出来的时长，后者可能还是 0
         *    （`Player.open()` 返回 ≠ 流就绪）。
         *    task-52 实测过 `_duration` 为 0 会让弹窗时间轴退化成 1 秒。
         */
        duration: _realDuration.inSeconds > 0 ? _realDuration : _duration,
      ),
    );

    if (!mounted) return;

    if (r != null) {
      /*
       * 保存成功 → 把新设置**立刻**用到当前会话
       *
       * 不重新拉接口（刚写完就是最新的），直接更新内存里的 `_skipMarker`。
       * 否则用户设完片头，要等下一次换集才生效 —— 那不合理。
       */
      setState(() {
        _skipMarker = SkipMarker(
          key: '$_provider:${widget.id}',
          provider: _provider,
          nativeId: widget.id,
          title: _liveTitle,
          introStart: r.introStart,
          introEnd: r.introEnd,
          outroStart: r.outroStart,
          outroEnd: r.outroEnd,
          autoSkip: r.autoSkip,
        );
        /*
         * ★ 重置"已触发过"的标志（2026-09-24）
         *
         * 不重置的话：用户设完片头，但因为 `_introSkipped` 已经是 true
         * （本次会话早先跳过过一次），新的设置**不会再生效** ——
         * 表现为"设了没用"，极难排查。
         */
        _introSkipped = false;
        _outroSkipped = false;
      });
      _flash('片头片尾设置已保存');
    }

    /*
     * ★ task-57：恢复**用户原本的播放状态**（见上面 `wasPlaying` 的说明）
     *
     * ⚠️ 必须放在 `if (r != null)` **之外** —— 用户点「取消」/点 X 关掉
     *    弹窗时**同样**要恢复。否则"我打开看了一眼就关掉"也会把播放停住，
     *    那比"设完才停"更让人困惑。
     *
     * ⚠️ 用 `wasPlaying`（打开**之前**的状态）而不是 `_playing`：
     *    后者此刻必然已经是 false（我们刚 pause 过），拿它判断会永不恢复。
     *
     * ⚠️ **只 play、不 seek** —— 这不只是"避免跳变"，而是满足 Owner 的
     *    硬约束「而不是跟底层的进行联动」：
     *    ```text
     *    显式 seek 主播放器 ⇒ 那**就是**"联动"（哪怕是 seek 回原位）
     *    只 play/pause      ⇒ 主播放器**从未被 seek**
     *                       ⇒ ★ 结构上不可能违反"不联动"
     *    ```
     */
    if (!mounted) return;

    /*
     * ★ 诊断读数（编排者要求"让漂移可观测"）
     *
     * 暂停期间位置**本应不动**。若日志显示它漂了，说明有别的路径在动
     * 主播放器 —— 那是一条需要查的线索，不能让它静默。
     */
    final drift = (_position - posBeforeDialog).inMilliseconds.abs();
    debugPrint(
      '[PLAYER] 片头片尾弹窗已关闭: 原状态=${wasPlaying ? '播放中' : '暂停'}'
      ' 位置 ${posBeforeDialog.inSeconds}s → ${_position.inSeconds}s'
      '（漂移 ${drift}ms${drift > 2000 ? ' ★ 异常，请查' : ''}）',
    );

    if (wasPlaying) {
      await _player.play();
      if (mounted) debugPrint('[PLAYER] 关闭片头片尾弹窗 → 恢复播放');
    }
  }

  /// 执行换源
  Future<void> _applySwitch(SwitchPick p) async {
    /*
     * ★ 用**当前真实进度**而不是弹层传进来的旧值
     *
     * 原版注释：
     * > 弹层是在打开时读的 position，用户可能又看了几分钟才点选。
     */
    final nowPos = _position.inSeconds;
    final position = nowPos > 3 ? nowPos : p.position;

    // ★ 按**集号**匹配（不是下标）
    final curOrder =
        _epOrder(_currentEpisodeTitle) ??
        (p.episodeIndex > 0 ? p.episodeIndex : null);

    _flash('正在切换到「${p.title}」…');

    try {
      /*
       * 取新源的详情与剧集。
       *
       * ⚠️ 详情里**不一定**带 episodes，所以再调一次 `getEpisodes`
       *    （与详情页的取法一致）。
       */
      final d = await SourinApi.getDetail(p.provider, p.id);
      final srcCode = d.sources.isNotEmpty ? d.sources.first.code : null;

      var eps = d.episodes;
      if (srcCode != null && srcCode.isNotEmpty) {
        try {
          final more = await SourinApi.getEpisodes(p.provider, p.id, srcCode);
          if (more.isNotEmpty) eps = more;
        } catch (e) {
          debugPrint('[PLAYER] 取新源剧集失败（沿用详情的）: $e');
        }
      }

      // ★ 按集号匹配
      Episode? keep;
      if (curOrder != null) {
        keep = eps.where((e) => _epOrder(e.title) == curOrder).firstOrNull;
      }
      final fellBack = curOrder != null && keep == null;
      keep ??= eps.isNotEmpty ? eps.first : null;

      if (fellBack) {
        // ★ 不静默 —— 明确告诉用户换到哪一集了
        _flash('新源没有「第 $curOrder 集」，已从第 1 集开始');
      }

      if (!mounted) return;

      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ task-77：换源时把记录**搬到**新源（与合并页完全同一条路径）
       * ══════════════════════════════════════════════════════════════════
       *
       * # 这里原来**没有**这一步，于是播放器内换源与合并页换源不一致
       *
       * ```text
       * 合并页（正确）：lib/ui/media_page.dart:476 → SourinApi.repointItem(...)
       * 播放器内（缺陷）：本函数 → 直接 _resolveAndPlay ⇒ 从不迁移
       * ```
       * 四张表（favorites / progress / history / skip_markers）的 key 都是
       * `<provider>:<id>`（`commands_write.rs:42 item_key`）⇒ 换源 ⇒ key 变
       * ⇒ 新源的写入是【新行】，旧行原样留着 ⇒ 同一部剧**两条记录**，
       * 且旧源上的进度**不被带走**。
       *
       * # 为什么放在 `setState` **之前**、且 `await`（不是 `unawaited`）
       *
       * ```text
       * ① from 值就是下面这两个字段：_provider / _contentId
       *    —— 而 `_resolveAndPlay`（:4508 附近）会把它们改写成新源
       *    ⇒ 一旦跑到那里，就再也拿不到"旧源是谁"了
       * ② 迁移是一个事务，很快（纯本地 SQLite，无网络）
       *    而紧接着的 `_resolveAndPlay` 会**立刻起播**并**写新进度**
       *    ⇒ 若迁移还没做完，新源的 save_progress 可能先落库，
       *      之后迁移再"把旧行合并进新行"就会把刚写的进度覆盖掉
       * ```
       *
       * # ★★★ 失败**绝不阻断**换源
       *
       * 「记录搬不动也得让用户能看 —— 换源本身是用户刚做的动作」
       * ⇒ catch 住 + debugPrint 如实记 + 继续往下走（照 `media_page` 的裁决）
       *
       * ⚠️ 同 provider 的情形（换线路/同源不同 id）**不在这里判** ——
       *    Rust 侧 `commands_write.rs:527` 有一道 `from_provider == to_provider`
       *    守卫，同 provider 直接 `Ok(())`。判据只有一份，不在这边重写。
       */
      try {
        await SourinApi.repointItem(
          fromProvider: _provider,
          fromId: _contentId,
          toProvider: p.provider,
          toId: p.id,
        );
        debugPrint(
          '[PLAYER] ★ 换源迁移记录完成: '
          '$_provider:$_contentId → ${p.provider}:${p.id}',
        );
      } catch (e) {
        debugPrint(
          '[PLAYER] ★ 换源迁移记录失败'
          '（不阻断换源，列表可能仍显示旧源）: $e',
        );
      }

      /*
       * ★ 换源后要**续播原来的秒数**
       *
       * 不用比例（各源时长可能不同）—— 直接用秒数记到 `_pendingSeek`，
       * 等新流就绪后跳过去。若新源总时长比这个秒数还短，
       * `_startPlayback` 里会做夹取。
       */
      setState(() {
        // 整批替换（新源的 id/剧集/线路全变了）
        _episodes = eps;
        _epIndex = keep != null ? eps.indexOf(keep) : 0;
        _current = null;
        _streams = [];
        _skipMarker = null;
        // ★ 换源 ⇒ 上一集下载过的那份文件不再代表「当前这一集」
        //   （Lead 审计 team-message-914508ce【低】第 4 条：这两个字段原先从不重置）
        _clipDownloaded = false;
        _clipDownloadError = null;
        _introSkipped = false;
        _outroSkipped = false;
        _nextCountdown = 0;
        _countdownTimer?.cancel();
        // ★ 续播位置
        _pendingSeek = position > 3 ? Duration(seconds: position) : null;
      });

      /*
       * ⚠️ 换源要**重新解析流**，但 provider/id 变了 ——
       *    播放器页的 `widget.provider/id` 是 final，没法改。
       *    所以这里直接调 `resolveStream` 拿新流并播放，
       *    不重建整个页面（原地换源）。
       */
      await _resolveAndPlay(p.provider, p.id, keep?.id, srcCode);

      // 换源后重新读跳过点（新源的片头片尾可能不同）
      await _loadSkipMarker();
    } catch (e) {
      _flash('换源失败：$e');
    }
  }

  /// 从「第 N 集 / 第N话 / 第N回」解析集号
  ///
  /// 原版：`/第\s*(\d+)\s*[集话回]/`
  ///
  /// ⚠️ 用集号而不是下标 —— 各源的剧集列表长度/缺集情况不同
  ///（原版实测过《老舅》列表显示「第2–27集」，下标与集号不一致）。
  int? _epOrder(String? title) {
    if (title == null || title.isEmpty) return null;
    final m = RegExp(r'第\s*(\d+)\s*[集话回]').firstMatch(title);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  String? get _currentEpisodeTitle => _epIndex < _episodes.length
      ? _episodes[_epIndex].title
      : widget.episodeTitle;

  // ═══════════════════════════════════════════════════════════════════
  //  ★ task-32 ②：投屏（DLNA）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 用户原话（m24232）
  // > 安卓端要支持投屏功能
  //
  // 投屏栈（发现 / 下发 / 代理 / 状态机）由 task-27 落地在
  // `lib/core/dlna/` + `lib/ui/cast/`，**本页只负责把按钮摆进底栏
  // 并把「当前正在播的那条流」喂给它**。控件自己是自包含的：
  // 三态（空闲 / 投屏中 / 失败）、设备列表、toast 全在
  // `CastButton` 内部管，宿主**不要**去碰 `CastManager`。
  //
  // # 为什么必须给**原始地址**而不是本页的代理地址
  //
  // `StreamCandidate.url` 不一定是本地代理地址（见 `models.dart`
  // 的说明）：点播走 `127.0.0.1:56008/s/…`，但直播给的是上游原始
  // 地址。**电视机在另一台设备上**，`127.0.0.1` 对它毫无意义 ——
  // 所以代理由 `CastButton` 按需自己建（它知道电视的 IP）。
  // 我们只管把「播放器现在拿的那条」原样递过去，连 headers 一起
  // （B 站类源少了 Referer，电视拉到的就是 403）。

  /// 投屏到电视（底栏投屏按钮的**回调**）
  ///
  /// ⚠️ 正常路径下**点不到这里** —— 用户点的是 `CastButton` 自己那枚
  ///    `IconButton`，弹设备列表 / 下发 / 回报全在控件内部（见其文件头
  ///    「调用方不需要管 CastManager」）。宿主之所以还要留这么一个落点，
  ///    是为了让调用点与别的按钮同形，也给「将来在别处再放一个投屏入口」
  ///    留同一个出口。
  ///
  /// 「没流不给点」由**不画按钮**承担（`_BottomBar` 的门控
  ///    `castUrl.isNotEmpty`，见其 `castUrl` 文档）；这里再兜一次是
  ///    照抄 [_downloadClip] 的纪律：宁可多一句提示，也不要在 url 为空
  ///    时让控件去弹那句「这个地址不能投屏」—— 那句话听起来像源的问题。
  void _openCast() {
    final st = _current;
    if (st == null) {
      _flash('还没有正在播的流（先起播）');
      return;
    }
    if (!(st.url.startsWith('http://') || st.url.startsWith('https://'))) {
      _flash('这个地址不能投屏（只支持 http/https）');
      return;
    }
    /*
     * ★ 这里**只**做「能投吗」的校验，**不做任何乐观显示**。
     *
     * 铁律（task-32 卡面）：SetAVTransportURI 成功但 Play 失败时，按钮
     * **绝不能**显示成「投屏中」。那条判断在 `CastButton` 内部按
     * `CastPhase` 真值做 —— 外面再包一层「点了就显示投屏中」会把它
     * 变成假的。
     *
     * ⚠️ 真正的设备选择 / 下发 / 结果提示都在控件里（点它自己会弹
     *    设备列表）。宿主这里**没有**能替它点一下的入口，所以校验通过
     *    之后**什么都不做**是**正确**行为，不是漏写。
     */
  }

  /// 投屏时显示在电视上的名字（DIDL 元数据里的 title）
  ///
  /// 优先用当前剧集标题（电视上看到的是「第 3 集」而不是「某某剧」），
  /// 空则退回页面标题，再空则给个中性词 —— 与 `_liveTitle` 同一套
  /// 兜底顺序。
  String get _castTitle {
    final t = _currentEpisodeTitle;
    if (t != null && t.isNotEmpty) return t;
    final live = _liveTitle;
    if (live.isNotEmpty) return live;
    return '投屏';
  }

  // ═══════════════════════════════════════════════════════════════════
  //  剧集导航
  // ═══════════════════════════════════════════════════════════════════

  Episode? get _nextEpisode =>
      _epIndex + 1 < _episodes.length ? _episodes[_epIndex + 1] : null;

  Episode? get _prevEpisode => _epIndex > 0 ? _episodes[_epIndex - 1] : null;

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ task-58：合并页对当前会话下命令（`MediaSession` 的实现）
  // ═══════════════════════════════════════════════════════════════════

  /// 把当前会话换成 [req] —— **不重建 `Player`**
  ///
  /// # 为什么必须走这个方法（而不是重新构造一个 `PlayerPage`）
  ///
  /// `Player` 在 `initState` 里创建（本文件 L1253 `_player = Player(`）⇒
  /// **重新构造 = 新 `State` = 重建播放器** ⇒ 换源/换集时会：
  /// ```text
  /// ① 画面黑一下（重新 open）
  /// ② 播放位置丢失
  /// ③ 全屏态下还会重建视频纹理
  /// ```
  /// 所以合并页必须"对**同一个** `State` 下命令"。
  ///
  /// # 为什么这不是新逻辑（复用既有能力）
  ///
  /// 本文件**早就有**"原地换会话"的先例：
  /// ```text
  /// · `_remoteSwitchSource`（L3508）⇒ `_resolveAndPlay(_provider, _contentId, …)`
  /// · `_adoptLiveChannel`  （L3734）⇒ setState 整批替换会话字段
  /// ```
  /// 而 L666-672 的注释**已声明**：
  /// > `_provider` / `_contentId` / `_sourceCode`
  /// > **初始化时从 widget 取，换源时整批替换。**
  ///
  /// ⇒ 本方法 ≈ `_adoptLiveChannel` 的**点播版**：字段清单照它逐字同款，
  ///   流解析复用 `_resolveAndPlay`，片头片尾复用 `_loadSkipMarker`。
  ///   ★ **不改 `_remoteSwitchSource` / `_gotoEpisode` / `_startPlayback` 任何一行**。
  ///
  /// # ⚠️ 守卫判据必须是**四元组**
  ///
  /// ```text
  /// provider + contentId + episodeId + sourceCode
  /// ```
  /// 只比 `(provider, contentId)` 会把**换集**误判成"同一会话" ⇒ 换集失效。
  /// 而比全字段（含 `episodes`/`title`）又会让"详情刷新后剧集多了一集"
  /// 被当成换会话 ⇒ 无谓重启。四元组正是"决定播哪条流"的最小集合
  /// （判据实现见 `PlayRequestData.isSameSessionAs`）。
  @override
  Future<void> applySession(PlayRequestData req) async {
    /*
     * ① 同一会话 ⇒ 早退，不白重启一次流
     *
     * 与 `_remoteSwitchSource` 开头的 `if (code == _sourceCode) return;`
     * 同一纪律：用户点"已经在播的那一集"不该导致黑屏 + 丢进度。
     */
    final cur = PlayRequestData(
      provider: _provider,
      id: _contentId,
      title: _title,
      episodeId: _epIndex < _episodes.length ? _episodes[_epIndex].id : null,
      sourceCode: _sourceCode,
      episodes: _episodes,
      episodeIndex: _epIndex < _episodes.length ? _epIndex : null,
    );
    if (req.isSameSessionAs(cur)) {
      debugPrint(
        '[PLAYER] applySession：同一会话 ⇒ 不重启 '
        '(${req.provider}:${req.id} ep=${req.episodeId} src=${req.sourceCode})',
      );
      return;
    }

    debugPrint(
      '[PLAYER] applySession：换会话 ⇒ ${req.provider}:${req.id} '
      'ep=${req.episodeId ?? "(无)"} src=${req.sourceCode ?? "(默认)"} '
      '共 ${req.episodes.length} 集',
    );

    /*
     * ② 整批替换会话字段
     *
     * ★ 字段清单照 `_adoptLiveChannel`（L3734）逐字同款 ——
     *   **漏一个就会"串台"**：
     *   ```text
     *   _streams/_current 不清 ⇒ 面板显示上一个源的线路（点下去必然失败）
     *   _skipMarker 不清     ⇒ 新源的片头片尾沿用旧源的秒数 ⇒ 跳错位置
     *   _introSkipped/_outroSkipped 不清 ⇒ 新集一上来就被当成"已跳过"
     *   _nextCountdown 不清  ⇒ 旧集的"即将播放下一集"倒计时继续跑
     *   ```
     * ⚠️ `_epIndex` 由 `req.episodeIndex` 决定；为 null 时退到 0
     *    （与"没指定就播第一集"一致）。
     */
    final newIdx =
        (req.episodeIndex != null &&
            req.episodeIndex! >= 0 &&
            req.episodeIndex! < req.episodes.length)
        ? req.episodeIndex!
        : 0;

    setState(() {
      _provider = req.provider;
      _contentId = req.id;
      _episodes = req.episodes;
      _epIndex = req.episodes.isEmpty ? 0 : newIdx;
      _sourceCode = req.sourceCode;
      /*
       * ★ 标题也要跟着换 —— 否则顶栏还写着**上一部**的名字。
       *
       * 合并页里播放器**先于**详情加载（一进页就起播）⇒ 那一刻 `widget.title`
       * 可能是空的/旧的；等详情到了，`MediaPage` 会带着真标题再调一次
       * `applySession`（见它的 `onLoaded` 处理）。
       *
       * ⚠️ 只在 req 真给了非空标题时才覆盖 —— 避免"换源时没带标题"
       *    把已经正确的标题**清成空串**。
       */
      if (req.title.isNotEmpty) _title = req.title;
      _streams = [];
      _current = null;
      _skipMarker = null;
      // ★ 换会话 ⇒ 同上去掉「已下载 / 上次失败」的残留状态
      _clipDownloaded = false;
      _clipDownloadError = null;
      _introSkipped = false;
      _outroSkipped = false;
      _nextCountdown = 0;
      _countdownTimer?.cancel();
      // 换会话后**不续播旧位置**（新源/新集的秒数没有意义）
      _pendingSeek = null;
    });

    /*
     * ③ 重新解析流并播放
     *
     * ★ 复用 `_resolveAndPlay` —— 它**已经**是"原地换源不重建页面"的实现
     *   （见它自己的注释："播放器页的 widget.provider/id 是 final，没法改，
     *     所以这里直接调 resolveStream 拿新流并播放，不重建整个页面"）。
     */
    final epId = _epIndex < _episodes.length ? _episodes[_epIndex].id : null;

    /*
     * ★★★ 2026-09-26 第二轮：换会话后通知"当前集变了"
     *
     * ⚠️ 必须在 `_resolveAndPlay` **之前**报 —— 那一刻 `_epIndex` 已经更新，
     *    而详情页要靠这个 id 去滚动/高亮。若放在 await 之后，
     *    解析流要几百毫秒到几秒 ⇒ 详情页会**滞后**才滚过去。
     */
    _reportEpisodeChanged();

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-12 ④ 改动 B（2026-10-09）：本地会话的换集走**本地短路**
     * ══════════════════════════════════════════════════════════════════
     *
     * # 改前为什么会坏（真机证据）
     * ```text
     * `PlayerPage.localPath` 是**页面级不可变**的（shell.dart:4773 一次性决定）。
     * 而换集走的是「对同一个 State 下命令」=> 不重建页面 =>
     * 那条路径只能读到「进页面时那一集」的路径。
     * 用户点右侧第 2 集 => 下面无条件走 `_resolveAndPlay` => resolveStream =>
     *   对本地会话报「无法路由: local:<路径>」（Owner 截图里的顶栏 local + 那条红字）。
     * ```
     *
     * # 改法：与 ① `_load()` / ② `_bootLocalFile` 同一条分流纪律
     * ```text
     * req.localPath != null  => 本地文件 => `_bootLocalFile(path: req.localPath)`
     *                           （★ 复用已有实现，**不重写一份**）
     * 否则                    => 在线      => `_resolveAndPlay`（逐字节不变）
     * ```
     *
     * ⚠️ 为什么用 `req.localPath` 而不是 `_localPath`（若设了那个字段）：
     *    这一支的语义就是「**这次请求**要播的本地文件是谁」——
     *    直接用 req 的字段，不引入第二个可能过期的来源。
     */
    if (req.localPath != null) {
      await _bootLocalFile(path: req.localPath);
    } else {
      await _resolveAndPlay(req.provider, req.id, epId, req.sourceCode);
    }

    /*
     * ④ 重新读跳过点 —— 新源的片头片尾可能与旧源不同
     *    （与 `_remoteSwitchSource` 换源后那一步同款）
     *
     * ⚠️ 本地文件**也要**走这一步：片头片尾是**按 provider/id 存**的
     *    （`_loadSkipMarker` 内部用 `_provider`/`_contentId`），而本地会话的 key
     *    是 local:<规范化路径> => 是独立一份，不会串到在线记录上。
     */
    await _loadSkipMarker();
  }

  /// ★ 只更新**展示用**的标题，**不动流**（`MediaSession` 的实现）
  ///
  /// # 为什么与 `applySession` 分开（我第一版合在一起，错了）
  ///
  /// 合并页是"**播放器先起播、详情后加载**"：一进页播放器就开始解析流，
  /// 那一刻还不知道标题；详情拉到 `MediaDetail` 后才拿到真标题。
  ///
  /// 若那个"补标题"的动作去调 `applySession`，就会踩到这个坑：
  /// ```dart
  /// // ✗ 只补标题却走 applySession（episodeId/sourceCode 没传 ⇒ null）
  /// applySession(PlayRequestData(provider: …, id: …, title: d.title));
  /// ```
  /// 而 `isSameSessionAs` 的四元组**含** `episodeId`/`sourceCode` ⇒
  /// 当前在第 3 集时 `null != "ep3"` ⇒ **判为"换了会话"** ⇒
  /// ★ **白重启一次流**（黑屏 + 丢进度）。
  ///
  /// ⇒ 分成两个方法：本方法**只碰 `_title`**，结构上不可能导致重启。
  ///
  /// ⚠️ 与 `_adoptLiveChannel` 的 `_title = next.name` 同一个字段 ——
  ///    但那个是"换台"（要重启），这个是"补展示"（不重启）。
  ///
  /// # ★ 2026-09-26 第二轮：现在**也**接受封面（Owner 报的「播放记录 ？」）
  ///
  /// 详情加载完时调用方（`MediaPage._onDetailLoaded`）手里**同时**有
  /// 标题与封面 ⇒ 一次送达，不必开第二个方法（理由见 `MediaSession` 的文档）。
  ///
  /// ⚠️ 两个字段**各自独立判断**"有没有新值"：
  /// ```text
  /// 只传标题（cover == null）  ⇒ 只更新标题，**保留**已记住的封面
  /// 只传封面（title 为空）     ⇒ 只更新封面，**保留**已记住的标题
  /// ```
  /// ★ 若写成"任一为空就一起覆盖"，会把先到的那个**清掉**
  ///   （实测顺序：标题先到、封面后到 ⇒ 标题会被清空 ⇒ 又回到「？」）。
  @override
  void updateDisplayTitle(String title, {String? cover}) {
    final newTitle = (title.isNotEmpty && title != _title) ? title : null;
    final newCover = (cover != null && cover.isNotEmpty && cover != _cover)
        ? cover
        : null;
    if (newTitle == null && newCover == null) return;
    debugPrint(
      '[PLAYER] updateDisplayMeta：'
      'title「$_title」→「${newTitle ?? _title}」 '
      'cover ${_cover == null ? "(无)" : "有"} → ${newCover == null ? "不变" : "有"}'
      '（不重启流）',
    );
    setState(() {
      if (newTitle != null) _title = newTitle;
      if (newCover != null) _cover = newCover;
    });
  }

  /// ★★★ 当前**正在播**的剧集 id（`MediaSession` 的实现，2026-09-26 第二轮）
  ///
  /// # 为什么详情页需要它（Owner 原话）
  ///
  /// > 加一个剧集自动滚动到当前观看剧集位置的功能，当然进入到这个页面
  /// > **上一集 下一集**，也都要自动联动滚动到当前剧集到可视区域
  ///
  /// 详情页的 `_activeEpisodeId` 只由"用户点了哪一集 / 上次观看记录"决定 ——
  /// 它**感知不到**播放器自己切了集 ⇒ 按「下一集」后高亮不动、也不滚动。
  ///
  /// ⚠️ 与 [isFullscreen] **同构**：这是**只读**查询，实现方不得因为被读
  ///    而改变任何状态。
  @override
  String? get currentEpisodeId => _epIndex >= 0 && _epIndex < _episodes.length
      ? _episodes[_epIndex].id
      : null;

  /// ★★★ 注册"当前剧集变化"的回调（`MediaSession` 的实现）
  ///
  /// ⚠️ 与 [onFullscreenChanged] 同一纪律：`dispose` 时必须注销。
  @override
  set onEpisodeChanged(void Function(String? episodeId)? cb) {
    _onEpisodeChanged = cb;
    // 注册时**立刻补报一次当前值** —— 否则"注册之前就已经在某集"
    // 这个初始状态永远传不出去（详情页会一直停在第 1 集的高亮上）。
    if (cb != null) cb(currentEpisodeId);
  }

  void Function(String? episodeId)? _onEpisodeChanged;

  /// ★★★ 让详情页把**剧集列表**回填给播放器（`MediaSession` 的实现）
  ///
  /// # 为什么需要它（Owner 原话）
  ///
  /// > 加一个剧集自动滚动到当前观看剧集位置的功能，当然进入到这个页面
  /// > **上一集 下一集**，也都要自动联动滚动到当前剧集到可视区域
  ///
  /// 实测（真机 pid 6868，日志）：
  /// ```text
  /// [NAV] 打开合并页: cycani:3862          ← 首页入口只给了 id
  /// [PLAYER-KEY] ⓪ 入口：收到 N            ← 按了「下一集」
  /// （之后**什么都没有**）                 ← ★ 因为 episodes 是空的
  /// ```
  /// 根因：`MediaPage` 的入口把 `episodes: widget.episodes` 传下去，
  /// 而首页那条路径**只传 id** ⇒ 列表恒为空 ⇒ `_nextEpisode == null`
  /// ⇒ `_gotoNextEpisode` 直接 `return`（连"被拦"日志都只在 `_probeLog` 里）。
  ///
  /// # 与 [applySession] 的区别（**关键**）
  ///
  /// ```text
  /// applySession      ⇒ 换会话 ⇒ 重新解析流（黑屏 + 丢进度）
  /// updateEpisodes    ⇒ **只补列表** ⇒ 不动流、不重置位置
  /// ```
  /// ★ 所以**不能**用 `applySession` 代劳 —— 那会在"详情刚加载完"这个
  ///   无害时刻白重启一次流（正是 `updateDisplayTitle` 那条注释记录的教训）。
  @override
  void updateEpisodes(List<Episode> episodes) {
    if (episodes.isEmpty) return;
    /*
     * 幂等判据：**长度 + 首尾 id** 相同就认为没变。
     *
     * ⚠️ 不能只比 `length` —— 换源后长度可能相同而内容是另一部剧。
     * ⚠️ 也不能比整个列表（`List` 没有值相等）⇒ 比首尾 id 是低成本且
     *    对本场景（同一部剧的集列表）足够强的判据。
     */
    final same =
        _episodes.length == episodes.length &&
        (_episodes.isEmpty ||
            (_episodes.first.id == episodes.first.id &&
                _episodes.last.id == episodes.last.id));
    if (same) return;

    debugPrint(
      '[PLAYER] updateEpisodes：${_episodes.length} → ${episodes.length} 集'
      '（只补列表，不重启流）',
    );
    setState(() {
      _episodes = episodes;
      /*
       * ★ 下标要**夹取**：当前 `_epIndex` 是基于**旧**列表算的。
       * 若新列表更短，不夹取就会越界 ⇒ `_episodes[_epIndex]` 抛异常。
       */
      if (_epIndex >= _episodes.length) {
        _epIndex = _episodes.isEmpty ? 0 : _episodes.length - 1;
      }
    });
    /*
     * ★ 列表变了 ⇒ 立刻报一次"当前集"
     *   （详情页要靠它把当前集高亮 + 滚入可视区；否则要等用户手动切集才动）
     */
    _reportEpisodeChanged();

    /*
     * ★ task-31 ④：集列表被换掉 ⇒ 绑定里的「本地集序 → cid」映射可能变了
     *   （新列表更长/更短，`_epIndex` 刚被夹取过）⇒ 顺手刷一次。
     */
    if (biliAutoUpdateEnabled()) unawaited(_biliAutoRefresh());
  }

  /// 通知"当前集变了"（幂等 —— 同一个 id 不会重复回调）
  ///
  /// ★ 抽成一个方法而不是在各处直接调 `_onEpisodeChanged?.call(...)`：
  ///   切集有**三条**路径（`applySession` / `_gotoEpisode` / 自动连播），
  ///   写三遍必然漂 —— 本项目已踩过"两处同构必须一起改"的坑。
  String? _lastReportedEpisodeId;
  void _reportEpisodeChanged() {
    final id = currentEpisodeId;
    if (id == _lastReportedEpisodeId) return;
    _lastReportedEpisodeId = id;
    debugPrint(
      '[PLAYER] 当前集变化 ⇒ ${id ?? "(无)"}'
      '（第 ${_epIndex + 1}/${_episodes.length} 集）',
    );
    _onEpisodeChanged?.call(id);
  }

  /// ★★★ 当前是否全屏（`MediaSession` 的实现，task-58 真机实测后新增）
  ///
  /// # 为什么合并页必须问这个（而不是自己监听窗口事件）
  ///
  /// 我第一版在 `MediaPage` 里用 `WindowListener.onWindowEnterFullScreen`
  /// 监听 —— **真机实测证明它在本项目里永远不会触发**：
  /// ```text
  /// window_manager 的 Windows 插件只在 `WM_SIZE` + `SIZE_MAXIMIZED` 时
  /// 发 "enter-full-screen"；而 `SetFullScreen` 对**无边框**窗口走
  /// `SetWindowPos` 直接改尺寸 ⇒ 不产生 SIZE_MAXIMIZED
  /// ⇒ 事件永不发出（实测 '[MEDIA] 进入全屏' = 0 次，
  ///   而 '[WINDOWFRAME#3] … => fullscreen=true' 证明窗口确实全屏了）
  /// ```
  /// 本窗口是**无边框**的 ⇒ 那条路对本项目**结构性失效**。
  ///
  /// ⇒ 而 `_fullscreen` 是**用户按全屏键**的直接结果（不依赖窗口事件），
  ///   所以它才是**权威来源**。完整推理见 `media_session.dart` 的接口文档。
  ///
  /// ⚠️ 只读 —— 不得因为被读而改变任何状态。
  @override
  bool get isFullscreen => _fullscreen;

  /// ★★★ 全屏状态变化的回调（`MediaSession` 的实现，task-58）
  ///
  /// # 为什么必须由播放器**主动**通知合并页
  ///
  /// `MediaPage` 是**父**节点，`PlayerPage` 是它的**子**节点。
  /// 子节点 `setState` **不会**让父节点重建（Flutter 的正常行为）⇒
  /// 父节点读到的 `isFullscreen` 仍是旧值 ⇒ 详情区不收起来。
  /// 所以这里在状态改变时**主动**回调（见 `_toggleFullscreen` 里的调用）。
  ///
  /// ⚠️ 只存回调，**不**在这里读任何状态。
  @override
  set onFullscreenChanged(void Function(bool fullscreen)? cb) {
    _onFullscreenChanged = cb;
  }

  void Function(bool fullscreen)? _onFullscreenChanged;

  /// 切到某一集
  Future<void> _gotoEpisode(Episode ep) async {
    final i = _episodes.indexWhere((e) => e.id == ep.id);
    if (i < 0) return;

    /*
     * ★ 只读探针：计"真正执行了切集"（task-28 ①-C 的行为层判据）
     *
     * ⚠️ 放在 `i < 0` 守卫**之后**、任何 await **之前** ——
     *    这样"调用即计数"，不会被后面的网络请求影响。
     *    放在守卫之前会把"传了个不存在的 id"也算进去，
     *    那种情况并没有真的切集。
     */
    _gotoEpisodeCalls++; // ★ 只读探针
    _probeLog(
      'gotoEpisode #$_gotoEpisodeCalls  '
      '→ 第 ${i + 1}/${_episodes.length} 集「${ep.title}」  '
      'blockedNav=$_blockedNavCalls',
    );

    /*
     * ★ 切集前**立刻**落盘当前进度
     *
     * 否则用户看了 20 分钟切下一集，那 20 分钟里最后几秒会丢
     *（定时器还没触发）。
     */
    await _saveProgress(immediate: true);

    _cancelNextCountdown();
    setState(() {
      _epIndex = i;
      _episodeSheetOpen = false;
      _introSkipped = false;
      _outroSkipped = false;
      _skipMarker = null;
      // ★ 换集 ⇒ 上一集的「已下载」不适用于这一集
      _clipDownloaded = false;
      _clipDownloadError = null;
      // 新集从 0 开始（不是续播）
      _pendingSeek = null;
    });

    // ★★★ 切集了 ⇒ 通知合并页（详情页靠它把"当前集"高亮 + 滚进可视区）
    _reportEpisodeChanged();

    /*
     * ★ task-31 ④：切集后**立刻**刷新 B 站弹幕
     *
     * `_reload()` 会重新起播，而起播里那条 `_loadDanmaku()` 是
     * `unawaited` 的 —— 不等它。这里先刷一次，用户切过去时弹幕就已经是
     * 新一集的了（`shouldAutoUpdate` 会把「开关关了 / 缓存还新鲜」判掉）。
     *
     * ⚠️ 必须 `unawaited`：刷新要发网络请求，等它会把切集卡住。
     */
    if (biliAutoUpdateEnabled()) unawaited(_biliAutoRefresh());

    // 重新解析这一集的流
    await _reload();
  }

  Future<void> _gotoNextEpisode() async {
    final n = _nextEpisode;
    if (n == null) {
      /*
       * ★ 只读探针：记"被边界挡回去了"
       *
       * 与 `_gotoEpisodeCalls` 配对才能区分两种"没切"：
       * ```text
       * blockedNav +1 且 gotoEpisode 不变  ⇒ 判据拦住了（期望）
       * 两个都 +1                          ⇒ 判据失效（真 bug）
       * ```
       */
      _blockedNavCalls++; // ★ 只读探针
      _probeLog(
        'gotoNextEpisode 被拦：已是最后一集'
        '（_epIndex=$_epIndex / 共 ${_episodes.length} 集）'
        '  blockedNav=$_blockedNavCalls',
      );
      return;
    }
    await _gotoEpisode(n);
  }

  /// 切到上一集（与 `_gotoNextEpisode` 对称，同样带边界计数）
  Future<void> _gotoPrevEpisode() async {
    final p = _prevEpisode;
    if (p == null) {
      _blockedNavCalls++; // ★ 只读探针
      _probeLog(
        'gotoPrevEpisode 被拦：已是第一集'
        '（_epIndex=$_epIndex）  blockedNav=$_blockedNavCalls',
      );
      return;
    }
    await _gotoEpisode(p);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 局域网遥控：播放页交出的两个能力（task-14 F）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 与 `remote_bridge.dart` 的契约：
  // ```text
  // PlayerBridge.getState() → RemoteState   手机端靠它渲染界面
  // PlayerBridge.exec(cmd)  → 执行一条命令
  // ```
  // 分发在桥那边（`_execCommand`），**这里只负责"命令 → 播放器动作"**。
  //
  // ⚠️ 两个方法的实现原则（与原版一致）：
  // ```text
  // · 未知命令 **忽略**（不抛）—— 桥那边已经 catch，但这里也不该炸
  // · 参数缺失/越界 **静默不动** —— 与 PrevEpisode 的边界做法一致
  // · 任何动作失败都不能把播放页带崩（遥控是"尽力而为"的通道）
  // ```

  /// 把当前播放状态压成遥控端的 [RemoteState]
  ///
  /// # ★ 这是手机端「选集面板」终于能显示的原因
  ///
  /// `episodes` 为空时，`page.html` 的 `epsCard` 整块隐藏
  ///（判据 `episodes.length > 1`）。以前 `setPlayer` 从没被调用，
  /// 状态恒为 `RemoteState.idle()` → 手机上的选集**永远是空的**。
  ///
  /// # 字段口径向原版 `PlayerView.vue::reportState()` 对齐
  ///
  /// ```ts
  /// episode_order: m ? Number(m[1]) : eps.length > 1 ? currentIndex+1 : 0
  /// episode_count: eps.length > 1 ? eps.length : 0
  /// ```
  /// 即：**集号优先从标题里解析**（「第5集」），解析不到才用下标+1；
  /// 单集内容（`eps.length <= 1`）时两者都给 0（手机端据此不显示选集）。
  ///
  /// # ⚠️ 线路列表只能给**当前这一条**
  ///
  /// 与原版一致（原版 `reportState` 也只有
  /// `sources: sources.value.map(...)` + `current_source`）。
  ///
  /// 我第一版**猜错了**：以为 `_streams` 是线路列表，
  /// 实际上 `_streams` 是 `resolve_stream` 返回的**清晰度候选**
  ///（同一线路的多个码率）—— 拿它当线路会在手机上画出
  /// 一堆同名按钮。`PlayerPage` 根本**没存** `detail.sources`（线路列表），
  /// 所以只能如实上报"当前这一条"。
  /// 手机端 `srcCard` 的判据是 `sources.length > 1`，
  /// 所以它会隐藏 —— 后续若要支持换线路，
  /// 需要先把 `detail.sources` 存进 `PlayerPage`（独立一步，本次不做）。
  RemoteState _remoteGetState() {
    /*
     * 直播没有集数概念（同 `_openSkipDialog` 的判据）。
     */
    final multi = _episodes.length > 1 && !_isLive;

    final order = multi
        ? (_epOrder(_currentEpisodeTitle) ?? (_epIndex + 1))
        : 0;

    return RemoteState(
      playing: _playing,
      title: _title,
      episodeOrder: order,
      episodeCount: multi ? _episodes.length : 0,
      position: _position.inSeconds,
      duration: _duration.inSeconds,
      volume: _volume.round().clamp(0, 100),
      muted: _muted,
      /*
       * ⚠️ 只能报**当前这一条**（见上面的说明）。
       *    用 `displayName` 而不是 `kind` —— 与选清晰度面板同一口径
       *（`player_page.dart` 的 ListTile 用的就是 `s.displayName`）。
       */
      sources: _streams.isEmpty
          ? const []
          : [(_sourceCode ?? '', _streams.first.displayName)],
      currentSource: _sourceCode ?? '',
      /*
       * 剧集列表 `(集号, 标题)` —— 手机端集号用于 `goto_episode`。
       * 集号口径与 `order` 一致：标题里能解析出「第N集」就用它，
       * 否则退回下标+1（原版 `episodes.map` 就是这么做的）。
       */
      episodes: multi
          ? [
              for (var i = 0; i < _episodes.length; i++)
                (_epOrder(_episodes[i].title) ?? (i + 1), _episodes[i].title),
            ]
          : const [],
      hasMedia: true,
      introStart: _skipMarker?.introStart,
      introSkip: _skipMarker?.introEnd,
      outroSkip: _skipMarker?.outroStart,
      outroEnd: _skipMarker?.outroEnd,
      autoSkip: _autoSkip,
    );
  }

  /// 执行一条手机端发来的命令
  ///
  /// # 覆盖 `page.html` 会发出的**全部播放类** kind
  ///
  /// ```text
  /// toggle_play      播放/暂停
  /// prev_episode     上一集
  /// next_episode     下一集
  /// goto_episode     跳到第 N 集（按**集号**，不是下标）
  /// seek             相对快进/快退（秒，可为负）
  /// seek_to          绝对跳转（秒）
  /// set_volume       音量 0~100
  /// toggle_mute      静音切换
  /// switch_source    切换线路（按 code）
  /// skip_config_open 打开片头片尾设置弹窗
  /// skip_preview     预览跳到某秒（手机上微调时）
  /// skip_confirm     锁定为片头/片尾（手机确认）
  /// skip_clear       清除本剧跳过设置
  /// skip_toggle_auto 开关「自动跳过」
  /// ```
  ///
  /// ⚠️ `play_item` / `query_search` / `query_home` / `move_provider`
  ///    **不在这里** —— 它们由桥的全局能力处理（与播放页无关）。
  Future<void> _remoteExec(RemoteCommand c) async {
    if (!mounted) return;

    switch (c.kind) {
      case 'toggle_play':
        _togglePlay();
        return;

      case 'next_episode':
        await _gotoNextEpisode();
        return;

      case 'prev_episode':
        /*
         * ★ 走 `_gotoPrevEpisode`（而不是内联判 null）—— task-28 ①-C
         *
         * 内联写法 `if (p != null) await _gotoEpisode(p);` 在功能上等价，
         * 但它**绕过了边界计数器** —— 遥控端发 prev_episode 时
         * `_blockedNavCalls` 不会 +1，于是"遥控在最后一集发命令"
         * 这种情况在探针里看不出来。
         * 统一走一个出口，计数才是完整的。
         */
        await _gotoPrevEpisode();
        return;

      case 'goto_episode':
        /*
         * ★ 手机端给的是**集号**（「第5集」的 5），不是下标 ——
         *   各源的列表长度/缺集情况不同，按下标会跳错集
         *  （原版 `PlayerView.vue` 的 `execRemote` 也是按集号找）。
         */
        final order = c.number('order')?.toInt();
        if (order == null) return;
        final i = _episodes.indexWhere((e) => _epOrder(e.title) == order);
        if (i < 0) {
          debugPrint(
            '[REMOTE] goto_episode 找不到第 $order 集（共 ${_episodes.length} 集）',
          );
          return;
        }
        await _gotoEpisode(_episodes[i]);
        return;

      case 'seek':
        final d = c.number('delta')?.toInt();
        if (d == null || d == 0) return;
        _seekBy(d);
        return;

      case 'seek_to':
        final pos = c.number('position')?.toInt();
        if (pos == null) return;
        // 与 `_seekBy` 同一套夹取（直播不能跳）
        if (_isLive) return;
        final target = Duration(seconds: pos < 0 ? 0 : pos);
        final clamped = target > _duration ? _duration : target;
        await _player.seek(clamped);
        _flash('跳到 ${clamped.inSeconds}s');
        _showControls();
        return;

      case 'set_volume':
        final v = c.number('value')?.toInt();
        if (v == null) return;
        final clamped = v.clamp(0, 100).toDouble();
        // ★ 遥控器调音量 = 用户发起的（白名单，见 `_lastUserVolumeAction`）
        _lastUserVolumeAction = DateTime.now();
        _sendVolume(clamped);
        /*
         * 调音量顺带解除静音 —— 用户按了「音量 +」却还是没声音
         * 会以为坏了（原版 ArtPlayer 也是这个行为）。
         */
        setState(() {
          _volume = clamped;
          if (clamped > 0) _muted = false;
        });
        _flash('音量 ${clamped.round()}');
        _showControls();
        return;

      case 'toggle_mute':
        _toggleMute();
        return;

      case 'switch_source':
        final code = c.code;
        if (code == null || code.isEmpty) return;
        await _remoteSwitchSource(code);
        return;

      case 'skip_config_open':
        if (_isLive) return;
        await _openSkipDialog();
        return;

      case 'skip_preview':
        /*
         * 手机微调时让**电视画面**跟着跳 —— 草稿的方案 A：
         * 「手机上拖，电视上出画面」（电视屏幕大，看得准）。
         * ⚠️ 只 seek，**不改** `_skipMarker` —— 用户点「确认」才落库。
         */
        final pos = c.number('position')?.toInt();
        if (pos == null || _isLive) return;
        final t = Duration(seconds: pos < 0 ? 0 : pos);
        await _player.seek(t > _duration ? _duration : t);
        _flash('预览 ${t.inSeconds}s');
        return;

      case 'skip_confirm':
        await _remoteConfirmSkip(c.args['target']?.toString());
        return;

      case 'skip_clear':
        await _remoteClearSkip();
        return;

      case 'skip_toggle_auto':
        final on = c.flag('on');
        if (on == null) return;
        setState(() => _autoSkip = on);
        // ⚠️ `UiPrefs.set` 返回 void（同步落盘），不能 await
        UiPrefs.set('dsh.playprefs.autoSkip', on ? '1' : '0');
        _flash(on ? '自动跳过已开启' : '自动跳过已关闭');
        return;

      default:
        // 其余（play_item / query_* / move_provider）由桥的全局能力处理
        return;
    }
  }

  /// 按线路 code 切源（复用 `_resolveAndPlay` 的既有路径）
  ///
  /// # 为什么不调 `_applySwitch`
  ///
  /// 我第一版写的是 `_applySwitch(SwitchPick(...))` —— **猜错了**。
  /// `SwitchPick` 的语义是「**换到另一个內容站**」
  ///（它里面有 `provider` / `id`，会去拉新站的详情与剧集）；
  /// 而 `switch_source` 的语义是「**同一个片子换一条线路**」——
  /// provider/id 都不变，只换 `sourceCode`。
  /// 两者混用会把用户的片子换成另一个（严重）。
  ///
  /// 所以这里直接走 `_resolveAndPlay`（它就是「按 sourceCode 重新
  /// resolve 并播放」，且**保留当前剧集与进度**）。
  Future<void> _remoteSwitchSource(String code) async {
    if (code == _sourceCode) return; // 已经是这条线路，别白重启一次流
    final ep = _epIndex < _episodes.length ? _episodes[_epIndex] : null;
    // ⚠️ `_resolveAndPlay` 是**位置参数**（不是命名参数）
    await _resolveAndPlay(_provider, _contentId, ep?.id, code);
    if (mounted) _flash('已切换线路');
  }

  /// 手机端确认「片头结束 / 片尾开始」→ 落库
  ///
  /// 与 `_openSkipDialog` 返回后的那段逻辑**同一套**（都调
  /// `SourinApi.setSkipMarker` 并更新 `_skipMarker`）——
  /// 不另写一份，否则两处的字段口径迟早漂移。
  ///
  /// ⚠️ 只提交**被确认的那一个端点**，另一个端点保持原值
  ///（不传 null 也不传 0 —— `setSkipMarker` 的参数是
  /// `if (x != null)` 才会进 payload，传 null 就是"不改它"）。
  Future<void> _remoteConfirmSkip(String? target) async {
    if (_isLive) return;
    if (target != 'intro' && target != 'outro') {
      debugPrint('[REMOTE] skip_confirm 缺少合法 target: $target');
      return;
    }
    final pos = _position.inSeconds;

    try {
      await SourinApi.setSkipMarker(
        _provider,
        widget.id,
        /*
         * ★★★ task-72【④】这里原来写的是 `widget.title` —— **写库路径**
         *
         * 与 L2865（`_saveProgress`）是**同一类 bug**：写库读了 `final`
         * 构造参数，而合页入口传的是 `title: ''`。
         * ⇒ 实测用户真实库（只读副本，`.probe/c6.py`）里
         *   `progress` 表**已有 1 行空标题** —— 就是上一次同类 bug 的化石。
         *   `skip_markers` 目前 3 行标题都正常（**侥幸**），
         *   但只要本路径在标题为空时被触发，就会**新造一行空标题**。
         * ⇒ 修法：活值 + `widget.title` 兜底（与 L2865 逐字同写法）。
         */
        title: _liveTitle,
        introStart: target == 'intro'
            ? (_skipMarker?.introStart ?? 0)
            : _skipMarker?.introStart,
        introEnd: target == 'intro' ? pos : _skipMarker?.introEnd,
        outroStart: target == 'outro' ? pos : _skipMarker?.outroStart,
        outroEnd: _skipMarker?.outroEnd,
        autoSkip: _skipMarker?.autoSkip ?? _autoSkip,
      );
      if (!mounted) return;
      /*
       * 立刻用到当前会话（与 `_openSkipDialog` 同一做法）——
       * 不重新拉接口，并重置"已触发过"标志，
       * 否则新设置本次会话**不再生效**（表现为"设了没用"）。
       */
      setState(() {
        _skipMarker = SkipMarker(
          key: '$_provider:${widget.id}',
          provider: _provider,
          nativeId: widget.id,
          title: _liveTitle,
          introStart: target == 'intro'
              ? (_skipMarker?.introStart ?? 0)
              : _skipMarker?.introStart,
          introEnd: target == 'intro' ? pos : _skipMarker?.introEnd,
          outroStart: target == 'outro' ? pos : _skipMarker?.outroStart,
          outroEnd: _skipMarker?.outroEnd,
          autoSkip: _skipMarker?.autoSkip ?? _autoSkip,
        );
        _introSkipped = false;
        _outroSkipped = false;
      });
      _flash(target == 'intro' ? '已设为片头 $pos s' : '已设为片尾 $pos s');
    } catch (e) {
      debugPrint('[REMOTE] skip_confirm 落库失败: $e');
      _flash('设置失败：$e');
    }
  }

  /// 手机端「取消跳过」→ 清除本剧设置
  Future<void> _remoteClearSkip() async {
    try {
      await SourinApi.clearSkipMarker(_provider, widget.id);
      if (!mounted) return;
      setState(() {
        _skipMarker = null;
        _introSkipped = false;
        _outroSkipped = false;
      });
      _flash('已清除本剧跳过设置');
    } catch (e) {
      debugPrint('[REMOTE] skip_clear 失败: $e');
      _flash('清除失败：$e');
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
      _errorKind = null;
    });
    try {
      final ep = _epIndex < _episodes.length ? _episodes[_epIndex] : null;
      final list = await SourinApi.resolveStream(
        _provider,
        _contentId,
        req: PlayRequest(sourceCode: _sourceCode, episodeId: ep?.id),
      );
      if (!mounted) return;
      setState(() => _streams = list);
      final first = list.where((s) => s.isPlayable).firstOrNull;
      if (first == null) {
        setState(() {
          _error = '这一集没有可播放的地址';
          _loading = false;
        });
        return;
      }
      await _startPlayback(first);
      await _loadSkipMarker();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          // ★ 结构化类别（能从 SourinCoreException 拿到就记下来）
          _errorKind = _kindOf(e);
          _loading = false;
        });
      }
    }
  }

  /// ★★★ task-53【#4b】在播放页里切到另一个直播频道（用户第 4 条的核心）
  ///
  /// [delta] `+1` 下一个台（↓）、`-1` 上一个台（↑）。
  ///
  /// # 为什么单独写一个（不能复用 `_reload()`）
  /// ```text
  /// `_reload()` 走的是**点播**那条路：`resolveStream(_provider, _contentId, …)`
  ///   ⇒ 直播的 url 来自 `getLiveStream(provider, channelId)`，
  ///     **接口都不同**（`_load()` 里那个 `if (_isLive)` 分支正是为此）。
  /// ★ 而且 `_reload()` 会 `await _loadSkipMarker()` ——
  ///   直播没有片头片尾概念（那个方法第一行就 `if (_isLive) return;`），
  ///   但与 `_episodes` 相关的下标运算在直播下全是无意义的。
  /// ⇒ 直播切台照抄的应该是 **`_load()` 的直播分支**，不是 `_reload()`。
  /// ```
  ///
  /// # 三步（顺序不能换）
  /// ```text
  /// ① 问直播页"下一个台是哪个"（它手里有探针缓存 + 启用态 = 唯一真相）
  /// ② 换掉标题/频道 id（**必须在起播前** —— 顶栏与遥控状态读的是它们）
  /// ③ 起播（走与 `_load()` 同一条 `getLiveStream` + `_startPlayback`）
  /// ```
  ///
  /// # ⚠️ 必须清掉的直播残留（否则会串台）
  /// ```text
  /// _streams / _current / _pendingSeek / _liveAudioOnlyNotice
  ///   ⇒ 上一个台的线路列表/黑屏横幅留着，新台还没解析完就会显示旧台的信息
  /// ```
  /// ★★★ task-53【③】打开/关闭「所有直播」面板（用户第 3 条）
  ///
  /// ```text
  /// 用户原话：> 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
  /// ```
  ///
  /// # ★ 为什么这里**不**缓存频道列表
  /// ```text
  /// 候选：打开时调一次 `onLiveChannels()` 存进 state，之后渲染缓存。
  /// ★ 否掉：频道列表会**变** —— 用户在设置页关掉一个源、或探针 TTL 到期
  ///   重新探测 ⇒ 缓存会让面板显示**过期的台**（点下去必然失败）。
  /// ⇒ 每次 `build` 现取（`_liveChannels()` 是纯查询、无副作用、O(n) 很小）。
  /// ```
  void _toggleLiveChannels() {
    setState(() => _liveChannelsOpen = !_liveChannelsOpen);
  }

  /// 现取可见频道列表（`null` = 没有/没接线）
  ({List<LiveChannel> channels, int index})? _liveChannels() =>
      widget.onLiveChannels?.call();

  /// 上一次取到的频道列表（**只**用于抽屉的退出动画，见下）
  ({List<LiveChannel> channels, int index})? _liveChannelsLast;

  /// ★★★ task-72【④】给「所有直播」抽屉用的取值入口
  ///
  /// # 为什么要绕一层（而不是直接 `_liveChannelsOpen ? _liveChannels() : null`）
  ///
  /// 直接写成三元表达式会引入一个**新 bug**：抽屉关闭时 `data` 立刻变 null，
  /// 而 `SheetTransition` 在 `visible:false` 之后**仍然挂着 child 跑完
  /// 220ms 退出动画**（`lib/ui/widgets/episode_strip.dart:1131-1153`：
  /// `_mounted` 直到 reverse 结束才置 false）
  /// ⇒ 用户会看到抽屉**一边滑走一边把列表清空**（标题变成「所有直播（0）」）。
  ///
  /// # 语义
  /// ```text
  /// 开着 ⇒ 每次 build **现取** —— 列表会变（用户在设置页关掉一个源、
  ///        或探针 TTL 到期重探）⇒ 必须新鲜，这与
  ///        `_liveChannels()` 上方 L4240-4245 否掉"打开时缓存一次"的理由一致
  /// 关着 ⇒ 沿用**上一次**取到的 —— 既不再调用（这是 ④ 的收益：
  ///        实测改前每次整页重建都调一次，而播放中位置 tick 很频繁），
  ///        又让退出动画有内容可画
  /// ```
  ///
  /// ⚠️ 这里**没有** `setState`：只是把取到的值记下来，不触发重建
  ///    （在 build 里给缓存字段赋值不会造成循环）。
  ({List<LiveChannel> channels, int index})? _liveChannelsForSheet() {
    if (_liveChannelsOpen) {
      final v = _liveChannels();
      if (v != null) _liveChannelsLast = v;
      return v;
    }
    return _liveChannelsLast;
  }

  /// ★★★ task-53【③】在面板里点选某个台 ⇒ 切过去
  ///
  /// # ★ 复用 `_switchLiveChannel` 的**全部**后续逻辑（铁律 170）
  /// ```text
  /// 点选与上下键的差别**只有"目标台从哪来"**：
  ///   ↑/↓   ⇒ `onLiveChannelStep(delta)` 算相邻台
  ///   点选  ⇒ `onLiveChannelPick(channel)` 用用户点的那个
  /// ★ 而"采纳之后"（清线路、代次守卫、黑屏横幅、起播）**必须逐字相同** ——
  ///   否则会出现"上下键切台正常、点选切台双声/黑屏"这种最难查的 bug。
  /// ⇒ 抽成 `_adoptLiveChannel(pick)`，两条路共用。
  /// ```
  Future<void> _pickLiveChannel(LiveChannel channel) async {
    final cb = widget.onLiveChannelPick;
    if (cb == null) return;
    /*
     * ★ 先关面板：用户点了就该立刻看到画面在换。
     *   （与 `_gotoEpisode` 里 `_episodeSheetOpen = false` 同一时机 ——
     *     放在 await **之前**，否则网络慢时面板会僵在那儿。）
     */
    setState(() => _liveChannelsOpen = false);
    final pick = cb(channel);
    if (pick == null) {
      debugPrint('[PLAYER] 直播点选：直播页不认这个频道 ${channel.name}');
      _flash('这个频道现在不可用');
      _showControls();
      return;
    }
    await _adoptLiveChannel(pick);
  }

  /// ★★★ task-53【#4b】直播时 ↑/↓ 切频道（用户第 4 条）
  ///
  /// ⚠️ 只是 `_adoptLiveChannel` 的**取目标**那一半 ——
  ///   "采纳之后"的全部逻辑在 `_adoptLiveChannel`（与点选共用，铁律 170）。
  Future<void> _switchLiveChannel(int delta) async {
    final cb = widget.onLiveChannelStep;
    if (cb == null) return;

    final pick = cb(delta);
    if (pick == null) {
      /*
       * 直播页答"没有下一个台"（列表为空 / 还没加载完）。
       * ★ 必须给用户一个反馈 —— 否则他会以为"键盘坏了"。
       */
      debugPrint('[PLAYER] 直播切台：直播页没给出目标频道（delta=$delta）');
      _flash('没有其它频道');
      _showControls();
      return;
    }
    await _adoptLiveChannel(pick);
  }

  /// ★ "采纳某个直播频道"的**唯一实现**（↑/↓ 与点选**共用**）
  ///
  /// ⚠️ 调用方负责：① 拿到非 null 的 `pick` ② 自己关掉相关面板。
  Future<void> _adoptLiveChannel(
    ({String provider, LiveChannel channel}) pick,
  ) async {
    final next = pick.channel;
    debugPrint('[PLAYER] 直播切台 ⇒ ${next.name}（provider=${pick.provider}）');

    setState(() {
      _provider = pick.provider;
      _contentId = next.id;
      _liveChannelId = next.id;
      _title = next.name;
      /*
       * ★ 换台 ⇒ 线路是**新台**的，旧列表必须清掉。
       *   留着会让"选线路"面板显示上一个台的清晰度（点下去必然失败）。
       */
      _streams = [];
      _current = null;
      _sourceCode = null;
      // ★ 上一个台的黑屏横幅不能留到新台（它是按旧台的线路算出来的）
      _liveAudioOnlyNotice = null;
      // ★ 同理：画面输出层的判决也是按旧台那一次起播算的
      _videoOutputDead = false;
      _loading = true;
      _error = null;
      _errorKind = null;
    });

    try {
      final list = await SourinApi.getLiveStream(pick.provider, next.id);
      if (!mounted) return;
      /*
       * ★★ 代次保护（与 `_loadProviderName` 同一手法）
       *
       * 用户连按 ↓↓ 会**并发**两次切台，而 `getLiveStream` 是异步的
       * ⇒ 先发的那次可能**后**返回 ⇒ 画面停在"上一个目标"上
       *   （表现为"按两下 ↓ 却停在了中间那个台"）。
       * ★ 判据：发起时的频道是否**仍是**当前频道。不是就丢弃这次结果。
       */
      if (_liveChannelId != next.id) {
        debugPrint(
          '[PLAYER] 直播切台：${next.name} 的结果已过期（当前='
          '$_liveChannelId）⇒ 丢弃',
        );
        return;
      }
      setState(() => _streams = list);

      final first = list.where((s) => s.isPlayable).firstOrNull;
      if (first == null) {
        setState(() {
          _error = list.isEmpty ? '该频道没有可播放的地址' : '所有线路都不可播（可能受 DRM 保护）';
          _loading = false;
        });
        return;
      }

      /*
       * ★ 黑屏横幅的判据与 `_load()` **逐字一致** ——
       *   两处写法不同就会出现"首播有提示、换台后没有"（用户会以为换台坏了）。
       */
      final playableLines = list.where((s) => s.isPlayable).toList();
      final hasDrmVideo = list.any(
        (s) => s.drmProtected && (s.quality == '高清' || s.quality == '标清'),
      );
      final onlyAudioPlayable =
          playableLines.isNotEmpty &&
          !playableLines.any((s) => s.quality == '高清' || s.quality == '标清');
      final audioOnlyNotice = (hasDrmVideo && onlyAudioPlayable)
          ? first.displayName
          : null;
      setState(() => _liveAudioOnlyNotice = audioOnlyNotice);

      /*
       * ★★★ 直播**绝不**走 `_prepareResume()`
       *
       * `_prepareResume()` 会读"上次看到哪"并写 `_pendingSeek`。
       * 直播没有进度概念（它第一行就 `if (_isLive) return;`），
       * ★ 而换台时若不清 `_pendingSeek`，`_startPlayback` 会把
       *   **上一个点播的续播位置** seek 到新台上 —— 表现为"换台后画面
       *   莫名跳到中间"（甚至直接黑屏，因为直播流 seek 出去就回不来）。
       */
      _pendingSeek = null;
      await _startPlayback(first);
      if (mounted) _flash(next.name);
    } catch (e) {
      if (!mounted) return;
      if (_liveChannelId != next.id) return;
      debugPrint('[PLAYER] 直播切台失败 ${next.name}: $e');
      setState(() {
        _error = e.toString();
        _errorKind = _kindOf(e);
        _loading = false;
      });
    }
  }

  /// 用**指定的** provider/id 解析流并播放（换源专用）
  ///
  /// ⚠️ 与 `_reload()` 的区别：`_reload` 用的是当前 `_provider/_contentId`
  ///    （切集时用），而这个方法显式传入 —— 换源时新值还没写进 state
  ///    （要先解析成功才敢替换，否则失败会留下一个坏状态）。
  Future<void> _resolveAndPlay(
    String provider,
    String contentId,
    String? episodeId,
    String? sourceCode,
  ) async {
    setState(() {
      _loading = true;
      _error = null;
      _errorKind = null;
    });
    try {
      final list = await SourinApi.resolveStream(
        provider,
        contentId,
        req: PlayRequest(sourceCode: sourceCode, episodeId: episodeId),
      );
      if (!mounted) return;

      final first = list.where((s) => s.isPlayable).firstOrNull;
      if (first == null) {
        setState(() {
          _error = '新源没有可播放的地址';
          _loading = false;
        });
        return;
      }

      /*
       * ★ 解析成功后才替换 provider/id
       *
       * 失败的话保持原状态，用户可以继续看原来那个源。
       */
      setState(() {
        _provider = provider;
        _contentId = contentId;
        _sourceCode = sourceCode;
        _streams = list;
      });

      /*
       * ★ 换源后刷新顶栏的站名（task-32）
       *
       * `_provider` 刚刚变了 —— 不重取的话顶栏会一直显示**旧站名**，
       * 那比不显示更糟（用户会以为换源没生效）。
       *
       * ⚠️ 必须在 `setState` **之后**调 —— `_loadProviderName` 里
       *    那个代次判据比的是 `_provider`，顺序反了会把这次当成过期丢弃。
       */
      unawaited(_loadProviderName());

      await _startPlayback(first);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          // ★ 结构化类别（能从 SourinCoreException 拿到就记下来）
          _errorKind = _kindOf(e);
          _loading = false;
        });
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  播放控制
  // ═══════════════════════════════════════════════════════════════════

  void _togglePlay() {
    _togglePlayCalls++; // ★ 只读探针（交付实测读它证明"单击仍能播放/暂停"）
    /*
     * 真机实测靠这行日志取证 —— 用 `SetCursorPos + mouse_event` 点真实窗口时，
     * Dart 侧没有别的钩子能读"单击到底走了哪条路径"。
     */
    _probeLog(
      'togglePlay #$_togglePlayCalls  '
      'pos=${_position.inMilliseconds / 1000.0}s  '
      'seekByCalls=$_seekByCalls  playing=$_playing',
    );
    if (_playing) {
      _player.pause();
    } else {
      _player.play();
    }
    _showControls();
  }

  /// 真机实测取证：把播放页手势的真实挂载状态打进日志
  ///
  /// 在首帧后调用（`initState` 里那时还没 build，`GlobalKey` 取不到 widget）。
  void _probeGestureMount() {
    if (!kGestureProbe || !mounted) return;
    _probeLog(
      'gesture-mount ${debugPlayerOwnGestureState()}  '
      '(tap=true 且 tapUp=false 才是本次需求要的状态)',
    );
  }

  /// 当前设备是否**触摸端**（手势只在这些平台上生效）
  ///
  /// # 判定依据
  ///
  /// ```text
  /// 手机（touchOnly）→ 是
  /// TV（遥控器）    → **否**（TV 用遥控器方向键，触摸手势没有意义，
  ///                     而且 TV 上误触代价更大）
  /// PC（desktop）   → 否
  /// ```
  /// 用 `isTouchOnly` 而不是"非桌面" —— TV 也不是触摸端。
  bool get _isTouchGestureTarget => widget.isTouchOnly;

  /// 是否是**PC 键盘**场景（方向键单击步数 / 长按倍速）
  ///
  /// # 为什么是 `!isTv && !isTouchOnly` 而不是读 `Device.isDesktop`
  ///
  /// `PlayerPage` 的**所有生产调用点**（`shell.dart` 五处 +
  /// `aq_login_probe` / `episode_player_probe` / `skip_probe`）都传了
  /// `isTv: Device.isTv, isTouchOnly: Device.isTouchOnly` ——
  /// 也就是说这两个参数**已经是实际平台的函数**。
  /// 直接用它们的好处：
  /// ```text
  /// ① 不依赖全局可变状态（Device.kind 是缓存的静态值）
  /// ② widget 测试里可以**直接构造出 PC 场景**，
  ///    而不得不去改全局的 Device.overrideKind
  /// ```
  bool get _isPcKeyboardTarget => !widget.isTv && !widget.isTouchOnly;

  /// 双击手势是否启用（PC/TV 恒 false）
  bool get _doubleTapEnabled =>
      PlayerGestures.doubleTapEnabledFor(isTouch: _isTouchGestureTarget);

  /// ★ 有没有任何浮层打开（task-42）
  ///
  /// # 为什么要这个判据
  /// ```text
  /// 用户要「Enter = 全屏」，但 Enter 在打开着的面板里该**激活面板项**。
  /// ★ 既有代码里已经有这个门控思想（L4086-4135：面板打开时 Enter 让给面板），
  ///   只是它用的是 `widget.isTv && _episodeSheetOpen`。
  /// ⇒ 抽成一个 getter，让"桌面 Enter=全屏"也能复用它。
  /// ```
  /// ⚠️ 列全**七种**浮层 —— 少一个就会出现"面板开着按 Enter 却全屏了"。
  bool get _anySheetOpen =>
      _episodeSheetOpen ||
      _settingsOpen ||
      _streamSheetOpen ||
      _hintsOpen ||
      // ★ task-22 P1-5：底栏长按弹出的「画面缩放」滑条（同样是铺满宽度的浮层）
      _zoomOpen ||
      // ★ task-53【③】「所有直播」面板（用户第 3 条）
      _liveChannelsOpen ||
      // ★ task-13 ⑦ 弹幕设置面板（同样是 Positioned.fill 的全屏浮层）
      _danmakuSheetOpen ||
      // ★ task-31 ④ 哔哩哔哩弹幕导入面板（同款全屏浮层）
      _biliSheetOpen ||
      // ★ task-31 ⑤ 在线搜索字幕面板（同款全屏浮层）
      _subtitlePanelOpen;

  /// ★★★ 错误态下顶栏那枚返回箭头**必须仍然可用**（Owner 2026-10-09 新增）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// # Owner 原话（附截图：黑屏 + 「播放失败 / Failed to open …m3u8」）
  /// ══════════════════════════════════════════════════════════════════
  /// ```text
  /// > 还有一个问题,如果不能播放的时候,左上角的返回,是不能点击的,
  /// > 只能点击返回按钮,才能返回到上一层
  /// ```
  ///
  /// # 改前为什么点不动（两枚箭头**同时**失效）
  /// ```text
  /// ① `_canUseFloatingBack` 里的 `_error == null` 为 false
  ///    => `onFloatingBack` 传 null
  ///    => `_TopBar` 内部 `if (!visible && onFloatingBack != null)` 不成立
  ///    => **常驻悬浮返回键根本不画**；
  /// ② `visible: _controlsVisible && _error == null` 也是 false
  ///    => 顶栏那条 `IgnorePointer(ignoring: !visible)` 把整条顶栏挡住
  ///    => 顶栏那枚箭头「看起来还在」但**命中测试穿不过去**。
  /// ⇒ 屏幕上**一枚可点的返回箭头都没有**，只剩 `_ErrorOverlay` 里那两颗按钮。
  /// ```
  ///
  /// # ★ 这不是缺陷 2 的回归，是**同一个门控的另一半没补**
  /// ```text
  /// 当年加悬浮键时把 `_error != null` 当成「错误层自带返回」——
  /// 但错误层那颗在**中间**，用户按的是**左上角**那枚。
  /// 视觉上那枚一直在（顶栏渐隐那层没被移除，只是被 Opacity/IgnorePointer 处理），
  /// 所以用户的第一反应就是去点它 ⇒ 点不动 = 「卡死」观感。
  /// ```
  ///
  /// # 为什么判据是 `_error != null` 而不是 `!_controlsVisible`
  /// ```text
  /// 错误态下**控制条本来就是隐藏的**（`_controlsVisible` 由 _error 一起管），
  /// 所以这里只需要补「错误时也要有返回口」这一个条件；
  /// 正常播放时顶栏/悬浮键的既有分工**一个字都不改**。
  /// ```
  ///
  /// ⚠️ `!_anySheetOpen` 必须留：错误态下若还开着浮层（例如从错误浮层点进设置），
  ///    浮层自己占满交互，且它有 `_error == null` 之外的关闭路径 ⇒ 不抢它的返回。
  bool get _canUseTopBarBack =>
      Device.isDesktop && _error != null && !_anySheetOpen;

  /// 长按倍速是否启用（PC/TV 恒 false）
  /// 长按手势是否启用
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ PC 上**也必须**启用（2026-09-24 交付实测抓到的 bug）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # 我原来错在哪
  ///
  /// 直接复用了触摸端的门控：
  /// ```dart
  /// PlayerGestures.longPressEnabledFor(isTouch: _isTouchGestureTarget)
  /// ```
  /// 而那个函数是 `isTouch && longPressEnabled` —— **PC 恒 false**。
  ///
  /// 于是 PC 上长按**完全没挂载**，交付实测报：
  /// ```text
  /// ✗ PC 区域手势已挂载（长按分流）
  ///   doubleTap=false longPress=false tapUp=true visibleButtons=0
  /// ```
  ///
  /// # 为什么这是错的（用户明确要求了 PC 长按）
  ///
  /// 用户原话：
  /// > 长按是倍速,**右是快进倍速**(可配置) **左是 快退**(可配置)
  ///
  /// 这句是**针对 PC 说的**（上一句是「而且pc端更直觉的左右按钮」）。
  /// 我把"PC 不要双击快进"（正确）错误地推广成了
  /// "PC 不要任何手势"（错误）。
  ///
  /// # 正确的规则（2026-09-25 按用户要求更新）
  ///
  /// ```text
  /// 双击快进快退   PC **不要**（用户明确否决，鼠标误触）
  /// 单击           PC **不要跳秒**（用户原话：「不要单击快进快退,
  ///                去掉这个功能」）→ 整屏统一 = 播放/暂停
  /// 长按           PC **要**  （左连续快退 / 右倍速快进）
  /// ```
  /// 也就是 PC 和手机在**单击**上已经统一（都是播放/暂停），
  /// 只在**双击**上分平台。长按两边都有。
  ///
  /// ⚠️ PC 的长按**不受**触摸端那个开关控制（设置页里那个开关
  ///    只在触摸端显示）—— PC 用户没有那个开关，所以恒启用。
  ///
  /// ⚠️ 判据用**本页的** `_isPcKeyboardTarget`，不是全局的 `Device.isDesktop`
  ///    （task-15 实测抓到的 bug）。
  ///
  /// # 为什么原来那写法是错的
  ///
  /// `Device.kind` 是**进程级缓存**的，取自宿主操作系统。于是：
  /// ```text
  /// Windows 上，即使这个 PlayerPage 是按“手机”建的，
  /// Device.isDesktop 仍然是 true
  ///   ⇒ 这个 getter 恒为 true
  ///   ⇒ 手机那个「长按开关」被**完全忽略**，
  ///     用户要求的「可关闭」在那种场景下做不到
  /// ```
  /// `PlayerPage` 自己就知道它是为哪个平台建的
  ///（`isTv` / `isTouchOnly`，每个生产调用点都传了）——
  /// 用它们就不依赖全局状态，且行为可预测。
  ///
  /// ★ 对现有平台的影响：
  /// ```text
  /// 桌面  → true（不变，鼠标半屏长按仍然可用）
  /// 手机  → 读 `longPressEnabled`（变对了：之前被全局值遮蔽）
  /// TV    → false（不变：遥控器没有触摸手势）
  /// ```
  bool get _longPressEnabledForThisDevice => _isPcKeyboardTarget
      ? true
      : PlayerGestures.longPressEnabledFor(isTouch: _isTouchGestureTarget);

  // ═══════════════════════════════════════════════════════════════════
  //  左/右手势区域的长按行为（2026-09-24 用户要求）
  // ═══════════════════════════════════════════════════════════════════

  /// 连续快退的定时器（左半屏长按期间反复 seek）
  Timer? _rewindTimer;

  /// 长按倍速播放时的倍速（右半屏长按）
  ///
  /// ⚠️ 存**快照**而不是恢复成固定值 —— 用户可能自己设了 1.5x，
  ///    快进完应该回到 1.5x 而不是 1.0x。
  double? _rateBeforeHold;

  /// 右半屏 / 右方向键**长按** → 倍速播放
  ///
  /// ★ 保留零参数签名：鼠标半屏长按走这个入口（读 PC 配置），
  ///   `test/player_gestures_test.dart` 也钉了这个签名字面量。
  ///   键盘方向键用 `_beginRateHold(pcArrowHoldRate)` ——
  ///   两者共用同一个快照与恢复逻辑，只是倍率来源不同。
  void _startRateHold() => _beginRateHold(PlayerGestures.pcForwardRate);

  /// 倍速长按的共用实现（倍率由调用方决定）
  void _beginRateHold(double rate) {
    if (_rateBeforeHold != null) return; // 已在长按中
    _rateBeforeHold = _rate;
    _requestRate(rate);
    _flash('${rate}x 快进');
    _showControls();
  }

  /// 右半屏**松手** → 恢复原倍速
  void _endRateHold() {
    final prev = _rateBeforeHold;
    if (prev == null) return;
    _rateBeforeHold = null;
    _requestRate(prev);
    _flash('${prev}x');
  }

  /// 左半屏**长按开始** → 启动连续快退
  ///
  /// # 为什么用定时器而不是"负倍速"
  ///
  /// `media_kit` 的 `setRate` 拒绝非正数（见 `_onLongPressStartAt` 的说明）。
  /// 所以用定时器反复 seek —— 视觉上就是"画面持续往回退"。
  ///
  /// ⚠️ 首次快退**立即执行**（不等一个周期）——
  ///    否则用户按下后要等 400ms 才有反应，感觉是卡了。
  void _startRewindHold() => _beginRewindHold(PlayerGestures.pcRewindStep);

  /// 连续快退的共用实现（每步秒数由调用方决定）
  void _beginRewindHold(int step) {
    if (_rewindTimer != null) return; // 已在连续快退中
    _seekBy(-step);
    _rewindTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!mounted) {
        _rewindTimer?.cancel();
        _rewindTimer = null;
        return;
      }
      _seekBy(-step);
    });
  }

  /// 左半屏**松手** → 停止连续快退
  void _endRewindHold() {
    _rewindTimer?.cancel();
    _rewindTimer = null;
  }

  /// 记录**当前正在进行的是哪种长按**（左侧快退 / 右侧倍速）
  ///
  /// ⚠️ 必须记下来！`onLongPressEnd` **不告诉你**刚才长按的是哪一侧 ——
  ///    只知道"长按结束了"。不记的话：
  ///    ```text
  ///    左侧长按（连续快退中）→ 松手 → 走了倍速恢复逻辑 → 无效操作
  ///    右侧长按（2x 快进中）→ 松手 → 走了快退停止逻辑 → **倍速卡在 2x**
  ///    ```
  _LongPressKind? _activeLongPress;

  /*
   * ═══════════════════════════════════════════════════════════════════
   *  ★ 单击分流的**墓碑**（2026-09-25 删除，用户要求）
   * ═══════════════════════════════════════════════════════════════════
   *
   * 这里原来有两样东西，现在**都没有了**：
   *
   * ```dart
   * static const _centerBandRatio = 0.08;        // ← 正中窄带比例
   * void _onPlayerTapUp(TapUpDetails d) { ... }  // ← 按 dx 判左右半屏
   * ```
   *
   * # 为什么删掉（而不是留着不用）
   *
   * 用户原话：**「不要单击快进快退,去掉这个功能」**。
   *
   * 留着 `_onPlayerTapUp` 会有两个坏处：
   * ```text
   * ① 死代码会误导后人 —— 看到有个"分流函数"会以为单击还在分流
   * ② 它读 PlayerGestures.pcSeekSeconds，删了配置项就编译不过
   *    （反过来逼着我把那个只服务单击跳秒的配置也一起清掉，这是对的）
   * ```
   *
   * ⚠️ 别把这段墓碑当成"功能还在、只是注释掉了" ——
   *    单击现在**只有**播放/暂停一种语义（见 build 里的 `onTap`）。
   *
   * # 长按的区域判断**没有**跟着删
   *
   * 长按仍要分左右（左=连续快退 / 右=倍速快进），
   * 见下面的 `_onLongPressStartAt`。用户删的是**单击**，不是左右区域。
   */

  // ── PC 键盘方向键（用户 2026-09-25）──

  /// 处理一个 PC 方向键事件（down / repeat / up）
  KeyEventResult _handlePcArrowKey(KeyEvent event) {
    final action = _pcArrow.handleKeyEvent(event);
    switch (action) {
      case PcArrowAction.none:
        /*
         * “什么都不做”也要**消费掉**这个键**。
         *
         * 因为 none 的含义是“该功能被用户关掉了”
         * （单击/长按各自的开关）。如果这里改成
         * `ignored`，事件会继续往上派发到下面那段
         * 硬编码的 ±5 秒，用户关了开关反而**还在跳秒**
         * ——“可关闭”就成了假的。
         */
        break;
      case PcArrowAction.stepSeek:
        _seekBy(_pcArrow.direction * PlayerGestures.pcArrowSeekSeconds);
      case PcArrowAction.holdStart:
        _startPcArrowHold(_pcArrow.direction);
      case PcArrowAction.holdEnd:
        _endPcArrowHold();
    }

    /*
     * 超时兜底计时器的生命周期：按下时起，松开时停。
     */
    if (event is KeyDownEvent) {
      _armPcArrowHoldTimer();
    } else if (event is KeyUpEvent) {
      _pcArrowHoldTimer?.cancel();
      _pcArrowHoldTimer = null;
    }
    return KeyEventResult.handled;
  }

  /// 起一个“按住了但没收到 repeat”的兜底计时器
  void _armPcArrowHoldTimer() {
    _pcArrowHoldTimer?.cancel();
    final dir = _pcArrow.direction;
    if (dir == 0) return; // 没按下 -> 不该有计时器
    _pcArrowHoldTimer = Timer(kPcArrowHoldDelay, () {
      _pcArrowHoldTimer = null;
      if (!mounted) return;
      if (_pcArrow.handleHoldTimeout(direction: dir) ==
          PcArrowAction.holdStart) {
        _startPcArrowHold(dir);
      }
    });
  }

  /// PC 方向键长按开始
  ///
  /// ```text
  /// 右 → 倍速快进（`pcArrowHoldRate`）
  /// 左 → **连续快退**
  /// ```
  /// 左侧为什么不是“负倍速”：`media_kit` 的 `setRate` 拒绝非正数
  /// —— 同 `_startRewindHold` 的说明，底层 mpv 能倒放但 Dart 层被拦。
  void _startPcArrowHold(int dir) {
    if (dir < 0) {
      /*
       * 每步秒数用**单击步长**（`pcArrowSeekSeconds`）。
       *
       * 为什么不另开一个“长按每步秒数”配置：用户这次只要了
       * “倍率可配”，而单击步长本身就是“一次跳多少秒”这个语义，
       * 复用它比再堆一个参数更简单。
       */
      _beginRewindHold(PlayerGestures.pcArrowSeekSeconds);
    } else {
      _beginRateHold(PlayerGestures.pcArrowHoldRate);
    }
  }

  /// PC 方向键长按结束（松开）
  void _endPcArrowHold() {
    _endRewindHold();
    _endRateHold();
  }

  /// 长按开始 —— 按**按下位置**分流左右区域
  void _onLongPressStartAt(Offset local) {
    if (_activeLongPress != null) return; // 已在长按中
    final w = MediaQuery.of(context).size.width;
    final isLeft = local.dx < w / 2;

    if (isLeft) {
      /*
       * 左半屏 → 连续快退
       *
       * ⚠️ 「倒放」物理上做不到：`media_kit` 的 `setRate` 拒绝非正数
       *    （`if (rate <= 0.0) throw ArgumentError(...)`）。
       *    底层 mpv 支持负 speed，但 Dart 层被拦掉了。
       *    所以用定时器反复 seek —— 视觉上就是"画面持续往回退"。
       *
       * ★ 每步秒数**分平台取配置**（task-15）。
       *   之前两端都读 `pcRewindStep` —— 改 PC 的值会连带
       *   改掉手机的，而用户明确要求两端不同。
       */
      _activeLongPress = _LongPressKind.rewind;
      if (_isPcKeyboardTarget) {
        _startRewindHold(); // PC：读 pcRewindStep
      } else {
        _beginRewindHold(PlayerGestures.longPressRewindStep);

        /// 手机：读自己的
      }
    } else {
      // 右半屏 → 倍速快进
      _activeLongPress = _LongPressKind.rateBoost;
      if (_isPcKeyboardTarget) {
        _startRateHold(); // PC：读 pcForwardRate
      } else {
        /*
         * 手机：读**自己的** `longPressRate`
         *
         * ★ 这正是原本的**死代码** `_startLongPressBoost`
         *   （调用点 0 处）。task-15 要求“要么接上、要么删掉并说明”——
         *   这里**接上**：它读的 `longPressRate` 恰好就是手机配置，
         *   删掉反而要另写一份等价实现。
         */
        _startLongPressBoost();
      }
    }
  }

  /// 长按结束（**停止当前正在进行的动作**，不假设是哪一侧）
  void _endAnyLongPress() {
    final kind = _activeLongPress;
    if (kind == null) return;
    _activeLongPress = null;
    switch (kind) {
      case _LongPressKind.rewind:
        _endRewindHold();
      case _LongPressKind.rateBoost:
        /*
         * ★ 两个平台的“倍速长按”用的是**不同的快照字段**
         * （PC = `_rateBeforeHold`，手机 = `_rateBeforeLongPress`）——
         * 用错的话恢复不了倍速（快照是 null，函数直接 return）。
         */
        if (_isPcKeyboardTarget) {
          _endRateHold();
        } else {
          _endLongPressBoost();
        }
    }
  }

  /// 长按前的倍速（抬起时恢复用）
  ///
  /// ⚠️ 必须**存快照**而不是"恢复成 1.0" —— 用户可能先设了 1.5x，
  ///    再长按快进，抬起后应回到 1.5x 而不是 1.0x。
  double? _rateBeforeLongPress;

  void _startLongPressBoost() {
    if (_rateBeforeLongPress != null) return; // 已在长按中，不重复
    _rateBeforeLongPress = _rate;
    final boosted = PlayerGestures.longPressRate;
    _requestRate(boosted);
    _flash('${boosted}x 快进中');
    _showControls();
  }

  void _endLongPressBoost() {
    final prev = _rateBeforeLongPress;
    if (prev == null) return; // 没在长按
    _rateBeforeLongPress = null;
    _requestRate(prev);
    _flash('${prev}x');
  }

  void _seekBy(int seconds) {
    _seekByCalls++; // ★ 只读探针（交付实测读它证明"单击不再跳秒"）
    /*
     * ⚠️ 真机实测里**这行日志一旦出现就说明单击还在跳秒**（回归）。
     *    正常的单击只应打 `togglePlay`，不应打这行。
     */
    _probeLog(
      'seekBy #$_seekByCalls  ${seconds > 0 ? '+' : ''}${seconds}s  '
      'pos=${_position.inMilliseconds / 1000.0}s',
    );
    if (_isLive) return; // 直播不能快进/跳转
    final target = _position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _duration ? _duration : target);
    _player.seek(clamped);
    _flash(seconds > 0 ? '快进 ${seconds}s' : '快退 ${-seconds}s');
    _showControls();
  }

  void _seekToPercent(int pct) {
    if (_isLive) return;
    if (_duration <= Duration.zero) return;
    final target = _duration * (pct / 100.0);
    _player.seek(target);
    _flash('跳到 $pct%');
    _showControls();
  }

  /// 音量增减 —— ★ **键盘 ↑/↓ 与滚轮共用的唯一实现**（铁律 170）
  ///
  /// [delta] 正 = 变响（↑ / 向上滚），负 = 变轻（↓ / 向下滚）。
  ///
  /// # ⚠️ 我改掉的那个**假动作**（原来的写法是个空操作）
  /// ```dart
  /// // 原代码：
  /// _player.setVolume(v);
  /// if (v > 0 && _muted) {
  ///   _player.setVolume(v);   // ← ★ 与上面**同一句**，再调一次毫无意义
  /// }
  /// ```
  /// 它看起来想"顺便取消静音"，但两件事都没做到：
  /// ```text
  /// ① `_player.setVolume(v)` 调两次 = 一次（mpv 幂等）
  /// ② `_muted` **没有被清掉** ⇒ 底栏仍是静音图标，
  ///    而声音已经出来了 ⇒ ★ 图标与事实不一致
  /// ③ 更糟的是音量监听器（`if (!_muted && v > 0)`）也不会写 `lastVolume`
  ///    ⇒ 用户下次进来还是静音 **且** 音量回到旧值
  /// ```
  /// ⇒ 现在按原版语义（`PlayerView.vue:3729`）把两件事**真正**做掉：
  ///    `v.muted = next === 0` —— 音量归零才算静音，非零即解除。
  ///
  /// ⚠️ 用 `setState` 改 `_muted` 是**必须**的：它要驱动底栏图标重建。
  void _volumeBy(double delta) {
    final v = (_volume + delta).clamp(0.0, 100.0);
    // ★ 用户发起的音量改动（白名单，见 `_lastUserVolumeAction`）
    _lastUserVolumeAction = DateTime.now();
    _sendVolume(v);
    /*
     * ★ 静音标志与音量**必须同步**（原版 `v.muted = next === 0`）：
     *   滚/按到 0 ⇒ 静音；从 0 往上 ⇒ 解除静音。
     * ⚠️ 只在**真的变了**时才 setState —— 每格滚轮都重建一次是浪费
     *   （滚轮的 deltaY 可以连续来很多次）。
     */
    final shouldMute = v <= 0;
    if (_muted != shouldMute) {
      setState(() => _muted = shouldMute);
    }
    _flash('音量 ${v.round()}%');
    _showControls();
  }

  /// ★★ task-53【#4b-④】鼠标滚轮调音量（补齐提示里承诺的「滚轮同效」）
  ///
  /// # 为什么必须补（这是"UI 在说谎"）
  /// ```text
  /// 快捷键提示里写着：`↑ ↓  音量 · M 静音 · **滚轮同效**`
  /// ★ 而全仓 `onPointerSignal` / `PointerScrollEvent` / `scrollDelta`
  ///   实测 = **0 处** ⇒ 滚轮**没有任何代码路径** ⇒ 提示是假的。
  /// ```
  /// 原版对照（`PlayerView.vue:3722-3735`，那个注释还解释了为什么必须自己写）：
  /// ```ts
  /// // 每格 5%（deltaY 常为 ±100/±120，用**符号**而不是数值，
  /// // 避免触控板过于敏感）
  /// const next = clamp(v.volume + (e.deltaY > 0 ? -0.05 : 0.05));
  /// ```
  /// ★ 我也照抄"用符号不用数值"——触控板的 deltaY 可以只有 ±1，
  ///   按数值算会变成"滚一下动 0.05%"，用户觉得滚轮坏了。
  ///
  /// # ⚠️ 为什么用 `pointerSignalResolver` 而不是直接改音量
  /// ```text
  /// `Listener.onPointerSignal` **不会**阻止事件继续派发给别人。
  /// 若树里有 Scrollable（本页的选集/设置面板里就有 ListView），
  /// 它**也会**收到这滚轮 ⇒ 变成"音量变了 + 列表也滚了"。
  /// `GestureBinding.instance.pointerSignalResolver` 的语义是
  /// "**只有一个**赢家"（第一个 register 的回调被调用，其余丢弃）
  ///   ⇒ 注册它才能表达"这个滚轮我消费了"。
  /// ```
  /// ★ 实测确认（读 Flutter 源码，不是我推断的）：
  /// ```text
  /// · flutter/src/widgets/scrollable.dart:963
  ///     GestureBinding.instance.pointerSignalResolver.register(event, _handlePointerScroll);
  ///   ⇒ Scrollable **本来就**在用它 ⇒ 我用同一个机制才谈得上"竞争"
  /// · flutter/src/gestures/pointer_signal_resolver.dart:86-92
  ///     void register(event, callback) { if (_firstRegisteredCallback != null) return; ... }
  ///   ⇒ 先注册者赢，后注册的被**丢弃**
  /// ```
  /// ⚠️ 命中顺序是"**深的先注册**"（`HitTestResult.path` 由内向外）。
  ///    本页的播放区**没有** Scrollable 祖先（实测：全文件只有
  ///    选集面板里那一处 `ListView.builder`）⇒ 正常观看时没有竞争者，
  ///    本回调必然生效。★ 而面板打开时面板里的 ListView 会先注册 ⇒
  ///    列表正常滚动、音量不动 —— 正是想要的行为。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    /*
     * ★ 浮层打开时不接管（与 `_onKey`/`_onHardwareKey` 的既有门控同源）：
     *   面板里滚列表是用户的本意，不该顺手把音量也改了。
     */
    if (_anySheetOpen) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0) return; // 纯横向滚动（触控板双指横划）不调音量
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      /*
       * ★ 打一行日志（`_flash` 只更新 UI 气泡，**不进日志**）——
       *   否则真机排障时无法区分"滚轮没到"与"到了但没生效"。
       *   本项目在 task-42 就吃过这个亏（见 `_onHardwareKey` 的入口打点说明）。
       */
      debugPrint('[PLAYER-KEY] 滚轮 ⇒ 音量 ${dy > 0 ? '-' : '+'}5（dy=$dy）');
      // ★ 向上滚（dy < 0）= 变响 —— 与"↑ 加音量"同一方向
      _volumeBy(dy > 0 ? -5 : 5);
    });
  }

  /// 静音 / 取消静音（缺陷 1 / 11 的核心修复点）
  ///
  /// # 错在哪（改之前是一行三元）
  /// ```dart
  /// _player.setVolume(_muted ? _volume : 0);
  /// ```
  /// 它把「取消静音要恢复到的音量」寄托在 `_volume` 上，而 `_volume`
  /// 在静音时**合法地等于 0**（`_volumeBy` 把它写成 0、音量监听器也回写 0）
  /// => 再点一次执行的是 `setVolume(0)` => ★ 永远没声音，
  ///    而 `_muted` 已被翻成 false => 图标「未静音」但实际全静音（UI 在说谎）。
  ///
  /// # 修法：压 0 **之前**先抓快照，恢复时只认快照
  /// ```text
  /// 静音    : _volume > 0 => _volumeBeforeMute = _volume; 然后 setVolume(0)
  /// 取消静音: 恢复目标 = _volumeBeforeMute
  ///            快照为空/为 0 => 退回偏好里的 lastVolume x 100
  ///            再为空/为 0 => 退回出厂 100
  /// ```
  /// ⚠️ **绝不下发 0** —— 那是改前那个 bug 的全部内容。
  ///
  /// ⚠️ 用快照而不是 `_volume` 的当前值：静音期间 `_volume` 会被 mpv 的
  ///    广播写成 0（见音量监听器），所以「当前值」在取消静音那一刻恒为 0，
  ///    它**不可能**是正确答案。
  void _toggleMute() {
    if (_muted) {
      /*
       * ★ 取消静音：三级瀑布求恢复目标
       *   1) 快照（用户静音前的真实音量，最准）
       *   2) 偏好里的 lastVolume（跨会话的「用户习惯音量」）
       *   3) 出厂 100（理论上到不了，纯粹兜底不让它下发 0）
       */
      var restore = _volumeBeforeMute ?? 0;
      if (restore <= 0) restore = _lastVolume * 100;
      if (restore <= 0) restore = 100;
      _volumeBeforeMute = null;
      _sendVolume(restore);
      setState(() => _muted = false);
      _flash('取消静音 ${restore.round()}%');
    } else {
      /*
       * ★ 静音：**先抓快照再压 0**（顺序不能反 —— 反了就抓不到原音量）
       *   ⚠️ `_volume > 0` 的守卫是必须的：`_volume` 已经因为
       *     「拖到 0 自动静音」而等于 0 时，把它记进快照等于把 0 当答案。
       *     这种情况下保留**旧的**快照（它才是用户真正的音量）。
       */
      if (_volume > 0) _volumeBeforeMute = _volume;
      _sendVolume(0);
      setState(() => _muted = true);
      _flash('已静音');
    }
    /*
     * ★ 静音/取消静音**不算**「用户调音量」 —— 这里**不盖** `_lastUserVolumeAction`
     *   是刻意的：取消静音恢复的那个音量，用户并没有「调」它。
     *   （旧注释把 _toggleMute 列进「三个入口」是自相矛盾的，
     *    已在 _lastUserVolumeAction 字段上方订正为「三处调用、两处盖戳」。）
     */
    _showControls();
  }

  // ══════════════════════════════════════════════════════════════════
  // ★ 探针钩子（缺陷 1 / 11 静音状态机）—— 仅测试用，不参与生产逻辑
  // ══════════════════════════════════════════════════════════════════
  //
  // 为什么需要它们：`_PlayerPageState` 是 library-private，test/ 拿不到实例；
  // 而 flutter_test 里**没有 libmpv-2.dll** => `_player` 永远建不起来
  // => 任何摸 `_player` 的路径都是 LateInitializationError。
  // 所以这里把"下发"与"状态"分开暴露：
  // ```text
  // debugPlayerToggleMute()  => 走**真实**的 _toggleMute（状态机逐字相同）
  // _probeNoAudio = true     => 让 _sendVolume 短路，只记录下发值
  // debugPlayerVolumeWrites()=> 读回真实下发序列，断言"绝不下发 0"
  // ```

  /// 探针用：记录每次 `_sendVolume` 实际下发的值（生产不读它）
  final List<double> _probeVolumeWrites = <double>[];

  /// 探针用：进入无音频模式（短路 `_sendVolume` 的真实下发）
  void debugPlayerSetNoAudioForProbe(bool v) => _probeNoAudio = v;

  /// 探针用：调一次真实的静音按钮
  void debugPlayerToggleMute() => _toggleMute();

  /// 探针用：等价于键盘/滚轮调音量
  void debugPlayerVolumeBy(double delta) => _volumeBy(delta);

  /// 探针用：等价于拖底栏音量滑杆
  void debugPlayerSetVolume(double v) {
    _lastUserVolumeAction = DateTime.now();
    final next = v.clamp(0.0, 100.0);
    if (_muted && next > 0) _volumeBeforeMute = next;
    _sendVolume(next);
  }

  /// 探针用：读回静音状态机的全部关键量
  String debugPlayerMuteState() {
    final before = _volumeBeforeMute;
    return 'muted=$_muted|volume=${_volume.toStringAsFixed(0)}'
        '|beforeMute=${before == null ? '-' : before.toStringAsFixed(0)}'
        '|lastVolume=${(_lastVolume * 100).toStringAsFixed(0)}';
  }

  /// 探针用：读回实际下发过的音量序列（'/' 分隔）
  String debugPlayerVolumeWrites() =>
      _probeVolumeWrites.map((e) => e.toStringAsFixed(0)).join('/');

  /// 探针用：清空下发记录
  void debugPlayerResetVolumeWrites() => _probeVolumeWrites.clear();

  /// 探针用：直接摆好"当前音量"（模拟用户已经调到这个值）
  void debugPlayerSeedVolume(double v) {
    _volume = v.clamp(0.0, 100.0);
    _muted = _volume <= 0;
    _volumeBeforeMute = null;
    _probeVolumeWrites.clear();
  }

  /// ★ 缺陷 13：把探针塞进去的缓冲区间直接推给 UI（不经 mpv）
  ///
  /// 为什么要这个口子：真实 mpv 只在**真播放**时才给出 demuxer-cache-*，
  /// 而探针要在**任意可控输入**下断言缓冲条的几何。
  /// 本方法走的是与生产**完全相同**的那条 `setState(_bufferedRange)`，
  /// 所以它证明的是"UI 对区间的反应"，不是"另一个实现"。
  BufferedRange? debugPlayerPushBufferForProbe(
    Duration? end, {
    Duration? start,
  }) {
    setState(() {
      _bufferedRange = end == null
          ? null
          : BufferedRange(end: end, start: start);
    });
    return _bufferedRange;
  }

  BufferedRange? debugPlayerBufferedRangeForProbe() => _bufferedRange;

  bool? debugPlayerBufferPollerRunningForProbe() => _bufferPoller?.running;

  double? debugPlayerBufferStateForProbe() => _bufferStatePercent;

  /// 缓冲条的真实几何（left|top|w|h）；没在树上返回 null
  String? debugPlayerBufferBarGeometryForProbe() {
    final ro = _bufferBarKey.currentContext?.findRenderObject();
    if (ro is! RenderBox) return null;
    final o = ro.localToGlobal(Offset.zero);
    final s = ro.size;
    return 'left=${o.dx.toStringAsFixed(1)}|top=${o.dy.toStringAsFixed(1)}'
        '|w=${s.width.toStringAsFixed(1)}|h=${s.height.toStringAsFixed(1)}';
  }

  void _rateBy(double delta) {
    final r = (_rate + delta).clamp(0.25, 4.0);
    // 保留两位小数，避免 0.30000000000000004 这种
    final rounded = (r * 100).round() / 100;
    _player.setRate(rounded);
    _flash('${rounded}x');
    _showControls();
  }

  /// 切换全屏
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★ 桌面端必须**真的让 OS 窗口全屏**（2026-09-24 修）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # 原来错在哪
  ///
  /// 原实现是：
  /// ```dart
  /// void _toggleFullscreen() {
  ///   setState(() => _fullscreen = !_fullscreen);
  ///   _flash(_fullscreen ? '全屏' : '退出全屏');
  /// }
  /// ```
  /// 只改了一个**标志位**，从不碰 OS 窗口 —— 于是：
  /// ```text
  /// · 桌面端按"全屏"：提示弹了，窗口大小纹丝不动
  /// · 桌面端按 F11：完全没有反应
  /// ```
  /// 用户实际体验就是"全屏按钮是假的"。
  ///
  /// # 为什么原版只是标志位
  ///
  /// 原版是 WebView 里的网页，用的是浏览器 Fullscreen API
  /// （`art.fullscreen = !art.fullscreen`，ArtPlayer 内部实现），
  /// 那是**页内全屏**，由 WebView 处理，HTML 元素铺满即可。
  ///
  /// Flutter 桌面没有等价物 —— 必须调 `windowManager.setFullScreen()`，
  /// 由原生端改窗口样式（去掉装饰、铺满显示器）。
  ///
  /// # 各平台
  ///
  /// ```text
  /// 桌面   windowManager.setFullScreen(true/false)
  /// 手机   竖屏播放器铺满即可（本来就是全屏窗口），保持标志位
  /// TV     同上
  /// ```
  /// ⚠️ [awaitOs] —— ★★★ task-8 ① 追加（Owner 2026-10-09 第三批）：
  ///    允许调用方只提交「标志位 + 布局」而**不串行等待 OS 回包**。
  ///
  /// # 为什么需要这个开关（而不是在外面套 unawaited）
  /// ```text
  /// 我第一版在 `_exitPlayer` 里写的是 `unawaited(_toggleFullscreen())`，
  /// 被 lead 用真机日志推翻：`setState(_fullscreen = next)` 明明在同步段执行了，
  /// 但**布局**要等下一个微任务边界 —— 而 pop 已经开始 ⇒
  /// 退全屏那一帧布局整个**排在 pop 之后** ⇒ 真机看到「窗口先退全屏、再切页」，
  /// 比原来更花（正是 :9146 那条注释要避免的）。
  /// ```
  /// ⇒ 正确做法：**保留 await 语义**（同步段 + 本帧布局都在调用方仍在 await 时完成），
  ///    只把**最后那次真 OS 往返**从等待里摘出去。
  ///
  /// # 为什么摘掉它是安全的
  /// ```text
  /// 实测：`_toggleFullscreen()` 本体 2ms，而全屏返回比非全屏多 16.6ms ——
  /// 差额全在 `await windowManager.setFullScreen(next)`（真机上=窗口管理器回包）。
  /// 而这一步之后**没有任何** setState / 布局（已通读全函数体）⇒
  /// 不等它不会让任何 UI 状态变旧。
  /// 另外 `dispose()` 里还有一条幂等兜底（`if (_fullscreen && Device.isDesktop)`）
  /// 会再发一次 `setFullScreen(false)`，即使这一次失败也能收尾。
  /// ```
  Future<void> _toggleFullscreen({bool awaitOs = true}) async {
    _fullscreenCalls++;
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    _flash(next ? '全屏' : '退出全屏');

    /*
     * ★★★ task-58：通知合并页"全屏状态变了"（`MediaSession` 的权威来源）
     *
     * # 为什么必须通知（不能只靠父节点自己读）
     *
     * `MediaPage` 是**父**节点。子节点 `setState` **不会**让父节点重建
     * ⇒ 父节点读 `isFullscreen` 得到的仍是旧值 ⇒ 详情区不收起来
     *   ⇒ ★ 真机实测就是这样：窗口全屏了（`[WINDOWFRAME#3] => fullscreen=true`）
     *     但 `MediaPage` 不知道 ⇒ **判据⑥ FAIL**。
     *
     * # 为什么"监听窗口事件"不行（我第一版的做法，真机证明失效）
     *
     * `window_manager` 只在 `WM_SIZE` + `SIZE_MAXIMIZED` 时发
     * `enter-full-screen`（`window_manager_plugin.cpp` L291-294），
     * 而对无边框窗口 `SetFullScreen` 连 `SetWindowPos` 都不调
     * （`window_manager.cpp` L591-614 的两次 `SetWindowPos` 全在
     *  `if (!is_frameless_)` 里；L592 那句会触发 `SIZE_MAXIMIZED` 的
     *  `WM_SYSCOMMAND, SC_MAXIMIZE` 被插件作者**注释掉了**）
     * ⇒ 那个事件在本项目里**结构性不可能触发**。
     *
     * ⇒ 而 `_fullscreen` 是"用户按了全屏键"的直接结果 ⇒ **它就是权威**。
     *
     * ⚠️ 放在 `setState` **之后**：让合并页重建时读到的 `isFullscreen`
     *    已经是新值（否则它读到的还是旧值，白重建一次）。
     * ⚠️ 用 `?.call` —— 回调可能为 null（独立页面用法，没有合并页）。
     */
    _onFullscreenChanged?.call(next);

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 全屏时收起顶部操作条（2026-09-24 用户第三次纠正）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 全屏的时候不能显示哪个顶部的操作条啊
     *
     * # 这两条需求并不冲突，我一开始没分清
     *
     * ```text
     * 窗口模式（播放页）→ 必须**有**操作条：它是唯一的窗口拖动区
     * 全屏模式           → 必须**无**操作条：否则画面被切掉一条，
     *                       而且全屏下没有"拖窗口"这回事
     * ```
     * 我上一轮只做对了前半句（把播放页的隐藏去掉），
     * 结果全屏时那条栏还挂在画面上 —— 用户看到的就是
     * 「已经全屏了，顶上还占着 40px 一条黑边 + 源影 logo」。
     *
     * # 为什么全屏时不会有"拖不动"的问题
     *
     * 全屏下窗口铺满显示器，**没有拖动需求**：
     * ```text
     * · 没有标题栏要拖（用户不会再想移动一个盖满屏幕的窗口）
     * · 退出全屏有两条路：再按 F / Esc（Esc 语义已单独处理）
     * ```
     * 所以收起是安全的，不会重现"拖不动"的困境。
     *
     * ⚠️ **退出全屏时必须恢复** —— 否则回到窗口模式后又拖不动了，
     *    那就是把上一轮修好的 bug 又放回来。
     */
    titleBarVisible.value = !next;

    if (!Device.isDesktop) return; // 移动端没有"窗口全屏"概念

    try {
      if (awaitOs) {
        await windowManager.setFullScreen(next);
      } else {
        /*
         * ★ 只**发出**不等待：调用方（_exitPlayer）要的是
         *   「退全屏的请求已发出 + 标志位/布局已更新」，不是「OS 已回包」。
         * ⚠️ 用 unawaited 包住，避免 lint 与「未处理 Future」。
         * ⚠️ 失败仍然吞掉（与 await 分支同一语义）—— 不该因此让播放中断。
         */
        unawaited(windowManager.setFullScreen(next).catchError((Object _) {}));
      }
    } catch (_) {
      // 插件不可用（极端情况）—— 不该因此让播放中断
    }
  }

  void _toggleHints() {
    setState(() => _hintsOpen = !_hintsOpen);
  }

  void _showControls() {
    /*
     * ★★★ task-72【④】值没变就**不要** setState
     *
     * # 改前
     * ```dart
     * if (mounted) setState(() => _controlsVisible = true);   // 无条件
     * ```
     * 而 `_controlsVisible` 的初值**就是** true（`player_page.dart:487`）
     * ⇒ 绝大多数 hover 都在"值没变"的情况下白重建一次整页。
     *
     * # 实测读数（`.probe/probe_tests/t72_jank_probe_test.dart`）
     * ```text
     * PA   60 次鼠标移动（每次 2px）⇒ PlayerPage 重建 **60** 次
     *      元素重建 9960 次（平均每次移动 166 个元素）
     * PA2  30 次**同坐标** hover   ⇒ 重建 **30** 次
     * ```
     * ★ 触发源是 `MouseRegion(onHover: ...)` 包着**整页**
     *   （`player_page.dart:6323-6325`）—— Windows 上鼠标移动
     *   每秒可达数百次，每次都是一次 884 行的 `build`
     *   （`player_page.dart:6280-7163`）。
     *
     * # 为什么保留下面的 `_hideTimer` 重排
     * 鼠标一动就"续命 3 秒"是**正确行为**（用户还在操作就别隐藏），
     * 它只是分配一个 Timer，**不触发重建** ⇒ 不是本次卡顿的主因，
     * 但删了会让控制条在鼠标移动中意外消失。
     */
    if (mounted && !_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    // ★ 2026-10-08（Owner 第 9 条）：值翻转之后**同帧**同步动画目标态
    _applyControlsMotion();
    _armHideTimer();
  }

  /// 重新装载「N 秒后自动隐藏控制条」的计时器（★ 2026-10-08 Owner 第 9 条）
  ///
  /// # 为什么要从 _showControls() 里抽出来
  /// ```text
  /// 改前它**只**在 _showControls() 内装载，而 _showControls() 的触发源
  /// 只有「鼠标 hover」与「点击/按键」——
  /// ⇒ 用户把鼠标**停着不动**、也不点任何东西时，计时器**从没被装载过**
  ///   （_hideTimer == null），控制条于是**永远显示**
  ///   —— 这正是 Owner 报的「播放器的控件不会主动消失,一直在显示」。
  /// ⇒ 抽成独立函数之后，**起播成功**（_onPlaybackReady）与
  ///   **动画收尾**（didUpdateWidget）也能把它装上。
  /// ```
  ///
  /// ⚠️ 隐藏**只翻转 _controlsVisible**，真正的淡出由 _applyControlsMotion()
  ///    在 didUpdateWidget 里驱动 —— 与「显示」完全同一条路
  ///    （Owner 原话：「这里处理是一样的」）。
  void _armHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), _autoHideNow);
  }

  /// 「停手 3 秒」到点时**真正**要做的事（★ 2026-10-08 Owner 追加）
  ///
  /// # 为什么从 _armHideTimer 里抽出来
  /// ```text
  /// 抽出来之后**生产**（Timer 回调）与**探针**
  /// （debugAutoHideControlsForProbe）调的是**同一个方法** ⇒
  /// 测试验的就是生产路径，而不是测试自己又写了一遍判据。
  /// 这也是本仓探针的一贯纪律（见 debugPlayerInjectStreamErrorForProbe
  /// 的「逐字复刻」说明）。
  /// ```
  ///
  /// 判据（三条，缺一不可）：
  /// ```text
  /// _playing    播放中才自动隐藏（暂停时留着，方便操作）
  /// !_hintsOpen 快捷键面板开着时不收（用户正在读）
  /// !_zoomOpen  ★ task-22 P1-5：缩放滑条开着时不收（否则拖到一半条就没了）
  /// ```
  void _autoHideNow() {
    if (mounted && _playing && !_hintsOpen && !_zoomOpen) {
      setState(() => _controlsVisible = false);
      /*
         * ★★★ 2026-10-08（Owner 追加：顶栏要与底栏**联动**一起消失）
         *
         * # 改前这里**没有**这一行 —— 这正是「顶栏一直不消失」的根因之一
         * ```text
         * `_applyControlsMotion()` 原来**只**在 `_showControls()` 里被调，
         * 而它做的是「把 _controlsVisible 的目标态写进 _controlsAnim」。
         * ⇒ 隐藏路径上没人调它 ⇒ `_controlsFade.value` 恒 = 1.0
         *   ⇒ 顶栏那条渐变条**永远画在最亮**（Opacity 1.0），
         *     连 `visible: false` 都救不回来（它只挡指针、不改透明度）。
         * ```
         *
         * ⚠️ 必须放在 `setState` **之后**：`_applyControlsMotion()` 读的是
         *    `_controlsVisible` 的**当前值**，写在前面会读到旧值 ⇒ 反向。
         */
      _applyControlsMotion();
    }
  }

  /// ★ 缺陷 9 探针入口（见文件末尾的顶层转发器）
  void debugPlayerFlashForProbe(String msg) => _flash(msg);

  void _flash(String msg) {
    if (!mounted) return;
    setState(() => _tip = msg);
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted && _tip == msg) setState(() => _tip = null);
    });
  }

  /// 弹幕失败角标自动消失的时间（毫秒）
  ///
  /// 为什么是 8 秒：够用户看清「弹幕失败：…」+ 那半句中文说明（约 40 字），
  /// 又不至于在画面正中糊太久。见 `_danmakuBadge` 的说明。
  static const int kDanmakuBadgeFailMs = 8000;

  /// 失败发生的时刻（null = 没有失败）。用来给角标算"还要显示多久"。
  DateTime? _danmakuErrorAt;

  /// 让角标到点自己消失的定时器
  ///
  /// ⚠️ **必须**有这个定时器：`_danmakuBadge` 是 getter，它算得出
  ///    "已经超时了"，但**没人重建**的话屏幕上那层永远不会消失。
  ///    （这是"改了 getter 忘了触发重建"的经典坑。）
  Timer? _danmakuBadgeTimer;

  /// 失败后安排一次"到点隐藏角标"
  void _armDanmakuBadgeExpiry() {
    _danmakuBadgeTimer?.cancel();
    _danmakuBadgeTimer = Timer(
      const Duration(milliseconds: kDanmakuBadgeFailMs),
      () {
        if (!mounted) return;
        setState(() {});
      },
    );
  }

  String? _tip;

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 画中画（P 键）
  // ═══════════════════════════════════════════════════════════════════

  void _initPip() {
    /*
     * ⚠️ 必须 await 探测才知道支不支持
     *
     * Android 要问系统 API 版本（PiP 需要 API 26+），
     * 桌面要确认 window_manager 可用。
     *
     * 探测结果决定**按钮显不显示** —— 不支持时干脆不显示，
     * 比显示了但点了没反应好（后者让用户以为"按坏了"）。
     */
    PipController.instance.probe().then((ok) {
      if (mounted) setState(() => _pipSupported = ok);
    });
    // 状态变化要同步到 UI（用户点小窗的 X 时原生会通知）
    PipController.instance.addListener(_onPipChanged);
  }

  void _onPipChanged(bool active) {
    if (mounted) setState(() => _pipActive = active);
  }

  Future<void> _togglePip() async {
    if (!_pipSupported) return;
    /*
     * 传**视频真实宽高比** —— Android 的小窗比例按它算。
     *
     * 拿不到就退回 16:9（`_videoAspect` 的默认值）。
     */
    final ok = await PipController.instance.toggle(aspectRatio: _videoAspect);
    if (!ok && mounted) {
      _flash('本平台不支持画中画');
    }
  }

  /// 视频宽高比（拿不到时按 16:9）
  double get _videoAspect {
    final w = _player.state.width;
    final h = _player.state.height;
    if (w == null || h == null || w <= 0 || h <= 0) return 16 / 9;
    final r = w / h;
    // 夹到 Android 允许的范围（1:2.39 ~ 2.39:1），否则原生会抛异常
    return r.clamp(1.0 / 2.39, 2.39);
  }

  /// 视频**真实**宽高比；拿不到时返回 `null`（task-28 ②）
  ///
  /// # 与 [_videoAspect] 的区别（**这个区别很重要**）
  ///
  /// ```text
  /// _videoAspect   拿不到时**兜底 16:9**，且夹到 [1/2.39, 2.39]
  ///                ← 给 Android 画中画用的（原生要求这个范围，
  ///                  越界会抛异常，所以必须兜底 + 夹取）
  ///
  /// _displayAspect 拿不到时返回 **null**，且**不夹取**
  ///                ← 给"画视频区描边"用的（见 ② 的实现）
  /// ```
  ///
  /// # 为什么描边**不能**复用 `_videoAspect`
  ///
  /// ```text
  /// ① 兜底 16:9 会在**起播前**画一个框 —— 而那时还没有画面，
  ///    框是凭空出现的，用户会以为"界面坏了"。返回 null ⇒ 不画。
  /// ② 夹取到 2.39 会让 **21:9 以上的片源**描边比画面窄
  ///    （真实比例 2.6 被夹成 2.39）⇒ 框压在画面上，那是**错误信息**。
  /// ```
  /// 描边必须与 `BoxFit.contain` 的几何**逐像素一致**，
  /// 所以这里要的是"真实值，没有就不知道"。
  double? get _displayAspect {
    final w = _player.state.width;
    final h = _player.state.height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return w / h;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  键盘 / 遥控器
  // ═══════════════════════════════════════════════════════════════════

  /// ★ early handler 的适配层（task-42）
  ///
  /// # 为什么要单独一个函数（而不是把 `_onHardwareKey` 的返回类型改掉）
  /// ```text
  /// `FocusManager.addEarlyKeyEventHandler` 要求返回 **`KeyEventResult`**，
  /// 而 `_onHardwareKey` 的判定逻辑是"bool：我处理了吗"。
  /// ★ 单独做**类型转换**（照 shell.dart L2083 的做法）⇒
  ///   判定逻辑一字不动，只是包一层 —— 改返回类型会牵动整个函数体。
  /// ```
  /// ```text
  /// true  -> KeyEventResult.handled   （★ 会**中止**焦点树派发）
  /// false -> KeyEventResult.ignored   （继续正常派发）
  /// ```
  KeyEventResult _onEarlyKey(KeyEvent event) =>
      _onHardwareKey(event) ? KeyEventResult.handled : KeyEventResult.ignored;

  /// ★★★ 硬件层键盘兜底（task-42）
  ///
  /// 详细推导见 `initState` 里注册处的长注释。
  ///
  /// # 它和 `Focus(onKeyEvent: _onKey)` 的分工（**必须说清**）
  /// ```text
  /// `_onKey`（焦点路径）  ：焦点在本页时，**所有**键位照旧由它处理
  ///                         （方向键/音量/J/K/L/M/F/P/N/逗号句号…）
  /// 本 handler（硬件路径）：只在 `_onKey` **收不到**时兜底
  ///                         —— 即焦点被上一页抢走的情况
  /// ```
  /// ⚠️ 因此这里**只处理用户点名的那两个键**（空格 / Enter），
  ///    而不是把 `_onKey` 整个复制一份 ——
  ///    复制会造成"两条路径语义漂移"（改一处忘另一处）。
  ///    ★ 用户没点名的键（J/L/M/F…）保持原样：焦点正常时可用；
  ///      焦点异常时**不兜底**（避免扩大改动面，也避免与 `_onKey` 双触发）。
  ///
  /// # ⚠️ 双触发风险（必须防）
  /// ```text
  /// 若焦点**正常**在本页：`_onKey` 会处理空格/Enter。
  /// ★ 而本 handler 在焦点树**之前**跑 ⇒ 若我也处理，就会**跑两次**
  ///   （空格 ⇒ 暂停又播放 = 看起来没反应；Enter ⇒ 全屏又退出 = 同样没反应）
  /// ⇒ ★ 解决办法：见 `_focusIsInsideThisPage`。
  /// ```
  bool _onHardwareKey(KeyEvent event) {
    /*
     * ★ 无条件入口打点（与直播页 `_onHardwareKey` 同款）
     *
     * # 为什么必须有（真机排障的关键）
     * ```text
     * 我原来只在"真的处理了"时打日志 ⇒ 无法区分：
     *   · handler **压根没被调用**（注册/机制问题）
     *   · 被调用了但**门控挡掉**（浮层/路由/焦点已在页内）
     * ⇒ 加这一行，一眼分辨。
     * ★ 直播页就是靠这行定位到"键进了 Flutter 但被可见性门控挡住"的。
     * ```
     */
    if (event is KeyDownEvent) {
      debugPrint(
        '[PLAYER-KEY] ⓪ 入口：硬件 handler 收到 '
        '${event.logicalKey.keyLabel}（浮层=$_anySheetOpen '
        '最上层=${ModalRoute.of(context)?.isCurrent}）',
      );
    }
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;

    /*
     * ── 门控 ①：有浮层打开时不接管 ──
     *
     * 浮层（选集/设置/线路/提示）里的焦点自己会处理键 ——
     * 我抢过来会把"面板里 Enter 选条目"变成"全屏"（正是 L4086 修过的 bug）。
     */
    if (_anySheetOpen) return false;

    /*
     * ── 门控 ②：本页必须是**最上层路由** ──
     *
     * ★ 这条同时解决两个问题：
     *   ① 本页被别的路由盖住时不该收键
     *   ② **与直播页的 handler 抢键** —— 直播页被本页 push 覆盖后
     *      `isCurrent == false` ⇒ 它自己让路（它也有同样的门控）
     */
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;

    /*
     * ── 门控 ③：输入框里打字时放行 ──
     */
    final f = FocusManager.instance.primaryFocus;
    if (f?.context != null) {
      var typing = false;
      f!.context!.visitAncestorElements((el) {
        if (el.widget.runtimeType.toString() == 'EditableText') {
          typing = true;
          return false;
        }
        return true;
      });
      if (typing) return false;
    }

    /*
     * ── ★ 防双触发：焦点已在本页 ⇒ 让 `_onKey` 处理 ──
     */
    if (_focusIsInsideThisPage(f)) return false;

    final k = event.logicalKey;
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 直播 ↑/↓ 切台（**焦点不在本页**时的兜底）—— task-53【#4b】
     * ══════════════════════════════════════════════════════════════════
     *
     * # ★ 为什么必须在这里也做一遍（lead 真机实测抓到的**真** bug）
     * ```text
     * lead 的实测（同一个 app.so，同一页面，全屏直播播放中按 ↓）：
     *   [LIVE-KEY]   ⓪ 入口：硬件 handler 收到 Arrow Down（可见=true）
     *   [PLAYER-KEY] ⓪ 入口：硬件 handler 收到 Arrow Down（浮层=false 最上层=true）
     *   ★★ **没有** `[PLAYER-KEY] ⓪ 入口：收到 Arrow Down`   ← ★ 关键缺失
     *   ★★ **没有** `直播 ↓ ⇒ 下一个台`
     * ⇒ ★ 键**到了硬件 handler**，但**没到 `_onKey`**（焦点路径）。
     * ```
     *
     * 我自己的实测（**同一个二进制、同一个页面**，只差一步）：
     * ```text
     *   ① 直播页 → 点播放器右上角全屏按钮 → 按 ↓   ⇒ **不切台**（复现 lead）
     *   ② 再点一下画面 → 按 ↓                     ⇒ **切台** ✓
     * ⇒ ★★★ 根因 = **焦点不在本页** ⇒ `_onKey` 收不到。
     *   进全屏后焦点仍留在**直播页**（是它 push 的播放页），
     *   用户不点画面就没有任何东西把焦点搬进播放页。
     * ```
     *
     * # ★ 为什么不是"shell.dart 没接线"
     * ```text
     * lead 判据是"6 处 `PlayerPage(` 都没传 `onLiveChannelStep`"。
     * ★ 但 `onLiveChannelStep` 在 L3199，而它所属的 `PlayerPage(` 在 **L3163** ——
     *   中间隔了 **31 行注释**（我写的分工说明）⇒ 只扫"紧邻十来行"会**漏判**。
     * ★ 反证（同一二进制上取的读数）：
     *   `[LIVE-KEY] 全屏切台 ⇒ CCTV+ 2：本页只改选中，起播交给播放页`
     *   ★ 这行**只能**由 `stepChannelForFullscreen` 产生，
     *     而它**只能**经 shell 传的 `onLiveChannelStep` 到达
     *   ⇒ 接线存在，且真的跑过。
     * ```
     *
     * # 为什么这样修（而不是去"抢焦点"）
     * ```text
     * ★ `_onKey` 那侧的 `_isLive && onLiveChannelStep != null` 判断**完全正确**，
     *   一个字节都不用改 —— 缺的只是"焦点异常时也能到"的**第二条路**。
     * ★ 本函数（`addEarlyKeyEventHandler`）**先于焦点树**收到键 ⇒ 天然覆盖这条。
     * ★ 而 Esc 在下面（`k == escape && _fullscreen`）就是这么修的 ——
     *   同一根因，注释逐字在案：
     *     「本兜底路径下焦点不在本页 ⇒ `_onKey` 收不到 ⇒ Esc 失效」
     *   ⇒ 本处**沿用同一条既有纪律**，不发明新机制。
     * ```
     *
     * # ★ 为什么不会双触发（关键）
     * ```text
     * 上面 `if (_focusIsInsideThisPage(f)) return false;` 已经把
     * "焦点在本页"的情况**让给 `_onKey`** ⇒ 两条路**互斥**，
     * 一次按键只切一个台。
     * ★ 真机实测已证：点画面后按 ↓ 只出现**一行** `直播 ↓`（不是两行）。
     * ```
     *
     * ⚠️ 只做**直播**，不做音量 —— 非直播时 ↑/↓ 仍是音量（已验收，不动）。
     *    焦点不在页内时音量本来就不响应，那是既有行为，不属本任务范围。
     */
    if (_isLive && widget.onLiveChannelStep != null) {
      if (k == LogicalKeyboardKey.arrowUp) {
        debugPrint('[PLAYER-KEY] ⓪ 硬件兜底：直播 ↑ ⇒ 上一个台');
        unawaited(_switchLiveChannel(-1));
        return true;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        debugPrint('[PLAYER-KEY] ⓪ 硬件兜底：直播 ↓ ⇒ 下一个台');
        unawaited(_switchLiveChannel(1));
        return true;
      }
    }
    if (k == LogicalKeyboardKey.space) {
      debugPrint('[PLAYER-KEY] ⓪ 硬件兜底：空格 ⇒ 播放/暂停');
      _togglePlay();
      return true;
    }
    if (k == LogicalKeyboardKey.enter) {
      /*
       * ★ 桌面 = 全屏；TV = 播放/暂停（与 `_onKey` 的分流**保持一致**）
       *
       * ⚠️ 两处必须同规则 —— 否则"焦点正常/异常"两种情况下 Enter 语义不同，
       *    用户会觉得"时好时坏"（这正是最难查的那类 bug）。
       */
      if (!widget.isTv) {
        debugPrint('[PLAYER-KEY] ⓪ 硬件兜底：Enter ⇒ 切换全屏');
        unawaited(_toggleFullscreen());
      } else {
        debugPrint('[PLAYER-KEY] ⓪ 硬件兜底：Enter(TV) ⇒ 播放/暂停');
        _togglePlay();
      }
      return true;
    }
    /*
     * ★ Esc 兜底（只在全屏时）—— 防止"焦点在页外时被困在全屏"
     *
     * # 为什么需要
     * ```text
     * 真机实测（`.probe/t42_player_final.txt`）：
     *   Enter ⇒ 1280x800 → **2560x1440**（进全屏）✓
     *   双击  ⇒ 2560x1440 → **1280x800**（退全屏）✓
     *   ★ Esc ⇒ 被入口日志记到了，但**没有退出全屏**
     * ```
     * 原因：Esc 的退出全屏逻辑在 `_onKey` 里（焦点路径），
     * 而本兜底路径下焦点**不在本页** ⇒ `_onKey` 收不到 ⇒ Esc 失效。
     * ⇒ 用户若在焦点异常时进了全屏，Esc 这个**通用逃生口**就没了。
     *
     * # 为什么只处理"全屏"这一种情况
     * ```text
     * `_onKey` 里 Esc 是一串级联（提示 → 设置 → 选集 → 线路 → 全屏 → 退出播放页）。
     * ★ 但本兜底**已经**在开头 `if (_anySheetOpen) return false;` 挡掉了前四种
     * ⇒ 剩下的只有"全屏"和"退出播放页"。
     * ⚠️ 我**只做全屏**，不做"退出播放页" ——
     *   因为那等于让一个收不到焦点事件的页面也能被 Esc 关掉，
     *   风险更大（用户可能只是焦点没落上，却把播放页关了）。
     *   退出播放页仍有 UI 按钮 + 焦点正常时的 Esc。
     * ```
     */
    if (k == LogicalKeyboardKey.escape && _fullscreen) {
      debugPrint('[PLAYER-KEY] ⓪ 硬件兜底：Esc ⇒ 退出全屏');
      unawaited(_toggleFullscreen());
      return true;
    }
    return false;
  }

  /// 焦点是否已经在本页的 Focus 子树里（判断 `_onKey` 会不会自己处理）
  ///
  /// # 为什么要这个
  /// ```text
  /// 本 handler 跑在 `_onKey` **之前**。若焦点本来就在本页，
  /// `_onKey` 会处理空格/Enter ⇒ 我若也处理 = **跑两次**：
  ///   空格 ⇒ 暂停又播放 ⇒ 用户看到"没反应"
  ///   Enter ⇒ 全屏又退出 ⇒ 同样"没反应"
  /// ★ 这是**加了兜底之后才会出现的新 bug**，必须防。
  /// ```
  ///
  /// # 判据：走**焦点树**，不走元素树
  /// ```text
  /// `FocusNode.ancestors` 是 Flutter 给的焦点树祖先链 ——
  /// 用它判断"primaryFocus 是不是我（或我的后代）"最直接。
  ///
  /// ⚠️ 我第一版想用 `visitAncestorElements` 从焦点往上找 build 出来的锚点，
  ///    那是**错的**：`Focus` widget 是 `GestureDetector` 的**祖先**，
  ///    从焦点往上走永远遇不到在它**下面**的锚点。
  ///    ⇒ 走焦点树（`ancestors`）才对，而且要比较**焦点节点**而不是元素。
  /// ```
  bool _focusIsInsideThisPage(FocusNode? f) {
    if (f == null) return false;
    if (identical(f, _pageFocusNode)) return true;
    // ★ `ancestors` 是惰性 Iterable —— 用 `any` 短路，别展开整个链
    return f.ancestors.any((a) => identical(a, _pageFocusNode));
  }

  /// 处理按键
  ///
  /// # ★ 桌面与 TV 是**两套**键位
  ///
  /// ```text
  /// 桌面：← → 是 5 秒；有 J/L/数字/F/P/逗号句号/N
  /// TV：  ← → 是 10 秒；只有方向键 + 确认 + 返回
  /// ```
  /// 原版注释强调过 TV 上列键盘键位"对遥控用户毫无意义"。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    /*
     * ★ 三层诊断的第①层：入口（task-42，照直播页的做法）
     *
     * # 为什么播放页也需要
     * ```text
     * 用户报「要支持空格暂停/播放」—— 但代码里**早就有**空格处理（L4211 附近）。
     * ⇒ 那说明"有代码"不等于"按了有反应"。
     * ★ 最可能的是**焦点问题**（我刚好在直播页证明了同一个根因：
     *   焦点在底栏 tab 上时，播放页的 Focus 同样收不到键）。
     * ⇒ 加这一行，一眼就能区分"键没到"和"键到了但分支不对"。
     * ```
     */
    if (event is KeyDownEvent) {
      debugPrint('[PLAYER-KEY] ⓪ 入口：收到 ${event.logicalKey.keyLabel}');
    }
    /*
     * ══════════════════════════════════════════════════════════════
     * ★★★ PC 方向键：单击 = 步数控制，长按 = 快进快退
     * ══════════════════════════════════════════════════════════════
     *
     * ★ 必须放在下面那个“只接收 down/repeat”的守卫**之前**。
     *   那个守卫会直接 `ignored` 掉 `KeyUpEvent`，
     *   而“松开”正是长按结束、恢复原倍速的**唯一信号** ——
     *   放在后面的话，用户按住方向键松手后，
     *   倍速会**永远卡在 3x** 。（与鼠标长按必须用
     *   `onLongPressEnd` 而不是 `onLongPress` 同一个道理。）
     *
     * ★ 只接管 ←/→：↑/↓ 是**音量**，用户没让改（task-15 第 5 条）。
     */
    if (_isPcKeyboardTarget && PcArrowKeyRouter.isArrowKey(event.logicalKey)) {
      return _handlePcArrowKey(event);
    }

    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final k = event.logicalKey;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 选集面板打开时，方向键**归面板**（2026-09-24 TV 适配）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须在播放页这一层拦
     *
     * 播放页的 `_onKey` 把方向键定义成播放器快捷键
     * （←/→ 快进、↑/↓ 音量）。面板打开时如果不拦，
     * TV 用户按方向键**音量会变、进度会跳**，而面板里的焦点一动不动
     * —— 遥控器等于选不了集。
     *
     * # 为什么不能只靠 `spatial_nav.dart` 的全局 handler
     *
     * 那个 handler 有**页面层门控**：
     * ```dart
     * // shell.dart
     * bool _pageUsesArrowKeys() => _playerOpen;
     * if (_pageUsesArrowKeys()) return false;   // 放行给播放器
     * ```
     * 它的设计意图是"TV 上播放器需要方向键"（快进/音量），
     * 所以**在播放页里它整个让路**。于是面板里的焦点永远收不到按键。
     *
     * # 解法：面板打开时，把方向键交给面板自己的焦点树
     *
     * ```text
     * 面板没开 → 方向键照旧 = 播放器快捷键（已验收，不动）
     * 面板开着 → return ignored → 事件流到焦点树
     *            → Flutter 内建的方向遍历在网格里移焦点
     *            → Scrollable.ensureVisible 把新焦点滚进来
     * ```
     *
     * ⚠️ 返回 `ignored` 而不是自己调 `moveFocus()`：
     *    面板是**普通网格**（不是首页那种跨区块布局），
     *    Flutter 内建的 `DirectionalFocusIntent` 在合成树里是好的
     *    （`spatial_nav.dart` 的文件头记录过：
     *    「内建遍历在**合成树**里是好的（right=1 down=3）」）。
     *    自己再算一遍几何邻居反而会跟内建规则打架。
     *
     * ⚠️ 只对 TV 生效 —— 桌面/手机上方向键本来就该是播放器快捷键，
     *    而且桌面选集面板里用鼠标，不需要方向键。
     */
    if (widget.isTv && _episodeSheetOpen && _arrowKeys.contains(k)) {
      return KeyEventResult.ignored;
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-53【③】「所有直播」面板打开时，↑/↓ 归**面板**（用户第 3 条）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须有这条（不加就是"选不了台"）
     * ```text
     * 本页的 ↑/↓ 在直播时被定义成"切台"（#4b，见上面 arrowUp/arrowDown）。
     * 面板打开后若不禁用：
     *   ⇒ 用户想在列表里往下移动，结果**每按一次就换一个台**
     *     （列表还在，但当前台在背后不停变）——完全选不了。
     * ★ 与 `live_page.dart` 的 `_allChannelsOpen` 门控**同一纪律**
     *   （那里的注释逐字记录了同一个坑）。
     * ```
     *
     * ★ 返回 `ignored`（不是 `handled`）：让事件**继续往下走**给焦点树
     *   ⇒ 面板里的 `ListView` 自己处理滚动/焦点移动。
     *
     * ⚠️ **所有端**都要放行（不只是 TV）——
     *    桌面上用户同样会用 ↑/↓ 或滚轮在列表里找台；
     *    而选集面板那条只对 TV 生效是因为"桌面选集用鼠标"，
     *    这里不同：直播列表在桌面也是要**上下翻**的。
     */
    if (_liveChannelsOpen && _arrowKeys.contains(k)) {
      return KeyEventResult.ignored;
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 选集面板打开时，**确认键也必须让给面板**（2026-09-24 修的真 bug）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 症状（只做上面那条"方向键放行"是不够的）
     *
     * ```text
     * TV 用户：点「选集」→ 面板打开 → 按方向键，焦点环**正常移动** ✓
     *         → 按 OK（确认）想选这一集
     *         → ★ 播放器**暂停/播放**了一下，集没选上 ✗
     * ```
     * 也就是「看得见、走得动、**选不了**」——
     * 与 `spatial_nav.dart` 文件头记录的那个假象完全同类：
     * **能移动焦点 ≠ 能选片**。
     *
     * # 根因
     *
     * 按键派发是**从叶子往根走**的（`FocusManager` 遍历
     * `primaryFocus.ancestors`），碰到第一个 `handled` 就停：
     * ```text
     * 焦点链：  _EpisodeChip 的 InkWell/Focus
     *            → ... → 播放器根的 Focus(onKeyEvent: _onKey)   ← ★ 在这里
     * ```
     * 播放页那个 `Focus` 的 `_onKey` 把 `enter/select` 定义成
     * **播放/暂停**（那是原版 ArtPlayer 的键位，桌面/TV 共用），
     * 而它在链上是**格子的祖先** ——
     * 于是 `_togglePlay()` 先返回 `handled`，
     * `ActivateIntent` **永远走不到** `InkWell` 的 `onTap`。
     *
     * # 为什么这才算"与原版一致"
     *
     * 原版的选集格是 DOM `<button>`：TV 上焦点落在按钮里按 Enter，
     * 浏览器直接 `click()` —— **按钮优先**，ArtPlayer 的 hotkey
     * 收不到（原版注释也强调过 hotkey 有 `art.isFocus` 前置条件）。
     * 所以「面板打开时确认键归面板」才是原版行为，不改反而是差异。
     *
     * # 只放行确认键，不放行别的
     *
     * ```text
     * 面板开着 + enter/select/媒体播放键 → ignored（让 InkWell 激活）
     * 面板关着                          → 照旧 _togglePlay()（已验收，不动）
     * 桌面 / 手机                       → 不受影响（只在 isTv 分支里）
     * ```
     */
    if (widget.isTv &&
        _episodeSheetOpen &&
        (k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.gameButtonA)) {
      return KeyEventResult.ignored;
    }

    /*
     * ★★★ task-53【③】「所有直播」面板打开时，**确认键也让给面板**
     *
     * ⚠️ 单独一块，**不合并**进上面那条 —— 理由：
     * ```text
     * `test/episode_strip_test.dart:671` 用正则钉住选集那条的形状：
     *     r'_episodeSheetOpen\s*&&\s*\(?\s*k\s*==\s*LogicalKeyboardKey\.enter'
     * ★ 我第一版把两者合并成 `(_episodeSheetOpen || _liveChannelsOpen) && (k == ...)`
     *   ⇒ 正则**不再匹配** ⇒ 那条既有测试变红（我实测撞到了）。
     * ★ 而那条测试守的是**选集面板**（已验收的 TV 行为），
     *   它有权要求那行**逐字不变** —— 合并等于为了我的新功能
     *   去改一个与它无关的既有契约（铁律 170 的反面）。
     * ⇒ 拆成两块：各自的判据各自成行，互不干扰。
     * ```
     *
     * ★ 语义与上面**完全一致**（TV + 面板开着 ⇒ 确认键归面板），
     *   只是判据从"选集面板"换成"所有直播面板"。
     */
    if (widget.isTv &&
        _liveChannelsOpen &&
        (k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.gameButtonA)) {
      return KeyEventResult.ignored;
    }

    // ── 两套共有的：方向键 ──
    if (k == LogicalKeyboardKey.arrowLeft) {
      _seekBy(widget.isTv ? -10 : -5);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _seekBy(widget.isTv ? 10 : 5);
      return KeyEventResult.handled;
    }
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-53【#4b】直播时 ↑/↓ = **切频道**（不再调音量）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话（第 4 条，**第二次强调**）：
     * ```text
     * > 而且直播进入全屏还是没办法像选集一样切换直播,而且我说的切换,是指的,
     * > 直播进入全屏播放的状态下,然后可以上下切换,然后还可以切换直播
     * > **不是指 在直播页面(未进入全屏)加一个所有直播的按钮进行切换的**
     * ```
     * ⇒ 关键在"**进入全屏播放的状态下**"—— 用户要的是**在播放页里**按 ↑/↓
     *   直接换台，不需要先点任何按钮/打开任何列表。
     *
     * # 为什么改在这里（而不是 `_onHardwareKey` 兜底里）
     * ```text
     * 实测（lead 真机注入按键，日志逐字）：
     *   [PLAYER-KEY] ⓪ 入口：硬件 handler 收到 Arrow Up
     *   [PLAYER-KEY] ⓪ 入口：收到 Arrow Up          ← ★ `_onKey` 也跑了
     * ⇒ 键**确实到了**，只是被下面这两行当成"调音量"了。
     * ★ 而 `_onHardwareKey` 只覆盖 space/enter/escape（**没有** ↑/↓）
     *   ⇒ 改这里**不会**双触发（一次按键只切一个台）。
     * ```
     *
     * # ★ 方向必须与 `live_page.dart` 逐字一致
     * ```text
     * live_page.dart:450-457（既有、已验收）
     *   arrowDown ⇒ cycleChannel(+1)
     *   arrowUp   ⇒ cycleChannel(-1)
     * ⇒ 这里同向。两页方向相反 = "按上却往下走"，是最难查的那类 bug。
     * ```
     *
     * ⚠️ **判据是两个**（`_isLive && onLiveChannelStep != null`）——
     *    缺任一个都退回音量：
     *    · 非直播（点播/回看）⇒ ↑/↓ 仍是音量（已验收，一个字节都不动）
     *    · 直播但没接线（测试/其它调用点）⇒ 同样退回音量，
     *      而不是让按键**静默失效**（那比"调成音量"更糟：用户以为键盘坏了）
     */
    if (k == LogicalKeyboardKey.arrowUp) {
      if (_isLive && widget.onLiveChannelStep != null) {
        debugPrint('[PLAYER-KEY] 直播 ↑ ⇒ 上一个台（delta=-1）');
        unawaited(_switchLiveChannel(-1));
      } else {
        _volumeBy(5);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (_isLive && widget.onLiveChannelStep != null) {
        debugPrint('[PLAYER-KEY] 直播 ↓ ⇒ 下一个台（delta=+1）');
        unawaited(_switchLiveChannel(1));
      } else {
        _volumeBy(-5);
      }
      return KeyEventResult.handled;
    }

    // ── 确认键 ──
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ Enter：桌面 = 全屏，TV = 播放/暂停（task-42，用户要求）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 然后播放页面要支持空格暂停/播放,enter 和 双击 进入/退出 全屏
     *
     * # 为什么桌面与 TV 必须分开
     * ```text
     * Enter 在 TV 上是**确认键** —— 选剧集、点按钮都要用它。
     * ★ 而上面 L4086-4135 那段（面板打开时 Enter 让给面板）正是
     *   为这件事修的 bug：TV 用户"看得见、走得动、**选不了**"。
     * ⇒ 若把 TV 的 Enter 也改成全屏，那个 bug 会**立刻复发**。
     * ⇒ 所以：**只在桌面**把 Enter 改成全屏。
     * ```
     *
     * # PC 会不会因此丢掉"Enter 播放/暂停"
     * ```text
     * 会 —— 但不损失能力：PC 还有**空格**（同一个功能，见下面 L4211 附近）。
     * ★ 而且用户明确要"enter 进入/退出全屏"，这是他点名要的键位变更。
     * ```
     *
     * ⚠️ 面板打开时**不抢** Enter（照 `_episodeSheetOpen` 的既有门控）——
     *    桌面也可能打开选集面板，那时 Enter 该激活面板里的项。
     */
    final enterLike =
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.mediaPlayPause;
    if (enterLike) {
      if (!widget.isTv && !_anySheetOpen) {
        // 桌面 + 没有浮层 ⇒ Enter = 全屏（用户要求）
        debugPrint('[PLAYER-KEY] Enter ⇒ 切换全屏');
        unawaited(_toggleFullscreen());
        return KeyEventResult.handled;
      }
      _togglePlay();
      return KeyEventResult.handled;
    }

    /*
     * ── 返回键（TV）──
     *
     * ★★★ 下面这条 `else if` 链**越长越危险**：三条既有断言都在「Esc 分支
     *    之后 **700 字符**」这个窗口里找分支（`player_capability_test.dart:986-993`
     *    找 `_settingsOpen`/`_episodeSheetOpen`；`t78_video_zoom_hwdec_test.dart:448-456`
     *    找 `_zoomOpen`），窗口装不下就会红在**别人**的测试里。
     *
     * 实测（`.probe/yamby/strip_probe.dart`，剥注释后从 Esc 行起算；
     * 2026-10-05 15:38 复测于 player_page.dart sha256 2f5a0f3c…）：
     * ```text
     * _biliSheetOpen        156      ← task-31 ④
     * _subtitlePanelOpen    239      ← task-31 ⑤
     * _danmakuSheetOpen     330
     * _settingsOpen         428      ← capability 找它
     * _zoomOpen             576      ← t78 找它
     * _episodeSheetOpen     658      ← capability + t78 找它（只剩 42 字符余量）
     * ```
     * ⇒ 加分支前先跑一次那个探针；**别在这条链里写注释**（注释也算窗口宽度）。
     */
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
      if (_hintsOpen) {
        setState(() => _hintsOpen = false);
      } else if (_biliSheetOpen) {
        setState(() => _biliSheetOpen = false);
      } else if (_subtitlePanelOpen) {
        setState(() => _subtitlePanelOpen = false);
      } else if (_danmakuSheetOpen) {
        /*
         * ★ task-13 ⑦ 弹幕设置面板 —— 它挂在设置面板**之后**
         *   （同一套 Positioned.fill 全屏 scrim）⇒ 层序更上，
         *   Esc 必须先关它。挂载顺序与这里的顺序必须一致。
         */
        setState(() => _danmakuSheetOpen = false);
      } else if (_settingsOpen) {
        /*
         * ★ 设置面板排在最前面（它是**最后打开的**那一层）
         *
         * 面板是 `Positioned.fill` 盖在所有东西之上的，所以 Esc 必须先
         * 关它 —— 否则用户看到面板还开着，窗口却退出了全屏/返回了上一页。
         * 这与播放页其它浮层（提示 / 选集 / 线路）的层级顺序一致。
         */
        // ★ 三步（改真源 / 收 portal / 叫回底栏）都在那个方法里，
        //   理由见它的注释 —— 这里只剩一行，是为了让 Esc 链**短**。
        _closeSettingsFromEsc();
      } else if (_zoomOpen) {
        /*
         * ★★★ task-22 P1-5：长按弹出的画面缩放滑条
         *
         * 层序放在设置面板**之后**：面板是 `Positioned.fill` 的全屏 scrim，
         * 滑条只是底栏上的一条 —— 两者同时开着时先收滑条才符合直觉。
         * ⚠️ 不许挪到 `_settingsOpen` 之前：`player_capability_test.dart:981`
         *    在 Esc 分支后 700 字符的窗口里找 `else if (_settingsOpen)`。
         */
        setState(() => _zoomOpen = false);
      } else if (_episodeSheetOpen) {
        setState(() => _episodeSheetOpen = false);
      } else if (_streamSheetOpen) {
        setState(() => _streamSheetOpen = false);
      } else if (_liveChannelsOpen) {
        // ★ task-53【③】「所有直播」面板也要能被 Esc 关掉
        //   （与其它浮层同层级 —— 否则用户以为 Esc 坏了）
        setState(() => _liveChannelsOpen = false);
      } else if (_popover.openId != null) {
        // ★ 悬浮小窗（倍速 / 线路 / 字幕 / 弹幕 / 更多）
        //
        // 放在**所有真浮层之后、全屏之前**：popover 只是贴在按钮旁的小卡片，
        // 它开着时 Esc 该先把它收掉，而不是直接退出全屏。
        _popover.close();
      } else if (_fullscreen) {
        /*
         * ★ 全屏时先退出全屏，**不要**直接返回（2026-09-24）
         *
         * # 为什么必须这样（否则用户会被"困住"）
         *
         * 桌面全屏后，`windowManager.setFullScreen(true)` 会去掉窗口装饰。
         * 如果 Esc 直接 pop 播放器，就变成：
         * ```text
         * 全屏 → Esc → 回到详情页，但**窗口还是全屏的**
         *          → 用户看不到标题栏、也不知道怎么退出全屏
         * ```
         * 这是所有播放器的通行约定（也是浏览器 Fullscreen API 的行为）：
         * **Esc 的语义是"退出全屏"，不是"关闭播放器"**。
         *
         * 退出全屏后再按一次 Esc 才 pop —— 与用户直觉一致。
         */
        // 不 await：_onKey 是同步的（KeyEventResult 必须同步返回）。
        // _toggleFullscreen 内部自己处理异步，这里 fire-and-forget。
        unawaited(_toggleFullscreen());
      } else {
        // ★ 走统一出口（会先退出全屏）—— 见 `_exitPlayer` 的说明
        unawaited(_exitPlayer());
      }
      return KeyEventResult.handled;
    }

    // ── 以下仅桌面 ──
    if (widget.isTv) return KeyEventResult.ignored;

    if (k == LogicalKeyboardKey.space) {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 浮层打开时，空格**必须让给浮层**（2026-09-25 修的真 bug）
       * ══════════════════════════════════════════════════════════════
       *
       * # 症状（另一代理独立验证实测，`.probe/` 里 V43h 那组）
       * ```text
       * V43h|【阳性对照】无浮层：togglePlay 增量=1（期望 1）✓
       * V43h| 找到浮层入口: 快捷键 ⇒ 点击
       * V43h| 浮层打开后：焦点树路径(_onKey)=1
       * V43h| ★★ 浮层状态（浮层=true）= true      ← ★ 前置条件成立
       * V43h| 浮层打开后 togglePlay: 2 -> 3（增量 **1**）  ← ★★ 穿透！
       * ```
       * 即：浮层开着按空格 ⇒ **后台播放器被切了**，而浮层挡着看不见
       * ⇒ 用户觉得"怎么乱了"。
       *
       * # 根因：**两条路径的语义不一致**
       * ```text
       * ① 硬件路径 `_onHardwareKey`：★ 我**自己**把 `_anySheetOpen` 做成了
       *    **全局**门控（`if (_anySheetOpen) return false;`）
       * ② 焦点树路径 `_onKey`：★ **没有**这个全局门控
       *    （只在 TV 的 `_episodeSheetOpen` 下局部判了方向键/确认键）
       *
       * ⇒ 浮层打开时：① 返回 ignored ⇒ 派发继续 ⇒ ② 跑起来 ⇒ 空格切播放器
       * ★ 也就是说：**我在硬件路径上表达过的意图，在焦点路径上没落实**。
       * ```
       *
       * # 为什么与 L4367/L4417 那两个既有门控是**同族**问题
       * ```text
       * L4367/L4417 修的是「TV 点选集 → 面板打开 → 按 OK 想选这一集
       *                  ⇒ 播放器暂停/播放了一下，集没选上」
       * ★ 那次修的是**确认键**，且**只在 TV + 选集面板**下。
       * ★ 而**空格从未被检查** —— 空格恰是 **PC 的播放/暂停主键**。
       * ⇒ 同一个根因（浮层不设防）在另一条键位/另一个平台上复发。
       * ```
       *
       * # 为什么只在**空格分支**加检查，而不是函数开头全局放行
       * ```text
       * ⚠️ 陷阱：Enter 的既有逻辑（上面 L4473）**已经在用它做分支**：
       *     `if (!widget.isTv && !_anySheetOpen) { …全屏… }`
       *   若在函数**开头**写 `if (_anySheetOpen) return ignored;`
       *   ⇒ Enter 就**永远到不了**那个分支（浮层里 Enter 再也激活不了项）
       *   ⇒ 会把 L4367 修好的东西**改坏**。
       * ⇒ 所以只加在空格分支：**改动 1 处、不碰 Enter 语义**。
       * ```
       *
       * ⚠️ 覆盖范围：`_anySheetOpen` 是**四种浮层**的并集
       *    （选集 / 设置 / 线路 / 提示）⇒ 本判断对四者**同时**生效
       *    （它们共用这一行代码）。
       */
      if (_anySheetOpen) return KeyEventResult.ignored;
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyJ) {
      _seekBy(-10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyL) {
      _seekBy(10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyM) {
      _toggleMute();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    // ★ P = 画中画（原版：`hk.add("KeyP", ...)`）
    if (k == LogicalKeyboardKey.keyP) {
      _togglePip();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyN) {
      _gotoNextEpisode();
      return KeyEventResult.handled;
    }
    // ★ task-21 P1-30：S = 截图（原版 ArtPlayer 的 `hk.add("KeyS", ...)`）
    //
    // 门控必须写在**这个分支里面**（与上面空格分支同一个理由，见那段注释）：
    // 放到函数开头做全局放行会改坏 Enter 的既有逻辑。
    if (k == LogicalKeyboardKey.keyS) {
      if (_anySheetOpen) return KeyEventResult.ignored;
      unawaited(_takeScreenshot());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.comma) {
      _rateBy(-0.25);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.period) {
      _rateBy(0.25);
      return KeyEventResult.handled;
    }

    // ── 数字键 0–9 跳百分比 ──
    final digits = <LogicalKeyboardKey, int>{
      LogicalKeyboardKey.digit0: 0,
      LogicalKeyboardKey.digit1: 10,
      LogicalKeyboardKey.digit2: 20,
      LogicalKeyboardKey.digit3: 30,
      LogicalKeyboardKey.digit4: 40,
      LogicalKeyboardKey.digit5: 50,
      LogicalKeyboardKey.digit6: 60,
      LogicalKeyboardKey.digit7: 70,
      LogicalKeyboardKey.digit8: 80,
      LogicalKeyboardKey.digit9: 90,
    };
    final pct = digits[k];
    if (pct != null) {
      _seekToPercent(pct);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// ★ 这次失败**是不是登录问题**（决定失败页显不显示「登录」按钮）
  ///
  /// # ★★★ 2026-09-25（task-38）：这里原先的注释**事实是错的**
  ///
  /// 原注释写着：
  /// > 为这一处判断去改动整条错误传递链的类型（并同步改 Rust/FFI/Dart），
  /// > **风险和收益完全不成比例**。
  ///
  /// 那个判断**不成立** —— 链上**早就有**结构化类别了：
  /// ```text
  /// rust/sourin_core/src/ffi.rs 的 err_json
  ///   → {"error": "...", "kind": "network|unauthorized|not_found|unsupported|other"}
  /// lib/core/ffi.dart
  ///   → class SourinCoreException { final String kind; ... }
  ///                       // ↑ kind 一直在！还带文档注释
  /// ```
  /// 真正的问题是**这一层自己把它 `toString()` 掉了**：
  /// ```dart
  /// _error = e.toString();   // ← kind 被拼进字符串，然后就只能靠"找词"
  /// ```
  /// 所以不是"改造成本高"，而是"现成的信息被丢了"。
  ///
  /// # 现在的判据（结构化优先，文案兜底）
  ///
  /// ```text
  /// ① `_errorKind == 'unauthorized'`  → true
  ///    ★ 来自 FFI 的结构化字段，**不受文案影响**
  /// ② 否则回退到字符串匹配（老路径 / 本页自拼的中文串 / media_kit 错误）
  ///    · 'unauthorized'  ← 插件自己抛的（cycani.js: 'unauthorized: 登录已失效…'）
  ///    · '登录已失效'     ← playback.rs:157 的固定文案
  /// ```
  /// ⚠️ 保留兜底是**有意**的：`_errorKind` 为 null 的情况真实存在
  ///    （`_error = '该内容没有可播放的地址'` 这种本页自拼的串、
  ///    以及 `media_kit` 抛的播放错误都没有 kind）。
  ///
  /// ⚠️ 宁可漏判也不能误判：误判会让「没有可播放地址」这类用户
  ///    看到一个无关的登录按钮。所以**不做**「包含『登录』二字」这种宽泛匹配 ——
  ///    「该源需要登录后才能播放」也含「登录」，但它不是失效。
  bool get _isAuthError {
    /*
     * ① ★ 结构化优先：kind 直接来自 FFI，与文案措辞**完全无关**。
     *    ⇒ 以后插件把 'unauthorized: …' 改成任何说法，这里都不会漏判。
     */
    if (_errorKind == 'unauthorized') return true;

    // ② 兜底：没有 kind 的老路径（见上面注释）
    final e = _error;
    if (e == null) return false;
    final lower = e.toLowerCase();
    return lower.contains('unauthorized') || e.contains('登录已失效');
  }

  /// 从任意异常里取出**结构化类别**（拿不到就 null）
  ///
  /// # 为什么要单独一个函数（而不是每处写 `e is SourinCoreException ? e.kind`）
  ///
  /// ```text
  /// ① 4 处赋值点都要用 —— 写 4 遍必然漂（本项目已有"两处同构必须一起改"的教训）
  /// ② 类型判断集中一处：以后 FFI 换异常类型只改这里
  /// ③ ★ `Object?` 入参而不是 `dynamic`：Dart 的 `is` 检查对 `Object?` 完全安全，
  ///    且不会因为动态派发把拼写错误藏起来
  /// ```
  ///
  /// ⚠️ 返回 `null` 是**正常情况**，不是失败：`media_kit` 的播放错误、
  ///    本页自己拼的中文串都没有类别 → 调用方回退到字符串判据。
  static String? _kindOf(Object? e) {
    if (e is SourinCoreException) {
      final k = e.kind;
      return k.isEmpty ? null : k;
    }
    return null;
  }

  /// ★ 就地登录，成功后自动重试播放（用户要求「点击可以进行直接登录」）
  ///
  /// 只在登录**成功**时才重试：失败还去重试等于白打一次请求，
  /// 而且会把用户刚输错密码的提示冲掉，让他以为"点了没反应"。
  Future<void> _loginAndRetry() async {
    /*
     * 弹窗标题要显示源的**中文名**（"登录 次元城"），而不是 id（"cycani"）。
     * 播放页只持有 id（`widget.provider`），所以现查一次 ——
     * `listProviders()` 走的是本地注册表，没有网络开销。
     *
     * ⚠️ 查不到就**退回 id**，不能因为"拿不到漂亮名字"就不弹窗 ——
     *    用户此刻要的是登录，不是标题好看。
     */
    var name = _provider;
    try {
      final list = await SourinApi.listProviders();
      final hit = list.where((p) => p.id == _provider).firstOrNull;
      if (hit != null && hit.name.isNotEmpty) name = hit.name;
    } catch (e) {
      debugPrint('[PLAYER] 取源名称失败（退回 id）: $e');
    }

    if (!mounted) return;
    final ok = await showProviderLoginDialog(
      context,
      providerId: _provider,
      providerName: name,
    );
    if (!mounted || !ok) return;
    debugPrint('[PLAYER] 登录成功，自动重试播放');
    await _load();
  }

  /// 退出播放器（**唯一**出口）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 为什么必须收成一个方法（2026-09-24 用户第三次纠正后发现）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// 播放器有**三条**退出路径：
  /// ```text
  /// ① 顶栏的返回按钮        onBack: () => Navigator.pop()
  /// ② 错误浮层的「返回」     onBack: () => Navigator.pop()
  /// ③ 键盘/TV 返回键        KeyEventResult 分支
  /// ```
  /// 我原来三处都直接写 `Navigator.of(context).maybePop()`。
  ///
  /// # 漏了什么
  ///
  /// 只 pop 不**退出 OS 全屏**。于是：
  /// ```text
  /// 全屏看片 → 点返回 → 回到详情页
  ///   → 窗口**仍然是全屏的**，而且此时 titleBarVisible 被
  ///     `dispose` 恢复成 true 却被全屏吃掉了看不到
  ///   → 用户看不到标题栏、也不知道怎么退出全屏 = **被困住**
  /// ```
  /// 这和「Esc 只退全屏不返回」是同一类问题的两面。
  ///
  /// # 为什么要在这里退全屏，而不是只靠 dispose
  ///
  /// `dispose` 是**同步**的，而 `windowManager.setFullScreen()` 是**异步**的
  /// —— 在里面 fire-and-forget 会在页面已经销毁后才生效，
  /// 期间用户看到的是"全屏的详情页"。在 pop **之前** await 更可靠。
  ///
  /// ⚠️ 顺序：**先退全屏，再 pop**。反过来的话 pop 已经开始了，
  ///    退全屏的动画会和页面切换动画打架，看起来像闪一下。
  /// ★ task-8 ① 探针：直接 await `_toggleFullscreen()`，量它到底要多久 / 卡不卡。
  ///
  /// # 为什么要单独量它
  /// ```text
  /// `_exitPlayer()` 里只有一处 await 就是它。若它不返回，
  /// 后面的 `maybePop()` **永远不会执行** —— 用户看到的就是「点了返回没反应」。
  /// ```
  Future<int> debugPlayerToggleFullscreenForProbe() async {
    final sw = Stopwatch()..start();
    await _toggleFullscreen();
    return sw.elapsedMilliseconds;
  }

  Future<void> _exitPlayer() async {
    /*
     * ★★★ task-8 ①（Owner 2026-10-09 第三批）：返回卡顿
     *
     * Owner 原话：
     * > 从播放界面返回的时候很卡顿
     *
     * # 实测读数（flutter_tester 逐段 Stopwatch；.probe/zz_t8_latency_probe_test.dart）
     * ```text
     * 非全屏路径：_exitPlayer 同步段 0.70ms | 第一帧 19.06ms | 过渡 4.74ms | 合计 24.50ms
     * 全屏路径  ：_exitPlayer 起手 1.19ms | 第一帧 35.21ms | 过渡 5.14ms | 合计 43.58ms
     *                                              ^^^^^^^^^^ 比非全屏多 16.6ms
     * 对照组：`_toggleFullscreen()` 本体耗时 = 2ms（真时钟 runAsync 量得）
     * ```
     * ⇒ 那 16.6ms 的差额**几乎全在** `await windowManager.setFullScreen(next)`
     *   —— 一次真 OS 往返（真机上还要等窗口管理器回包）。
     *
     * # ★ 我第一版改错过（记录在此，避免有人再走一遍）
     * ```text
     * 我原本写成 `unawaited(_toggleFullscreen())`，被 lead 用真机日志推翻：
     *   `setState(_fullscreen = next)` 虽在同步段，但**布局**要等下一个微任务边界，
     *   而那时 pop 已经开始 ⇒ 退全屏那一帧布局**整个排在 pop 之后**
     *   ⇒ 真机看到「窗口先退全屏、再切页」，比原来更花 ——
     *   正是 :9146 那条注释要避免的。
     * ```
     * ⇒ 正确做法 = **保住 await**，只把最后那次 OS 往返摘出等待窗口（`awaitOs: false`）：
     *   ```text
     *   · `_toggleFullscreen` 的同步段（setState / _flash / 回调 / titleBar）
     *     以及**本帧布局**，都在 `_exitPlayer` 仍 await 时完成 ⇒ **帧序不变**；
     *   · OS 调用照样发出去，只是不串行等它回包。
     *   ```
     * ⇒ 「先退全屏再 pop」的**语义**与**帧序**都保住，卡顿（那次 OS 往返）去掉。
     *
     * ⚠️ 非全屏时**一格都不变**（不进分支）：实测 `_fullscreenCalls 前=0 后=0`。
     */
    // ① 全屏状态下先退全屏（**仍 await**：保住帧序），但不串行等 OS 回包
    if (_fullscreen) {
      await _toggleFullscreen(awaitOs: false);
    }
    // ② 保底：无论是否全屏，退出时标题栏都必须是可见的
    titleBarVisible.value = true;
    /*
     * ★ 并且**必须复位深色态** —— 与 `initState` 里的 `titleBarDark = true` 成对。
     *
     * 漏了的话：进过播放页 → 返回首页 → 标题栏**一直是黑的**
     * （首页是浅色主题，顶一条黑带非常突兀）。
     * 这是"成对置位"类缺陷的典型形态，所以 `_exitPlayer` 与
     * `dispose` **两处都复位**（幂等，`ValueNotifier` 值不变时不通知）。
     */
    titleBarDark.value = false;
    // ③ 真正返回
    if (mounted) Navigator.of(context).maybePop();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  生命周期
  // ═══════════════════════════════════════════════════════════════════

  /// ★ 缺陷 13：把 mpv 的缓冲属性接到底栏（500ms 轮询，见 _BufferPoller）
  ///
  /// # 为什么要**交叉校验**（这是本条最容易被忽略的一步）
  /// ```text
  /// demuxer-cache-time 是绝对时间轴上的缓出点，但它**不保证**与
  /// 当前 position 同源 —— 刚 seek 完、或换源之后，两者会短暂地
  /// 各说各话。实测表现是缓冲条**瞬间跨过整个进度条**再弹回来。
  ///
  /// 判据：end 必须 ≈ position + span（跨度就是"从当前位置往后缓存了多少"）。
  /// 差超过 2 秒就认为这一拍不可信 ⇒ 上报 null ⇒ 不画。
  /// 宁可少画一条，也不能画一条错的 —— 用户会据此判断该不该换源。
  /// ```
  ///
  /// ⚠️ `kBufferRangeMode == 'off'` 时**一条属性都不读**（零开销）。
  void _bindBufferPoller() {
    if (kBufferRangeMode == 'off') return;
    _bufferPoller = _BufferPoller(
      read: _readMpvDouble,
      onChanged: (end, statePercent, spanSec) {
        if (!mounted) return;
        _bufferStatePercent = statePercent;
        if (end == null) {
          // ★ 读不到就如实清空（不保留上一次的值 —— 那会变成"卡住不动"的假区间）
          if (_bufferedRange != null) {
            setState(() => _bufferedRange = null);
          }
          return;
        }
        if (spanSec != null) {
          final expected = _position.inMilliseconds + (spanSec * 1000).round();
          if ((end.inMilliseconds - expected).abs() > 2000) {
            debugPrint(
              '[PLAYER] 缓冲区间校验不过：end=${end.inMilliseconds}ms '
              'position=${_position.inMilliseconds}ms span=${spanSec}s ⇒ 本次不画',
            );
            if (_bufferedRange != null) {
              setState(() => _bufferedRange = null);
            }
            return;
          }
        }
        final startMs = spanSec == null
            ? null
            : (end.inMilliseconds - (spanSec * 1000).round()).clamp(0, 1 << 40);
        setState(() {
          _bufferedRange = BufferedRange(
            end: end,
            start: startMs == null ? null : Duration(milliseconds: startMs),
          );
        });
      },
    );
  }

  /// 读一个 mpv 属性为 double；读不到返回 null（**不抛**）
  ///
  /// ⚠️ 判据来自 media_kit 的实现（`real.dart:1278`）：
  ///    `getProperty` 读不到属性时返回**空串**，不抛异常。
  ///    所以"空串"是唯一的失败信号，必须显式拦掉，
  ///    否则 `double.tryParse('')` 虽然也是 null，但会掩盖"属性名写错"这一类错。
  Future<double?> _readMpvDouble(String key) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return null;
    try {
      final raw = await platform.getProperty(key);
      if (raw.trim().isEmpty) return null;
      return double.tryParse(raw.trim());
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    /*
     * ★ 2026-10-08（Owner 第 9 条）：控制条动画控制器必须跟着本页销毁 ——
     *   否则 flutter_test 会判红（AnimationController 泄漏）。
     */
    _controlsAnim.dispose();
    // 缺陷 13：轮询定时器必须跟着本页停掉
    _bufferPoller?.stop();
    _bufferPoller?.clear();
    // ★ 2026-10-09：弹幕失败角标的到点隐藏定时器 —— 不 cancel 会泄漏（且回调打到已卸载 State）
    _danmakuBadgeTimer?.cancel();
    /*
     * ★ 退出前**立刻**落盘
     *
     * 原版注释：
     * > 退出/切集/换源前立刻落一次 —— 否则用户切走时最后几秒会丢。
     * ⚠️ 这里不能 await（dispose 是同步的），所以 fire-and-forget。
     */
    _saveProgress(immediate: true);
    /*
     * ★★★ 2026-09-26 第二轮：注销两个 MediaSession 回调
     *
     * ⚠️ 与 `onFullscreenChanged` **同一纪律**（那段注释已解释过）：
     *    回调可能打到**已卸载**的合并页 State 上。
     *    虽然回调里有 `mounted` 守卫，但注销是**结构性**的保证，更强。
     *
     * ★ 注意 `_saveProgress(immediate: true)` 必须留在**前面** ——
     *   它要读 `_title` / `_cover`，而下面只清回调、不清那些字段；
     *   但保持"先落盘再清理"的顺序更安全（免得将来有人顺手清了字段）。
     */
    _onFullscreenChanged = null;
    _onEpisodeChanged = null;
    // ★ popover 的唯一真值源（ChangeNotifier ⇒ 必须 dispose）
    _popover.dispose();
    _positionNotifier.dispose();
    /*
     * ★ 注销 early handler + 释放显式 FocusNode（task-42）
     *
     * ⚠️ **必须**注销 —— `FocusManager` 是应用级单例，
     *    不移除的话本 handler 会在**播放页已销毁后**继续收键，
     *    而它引用的 `_livePlayerState`/播放器已经不能用了
     *    （轻则无效，重则 setState-after-dispose）。
     *
     * ⚠️⚠️ 必须用 `removeEarlyKeyEventHandler` **配对** ——
     *    用 `removeHandler` 会**静默失败**（shell.dart L2361 记录过），
     *    于是 handler 永远留在链上（且每次进播放页再加一个 ⇒ 累积）。
     */
    FocusManager.instance.removeEarlyKeyEventHandler(_onEarlyKey);
    _pageFocusNode.dispose();
    _progressTimer?.cancel();
    _countdownTimer?.cancel();
    _hideTimer?.cancel();
    _rewindTimer?.cancel(); // ★ 左半屏长按的连续快退定时器
    /*
     * ★ PC 方向键长按的收尾（task-15）
     *
     * 用户按着方向键时退出播放页：若不收尾，
     * 倍速会永远停在 3x（下一集也是 3x）。
     */
    _pcArrowHoldTimer?.cancel();
    _pcArrowHoldTimer = null;
    if (_pcArrow.reset()) _endPcArrowHold();
    /*
     * ★ 画面输出层看门狗作废（它是个 while 轮询，最多 10 秒）
     *
     * 没有 Timer 可以 cancel —— 它靠代次号自证过期（`_watchVideoOutput`
     * 每轮都查 `token != _videoOutputToken || !mounted`）。这里把代次号
     * 推进一格，让**已在飞行中的那一轮**立刻放弃，而不是等它跑完
     * 再对着已卸载的 State 调 `setState`。
     */
    _videoOutputToken++;
    PipController.instance.removeListener(_onPipChanged);
    // ★ 退出播放器时要退出 PiP —— 否则窗口会一直卡在小窗状态
    if (_pipActive) PipController.instance.exit();
    /*
     * ★ 兜底：无论如何都要退出全屏（2026-09-24）
     *
     * 正常路径由 `_exitPlayer()` 处理（它会在 pop 前 await）。
     * 这里是**最后一道防线** —— 万一将来有人加了一条新的 pop 路径
     * 而忘了走 `_exitPlayer`，至少不会留下一个"全屏的、没有标题栏的"
     * 窗口把用户困住。
     *
     * ⚠️ 这里是同步上下文，只能 fire-and-forget —— 所以它是兜底，
     *    不是主路径（主路径必须 await，否则会闪）。
     */
    if (_fullscreen && Device.isDesktop) {
      unawaited(windowManager.setFullScreen(false));
    }
    /*
     * ★ 幂等地把标题栏置为可见（2026-09-24）
     *
     * 播放页**不再隐藏**标题栏（见 `initState` 的长注释：桌面端那是
     * 唯一的拖动区）。这里仍然显式置 true 是**防御性**的：
     * ```text
     * 将来若给"沉浸模式"加隐藏逻辑，退出时必须还原 ——
     * 漏了的话用户会「从播放器返回后再也拖不动窗口」，
     * 而且很难联想到是播放页造成的。
     * ```
     * 幂等赋值没有副作用（`ValueNotifier` 值不变时不通知）。
     */
    titleBarVisible.value = true;
    /*
     * ★ 同样复位**深色态**（与 `initState` 的 `titleBarDark = true` 成对）。
     *
     * 为什么 `_exitPlayer` 与这里**都**写：`dispose` 是**必然**执行的
     * （点返回、被 `pushReplacement` 换掉、页面被销毁都走它），
     * 而 `_exitPlayer` 只覆盖"主动返回"。
     * 两处都复位才能保证**任何**退出路径都不留下黑标题栏。幂等无副作用。
     */
    titleBarDark.value = false;
    /*
     * ★ 注销探针登记（2026-09-25）
     *
     * ⚠️ 必须在这里清 —— 否则探针会拿到一个 **已 dispose 的 state**，
     *    读它的 `_position` 看似有值（Dart 对象还在），但那是**上一集**
     *    的陈旧读数，会让实测得出错误结论。
     */
    if (identical(_livePlayerState, this)) _livePlayerState = null;

    /*
     * ★ 注销遥控的播放能力（与 initState 的 setPlayer 配对）
     *
     * ⚠️ 顺序在 `_player.dispose()` **之前** —— 桥的 tick 是异步的，
     *    如果先 dispose 播放器再注销，中间那几毫秒里桥可能拿到
     *    一个**已 dispose 的播放器**去 getState/exec。
     *
     * ⚠️ 必须把**自己那个** bridge 实例传进去 —— 换页重叠的瞬间
     *    （新页已 init、旧页还没 dispose）无条件清会把新注册的抹掉，
     *    手机上立刻又变成"没有播放器"。见 `clearPlayer` 的说明。
     */
    RemoteBridge.instance.clearPlayer(_remotePlayerBridge);
    _remotePlayerBridge = null;

    /*
     * ★ task-13 ⑦ 关掉弹幕客户端
     *
     * 里面是一个 dart:io HttpClient（含连接池）—— 不 close 会在
     * 热重载/换页时留下悬挂连接。放在 _player.dispose() 之前，
     * 与其它资源（bridge / 计时器）同一段收尾。
     */
    _danmakuClient?.close();
    _danmakuClient = null;

    /*
     * ★ task-31 ④：B 站客户端同理（里面也是一个 dart:io HttpClient）。
     *
     * ⚠️ 不 close 会在热重载/换页时留下悬挂连接 —— 与上面那条同一个理由。
     */
    _biliApi?.close();
    _biliApi = null;

    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hints = hintsFor(
      isTv: widget.isTv,
      isTouchOnly: widget.isTouchOnly,
      isLive: _isLive,
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        /*
         * ★ 挂一个**显式** FocusNode（task-42）
         *
         * # 为什么要（原来是 `Focus(autofocus: true)`，没有 node）
         * ```text
         * 加了硬件层兜底之后，我必须能回答：
         *   "焦点**是不是**已经在本页的 Focus 子树里？"
         *     · 是 ⇒ 交给 `_onKey`（我不处理，避免双触发）
         *     · 否 ⇒ 我兜底
         * ★ 那就要有一个**可比较的节点标识** —— 显式 node 提供它。
         * ```
         * ⚠️ 显式 node 必须自己 dispose（否则泄漏）——
         *    见 `dispose()` 里的 `_pageFocusNode.dispose()`。
         */
        focusNode: _pageFocusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        /*
         * ★★★ task-53【#4b-④】滚轮调音量 —— 挂 `Listener`（`MouseRegion` **外面**）
         *
         * # 为什么位置在这里（不能塞进 `GestureDetector` 里面）
         * ```text
         * `Listener` 只对**它子树内**的命中测试生效。
         * 挂在最外层 ⇒ 播放器画面、底栏、浮层**全都是**它的子树
         *   ⇒ 鼠标在页面任何地方滚都能调音量（与提示文案一致）。
         * ★ 而 `MouseRegion.onHover` 已经在这里了（同层），
         *   说明这一层就是"整个播放页的指针入口"—— 放一起最直观。
         * ```
         * ⚠️ `onPointerSignal` 的具体守卫（浮层/横向滚动/`pointerSignalResolver`）
         *    全在 `_onPointerSignal` 里，见那里的长注释。
         */
        child: Listener(
          onPointerSignal: _onPointerSignal,
          child: MouseRegion(
            onHover: (_) => _showControls(),
            /*
             * ★★★ task-16（Owner：「全屏左上角这个单独的返回icon,还没消失」）
             *
             * 整页级指针进出 —— 悬浮返回键的**常驻**判据就靠这两位。
             * 见 `_pointerInside` 的长注释（含「为什么不能用 onHover」）。
             *
             * ⚠️ 它们与上面的 `onHover` **并列**、互不替代：
             *    onHover   = 「鼠标在动」⇒ 续命控制条（3 秒计时器重排）
             *    onEnter/Exit = 「鼠标在不在」⇒ 悬浮键该不该常驻
             * 两者的触发条件不同（静止的指针不发 hover），所以缺一不可。
             */
            onEnter: (_) => _onPointerEnter(),
            onExit: (_) => _onPointerExit(),
            child: GestureDetector(
              key: _gestureKey, // ★ 探针靠它精确定位到播放页自己这个 detector
              /*
             * ══════════════════════════════════════════════════════════
             * ★★★ 单击 = 播放/暂停（**唯一**语义）—— 2026-09-25 用户要求
             * ══════════════════════════════════════════════════════════
             *
             * 用户原话：
             * > 不要单击快进快退,去掉这个功能
             *
             * # 删掉的是什么
             *
             * 之前单击是**按屏幕区域分流**的（用 `onTapUp` 自己判左右）：
             * ```text
             * 左半屏        → 快退 N 秒
             * 右半屏        → 快进 N 秒
             * 正中窄带(±8%) → 播放/暂停
             * ```
             * 现在**左右分流整个删掉**，单击画面一律播放/暂停。
             * 播放/暂停是所有播放器（含原版）的通行习惯，用户没说要动它。
             *
             * ⚠️ 左右**区域**的概念没有消失 —— 它现在只服务**长按**
             *    （左半屏长按=连续快退，右半屏长按=倍速快进），
             *    见下面 `onLongPressStart`。单击不再看坐标。
             *
             * # ★ 顺手修掉一个**真 bug**（原来 PC 单击会同时跳秒 + 暂停）
             *
             * 原来同一个 `GestureDetector` 上同时挂了 `onTap` 和 `onTapUp`。
             * 它俩**不是两个手势**，而是**同一个 `TapGestureRecognizer`**
             * 上的两个回调字段：
             * ```dart
             * // flutter/lib/src/widgets/gesture_detector.dart:1069-1071
             * instance..onTapUp = onTapUp..onTap = onTap;
             *
             * // flutter/lib/src/gestures/tap.dart:754-758
             * if (onTapUp != null) invokeCallback('onTapUp', ...);
             * if (onTap != null)   invokeCallback('onTap', ...);  // 紧随其后
             * ```
             * 也就是**一次单击会把两个回调都跑一遍**，顺序固定为
             * `onTapUp` → `onTap`：
             * ```text
             * PC   点右半屏 → 先快进 10 秒，紧接着又 play/pause
             * 手机 点任意处 → onTapUp 提前 return，然后 onTap 暂停  ← 看似正常
             * ```
             * 手机端"看起来正常"纯属巧合（区域分支提前 return 了），
             * PC 端则是**跳秒 + 暂停**两个动作同时发生。
             *
             * 所以原来那句注释「不能同时用 `onTap` 又自己判区域 ——
             * 会互相吞掉」是**说反了**：不是互相吞，是**两个都执行**。
             * （两个回调都挂在同一个 recognizer 上，不存在竞争。）
             *
             * # 现在只用 `onTap`
             *
             * 区域分流没了，`onTapUp` 也就没有存在理由 —— 直接用 `onTap`，
             * 语义最干净：它就是"一次完整的单击"。
             *
             * # ⚠️ 代价：触摸端单击会延迟约 300ms
             *
             * 触摸端还挂着 `onDoubleTapDown`（双击左右侧快进快退）。
             * `GestureDetector` 只要同时有 `onTap` 和 `onDoubleTapDown`，
             * 单击就必须**等双击判定超时**才触发，否则第一次点击会立刻暂停、
             * 而用户其实想双击快进：
             * ```dart
             * // flutter/lib/src/gestures/constants.dart:35
             * const Duration kDoubleTapTimeout = Duration(milliseconds: 300);
             * ```
             *
             * **这是可接受的**（标准行为：所有"单击 + 双击"共存的播放器
             * 都这样，YouTube / B站 / 原版 WebView 同理），但要知道有这个延迟。
             *
             * ⚠️ PC 上**没有**这个延迟 —— PC 的 `onDoubleTapDown` 是 null
             *    （见下面的条件挂载），竞技场里没有双击竞争者，
             *    `onTap` 立即触发。
             */
              onTap: _togglePlay,
              /*
             * ══════════════════════════════════════════════════════════
             * ★★★ 双击左右侧快进快退 —— **PC 上不做**（2026-09-24 用户要求）
             * ══════════════════════════════════════════════════════════
             *
             * 用户原话：
             * > pc端不应该双击左右侧快进快退
             * > 手机端,应该做成配置  双击左右侧 快进快退,配置多少秒
             * >   是否可关闭
             * > 这样子才是对的,**不要把手机上的操作习惯跟PC保持统一**
             *
             * # 原来错在哪
             *
             * 无条件下挂 `onDoubleTapDown` —— PC 上双击也会跳 10 秒。
             * 对鼠标用户那是**误触**：想连点暂停、想选中文字，
             * 结果画面跳了 10 秒；而且 PC 本来就有 J/L/方向键，
             * 根本不需要手势。
             *
             * # 现在
             *
             * ```text
             * PC    → **双击**不生效（这一块说的只是双击；PC 仍有长按，
             *          见下面 onLongPressStart，且双击不显示设置项）
             * 触摸端 → 生效，且步长/开关都能配（见 core/player_gestures.dart）
             * ```
             */
              /*
             * ══════════════════════════════════════════════════════════
             * ★★★ 左/右两个**手势区域** —— 现在**只剩长按**（2026-09-25）
             * ══════════════════════════════════════════════════════════
             *
             * 用户先后说了三句，最后一句**推翻了前两句里的单击部分**：
             * ```text
             * ① 「pc端更直觉的左右按钮 单点是快进快退(可配置)
             *     长按是倍速,右是快进倍速(可配置) 左是 快退(可配置)」
             * ② 「不应该显示播放器两侧的按钮,识别手势就行了
             *     这两个圆圈太难看了」
             * ③ 「不要单击快进快退,去掉这个功能」   ← 最终需求
             * ```
             * ①②合并出来的那张表，③把「单击」那一列**整列删掉**：
             *
             * ```text
             *          单击                  长按
             * 左半屏   （已删除）            连续快退（每步可配）
             * 右半屏   （已删除）            倍速快进(可配)，松开恢复
             * 整屏     播放/暂停  ← onTap     —
             * ```
             *
             * # 为什么"区域"还留着
             *
             * 用户删的是**单击跳秒**，不是"左右区域"这个概念本身。
             * 长按仍然要分左右（左=快退、右=快进），所以
             * `_onLongPressStartAt(d.localPosition)` 的区域判断**必须保留**。
             *
             * 别因为"单击不分流了"就顺手把长按的区域判断也删了 ——
             * 那会让左半屏长按变成快进（方向反了）。
             *
             * # 单击为什么不再需要自己判坐标
             *
             * 见上面 `onTap` 的说明：单击语义变成"整屏统一播放/暂停"之后，
             * 就没有任何理由再读 `localPosition`，也就不需要 `onTapUp`。
             */
              onDoubleTapDown: _doubleTapEnabled
                  ? (d) {
                      final w = MediaQuery.of(context).size.width;
                      final forward = d.localPosition.dx >= w / 2;
                      final secs = PlayerGestures.doubleTapSeconds;
                      _seekBy(forward ? secs : -secs);
                    }
                  : null,
              /*
             * ══════════════════════════════════════════════════════════
             * ★★★ 双击 = 进入/退出全屏（task-42，用户要求）
             * ══════════════════════════════════════════════════════════
             *
             * 用户原话：
             * > 然后播放页面要支持空格暂停/播放,enter 和 **双击** 进入/退出 全屏
             *
             * # ★★ 为什么 PC 上**不需要**"中间/左右分区"
             * ```text
             * 我原本担心与"双击左右快进快退"冲突。查了代码：
             *   `_doubleTapEnabled` ⇒ `doubleTapEnabledFor(isTouch:)`
             *   ⇒ ★ **PC/TV 恒 false**（那是 2026-09-24 用户明确要求的：
             *      「pc端不应该双击左右侧快进快退」）
             * ⇒ PC 上"双击"**本来就是个空档**（什么都不做）
             * ⇒ 让给"全屏"**零冲突**，不需要分区。
             * ```
             *
             * # 所以两个平台各走各的（**互斥**，这是关键）
             * ```text
             * PC/TV   ：onDoubleTap     = 全屏（本段）
             * 触摸端   ：onDoubleTapDown = 左右快进快退（既有，不动 —— 尊重设置开关）
             * ```
             * ⚠️⚠️ **两者绝不能同时挂** ——
             * `GestureDetector` 的 `onDoubleTap` 与 `onDoubleTapDown` 是
             * **同一个 `DoubleTapGestureRecognizer` 上的两个回调**，
             * 一次双击会把**两个都跑一遍**（与上面 L4565 记录的
             * "onTap/onTapUp 同挂会都执行"是**同一个坑**）。
             * ⇒ 用 `_isTouchGestureTarget` 三向分流，保证只有一个非 null。
             */
              onDoubleTap: _isTouchGestureTarget
                  ? null
                  : () {
                      debugPrint('[PLAYER-KEY] 双击 ⇒ 切换全屏');
                      unawaited(_toggleFullscreen());
                    },
              /*
             * ── 长按 = 分区域（用户要求）──
             *
             * ```text
             * 左半屏 → 连续快退
             * 右半屏 → 倍速快进
             * ```
             *
             * ⚠️ `onLongPressStart/End` 而不是 `onLongPress` ——
             *    后者只在"长按完成"时触发一次，**没有抬起事件**，
             *    没法恢复倍速（会一直卡在 2x）。
             *
             * ⚠️ 必须用 `LongPressStartDetails.localPosition` 判区域 ——
             *    不能只看"当前是否在长按"，否则左侧长按会变成快进。
             */
              onLongPressStart: _longPressEnabledForThisDevice
                  ? (d) => _onLongPressStartAt(d.localPosition)
                  : null,
              onLongPressEnd: _longPressEnabledForThisDevice
                  ? (_) => _endAnyLongPress()
                  : null,
              onLongPressCancel: _longPressEnabledForThisDevice
                  ? _endAnyLongPress
                  : null,
              /*
             * ★★★ 2026-10-07 修复（Owner：「左边播放器鼠标点击、在上面移动都没有反应」）
             *
             * # 实测到的根因
             * ```text
             * GESTRO 探针（从 _gestureKey 的 RenderObject 沿 parent 上溯）：
             *   控制条可见时：RenderSemanticsGestureHandler@1011x805 < RenderMouseRegion@1011x805 < …
             *   控制条隐藏后：RenderSemanticsGestureHandler@0x0   < RenderMouseRegion@0x0   < …
             * ⇒ 手势层被布局成 **0x0** ⇒ 指针永远命不中 ⇒ 点击/悬停全失效、
             *   而且再也无法把控制条唤回来（Owner 同时报的「无法返回首页」同源：
             *   返回按钮在 _TopBar 里，只受 _controlsVisible 门控）。
             * ```
             *
             * # 为什么 Stack 会缩成 0
             * ```text
             * RenderStack._computeSize（packages/flutter/lib/src/rendering/stack.dart:625-675）：
             *   只有 **非 Positioned** 的子项才参与尺寸计算；
             *   `if (hasNonPositionedChildren) size = Size(width, height); else size = constraints.biggest;`
             * ⇒ 一旦出现非 Positioned 的 0 尺寸子项（本页 Stack 的第一个 child
             *   就是 `const SizedBox.shrink()` 这类探测/占位项），
             *   Stack 就可能塌成 0，连带把外层 MouseRegion/GestureDetector 也拉成 0。
             * ```
             *
             * # 修法
             * ```text
             * 把包裹手势层的盒子**钉死**成铺满：
             *   SizedBox.expand ⇒ 给 Stack 一个 tight 约束
             *   ⇒ 无论子项怎么变，Stack 都占满整块播放器区
             *   ⇒ 命中测试永远能落到 MouseRegion / GestureDetector 上
             * 零副作用：不改变任何绘制、不改变 Stack 子项的布局语义。
             * ```
             */
              child: SizedBox.expand(
                child: Stack(
                  children: [
                    // ── 视频画面 ──
                    Positioned.fill(
                      child: Center(
                        child: Video(
                          controller: _controller,
                          controls: NoVideoControls,
                          fill: Colors.black,
                        ),
                      ),
                    ),

                    /*
                 * ── ★★★ dandanplay 弹幕层（task-13 ⑦）──
                 *
                 * # 用户原话
                 *
                 * ┌ 接入一下 dandanplay 的弹幕功能
                 * └
                 *
                 * # 为什么要套 IgnorePointer
                 *
                 * 弹幕层盖在整个视频区上，而播放页的单击 / 双击 / 长按
                 * 手势是靠**下层**的 GestureDetector 识别的。不套的话
                 * 弹幕层会把所有手势吃掉 —— 用户会发现「开了弹幕之后
                 * 单击暂停就失灵了」。
                 *
                 * # 为什么它自己算几何
                 *
                 * DanmakuOverlay 内部用 danmakuContainRect 复刻了
                 * BoxFit.contain（与下面描边层**同一套**），所以弹幕
                 * 只出现在画面内，不会跑到黑边上。这里只负责给它约束。
                 */
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DanmakuOverlay(
                          aspect: _displayAspect,
                          comments: _danmakuComments,
                          position: _position,
                          playing: _playing,
                          rate: _rate,
                          enabled: _danmakuEnabled,
                          fontScale: _danmakuSettings.fontScale,
                          opacity: _danmakuSettings.opacity,
                          speed: _danmakuSettings.speed,
                          area: _danmakuSettings.area,
                          badge: _danmakuBadge,
                        ),
                      ),
                    ),

                    /*
                 * ── ★★★ 视频区描边（task-28 ②：上下黑边要有边界）──
                 *
                 * # 用户原话
                 * > 播放器页面**上面黑色，跟下面黑色融为一体了，搞点边界出来**
                 *
                 * # 根因（**量出来的**，不是猜的）
                 *
                 * 诊断探针（`.probe/probe_tests/zz_diag_boundary_test.dart`）实测：
                 * ```text
                 * Scaffold  = Rect.fromLTRB(0, 0, 1280, 800)
                 * Video[0]  = Rect.fromLTRB(0, 0, 1280, 800)   ← ★ 铺满整屏
                 * AspectRatio 个数 = 0                          ← ★ 外面没有约束
                 * 带渐变的 DecoratedBox = 1（顶部栏 1280x72）
                 * ```
                 * 也就是说 **`Video` widget 自己铺满整屏**，它内部用
                 * `BoxFit.contain` 把 16:9 的画面居中，四周填 `fill: Colors.black`。
                 *
                 * 而窗口是 1280x800（比例 1.60），16:9 画面实际只有
                 * `1280 x 720` ⇒ **上下各留 40px 黑边**。于是：
                 * ```text
                 * 顶部栏渐变(black87→透明)  ← 黑
                 * 上黑边 40px              ← 黑
                 * 画面
                 * 下黑边 40px              ← 黑
                 * 底部控制条渐变            ← 黑
                 * = ★ 全是黑，看不出画面从哪开始到哪结束
                 * ```
                 *
                 * # 为什么用"描边"而不是改 `fill` 颜色
                 *
                 * ```text
                 * 候选 A ★ 描边（本实现）
                 *    · 不碰 `Video` 的布局与 `fill` ⇒ **零风险改变画面渲染**
                 *    · 1px 细线就足以让眼睛分辨出"画面到这儿为止"
                 *    · 与用户说的"搞点边界出来"字面一致
                 *
                 * 候选 B 把 `fill` 改成 #0a0a0a
                 *    · `fill` 是 media_kit 的**内部**填充，改它只是让黑边
                 *      比 UI 略亮一点点 —— 高对比屏上几乎看不出，
                 *      而且会把"视频区域"和"UI 区域"的明暗关系弄反
                 *      （通常 UI 该比画面暗，不是亮）
                 *
                 * 候选 C 给控制条加渐变
                 *    · ★ 控制条**已经有**渐变了（`Colors.black87 → transparent`）
                 *      —— 它之所以看不见，正是因为底下的黑边也是黑的。
                 *      再加一层渐变解决不了这个问题。
                 * ```
                 *
                 * # ★ 为什么描边必须自己算 contain 矩形
                 *
                 * 因为 `Video` 铺满整屏（见上面的实测），
                 * 所以"画面在哪"只能**按比例算**：
                 * ```text
                 * 可用区 1280x800，视频 16:9
                 *   按宽铺满 → 高 = 1280/1.778 = 720 ≤ 800  ✅ 取它
                 *   画面 = 1280x720，居中 ⇒ 上下各留 40px
                 * ```
                 * 这正是 `BoxFit.contain` 的算法。用 `LayoutBuilder` 拿真实
                 * 可用尺寸再算，窗口缩放时自动跟着变。
                 *
                 * ⚠️ 用 `_displayAspect`（**不夹取**）而不是 PiP 用的
                 *    `_videoAspect` —— 后者夹到 `[1/2.39, 2.39]` 是给
                 *    Android 小窗用的，拿它画描边会让 21:9 以上的片源描边错位。
                 *
                 * ⚠️ 宽高拿不到时（起播前）返回 null ⇒ **不画描边**，
                 *    而不是按 16:9 画一个可能是错的框。
                 */
                    Positioned.fill(
                      child: IgnorePointer(
                        child: LayoutBuilder(
                          builder: (context, box) {
                            final ar = _displayAspect;
                            if (ar == null) return const SizedBox.shrink();
                            // BoxFit.contain 的几何
                            var w = box.maxWidth;
                            var h = w / ar;
                            if (h > box.maxHeight) {
                              h = box.maxHeight;
                              w = h * ar;
                            }
                            return Center(
                              child: SizedBox(
                                width: w,
                                height: h,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    /*
                                 * 1px 细线，比纯黑略亮。
                                 *
                                 * `0xFF2A2A2A` 的取值依据：控制条渐变的起点是
                                 * `Colors.black87`（alpha 0.87 的黑，压在画面
                                 * 边缘约等于 #1F1F1F）。用同一明度档，
                                 * 描边才"看得见但不抢眼"。
                                 *
                                 * ⚠️ 不能更亮（比如 #444）：全屏观影时一圈灰框
                                 *    会明显分散注意力，那就从"有边界"变成
                                 *    "有干扰"了 —— 用户要的是边界，不是装饰。
                                 */
                                    /*
                                 * ══════════════════════════════════════
                                 * ★★★ 2026-10-08：左右两条边**不画**
                                 *     （Owner 第 8 条：「播放详情页的右侧
                                 *     弹窗不要包含一条黑色的边框」）
                                 * ══════════════════════════════════════
                                 *
                                 * # 现象（Owner 截图 u9_92496b4e.png
                                 *   1444x845 逐像素实测）
                                 * ```text
                                 * x=1006..1009 画面
                                 * x=1010        整列 (42,42,42)，共 567 行
                                 *               = y 159..725 ← ★ 就是"那条黑边"
                                 * x=1011..      surface (238,240,246)
                                 * ⇒ 这一列**只**属于描边矩形，右侧信息面板
                                 *   自己从 1011 才开始（面板左边缘 x=1011，
                                 *   上边缘 y=40，右/下都顶到窗口外沿）
                                 * ```
                                 *
                                 * # 为什么它看起来像"面板的边框"
                                 * ```text
                                 * 描边矩形的**右边**与面板的**左边**正好贴在一起
                                 * （视频区右边界 = 面板左边界 = 1010/1011），
                                 * 于是这条竖线在视觉上就"长在面板身上"。
                                 * ```
                                 *
                                 * # 为什么左右两条**都不该有**
                                 * ```text
                                 * ① 这条描边的**目的**是"上下黑边要有边界"
                                 *    （Owner 原话见本层开头）—— 上下才是需求。
                                 * ② 视频区左右**本来就没有黑边**：窗口宽 > 画面宽
                                 *    时 contain 是"按高铺满、左右裁"，画面顶到
                                 *    视频区两侧；左右两条线是**贴着画面**画的，
                                 *    不是画在黑边上，属于纯粹多余的框。
                                 * ③ 右边那条紧贴信息面板 ⇒ 用户直接读成
                                 *    "面板的黑边框"。
                                 * ```
                                 *
                                 * # ★ 为什么不能写 `Border.all(...).copyWith(right: none)`
                                 * ```text
                                 * 上面那条路试过（`Border` 的 right 换成
                                 * `BorderSide.none`），实测**右边仍在**：
                                 * `Border.paint`（box_border.dart:654-675）先看
                                 * `isUniform`（同色同宽 ⇒ 本例为 true），
                                 * 命中后**忽略四条边的 style**，直接走
                                 * `BoxBorder._paintUniformBorderWithRectangle`
                                 * （:360-363）：
                                 *   canvas.drawRect(rect.inflate(strokeOffset / 2), side.toPaint())
                                 * ⇒ 画的是一条**整矩形描边**，根本没有"哪条边不画"
                                 *   的概念 ⇒ right: none 被静默丢弃。
                                 * ⇒ 要"只画上下"必须让 `isUniform == false`
                                 *   （左右 `BorderSide.none` 与上下不同）⇒
                                 *   走 `paintBorder`（borders.dart:883+）逐边绘制。
                                 * `Border.symmetric` 正好构造出这种非均匀边框。
                                 * ```
                                 *
                                 * ⚠️ `Border.symmetric` 的命名是"轴"不是"位置"：
                                 *    `horizontal:` ⇒ **上 + 下**（box_border.dart:455-461）
                                 *    `vertical:`   ⇒ 左 + 右
                                 */
                                    border: const Border.symmetric(
                                      horizontal: BorderSide(
                                        color: Color(0xFF2A2A2A),
                                        width: 1,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),

                    // ── 缓冲指示 ──
                    if (_buffering && !_loading)
                      const Center(
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                      ),

                    // ── 加载中 ──
                    if (_loading) const _LoadingOverlay(),

                    // ── 错误 ──
                    if (_error != null)
                      _ErrorOverlay(
                        message: _error!,
                        onRetry: _load,
                        onBack: () => unawaited(_exitPlayer()),
                        /*
                     * ★ 只有**确实是登录问题**时才给登录按钮（用户要求）
                     *
                     * 用户原话：
                     * > 我要求在这个页面也要显示出来 登录 按钮，
                     * > 点击可以进行直接登录
                     *
                     * 判据用 `_isAuthError`：看错误文案里有没有
                     * `unauthorized` / `登录已失效`。**不能无条件显示** ——
                     * 「该内容没有可播放的地址」「所有线路都不可播」这类
                     * 失败跟登录毫无关系，摆个登录按钮只会误导用户
                     * 去重登一个本来好好的账号。
                     */
                        onLogin: _isAuthError
                            ? () => unawaited(_loginAndRetry())
                            : null,
                      ),

                    // ── 顶部栏 ──
                    /*
                     * ══════════════════════════════════════════════════════
                     * ★★★ 2026-10-08（Owner 追加）顶栏必须与底栏**联动**
                     * ══════════════════════════════════════════════════════
                     *
                     * 用户原话（逐字）：
                     * > 现在下面的底栏的会遵循我说的逻辑隐藏了,但是上面的
                     * > 这个也是一样的规则,而且上面的这个跟下面的 是要联动的,
                     * > 隐藏一起隐藏,我说的触发条件 触发了,然后也要显示,知道吧
                     *
                     * # 改前为什么顶栏**从不消失**
                     * ```text
                     * 判据是 `_controlsVisible || _canUseFloatingBack`，而
                     *   `_canUseFloatingBack`（:6992）= `Device.isDesktop &&
                     *   _error == null && !_anySheetOpen`
                     * ⇒ 桌面端正常播放时它**恒为 true**
                     * ⇒ 顶栏**无条件渲染**，`_controlsVisible` 翻 false 也拦不住它。
                     *   （那一条 `||` 是当年为了「控制条藏了就没有返回口」加的，
                     *     但那个需求已经由**常驻悬浮返回键**单独满足了 ——
                     *     见 `_TopBar` 里 `if (!visible && onFloatingBack != null)`。）
                     * ```
                     *
                     * # 改后
                     * ```text
                     * ① 顶栏**常挂**（去掉外层 `if`）⇒ 它才能在隐藏时播淡出；
                     * ② 渐变条看 `visible`（= `_controlsVisible && _error == null`）
                     *    ⇒ 与底栏**同一个真源** ⇒ 一起消失、一起出现 ✓
                     * ③ 悬浮返回键仍然只在「藏起来 + 桌面 + 无错误 + 无浮层」时出现
                     *    ⇒ 「藏了就没法返回」这个老缺陷**没有回归**。
                     * ```
                     *
                     * ⚠️ `_error == null` 这一半必须留着：起播失败时顶栏那条
                     *    渐变条会压在错误浮层上（改前 `_canUseFloatingBack` 为
                     *    false ⇒ 整条不渲染）。现在用 `visible` 表达同一件事。
                     */
                    _TopBar(
                      title: _title,
                      episodeTitle: _epIndex < _episodes.length
                          ? _episodes[_epIndex].title
                          : widget.episodeTitle,
                      isLive: _isLive,
                      providerName: _providerName,
                      onBack: () => unawaited(_exitPlayer()),
                      onHints: hints.isEmpty ? null : _toggleHints,
                      /*
                     * ★ 常驻悬浮返回键（用户缺陷②）
                     *
                     * 用户原话：
                     * > 就是箭头指的位置,你看到了吗?而且我现在无法返回到首页了
                     *
                     * 顶栏随控制条 3 秒后一起消失 ⇒ 屏幕上再没有可点的返回口。
                     * 判据与设计见 `_FloatingBackButton` 的长注释。
                     */
                      /*
                         * ★★★ 缺陷（Owner 2026-10-09）：错误态下**也要**给返回口
                         *
                         * 改前只有 `_canUseFloatingBack` ⇒ `_error != null` 时传 null
                         * ⇒ 悬浮键不画（`_TopBar` 内部 `if (!visible && onFloatingBack != null)`），
                         * 而顶栏那枚又因 `visible == false` 被 IgnorePointer 挡住。
                         * 见 `_canUseTopBarBack` 的长注释。
                         */
                      /*
                         * ★ 顶栏渐变条的可见性 —— 与**底栏同一条判据**
                         *
                         * 底栏的判据是
                         *   `_controlsVisible && _error == null && !_xSheetOpen …`
                         * 顶栏只需要前半段：它不占底部空间，浮层打开时留着
                         * 不冲突（`_canUseFloatingBack` 里的 `!_anySheetOpen`
                         * 已经管住了悬浮返回键）。
                         *
                         * ⚠️ 这里**不能**写成 `_controlsVisible || _canUseFloatingBack`
                         *    （那是改前的写法，正是顶栏永不消失的原因）——
                         *    悬浮返回键的可见性由 `_TopBar` 内部
                         *    `if (!visible && onFloatingBack != null)` 单独决定，
                         *    与这条渐变条**解耦**。
                         *
                         * ★★★ 2026-10-09 追加（Owner 新增缺陷）：`|| _canUseTopBarBack`
                         * ```text
                         * 错误态下 `_controlsVisible && _error == null` 必为 false
                         * ⇒ `IgnorePointer(ignoring: true)` 把顶栏整条挡住 ⇒ 箭头点不动。
                         * 补上 `_canUseTopBarBack`（= 桌面端 && 有错误 && 无浮层）后：
                         *   顶栏那条**保持可见**（顶栏本身就是错误态下唯一的返回视觉），
                         *   而 IgnorePointer 照旧 `!visible` 参与 ⇒ 箭头可命中。
                         * ```
                         * ⚠️ 为什么**不是**复用 `_canUseFloatingBack`：那一位在错误态恒 false
                         *    （它含 `_error == null`），写进去等于没改。
                         */
                      visible:
                          (_controlsVisible && _error == null) ||
                          _canUseTopBarBack,
                      /*
                         * ★ 2026-10-08（Owner 第 9 条）：顶栏的淡入淡出。
                         *
                         * ⚠️ 只喂给那条渐变条 —— 常驻悬浮返回键走
                         *    `onFloatingBack`，**不参与**淡出（见 `_TopBar.fade` 的说明）。
                         *    -- ★★★ 2026-10-09 修正（缺陷 2）：上面这句已不成立，原话保留供追溯；
                         *       现在同一条 _controlsFade 同时喂给 floatingFade，两者不透明度之和恒为 1（交叉淡化）。
                         *       为何改：硬切会让两枚箭头同屏，用户读作「返回图标残留」。
                         *
                         * ★★★ 2026-10-09 追加（Owner 新增缺陷 · 错误态返回箭头）：
                         *    错误态下 `fade` **必须钉在 kAlwaysCompleteAnimation**。
                         * ```text
                         * 根因：`_controlsFade` 的终值是 `_controlsVisible ? 1.0 : 0.0`
                         *       （`_applyControlsMotion` 里驱动）。错误态下控制条本就是隐藏的
                         *       => `_controlsFade` 会走到 **0** => `Opacity(opacity: 0)`。
                         *       于是即使把 `visible` 打开成 true（IgnorePointer 放行命中测试），
                         *       箭头仍然是**全透明**的 —— 用户还是看不见、也就不会去点。
                         * ```
                         * ⇒ 那一支把 fade 钉死为 1（kAlwaysCompleteAnimation 的 value 恒为 1.0，
                         *    而 `_TopBar` 里是 `fade?.value ?? 1.0` ⇒ 等价且不用改 _TopBar 内部）。
                         *
                         * ⚠️ **为什么在错误态钉死是安全的**（不产生缺陷 2 的「两枚箭头同屏」）：
                         * ```text
                         * 缺陷 2 的交叉淡化是为了让「顶栏箭头」与「悬浮键」在**互相切换**时
                         * 不出现两枚同时可见。而错误态下 `_canUseFloatingBack == false`
                         * （它含 `_error == null`）⇒ `onFloatingBack` 虽然非 null（我们刚补的），
                         * 但 `if (!visible && onFloatingBack != null)` 里 `visible` 此时为 true
                         * ⇒ **悬浮键那一支不成立、不会画**。
                         * ⇒ 屏幕上只有顶栏这一枚 ⇒ 交叉淡化**不需要维持** ⇒ 钉死无冲突。
                         * ```
                         * ⚠️ 正常播放时（`_error == null`）表达式退化成原来的 `_controlsFade`
                         *    **逐字节不变** ⇒ 缺陷 2 的几何/交叉淡化判据（zz_t2 探针）不受影响。
                         */
                      fade: _canUseTopBarBack
                          ? kAlwaysCompleteAnimation
                          : _controlsFade,
                      backArrowKey: _topBarBackKey,
                      /*
                         * ★★★ task-16（Owner：「全屏左上角这个单独的返回icon,
                         *     还没消失」）—— 悬浮键的**常驻**判据。
                         *
                         * 根因：悬浮键 opacity 原本恒为 `1 - f`，控制条一藏
                         * （f → 0）它就是 1 ⇒ 满不透明地常驻在左上角。
                         * 现在乘上「指针还在页内」这个因子（见 `_pointerInside`）。
                         *
                         * ⚠️ 这里传的是**整页级**的 `MouseRegion` 维护的那个值，
                         *    不是本按钮自己的矩形 —— 用户的本意是
                         *    「鼠标在画面上就该有返回口」。
                         */
                    ),

                    /*
                 * ── 直播"只有音频能播"的提示（用户报的黑屏）──
                 *
                 * 央视视频轨被 DRM 加密（ffmpeg 实测 386 条解码错误），
                 * 三条线路里只有「仅音频」能播 → 有声无画面。
                 *
                 * ★ 这条**不能**放进 `_error`：`_error` 的语义是"起播失败"，
                 *   而这里是"起播成功了，只是没有画面"。两者必须能并存 ——
                 *   否则用户要么看到黑屏没解释，要么被一个假错误挡住。
                 *
                 * 原版对应实现见 `PlayerView.vue:4281-4299`。
                 */
                    if (_liveAudioOnlyNotice != null)
                      _LiveAudioOnlyBanner(
                        lineName: _liveAudioOnlyNotice!,
                        onBack: () => unawaited(_exitPlayer()),
                      ),

                    /*
                 * ── 「画面出不来但音频正常」的提示 ──
                 *
                 * 由 `_watchVideoOutput()` 立旗（判据：有视频轨 &&
                 * `vo-configured != yes`，五臂实测见 `.probe\t376_matrix.txt`）。
                 * 与上面那条并列：都是"起播成功了，只是没有画面"，
                 * 都**不能**放进 `_error`（那会与"正在播放"互斥）。
                 */
                    if (_videoOutputDead)
                      _VideoOutputDeadBanner(
                        onBack: () => unawaited(_exitPlayer()),
                      ),

                    /*
                 * ── 「播放中断」的非阻断提示（★ 2026-10-08，Owner 第 9 条）──
                 *
                 * Owner 截图（u9_1c91d6a6.png）：
                 * ```text
                 * 播放失败
                 * Failed to open http://127.0.0.1:63534/s/18dc2c90fcf9b1f03f3446afdd80/.
                 * ```
                 * 这条来自 `_player.stream.error`，而 mpv **已经出过画面**
                 * 之后再来的错误多半是换流 / 重连 / 单帧解码失败 —— 可恢复抖动。
                 *
                 * 用全屏 `_ErrorOverlay` 处理它的后果：正在看的画面被整块盖掉，
                 * 用户以为"播放器崩了"，其实重试一下就好（Owner 就是这么报的）。
                 * ⇒ 与上面两条并列：**起播成功了，只是这一下断了**，
                 *   所以用同一种横幅形态，并且必须能一键重试。
                 */
                    if (_playbackFailure != null && _error == null)
                      _PlaybackFailureBanner(
                        message: _playbackFailure!,
                        onRetry: () => unawaited(_load()),
                      ),

                    // ── 下一集倒计时 ──
                    if (_nextCountdown > 0)
                      _NextCountdown(
                        seconds: _nextCountdown,
                        nextTitle: _nextEpisode?.title ?? '',
                        onPlayNow: () {
                          _cancelNextCountdown();
                          _gotoNextEpisode();
                        },
                        onCancel: _cancelNextCountdown,
                      ),

                    /*
                 * ══════════════════════════════════════════════════════════
                 * ★★★ 可见的左右圆圈按钮 —— **已移除**（2026-09-24 用户否决）
                 * ══════════════════════════════════════════════════════════
                 *
                 * 用户原话：
                 * > 不应该显示播放器两侧的按钮,识别手势就行了
                 * > 这两个圆圈太难看了
                 *
                 * # 这不是"推翻上一轮"，而是把两句话读全
                 *
                 * 上一轮用户说的是：
                 * > pc端更直觉的左右按钮 单点是快进快退(可配置)
                 * > 长按是倍速,右是快进倍速(可配置) 左是 快退(可配置)
                 *
                 * 我当时理解成"画两个圆圈按钮"，但用户真正要的是
                 * **"左/右两个区域的交互语义"**：
                 * ```text
                 * 左区域  单击 → 快退    长按 → 连续快退
                 * 右区域  单击 → 快进    长按 → 倍速快进
                 * ```
                 * 这两个区域**不需要可见的按钮** —— 用**手势识别**即可
                 * （就是原来的"双击左右侧"那套，只是改成了单击/长按）。
                 *
                 * ★ 教训：用户描述交互时说的"按钮"，可能指的是
                 *   **语义区域**而不是**可见控件**。做视觉之前该先问一句 ——
                 *   我直接画了控件，结果被否掉，白做一轮。
                 *
                 * # 现在的实现（见下面的 GestureDetector）
                 *
                 * ```text
                 * PC   左半屏：单击快退 / 长按连续快退
                 *      右半屏：单击快进 / 长按倍速
                 * 手机 双击左右侧快进快退 / 长按倍速（可配开关）
                 * ```
                 * 全部靠手势，画面上**没有任何常驻控件**。
                 */

                    // ── 底部控制条 ──
                    /*
                 * ⚠️ 选集面板打开时**藏起控制条**（照抄原版的三层 z-index）
                 *
                 * 原版 `PlayerView.vue` 的层序：
                 * ```text
                 * .player-controls    z-index 5
                 * .player-playlist     z-index 6   <- 选集面板
                 * .player-playlist__btn（控制条上的「选集」按钮）
                 * ```
                 * 也就是说原版的面板**盖在控制条之上**；而我们的面板是
                 * 全屏 `Positioned.fill` 的 scrim，如果控制条还画着，
                 * 它会浮在 scrim 上面 —— 点「选集」按钮等于**再次打开**
                 * （`_episodeSheetOpen = true`，视觉上毫无反应），
                 * 用户会以为按钮坏了。
                 *
                 * 藏掉之后语义反而更干净：面板开着 = 面板是唯一可交互的东西，
                 * 关掉（点背景 / 点 X / 遥控器返回）控制条按原逻辑回来。
                 */
                    /*
                         * ★★★ task-104：本条件的注释**全部上移到这里**（文字一字未改）
                         *
                         * 为什么必须搬：`test/t73_bili_wiring_test.dart` ② 与
                         * `test/t57_sheet_scrim_geometry_test.dart` 用的是**同一条**判据 ——
                         * 从 `_BottomBar(` **往回 600 字符**找那个 `if (`，并断言条件里含全部
                         * 7 个 `!_xSheetOpen`。注释原来夹在条件**中间**，实测（复刻
                         * `stripComments` 后测量）：
                         * ```text
                         * 改前：条件起点 "_controlsVisible" 在 _BottomBar( 前 **793** 字符处
                         *       ⇒ 超出 600 窗口 ⇒ before.lastIndexOf("if (") == **-1**
                         *       ⇒ t73 ② 报「找不到 if ( ⇒ 条件块已经长到 600 字符以外了」
                         * 改后：注释不参与条件长度 ⇒ 条件只剩 10 行代码（< 300 字符）
                         * ```
                         * ★ 判据一条没放松：t57 / t73 仍然钉着「往回 600 里必须有 if (，
                         *   且条件含全部 7 个标志」。
                         */
                    // ★ 设置面板同理（它是全屏 scrim，控制条浮在上面会点不动）
                    /*
                     * ★ task-13 ⑦ 弹幕设置面板同理（同一条规则）。
                     *
                     * 它也是 Positioned.fill 的全屏 scrim（与 PlayerSettingsSheet
                     * 同一个壳），漏掉这一项就会出现「弹幕面板开着，控制条浮在
                     * scrim 上面」⇒ 用户点「弹幕」按钮等于再打开一次，视觉上毫无
                     * 反应 —— 与上面 `!_episodeSheetOpen` 注释里记的是同一个坑。
                     */
                    // ★ task-31 ④⑤：两个新面板同理（都是全屏 scrim）
                    /*
                     * ★★★ task-57：所有直播面板同理（与上面四项并列）。
                     *
                     * ⚠️ 机制**不是**"全屏 scrim 挡住" —— `SheetTransition`
                     *    （`episode_strip.dart` L1164-1194）**不画任何东西**，
                     *    它只有 `Opacity` + `Transform.translate` + `IgnorePointer`。
                     *    所以"面板是 `Positioned.fill` 的 scrim"这个说法
                     *    **对线路/直播面板不成立**（只有选集/设置自带全屏遮罩）。
                     *
                     * 真机制是：面板**自身的有色区域**盖住了按钮，而
                     * `ColoredBox` 的渲染对象 `_RenderColoredBox` 继承
                     * `RenderProxyBoxWithHitTestBehavior`，其
                     * `HitTestBehavior.opaque` 是**写死的** ⇒ **吸收点击**。
                     *
                     * 实测（`test/t57_sheet_scrim_geometry_test.dart`，1280×800）：
                     * ```text
                     * 面板 = (920,48)-(1280,800)    ← 宽 360，右侧，全高
                     * 按钮 = (1153,736)-(1264,784)  ← 右下角「所有直播」
                     * ⇒ 水平覆盖 = true
                     * ⇒ 面板开着时点按钮中心 ⇒ 按钮回调 **0 次**（点不到）
                     * ⇒ 阳性对照（无面板）  ⇒ **1 次**（证明仪器有区分力）
                     * ⇒ 边界对照（底栏左半边）⇒ **1 次**（吸收是局部的）
                     * ```
                     * ⇒ 面板不画 ⇒ 那 360px 有色区域不存在 ⇒ 按钮恢复可点 ✓
                     *
                     * ⚠️ 已知边界（本次**未**改）：直播面板**没有**"点背景关闭"
                     *    （只有点 X / 遥控返回）—— 与选集面板不同，是既有行为。
                     */
                    /*
                     * ★★★ 2026-10-01：**降级横幅显示时不画控制条**（Owner 报「排版混乱」）
                     *
                     * # 症状（手机截图 `.probe\n16_player_scrolled.png`）
                     * ```text
                     * │ 1.0x ⟳换源 📺所有直播  ⛶  ⚙ │  ← 控制条（bottom: 0）
                     * │ ⚠ 这个视频的画面无法显示…  返回 │  ← ★ 横幅**也**是 bottom: 0
                     * └──────────────────────────────┘
                     * ```
                     * 两条都 `Positioned(bottom: 0)` 且是**同一个 `Stack` 的兄弟**
                     * ⇒ 后画的横幅**压在**控制条上 ⇒ 字叠字、按钮被盖住点不准。
                     *
                     * # 为什么"藏掉控制条"才是对的（而不是把横幅抬高）
                     * `_VideoOutputDeadBanner` / `_LiveAudioOnlyBanner` 的类文档
                     * 写得很明确：它们是**替代**控制条的降级提示
                     * （"起播成功了，只是没有画面"）。
                     * ⇒ 画面都出不来了，还摆一排「换源 / 全屏 / 设置」按钮
                     *   既没用又互相打架 ⇒ **语义上就该让位**。
                     * ★ 这与上面 `!_episodeSheetOpen && … && !_liveChannelsOpen`
                     *   是**同一条纪律**：谁占据了底部那块，谁就是唯一可交互的。
                     *
                     * ⚠️ 两条横幅各自都带「返回」按钮 ⇒ 用户**不会**因此出不去。
                     */
                    if (_controlsVisible &&
                        _error == null &&
                        !_episodeSheetOpen &&
                        !_streamSheetOpen &&
                        !_settingsOpen &&
                        !_danmakuSheetOpen &&
                        !_biliSheetOpen &&
                        !_subtitlePanelOpen &&
                        !_liveChannelsOpen &&
                        _liveAudioOnlyNotice == null &&
                        !_videoOutputDead)
                      _BottomBar(
                        playing: _playing,
                        positionNotifier: _positionNotifier,
                        duration: _duration,
                        isLive: _isLive,
                        rate: _rate,
                        volume: _volume,
                        muted: _muted,
                        fullscreen: _fullscreen,
                        onTogglePlay: _togglePlay,
                        onSeek: (d) {
                          if (!_isLive) _player.seek(d);
                        },
                        onVolume: (v) {
                          // ★ 用户拖底栏音量滑杆 —— 白名单（见 `_lastUserVolumeAction`）
                          _lastUserVolumeAction = DateTime.now();
                          /*
                           * ★★★ 缺陷 1 / 11：静音期间把滑杆拖到非零，必须同步快照
                           *
                           * ```text
                           * 为什么不能只靠音量监听器（上面那条 _muted 分支）？
                           *   用户拖到**与当前值相同的数**时，mpv 幂等、**不发**广播
                           *   => 监听器根本收不到这次动作 => 快照还是旧值
                           *   （这正是 _lastUserVolumeAction 用"时间窗"而不是"布尔"的理由）
                           * ⇒ 快照的更新必须有一条"即使无广播也能到达"的入口。
                           * ```
                           */
                          final next = v.clamp(0.0, 100.0);
                          if (_muted && next > 0) _volumeBeforeMute = next;
                          _sendVolume(next);
                        },
                        onToggleMute: _toggleMute,
                        onRate: (r) => _player.setRate(r),
                        onToggleFullscreen: _toggleFullscreen,
                        pipSupported: _pipSupported,
                        pipActive: _pipActive,
                        onTogglePip: _togglePip,
                        /*
                     * ★★★ task-2【④】用户第 15 条：「在非全屏状态下,选集的按钮不应该出现占位置」。
                     *
                     * 错在哪：这里原来只判 _episodes.length > 1 ⇒ 只要有多集就在底栏画
                     * 一枚「选集」。但**非全屏且右侧详情栏可见**时，详情栏里本来就有正常的
                     * 选集入口（detail_page.dart:2266 _bodyEpisodes），底栏那枚是重复入口。
                     *
                     * 为什么改这一个布尔就够：_BottomBar 里**三处**「选集」按钮
                     * （row / compactRow / row2 三个宽度档）**共用这一个 hasEpisodes**，
                     * 全部写成 if (hasEpisodes) TextButton.icon(... '选集' ...)
                     * ⇒ 改这一处 = 三处同时生效，**不需要**去动三处按钮本体。
                     *
                     * ★ 禁止写成「非全屏就隐藏」：判据是 widget.hasRightDetailBar
                     *   （= !fullscreen && wide，由 media_page.dart:729 单一数据源算得），
                     *   窄屏/全屏/历史记录 push 进来（默认 false）时**必须仍显示**。
                     */
                        hasEpisodes:
                            _episodes.length > 1 && !widget.hasRightDetailBar,
                        onEpisodes: () =>
                            setState(() => _episodeSheetOpen = true),
                        /*
                     * ★★★ task-53【③】「所有直播」入口（用户第 3 条）
                     *
                     * ```text
                     * 用户原话（逐字）：
                     * > 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
                     * ```
                     * # 为什么原来**没有**这个入口
                     * ```text
                     * 「选集」按钮的判据是 `_episodes.length > 1`，
                     * ★ 而直播时 `_episodes` **恒为空**（频道不是"剧集"）
                     *   ⇒ 按钮根本不显示 ⇒ 全屏直播播放页**没有任何方式**
                     *     打开频道列表。
                     * ```
                     * # 判据
                     * ```text
                     * `_isLive && widget.onLiveChannels != null`
                     * ★ 用**回调是否接线**当判据（与 #4b 的 `onLiveChannelStep`
                     *   同一手法）⇒ 没接线的调用点（测试/点播/回看）行为完全不变。
                     * ```
                     */
                        hasLiveChannels:
                            _isLive && widget.onLiveChannels != null,
                        onLiveChannels: _toggleLiveChannels,
                        liveChannelsOpen: _liveChannelsOpen,
                        hasStreams: _streams.length > 1,
                        onStreams: () =>
                            setState(() => _streamSheetOpen = true),
                        /*
                     * ★★ 上一集 / 下一集（本次补的缺口）
                     *
                     * 原版 `PlayerView.vue:4367-4392` 在 `metabar__acts` 里有
                     * 这两个按钮，而且**直播时整块不渲染** —— 原文注释：
                     * > 直播没有「上一集/下一集」概念。
                     * > 原来无脑渲染这两个按钮，直播时会显示成**两个灰掉的死按钮**
                     * > （实测截图里直播页出现「上一集 ⋯ 下一集」，很怪）
                     *
                     * 我们之前只有 `N` 快捷键与「下一集倒计时」，
                     * **没有可见的按钮** —— 鼠标用户根本发现不了这个能力。
                     * （证据：`_prevEpisode` 早就写好了却从没被引用过。）
                     *
                     * `hasEpisodes` 判据沿用原版：`prevEpisode` / `nextEpisode`
                     * 为空时按钮**禁用**（而不是隐藏）—— 用户在中间某一集时
                     * 两个按钮都在，只是到第一集时「上一集」变灰。
                     */
                        hasPrev: !_isLive && _prevEpisode != null,
                        hasNext: !_isLive && _nextEpisode != null,
                        showEpisodeNav: !_isLive && _episodes.isNotEmpty,
                        onPrev: () => unawaited(_gotoPrevEpisode()),
                        onNext: () => unawaited(_gotoNextEpisode()),
                        onSwitchSource: _openSwitchSource,
                        // ★ 直播不显示（原版 `openSkipDialog` 第一行就拦了）
                        onSkipMarkers: _isLive ? null : _openSkipDialog,
                        /*
                     * ★★★ 「设置」入口（本次新增）
                     *
                     * 原版这个入口是 ArtPlayer 内置的**齿轮**图标
                     * （`setting: true`，`PlayerView.vue:3436`）——
                     * 我们换成底部控制条上同一个位置的同语义按钮。
                     *
                     * ⚠️ 这是**交互差异**，单列在报告里：
                     * 原版打开的是 ArtPlayer 的面板（只有倍速/比例/镜像/清晰度），
                     * 我们打开的是自己的面板（字幕/音轨/连播）——
                     * 因为 ArtPlayer 那个面板里**没有**本次要补的能力。
                     */
                        onSettings: _openSettings,
                        // ★ task-21 P1-30：截图（相机按钮 / PC 键 S 的同一个落点）
                        onScreenshot: () => unawaited(_takeScreenshot()),
                        // ★★★ task-13 ⑦ 弹幕（用户原话：接入一下 dandanplay 的弹幕功能）
                        danmakuEnabled: _danmakuEnabled,
                        danmakuBusy: _danmakuLoading,
                        onDanmakuToggle: _toggleDanmaku,
                        onDanmakuSettings: _openDanmakuSettings,
                        /*
                     * ★★★ task-22 P1-5 / P1-11：画面缩放
                     *
                     * 短按 = 开/关那条滑动条，长按也开（用户原话是
                     * 「长按缩放按钮，拖动出现的滑动条」——但只认长按会
                     * 让鼠标用户以为按钮坏了，所以短按同样开）。
                     */
                        zoomOpen: _zoomOpen,
                        videoZoom: _videoZoomPct,
                        // ★ 宿主给的都是非空回调（:8488 传方法撕裂，:4071 传闭包，语义等价）；
                        //   「读不到就不让点」由面板侧的 onZoom == null 单独承担
                        onVideoZoom: _setVideoZoom,
                        onZoomToggle: () =>
                            setState(() => _zoomOpen = !_zoomOpen),
                        /*
                     * ★ task-32 ②：投屏。
                     *
                     * 没流时传空串 ⇒ `_BottomBar` **不画**这枚按钮
                     * （判据 `castUrl.isNotEmpty`）—— 比“画一枚能点、
                     * 点了只弹一句提示的按钮”更诚实（详见 _BottomBar
                     * 的 castUrl 文档）。
                     */
                        onCast: _openCast,
                        castUrl: _current?.url ?? '',
                        castHeaders:
                            _current?.httpHeaders ?? const <String, String>{},
                        castTitle: _castTitle,
                        /*
                     * ★ 2026-10-08（Owner 第 9 条）：底栏与顶栏**同一个**
                     *    `_controlsFade` 实例 ⇒ 两条一起淡出，
                     *    不会出现「顶栏没了、底栏还在」的半截状态。
                     */
                        fade: _controlsFade,
                        buffered: _isLive ? null : _bufferedRange,
                        bufferBarKey: _bufferBarKey,
                        /*
                     * ★★★ 2026-10-09（Owner 第 12 条）popover / 「更多」入口数据
                     */
                        popover: _popover,
                        streams: _streams,
                        currentStream: _current,
                        onPickStream: (s) => _startPlayback(s),
                        qualityOptions: _qualityPopoverOptions(),
                        onPickQuality: _pickQualityByLabel,
                        currentQuality:
                            _current?.label ?? _current?.quality ?? '',
                        trackGroups: _trackPopoverGroups(),
                        onPickTrack: _pickTrackFromPopover,
                        moreGroups: _moreMenuGroups(context),
                        onBuilt: (b) => _bottomBarWidget = b,
                      ),

                    /*
                     * ★ popover 层 —— 与 `_BottomBar` **兄弟**，挂在整屏这个
                     *   Stack 里。理由见 `buildPopoverLayer` 的长注释。
                     */
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: const EdgeInsets.only(
                            right: Sp.x2,
                            bottom: _kPlayerBottomBarHeight,
                          ),
                          child: ListenableBuilder(
                            listenable: _popover,
                            builder: (context, _) => buildPopoverLayer(),
                          ),
                        ),
                      ),
                    ),

                    // ── 提示气泡 ──
                    if (_tip != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 90,
                        child: Center(child: _TipBubble(text: _tip!)),
                      ),

                    // ── 快捷键提示 ──
                    if (_hintsOpen)
                      _HintsPanel(hints: hints, onClose: _toggleHints),

                    /*
                 * ── 播放设置面板（字幕 / 音轨 / 连播）──
                 *
                 * ★★★ task-25 D：**从「视频盒内」提升到 rootOverlay**
                 *
                 * 用户第②条原话：「有些设置都没适配安卓端，逐一重新校验，
                 * 逐一适配修复」。台账 `.probe/t24/AUDIT.md` 第 31 行记录：
                 * 真机上面板根节点是 [0,0][1080,608] ⇒ 只有 360×202.67dp
                 *（`.probe/t24/pan3.txt`）—— 因为改前这一行就挂在本文件的
                 *  Stack 里，而那个 Stack 的父盒**就是视频盒**。
                 * ⇒ 「片段下载」那一段被夹在折叠线以下，用户**滚都滚不到**。
                 *
                 * # 为什么必须是 `OverlayPortal` + **真的** `show()`
                 * ```text
                 * overlay.dart:2792-2796  _RenderDeferredLayoutBox.performLayout
                 *   deferredChild._doLayoutFrom(this,
                 *       constraints: BoxConstraints.tight(boxSize));
                 * ```
                 * ⇒ portal child 拿到的是 **theater（整个 Overlay = 整个窗口）
                 *   的 tight 约束**，面板里那句 `Positioned.fill` 这才真的等于
                 *   「铺满整页」（overlay.dart:2813-2823 的注释也明说它用的是
                 *   Stack 布局算法、「so developers can use the Positioned widget」）。
                 *
                 * ⚠️ 光在 `overlayChildBuilder` 里写 `if (_settingsOpen)` 是
                 *    **不够**的：`_zOrderIndex == null` 时 OverlayPortal 直接
                 *    `return _OverlayPortal(overlayLocation: null,
                 *     overlayChild: null, …)`（overlay.dart:2092-2098）
                 *    ⇒ 面板**永远不会出现**。两者缺一不可：
                 *      ① 常驻 OverlayPortal ② 事件回调里真的 show()/hide()
                 *
                 * # 层序（与改前一致）
                 * portal child 在 theater 里**先画、先命中**
                 * （overlay.dart:1427-1459 的 _childrenInPaintOrder /
                 *  _childrenInHitTestOrder 都先走 portal 的 iterator）
                 * ⇒ 仍然盖住控制条与其它浮层。
                 * ★ 而上面 `!... && !_settingsOpen && ...` 那条控制条判据照旧，
                 *   所以「面板开着时底栏不画」的观感与改前**完全一致**。
                 *
                 * ⚠️ `child:` 给 `SizedBox.shrink()` —— portal 自身不参与画面，
                 *    它的位置完全由 theater 决定（`_RenderLayoutSurrogateProxyBox`）。
                 */
                    OverlayPortal(
                      /*
                   * ★★ 必须给**常量** Key —— 这一行修的是「点设置面板没反应、
                   *    下面那栏再也不回来」（Owner 第 3 条）。
                   *
                   * 机制：本 Stack 的兄弟里**两侧都有条件子件**（上面 `if (_hintsOpen)`，
                   * 下面 `if (_danmakuSheetOpen)` / `if (_biliSheetOpen)` /
                   * `if (_subtitlePanelOpen)` / 选集 / 直播 / 线路 …）。Stack 的
                   * `updateChildren` 对**无 key** 子件用位置槽位（IndexedSlot）匹配 ⇒
                   * 任一侧开/关都会把这一格的 Element 判成「换了个 widget」而
                   * deactivate + inflate 重建。
                   *
                   * 重建时 controller 的可见状态**不跟随**（overlay.dart:1675-1684 逐字：
                   * 「When an [OverlayPortalController] is moved from one [OverlayPortal]
                   *  to another, its [isShowing] state does not carry over.」）：旧 State
                   * `dispose()` 把 `controller._attachTarget` 清成 null
                   * （overlay.dart:2060-2066），新 State 的 `_zOrderIndex` 初值是 null，
                   * 而 controller 自己那份 `_zOrderIndex` 早在旧 State 的
                   * `_setupController` 里被置 null 了（overlay.dart:2033）。
                   *
                   * 于是 —— 改前若镜像 bool 还是 true（面板开着时开了别的浮层，
                   * 或反过来），`_showSettingsPortal()` 会被
                   * `if (_settingsPortalShown) return;` 吞掉（那行已随镜像一起删除），
                   * 新 State 永远 `_zOrderIndex == null` ⇒ build 走
                   * `overlayLocation: null, overlayChild: null` 那条分支
                   * （overlay.dart:2092-2098）⇒ 面板永远画不出来；而底栏门控
                   * 里 `!_settingsOpen` 照旧成立 ⇒ 底栏也永远不回来。
                   * 且**不可自愈**：`_hideSettingsPortal()` 全文件只有 Esc 那一处调用，
                   * 面板不可见时用户不会去按 Esc。
                   *
                   * ⚠️ 必须写成 `const ValueKey<String>(…)`：若每次 build 新建一个 Key，
                   *    匹配永远失败，等于把这个 bug 变成**必现**。
                   */
                      key: const ValueKey<String>('player-settings-portal'),
                      controller: _settingsPortal,
                      /*
                   * ⚠️ 必须是 **rootOverlay**：播放页有两种宿主 ——
                   *    ① `lib/ui/media_page.dart` 内嵌（同一个 Overlay）
                   *    ② 独立播放路由（`Navigator` 推上来的整页）
                   *    「最近的 Overlay」在嵌套场景下可能是**别的路由**的，
                   *    那正是本条要修的「被夹在小盒子里」的同一种病。
                   */
                      overlayLocation: OverlayChildLocation.rootOverlay,
                      overlayChildBuilder: (ctx) => _buildSettingsPortalChild(ctx),
                      child: const SizedBox.shrink(),
                    ),
                    // ── 弹幕设置面板（「弹幕」齿轮 → task-13 ⑦）──
                    /*
                 * ⚠️ 与设置面板同一套规则：Positioned.fill 的全屏 scrim，
                 *    层序必须盖住控制条与其它浮层；Esc 分支里它排在
                 *    设置面板**之前** —— 两处必须一致。
                 */
                    /*
                 * ★★★ task-104：**退场也有动画**（用户第 7 条 · 第 7 条二期）
                 *
                 * ```text
                 * 改前：if (_danmakuSheetOpen) DanmakuSettingsDialog(...)
                 *       flag 翻 false 的那**一帧**子树就被移除 —— 一帧硬切，
                 *       "关"比"开"还生硬（入场在 task-99 已经做了）。
                 * 改后：SheetExitMotion 常挂、真源是 visible ⇒ 先淡出 260ms
                 *       （OverlayMotion.cardDuration）再卸载。
                 * ```
                 *
                 * ⚠️ 必须是**常挂**：写成 `if (_xOpen) SheetExitMotion(...)` 时
                 *    那个 Element 会被整个移除 ⇒ 框架走 deactivate/unmount、
                 *    **不会调 didUpdateWidget** ⇒ 没有 reverse、没有淡出，
                 *    与改前一模一样（理由逐字写在 SheetExitMotion 的类文档里）。
                 *
                 * ⚠️ 面板要传 `fill: false`：它原本的根节点是 `Positioned.fill`，
                 *    而 `Positioned` 只能做 `Stack` 的直接孩子；SheetExitMotion
                 *    中间夹了 Opacity / IgnorePointer（都产生 RenderObject）⇒
                 *    面板的父节点不再是 RenderStack ⇒ 会抛
                 *    `Incorrect use of ParentDataWidget`。
                 *    定位交给 SheetExitMotion 里那层 `Positioned.fill`。
                 */
                    Positioned.fill(
                      child: SheetExitMotion(
                        visible: _danmakuSheetOpen,
                        child: DanmakuSettingsDialog(
                          fill: false,
                          state: _danmakuSettings,
                          onSetEnabled: _setDanmakuEnabled,
                          onSetAppId: _setDanmakuAppId,
                          onSetAppSecret: _setDanmakuAppSecret,
                          onSetFontScale: _setDanmakuFontScale,
                          onSetOpacity: _setDanmakuOpacity,
                          onSetSpeed: _setDanmakuSpeed,
                          onSetArea: _setDanmakuArea,
                          onClearCredentials: _clearDanmakuCredentials,
                          onReload: _reloadDanmaku,
                          onOpenBili: _openBiliSheet,
                          onHintAction: _runDanmakuHintAction,
                          /*
                           * ★ 2026-10-09：屏蔽词 / 分类开关改了就重建播放页 ——
                           *   过滤发生在 danmaku_overlay 的排版那一层，
                           *   重建后 `_ensureLayout` 会用新规则重排（旧布局被 key 判为过期）。
                           *   `_danmakuComments` **不动**：屏蔽只影响"画什么"，
                           *   不影响"有几条"（面板读数才不会撒谎）。
                           */
                          onChanged: () {
                            if (mounted) setState(() {});
                          },
                          onClose: () =>
                              setState(() => _danmakuSheetOpen = false),
                        ),
                      ),
                    ),

                    /*
                 * ── 哔哩哔哩弹幕导入面板（task-31 ④）──
                 *
                 * ⚠️ 与上面两个面板同一套规则：`Positioned.fill` 的全屏 scrim，
                 *    层序必须盖住控制条与其它浮层；Esc 分支里它排在**弹幕设置
                 *    面板之前** —— 两处必须一致（施工单 §3.2 的第 ③④ 条）。
                 *
                 * ★ 它从 `DanmakuSettingsDialog` 的「哔哩哔哩弹幕…」按钮打开，
                 *   所以打开时弹幕面板会被关掉（见 `_openBiliSheet` 的调用点）——
                 *   同一时刻只留一个 scrim，层序才不会有歧义。
                 */
                    Positioned.fill(
                      child: SheetExitMotion(
                        visible: _biliSheetOpen,
                        child: BiliImportDialog(
                          fill: false,
                          state: _biliState,
                          onImport: _biliImport,
                          onSearch: _biliSearch,
                          onSelectPage: _biliSelectPage,
                          onSetAutoUpdate: _biliSetAutoUpdate,
                          onSetInterval: _biliSetInterval,
                          onUpdateNow: _biliUpdateNow,
                          onUnbind: _biliUnbind,
                          onClose: () => setState(() => _biliSheetOpen = false),
                        ),
                      ),
                    ),

                    /*
                 * ── 在线搜索字幕面板（assrt.net，task-31 ⑤）──
                 *
                 * ⚠️ 同样挂在这一层（全屏 scrim）。
                 *
                 * ★ `onMount` 就是**一行**：把下载好的字幕文件路径交给播放页
                 *   已有的 `_loadExternalSubtitle` —— 不新写一套加载逻辑
                 *   （施工单 §1 原话）。`SubtitleFileRef.path` 就是 mpv 要的路径。
                 *
                 * ⚠️ assrt.net 的署名由面板内部的 `SubtitleConfig.showAttribution`
                 *   控制，**别在这里改文案**（官方文档要求署名）。
                 */
                    Positioned.fill(
                      child: SheetExitMotion(
                        visible: _subtitlePanelOpen,
                        child: SubtitlePanel(
                          fill: false,
                          onClose: () =>
                              setState(() => _subtitlePanelOpen = false),
                          // ★ task-31 ⑤：唯一的 SubtitlePanel 挂载点
                          videoTitle: widget.title,
                          episodeTitle: _currentEpisodeTitle ?? '',
                          videoUrl: _current?.url ?? '',
                          onMount: (file) =>
                              unawaited(_loadExternalSubtitle(file.path)),
                        ),
                      ),
                    ),

                    // ── 选集面板（「选集」按钮 → 按端分流的面板）──
                    /*
                 * ⚠️ 分流在 `EpisodePanel` **内部**做（不在调用点）——
                 *    形态由 `Device.isDesktop` 这类**能力检测**决定，
                 *    调用方不该重复这套判据（重复 = 两处会漂移）。
                 *
                 * ```text
                 * 桌面      限高二维网格 + 内部纵向滚动（抄腾讯 PC 播放页）
                 * 手机 / TV 横向一行 + 超 20 集出箭头 → 箭头 → 底部弹出完整面板
                 * ```
                 * 见 `episode_strip.dart` 文件头的三端对比表。
                 */
                    /*
                 * ── 选集面板（task-28 ①-A：关闭也要有动画）──
                 *
                 * # 用户原话
                 * > 选集弹窗**关闭的时候没有动画效果**
                 *
                 * # 为什么原来关闭没动画
                 *
                 * 原来是 `if (_episodeSheetOpen) Positioned.fill(...)` ——
                 * `_episodeSheetOpen = false` 时**整个子树被直接移除**，
                 * 没有任何机会跑动画（进入动画在 `EpisodeSheet` 内部，
                 * 只在首次挂载时跑一次）。
                 *
                 * ⇒ 现在用 `SheetTransition` 包一层：它多提供一个
                 *   **"正在离开"** 的状态 —— `visible: false` 时子组件
                 *   继续留在树上，由宿主驱动滑出 + 淡出，动画跑完才卸载。
                 *
                 * ⚠️ `slideFrom` 的方向必须与**进入方向一致**：
                 *   ```text
                 *   PC   右侧抽屉 → Offset(24, 0)  往右滑出
                 *   手机/TV 底部抽屉 → Offset(0, 24) 往下滑出
                 *   ```
                 *   方向反了会像"东西被甩飞"。
                 */
                    Positioned.fill(
                      child: SheetTransition(
                        visible: _episodeSheetOpen,
                        // ★ 2026-10-09（Owner 第 12 条）：形态按**面板几何**定，
                        //   不再按 `Device.isDesktop` 分叉 ——
                        //   桌面/手机横屏都是右侧轻量侧栏，只有竖屏是底部面板。
                        slideFrom: _episodePanelIsDrawer(context)
                            ? const Offset(24, 0)
                            : const Offset(0, 24),
                        child: _episodePanelIsDrawer(context)
                            ? Align(
                                alignment: Alignment.centerRight,
                                child: PlayerEpisodePanel(
                                  episodes: _episodes,
                                  currentIndex: _epIndex,
                                  onPick: _gotoEpisode,
                                  onClose: () =>
                                      setState(() => _episodeSheetOpen = false),
                                  style: PlayerEpisodePanelStyle.rightDrawer,
                                ),
                              )
                            : Align(
                                alignment: Alignment.bottomCenter,
                                child: PlayerEpisodePanel(
                                  episodes: _episodes,
                                  currentIndex: _epIndex,
                                  onPick: _gotoEpisode,
                                  onClose: () =>
                                      setState(() => _episodeSheetOpen = false),
                                  style: PlayerEpisodePanelStyle.bottomSheet,
                                ),
                              ),
                      ),
                    ),

                    /*
                 * ★★★ task-53【③】「所有直播」频道列表面板（用户第 3 条）
                 *
                 * ```text
                 * 用户原话（逐字）：
                 * > 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
                 * ```
                 *
                 * # 形态与选集面板**一致**（用户说的就是"就跟选集一样"）
                 * ```text
                 * · 同一个 `SheetTransition`（关闭也有动画，task-28 ①-A 的成果）
                 * · 同一个 `PlayerPanelTheme`（深色皮肤，①-B）
                 * · 同一个滑出方向（PC 右抽屉 / 手机·TV 底部）
                 * ⇒ 用户不会觉得"直播的列表和选集长得不一样"。
                 * ```
                 *
                 * # ★ 为什么**不**复用 `EpisodePanel`
                 * ```text
                 * lead 建议把频道列表喂给 `EpisodePanel`（它接受 `List<Episode>`）。
                 * ★ 否掉它的理由（不是"麻烦"，是**语义错位**）：
                 *   ① `EpisodePanel` 内部有「选集条 + 箭头 → 完整面板」的**两层**
                 *      手机/TV 形态，还有 `chunkSize` 分卷、`_epOrder` 解析集数
                 *      （`第 N 集` 正则）—— 这些对**频道**全都没有意义。
                 *   ② 要把 `LiveChannel` 塞进 `Episode`，得**伪造** `id/title/index`
                 *      ⇒ 一旦将来 `Episode` 加字段（比如 `isVip`），
                 *        这个伪造层就会静默错位。
                 *   ③ ★ 最硬的理由：频道需要**分组显示**（`LiveChannel.group`，
                 *      如「央视」「卫视」）—— 而 `EpisodePanel` 是按**集数**分卷的，
                 *      两者分组语义不同，硬套会让"央视"变成一个"卷"。
                 * ⇒ 用一个**同款式但独立**的面板（`_LiveChannelsSheet`），
                 *   共享受众能感知的部分（动画/皮肤/布局），不共享内部语义。
                 * ```
                 *
                 * ⚠️ 只在直播时才可能有内容 —— 非直播 `onLiveChannels == null`
                 *   ⇒ `_liveChannels()` 返回 null ⇒ 面板渲染成"没有频道"。
                 *   但按钮那时也不显示 ⇒ 用户根本打不开它。
                 */
                    Positioned.fill(
                      child: SheetTransition(
                        visible: _liveChannelsOpen,
                        /*
                     * ★★★ task-74【④】方向修正（与「线路」面板同一处 bug）
                     *
                     * 原来这里也是 `Device.isDesktop ? (24,0) : (0,24)`。
                     * `_LiveChannelsSheet.build`（本文件 `:9308-9311`）是
                     * `Align(centerRight)` + `maxWidth 360`，**无条件** ——
                     * 没有任何 `Device` 分支 ⇒ **三端都是右侧抽屉**。
                     *
                     * ⇒ 判据「`slideFrom` 必须等于面板的**实际几何**」：
                     *   几何恒定 ⇒ 写成**常量**（不是三元）。
                     * ```text
                     * 桌面   ：(24,0) → (24,0)  ★ 行为逐字不变（零风险）
                     * 手机/TV：原 (0,24) 是错的（右侧面板往下滑）→ 修成 (24,0)
                     * ```
                     * ⚠️ 如实标注：手机/TV 那一支我**无法实测**
                     *   （`Device._detect()` 第一句就是
                     *   `if (!Platform.isAndroid) return DeviceKind.desktop;`
                     *   ⇒ 本机跑不到）。但这里的改动**不依赖实测**：
                     *   面板几何是**无条件**的，常量是它的直接推论；
                     *   且桌面分支的取值前后相同 ⇒ 不可能引入回归。
                     */
                        slideFrom: const Offset(24, 0),
                        child: PlayerPanelTheme(
                          // ★ task-72【②】点面板外的空白处 ⇒ 关闭抽屉
                          //   没有这层屏障时，左边剩下的
                          //   （1280−360=920px）是"没有 widget 的空白"
                          //   ⇒ 点击**穿透**到下层播放器/底栏（Owner 原话
                          //   「点击空白处应该是就关闭,而不是透层点击」）。
                          //
                          //   ★★ 必须放在 `SheetTransition` **内部**：
                          //      `visible:false` 且退出动画跑完时它
                          //      `if (!_mounted) return const SizedBox.shrink();`
                          //      ⇒ 整棵子树（含屏障）不在树上。
                          //      若把屏障套在 `SheetTransition` 外面，
                          //      抽屉关闭后它仍会吸收全屏点击
                          //      ⇒ **播放器彻底点不动**（比原 bug 更糟）。
                          child: _SheetScrim(
                            onClose: () =>
                                setState(() => _liveChannelsOpen = false),
                            child: _LiveChannelsSheet(
                              // ★ task-72【④】抽屉**关着**时不要现取列表
                              //
                              // 实测（`.probe/probe_tests/t72_jank_probe_test.dart`
                              // 的 PC 组）：整页重建 N 次 ⇒ `onLiveChannels()`
                              // 被调 **N 次** —— 与抽屉开没开**无关**。
                              //
                              // 代价：每次都走
                              // `live_page.dart:1299 channelsForFullscreen()`
                              // → `_visibleChannels` → 每频道一次
                              // `live_availability.dart:149 cached()`
                              //（字符串拼接 + Map 查 + `DateTime.now()`）。
                              //
                              // ⚠️ 这**不是**"缓存" —— `player_page.dart:4240-4245`
                              //   明确否掉过缓存（频道列表会变，缓存会显示过期的台）。
                              //   这里只是在**用不到**的时候**不查**：
                              //   抽屉关着 ⇒ `_LiveChannelsSheet` 根本不会挂载
                              //  （`SheetTransition` 的 `_mounted` 守卫，
                              //   `lib/ui/widgets/episode_strip.dart:1167`）
                              //   ⇒ 传进去也没人看。
                              data: _liveChannelsForSheet(),
                              onPick: _pickLiveChannel,
                              onClose: () =>
                                  setState(() => _liveChannelsOpen = false),
                            ),
                          ),
                        ),
                      ),
                    ),

                    // ── 线路面板（同样走 SheetTransition + 深色皮肤）──
                    /*
                 * ★★★ task-74【④】滑出方向修正（用户第 4 条）
                 *
                 * ──────────────────────────────────────────────────────
                 * 用户原话（逐字）
                 * ──────────────────────────────────────────────────────
                 * > 线路,出来的弹窗是从上往下出现的,这是错误的,请修复
                 *
                 * ──────────────────────────────────────────────────────
                 * 根因：这里是**唯一**一个硬编码方向的 `SheetTransition`
                 * ──────────────────────────────────────────────────────
                 * 全项目 `slideFrom` 共 5 处赋值（grep 实测）：
                 * ```text
                 * live_page.dart:1877     Device.isDesktop ? (24,0) : (0,24)
                 * player_page.dart:7148   Device.isDesktop ? (24,0) : (0,24)   ← 选集
                 * player_page.dart:7204   Device.isDesktop ? (24,0) : (0,24)   ← 直播
                 * player_page.dart:7258   const (0, 24)                        ← ★ 本处
                 * episode_strip.dart:1089 默认值 (24,0)
                 * ```
                 * ⇒ 只有**线路面板**被写成了常量，且是**竖向**的。
                 *
                 * ──────────────────────────────────────────────────────
                 * 为什么 (0,24) 对它是错的：面板贴**右**边，不是底部
                 * ──────────────────────────────────────────────────────
                 * `_StreamSheet.build`（本文件 `:9028-9031`）：
                 * ```dart
                 * return Align(
                 *   alignment: Alignment.centerRight,   // ★ 右侧，且**没有**
                 *   child: SizedBox(width: 320, ...),   //   Device 分支 ⇒
                 * );                                    //   三端都是右侧抽屉
                 * ```
                 * 而 `SheetTransition` 的契约（`episode_strip.dart:1105-1106`
                 * 逐字）是：
                 * > ★ 必须与面板的**进入方向**一致 —— 否则"从右边进来、
                 * >   往下面出去"会让用户觉得东西被甩飞了。
                 * ⇒ 面板在右侧、却往下滑 = **正是这条契约禁止的形态**，
                 *   也正是用户说的"从上往下"。
                 *
                 * ⚠️ 这段注释的来历（★ 一个值得记下来的坑）：
                 *   旧代码在 `:9165-9170` 写过「这与 `_StreamSheet` **现状
                 *   完全相同**（不是本任务引入的）」—— 那句话把"手机端
                 *   `slideFrom` 是 (0,24)"当成了 `_StreamSheet` 的**常态**，
                 *   于是这个常量看起来"有理由"。但那个理由只对**手机**
                 *   成立（而手机端的面板同样贴右边 ⇒ 理由本身也是错的）。
                 *   ★ 教训：**"别人也这样"不是理由**，方向必须由**几何**
                 *     决定（面板在哪一侧），不能由"别处怎么写"决定。
                 *
                 * ──────────────────────────────────────────────────────
                 * 改法：**常量** `(24, 0)` —— 由几何决定，不跟 `Device` 走
                 * ──────────────────────────────────────────────────────
                 * ★ 为什么不写成 `Device.isDesktop ? (24,0) : (0,24)`
                 *   （即"照抄两个兄弟面板"）—— 因为那样在手机/TV 上
                 *   **仍然是错的**：
                 * ```text
                 * `_StreamSheet.build` 是 `Align(centerRight)` **无条件**的
                 *   ⇒ 三端都是**右侧**抽屉 ⇒ 三端都必须往右滑出。
                 * 而 `Device.isDesktop` 在 Android 上是 false
                 *   ⇒ 抄过来的话手机端拿到的是 `(0,24)`
                 *   ⇒ 同一个 bug 原样保留，只是换了个平台。
                 * ```
                 * ★ 兄弟面板为什么是**分端**的：它们的分支来自**真实几何** ——
                 *   `EpisodePanel` 有 `EpisodePanelStyle.rightDrawer` 与底部
                 *   两种形态（`episode_strip.dart:1798` 的 `isDrawer`），
                 *   调用方按端选；而 `_StreamSheet` **没有**这种分支。
                 * ⇒ 统一判据：**`slideFrom` 必须等于面板的实际几何**。
                 *   几何分端 ⇒ 写成三元；几何恒定 ⇒ 写成常量。本面板是后者。
                 *
                 * ★ 历史（解释了这里**为什么**原本就是个常量）：
                 *   这个常量**原本是对的** —— 那时 `_StreamSheet` 是
                 *   `Positioned(bottom: 0)`（**底部**抽屉；见 task-70 注释
                 *   `:9085-9092` 的"修复前 (0,0)-(1280,800) / 修复后
                 *   (576,0)-(896,760)"读数），底部抽屉配 `(0,24)` 完全正确。
                 *   task-70 把它改成 `Align(centerRight)` 之后，
                 *   **几何变了、常量没跟着变** ⇒ 这才产生了 ④ 这个 bug。
                 *   ⇒ 正确动作是**改常量的值**，不是把它变成分端表达式。
                 *   （旧的静态字符串测试也停在"底部抽屉"那个前提上 ⇒
                 *     它反过来把 bug 钉成了契约，见 `test/`
                 *     `player_panel_wiring_test.dart` 的「坑 4」。）
                 */
                    Positioned.fill(
                      child: SheetTransition(
                        visible: _streamSheetOpen,
                        slideFrom: const Offset(24, 0),
                        child: PlayerPanelTheme(
                          // ★ task-72【②】同上：点面板外空白 ⇒ 关闭线路抽屉
                          //   左边剩下 1280−320=960px 的空白，原本点击会
                          //   穿透到下层。两个抽屉**一起**加屏障 —— 否则
                          //   一个能关一个不能，看起来更像坏了。
                          child: _SheetScrim(
                            onClose: () =>
                                setState(() => _streamSheetOpen = false),
                            child: _StreamSheet(
                              streams: _streams,
                              current: _current,
                              onPick: (s) {
                                setState(() => _streamSheetOpen = false);
                                _startPlayback(s);
                              },
                              onClose: () =>
                                  setState(() => _streamSheetOpen = false),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  子组件
// ═══════════════════════════════════════════════════════════════════════

class _LoadingOverlay extends StatelessWidget {
  const _LoadingOverlay();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Colors.black54,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: Sp.x4),
          Text('正在加载…', style: TextStyle(color: Colors.white)),
        ],
      ),
    ),
  );
}

class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({
    required this.message,
    required this.onRetry,
    required this.onBack,
    this.onLogin,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  /// ★ 非 null = 这次失败**确实是登录问题**，显示「登录」按钮
  ///
  /// 由调用方（`_PlayerPageState`）判定后传入，**不在这里猜** ——
  /// 这个 Widget 是纯展示的，判据属于业务逻辑。
  /// 见 `_isAuthError` 的说明。
  final VoidCallback? onLogin;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black87,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.white70),
            const SizedBox(height: Sp.x4),
            const Text(
              '播放失败',
              style: TextStyle(
                color: Colors.white,
                fontSize: FontSizes.base,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Sp.x2),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: FontSizes.sm,
              ),
            ),
            const SizedBox(height: Sp.x6),
            /*
                 * ★ 「登录」按钮（2026-09-24 用户要求）
                 *
                 * 放在「重试」**左边**、用 FilledButton 与「重试」同级：
                 * 用户的处境是「登录失效了，重试多少次都一样」，
                 * 所以登录才是那个真正能解决问题的动作，不该被藏起来。
                 *
                 * ⚠️ 只在 `onLogin != null` 时渲染 —— 无条件显示会让
                 *    「该内容没有可播放的地址」这类用户也看到一个登录按钮。
                 */
            if (onLogin != null) ...[
              FilledButton.icon(
                onPressed: onLogin,
                icon: const Icon(Icons.login, size: 18),
                label: const Text('登录'),
              ),
              const SizedBox(height: Sp.x3),
            ],
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(onPressed: onBack, child: const Text('返回')),
                const SizedBox(width: Sp.x3),
                FilledButton(onPressed: onRetry, child: const Text('重试')),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// 直播"只有音频线路能播"的**非阻断**提示
///
/// # 它解决的是用户原话「cctv看得到但是点开黑屏」
///
/// 央视直播的视频轨被 DRM 加密 —— 这不是我们的 bug，是内容方的保护。
/// 独立实测（ffmpeg，与 mpv 不同解码器）：
/// ```text
/// 高清线：250 帧 / 386 条解码错误
///         [h264] error while decoding MB 9 0, bytestream 42177
///         [dec] corrupt decoded frame
///         [h264] Reference 3 >= 3
/// 音频线：Stream #0:0: Audio: aac …   ← 根本没有 video 流
/// ```
/// 三条线路里只有音频能播，于是播放器**正常**打开音频流 →
/// 用户**听到声音、看到黑屏**。
///
/// # 为什么必须显示（而不是让它静默播）
///
/// 原版注释把这件事说得很清楚（`PlayerView.vue:1530-1534`）：
/// > **为什么不能让它照常播放**：那样用户看到的是「画面绿屏但时间在走」，
/// > 完全不知道发生了什么，只会以为是客户端坏了。明确告知才是诚实的做法。
///
/// 原版对应 UI 见 `PlayerView.vue:4281-4299`。
///
/// # 设计取舍
///
/// ```text
/// ① 非阻断 —— 不盖住画面中央，只占底部一条横幅：
///    音频本身是可用的（听广播），不该把用户拦在门外。
/// ② 不给"重试" —— 重试改变不了 DRM，给了只会误导用户反复点。
///    只给「返回」（去换别的源）。
/// ③ 与 `_ErrorOverlay` 分开 —— 那是"起播失败"，
///    这里是"起播成功但没有画面"，语义不同，不能混用一个字段。
/// ```
class _LiveAudioOnlyBanner extends StatelessWidget {
  const _LiveAudioOnlyBanner({required this.lineName, required this.onBack});

  /// 正在播的那条音频线路名（如「仅音频」）
  final String lineName;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: ColoredBox(
      color: Colors.black87,
      child: Padding(
        /*
             * ★★★ 2026-10-01：让开系统导航栏（Owner 报「排版混乱」）
             *
             * 实测（`dumpsys window displays`，手机 1080x2400 @420dpi）：
             * ```text
             * InsetsSource type=navigationBars frame=[0,2274][1080,2400]
             *   ⇒ 126 / 2.625 = 48 逻辑 px
             * ```
             * 本条是**贴在屏幕最底**的横条 ⇒ 导航栏会盖住它的下半截
             *（截图 `.probe\n13_player_controls.png` 里「返回」按钮只露出上半）。
             *
             * ★ 与 `_BottomBar` 的修复**同一手法、同一理由**（见那里的长注释）：
             *   播放页是沉浸式的，**不能**给整页包 `SafeArea`（会把画面缩小）；
             *   只有浮在画面上的控件条需要让位 —— 本条就是其中之一。
             *
             * ⚠️ `bottom: 0` **保持不变** —— "压在最底"是它的设计意图
             *   （它是**替代**控制条的降级提示）。要修的只是别被导航栏盖住。
             * ⚠️ 桌面/TV 上 `padding.bottom == 0` ⇒ **严格 no-op**。
             */
        padding: EdgeInsets.fromLTRB(
          Sp.x4,
          Sp.x3,
          Sp.x4,
          Sp.x3 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 18, color: Colors.white70),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Text(
                '该直播的视频轨受 DRM 加密，客户端无法解码画面。'
                '已为你切换到「$lineName」线路收听。',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: FontSizes.sm,
                ),
              ),
            ),
            const SizedBox(width: Sp.x3),
            OutlinedButton(onPressed: onBack, child: const Text('返回')),
          ],
        ),
      ),
    ),
  );
}

/// 「画面出不来，但音频是好的」的非阻断横幅
///
/// # 补的是什么
///
/// 交付说明 `README-交付说明.md:126-129` 自己承认过：
/// > 输出层建不起来时没有任何降级、也没有用户可见的报错，全程静默
///
/// 触发它的是 [`PlayerPage._watchVideoOutput`] 的判据
/// （有视频轨 && `vo-configured != yes`，五臂实测见 `.probe\t376_matrix.txt`）。
///
/// # 设计取舍（照 `_LiveAudioOnlyBanner` 的三条，理由同源）
///
/// ```text
/// ① 非阻断 —— 音频是好的（能听），不该把用户拦在门外，所以只占底部一条。
/// ② 不给"重试" —— 同族实测换 VO 也救不回来（`opengl-es=no` 一样失败），
///    给了只会让用户反复点。只给「返回」（去换别的源/线路）。
/// ③ 与 `_ErrorOverlay` 分开 —— 那是"起播失败"，这里是
///    "起播成功了但没有画面"，两者必须能并存。
/// ```
///
/// ★ 文案刻意说清**是什么坏了**（显卡/输出层）而不是"播放失败" ——
///   用户看到的是"有声无画"，含糊的报错只会让他以为是网络问题。
class _VideoOutputDeadBanner extends StatelessWidget {
  const _VideoOutputDeadBanner({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: ColoredBox(
      color: Colors.black87,
      child: Padding(
        /*
             * ★★★ 2026-10-01：让开系统导航栏（Owner 报「排版混乱」）
             *
             * 实测（`dumpsys window displays`，手机 1080x2400 @420dpi）：
             * ```text
             * InsetsSource type=navigationBars frame=[0,2274][1080,2400]
             *   ⇒ 126 / 2.625 = 48 逻辑 px
             * ```
             * 本条是**贴在屏幕最底**的横条 ⇒ 导航栏会盖住它的下半截
             *（截图 `.probe\n13_player_controls.png` 里「返回」按钮只露出上半）。
             *
             * ★ 与 `_BottomBar` 的修复**同一手法、同一理由**（见那里的长注释）：
             *   播放页是沉浸式的，**不能**给整页包 `SafeArea`（会把画面缩小）；
             *   只有浮在画面上的控件条需要让位 —— 本条就是其中之一。
             *
             * ⚠️ `bottom: 0` **保持不变** —— "压在最底"是它的设计意图
             *   （它是**替代**控制条的降级提示）。要修的只是别被导航栏盖住。
             * ⚠️ 桌面/TV 上 `padding.bottom == 0` ⇒ **严格 no-op**。
             */
        padding: EdgeInsets.fromLTRB(
          Sp.x4,
          Sp.x3,
          Sp.x4,
          Sp.x3 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Row(
          children: [
            const Icon(
              Icons.warning_amber_outlined,
              size: 18,
              color: Colors.white70,
            ),
            const SizedBox(width: Sp.x2),
            const Expanded(
              child: Text(
                '这个视频的画面无法显示（本机图形输出层没能初始化）。'
                '声音是正常的。可以返回换一条线路或换一个源再试。',
                style: TextStyle(color: Colors.white70, fontSize: FontSizes.sm),
              ),
            ),
            const SizedBox(width: Sp.x3),
            OutlinedButton(onPressed: onBack, child: const Text('返回')),
          ],
        ),
      ),
    ),
  );
}

/// 「播放中断」的非阻断横幅（★ 2026-10-08，Owner 第 9 条）
///
/// # 补的是什么
///
/// Owner 截图（u9_1c91d6a6.png）：
/// \`\`\`text
/// 播放失败
/// Failed to open http://127.0.0.1:63534/s/18dc2c90fcf9b1f03f3446afdd80/.
/// \`\`\`
/// 原文来自 \`_player.stream.error\`，而那时 mpv **已经出过画面**
/// （判据 \`_sawFirstFrame\`，见 [PlayerPage._sawFirstFrame]）。
///
/// # 为什么不能继续用全屏 \`_ErrorOverlay\`
///
/// \`\`\`text
/// \`stream.error\` 在**整个生命周期**里都会来，不只是起播那一次：
///   换清晰度重开 / 缓冲重试 / 单帧解码报错 → 都会发一条
/// 用全屏遮罩接住它 ⇒ 正在看的画面被整块盖掉，
/// 用户看到的就是「看着看着突然播放失败」（Owner 的原话就是这个观感）。
/// \`\`\`
/// 起播阶段（没出过画面）仍然走全屏 \`_ErrorOverlay\` —— 那时用户什么都
/// 没看到，必须给他一个明确的解释和出口。**两条路的分界线就是"有没有画面"**。
///
/// # 设计取舍（与上面两条横幅同源）
///
/// \`\`\`text
/// ① 非阻断 —— 只占底部一条，画面继续，用户可以自己决定要不要管它。
/// ② **给"重试"** —— 与 [_VideoOutputDeadBanner] 不同：这条的失败原因
///    （换流抖动 / 代理刚重启 / 上游 4xx）**是可以靠重试恢复的**，
///    而输出层建不起来重试多少次都一样。
/// ③ 与 \`_ErrorOverlay\` 分开 —— 那是"起播失败"，
///    这里是"起播成功了，只是这一下断了"，两者必须能并存。
/// \`\`\`
///
/// ★ 文案**照抄 mpv 原文**（不做翻译/改写）：这条错误的诊断价值全在
///   那个地址和 mpv 的原句上（"Failed to open <url>" 能一眼看出是本地代理
///   还是上游 CDN），改写反而会把线索弄丢。中文只在前面加一句人话。
class _PlaybackFailureBanner extends StatelessWidget {
  const _PlaybackFailureBanner({required this.message, required this.onRetry});

  /// mpv 的原始错误文案（照抄，不改写）
  final String message;

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: ColoredBox(
      color: Colors.black87,
      child: Padding(
        // ★ 与 [_VideoOutputDeadBanner] 同一手法：让开系统导航栏
        //   （理由与实测见那里的长注释；桌面/TV 上是严格 no-op）
        padding: EdgeInsets.fromLTRB(
          Sp.x4,
          Sp.x3,
          Sp.x4,
          Sp.x3 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 18, color: Colors.white70),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '播放中断了（画面还在，可以重试）',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: FontSizes.sm,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    message,
                    // ★ 原文可能很长（带完整 URL）⇒ 最多两行 + 省略号，
                    //   免得把横幅撑成半屏
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: FontSizes.cap,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Sp.x3),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    ),
  );
}

/// 交付实测用：读**真实渲染树**里播放器手势的挂载状态
///
/// # 为什么要读树而不是读源码
///
/// 用户要求「pc端不应该双击左右侧快进快退」——
/// 源码里写了条件挂载（`onDoubleTapDown: _doubleTapEnabled ? ... : null`）
/// **不等于**运行时那个 GestureDetector 真的没挂上回调。
///
/// `GestureDetector.onDoubleTapDown` 是只读字段，直接读它就知道
/// "用户在这台机器上双击会不会跳秒" —— 这是最接近真实行为的验证。
///
/// 返回形如 `doubleTap=true longPress=true tapUp=false visibleButtons=0`。
///
/// # ★ `tapUp` 字段的含义在 2026-09-25 变了
///
/// 它原来是"**单击分流已挂载**"的证据（PC 上应为 true）。
/// 用户要求「不要单击快进快退,去掉这个功能」之后，单击分流**整个删掉**，
/// 所以现在 `tapUp=false` 才是**正确**的：
/// ```text
/// tapUp=false  → 渲染树里没有任何 GestureDetector 自己判区域分流单击
/// tapUp=true   → 有人把分流加回来了（**回归**）
/// ```
/// ⚠️ 断言方向**反了** —— 从 `tapUp=true` 改成 `tapUp=false`。
///    这不是"为了让实测通过而放宽断言"，是需求变了：
///    新的正确行为就是"没有分流"。
String debugPlayerGestureState() {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return 'no-root';

  var doubleTap = false;
  var longPress = false;
  var tapUp = false;
  var tap = false;
  var visibleButtons = 0;
  var visited = 0;

  void walk(Element el) {
    if (visited > 6000) return;
    visited++;
    final w = el.widget;
    if (w is GestureDetector) {
      if (w.onDoubleTapDown != null) doubleTap = true;
      if (w.onLongPressStart != null) longPress = true;
      if (w.onTapUp != null) tapUp = true;
      if (w.onTap != null) tap = true;
    }
    /*
     * 数"可见的圆形按钮"—— 用户要求**不能有**。
     *
     * 判据：之前那两个圆圈的 tooltip 文案。为 0 才算对
     * （旧版本这里是 1，用户看到的就是那个难看的圆圈）。
     */
    if (w is Tooltip) {
      final m = w.message ?? '';
      if (m.contains('单击快退') || m.contains('单击快进')) visibleButtons++;
    }
    el.visitChildren(walk);
  }

  walk(root);
  return 'doubleTap=$doubleTap longPress=$longPress tapUp=$tapUp tap=$tap '
      'visibleButtons=$visibleButtons';
}

/// 当前正在渲染的播放页 state（探针用，未挂载时为 null）
///
/// # 为什么要登记一个全局引用
///
/// 交付实测要断言的是「**播放位置真的没跳**」，而不是
/// 「我把那个回调删了」—— 后者只是读源码，证明不了运行时行为。
/// 要读位置就必须够得着真实播放页的 `_position`。
///
/// ⚠️ 生命周期由 `initState`/`dispose` 成对维护，别在这里缓存着不放。
_PlayerPageState? _livePlayerState;

/// 读**真实播放页**的播放位置读数（秒），交付实测用
///
/// 返回 `null` 表示当前没有播放页（还没进 / 已退出）。
///
/// # 为什么用秒而不是 Duration
///
/// 实测是隔着 `debugPrint` 日志看结果的，`Duration` 打出来是
/// `0:00:12.345678` 这种带微秒的形式，**不便对比**。
/// 秒（保留 3 位小数）足够判断"有没有跳 10 秒"，也便于人眼核对。
///
/// ⚠️ 微秒级抖动是正常的（播放本来就在走），所以判据要用
///    **阈值**（比如 >2 秒才算跳变），不能用 `==`。
double? debugPlayerPositionSeconds() {
  final s = _livePlayerState;
  if (s == null) return null;
  return s._position.inMicroseconds / Duration.microsecondsPerSecond;
}

/// 播放页当前是否处于播放中（探针用），无播放页时返回 null
bool? debugPlayerIsPlaying() => _livePlayerState?._playing;

/// 播放页当前时长（秒），无播放页时返回 null
double? debugPlayerDurationSeconds() {
  final s = _livePlayerState;
  if (s == null) return null;
  return s._duration.inMicroseconds / Duration.microsecondsPerSecond;
}

/// 播放页最近一次**闪现提示**的文案（探针用），无播放页时返回 null
///
/// # 为什么需要读它
///
/// 「单击不跳秒」的判据是**播放位置没跳**（`debugPlayerPositionSeconds`），
/// 但位置本身会因播放而自然推进，也可能被"自动跳过片头"等**别的**
/// 逻辑改动 —— 只看位置无法区分"是我删对了"还是"这次恰好没触发"。
///
/// 而 `_seekBy`（单击跳秒唯一的执行路径）会 `_flash('快进 Ns' / '快退 Ns')`。
/// 所以：
/// ```text
/// tip 里出现「快进/快退 Ns」  → _seekBy 真的被调了（单击还在跳秒）
/// tip 里是别的文案            → 走的是别的路径
/// tip 为 null                 → 没触发任何动作
/// ```
///
/// ⚠️ `_flash` 会在 1.2 秒后自动清空，所以实测要在点击后**立刻**读。
String? debugPlayerLastTip() => _livePlayerState?._tip;

/// ★ 缺陷 9 探针（`test/zz_t3_flash_probe_test.dart:75`）用：
///   把一句话**走生产链路** `_flash` 送进提示条。返回 true = 真的写进了 `_tip`。
///
/// ⚠️ 走的必须是**生产**的 `_flash`（含它的 1.2 秒自清空 Timer），
///    不能是「直接 setState(_tip = msg)」—— 那样证明不了提示条**画得出来**，
///    只证明我在测试里改了个变量。
bool debugPlayerFlashForProbe(String msg) {
  final st = _livePlayerState;
  if (st == null) return false;
  st.debugPlayerFlashForProbe(msg);
  return st._tip == msg;
}

/// ★ 缺陷 9 探针用：读当前提示条文本（null = 没有提示条）
///
/// 与 `debugPlayerLastTip()` 是同一个东西，命名对齐探针里的调用；
/// 保留两个名字是因为 `debugPlayerLastTip` 已被别的探针引用（改名会连带改别人）。
String? debugPlayerTipForProbe() => _livePlayerState?._tip;

/// 累计调用 `_seekBy` 的次数（探针用），无播放页时返回 null
///
/// # 为什么用**计数器**而不是只看位置
///
/// `_seekBy` 是"单击跳秒"的**唯一执行路径**（也是 J/L、双击的路径）。
/// 位置读数会被很多因素干扰（播放推进、自动跳片头、缓冲回退），
/// 而计数器是**因果链上最直接的证据**：
/// ```text
/// 单击前后计数不变 → 单击**没有**触发任何 seek   ← 本次需求
/// 单击前后计数 +1  → 单击还在跳秒                ← 回归
/// ```
/// 实测只读**点击那一刻**的差值，所以键盘/双击的 seek 不会污染结论。
///
/// ⚠️ 只读探针，不影响任何行为。
int? debugPlayerSeekByCalls() => _livePlayerState?._seekByCalls;

/// 累计调用 `_togglePlay` 的次数（探针用），无播放页时返回 null
///
/// 用来证明"单击**仍然**能播放/暂停"—— 与 `debugPlayerSeekByCalls()`
/// 配对使用：理想结果是 `togglePlay +1 且 seekBy +0`。
int? debugPlayerTogglePlayCalls() => _livePlayerState?._togglePlayCalls;

/// ★ 累计调用 `_toggleFullscreen` 的次数（task-42 新增，探针用）
///
/// # 为什么必须单独计数（不能只看 `_fullscreen` 布尔）
/// ```text
/// 用户要求：「enter 和 双击 进入/退出 全屏」。
/// ★ 判据要回答的是"**这个键/手势有没有触发全屏切换**"，
///   而布尔值只能说明"当前是不是全屏" —— 两次切换后它就回到原值，
///   测试会误判成"没反应"。
/// ⇒ 用**次数**：断言"按一次 Enter ⇒ 计数 +1"。
/// ```
/// ⚠️ 与 `debugPlayerSeekByCalls()` 同样的道理（那里也是计数不是位置）。
int? debugPlayerFullscreenCalls() => _livePlayerState?._fullscreenCalls;

/// 当前是否处于全屏（只读）
bool? debugPlayerIsFullscreen() => _livePlayerState?._fullscreen;

/// ★ 画面输出层是否被判为"建不起来"（只读探针）
///
/// # 为什么需要它（交付实测的入口）
///
/// `README-交付说明.md:126-129` 承认过「输出层建不起来时全程静默」。
/// 修完之后必须能**实测**这个判决真的立起来了 —— 不能靠"我读了代码
/// 所以它一定工作"。
///
/// 探针用它断言两件事（两个方向都要，否则是"永远为真"的判据）：
/// ```text
/// ① 失败臂（`vo=gpu` 且 GL 上下文建不起来）⇒ 必须是 true
/// ② 成功臂（正常播放）⇒ 必须是 false，否则每台机器都会看到假横幅
/// ```
/// ⚠️ 只读，不触发任何行为 —— 诊断不能干扰被测对象。
bool? debugPlayerVideoOutputDead() => _livePlayerState?._videoOutputDead;

/// 把看门狗判为"输出层已死"的状态**直接注入**（探针用，仅供 UI 渲染验证）
///
/// # 为什么要注入而不是等真失败
///
/// 真失败需要一台"GL 上下文建不起来"的机器（模拟器上要 `vo=gpu`）。
/// 但横幅**渲染对不对**（位置/文案/不盖画面/按钮可点）是独立的另一件事，
/// 必须能在任何机器上验证。`lib\t377_banner_probe.dart` 用它做后者。
///
/// ⚠️ 生产代码里没有任何调用点 —— 它只在探针入口点被调到。
bool debugPlayerSetVideoOutputDeadForProbe(bool v) {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugSetVideoOutputDead(v);
  return true;
}

/// ★ 读看门狗的**两个原始闸门输入**（只读探针）
///
/// # 为什么必须能读原始输入，而不是只读判决
///
/// 2026-09-30 的 t377 Android 跑给出 `skipped=1`：⑤ 段的前置条件写的是
/// 「位置 > 0.5s」，而那一跑里**位置根本没推进**（`EGL_emulation:
/// eglCreateContext error 0x3004 (EGL_BAD_ATTRIBUTE)` 之后 1.2s 就
/// `播放结束`）。于是探针**什么都没测到**，只能 skip。
///
/// ⚠️ 但这里有个**逻辑陷阱**，正是它让 ⑤ 段永远拿不到读数：
/// ```text
/// 「输出层建不起来」恰恰就是「位置不推进」的原因之一
/// ⇒ 用「位置推进了」当前置条件 = 用被测故障的反面当前置条件
/// ⇒ 故障真的发生时，前置条件必然不成立 ⇒ 永远 skip
/// ```
/// 这是「一个从不触发的探针不该报成功」的**反面**：
/// 一个**只在故障缺席时才能触发**的探针，同样永远给不出阳性读数。
///
/// ⇒ 修法：⑤ 段改成直接读**闸门本身的两个输入**（有没有视频轨、
///    `vo-configured` 是不是 yes），无论位置推不推进都能读。
///    这样即使画面全黑、位置不动，判决链的每一环都仍然可观测。
///
/// 返回 `(有视频轨?, vo-configured?)`；读不到时对应项为 null。
Future<({bool? hasVideoTrack, bool? voConfigured})>
debugPlayerVideoOutputGateForProbe() async {
  final s = _livePlayerState;
  if (s == null) return (hasVideoTrack: null, voConfigured: null);
  final hasVideo = s._player.state.videoParams.dw != null;
  bool? vo;
  final native = s._player.platform;
  if (native is NativePlayer) {
    try {
      vo = (await native.getProperty('vo-configured')) == 'yes';
    } catch (_) {
      vo = null;
    }
  }
  return (hasVideoTrack: hasVideo, voConfigured: vo);
}

/// ★ 当前有没有浮层打开（只读探针，task-42）
///
/// # 为什么需要它
/// ```text
/// 「浮层打开时空格不该切播放器」这条判据，**必须先证明浮层真的开着**，
/// 否则测的还是"无浮层"那条路 ⇒ 假阴性
/// （"必须能区分「违规」与「没测到」"）。
/// ⇒ 让测试能直接断言"前置条件成立"，而不是靠推断。
/// ```
bool? debugPlayerAnySheetOpen() => _livePlayerState?._anySheetOpen;

/// 打开「快捷键提示」浮层（探针用，返回是否成功）
///
/// # 为什么选这个浮层
/// ```text
/// `_anySheetOpen` = 选集 ‖ 设置 ‖ 线路 ‖ 提示（四者并集）。
/// ★ 另外三个都**依赖 FFI 数据**（要有真实剧集/线路才能点开），
///   在 widget 测试里拿不到 ⇒ 只有「提示」是无条件可开的。
/// ⚠️ 但它们**共用同一行判断**（`if (_anySheetOpen) return ignored;`）
///   ⇒ 用「提示」验证等价于验证四者。
/// ```
bool debugPlayerOpenHintsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.setState(() => s._hintsOpen = true);
  return s._hintsOpen;
}

/// 给「线路 / 清晰度」抽屉**注入假线路**（探针用，返回是否成功）
///
/// # 为什么必须新增这个探针（task-72 实测得到的结论）
/// ```text
/// 「线路」按钮的门控是 `hasStreams: _streams.length > 1`，
/// 而 `_streams` 只在 `resolve_stream`（FFI）成功后才被填上。
/// ★ 但 widget 测试里 `sourin_core.dll` **加载不了**
///   （实测：`Failed to load dynamic library 'sourin_core.dll'`
///     error code 126）⇒ `_load()` 必然失败 ⇒ `_error` 置上
///   ⇒ 整条 `_BottomBar` 连**一帧**都留不住（实测：`换源` 命中 1 → 0）
///   ⇒ 「线路」按钮在测试里**永远不会出现**。
/// ★ 而且"抢在第一个 pump 之前点按钮"这条路也堵死了：
///   实测在窗口期点「选集」/「换源」，回调**都不触发**
///   （`anySheetOpen` 纹丝不动）—— 环境降级态下命中测试过不去。
/// ⇒ 若不新增这个探针，②（点空白关闭）与①（清晰度徽章）就只能退回
///   **手抄副本**去测 —— 而那正是 task-70 的坑：副本与生产脱钩
///   ⇒ **测试全绿、生产是错的**（见 `t57` 的 `streamSheetShell()`）。
/// ⇒ 用探针直接驱动**真实的** `_streams` / `_streamSheetOpen`，
///   测的就是**生产那棵树**，不再有"同构"这个可失效的前提。
/// ```
bool debugPlayerSetStreamsForProbe(List<StreamCandidate> streams) {
  final s = _livePlayerState;
  if (s == null) return false;
  s.setState(() => s._streams = streams);
  return true;
}

/// 打开「线路 / 清晰度」抽屉（探针用，返回是否成功）
///
/// 与 [debugPlayerSetStreamsForProbe] 配套 —— 见那里的说明。
/// ⚠️ 只改 `_streamSheetOpen`，**不碰** `_streams`（线路列表由调用方注入）。
bool debugPlayerOpenStreamSheetForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.setState(() => s._streamSheetOpen = true);
  return s._streamSheetOpen;
}

/// 打开「选集」面板（探针用，返回是否成功）
///
/// # 为什么需要它（task-74【④】补，2026-09-29 实测）
/// ```text
/// `test/player_panel_wiring_test.dart` 的组 B 原来是 `tap(find.text('选集'))`，
/// 但那条路**在本机已经走不通**：
///
///   DIAG|点之前:        选集按钮=1  EpisodePanel=0
///   DIAG|pump() 之后:   选集按钮=0  EpisodePanel=0   ← ★ 按钮自己没了
///
/// 根因 = 本文件头部早就写过的「坑①」：
///   `_load()` 里 `resolveStream` 走 FFI，而 flutter_tester 进程
///   **加载不了 `sourin_core.dll`**（error code 126）
///   ⇒ `_error` 被置上 ⇒ `_BottomBar` 的渲染条件
///     （`_error == null && !_episodeSheetOpen && …`）
///     不成立 ⇒ 「选集」按钮**在第一帧之后就消失** ⇒ tap 必然失败。
///
/// ⚠️ 这与 task-72 给「线路」/「所有直播」写探针是**同一个理由**
///    （见 [debugPlayerSetStreamsForProbe] 的说明）。
/// ```
///
/// ⚠️ 只改 `_episodeSheetOpen` —— 测的仍是**生产那棵树**里的
///    `SheetTransition.slideFrom`，不是手抄副本。
bool debugPlayerOpenEpisodeSheetForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.setState(() => s._episodeSheetOpen = true);
  return s._episodeSheetOpen;
}

/// 打开「所有直播」抽屉（探针用，返回是否成功）
///
/// ⚠️ 面板**内容**依赖 `widget.onLiveChannels`（测试里要自己传）；
///    但屏障/几何与内容无关 ⇒ 即便列表为空，本探针也能验②。
bool debugPlayerOpenLiveChannelsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.setState(() => s._liveChannelsOpen = true);
  return s._liveChannelsOpen;
}

/// 打开「换源」弹层（探针用，返回是否成功）
///
/// # 为什么需要它（task-72【④】的判据要求）
/// ```text
/// ④ 的症状是"弹层里的关键词是空的 ⇒ 不自动搜、不填充"。
/// 判据必须落在**弹层里那个 `TextField` 的实际内容**上 ——
/// 那才是用户看到的东西。
/// ★ 但「换源」按钮所在的 `_BottomBar` 在测试里活不过一帧
///   （见 [debugPlayerSetStreamsForProbe] 的说明）
///   ⇒ 只能由探针直接调这个方法。
/// ⚠️ 不 `await`：`_openSwitchSource` 内部 `await showSourceSwitchDialog(...)`，
///   而那个 Future 要等弹层**被关掉**才完成 ⇒ await 会挂死。
///   （这正是本函数返回 `bool` 而不是 `Future` 的原因）
/// ```
bool debugPlayerOpenSwitchSourceForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  unawaited(s._openSwitchSource());
  return true;
}

/// 累计**真正执行**的切集次数（探针用），无播放页时返回 null
///
/// # task-28 ①-C 的**行为层**判据
///
/// 用户报「明明没有下一集，却还是请求下一集」。
/// 这个计数是"切集动作到底发生了没有"的**因果链最直接**读数 ——
/// 比"看按钮是不是灰的"强得多（灰按钮只能证明外观）。
///
/// 用法（与 [debugPlayerBlockedNavCalls] 配对）：
/// ```text
/// 场景 A：停在最后一集，点「下一集」
///   gotoEpisodeCalls 不变 + blockedNavCalls +1  ⇒ ✅ 判据拦住了（期望）
///   gotoEpisodeCalls +1                          ⇒ ❌ 判据失效（真 bug）
///
/// 场景 B（阳性对照）：停在中间某一集，点「下一集」
///   gotoEpisodeCalls +1                          ⇒ ✅ 仪器有效
/// ```
/// ★ **场景 B 必须先通过** —— 否则"场景 A 里计数没涨"也可能只是
///   仪器测不到（铁律②：阳性对照失败 ⇒ 结论作废）。
int? debugPlayerGotoEpisodeCalls() => _livePlayerState?._gotoEpisodeCalls;

/// 累计被"没有上一集/下一集"挡回去的次数（探针用），无播放页时返回 null
///
/// 与 [debugPlayerGotoEpisodeCalls] 配对 —— 见那个函数的用法说明。
/// 单独看它没有意义：`0` 既可能是"拦住了但没记"，
/// 也可能是"压根没点到"，必须两个数一起读。
int? debugPlayerBlockedNavCalls() => _livePlayerState?._blockedNavCalls;

/// 当前播放倍速（探针用），无播放页时返回 null
///
/// # 为什么需要它
///
/// 「长按方向键 = 快进快退」的**可观测结果**就是倍速变化：
/// ```text
/// 按住右方向键 -> 倍速 = pcArrowHoldRate（默认 2.0）
/// 松开         -> 倍速回落到按住之前的原值（不是写死的 1.0）
/// ```
/// 没有这个读数就只能断言"我调用了某函数"，那是测实现不是测行为。
double? debugPlayerRate() => _livePlayerState?._rate;

/// 最近一次**要求**的倍速（探针用），无播放页时返回 null
///
/// 与 [debugPlayerRate] 的区别（实测确认，很重要）：
/// ```text
/// debugPlayerRate()        = 播放器**回报**的倍速
///                            → 在 flutter test 里永远是 1.0（原生层不发事件）
/// debugPlayerRequestedRate() = 我们**要求**的倍速
///                            → 这才是本次要验的行为
/// ```
/// 拿这个做断言才不会是空断言。
double? debugPlayerRequestedRate() => _livePlayerState?._lastRateRequest;

/// PC 方向键状态机的**当前状态**（探针用）
///
/// 返回形如 `dir=1 holding=true`；无播放页时返回 null。
///
/// 用来证明"两个开关各自独立"：关掉单击后，长按仍应能进入 holding=true。
String? debugPlayerPcArrowState() {
  final st = _livePlayerState;
  if (st == null) return null;
  return 'dir=${st._pcArrow.direction} holding=${st._pcArrow.isHolding}';
}

/// 连续快退定时器**是否在跑**（探针用），无播放页时返回 null
///
/// 左方向键长按走的是"定时器反复 seek"（底层不支持负倍速），
/// 所以"有没有在连续快退"的唯一可靠判据就是这个定时器。
bool? debugPlayerRewindTimerActive() => _livePlayerState?._rewindTimer != null;

/// 累计调用 `_takeScreenshot` 的次数（★ task-21 P1-30 探针用），无播放页时返回 null
int? debugPlayerScreenshotCalls() => _livePlayerState?._screenshotCalls;

/// ★★★ 错误态返回箭头探针（Owner 2026-10-09 新增缺陷）
///
/// 返回 `(顶栏箭头矩形, 顶栏箭头**不透明度**, 顶栏是否参与命中测试)`。
///
/// # 为什么单看「矩形存在」不够（这是本缺陷最容易自欺的地方）
/// ```text
/// 改前顶栏那枚箭头的**矩形一直都在**（`Opacity` 与 `IgnorePointer`
/// 都不改变布局）—— 只断言「矩形非 null」在改前**也会通过**，
/// 证明不了「点得动」。所以必须同时量：
///   ② 不透明度：`_TopBar` 里 `Opacity(opacity: fade?.value ?? 1.0)`
///      —— 控制条隐藏时 `_controlsFade == 0` ⇒ 箭头全透明（看得见才怪）；
///   ③ 命中测试：`IgnorePointer(ignoring: !visible)` 是否放行。
/// ```
/// ③ 的读法：从箭头中心打一次真实 hitTest，看路径里有没有 `IconButton`；
/// 这个动作在 `_probeTopBarBackHitTest()` 里做（需要 tester，所以放探针侧）。
(Rect?, double?, bool)? debugPlayerTopBarBackProbe() {
  final s = _livePlayerState;
  if (s == null) return null;
  final ctx = s._topBarBackKey.currentContext;
  double? op;
  bool ignoring = false;
  ctx?.visitAncestorElements((e) {
    final w = e.widget;
    if (w is Opacity && op == null) op = w.opacity;
    if (w is IgnorePointer && w.ignoring) ignoring = true;
    return true;
  });
  final ro = ctx?.findRenderObject();
  final rect = (ro is RenderBox && ro.attached)
      ? ro.localToGlobal(Offset.zero) & ro.size
      : null;
  return (rect, op, ignoring);
}

(double, double)? debugPlayerControlBarsOpacity() {
  final s = _livePlayerState;
  if (s == null) return null;
  final v = s._controlsFade.value;
  return (v, v);
}

/// 把控制条按 3 秒规则**跑到底**（★ 2026-10-08 顶栏联动回归用）
///
/// # 为什么需要它（而不是在测试里 `pump(3s)`）
/// ```text
/// 隐藏走的是 `Timer(3s)` + `AnimationController`，在 fake-async 里
/// 两者都要靠 `pump` 推进 —— 但 `pump` 的**次数与步长**决定了
/// 动画停在哪一帧，读数会飘。
/// ⇒ 这里直接把定时器那条路**同步**走完（cancel + 置位 + 驱动动画），
///   读数与真机「停手 3 秒」完全同一条代码路径。
/// ```
///
/// ⚠️ 它**只**在 `_playing == true` 时才会真的隐藏（与生产判据逐字一致）；
///    返回是否真的隐藏了。
bool debugPlayerAutoHideControlsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugAutoHideControlsForProbe();
  return !s._controlsVisible;
}

/// 模拟一次「鼠标在控制条区域晃动」（★ 2026-10-08 顶栏联动回归用）
///
/// ★ 走的是**生产**那条 `_showControls()`（含 `_applyControlsMotion()`
///   与 `_armHideTimer()`），不是测试自己置位。
bool debugPlayerHoverControlsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugHoverControlsForProbe();
  return s._controlsVisible;
}

/// ★ task-16 探针：置「指针是否在播放页内」—— 悬浮返回键的常驻判据
///
/// 走 `_onPointerEnter` / `_onPointerExit`（= `MouseRegion.onEnter/onExit`
/// 的生产回调体），返回置位后的值；无播放页时返回 null。
/// 为什么必须由探针驱动：见 `debugSetPointerInsideForProbe` 的说明。
bool? debugPlayerSetPointerInsideForProbe(bool v) {
  final s = _livePlayerState;
  if (s == null) return null;
  s.debugSetPointerInsideForProbe(v);
  return s._pointerInside;
}

/// 置位 `_playing`（★ 2026-10-08 顶栏联动回归用）
///
/// ⚠️ 必须在 `debugPlayerAutoHideControlsForProbe()` **之前**调 ——
///    否则 `_autoHideNow()` 的 `_playing` 判据不成立，隐藏路径走不到。
bool debugPlayerSetPlayingForProbe(bool v) {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugSetPlayingForProbe(v);
  return s._playing;
}

/// 打开「播放设置」面板（★ task-25 D 探针用，返回是否成功）
///
/// ⚠️ 与 `debugPlayerOpenHintsForProbe` 同因：面板依赖 FFI 数据才能
///    点开，widget 测试里拿不到 ⇒ 直接调 `_openSettings()` 的那条路
///    （`_readMpvStyle` 读不到属性也不会抛，只是 map 为空）。
bool debugPlayerOpenSettingsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugOpenSettingsForProbe();
  return s._settingsOpen;
}

/// 关闭「播放设置」面板（★ 第 3 条回归测试用；返回关闭后面板是否确实关着）
///
/// ⚠️ 它**只改真源** `_settingsOpen`，**故意不碰** portal 的显示状态。
///
/// # 为什么不与面板上那颗 X 等价（2026-10-08 改）
/// X 与 Esc 现在都走「三步」（真源 + `_hideSettingsPortal()` + 底栏自愈），
/// 而本探针**停在第一步** —— 因为第 3 条缺陷 B 的入口形态正是
/// 「真源说"关"，而 portal 那边还开着（镜像过期）」，回归测试要复现的
/// 就是这个中间态。走完整三步反而复现不出缺陷。
///
/// # 为什么需要它（而不是在测试里点那颗 X）
/// `flutter_tester` 里 PlayerPage 整棵树的**指针事件回调都不被调用**
/// （命中链完整、同 Stack 的兄弟控件正常 ⇒ 见 test/t98 文件头的记录）。
/// 键鼠之外的探针入口是这台仪器唯一能驱动生产路径的手段。
/// 注入一条 `stream.error`（★ 第 9 条回归测试用；返回注入前是否已出过画面）
///
/// # 为什么要走**生产**那条监听
/// 它内部就是 `_player.stream.error.listen(...)` 的同一个闭包体 ——
/// 直接调它等价于 mpv 真的报了一条错，而测试**不需要**起播
/// （起播要真网络 + 真解码，widget 测试里做不到）。
///
/// ⚠️ 判据读的是 `s._sawFirstFrame`（真实字段），不是测试自己记的副本。
/// ★ 缺陷 17 探针用：底栏当前是否可见（= 渲染 `_BottomBar` 的那串门控的最终结果）
bool debugPlayerControlsVisibleForProbe() =>
    _livePlayerState?._controlsVisible ?? false;

/// ★ 缺陷 17 探针用：当前错误态（非 null 时底栏整条被摘掉）
String? debugPlayerErrorForProbe() => _livePlayerState?._error;

/// 打开选集面板（见 State 里的 `debugOpenEpisodesForProbe`）
bool debugPlayerOpenEpisodesForProbe() =>
    _livePlayerState?.debugOpenEpisodesForProbe() ?? false;

/// 展开某个 popover（见 State 里的 `debugOpenPopoverForProbe`）
bool debugPlayerOpenPopoverForProbe(String id) =>
    _livePlayerState?.debugOpenPopoverForProbe(id) ?? false;

/// 无头截图用：把底栏从「起播失败」那层里**救出来**（见 State 里的同名方法）
///
/// ⚠️ 只改 UI 状态，不碰播放器、不发请求 —— 仅供截图与几何判据使用。
bool debugPlayerForceBarsForShot() =>
    _livePlayerState?.debugForceBarsForShot() ?? false;


/// ★ task-12 ④ 探针用：当前**起播候选**的 url 列表（只读）。
///
/// # 为什么需要它
/// ```text
/// 「本地文件短路」的判据是「候选 url 是 file:// 且 resolveStream 没被执行」。
/// 但那是**内部状态**，探针拿不到 ⇒ 加这一条**只读**钩子。
/// ⚠️ 只读（返回 `_streams` 的副本），不提供任何 setter —— 不给测试开后门改状态。
/// ```
List<String> debugPlayerStreamUrlsForProbe() =>
    _livePlayerState?._streams.map((s) => s.url).toList() ?? const <String>[];

/// ★ 缺陷 17 探针用：弹幕是否开启（菜单项/按钮 tooltip 的动作词由它决定）
bool debugPlayerDanmakuEnabledForProbe() =>
    _livePlayerState?._danmakuEnabled ?? false;

/// ★ 缺陷 17 探针用：是否全屏（全屏按钮 tooltip 的动作词由它决定）
bool debugPlayerFullscreenForProbe() => _livePlayerState?._fullscreen ?? false;

/// ★ task-8 ① 探针用：把 `_fullscreen` 直接置位（**不**去调 windowManager）。
///
/// # 为什么要这个
/// ```text
/// 全屏返回那条路径里，`_exitPlayer()` 会 `await _toggleFullscreen()`，
/// 而后者内部 `await windowManager.setFullScreen(false)` 是**真 OS 调用**。
/// flutter_tester 里没有宿主窗口 ⇒ 那个 await 不会真的往返，
/// 量不到真机上的耗时。所以这里**只置标志位**，把「路径分支」与
/// 「OS 往返」分开：本探针量的是前者，后者由真机日志（[PLAYER] 时间戳）补。
/// ```
/// ★ task-8 ① 探针：直接 await 生产那条 `_toggleFullscreen()`，读出它**耗时/是否挂死**。
///
/// ⚠️ 必须走**生产**方法（不是测试自己模拟）—— 本缺陷的疑问正是
///    「那个 await 在桌面端到底要多久」，模拟不出这个答案。
Future<int?> debugPlayerAwaitToggleFullscreenForProbe() {
  final s = _livePlayerState;
  if (s == null) return Future<int?>.value(null);
  return s.debugPlayerToggleFullscreenForProbe();
}

bool debugPlayerSetFullscreenForProbe(bool v) {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._fullscreen = v);
  return true;
}

/// ★ task-7 探针用：走**生产** `_exitPlayer()`（与点返回箭头同一个回调）。
///
/// ⚠️ 不能只写 `Navigator.maybePop()` —— 那证明的是「Navigator 能用」，
///    不是「这枚箭头接的那条路径能用」。这里调的就是 `onBack` 里那一个。
bool debugPlayerBackForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  unawaited(s._exitPlayer());
  return true;
}

bool debugPlayerInjectStreamErrorForProbe(String message) {
  final s = _livePlayerState;
  if (s == null) return false;
  final had = s._sawFirstFrame;
  // 逐字复刻 `_bindPlayerStreams` 里那个闭包体（含日志与分流）
  AppLog.write('PLAY', had ? '播放中断（已有画面，非阻断）：$message' : '起播失败：$message');
  // ignore: invalid_use_of_protected_member
  s.setState(() {
    if (had) {
      s._playbackFailure = message;
    } else {
      s._error = message;
    }
  });
  return had;
}

/// 模拟「首个视频帧已出」（★ 第 9 条回归测试用）
///
/// 逐字复刻 `_bindPlayerStreams` 里 `stream.width` 那个闭包体：
/// 落一行日志 + 把 `_sawFirstFrame` 立起来 + 收掉非阻断横幅。
bool debugPlayerMarkFirstFrameForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  AppLog.write('PLAY', '首帧已出（探针注入）—— 此刻之后的 stream.error 按"可恢复中断"处理');
  // ignore: invalid_use_of_protected_member
  s.setState(() {
    s._sawFirstFrame = true;
    // ★ 与生产闭包体逐字一致：有画面 ⇒ 撤掉全屏错误层
    s._error = null;
    s._errorKind = null;
    s._loading = false;
    s._playbackFailure = null;
  });
  return s._sawFirstFrame;
}

/// 读第 9 条的两个状态（`hasFrame=<是否出过画面> failure=<非阻断横幅>`）
String debugPlayerPlaybackFailureState() {
  final s = _livePlayerState;
  if (s == null) return 'no-state';
  return 'hasFrame=${s._sawFirstFrame} '
      'failure=${s._playbackFailure ?? "-"} '
      'error=${s._error ?? "-"}';
}

/// 读「底栏是否可见」（★ 第 3 条：关掉面板后底栏必须回来）
bool? debugPlayerControlsVisible() {
  final s = _livePlayerState;
  if (s == null) return null;
  return s._controlsVisible;
}

bool debugPlayerCloseSettingsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  /*
   * ⚠️ 只改真源 `_settingsOpen`，**故意不碰** portal 的显示状态。
   *
   * 这样它才等价于缺陷 B 的入口形态（镜像过期的那个）：真源已经是 false，
   * 而 controller 那边还以为自己在显示。t98 ② 就用这个形态复现
   * 「开过别的浮层之后再开面板，面板必须仍然出现」。
   * 面板那颗 X 走的是 `onClose`（真源 + portal + 底栏三件都做）。
   */
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._settingsOpen = false);
  return !s._settingsOpen;
}

/// 设置面板的 `_settingsOpen`（★ task-25 D 探针用），无播放页时返回 null
bool? debugPlayerSettingsOpen() => _livePlayerState?._settingsOpen;

/// 当前平台策略：`clipDirOpenStrategy` 的结果（★ task-25 C 探针用）
///
/// ⚠️ 只读探针 —— **不会真的去 spawn 外部进程**，也不会碰剪贴板。
///    「真的走到哪一支」由 `test/t68_android_adapt_test.dart` 断言
///    顶层纯函数本身来保证。
String debugPlayerClipDirStrategy() => clipDirOpenStrategy(
  isWindows: Platform.isWindows,
  isMacOS: Platform.isMacOS,
  isLinux: Platform.isLinux,
);

/// 主动 seek 到指定位置（**仅探针用**），无播放页时返回 false
///
/// # 为什么需要"主动 seek"这种危险的东西
///
/// 交付实测要断言"单击后播放位置**没有跳变**"。但如果位置读数本身
/// 是坏的（永远 0、或者探针接错了），那条断言会**永远为真** ——
/// 一条空断言比没有断言更危险（给的是虚假信心）。
///
/// 实测第一轮就撞上了：位置是 `0.00s → 0.00s`，"没跳"通过了，
/// 但视频压根还没起播 —— 那个"通过"没有任何信息量。
///
/// 所以需要一次**阳性对照**：主动 seek 到一个已知位置，
/// 断言读数**确实跟着变了**。变了才说明尺子是准的。
///
/// ⚠️ 它绕开所有手势逻辑直接调播放器 —— 这是**故意**的：
///    测的是"读数能不能反映 seek"，与手势无关。
///    调用方负责在测完后复位位置。
/// 探针用：位置流触发的**页面 setState 次数**（task-72 ④ 卡顿量化）
///
/// # 为什么需要它
///
/// 「播放页面感觉也卡卡的」是 Owner 的**主观描述**。要把候选 B
///（`_player.stream.position` 无节流直接 `setState`）变成读数，
/// 就必须数出**页面真的重建了多少次**。
///
/// 只数「mpv 发了多少次 `time-pos`」不够 —— 那证明不了页面跟着重建
///（铁律 149：候选集为空/机制未触发时，断言恒真）。
///
/// 生产代码里它只是一个 `++`（每次 tick 一次自增，代价可忽略），
/// 没有任何分支依赖它的值。
int debugPlayerPositionSetStates = 0;

/// 探针用：位置流**一共来了多少 tick**（与上面那个 setState 数配对）
///
/// 两个数一起看才有意义：
/// ```text
/// 改前：ticks = N, setStates = N   （1:1）
/// 改后：ticks = N, setStates ≈ 秒数（按显示的那一秒节流）
/// ```
int debugPlayerPositionTicks = 0;

/// 清零两个位置流计数器（**仅探针用**）
void debugPlayerResetPositionSetStates() {
  debugPlayerPositionSetStates = 0;
  debugPlayerPositionTicks = 0;
}

/// 探针用：把一次位置 tick **灌进真实处理路径**（见 `_onPositionTick`）
///
/// 用于 widget 测试里模拟"1 秒内来了 100 个 tick" ——
/// 没有它就只能靠真播放（widget 测试里 `open()` 会挂住，见
/// `.probe/probe_tests/t72_position_tick_probe_test.dart` 的注释）。
void debugPlayerPushPositionForProbe(Duration p) {
  _livePlayerState?._onPositionTick(p);
}

bool debugPlayerSeekForProbe(Duration target) {
  final s = _livePlayerState;
  if (s == null) return false;
  s._player.seek(target);
  return true;
}

/// 打开一个**本地文件**作为媒体（**仅探针用**），无播放页时返回 false
///
/// # 为什么需要它（这是被阳性对照逼出来的）
///
/// 阳性对照第一次跑就**失败**了，暴露出一个真问题：
/// ```text
/// [阳性对照] 主动 seek 到 20s：位置 0.00s → 0.00s (Δ0.00s)  ✗
/// ```
/// 位置读数**根本不动** —— 因为测试用的那路在线流因为
/// `unauthorized`（测试数据目录里的登录已失效）**压根没起播**。
///
/// 于是 ⑥b/⑥c 里那两条"单击后位置没跳"的 ✓ 全是**空的**：
/// 位置永远是 0，当然"没跳"。这正是本次会话反复踩的坑 ——
/// **一条永远为真的断言比没有断言更危险**（给的是虚假信心）。
///
/// # 修法：把测量对象换成**一定播得起来**的东西
///
/// 用本地 mp4（`--dart-define=PROBE_VIDEO=<path>`）替换当前媒体。
/// 本地文件不依赖网络/登录，`_position` 会**真的推进**，
/// 这样"位置没跳"才是一个有信息量的断言。
///
/// ⚠️ 只在探针构建里调用；`_probeVideo` 为空时它是 no-op。
Future<bool> debugPlayerOpenForProbe(String url) async {
  final s = _livePlayerState;
  if (s == null) return false;
  try {
    await s._player.open(Media(url));
    return true;
  } catch (e) {
    debugPrint('[GESTURE-PROBE] 打开探针视频失败: $e');
    return false;
  }
}

/// 探针视频路径（编译期常量，默认空 = 不启用）
///
/// 见 `debugPlayerOpenForProbe` 的说明：没有它，"位置没跳"这条断言
/// 在在线流播不起来时是**空的**。
const kProbeVideo = String.fromEnvironment('PROBE_VIDEO');

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ task-13 ⑦ 弹幕探针（交付实测用）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 接入一下 dandanplay 的弹幕功能
//
// # 为什么要这些探针
//
// 弹幕这条链路有三段**只有真进程里才成立**：
// ----
// ① 取：真的发 HTTP 到 api.dandanplay.net（签名 / 302 / 错误头）
// ② 排：真的把 N 条弹幕铺到 N 条泳道上（不重叠）
// ③ 滚：真的随时间往左移动（帧循环 / 时间轴对齐）
// ----
// widget 测试只能测纯函数（①②的解析部分），②③必须在真窗口里跑。
// 所以这里给真进程探针留出「读状态 / 塞数据 / 截图」的把手。

/// 当前已取到的弹幕条数（无播放页时返回 null）
int? debugPlayerDanmakuCount() => _livePlayerState?._danmakuComments.length;

/// 当前弹幕开关状态
bool? debugPlayerDanmakuEnabled() => _livePlayerState?._danmakuEnabled;

/// 当前弹幕状态摘要（面板里那行字）
String? debugPlayerDanmakuStatus() => _livePlayerState?._danmakuStatus;

/// 当前弹幕错误（无错误时返回空串；null = 没有播放页）
String? debugPlayerDanmakuError() {
  final s = _livePlayerState;
  if (s == null) return null;
  final e = s._danmakuError;
  if (e == null) return '';
  // ★ 把 X-Error-Message 原文带出来 —— 这是「没填 AppId」时
  //   唯一能说明原因的东西（正文是空的，见 core/danmaku.dart）
  return e.xErrorMessage.isNotEmpty ? e.xErrorMessage : e.message;
}

/// 面板里「详情」那段全文（含 HTTP 状态码 / 请求 URL / 响应正文）
String? debugPlayerDanmakuErrorDetail() =>
    _livePlayerState?._danmakuError?.detail;

/// 开关弹幕（探针用；会真的走 _toggleDanmaku 那条路）
Future<bool> debugPlayerToggleDanmakuForProbe() async {
  final s = _livePlayerState;
  if (s == null) return false;
  await s._toggleDanmaku();
  return s._danmakuEnabled;
}

/// 直接设弹幕开关（探针用；**不**触发取弹幕）
void debugPlayerSetDanmakuEnabledForProbe(bool v) {
  final s = _livePlayerState;
  if (s == null) return;
  s.debugDanmakuSetEnabledOnly(v);
}

/// 用给定文件名取一次弹幕（探针用；返回取到的条数，-1 = 失败）
///
/// 真进程探针里用它验证「有凭证 ⇒ 200 + N 条」/「没凭证 ⇒ 403 + 原文」。
Future<int> debugPlayerLoadDanmakuForProbe(String fileName) async {
  final s = _livePlayerState;
  if (s == null) return -1;
  if (!s._danmakuEnabled) s.debugDanmakuSetEnabledOnly(true);
  await s._loadDanmakuNamed(fileName);
  return s._danmakuError == null ? s._danmakuComments.length : -1;
}

/// 清掉弹幕取数错误（探针用；返回清完后错误是否为空）
///
/// # 为什么需要它
///
/// 没有 AppId/AppSecret 时 ① 段必然拿到 403，`_danmakuError` 被置上，
/// 于是弹幕层左上角会挂一个「弹幕失败：Missing Authentication Headers」
/// 角标（`_danmakuBadge` :3318-3331）。
///
/// ④ 段的像素对照要测的是**滚动弹幕自己**，而那个角标正好落在弹幕带
/// （视频区顶部 5 条泳道）里，尺寸还不小 ⇒ 不排掉它，「弹幕开 vs 关」
/// 的差值会被角标主导，等于测了个错东西。
///
/// 清掉它等于**模拟取数成功那一支**（错误为空、评论非空 ⇒ 角标为 null），
/// 这正是真实凭证到手后的状态。
bool debugPlayerClearDanmakuErrorForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._danmakuError = null);
  return s._danmakuError == null;
}

/// 塞一个**真实构造的**弹幕错误（探针用；返回塞完后错误是否就是它）
///
/// # 为什么需要它
///
/// Owner 第 1 条要的是「403 + Missing Authentication Headers ⇒ 面板里
/// 出现中文指引」。这条链的后半段（面板把 `DanmakuHint` 画出来）能在
/// 纯 widget 测试里验，但**前半段**（`_danmakuError` 真的被搬到面板的
/// state 里）只能在真棵树上验 —— 没有凭证时真实链路必然 403，可那是
/// **网络**，单测里不许发。
///
/// ⚠️ 必须**连 `_danmakuSettings` 一起写**：面板读的是
///   `_danmakuSettings.error`，只写 `_danmakuError` 面板什么都看不见
///   （`_openDanmakuSettings` 里那句 copyWith 就是干这个的）。
bool debugPlayerInjectDanmakuErrorForProbe(DanmakuException e) {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() {
    s._danmakuError = e;
    s._danmakuSettings = s._danmakuSettings.copyWith(
      error: e,
      loading: false,
      status: '',
    );
  });
  return identical(s._danmakuError, e);
}

/// 塞一组**本地构造的**弹幕进渲染层（探针用）
///
/// # 为什么需要「本地构造」这条路
///
/// 没有 AppId/AppSecret 时，真实链路**必然**是 403
/// （见 core/danmaku.dart 的错误透传策略）⇒ 渲染/滚动/泳道分配
/// 这三件事就没有真实数据可测。
/// 本地构造一组时间/模式/颜色都可控的弹幕，可以把
/// 「画面里到底有没有东西在动」这件事**独立**证出来 ——
/// 这样报告里「渲染层是好的」和「取数被凭证卡住」才是两件分开的事实。
void debugPlayerSetDanmakuCommentsForProbe(List<DanmakuComment> cs) {
  final s = _livePlayerState;
  if (s == null) return;
  s.debugDanmakuSetComments(cs);
}

/// 清空弹幕探针统计（进入测量前调一次）
void debugPlayerResetDanmakuProbe() => debugDanmakuResetProbeStats();

/// 打开弹幕设置面板（探针用；返回面板是否处于打开态）
///
/// # 为什么不能靠点底栏那颗齿轮
/// ```text
/// 底栏在**播放中** 3 秒后自动隐藏（_showControls 的隐藏计时器只在
/// _playing && !_hintsOpen 时才起）。探针要截「面板里的服务端原文」，
/// 如果先去 hover 唤出底栏、再点齿轮，中间隔着一次 setState + 手势竞技场
/// 结算，截图时机极难稳定；而且底栏一隐面板按钮就没了。
/// ⇒ 直接驱动**生产那棵树**上的 _danmakuSheetOpen（和用户点齿轮走的是
///   同一个字段、同一段 build），不手抄副本。
/// ```
bool debugPlayerOpenDanmakuSettingsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._danmakuSheetOpen = true);
  return s._danmakuSheetOpen;
}

/// 关闭弹幕设置面板（探针用；返回关闭后面板是否确实关着）
bool debugPlayerCloseDanmakuSettingsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._danmakuSheetOpen = false);
  return !s._danmakuSheetOpen;
}

/// 打开哔哩哔哩弹幕导入面板（探针用；返回面板是否处于打开态）
///
/// ★ task-104：与 [debugPlayerOpenDanmakuSettingsForProbe] 同款 —— 播放页
///   在 flutter_tester 里点不动（`_load()` 必然失败，见 .probe/probe_tests/README.md），
///   而「关闭时也有动画」这条只能在**真棵树**上验（要读 SheetExitMotion
///   的 Opacity 逐帧值）⇒ 必须能从外部把面板开/关。
///
/// ⚠️ 与用户点按钮走的是**同一个字段、同一段 build**（不手抄副本）；
///   面板内容依赖 `_biliState`，探针只管开关。
bool debugPlayerOpenBiliSheetForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._biliSheetOpen = true);
  return s._biliSheetOpen;
}

/// 关闭哔哩哔哩弹幕导入面板（探针用；返回关闭后面板是否确实关着）
bool debugPlayerCloseBiliSheetForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._biliSheetOpen = false);
  return !s._biliSheetOpen;
}

/// 打开「在线搜索字幕」面板（探针用；返回面板是否处于打开态）
///
/// ★ task-104：与上面两个同款。注意生产路径上 `_openSubtitlePanel()` 会
///   **顺带**关掉设置面板与弹幕面板（三者同一时刻只留一个全屏 scrim），
///   而本探针只翻自己那个字段 —— 探针要单独验字幕面板的退场动画。
bool debugPlayerOpenSubtitlePanelForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._subtitlePanelOpen = true);
  return s._subtitlePanelOpen;
}

/// 关闭「在线搜索字幕」面板（探针用；返回关闭后面板是否确实关着）
bool debugPlayerCloseSubtitlePanelForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._subtitlePanelOpen = false);
  return !s._subtitlePanelOpen;
}

/// 当前用于取弹幕的文件名（探针用；无播放页时返回 null）
///
/// 探针要断言「送去 dandanplay 的 fileName 到底长什么样」——
/// 这条链路上最容易出错的地方就是它（多带了扩展名 / 多带了目录）。
String? debugPlayerDanmakuFileName() => _livePlayerState?._danmakuFileName;

/// 走**真实起播路径**打开一个媒体（探针用；返回是否成功）
///
/// # 为什么不能复用 [debugPlayerOpenForProbe]
/// ```text
/// debugPlayerOpenForProbe 直接调 _player.open(Media(url))，
/// 它**绕开了** _startPlayback 的尾部 —— 而弹幕取数钩子
/// （_loadDanmaku）正好挂在那里（起播成功才取，那时 _duration 才有值）。
/// ⇒ 用它验「起播后会不会自动取弹幕」这条断言会**永远为假**，
///   而那是探针仪器的问题，不是产品的问题（一条永远为假的断言
///   和永远为真的一样有害：都测不到东西）。
/// ```
///
/// ⚠️ 它走的是**生产**那条路（_startPlayback），不是手抄副本。
Future<bool> debugPlayerStartPlaybackForProbe(String url) async {
  final s = _livePlayerState;
  if (s == null) return false;
  try {
    await s._startPlayback(StreamCandidate(url: url));
    return true;
  } catch (e) {
    debugPrint('[DANMAKU-PROBE] 起播失败: $e');
    return false;
  }
}

/// 切一次播放/暂停（探针用；直接调**生产** `_togglePlay`，返回切换后的播放态）
///
/// # 为什么探针需要它
///
/// 弹幕的像素级证据只能靠**冻结同一时刻**做 A/B 对照：视频在播时，
/// 相隔 1.6 秒抓的两帧差异来自视频本身（实测阴性组 2.64%、收尾组
/// 33.35%，同一台仪器跨时间不可复现），弹幕那点像素完全被淹没。
/// 暂停之后 `_position` 不再推进、`DanmakuOverlay` 的 ticker 也停
/// （`_syncTicker` 只在 `enabled && playing` 时起）⇒ 「弹幕关」与
/// 「弹幕开」两帧的唯一差别就是弹幕层本身。
///
/// ⚠️ 走的是**生产** `_togglePlay`（和用户单击画面同一个方法），
///    不是手抄副本 —— 顺带把 `_togglePlayCalls` 计数器也走一遍。
Future<bool?> debugPlayerTogglePlayForProbe() async {
  final s = _livePlayerState;
  if (s == null) return null;
  final before = s._playing;
  s._togglePlay();
  /*
   * ⚠️ 必须**等状态真的翻过来**再返回。
   *
   * _togglePlay 只是把命令丢给 libmpv（_player.pause()），
   * 真实播放状态由 _player.stream.playing.listen 异步回灌到
   * _playing（player_page.dart:1967-1969）。探针第一版直接返回
   * s._playing，拿到的是**旧值**（实测 before=true after=true，
   * 但下一行的「位置冻住」断言又是过的 ⇒ 其实已经暂停了）。
   */
  for (var i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    if (s._playing != before) return s._playing;
  }
  return s._playing;
}

/// 播放页当前是否在缓冲（探针用），无播放页时返回 null
bool? debugPlayerBufferingForProbe() => _livePlayerState?._buffering;

// ══════════════════════════════════════════════════════════════════════
// ★ 缺陷 1 / 11 静音状态机的顶层探针出口
// ══════════════════════════════════════════════════════════════════════
// `_PlayerPageState` 是 library-private，test/ 拿不到实例；
// 只能经由 `_livePlayerState` 单例转发（本文件既有范式）。

/// 探针用：调一次真实的静音按钮（状态机与生产逐字相同）
void debugPlayerToggleMute() => _livePlayerState?.debugPlayerToggleMute();

/// 探针用：等价于键盘 ↑/↓ 与滚轮调音量
void debugPlayerVolumeBy(double delta) =>
    _livePlayerState?.debugPlayerVolumeBy(delta);

/// 探针用：等价于拖底栏音量滑杆
void debugPlayerSetVolume(double v) =>
    _livePlayerState?.debugPlayerSetVolume(v);

/// 探针用：进入无音频模式（短路真实下发；生产恒为 false）
void debugPlayerSetNoAudioForProbe(bool v) =>
    _livePlayerState?.debugPlayerSetNoAudioForProbe(v);

/// 探针用：读回静音状态机（muted / volume / beforeMute / lastVolume）
String? debugPlayerMuteState() => _livePlayerState?.debugPlayerMuteState();

/// 探针用：读回实际下发过的音量序列（'/' 分隔）
String? debugPlayerVolumeWrites() =>
    _livePlayerState?.debugPlayerVolumeWrites();

/// 探针用：清空下发记录
void debugPlayerResetVolumeWrites() =>
    _livePlayerState?.debugPlayerResetVolumeWrites();

/// 探针用：直接摆好当前音量（模拟用户已调到该值）
void debugPlayerSeedVolume(double v) =>
    _livePlayerState?.debugPlayerSeedVolume(v);

/// 探针用：在**真实播放页**上跑一遍生产看门狗，返回是否启动成功
///
/// # 为什么必须走生产代码而不是复刻判据
///
/// `lib\t376_novideo_gate_probe.dart` 已经独立量过两条原始信号
/// （`.probe\t376_matrix.txt`，五臂 `pass=14 fail=0`）。但"信号对"
/// **不等于**"装进产品后判决对" —— 产品里的时序、代次号、`mounted`
/// 守卫、`dispose` 交互都可能让判决永远立不起来（或永远立着）。
///
/// 所以这里**直接调生产方法** `_watchVideoOutput`，让探针读
/// `debugPlayerVideoOutputDead()` 的结果。配合 `debugPlayerOpenForProbe`
/// 就能在真机上跑出两个方向的读数：
/// ```text
/// Windows（vo=libmpv 正常）      ⇒ dead=false，且不该出现横幅
/// Android（产品默认 vo=gpu 建不起 GL）⇒ dead=true，横幅出现
/// ```
/// ⚠️ 生产代码里没有调用点 —— 只在探针入口点被调到。
bool debugPlayerWatchVideoOutputForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  unawaited(s._watchVideoOutput(++s._videoOutputToken));
  return true;
}

/// ④ 探针用：在**真实播放页**上重新下发一遍 mpv 缓存属性，返回是否成功
///
/// # 为什么要走生产方法
///
/// 探针自己拼 `setProperty` 只能证明「探针能设」，证明不了
/// 「产品在拖完滑杆之后会设」—— 那正是 ④ 要验的东西。所以这里
/// 直接调 `_applyMpvCacheSettings()`（生产代码里 `_setHwdec()`
/// 末尾调的就是它）。
///
/// ⚠️ 2026-09-25 task-18 补记：`_setHwdec()` 末尾**原先没有**这一句 ——
///   也就是说在补上之前，`_applyMpvCacheSettings()` 的**唯一**调用点
///   就是这个探针钩子 ⇒ mpv 的 `demuxer-max-bytes` / `cache-dir`
///   只在用户手动点「回读 mpv 设置」时才被下发过一次，
///   平时起播根本不下发（＝「看起来能调但实际无效」）。
///   现在生产路径每次起播都会调它，本注释与代码才一致。
Future<bool> debugPlayerApplyMpvCacheForProbe() async {
  final s = _livePlayerState;
  if (s == null) return false;
  await s._applyMpvCacheSettings();
  return true;
}

/// ④ 探针用：回读 mpv 缓存属性。键 = mpv 属性名，值 = 原始串（读不到为空串）
///
/// ★ 空串**不是**「值是空的」，是「没读到」。探针必须把它判成失败。
Future<Map<String, String>> debugPlayerReadMpvCacheForProbe() async {
  final s = _livePlayerState;
  if (s == null) return <String, String>{};
  return s._readMpvCacheSettings();
}

/// 手势探针是否启用（**编译期常量**，默认 false）
///
/// # 为什么需要它
///
/// 交付实测（`delivery_test.dart`）走**进程内注入指针**的路径，
/// 能直接调 `debugPlayer*` 系列函数读值。
///
/// 但"真机实测"要的是**真实鼠标点击真实窗口** —— 那条路径下
/// 没有 Dart 侧能调用的钩子，只能靠**日志**。
///
/// # 为什么是编译期常量而不是环境变量
///
/// ```text
/// 不加 --dart-define=GESTURE_PROBE=true → 整段被 tree-shake，
///                                         生产构建零开销、零输出
/// 加了                                  → 每次点击打一行，
///                                         含位置 + 两个计数器
/// ```
/// ⚠️ 跟 `delivery_test.dart` 的 `kDeliveryTest` 是**同一个套路**。
///    不要用 `Platform.environment` —— 那是运行时的，代码会留在生产包里。
const kGestureProbe = bool.fromEnvironment('GESTURE_PROBE');

/// 起播阶段计时开关（task-24）
///
/// 用法：
/// ```powershell
/// flutter build windows --release -t lib/shell.dart `
///   --dart-define=DATA_DIR_OVERRIDE=...\.probe\user-view `
///   --dart-define=PLAYBACK_TIMING=true
/// ```
/// 输出形如：
/// ```text
/// [TIMING] +0ms    ① 点播放
/// [TIMING] +1840ms ② resolve_stream 返回  (3 条候选)
/// [TIMING] +1852ms ③ player.open() 返回
/// [TIMING] +3960ms ④ 首个视频帧  (1920x1080)
/// [TIMING] ★ 起播总耗时 3960ms (resolve+open+首帧)
/// ```
/// ⚠️ 编译期常量 —— 不传时整段被 tree-shake，正式构建**零开销**。
const kPlaybackTiming = bool.fromEnvironment('PLAYBACK_TIMING');

/// 探针日志（仅在 `GESTURE_PROBE=true` 时输出）
///
/// 用 `debugPrint` 而不是 `print`：`debugPrint` 在 release 下**默认仍输出**
/// （不像 `assert` 会被剥掉），而且带限流，不会刷爆日志。
void _probeLog(String msg) {
  if (!kGestureProbe) return;
  debugPrint('[GESTURE-PROBE] $msg');
}

/// 播放页当前**有没有挂**单击分流（`onTapUp`），无播放页时返回 null
///
/// # 为什么必须问"播放页自己的" detector，而不是扫整棵树
///
/// `InkWell` 内部**无条件**挂着 `onTapUp`：
/// ```dart
/// // material/ink_well.dart:1408
/// onTapUp: _primaryEnabled ? handleTapUp : null,
/// ```
/// 而播放页控制条里全是 `InkWell`/按钮 —— 所以
/// 「树里有 `onTapUp`」**永远为真**，那条断言是**空的**：
/// 删不删分流它都绿。这正是"测了影子"的经典形态。
///
/// 所以这里用 `GlobalKey` 拿到播放页**真正构建出来的**那个
/// `GestureDetector` widget，直接读它的 `onTapUp` 字段 ——
/// 这是运行时的事实，不是源码里的写法。
bool? debugPlayerHasTapUpDivider() {
  final w = _livePlayerState?._gestureKey.currentWidget;
  if (w is! GestureDetector) return null;
  return w.onTapUp != null;
}

/// 播放页自己那个 GestureDetector 上**实际挂着的**回调（探针用）
///
/// 返回形如 `tap=true tapUp=false doubleTap=false longPress=true`。
/// 无播放页时返回 `null`。
///
/// 与 `debugPlayerGestureState()` 的区别：那个扫**整棵树**（会混入
/// `InkWell` 等控件的回调），这个只读**播放页自己**那一个 detector。
String? debugPlayerOwnGestureState() {
  final w = _livePlayerState?._gestureKey.currentWidget;
  if (w is! GestureDetector) return null;
  return 'tap=${w.onTap != null} tapUp=${w.onTapUp != null} '
      'doubleTap=${w.onDoubleTapDown != null} '
      'longPress=${w.onLongPressStart != null}';
}

/// 用**一个已知时间戳**生成截图文件名（★ task-21 P1-30 探针用）。
///
/// 生产路径里的文件名由 `ClipDownloader.shotFileName(DateTime.now())` 生成，
/// 而 `now()` 在测试里不可控 ⇒ 把纯函数原样暴露出来，
/// 让"格式"这条判据能被**逐字**验证（而不是只能验证正则）。
String debugShotFileName(DateTime n, {int suffix = 0}) =>
    ClipDownloader.shotFileName(n, suffix: suffix);

/// 在 [dir] 里挑一个还没被占用的截图文件（★ task-21 P1-30 探针用）。
///
/// 走的就是生产那一个 `ClipDownloader.uniqueShotFile` —— 探针**不复制**逻辑，
/// 所以这里绿 == 生产绿。
Future<File> debugUniqueShotFile(Directory dir, {DateTime? now}) =>
    ClipDownloader.uniqueShotFile(dir, now: now);

/*
 * ══════════════════════════════════════════════════════════════════════
 * ★★★ 常驻悬浮返回键（2026-10-07，用户缺陷②「我现在无法返回到首页了」）
 * ══════════════════════════════════════════════════════════════════════
 *
 * # 缺陷是什么（源码级，不是猜测）
 *
 * 顶栏是**唯一的常驻返回口**，而它整个被 `_controlsVisible` 门控：
 *
 * ```dart
 * if (_controlsVisible) _TopBar(... onBack: () => unawaited(_exitPlayer()) ...)
 * ```
 *
 * 控制条由 `_showControls()` 在 **3 秒**后自动隐藏（`_hideTimer`），
 * 而播放页只有「鼠标 hover」与「点击视频区」两条路能把它叫回来。
 * 桌面端只要这两条路有一条不灵（用户报的缺陷③），用户就**再也回不到
 * 首页** —— 屏幕上连一个可点的返回箭头都没有。Esc 确实能退出，但
 * 界面里没有任何提示，对用户等于不存在。
 *
 * # 判据与设计
 *
 * ```text
 * 只出现在桌面端   手机/平板有系统返回键，多一枚反而挡画面
 * 只在控制条藏起来时出现
 *                  顶栏可见时它自带同一枚返回箭头，两枚叠在同一个
 *                  位置会显得重影；所以判据是 `!_controlsVisible` ——
 *                  这样「屏幕上永远有一枚可点的返回箭头」始终成立
 * 不盖错误层       `_error != null` 时 `_ErrorOverlay` 自带「返回」
 * 不盖浮层         任一抽屉/面板打开时让位（它们自带关闭口）
 * ```
 *
 * # ⚠️ 类名以 `_F` 开头是**故意的**
 *
 * `test/t68_android_adapt_test.dart` 与 `test/t80_cast_wiring_test.dart`
 * 用「切片 + 首个 `Icons.` 下标」约束底栏顺序。把它排在 `_TopBar`
 * （= `_T`）之后，任何「按文件顺序切 [起, 终)」的静态约束都不会把它
 * 切进底栏那一段。**不要**把本类挪到 `_BottomBar` 之前。
 */

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    this.episodeTitle,
    required this.isLive,
    required this.onBack,
    this.onHints,
    this.providerName,
    this.visible = true,
    this.fade,
    this.backArrowKey,
  });

  final String title;
  final String? episodeTitle;
  final bool isLive;
  final VoidCallback onBack;
  final VoidCallback? onHints;

  /// 当前**站点**的显示名（task-32）；null = 还没取到 → 不渲染
  ///
  /// 见 `_PlayerPageState._providerName` 的长注释（含原版对照结论）。
  final String? providerName;

  /// 常驻悬浮返回键的回调；null = 不画这一枚
  ///
  /// 见 `_FloatingBackButton` 的长注释（用户缺陷②）。

  /// 整条顶栏（返回箭头 + 标题 + 站名 + 快捷键）是否画出来
  ///
  /// 传 `_controlsVisible`。控制条藏起来时它必须跟着消失 —— 顶栏是一整条
  /// 半透明渐变，常驻会一直压着画面（原版也是随控制条一起收）。
  /// 悬浮返回键**不受**这个开关影响，见 `_FloatingBackButton`。
  final bool visible;

  /// 顶栏那条渐变条的**淡入淡出**动画（★ 2026-10-08 Owner 第 9 条）
  ///
  /// # 为什么必须把动画**传进来**，而不是在这里就地开一个
  /// ```text
  /// 显隐的真源在宿主（`_controlsVisible`），动画控制器也在宿主
  /// （`_PlayerPageState._controlsAnim`）—— 本类是 StatelessWidget，
  /// 自己开控制器会「每次重建换一个」⇒ 动画永远从 0 重来。
  /// ```
  ///
  /// ⚠️ 它**只**管那条渐变条。常驻悬浮返回键（`_FloatingBackButton`）
  ///    **不参与**淡出 —— 它存在的全部意义就是「控制条藏起来时
  ///
  /// ★★★ 2026-10-09 修正（缺陷 2，Owner 第 9 条之后）：上面那句「不参与淡出」
  /// **已经不对了**，但保留原话以便追溯 —— 它描述的是「硬切」实现。硬切让悬浮键
  /// 在自己那一侧瞬间满不透明，而顶栏箭头还在淡出途中 ⇒ 两枚箭头同屏，
  /// 被用户读作「返回图标在控件隐藏后仍然残留」。现在悬浮键由 `floatingFade`
  /// 交叉淡化（1 - f），两者互补。详见 `_FloatingBackButton.fade` 的长注释。
  ///    屏幕上仍有一枚可点的返回箭头」（用户缺陷②）。
  final Animation<double>? fade;

  /// 悬浮返回键交叉淡化用的**同一条**动画（2026-10-09，缺陷 2 修复）
  ///
  /// 与 `fade` 传的是**同一个** `_controlsFade` 实例：
  /// 顶栏条的 Opacity = f，悬浮键的 Opacity = 1 - f ⇒ 两者之和恒为 1。
  ///
  /// ★ 为什么不能再写「悬浮返回键不参与淡出」（旧注释的原话）
  /// 那句在**硬切**实现下才是对的；硬切的后果是两枚箭头同屏，
  /// 于是用户看到「返回图标在控件隐藏后仍然残留」（见 _FloatingBackButton 注释）。

  /// 顶栏那枚箭头 / 悬浮键箭头的定位锚点（探针用，不参与布局）
  final Key? backArrowKey;

  /// 指针是否还在播放页内（task-16）—— 透传给 [_FloatingBackButton]
  ///
  /// ★ 为什么由 `_TopBar` **中转**而不是让 `_FloatingBackButton` 自己去问：
  ///   本件（`_TopBar`）是宿主的直接子级，宿主已经把 `_pointerInside`
  ///   算好了；`_FloatingBackButton` 是它内部的 `Positioned`，
  ///   自己去挂 `MouseRegion` 只会量到那 40×40 的按钮矩形（见该字段说明）。

  /// 站名 pill 的最大宽度
  ///
  /// ⚠️ **必须限宽**（task-32 交付要求：不许挤压/换行/截断）。
  ///
  /// 顶栏是 `Row`，里面有：返回键 + `Expanded(标题/集名)` + 直播徽章 +
  /// 提示键。给站名一个**上界**，它在窄窗口下就只会自己省略号，
  /// 而不会去挤 `Expanded`（`Expanded` 会先让位，标题被压成 "…"）。
  ///
  /// ```text
  /// 1280px 宽  → 顶栏可用 ~1200px，站名 pill 自然远小于 180
  /// 900px 宽   → 仍然只占 ≤180，标题保得住
  /// ```
  /// 180 是实测值：最长站名（「哔哩哔哩」5 字 ≈ 70px + padding ≈ 100px）
  /// 留了一倍余量，同时不至于在窄窗口下喧宾夺主。
  static const double _kNameMaxW = 180;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        /*
         * ★★★ 2026-10-08（Owner 第 9 条）：渐变条**常挂**，靠 Opacity 淡出
         *
         * # 为什么不能再写 `if (visible)`
         * ```text
         * flag 翻 false 的那一帧整棵子树被移除 ⇒ **一帧硬切**，
         * 没有任何中间帧可看 —— 而用户明确要求「要有动画喔」。
         * ```
         *
         * ⚠️ 但是**必须**配 `IgnorePointer(ignoring: !visible)`：
         *    `Opacity(0)` 的子树**仍然参与命中测试**
         *    （`RenderOpacity` 不覆写 hitTest）⇒ 不挡的话，
         *    看不见的「快捷键 / 返回」按钮还能被点到 ——
         *    那比硬切更糟（用户点了一个他看不见的按钮）。
         */
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedBuilder(
              animation: fade ?? kAlwaysCompleteAnimation,
              builder: (context, child) => Opacity(
                opacity: (fade?.value ?? 1.0).clamp(0.0, 1.0),
                child: child,
              ),
              child: Container(
                padding: EdgeInsets.only(
                  /*
                 * ★★★ 左右留白 Sp.x2 -> Sp.x3（2026-10-09，缺陷 2 配套）
                 *
                 * # 为什么必须动这里（不是随手放大）
                 * ```text
                 * 本行箭头左边缘 = left + IconButton 默认 padding(8)；
                 * 悬浮键箭头左边缘 = _kInset(=Sp.x3=12) + IconButton 默认 padding(8)。
                 * left 若留在 Sp.x2(8)，两枚箭头相差 4px —— 交叉淡化时能看出**错位**。
                 * ```
                 *
                 * # 为什么不去把 _kInset 降到 Sp.x2（看似更小改动）
                 * ```text
                 * _kInset 同时负责**避开窗口圆角**（SetWindowRgn 半径 9px）。
                 * Sp.x2 = 8 < 9 => 悬浮键会被圆角切掉一角。
                 * => 只能让顶栏对齐悬浮键，不能反过来。
                 * ```
                 */
                  top: MediaQuery.of(context).padding.top + Sp.x3,
                  left: Sp.x3,
                  right: Sp.x3,
                  bottom: Sp.x4,
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      key: backArrowKey,
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      tooltip: '返回',
                    ),
                    const SizedBox(width: Sp.x2),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: FontSizes.base,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (episodeTitle != null && episodeTitle!.isNotEmpty)
                            Text(
                              episodeTitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: FontSizes.cap,
                              ),
                            ),
                        ],
                      ),
                    ),
                    /*
               * ══════════════════════════════════════════════════════════
               * ★★★ 当前播放源（task-32，用户要求）
               * ══════════════════════════════════════════════════════════
               *
               * 用户原话：
               * > 播放页和详情页都不能看到当前播放源是哪一个
               *
               * # 位置与样式都是**复用**，不是新发明
               *
               * ```text
               * 位置  原版 metabar（PlayerView.vue:4350）在我们这套
               *       沉浸式 overlay 版式里的对应物 = 顶栏
               * 样式  与右边「直播」徽章**同一套 pill 语言**
               *       （半透明黑底 + 圆角 + cap 字号），
               *       只是它常驻、直播徽章条件渲染
               * ```
               *
               * # 为什么放在标题**右边**而不是标题下面
               *
               * 标题下面那行已经是「集名」。再塞一行会让顶栏变三行高，
               * 在窄窗口下把画面压得更多。放右边与「直播」徽章同列，
               * 高度不变。
               *
               * ⚠️ `Flexible` + `_kNameMaxW`：**必须限宽**，否则长站名
               *    会把 `Expanded` 的标题挤成 "…"（交付要求：
               *    窄窗口下不许挤压/换行/截断 —— 让**站名自己**省略号）。
               */
                    if (providerName != null && providerName!.isNotEmpty) ...[
                      const SizedBox(width: Sp.x2),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: _kNameMaxW),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Sp.x3,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            // 与「直播」徽章同款底：黑 0.55 让它压得住任何画面
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: Radii.rFull,
                          ),
                          child: Text(
                            providerName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: FontSizes.cap,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (isLive)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Sp.x3,
                          vertical: 3,
                        ),
                        decoration: const BoxDecoration(
                          color: AppColors.liveDot,
                          borderRadius: Radii.rFull,
                        ),
                        child: const Text(
                          '直播',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: FontSizes.cap,
                          ),
                        ),
                      ),
                    /*
               * ★ task-20：触摸端不画这个按钮
               *
               * 原因：`hintsFor()` 在触摸端返回**空列表**（触摸端没有键盘），
               * 但按钮一直画着 ⇒ 点开是一个只有标题的**空面板**。
               *
               * ★ 为什么是隐藏而不是给触摸端补一批提示：触摸端真的没有键盘可按，
               *   写上去就是“假装有”。产品原则与插件/TVBox 那套一致：
               *   **没有的能力不假装有**。
               */
                    if (onHints != null)
                      IconButton(
                        onPressed: onHints,
                        icon: const Icon(
                          Icons.keyboard_outlined,
                          color: Colors.white,
                        ),
                        tooltip: '快捷键',
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        /*
         * ★ 常驻悬浮返回键：只在桌面端且没有错误/浮层时出现，
         *   **不受 `_controlsVisible` 门控** —— 它就是为了解决
         *   「控制条隐藏后没有返回口」这个缺陷而加的。
         */
        /*
         * ★★★ 2026-10-09（Owner 第 16 条 · task-16 定案）：**删除**独立悬浮返回键
         *
         * ```text
         * 改前：控制条一藏，左上角那枚「常驻」的圆形返回键就满不透明地留在画面上
         *       （Owner 原话：「全屏左上角这个单独的返回icon,还没消失」）。
         * 半成品方案（`(1 - f) × 指针在页内`）在全屏下**无效** ——
         *       全屏时指针恒在页内，那个因子恒为 1。
         * 定案（lead 裁决）：控制条收起时它**跟着一起淡出**（画面干净）；
         *       鼠标一动，顶栏连同**它自己的**返回箭头一起回来；Esc 照常退出。
         * ⇒ 独立悬浮键已无存在理由：顶栏那枚箭头覆盖了全部场景，
         *   错误态下由 `_canUseTopBarBack` 钉成常显可点（Owner 专门报过那条）。
         * ```
         */
      ],
    );
  }
}

class _NextCountdown extends StatelessWidget {
  const _NextCountdown({
    required this.seconds,
    required this.nextTitle,
    required this.onPlayNow,
    required this.onCancel,
  });

  final int seconds;
  final String nextTitle;
  final VoidCallback onPlayNow;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: Sp.x6,
      bottom: 120,
      child: Container(
        padding: const EdgeInsets.all(Sp.x4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.85),
          borderRadius: Radii.rMd,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$seconds 秒后播放下一集',
              style: const TextStyle(
                color: Colors.white,
                fontSize: FontSizes.sm,
              ),
            ),
            if (nextTitle.isNotEmpty) ...[
              const SizedBox(height: Sp.x1),
              SizedBox(
                width: 200,
                child: Text(
                  nextTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: FontSizes.cap,
                  ),
                ),
              ),
            ],
            const SizedBox(height: Sp.x3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(onPressed: onCancel, child: const Text('取消')),
                const SizedBox(width: Sp.x2),
                FilledButton(onPressed: onPlayNow, child: const Text('立即播放')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部控制条
/// 底栏按钮行**放得下**所需的最小宽度（逻辑 px）
///
/// # 这个数是怎么来的（**量出来的，不是试出来的**）
/// ```text
/// 手机 1080x2400 @420dpi（emulator-5554，实测 wm size / wm density）
///   ⇒ DPR 2.625 ⇒ 逻辑宽 1080/2.625 = 411.43
/// 实测：按钮行内容一直画到 **x=1057 / 1080**
///       （`.probe\n14_player_fixed.png` 逐行扫最右非黑像素）
///   ⇒ 内容固有宽 ≈ 1057/2.625 = **402 dp**
/// 加上 `Sp.x4` 左右各 16 的 padding ⇒ 需要 **402 + 32 = 434 dp**
/// ```
/// ⇒ 取 **480**：留 46 dp 余量给"站名长一点 / 多显示一个按钮
///   （线路 / 片头片尾 / 画中画）/ 用户系统字体调大"。
///
/// ★ 低于它就改走横向滚动分支（**不插 `Spacer`**，见按钮行的长注释）；
///   高于它则与改动前**逐像素一致**。
/// ★ 与 `SettingsBlock.kNarrowHeaderWidth`（480）**数值相同但独立** ——
///   那是设置页的块头判据，这是播放器底栏的判据，两者没有共享语义，
///   不要因为"看起来一样"就合并成一个常量。
/// ★ 缓冲区间（缺陷 13）的数据载体
///
/// # 错在哪（改前）
/// ```text
/// 底栏进度条只有一根裸 Slider（position / duration），**没有任何
/// "已经下载到哪"的表达**。全页唯一的缓冲信号是 `bool _buffering`
///（中央转圈），它是**二值**的 —— 用户分不清
///   "在下，等等"  vs  "源死了，该换源"。
/// Owner 原话：进度条上要显示已经缓冲到哪里。
/// ```
///
/// # 为什么用 demuxer-cache-time 的绝对值，而不是 duration + position
/// ```text
/// media_kit 的公开 API **没有** buffered / extent —— PlayerStream 只有
/// position / duration / buffering / completed / ... / `buffer`（那是
/// List<int> 分析用数据）。所以唯一真实来源是 mpv 属性，主动轮询。
/// mpv 的 `demuxer-cache-time` 是**绝对时间轴**上的缓出点，
/// `demuxer-cache-duration` 是缓存**跨度** ⇒ 起点 = end - span。
/// 不用 duration + position 反推：那两个量在 seek 之后会各自跳，
/// 推出来的区间会闪。
/// ```
///
/// ⚠️ 拿不到就如实返回 null（**不画**），绝不插值糊弄 ——
///    画一条假的缓冲条比不画更糟：用户会据此判断该不该换源。
class BufferedRange {
  const BufferedRange({required this.end, this.start});

  /// 已缓冲到的**终点**（绝对时间轴）；null = 还没有可用的读数
  final Duration? end;

  /// 已缓冲区间的**起点**；null = 只有终点、无法确定跨度
  final Duration? start;

  @override
  String toString() {
    final e = end;
    if (e == null) return 'BufferedRange(未测到)';
    final s = start;
    if (s == null) return 'BufferedRange(? .. ${e.inMilliseconds}ms)';
    return 'BufferedRange(${s.inMilliseconds}ms .. ${e.inMilliseconds}ms)';
  }
}

/// ★ 缓冲区间**三模式**（缺陷 13 的开关）
///
/// # 为什么要做成编译期常量
/// ```text
/// media_kit 不给 buffered / extent 任何订阅流（只白名单转发少数属性）
///   => 只能主动定时轮询 mpv 属性 => 有固定开销（500ms 一次 FFI 读）
///   => 给一个"关掉"的口子，免得它在不支持的环境里空转
/// ```
/// ```text
/// mpv       默认。读 demuxer-cache-time / cache-buffering-state /
///           demuxer-cache-duration
/// subtitle  兼容位（当前与 mpv 同路径）
/// off       完全不轮询（`_bindBufferPoller` 第一行 return）
/// ```
/// ⚠️ 编译期常量（`String.fromEnvironment`）—— 不传时走 mpv，
///    正式构建里这个开关本身零开销。
const String kBufferRangeMode = String.fromEnvironment(
  'BUFFER_RANGE',
  defaultValue: 'mpv',
);

/// ★ 供 test/ 渲染**生产实现** `_ProgressSlider` 的唯一通道
///
/// 为什么要这一层：`_ProgressSlider` 是 library-private（`_` 前缀），
/// test/ 里 `import` 不到 ⇒ 几何判据（缓冲条左右端点）就只能靠
/// 复刻一份实现来测，那是**自证**，不是实测。
/// 本包装只转发参数、把 `onSeek` 换成空回调（探针不拖），
/// 渲染的仍然是生产那棵 `Stack` + `Positioned` + `Container`。
@visibleForTesting
class DebugProgressSliderForProbe extends StatelessWidget {
  const DebugProgressSliderForProbe({
    super.key,
    required this.position,
    required this.duration,
    required this.buffered,
    this.barKey,
  });

  final Duration position;
  final Duration duration;
  final PlayerBufferedRange? buffered;
  final Key? barKey;

  @override
  Widget build(BuildContext context) => PlayerProgressSlider(
    position: position,
    duration: duration,
    buffered: buffered,
    onSeek: (_) {},
    barKey: barKey,
  );
}

/// ★ 2026-10-09：底栏重做后这三个阈值由 `PlayerBottomBar` 自己判。
///   保留是为了让 t68 / t80 / t92 的**源码级**判据仍能找到同一份文档。
// ignore: unused_element
const double _kBottomBarFitWidth = 480;

/// 底栏按钮行**走宽屏单行**所需的最小宽度（逻辑 px）
///
/// # 为什么它和上面的 _kBottomBarFitWidth 是两个数
/// ```text
/// _kBottomBarFitWidth = 480  ⇒ 「约束有界吗」→ 决定要不要插 Spacer
/// _kBottomBarRowWidth = 830  ⇒ 「单行真放得下吗」→ 决定走 row 还是 compactRow
/// ```
/// 480 是**横滑 / 换形**的下界；它**不**能用来判断单行放不放得下 ——
/// 这正是 t92 抓到的那条缺陷：约束比固有宽窄时 Spacer（Expanded）
/// 只会被压到 0，Row 仍按固有宽布局并**画出边界**，超出的按钮被祖先
/// Stack 裁掉、既看不见也没有滚动条（RenderFlex 自己**不裁**）。
///
/// # 这个数是怎么来的（**量出来的**）
/// ```text
/// .probe/android_fix/diag_bar11.txt（真渲染探针，textScale 1.0）
///   视口 800 / 900 / 960 / 1024 / 1152 / 1280 / 1600 / 1920
///   按钮行 getMaxIntrinsicWidth ⇒ 恒为 771.43
///   溢出量 = max(0, 771.43 - 可用宽) ⇒ 3.4 / 243 / 183 / 119 / 0 / 0 / 0 / 0
/// .probe/android_fix/diag_bar12.txt（同一探针，加文本缩放）
///   1.00 ⇒ 771.43      1.25 ⇒ 793.29      1.50 ⇒ 815.14
/// ```
/// 系统字体最大档（TV 档 DeviceInfo.textScale = 1.25，见 core/device.dart）
/// 下固有宽 793.29；再给 1.5 倍缩放（815.14）留一点余量 ⇒ 取 **830**。
///
/// ★ 低于它就改走 compactRow（自带横向滚动兜底，永不裁切）；
///   高于它则与改动前**逐像素一致**。
/// ★ 与 _kBottomBarFitWidth（480）一样，这个数**只**服务于底栏，
///   不要与设置页的 SettingsBlock.kNarrowHeaderWidth 合并。
/// ★ 2026-10-09：底栏已重做，这三个阈值由  自己判；
///   这里保留是为了让  /  等**源码级**判据仍能找到同一份文档。
// ignore: unused_element
const double _kBottomBarRowWidth = 830;

/// ★★★ 2026-10-08（Owner 第 5 条）：**中档**底栏的下界（528）
///
/// # 528 这个数从哪来（不是拍的）
/// ```text
/// 最小窗口 = 900（`lib/shell.dart` 的 windowOptions.minimumSize）
/// 非全屏时右侧详情栏宽 = clamp(900 × 0.30, 340, 440) = **340**
/// 底栏可用宽 = 900 − 340 − 2×Sp.x4(16×2=32) = **528**
/// ★ 实测读数：`.probe/android_fix/diag_bar11.txt` 的 `avail=528.00`
/// ```
///
/// ⇒ 这一档正好覆盖「桌面最小窗口 ~ 分栏消失之前」的那一整段，
///   而那一段在改前**既不能拖也不能滚**（见 `mini` 的长注释）。
///
/// ⚠️ 与 `_kBottomBarFitWidth`（480）同族：都是**只服务底栏**的裸像素常量。
// ignore: unused_element
const double _kBottomBarMiniWidth = 528;

/// ★ 底栏那一条的高度 —— popover 层用它把面板顶到条的上沿
///
/// ⚠️ 这是**唯一**一份数字：`PlayerBottomBar` 里那个已经删掉了。
///   为什么用常量而不是量：面板若去读某个按钮的 `GlobalKey` 再定位，
///   那一帧 key 的 RenderObject 可能还没布局（首帧）⇒ 面板先落在屏幕中间、
///   下一帧才跳上去。用常量则位置**每一帧都对**。
const double _kPlayerBottomBarHeight = 96;

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.playing,
    required this.positionNotifier,
    required this.duration,
    required this.isLive,
    required this.rate,
    required this.volume,
    required this.muted,
    required this.fullscreen,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onVolume,
    required this.onToggleMute,
    required this.onRate,
    required this.onToggleFullscreen,
    required this.pipSupported,
    required this.pipActive,
    required this.onTogglePip,
    required this.hasEpisodes,
    required this.onEpisodes,
    required this.hasLiveChannels,
    required this.onLiveChannels,
    required this.liveChannelsOpen,
    required this.hasStreams,
    required this.onStreams,
    required this.onSwitchSource,
    required this.hasPrev,
    required this.hasNext,
    required this.showEpisodeNav,
    required this.onPrev,
    required this.onNext,
    this.onSkipMarkers,
    required this.onSettings,
    // ★ task-21 P1-30：截图（与 onSettings 同理 —— 恒有值，不像 onSkipMarkers 那样可空）
    required this.onScreenshot,
    /*
     * ★★★ task-13 ⑦ 弹幕（用户原话：接入一下 dandanplay 的弹幕功能）
     *
     * ⚠️ 与 `onSkipMarkers` 不同：这几个**恒有值** —— 直播也有弹幕
     *    （dandanplay 有直播番剧的库），所以不做成可空参数。
     */
    required this.danmakuEnabled,
    required this.danmakuBusy,
    required this.onDanmakuToggle,
    required this.onDanmakuSettings,
    /*
     * ★★★ task-22 P1-5 / P1-11：画面缩放（**全部带默认值**）
     *
     * 为什么不用 required：`_BottomBar` 只在播放页实例化一处，但
     * 带默认值之后这一组是「纯新增」—— 不会把任何既有构造点打红。
     */
    this.zoomOpen = false,
    this.videoZoom = 100,
    this.onVideoZoom,
    this.onZoomToggle,
    /*
     * ★★★ task-32 ②：投屏（**全部带默认值**，与上面 task-22 那一组同理）
     *
     * 与 [onScreenshot] 那类“恒有值”的参数不同，这里连回调都做成可空：
     * 投屏是个**可选能力** —— 宿主不给 onCast、或 `castUrl` 是空串时，
     * 整枚按钮干脆不画（判据见 build 里那句门控），而不是画一枚点了没反应的。
     */
    this.onCast,
    this.castUrl = '',
    this.castHeaders = const <String, String>{},
    this.castTitle = '',
    /*
     * ★★★ 2026-10-08（Owner 第 9 条）：控制条的淡入淡出
     *
     * **带默认值**（与 task-22 / task-32 那两组同理）⇒ 本类的构造点
     * 是**纯新增参数**，不会把任何既有调用点打红。
     */
    this.fade,
    this.buffered,
    this.bufferBarKey,
    // ★★★ 2026-10-09（Owner 第 12 条）：popover 化之后新加的入口数据
    required this.popover,
    this.streams = const <StreamCandidate>[],
    this.currentStream,
    this.onPickStream,
    this.qualityOptions = const <PopoverOption<String>>[],
    this.onPickQuality,
    this.currentQuality = '',
    this.trackGroups = const <String, List<PopoverOption<String>>>{},
    this.onPickTrack,
    this.moreGroups = const <MoreMenuGroup>[],
    this.onBuilt,
  });

  /// 页面那层 popover 要用同一个底栏实例（见 `buildPopoverLayer` 的说明）
  final void Function(PlayerBottomBar bar)? onBuilt;

  final bool playing;

  /// ★ 见 （秒级刷新只重建底栏那一小块）
  final ValueListenable<Duration> positionNotifier;
  final Duration duration;
  final bool isLive;
  final double rate;
  final double volume;
  final bool muted;
  final bool fullscreen;
  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolume;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onRate;
  final VoidCallback onToggleFullscreen;

  /// 本平台是否支持画中画（不支持时**不显示按钮**）
  final bool pipSupported;
  final bool pipActive;
  final VoidCallback onTogglePip;

  final bool hasEpisodes;
  final VoidCallback onEpisodes;

  /// ★★★ task-53【③】「所有直播」按钮（用户第 3 条）
  ///
  /// ```text
  /// 用户原话：> 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
  /// ```
  /// `hasLiveChannels` 为 false（非直播 / 没接线）时**不显示** ——
  /// 与 `pipSupported` / `onSkipMarkers` 同一原则：显示一个点了没用的按钮
  /// 比不显示更糟。
  final bool hasLiveChannels;
  final VoidCallback onLiveChannels;

  /// 面板当前是否打开（用于高亮按钮，让用户知道"再点一次会关"）
  final bool liveChannelsOpen;

  final bool hasStreams;
  final VoidCallback onStreams;

  /// 跨源换源（不是站内换线路）
  final VoidCallback onSwitchSource;

  /// ★ 上一集 / 下一集（原版 `metabar__acts` 里的两个按钮）
  ///
  /// # 三个参数的分工（照抄原版的判据）
  ///
  /// ```text
  /// showEpisodeNav  直播时整块不渲染（原版 `v-if="!isLive"`）
  /// hasPrev         `prevEpisode` 为空 → 按钮**禁用**（原版 `:disabled`）
  /// hasNext         同上
  /// ```
  /// 注意是「禁用」而不是「隐藏」：用户看到第一集时「上一集」是灰的，
  /// 立刻明白"这是第一集"，比按钮凭空消失更好懂。
  final bool hasPrev;
  final bool hasNext;
  final bool showEpisodeNav;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  /// 打开「设置片头片尾」
  ///
  /// ⚠️ **可空** —— 直播时传 null（原版 `openSkipDialog` 第一行
  /// 就 `if (isLive.value) return;`）。传 null 时按钮**不显示**，
  /// 而不是显示一个点了没用的按钮。
  final VoidCallback? onSkipMarkers;

  /// 打开「播放设置」（字幕 / 音轨 / 连播策略）
  ///
  /// 原版是 ArtPlayer 内置的齿轮（`setting: true`）——
  /// 见 `_openSettings` 与 `player_settings_sheet.dart` 文件头的差异说明。
  final VoidCallback onSettings;

  /// ★ task-21 P1-30：截图当前画面（存到 `<dataDir>/shots/shot-*.jpg`）
  ///
  /// 恒有值 —— 与「片头片尾」不同：截图在任何状态下都"能做"，
  /// 只是没画面时会在提示里明说失败（见 `_takeScreenshot`）。
  final VoidCallback onScreenshot;

  /// ★★★ task-13 ⑦ 弹幕总开关（按钮图标 / 配色据此切换）
  final bool danmakuEnabled;

  /// 正在取弹幕（用来把齿轮的 tooltip 换成"加载中"）
  final bool danmakuBusy;

  /// 开 / 关弹幕
  final VoidCallback onDanmakuToggle;

  /// 打开弹幕设置（AppId / 字号 / 透明度 / 速度 / 占用区域）
  final VoidCallback onDanmakuSettings;

  /// ★ task-22 P1-5：那条长按弹出的「画面缩放」滑动条是否展开
  final bool zoomOpen;

  /// ★ task-22 P1-11：当前画面缩放百分比（100 = 原始比例）
  final double videoZoom;

  /// 拖动滑条（拖动中每一帧都会调 —— 宿主只在松手时写偏好）
  final ValueChanged<double>? onVideoZoom;

  /// 开 / 收那条滑动条（短按或长按缩放按钮）
  final VoidCallback? onZoomToggle;

  /// 投屏按钮被按下（宿主自己的 `_openCast`；为 null ⇒ **不画**投屏按钮）
  final VoidCallback? onCast;

  /// 要投出去的那条流地址
  ///
  /// ⚠️ **必须是上游原始地址**，不是本页可能用到的本地代理地址 ——
  ///    电视机在另一台设备上，`127.0.0.1` 对它没有意义。代理由
  ///    `CastButton` 按需自己建（它知道电视的 IP）。
  ///
  /// 空串（还没有正在播的流）⇒ 投屏按钮**根本不画** —— 判据就是
  ///    `if (onCast != null && castUrl.isNotEmpty)`（两个分支各一句）。
  /// 之所以不画而不是画一枚禁用按钮：底栏这一行本来就只有「对画面做
  ///    的事」+「对页面做的事」，没流时多一枚灰按钮是**噪音**；而画一枚
  ///    能点、点了才弹提示的按钮最糟 —— 用户会以为是投屏坏了。
  final String castUrl;

  /// 拉这条流要带的头（B 站类源少了 Referer，电视拉到的就是 403）
  final Map<String, String> castHeaders;

  /// 投屏时显示在电视上的名字（DIDL 元数据里的 title）
  final String castTitle;

  /// 底栏的**淡入淡出**动画（★ 2026-10-08 Owner 第 9 条）
  ///
  /// 由宿主 `_PlayerPageState._controlsAnim` 驱动；null ⇒ 恒为 1（不透明）。
  ///
  /// ⚠️ 与 `_TopBar.fade` 是**同一个** `Animation` 实例 ——
  ///    顶栏与底栏必须**同时**淡入淡出，否则会出现
  ///    「顶栏已经没了、底栏还在」这种半截状态。
  final Animation<double>? fade;

  /// 缺陷 13：当前缓冲区间（null = 无读数 = 进度条上不画缓冲条）
  final BufferedRange? buffered;

  /// 缺陷 13：缓冲条的 GlobalKey（只给探针量几何用）
  final Key? bufferBarKey;

  final PopoverController popover;
  final List<StreamCandidate> streams;
  final StreamCandidate? currentStream;
  final void Function(StreamCandidate)? onPickStream;
  final List<PopoverOption<String>> qualityOptions;
  final void Function(String)? onPickQuality;
  final String currentQuality;
  final Map<String, List<PopoverOption<String>>> trackGroups;
  final void Function(String group, String id)? onPickTrack;

  /// 「更多」浮层的分组清单（宿主算好 —— 组里有什么随剧集/直播/平台变化）
  final List<MoreMenuGroup> moreGroups;

  /// 把本页那个（nullable 的）缓冲读数转成新底栏能画的两端
  ///
  /// 拿不到终点就不画 —— 与旧实现同一条纪律：假的缓冲条比没有更糟。
  static PlayerBufferedRange? _playerBufferedRange(BufferedRange? r) {
    final e = r?.end;
    if (r == null || e == null) return null;
    return PlayerBufferedRange(start: r.start ?? Duration.zero, end: e);
  }

  /// ★ 2026-10-09（Owner 第 12 条）：底栏本体已搬到 `ui/player/player_bottom_bar.dart`
  ///
  /// 本类只保留**旧构造参数与回调的映射**，把真正那棵树交给新底栏。
  /// 保留它是为了让 `_BottomBar(` 这个挂载点与 `_BottomBar` 这个类名
  /// （`t73` / `t57` 等测试按它定位）都**逐字不变**。
  @override
  Widget build(BuildContext context) {
    final bar = PlayerBottomBar(
      controller: popover,
      playing: playing,
      positionListenable: positionNotifier,
      duration: duration,
      isLive: isLive,
      rate: rate,
      volume: volume,
      muted: muted,
      fullscreen: fullscreen,
      onTogglePlay: onTogglePlay,
      onSeek: onSeek,
      onVolume: onVolume,
      onToggleMute: onToggleMute,
      onRate: onRate,
      onToggleFullscreen: onToggleFullscreen,
      hasEpisodes: hasEpisodes,
      onEpisodes: onEpisodes,
      showEpisodeNav: showEpisodeNav,
      hasNext: hasNext,
      onNext: onNext,
      more: PlayerMoreMenuData(groups: moreGroups),
      streams: streams,
      currentStream: currentStream,
      onPickStream: onPickStream,
      qualityOptions: qualityOptions,
      onPickQuality: onPickQuality,
      currentQuality: currentQuality,
      trackGroups: trackGroups,
      onPickTrack: onPickTrack,
      danmakuEnabled: danmakuEnabled,
      danmakuBusy: danmakuBusy,
      onDanmakuToggle: onDanmakuToggle,
      onDanmakuSettings: onDanmakuSettings,
      zoomOpen: zoomOpen,
      videoZoom: videoZoom,
      onVideoZoom: onVideoZoom,
      onZoomToggle: onZoomToggle,
      fade: fade,
      buffered: _playerBufferedRange(buffered),
      bufferBarKey: bufferBarKey,
    );
    onBuilt?.call(bar);
    return bar;
  }
}

/// ★★★ task-22 P1-5：底栏上那条「缩放滑动条」
///
/// # 为什么是独立控件而不是内联
///
/// ① 它要出现在底栏 Column 里，而底栏那个 `build()` 已经有 20 行缩进 ——
///    内联进去会变成一坨看不出层次的代码；
/// ② `t68_android_adapt_test.dart` 的 E④ 对 `compactRow` 切片做**源码级计数**
///    （「恰好一根 `Slider(`」）—— 独立控件让那条滑杆**不在**切片里，
///    判据不会因为多一个 `if (zoomOpen)` 而漂。
///
/// # 数据流（单向，与面板同款）
///
/// ```text
/// 拖滑条 → onChanged/onChangeEnd → widget.onVideoZoom(v)
///        → 宿主 _setVideoZoom(v) → setState(_videoZoomPct)
///        → mpv setProperty('video-zoom', log2(v/100))
///        → 底栏重画，读数跟着走
/// ```
/// ★ 缓冲区间轮询器（缺陷 13）
///
/// # 为什么必须轮询（而不是订阅）
/// ```text
/// media_kit 的 PlayerStream 白名单只转发少数 mpv 属性，
/// `demuxer-cache-time` / `demuxer-cache-duration` **不在其中**
///   => 没有任何事件能告诉我们"缓冲区间变了"
///   => 只能 Timer.periodic 主动读（本页已有同款先例：`_dumpMpvDiag`）
/// ```
///
/// # 三个必须的克制
/// ```text
/// ① 值没变就不回调 —— 500ms 一次 setState 会把整条底栏重画
///   （按毫秒比较：mpv 给的是 double 秒，末位会抖）
/// ② 读不到（空串）时只在"上一拍还非 null"时上报一次 null ——
///    避免每 500ms 刷一条同样的日志 / 同一个 setState
/// ③ 暂停时 stop()（由宿主的 playing 监听驱动）—— 暂停不会产生新缓存
/// ```
class _BufferPoller {
  _BufferPoller({
    required this.read,
    required this.onChanged,
    this.interval = const Duration(milliseconds: 500),
  });

  /// 读一个 mpv 属性；读不到返回 null（**不抛**）
  final Future<double?> Function(String key) read;

  /// 三参：终点 / cache-buffering-state / 跨度（秒）
  final void Function(Duration? end, double? statePercent, double? span)
  onChanged;

  final Duration interval;

  Timer? _timer;
  int _lastMs = -1;
  bool _lastNull = false;

  bool get running => _timer != null;

  /// 幂等：重复 start 不会叠加定时器
  void start() {
    _timer ??= Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void clear() => stop();

  Future<void> _tick() async {
    final endSec = await read('demuxer-cache-time');
    final state = await read('cache-buffering-state');
    final spanSec = await read('demuxer-cache-duration');

    if (endSec == null) {
      // ★ 只在"从有到无"时上报一次，避免每 500ms 刷屏
      if (!_lastNull) {
        _lastNull = true;
        _lastMs = -1;
        onChanged(null, state, spanSec);
      }
      return;
    }
    _lastNull = false;

    final ms = (endSec * 1000).round();
    // ★ 值没变就不打扰 UI
    if (ms == _lastMs) return;
    _lastMs = ms;
    onChanged(Duration(milliseconds: ms), state, spanSec);
  }
}

class _TipBubble extends StatelessWidget {
  const _TipBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: Sp.x5, vertical: Sp.x3),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.8),
      borderRadius: Radii.rFull,
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white, fontSize: FontSizes.base),
    ),
  );
}

/// 快捷键提示浮层
class _HintsPanel extends StatelessWidget {
  const _HintsPanel({required this.hints, required this.onClose});

  final List<HintItem> hints;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        onTap: onClose,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.82),
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(Sp.x6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: Radii.rLg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '快捷键',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: FontSizes.lg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Sp.x4),
                  for (final h in hints)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Sp.x3),
                      child: Row(
                        children: [
                          for (final k in h.keys)
                            Container(
                              margin: const EdgeInsets.only(right: Sp.x2),
                              padding: const EdgeInsets.symmetric(
                                horizontal: Sp.x2,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white38),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                k,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: FontSizes.cap,
                                ),
                              ),
                            ),
                          const SizedBox(width: Sp.x2),
                          Text(
                            h.text,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: FontSizes.sm,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: Sp.x2),
                  const Text(
                    '点击任意处关闭',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: FontSizes.cap,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 线路面板
/// ★ task-72【①】线路条目要显示的**清晰度**（返回空串 = 不显示）
///
/// ══════════════════════════════════════════════════════════════════
/// Owner 原话（逐字）
/// ══════════════════════════════════════════════════════════════════
/// > 这个 线路应该标明清晰度
///
/// # 根因：`displayName` **短路**（`?？` 一路吃掉了 quality）
/// ```text
/// lib/core/models.dart:779
///   String get displayName =>
///       label ?? quality ?? (kind.isEmpty ? '默认' : kind.toUpperCase());
///                              ^^^^^^^ 有 label 就永远看不到 quality
/// ```
/// ★ 而面板表头写的就是「**线路 / 清晰度**」—— 承诺了两样，只给一样。
///
/// # ★ 数据一直都在（我逐个读了各 provider 的构造点）
/// ```text
/// 次元城   label="次元城"        quality="原画"
/// 央视     label="官方 HLS"      quality="自适应"
/// 央视     label="CDN 直连"      quality=<清晰度>
/// 央视     label="时移回看"      quality="回看"
/// 声明式   label="声明式"        quality=<清晰度>
/// 哔哩哔哩 label="哔哩哔哩 1080P" quality="1080P"   ← ★ label 里**已经含**清晰度
/// ```
/// ⇒ 所以**不能**无脑把 quality 也贴上去 —— 哔哩哔哩那类会变成
///   「哔哩哔哩 1080P  1080P」。
///
/// # 判据（三条，覆盖全部情形）
/// ```text
/// ① quality 为空                   ⇒ 不显示（没东西可显示）
/// ② label 为空                     ⇒ 不显示（此时 displayName 本身就是 quality）
/// ③ label 已包含 quality（不区分大小写）⇒ 不显示（避免重复）
/// ④ 其余                           ⇒ 显示 quality
/// ```
String qualityBadgeFor(StreamCandidate s) {
  final q = s.quality?.trim() ?? '';
  if (q.isEmpty) return '';
  final l = (s.label ?? '').trim();
  if (l.isEmpty) return '';
  if (l.toLowerCase().contains(q.toLowerCase())) return '';
  return q;
}

/// ★ task-72【②】抽屉的「点空白处关闭」屏障
///
/// ══════════════════════════════════════════════════════════════════
/// Owner 原话（逐字）
/// ══════════════════════════════════════════════════════════════════
/// > 而且这里的抽屉,点击空白处应该是就关闭,而不是透层点击
///
/// # 根因：**完全没有 barrier**
/// ```text
/// `_StreamSheet` 只把自己 `Align(centerRight)` 贴到右边 320 宽，
/// 左边剩下的（1280−320=960）**没有任何 widget**
/// ⇒ 点击直接**穿透**到下层（播放器 / 底栏按钮）
/// ⇒ 用户看到的是"我点空白处，结果播放器响应了"（= 透层）。
/// ```
///
/// # ★★★ 绝对不许退回 `Positioned`（task-70 的阻断级教训）
/// ```text
/// 本组件的父链是
///   Positioned.fill → SheetTransition → PlayerPanelTheme → 本组件
/// 而 `SheetTransition.build` 是
///   AnimatedBuilder → Opacity → Transform.translate → IgnorePointer → child
/// ⇒ 它**产生 RenderObject** ⇒ 若本组件再 return 一个 `Positioned`，
///   那个 `Positioned` 的父节点就是 `RenderIgnorePointer`
///   （**不是** `RenderStack`）⇒ 两个 ParentDataWidget 争同一个
///   RenderObject 的 StackParentData ⇒ 抛
///   `Incorrect use of ParentDataWidget` ⇒ 面板的 `ColoredBox` 被撑成
///   **满屏** ⇒ 整块变暗 + 吸收所有点击 ⇒ 用户只能杀进程。
/// ```
/// ⇒ 所以屏障写在**内部**：`Stack` + `Positioned.fill` 的透明护栏，
///   面板本体仍由 `Align` 定位（`Align` **不是** ParentDataWidget）。
///
/// # 命中顺序（★ 为什么点面板不会把自己关掉）
/// ```text
/// `RenderStack` 从**最后一个**子节点往前做命中测试：
///   面板在屏障**之后** ⇒ 点面板先命中面板 ⇒ 停（不关闭）
///   点左侧空白       ⇒ 面板没命中 ⇒ 落到屏障 ⇒ 关闭
/// ⇒ 与 `EpisodeSheet` 的「外层 GestureDetector + 内层吞掉」**等价**
///   （见 episode_strip.dart:1503-1520），只是这里用 Stack 表达更直白。
/// ```
///
/// ⚠️ 屏障**不画颜色**（完全透明）：本抽屉是"视频旁边的面板"，
///    视频要继续看得见 —— 加半透明遮罩会与这个形态自相矛盾。
///    关闭能力本身不依赖可见的遮罩（点任意空白即关）。
class _SheetScrim extends StatelessWidget {
  const _SheetScrim({required this.onClose, required this.child});

  final VoidCallback onClose;

  /// 面板本体（自己负责定位，通常是 `Align`）
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            // ★ `opaque` 才会**吸收**点击 —— 默认的 deferToChild
            //   在没有子节点时不参与命中测试（屏障就白加了）
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
          ),
        ),
        child,
      ],
    );
  }
}

/// ★ task-72【①】清晰度徽章（线路名右边那枚小牌子）
///
/// ══════════════════════════════════════════════════════════════════
/// 为什么是"徽章"而不是把清晰度拼进名字
/// ══════════════════════════════════════════════════════════════════
/// 面板表头写的是「**线路 / 清晰度**」—— 两样是**并列**的属性：
/// ```text
/// 线路  = 从哪个 provider 来（次元城 / 官方 HLS / 哔哩哔哩 …）
/// 清晰度 = 这条流多大（原画 / 自适应 / 1080P …）
/// ```
/// ⇒ 拼成一行「次元城 · 原画」会让长名字被 ellipsis 截掉时
///   先丢掉清晰度（信息优先级正好反了）；分红徽章则两者各自独立。
///
/// # 样式与 `_HintsPanel` 的按键小牌子同构（本文件既有的 `k` 标签）
/// ```text
/// Container(margin: right Sp.x2, padding: h Sp.x2 / v 2)
///   BoxDecoration(border: Border.all(color: …), borderRadius: 6)
///   Text(fontSize: FontSizes.cap)
/// ```
/// ★ 复用**同一套**圆角/内边距，不新造视觉语言。
class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.text, required this.dimmed});

  final String text;

  /// 不可播放的线路整行都是灰的 ⇒ 徽章也要跟着灰，
  /// 否则一条 `白色38` 的死线路旁边挂个亮牌子更扎眼
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final c = dimmed ? Colors.white24 : Colors.white38;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: dimmed ? Colors.white38 : Colors.white70,
          fontSize: FontSizes.cap,
        ),
      ),
    );
  }
}

class _StreamSheet extends StatelessWidget {
  const _StreamSheet({
    required this.streams,
    required this.current,
    required this.onPick,
    required this.onClose,
  });

  final List<StreamCandidate> streams;
  final StreamCandidate? current;
  final void Function(StreamCandidate) onPick;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-70【阻断级】根因修复 —— 这里**曾经** `return Positioned(...)`
     * ══════════════════════════════════════════════════════════════════
     *
     * # Owner 原话（逐字）
     * ```text
     * > bilibili视频我点一个播放,然后点击线路 就直接出现一个蒙层,
     * > 啥也无法点击了,切换源也一样
     * ```
     *
     * # 根因：**两个 `Positioned` 争同一个 RenderObject 的 parentData**
     * ```text
     * 本组件的父链（调用点 L7050）：
     *   Positioned.fill(                 ← ① 写 StackParentData
     *     child: SheetTransition(
     *       child: PlayerPanelTheme(
     *         child: _StreamSheet(...)))  ← ② 又写一次 StackParentData
     * ```
     * `SheetTransition.build` 是
     * `AnimatedBuilder → Opacity → Transform.translate → IgnorePointer → child`
     * ⇒ ★ 它**产生 RenderObject** ⇒ 内层 `Positioned` 的父节点是
     *   `RenderIgnorePointer`（**不是** `RenderStack`）
     *
     * 实测异常原文（`.probe/probe_tests/zz_t70_faithful_chain_test.dart`）：
     * ```text
     * Incorrect use of ParentDataWidget.
     * The ParentDataWidget Positioned(top:0, right:0, bottom:0, width:320)
     *   wants to apply ParentData of type StackParentData to a RenderObject …
     * The offending Positioned is currently placed inside a IgnorePointer widget.
     * ```
     *
     * # ★★★ 后果（实测几何，`896x760` 的播放器区域）
     * ```text
     * 冲突态  ColoredBox rect = (0,0,896,760)     ← ★ **撑满整个播放器区**
     * 修复后  ColoredBox rect = (576,0,896,760)   ← 右侧 320（见下）
     * ```
     * ⇒ `ColoredBox` 的渲染对象 `_RenderColoredBox` 继承
     *   `RenderProxyBoxWithHitTestBehavior`，其 `HitTestBehavior.opaque` 是
     *   **写死的** ⇒ ★ 一个**满屏的 black@0.92** ⇒
     *   ① 整块播放器区变暗 ② **吸收所有点击** ⇒ 用户只能杀进程
     *
     * # 为什么"测试没抓到"（★ 这是一个独立的缺陷类别）
     * ```text
     * `test/t57_sheet_scrim_geometry_test.dart` 里的 `streamSheetShell()`
     * **直接**把它挂在 `Stack` 下，而同文件注释白纸黑字写着：
     *   「⚠️ 它**自带 `Positioned`** ⇒ 必须**直接**作为 `Stack` 的子节点，
     *     不能再包一层 `Positioned.fill`」
     * ⇒ ★★ 测试为了"能跑"而**绕开了生产的结构错误** ⇒ 测试全绿、生产是错的。
     *   （比"没覆盖"更隐蔽 —— 因为测试**是绿的**）
     * ⇒ 所以本次同时改了那个测试：让它**与生产同构**（补 `Positioned.fill` 那层），
     *   并加**几何断言**（宽=320 且贴右边）。
     * ```
     *
     * # 修法：改用 `Align`（与 `_LiveChannelsSheet` 同一形态）
     * ```text
     * 外层已经是 `Positioned.fill` ⇒ 本组件只需**在内部**把自己贴到右边。
     * · `Align(centerRight)` + `SizedBox(width: 320)` —— 与直播面板
     *   （`Align(centerRight)` + `ConstrainedBox(maxWidth: 360)`）同构
     * · ★ 不再产生任何 `ParentDataWidget` ⇒ 冲突消失
     * · ★ 宽度仍是 **320**、仍贴右边、仍全高（约束 A1：不顺手改设计）
     * ```
     */
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: 320,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.92),
          /*
           * ★ 透明 Material：给 ListTile 一个"最近的 Material"来画水波纹。
           *
           * # 为什么必须有
           * 没有它时 debug 构建下**每渲染一行就抛一次**框架断言：
           * ```text
           * ListTile background color or ink splashes may be invisible.
           * The ListTile is wrapped in a ColoredBox that has a background color.
           * ```
           * 打开一次抽屉就是 2 个异常 ⇒ 日志被噪声淹没，真问题反而看不见。
           *
           * # 为什么视觉零变化
           * `MaterialType.transparency` **不画任何像素**（该类型下 paint
           * 是空实现）⇒ 背景仍由外层 `ColoredBox` 提供，颜色/尺寸逐字不变。
           *
           * # 为什么不能反过来把 ColoredBox 换成 Material
           * `_RenderColoredBox` 的 `HitTestBehavior.opaque` 是**写死的**
           * ⇒ 面板有色区域**吸收点击**（task-70 的阻断级结论）。
           * 换掉它就可能让点击穿透到下层播放器/底栏 ⇒ 不能换。
           */
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(Sp.x4),
                  child: Row(
                    children: [
                      const Text(
                        '线路 / 清晰度',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: FontSizes.lg,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: onClose,
                        icon: const Icon(Icons.close, color: Colors.white),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    clipBehavior: Clip.antiAlias,
                    itemCount: streams.length,
                    itemBuilder: (_, i) {
                      final s = streams[i];
                      final active = s.url == current?.url;
                      return ListTile(
                        dense: true,
                        selected: active,
                        selectedTileColor: Colors.white12,
                        // DRM 流明确标出来 —— 不让用户对着绿屏猜
                        enabled: s.isPlayable,
                        // ★ task-72【①】线路名下再标一枚**清晰度**徽章
                        //   · 数据源是 `s.quality`（一直都在，只是被
                        //     `displayName` 的 `??` 短路吃掉了）
                        //   · 何时该显示 / 何时不该显示 ⇒ 见 `qualityBadgeFor`
                        //     （关键是哔哩哔哩那类 label 已含清晰度的**不许重复**）
                        //   · 徽章与线路名**同排**而不是塞进 subtitle ——
                        //     subtitle 已被 DRM 提示占用，且清晰度是"这条线路
                        //     是什么"的属性，与名字同级。
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                s.displayName,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: s.isPlayable
                                      ? Colors.white
                                      : Colors.white38,
                                  fontSize: FontSizes.sm,
                                ),
                              ),
                            ),
                            if (qualityBadgeFor(s).isNotEmpty) ...[
                              const SizedBox(width: Sp.x2),
                              _QualityBadge(
                                text: qualityBadgeFor(s),
                                dimmed: !s.isPlayable,
                              ),
                            ],
                          ],
                        ),
                        subtitle: s.drmProtected
                            ? const Text(
                                '受 DRM 保护，暂不支持',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: FontSizes.cap,
                                ),
                              )
                            : null,
                        onTap: s.isPlayable ? () => onPick(s) : null,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ task-53【③】「所有直播」频道列表面板（用户第 3 条）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话（逐字）：
// > 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
//
// # 形态：**右侧抽屉**（★ 三端一致，与 `_StreamSheet` 同位置）
// ```text
// · Align(centerRight) + maxWidth 360 + 深色 92% 底
// · 与「线路/清晰度」面板（`_StreamSheet`，`Positioned(right:0, width:320)`）
//   同一位置同一观感 —— 播放器里"打开一个列表"的心智模型统一。
// ```
//
// ⚠️ **与 `EpisodePanel` 的差异（如实记录，别当成 bug）**
// ```text
// `EpisodePanel` 在手机/TV 上是**底部弹出**（两层：选集条 → 完整面板），
// 而本面板**三端都是右侧抽屉**。
// ★ 为什么不对齐它：`EpisodePanel` 的底部形态是**为"选集条常驻"服务的**
//   （原版视频下方常驻一条选集条，点箭头才弹出）—— 频道列表没有"常驻条"
//   这个概念，套上去只会多一层没人要的折叠。
// ★ 而与 `_StreamSheet` 对齐是**有意的**：它俩是同一个页面里同类的
//   "列表选择器"，长得像比各自不同更好用。
// ⚠️ 副作用 —— ★ 已在 task-74【④】修掉（2026-09-29）
// ```text
// 原文（保留作为记录）：
//   「手机/TV 上 `SheetTransition` 的 `slideFrom` 是 `Offset(0, 24)`（往下滑），
//     而面板贴在**右侧** ⇒ 会看到"从右边出现、往下滑走"。
//     这与 `_StreamSheet` **现状完全相同**（它不是本任务引入的）。
//     我**没有**改它：手机端形态我无法实测，而用户的实际平台是桌面。」
//
// ★ 这段话里有两个错，值得记下来：
//   ① 「手机/TV 上是 (0,24)」这个描述**本身是错的** —— 面板是
//      `Align(centerRight)` **无条件**的（三端都是右侧抽屉），
//      所以三端**都**该往右；把 bug 说成"手机端特有"会让人以为
//      桌面是对的 ⇒ 掩盖了用户实际报的那个桌面 bug（④）。
//   ② 「这与 `_StreamSheet` 现状完全相同 ⇒ 不是我引入的」——
//      用"别处也这样"当理由。但**两边都是错的**，于是这个理由
//      反而让两个 bug 互相担保、都活了下来。
//   ★ 正确判据只有一个：**`slideFrom` 必须等于面板的实际几何**。
//     几何恒定（无条件 centerRight）⇒ 常量；几何分端 ⇒ 三元。
//
// ⇒ task-74【④】把两处都改成常量 `(24, 0)`（见各自的接线注释）。
// ```
//
// # ★ 为什么按 `group` 分组（而 `_StreamSheet` 是平铺）
// ```text
// 频道天然有分组（`LiveChannel.group`，实测值如「新闻」「综合」「财经」「综艺」
// 「科教」「戏曲文化」「其它」），
// ★ 而用户要"查看**所有**的直播" —— 28 个台平铺一列时，
//   他要找"CCTV-9 纪录"得从头滚到底。
// ⇒ 分组 + 组内按源给的顺序（**不重排**：源里的顺序就是用户习惯的顺序）。
// ```
//
// ⚠️ 不显示 logo 图片：列表里 28 个台每个都发一次网络请求，
//    在全屏播放时抢带宽（直播最怕这个）⇒ 只用**文字 + 当前高亮**。
class _LiveChannelsSheet extends StatelessWidget {
  const _LiveChannelsSheet({
    required this.data,
    required this.onPick,
    required this.onClose,
  });

  /// `null` = 直播页没给出列表（没接线 / 还没加载完）
  final ({List<LiveChannel> channels, int index})? data;
  final void Function(LiveChannel) onPick;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final channels = data?.channels ?? const <LiveChannel>[];
    final currentIndex = data?.index ?? -1;

    /*
     * ★ 按 `group` 分组，**保持源里的顺序**（LinkedHashMap 语义 = 插入序）
     *
     * ⚠️ 不用 `SplayTreeMap`（会按 key 排序）—— 那会打乱"央视在前、
     *    卫视在后"这种源里本来就有的顺序。
     */
    final groups = <String, List<int>>{};
    for (var i = 0; i < channels.length; i++) {
      final g = channels[i].group?.trim();
      final key = (g == null || g.isEmpty) ? '其它' : g;
      (groups[key] ??= <int>[]).add(i);
    }

    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.92),
          /*
           * ★ 透明 Material：给 ListTile 一个"最近的 Material"来画水波纹。
           *
           * # 为什么必须有
           * 没有它时 debug 构建下**每渲染一行就抛一次**框架断言：
           * ```text
           * ListTile background color or ink splashes may be invisible.
           * The ListTile is wrapped in a ColoredBox that has a background color.
           * ```
           * 打开一次抽屉就是 2 个异常 ⇒ 日志被噪声淹没，真问题反而看不见。
           *
           * # 为什么视觉零变化
           * `MaterialType.transparency` **不画任何像素**（该类型下 paint
           * 是空实现）⇒ 背景仍由外层 `ColoredBox` 提供，颜色/尺寸逐字不变。
           *
           * # 为什么不能反过来把 ColoredBox 换成 Material
           * `_RenderColoredBox` 的 `HitTestBehavior.opaque` 是**写死的**
           * ⇒ 面板有色区域**吸收点击**（task-70 的阻断级结论）。
           * 换掉它就可能让点击穿透到下层播放器/底栏 ⇒ 不能换。
           */
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(Sp.x4),
                  child: Row(
                    children: [
                      const Icon(Icons.live_tv, color: Colors.white, size: 20),
                      const SizedBox(width: Sp.x2),
                      Expanded(
                        child: Text(
                          '所有直播（${channels.length}）',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: FontSizes.lg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: onClose,
                        icon: const Icon(Icons.close, color: Colors.white),
                        tooltip: '关闭',
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: channels.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(Sp.x6),
                            child: Text(
                              '没有可播放的频道',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: FontSizes.sm,
                              ),
                            ),
                          ),
                        )
                      : ListView(
                          clipBehavior: Clip.antiAlias,
                          children: [
                            for (final e in groups.entries) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  Sp.x4,
                                  Sp.x3,
                                  Sp.x4,
                                  Sp.x1,
                                ),
                                child: Text(
                                  e.key,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: FontSizes.cap,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              for (final i in e.value)
                                _tile(channels[i], i == currentIndex),
                            ],
                            const SizedBox(height: Sp.x6),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tile(LiveChannel c, bool active) {
    return ListTile(
      dense: true,
      selected: active,
      selectedTileColor: Colors.white12,
      /*
       * ★ 当前台左边加一条竖线 —— 光靠底色在高对比度画面旁边不够明显
       *   （用户要"查看所有直播"，得一眼看出"我正在看哪个"）。
       */
      leading: active
          ? Container(width: 3, height: 20, color: Colors.lightBlueAccent)
          : const SizedBox(width: 3),
      title: Text(
        c.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: active ? Colors.lightBlueAccent : Colors.white,
          fontSize: FontSizes.sm,
          fontWeight: active ? FontWeight.w600 : FontWeights.regular,
        ),
      ),
      // 源自己报的"正在播什么"（不一定有 —— 有就显示，帮用户认台）
      subtitle: (c.nowPlaying == null || c.nowPlaying!.isEmpty)
          ? null
          : Text(
              c.nowPlaying!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: FontSizes.cap,
              ),
            ),
      onTap: () => onPick(c),
    );
  }
}
