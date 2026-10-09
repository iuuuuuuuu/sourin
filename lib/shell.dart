// ═══════════════════════════════════════════════════════════════════════
//  源影 Flutter 版 —— 应用外壳（自定义标题栏 + 底栏导航）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 的两条硬要求（2026-09-22 原话）
//
// ```text
// ① 「ui要好看,可以引入外部ui库」
//      → 用 forui
// ② 「操作逻辑都还要原来的保持一样的」
//      → 见 INTERACTION-CONTRACT.md，逐条对齐
// ③ 「顶部那个操作也要自己实现,自带的还是不好看」
//      → ★ 标题栏必须**自绘**，不能用系统原生标题栏
// ```
//
// # ③ 为什么必须自绘
//
// Windows 原生标题栏是系统画的：白底、方角、字体固定、按钮样式固定。
// 它和应用的深色玻璃风格**没法融合** —— 会出现一条突兀的白色横条。
//
// 自绘的方案：
// ```text
// ① 窗口设 decorations: false（去掉系统标题栏）
// ② 自己画一条 AppBar：拖动区 + 最小化/最大化/关闭按钮
// ③ 拖动区用 window_manager 的 startDragging()
// ④ 窗口圆角也自己画（CSS 圆角那套在 Flutter 里用 ClipRRect）
// ```
//
// ⚠️ 代价：自绘标题栏必须自己处理
// ```text
// · 拖动移动窗口
// · 双击最大化/还原
// · 贴边时的最大化行为（Windows 的 Aero Snap）
// · 高分屏缩放
// ```
// 所以引入 `window_manager` 这个成熟包，不要自己调 Win32。
//
// # 交互逻辑对齐（见契约文档）
//
// | 原版 | 这里 |
// |---|---|
// | 底栏 5 项：发现/直播/追更/搜索/设置 | 同样 5 项，同样顺序 |
// | detail/browse 隐藏底栏 | 同样隐藏 |
// | 按 tab 序号定切换方向 | 同样实现 |
// | 追更带未读 badge | 同样保留 |
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'package:path_provider/path_provider.dart';

import 'core/app_tray.dart';
import 'core/device.dart';
import 'core/ffi.dart';
import 'core/ui_prefs.dart';
import 'core/window_bounds.dart';
import 'delivery_test.dart';
import 'core/sourin_api.dart' show SectionSource, SourinApi;
/*
 * ⚠️ 只 `show Episode`（集成任务 M2）
 *
 * 遥控 `play_item` 要把补齐后的剧集列表交给 `PlayRequestData`，
 * 而 `shell.dart` 原先**完全没 import 过 `core/models.dart`**
 * （`SectionSource` 是从 `sourin_api.dart` 里 show 出来的）。
 * Dart 的 import **不会传递** —— `detail_page.dart` / `remote_bridge.dart`
 * 各自 import 了 models，但对本文件不可见。
 *
 * 用 `show` 而不是整包 import：`shell.dart` 是个 2700 行的大文件，
 * 无差别引入 `models.dart` 的全部类型会埋下与页面同名符号冲突的隐患
 * （本项目已因"两套 Material"吃过一次命名冲突的苦）。
 */
import 'core/models.dart' show Episode, Favorite, Progress, followRemainingByKey;
import 'ui/browse_page.dart';
import 'ui/spatial_nav.dart';
import 'ui/app_theme.dart';
import 'ui/tokens.dart';
import 'ui/widgets/app_toast.dart';
import 'ui/widgets/window_frame.dart';
// ★ task-17：手机端系统栏（状态栏/导航栏）刷成内容区同色
import 'ui/system_ui.dart';
// ★ task-55：页面切换动画风格（用户在设置页里选，tab 切换跟随）
import 'ui/widgets/page_transition.dart';
// ★ task-55：`MotionPrefs.resolve` —— 系统"减少动态效果"时强制无动画
import 'ui/widgets/motion_prefs.dart';
import 'ui/titlebar_visibility.dart';
// ★ task-11 A1：`MaterialApp.builder` 里挂全局 `TextScaler`（TV ×1.25）
//   ⚠️ 平台判定**不在本文件** —— A1 修复后 `defaultTargetPlatform` /
//   `TargetPlatform` 在这里只剩注释提及，所以 `foundation.dart` 的 show 列表
//   已把它们去掉（留着就是 unused import）。唯一真源是
//   `AppMetrics.effectiveTextScale`（`ui/tokens.dart`），它同时管住
//   「挂上去的 TextScaler」与「卡片文字区高度」。
// ★ task-3 ⑲「已缓存」底部页（列表 = 真扫下载目录）
import 'ui/cache_page.dart';
import 'ui/detail_page.dart';
import 'ui/follow_page.dart';
import 'ui/home_page.dart';
import 'ui/live_page.dart';
// ★ task-58：合并页（上播放器 + 下详情）—— 详情页入口现在指向它
import 'ui/media_page.dart';
import 'ui/search_page.dart';
import 'ui/settings_page.dart';
import 'ui/player_page.dart';
import 'ui/remote_bridge.dart';
// ★ 真机拖拽自检（默认关，`SOURIN_DRAG_SELFTEST=1` 才跑）
import 't458_drag_selftest.dart';
import 'ui/app_palette.dart';
import 'ui/app_scaffold.dart';

/// ★ 是否桌面平台（Windows / macOS / Linux）
///
/// # 为什么要集中成一个常量（2026-09-22 实测教训）
///
/// 我一开始在三处各写了一遍 `Platform.isWindows || isMacOS || isLinux`，
/// 结果漏掉一处就炸：
/// ```text
/// MissingPluginException(No implementation found for method isMaximized
///   on channel window_manager)
/// ```
/// 因为 `window_manager` 的原生端**只在桌面注册**。
///
/// 所以规则是：**每个平台相关插件调用点，都要先问「这个平台有吗」**，
/// 而「是不是桌面」只在这一处定义，避免写法不一致。
///
/// 平台差异清单（目前已知）：
/// ```text
/// 能力              桌面   Android   说明
/// window_manager     ✓       ✗      自绘标题栏（移动端系统自带）
/// 自绘标题栏          ✓       ✗      移动端画了会变成"双层标题"
/// 存储权限            ✗       ✓      Android 要 manifest 声明
/// hwdec 后端      d3d11va  mediacodec 各平台硬件加速接口不同
/// ```
final bool kIsDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
/// 底栏条目 —— **顺序与语义必须与原版一致**
///
/// 源：`src/App.vue` L79–109
/// 顺序有语义：切换动画方向靠它算（见 `_transitionDir`）
enum AppTab {
  home('发现', '/'),
  live('直播', '/live'),
  follow('追更', '/follow'),
  search('搜索', '/search'),
  /*
   * ★ task-3 ⑲ 新增「已缓存」页（Owner 原话）：
   * > 对于已下载的,底部是不是应该加个已缓存的页面?
   * > 然后有封面,并且显示出来缓存了多少
   *
   * ⚠️ 顺序即**底栏顺序**：这里必须排在 settings **之前** ——
   *    用户看到的第 5 项就是「已缓存」，设置被挤到第 6 项。
   *    枚举顺序另有语义：`_transitionDir` 靠 index 差算切换方向，
   *    插在中间（而不是末尾）会让「搜索 → 已缓存」的动画方向
   *    与「搜索 → 设置」不同 —— 这正是我们要的（它物理上排在前）。
   * ⚠️ 往这里加成员会**同时**影响 5 处，改完必须全部核对：
   *    `_icons` / `_iconsActive`（漏加 = **运行时 null 崩**，见 :167 的 `[this]!`）、
   *    `_pageFor` 的 switch（无 default ⇒ 漏 case 是编译期非穷尽错误）、
   *    `_pageCache`（按 values.length 自动扩容，无需改）、
   *    底部栏宽度 `_tabWidthFor`（用 values.length 均分 ⇒ 每格变窄）。
   */
  cached('已缓存', '/cached'),
  settings('设置', '/settings');

  const AppTab(this.label, this.path);
  final String label;
  final String path;

  static const _icons = {
    AppTab.home: Icons.explore_outlined,
    AppTab.live: Icons.live_tv_outlined,
    AppTab.follow: Icons.star_border_rounded,
    AppTab.search: Icons.search_rounded,
    // ★「已缓存」用 download_done 语义（**不是** folder）——
    //   Owner 要的是"已经存下来的东西"，folder 会让人以为是下载目录入口。
    AppTab.cached: Icons.download_done_outlined,
    AppTab.settings: Icons.settings_outlined,
  };
  static const _iconsActive = {
    AppTab.home: Icons.explore,
    AppTab.live: Icons.live_tv,
    AppTab.follow: Icons.star_rounded,
    AppTab.search: Icons.search_rounded,
    AppTab.cached: Icons.download_done_rounded,
    AppTab.settings: Icons.settings,
  };

  IconData icon({required bool active}) =>
      (active ? _iconsActive : _icons)[this]!;
}

/// ★★★ 当前**可见**的 tab —— 保活（KeepAlive）后页面用它判断"我还在不在前台"
///
/// # 为什么必须有它（保活引入的**新**问题）
///
/// 保活 ⇒ 直播页切走后**不销毁** ⇒ 内嵌播放器会**在后台继续出声**。
/// 所以需要一个"可见性"信号：
/// ```text
/// 不可见时  pause()      ← ★ 不是 dispose（保活的意义就是解码器不丢）
/// 恢复可见时 按用户意图续播（见下面的 _pausedByHide 用法）
/// ```
///
/// # 为什么用 `InheritedNotifier` 而不是自己传回调
///
/// ```text
/// ① Flutter 官方推荐的"向下暴露可监听状态"方式
/// ② 子页面只需 `ShellScope.isActive(context, AppTab.live)` ——
///    shell **不需要**知道有哪些页面关心它（解耦）
/// ③ `ValueNotifier` 变化时只重建**真正依赖它**的 widget
///    （比 setState 整个 shell 便宜得多）
/// ```
///
/// # 用法（三处**必须**照做，否则会踩坑）
///
/// ```dart
/// class _LivePageState extends State<LivePage> {
///   ValueListenable<AppTab>? _active;
///   bool _pausedByHide = false;          // ★ ① 不能省，见下
///
///   @override
///   void didChangeDependencies() {
///     super.didChangeDependencies();
///     _active?.removeListener(_onVisibilityChanged);
///     _active = ShellScope.activeTabOf(context);
///     _active?.addListener(_onVisibilityChanged);
///   }
///
///   void _onVisibilityChanged() {
///     if (!mounted) return;
///     final visible = ShellScope.isActive(context, AppTab.live);
///     if (!visible && player.isPlaying) {
///       player.pause();
///       _pausedByHide = true;            // ★ 记住"是我暂停的"
///     } else if (visible && _pausedByHide) {
///       player.play();                   // ★ 只恢复**我**暂停的
///       _pausedByHide = false;
///     }
///   }
///
///   @override
///   void dispose() {
///     _active?.removeListener(_onVisibilityChanged);   // ★ ② 必须移除
///     super.dispose();
///   }
/// }
/// ```
/// ```text
/// ★ ① `_pausedByHide` 标志不能省 ——
///      否则"用户自己暂停后切走再切回"会被自动播起来（**违背用户意图**）
/// ★ ② 监听一定要 removeListener —— 保活页生命周期变长了，泄漏后果更明显
/// ★ ③ 用 pause **不要** dispose/重建播放器
/// ```
class ShellScope extends InheritedNotifier<ValueNotifier<AppTab>> {
  const ShellScope({
    super.key,
    required ValueNotifier<AppTab> super.notifier,
    required super.child,
  });

  /// 本页是否**可见**（在前台）
  ///
  /// ⚠️ 语义是"**可见**"，不是"活跃" ——
  ///    保活页仍然 `mounted`，只是不可见。
  ///    所以**不要**拿它决定"要不要保留状态"，只决定"要不要跑副作用"
  ///    （停播放器 / 停定时器 / 停动画）。
  static bool isActive(BuildContext context, AppTab tab) {
    final n = context
        .dependOnInheritedWidgetOfExactType<ShellScope>()
        ?.notifier;
    return n?.value == tab;
  }

  /// 想要"可见性变化时做点事"（如 pause / 续播）时用这个
  ///
  /// 返回 `ValueListenable<AppTab>`；调用方自己 `addListener`，
  /// 并在 `dispose`（或 `didChangeDependencies` 开头）**移除**。
  static ValueListenable<AppTab>? activeTabOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellScope>()?.notifier;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  /*
   * ★★★ 必须初始化 media_kit —— 否则**播放器根本起不来**
   *     （2026-09-23 交付实测发现的真 bug）
   *
   * # 症状（极具迷惑性）
   *
   * 应用启动、首页、详情页、切 tab **全都正常** ——
   * 只有真正要播的时候才炸：
   * ```text
   * Unhandled Exception: MediaKit.ensureInitialized must be called
   *   before using any API from package:media_kit.
   * ```
   *
   * # 为什么之前没被发现
   *
   * 我所有的播放测试都写在**独立探针**里（`player_probe.dart` 等），
   * 而那些探针的 `main()` 里都有这一句 —— 所以它们全绿。
   * 但**真实入口 `shell.dart` 从来没有这一句**。
   *
   * 「探针绿」不等于「应用对」—— 这正是交付实测（用真实入口跑）
   * 才能抓到的问题。
   *
   * ⚠️ 必须在 `runApp` 之前 —— media_kit 的原生层要在
   *    Flutter 引擎起来时一起加载。
   */
  MediaKit.ensureInitialized();

  /*
   * ★★★ 平台分支：window_manager 只存在于桌面（2026-09-22 踩的坑）
   *
   * # 症状
   *
   * 直接跑 `Windows` 正常；装到 Android 上是**纯白屏**，而且
   * logcat 里**没有任何 Dart 异常** —— 最难查的那类问题。
   *
   * # 原因
   *
   * `window_manager` 是**桌面专用插件**（Windows/macOS/Linux）。
   * 在 Android 上调 `windowManager.ensureInitialized()` 会：
   * ```text
   * ① 走 MethodChannel 找一个不存在的原生实现
   * ② await 永远不返回（或抛错但被吞掉）
   * ③ 于是 runApp() 永远执行不到 → 白屏
   * ```
   * 白屏但无异常，就是「卡在 await 上」的典型特征。
   *
   * # 正确做法
   *
   * ```text
   * 桌面 → 自绘标题栏要做的事：隐藏系统标题栏、设最小尺寸、居中
   * 移动 → 系统自己有标题栏/状态栏，什么都不用做
   * ```
   * 平台判定统一用文件顶部的 `kIsDesktop` ——
   * 这是「一套代码多端」必须处理的第一个平台差异。
   */
  if (kIsDesktop) {
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ 最小窗口尺寸 = **原版 Tauri 的值**（900×600）
       * ══════════════════════════════════════════════════════════════════
       *
       * # 为什么必须与 Tauri 一致
       * ```text
       * 原版 `src-tauri/tauri.conf.json`：
       *   "width": 1280, "height": 800,
       *   "minWidth": 900, "minHeight": 600
       * ```
       * ⇒ 原版**从来不允许**窗口小于 900×600 ⇒ 用户从未见过更小的形态。
       *
       * # ⚠️ 这里曾经被改成 200×200，且留了一句 `AG-EXPERIMENT-TEMP (revert)`
       * ```text
       * minimumSize: Size(200, 200), // AG-EXPERIMENT-TEMP (revert)
       * ```
       * ★ 那是**某次实验的临时值，忘了还原**。后果不只是"能缩得更小"：
       * ```text
       * ① 用户可以把窗口拖到 200×200 —— 而**右侧详情面板的头部自然高
       *    就有 334~397px**（实测，见 `.probe/probe_tests/
       *    t64_header_measure_test.dart`）
       *    ⇒ 头部**必然**把视口吃光 ⇒ 选集区被整个推出可视区
       *      ⇒ 用户**完全看不到剧集**（而那是详情页的主要功能）
       * ② 它还会让测试去追一个**生产上不可达**的尺寸
       *    （`t64_panel_fixed_test.dart` 原来那两条 360×300 / 400×200
       *      的"不溢出"断言 —— 见该文件的说明）
       * ```
       *
       * ⇒ 还原成 900×600：**与原版一致**，且 900 恰好是 `media_page.dart`
       *   宽档阈值（`mq.size.width >= 900`）⇒ 窗口不可能窄到触发半屏形态。
       *
       * ⚠️ 不要为了"能缩小窗口"而调低它 ——
       *    右侧详情面板在 <900 宽时会走上下分栏，头部 + 选集放不下。
       */
      minimumSize: const Size(900, 600),
      center: true,
      // ★ 关键：去掉系统标题栏，才能自绘
      titleBarStyle: TitleBarStyle.hidden,
      /*
       * ★★ 窗口底色保留为**透明**（2026-09-24 复核后**保留**）
       *
       * # 本轮实测（两个方向都试过，结论是"必须留着"）
       *
       * 我先按"透明方案无效"的推断把它**删掉**，实测反而更糟：
       * ```text
       *              四角最外像素      说明
       * 保留 transparent   241,241,241   主题浅色（不难看）
       * 删掉 transparent    10,10,10      近黑 ← 回归成"黑角"！
       * ```
       * 两次运行都是首页、同坐标 (300,200)、同尺寸，可比。
       *
       * 原因：`backgroundColor: transparent` 会让 window_manager 调
       * `SetWindowCompositionAttribute(ACCENT_ENABLE_TRANSPARENTGRADIENT)`，
       * 那条 DWM 着色确实**不能**让 Flutter 表面真透明，但它把
       * 窗口底色的**合成基调**改成了浅色 —— 于是 `ClipRRect` 之外
       * 露出的不是近黑，而是接近主题底色。**方向是对的。**
       *
       * # 但要如实说明：这**不是**"真透明"
       *
       * 判据（同一位置 `mode=none` vs `mode=blur` 逐字节对比）：
       * `DwmEnableBlurBehindWindow` / `WS_EX_LAYERED` / `SetWindowRgn`
       * 三条路**全部实测无效** —— Flutter 的 Windows embedder 用 ANGLE
       * 建 D3D11 swapchain，alpha 对 DWM 被忽略，所以圆角外露的是
       * **Flutter 清屏色**，不可能"透出桌面"。
       *
       * 原版（Tauri/WebView2）同一招有效，是因为 WebView2 走
       * DirectComposition（视觉树自带 per-pixel alpha）。
       * **同一行代码，渲染架构不同则结果不同。**
       *
       * # Win10 + Flutter 能做到的程度
       *
       * ```text
       * 做不到  "真透明圆角"（圆角外透出桌面）
       * 做得到  圆角外是**接近主题的浅色**而非突兀的黑块 ——
       *         视觉上"像圆角"，这是当前最佳可行效果
       * 原因    ① Win10 无原生圆角 API（要 Win11 22000+）
       *         ② Flutter D3D11 swapchain 不提供 alpha 合成
       *         ③ SetWindowRgn 是二值裁剪、无抗锯齿（原版已否决）
       * ```
       * ⚠️ 不假装做到了"真透明"：这里没有实现，也不声称实现。
       */
      backgroundColor: Colors.transparent,
      title: '源影',
    );

    /*
     * ★★★ m13655 (B)：`show()` 从这里的回调里**搬走**了（2026-10-04）
     *
     * # 为什么必须搬
     * ```text
     * `window_manager` 的 Show()（window_manager.cpp:276-287）做的是
     *   SetWindowLong(GWL_STYLE |= WS_VISIBLE) + ShowWindowAsync(SW_SHOW)
     * ⇒ **一调就可见**。
     *
     * 而 「上次记住的窗口几何」 要到下面 `await UiPrefs.load(dir)` 之后才读得到
     * （那是本函数 400 行以后的事，比这里晚 ~70ms）。
     * ⇒ 在这里 show 的话，窗口会先在**默认位置**（居中 1280×800）出现，
     *   等还原逻辑跑完再跳到记住的位置 —— 正是 Owner 说的
     *   「而不是默认的」 要避免的那个观感。
     * ```
     *
     * ⇒ 现在的顺序是：
     *   `UiPrefs.load()` → `WindowBoundsStore.restore()` → `_showDesktopWindow()`
     * ⇒ 窗口**第一次出现在屏幕上时就已经是记住的几何**。
     *
     * ⚠️ `center: true` 保留在 `windowOptions` 里**是有意的**：
     *    首次运行（没有存过几何）时它就是「居中」，与改动前逐字一致；
     *    而且那时窗口还不可见，居中本身不产生任何观感。
     *
     * ⚠️ 无回调版本的 `waitUntilReadyToShow` 只做通道调用 + 设尺寸/居中/
     *    最小尺寸/标题（`window_manager.dart:127-158`），不做显示。
     */
    await windowManager.waitUntilReadyToShow(windowOptions);
  }

  /*
   * ★ 首帧探针（2026-09-22）
   *
   * # 为什么需要它
   *
   * 截图验证有个致命前提：**屏幕必须是亮的、会话必须是解锁的**。
   * 实测踩到：机器锁屏后 `CopyFromScreen` 抓到的是锁屏画面，
   * 每次截图 SHA256 都一样 —— 看起来像"应用没渲染"，
   * 其实是**验证手段失效**，不是代码问题。
   *
   * 所以加这个不依赖屏幕的探针：Flutter 画出第一帧后会回调，
   * 我们把证据打到 stdout。重定向日志就能精确判断。
   */
  WidgetsBinding.instance.addPostFrameCallback((_) {
    debugPrint('[SHELL] FIRST_FRAME_RENDERED');
    // 报告实际生效的 TV 样式值（不只是判定结果）
    // ★ 字号那一项取 `AppMetrics.effectiveTextScale`（A1 的**唯一真源**）——
    //   第一版打的是 `Device.textScale`，那是「TV 判定」而不是「真的挂上去了」，
    //   所以手机上这条日志显示 1.0 而屏幕其实被放大了（缺陷藏了很久）。
    debugPrint('[SHELL] 底栏高度=${Device.isTv ? 72 : 58} '
        '字号缩放=${AppMetrics.effectiveTextScale} 画焦点环=${Device.needsFocusRing}');
  });

  /*
   * ★ 先确定设备类型，再 runApp（2026-09-22）
   *
   * # 为什么必须在 runApp **之前**
   *
   * 设备判定决定首帧的布局（字号缩放、安全区、控制条高度）。
   * 如果先按默认画、之后再改，会看到明显的「跳一下」——
   * 原版注释强调过：**大屏上这种闪动非常明显**。
   *
   * ```text
   * 应在 runApp 前：await Device.init()
   *     → 首帧就是对的
   *
   * 反面：在 initState 里异步改
   *     → 先按手机布局画一帧，再跳成 TV 布局
   * ```
   *
   * # 平台通道不可用时不会卡住
   *
   * `Device.init()` 内部有 try/catch —— 桌面/Web 上通道不存在时
   * 会走兜底启发式并立即返回，不会像 `window_manager` 那样挂住。
   */
  await Device.init();

  /*
   * ★ 启动 Rust 核心（2026-09-23）
   *
   * # 必须在 runApp 之前
   *
   * 因为发现页在 `initState` 里就会调 `listProviders()` ——
   * 核心没起来的话那一步会抛「核心尚未启动」，首页直接进错误态。
   * 而且失败信息要能显示出来，所以这里**不吞异常**：
   * 记下来传给 App，让界面如实显示，而不是白屏。
   *
   * # 数据目录怎么定
   *
   * ```text
   * Windows → %APPDATA%\app.sourin.player   （与原版**同一个目录**，
   *                                            这样用户已有的收藏/历史/插件直接可用）
   * Android → 应用私有目录（沙箱）
   * ```
   * ⚠️ 与原版共用数据目录是**有意**的 —— 这是"替代原版"而不是"另起一个应用"。
   *    但共用意味着**绝不能写坏**：核心层的写操作都是原子的
   *   （临时文件 + rename），且我们不在启动时做任何迁移。
   */
  String? coreError;
  /*
   * ★★ 核心数据目录 —— 失败时**必须**一起带到界面（任务 AM，2026-09-25）
   *
   * # 为什么光有 `coreError` 不够
   *
   * 真机实测（Android TV，数据目录指向应用不可访问的路径）：
   * 界面只显示"还没有可用的内容源"，用户**完全不知道**核心没起来，
   * 更不知道该去改哪个路径。
   *
   * 而"数据目录是哪个"恰恰是**唯一可操作**的信息 ——
   * 用户改不了代码，但他能改存储权限 / 换回内置存储。
   * 所以这里把解析出来的目录一并传给界面。
   */
  String? coreDataDir;
  try {
    final dir = await _resolveDataDir();
    coreDataDir = dir;

    /*
     * ★ 先加载 UI 偏好（2026-09-23）
     *
     * 详情页要用它读「上次选的是哪个播放源」（原版用 localStorage）。
     * ⚠️ 必须在 runApp 之前 —— 详情页在 initState 里就会同步读它，
     *    晚加载的话第一次进详情页会读不到（表现为"记住的源没生效"）。
     */
    await UiPrefs.load(dir);

    /*
     * ★★ task-55：`UiPrefs` 加载完成后，把"动画风格"同步进运行期缓存
     *
     * # 为什么必须在这里同步（否则"重启后设置失效"）
     * ```text
     * `PageTransitionStyleStore.current` 是 `static final` ——
     * ★ 它在**类首次被访问**时初始化，而那很可能发生在这行**之前**
     *   （shell 构建时就会读它来决定 tab 过渡风格）
     * ⇒ 那时 `UiPrefs` 还是空的 ⇒ 读到默认值 `slideRight`
     * ⇒ ★ 用户明明在设置里选了"缩放"，重启后又变回"右滑"
     *   —— 看起来像"设置没保存"，其实是**读早了**
     * ```
     * ⇒ 在 `UiPrefs.load()` 之后**再同步一次**（幂等，开销可忽略）。
     *
     * ⚠️ 顺序不能反：必须**先** `UiPrefs.load(dir)`，再 `syncFromPrefs()`。
     */
    PageTransitionStyleStore.syncFromPrefs();

    /*
     * ★★★ m13655 (B)：还原上次记住的窗口几何（Owner 原话，2026-10-04）
     *
     * > 「调整窗口大小后记录，下次打开要还原  而不是默认的」
     *
     * # 为什么插在**这里**
     * ```text
     * 上界：必须在 `UiPrefs.load(dir)`（上一段）之后 —— 几何就存在里面
     * 下界：必须在 `_showDesktopWindow()`（下一段）之前 —— 先 show 就会跳
     * ```
     * ⇒ 这一段正好是唯一的合法位置。
     *
     * ⚠️ 失败**不抛**：没存过 / 平台不支持 / 插件报错都只是返回 false，
     *    窗口照常以默认几何显示（退回改动前的行为，绝不留一个不出现的窗口）。
     */
    await WindowBoundsStore.restore();

    /*
     * ★ 几何已定，现在才让窗口出现（m13655 B 从 `waitUntilReadyToShow` 搬来）
     *
     * ⚠️ 这**不是**可选的提前量：`show()` 之后窗口就可见了，
     *    而 Flutter 的首帧还要等 `runApp`（本函数末尾）——
     *    改动前也是这个次序（实测 show 1.638s / 首帧 1.742s，差 104ms），
     *    所以观感与改动前一致，不会多出一段空白。
     */
    await _showDesktopWindow();

    final r = await SourinCore.startAsync(dir);
    debugPrint('[SHELL] 核心已启动: $r');
  } catch (e, st) {
    coreError = e.toString();
    /*
     * ★ 目录可能是在 `_resolveDataDir()` **内部**失败的（权限不足 /
     *   路径被文件占位）—— 那时 `coreDataDir` 还没被赋值。
     *   用 `??=` 兜住：拿"本来打算用哪个目录"，而不是留空。
     *   用户看不到路径就无从下手（这正是本 bug 的一半）。
     */
    coreDataDir ??= lastDataDirAttempt;
    debugPrint('[SHELL] ★ 核心启动失败: $e');
    debugPrint('[SHELL] ★ 失败时数据目录: ${coreDataDir ?? "(未解析出)"}');
    debugPrint('$st');
  }

  /*
   * ★ 手机端裁剪「遥控」——第 3 层（Rust 自启），task-6
   *
   * Owner 原话（2026-10-02）："手机端不需要遥控,需要裁剪掉"。
   *
   * 三层必须同时生效，缺一层就是"看着没了、其实还在听"：
   *   ① `lib/ui/settings_page.dart`：`if (!Device.isTouchOnly)` 藏掉整个设置块
   *   ② `lib/shell.dart`（本文件上方 `MaterialApp.builder`）：手机端**不挂**
   *      `RemoteBridgeHost` ⇒ `setGlobals` 不被调用 ⇒ `_tick()` 不轮询
   *   ③ ★ 本处：Rust 侧 `state.rs` 的 bootstrap 会在 `remote_pref.auto_start`
   *      为真时**主动 bind 8642 并起 HTTP 服务**（默认偏好就是 `true`，
   *      `commands_remote.rs:81`）。前两层都拦不住它 —— 手机照样在监听。
   *
   * 做法：手机端启动后**立即停一次**。`remote_stop` 内部已经
   * `pref.auto_start = false; save_remote_pref(...)`（`commands_remote.rs:274-278`），
   * 所以这一次调用同时完成「现在停」+「以后开机不自动起」——
   * 不需要再单独调 `remoteSetAutoStart(false)`（同一字段写两遍是冗余）。
   *
   * ⚠️ 必须**单独 try/catch**，不能并进上面核心启动的 catch：
   *    那样 remote_stop 失败会污染 `coreError`，把已经成功启动的核心
   *    误报成"启动失败"（满屏错误页），代价远大于收益。
   *
   * ⚠️ 时序：bootstrap 先绑端口、Dart 才来得及停 ⇒ 首启有一个毫秒级
   *    「已监听 → 被停」窗口；第二次启动起 `auto_start=false` 已落盘，
   *    Rust 直接跳过自启。`remote_stop` 内部超时上限 3 秒，正常 <50ms。
   *
   * ⚠️ 手机端 UI 已藏掉遥控设置块 ⇒ `auto_start` 再也不可能被用户打开，
   *    这个 false 是终态，不会和用户意志冲突。
   */
  if (Device.isTouchOnly) {
    try {
      final st = await SourinApi.remoteStop();
      debugPrint('[SHELL] ★ 手机端已裁剪遥控: stopped=${st.stopped} running=${st.running}');
    } catch (e) {
      debugPrint('[SHELL] ★ 手机端关闭遥控失败（不影响使用）: $e');
    }
  }  /*
   * ★ Step 1：预编译液态玻璃的 shader（`liquid_glass_widgets` 要求）
   *
   * 包文档：
   * > `initialize()` performs **100% non-blocking async disk-to-RAM I/O**
   * > —— zero GPU draw calls, zero rasterization ——
   * > so the OS window always presents immediately.
   *
   * 不调的话第一帧的玻璃会**编译 shader 而卡一下**（Windows 上是
   * ANGLE 运行时编译 GLSL）—— 包文档明确说这是为了"首帧就是玻璃"。
   *
   * ⚠️ 必须 `await`（它是 async）—— 但因为它只做磁盘 I/O，
   *    不会阻塞首帧的呈现。
   */
  await LiquidGlassWidgets.initialize();

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ 真机拖拽自检（2026-10-01，Owner 要求「拟人化操作试试看」）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 为什么要在**真实入口**里挂这个
   *
   * Owner 报「片头片尾的设置根本没用,那四个箭头是可以拖动的」。
   * 我写了三版**外部鼠标驱动**脚本（`.probe\t455/t456/t457`），
   * 全部卡在同一处：
   * ```text
   * 主屏 2560x1440 被 VS Code 全屏占着
   * 副屏 2048x1152 被两个 qemu 占着（y 96..1055）
   * ⇒ **没有 1280x800 的空位**给一个可点击的窗口
   * ⇒ `WindowFromPoint` 的落点校验（必要的保护，实测挡住过两次）
   *   拒绝了所有落点
   * ```
   * ★ 我不能为了测试去关掉 Owner 正在用的 VS Code / 模拟器。
   *
   * ⇒ 改为**进程内**发真实指针事件
   *   （`GestureBinding.handlePointerEvent`）—— 走的是与物理鼠标
   *   **完全相同**的手势管线，只是不经过操作系统光标，
   *   所以不需要窗口可见、不需要前台。
   *
   * ⚠️ **默认关**（`SOURIN_DRAG_SELFTEST=1` 才跑）⇒ 生产行为逐字不变。
   *    跑完 `exit(0)`（自检是独立进程，不该继续跑正常 UI）。
   *
   * 用法：
   * ```powershell
   * $env:SOURIN_DRAG_SELFTEST='1'; .\sourin_spike.exe
   * # 结果写到 %TEMP%\sourin_drag_selftest.txt
   * ```
   */
  if (dragSelfTestEnabled) {
    final sink = StringBuffer()
      ..writeln('=== 源影 真机拖拽自检（进程内真实指针事件）===')
      ..writeln('时间: ${DateTime.now().toIso8601String()}');
    await runDragSelfTest(sink);
    return; // 自检自己 exit，这里只是让分析器知道流程结束
  }

  runApp(SourinApp(coreError: coreError, coreDataDir: coreDataDir));

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ 2026-10-08（Owner 第 8 条）：注册托盘图标 + 接管「点 X」
   * ══════════════════════════════════════════════════════════════════
   *
   * # 为什么在 `runApp` **之后**（而不是之前）
   * ```text
   * `AppTray.start()` 走 `tray_manager` 的 MethodChannel ⇒
   *   通道的另一端是**原生侧**，不依赖 Flutter 的帧；
   * 但它内部会 `await windowManager.setPreventClose(true)` —— 那一步
   *   要在 `windowManager.ensureInitialized()` 之后（:318 已满足）。
   * ⇒ 放这里与放 `runApp` 之前等价，但放**之后**有一个实际好处：
   *   若托盘注册抛异常，它落在 runApp 之后 ⇒ **不会**把异常抛进
   *   main 的 try/catch 里被误记成「核心启动失败」
   *   （这正是 `_showDesktopWindow` 踩过的那类坑，:722-744 逐字记过）。
   * ```
   *
   * ⚠️ **不 await**：托盘注册要走一次 IPC，`await` 会让首帧等它 ——
   *    而托盘晚 50ms 出现对用户毫无影响。失败已由 `start()` 自己吞并留日志。
   */
  unawaited(AppTray.instance.start());
}

/// 让桌面窗口显示出来（★ 只在 `kIsDesktop` 下调用）
///
/// # ★★★ 为什么单独抽一个函数，而不是在 `main()` 里直接写两行
///
/// 因为**调用时机是 m13655 (B) 的全部难点**：
///
/// ```text
/// 必须在 `WindowBoundsStore.restore()` **之后** —— 先显示就会看到窗口
///   从默认位置跳到记住的位置（Owner 要避免的正是这个）；
/// 必须在 `runApp()` **之前** —— 窗口不可见时 Flutter 的帧调度是空闲的
///   （`flutter_window.cpp` 的 `SetNextFrameCallback` 是**按帧**触发的，
///    不是定时器）⇒ 把它放到 `runApp` 之后，首帧可能永远不来。
/// ```
///
/// # 为什么失败也不抛
///
/// 用户装了但窗口没出现 = 完全无法使用，而且**没有任何界面能提示他**。
/// 所以这里把异常吞掉并打印：宁可窗口停在默认几何，也不能不出现。
///
/// ⚠️ `focus()` 不吞异常 —— 它只做 `SetForegroundWindow`（不抢鼠标、
///    不改几何），失败只说明当前会话不允许抢焦点，与能否使用无关，
///    但真出错时留下日志比静默更有用。
Future<void> _showDesktopWindow() async {
  /*
   * ★★★ 2026-10-04 实测回归：**Android 上必须先判平台**
   *
   * # 症状（真机 logcat，非推断）
   * ```text
   * [SHELL] ★ 显示窗口失败（窗口可能不可见）:
   *         MissingPluginException(No implementation found for method
   *         isMinimized on channel window_manager)
   * [SHELL] ★ 核心启动失败:
   *         MissingPluginException(No implementation found for method
   *         focus on channel window_manager)
   * #2      _showDesktopWindow (package:sourin_spike/shell.dart:719)
   * #3      main (package:sourin_spike/shell.dart:577)
   * ```
   * ⇒ 手机/电视上界面直接进「核心未能启动」页 —— **Rust 核心根本没被启动**。
   *
   * # 为什么本函数原来没有平台判断
   * ```text
   * 它是从 `waitUntilReadyToShow` 的回调里**搬出来**的（m13655 B），
   * 而那个回调**只在 `if (kIsDesktop) { ... }` 里**（见上面 :317）——
   * 搬的时候把「外层已经判过平台」这个前提一起丢了。
   * ```
   *
   * # 为什么不能只靠 try/catch
   * ```text
   * `show()` 的异常被吞掉了（这是对的），但 `await windowManager.focus()`
   * 在 try **外面** ⇒ 它一抛，异常就冲出本函数，被 main 里那个
   * `try { ... } catch (e, st) { coreError = ... }` 接住 ⇒
   * 于是「窗口显示」的失败被**记成了「核心启动失败」**，
   * 而且后面 `SourinCore.startAsync(dir)` 那一行**永远不会执行**。
   * ```
   *
   * # 修法
   * ```text
   * 与 `WindowBoundsStore.restore()` 同款前置判断
   * （`lib/core/window_bounds.dart:181` `if (!isSupported) return false;`）
   * ⇒ 非桌面**直接返回**，通道一次都不碰。
   * ```
   *
   * ⚠️ 保留 `focus()` **不吞异常**的原设计（见上面 :710-712）：桌面真出错时
   *    留下日志比静默更有用。这里加的只是平台闸门，不是 try/catch。
   */
  if (!kIsDesktop) return;
  try {
    await windowManager.show();
  } catch (e) {
    debugPrint('[SHELL] ★ 显示窗口失败（窗口可能不可见）: $e');
  }
  await windowManager.focus();
}

/// ★ 「本来打算用哪个数据目录」—— 解析**失败时**也要能报出来
///
/// # 为什么需要这个全局量（任务 AM，2026-09-25）
///
/// `_resolveDataDir()` 的返回值只有在**完全成功**时才存在。
/// 而最典型的启动失败恰恰发生在它**内部**：
/// ```text
/// DATA_DIR_OVERRIDE 指向一个不可写/被占用的路径
///   → d.create() 抛异常 → 函数根本没 return 过
///   → 调用方拿不到任何路径 → 界面只能说"启动失败"，
///     说不出"失败在哪个目录" → 用户无从下手
/// ```
/// 所以要在**动手之前**先把目标路径记下来。
///
/// ⚠️ 只写不读地放在顶层是有意的：它是"最后一次尝试"的快照，
///    不参与任何逻辑判断，纯粹为了错误信息能带上路径。
String? lastDataDirAttempt;

/// 解析核心的数据目录
///
/// # 为什么不用 path_provider 的 `getApplicationSupportDirectory`
///
/// 它给的是 `%APPDATA%\<公司>\<应用>`，而原版（Tauri）用的是
/// `%APPDATA%\app.sourin.player` —— **路径不同**，用户的收藏/历史/
/// 26 个插件就都读不到了。
///
/// 「替代原版」的前提是**数据能接上**，所以这里显式对齐原版路径。
Future<String> _resolveDataDir() async {
  /*
   * ★★ 交付实测可以用**独立数据目录**（不碰用户真实数据）
   *
   * ```text
   * flutter build windows --dart-define=DATA_DIR_OVERRIDE=D:\tmp\probe
   * ```
   *
   * # 为什么需要
   *
   * 有些功能**必须写数据**才能验证（片头片尾标记、播放进度）。
   * 而用户真实库里有他的收藏/历史/片头片尾 ——
   * **绝不能拿它做写测试**（这个项目历史上数据被清空过一次）。
   *
   * ⚠️ 只在**显式传入**时生效，默认仍是真实目录 ——
   *    生产构建里这个常量是空串，等于没有这个分支。
   */
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isNotEmpty) {
    /*
     * ★ 先记路径再动手（见 `lastDataDirAttempt` 的说明）——
     *   下一行的 `create()` 正是最可能抛异常的地方。
     */
    lastDataDirAttempt = override;
    final d = Directory(override);
    if (!await d.exists()) await d.create(recursive: true);
    debugPrint('[SHELL] ★ 使用覆盖数据目录（仅测试）: ${d.path}');
    return d.path;
  }

  if (kIsDesktop) {
    final appdata = Platform.environment['APPDATA'] ??
        Platform.environment['HOME'] ??
        '.';
    final dir = Directory(
      '$appdata${Platform.pathSeparator}app.sourin.player',
    );
    lastDataDirAttempt = dir.path;
    // 首次运行（原版没装过）时要建出来，否则核心建库会失败
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  // Android / iOS：应用私有目录（沙箱，不需要额外权限）
  final d = await getApplicationSupportDirectory();
  lastDataDirAttempt = d.path;
  return d.path;
}

/// ★★★ 保活页面之间的**进入过渡**（task-41）
///
/// # 为什么需要单独一个 widget
///
/// 保活后不能再用 `AnimatedSwitcher`（它靠"换 widget ⇒ 旧的移出"来播动画，
/// 而保活要求旧的**不移出**）。所以过渡要**手写**，且必须满足：
/// ```text
/// ① 动画由**隐式动画**（AnimatedSlide/AnimatedOpacity）驱动
///    —— ★ 绝不能用"换 key 重挂载"来触发（那就是原 bug 的形态）
/// ② 只有**进入的**那一页播动画（隐藏页只是 Offstage，不动）
/// ③ 动画结束后必须**复位**，否则下次切进来不会重播
/// ```
///
/// # 它是怎么在不换 key 的前提下重播动画的
///
/// ```text
/// active 由 false → true 时：
///   先把 offset/opacity 设成"起始态"（在本 widget 的 State 里）
///   下一帧再设回"终态" ⇒ 隐式动画自然从起始态补间到终态
/// ```
/// ⚠️ 关键：`child`（真正的页面）**始终是同一个实例**，且在树的
///    同一个位置 ⇒ 它的 Element/State **不会被重建**。
///    动画只作用在**包在外面的** `SlideTransition`/`FadeTransition` 上。
///
/// # 为什么不用 `AnimatedSlide` 而用 `TweenAnimationBuilder`
///
/// `AnimatedSlide` 需要一个"目标值变化"来触发补间；而我们要的是
/// **每次进入都从 -0.02 补到 0**（即使目标值一直是 0）——
/// `TweenAnimationBuilder` 用 `key` 也不行（同样会重建子树），
/// 所以用**自己的 AnimationController**：进入时 `forward(from: 0)`。
class _KeepAliveTransition extends StatefulWidget {
  const _KeepAliveTransition({
    required this.active,
    required this.dir,
    required this.leaving,
    required this.child,
    required this.style,
    this.leavingFade,
  });

  /// 本页是否是**当前可见**的那一页（只有它播进入动画）
  final bool active;

  /// ★★★ task-14 ⑨ 白屏修复（2026-10-04）：本页是否是**刚被切走**的那一页
  ///
  /// # 为什么需要这个标志（白屏的根因）
  /// ```text
  /// 改前：切 tab 时
  ///   ① 新页的 _c.forward(from: 0) ⇒ 过渡层 opacity 从 **0** 开始
  ///   ② 旧页同时被 Offstage(offstage: true) 移出合成
  ///   ⇒ 两边**同时**都不画东西 ⇒ 露出底下的 floorColor
  /// 实测（手机 360x800dp）：76–120ms 的纯色空白（像素级判定过）
  /// ```
  /// ⇒ 旧页在**离场窗口内**必须继续参与合成，而且只能画**静态内容**
  ///   （见 _KeepAliveTransitionState.build：它拿的是恒为 1 的动画）。
  ///
  /// ⚠️ 与 [active] 的区别：active 管「进入动画」（forward(from: 0)），
  ///    leaving 只管「继续画着、别播动画」。两者**互斥**
  ///    （一次切换里只有一页 active、另一页 leaving）。
  final bool leaving;

  /// ★★★ 2026-10-08（Owner 第 2 条）：离场页的**淡出**动画（1.0 → 0.0）
  ///
  /// # 它解决什么（用户报的「拖影」）
  /// ```text
  /// 改前离场页拿 `AlwaysStoppedAnimation(1.0)` ⇒ 整段 260ms 都不透明，
  /// 而新页从 0 淡入 ⇒ 新页半透明时底下那层旧页 100% 透出来
  ///   ⇒ 「上个页面的元素还没彻底消失、两层叠加」。
  /// ```
  ///
  /// ⚠️ **只有离场那一页**收到非 null（调用方写的是
  ///    `t == _leavingTab ? _leavingFade : null`）—— 绝不能无条件传：
  ///    那会让**新页**也带上一条 1→0 的淡出（灾难）。
  ///
  /// ⚠️ 控制器在 **shell** 上（`_ShellPageState._leaveC`），不在这里：
  ///    `TickerMode(enabled: t == _tab)` 会停掉隐藏页的 ticker
  ///    ⇒ 离场页自己开的控制器**根本不会走**（task-14 ⑨ 的注释记过）。
  ///
  /// ★ 与 `leaving`（bool）的分工：`leaving` 决定「进入动画让位」
  ///   （喂恒 1 的动画），`leavingFade` 决定「怎么消失」。两者只在
  ///   离场窗口内同时为真 —— 见 build 里的组合。
  final Animation<double>? leavingFade;

  /// 进入方向（+1 = 从右进，-1 = 从左进）
  final double dir;

  /// ★★ task-55：进入动画的**风格**（用户在设置页里选）
  ///
  /// ⚠️ 由**调用方**传入（而不是这里直接读 `PageTransitionStyleStore`）——
  ///   因为调用方在 `ValueListenableBuilder` 里监听该 store
  ///   ⇒ 用户改设置时**只有调用方重建**，本 State（含 `_c`）**不重建**
  ///   ⇒ ★ 动画控制器不会被重置（否则改设置会打断正在播的过渡）。
  final PageTransitionStyle style;

  /// ★ 真正的页面 —— **必须**是稳定实例（来自 `_pages`）
  final Widget child;

  @override
  State<_KeepAliveTransition> createState() => _KeepAliveTransitionState();
}

class _KeepAliveTransitionState extends State<_KeepAliveTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    /*
     * ★★ task-14 ⑨：时长取 `Motion.base`（260ms）——
     *    与二级页链**同一个常量**：
     *      `lib/ui/widgets/page_transition_route.dart:120-122`
     *      `@override Duration get transitionDuration => ... Motion.base;`
     *    改前这里写的是硬编码 `Duration(milliseconds: 260)` ——
     *    数值虽同，但**没有单一真源**：任一侧改了另一侧不会跟着改。
     *    这正是用户说的「点底栏和设置页二级页动画根本就不一样」
     *    得以长期潜伏的温床。
     */
    duration: Motion.base,
    value: 1, // 首帧就是"已就位"，不播动画（避免启动时闪一下）
  );

  @override
  void didUpdateWidget(covariant _KeepAliveTransition old) {
    super.didUpdateWidget(old);
    /*
     * ★ 只在"从不可见变成可见"时重播 ——
     *   否则父级任何 rebuild（如 _unread 变化）都会重播动画，很难看。
     */
    if (widget.active && !old.active) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    /*
     * ⚠️ `TickerMode(enabled: t == _tab)` 已经停掉了隐藏页的 ticker，
     *    所以这里的 controller 在隐藏时**不会**空转 —— 不需要额外判断。
     *
     * 位移 0.02 ≈ 1280*0.02 = 25.6px（与原 AnimatedSwitcher 的 24px 对齐）。
     */
    /*
     * ★★ task-14 ⑨：曲线与二级页链**同源**。
     *    · 二级页：`lib/ui/widgets/page_transition_route.dart:167`
     *      `MotionPrefs.curve(context, Motion.easeOut)`
     *    · 这里：**同一个调用**（只差一层 `reduce` 判断）
     *
     *    改前是 `Curves.easeOutCubic`（≈ `Cubic(0.215, 0.61, 0.355, 1)`），
     *    与 `Motion.easeOut`（`Cubic(0.22, 1, 0.36, 1)`）**不是同一条曲线**：
     *    1280 宽下 40ms 时位移 15.51px vs 11.15px、透明度 0.394 vs 0.564
     *    ⇒ 肉眼可见「两条链不一样」。
     *
     * ⚠️ `reverseCurve` 与 `curve` **同值**：`_c` 只被 `didUpdateWidget`
     *    里的 `_c.forward(from: 0)` 驱动（见上），**从不 `reverse()`**
     *    ⇒ 原来那行 `Curves.easeInCubic` 是**死分支**，
     *    留着只会让人误以为「反向另有一条曲线」。
     */
    final curved = CurvedAnimation(
      parent: _c,
      curve: MotionPrefs.curve(context, Motion.easeOut),
      reverseCurve: MotionPrefs.curve(context, Motion.easeOut),
    );

    /*
     * ══════════════════════════════════════════════════════════════
     * ★★ task-55：按**用户选的风格**组装过渡（原来是硬编码的 淡入+右滑）
     * ══════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 然后还有个动画效果,我说让你多做几个我来切换的,这个你也没做
     *
     * # 改之前
     * ```text
     * 这里硬编码 `FadeTransition` + `SlideTransition(0.02*dir → 0)`
     * ⇒ ★ 只有**一种**效果，用户**不能选** ⇒ 用户说"没做" ✓
     * ```
     *
     * # 改之后
     * ```text
     * `PageTransition.apply(...)` 按 `widget.style` 分派 6 种之一：
     *   右滑（= 上面那套，默认）/ 淡入 / 上滑 / 缩放 / 上浮 / **无动画**
     * ★ `none` 时它**直接返回 child**（零 widget 层）⇒ 真·关闭
     * ```
     *
     * ⚠️ **只换"组合方式"** —— 下面这些**一律不动**：
     *    · `_c`（AnimationController）的生命周期与 `value: 1` 初值
     *    · `didUpdateWidget` 的"只在 不可见→可见 时重播"逻辑
     *    · `TickerMode` 门控、保活的 Stack/Positioned 结构
     *    · `child` 的稳定实例语义（本 widget 动画不影响子页 State）
     *
     * ⚠️ `style` 由**调用方**传入（那里监听 store）——
     *    所以改设置时**本 State 不重建** ⇒ `_c` 不被重置
     *    ⇒ 不会打断正在播的过渡 ✓
     */
    /*
     * ══════════════════════════════════════════════════════════════
     * ★★★ task-14 ⑨ 白屏修复（2026-10-04）
     * ══════════════════════════════════════════════════════════════
     *
     * # 根因（已像素级证实）
     * ```text
     * _switchTo ⇒ 新页 _c.forward(from: 0) ⇒ 过渡层 opacity = 0
     * 同一帧旧页被 Offstage(offstage: true) 移出合成
     * ⇒ 两边都不画东西 ⇒ 露出底下 shell 的 floorColor
     * 实测手机上 76–120ms 的纯色（#EDEDF5 / #EEF0F6）空白
     * ★ 给「空白」垫个背景色**没用** —— 它本身就是背景色
     * ```
     *
     * # 修法
     * ```text
     * 离场页在窗口期内继续参与合成，但喂它一个**恒为 1** 的动画
     *   ⇒ 它停在「已就位」那一态（不透明度 1、位移 0、缩放 1）
     *   ⇒ 新页从透明淡入时，底下**始终有东西** ⇒ 不再露白
     *   ⇒ 而且它**不播任何动画**（零 ticker、零额外绘制路径）
     * ```
     *
     * ⚠️ 为什么不给离场页 _c.reverse()（「淡出」那种写法）：
     *    那需要它的 ticker 是活的，而 TickerMode(enabled: t == _tab)
     *    恰好把隐藏页的 ticker 停了 ⇒ 反向根本不会走
     *    ⇒ 用 AlwaysStoppedAnimation 反而更诚实：**它就是静止的**。
     *
     * ⚠️ animation 只影响过渡层，child 仍是**同一个稳定实例**
     *    （来自 _contentFor）⇒ 页面 State / 滚动位置 / 解码器都不受影响。
     */
    final Animation<double> animation =
        widget.leaving ? const AlwaysStoppedAnimation<double>(1.0) : curved;

    final Widget transitioned = PageTransition.apply(
      animation: animation,
      style: widget.style,
      dir: widget.dir,
      child: widget.child,
    );

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-10-08（Owner 第 2 条）：离场页**淡出**（拖影的根治）
     * ══════════════════════════════════════════════════════════════════
     *
     * 组合方式是**叠加**，不是替换：
     * ```text
     * ① `PageTransition.apply(...)` 照旧 —— 离场页拿恒 1 的动画
     *    ⇒ 它停在「已就位」（不透明度 1、位移 0、缩放 1）
     *    ⇒ 继续垫在新页底下挡 floorColor（task-14 ⑨ 白屏修复**不受影响**）
     * ② 外面再叠一层 `FadeTransition`，只给**离场页**（leavingFade != null）
     *    ⇒ 1.0 → 0.0 淡出 ⇒ 新页半透明时底下那层也在一起变淡
     *    ⇒ 不再有「两层内容叠加」的拖影
     * ```
     *
     * ⚠️ 为什么用 `FadeTransition`（而不是 `Opacity`）：
     *    这一层是**纯内部组合**，没有任何测试/探针读它；
     *    而 `FadeTransition` 是 `RenderAnimatedOpacity`（单次绘制、
     *    自动加 `RepaintBoundary`），比每次重建 `Opacity` widget 更省。
     *    ★ 注意：`test/keepalive_anim_test.dart` 的读数器取的是
     *      `find.byType(FadeTransition).first`（**从当前页往上找**）——
     *      本层加在**离场页**那一支上，与它取的那一支不是同一个元素
     *      （`_geometryOf` 用 `find.ancestor(of: 当前页)` 限定）。
     *
     * ⚠️ 只在 `leavingFade != null` 时才加这一层 —— 其余四种情况
     *    （当前页、隐藏页、未访问页）的 widget 树与改动前**逐层一致**。
     */
    final Animation<double>? lf = widget.leavingFade;
    final Widget wrapped = lf == null
        ? transitioned
        : FadeTransition(opacity: lf, child: transitioned);

    return IgnorePointer(
      /*
       * ★ 只有**当前可见**的那一页能收指针事件。
       *
       * 离场页在窗口期内仍在合成 ⇒ 若不挡，它会抢走新页的点击 ——
       * 尤其是滑入类风格（slideRight/slideUp/fadeUp/zoom）：
       * 新页那 260ms 里并没有铺满全屏（如 slideRight 偏 0.02*宽 ≈ 7.2dp），
       * 露出来的那一条上，命中的就是**下面的离场页**。
       *
       * ⚠️ 当前页 ignoring: false ⇒ 它的无障碍语义完全不变。
       */
      ignoring: !widget.active,
      child: wrapped,
    );
  }
}

/*
 * ══════════════════════════════════════════════════════════════════════════
 * ★★★ `_SourinScrollBehavior` —— arm64「内容区全空白」的根因修复（2026-10-01）
 * ══════════════════════════════════════════════════════════════════════════
 *
 * # 为什么要覆写 `buildOverscrollIndicator`
 *
 * `MaterialScrollBehavior`（material_ui 的默认 `ScrollBehavior`）会给
 * **每一个 Android 上的竖向滚动视图**外面套一层：
 * ```dart
 * // material_ui-1.4.0\lib\src\app.dart:920-927
 * case TargetPlatform.android:
 *   switch (indicator) {                     // useMaterial3 ⇒ stretch
 *     case AndroidOverscrollIndicator.stretch:
 *       return StretchingOverscrollIndicator(
 *         axisDirection: details.direction,
 *         clipBehavior: details.clipBehavior ?? Clip.hardEdge,   // ← 元凶
 *         child: child,
 *       );
 * ```
 * 而 `details.clipBehavior` 来自 `ScrollView.clipBehavior`，默认就是
 * `Clip.hardEdge`（`scroll_view.dart:129`，经 `:486/:498/:527` 进
 * `ScrollableDetails`）⇒ **这一层永远是 hardEdge，除非页面显式传别的**。
 * 它在 **Viewport 之外** ⇒ 是页面内容路径上**最外层**的裁剪。
 *
 * # 为什么最外层是 hardEdge 就完了（实测规律，18/18）
 *
 * `.probe\t429_*`（7 段）+ `.probe\t435_*`（11 段）跨 arm64/x86_64 两臂：
 * ```text
 * 最外层 == Clip.hardEdge  ⇒ 整棵子树**一个像素都不画**（arm64）
 * 最外层 == antiAlias/none ⇒ 里面再套 hardEdge 也**没事**
 * ```
 * ★ 两个决定性最小对（否掉了"层数"假设）：
 *   · `ClipRect(antiAlias)` 在外 + `Scroll(hardEdge)` 在**内** ⇒ **活**
 *   · `Overlay(hardEdge)` 在外 + 里面 antiAlias + hardEdge   ⇒ **死**
 * ★ x86_64 上 18 段**全活** ⇒ arm64（Berberis 翻译执行）特有。
 *
 * # 为什么降级成 `Clip.none` 是对的
 *
 * `StretchingOverscrollIndicator` 的**拉伸效果本身不受影响** ——
 * 它画在 child **之上**，`clipBehavior` 只决定要不要额外裁一刀。
 * 这一刀裁的本来就是屏幕边界 ⇒ 去掉后**观感没有可辨差别**；
 * 而真正需要的裁剪（`ScrollView` 自己的 `Viewport`）仍然在。
 *
 * ⚠️ 改的是**全局** `ScrollBehavior` ⇒ 一处生效于所有页面，
 *    比逐页给 16 处滚动视图传 `clipBehavior` 更不容易漏。
 * ⚠️ 这条规律**不止于** `MaterialScrollBehavior` ——
 *    t435 段10 证明 `Overlay.wrap(hardEdge)` 也触发同类现象；
 *    所以这里只是消掉产品里那一处，**不是通用解**。
 * ⚠️ 机制**未证实**：为什么 hardEdge 会死、antiAlias 为什么活，只到
 *    「与 `canvas.clipRect(rect, doAntiAlias)` 的那个布尔相关」
 *    （`rendering\object.dart:592`）。猜测是 hardEdge 走 scissor test
 *    而翻译执行把它弄坏 —— **没有插桩验证过**。
 * ⚠️ **真机是否受影响 = 未验证**（本机无法跑真 arm64：
 *    emulator 37.1.11.0 硬拒 arm64 系统镜像，见 `.probe\t438_root_cause.txt` §6）。
 */
class _SourinScrollBehavior extends MaterialScrollBehavior {
  const _SourinScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    /*
     * ★ 把 overscroll 那一层的裁剪降级成 `Clip.none`。
     *
     * ★ 字段真名是 **`decorationClipBehavior`**（不是 `clipBehavior`）——
     *   `ScrollableDetails` 在 `widgets\scrollable_helpers.dart:36`，
     *   `:87 final Clip? decorationClipBehavior;`，
     *   而 `clipBehavior` 是它的**已废弃 getter**（`:96`）。
     *   ★ 文档 `:82-84` 说得正好就是我们要的这件事：
     *   > This [Clip] does not affect the [Viewport.clipBehavior], but is rather
     *   > passed from the same value by [Scrollable] so that decorators like
     *   > [StretchingOverscrollIndicator] honor the same clip.
     *   ⇒ 改它**只影响装饰器**，不动 Viewport 自己的裁剪 —— 正是我们要的。
     *
     * ★ 用 SDK 自带的 `copyWith`（`:100-112`），**不要**手写构造器搬字段：
     *   我第一版手写了，结果① 用错了字段名 ② 多写了一个不存在的
     *   `restorationId`（`ScrollableDetails` 只有 direction / controller /
     *   physics / decorationClipBehavior 四个字段）。手搬字段既容易漏又容易编错，
     *   `copyWith` 是 SDK 维护的。
     */
    return super.buildOverscrollIndicator(
      context,
      child,
      details.copyWith(decorationClipBehavior: Clip.none),
    );
  }
}

class SourinApp extends StatefulWidget {
  const SourinApp({super.key, this.coreError, this.coreDataDir});
  /// 核心启动失败时的错误消息（null = 启动成功）
  ///
  /// 有值时由 `ShellPage` 显示**接管式**的错误页 —— **不能静默吞掉**：
  /// 用户看到的是「首页一直空着」，而真正的原因（库损坏 / 权限不足）
  /// 完全没有提示，那是不可诊断的。
  final String? coreError;

  /// 核心本应使用的数据目录（**失败时**用来告诉用户"是哪个目录出问题"）
  ///
  /// # 为什么必须和 `coreError` 成对传下去（任务 AM，2026-09-25）
  ///
  /// 真机实测：数据目录不可访问 → 界面只显示"还没有可用的内容源"。
  /// 用户既不知道出错了，更不知道该去哪修。
  ///
  /// 而"哪个目录"是**唯一可操作**的线索：
  /// ```text
  /// Android TV → 可能是外置存储没权限 → 换回内置存储
  /// Windows    → 可能是被别的程序占用 / 路径写错
  /// ```
  /// 所以错误页必须把它显示出来（可复制）。
  final String? coreDataDir;

  @override
  State<SourinApp> createState() => _SourinAppState();
}

class _SourinAppState extends State<SourinApp>
    with WidgetsBindingObserver {
  /// ★★★ 遥控桥的「全局能力」—— 三件与**页面无关**的事（集成任务 M2）
  ///
  /// ```text
  /// search    全源搜索并把结果回填给 Rust（remote_bridge.dart 已实现）
  /// loadHome  刷新首页并回填（同上）
  /// openItem  ★ 打开某个条目 —— **必须由挂载方注入**（要导航能力）
  /// ```
  ///
  /// # 为什么 `search` / `loadHome` 不在这里写
  ///
  /// `RemoteCapabilities.globalsFor()` 就是原版 `App.vue` 里那两段逻辑的
  /// 现成移植（各 60 行：轮流取源、失败也回填）。在这里重抄一遍的话，
  /// 改协议时就会漏改一处 —— 原版就是因为分散在两处才出过 bug
  /// （见 `remote_bridge.dart` 文件末的长注释）。
  ///
  /// # 为什么用 `late final` 而不是在 `build` 里现场构造
  ///
  /// `RemoteBridgeHost` 的 `initState` 会 `setGlobals(globals)`，
  /// 只在**首次挂载**时跑一次。若每次 `build` 都造一个新的
  /// `GlobalBridge`，主题切换触发的重建就会传进一个**新对象**，
  /// 而宿主不会重新注册 —— 于是桥里留着旧闭包（虽然当前内容等价，
  /// 但"注册了什么"与"传了什么"从此不一致，是难查的隐患）。
  /// 持有单实例让「传进去的」与「桥里存的」永远是同一个。
  late final GlobalBridge _globals =
      RemoteCapabilities.globalsFor(
        openItem: _openItemFromRemote,
        /*
         * ★ 直播切频道（task-39）
         *
         * # ⚠️ 为什么走 notifier 而不是直接拿 `_liveKey`
         * ```text
         * `_liveKey` 在 `_ShellPageState`（L1520）里，而这里（`_SourinAppState`）
         * 拿不到它 —— `ShellPage` 没有 GlobalKey，也没有向上暴露 state。
         * ★ 直接加一个 `GlobalKey<ShellPageState>` 会改动 shell 的构造链
         *   （且 `ShellPage` 是 `_SourinAppState.build` 里现场构造的，
         *    加 key 会影响 Element 复用语义）。
         * ⇒ 用一个**单向信号**：这里只负责"转发意图"，
         *   由 ShellPage 在 initState 订阅并执行。
         *   这与 task-41 的可见性做法一致（都是 notifier）。
         * ```
         *
         * # 为什么不在别处判"当前是不是直播 tab"
         * ★ 用户在**播放页**看直播时也该能切台 ——
         *   所以这个命令不该被"当前 tab"过滤掉。
         *   `cycleChannel` 内部按**可见列表**算，语义正确。
         */
        liveChannelStep: (delta) => _liveChannelStep.value = delta,
      );

  /// 直播切频道信号（task-39）—— `ShellPage` 订阅它
  ///
  /// ⚠️ 用 `ValueNotifier<int>` 而不是 `StreamController`：
  ///    · 不需要背压/异步（就是"按了一下"）
  ///    · `ValueNotifier` 没有"没人订阅就挂起"的问题
  ///      （`StreamController` 的 broadcast 在没人听时会丢事件，
  ///       而遥控命令**恰好**可能早于页面订阅到达）
  final _liveChannelStep = ValueNotifier<int>(0);

  /// ★★ 遥控命令 `play_item` 的落地处 —— 手机端从搜索结果点进来
  ///
  /// # 语义（对齐原版 `App.vue` L281 的 `openItem`）
  ///
  /// ```ts
  /// openItem: async (provider, id, title) => {
  ///   store.openPlayer({ provider, id, title: title ?? "" });
  ///   if (route.name !== "play") await router.push({ name: "play" });
  /// }
  /// ```
  /// 也就是「**打开**这个片子」—— 本质是**导航**，
  /// 与「暂停 / 快进」（操作当前播放器）是两类事。
  ///
  /// # 为什么它不能挂在播放页能力上（原版实测抓到的真 bug）
  ///
  /// `execPlayer` **只在播放页挂载时存在**。用户还停在首页时
  /// （根本没打开过任何视频）点手机上的搜索结果：
  /// ```text
  /// POST /api/cmd {kind:play_item}  → 200 {"ok":true}   ← 服务端收下了
  /// 5 秒后 /api/state               → title="" has_media=false  ← 客户端没动
  /// ```
  /// 用户看到的就是「手机点了没反应」—— 原版注释说这是最难查的一类表现。
  ///
  /// # 与「直接推详情页」的取舍
  ///
  /// 详情页确实复用更彻底，但原版的 `play_item` 是**直接进播放器**
  /// （`router.push({name:"play"})`）—— 项目铁律是「操作逻辑必须和原版
  /// 完全一致」，所以这里也进播放器，而不是自作主张多插一层详情页
  ///（多一层就多一次点击，与用户预期不符）。
  ///
  /// # ★ 为什么要先把剧集补齐（这一条是**加法**，不是改语义）
  ///
  /// 手机端发来的命令**只有** `provider` / `id` / `title` 三个字段
  ///（见 `models.dart` 的 `RemoteCommand`），没有集数与线路。
  /// 直接 `_openPlayer` 会得到一个 `episodes: []` 的会话 ——
  /// 播放器右侧「选集」栏因 `hasEpisodes: _episodes.length > 1` 而**整栏消失**，
  /// 而且用户接着用手机发 `next_episode` 时**没有下一集可切**
  ///（原版注释里"在首页下发 next_episode"正是它自己举的例子）。
  ///
  /// 所以按 `delivery_test.dart`（本项目自己的真实导航夹具）**同一套**
  /// 取数方式补齐：`getDetail` 拿播放源 → 第一个源 code →
  /// `getEpisodes` 拿该源剧集 → 带首集进播放器。
  ///
  /// ⚠️ 补齐全过程 **best-effort**：任何一步失败都退化为原版那种
  ///    「只给 id」的裸会话（播放器仍然能放第一路流），绝不因为
  ///    详情/剧集拉不到就**什么都不做**（那才是原版那个 bug 的形态）。
  Future<void> _openItemFromRemote(
    String provider,
    String id,
    String? title,
  ) async {
    if (provider.isEmpty || id.isEmpty) {
      debugPrint('[REMOTE] play_item 参数不完整（provider="$provider" '
          'id="$id"）—— 忽略');
      return;
    }

    debugPrint('[REMOTE] play_item → 打开 $provider:$id'
        '（手机给的标题="${title ?? "(无)"}"）');

    // ── ① 尽力补齐：详情 → 首个线路 → 该线路的剧集 ──
    var shownTitle = title ?? '';
    String? cover;
    String? srcCode;
    List<Episode> eps = const [];
    try {
      final d = await SourinApi.getDetail(provider, id);
      // 详情里的标题比手机端传的更准（手机那个是搜索结果里的短标题）
      if (d.title.isNotEmpty) shownTitle = d.title;
      cover = d.cover;
      srcCode = d.sources.isNotEmpty ? d.sources.first.code : null;
      eps = d.episodes;

      /*
       * 详情**不一定**带剧集 —— 与详情页/播放页取法一致，
       * 这时再按源调一次 `get_episodes`。
       */
      if (srcCode != null && srcCode.isNotEmpty) {
        try {
          final more = await SourinApi.getEpisodes(provider, id, srcCode);
          if (more.isNotEmpty) eps = more;
        } catch (e) {
          debugPrint('[REMOTE] play_item 取剧集失败（沿用详情的）: $e');
        }
      }
      debugPrint('[REMOTE] play_item 已补齐：标题="$shownTitle" '
          '源=${srcCode ?? "(无)"} 剧集=${eps.length}');
    } catch (e) {
      /*
       * ⚠️ 补齐失败**不中止** —— 手机端只要求"打开这个片子"。
       *    播放器拿得到 id 就能自己 resolve_stream（与 `needsHydration`
       *    同义），所以这里只是损失"选集栏"，不是损失播放。
       */
      debugPrint('[REMOTE] play_item 补齐详情失败（仍按裸会话打开）: $e');
    }

    final shell = debugShellKey.currentState;
    if (shell == null) {
      // 不静默：这是"点了没反应"的典型成因，必须留在日志里
      debugPrint('[REMOTE] play_item 被丢弃：shell 尚未挂载');
      return;
    }

    // ── ② 走 shell **已有的**导航路径（不另写一套）──
    final first = eps.isNotEmpty ? eps.first : null;
    /*
     * ⚠️ `replace: true` —— 手机端点另一个片子时**换掉**正在播的那个
     *
     * 原版是 `store.openPlayer(...)`（**替换**会话）+ `if (route.name !== "play")
     * router.push(...)`（已经在播放页就什么都不做）。
     *
     * Flutter 侧没有"改会话"这种机制：`PlayerPage` 的会话是构造参数。
     * 所以等价做法是**替换路由**：
     * ```text
     * 没在播放  → pushReplacement 落在栈顶，等价于 push
     * 正在播放  → 换掉当前播放器（**只有一套解码器出声**）
     * ```
     * 不用 `replace` 的话，用户手机上连点两个搜索结果就会叠出两个播放器
     * —— 而 `PlayerPage` 没有 `RouteAware`，被盖住时**不会暂停**，
     * 表现是两个声音同时在放。
     */
    shell._openPlayer(
      PlayRequestData(
        provider: provider,
        id: id,
        title: shownTitle,
        cover: cover,
        episodeId: first?.id,
        episodeTitle: first?.title,
        sourceCode: srcCode,
        episodes: eps,
        episodeIndex: first != null ? 0 : null,
      ),
      replace: true,
    );
  }

  @override
  void initState() {
    super.initState();
    appThemeRevision.addListener(_onThemeChanged);
    /*
     * ★ 跟随系统时要响应系统明暗切换（原版用 matchMedia 的 change 事件）
     *
     * Flutter 侧对应 `didChangePlatformBrightness`（见下）。
     * 不监听的话：用户在系统里切到浅色，我们的 `system` 模式不会跟着变 ——
     * 必须重启应用才对，那是明显的 bug。
     */
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    appThemeRevision.removeListener(_onThemeChanged);
    WidgetsBinding.instance.removeObserver(this);
    // ★ task-39：遥控切频道信号（本类持有）
    //   ⚠️ `_liveVisible` 在 `_ShellPageState` 里（它的 dispose 自己管）
    _liveChannelStep.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  /// 系统明暗偏好变了（仅 `system` 模式需要响应）
  @override
  void didChangePlatformBrightness() {
    if (AppTheme.mode == AppThemeMode.system && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 主题双色（2026-09-24 用户指出「主题双色你没做」）
     * ══════════════════════════════════════════════════════════════════
     *
     * 原版有完整三态：`system` / `light` / `dark`
     * （`src/design/theme.ts` + `src/design/theme-light.css`）。
     * 我之前只写死了深色 —— 这条是补的。
     *
     * ```text
     * AppTheme.mode             用户选择（存 UiPrefs，键 dsh.theme）
     * AppTheme.resolve(...)     解析 system → 实际明暗
     * AppTheme.themeFor(...)    取 forui 主题
     * buildMaterialTheme(...)   深色补全（ui/theme_bridge.dart）
     * buildLightMaterialTheme() 浅色补全（ui/app_theme.dart）
     * ```
     *
     * ⚠️ 两套都要走 bridge 补全语义角色 —— 深色漏填会兜底成亮色，
     *    浅色漏填会兜底成暗色（卡片变黑块）。**两边都会坏**。
     */
    final brightness = AppTheme.resolve(
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    final materialTheme = AppTheme.themeFor(brightness);

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 液态玻璃引擎的外壳（2026-09-24 用户要求「参考开源项目」）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 你可以参考github开源的项目做,不要硬自己实现
     *
     * 之前我自己撸了一套 `LiquidGlass`（BackdropFilter + 自绘投影），
     * 踩了一串坑（投影透过玻璃、tint 用了原版已打回的值、没有氛围层…）
     * 而且最终**还是不像玻璃** —— 因为真正的液态玻璃需要
     * **折射（refraction）**，那是 fragment shader 的活，不是
     * `BackdropFilter` 能做的。
     *
     * # 选这个包的理由（对比过 pub.dev 上 6 个同类）
     *
     * ```text
     * ① **Material-free by design** —— 零 flutter/material.dart 引用。
     *    这条最关键：Flutter 3.47 把 Material 拆成 material_ui 之后，
     *    任何拖进 flutter/material 的包都会重演"两套 Theme 串台"
     *    （设置页标题对比度 1.16:1 那个 bug）。
     * ② 零第三方运行时依赖（纯 Flutter SDK + 自带 GLSL）
     * ③ Windows(Impeller/ANGLE) 与 Android(Vulkan/GLES) 都在支持列表
     * ④ 提供 `brightnessResolver` 回调 —— 让宿主桥接**自己的**主题，
     *    包不耦合任何 Material/Cupertino 主题系统。正合我们的
     *    `AppTheme`（三态：跟随系统/浅/深）。
     * ⑤ MIT / 283 likes / 74.9k downloads
     * ```
     *
     * ⚠️ 它要求 Flutter ≥ 3.41.0 —— 我们是 3.47.5 ✓
     *
     * # 为什么 `brightnessResolver` 必须给
     *
     * 包文档：
     * > Without this, shadows and borders can disappear when the device
     * > is in Dark Mode even if your app is set to Light Mode (and vice-versa).
     *
     * 这正是我们**已经踩过一次**的那类 bug（主题解析链路不一致）。
     * 所以显式接上 `AppTheme.resolve` —— 与 `MaterialApp.theme` 同源。
     */
    return LiquidGlassWidgets.wrap(
      brightnessResolver: (ctx) => AppTheme.resolve(
        systemBrightness: MediaQuery.platformBrightnessOf(ctx),
      ),
      child: MaterialApp(
      title: '源影',
      debugShowCheckedModeBanner: false,
      /*
       * ★★★ 2026-10-08（Owner 第 8 条）：把 Navigator 的 key 交给托盘模块
       *
       * # 为什么必须是**这里**的 key
       * ```text
       * 关闭确认弹窗要在「用户点 X」那一刻弹出来，而那一刻可能：
       *   · 任何页面都还没挂载（进程刚起来就点 X）
       *   · 正停在播放页（全屏路由）
       * ⇒ 只有 MaterialApp **自己的** Navigator 是任何时候都存在的。
       * ⚠️ `builder` 里的 context 在 Navigator 外面 ⇒ `Navigator.of(ctx)`
       *    会找到**根**（那是另一个 Navigator），弹窗会盖不住内容区。
       * ```
       * ⚠️ 与 `_ShellPageState._navKey` 是**两个不同的 key**：
       *    那个是交付实测用来读当前路由名的（`shell.dart:2932`），
       *    语义完全不同，不要合并。
       */
      navigatorKey: AppTray.navigatorKey,
      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ arm64 内容区全空白的**根因修复**（2026-10-01）
       * ══════════════════════════════════════════════════════════════════
       *
       * 症状：arm64 交付包在 Android TV 上**内容区一个像素都不画**
       *       （只剩 `MaterialApp.builder` 那层 `ColoredBox(floorColor)`
       *       的 `#0A0A0A` 地板色），**底栏正常**；x86_64 同车同会话完整。
       *       两臂 Dart 日志逐行相同 ⇒ 不是 Dart 层，是**绘制/合成层**。
       *
       * 规则（由 `.probe\t429_*` 的 7 段 + `.probe\t435_*` 的 11 段归纳，
       *      共 18 个点，18/18 全中）：
       * ```text
       * 决定生死的是「从根往下遇到的**第一个（最外层）**裁剪」的 clipBehavior，
       * 不是嵌套层数。
       *   最外层 == Clip.hardEdge  ⇒ 整棵子树一个像素都不画
       *   最外层 == antiAlias/none ⇒ 里面再套 hardEdge 也**没事**
       * ```
       * ★ 两个决定性最小对（否掉了"层数"假设）：
       *   · `ClipRect(antiAlias)` 在外 + `Scroll(hardEdge)` 在**内** ⇒ **活**
       *   · `Overlay(hardEdge)` 在外 + 里面是 antiAlias + hardEdge ⇒ **死**
       *
       * # 那么产品里"最外层那个 hardEdge"是谁
       *
       * **不是** `Navigator`/`Overlay` —— `WidgetsApp` 显式给 Navigator 传
       * `clipBehavior: Clip.none`（`flutter\...\widgets\app.dart:1695-1696`），
       * `navigator.dart:1601` 的 `Clip.hardEdge` 只是默认参数。
       *
       * **是 `MaterialScrollBehavior.buildOverscrollIndicator`** ——
       * 它给**每一个 Android 上的竖向滚动视图**外面套一层：
       * ```dart
       * // material_ui-1.4.0\lib\src\app.dart:920-927
       * case TargetPlatform.android:
       *   switch (indicator) {                    // useMaterial3 ⇒ stretch
       *     case AndroidOverscrollIndicator.stretch:
       *       return StretchingOverscrollIndicator(
       *         axisDirection: details.direction,
       *         clipBehavior: details.clipBehavior ?? Clip.hardEdge,  // ← 这里
       *         child: child,
       *       );
       * ```
       * 而 `details.clipBehavior` 来自 `ScrollView.clipBehavior`，
       * 其默认就是 `Clip.hardEdge`（`scroll_view.dart:129`，
       * 经 `:486/:498/:527` 塞进 `ScrollableDetails`）
       * ⇒ ★ **这一层永远是 hardEdge，除非页面显式传别的**。
       * 它在 **Viewport 之外** ⇒ 是页面内容路径上**最外层**的裁剪。
       * 产品每个 tab 的页面根都是竖向滚动视图（home 的 `CustomScrollView`、
       * live 4 处、follow 2 处、search 2 处、settings 7 处）
       * ⇒ arm64 上**每个页面**都被这层裁死。
       *
       * # 为什么"改 `shell.dart` 内容区那次 `ClipRect`"没用（自洽性）
       *
       * 那处在 `Stack` 的兄弟层，而这一层在**每个页面内部**、滚动视图外面
       * ⇒ 从根到内容区**先**遇到这一层 ⇒ 按上面的规则**先遇到的说了算**
       * ⇒ 我改的那处永远轮不到 ⇒ 产品读数**逐字节相同**（完全自洽）。
       * （见 `.probe\t434_negative_result.txt` 与 `.probe\t438_root_cause.txt`）
       *
       * # 为什么这样修是对的（而不是"把裁剪都删了"）
       *
       * `StretchingOverscrollIndicator` 的**拉伸效果本身不受影响** ——
       * 它是画在 child **之上**的装饰；`clipBehavior` 只决定它要不要
       * 额外裁一刀。把这一刀降级成 `Clip.none` 后：
       *   · 观感：**没有可辨差别**（拉伸动画照旧，裁的本来就是屏幕边界）
       *   · 语义：不再多一层无谓的裁剪（`ScrollView` 自己的 `Viewport`
       *     仍然会按需裁剪内容，那才是真正需要的裁剪）
       *
       * ⚠️ 改的是**全局** `ScrollBehavior` ⇒ 一处生效于所有页面，
       *    比逐页给 16 处滚动视图传 `clipBehavior` 更不容易漏。
       * ⚠️ 但这条规则**不止于** `MaterialScrollBehavior` ——
       *    t435 段10 证明 `Overlay.wrap(hardEdge)` 也触发同类现象。
       *    所以这里只是消掉产品里那一处，不是通用解。
       */
      scrollBehavior: const _SourinScrollBehavior(),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: [Locale("zh", "CN"), Locale("en", "US")],
      /*
       * ★ 两层 theme 都要给（2026-09-22 实测踩到）
       *
       * ```text
       * theme:          → MaterialApp 的（给 Material 组件兜底背景色）
       * AppThemeHost(data:)   → forui 的（给 FScaffold / FButton 等）
       * ```
       * 只给 FTheme 而漏掉 MaterialApp.theme 的后果：
       * **整个窗口是一片深蓝色**，什么都没有 ——
       * 因为 MaterialApp 用默认亮色主题，而 FScaffold 又依赖它画底。
       *
       * `.toApproximateMaterialTheme()` 是 forui 提供的转换方法，
       * 把 forui 主题映射成 Material 的，两边观感一致。
       *
       * ⚠️ 但那个方法**只填了一部分角色**，其余留空 —— 而 Material 的
       *    getter 兜底值恰好会让「卡片底 = 背景色」「边框 = 纯白」。
       *    所以走 `buildMaterialTheme()`（见 ui/theme_bridge.dart）
       *    把角色补全。这是必须的第二步，不是可选优化。
       */
      theme: materialTheme,
      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ 自绘标题栏必须挂在 **builder 里**（Navigator 之外）
       * ══════════════════════════════════════════════════════════════════
       *
       * # 为什么（2026-09-24 用户报告的真缺陷）
       *
       * 用户反馈：「影视详情页和播放页都没有顶部的那个操作条，无法拖动」。
       *
       * 根因是我把标题栏挂成了 `FScaffold.header` —— 但那是
       * **ShellPage 内部**的位置，而详情页/浏览页/播放页都是
       * `Navigator.push` 上来的**新路由**，它们渲染在 ShellPage
       * **之外**（Navigator 的 overlay 里）：
       * ```text
       * Navigator
       *  ├─ 路由 0: ShellPage  ← 有 FScaffold.header（标题栏在这里）
       *  ├─ 路由 1: DetailPage ← 在它外面！既没标题栏也没拖动区
       *  └─ 路由 2: PlayerPage ← 同上
       * ```
       * 于是**一进详情页就拖不动窗口了**。
       *
       * # 原版怎么做的（`App.vue` L457）
       *
       * ```html
       * <TitleBar />                 <!-- ★ 在 RouterView **外面** -->
       * <div class="app-root">
       *   <main><RouterView>...</RouterView></main>
       *   <LiquidTabBar />
       * </div>
       * ```
       * 标题栏是**整个应用的外壳**，所有路由共用一条；
       * 只有播放页通过 `.is-hidden`（`opacity:0` + 移出屏幕 +
       * `pointer-events:none`）**完全让位给视频**。
       *
       * # Flutter 的对应位置
       *
       * `MaterialApp.builder` 正好在 Navigator **外面** ——
       * 所有路由都会渲染进它的 `child`。所以这里用 Column：
       * ```text
       * ┌──────────────────────────────┐
       * │ _CustomTitleBar（可拖动）      │  ← 所有页面共用
       * ├──────────────────────────────┤
       * │ child（Navigator：各路由）      │
       * └──────────────────────────────┘
       * ```
       *
       * ⚠️ 播放页不在这里隐藏 —— 播放页是全屏视频，标题栏会挡住画面。
       *    用 `_TitleBarHost`（下面）根据"当前是否在播放页"动态收起。
       */
      builder: (context, child) => _TextScaleHost(
        child: AppThemeHost(
          data: materialTheme,
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 2026-10-01：删掉 `FToaster`（原本是 `child: FToaster(`）
         * ══════════════════════════════════════════════════════════════
         *
         * # 为什么删（交付实测逼出来的，不是审美）
         *
         * `.probe\t427_deliver_tv.py` 用**交付包本体**在 Android TV
         * （`emulator-5556`，ARM 翻译层）实测：
         * ```text
         * arm64 交付包（44,937,288 B）  → 纯黑，屏幕只有 1 种颜色 #000000
         * x86_64 交付包（同车/同会话）  → 198 色，角落 #0A0A0A
         * ```
         * 十一段最小对探针（`.probe\t424_arm64.apk`）把凶手锁到了
         * `FToaster` 内部那次 `Overlay.wrap`：
         * ```text
         * 段 4  FTheme → FToaster                    → _Flat   全透明（a00=00）
         * 段 5  FTheme → Overlay.wrap(Clip.none)     → _Flat   580 色  ✅
         *       ↑ 与段 4 逐字同构，唯一差别是 clipBehavior
         * ```
         * `FToaster.build()`（`toaster.dart:384-413`）在 `_entries` 为空时
         * 就是 `Overlay.wrap(child: Stack(... children: [widget.child]))`；
         * 而 `Overlay.wrap` 默认 `clipBehavior: Clip.hardEdge`
         * （`overlay.dart:503`）⇒ `_RenderTheater.paint` 走
         * `context.pushClipRect(...)`（`overlay.dart:1528-1545`）。
         *
         * # 为什么删它是**语义无损**的
         *
         * ```text
         * grep 'FToaster.of(|FToasterState|showFToast|showRawFToast' lib/
         *   ⇒ 0 命中 —— 产品从不弹 forui 的 toast
         * 产品自己的 toast = 各页面手写的 `_toast` 字段 + `_Toast` 黑底胶囊
         *   （detail_page.dart:1227 / follow_page.dart:869 /
         *     settings_page.dart:519 / settings\skip_page.dart:204）
         * ```
         * `FToasterState.build()` 在 `_entries` 为空时只做两件事：把
         * `widget.child` 原样塞进一个 `Stack`，再套一层 `Overlay`。它不建
         * Timer、不注册监听、不读偏好 ⇒ 删掉它只是去掉了那一层 `Overlay`
         * （以及它那次 hardEdge 裁剪），**没有任何别的副作用**。
         *
         * ⚠️ 将来若真要用 forui 的 toast，必须把 `FToaster` 加回来，但
         *    **不要**用它的默认 `Clip.hardEdge` —— 要么用
         *    `Overlay.wrap(clipBehavior: Clip.none, ...)` 自己包，要么先
         *    在那个平台上实测过再说。
         */
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★ 为什么标题栏在这一层（`MaterialApp.builder`）
         * ══════════════════════════════════════════════════════════════
         *
         * `builder` 在 **Navigator 之外** —— 所以所有路由
         *（ShellPage / DetailPage / PlayerPage）都渲染进它的 `child`，
         * 共享同一条标题栏。
         *
         * 历史（两次真缺陷，都是用户发现的）：
         * ```text
         * 第一版  挂成 `FScaffold.header` → 它在 ShellPage **内部**，
         *         而详情页/播放页是 push 上来的**新路由**
         *         → 「一进详情页就拖不动窗口」
         * 第二版  移到这里（对了），但又给播放页加了
         *         主动隐藏 → 「播放页没有操作条，无法拖动窗口」
         * ```
         * 结论：**标题栏是全局的窗口控制区，不能挂进任何具体页面**；
         * 并且在桌面端它是**唯一的拖动区**（`titleBarStyle: hidden`
         * 去掉了系统标题栏），所以**不能隐藏**。
         *
         * ⚠️ **只有 `ClipRRect` 是不够的**（2026-09-25 任务 AD 实测）
         *
         * 用户报的「深色主题白角 / 浅色主题黑角」就是这条注释
         * 里那个"尚未验证的断言"**被实测推翻了**：
         * ```text
         * 导出 Flutter 自己合成的那张图（RepaintBoundary.toImage，带 alpha）：
         *   圆角外 alpha = 0   ← Flutter 认为那里是**透明**的
         *   ⇒ 白/黑**不是 Flutter 画的**，是**窗口背景**在 Flutter 表面
         *     之外填的（window_manager 的 SetWindowCompositionAttribute）
         * ```
         * 而窗口背景用的是**系统**主题（注册表 `AppsUseLightTheme`），
         * 与用户选的 `dsh.theme` **不同源** —— 这就是"与主题相反"的来源。
         * 实测本机：系统 `AppsUseLightTheme=1`（浅色）而应用 `dsh.theme=dark`
         * → 深色应用 + 浅色窗口底 = **白角**。
         *
         * 四条 DWM 透明路已实测全是 no-op（见 `win32_window.cpp` 顶部），
         * 所以这里改方向：**让圆角外由我们自己画成主题色**
         * —— `WindowFrame` 现在收一个 `backdrop`。
         */
        child: WindowFrame(
          /*
           * ★★★ 圆角**外面**那一圈的颜色（2026-09-25 任务 AD）
           *
           * 必须与**内容区同源**，否则又会"与主题相反"。
           * `AppTheme.floorColor(brightness)` 正是为此而生：
           * 它只认传进来的 `brightness`，色值从 `themeFor(brightness)` 取。
           *
           * ⚠️ 这里**不能**用 `FTheme.of(context)` / `Theme.of(context)` ——
           *    这个 `context` 在 `FTheme` **上面**（见下面那段长注释），
           *    两者都会静默兜底成**浅色**。
           */
          backdrop: AppTheme.floorColor(brightness),
          /*
           * ═══════════════════════════════════════════════════════════════
           * ★★★ 这里【不再传】`shadowColor`（2026-09-25 实测撤销）
           * ═══════════════════════════════════════════════════════════════
           *
           * 用户原话：
           * > 这次你改的没有了,但是不是应该加个浅色的边框或者阴影的,
           * > 用来区分跟其他浅色客户端的重叠
           * > 像 qq 客户端这种边缘模糊阴影,之前的是实体的非常难看
           *
           * 我曾实现"在窗口**内侧**画一圈渐变"来模拟投影。
           * ★ 用户实测反馈：「现在就是一圈实色的边缘，根本就不是阴影」
           *
           * 真实抓图（`.probe/RING-real2.png`，上边中点垂直扫描）：
           * ```text
           * y=-1: #FFFFFF   ← 窗口外（桌面）
           * y=+0: #E5E7ED   ← 突然跳到我们的色
           * y=+5: #D5D7DD   ← ★ 最暗（比内容 #E8EBF3 暗 19 级）
           * y=+16: #E8EBF3  ← 回到内容色
           * ```
           * ⇒ 窗口最外 5~16px 是一圈【比内容暗 19 级】的实色带
           *
           * ★ 结构性原因：真投影必须画在窗口**外面**；
           *   画在**内侧**时那一圈被窗口边界**硬切** ⇒ 调参数救不回来。
           *
           * ★ 而 DWM 阴影本机拿不到（三层实测）：
           * ```text
           * ① 我们的窗口外扩 (0,0,0,0)；加回 CAPTION+THICKFRAME 仍 (0,0,0,0)
           * ② ★★★ 全新创建的标准窗口（WS_OVERLAPPEDWINDOW）也是 (0,0,0,0)，
           *      窗口外像素 249 均匀无渐变
           *    ⇒ ★★ 不是我们的样式问题，是【系统不给任何窗口画阴影】
           * ③ VisualFXSetting = 2（「调整为最佳性能」← 关闭窗口阴影）
           * ```
           *
           * ⇒ ★ 两条路都堵死 ⇒ **不加投影**（保持现状：无边界）
           *    详细记录见 `lib/ui/widgets/window_frame.dart` 的
           *    `kWindowShadowWidth` 文档。
           *
           * ⚠️ 若将来要恢复，**必须**先解决"画在窗口外"这个前提
           *    （需要窗口比内容大 + 那块区域真透明）。
           */
          /*
           * ═══════════════════════════════════════════════════════════
           * ★★★ 这里删掉了 `AmbientBackground`，但**保留一层极简底色**
           *     （2026-09-24 实测决定，"理论上应该没问题"是错的）
           * ═══════════════════════════════════════════════════════════
           *
           * # 先试了完全删掉 —— 是**回归**
           *
           * 开源包文档说 Impeller 上玻璃直接采样 live backdrop、
           * 不需要背景 widget。但那是说"不需要一个**专门的玻璃背景**"，
           * 不等于"窗口可以没有底色"。
           *
           * `PrintWindow` 截图 + 颜色直方图对比（同一页面、同一窗口尺寸）：
           * ```text
           *                    删之前                  完全删掉之后
           * 第 2 常见色   (239,241,247) x40160   (26,27,29) x47286
           *               ↑ 浅色底（正常）          ↑ 深色标题栏（**错的**）
           * 标题栏中线     (240,241,243)            (26,27,29)
           * 标题栏 x=640   y=2..40 = 浅灰            y=2..40 = 近黑
           * ```
           * **标题栏从浅灰变成了近黑** —— 因为背后没有底，
           * 玻璃折射的是窗口的**透明清屏色（黑）**。
           * 浅色主题下这一条会是一道突兀的黑边。
           *
           * # 所以保留什么、删掉什么
           *
           * ```text
           * 删掉  三个氛围光球（radial-gradient + blur 130px）
           *       → Impeller 的玻璃**自己**有折射和边缘光照，
           *         叠一层自绘光球反而会和 shader 抢戏
           * 保留  一层纯底色（--bg-base 语义）
           *       → 玻璃要有"色差"才看得出来；
           *         浅色下必须是 #EEF0F6 那一档带蓝的浅灰，
           *         不能是 forui 的纯白（白色叠白色 = 还是白）
           * ```
           *
           * ⚠️ 底色用 `LightTokens.bgBase`（`app_theme.dart`，照抄原版
           *    `--bg-base: #eef0f6`）而不是 `FTheme.colors.background` ——
           *    forui 的 `neutral.light.background` 是**纯白 #FFFFFF**，
           *    那正是我早先踩过的坑（整个应用变纯白，玻璃全看不见）。
           */
          child: ColoredBox(
            /*
             * ⚠⚠ 不能用 `Theme.of(context)` 判断明暗！
             *    （2026-09-24 真机实测抓到）
             *
             * # 症状
             *
             * 切到**深色主题**后，内容变黑了（对的），
             * 但**标题栏还是浅色** `(238,238,238)`（错的）。
             *
             * # 根因：`MaterialApp.builder` 的 context 在 Theme **上面**
             *
             * `MaterialApp` 把 `theme` 注入到**它自己构建的 Navigator 子树**里，
             * 而 `builder` 的 `context` 是 `MaterialApp` **外层**的：
             * ```text
             * LiquidGlassWidgets.wrap
             *  └ MaterialApp
             *      ├ builder(context, child)   ← 这个 context 看不到 theme！
             *      │   └ …（标题栏在这里）
             *      └ theme: materialTheme      ← 注入在这下面
             * ```
             * 所以 `Theme.of(context)` 在这里拿到的是
             * **`ThemeData.fallback()`**（Material 3 的**亮色**）——
             * 永远是 light，不管用户选什么。
             *
             * ★ 这正是本项目早先踩过的同一类坑
             *   （双 Material 拆分：`flutter/material` 与 `material_ui` 各自有
             *   一套 `Theme` InheritedWidget，`Theme.of` 不能跨包）。
             *
             * # 修法：用**我们自己解析出的** brightness
             *
             * `build()` 里已经算过一次了（且与 `materialTheme` **同源**）：
             * ```dart
             * final brightness = AppTheme.resolve(
             *   systemBrightness: MediaQuery.platformBrightnessOf(context),
             * );
             * ```
             * 直接用它 —— 这才与 `MaterialApp.theme` 一定一致。
             *
             * ══════════════════════════════════════════════════════════
             * ★★★ 上面那条"修法"只修了一半（2026-09-25 真机像素取证）
             * ══════════════════════════════════════════════════════════
             *
             * # 症状（用户指出：「你看这深色模式下的状态栏显示正常吗?」）
             *
             * ```text
             * 深色主题下：
             *   标题栏 (x=500,y=16) = (239,239,239)  ← 浅灰
             *   内容区 (x=1000,y=60) = (6,6,6)        ← 深色
             * ```
             * 96/116 张历史截图稳定复现，不是偶发。
             *
             * # 根因：**判断**那一半对了，**取色**那一半还在坑里
             *
             * ```dart
             * color: brightness == Brightness.light
             *     ? LightTokens.bgBase
             *     : AppPalette.of(context).background,  // ← 就是这一行
             * ```
             * `brightness` 是自己解析的（对），但深色分支取色走的是
             * `FTheme.of(context)` —— 而**这个 `context` 在 `FTheme` 上面**：
             * ```text
             * MaterialApp
             *  ├ builder(context, child)   ← 这个 context 不是 FTheme 的子孙
             *  │   └ AppThemeHost(data: materialTheme)   ← 注入在 builder 的**返回值**里
             *  └ theme: materialTheme
             * ```
             * forui 的 `FTheme.of` 找不到祖先时**不抛异常**，
             * 而是静默兜底成 `AppTheme.themeFor(Brightness.light)`
             * （forui `src/theme/theme.dart:140`：
             *  `return theme?.data ?? AppTheme.themeFor(Brightness.light);`）——
             * 也就是**浅色**，`background = #FFFFFF` 纯白。
             *
             * ⇒ 深色下这层地板画成了**纯白**，标题栏玻璃透出白底
             *   → `(239,239,239)`（白底 + 玻璃的暗化合成）。
             *
             * # 为什么之前"以为修好了"
             *
             * 旧注释只盯着 `Theme.of`（Material 那套）的坑，
             * 换成自己解析 `brightness` 之后就认为完事了 ——
             * 但**同一个表达式里还有第二个独立主题系统**（forui），
             * 它的 `FTheme.of` 有**一模一样**的"找不到祖先 → 静默浅色"行为。
             * 两套主题系统各踩一次，是同一个坑的两个实例。
             *
             * ⚠️ 教训：`builder` 里**任何** `X.of(context)` 只要 X 的
             *    注入点在 builder 返回值内部，就都会兜底成浅色。
             *    这里的 `FTheme.of`、`Theme.of` 都算。
             *
             * # 修法：取色也走**自己解析的** brightness
             *
             * 用 `AppTheme.floorColor(brightness)`（`ui/app_theme.dart`）——
             * 它内部只认传进来的 `brightness`，颜色从
             * `AppTheme.themeFor(brightness)` 取，与 `MaterialApp.theme`
             * **同源**，因此结构上不可能再与内容区不一致。
             *
             * 同源之后：内容区 `FScaffold` 画的是
             * `colors.background`（`scaffold.dart:194`），
             * 深色下正是 `#0A0A0A` —— 与这层地板**同一个值**。
             */
            color: AppTheme.floorColor(brightness),
            /*
             * ★ 手机端裁剪遥控（task-6，2026-10-02）
             *
             * Owner 原话：「手机端不需要遥控,需要裁剪掉」。
             *
             * 手机**就是**遥控器（手机浏览器打开遥控页去遥控别的设备），
             * 它自己不需要被别人遥控 —— 而 RemoteBridgeHost 挂载后会
             * setGlobals → _tick() 轮询 Rust 遥控 HTTP 服务器
             * （remote_report_state / remote_take_commands），
             * 也就是手机端会**一直在监听遥控命令**。
             *
             * 只隐藏设置页那块 UI 是不够的（settings_page.dart 已加
             * `if (!Device.isTouchOnly)`），这里必须同时不挂载，
             * 两处一起生效才算真的裁剪掉。
             *
             * TV / 桌面**保留**（TV 靠遥控器操作，见 device.dart 的
             * needsFocusRing；桌面用键盘/鼠标，也不裁）。
             */
            child: Device.isTouchOnly
                ? SystemUiHost(
                    brightness: brightness,
                    child: _TitleBarHost(child: child ?? const SizedBox()),
                  )
                : RemoteBridgeHost(
              globals: _globals,
              /*
               * ══════════════════════════════════════════════════════
               * ★★★ 局域网遥控桥的挂载点（集成任务 M2，2026-09-24）
               * ══════════════════════════════════════════════════════
               *
               * # 之前是什么状态（审计发现的最高优先级问题）
               *
               * `ui/remote_bridge.dart`（734 行）**没有任何生产代码 import** ——
               * 只有 `remote_probe.dart` 这个探针用。于是：
               * ```text
               * RemoteBridgeHost 从不挂载 → setGlobals 从不被调用
               *   → _tick() 第一行就 `if (_globals == null) return`
               *   → remote_report_state / remote_take_commands 永不执行
               *   → remote_set_home / remote_set_search 永不执行（没人回填）
               *   → search_all 全 lib/ 只有 remote_bridge.dart:505 一处调用
               * ⇒ 手机遥控的「手机 → 客户端」整条链路是**断的**
               * ```
               * 文件头自己写明了「`RemoteBridgeHost`（永远挂载，在
               * `MaterialApp.builder` 里）」—— 但 shell 的 builder 树里没有它。
               *
               * # 为什么必须在这一层（`_TitleBarHost` 的 child 就是 Navigator）
               *
               * 树的结构（自上而下）：
               * ```text
               * MaterialApp.builder
               *  └ FTheme → FToaster → WindowFrame → ColoredBox
               *     └ _RemoteBridgeHost   ← ★ 这里：**Navigator 之外**
               *        └ _TitleBarHost → Column
               *           ├ _CustomTitleBar（自绘标题栏）
               *           └ Expanded(child) = **Navigator（各路由）**
               * ```
               * 遥控桥必须覆盖**所有路由**（首页 / 详情页 / 播放页都能被遥控），
               * 挂在某个页面内部的话切页就没了 —— 与自绘标题栏同一个理由
               * （见上面 `builder:` 的长注释）。
               *
               * ⚠️ **只挂这一处**（`remote_bridge.dart` 文件头专门警告过）：
               *    builder 里挂一次、home 里又挂一次会造成两个宿主同时
               *    `setGlobals`，虽然单例桥能容忍（后注册的覆盖），
               *    但两个 `dispose` 会互相干扰。
               */
              /*
               * ★ 统一 toast 宿主 —— 必须在这一层（与自绘标题栏同一层，
               *   Navigator 之外）⇒ 首页/详情页/播放页都能弹到。
               */
              child: ToastHost(
                child: _TitleBarHost(child: child ?? const SizedBox()),
              ),
            ),
          ),
        ),
      ),
      ),
      /*
       * ★ 交付实测要读「当前路由名」
       *
       * ⚠️ 用 `NavigatorObserver` 而**不是** `onGenerateRoute` ——
       *    后者是"由你负责生成路由"，给它返回一个空 widget 就等于
       *    把整个导航废掉（我第一版就是这么写的，幸好没跑）。
       *    observer 只**观察**，不干预路由生成。
       */
      /*
       * ★★★ 进新路由时**主动种焦点**（任务 AI，缺陷② 的本体修复）
       *
       * `FocusPrimingObserver` 是**无条件**注册的（不像下面那个只在
       * `kDeliveryTest` 时注册）—— 它是**生产行为**，不是探针：
       * 每个新路由（详情页/播放页/…）挂载后，如果焦点没有落在一个
       * 真控件上，就种一个。这正是「进了详情页遥控器就失灵」的修法。
       *
       * ⚠️ 放在列表**第一个** —— `didPush` 的调用顺序就是注册顺序，
       *    要保证"种焦点"早于任何观察/记录逻辑。
       */
      navigatorObservers: <NavigatorObserver>[
        FocusPrimingObserver(),
        ...kDeliveryTest
            ? <NavigatorObserver>[RouteNameObserver()]
            : const <NavigatorObserver>[],
      ],
      home: ShellPage(
        key: debugShellKey,
        coreError: widget.coreError,
        coreDataDir: widget.coreDataDir,
        liveChannelStep: _liveChannelStep,
      ),
      ),
    );
  }
}

class ShellPage extends StatefulWidget {
  const ShellPage({
    super.key,
    this.onTabChanged,
    this.coreError,
    this.coreDataDir,
    this.liveChannelStep,
  });

  /// 核心启动失败时的错误消息（null = 成功）
  ///
  /// ⚠️ **有值时整个内容区被错误页接管**（任务 AM，2026-09-25）。
  ///
  /// 之前的注释写的是"一路传下来是为了让发现页能如实显示" ——
  /// 但**这条链路从来没被接上**：`_ShellPageState` 里 `coreError`
  /// 出现 0 次（真机实测确认：核心启动失败时界面照常渲染空态，
  /// 用户只看到"还没有可用的内容源"，完全不知道核心没起来）。
  /// 现在它真的被用上了。
  final String? coreError;

  /// 核心本应使用的数据目录（失败时用于"下一步怎么办"）
  final String? coreDataDir;

  /// tab 变化时的回调（诊断用）
  ///
  /// 加它是为了让 TV 探针能观察「按键有没有真的切页面」——
  /// 否则只能从外部猜，而焦点导航是**行为**，截图看不出来。
  final ValueChanged<AppTab>? onTabChanged;

  /// ★★ 遥控"切频道"信号（task-39）
  ///
  /// 由 `_SourinAppState` 提供（它拿不到本页的 `_liveKey`），
  /// 本页订阅并转成 `LivePageState.cycleChannel(delta)`。
  ///
  /// ⚠️ 当成**脉冲**用（每次通知 = 按了一下），不要读它的值 ——
  ///    连按"下一个"时值恒为 `+1`，`ValueNotifier` 不会重复通知，
  ///    所以监听者必须"收到就执行"。
  final ValueNotifier<int>? liveChannelStep;

  @override
  State<ShellPage> createState() => _ShellPageState();
}

/// ★ 探针用的全局访问点（2026-09-22）
///
/// # 为什么需要它
///
/// TV 适配验收必须回答一个**行为**问题：
/// ```text
/// 派发方向键之后，当前 tab 变了没有？
/// ```
/// 这没法从 widget 树外面读 —— `_tab` 是私有状态。
///
/// 两种做法：
/// ```text
/// a) 让调用方传 callback 进来        → 需要改 ShellPage 的构造签名
/// b) 暴露一个只读的全局 key          → 不改现有调用点
/// ```
/// 选 (b)：`SourinApp` 已经无参构造了 ShellPage，加必填参数会牵连改动。
/// 这个 key 只在探针里用，正式代码不引用它。
/// 最近一次 push 的路由名（仅交付实测用）
String lastRouteName = '(none)';

/// 只观察、不干预的路由名记录器
///
/// ⚠️ 必须在 `kDeliveryTest` 为 false 时**完全不注册** ——
///    生产构建里不需要任何路由开销。
class RouteNameObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    lastRouteName = route.settings.name ?? route.runtimeType.toString();
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    lastRouteName =
        previousRoute?.settings.name ?? '(popped to root)';
    super.didPop(route, previousRoute);
  }
}

final debugShellKey = GlobalKey<_ShellPageState>();

class _ShellPageState extends State<ShellPage>
    with SingleTickerProviderStateMixin {
  AppTab _tab = AppTab.home;

  /*
   * ══════════════════════════════════════════════════════════════════════
   * ★★★ 核心启动失败 → 内容区被错误页接管（任务 AM，2026-09-25 真机实测）
   * ══════════════════════════════════════════════════════════════════════
   *
   * # 修的是什么 bug
   *
   * 真机（Android TV，数据目录指向 App 不可访问的路径）实测日志：
   * ```text
   * [SHELL] ★ 核心启动失败: PathAccessException: ... Permission denied
   * [SHELL] FIRST_FRAME_RENDERED          ← ★ 界面照常渲染
   * [SHELF] 取收藏失败: 核心尚未启动
   * [HOME] ★ loadAll 失败:
   * [HOME] 渲染完成: 启用源=0 个 ... 错误=无   ← ★ "错误=无"！
   * ```
   * **用户看到的是一个空应用**（"还没有可用的内容源"），
   * 却完全不知道核心根本没启动。
   *
   * # 根因：链路建好了，最后一跳断了
   *
   * `coreError` 从 `main()` 一路传到 `ShellPage`（8 处引用），
   * 但 `_ShellPageState` 里**出现 0 次** —— 拿到却从不使用。
   * 所以"界面照常渲染空态"不是偶然，是必然。
   *
   * # 为什么用「接管内容区」而不是「顶部加一条错误条」
   *
   * 核心没起来时**所有页面都是死的**：
   * ```text
   * 发现 → 0 个源（空态）      直播 → 空
   * 追更 → 空                  搜索 → 搜不了
   * 设置 → 读了也没用
   * ```
   * 只在首页顶部加条 banner 的话：
   * ```text
   * · 用户一切到「直播」就看不到错误了 → 又变回"这个应用怎么是空的"
   * · 而首页那条 banner 下面还是"还没有可用的内容源" —— 与真相矛盾
   * ```
   * 所以**内容区整体接管**：错误信息在**任何 tab 下都可见**，
   * 且不再显示那个误导性的空态。
   *
   * # 为什么**保留**底栏和标题栏（不做全屏接管）
   *
   * ① 外壳仍然有意义：底栏让用户能确认"应用本身是活的"——
   *    全屏接管会让人怀疑是不是整个程序崩了。
   * ② 底栏的「设置」是**修复入口**：用户可能要去设置里
   *    换数据目录 / 看诊断信息。把底栏拆掉等于把退路也拆了。
   * ③ 与原版的交互一致（见下方 `_CoreErrorView` 的说明）。
   *
   * ⚠️ 这一层是**纯读** `widget.coreError`，不引入新的状态 ——
   *    核心启动发生在 `runApp` 之前，运行期不可能再变。
   */

  /// 发现页的 key —— 用来在「切回首页」时调它的 `loadAll()`
  ///
  /// # 为什么需要从外部调
  ///
  /// 原版 `HomeView` 在 `keepAlivePages` 里，`onMounted` 只跑一次；
  /// 它靠 `onActivated`（每次切回都触发）来刷新。
  ///
  /// Flutter 的 `IndexedStack` **没有**等价的钩子 —— 子页面被保活，
  /// 但切回来时不会有任何通知。所以由 shell 主动调。
  ///
  /// 原版注释强调过**不能**无条件全量重拉：
  /// > 那样每次切回来要等 4 秒。这里只重拉**分区列表**（很快，走缓存），
  /// > 区块内容按需补齐。
  /// 所以这里调的是 `loadAll()`（非 force）。
  final _homeKey = GlobalKey<HomePageState>();

  /// 全局导航 key —— 交付实测要用它读当前路由名
  final _navKey = GlobalKey<NavigatorState>();


  /// 交付实测只跑一次
  bool _deliveryRan = false;

  /// 直播页 / 追更页 / 搜索页的 key
  ///
  /// 同样用于「切回本页要刷新」（原版的 `onActivated`）——
  /// `IndexedStack` 没有等价钩子，只能由 shell 主动调。
  final _liveKey = GlobalKey<LivePageState>();
  final _followKey = GlobalKey<FollowPageState>();
  final _searchKey = GlobalKey<SearchPageState>();
  final _settingsKey = GlobalKey<SettingsPageState>();

  /// ★ task-3 ⑲「已缓存」页的 key —— 与上面四个同契约（一页一个，只出现一次）
  ///
  /// ⚠️ 必须用 `CachePageState` 这个**具体**类型：`_switchTo` 要调
  ///    `loadAll()`，而 GlobalKey 的 `currentState` 是 `State<T>` ——
  ///    泛型给错就取不到那个方法（编译期报错，好在不会静默失败）。
  final _cachedKey = GlobalKey<CachePageState>();

  /// ★★ task-65：**待激活**的追更页 tab（`null` = 无请求）
  ///
  /// # 为什么需要这个字段（而不是直接调 `_followKey.currentState.showTab`）
  ///
  /// Owner 原话：
  /// > 首页的 追更，历史，收藏 应该有一个查看更多按钮……
  /// > 点一下就跳转到 追更页面，**激活对应的 tab**
  ///
  /// 但"点查看更多"时有两种情形：
  /// ```text
  /// ① 追更页**已经**在树上（用户之前访问过 ⇒ 保活缓存里有）
  ///    ⇒ 直接 `_followKey.currentState?.showTab(key)` 就行
  /// ② 追更页**还没**进过树（首次访问）
  ///    ⇒ `currentState == null` ⇒ 上面那行**静默失败** ⇒ 请求丢失
  /// ```
  /// ⇒ 所以必须把意图**存下来**，由 `_pageFor(AppTab.follow)` 在**构造**
  ///   `FollowPage` 时读走（`initialTab:`）。这样两种情形都覆盖。
  ///
  /// ⚠️ 消费后**必须清空**（见 `_pageFor` 里那处）——
  ///    否则用户之后手动切到追更页时会被这个旧请求**再拽一次**。
  ///
  /// ⚠️ 它是**实例字段**，不是全局单例 —— 作用域就是"这一个 Shell"，
  ///    与 `_followKey` 同级，测试里可经 widget 树拿到（无隐式全局状态）。
  String? _followTabRequest;

  /// ★★ task-65：切到「追更」页并激活 `key` 对应的 tab
  ///
  /// `key` 取值：`'following'` / `'all'` / `'continue'`（见 `_FollowTab.key`）。
  void _openFollowTab(String key) {
    debugPrint('[SHELL] 查看更多 → 追更页 tab=$key');
    /*
     * ① 先记下意图（覆盖"追更页还没进过树"的情形 —— 见 `_followTabRequest`）
     */
    _followTabRequest = key;
    /*
     * ② 切到追更页。
     *
     * ⚠️ `_switchTo` 在 `t == _tab` 时**直接 return**（不 setState）⇒
     *    如果用户**已经**在追更页，这一步不会重建 `FollowPage`，
     *    那么 `initialTab` 那条路**不会触发**。
     *    ⇒ 所以紧接着**直接调 `showTab`**（下面 ③）兜住这种情形。
     */
    _switchTo(AppTab.follow);
    /*
     * ③ 若追更页已在树上 ⇒ 直接切（立刻生效，不等下一次 build）
     */
    _followKey.currentState?.showTab(key);
  }

  /// 读走并清空「待激活 tab」请求（见 `_followTabRequest`）
  ///
  /// ★ 抽成方法而不是在 `_pageFor` 里内联两行 —— 这样"读走+清空"是
  ///   **一个原子动作**，不会出现"只读没清"的漏改（那会让旧请求复活）。
  String? _takeFollowTabRequest() {
    final r = _followTabRequest;
    _followTabRequest = null;
    return r;
  }

  /// ★★★ 当前**可见**的 tab —— 可见性的**唯一真相**（task-41）
  ///
  /// # 它是怎么统一两套实现的
  ///
  /// 原先这里是 `ValueNotifier<bool> _liveVisible`（task-39 的本地实现，
  /// 只表达"直播页可不可见"）。那有两个问题：
  /// ```text
  /// ① 两套真相：`ShellScope.activeTabOf` 与本 notifier 都会随切 tab 变化
  ///    ⇒ 必然漂移（本项目已有"两处同构必须一起改"的教训）
  /// ② bool 表达不了"**哪个** tab 可见" ——
  ///    将来（不只直播页）有第二个页面要判断可见性时就不够用
  /// ```
  /// ⇒ 现在**只保留一个** `ValueNotifier<AppTab>`（权威值），
  ///    并通过 `ShellScope`（InheritedNotifier）向下暴露：
  /// ```text
  /// _activeTab (ValueNotifier<AppTab>)      ← ★ 唯一真相
  ///   ├ ShellScope.notifier                 → 新代码用
  ///   │    · ShellScope.isActive(ctx, tab)
  ///   │    · ShellScope.activeTabOf(ctx)
  ///   └ _liveVisibleAdapter (bool 投影)     → 兼容既有 LivePage(visible:)
  /// ```
  /// ★ 为什么还留一个 bool 适配器：`LivePage` 的既有签名是
  ///   `ValueListenable<bool>? visible`，且同一轮里 task-39 还改了别的
  ///   （遥控信号）—— **少一次改动少一次风险**（Lead 的建议）。
  ///   适配器是**投影**（由 _activeTab 派生），所以**不会**产生第二套真相。
  final _activeTab = ValueNotifier<AppTab>(AppTab.home);

  /// 直播页可见性的 **bool 投影**（由 [_activeTab] 派生，不是独立状态）
  ///
  /// ⚠️ 它**只读**派生 —— 任何人都不该直接写它，否则又变成两套真相。
  ///    唯一的同步点是 [`_syncVisibility`]（由 `_switchTo` 调用）。
  final _liveVisible = ValueNotifier<bool>(false);

  /// 把 [_activeTab] 的变化**投影**到 [_liveVisible]
  ///
  /// ★ 单向：`_activeTab` → `_liveVisible`。反方向不存在。
  ///   这样"可见性"永远只有一个权威值，投影只是给既有签名做兼容。
  void _syncVisibility() {
    final v = _activeTab.value == AppTab.live;
    if (_liveVisible.value != v) _liveVisible.value = v;
  }

  /// 探针读取当前 tab（只读，不改变状态）
  AppTab get debugCurrentTab => _tab;

  /// 探针**显式切换** tab（交付实测 / 空间导航实测用）
  ///
  /// # 为什么测试需要这个（2026-09-23）
  ///
  /// 空间导航上线后，方向键的语义变成"移动焦点"，
  /// 于是"按 N 次 ← 就能回到首页"这个假设**不再成立** ——
  /// 实测按 12 次 ← 还在一整排源条 pill 里横向移动，
  /// 结果探针停在 live 页上测"内容区焦点移动"，
  /// 而 live 页源条下面没有海报行，↓ 自然无路可走 → 假失败。
  ///
  /// **测试要控制前提**，不该依赖"按多少次键能走到"这种脆弱假设。
  void debugSwitchTo(AppTab t) => _switchTo(t);

  /// 缺陷 3 探针读数口：当前离场页的淡出不透明度 + 离场窗口是否还在
  ///
  /// 返回 `(leavingTabName, leavingFadeValue, leaveControllerValue)`；
  /// 没有离场页时第一项为 null。用于 `.probe/zz_t3_overlap_probe_test.dart`
  /// 逐帧核对 `enter(t) + leavingFade(t) == 1.000`。
  (String?, double, double) debugLeavingFadeForProbe() => (
        _leavingTab?.name,
        _leavingFade.value,
        _leaveC.value,
      );

  /// 上一个 tab 的序号 —— 用来算切换方向
  int _prevIndex = 0;

  /// ★★★ task-14 ⑨ 白屏修复（2026-10-04）：**刚被切走**的那一页
  ///
  /// 离场窗口内非 null（窗口长度 = Motion.base），由 _leavingTimer 清回。
  /// 唯一消费者是保活 Stack：它决定谁继续参与合成（见 Offstage.offstage）。
  AppTab? _leavingTab;

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ 2026-10-08（Owner 第 2 条）离场页**淡出** —— 「拖影」的根治
   * ══════════════════════════════════════════════════════════════════
   *
   * 用户原话：
   * > 每个页面来回切换,出现严重的拖影,就是页面已经切换了,
   * > 但是那些上个页面的元素还没彻底消失,看着非常难受
   *
   * # 症状的机制（不是玄学，是两层同时可见）
   * ```text
   * 改前：离场页拿的是 `AlwaysStoppedAnimation(1.0)`
   *       （task-14 ⑨ 白屏修复，见 _KeepAliveTransitionState 的长注释）
   *   ⇒ 它**整段 260ms 都停在不透明度 1**
   * 而新页从 opacity 0 淡入 ⇒ 新页半透明时，底下那层旧页 100% 透出来
   *   ⇒ 用户看到的正是「上个页面的元素还没彻底消失、两层内容叠加」
   * ```
   * ★ 白屏修复**不能**回退（那会让 260ms 里露出 floorColor，实测
   *   76–120ms 的纯色 #EDEDF5/#EEF0F6）—— 正确做法是让离场页**淡出**：
   *   它一开始仍然是不透明的（挡住 floorColor ✓），
   *   但会跟着新页一起消失（不再叠加 ✓）。
   *
   * # 为什么曲线用 easeInOut（不是 easeOut）
   * ```text
   * 新页走 easeOut（前快后慢）：40ms 就到 ~0.56 不透明度。
   * 若离场页也用 easeOut 淡出，两边在 40ms 时各 ~0.5 ⇒ 中段仍有 50% 叠影。
   * easeInOut（`Cubic(0.65, 0, 0.35, 1)`）**前段几乎不动**：
   *   t=0.2 时它才降到 ~0.9 ⇒ 旧页继续挡住 floorColor；
   *   而那时新页已经 ~0.65 ⇒ 叠影从 100% 降到 ~30%；
   *   t=0.5 时旧页 0.5、新页 0.95 ⇒ 叠影 ~2.5%（肉眼不可见）。
   * ⇒ 「先挡住，后消失」——两个目标同时满足。
   * ```
   *
   * ⚠️ 控制器必须挂在 **shell** 上（不能挂在离场页自己身上）：
   *    `TickerMode(enabled: t == _tab)` 会把隐藏页的 ticker 停掉，
   *    离场页自己那条 `_c` 根本不会走（task-14 ⑨ 的注释逐字记过这件事）。
   *    shell 的 ticker 永远是活的 ⇒ 只有它能驱动这条淡出。
   *
   * ⚠️ `value: 0` ⇒ `_leavingFade` 初值 = 1.0（「刚就位」）——
   *    离场页在窗口的第一帧必须仍然不透明，否则白屏修复白做。
   */
  late final AnimationController _leaveC = AnimationController(
    vsync: this,
    duration: Motion.base,
    value: 0,
  );

  /// 离场页的不透明度：1.0（刚就位）→ 0.0（彻底消失）
  ///
  /// [2026-10-09 / Owner 第 3 条] 曲线 = `Motion.easeOut`，**与进入页
  /// `_KeepAliveTransition._c` 同源** => 两条动画同一 ticker 时间轴、
  /// 同一 duration => `enter(t) + leave(t) === 1.000`（逐帧互斥）。
  /// 改前用 `Motion.easeInOut`，与进入页互为反相 —— 真机峰值 sum 1.719。
  /// 全部推导与读数见下面 `_leaveC` 处那段长注释。
  ///
  /// 只在 `t == _leavingTab` 的那一页上生效（见 build 里的传参）。
  late final Animation<double> _leavingFade = Tween<double>(
    begin: 1.0,
    end: 0.0,
  ).animate(
    CurvedAnimation(
      parent: _leaveC,
      /*
       * [2026-10-09 / Owner 第 3 条「切页文字重叠」] 曲线从 easeInOut 换成
       *   **与进入页同源**的 easeOut。
       *
       * # 改前的真机读数（.probe/zz_t3_overlap_probe_test.dart v4）
       * ```text
       * t=  0ms  enter out=0.000  |  leave out=1.000  |  sum(out)=1.000
       * t= 16ms  enter out=0.261  |  leave out=0.997  |  sum(out)=1.257
       * t= 40ms  enter out=0.565  |  leave out=0.977  |  sum(out)=1.542
       * t= 80ms  enter out=0.840  |  leave out=0.879  |  sum(out)=1.719  <-- 峰值
       * t=130ms  enter out=0.961  |  leave out=0.500  |  sum(out)=1.461
       * t=260ms  enter out=1.000  |  leave out=1.000  |  sum(out)=2.000  <-- 见下
       * ```
       * 80ms 时两页**同时**处于 0.84 / 0.88 的「都很亮」区间
       *   => 屏幕上是两份文字叠在一起 = Owner 说的「文字重叠」
       *
       * # 根因：不是「层数」，是**两条曲线互为反相**
       * ```text
       * 进入页  _c      走 Motion.easeOut   = Cubic(0.22, 1, 0.36, 1)
       * 离场页  _leaveC 走 Motion.easeInOut = Cubic(0.65, 0, 0.35, 1)
       *   -> easeOut  : 起步快、收尾长 —— 16ms 就 0.261、80ms 已 0.841
       *   -> easeInOut: 起步平、收尾也平 —— 80ms 才掉到 0.880
       * => 恰好是「一个猛涨、一个不动」=> 峰值 sum 1.72 出现在 81ms
       * ```
       * 原注释（下方 2026-10-08 记录）以为「离场用 easeInOut 前段几乎不动
       * 才能继续挡住 floorColor」—— 挡住 floorColor 是**对的**（确实要挡），
       * 但它没算「新页此时已经很亮」=> 挡住的代价就是叠影。
       *
       * # 为什么换成 easeOut 就是**精确互斥**
       * ```text
       * 离场页绘制不透明度 = _leavingFade = 1.0 -> 0.0，由 _leaveC 驱动
       * 两个 controller 都在**同一个 setState 帧**里 forward(from: 0)
       *   => 同一 ticker 时间轴、同一 duration(Motion.base) => elapsed 相同
       * => leave(t) = 1 - easeOut(t) = 1 - enter(t)
       * => enter(t) + leave(t) === 1.000 **对每一个 t 都成立**
       * ```
       * 数值验算（同一求值器）：峰值 = 1.000 @ 0ms，sum>1.5 持续 **0ms**。
       * 逐帧：0.000/1.000、0.261/0.739、0.565/0.435、0.840/0.160、0.961/0.039。
       * => 任意时刻两页不透明度之**和恒为 1** => 数学上不可能「两页都亮」。
       *
       * # 为什么这一改**同时收掉**缺陷 18（切页残影）
       * ```text
       * 改前 t>=260ms: _leavingTab 已被 _leavingTimer 清成 null => 外层
       *   FadeTransition 被整个移除（下方 lf == null 分支）=> 离场页回到
       *   **不透明度 1**（读数 sum=2.000）=> 若此刻它还没被 offstage
       *   （换位/重建的时序差），就是一块**满亮的残影**
       * 改后 t>=260ms: _leaveC 走到 1 => _leavingFade = 0 => 即使外层
       *   那层被移除，离场页在退出窗口那一刻**本身就是 0**
       *   => 残影从「靠时序侥幸」变成「数学上为 0」
       * ```
       *
       * 曲线**只在**离场侧改；进入页仍是 Motion.easeOut（一行未动）。
       * `Motion.easeInOut` 在 tokens.dart:170 仍被别处使用，**不删**。
       */
      curve: MotionPrefs.curve(context, Motion.easeOut),
      reverseCurve: MotionPrefs.curve(context, Motion.easeOut),
    ),
  );

  /// 保活 Stack 的**绘制顺序**（最后一项画在最上面）
  ///
  /// # 为什么不能直接用 AppTab.values
  /// ```text
  /// 离场页必须画在当前页**下面** —— 否则它会盖住正在淡入的新页
  /// （离场页停在「已就位」，是不透明的）。
  /// 而 AppTab.values 的顺序是固定的：
  ///   home(0) → live(1)：离场页 home 恰好在下面 ✓
  ///   live(1) → home(0)：离场页 live 会**盖住** home       ✗
  /// ```
  /// ⚠️ 只在 _switchTo 里重排；初值 = 声明顺序。
  /// ⚠️ 槽位**数量**永远是 5（只换顺序）⇒ Stack 的「按位置匹配」语义不变
  ///    ⇒ 保活不受影响。
  List<AppTab> _stackOrder = AppTab.values.toList();

  /// 离场窗口的收尾定时器（dispose 里必须取消，见那里的注释）
  Timer? _leavingTimer;

  /// 是否最大化（自绘标题栏要自己显示按钮状态）
  bool _maximized = false;

  /// 底部「追更」徽标 = **还需要看多少集**（task-40）
  ///
  /// # ★★★ 这里原来是 `int _unread = 3;` —— 一个**硬编码**的 3
  ///
  /// 用户原话：
  /// > 底部的菜单栏，追更默认就显示  3  徽标，这是错误的
  ///
  /// 旧注释写着「原版来自 store.unreadCount」，但**实际是个字面量** ——
  /// 注释在说谎。实测（`.probe/probe_tests/zz_t40_badge_repro_test.dart`）：
  /// ```text
  /// PROBE40|A_badges=[3]
  /// ⇒ 挂载即显示 3，与数据无关
  /// ```
  /// 为什么它会一直显示 3：唯一的更新路径是
  /// `FollowPage.onUnreadChanged` → `_refreshUnread()` → `totalUnread()`，
  /// 而 `FollowPage` **只在用户点过追更 tab 之后**才被构造
  /// ⇒ 没进过追更页 ⇒ 永远停在初始值。
  ///
  /// # 新语义：总集数 − 已看集数（用户明确要求）
  ///
  /// ```text
  /// 全 12 集，看到第 1 集  ⇒ 11
  /// 全 12 集，看到第 12 集 ⇒ 0  ⇒ ★ 徽标消失
  /// ```
  /// 算法与另两处（首页「我的」/ 追更页）**共用** `followRemainingByKey`
  /// —— 三处写三遍必然漂（本项目已踩过"两处同构"的坑）。
  ///
  /// # 为什么在 initState 就拉一次
  ///
  /// 底部徽标**任何时候都可见**（不像追更页要点进去）⇒ 必须自己在
  /// 启动时取数，不能等 FollowPage 回调。
  int _unread = 0;

  /// 拉底部徽标（追更还剩多少集）
  ///
  /// ⚠️ 用 `listAllProgress()` 而**不是** `continueWatching()`：
  ///    后者带 `WHERE finished=0 AND position > 5` 过滤（store.rs:909），
  ///    会把"已看完"的行滤掉 ⇒ 刚看完的剧徽标**不会消失**。
  ///
  /// ⚠️ 失败静默（保留旧值）—— 与 task-36 修过的"失败不许清空"
  ///    同一个原则：瞬时失败不该让徽标闪成 0。
  Future<void> _refreshUnread() async {
    try {
      final following = await SourinApi.listFavorites(followingOnly: true);
      final all = await SourinApi.listAllProgress();
      final byKey = followRemainingByKey(
        following: following,
        allProgress: all,
      );
      var sum = 0;
      for (final v in byKey.values) {
        sum += v;
      }
      if (!mounted) return;
      if (sum != _unread) setState(() => _unread = sum);
      debugPrint('[SHELL] 追更徽标(还剩未看) = $sum（${following.length} 部追更）');
    } catch (e) {
      debugPrint('[SHELL] 追更徽标取数失败（保留旧值 $_unread）: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    /*
     * ⚠️ 只在桌面调 windowManager（2026-09-22 实测踩到）
     *
     * Android 上直接调会抛：
     * ```text
     * MissingPluginException(No implementation found for method isMaximized
     *   on channel window_manager)
     * Unhandled Exception ... _syncMaximized (shell.dart:189)
     * ```
     * 因为 `window_manager` 的原生端只在桌面平台注册。
     *
     * ★ 教训：**每个插件调用点都要问「这个平台有吗」**。
     *   集中成一个 `kIsDesktop` 常量，比到处写 Platform.isWindows 清晰。
     */
    if (kIsDesktop) _syncMaximized();

    /*
     * ★ 核心启动失败 → 打一条**可验证**的日志（任务 AM）
     *
     * # 为什么这条日志是修 bug 的一部分
     *
     * 真机复现日志里最刺眼的是这一行自相矛盾：
     * ```text
     * [HOME] ★ loadAll 失败:
     * [HOME] 渲染完成: 启用源=0 个（当前=） 分区=0 卡片=0 错误=无   ← ★
     * ```
     * 核心没启动，探针却报「错误=无」。根因是那条探针只在
     * `loadAll` **走完 try** 时才打印，而 `_error` 会被中间某次
     * 调用重置（`home_page.dart:285`）—— 探针因此**说了谎**。
     *
     * # 为什么修在 shell 而不是改那条探针
     *
     * `home_page.dart` **不在本任务的改动范围**内（文件归属约束）。
     * 而且从设计上讲，更好的修法是**根本不挂载发现页**：
     * ```text
     * 核心没起来 → 内容区是错误页 → HomePage 不存在
     *            → 那条探针根本没机会打印 → 矛盾从源头消失
     * ```
     * 这比"让探针说得更准"更彻底 —— 一个不该出现的页面
     * 连它的日志都不该出现。
     *
     * ⚠️ 这条日志是**验收判据**：失败场景下它必须出现，
     *    而 `[HOME] 渲染完成` / `[SHELF] 取收藏失败` 必须**不**出现。
     */
    if (widget.coreError != null) {
      debugPrint('[SHELL] ★ 核心启动失败页接管内容区'
          '（发现页不挂载 → 不再有误导性的空态与"错误=无"）');
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 开机种焦点（任务 AI，2026-09-25 真机实测）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须有一个**不依赖按键**的触发点
     *
     * 真机复测缺陷② 时暴露出比"详情页不动"更严重的一层：
     * 冷启动后**连一次 `[NAV]` 日志都不打** —— 我自己的 handler 没被调用。
     *
     * 去读 Flutter SDK 才找到原因（`focus_manager.dart: handleKeyMessage`）：
     * ```dart
     * if (FocusManager.instance.primaryFocus == null) {
     *   return false;                      // ★★ 直接丢弃按键
     * }
     * var handled = false;
     * if (_earlyKeyEventHandlers.isNotEmpty) { ... }   // 连 early handler 都到不了
     * ```
     * 即 **`primaryFocus == null` 时所有 handler 一个都不跑**。
     *
     * 这造成一个**自锁**：
     * ```text
     * primaryFocus == null
     *   -> 按键被丢弃 -> moveFocus 不被调用 -> primeFocus 不被调用
     *   -> primaryFocus 永远是 null       ★ 按多少次方向键都没用
     * ```
     * 唯一的破局手段（种焦点）本身要靠按键触发，而按键恰恰被挡掉了。
     *
     * # 为什么用 `addPostFrameCallback`
     *
     * 要等 widget 树挂载 + 布局完成，`_collect()` 才收得到可聚焦控件。
     * 在第一帧之前调用会"一个候选都没有"，等于白调。
     *
     * 每次进新路由也会再种一次（`FocusPrimingObserver`，挂在
     * `MaterialApp.navigatorObservers` 上）—— 那才是缺陷② 的本体。
     */
    primeFocusSoon();

    /*
     * ★★★ 底部徽标：**开机就取一次**（task-40）
     *
     * # 为什么不能等 FollowPage 回调
     *
     * 旧代码的死结（这就是"永远显示 3"的成因）：
     * ```text
     * _unread 唯一更新路径 = FollowPage.onUnreadChanged
     *   → 而 FollowPage 只在**用户点过「追更」tab** 之后才构造
     *   ⇒ 没进过追更页 ⇒ _unread 停在初始字面量（原来写死 3）
     * ```
     * 底部徽标**任何时候都可见**，所以它必须自己取数。
     *
     * ⚠️ 用 `addPostFrameCallback` 而不是直接 await：
     *    首帧必须尽快出来，不能等两个 IPC。
     * ⚠️ 与 FollowPage 的 `_refreshUnread` 会**同时**存在（都调
     *    `setState` 改 `_unread`）—— 两者算的是**同一个公式**，
     *    所以后到的结果不会与前一个冲突（幂等）。
     */
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshUnread());
    });

    /*
     * ★★ 订阅"遥控切频道"信号（task-39）
     *
     * 信号来自 `_SourinAppState._liveChannelStep`（那里拿不到本 State 的
     * `_liveKey`，所以走 notifier —— 见那边的注释）。
     *
     * ⚠️ `ValueNotifier` 的 listener **只在值变化时**触发。
     *    遥控连续按"下一个"时 delta 恒为 `+1` ⇒ 第二次赋值**不触发**！
     *    ⇒ 所以这里不读 `value`，而是**当成一次"脉冲"**处理：
     *      收到通知就执行一次（而不是"按值执行"）。
     */
    widget.liveChannelStep?.addListener(_onLiveChannelStep);

    /*
     * ⚠️ 首次可见性同步 —— 初始 tab 是首页，直播页**不可见**。
     *    `_liveVisible` 的初值已经是 `false`（见声明处），
     *    所以这里不用额外做；但若将来初始 tab 变成 live，
     *    必须在 `_switchTo` 里同步（那里已经统一处理了）。
     */

    /*
     * ★★★ 交付实测（只在 `--dart-define=DELIVERY_TEST=true` 时启用）
     *
     * 用**真实的导航回调**驱动 —— 走的就是用户实际会走的路径，
     * 不是另写一套探针逻辑。
     *
     * ⚠️ `kDeliveryTest` 是**编译期常量**（`bool.fromEnvironment`），
     *    为 false 时整段被 tree-shake 掉，生产构建零开销。
     *
     * ⚠️ 必须放在 `_ShellPageState` 里 —— 顶层 `main()` 没有
     *    `mounted` / `_switchTo` 这些 State 成员（我第一版挂错了）。
     */
    if (kDeliveryTest && !_deliveryRan) {
      _deliveryRan = true;
      // 等首帧 + 首页数据加载完再开始
      Future.delayed(const Duration(seconds: 6), () {
        if (!mounted) return;
        DeliveryTest(
          switchTo: (i) => _switchTo(AppTab.values[i]),
          openDetail: _openDetail,
          openPlayer: _openPlayer,
          goBack: () async {
            final nav = Navigator.of(context);
            if (nav.canPop()) nav.pop();
          },
          currentRoute: () => lastRouteName,
          /*
           * ★ HEVC 测试要**渲染出 Video widget** 才能跑
           *
           * 离屏跑时 `VideoController` 初始化不完 → `setProperty`/`open`
           * 永久阻塞（实测踩到，见 delivery_test.dart 的详细说明）。
           * 所以推一个真实播放页上去，测完再 pop。
           */
          pushTestPage: (page) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => page),
            );
          },
          popTestPage: () {
            final nav = Navigator.of(context);
            if (nav.canPop()) nav.pop();
          },
          /*
           * ★ 主题体检要读**真实渲染树**里的主题角色值
           *
           * 传 shell 自己的 context —— 它在 MaterialApp/FTheme 之下，
           * 所以 `Theme.of(shellContext)` 拿到的是子页面**同款**的
           * ThemeData（同一个 MaterialApp 提供者）。
           *
           * ⚠️ 不能传 `debugShellKey.currentContext`（那是 State 的
           *    context，同样在树里，但用闭包捕获的 `context` 更直接、
           *    也不依赖 key 是否已挂载）。
           */
          themeContext: () => context,
        ).run();
      });
    }

    /*
     * ★★ TV 方向键：用全局 handler（2026-09-22，第四次也是最终方案）
     *
     * # 为什么不走焦点树
     *
     * 试了三种焦点树方案全部失败（详见 build 方法里的记录）：
     * 根因是 Flutter 只沿主焦点的祖先链冒泡，而我们的底栏
     * 因为 overlay/re-parent 结构始终不在那条链上。
     *
     * `HardwareKeyboard.instance.addHandler` 是**全局**注册，
     * 不依赖焦点归属 —— 实测收到 44/44 个事件。
     *
     * # 为什么要「输入框守卫」
     *
     * 全局 handler 会在**任何**时候收到按键，包括用户在搜索框打字。
     * 不守卫的话：在搜索框按 ←/→ 会变成切页面，用户没法移动光标。
     *
     * 守卫方式：看主焦点所在的位置有没有文本输入。
     * ```text
     * 有 EditableText 祖先 → 认为在输入，忽略方向键
     * 否则               → 当作导航操作
     * ```
     * 这也是 `ArtPlayer` 那套 `isFocus` + 输入框排除逻辑的等价物
     * （契约里记过：快捷键不能和输入框打架）。
     *
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 必须**按设备** + **按页面**双重门控（2026-09-23 实测抓到的真回归）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 我第一版漏了什么
     *
     * 原写法是**无条件** `addHandler(_onGlobalKey)`，而 `_onGlobalKey`
     * 对所有方向键一律 `return true`。于是：
     * ```text
     * 播放器：←/→ 是快退快进、↑/↓ 是音量（player_page.dart 的 _onKey）
     *        但 HardwareKeyboard 的 handler 跑在焦点树**之前**，
     *        return true 就等于 preventDefault → 播放器**永远收不到**
     * ```
     * 真机实测（Android TV，`adb shell input keyevent DPAD_RIGHT` ×2）：
     * ```text
     * logcat **一行输出都没有** —— 播放器完全没收到按键
     * ```
     * 也就是**音量键和快进键全废了**，而且没有任何报错。
     *
     * # 原版怎么做（`spatialNav.ts` 的注释）
     *
     * > 那些是给**桌面键盘**用的，TV 上方向键应该先被空间导航消费掉。
     * > 用 capture + stopPropagation，保证 TV 上方向键不会触发播放器快捷键。
     * > **桌面不受影响 —— 因为桌面根本不装这个模块（见调用点）。**
     *
     * 关键词是**「见调用点」** —— 原版是**有条件安装**的，我漏了这层。
     *
     * # 两层门控
     *
     * ```text
     * ① 设备层 Device.needsFocusRing（= 是 TV）
     *    桌面不装 → 键盘方向键照旧归播放器/列表
     * ② 页面层 _pageUsesArrowKeys（= 当前在播放器）
     *    TV 上播放器**也**需要方向键（遥控器快进/音量），
     *    所以光靠设备层不够
     * ```
     * 两者都放行时，方向键才归空间导航。
     */
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 为什么是 `addEarlyKeyEventHandler` 而不是 `addHandler`（任务 AI，2026-09-25）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 真 bug：一次方向键让焦点**前进两格**
     *
     * 真机实测（Android TV，tvdemo 数据源，`[NAV]` 追踪）：
     * ```text
     * [NAV] dir=NavDir.right 移动到 _BottomItem... | 选中=(252,450,404,522) | 已 requestFocus
     * [NAV] 帧后确认: ... 实际矩形=(404,450,556,522) 一致=false   ← 又前进了一格
     * ```
     * `选中` 与 `实际` 相差正好**一个 tab 的宽度**（152px）——
     * 也就是说**有第二个搬运方**把焦点又推了一格。
     *
     * # 根因：`HardwareKeyboard.addHandler` 的返回值**不会**中止派发
     *
     * Flutter SDK `hardware_keyboard.dart` 的 `_dispatchKeyEvent`：
     * ```dart
     * for (final KeyEventCallback handler in _handlers) {
     *   final bool thisResult = handler(event);
     *   handled = handled || thisResult;      // ★ 只是"或"起来，**不 break**
     * }
     * ```
     * 所以 `_onGlobalKey` 返回 `true` **不等于** `preventDefault` ——
     * 事件照样继续流到 `FocusManager` → 焦点树 → 内建
     * `DirectionalFocusIntent` **再搬一次**。
     *
     * 旧注释里写的
     * > `return true` 就等于 preventDefault → `DirectionalFocusIntent` 永不触发
     * **是错的**（那个结论当年是在"底栏 KeyDown 被吞"的别的现象上得的）。
     *
     * # 修法：改用 `FocusManager` 的 early handler（返回值**真的**会中止）
     *
     * `focus_manager.dart` 的 `_dispatchKeyEvent`：
     * ```dart
     * if (_earlyKeyEventHandlers.isNotEmpty) { ... }
     * if (handled) {
     *   return true;          // ★ 在这里就返回了
     * }
     * // Walk the current focus from the leaf to the root ...   ← 焦点树走不到
     * for (final node in [primaryFocus!, ...primaryFocus!.ancestors]) { ... }
     * ```
     * 即 early handler 返回 `handled` → **焦点树整段被跳过** →
     * 内建 `DirectionalFocusIntent` 不再触发 → 一次按键只移动一格。
     *
     * # 为什么语义上与旧写法**等价**（不是新引入的行为）
     *
     * `_onGlobalKey` 的契约本来就是「方向键 return true=消费；其余 return false=放行」。
     * `HardwareKeyboard` 那条路径上它**没能真正消费**（上面那个 bug），
     * 而 early handler 这条路径上它**能**。所以这个改动只是让
     * 早已写好的契约**第一次真正生效**，而不是改交互。
     *
     * 门控全部保留且顺序不变：`Device.needsFocusRing` → `_pageUsesArrowKeys()`
     * → `_isTypingInTextField()` → 只认方向键。非方向键一律 `ignored`，
     * 照旧走焦点树（播放器快捷键、输入框打字都不受影响）。
     */
    FocusManager.instance.addEarlyKeyEventHandler(_onEarlyKey);

    /*
     * ★★★ 保活缓存 —— **惰性**创建（task-41）
     *
     * # 为什么是"惰性"而不是"启动时全建"
     *
     * 我第一版在 initState 里 `List.generate` 了 5 个页面 —— **错的**：
     * ```text
     * ① 启动即挂载 5 个页面 ⇒ 5 个页面同时 loadAll（5 份网络/FFI 请求）
     *    启动变慢；而且用户可能**从不**点设置页，白建
     * ② 更严重：core_error_test 里只挂 ShellPage 的用例
     *    会连带把 HomePage/LivePage/... 全建出来
     *    ⇒ 它们各自的 initState 去打 FFI ⇒ 在无核心的测试环境抛异常
     *    ⇒ **4 个既有测试变红**（我实测到了）
     * ```
     * ★ 原版 `keep-alive` 也是**惰性**的：组件**首次被访问时**才创建，
     *   之后才保留。惰性与保活并不冲突 ——
     *   ```text
     *   首次访问 → 建（一次）
     *   之后切走 → 留在树上（Offstage）⇒ State 不丢   ← 保活的收益在这里
     *   切回来   → 复用同一个实例 ⇒ 不重建
     *   ```
     * ⇒ 只有"**访问过的**"页面才进树；没访问过的槽位先放占位。
     *
     * ⚠️ 占位必须是**尺寸稳定的空 widget**（`SizedBox.shrink`），
     *    不能是 `null`/条件省略 —— Stack 的子节点**按位置**匹配，
     *    槽位数量变化会让后面的页面错位重建（保活失效）。
     */
    _visited.add(_tab);
  }

  /// 已经**访问过**的 tab（惰性保活：只有访问过的才进树）
  ///
  /// ★ 一旦加入就**不再移除** —— 这正是"保活"：
  ///   切走只是 `Offstage`，State 留在树上。
  final Set<AppTab> _visited = <AppTab>{};

  /// 已创建的页面缓存（与 `AppTab.values` 下标一一对应）
  ///
  /// ⚠️ `null` = 还没访问过（不进树，只放占位）
  late final List<Widget?> _pageCache = List<Widget?>.filled(
    AppTab.values.length,
    null,
  );

  /// 取某个 tab 的**保活**子页 —— 返回**同一个实例**（首次调用时创建）
  ///
  /// ★ 与 `_pageFor` 的分工：
  /// ```text
  /// _pageFor(t)     **构造**一个新对象（每次调用都是新的）
  /// _contentFor(t)  **查找/惰性创建**并缓存（保活路径专用）
  /// ```
  /// ⚠️ 凡是保活路径（build 里的 Stack）都必须用 `_contentFor`；
  ///    用 `_pageFor` 会 new 出新实例 ⇒ 保活失效（本任务的核心不变量）。
  Widget? _contentFor(AppTab t) {
    if (!_visited.contains(t)) return null;
    return _pageCache[t.index] ??= _pageFor(t);
  }

  /// 把 [_onGlobalKey] 的 `bool` 契约适配成 `KeyEventResult`
  ///
  /// `_onGlobalKey` 的语义是：
  /// ```text
  /// true  -> 这个按键我消费了（方向键）
  /// false -> 放行给焦点树 / 平台
  /// ```
  /// `KeyEventResult` 的对应关系：
  /// ```text
  /// true  -> KeyEventResult.handled   （★ 会**中止**焦点树派发）
  /// false -> KeyEventResult.ignored   （继续正常派发）
  /// ```
  /// 单独写一个适配函数而不是把 `_onGlobalKey` 的返回值改成枚举 ——
  /// 后者会改动 300 多行的守卫逻辑，而它们已经被真机验证过。
  /// 这里只做**类型转换**，保证判定逻辑一字不动。
  KeyEventResult _onEarlyKey(KeyEvent event) =>
      _onGlobalKey(event) ? KeyEventResult.handled : KeyEventResult.ignored;

  /// 当前页面是否**自己要**用方向键（播放器）
  ///
  /// # 为什么要单独判断，不能只看设备
  ///
  /// TV 上播放器同样需要方向键（遥控器 ←/→ 快进、↑/↓ 音量），
  /// 而那是原版 `ArtPlayer` 的键位（见 `player_page.dart` 的 `_onKey`）。
  /// 所以"是 TV"不足以决定方向键归属 —— 还要看**当前页面是谁**。
  ///
  /// # 怎么判断
  ///
  /// 看 `_navKey` 的导航栈顶：播放器是用 `MaterialPageRoute` 推上去的，
  /// 所以"栈里有没有路由"就等价于"在不在子页面"。
  ///
  /// ⚠️ 详情页**不在**排除名单里 —— 详情页需要方向键来选剧集/按钮，
  ///    它也没有自己的方向键处理（`detail_page.dart` 没有 `onKeyEvent`）。
  ///    只有播放器例外。
  bool _pageUsesArrowKeys() {
    /*
     * 用"shell 之上有没有被 push 的路由"判断太粗（详情页也会被算进去），
     * 所以这里用**显式标志** —— 播放器打开时置位，关闭时清除。
     * 比猜路由类型可靠，也不会因为将来加页面而误判。
     */
    return _playerOpen;
  }

  /// 播放器是否打开（由 `_openPlayer` / 播放器 pop 回调维护）
  bool _playerOpen = false;

  /// ★ 播放器路由的**代号**（集成任务 M2）
  ///
  /// # 为什么需要它（遥控 `play_item` 暴露出来的陈旧回调问题）
  ///
  /// `_openPlayer` / `_openLiveChannel` 都是「push 之后挂个
  /// `whenComplete` 把标志清掉」。单播放器时代这样是成立的：
  /// 那个 `whenComplete` 只可能属于自己的那个路由。
  ///
  /// 但遥控的 `play_item` 会**替换**正在播的那个（手机端点另一个片子，
  /// 而客户端可能正开着播放器）—— 替换走 `pushReplacement`，
  /// 此时：
  /// ```text
  /// ① 新播放器 pushReplacement → _playerOpen = true
  /// ② 旧路由退场动画结束后，它那个 whenComplete 才跑
  ///    → 无条件 _playerOpen = false   ← **把新播放器的标志清掉了**
  /// ```
  /// 后果有两个，都不轻：
  /// ```text
  /// · TV 上全局方向键 handler 会重新抢走 ←/→（播放器快进失灵）
  /// · 下一次 play_item 以为"没在播"，于是**再叠一个播放器**上去
  ///   → 两个解码器同时出声
  /// ```
  ///
  /// 修法是给每个路由发一个单调递增的代号，回调只在**自己仍是最新那个**
  /// 时才清标志。单个播放器的常规路径行为完全不变（代号必然相等）。
  int _playerOpenGen = 0;

  /// 全局按键处理（TV 方向键 → **空间导航**）
  ///
  /// 返回 true 表示**消费**掉事件，不再向下传递。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-09-23 重写：从「切 tab」改成「移动焦点」
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # 原来错在哪（TV 实测抓到的真 bug）
  ///
  /// 旧版本是：←/→ 直接 `_switchTo(下一个 tab)`。
  /// 截图看「发现 → 设置」确实切过去了，所以我以为 TV 适配没问题。
  ///
  /// **但实测内容区焦点完全不动**：
  /// ```text
  /// 按 ↓ 前: Focus @(12,469) 187x71
  /// 按 ↓ 后: Focus @(12,469) 187x71   Δ=(0,0)  ✗
  /// 按 → 前: Focus @(12,469) 187x71
  /// 按 → 后: Focus @(12,469) 187x71   Δx=0     ✗
  /// ```
  /// 也就是**遥控器选不了片** —— 而"能不能选片"才是 TV 上的核心诉求。
  ///
  /// ★ 这个误判和原版 `spatialNav.ts` 里记的一模一样：
  /// > 我用 `Tab` 键验的焦点，但**遥控器上没有 Tab 键**。
  /// > 所以那个"12/12 通过"是假阳性。
  ///
  /// # 为什么旧写法会**吃掉**内容区的方向键
  ///
  /// `HardwareKeyboard` 的 handler 跑在**焦点树派发之前**。
  /// 旧写法对 ←/→ 直接 `return true` → 事件被标记已处理 →
  /// `FocusManager` 再也不会派发 → `DirectionalFocusIntent` 永不触发。
  ///
  /// # 新写法（对齐原版）
  ///
  /// ```text
  /// 方向键  → 几何邻居算法找下一个可聚焦节点并移过去
  /// 找不到  → 也 return true（否则 Scrollable 会拿去做"滚页面"）
  /// 输入框  → return false（放行给输入框移动光标）
  /// ```
  /// 切 tab 改成「焦点移到哪个 tab 上就切到哪个」（Enter 确认），
  /// 这与原版的交互一致 —— 原版 `LiquidTabBar.vue` **只有 `@click`**，
  /// 没有键盘 handler，靠的就是空间导航 + 确认键。
  bool _onGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    /*
     * ── 门控 ①：设备层 ──
     *
     * 桌面**不启用**空间导航 —— 方向键归播放器/列表用
     * （原版：「桌面不受影响 —— 因为桌面根本不装这个模块」）。
     */
    if (!Device.needsFocusRing) return false;

    /*
     * ── 门控 ②：页面层 ──
     *
     * TV 上播放器也要方向键（遥控器快进/音量），放行给它。
     */
    if (_pageUsesArrowKeys()) return false;

    // ── 输入框守卫：正在打字时不抢方向键 ──
    if (_isTypingInTextField()) return false;

    /*
     * 只接管**方向键** —— 其余按键照旧走焦点树的正常派发。
     */
    final k = event.logicalKey;
    final isArrow = k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight;
    if (!isArrow) return false;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 没有焦点时**主动放一个**（对齐原版 `primeFocus`）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 原来这里是 `return false`，为什么改成 primeFocus
     *
     * 原写法（2026-09-22）：
     * ```dart
     * if (FocusManager.instance.primaryFocus == null) return false;
     * ```
     * 当时的理由是"启动瞬间焦点还没建立，让事件流下去"。
     * 但**真机实测（2026-09-23）证明这个理由不成立**：
     *
     * ```text
     * 首页：焦点会自动落在源条第一个 pill 上 → 方向键能用 ✓
     * 详情页：遥控器 OK 进去之后，按方向键**毫无反应** ✗
     * ```
     * 原因是详情页是个**新路由**，里面没有任何地方设过焦点
     * （`detail_page.dart` 里搜不到 `autofocus`/`FocusNode`/`requestFocus`），
     * 所以 `primaryFocus == null`；而 `moveFocus` 需要"当前矩形"
     * 才能算邻居，拿不到就直接返回 false ——
     * 用户看到的是「首页能选片，一进详情页遥控器就失灵」。
     *
     * # 两种"没动"必须区分
     *
     * ```text
     * primaryFocus == null  → 焦点无处安放 → 必须**先放一个**（bug）
     * 有焦点但找不到邻居     → 到边界了     → 静默不动是正确行为（设计）
     * ```
     *
     * 原版 `spatialNav.ts` 专门有 `primeFocus()` 处理第一种情况，
     * 注释原文：
     * > TV 上如果没有焦点，用户按方向键是"从零开始"，
     * > 而我们的算法在"当前没有焦点"时才会落到第一个 ——
     * > 主动做一次更自然（页面一进来就有焦点环，用户知道从哪开始）。
     *
     * ⚠️ 放置成功后 `return true`（消费掉这次按键）——
     *    否则这次方向键既放了焦点又让 `Scrollable` 滚了页面，
     *    用户会觉得"按一下跳了两格"。
     */
    if (FocusManager.instance.primaryFocus == null) {
      final primed = primeFocus();
      // 放下焦点后，这一次按键就算处理完了
      if (primed) return true;
      // 实在没有可聚焦的东西（空页面）→ 不消费，让事件流下去
      return false;
    }

    final dir = k == LogicalKeyboardKey.arrowUp
        ? NavDir.up
        : k == LogicalKeyboardKey.arrowDown
            ? NavDir.down
            : k == LogicalKeyboardKey.arrowLeft
                ? NavDir.left
                : NavDir.right;

    final moved = moveFocus(dir);

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 这里**刻意不做**「焦点进底栏就自动切 tab」（2026-09-23 撤掉）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 我一度加了这个，为什么要撤
     *
     * 当时的想法：「焦点落在某个 tab 上就等于选中它，帮用户省一次确认键」。
     * 听起来更好，但它有**两个问题**：
     *
     * ## ① 与原版交互不一致（Owner 的硬性要求）
     *
     * 原版 `LiquidTabBar.vue` 里**只有 `@click="go(item)"`**，
     * 没有任何"焦点变化就切换"的逻辑：
     * ```text
     * 方向键 → 空间导航移动焦点（只是高亮，不切页面）
     * 确认键 → 激活当前焦点项 → 才切页面
     * ```
     * 自动切换会让用户**按 ←/→ 路过底栏时页面乱跳** ——
     * 这是行为差异，不是"优化"。
     *
     * ⚠️ 本项目的硬性约束：「操作逻辑必须和原版完全一致，
     *    任何交互差异需先与用户确认」。所以这里必须撤掉。
     *
     * ## ② 它本身还有一个 bug（实测抓到）
     *
     * 用"焦点矩形与底栏矩形求交"判断焦点在不在底栏上，
     * 而**根节点的矩形是整屏**（实测 `(0,0,960,540)`）——
     * 它和底栏必然相交 → 从根节点按 → 会**误判成"焦点在底栏"**，
     * 于是莫名其妙切到 follow 页。
     *
     * # 正确的做法（已经在用了，不需要额外代码）
     *
     * `_BottomItem` 是 `FocusableActionDetector`，它已经把
     * `ActivateIntent` 映射到 `widget.onTap`（见其 build 里的注释）：
     * ```text
     * 遥控器确认键 → ActivateIntent → onTap → onSelect → _switchTo
     * ```
     * 这条路径**与原版逐字对应**（`@click` 由确认键触发）。
     * 所以只要方向键能把焦点移到 tab 上，用户按确认就能切页 ——
     * 不需要我再加一层"自动切"。
     */
    // ignore: unused_local_variable
    final _ = moved;

    /*
     * ★★ 无论有没有移动成功，都必须消费掉
     *
     * 这是原版三个坑之首：
     * > ① 必须 `preventDefault()`
     * >    否则方向键的默认滚动行为照旧执行，页面一边滚一边移焦点。
     *
     * Flutter 里对应的就是 `Scrollable` 会拿方向键去滚动。
     */
    return true;
  }

  /// 当前焦点是否在文本输入框里
  ///
  /// 实现：从主焦点向上找有没有 `EditableText`。
  /// 比"看 widget 类型名"可靠 —— 输入框可能被各种包装。
  bool _isTypingInTextField() {
    var node = FocusManager.instance.primaryFocus;
    var depth = 0;
    while (node != null && depth < 30) {
      final ctx = node.context;
      if (ctx != null) {
        var found = false;
        ctx.visitAncestorElements((el) {
          if (el.widget is EditableText) {
            found = true;
            return false;
          }
          return true;
        });
        if (found) return true;
      }
      node = node.parent;
      depth++;
    }
    return false;
  }

  @override
  void dispose() {
    // ★ 必须注销 —— 否则页面销毁后 handler 还在，
    //   引用已 dispose 的 State 会抛异常（setState after dispose）
    //
    // ⚠️ 必须与注册**配对**：注册改成了 `addEarlyKeyEventHandler`
    //    （见 `initState` 里的推导），注销也要用对应的
    //    `removeEarlyKeyEventHandler` —— 用 `removeHandler` 会**静默失败**
    //    （两个不同集合），页面销毁后 handler 仍活着。
    FocusManager.instance.removeEarlyKeyEventHandler(_onEarlyKey);
    // ★ task-39：注销遥控切频道信号（与 initState 的 addListener 配对）
    widget.liveChannelStep?.removeListener(_onLiveChannelStep);
    // ★ 释放可见性（task-41）：权威值 + 它的 bool 投影都要释放
    //   ⚠️ 顺序无所谓（两者独立），但**两个都必须释放** ——
    //      只释放一个会漏（本项目踩过"两处同构必须一起改"）。
    _activeTab.dispose();
    _liveVisible.dispose();
    // ★★★ task-14 ⑨（2026-10-04）：离场窗口的定时器必须一起取消 ——
    //   否则 shell 被销毁后它还挂着，flutter_test 会直接判红：
    //   A Timer is still pending even after the widget tree was disposed.
    //   （见 flutter_test/lib/src/binding.dart 的 _verifyInvariants）
    _leavingTimer?.cancel();
    _leaveC.dispose();
    super.dispose();
  }

  /// ★ 遥控"切频道"信号的处理（task-39）
  ///
  /// # ⚠️ 当成**脉冲**，不读值
  /// ```text
  /// 遥控面板按「下一个」→ delta 恒为 +1
  /// ⇒ `ValueNotifier` 认为"值没变" ⇒ **第二次不通知**
  /// ⇒ 所以监听者必须"收到就执行一次"，不能"按值执行"。
  /// ```
  /// ⚠️ `cycleChannel` 内部判空（没有频道时直接 return），
  ///    所以不在直播页时它是无害的 no-op。
  void _onLiveChannelStep() {
    if (!mounted) return;
    final delta = widget.liveChannelStep?.value ?? 0;
    if (delta == 0) return;
    debugPrint('[SHELL] 遥控切频道 delta=$delta');
    _liveKey.currentState?.cycleChannel(delta);
  }

  /// 桌面平台判定 —— 集中在唯一一处，避免各处写法不一致

  Future<void> _syncMaximized() async {
    if (!kIsDesktop) return;
    try {
      final m = await windowManager.isMaximized();
      if (mounted) setState(() => _maximized = m);
    } catch (_) {
      // 插件不可用（极端情况）—— 不该因此让应用崩
    }
  }

  void _switchTo(AppTab t) {
    if (t == _tab) return;
    final from = _tab;
    /*
     * ★★★ task-14 ⑨ 白屏修复（2026-10-04）：把离场页**留在合成里**一个窗口期
     *
     * # 为什么必须重排绘制顺序
     * ```text
     * Stack 里**最后**一项画在最上面。离场页停在"已就位"（不透明），
     * 所以它必须画在当前页**下面**，否则会盖住正在淡入的新页。
     * 而 AppTab.values 的顺序是固定的：
     *   home(0) → live(1)：离场页 home(0) 恰好在下面       ✓ 不用动
     *   live(1) → home(0)：离场页 live(1) 会盖住 home(0)    ✗ 必须换位
     * ```
     *
     * ⚠️ 只换**顺序**、不换**数量**（永远 5 个槽位）——
     *    且 Stack 的子节点带 ValueKey<AppTab> ⇒ Flutter 会**移动** Element
     *    而不是重建（保活不受影响，见 build 里那段注释）。
     */
    _stackOrder = AppTab.values.toList();
    if (from.index > t.index) {
      // 离场页序号更大 ⇒ 默认顺序会让它画在上面 ⇒ 换到当前页前面去
      _stackOrder
        ..remove(from)
        ..insert(_stackOrder.indexOf(t), from);
    }
    _leavingTimer?.cancel();
    _leavingTab = from;
    /*
     * ★ 2026-10-08（Owner 第 2 条）：离场页的淡出与离场窗口**同一条时间线**
     *   （都是 Motion.base）—— 窗口一结束它就被 offstage，
     *   所以这条动画只需覆盖窗口内那 260ms。
     */
    _leaveC.duration = MotionPrefs.duration(context, Motion.base);
    _leaveC.forward(from: 0);
    _leavingTimer = Timer(Motion.base, () {
      if (!mounted) return;
      /*
       * 窗口结束 ⇒ 离场页重新 offstage，绘制顺序也回到声明顺序。
       * ⚠️ 这里必须 setState：offstage 变了要重建。
       * ⚠️ mounted 守卫：shell 可能在窗口期内被销毁（dispose 已取消定时器，
       *    这行是双保险）。
       */
      setState(() {
        _leavingTab = null;
        _stackOrder = AppTab.values.toList();
      });
    });
    setState(() {
      _prevIndex = _tab.index;
      _tab = t;
      /*
       * ★ 惰性保活：把目标页标记为"已访问" ⇒ 它会进树并**留在树上**
       *   （见 `_visited` / `_contentFor` 的说明）。
       * ⚠️ 必须放在 `setState` 里 —— 否则首帧不会建这一页。
       */
      _visited.add(t);
      /*
       * ★★ 可见性**唯一真相**的写入点（task-41）
       *
       * 放这里而不是外面 —— `_activeTab` 是"当前可见的 tab"，
       * 与 `_tab` 必须**同一次**更新，否则中间会出现
       * "页面已切但可见性还没变"的一帧（隐藏页会晚一拍才停播放器）。
       */
      _activeTab.value = t;
    });
    // ★ 投影到既有 LivePage(visible:) 签名（单向，见 `_syncVisibility`）
    //
    // ⚠️⚠️ 这一行**必须存在** —— 我 2026-09-25 做红度验证时曾把它临时注释成
    //     `// MUT-M7 不投影`，然后**忘记还原**，导致：
    //     ```text
    //     ① `_liveVisible` 永远停在初值 false
    //     ② 直播页的方向键被门控挡住（真机实测「↓ / Enter 全废」）
    //     ③ 播放页的空格/Enter/F/J/L 也全废（同类门控）
    //     ★ 而**编译通过、测试全绿** —— 因为它是**功能层**的变异
    //     ```
    //     是靠另一个代理的**真机分层日志**才发现的（不是测试）。
    // ⚠️ 今后做红度变异：**注入与还原必须在同一个可重跑脚本里**，
    //    且还原后**验哈希**（见 `.probe/` 里 task-38 那套做法）。
    //
    // ★★ 2026-09-25 追记（铁律 108）：这段注释本身曾被
    //    另一个代理的变异脚本**整文件写回**覆盖掉（变异窗口长达 26 分钟）。
    //    ⇒ **共享文件上的实验性写入，必须有「窗口 + 冲突检测」两重保护**。
    _syncVisibility();
    /*
     * 导航日志（2026-09-22 加）
     *
     * # 为什么要有这行
     *
     * TV 适配是**行为**，截图看不出来。而这行日志让「遥控器按键
     * 有没有真的切页面」变成**可观测**的 —— 也是我在 Android TV
     * 上用 `adb shell input keyevent` 验证时的唯一证据来源。
     *
     * ⚠️ 用 `debugPrint` 而不是 `print`：debugPrint 会进 logcat，
     *    且 release 构建下依然输出（`print` 在某些平台被剥离）。
     */
    debugPrint('[NAV] ${from.name} -> ${t.name}');
    // 通知探针（诊断用；正式代码不传这个回调，等于无开销）
    widget.onTabChanged?.call(t);

    /*
     * ★ 切回「发现」时刷新（对应原版 HomeView 的 `onActivated`）
     *
     * 原版注释：
     * > 每次**返回**首页都刷新一次（KeepAlive 场景必须）
     * > 实测确认过问题：切走再切回首页，**完全没有重新请求**
     * > （`performance` 资源条目增量为 0），显示的还是进页面那一刻的数据。
     * >
     * > ⚠️ 但**不能**无条件全量重拉 —— 那样每次切回来要等 4 秒。
     * > 这里只重拉**分区列表**（很快，走缓存），区块内容按需补齐。
     *
     * 所以调 `loadAll()`（**非** force）—— 它会重拉分区骨架，
     * 但已有内容的区块会被跳过（见 `loadAll` 的第 ④ 步）。
     */
    if (t == AppTab.home) {
      // ★ `reason: 'tab-switch'` —— task-36 的"切回刷新"，**不是**重建
      //   （保活后这条**仍然要出现** ⇒ 用它断言"刷新没退化"）
      _homeKey.currentState?.loadAll(reason: 'tab-switch');
    }
    /*
     * ★ 直播页：重新拉频道列表**但保留选中的频道**
     *
     * 原版 `onActivated(() => loadAll(true))` —— 参数 true 就是"保留选中"。
     * 原版注释解释了为什么：
     * > 频道列表本身会变：启用/停用源、源新增频道、源失效被剔除。
     * > 实测确认过问题：切走再切回，完全没有重新请求。
     */
    if (t == AppTab.live) {
      _liveKey.currentState?.loadAll(keepSelection: true);
    }
    /*
     * ★★★ 可见性通知（task-39 的诉求，task-41 统一了真相）
     *
     * 必须在**每次切 tab** 都更新（不只是切到 live 时）——
     * 因为"离开 live"也要让播放器停下来。
     *
     * ⚠️ **这里不再直接写 `_liveVisible`** ——
     *    权威值 `_activeTab` 已在上面 `setState` 里更新，
     *    并在那里 `_syncVisibility()` 投影过来。
     *    （原来这两处各写一次 = 两套真相，必然漂移。）
     */
    /*
     * ★ 追更页：重新拉列表
     *
     * 原版注释：
     * > 数据很容易在别处被改：在播放页看完一集 → 进度变了；
     * > 在详情页点了「追更」/「收藏」→ 列表应立刻反映。
     * > 不刷新就会出现「明明刚追更，回来却看不到」。
     */
    if (t == AppTab.follow) {
      _followKey.currentState?.loadAll();
    }
    /*
     * ★ 设置页：重新拉（遥控状态/同步状态是外部会变的）
     *
     * 原版注释：
     * > 遥控可能被别的入口改过（比如底栏长按），
     * > 回来不刷新会显示过期状态。
     */
    /*
     * ★ task-3 ⑲「已缓存」页：切回来重新扫盘
     *
     * 与上面几支同一个理由，而且这一支**更需要**刷新：盘上的文件
     * 会被别处改 —— 用户在播放页删了缓存、在详情页新下了一集、
     * 或直接在资源管理器里拖走一个文件。不重扫就会显示过期数字。
     *
     * ⚠️ 只能调 `load()`（重扫）**不能**调 `_pageFor(AppTab.cached)` ——
     *    后者会 new 出一个新 CachePage ⇒ 保活失效（本文件的核心不变量）。
     */
    if (t == AppTab.cached) {
      _cachedKey.currentState?.load();
    }
    if (t == AppTab.settings) {
      _settingsKey.currentState?.loadAll();
    }
  }

  /// ★ 按 tab 序号算切换方向（对齐原版 L41–45）
  ///
  /// ```text
  /// 往后切（序号变大）→ 新页面从右进  → 偏移 +24px
  /// 往前切（序号变小）→ 新页面从左进  → 偏移 -24px
  /// ```
  double get _transitionDir => _tab.index >= _prevIndex ? 1.0 : -1.0;

  @override
  Widget build(BuildContext context) {
    final colors = AppPalette.of(context);
    /*
     * ★ 自绘标题栏只在桌面显示（2026-09-22）
     *
     * Android 上系统自带状态栏/导航栏，再画一条 40px 的自绘标题栏
     * 会变成「双层标题」——既难看又占地方。
     *
     * 所以：
     * ```text
     * 桌面 → 自绘标题栏（因为系统那条不好看，Owner 明确要求换掉）
     * 移动/TV → 不画（系统那条就是对的，而且 TV 上根本没有标题栏概念）
     * ```
     */

    /*
     * ★★ TV 方向键处理：包住**整个 shell**（2026-09-22，第三次修正）
     *
     * # 前两次为什么都失败
     *
     * **第一次**：用 `FocusTraversalGroup(ReadingOrderTraversalPolicy())`，
     * 以为方向键会自动移焦点。实测按 → 十次 tab 不动 ——
     * 因为该 policy 只响应 Tab/Shift+Tab。
     *
     * **第二次**：改成把 `Focus(onKeyEvent:)` 放在**底栏那一层**。
     * 加了打点确认，结果 **`onKeyEvent` 被调用 0 次**。
     *
     * # 第二次失败的原因（这是关键认知）
     *
     * Flutter 的按键派发规则是：
     * ```text
     * 从【主焦点节点】出发，沿**祖先链**向上冒泡，
     * 找到第一个返回 handled 的 handler 就停。
     * ```
     * 也就是说 —— **只有主焦点的祖先才能收到按键**。
     *
     * 我的底栏 Focus 与主焦点（在内容区）是**兄弟关系**，
     * 不在同一条祖先链上 → 事件永远冒泡不到它。
     *
     * # 正确位置：包住整个 shell
     *
     * 这样无论焦点当前在内容区的哪个控件上，
     * 事件向上冒泡时**必然经过这一层**。
     *
     * # 另一个必须注意的点
     *
     * `canRequestFocus: false` 不能省 —— 这一层是**拦截器**不是**焦点项**。
     * 若它自己也能拿焦点，会把焦点从内容区抢走，
     * 导致用户点进某个控件后按方向键变成"切页面"。
     */
    /*
     * ⚠️ 这里**不**用 `Focus(onKeyEvent:)` 包住 FScaffold（实测无效）
     *
     * # 为什么（2026-09-22 排查结论）
     *
     * Flutter 只把按键沿【主焦点的祖先链】向上冒泡。我实测打了三处点：
     * ```text
     * ① FocusTraversalGroup(ReadingOrderTraversalPolicy())
     *    → 方向键不动（该 policy 只响应 Tab/Shift+Tab）
     *
     * ② 把 Focus(onKeyEvent:) 放在底栏那一层
     *    → handler 被调用 **0 次**（底栏与主焦点是兄弟，不在祖先链上）
     *
     * ③ 把它上移到包住整个 FScaffold
     *    → handler 仍然 **0 次**
     * ```
     * 第 ③ 次失败的原因：`FScaffold` 内部有 `FSheets`／overlay 结构，
     * 焦点被 re-parent 到我的 Focus **之外** —— 祖先链里根本没有它。
     *
     * # 换成全局 handler（见 initState）
     *
     * `HardwareKeyboard.instance.addHandler` 不依赖焦点树，
     * 实测能收到全部按键（44/44）。用它 + 输入框守卫，
     * 就得到「TV 上方向键一定能切页」这个确定行为。
     */
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ Material 祖先 —— 遥控器确认键能不能用的**决定性前提**
     * ══════════════════════════════════════════════════════════════════
     *
     * # 真 bug（2026-09-23 实测抓到，症状极其隐蔽）
     *
     * TV 上按遥控器 OK：方向键能把焦点移到海报卡上（焦点环都画出来了），
     * 但**按 OK 什么都不会发生** —— 打不开详情页。
     *
     * 而 `adb shell input tap`（触摸/鼠标路径）**能正常打开**。
     * 也就是「能点不能按」，非常反直觉。
     *
     * # 根因：`InkWell` 的键盘激活路径里 `Material.of` 抛异常
     *
     * 手写实验把 `Actions.invoke(ActivateIntent)` 的结果打出来，拿到：
     * ```text
     * [KEY] ★ 手动 invoke 抛异常: Null check operator used on a null value
     * [KEY] #0  Material.of (package:material_ui/src/material.dart:418)
     * ```
     * 对照 `ink_well.dart` 的两条路径：
     * ```dart
     * // 键盘路径（activateOnIntent, L877）—— 先起水波纹，再调 onTap
     * void activateOnIntent(Intent? intent) {
     *   _startNewSplash(context: context);   // ← 这里 Material.of 抛异常
     *   _currentSplash?.confirm();
     *   if (widget.onTap != null) widget.onTap?.call();   // ← 永远到不了
     * }
     *
     * // 触摸路径（handleTap, L1210）—— 水波纹在 tapDown 时已经起过
     * void handleTap() {
     *   _currentSplash?.confirm();
     *   if (widget.onTap != null) widget.onTap?.call();   // ← 直接调用，不碰 Material
     * }
     * ```
     * **两条路径的差别就在这一处**：键盘激活要先 `_startNewSplash`
     * （它内部调 `Material.of` 拿墨迹控制器），而触摸路径此时
     * 水波纹早已创建完毕，`handleTap` 不再碰 `Material`。
     *
     * 所以没有 `Material` 祖先时：
     * ```text
     * 触摸/鼠标 → onTap 正常 ✓（我一开始就是靠这个以为没问题）
     * 键盘/遥控器 → 抛异常 → onTap 从未执行 ✗（且异常被 Flutter 吞掉，
     *               logcat 里连 E 级日志都没有）
     * ```
     *
     * # 为什么之前所有测试都是绿的
     *
     * ```text
     * · 单测用 `Scaffold`（Material 库的），它**自带 Material 祖先**
     *   → 所以 `Enter=1 Select=1 Space=1` 全过 ✓
     * · 真机用 `FScaffold`（forui 的），它**不提供 Material**
     *   → 键盘激活必炸 ✗
     * ```
     * 这就是「单测绿 ≠ 真机能用」的又一个实例，而且这次差别
     * **完全在测试脚手架用错了 widget**。
     *
     * # 修法
     *
     * 在 `FScaffold` 的 child 外面套一层 `Material`。
     * 用 `MaterialType.transparency`（而不是默认的 canvas）：
     * ```text
     * canvas       → 会画一层 canvasColor 背景，盖住我们的深色主题
     * transparency → backgroundColor 为 null，不画背景、不投影、
     *                不吸 hit test，只提供墨迹控制器  ← 正是我们要的
     * ```
     * ⚠️ 这一层**必须包在 `FScaffold` 的 child 最外层**，
     *    而不是逐个页面去包 —— 全 app 有 18 处 `InkWell`
     *    （海报卡/源条/底栏/详情按钮/追更/直播/设置…），
     *    漏掉任何一处就是"那个按钮遥控器按不动"，
     *    而且**没有任何报错**（异常被吞），极难排查。
     */
    /*
     * ★★★ 用 `ShellScope` 包住整个 shell（task-41）
     *
     * # 为什么包在**最外层**
     *
     * `ShellScope` 是 `InheritedNotifier` —— 子页面（含 5 个 tab 页，
     * 以及它们 push 出去的详情/播放页？后者在 Navigator 之上，
     * 拿不到这里 —— 见下）用 `ShellScope.isActive(context, tab)` 查询。
     * 包在最外层保证：
     * ```text
     * ① 5 个 tab 页**全部**在它的子树里（无论当前可见与否）
     *    ⇒ 保活页也能查到"我现在可不可见"
     * ② 只重建**真正 dependOn** 它的 widget（比 setState 整个 shell 便宜）
     * ```
     * ⚠️ 用 `Navigator.push` 出去的页面**不在**这棵子树里
     *    （它们在 MaterialApp 的 Navigator 下，是 ShellPage 的**兄弟**）
     *    ⇒ 那些页面拿不到 ShellScope。这是**刻意的**：
     *      它们是"全屏页"，没有"tab 可见性"的概念。
     */
    return ShellScope(
        notifier: _activeTab,
        child: AppScaffold(
        /*
         * ══════════════════════════════════════════════════════════════════
         * ★★★ 关掉 forui 的 childPadding（2026-10-03 双端像素实测反解）
         * ══════════════════════════════════════════════════════════════════
         *
         * # 现象：内容区左右各多出 **12 逻辑 px**
         *
         * `FScaffold` 默认 `childPad: true` ⇒ 它会给 child 套一层
         * `Padding(style.childPadding)`；而 `FScaffoldStyle.inherit` 里
         * `childPadding = style.pagePadding.copyWith(top: 0, bottom: 0)`，
         * `pagePadding = .symmetric(vertical: 8, horizontal: 12)`
         * （forui `widgets/scaffold.dart:191-202`、`theme/style.dart:37`）
         * ⇒ **左右各 12**（上下为 0，所以只有横向漂移）。
         *
         * 上面 `scaffoldStyle` 那段长注释已写明：`FScaffoldStyleDelta.delta`
         * 的 `call()` 逐字段 `?? original.X` ⇒ 我们只覆盖了
         * `backgroundColor` ⇒ `childPadding` 一直是 **forui 原值**。
         * 这 12/side **从第一天就在**，宽屏看不出来，窄屏就显形了。
         *
         * # 为什么必须修（不是「差几像素无所谓」）
         *
         * 栅格算法的 `minCell*` 是**不变量**（`tokens.dart:274/277/284`），
         * 而多出来的 24/side 按列数摊到每张卡上 ⇒ 单元宽被压到下限以下：
         * ```text
         *   手机 411.43（窄档，3 列）  实测 110.48 < minCellNarrow 112  ✗
         *   TV   960   （TV 档，4 列）  实测 195    < minCellTv     200  ✗
         * ```
         * （24 ÷ 3 = 8 ⇒ 118.48 − 8 = 110.48；24 ÷ 4 = 6 ⇒ 201 − 6 = 195
         *   —— 两个数都与实测**逐位吻合**，说明根因就是这个 12/side。）
         *
         * # 修法：一行 `childPad: false`，**不动 `Layout`**
         *
         * 也考虑过在 `Layout.paddingFor` 里各减 12，但那样会把
         * 「框架的锅」写进我们自己的设计令牌里，而且 `t493_layout_probe`
         * 直接调 `Layout.*` 做 A/B ⇒ 改 `Layout` 会让那份**已验收的**
         * 探针读数整体失效。`childPad: false` 只作用于**真实外壳**，
         * `Layout` 的语义与数值一个都不变。
         *
         * ⚠️ 连带影响（必须同步，已改）：
         *   底栏的 `_kTabRowHorizontalLoss` 里那 12/side 不再存在 ⇒
         *   从 `Sp.x3*2 + Sp.x6*2`(72) 改成 `Sp.x6*2`(48)。
         *   改漏会让底栏窄屏下**算宽一档**（药丸也会跟着错位，
         *   因为它与 `SizedBox(width:)` 同源）。
         *
         * ⚠️ 上下为 0（`copyWith(top: 0, bottom: 0)`）⇒ 纵向零风险。
         *
         * ⚠️ 只改**真实外壳**。`:281` 等 6 个 `lib\t*_probe.dart` /
         *   `merge_view_probe.dart` 里的 `FScaffold` 是独立诊断入口
         *   （各自 `-t` 启动），不承载 Owner 的界面契约，本轮不动。
         */
        /*
         * ══════════════════════════════════════════════════════════════════
         * ★★★ 页面底色必须与吸顶条同源（2026-09-25 用户报「搜索这里有一块阴影」）
         * ══════════════════════════════════════════════════════════════════
         *
         * 用户原话（附裁剪截图）：
         * > 这里有一块阴影,搜索这里
         *
         * # 现象（PrintWindow 逐像素实测，1280x800）
         *
         * 搜索框背后一条 `y=118..187`（70px）、`x=12..1267` 的**灰带**，
         * 颜色 `rgb(238,240,246)` = `#EEF0F6`；而它以外整个内容区是
         * **纯白 `rgb(255,255,255)`**。
         *
         * 几何自证：`_searchBarHeight(50) + AppMetrics.homeTopPadding(20) = 70`
         * —— 恰好等于灰带高度 ⇒ 那条带子就是 `search_page.dart` 的
         * `SliverPersistentHeader`（吸顶搜索条）。
         *
         * # 根因：**两个不同的「底色」真相来源**
         *
         * ```text
         * 吸顶条   → Theme.of(context).colorScheme.surface
         *            = app_theme.dart:362 显式设的 LightTokens.bgBase = #EEF0F6
         * 页面底色 → 本行 FScaffold 的 forui 默认
         *            = FScaffoldStyle.inherit 里的 colors.background
         *            = forui colors.dart:144 neutralLight.background = #FFFFFF
         * ```
         *
         * 两者在**深色**下恰好相等（都是 `#0A0A0A`），所以这个 bug 一直藏着
         * —— 此前所有交付截图都是深色（隔离数据目录 seed 了 `"dsh.theme":"dark"`）。
         * 用户真实 `ui-prefs.json` **没有** `dsh.theme` 键 ⇒ 回落
         * `AppThemeMode.system` ⇒ 本机系统浅色 ⇒ 缺陷才显形。
         *
         * # 为什么把**页面底色**改成 `colors.surface`，而不是反过来改吸顶条
         *
         * ① 5 个自带 `Scaffold` 的页面**已经**把 `colors.surface` 当页面底色
         *    （`browse_page.dart:172` / `detail_page.dart:1475` /
         *    `media_page.dart:919` / `settings_sub_page.dart:130`）——
         *    只有 4 个 tab 页（home/search/follow/live，它们都没有自己的
         *    `Scaffold`）在裸用 forui 白 ⇒ **它们才是异类**。
         * ② `settings_sub_page.dart` 是**配对成功的样板**：页面底色（`:130`）
         *    与吸顶返回条（`:254`）是**同一个表达式** ⇒ 该页没有灰带。
         * ③ 3 处吸顶条（`search_page.dart:464` / `settings_page.dart:3139` /
         *    `settings_sub_page.dart:254`）全都用 `colors.surface`；把这里也设成
         *    同一个表达式 ⇒ 无论明暗都保证「吸顶条 == 页面底色」这个
         *    **不变量**，比逐个页面去改更不容易再漂移。
         * ④ `AppTheme.floorColor()` 的浅色分支本来就是 `bgBase`(#EEF0F6)，而
         *    窗口地板 vs 内容区白**当前就不一致** —— 改完反而统一了。
         *
         * # 为什么写 `Theme.of(context).colorScheme.surface`，而不是
         *   `AppTheme.floorColor(brightness)`
         *
         * `brightness` 是 `MaterialApp.builder` 那个方法的局部变量，与本行
         * **不在同一个方法**里（本行在 `_ShellPageState.build`）。要用得重算
         * `AppTheme.resolve(systemBrightness: ...)`。而 `colorScheme.surface`
         * 与吸顶条**逐字同源** ⇒ 不可能漂移。
         *
         * ⚠️ 这里 `Theme.of` 拿到的是 `MaterialApp` 的主题（本 build 在
         *    `MaterialApp` **之下**），不是 `FTheme` —— 与 `:1225` 那条
         *    「builder 里不能用 `Theme.of`」的警告**不冲突**（那是另一个 context）。
         *
         * # 深色下零影响（已核实）
         *
         * forui `theme_data.dart:1029` 里 `toApproximateMaterialTheme()` 写的
         * 是 `surface: colors.background`，而 `theme_bridge.dart` 的深色覆盖
         * 列表**不含** `surface` ⇒ 深色下本行取到的就是 `#0A0A0A`，与原来的
         * forui 默认**完全相同** ⇒ 深色渲染逐像素不变。
         *
         * ⚠️ 只覆盖 `backgroundColor`：`FScaffoldStyle.delta` 的 `call()` 逐字段
         *    `?? original.X`（`scaffold.design.dart:152-159`）⇒ `childPadding` /
         *    `footerDecoration` / `headerDecoration` 全部保持 forui 原值。
         */
        backgroundColor: Theme.of(context).colorScheme.surface,
        /*
         * ⚠️ 这里**不再**挂标题栏（2026-09-24 改）
         *
         * 标题栏已上移到 `MaterialApp.builder`（见那里的长注释）——
         * 因为挂在这里时，push 上来的详情页/播放页在 ShellPage 外面，
         * **一进详情页就拖不动窗口**（用户实际反馈的问题）。
         */
        child: Material(
        type: MaterialType.transparency,
        /*
         * ══════════════════════════════════════════════════════════════════
         * ★★★ 必须是 Stack 而不是 Column（2026-09-24 用户指出玻璃不像玻璃）
         * ══════════════════════════════════════════════════════════════════
         *
         * 用户原话：
         * > 上面这个操作条,还有下面的这个 你看跟液态玻璃有半毛钱关系吗?
         *
         * # 根因：`Column` 让底栏**没有东西可以折射**
         *
         * 我之前写的是：
         * ```text
         * Column
         *  ├ Expanded(内容)     ← 内容占满剩余
         *  └ _BottomBar         ← 在内容**下面**，不是**上面**
         * ```
         * 而 `BackdropFilter` 模糊的是**它背后的像素**。
         * 底栏在 Column 里排在内容之后 —— 它背后是**空白**（不是海报）。
         * 模糊空白 = 空白 → **看起来就是一块实心色板**。
         *
         * 原版为什么是玻璃：它是 CSS `position: fixed` ——
         * 底栏**浮在内容之上**，背后就是滚动的海报。
         *
         * # 原版注释早就写明了这件事
         *
         * 原版 `liquid-glass.css` 里那一段的标题是：
         * 「背景氛围层（**玻璃要有东西可折射**）」，
         * 后面还有一句更直白的：
         * > 这样玻璃依然"有东西可折射"（**否则纯黑底上玻璃就是一块灰板**）
         *
         * 我漏了**两件事**，缺任何一个玻璃都不成立：
         * ```text
         * ① 窗口没有底色            → 补：MaterialApp.builder 里的 ColoredBox
         * ② 底栏不是浮在内容之上  → 补：这个 Stack
         * ```
         *
         * # 现在的层级
         *
         * ```text
         * Stack
         *  ├ 内容区（滚动海报）
         *  └ _BottomBar（悬浮在内容**之上**）← 于是背后有海报可折射
         * ```
         * ⚠️ 底色（`#EEF0F6` 那一层）现在统一在 `MaterialApp.builder`
         *    的 `ColoredBox`（见那里的说明）—— 不再分散到这里。
         *
         * ⚠️ 底栏浮起来之后**不再占据布局空间** ——
         *    内容会被它盖住底部一小块。这是**正确**的：
         *    原版也是 `position: fixed`，页面靠 `padding-bottom` 留白。
         *    各页面自己留 `bottom` 内边距（见 `_pageFor` 里的 padding）。
         */
        child: Stack(
        children: [
          /*
           * ── 内容区 ──
           *
           * ⚠️ 底色（`#EEF0F6`）在 `MaterialApp.builder` 的 `ColoredBox`，
           *    不在这里 —— 它要同时给**标题栏**和**所有路由**做底。
           *    这里只管内容区本身（切 tab 动画等）。
           */
          Positioned.fill(
            child: ClipRect(
              /*
               * ══════════════════════════════════════════════════════════
               * ★★★ 2026-10-01：这一处**单独改没用** —— 实测读数在下面，
               *     别把它当成 arm64 内容区空白的修复
               * ══════════════════════════════════════════════════════════
               *
               * # ⚠️⚠️ 先读这条否证（否则你会以为这行是修复）
               *
               * 我把这里从默认 `Clip.hardEdge` 改成 `Clip.antiAlias` 后
               * **重新构建了 arm64 交付包并装到车上实测**，结果是
               * **逐字节相同**：
               *
               * ```text
               * 改前 t20/t30.png  sha16 = E978F71D38702923  34825 B  109 色
               * 改后 t20/t30.png  sha16 = E978F71D38702923  34825 B  109 色
               *                  ↑ 完全一样 ⇒ 内容区**仍然一个像素都没画**
               * ```
               * ★ 并且确认改动**确实进了二进制**：
               *   `.dart_tool\flutter_build\e601be8d…\.filecache` 记录的
               *   `lib\shell.dart` md5 = `4959ceeadd9e788e80885e02e9874be4`
               *   = 改后文件的 md5；`app.dill` 10:29:43 晚于源码 10:26:38；
               *   新 APK sha256 = `87D3ECD6…`（与改前的 `D18216E0…` 不同）。
               * ⇒ **不是"没编进去"，是这一处不是凶手。**
               *
               * # 那为什么留着 `antiAlias`
               *
               * 最小对探针（`lib\t429_arm64_probe.dart`）**证明过硬编码
               * `hardEdge` 本身在 arm64 上会杀掉子树**（见下），所以把链上
               * 的 `hardEdge` 逐个去掉是**正确方向**；只是它**不充分** ——
               * 内容区里还有别的 `hardEdge` 裁剪（首要嫌疑是
               * `CustomScrollView` 的 `Viewport`，`viewport.dart:79/398/434`
               * 默认 `Clip.hardEdge`）。
               * ⇒ 保留它，但**别把这一行当修复**；真正的归因见
               *   `.probe\t435_*.txt`。
               *
               * # 已证的部分：`Clip.hardEdge` 在 arm64 上会杀掉子树
               *
               * 症状（Owner 的交付包实测）：arm64 交付包在 Android TV 车上
               * 底栏（发现/直播/追更/搜索/设置）**正常**，内容区**全空** ——
               * 只剩 `MaterialApp.builder` 那层 `ColoredBox(floorColor)` 的
               * `#0A0A0A`；x86_64 同车同会话内容齐全。两臂 **Dart 日志逐行
               * 相同**（各 26 行，唯一差异是 getHome 耗时 8ms vs 311ms）
               * ⇒ **不是 Dart 层，是合成/绘制层。**
               *
               * 探针把「路径 × clipBehavior」四格全测了（只测两格会同时动
               * 两个自变量）：
               *
               * ```text
               *                    canvas 路径            layer 路径
               *   hardEdge     段2  #7F7F7F 死          段5  #7F7F7F 死
               *   antiAlias    段4  #E8C81E 活          段9  #9B6D4E 活
               *   Clip.none    段3  #C81EC8 活          ——（none 提前 return）
               *   无裁剪       段1  #E8001E 活
               * ```
               * ⇒ ★ **决定生死的是 `clipBehavior == Clip.hardEdge`，与走
               *   canvas 还是 layer 路径无关**；x86_64 四格**全活** ⇒ arm64 特有。
               * ★ 两台仪器同结论：进程内 `toImage()` 与屏幕 `screencap` 的
               *   px00 逐段一致（`.probe\t433_stage_measure.txt`，fail=0）
               *   ⇒ 内容确实没画上去，不是读回路径坏了。
               *
               * ⚠️ **机制未证实**：`hardEdge` 与 `antiAlias` 在引擎里的差别
               *    只是 `canvas.clipRect(rect, doAntiAlias)` 那一个布尔
               *    （`rendering\object.dart:592`）。合理猜测是 hardEdge 走
               *    scissor test（`glScissor`）那条路而车的 GLES 把它弄坏了 ——
               *    ★ 我**没有**在引擎/driver 层插桩验证过。
               *
               * # 为什么底栏没事
               *
               * 底栏是那个 `Positioned(left: 0, right: 0, bottom: 0, …)`，
               * **同一个 `Stack` 里本 `ClipRect` 之外**的兄弟；且它内部的
               * `GlassContainer` 用的是 `ClipRRect`（**默认 `Clip.antiAlias`**，
               * `basic.dart:1048`）⇒ 它那一条链上没有嵌套的 `hardEdge`。
               *
               * ⚠️ 本文件另一处 `Expanded(child: ClipRect(child: widget.child))`
               *    （桌面标题栏）**故意保持**默认 `hardEdge` —— 它在
               *    `if (!kIsDesktop) return widget.child;` 之后，
               *    **Android 永远走不到**。别顺手改它。
               *
               * ★★ **本注释刻意不写行号**（`lib\shell.dart` 每次改动都会让行号
               *    漂 —— 我自己这一轮就把底栏从 `:3332` 推到了 `:3404`、
               *    桌面那处从 `:4049` 推到 `:4128`）。
               *    引用**内容**（"那个 `Positioned(bottom: 0)`"）比引用**位置**耐用。
               */
              clipBehavior: Clip.antiAlias,
              /*
               * ══════════════════════════════════════════════════════════
               * ★★★ KeepAlive：5 个主 tab **保活**（task-41）
               * ══════════════════════════════════════════════════════════
               *
               * # 这里原来是什么（以及为什么**必须**换掉）
               *
               * ```dart
               * AnimatedSwitcher(
               *   child: KeyedSubtree(
               *     key: ValueKey(_tab),      // ← 换 key ⇒ 旧子树整个销毁
               *     child: _pageFor(_tab),    // ← 只渲染当前 tab
               *   ),
               * )
               * ```
               *
               * ⇒ 切走首页 = 整棵子树销毁；切回来 = **全新 State**：
               * ```text
               * home_page initState → loadAll(force: true) 又跑一次
               * PosterCard 是**新对象** ⇒ _loaded=false ⇒ 先画占位再淡入
               * 滚动位置归零
               * ```
               * ⇒ 用户原话：
               * > 首页不是占位颜色太深，**不是加的有缓存吗？怎么切换还会这个样子**
               * ★ 答案：**缓存救得了字节，救不了 State** ——
               *   封面 URL 稳定（`streamproxy.rs` 复用同一 token）⇒ ImageCache
               *   里**确实有那张图**，但页面是新的，占位态与滚动位置全从零开始。
               *
               * # ★★★ 原版**明确警告过**这个写法（不是我推断的）
               *
               * `src/App.vue` L349-356 原文：
               * ```javascript
               * /**
               *  * ⚠️ **不能用「给组件换 key 触发重挂载」的办法** ——
               *  *    那会与 keep-alive 直接冲突（换 key = 新组件实例 = 保活白做，
               *  *    滚动位置与内部状态全丢）。正确做法是：
               *  *      - 数据层用缓存 TTL（见 `api/cache.ts`）保证新鲜度
               *  *      - 「我的」区块自己监听路由变化去重取（见 MyShelf）
               *  */
               * ```
               * 原版还有 `keepAlivePages`（5 页）+ `MAX_KEEP = 5`（LRU 上限）
               * + 滚动位置记忆（L364）+ 「方向滑动」过渡（L38-41）。
               *
               * # 为什么用 `Stack + Offstage` 而不是 `IndexedStack`
               *
               * ```text
               * IndexedStack   保活 ✓  但**没有过渡动画** ✗（原版有方向滑动）
               * Stack+Offstage 保活 ✓  可自己套动画 ✓
               * ```
               * 而且本项目注释（L1305/L1324）**一直按 IndexedStack 保活写的**：
               * > 「Flutter 的 `IndexedStack` 没有等价的钩子 —— 子页面被保活，
               * >   但切回来时不会有任何通知。所以由 shell 主动调。」
               * ⇒ ★ 那套"切回本页主动调 loadAll"的设计（见 `_switchTo`）
               *   **本来就是为保活写的**，只是内容区不知何时退回了 AnimatedSwitcher
               *   ⇒ 本次改动是**修回归**，不是加新功能 —— 既有代码因此才真正生效。
               *
               * # 不变量（改这里时必须全部满足，否则保活失效）
               *
               * ```text
               * ① 5 个子页 widget **只建一次**（`_pages`，见 initState）
               *    —— 在 build 里 `_pageFor(_tab)` 现造 ⇒ widget 不等
               *       ⇒ 即使 Offstage 也会重建子树
               * ② `TickerMode(enabled: false)` 停掉隐藏页的动画
               *    —— 否则 5 页同时跑 ticker，白烧 CPU
               * ③ 5 个 GlobalKey 各自只出现一次（一页一个）⇒ 不冲突
               * ④ 过渡动画**不许丢**（原版有；用户可能已在用）
               * ```
               *
               * # LRU 上限：为什么这里**不需要**（原版 MAX_KEEP=5）
               *
               * 原版要上限是因为路由可能很多；我们**恰好只有 5 个固定 tab**
               * （`AppTab` 枚举，无参数化页面 —— detail/browse/player 走
               * `Navigator.push`，**不在**这个 Stack 里）。
               * ⇒ 常驻数恒等于 5，不可能增长 ⇒ 不需要淘汰逻辑。
               * ⚠️ 后人若往 `AppTab` 加页面，请重新评估这条。
               *
               * # 内存代价（实测见报告）
               *
               * ```text
               * 保活 = 5 份 State 常驻 + 5 份 ImageCache 引用
               * 换来 = 不重建 / 滚动位置保留 / 不重新走占位
               * ```
               */
              /*
               * ══════════════════════════════════════════════════════════
               * ★★★ F6：内容区的**顶部安全区**（手机状态栏 / 挖孔）
               * ══════════════════════════════════════════════════════════
               *
               * # 缺陷（设备实测，不是推测）
               *
               * 手机上 Flutter 的 view 是 `[0,0][1080,2274]`（设备 px）：
               * **底部**的 126 px 被系统让给了导航栏，**顶部**那 128 px
               * 却没有任何人让 —— 状态栏直接压在内容上。
               *
               * ```text
               * emulator-5556（1080×2400 @ 420dpi ⇒ DPR 2.625）
               * InsetsSource type=statusBars frame=[0,0][1080,128]
               *   ⇒ 128 / 2.625 = 48.76 逻辑 px
               * mDisplayCutout insets=Rect(0,128-0,0)（挖孔在 x 492..610）
               * 「所有直播」按钮 a11y 边界 [713,84][986,163]
               *   ⇒ 从屏幕 y=84 起画（= Sp.x8(32) × 2.625），前 44 px
               *     落在状态栏带里 ⇒ 点不动，且 44/79 = 56% 的按钮失效
               * ```
               *
               * # 为什么修在这里
               *
               * 全项目 `SafeArea|padding.top|viewPadding|paddingOf` 共 9 处
               * 命中，**shell 一处都没有** ⇒ 这是 shell 级缺陷，不是某一页
               * 的缺陷（发现页 / 直播页 / 追更页都没有 Scaffold 或 SafeArea）。
               *
               * 放在 `ClipRect` **里面**：裁剪仍由 ClipRect 兜底（转场缩放
               * 溢出照旧被裁掉，见上面那段"白条覆盖操作条"的修复），
               * 安全区只负责把内容推下来。
               *
               * # 为什么只吃顶部
               *
               * 底部各页自己留了 `Sp.bottomBarInset`（`ui/tokens.dart:73`），
               * 这里再吃一次会双倍留白 ⇒ `bottom: false`。
               * 左右也不吃：横屏 / 分屏下的左右内边距由系统窗口决定，
               * 不该由 shell 猜 ⇒ `left/right: false`。
               *
               * ⚠️ 2026-10-05：`bottom: false` 只管**内容区**。
               *    **底栏自己**要躲系统导航栏 —— 它吃的是下面那段
               *    `Positioned(bottom: MediaQuery.paddingOf(context).bottom)`
               *    （本 `SafeArea` 是它的**兄弟**，管不到它）。
               *    两者不冲突、也不可互相替代：
               *      `Sp.bottomBarInset` ⇒ 「内容别被底栏盖住」
               *      `Positioned.bottom` ⇒ 「底栏别被系统栏盖住」
               *
               * # 语义（不会双倍）
               *
               * `SafeArea` 会把后代的 `MediaQuery.padding.top` **清零**
               * （`safe_area.dart:128-135` 的 `removePadding`）⇒ 各页自己
               * 再包一层 `SafeArea` 也是 no-op，不会叠加。
               * `padding.top = max(0, viewPadding.top - viewInsets.top)`
               * （`media_query.dart:155-163`）⇒ 键盘弹出时自动让位。
               *
               * # 负对照（这一层在别的形态上是 no-op）
               *
               * ```text
               * TV（emulator-5554）：InsetsState 里**没有** statusBars 源
               *   也没有 navigationBars 源，mAppBounds == mBounds == 整屏
               *   ⇒ padding.top == 0 ⇒ 严格零影响
               * 桌面：ViewPadding 默认全零（platform_dispatcher.dart:2000）
               *   ⇒ padding.top == 0 ⇒ 严格零影响
               * ```
               *
               * ⚠️ 包的是**整个三元**（错误页那一支也要安全区）——
               *    核心启动失败时错误页同样会顶到状态栏下面。
               */
              child: SafeArea(
                top: true,
                bottom: false,
                left: false,
                right: false,
                child: widget.coreError != null
                  /*
                   * ★★ 核心启动失败 → 内容区**整体**换成错误页（任务 AM）
                   *
                   * ⚠️ 这一支**不走保活** —— 错误页是"接管式"的一次性视图，
                   *    它与 tab 无关（切 tab 也不该变），保活它没有意义，
                   *    而且会让 5 个正常页在错误状态下也常驻（白占内存）。
                   * ⇒ 所以这里**保留**原来的"单页 + 换 key"写法，
                   *   但因为它与 `_tab` 无关，用**常量 key** 更贴切
                   *   （切 tab 不重播动画 —— 与原实现意图一致）。
                   */
                  ? KeyedSubtree(
                      key: const ValueKey('core-error'),
                      child: _CoreErrorView(
                        message: widget.coreError!,
                        dataDir: widget.coreDataDir,
                      ),
                    )
                  /*
                   * ══════════════════════════════════════════════════════
                   * ★★★ 保活内容区（task-41）
                   * ══════════════════════════════════════════════════════
                   *
                   * ★ 过渡动画怎么保住的（原版有"方向滑动"，不能丢）
                   *
                   * 保活后**不能**用 `AnimatedSwitcher`（它就是靠"换 widget
                   * ⇒ 旧的移出 ⇒ 播退场动画"，而保活恰恰要求旧的**不移出**）。
                   * 所以改成：**给当前可见的那一页**套一层进入动画 ——
                   * ```text
                   * AnimatedSlide + AnimatedOpacity
                   *   · _tab 变化时，被切到的那页从 ±0.02 滑入 + 淡入
                   *   · 用现有 `_transitionDir`（按 tab 序号算方向，见 L2192）
                   *   · 位移 0.02 ≈ 1280*0.02 = 25.6px，与原实现的 24px 对齐
                   * ```
                   * ⚠️ 动画只作用在**进入的那一页**；隐藏页只是 Offstage，
                   *    不参与动画（省 CPU，也避免"退出页还在动"的怪异感）。
                   */
                  : Stack(
                      children: [
                        for (final t in _stackOrder)
                          Offstage(
                            /*
                             * ★★★ task-14 ⑨ 白屏修复（2026-10-04）：必须带 key
                             *
                             * ```text
                             * _stackOrder 会**换顺序**（离场页要画到当前页下面）。
                             * 而 Stack 的子节点是**按位置**匹配的：
                             *   无 key ⇒ 换顺序 = 位置上的 widget 类型对不上
                             *          ⇒ 旧页 Element 被**销毁重建** ⇒ 保活失效！
                             *   有 key ⇒ updateChildren 按 key 匹配 ⇒ **移动** Element
                             *          ⇒ State / 滚动位置 / 解码器全都留着 ✓
                             * ```
                             * ⚠️ key 只能依赖 t —— 绝不能依赖 _leavingTab
                             *    （否则窗口开关会换 key ⇒ 每次切页都重建）。
                             *    见 test/task37_keepalive_placeholder_test.dart 的判据。
                             */
                            key: ValueKey<AppTab>(t),
                            /*
                             * ★ 保活的**核心**：offstage 而不是"移除"
                             *   —— 子页仍在树上 ⇒ State / 滚动位置 / 解码器都留着
                             */
                            /*
                             * ★★★ task-14 ⑨ 白屏修复（2026-10-04）
                             *
                             * 离场页（_leavingTab）在窗口期内**不 offstage** ——
                             * 它要继续参与合成，垫在新页底下（新页此刻 opacity = 0）。
                             * 窗口一过（Timer(Motion.base) 把 _leavingTab 清回 null）
                             * 它自动回到 offstage ⇒ 可见性语义与改前**完全一致**。
                             *
                             * ⚠️ _leavingTab 只在那一个窗口内有值，其余时刻恒 null
                             *    ⇒ 这里退化成 t != _tab（= 改前行为）。
                             */
                            offstage: t != _tab && t != _leavingTab,
                            child: TickerMode(
                              // ★ 隐藏页停 ticker（省 CPU），但**不销毁** State
                              enabled: t == _tab,
                              /*
                               * ⚠️⚠️ `_KeepAliveTransition` 必须**无条件**在树里
                               *      （哪怕这一页还没访问过，child 先放占位）。
                               *
                               * # 我第一版把它写在 `_contentFor(t) == null` 的
                               *   分支里 ⇒ **首次切到某个 tab 时不会播动画**
                               *
                               * 原因是 Flutter 的生命周期：
                               * ```text
                               * 新建 widget   ⇒ 走 initState   （`didUpdateWidget` **不调用**）
                               * 已存在 widget ⇒ 走 didUpdateWidget
                               * ```
                               * 而我的动画触发点写在 `didUpdateWidget`
                               * （`active` false→true 时 `forward(from: 0)`）。
                               * ⇒ 首次切到 live 时那个 `_KeepAliveTransition` 是**新建**的，
                               *   `didUpdateWidget` 根本不跑 ⇒ controller 停在初值 1
                               *   （= 已就位）⇒ **没有进入动画**。
                               * ★ 而"切回已经访问过的页"（如 live→home）时它是**已存在**的
                               *   ⇒ 动画正常 —— 所以这个 bug **只在第一次访问某页时出现**，
                               *     很容易被"我明明看到动画了"骗过。
                               * ⇒ 修法：让它**从一开始就在树里**（child 用占位），
                               *   这样首次切过去时是 `didUpdateWidget` ⇒ 动画正常。
                               * ```
                               */
                              child: ValueListenableBuilder<PageTransitionStyle>(
                                /*
                                 * ══════════════════════════════════════
                                 * ★★ task-55：动画风格 —— **监听**用户的选择
                                 * ══════════════════════════════════════
                                 *
                                 * 用户原话：
                                 * > 然后还有个动画效果,我说让你多做几个**我来切换的**
                                 *
                                 * # 为什么用 `ValueListenableBuilder`（而不是直接读 `.value`）
                                 * ```text
                                 * 直接读 `PageTransitionStyleStore.current.value`：
                                 *   ⇒ ★ 只有"父级恰好重建"时才用上新风格
                                 *   ⇒ 用户在设置页点一下 ⇒ **当前这一层不会变**
                                 *     要等下次切 tab 才生效 ⇒ **不符合"我来切换的"**
                                 *
                                 * `ValueListenableBuilder`：
                                 *   ⇒ store 一变 ⇒ **只有这一小段重建** ✓
                                 *   ⇒ 用户点一下 ⇒ 下次切 tab **立刻**用新风格
                                 * ```
                                 *
                                 * ⚠️ 它**只重建 builder 里的子树**（即 `_KeepAliveTransition`
                                 *    这个 widget）——
                                 *    ★ 而 `_KeepAliveTransitionState`（含 `_c` 控制器）
                                 *      **不会被重建**（State 按"类型+位置"复用）
                                 *    ⇒ 改设置**不会打断**正在播的过渡 ✓
                                 *
                                 * ⚠️ `MotionPrefs.resolve` 在这里算 ——
                                 *    builder 里**有** context ⇒ 无障碍"减少动态效果"
                                 *    也一并生效（系统要求减少 ⇒ 强制 `none`）
                                 */
                                valueListenable: PageTransitionStyleStore.current,
                                builder: (context, style, _) =>
                                    _KeepAliveTransition(
                                  // 只有当前页参与进入动画
                                  active: t == _tab,
                                  /*
                                   * ★ 离场页：窗口期内只"画着"，不播动画
                                   *   （它拿的是恒为 1 的动画，见 build 里的说明）
                                   */
                                  leaving: t == _leavingTab,
                                  /*
                                   * ★ 2026-10-08（Owner 第 2 条）：离场页的不透明度。
                                   *
                                   * ⚠️ 必须**只**在离场那一页上生效 —— 给所有页
                                   *    都喂同一条会让新页也带上 1→0 的淡出（灾难）。
                                   *    所以这里用 `t == _leavingTab ? _leavingFade : null`，
                                   *    而不是无条件传。
                                   */
                                  leavingFade:
                                      t == _leavingTab ? _leavingFade : null,
                                  // 方向按 tab 序号算（复用既有逻辑）
                                  dir: _transitionDir,
                                  // ★ 用户选的风格（系统要求减少动效时被降级为 none）
                                  style: MotionPrefs.resolve(context, style),
                                  /*
                                   * ★ 惰性保活：没访问过的槽位放**尺寸稳定的占位**。
                                   *
                                   * ⚠️ 占位不能省略（不能写成 `if (...)`）——
                                   *    Stack 的子节点**按位置**匹配，
                                   *    槽位数量变化会让后面的页面错位重建（保活失效）。
                                   */
                                  child: _contentFor(t) ??
                                      const SizedBox.shrink(),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ), // Stack（保活）
              ), // SafeArea（F6 顶部安全区）
            ), // ClipRect
          ), // Positioned.fill

          // ── 底栏（自绘，不用 NavigationBar）──
          /*
           * ★ 用 Positioned 让底栏**浮在内容之上**（见上面 Stack 的说明）
           *
           * 不用 `Align(bottomCenter)` —— 那会把它放进 Stack 的
           * 非定位子节点列表，尺寸约束行为不同；`Positioned` 语义更明确。
           *
           * ══════════════════════════════════════════════════════════
           * ★★★ 2026-10-05：`bottom` 必须再加**系统导航栏安全区**
           * ══════════════════════════════════════════════════════════
           *
           * 用户原话：
           * > 这手机端底部都被遮挡了,你没有做安全距离判定吗?
           *
           * # 症状（模拟器实测，1080x2400 / 480dpi ⇒ 360x800dp）
           * ```text
           * navigationBars InsetsSource frame=[0,2256][1080,2400]
           *   ⇒ 144px = 48dp
           * 底栏 5 个 tab 的 a11y 命中矩形（uiautomator dump）：
           *   发现 [72,2190][259,2364] … 设置 [821,2190][1008,2364]
           *   ⇒ y2 = 2364 = 2400 − 36px（12dp 悬浮间隙，在 _BottomBar 里）
           * ⇒ 药丸 2190..2364 与导航栏带 2256..2400 重叠 108px = 36dp
           * ```
           *
           * # 根因：漏了原版公式里的 `var(--safe-bottom)`
           *
           * 原版 `src/design/liquid-glass.css:82-87`：
           * ```css
           * .tabbar { bottom: calc(var(--tabbar-bottom) + var(--safe-bottom)); }
           * ```
           * 当初只抄了 `--tabbar-bottom`（落在 `_BottomBar` 的
           * `Padding(bottom: 12)` 里），把 `--safe-bottom` 丢了。
           *
           * ⚠️ `Sp.bottomBarInset` **补不了**这个洞：它是给**页面内容**
           *    留白的 getter（无 `context`，拿不到 `MediaQuery`），
           *    管的是「内容别被底栏盖住」，不是「底栏别被系统栏盖住」。
           *
           * # 为什么这里的 `paddingOf` 读到的是**根 padding**
           *
           * 本 `Positioned` 是 `Stack`（`:3649`）的**兄弟**，不是那个
           * `SafeArea(top: true, …)`（`:3886`，在 `Positioned.fill` 之内）
           * 的后代 ⇒ 没有 `removePadding` 把它清零，读到的就是窗口的
           * `viewPadding.bottom`。键盘弹出时 `padding.bottom` 归零，底栏
           * 顺势落回底部 —— 那时它本来就被键盘盖着，符合预期。
           *
           * # 负对照（桌面 / TV 上严格 no-op）
           * ```text
           * 桌面：ViewPadding 默认全零（platform_dispatcher.dart:2000）
           * TV  ：InsetsState 里没有 navigationBars 源
           * ⇒ padding.bottom == 0 ⇒ 几何逐像素不变
           * ```
           */
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.paddingOf(context).bottom,
          /*
           * ★ 套 `BottomBarMarker` —— 等价于原版的 `data-nav-scope`/`.tabbar`
           *
           * 空间导航的 `↓` 要做"先在内容区找、找不到才落底栏"的两轮搜索，
           * 而它必须知道**哪些节点属于底栏**。
           *
           * ⚠️ 不能靠几何判断（"在屏幕下方"）—— 实测在 960x540 的 TV 上，
           *    阈值 459 把一张 `(36,202,184,468)` 的**海报卡**误判成底栏，
           *    导致两轮搜索排错对象。
           *    原版用的是 `c.el.closest(".tabbar")` 这种**结构判据**，
           *    永远不会因为屏幕尺寸而判错。这里照做。
           */
            child: BottomBarMarker(
              child: _BottomBar(
                current: _tab,
                unread: _unread,
                colors: colors,
                onSelect: _switchTo,
              ),
            ),
          ),
        ],
      ),
      ),   // ← Material(type: transparency) 的收尾（见上方的长注释）
    ),     // ← AppScaffold 的收尾
    );     // ← ShellScope 的收尾
  }

  Widget _pageFor(AppTab t) {
    switch (t) {
      case AppTab.home:
        /*
         * ★ 发现页（2026-09-23 接入真页面）
         *
         * 用 `GlobalKey` 拿到 state —— 因为「返回首页要刷新」
         *（原版 `onActivated`）需要从外部调 `loadAll()`。
         *
         * 原版注释：
         * > 本页在 `keepAlivePages` 里，组件实例被缓存 ——
         * > `onMounted` **只执行一次**。而首页内容是会变的：
         * > 用户在设置页导入/停用了源、「我的」三合一的收藏/追更/历史变了。
         * > ⚠️ 但**不能**无条件全量重拉 —— 那样每次切回来要等 4 秒。
         * > 这里只重拉**分区列表**（很快，走缓存），区块内容按需补齐。
         *
         * Flutter 侧等价：切回 home 时调 `loadAll()`（非 force）——
         * 它会重拉分区骨架，但已有内容的区块会跳过。
         */
        return HomePage(
          key: _homeKey,
          isTv: Device.isTv,
          onOpenDetail: _openDetail,
          onOpenLive: _openLiveChannel,
          onBrowse: _openBrowse,
          /*
           * ★★ task-65：「我的」版块的「查看更多」
           *
           * Owner 原话：
           * > 首页的 追更，历史，收藏 应该有一个查看更多按钮……
           * > 点一下就跳转到 追更页面，激活对应的 tab
           *
           * `key` 由 `MyShelf` 按**当前 tab** 算好（`shelfTabToFollowKey`）。
           */
          onSeeAllShelf: _openFollowTab,
          /*
           * ★ 点「我的」卡片 → 直接进播放器续播
           *
           * 与其它区块不同（那些跳详情页）—— 原版注释：
           * > 这些是"我自己的数据"，用户点它就是要**接着看**。
           */
          onShelfPlay: (provider, id, title, cover, episodeId) {
            Navigator.of(context).push(
              MaterialPageRoute(
                // ★ task-58：合并页（上播放器 + 下详情）—— 标题已知，直接给
                //
                // ⚠️ `MediaPage` **没有**那四个直播参数（设计上不需要）——
                //    理由与注意点见 `AppTab.follow` 那处（同一段注释）。
                builder: (_) => MediaPage(
                  provider: provider,
                  id: id,
                  title: title,
                  cover: cover,
                  episodeId: episodeId,
                  isTv: Device.isTv,
                  isTouchOnly: Device.isTouchOnly,
                ),
              ),
            );
          },
        );
      case AppTab.live:
        /*
         * ★ 直播页（2026-09-23）
         *
         * 用 GlobalKey 拿 state —— 切回本页要「重新拉频道列表
         * 但保留选中的频道」（原版 `onActivated(() => loadAll(true))`）。
         */
        return LivePage(
          key: _liveKey,
          isTv: Device.isTv,
          /*
           * ★ 可见性信号（task-39）——
           *   直播页有内嵌播放器，而 tab 页被保活（切走不销毁）
           *   ⇒ 必须告诉它"你不可见了"，否则后台继续出声。
           */
          visible: _liveVisible,
          /*
           * ★★ 必须 `return` push 的 Future（task-39，lead 裁决 (a)）
           *
           * # 为什么（不 return 会编译错：`Future<void>` 不能返回 null）
           * ```text
           * 直播页有**内嵌播放器**；全屏是 push 一个独立 PlayerPage。
           * 两个播放器同时解码同一路流 ⇒ **回声/重音**。
           * ⇒ 直播页要"跳全屏前 pause 内嵌，pop 回来再续播"。
           *   ★ 那个"回来"的时机只能靠这个 Future（pop 时完成）。
           * ⇒ 所以这里**必须**把它交出去。
           * ```
           */
          onWatchLive: (provider, channelId, name) {
            return Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PlayerPage(
                  provider: provider,
                  id: channelId,
                  title: name,
                  liveChannelId: channelId,
                  /*
                   * ★ task-53【#4b】全屏直播里 ↑/↓ 切台（用户第 4 条）。
                   *   分工：直播页 `_liveKey` 是"哪些台可见"的唯一真相
                   *   （探针缓存 + 启用态 + audioOnly 过滤）⇒ 由它算目标台。
                   *   `stepChannelForFullscreen` **只改选中、不起播** ——
                   *   此刻出声的是播放页那个 mpv，直播页若也起播就是**双声**。
                   * ⚠️ 不用 `_liveChannelStep`（ValueNotifier）：它**去重相等的值**
                   *   ⇒ 连按两次 ↓（delta 都是 +1）第二次不通知 ⇒ 只切一个台。
                   * ⚠️ 只在**焦点在本页**时够用；焦点不在时由播放页
                   *   `_onHardwareKey` 的兜底路径接管（同 Esc，见那里的注释）。
                   * ★ 详细推导见 `player_page.dart::onLiveChannelStep` 的文档。
                   */
                  onLiveChannelStep: (delta) =>
                      _liveKey.currentState?.stepChannelForFullscreen(delta),
                  /*
                   * ★★★ task-53【③】「所有直播」列表面板（用户第 3 条）
                   *
                   * ```text
                   * 用户原话（逐字）：
                   * > 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
                   * ```
                   * 分工与 `onLiveChannelStep` **完全一致**：直播页是"哪些台可见"
                   * 的唯一真相（探针缓存 + 启用态 + audioOnly 过滤）⇒ 由它给列表。
                   * ⚠️ 三处直播 `PlayerPage(` **必须都接** —— 少一处那条路径就没有
                   *   入口（#4b 就是这么漏的，见
                   *   `test/zz_t53_live_fullscreen_switch_test.dart`）。
                   */
                  onLiveChannels: () =>
                      _liveKey.currentState?.channelsForFullscreen(),
                  onLiveChannelPick: (c) =>
                      _liveKey.currentState?.pickChannelForFullscreen(c),
                  isTv: Device.isTv,
                  isTouchOnly: Device.isTouchOnly,
                ),
              ),
            );
          },
          onWatchReplay: (provider, channelId, title, episodeTitle) {
            /*
             * ★ 回看走的是**同一个直播频道**的时移流
             *
             * 原版把 `episodeTitle` 设成「20:00 节目名」用来在
             * 播放器上显示"你在看哪一段"。
             */
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PlayerPage(
                  provider: provider,
                  id: channelId,
                  title: title,
                  episodeTitle: episodeTitle,
                  liveChannelId: channelId,
                  /*
                   * ★ task-53【#4b】回看也是**同一个直播频道**（时移流）
                   *   ⇒ `_isLive` 为真，↑/↓ 应当切台而不是调音量。
                   *
                   * ⚠️ 本路径当前**不可达**：节目单（`EpgPanel`）已按用户
                   *    第 4 条要求从直播页移除，`onWatchReplay` 没有调用点
                   *    （`live_page.dart` 只保留构造参数，见它的注释）。
                   *    ★ 仍然接线：一旦将来恢复入口，行为是对的，
                   *      而不是"静默变成音量键"。
                   */
                  onLiveChannelStep: (delta) =>
                      _liveKey.currentState?.stepChannelForFullscreen(delta),
                  // ★ task-53【③】回看也是同一个直播频道 ⇒ 同样给「所有直播」入口
                  onLiveChannels: () =>
                      _liveKey.currentState?.channelsForFullscreen(),
                  onLiveChannelPick: (c) =>
                      _liveKey.currentState?.pickChannelForFullscreen(c),
                  isTv: Device.isTv,
                  isTouchOnly: Device.isTouchOnly,
                ),
              ),
            );
          },
        );
      case AppTab.follow:
        /*
         * ★ 追更页（2026-09-23）
         *
         * 原版注释：
         * > 每次**返回**本页都重新拉一次（KeepAlive 场景必须）。
         * > 本页的数据很容易在别处被改：在播放页看完一集 → 进度变了；
         * > 在详情页点了「追更」/「收藏」→ 列表应立刻反映。
         * > 不刷新就会出现「明明刚追更，回来却看不到」。
         */
        return FollowPage(
          key: _followKey,
          isTv: Device.isTv,
          /*
           * ★★ task-65：把"待激活的 tab"交给追更页
           *
           * ⚠️ 必须**读走并清空** —— 见 `_followTabRequest` 的说明：
           *    留着的话，用户之后手动切到本页会被这个旧请求**再拽一次**。
           *
           * ⚠️ 只在 `_pageFor` 里消费（**构造**路径）。`_contentFor` 是
           *    保活查找路径，不会走到这里 —— 那种情形由
           *    `_openFollowTab` 里的 `showTab` 直接处理。
           */
          initialTab: _takeFollowTabRequest(),
          onUnreadChanged: (n) {
            if (mounted && n != _unread) setState(() => _unread = n);
          },
          onPlay: (provider, id, title, cover, episodeId) {
            Navigator.of(context).push(
              MaterialPageRoute(
                // ★ task-58：合并页（上播放器 + 下详情）
                //
                // ⚠️ `MediaPage` **没有** `liveChannelId` / `onLiveChannelStep` /
                //    `onLiveChannels` / `onLiveChannelPick` 这**四个**参数 ——
                //    那是**设计上不需要**（直播没有"详情区"，它继续走 `PlayerPage`，
                //    见下面 `AppTab.live` 那几处）。
                //    ⇒ 若将来这里要传直播参数，说明你在做"**直播也进合并页**"，
                //      那时必须给 `MediaPage` **补上**那四个参数，
                //      **不是**把这里改回 `PlayerPage`。
                builder: (_) => MediaPage(
                  provider: provider,
                  id: id,
                  title: title,
                  cover: cover,
                  episodeId: episodeId,
                  isTv: Device.isTv,
                  isTouchOnly: Device.isTouchOnly,
                ),
              ),
            );
          },
          onOpenDetail: _openDetail,
        );
      case AppTab.search:
        return SearchPage(
          key: _searchKey,
          isTv: Device.isTv,
          onOpenDetail: _openDetail,
        );
      /*
       * ★ task-3 ⑲「已缓存」页（Owner 要的「底部已缓存页 + 封面 + 缓存了多少」）
       *
       * 数据源 = **真扫盘**（`scanCacheWorks(DownloadDir.root())`）：
       * lib/core/sourin_api.dart 里**根本没有**下载记录这类接口，
       * 盘上的文件才是唯一真相 —— 也因此这里的数字与用户
       * 在资源管理器里看到的是同一个。
       *
       * `onOpen` 复用「我的」版块那条现成入口（push 合并页 MediaPage：
       * 上播放器 + 下详情，见 `onShelfPlay`），不新造一条播放路径。
       */
      case AppTab.cached:
        return CachePage(
          key: _cachedKey,
          isTv: Device.isTv,
          onOpen: _openCachedWork,
        );
      case AppTab.settings:
        /*
         * ★ 设置页（2026-09-23）
         *
         * 源列表在这里被改（启用/停用/导入插件）—— 改完要通知首页刷新，
         * 否则用户回首页会发现新源没出现（原版的 `store.refreshProviders()`）。
         */
        return SettingsPage(
          key: _settingsKey,
          isTv: Device.isTv,
          onProvidersChanged: () {
            // ★ `reason: 'providers-changed'` —— 第三条 `force=true` 来源
            //   （Lead 发现）。不加标记的话，用户"在设置页停用源 → 回首页"
            //   会让 `force=true` 计数 +1，判据会**误判**成"页面重建了"。
            _homeKey.currentState?.loadAll(
              force: true,
              reason: 'providers-changed',
            );
          },
        );
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  导航回调（发现页 → 其它页）
  // ═══════════════════════════════════════════════════════════════════

  /// ★ task-3 ⑲ / ★★ task-12 ④：点「已缓存」页的一张卡片 ⇒ 进播放
  ///
  /// # 为什么必须与 `onShelfPlay` 走**同一个** MediaPage（而不是直接开播放器）
  ///
  /// 与下面 `_openDetail` 那段讲的是同一件事：多集内容要选集、多源要换源，
  /// 那些能力长在 MediaPage 内部。直接开 PlayerPage 会退回老毛病 ——
  /// 永远只能看第一集。
  ///
  /// # ★★ task-12 ④：会话由 **CachePage 组织好**，这里只转发
  ///
  /// `buildLocalPlayRequest(work)` 在 **cache_page.dart** 里把会话（含
  /// provider=local、规范化后的绝对路径）组织成 `CachedPlayRequest`；
  /// 本方法只往 `MediaPage` 喂值，**不猜任何字段**。
  ///
  /// # ★★★ 两条路怎么分（lead 裁决）
  /// ```text
  /// 旁文件在（provider/id 齐） ⇒ **仍然走在线路径**（与 task-3 行为逐字相同）
  ///   为什么：旁文件意味着这一集是**从某个站点下载的**，在线路径能拿到
  ///   选集 / 换源 / 弹幕那些能力（Owner：「弹幕 历史等等功能也还是要有的」）。
  ///   ⇒ 本地播放是**兜底**，不是替代。
  ///
  /// 旁文件不在（老下载 / 用户手拷进来的）⇒ **走本地播放**（localPath）
  /// ```
  ///
  /// # 本地播放为什么能成立（链路，全部实测核过）
  /// ```text
  /// ① mpv 原生支持 `file://`；`player_page.dart:3263` 把 url 原样交给 mpv；
  ///    `models.dart:822` 的 isPlayable 只判 `!drmProtected && url.isNotEmpty`
  ///    ⇒ file:// 能过闸。
  /// ② `player_page.dart:2921 _load()` 是唯一生产起播入口，且**无条件**走
  ///    `SourinApi.resolveStream` → Rust `registry.route`（playback.rs:161-164）
  ///    ⇒ 本地路径没有 provider 可路由 ⇒ 必须**在它之前**短路。
  /// ③ 落点（lead 裁决「路 A」）：PlayerPage / MediaPage 各加一个**可选**
  ///    `localPath`，在 `initState` 里短路、**根本不调 _load()** ——
  ///    这样 `_load()` 的字节一行不动（不碰 ui-dev 正在改的那个函数）。
  ///    那两处由 **ui-dev** 落（它 owner 那两个文件）；本文件只负责喂值。
  /// ```
  void _openCachedWork(CachedPlayRequest req) {
    final w = req.work;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MediaPage(
          // ★ 有旁文件 ⇒ 用站点 provider/id（在线能力全都在），
          //   没有 ⇒ 用 req 里组织好的 local 会话（provider='local'）。
          provider: w.provider ?? req.provider,
          id: w.mediaId ?? req.mediaId,
          title: w.displayTitle,
          cover: w.cover,
          episodeId: req.episode.fileName,
          /*
           * ★★ localPath 的取值规则（与上面那个三元一一对应，不能只改一半）：
           * ```text
           * 有旁文件 ⇒ **null** —— 让播放器走原来的网络解析（行为逐字不变）；
           * 没旁文件 ⇒ 文件的**绝对路径** —— initState 短路成 file:// 起播。
           * ```
           * ⚠️ 必须显式写 `null` 而不是省掉：省掉的话，将来若有人把这两个三元
           *    改歪（比如 provider 有旁文件、localPath 却给了路径），
           *    症状是「有旁文件的在线剧被当成本地文件播」——很难查。
           */
          localPath: w.provider != null && w.mediaId != null
              ? null
              : req.episodeAbsolutePath,
          isTv: Device.isTv,
          isTouchOnly: Device.isTouchOnly,
        ),
      ),
    );
  }

  /// 打开**合并页**（task-58：上播放器 + 下详情）
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// ★★★ 2026-09-26 Owner 裁决：详情页与播放页**合并成一个页面**
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// ```text
  /// ① 布局：**上播放器 + 下详情**（B站那种）
  /// ② 全屏：全屏时只剩视频，退出后回到合并页
  /// ③ 旧详情页：**完全去掉**，所有入口直接进合并页
  /// ```
  ///
  /// # 为什么仍然必须"先跳这一页"（而不是直接开播放器）
  ///
  /// 旧注释的顾虑**仍然成立**：
  /// > 多集内容（如 cycani 的 24 集）需要选集、多源内容需要换源。
  ///
  /// 只是那些能力现在**长在合并页内部**了：
  /// ```text
  /// 选集 ⇒ 详情区点某一集 ⇒ `MediaSession.applySession`（同一个播放器，不 push）
  /// 换源 ⇒ 详情区点换源   ⇒ 同上
  /// ```
  /// ⇒ 所以不再需要"详情页 → 播放页"那两级 push，也不会
  ///   "永远只能看第一集"。
  ///
  /// # ⚠️ 日志文案是**验收判据的一部分**
  ///
  /// 判据①要求「首页点卡片 ⇒ **只有一次导航**，日志里**没有**
  /// 「打开详情」再「打开播放器」」。
  /// ⇒ 文案必须能**区分新旧路径**（旧的是「打开详情」+「打开播放器」两条），
  ///   否则这条判据没有区分力。
  void _openDetail(String provider, String id) {
    debugPrint('[NAV] 打开合并页: $provider:$id');
    Navigator.of(context).push(_mediaRoute(provider, id));
  }

  /// 合并页路由
  ///
  /// # ★ 为什么不再需要 `onPlay` / `onOpenDetail` 两层回调（净简化）
  ///
  /// 旧结构里详情页要能"换源后跳到新源的详情页"，所以抽了个
  /// `_detailRoute` 并在里面嵌一层 `onOpenDetail` 回调（注释见 git 历史）。
  ///
  /// 合并页里那两个动作**都在页内完成**（走 `MediaSession`）：
  /// ```text
  /// 选集 ⇒ 同一个播放器换集（不 push）
  /// 换源 ⇒ 同一个播放器换源（不 pushReplacement）
  /// ```
  /// ⇒ 嵌套回调**整个消失**，任意次换源都只是页内状态变化。
  ///
  /// ⚠️ 这也顺带修掉了旧结构的一个隐患：`pushReplacement` 换源时
  ///    会把**正在播的播放器**一起销毁（新路由 = 新 `Player`）。
  MaterialPageRoute<void> _mediaRoute(String provider, String id) {
    return MaterialPageRoute<void>(
      builder: (ctx) => MediaPage(
        provider: provider,
        id: id,
        // ⚠️ 标题此刻还不知道（要详情才有）——
        //    合并页会在详情加载完后用 `updateDisplayTitle` 补上。
        title: '',
        isTv: Device.isTv,
        /*
         * ★★ `isTouchOnly` 必须一起传（漏传已修）
         *
         * 本处是全仓**唯一**漏传这个参数的 `MediaPage(` 构造点（其余
         * **三处**都传了）。漏传的后果是手机上所有非直播入口（首页卡片 /
         * 我的三合一 / 追更 / 搜索 / 浏览页 / 详情换源）都走到了 PC 分支：
         *
         * ```text
         * MediaPage.isTouchOnly 默认 false
         *   ⇒ PlayerPage._isTouchGestureTarget == false
         *   ⇒ _isPcKeyboardTarget == true
         *   ⇒ 双击 = 全屏（而不是左右快进快退）
         *   ⇒ 长按读 player.pcButtons.* 而不是 player.gesture.*
         *   ⇒ 「长按开关」关不掉（PC 分支恒 true）
         * ```
         *
         * 真机铁证（android-phone，旧 APK 同样命中，说明是既有缺陷）：
         * 双击后 logcat 出 `[PLAYER-KEY] 双击 ⇒ 切换全屏`，而那行
         * 全仓只能出自 `player_page.dart` 的 `onDoubleTap` **else 分支**。
         *
         * ⚠️ 守卫：`test\t456_media_route_touch_test.dart`
         *    （本仓**四个** `MediaPage(` 构造点必须都带 `isTouchOnly:`）。
         */
        isTouchOnly: Device.isTouchOnly,
      ),
    );
  }

  /// 打开播放器
  ///
  /// 直播与点播共用同一个入口 —— 播放器自己根据 `episodes` 是否为空
  /// 决定要不要显示选集栏。
  ///
  /// [replace] 为 true 时用 `pushReplacement` —— **只给遥控 `play_item` 用**：
  /// 手机端点另一个片子时，语义是「**换**成这个」（原版
  /// `if (route.name !== "play") router.push(...)` 等价于"已经在播放页就
  /// 就地换会话"），而不是再叠一层。叠一层会让两个 `Player` 同时解码出声
  ///（`PlayerPage` **没有** `RouteAware`，被盖住时不会暂停）。
  void _openPlayer(PlayRequestData req, {bool replace = false}) {
    debugPrint('[NAV] 打开播放器: ${req.provider}:${req.id} '
        'ep=${req.episodeId ?? "(无)"} 共 ${req.episodes.length} 集'
        '${replace ? "（替换当前播放器）" : ""}');
    /*
     * ★ 置位"播放器已打开" —— 让全局方向键 handler 放行
     *   （播放器要用 ←/→ 快退快进、↑/↓ 音量，见 player_page 的 _onKey）
     *
     * ⚠️ 必须在 `push` **之前**置位：`push` 之后播放器立刻进入构建，
     *    用户可能在动画还没结束时就按键。
     */
    _playerOpen = true;
    // 本次路由的代号（见 `_playerOpenGen` 的说明：防御 pushReplacement 时
    // 旧路由的 whenComplete 回来把新播放器的标志清掉）
    final gen = ++_playerOpenGen;

    final route = MaterialPageRoute<void>(
      // ★ task-58：合并页（上播放器 + 下详情）
      //
      // ⚠️ `MediaPage` **没有**那四个直播参数（设计上不需要）——
      //    理由与注意点见 `AppTab.follow` 那处（同一段注释）。
      builder: (_) => MediaPage(
        provider: req.provider,
        id: req.id,
        // ★ 这里**知道**标题（遥控/搜索直接播时带了）⇒ 直接给，不必等详情
        title: req.title,
        cover: req.cover,
        episodeId: req.episodeId,
        episodeTitle: req.episodeTitle,
        sourceCode: req.sourceCode,
        episodes: req.episodes,
        episodeIndex: req.episodeIndex,
        isTv: Device.isTv,
        isTouchOnly: Device.isTouchOnly,
      ),
    );

    final nav = Navigator.of(context);
    /*
     * ⚠️ 栈里没有可替换的路由时必须退回 `push`
     *
     * `pushReplacement` 在**根路由**上调用是合法的（它替换掉根），
     * 但那种情况只可能出现在"没有播放器"时 —— 而那时 replace 本来就是多此一举。
     * 用 `canPop()` 兜一层，语义更直白。
     */
    final fut = (replace && nav.canPop())
        ? nav.pushReplacement(route)
        : nav.push(route);

    fut.whenComplete(() {
      /*
       * ⚠️ 只在**自己仍是最新那个播放器**时才清标志（见 `_playerOpenGen`）
       *
       * 旧实现无条件 `_playerOpen = false` —— 在 pushReplacement 的场景下，
       * 旧路由的退场回调会把**新播放器**的标志清掉。
       */
      if (gen == _playerOpenGen) _playerOpen = false;
      // 被替换掉时清掉"播放器已打开"的语义由新一代负责（上面那行不等）
    });
  }

  /// 打开直播频道
  ///
  /// 直播没有剧集/多源可选，跳详情页反而是多余的一步，故直接进播放器。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ task-6：新增第一个参数 [provider]（这个频道**属于哪个源**）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # 错在哪
  ///
  /// 旧签名只有 `(channelId, name)`，而下面 push 的 `PlayerPage` 里
  /// `provider` 被**写死成 'cctv'`**：
  /// ```text
  /// 旧 :4913  void _openLiveChannel(String channelId, String name)
  /// 旧 :4923    provider: 'cctv',        ← ★ 无论频道来自哪个源都写 cctv
  /// ```
  /// 而调用方（首页直播条的 `onOpenLive`）**本来就知道源** ——
  /// 它每个频道都是按 `(provider, channelId)` 探出来的。
  /// 信息在回调边界上被丢掉 ⇒ 一旦用户在首页切到别的源再看直播，
  /// 播放器仍然去 cctv 取流 ⇒ 取不到 ⇒ **黑屏**。
  /// （正是 Owner 第 8 条要消灭的症状；task-4 实测：cctv 的 20 个频道
  ///   视频线 100% `drmProtected: true`，写死 cctv 等于写死黑屏。）
  ///
  /// # 为什么这么改
  ///
  /// 让**知道源的那一层**把源如实传上来，参数顺序与
  /// `HomePage.onOpenLive` / `LivePage.onWatchLive`（`(provider, channelId, name)`）
  /// 保持一致 —— 同一个语义在三个回调上用同一种形状，少一次"顺序记错"的机会。
  ///
  /// ⚠️ 刻意**不给默认值**：写死 'cctv' 正是本次要修的 bug，
  ///    留个默认值等于把它换个地方留着（下一个人漏传时静默回到黑屏）。
  ///    没有默认值 ⇒ 漏传是**编译错误**。
  void _openLiveChannel(String provider, String channelId, String name) {
    debugPrint('[NAV] 打开直播: $provider/$channelId ($name)');
    // 同 `_openPlayer`：置位，让全局 handler 把方向键让给播放器
    _playerOpen = true;
    // 同 `_openPlayer`：代号守卫（否则被遥控替换掉时，
    // 本路由的 whenComplete 会清掉新播放器的标志，见 `_playerOpenGen`）
    final gen = ++_playerOpenGen;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          // ★ task-6：源来自调用方（旧代码在这里写死 'cctv'）
          provider: provider,
          id: channelId,
          title: name,
          liveChannelId: channelId,
          /*
           * ★ task-53【#4b】遥控进直播也接线 —— 与播放器全屏按钮那条路
           *   （`onWatchLive`）**同一分工**，见那里的长注释。
           *
           * ⚠️ 本路径是**遥控**（TV/手机遥控）触发的，TV 上 ↑/↓ 就是换台键
           *   ⇒ 不接线的话 TV 用户按方向键只会调音量（而 TV 没有音量键语义），
           *     正是用户第 4 条要解决的问题。
           */
          onLiveChannelStep: (delta) =>
              _liveKey.currentState?.stepChannelForFullscreen(delta),
          // ★ task-53【③】遥控进直播也给「所有直播」入口（同 `onWatchLive` 的分工）
          onLiveChannels: () =>
              _liveKey.currentState?.channelsForFullscreen(),
          onLiveChannelPick: (c) =>
              _liveKey.currentState?.pickChannelForFullscreen(c),
          isTv: Device.isTv,
          isTouchOnly: Device.isTouchOnly,
        ),
      ),
    ).whenComplete(() {
      if (gen == _playerOpenGen) _playerOpen = false;
    });
  }

  /// 「查看全部」→ 浏览页
  ///
  /// # 三种去向（与原版一一对应）
  ///
  /// ```text
  /// category → 浏览页（带分类参数）
  /// rank     → 浏览页（带榜单参数，复用同一页面）
  /// custom   → 直播页
  /// ```
  /// 原版注释解释了为什么复用同一个页面：
  /// > 两者除了取数接口不同，**交互完全一致**（网格 + 分页加载 + 空态），
  /// > 分开写只会让改一处要改两遍。
  void _openBrowse(String provider, String title, SectionSource src) {
    debugPrint('[NAV] 浏览: $provider / $title / type=${src.type}');

    // custom 型（首页的直播条）→ 切到直播 tab
    if (src.type == 'custom') {
      _switchTo(AppTab.live);
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BrowsePage(
          provider: provider,
          categoryId: src.categoryId ?? '',
          rankId: src.rankId ?? '',
          title: title,
          isTv: Device.isTv,
          onOpenDetail: _openDetail,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★ 自绘标题栏
// ═══════════════════════════════════════════════════════════════════════
//
// Owner：「顶部那个操作也要自己实现，自带的还是不好看」
//
// 三个必须自己处理的细节：
// ```text
// ① 拖动：整条空白区拖动要能移动窗口 → GestureDetector + startDragging
// ② 双击：双击标题栏 = 最大化/还原（Windows 的既有习惯，必须保留）
// ③ 按钮：最小化/最大化/关闭，样式自定，且关闭按钮 hover 要变红
// ```

/// 自绘标题栏的宿主（挂在 `MaterialApp.builder` 里，**Navigator 之外**）
///
/// # 为什么必须在这里（2026-09-24 用户报告的真缺陷）
///
/// 用户反馈：「影视详情页和播放页都没有顶部的那个操作条，无法拖动」。
///
/// 我原来把标题栏挂成 `FScaffold.header` —— 那是 `ShellPage` 内部，
/// 而详情页/浏览页/播放页都是 `Navigator.push` 上来的**新路由**，
/// 渲染在 `ShellPage` **之外**：
/// ```text
/// Navigator
///  ├─ 路由 0: ShellPage   ← 标题栏在这里（只有它有）
///  ├─ 路由 1: DetailPage  ← 在它外面，既没标题栏也没拖动区 ✗
///  └─ 路由 2: PlayerPage  ← 同上 ✗
/// ```
/// 结果**一进详情页就拖不动窗口**。
///
/// 原版 `App.vue` 把 `<TitleBar />` 放在 `RouterView` **外面**，
/// 所有路由共用一条 —— 这里用同样思路，挂在 `MaterialApp.builder`。
///
/// # 播放页要完全让位（对齐原版 `.is-hidden`）
///
/// 原版 CSS：
/// ```css
/// .titlebar.is-hidden {
///   opacity: 0;
///   transform: translateY(-100%);
///   pointer-events: none;
/// }
/// ```
/// 即"移出屏幕 + 不可点"。这里用 `AnimatedSize` + 高度归零实现等价效果：
/// 播放页要的是**画面占满**，留一条 40px 的空条会白占地方。
///
/// ⚠️ 桌面以外的平台**完全不渲染** —— Android 没有"窗口"概念，
///    minimize/toggleMaximize 在那平台上不存在（点了不会有反应）。
class _TitleBarHost extends StatefulWidget {
  const _TitleBarHost({required this.child});

  final Widget child;

  @override
  State<_TitleBarHost> createState() => _TitleBarHostState();
}

class _TitleBarHostState extends State<_TitleBarHost>
    with WidgetsBindingObserver {
  /// 是否最大化（自绘标题栏要自己显示按钮状态）
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    titleBarVisible.addListener(_onVisibleChanged);
    // ★ 播放页要把标题栏压暗（见 `titleBarDark` 的说明）
    titleBarDark.addListener(_onVisibleChanged);
    /*
     * ⚠️ 只在桌面调 windowManager（实测踩到）
     *
     * Android 上直接调会抛：
     * ```text
     * MissingPluginException(No implementation found for method isMaximized
     *   on channel window_manager)
     * ```
     * 因为 `window_manager` 的原生端只在桌面平台注册。
     */
    if (kIsDesktop) _syncMaximized();
  }

  @override
  void dispose() {
    titleBarVisible.removeListener(_onVisibleChanged);
    titleBarDark.removeListener(_onVisibleChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onVisibleChanged() {
    if (mounted) setState(() {});
  }
  /// 窗口尺寸变化 → 重新读最大化状态
  ///
  /// # 为什么需要（原版没有，是 Flutter 侧的必要补充）
  ///
  /// 用户双击标题栏最大化、或拖到屏幕边缘触发 Aero Snap 时，
  /// 我们是**收不到点击回调**的 —— 只有窗口尺寸变了。
  /// 不监听的话按钮图标会停在"最大化"状态（该显示"还原"了）。
  @override
  void didChangeMetrics() {
    if (kIsDesktop) _syncMaximized();
  }

  Future<void> _syncMaximized() async {
    if (!kIsDesktop) return;
    try {
      final m = await windowManager.isMaximized();
      if (mounted && m != _maximized) setState(() => _maximized = m);
    } catch (_) {
      // 插件不可用（极端情况）—— 不该因此让应用崩
    }
  }

  @override
  Widget build(BuildContext context) {
    // 非桌面：没有窗口概念，不渲染标题栏
    if (!kIsDesktop) return widget.child;

    final show = titleBarVisible.value;
    final isDark = titleBarDark.value;
    return Column(
      children: [
        /*
         * ★ 用 AnimatedSize 做"收起"动画
         *
         * 原版是 CSS transition（`opacity` + `translateY`），
         * 但 CSS 里元素**仍然占位**（`translateY(-100%)` 只是移出去）——
         * 播放页那边是靠 `.app-main` 的 `padding-top` 配合。
         *
         * Flutter 里更直接：把高度收到 0，内容自然占满。
         * 180ms 与原版动效时长接近。
         *
         * ⚠️ 用户报的「进播放页闪白条」**不是**这个动画造成的：
         *    实测（`.probe/whitebar_capture.py`）标题栏在播放页
         *    **根本不会收起**（`player_page.dart:627` 刻意保持显示，
         *    因为桌面端它是唯一的拖动区）。真正的原因是
         *    **浅色玻璃压在纯黑播放页上** —— 见 `titleBarDark`。
         */
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: show
              ? _CustomTitleBar(
                  maximized: _maximized,
                  dark: isDark,
                  onMinimize: () => windowManager.minimize(),
                  onToggleMaximize: () async {
                    if (await windowManager.isMaximized()) {
                      await windowManager.unmaximize();
                    } else {
                      await windowManager.maximize();
                    }
                    await _syncMaximized();
                  },
                  onClose: () => windowManager.close(),
                )
              : const SizedBox(width: double.infinity),
        ),
        /*
         * ══════════════════════════════════════════════════════════════════
         * ★★★ `ClipRect` —— 修用户报的「白条覆盖操作条」（任务㉗④）
         * ══════════════════════════════════════════════════════════════════
         *
         * # 用户原话
         *
         * > 打开播放详情页的时候还是有白色的条会覆盖操作条,
         * > 这个不能优化掉吗?太影响观感了
         *
         * # 根因（逐帧实测，`.probe/t27_whitebar_map.py`）
         *
         * 白条**不是**标题栏的问题，也**不是** scrim —— 是**转场把上一页放大后
         * 画到了标题栏上面**：
         * ```text
         * 正常     标题栏 y=0..39（40px，= preferredSize），内容从 y=40 开始
         * 转场中   标题栏仍从 y=0 开始，但**被压到 y=0..22**
         *          纯白 #ffffff 填满 y=23..39（正是被压掉的那 17px）
         * ```
         * 而且白条**上边缘在动**（t=213ms → y=23，t=375ms → y=21），
         * 说明它在**变大** —— 这是缩放动画的特征，不是静态色块。
         *
         * 算术对得上 `ZoomPageTransitionsBuilder` 的离场缩放：
         * ```text
         * Navigator 高 = 800 − 40 = 760
         * scale 1.04 → 页面顶部上溢 (760×0.04)/2 = 15.2px → y≈24.8
         * scale 1.05 → 上溢 19.0px                      → y≈21.0
         * ★ 实测 y=23..21 正好落在这两个值之间
         * ```
         * 也就是说：**离场页被放大，而 `Navigator` 不裁剪**，
         * 于是它溢出到标题栏区域，把操作条盖住了。白色就是那一页自己的底色。
         *
         * # 为什么之前没修掉
         *
         * 上一轮修的是 `ZoomPageTransitionsBuilder.backgroundColor`
         * （那层 scrim）—— 实测确实有用（scrim 不再是 `surface` 色），
         * 但**没解决缩放溢出**：scrim 透明了，页面自己还是会放大画出来。
         * 所以用户仍看到白条。
         *
         * # 修法：给 Navigator 加一层裁剪
         *
         * `ClipRect` 让内容**只能画在自己的矩形里**，缩放溢出被裁掉：
         * ```text
         * 不改动画       —— 用户只是嫌白条难看，不是要取消缩放淡入
         * 不改 Navigator —— 只加一层裁剪，路由栈/返回全不受影响
         * 不动标题栏     —— 桌面端它是**唯一**的拖动区，绝不能隐藏
         * ```
         *
         * ⚠️ 用默认的 `Clip.hardEdge`（不是 `antiAlias`）：这里裁的是一条
         *    **直边**（矩形边界），硬边没有任何视觉差异，而 `antiAlias` 会为
         *    每个转场帧多付一次抗锯齿合成。直边用硬边是标准取舍。
         */
        Expanded(child: ClipRect(child: widget.child)),
      ],
    );
  }
}

class _CustomTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const _CustomTitleBar({
    required this.maximized,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
    this.dark = false,
  });

  final bool maximized;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;

  /// 是否用**深色**（播放页沉浸态，见 `titleBarDark` 的说明）
  ///
  /// ★ 用户报的"进播放页闪白条"就是这个：标题栏挂在 Navigator 之外，
  ///   播放页是纯黑，而标题栏是浅色玻璃 → 顶部永远压着一条浅色横条。
  ///
  /// ⚠️ 不能靠"隐藏"解决 —— 桌面端它是**唯一**的拖动区
  ///    （用户为这件事专门纠正过，见 `player_page.dart:602-604`）。
  final bool dark;

  @override
  Size get preferredSize => const Size.fromHeight(40);

  @override
  Widget build(BuildContext context) {
    final colors = AppPalette.of(context);
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★ 播放页：整条标题栏换成**深色**（修用户报的"闪白条"）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么是"变深"而不是"隐藏"
     *
     * 标题栏挂在 `MaterialApp.builder`（Navigator **之外**），
     * 所以它压在所有路由之上。播放页纯黑，标题栏浅色玻璃 → 顶部一条白条。
     *
     * 原版 `TitleBar.vue` 直接 `hidden.value = route.name === 'player'`，
     * 但原版是 WebView，窗口由 Tauri 管，隐藏后**仍可拖**。
     * 我们去掉了系统标题栏，这条就是**唯一**拖动区 ——
     * 隐藏它 = 窗口拖不动，而用户为这件事专门纠正过
     * （`player_page.dart:602-604` 记录了原话）。
     *
     * ⇒ 保留功能（还能拖 / 最小化 / 关闭），只把**颜色**压暗。
     *
     * 实测（`.probe/real_player_capture.py`）：
     * ```text
     * 首页标题栏  #e7eaf2 / #e8ebf3   ← 浅色玻璃（用户看到的"白条"）
     * 播放页目标  接近 #000000         ← 与纯黑播放页融为一体
     * ```
     */
    final Color barFg = dark ? Colors.white70 : colors.foreground;
    final Color barFgStrong = dark ? Colors.white : colors.foreground;
    final Color barBorder =
        dark ? Colors.white.withValues(alpha: 0.10) : colors.border;
    /*
     * 深色态**不用** `GlassContainer` —— 液态玻璃是"折射背后内容"，
     * 背后是纯黑播放页时它只会得到一条**发灰**的带子（正是"丑"的来源）。
     * 直接用纯黑 + 极淡分割线，与播放页无缝。
     */
    if (dark) {
      return SizedBox(
        height: 40,
        child: ColoredBox(
          color: Colors.black,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: barBorder, width: 1)),
            ),
            child: _titleBarRow(barFg, barFgStrong),
          ),
        ),
      );
    }
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 标题栏 = 开源包的 `GlassContainer`（2026-09-24 换掉自绘玻璃）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须换（用户两次打回）
     *
     * 用户原话：
     * > 你看跟液态玻璃有半毛钱关系吗?
     * > 上面那个操作条,还有下面的这个 …
     *
     * 我原来用的是**自己写的**一个 `LiquidGlass`
     *（已删，原在 `lib/ui/widgets/liquid_glass.dart`），它是：
     * ```text
     * ClipRRect > BackdropFilter(blur) > DecoratedBox(白 5%)
     * ```
     * **`BackdropFilter` 只能模糊，做不出液态玻璃的核心「折射」** ——
     * 真液态玻璃要 fragment shader 采样背后纹理、按法线做位移，
     * 让边缘产生放大/扭曲的光学效果。
     * 模糊 + 白色半透明 = **毛玻璃（frosted）**，不是液态玻璃。
     *
     * 所以现在和底栏用**同一个组件、同一套材质**：
     * ```text
     * 底栏    GlassContainer(shape: LiquidRoundedSuperellipse(半高))  → 胶囊
     * 标题栏  GlassContainer(shape: LiquidRoundedRectangle(0))       → 直角条
     * ```
     * 只有**形状**不同（底栏是浮起来的胶囊，标题栏是通栏），
     * 材质完全一致 —— 这正是用户要的"跟底部的一样"。
     *
     * # 形状为什么用 `LiquidRoundedRectangle(borderRadius: 0)`
     *
     * 不能用 `LiquidRoundedSuperellipse` —— 那是 squircle（超椭圆），
     * 即使半径给 0 也会在角上有微妙的连续曲率，通栏会露出背景缝。
     * 标题栏是"贴满窗口顶部的一条"，必须方角。
     *
     * # 那条分割线保留
     *
     * 原版 `TitleBar.vue` 有一条**极淡**的分割线：
     * ```css
     * box-shadow: inset 0 -1px 0 0 var(--divider);
     * ```
     * 原版注释解释了为什么不用实线 `border-bottom`：
     * > 不用 `border-bottom`（那是实线，在浅色主题下像一条分割线）——
     * > 改用极淡的渐变，只在需要时勾出边界
     *
     * 这里用 `colors.border`（forui 语义角色，本身就是"最淡的那一档"）。
     */
    return SizedBox(
      height: 40,
      child: GlassContainer(
        /*
         * ★ 直角通栏 —— 标题栏贴满窗口顶部，不能有圆角
         *（底栏是浮起来的胶囊，那个才用 squircle）
         *
         * ⚠️ 正确类名是 `GlassContainer`（包的 `lib/widgets/containers/`），
         *    不是 `LiquidGlassContainer` —— 我踩过这个坑。
         * ⚠️ 它**没有** `cornerRadius` / `boxShadow` 参数，形状走 `shape:`。
         */
        shape: const LiquidRoundedRectangle(borderRadius: 0),
        // 与底栏同一档（包文档推荐：95% 场景的正确选择）
        quality: GlassQuality.standard,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              // 极淡的分割线（与下方内容区分，但不抢视线）
              bottom: BorderSide(color: barBorder, width: 1),
            ),
          ),
          child: _titleBarRow(barFg, barFgStrong),
        ),
      ),
    );
  }

  /// 标题栏的内容行（浅色 / 深色两种外观**共用**）
  ///
  /// ⚠️ 抽出来是为了保证两种状态下**结构完全一致** ——
  ///    拖动区、三个窗口按钮、图标、标题一个都不能少。
  ///    如果各写一份，很容易在深色态漏掉拖动区，
  ///    那正好会重现用户抱怨过的「播放页无法拖动窗口」。
  Widget _titleBarRow(Color fg, Color fgStrong) {
    return Row(
      children: [
        const SizedBox(width: 14),
        // 应用图标（画一个，不用图片资源）
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            gradient: const LinearGradient(
              colors: [Color(0xFF5B8DEF), Color(0xFF8B5CF6)],
            ),
          ),
          child: const Icon(Icons.play_arrow_rounded,
              size: 13, color: Colors.white),
        ),
        const SizedBox(width: 9),
        Text(
          '源影',
          style: TextStyle(
            fontSize: FontSizes.cap,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: fgStrong,
          ),
        ),

        /*
         * ★ 拖动区
         *
         * 用 `Expanded` 占满剩余空间，让整条标题栏都能拖。
         * `behavior: HitTestBehavior.opaque` 确保空白处也能接收手势
         * （否则只有文字/图标上能拖，手感会很差）。
         *
         * ⚠️ 深色态（播放页）**必须**同样保留 —— 见 `_titleBarRow` 的说明。
         */
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => windowManager.startDragging(),
            onDoubleTap: onToggleMaximize,
            child: const SizedBox.expand(),
          ),
        ),

        _WinButton(
          icon: Icons.remove_rounded,
          onTap: onMinimize,
          // 深色态 hover 用白色微亮，浅色态用主题 secondary
          hoverColor: dark ? Colors.white24 : fg.withValues(alpha: 0.12),
          iconColor: fg,
        ),
        _WinButton(
          icon: maximized
              ? Icons.filter_none_rounded
              : Icons.crop_square_rounded,
          onTap: onToggleMaximize,
          hoverColor: dark ? Colors.white24 : fg.withValues(alpha: 0.12),
          iconColor: fg,
          small: true,
        ),
        _WinButton(
          icon: Icons.close_rounded,
          onTap: onClose,
          // ★ 关闭按钮 hover 变红 —— Windows 的既有习惯
          hoverColor: const Color(0xFFE81123),
          hoverIcon: Colors.white,
          iconColor: fg,
        ),
      ],
    );
  }
}

class _WinButton extends StatefulWidget {
  const _WinButton({
    required this.icon,
    required this.onTap,
    required this.hoverColor,
    this.hoverIcon,
    this.small = false,
    this.iconColor,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color hoverColor;
  final Color? hoverIcon;
  final bool small;

  /// 图标常态色
  ///
  /// ⚠️ 必须有这个参数：深色态（播放页）下若还用
  ///    `AppPalette.of(context).foreground`（深色主题里是**深色**字），
  ///    图标会变成"黑底黑图标"看不见。
  final Color? iconColor;

  @override
  State<_WinButton> createState() => _WinButtonState();
}

class _WinButtonState extends State<_WinButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          width: 46,
          height: 40,
          color: _hover ? widget.hoverColor : Colors.transparent,
          child: Center(
            child: Icon(
              widget.icon,
              size: widget.small ? 12 : 15,
              color: _hover && widget.hoverIcon != null
                  ? widget.hoverIcon
                  : (widget.iconColor ?? AppPalette.of(context).foreground),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  核心启动失败页（任务 AM，2026-09-25 真机实测修复）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个页面替代的是什么
//
// 真机（Android TV）把数据目录指向 App 不可访问的路径，实测日志：
// ```text
// [SHELL] ★ 核心启动失败: PathAccessException: Exists failed,
//         path = '.../tvdata' (OS Error: Permission denied, errno = 13)
// [SHELL] FIRST_FRAME_RENDERED                 ← ★ 界面照常渲染
// [SHELF] 取收藏失败: SourinCoreException(unsupported): 核心尚未启动
// [HOME] 渲染完成: 启用源=0 个（当前=） 分区=0 卡片=0 错误=无
// ```
// 用户看到的是「还没有可用的内容源」—— **一个空应用**，
// 而真相是核心根本没起来。这就是"静默失败"：
// 失败被如实记录了（日志里有），却**从没到达用户**。
//
// # 原版怎么做（`cctv_to_client` 的基准）
//
// 原版是 Tauri，Rust 核心**在进程内**，`lib.rs:3643` 的 `setup()` 里
// 初始化失败时**降级而不是中断**：
// ```rust
// let db = Db::open(&db_path).unwrap_or_else(|e| {
//     log::error!("打开数据库失败 {db_path:?}: {e}，回退到内存库");
//     Db::in_memory().expect("内存库也失败")
// });
// ```
// 即「库打不开 → 用内存库继续跑」，并在日志里说明原因。
// 它的界面因此**总有内容**，不会出现"空得让人困惑"的状态。
//
// ⚠️ 但我们的 FFI 核心**没有**内存库降级路径（`sourin_start` 失败
//    就是没起来），所以不能照抄。**可抄的是它的"如实告知"精神** ——
//    原版对每个失败点都 `log::error!` 且**带上具体路径**
//    （`{db_path:?}`），这正是我们这里缺的那一半。
//
// # 为什么不照抄原版的"降级到内存库"
//
// ```text
// ① 核心没提供这个能力（改 Rust 超出本任务范围，且会引入数据语义问题：
//    内存库意味着用户收藏/历史**看着还在、重启就没了** —— 更糟）
// ② 本项目铁律「实测才算完成」：没有的能力不假装有
// ```
// 所以这里做的是**诚实的失败页**：说清"核心没启动"、
// "哪个目录出的问题"、"下一步能做什么"。
//
// # 为什么不弹 FDialog（forui 的对话框）
//
// 对话框是**可关闭**的，关掉之后用户又回到那个误导性的空态 ——
// 等于把 bug 藏回去。核心没起来是**持续性**故障，界面必须持续如实反映。
// 这与原版 `flashTip` 的用法也不冲突：那个是**瞬时提示**
//（"已切换备用线路"），而这里是**终态**。
//
// # 三个信息层次（对应用户的三个问题）
//
// ```text
// ① 出什么事了      → 标题 + 图标（红色，一眼可见）
// ② 为什么 / 在哪   → coreError 原文 + 数据目录（可复制）
// ③ 我该做什么      → 可操作的下一步
// ```
class _CoreErrorView extends StatelessWidget {
  const _CoreErrorView({required this.message, this.dataDir});

  /// `coreError` 原文（`e.toString()`）
  final String message;

  /// 核心本应使用的数据目录（可能为 null —— 目录没解析出来就失败了）
  final String? dataDir;

  @override
  Widget build(BuildContext context) {
    /*
     * ★ 取色来源：`FTheme.of(context)`（**不是** MaterialApp.builder）
     *
     * 本页在 `ShellPage` 内部 —— 也就是在 `MaterialApp` 的 `home` 里，
     * 而 `FTheme` 是在 `MaterialApp.builder` 中注入的（见那里的长注释）。
     * builder 的返回值**包住了** Navigator，所以路由内的 context
     * **能**看到 `FTheme`。这与"在 builder 里取色必须用
     * `AppTheme.floorColor`"的坑是两回事 —— 那条约束针对的是
     * builder 自己的 context（它在 FTheme **之外**）。
     */
    final colors = AppPalette.of(context);

    /*
     * 用 forui 的 `error` 角色而不是硬编码红色 ——
     * 这样深浅两套主题下都自动是"主题里那个红"。
     * ⚠️ 本项目的对比度事故教训（1.16:1）：错误色必须配
     *    `errorForeground` 或足够暗的底，不能红字压红底。
     *    这里用 `error` 画图标/标题，正文用 `foreground`/`mutedForeground`，
     *    容器底用极低 alpha 的 `error` —— 三者对比度都足够。
     */
    final errorColor = colors.error;

    return SingleChildScrollView(
      clipBehavior: Clip.antiAlias,
      /*
       * ⚠️ 底部内边距必须 ≥ 悬浮底栏的高度 + 间隙，否则内容会被底栏盖住
       *    （`Sp.bottomBarInset` 就是为此存在的，与其它页面一致）。
       */
      padding: EdgeInsets.fromLTRB(
        AppMetrics.contentPadding,
        AppMetrics.homeTopPadding,
        AppMetrics.contentPadding,
        Sp.bottomBarInset,
      ),
      child: Center(
        child: ConstrainedBox(
          // 宽屏下不要让文字拉成一整行（可读性）
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── ① 一眼可见：出什么事了 ──
              Row(
                children: [
                  Icon(Icons.error_outline_rounded, size: 30, color: errorColor),
                  const SizedBox(width: Sp.x3),
                  Expanded(
                    child: Text(
                      '核心未能启动',
                      style: TextStyle(
                        fontSize: FontSizes.lg,
                        fontWeight: FontWeights.semibold,
                        color: errorColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Sp.x3),
              Text(
                /*
                 * ★ 这句话是**修 bug 的核心** ——
                 *
                 * 原来的空态说「还没有可用的内容源」，把"没配置源"
                 * 和"核心挂了"混为一谈。用户会去折腾源（换源/导入插件），
                 * 而真正的问题（数据目录不可访问）永远发现不了。
                 */
                '数据核心没有启动成功，所以暂时读不到任何内容源。'
                '这不是"还没有内容源"——是启动过程出错了。',
                style: TextStyle(
                  fontSize: FontSizes.base,
                  height: 1.5,
                  color: colors.foreground,
                ),
              ),
              const SizedBox(height: Sp.x6),

              // ── ② 在哪出的问题：数据目录（可复制）──
              _ErrCard(
                title: '数据目录',
                /*
                 * 目录可能为空（解析目录这一步本身就失败了）——
                 * 那种情况如实说"没能确定"，不要编一个路径出来。
                 */
                body: (dataDir == null || dataDir!.isEmpty)
                    ? '(未能确定 —— 解析数据目录这一步就失败了)'
                    : dataDir!,
                colors: colors,
                mono: true,
                /*
                 * ★ 只有拿到真实路径时才提供"复制" ——
                 *   复制一个占位文案对用户毫无用处。
                 */
                copyable: (dataDir != null && dataDir!.isNotEmpty),
              ),
              const SizedBox(height: Sp.x4),

              // ── ② 为什么：错误原文 ──
              _ErrCard(
                title: '错误详情',
                body: message,
                colors: colors,
                mono: true,
              ),
              const SizedBox(height: Sp.x6),

              // ── ③ 我该做什么 ──
              Text(
                '可以这样处理',
                style: TextStyle(
                  fontSize: FontSizes.base,
                  fontWeight: FontWeight.w600,
                  color: colors.foreground,
                ),
              ),
              const SizedBox(height: Sp.x3),
              for (final tip in _tips(dataDir))
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.x2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 6, right: Sp.x3),
                        child: Icon(
                          Icons.circle,
                          size: 5,
                          color: colors.mutedForeground,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          tip,
                          style: TextStyle(
                            fontSize: FontSizes.sm,
                            height: 1.55,
                            color: colors.mutedForeground,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: Sp.x5),

              /*
               * ★ 重试按钮（原版的 `flashTip` 带 action 的等价物）
               *
               * 核心的 `sourin_start` 是**幂等**的（Rust 侧：
               * 「已在运行 → 直接返回」），所以重复调用是安全的。
               * 用户修好存储权限后**不必重启应用**。
               */
              OutlinedButton(
                onPressed: _retry,
                child: const Text('重新尝试启动'),
              ),
              const SizedBox(height: Sp.x4),

              /*
               * ★ 日志指引 —— 诊断的最后手段
               *
               * 这一条是给"看不懂上面那些"的用户的：
               * 原版把详细原因都写进日志，我们这里也是
               *（`[SHELL] ★ 核心启动失败` 那一行）。
               */
              Text(
                '完整的技术细节在运行日志里（搜索「核心启动失败」）。',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 按场景给**可操作**的建议
  ///
  /// # 为什么要分场景而不是给一段通用文案
  ///
  /// "请检查数据目录"这种话用户没法执行 —— 他不知道该检查什么。
  /// 而错误文本里其实**已经带着原因**（`Permission denied` /
  /// `Exists failed` / 磁盘满…），把它翻译成一句能动手的话就行。
  static List<String> _tips(String? dataDir) {
    final tips = <String>[
      /*
       * ① 权限类（真机实测最典型：Android TV 外置存储 / Windows 受保护目录）
       */
      if (dataDir != null && dataDir.isNotEmpty)
        '确认应用对上面那个目录有读写权限。'
            '在 Android 上，指向外置存储或其它应用的目录常常没有权限 —— '
            '换回应用内置存储目录通常就能解决。',
      /*
       * ② 路径被文件占用（Windows 上很容易踩：把路径写成了一个已存在的文件）
       *
       * ⚠️ 不要在这里写 Markdown 的 `**粗体**` —— 这是 `Text` 不是
       *    Markdown 渲染器，星号会**原样显示**出来（我第一版就写错了，
       *    截图里能看到字面的 `**已存在的文件**`）。
       *    要强调就用中文引号「」，视觉上同样醒目且不会露馅。
       */
      '确认那个路径不是一个「已存在的文件」，也没有被其它程序占用。',
      /*
       * ③ 环境类
       */
      '如果是磁盘已满或存储被移除，腾出空间 / 恢复存储后重试。',
      /*
       * ④ 兜底：重启
       */
      '如果以上都不适用，重启应用；问题依旧的话请附上日志反馈。',
    ];
    return tips;
  }

  /// 重试：**只重新尝试启动核心**，不重启应用
  ///
  /// # 为什么值得有这个按钮
  ///
  /// 最常见的失败原因（权限、存储被移除、目录被占用）都是
  /// **用户可以在应用外修好**的。没有这个按钮的话，用户修好之后
  /// 只能靠"杀进程重开"—— 而 TV 上杀进程并不直观。
  ///
  /// ⚠️ 这里**不改** `widget.coreError`（那是 `main()` 启动时定下的，
  ///    `ShellPage` 只是消费者）。真正的状态在 `SourinCore` 里，
  ///    所以重试用 `SourinCore.isStarted` 判定结果。
  static Future<void> _retry() async {
    /*
     * 目录用"上次尝试的那个" —— 与错误页显示的是同一个值，
     * 不会出现"显示的路径"和"重试用的路径"不一致。
     */
    final dir = lastDataDirAttempt;
    if (dir == null || dir.isEmpty) {
      debugPrint('[SHELL] 重试失败：没有可用的数据目录');
      return;
    }
    try {
      final r = await SourinCore.startAsync(dir);
      debugPrint('[SHELL] ★ 重试启动成功: $r');
    } catch (e) {
      debugPrint('[SHELL] ★ 重试启动仍失败: $e');
    }
  }
}

/// 错误页里的一块「标签 + 内容」卡片（等宽字体，可复制）
///
/// # 为什么用等宽字体显示路径和错误
///
/// 路径里的 `\`、`/`、空格在比例字体下很难分辨，
/// 而用户可能要**照着抄**这个路径去改权限设置 ——
/// 抄错一个字符就找不到目录了。
class _ErrCard extends StatelessWidget {
  const _ErrCard({
    required this.title,
    required this.body,
    required this.colors,
    this.mono = false,
    this.copyable = false,
  });

  final String title;
  final String body;
  final AppPalette colors;
  final bool mono;

  /// 是否提供「复制」（只有真实路径才值得复制）
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: FontSizes.cap,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                color: colors.mutedForeground,
              ),
            ),
            if (copyable) ...[
              const Spacer(),
              /*
               * ★ 复制按钮 —— TV 上用不了，但桌面/手机上很实用。
               *   不隐藏它：TV 上多一个不可聚焦的按钮不影响遥控操作
               *  （空间导航只收真焦点控件）。
               */
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: body));
                  debugPrint('[SHELL] 已复制到剪贴板: $body');
                },
                child: const Text('复制'),
              ),
            ],
          ],
        ),
        const SizedBox(height: Sp.x1),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Sp.x3),
          decoration: BoxDecoration(
            // 极低 alpha —— 只是"这是一块代码/路径"的视觉暗示，不喧宾夺主
            color: colors.muted.withValues(alpha: 0.5),
            borderRadius: Radii.rMd,
            border: Border.all(
              color: colors.border.withValues(alpha: 0.6),
            ),
          ),
          child: SelectableText(
            body,
            style: TextStyle(
              fontSize: FontSizes.sm,
              height: 1.45,
              color: colors.foreground,
              /*
               * ⚠️ 等宽字族名要按平台给：Windows 是 Consolas，
               *    Android 是 monospace。给错的话会**静默回退**成
               *    默认字体（Flutter 不会报错），等于白设。
               */
              fontFamily: mono
                  ? (Platform.isWindows ? 'Consolas' : 'monospace')
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  底栏（5 项，顺序与原版一致）
// ═══════════════════════════════════════════════════════════════════════
//
// ★ TV 适配（2026-09-22）
//
// # 这一步解决的是契约里记录的**真机 bug**
//
// 原版注释（`src/App.vue` L469–477，真机实测）：
// ```text
// 「发现 / 直播 / 追更 / 搜索 / 设置」，TV 上等于困死在一个页面。
// ```
// 含义：应用在 TV 上能启动、能显示，但**用户切不了页面** ——
// 没有鼠标，而底栏只响应点击。整个应用等于不可用。
//
// # Flutter 侧的解法：显式处理方向键
//
// ```text
// · Focus 包住底栏，onKeyEvent 里判断 ←/→ → 直接切 tab
// · 每个 tab 是 FocusableActionDetector → 确认键 / 悬停 / 焦点环
// ```
// ⚠️ **不要**指望 `FocusTraversalGroup` 让方向键移动焦点 ——
//    它只响应 Tab/Shift+Tab（实测：按 → 十次 tab 不动）。
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.current,
    required this.unread,
    required this.colors,
    required this.onSelect,
  });

  final AppTab current;
  final int unread;
  final AppPalette colors;
  final ValueChanged<AppTab> onSelect;

  @override
  Widget build(BuildContext context) {
    /*
     * ★ TV 焦点导航：Focus + onKeyEvent 显式处理方向键（2026-09-22）
     *
     * # 第一版为什么失败（实测 PASS=5 FAIL=3）
     *
     * 我原本用的是
     * ```dart
     * FocusTraversalGroup(policy: ReadingOrderTraversalPolicy())
     * ```
     * 以为方向键会自动在 tab 之间移动焦点。**实测按 → 十次，
     * tab 一直停在 home** —— 与契约里记录的那个真机 bug 表现一模一样。
     *
     * 原因：`ReadingOrderTraversalPolicy` 只响应 **Tab / Shift+Tab**，
     * 方向键默认**不参与遍历**。方向键要走 `DirectionalFocusIntent`，
     * 而那个 action 依赖 `WidgetsApp` 注入的默认 shortcuts 映射 ——
     * 在自绘的底栏里没有这层保障。
     *
     * # 最终方案：按键处理**上移到 shell 层级**
     *
     * 底栏这里只负责**渲染**，不接按键 —— 原因见 `_ShellPageState.build`
     * 里那段注释（按键只沿主焦点的祖先链冒泡，底栏与主焦点是兄弟关系，
     * 收不到事件）。
     *
     * 焦点环仍然保留在每个 item 上 —— 确认键 / 悬停各走自己的路径。
     */
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 悬浮液态玻璃底栏（2026-09-24 用户指出「悬浮底栏没做」）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 原版是什么样（`liquid-glass.css` 的 `.tabbar`）
     *
     * ```css
     * .tabbar {
     *   position: fixed;
     *   left: 50%;
     *   bottom: calc(var(--tabbar-bottom) + var(--safe-bottom));
     *   transform: translateX(-50%);       /* ★ 居中 */
     *   width: max-content;                /* ★ 内容宽度，不是满宽 */
     *   max-width: calc(100vw - var(--sp-8));
     *   border-radius: var(--r-full);      /* ★ 全圆角 */
     *   padding: 7px;
     *
     *   --lg-tint: rgb(255 255 255 / 0.06);
     *   --lg-blur: 18px;
     *   --lg-shadow: 0 16px 44px -12px rgb(0 0 0 / 0.62), ...;
     * }
     * ```
     * 原版注释还记录了一次调整：
     * > ★ 2026-09-15 调整：blur 30px → 18px、tint 0.085 → 0.06
     * > 实测 30px 会把背景糊成一片纯色块，底栏看起来像**乳白塑料**
     * > 而不是玻璃。降到 18px 后仍能看见背后的海报结构，
     * > 「透」的观感明显更强
     *
     * # 我之前做成了什么
     *
     * ```text
     * Container(height: 58, border: 顶边实线) + Row(Expanded × 5)
     * ```
     * 即**满宽 + 贴底 + 实心 + 顶边线性分割** —— 一条"普通应用底栏"，
     * 与"液态玻璃悬浮药丸"完全是两种东西。
     *
     * # 现在
     *
     * ```text
     * 外层  透明容器，只负责留出悬浮的空间（底部 12px 间隙）
     * 内层  居中 + width: max-content（内容宽度）+ 全圆角 + 玻璃 + 外投影
     * ```
     *
     * ⚠️ 与空间导航的契约（`spatial_nav.dart`）：
     *    底栏仍然包在 `BottomBarMarker` 里，且 `↓` 到这里的判定
     *    靠的是**结构标记**不是几何位置 —— 悬浮后底栏不再贴屏幕底边，
     *    如果当初用"矩形在屏幕下方 15%"那种几何判据就会**失效**。
     *    （那轮已经改成结构判据了，这里正好验证那个决定的正确性。）
     */
    final barHeight = Device.isTv ? 72.0 : 58.0;
    /*
     * ★ tab 宽度**随可用宽度收缩**（2026-09-30 修）
     *
     * 原来这里是常量（`Device.isTv ? 152 : 118`）—— 手机逻辑宽 411.43、
     * 真正能给 tab 用的只有 `411.43 − 72 = 339.43`，而 5 × 118 = 590
     * ⇒ 第 4/5 项（搜索 / 设置）被画到屏幕外（详见 `_tabWidthFor`）。
     *
     * 药丸（下面 `AnimatedPositioned`）与每个 `SizedBox` 必须用
     * **同一个** `tabWidth` 变量，否则药丸会和图标错位。
     */
    final tabWidth = _tabWidthFor(MediaQuery.of(context).size.width);
    // 药丸配色（药丸 + 文字 + 阴影三者成对取自同一个调色板）
    final pill = _BottomPalette.of(context);

    return Padding(
      /*
       * 悬浮间隙：底栏**不贴屏幕底边**，留出一圈让投影可见 ——
       * 这就是"悬浮"的视觉来源。原版用
       * `bottom: calc(var(--tabbar-bottom) + var(--safe-bottom))`。
       *
       * ⚠️ 2026-10-05：这里**只**负责 `--tabbar-bottom`（12 / 18dp）。
       *    原版公式的另一半 `--safe-bottom` 补在**外层** ——
       *    `Positioned(bottom: MediaQuery.paddingOf(context).bottom)`
       *    （`shell.dart` 的底栏块）。★ 别在这里再加一次，会双倍。
       */
      padding: EdgeInsets.only(
        bottom: Device.isTv ? 18 : 12,
        left: Sp.x6,
        right: Sp.x6,
      ),
      child: Center(
        // ★ width: max-content —— 内容多宽就多宽，不撑满
        child: IntrinsicWidth(
          child: ConstrainedBox(
            // 原版 `max-width: calc(100vw - var(--sp-8))`
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width - Sp.x8,
            ),
            child: SizedBox(
              height: barHeight,
              /*
               * ══════════════════════════════════════════════════════════
               * ★★★ 用**开源包的真液态玻璃**（2026-09-24 用户要求）
               * ══════════════════════════════════════════════════════════
               *
               * 用户原话：
               * > 你可以参考github开源的项目做,不要硬自己实现
               *
               * # 我之前自己撸的那套差在哪
               *
               * ```dart
               * ClipRRect > BackdropFilter(blur) > DecoratedBox(白 6%)
               * ```
               * `BackdropFilter` **只能模糊**，做不出液态玻璃的核心
               * —— **折射（refraction）**。真正的液态玻璃是
               * fragment shader 采样背后纹理、按法线做**位移**，
               * 让边缘产生"放大/扭曲"的光学效果。那是 shader 的活。
               *
               * 所以用户说"跟液态玻璃有半毛钱关系吗"是对的：
               * 模糊 + 白色半透明 = **毛玻璃（frosted）**，不是液态玻璃。
               *
               * # 这个包做了什么
               *
               * ```text
               * Impeller  → 两遍管线：blur pass + shader pass（折射、
               *              边缘光照、玻璃染色、色差）
               * Skia/Web  → 单遍 lightweight shader
               * ```
               * 在 Windows 上走 Impeller(ANGLE) 的轻量 2D shader。
               *
               * `LiquidGlassContainer` 是它的低层积木
               * （`GlassCard` 是高层封装，但那个带自己的内边距/语义，
               * 我们要的是"纯粹的玻璃底板 + 自己的 Row"）。
               */
              child: GlassContainer(
                /*
                 * ★ 全圆角药丸 —— 原版 `border-radius: var(--r-full)`
                 *
                 * 用 `LiquidRoundedSuperellipse`（超椭圆 / squircle）
                 * 而不是普通圆角矩形 —— 那正是 iOS 26 液态玻璃的轮廓语言。
                 * 半径给足（= 高度一半）就是胶囊形。
                 */
                shape: LiquidRoundedSuperellipse(
                  borderRadius: barHeight / 2,
                ),
                /*
                 * `GlassQuality.standard` 是包文档推荐的默认档：
                 * > The right choice for 95% of use cases.
                 * > Works on every platform with iOS 26-accurate glass.
                 *
                 * ⚠️ **不用** `premium` —— 那个是 Impeller-only，
                 *    且包文档明确说"Use Premium only for static,
                 *    non-scrolling surfaces"，底栏下面有滚动内容。
                 */
                quality: GlassQuality.standard,
                /*
                 * ══════════════════════════════════════════════════════════
                 * ★★★ 用 Stack 加"滑动选中药丸"（2026-09-24 用户指出「没有选中效果」）
                 * ══════════════════════════════════════════════════════════
                 *
                 * # 原版的核心认知（`liquid-glass.css` 的注释）
                 *
                 * > 关键认知：**「选中」的主信号是底下那个药丸，不是文字亮度**。
                 * > 所以悬停只需轻微提亮；跳到与选中同亮度就会喧宾夺主。
                 *
                 * 原版还有个**真 bug 记录**：
                 * > 原写法把 hover 与 is-active 都设成 `--tab-fg-strong`：
                 * > `两者渲染完全一样`，于是鼠标划过哪个 tab，哪个就像「已选中」
                 * > —— 用户分不清自己在哪一页
                 *
                 * # 我之前漏了什么
                 *
                 * 只做了"选中 → 图标文字变亮"，**完全没有药丸**。
                 * 于是：
                 * ```text
                 * 悬停   = 变亮 → 看起来像选中
                 * 选中   = 变亮 → 和悬停一样
                 * ```
                 * 正是原版明确记录过的那个 bug。用户说"没有选中效果"就是这个。
                 *
                 * # 三层结构
                 * ```text
                 * Stack
                 *  ├ AnimatedPositioned  选中药丸（滑过去，带 spring 曲线）
                 *  └ Row                 五个 tab（文字/图标在上层）
                 * ```
                 */
                child: Stack(
                children: [
                  // ── 滑动选中药丸 ──
                  AnimatedPositioned(
                    /*
                     * 原版：
                     * ```css
                     * transition: transform var(--dur-slow) var(--ease-spring),
                     *             width     var(--dur-slow) var(--ease-spring);
                     * ```
                     * `--ease-spring` —— 药丸滑动用**弹性曲线**，
                     * 这是"液态"手感的一部分（不是 linear/ease）。
                     */
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutBack,
                    /*
                     * ★ 药丸的位置与宽度必须与每个 `SizedBox` **同源**
                     *   —— 都用上面按窗口宽算出的 `tabWidth`。
                     *   窄屏收缩后若还用常量算，药丸会和图标错位。
                     */
                    left: _pillLeft(current, tabWidth),
                    top: 6,
                    bottom: 6,
                    width: tabWidth,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        /*
                         * ══════════════════════════════════════════════════
                         * ★★★ 选中药丸**必须按主题分支**（bug ③ 修复）
                         * ══════════════════════════════════════════════════
                         *
                         * # 之前是什么样（用户报的"黑色模式下有问题"）
                         *
                         * 这里**硬编码**了浅色那一套值，没有任何主题分支：
                         * ```dart
                         * colors: [
                         *   Colors.white.withValues(alpha: 0.96),
                         *   Colors.white.withValues(alpha: 0.80),
                         * ],
                         * ```
                         * 深色主题下就是**白药丸 + `#FAFAFA` 文字 = 白底白字**，
                         * 用户看不出当前选中在哪一页。
                         *
                         * 这个 bug 的全部特征是「**不报错**」：
                         * 编译过、analyze 0 error、能跑起来，只有量像素或看截图
                         * 才发现（实测深色底栏药丸 `(250,250,250)`，而同屏
                         * 「我的」分段控件是 `(59,59,59)`）。
                         *
                         * # 原版是**两套值**，不是一个值配两个底
                         *
                         * ```css
                         * 深色（src/design/tokens.css:293，默认主题）
                         * --tab-pill-bg: linear-gradient(180deg,
                         *                  rgb(255 255 255 / 0.19),
                         *                  rgb(255 255 255 / 0.10));
                         *
                         * 浅色（src/design/theme-light.css:65）
                         * --tab-pill-bg: linear-gradient(180deg,
                         *                  rgb(255 255 255 / 0.96),
                         *                  rgb(255 255 255 / 0.80));
                         * ```
                         * 深色那套合成到 `#0A0A0A` 上约 `(57,57,57)` ——
                         * 与「我的」分段控件的 `(59,59,59)` 基本一致，
                         * 那正是原版"对齐已有同类控件"的设计意图
                         * （`tokens.css:325-330` 的注释：做新的"选中药丸"之前
                         *   应该先找**已有的同类控件**对齐，而不是自己发明材质）。
                         *
                         * ⚠️ **不能用语义角色去推这个值**。
                         *    `colors.foreground` 在浅色下是近黑、深色下是近白，
                         *    拿它当"提亮层"会在浅色主题下画出**暗药丸**
                         *    （`source_bar.dart` 那边正是这么翻车的）。
                         *    药丸是"白色叠多少"这个与主题无关的原始 alpha，
                         *    forui 没有对应角色 —— 所以只能显式分支。
                         *
                         * ★ 参照物：`lib/ui/widgets/my_shelf.dart` 的
                         *   `_ShelfPalette.of(isLight)` —— 它是这个项目里
                         *   **唯一做对了**的药丸样板（药丸 + 文字 + 阴影
                         *   三者**成对**定义，不散落 `isLight ? : `）。
                         */
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: pill.pillGradient,
                        ),
                        borderRadius: BorderRadius.circular(barHeight / 2),
                        /*
                         * 原版 `--tab-pill-shadow`（两套主题各一份）：
                         * ```css
                         * 深色 tokens.css:294
                         *   inset 0 1px 0 rgb(255 255 255 / 0.28),
                         *   0 2px 10px -2px rgb(0 0 0 / 0.34)
                         * 浅色 theme-light.css:66
                         *   inset 0 1px 0 rgb(255 255 255 / 1),
                         *   0 2px 8px -2px rgb(16 18 26 / 0.16)
                         * ```
                         * 内顶高光 + 下方淡投影 = 药丸"浮"在玻璃上。
                         * ⚠️ 阴影也必须跟着主题走：深色下药丸自己就很淡，
                         *    投影不给足就"贴"在玻璃上没有层次；浅色下投影过重
                         *    会像脏边。
                         */
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black
                                .withValues(alpha: pill.pillShadow),
                            blurRadius: 8,
                            spreadRadius: -2,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ── 五个 tab ──
                  Row(
                    mainAxisSize: MainAxisSize.min,
                  children: [
                    /*
                     * ⚠️ 每个 item 必须有**显式宽度**（2026-09-24 实测踩到）
                     *
                     * 第一版直接 `_BottomItem` 裸放进 `MainAxisSize.min` 的
                     * Row 里，配合外层 `IntrinsicWidth` —— 结果五个 tab
                     * **挤成一团**（截图里图标和文字叠在一起）。
                     *
                     * 原因：`_BottomItem` 内部是「图标 + 文字」的 Column，
                     * 在 `MainAxisSize.min` 下它自己也不知道该多宽，
                     * `IntrinsicWidth` 又只按"最小内在宽度"算 ——
                     * 三者互相谦让，最后谁都没拿到宽度。
                     *
                     * 解法：给每个 tab 一个**明确宽度**。
                     * 原版是 CSS `width: max-content` + `padding: 7px` +
                     * `gap: 2px`，每个 tab 由内容自然撑开；
                     * Flutter 里显式给宽度最直接、也最可预测。
                     */
                    for (final t in AppTab.values)
                      SizedBox(
                        width: tabWidth,
                        child: _BottomItem(
                          tab: t,
                          active: t == current,
                          badge: t == AppTab.follow ? unread : 0,
                          colors: colors,
                          onTap: () => onSelect(t),
                        ),
                      ),
                  ],
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

// ══════════════════════════════════════════════════════════════════════════
//  ★★ task-11 A1（2026-10-04）—— TV 字号 ×1.25 的**唯一**接线点
// ══════════════════════════════════════════════════════════════════════════
//
// # Owner 要求
// 「都按照推荐的做」⇒ A1（TV 字号 ×1.25）落地。
// 原版 `device.ts` 在 leanback 设备上把整套 `--fs-*` 调大一档
// （cap 12→14、base 16→20…）。本项目里那个系数**早就定义了**
// （`lib/core/device.dart:192` / `lib/ui/tokens.dart:222`），
// 但**从来没有被接上** —— 是死代码。
//
// # 为什么挂在 `MaterialApp.builder`（而不是 `Device` 里）
//
// Flutter 里「整套字号放大」只有一个正规入口：`MediaQuery.textScaler`。
// 而 `MediaQuery` 由 `View` → `MediaQuery.fromView` 在**应用最外层**建立
// （SDK `widgets/view.dart:275`），所以只能在它**下面**覆写；
// `MaterialApp.builder` 正好在 Navigator 外面、又在 View 里面 —— 唯一的位置。
//
// # ★★ 条件必须同时看「平台」与「设备」（2026-10-04 修的一个真缺陷）
//
// 第一版这里只判**平台**（`android` / `fuchsia` ⇒ ×1.25）——
// 于是**安卓手机也被整体放大**：字号大了一档，而放大字号的两条理由
// （10 英尺原则 / 沙发距离）在手机上一条都不成立。
//
// 平台只是**必要**条件。安卓上既可能是 TV 也可能是手机，区分它们的是
// `Device.isTv`（`sourin/device` 通道读 `android.software.leanback` 与
// `FEATURE_TOUCHSCREEN`，见 `lib/core/device.dart:273-301`）。
// ⇒ 条件 = 平台 ∈ {android, fuchsia} **且** `Device.isTv`。
//
// 第一版注释当时列了两条「不敢用 `Device.isTv`」的理由，**两条都已不成立**：
// 1. 「异步填的、首帧拿不到」—— `Device.init()` 在 `runApp` **之前** await
//    完成（本文件 `main()` 里那句 `await Device.init();`）⇒ TV 上首帧
//    `Device.isTv` 已经是 true，不会闪。
// 2. 「测试覆盖不到」—— `flutter test` 里 `defaultTargetPlatform` 被**强制**
//    成 `TargetPlatform.android`（SDK `foundation/_platform_io.dart` 的
//    `FLUTTER_TEST` 分支）⇒ 只判平台的写法在测试里**恒**走放大分支；
//    加上 `Device.isTv` 这道门后，`Device.overrideKind(DeviceKind.tv)`
//    才是放大 ⇒ 这条分支反而**变成可断言的了**。
//
// ⚠️ 判定**只此一处**（`AppMetrics.effectiveTextScale`）—— 本文件只负责取用。
//
// # 与 Windows 的关系（重要）
//
// `defaultTargetPlatform` 在 **Windows 上也是 `TargetPlatform.windows`**
// （不是 `android`）⇒ 桌面端恒为 1.0，**一个像素都不会变**。
// 这正是 A1 要的：只放大 TV，不动桌面。
//
// # 为什么用 `_TextScaleHost` 而不是直接写 `MediaQuery(…)`
//
// 因为要**读**（`MediaQuery.maybeOf`）才能**覆写**一个字段而保留其余
// （padding / size / brightness …）。把它写成一个带 `BuildContext` 的
// widget 比在 `builder:` 里塞一段内联代码干净，也让「只挂一处」这条
// 约定（见 `remote_bridge.dart` 的警告）有唯一的落点。
class _TextScaleHost extends StatelessWidget {
  const _TextScaleHost({required this.child});

  final Widget child;

  /// 这台设备**实际**该用的字号系数
  ///
  /// ⚠️ 这里**只取用，不判定** —— 判定在 `AppMetrics.effectiveTextScale`
  ///    （唯一真源）。第一版在这里自己判平台，结果安卓手机也被 ×1.25。
  ///
  /// ⚠️ 用 `MediaQuery.maybeOf`（不是 `of`）：`of` 在没有 MediaQuery
  ///    祖先时**抛异常**，而 `builder` 的 context 处于最外层，宁可兜底 1.0。
  static double scaleOf(BuildContext context) {
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return 1.0;
    return AppMetrics.effectiveTextScale;
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return child;
    final want = scaleOf(context);
    if (want == 1.0) return child;
    // ★ 挂上去的值必须是 `want` 本身，不能写死 `const TextScaler.linear(
    //   AppMetrics.tvScale)` —— 否则「判定的值」与「生效的值」是两个真源，
    //   迟早分叉（第一版就是这个形状：判定看平台，挂的是 tvScale 常量）。
    return MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.linear(want)),
      child: child,
    );
  }
}

/// tab 宽度的**上限**（宽屏时的值 —— Owner 已验收的外观，不许变）
///
/// ```text
/// 桌面 1280 / TV 960 等宽屏 → 上限命中 ⇒ 与改前逐像素相同（无回归）
/// ```
double get _tabWidthMax => Device.isTv ? 152 : 118;

/// 单个 tab 的**可读下限**
///
/// 图标 21 + 两字标签 ≈ 21 ⇒ 44 是"还能看"的底线。
/// 存在的意义：不许靠"把 tab 压成 1px"来假装 5 项都放得下。
const double _tabWidthMin = 44;

/// 一行 5 个 tab 的横向**净损失**（窗口宽 → 真正能给 Row 用的宽）
///
/// ```text
/// 本文件 _BottomBar 的 Padding   Sp.x6/side × 2     = 48
/// ```
///
/// ⚠️ 用 `Sp` 组合而**不写 48** —— 这个数改了这里要跟着改，
///    写死数字就会悄悄失真（这个项目踩过：常量散落各处只改一处）。
///
/// ⚠️ 这个数是**实测反解**出来的，不是猜的：
///    · 手机 1080×2400 @420dpi（逻辑 411.43）像素反解面板
///      左边界 `35.86`、宽 `339.71`；本文件按 `Sp.x6` 与 `W − 72`
///      算出的是 **左 36.0 / 宽 339.43** —— 两个**独立仪器**同值
///      （这是 `childPad: false` **之前**的读数 ⇒ 那 12/side 确实存在）
///
/// ★★ 2026-10-03 修：**原来这里是 72，多算了 forui 的 12/side**
/// ```text
///   原来  forui FScaffold.childPadding  horizontal 12/side = 24
///         本文件 _BottomBar 的 Padding                 = 48
///                                          合计       = 72
///   现在  `AppScaffold(childPad: false)` 关掉 forui 那 24
///         ⇒ 只剩我们自己的 48
/// ```
/// 那 12/side 来自 forui 的两个默认值（不是我们的代码）：
///    `forui widgets/scaffold.dart:105-107`  `if (childPad) Padding(childPadding)`
///    `forui widgets/scaffold.dart:191-202`
///      `childPadding = style.pagePadding.copyWith(top: 0, bottom: 0)`
///    `forui theme/style.dart:37`
///      `pagePadding = .symmetric(vertical: 8, horizontal: 12)`
/// 修在**真实外壳**的 `AppScaffold(childPad: false)`（见本文件上方那段
/// 长注释）—— 只改外壳，`Layout` 的数值与语义一个都不动。
///
/// ⚠️ 若这里漏改，窄屏下 `usable` 会**少算 24**：手机 411.43 下
///    `_tabWidthFor` 拿到 363.43/5 = 72.69，而真实可用是
///    `411.43 − 48 = 363.43` ⇒ 药丸与 `SizedBox(width:)` 同源，
///    两者一起偏 ⇒ 5 个 tab **画到面板外**。
const double _kTabRowHorizontalLoss = Sp.x6 * 2;

/// 单个 tab 的宽度（药丸滑动要用同一个值算位置）
///
/// ★ 2026-09-30 修：这里**原来是与可用宽度无关的常量**
///   （`Device.isTv ? 152 : 118`）。
///
/// # 缺陷（Owner 手机实测）
///
/// 手机（1080×2400 @420dpi ⇒ DPR 2.625 ⇒ 逻辑宽 **411.43**）底栏只画出
/// **3 项**：发现 / 直播 / 追更 —— 「搜索」「设置」被画到屏幕外，
/// 用户**根本没有这两个入口**。
///
/// 根因：`5 × 118 = 590` 远超可用宽（`411.43 − 72 = 339.43`）；
/// `Row(MainAxisSize.min)` 被约束夹到上限后**仍然从 x=0 往外画**，
/// 第 4/5 项落到屏外 —— 而 `RenderFlex` 默认 `Clip.none`
/// ⇒ **不裁剪、不报错、release 下也不打印 overflow**（所以一直没被发现）。
///
/// # 修法
///
/// 「装得下就保持原样，装不下就等分」，上限夹住：
/// ```text
/// 上限 _tabWidthMax   宽屏立刻命中 ⇒ 与改前逐像素相同（零回归）
/// 下限 _tabWidthMin   只在够得着的时候才用它当"舒适线"
/// ```
/// 只有窗口宽 > `5×118 + 72 = 662` 时上限才不命中 ⇒ 宽屏完全不受影响。
///
/// # ★ 2026-09-30 二次修：下限**自己会把同一个缺陷造回来**
///
/// 第一版写成 `fit.clamp(_tabWidthMin, _tabWidthMax)`。缺陷在**更窄**处复现：
/// 下限一旦生效，`5 × 44 = 220` 就**超过**可用宽 `W − 72` ⇒ 第 4/5 项
/// 又一次被画到屏外，而且 `RenderFlex` 是 `Clip.none`
/// ⇒ **同样不裁剪、不报错、release 不打印** —— 与上面那个缺陷一模一样。
///
/// 阈值：`5 × 44 + 72 = 292` ⇒ **任何逻辑宽 < 292 都会溢出**：
/// ```text
/// W=291 → 超 1.0px   W=280 → 超 12.0px   W=240 → 超 52.0px
/// W=205 → 超 87.0px  W=150 → 超 142.0px  W=292 → 恰好 0
/// ```
///
/// # ★ 哪一端真的碰得到（逐条查过，别照抄"窗口能拖窄"这种话）
/// ```text
/// Windows  不可达 —— `:346 minimumSize: Size(900, 600)`（= 原版 Tauri 的值）
///          ⇒ 底栏所在的这个 shell 永远 ≥ 900 宽。
///          （`core\pip.dart:224` 确实把下限降到 Size.zero，但那是
///           **画中画**路径：`:79 _pipWidth = 420`、且 PiP 里挂的是播放页
///           不是 shell ⇒ 底栏不参与。）
/// Android  可 ✓ —— 清单 `android\app\src\main\AndroidManifest.xml:83`
///          `android:resizeableActivity="true"` ⇒ 分屏 / 自由窗口成立；
///          `:79 configChanges` 已含 `screenSize|smallestScreenSize` ⇒
///          不重建 Activity，只是 FlutterView 变窄 ⇒ MediaQuery 跟着变。
///          手机 411.43 对半分 ≈ **205**。
/// ```
/// ⇒ 判据覆盖到 205 不是"追一个生产上不可达的尺寸"（那种错本项目犯过，
///    见 `:335-337` 的自我批评），而是**Android 分屏的真实宽度**。
///
/// # 判据：极窄时**可见性优先于舒适下限**
///
/// 44 是"图标 21 + 两字标签 ≈ 21，还能看"的**舒适**线，不是硬约束。
/// 一个被画到屏外的 tab 不是"小"，是**入口不存在**（这正是 Owner 报的
/// 那个缺陷）。所以下限只允许在**不引起溢出**时才起作用：
/// `fit < 44` ⇒ 直接返回 `fit`。
///
/// 代价（照实记）：W=205 时每项 26.6px —— 已经很挤，图标和两字标签
/// 都放不下，但 5 个入口都在、都点得到。真到那种宽度，"挤"是唯一
/// 诚实的选择；把第 5 项画到屏外才是真的坏。
///
/// ⚠️ 必须与 `SizedBox(width:)` 和 `_pillLeft` 用**同一个来源** ——
///    写两处的话改一处就会错位（药丸和图标对不上）。
double _tabWidthFor(double windowWidth) {
  final usable = windowWidth - _kTabRowHorizontalLoss;
  final fit = usable / AppTab.values.length;
  if (fit >= _tabWidthMin) return fit < _tabWidthMax ? fit : _tabWidthMax;
  // 极窄：让位给可见性。绝不返回高于 fit 的值，否则就会溢出。
  // 夹在 0 以上 —— 负宽会让 SizedBox 直接断言炸掉。
  return fit > 0 ? fit : 0;
}

/// 选中药丸的左偏移
///
/// 原版是 JS 量 DOM 位置；这里是纯算术（等宽 tab，位置 = 序号 × 宽度）。
/// 用算术更稳 —— 不依赖布局完成的时机。
///
/// ⚠️ 形参是 `tabWidth` **不是** `barHeight` —— 药丸的平移量只由 tab 宽度
///    决定。两者必须与 `SizedBox(width:)` 同源，否则窄屏收缩后药丸会跑偏。
double _pillLeft(AppTab current, double tabWidth) =>
    current.index * tabWidth;

class _BottomItem extends StatefulWidget {
  const _BottomItem({
    required this.tab,
    required this.active,
    required this.badge,
    required this.colors,
    required this.onTap,
  });

  final AppTab tab;
  final bool active;
  final int badge;
  final AppPalette colors;
  final VoidCallback onTap;

  @override
  State<_BottomItem> createState() => _BottomItemState();
}

class _BottomItemState extends State<_BottomItem> {
  bool _hover = false;

  /// ★ 是否拥有焦点（TV 上这个才是关键状态）
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.active;
    final pill = _BottomPalette.of(context);

    /*
     * 颜色优先级：焦点 > 悬停 > 激活 > 默认
     *
     * 为什么焦点排在激活之上：TV 上用户需要知道"我按确认会去哪"，
     * 那个位置必须最显眼 —— 哪怕它已经是当前页。
     *
     * ★ 但**激活**那一档不能再用 `colors.foreground`（2026-09-24，bug ③）
     *
     * `colors.foreground` 是"背景色上的前景色"：
     * ```text
     * 深色  #FAFAFA（近白）
     * 浅色  #0A0A0A（近黑）
     * ```
     * 而选中的那个 tab 的文字/图标**压在药丸上**，药丸是"白色叠多少"
     * 这个与主题无关的 alpha 算出来的：浅色下药丸≈纯白、深色下≈`(57,57,57)`。
     * 于是浅色主题下 `foreground`(#0A0A0A) 恰好可用，深色主题下
     * `foreground`(#FAFAFA) 也恰好可用 —— 看着"两套都对"，
     * **但那只是巧合**：真正决定它的是**药丸的明暗**，不是主题的明暗。
     *
     * 修 bug ③ 时如果只换药丸渐变、不动这里，浅色主题就会变成
     * 「白药丸 + `colors.foreground`」——在**浅色**下 `foreground` 确实
     * 是近黑，还能看；但一旦哪天主题映射改成浅色 `foreground` = 近白，
     * 就立刻重现同一个白底白字。所以这里显式取 `--tab-fg-strong`
     * （浅 `rgb(16 18 26 / .94)` / 深 `#ffffff`），与药丸**成对**定义，
     * 让"药丸亮 → 字暗 / 药丸暗 → 字亮"这条约束写在代码里。
     *
     * ⚠️ 焦点/悬停态**不**用药丸色：那两种状态下文字在**玻璃**上，
     *    不在药丸上，用 `colors.*`（跟随主题）才是对的。
     */
    final color = _focused
        ? widget.colors.foreground
        : on
            ? pill.activeForeground
            : (_hover ? widget.colors.foreground : widget.colors.mutedForeground);

    // 焦点态的背景与描边（TV 上可见性全靠它）
    final showFocus = _focused && Device.needsFocusRing;

    /*
     * ★ FocusableActionDetector 而不是 GestureDetector
     *
     * 它同时提供三件事：
     * ```text
     * ① onFocusChange  → 知道何时获得/失去焦点
     * ② actions        → 把「确认键」映射到激活行为
     * ③ shortcuts      → 自定义按键（方向键由外层遍历策略处理）
     * ```
     * 用 GestureDetector 的话，遥控器的「确认」不产生 onTap
     * —— 那是触摸/鼠标事件，遥控器走的是按键通道。
     */
    return FocusableActionDetector(
      // 当前 tab 初始就拿到焦点，否则用户按方向键毫无反应
      autofocus: on,
      /*
       * ★★ 必须用 `onFocusChange`，不能用 `onShowFocusHighlight`
       *
       * `onShowFocusHighlight` 只在「高亮模式」（`highlightMode`）下
       * 触发 —— 那是**桌面键盘 Tab** 那条路。遥控器 / 手柄的焦点**不产生
       * 高亮模式** ⇒ TV 上 `_focused` 永远是 false ⇒ `showFocus` 恒 false
       * ⇒ 焦点环一次都画不出来（android-tv 在真机上量到的就是这样：
       *   按方向键焦点确实在移动，但底栏一直是「未选中」的样子）。
       *
       * `onFocusChange` 两种输入都会回调，是这里唯一正确的信号源。
       */
      onFocusChange: (v) => setState(() => _focused = v),
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      /*
       * 把「确认」与「点击」都映射到同一行为。
       *
       * `ActivateIntent` 是 Flutter 对 Enter / 空格 / 遥控器确认键的
       * 统一抽象 —— 映射它就能覆盖遥控器，不用逐个键判断。
       */
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      mouseCursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            // 焦点态：淡色背景 + 底部粗线（电视上远距离也能看见）
            color: showFocus
                ? widget.colors.foreground.withValues(alpha: 0.10)
                : Colors.transparent,
            border: showFocus
                ? Border(
                    bottom: BorderSide(
                      color: widget.colors.foreground,
                      width: 3,
                    ),
                  )
                : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    widget.tab.icon(active: on),
                    size: _focused ? 24 : 21, // 焦点态略放大
                    color: color,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.tab.label,
                    style: TextStyle(
                      fontSize: _focused ? 12 : 10.5,
                      color: color,
                      fontWeight:
                          on || _focused ? FontWeight.w600 : FontWeights.regular,
                    ),
                  ),
                ],
              ),
              // 未读小红点（原版 badge）
              if (widget.badge > 0)
                Positioned(
                  top: 8,
                  right: 34,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    constraints: const BoxConstraints(minWidth: 16),
                    child: Text(
                      widget.badge > 99 ? '99+' : '${widget.badge}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: FontSizes.cap,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底栏「选中药丸」的配色 —— **浅色/深色两套，成对定义**
///
/// # 为什么要有这个类（而不是就地写 `isLight ? a : b`）
///
/// bug ③ 的成因不是"值写错了"，而是**值散落在各处、只写了一套**：
/// ```text
/// 药丸渐变   写死浅色值（无分支）
/// 药丸阴影   写死 0.16（浅色的值，参考 my_shelf.dart）
/// 选中文字   #FAFAFA ← 从 colors.foreground 来，深色下恰好也是近白
/// ```
/// 三处**各自**看都"挺合理"，合起来就是深色下的**白底白字**。
/// 把三样集中到一处、**成对**给值，漏改一处的可能性就没了
/// —— 这正是 `lib/ui/widgets/my_shelf.dart` 的 `_ShelfPalette` 的做法
/// （原版 `tokens.css:325-330` 的教训：做新的"选中药丸"之前先找已有的
///   同类控件对齐，而不是自己发明一套材质）。
///
/// # 判据用 forui 的 `colors.brightness`，不用 Material 的
///
/// `AppPalette` **自带 `brightness`**（forui `src/theme/colors.dart:32`），
/// 而 `AppPalette.of(context)` 是**本文件已经在用**的那一条链路
/// （`_BottomItem` 的 `widget.colors` 就是从这里传下来的）。
/// `Theme.of(context).brightness` 在「同一个 shell 里两套 Material 串台」
/// 那类 bug 下会走兜底值 —— 本项目为这个已经踩过一次 1.16:1 的对比度事故，
/// 所以这里刻意选**不依赖 Material** 的判据。
///
/// # 值来自哪里
///
/// ```css
/// /* src/design/tokens.css:293（深色，默认主题） */
/// --tab-pill-bg: linear-gradient(180deg,
///                  rgb(255 255 255 / 0.19), rgb(255 255 255 / 0.10));
/// --tab-pill-shadow: inset 0 1px 0 rgb(255 255 255 / 0.28),
///                    0 2px 10px -2px rgb(0 0 0 / 0.34);
/// --tab-fg-strong: #ffffff;
///
/// /* src/design/theme-light.css:65（浅色） */
/// --tab-pill-bg: linear-gradient(180deg,
///                  rgb(255 255 255 / 0.96), rgb(255 255 255 / 0.80));
/// --tab-pill-shadow: inset 0 1px 0 rgb(255 255 255 / 1),
///                    0 2px 8px -2px rgb(16 18 26 / 0.16);
/// --tab-fg-strong: rgb(16 18 26 / 0.94);
/// ```
/// ⚠️ 同一套 `--tab-pill-bg` **也被「我的」分段控件复用**（原版有意为之），
///    所以底栏与分段控件**本来就该长得一样**；
///    而首页**源条**用的是另一个令牌 `--srcbar-pill-bg`（= `--surface-4`），
///    深色 0.17 / 浅色 1.0 —— **值不同但两边都对**，见 `source_bar.dart`。
class _BottomPalette {
  const _BottomPalette({
    required this.pillGradient,
    required this.pillShadow,
    required this.activeForeground,
  });

  /// 药丸的白色渐变（上亮下暗，模拟玻璃高光；原版 `180deg`）
  final List<Color> pillGradient;

  /// 药丸投影的不透明度 —— 深色下药丸自己很淡，靠阴影分层，所以更重
  final double pillShadow;

  /// 选中 tab 的文字/图标色（**必须与药丸明暗相反**）
  final Color activeForeground;

  static _BottomPalette of(BuildContext context) {
    final isLight = AppPalette.of(context).brightness == Brightness.light;
    return isLight ? _light : _dark;
  }

  /// 浅色 —— `theme-light.css:65` 的 `--tab-pill-bg`
  ///
  /// ⚠️ 这里刻意写成 `Colors.white.withValues(alpha: 0.96)` 而不是
  ///    `const Color(0xF5FFFFFF)`：两个值必须**以 alpha 的形式可读**——
  ///    `test/theme_tokens_test.dart` 的 ③ 就是按 `alpha: 0.96` 这种
  ///    带前缀的片段去判定"两套值都在"的。写成打包好的 ARGB 字面量
  ///    虽然渲染完全等价，却会让那条断言**假红**（判据是文本级的不变量，
  ///    不是渲染级的——渲染级由真机截图负责）。
  static final _light = _BottomPalette(
    pillGradient: [
      Colors.white.withValues(alpha: 0.96),
      Colors.white.withValues(alpha: 0.80),
    ],
    pillShadow: 0.16,
    // `--tab-fg-strong: rgb(16 18 26 / 0.94)`
    activeForeground: const Color(0xFF10121A).withValues(alpha: 0.94),
  );

  /// 深色 —— `tokens.css:293` 的 `--tab-pill-bg`
  ///
  /// 这是本 bug 的核心：深色下药丸**不是白色**，是"白 19%→10%"
  /// 叠在深色玻璃上（合成到 `#0A0A0A` 约 `(57,57,57)`），
  /// 与「我的」分段控件的实测 `(59,59,59)` 对齐。
  static final _dark = _BottomPalette(
    pillGradient: [
      Colors.white.withValues(alpha: 0.19),
      Colors.white.withValues(alpha: 0.10),
    ],
    pillShadow: 0.34,
    // `--tab-fg-strong: #ffffff`
    activeForeground: Colors.white,
  );
}
