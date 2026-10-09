// ═══════════════════════════════════════════════════════════════════════
//  设置页 —— 对齐原版 SettingsView.vue（4442 行）
// ═══════════════════════════════════════════════════════════════════════
//
// 这一页是**底座可扩展性的门面**：
// 用户在这里导入插件、配置代理、绑定云盘，而无需开发者发版。
//
// # 八个区块（与原版一一对应）
//
// ```text
// 内容源       启用/停用/排序/移除、导入插件
// JS 插件      列表、编辑、删除、配置项
// 账号登录     需要登录的源（B站等）
// 局域网遥控   开关/PIN/二维码/固定码/自启
// 云盘同步     WebDAV 配置/测试/立即同步   ★ 2026-09-29 已移入「备份与恢复」二级页
// 片头 / 片尾  全局开关与默认值
// 备份         导出/导入
// 关于         版本信息
// ```
//
// ⚠️ 这张表记的是**原版**的八个区块（对照用），不是本页现在的目录。
//    其中「片头 / 片尾」「备份」「关于」在 2026-09-25 的二级页拆分里
//    就搬走了，「云盘同步」在 2026-09-29 跟着搬进了同一个二级页 ——
//    本页现在只剩**入口行**，点进去才是内容（详见下面的拆分注释）。
//
// # ★ 从原版继承的关键行为
//
// ## 遥控：IP 拿不到时必须明确告警
//
// 原版注释：
// > 局域网 IP 拿不到时必须明确告警（否则用户会一直试连）
//
// ## 遥控：二维码里**不含配对码**
//
// 原版注释：
// > 扫码打开页面后**仍需手输配对码** —— 二维码里不含配对码，
// > 这样只有能看到这台设备的人才能连上。
//
// ## 遥控：开机自启的开关放在状态区**之上**
//
// 原版注释：
// > 放在状态区**之上**：这是「它会不会自己起来」的开关，
// > 比「现在开着没有」更该先被看到。

import 'dart:async';

import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/device.dart';
import '../core/player_gestures.dart';
import '../core/sourin_api.dart';
import 'app_theme.dart';
import 'remote_bridge.dart';
import 'tokens.dart';
import 'widgets/qr_view.dart';
/*
 * ═══════════════════════════════════════════════════════════════════════
 * ★★★ 四个面板的接线（2026-09-24 集成任务 M）
 * ═══════════════════════════════════════════════════════════════════════
 *
 * # 为什么要单独写这段注释
 *
 * 审计发现这 4 个文件、2111 行**已完成的代码只被探针文件 import** ——
 * 生产环境从不执行：
 * ```text
 * remote_bridge.dart          580 行   只有 remote_probe.dart
 * widgets/backup_panel.dart   700 行   只有 settings_panels_probe.dart
 * widgets/proxy_panel.dart    741 行   同上
 * widgets/provider_login_panel.dart 581 行  同上
 * ```
 * 后果不只是"少个按钮"—— `remote_bridge.dart` 没挂载意味着
 * **局域网遥控「手机→客户端」整条链路是断的**：
 * 手机发命令 → 命令进 Rust 队列 → **没有桥去取** → 手机一直转圈。
 *
 * ★ 教训：**"代码写完了"和"功能可用了"之间差一次接线**。
 *   探针能证明 widget 自身渲染正常，但证明不了它被接进了应用。
 *   所以 `test/wiring_test.dart` 断言的是"**被挂载**"，
 *   而不是"文件存在"。
 */
import 'widgets/backup_panel.dart';
import 'widgets/provider_login_panel.dart';
import 'widgets/proxy_panel.dart';
/*
 * ★ 响应式卡片网格（2026-09-25）
 *
 * 用户原话：「js插件还没改成一行多个的显示(根据宽度动态处理显示)」。
 * `ReorderableListView` 只有单列，所以换成这个自己搭的网格 ——
 * 为什么不加第三方包 / 为什么不用 SliverGrid，理由全写在那个文件头部。
 */
import 'widgets/reorderable_card_grid.dart';
/*
 * ═══════════════════════════════════════════════════════════════════════
 * ★★★ Provider 导入 / 编辑入口（任务 R）
 * ═══════════════════════════════════════════════════════════════════════
 *
 * 原版 `SettingsView.vue` 有「导入源」按钮与第三方源的「编辑」按钮，
 * 它们共同撑起 `import_declarative_provider` / `install_http_provider` /
 * `get_provider_config` 三个命令的**唯一界面入口**。
 *
 * ⚠️ 命令包装在 `sourin_api.dart` 里**一直都有** —— 缺的是接线。
 *    所以这次没有新增 API，只是把已有的接进设置页。
 *
 * 弹窗做成**自包含** widget（只依赖 `SourinApi`，不碰本页私有状态），
 * 因为本文件同时有 3~4 个代理在改，页面这边只留"打开它 + 拿结果"，
 * 冲突面最小。
 */
import 'widgets/provider_import_dialog.dart';
/*
 * ═══════════════════════════════════════════════════════════════════════
 * ★★★ 二级页拆分（2026-09-25 任务 ㉙，用户拍板方案 A）
 * ═══════════════════════════════════════════════════════════════════════
 *
 * 用户原话：
 * > 我希望设置页，**这几个功能，拆分到二级页面**，而不是在一级
 * > 3. 我选择A
 *
 * 方案 A = 拆走 5 个低频区块，一级页保留 3 个常用区块：
 * ```text
 * 拆走 → 片头片尾 / PC 播放手势 / 备份 / 主题 / 关于
 * 保留 → JS 插件 / 局域网遥控 / 云盘同步
 * ```
 * 一级页内容总高 3236px → 约 2180px（实测数据见
 * `.probe/REPORT-6-settings-split.md`）。
 *
 * # ★ 2026-09-29 追加：云盘同步也拆走了（用户第二次拍板）
 *
 * 用户原话：
 * > 云盘同步合并到备份二级页去
 *
 * ```text
 * 拆走 → 片头片尾 / PC 播放手势 / 备份 / 主题 / 关于 / 云盘同步  ← 本次
 * 保留 → JS 插件 / 局域网遥控
 * ```
 * 云盘同步去的是**已经存在**的「备份与恢复」二级页
 * （`settings/backup_page.dart`），作为第二个区块挂在备份下面 ——
 * 因为它和备份是同一类东西：都是"数据怎么出去/进来"，
 * 而且都是**配一次就不再点**的低频项。
 *
 * ⚠️ 原来的"保留"清单里之所以有它，是因为当时觉得"绑定云盘"算常用；
 *    实际它是**一次性配置**，放一级页反而占着首屏。方案 A 的判据
 *    （"危险/低频操作藏深一层"）对它同样成立。
 *
 * ⚠️ 顺带修掉一个真实缺陷：`SourinApi.syncStatus()` 原来挂在
 *    `loadAll()` 的 `Future.wait` 里 —— 而 `about_page.dart:61-69`
 *    已经记过「用户**没配云盘**时这个接口可能直接报错（那是正常状态，
 *    不是故障）」⇒ 没配云盘的用户本来会把**整个设置页**变成
 *    「加载失败：…」。现在它在面板里单独 `try/catch`。
 *
 * # ⚠️ 这 7 个 import 是**必须**的
 *
 * 拆完之后一级页只剩**入口行**（`SettingsEntryRow`），点进去才是内容。
 * 少一个 import 就少一个入口 —— 而那是**编译不过**的错误（不是静默的），
 * 所以不会出现"页面看着正常但点不进去"。
 *
 * ⚠️ 但**编译过 ≠ 用户看得见**：`import` 只是让类名可用，真正决定
 * 用户能否点进去的是下面 `SettingsEntryRow` 的 `onTap`。task-18 就踩过
 * 这个坑（两个二级页都写好了，一级页一行入口都没有 ⇒ 功能对用户完全
 * 不可见）。`test/task18_entry_test.dart` 就是为这件事加的回归。
 */
import 'settings/about_page.dart';
import 'settings/backup_page.dart';
import 'settings/pc_gestures_page.dart';
import 'settings/playback_page.dart';
import 'settings/skip_page.dart';
import 'settings/theme_page.dart';
import 'settings/touch_gestures_page.dart';
/*
 * ★ 2026-10-06（task-33 ⑦）：Emby 二级页的入口 —— 补上**唯一**那行缺失的接线
 *
 * `emby_page.dart`（717 行，task-35 的成果）**写完了却没有任何引用**：
 * 全仓 `EmbySettingsPage` 只在它自己文件里出现 ⇒ 用户永远点不进去。
 * 这与上面 task-18 踩过的坑是**同一个**：
 * > 两个二级页都写好了，一级页一行入口都没有 ⇒ 功能对用户完全不可见。
 *
 * ⚠️ 只加 import 不够，必须同时加 `SettingsEntryRow`（见 build 里
 *    「内容源」分组下的那一行）—— 本文件的注释 :151-160 逐字记着这条。
 */
import 'settings/emby_page.dart';
/*
 * ★ 共用零件（2026-09-25 任务 ㉙ 从本文件抽出）
 *
 * `SettingsBlock` / `SettingsGestureToggle` / `SettingsGestureChoice` /
 * `SettingsGesturePill` / `SettingsInfoRow` 原本是本文件的**私有类**
 * （`_Block` / `_GestureToggle` …）。二级页在新文件里，私有类跨文件
 * 用不了 —— 所以公开并搬到 `settings_kit.dart`。
 *
 * ⚠️ 下面 5 行 `typedef` 让**本文件所有调用点一个字都不用改**：
 * ```text
 * 10 处 `_Block(...)` 仍然写 `_Block(...)`，只是现在指向 SettingsBlock
 * ```
 * 本文件有并发写入者（task-6 在改插件更新 UI），改动面越小冲突越小。
 */
import 'widgets/overlay_motion.dart';
import 'widgets/plugin_edit_dialog.dart';
import 'widgets/plugin_speedtest.dart';
import 'widgets/settings_kit.dart';
// ★ task-55：动画效果选择项（`PageTransitionStyle` / `PageTransitionStyleStore`）
import 'widgets/page_transition.dart';
/*
 * ★ task-43：「JS 插件」二级页用 `SettingsSubPage` 做外壳
 *   （与另外 5 个二级页**完全一致**：它自带返回按钮 + Esc/遥控返回，
 *    而全局标题栏**没有**返回键 —— 见那个文件的长注释）。
 *
 * ⚠️ 本文件原本**没有** import 它（一级页不直接用），必须补上，
 *   否则 `_PluginsPage` 编译不过（未定义的类）。
 */
import 'widgets/settings_sub_page.dart';

/*
 * TVBox 源的「订阅更新」弹窗（`TvboxUpdateDialog`）。
 *
 * 与 JS 插件那条链**并列**：插件读 `plugins/.meta/<id>.json`，
 * TVBox 源读 `data_dir/tvbox-sources.json`（sidecar）——
 * 两者都是纯本地读文件，界面上共用卡片上的同一个图标按钮。
 */
import 'widgets/tvbox_source_panel.dart';

/// 本文件里的旧名字 → `settings_kit.dart` 里的公开类
///
/// ⚠️ 这几个别名**只为减少改动面**而存在。新代码请直接用公开名
///    （`SettingsBlock` 等）—— 别名是给历史调用点留的过渡层。
typedef _Block = SettingsBlock;
typedef _GestureToggle = SettingsGestureToggle;
typedef _GestureChoice<T> = SettingsGestureChoice<T>;
typedef _GesturePill = SettingsGesturePill;
typedef _InfoRow = SettingsInfoRow;

/// 设置页
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.onProvidersChanged, this.isTv = false});

  /// 源列表变了（启用/停用/导入）→ 通知首页刷新
  final VoidCallback? onProvidersChanged;

  final bool isTv;

  @override
  State<SettingsPage> createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage> {
  bool _loading = true;

  /// ★★★ 「首次加载是否已完成」—— 全页转圈的**唯一**判据
  ///
  /// # 为什么不能用 `_providers.isEmpty` 当判据（2026-09-25 实测）
  ///
  /// 原来用的是 `_providers.isEmpty` —— 它是"首次加载"的**代理判据**，
  /// 两者并不是同一个东西：
  /// ```text
  /// _providers.isEmpty == true 有两种可能：
  ///   ① 真的还没加载过            ← 该转圈
  ///   ② 加载过，但这次结果为空     ← ★ 不该转圈（会销毁 ListView → 滚动归零）
  /// ```
  /// ② 是**真实可达**的：核心重启 / 插件重载 / `listProviders()` 瞬时失败
  /// 都会让 `_providers` 变空。那时下一次 `loadAll()` 又会置 `_loading = true`
  /// ⇒ `build()` 的 `if (_loading) return const Center(...)` **整个替换** ListView
  /// ⇒ 滚动位置归零 ⇒ 用户看到的正是「设置页往下滑，自动往上滚」。
  ///
  /// 实测证据（`.probe/probe_tests/zz_probe_t3_scroll_guard_test.dart`）：
  /// ```text
  /// GUARD[A] 再次 loadAll 后 pixels=3000.0  ListView在=true    ← 阳性对照：守卫起作用
  /// GUARD[B] providers 变空 ⇒ ListView消失=true；pixels 3000→0  ← ★ 漏洞复现
  /// GUARD[C] 改判据后 pixels=3000→3000，ListView消失=false       ← 修法有效
  /// ```
  ///
  /// ★ `loadAll()` 在 `lib/` 下有 **29 处调用点**（剥注释后实测），
  ///   其中 `shell.dart` 里「切回设置页」那条**每次切 tab 都会踩**。
  ///
  /// ⚠️ 这是**新增**判据，不是替换 —— `_providers.isEmpty` 在别处
  ///    （空态 UI）的语义原样保留。
  bool _firstLoadDone = false;

  String? _toast;

  /// ★★★ 数据版本号 + toast 通知（task-43，「JS 插件」二级页要用）
  ///
  /// # 为什么需要这两个
  /// ```text
  /// 二级页是 `Navigator.push` 上来的**另一条路由** —— 不在本 State
  /// 的子树里，所以：
  ///   ① host 的 `setState` **不会**重建它 ⇒
  ///      操作后（loadAll 已刷新数据）界面看着不变，像「点了没反应」。
  ///   ② host 的 toast 画在**宿主自己的 Stack** 里 ⇒
  ///      被整屏的路由盖住 ⇒ `_flash()` 的 59 处反馈**全部看不见**。
  /// ```
  /// ⇒ 两个 `ValueNotifier`，二级页自己订阅、自己画。
  ///
  /// ⚠️ 用 `ValueNotifier` 而不是让二级页 `addListener(host)`：
  ///    `State` **不是** `Listenable`（只有 `ChangeNotifier` 是）。
  /// ⚠️ host 自己的 toast 渲染**原样保留** —— 这两个只是**追加**通道，
  ///    不替换既有行为（一级页的 toast 仍由 `_toast` 字段驱动）。
  final _dataRev = ValueNotifier<int>(0);
  final _toastRev = ValueNotifier<String?>(null);

  // ── 内容源 ──
  List<ProviderManifest> _providers = [];

  /// ── 健康检测（任务 R）──
  ///
  /// 原版 `sweepping` —— 探测期间按钮禁用 + 文案变「检测中…」。
  /// 探测要逐个源发网络请求（本机 26 个源，实测要十几秒），
  /// 不禁用会被连点，第二遍纯属浪费。
  bool _sweeping = false;

  /// ── 插件（任务 R）──
  ///
  /// 原版 `pluginBusy` —— 「重新加载」期间禁用。
  /// `reload_plugins` 会**执行全部插件脚本**，不是瞬时操作。
  bool _pluginBusy = false;

  // ── 插件 ──
  PluginListResult _plugins = const PluginListResult();

  /// ★ 插件安装来源（`{ 插件id: 安装链接 }`）—— task-23
  ///
  /// # 为什么要单独一份，而不是从 `_plugins` 里读
  ///
  /// `PluginEntry`（`list_plugins` 的返回）里**没有**来源链接 ——
  /// 它是 `plugins/.meta/<id>.json` 这个 sidecar 里的东西。
  ///
  /// # ★ 为什么在 `loadAll` 里读它（而不是等用户点按钮）
  ///
  /// 界面要在**这一帧**就知道"哪张卡显示「检测更新」图标"。
  /// `list_plugin_sources` 是**纯本地读目录**（毫秒级、零网络），
  /// 所以放在页面加载里没问题。
  ///
  /// ⚠️ **绝不能**改成"用批量检测来判断有没有来源" ——
  ///    那会让**打开设置页就对每个插件发一次 HTTP 请求**
  ///    （设置页卡几秒 + 可能被 CDN 限流）。
  ///
  /// ⚠️ 查到 `null` = 这个插件**没有安装链接**（手动放入的）→
  ///    界面**不显示**「检测更新」入口。这是**如实**，不是缺陷：
  ///    没有链接就无从查起，假装能查才是骗用户。
  Map<String, String> _pluginSources = const {};

  /*
   * ── TVBox 订阅来源（与 `_pluginSources` 同性质、不同来源）──
   *
   * JS 插件把安装链接写在 `plugins/.meta/<id>.json`；
   * TVBox 源把订阅链接写在 `data_dir/tvbox-sources.json`。
   * `list_tvbox_sources` 与 `list_plugin_sources` 一样是**纯本地读目录**
   * （零网络）—— 设置页一打开就对每个订阅发 HTTP 是不可接受的。
   *
   * 值类型是 `TvboxSourceInfo`（不是 `String`）：
   *   1. 弹窗要 `sourceUrl`；
   *   2. `sourceUrl == null` 是**合法状态**（贴文本导入的源），
   *      弹窗里可以让用户**补填**链接。
   *   => 判据必须是「后端认识这个源」= `containsKey`，
   *      **不能**写成 `sourceUrl != null`（那会把补填入口一起关掉）。
   */
  Map<String, TvboxSourceInfo> _tvboxSources = const {};

  // ── 遥控 ──
  RemoteStatus? _remote;
  bool _remoteAutoStart = true;
  bool _remoteBusy = false;

  /*
   * ── 同步 ── ★ 2026-09-29 已整块搬走
   *
   * 用户原话：
   * > 云盘同步合并到备份二级页去
   *
   * 原来的 `SyncStatus? _sync` / `bool _syncBusy` 两个字段、四个方法
   * （`_configureWebdav` / `_testSync` / `_syncNow` / `_disconnectSync`）、
   * 一个 UI 区块（`_Block(title: '云盘同步', …)`）和 `_WebdavDialog`
   * **全部**搬进了 `lib/ui/widgets/sync_panel.dart`（自包含无参 widget）。
   *
   * ⚠️ 顺带修掉一个真实缺陷：`SourinApi.syncStatus()` 原来挂在
   *    `loadAll()` 的 `Future.wait` 里 —— 而 `about_page.dart:61-69`
   *    已经记过「用户**没配云盘**时这个接口可能直接报错（那是正常状态，
   *    不是故障）」⇒ 没配云盘的用户本来会把**整个设置页**变成
   *    「加载失败：…」。现在它在面板里单独 `try/catch`。
   */

  /// ── 片头片尾（设置页总览，集成任务 M）──
  ///
  /// 片头片尾是在**播放器**里设的，这里只做"看得见 + 能清除"。
  ///
  /// ⚠️ 单独拉而不是并进 `loadAll()` 的 `Future.wait` ——
  ///    因为 `listSkipMarkers` 失败**不该让整页加载失败**
  ///    （源/插件/遥控都是核心，片头片尾是附加信息）。
  List<SkipMarker> _skipMarkers = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => loadAll());
  }

  /// 拉取全部数据
  ///
  /// # ★★ 2026-09-25：修「刷新把整页变转圈 → 滚动位置归零」
  ///
  /// ## 用户报的现象
  ///
  /// > 设置页往下滑会自动往上滚
  ///
  /// ## 真根因（不是 `spatial_nav.dart` 的 `ensureVisible`）
  ///
  /// 代理③ 用探针**证伪**了最初那个假设 —— 实测：
  /// ```text
  /// [STRACE] _scrollIntoView 被调用: 0 次
  /// ensureVisible 在堆栈里出现: 0 次
  /// 滚动变化的原因分布: pointerScroll(20) / handleThumbDragUpdate(63)
  /// ```
  /// 滚动**确实在变**，但全是用户输入 —— 不是 `_scrollIntoView` 干的。
  ///
  /// 真正的原因在这里 + `build()` 的开头：
  /// ```dart
  /// // 本方法原先的第一行
  /// if (mounted) setState(() => _loading = true);   // ← 整页变转圈
  ///
  /// // build() 里
  /// if (_loading) {
  ///   return const Center(child: CircularProgressIndicator());  // ← ListView 被整个替换
  /// }
  /// return ListView(...);    // ← 重建时滚动位置从 0 开始
  /// ```
  /// `_loading` 一置位，`ListView` 就从树上被**移除**；恢复时是一个
  /// **全新的** `ListView`，没有 `ScrollController` 也没有
  /// `PageStorageKey` 能接住旧位置 → 滚动归零。
  ///
  /// 而 `loadAll()` 在 **12 处**被调用（initState、每个源操作的
  /// 停用/启用/移除/排序/导入/重载/安装插件……）——
  /// 所以用户「滚到中间 → 点任意一个开关 → 页面跳回顶部」，
  /// 看起来就像"自己往上滚"。
  ///
  /// ## 修法：加载态**只在首次**显示（编排者给的方案 A）
  ///
  /// 判据从 `_loading` 改成 `_loading && _providers.isEmpty`：
  /// ```text
  /// 首次进页面   _providers 为空 → 显示转圈（本来就该等）
  /// 之后的刷新   _providers 有值 → 保持列表，数据原地更新
  /// ```
  ///
  /// # 为什么选 A，而不是「给 ListView 加 ScrollController」
  ///
  /// ```text
  /// B（ScrollController/PageStorageKey）
  ///   `_loading` 时 ListView **整个不存在**。就算把 controller 挂在
  ///   外面，ListView 重建时仍要用 `initialScrollOffset` 才能复位 ——
  ///   而 controller 的 offset 在 ListView detach 时会被重置。
  ///   要让它工作得**保住 controller 不被销毁**，改动面更大、更脆。
  ///
  /// C（局部 loading）
  ///   视觉最好，但要给 8 个区块各写一份局部 loading 态 ——
  ///   而 `loadAll()` 是**一把梭**拉全部数据，没有"哪一块在加载"的信息。
  ///
  /// A（本方案）
  ///   一行判据。语义上也是对的：`loadAll()` 是**刷新**语义
  ///  （initState 调一次，之后都是用户操作后刷新）——
  ///   刷新时把已有内容换成转圈，本来就是错的。
  /// ```
  ///
  /// ⚠️ 副作用检查：`_loading` 仍然在首次为 `true`，
  ///    所以「进设置页先转圈」的原有行为**没变**；
  ///    变的只是"刷新时不再清空页面"。
  Future<void> loadAll() async {
    /*
     * ★ 只在**首次**显示整页转圈
     *
     * 见上面的长注释：这是「滚动位置归零」的根因所在 ——
     * 刷新时保持列表存在，滚动位置才不会被重置。
     *
     * ⚠️⚠️ 判据是 `!_firstLoadDone`（显式的"首次"标志），
     *      **不是** `_providers.isEmpty`（那只是代理 —— 见 `_firstLoadDone`
     *      的文档：加载过但结果为空时它会误判成"还没加载过"，
     *      于是刷新时又把整页换成转圈、销毁 ListView、滚动归零）。
     */
    if (mounted && !_firstLoadDone) setState(() => _loading = true);
    try {
      /*
       * ★ 并发拉三份
       *
       * ⚠️ 遥控状态用 `remoteStatus()` 而不是 `remoteStart()` ——
       *    后者会**启动服务并改偏好**，进设置页不该有副作用。
       *
       * ⚠️ 2026-09-29：原来这里是**四**份，第 4 份 `syncStatus()` 已随
       *    云盘同步搬去 `sync_panel.dart`（见本文件 `_sync` 字段处的注释：
       *    没配云盘时它会报错，挂在 `Future.wait` 里会把整页变成加载失败）。
       */
      final results = await Future.wait([
        SourinApi.listProviders(),
        SourinApi.listPlugins(),
        SourinApi.remoteStatus(),
      ]);

      final autoStart = await SourinApi.remoteAutoStart();

      /*
       * ★ 片头片尾**单独拉、单独失败**（集成任务 M）
       *
       * 不并进上面的 `Future.wait`：那四个是核心数据，失败该报错；
       * 片头片尾是附加总览，**查不到不该让整页白掉**。
       */
      var markers = <SkipMarker>[];
      try {
        markers = await SourinApi.listSkipMarkers();
      } catch (e) {
        debugPrint('[SETTINGS] 片头片尾列表加载失败（不影响其它区块）: $e');
      }

      /*
       * ★ 插件安装来源也**单独拉、单独失败**（task-23）
       *
       * 理由与片头片尾一样：它是"附加信息"——
       * 查不到只是"显示不了检测更新入口"，**不该让整页白掉**。
       *
       * ⚠️ 读不到时保持 `{}`（= 所有插件都当作"没有来源"）——
       *    **保守方向是对的**：宁可少显示一个按钮，
       *    也不能在没有来源的情况下显示「检测更新」骗用户。
       */
      var sources = <String, String>{};
      try {
        sources = await SourinApi.listPluginSources();
      } catch (e) {
        debugPrint('[SETTINGS] 插件安装来源加载失败（不影响其它区块）: $e');
      }

      /*
       * TVBox 订阅来源也**单独拉、单独失败**（与上面那笔同一个理由）
       *
       * 它是「附加信息」：查不到只是「显示不了检测更新入口」，
       * **不该让整页白掉**。
       *
       * 读不到时保持 `{}` —— 保守方向（宁可少一个按钮，
       * 也不能在没有来源的情况下显示「检测更新」骗用户）。
       */
      var tvboxSources = <String, TvboxSourceInfo>{};
      try {
        final tvs = await SourinApi.listTvboxSources();
        tvboxSources = {for (final s in tvs.sources) s.id: s};
      } catch (e) {
        debugPrint('[SETTINGS] TVBox 订阅链接加载失败（不影响其它区块）: $e');
      }

      if (!mounted) return;
      setState(() {
        _providers = results[0] as List<ProviderManifest>;
        _plugins = results[1] as PluginListResult;
        _remote = results[2] as RemoteStatus;
        _remoteAutoStart = autoStart;
        _skipMarkers = markers;
        _pluginSources = sources;
        _tvboxSources = tvboxSources;
      });
    } catch (e) {
      debugPrint('[SETTINGS] 加载失败: $e');
      _flash('加载失败：$e');
    } finally {
      /*
       * ★★★ `_firstLoadDone` 必须在 `finally` 里置位 —— 覆盖**成功和失败**两条路径
       *
       * # 为什么不能只在成功路径置位（那会比原来更糟）
       *
       * 若只在 L404 那个 `setState` 里置位，那么**首次加载失败**时
       * `_firstLoadDone` 永远是 false ⇒ 之后每一次 `loadAll()` 都满足
       * `!_firstLoadDone` ⇒ **每次都把整页换成转圈**
       * ⇒ 失败态下比修之前还糟（原来是"列表空的时候才转圈"，
       *    改错之后变成"永远转圈"）。
       *
       * `finally` 是唯一同时覆盖 try 成功与 catch 失败的位置。
       */
      if (mounted) {
        setState(() {
          _loading = false;
          _firstLoadDone = true;
        });
        // ★ task-43：二级页是另一条路由，收不到本次 setState ⇒ 用计数通知
        _dataRev.value++;
      }
    }
  }

  void _flash(String msg) {
    if (!mounted) return;
    setState(() => _toast = msg);
    // ★ task-43：二级页在另一条路由上，看不到宿主 Stack 里的 toast
    _toastRev.value = msg;
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_toast == msg) setState(() => _toast = null);
      if (_toastRev.value == msg) _toastRev.value = null;
    });
  }

  // ═══════════════════════════════════════════════════════════════════
  //  二级页导航（2026-09-25 任务 ㉙）
  // ═══════════════════════════════════════════════════════════════════

  /// 打开一个设置二级页
  ///
  /// # 为什么用 `Navigator.push` 而不是 `showDialog`
  ///
  /// 用户明确要的是**二级页面**：
  /// > 我希望设置页，这几个功能，**拆分到二级页面**，而不是在一级
  ///
  /// 本文件已有的「点击 → 弹窗」模式（`_openOrderDialog` /
  /// 片头片尾历史）是**弹窗**，不是页面 —— 那适合"看一眼就走"的
  /// 轻量内容；这 5 个是**有若干开关/选项、要停留操作**的配置面板，
  /// 弹窗会让它们挤在一个小盒子里（PC 播放手势那个尤其明显）。
  ///
  /// # 复用 `MaterialPageRoute`（不自己写路由）
  ///
  /// `shell.dart` 的全局标题栏挂在 `MaterialApp.builder` 里、
  /// **在 Navigator 之外**，所以 `push` 上来的路由**天然**共享那条标题栏
  /// —— 不需要任何额外接线（详情页/浏览页/播放页都是这么做的）。
  ///
  /// ⚠️ 返回入口由 `SettingsSubPage` **页内自画**
  ///    （全局标题栏**没有**返回按钮，见那个文件的说明）。
  void _openSubPage(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  /// 打开「JS 插件」二级页（task-43）
  ///
  /// 与另外 5 个二级页**同一范式**（`_openSubPage` + `SettingsSubPage`）。
  ///
  /// ⚠️ 传 `this`：二级页要调 `_pluginsBlock` 与那一堆动作方法。
  ///    设置页 tab 被 shell 保活，本 State 不会先于二级页 dispose。
  void _openPluginsPage() {
    _openSubPage(_PluginsPage(host: this));
  }

  // ═══════════════════════════════════════════════════════════════════
  //  内容源
  // ═══════════════════════════════════════════════════════════════════

  /// ★★★ 停用 / 启用一个源（任务 AE 接上 `get_provider_enabled`）
  ///
  /// # 为什么这里要读一次 `get_provider_enabled`（原版那个真 bug 的教训）
  ///
  /// 原版 `stores/app.ts:259-283` 记录得很清楚：
  /// > ## ⚠️ 这里曾是一个真 bug：用了 `working` 而不是 `enabled`
  /// >
  /// > | 字段 | 含义 | 谁能改 |
  /// > |---|---|---|
  /// > | `working` | **站点自身**是否可用（探测出来的）| 用户改不了 |
  /// > | `enabled` | **用户**是否要使用它（持久化的偏好）| 用户的选择 |
  /// >
  /// > 实测证据：停用 cctv 后 `get_provider_enabled('cctv')` 返回 `false`，
  /// > 但首页的切换条里它还在。
  ///
  /// # 为什么不能只信内存里那个 `p.enabled`
  ///
  /// `p.enabled` 是**上一次 `list_providers()` 的快照**。用户点「停用」时
  /// 它还是旧值，而这个值是**乐观算出来**的（`!p.enabled`）。
  /// 落盘才是真相 —— 所以这里：
  /// ```text
  /// ① 先写（set_provider_enabled）
  /// ② 再用 get_provider_enabled **从盘上读回真相**
  /// ③ 用真相决定提示文案
  /// ```
  /// 这样即使写失败/源不存在（后端返回 `false` 而不是报错），
  /// 提示也不会撒谎。**这就是那个命令的 UI 入口。**
  ///
  /// ⚠️ 提示文案要用**读回的真相**，不是 `p.enabled` 取反 ——
  ///    否则"点了停用但其实没停成"时用户会收到一条假成功提示。
  Future<void> _toggleProvider(ProviderManifest p) async {
    try {
      // ① 写（期望的新状态）
      final want = !p.enabled;
      await SourinApi.setProviderEnabled(p.id, want);

      /*
       * ② 从盘上读回真相（`get_provider_enabled` 读的是
       *    `disabled-providers.json`，见 rust/.../commands.rs:114）。
       *
       * ⚠️ 读失败**不该让整个操作算失败** —— 写已经成功了。
       *    所以这里单独 try/catch，退回到"按期望值报"。
       */
      bool actual = want;
      var readBack = false;
      try {
        actual = await SourinApi.getProviderEnabled(p.id);
        readBack = true;
      } catch (e) {
        debugPrint('[SETTINGS] get_provider_enabled 读回失败（不影响写入）: $e');
      }

      await loadAll();
      widget.onProvidersChanged?.call();

      /*
       * ③ 文案按**真相**报（与后端不一致时如实说出来）
       */
      if (readBack && actual != want) {
        _flash(
          '「${p.name}」状态未变更 —— 后端报告仍是'
          '${actual ? "启用" : "停用"}（源可能已不存在）',
        );
      } else {
        _flash(actual ? '已启用「${p.name}」' : '已停用「${p.name}」');
      }
    } catch (e) {
      _flash('操作失败：$e');
    }
  }

  Future<void> _removeProvider(ProviderManifest p) async {
    /*
     * ⚠️ 内置源不能移除（它们编译在核心里，移了会"复活"）
     *
     * 原版用 `kind` 区分：`js` / `declarative` / `http` 是第三方的，
     * 其余（内置 Rust 实现）不给删。
     */
    final isThirdParty =
        p.kind == 'js' ||
        p.kind == 'declarative' ||
        p.kind == 'http' ||
        p.kind == 'tvbox';
    if (!isThirdParty) {
      _flash('内置源不能移除，可以停用它');
      return;
    }

    final ok = await _confirm(
      title: '移除内容源',
      /*
       * ⚠️ 文案不能再说「插件文件会一起删掉」——
       *
       * 这句话在合并前是**对的**吗？不是。`remove_provider` 从来就
       * 只做 `registry.unregister`（见 `commands_provider.rs:111`），
       * **不碰磁盘**。旧文案是一句假承诺。
       *
       * 合并后 JS 插件走 `_removeOf` → `_removePlugin`（真删文件），
       * 所以「文件会被删掉」现在由 `_removePlugin` 那条路径负责，
       * 它自己的确认框文案是准确的（「此操作不可撤销」）。
       * 这里只描述 `_removeProvider` 真正做的事。
       */
      message:
          '确定移除「${p.name}」吗？\n\n'
          '移除后这个源不再出现在列表里。',
    );
    if (!ok) return;

    try {
      await SourinApi.removeProvider(p.id);
      await loadAll();
      widget.onProvidersChanged?.call();
      _flash('已移除「${p.name}」');
    } catch (e) {
      _flash('移除失败：$e');
    }
  }

  /// 打开排序面板
  Future<void> _openOrderDialog() async {
    final draft = _providers.map((p) => p.id).toList();

    final result = await showAppDialog<List<String>>(
      context: context,
      builder: (_) => _OrderDialog(
        draft: draft,
        nameOf: (id) =>
            _providers.where((p) => p.id == id).firstOrNull?.name ?? id,
        offOf: (id) =>
            _providers.where((p) => p.id == id).firstOrNull?.enabled == false,
      ),
    );

    if (result == null) return;
    try {
      /*
       * ⚠️ 用**返回值**刷新，不是回显入参
       *
       * 入参里可能有过期/不存在的 id，返回值才是真相。
       */
      final applied = await SourinApi.setProviderOrder(result);
      await loadAll();
      widget.onProvidersChanged?.call();
      _flash('顺序已保存（${applied.length} 个源）');
    } catch (e) {
      _flash('保存顺序失败：$e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  内容源排序（任务：卡片式 + 三种排序方式）
  // ═══════════════════════════════════════════════════════════════════

  /// ★ 排序落盘 —— **三种排序方式共用这一个出口**
  ///
  /// # 为什么必须只有一处
  ///
  /// 三种排序方式（拖动 / 卡片按钮 / 遥控面板）如果各自写一份
  /// 「算新顺序 + 落盘 + 刷新」，迟早会有一份漏掉某步。已知会漏的：
  /// ```text
  /// ① 漏 loadAll()          → UI 不动（用户以为没生效，再点一次）
  /// ② 漏 onProvidersChanged → 首页/搜索页的顺序还是旧的
  /// ③ 漏 setProviderOrder   → 只有内存变了，**重启就还原**
  /// ```
  /// ③ 正是「排序」这个需求的核心验收 —— 光看 UI 动了不算数。
  ///
  /// # 为什么用返回值刷新，不是自己算的顺序
  ///
  /// `SourinApi.setProviderOrder` 返回**后端实际生效**的顺序
  ///（`rust/sourin_core/src/commands_provider.rs` 的 `registry.reorder()`
  /// 会剔除不存在的 id、补上缺失的 id）。自己算的那份可能和它对不上。
  ///
  /// # 为什么先 `loadAll()` 再报成功
  ///
  /// 落盘失败时 `setProviderOrder` 会抛 —— 那时**不该**提示"已保存"。
  /// 所以顺序是：先写、再读、最后才提示。
  Future<void> _persistOrder(List<String> ids, String okMessage) async {
    try {
      final applied = await SourinApi.setProviderOrder(ids);
      await loadAll();
      widget.onProvidersChanged?.call();
      _flash(okMessage.replaceFirst('{}', '${applied.length}'));
    } catch (e) {
      _flash('保存顺序失败：$e');
    }
  }

  /// ★ 「上一个 / 下一个」按钮 —— 把某个源上移/下移一位
  ///
  /// # 边界：静默不动（与原版 `PrevEpisode` 在首集的做法一致）
  ///
  /// 第一项再上移 / 最后一项再下移**什么都不做**，不报错。
  /// 界面上这两个按钮此时本来就是**置灰**的（见 `canMoveUp` /
  /// `canMoveDown`），正常点不到；这里再判一次是防遥控/程序调用绕过 UI。
  ///
  /// ⚠️ 与 `_OrderDialog._move` 的边界处理**必须一致** ——
  ///    那边也是 `if (j < 0 || j >= len) return;`。
  Future<void> _moveProviderBy(String id, int delta) async {
    final ids = _providers.map((p) => p.id).toList();
    final i = ids.indexOf(id);
    // id 不在列表里（列表过期）→ 如实提示，不静默
    if (i < 0) {
      _flash('找不到该内容源，请下拉刷新后重试');
      return;
    }
    final j = i + delta;
    if (j < 0 || j >= ids.length) return; // 边界：静默不动
    ids.removeAt(i);
    ids.insert(j, id);
    await _persistOrder(ids, '顺序已保存（{} 个源）');
  }

  /// ★ 拖动排序（`ReorderableListView.onReorderItem`）
  ///
  /// # ★★ 为什么用 `onReorderItem` 而不是 `onReorder`（踩过，记下来）
  ///
  /// Flutter 的 `onReorder` 有个**历史包袱**：往下拖时 `newIndex` 是
  /// **移除该项之前**的下标，官方文档要求调用方自己减一：
  /// ```dart
  /// if (newIndex > oldIndex) newIndex -= 1;   // ← onReorder 的老写法
  /// ```
  /// 这个语义反直觉，踩的人太多，所以新版加了 `onReorderItem` ——
  /// **它已经在内部把 `newIndex` 换算好了**。
  ///
  /// ⚠️ 两者**不能混**：如果用了 `onReorderItem` 还自己 `-= 1`，
  ///    就会**减两次** —— 往下拖一格会变成"跳过一格"，
  ///    而且只在某些方向/位置错，最难查。
  ///
  /// ```text
  /// onReorder      newIndex 是"移除前"的下标 → 调用方必须 -1
  /// onReorderItem  newIndex 已经是"移除后"的目标位 → 直接用
  /// ```
  /// 本方法用 `onReorderItem`，所以**不做** `-= 1`。
  /// 对应断言在 `test/provider_reorder_cards_test.dart`。
  ///
  /// # 下标越界防护（遥控/程序调用可能绕过 UI 的置灰）
  ///
  /// `ReorderableListView` 正常不会传越界值，但这里是**三种排序方式
  /// 的共用路径之一**，加两道钳制不亏。
  Future<void> _onReorderProviders(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _providers.length) return;
    if (newIndex < 0) newIndex = 0;
    if (newIndex >= _providers.length) newIndex = _providers.length - 1;
    // 原地放下 → 直接返回，避免白写一次盘（拖动时轻微抖动就会触发）
    if (newIndex == oldIndex) return;

    final ids = _providers.map((p) => p.id).toList();
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex, moved);
    await _persistOrder(ids, '顺序已保存（{} 个源）');
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Provider 导入 / 编辑（任务 R）
  // ═══════════════════════════════════════════════════════════════════

  /// ★ 打开「导入源」（新增）
  ///
  /// 原版 `openAdd()`（`SettingsView.vue:1413`）：
  /// ```ts
  /// editing.value = null;  importError.value = "";
  /// importJson.value = ""; httpBase.value = ""; httpHeadersJson.value = "";
  /// importMode.value = "declarative";  showImport.value = true;
  /// ```
  /// 原版注释解释了为什么**必须显式清空**：
  /// > 否则「编辑 A → 关闭 → 点添加」会把 A 的配置带进来，
  /// > 用户以为在新建，实际会覆盖掉 A（同 id 覆盖语义）。
  ///
  /// 我们这边 `showAdd()` 每次都 new 一个弹窗 State，天然是空的 ——
  /// 但仍然走这条路径（而不是"直接 new 一个空表单"），
  /// 保证"清空"这个语义**只有一处实现**。
  Future<void> _openImportDialog() async {
    final r = await ProviderImportDialog.showAdd(context);
    if (!mounted) return;
    await _afterImport(r);
  }

  /// ★ 打开「编辑」—— 按 kind 分派回填（原版 `edit()`，`SettingsView.vue:1365`）
  ///
  /// # 原版的两条分支
  ///
  /// ```ts
  /// if (p.kind === "js") { ...editPlugin(info); return; }   // ← JS 插件走源码编辑器
  /// const cfg = await provApi.config(p.id);
  /// if (!cfg) { flash("该源没有可编辑的配置"); return; }
  /// ```
  ///
  /// ⚠️ 原版 `canEdit`（:1354）的判据要**正向列举可编辑的**：
  /// > 判据要正向列举可编辑的，而不是「不等于 builtin」——
  /// > 后者在将来新增源类型时会误放行（点了报错比不放更糟）。
  ///
  /// 所以下面先判 kind，再调 `get_provider_config` ——
  /// 内置源**根本不会**走到这里（卡片上不显示「编辑」按钮）。
  ///
  /// # JS 插件的「编辑」走**另一条路**（原版 `edit()` 的第一条分支）
  ///
  /// 原版 `edit()`（:1365）开头就是：
  /// ```ts
  /// if (p.kind === "js") {
  ///   const info = pluginList.value.find((x) => x.id === p.id);
  ///   if (!info) {
  ///     flash("找不到该插件的文件（可能刚被删除，试试「重新加载」）");
  ///     return;
  ///   }
  ///   await editPlugin(info);   // ← 源码编辑器，不是本弹窗
  ///   return;
  /// }
  /// ```
  /// JS 插件是**磁盘上的一个 .js 文件**，它的"配置"就是源码本身，
  /// 所以走源码编辑器；只有 `declarative` / `http` 两种「配置型」源
  /// 才回填到本弹窗。
  ///
  /// ⚠️ 那句兜底文案里的「试试**重新加载**」不是随口说的 ——
  ///    插件文件被手工删掉后，registry 里可能还留着旧条目，
  ///    点「重新加载」能让两边对齐。我们刚好补了这个按钮。
  Future<void> _editProvider(ProviderManifest p) async {
    // ── JS 插件：转给源码编辑器（原版 `editPlugin`）──
    if (p.kind == 'js') {
      final info = _plugins.plugins.where((e) => e.id == p.id).firstOrNull;
      if (info == null) {
        _flash('找不到该插件的文件（可能刚被删除，试试「重新加载」）');
        return;
      }
      await _editPlugin(info);
      return;
    }

    ProviderImportSeed? seed;
    try {
      /*
       * ★ 用 `getProviderImportSeed` 而不是 `getProviderConfig`
       *
       * 后者返回裸 `Map<String,dynamic>?`，调用方要自己判 kind、
       * 自己 jsonDecode、自己处理 headers 缺失 —— 三处重复的契约逻辑。
       * 前者收成一个封闭类型，kind 不认识时返回 null。
       */
      seed = await SourinApi.getProviderImportSeed(p.id);
    } catch (e) {
      _flash('读取配置失败：$e');
      return;
    }

    if (!mounted) return;
    if (seed == null) {
      /*
       * 原版 `edit()` 的兜底文案：
       * > flash("该源没有可编辑的配置")
       *
       * 触发场景：内置源（后端 `get_provider_config` 对非第三方返回 null）
       * 或将来后端加了新的持久化形态而我们的模型不认识。
       */
      _flash('该源没有可编辑的配置');
      return;
    }

    final r = await ProviderImportDialog.showEdit(
      context,
      seed: seed,
      name: p.name,
    );
    if (!mounted) return;
    await _afterImport(r);
  }

  /// 弹窗返回后的统一收尾（刷新 + 提示）
  ///
  /// # 为什么抽出来
  ///
  /// 「导入源」与「编辑」两条路径的收尾**完全相同**（原版也是 ——
  /// `doImport` / `doInstallHttp` 各自 `closeImport()` 后都走
  /// `store.loadProviders()` + `flash(...)`）。
  /// 抽一处避免"改了导入忘了改编辑"。
  Future<void> _afterImport(ProviderImportResult r) async {
    switch (r) {
      /*
       * ⚠️ TVBox 导入的"取消"里**可能带着已完成的结果**（task-5）
       *
       * TVBox 是"先出结果清单、用户点完成才关窗"，关窗走的还是
       * 取消按钮那条路。如果这里直接 return，源明明已经落库了，
       * 列表却不刷新 —— 用户以为导入失败，其实得手动重进页面才能看见。
       * 见 `provider_import_dialog.dart` 的 `ProviderImportCancelled.done`。
       */
      case ProviderImportCancelled(done: final ProviderImportDone d):
        await loadAll();
        widget.onProvidersChanged?.call();
        _flash(d.toast);
      case ProviderImportCancelled():
        // 用户关掉了弹窗 —— 什么都不做（不是错误，不该弹提示）
        return;
      case ProviderImportDone(:final toast):
        /*
         * ⚠️ 必须**重新拉列表**而不是本地插入一条
         *
         * 同 id 覆盖时后端会替换掉原条目（`list.retain(|x| x.id() != ...)`），
         * 本地插入会留下两条同名源。
         */
        await loadAll();
        widget.onProvidersChanged?.call();
        _flash(toast);
    }
  }

  /// ★ 健康检测（原版 `sweep()`，`SettingsView.vue:1490`）
  ///
  /// # 原版的反馈逻辑（逐字对齐，这是本按钮的**全部价值**）
  ///
  /// ```ts
  /// const r = await provApi.healthSweep();
  /// const bad = Object.entries(r).filter(([, ok]) => !ok);
  /// flash(bad.length ? `${bad.length} 个源不可用` : "全部正常");
  /// ```
  ///
  /// ⚠️ **不能只显示"检测完成"** —— 用户点这个按钮就是想知道
  ///    "哪些源挂了"。原版注释没写，但这是这个功能存在的唯一理由：
  ///    本机 26 个源，用户没法逐个点进去试。
  ///
  /// # 为什么不用返回值刷新本地 `_providers`
  ///
  /// `health_sweep` 更新的是后端的 `working` 状态，
  /// 而 `list_providers` 返回的 manifest 里带 `working` ——
  /// 所以理论上可以刷新。但原版**没有**刷新（只 flash），
  /// 我们保持一致：刷新会让 26 张卡片同时重绘，而检测期间
  /// 用户还在看结果文案，界面跳一下反而干扰。
  Future<void> _healthSweep() async {
    setState(() => _sweeping = true);
    try {
      final r = await SourinApi.healthSweep();
      // 后端返回 `id → 是否可用`；不可用的挑出来计数
      final bad = r.entries.where((e) => !e.value).toList();
      if (bad.isEmpty) {
        _flash('全部正常（${r.length} 个源）');
      } else {
        /*
         * ★ 报出**具体哪几个**不可用，不只是数量
         *
         * 原版只 flash 了数量（`${bad.length} 个源不可用`），
         * 但数量对用户没用 —— 他还得自己猜是哪个。
         * 26 个源里挑 3 个坏的名字，比"3 个源不可用"有用得多。
         * 名字取不到就退回 id（`nameOf` 的兜底逻辑与排序面板一致）。
         */
        final names = bad
            .take(5)
            .map(
              (e) =>
                  _providers.where((p) => p.id == e.key).firstOrNull?.name ??
                  e.key,
            )
            .join('、');
        final more = bad.length > 5 ? ' 等 ${bad.length} 个' : '';
        _flash('${bad.length} 个源不可用：$names$more');
      }
    } catch (e) {
      _flash('健康检测失败：$e');
    } finally {
      if (mounted) setState(() => _sweeping = false);
    }
  }

  /// ★ 重新加载全部 JS 插件（原版 `reloadPlugins()`，`SettingsView.vue:1027`）
  ///
  /// ```ts
  /// const n = await plugApi.reload();
  /// await loadPlugins();  await store.loadProviders();
  /// flash(`已重新加载 ${n} 个插件`);
  /// ```
  ///
  /// # 为什么这个按钮必须存在
  ///
  /// 用户手工把 `.js` 文件放进 `plugins/` 目录后，**界面不会自己发现** ——
  /// 没有这个按钮就只能重启程序。改了插件源码同理。
  Future<void> _reloadPlugins() async {
    setState(() => _pluginBusy = true);
    try {
      final n = await SourinApi.reloadPlugins();
      await loadAll();
      widget.onProvidersChanged?.call();
      _flash('已重新加载 $n 个插件');
    } catch (e) {
      _flash('重新加载失败：$e');
    } finally {
      if (mounted) setState(() => _pluginBusy = false);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  片头片尾总览（集成任务 M）
  // ═══════════════════════════════════════════════════════════════════

  // ═══════════════════════════════════════════════════════════════════
  //  插件
  // ═══════════════════════════════════════════════════════════════════

  /// 从 URL 安装插件
  Future<void> _installPlugin() async {
    final url = await _promptText(title: '安装 JS 插件', hint: '插件地址（支持各种插件市场的链接）');
    if (url == null || url.trim().isEmpty) return;

    _flash('正在下载…');
    try {
      final r = await SourinApi.installPlugin(url.trim());
      await loadAll();
      widget.onProvidersChanged?.call();
      _flash('已安装「${r.name}」v${r.version}（${r.bytes} 字节）');
    } catch (e) {
      _flash('安装失败：$e');
    }
  }

  /// 添加插件（task-10 ③：与「编辑」共用同一个表单）
  ///
  /// # 改前
  /// ```text
  /// 一个多行框，只能贴**源码**（`install_plugin_source`）。
  /// 想按链接装得去另一个入口（「从链接安装」），用户要自己先判断
  /// 「我手上这个算哪种」—— 而 Owner 的诉求正是「一个表单，自动识别」。
  /// ```
  Future<void> _installPluginSource() async {
    if (!mounted) return;
    final r = await showPluginEditDialog(context: context);
    if (r == null || !mounted) return;

    try {
      if (r.kind == PluginInputKind.link) {
        // 链接型 ⇒ 走「按链接安装」（会解析插件市场链接并记住来源）
        final res = await SourinApi.installPlugin(r.text);
        await loadAll();
        widget.onProvidersChanged?.call();
        _flash('已安装「${res.name}」v${res.version}');
      } else {
        // 源码型 ⇒ 新建（文件不存在也能建，与 savePluginSource 不同）
        final res = await SourinApi.installPluginSource(r.text);
        await loadAll();
        widget.onProvidersChanged?.call();
        _flash('已安装「${res.name}」v${res.version}');
      }
    } catch (e) {
      _flash('安装失败：$e');
    }
  }

  /// 打开「插件更新」弹窗（检测更新 + 更新历史/回滚）—— task-23
  ///
  /// # 为什么把所有东西塞进一个弹窗
  ///
  /// 卡片只有 **299px 宽**（4 列），放不下"当前版本 / 来源链接 / 检测结果 /
  /// 历史档列表 / 回滚按钮"这些内容。弹窗有 480px 宽 + 有界高度，
  /// 是唯一能讲清楚的地方。
  ///
  /// # 交互（照 `_SkipHistoryDialog` / `_OrderDialog` 的既有模式）
  ///
  /// ```text
  /// 打开弹窗 → 显示当前版本 + 来源链接 + 历史档列表
  ///         → 用户点「检测更新」才**联网**（打开时绝不自动查）
  ///         → 有新版 → 出现「更新到 vX.Y.Z」按钮（用户点才覆盖）
  ///         → 历史档每行一个「回滚」按钮
  /// ```
  ///
  /// ⚠️ **打开弹窗时不自动检测** —— 那是网络请求，
  ///    用户只是看一眼历史也会被发一次请求（还慢）。
  ///    这正是 `list_plugin_sources` 与 `check_*` 分开的原因。
  Future<void> _openPluginUpdate(String id, String name) async {
    final src = _pluginSources[id];
    if (src == null) {
      /*
       * 理论上进不来（卡片上没按钮就不会调这里），
       * 但**防御性**保留：宁可什么都不做，也不要弹一个查不了的窗口。
       */
      _flash('这个插件没有安装链接，无法检测更新');
      return;
    }

    final changed = await showAppDialog<bool>(
      context: context,
      builder: (_) => _PluginUpdateDialog(id: id, name: name, sourceUrl: src),
    );

    // 弹窗里做过更新/回滚 → 刷新列表（版本号、配置声明都可能变）
    if (changed == true && mounted) {
      await loadAll();
      widget.onProvidersChanged?.call();
    }
  }

  /// 打开 TVBox 源的「订阅更新」弹窗（检测更新 / 一键更新 / 补填订阅链接）
  ///
  /// 与上面的 `_openPluginUpdate` **同构**，只有两点不同：
  /// ```text
  /// 1. 判据是 `_tvboxSources[id]` 的**存在性**，不是 `sourceUrl != null`
  ///    —— 贴文本导入的 TVBox 源没有链接，但用户可以在弹窗里补填，
  ///      这正是 `TvboxUpdateDialog` 存在的意义（见它的 `_hasLink`）。
  /// 2. 弹窗构造走 `TvboxUpdateDialog.show(...)`（它自己包了 `showDialog`）。
  /// ```
  ///
  /// **打开弹窗时不自动检测** —— 与插件那条同一个原则：
  /// 检测是联网动作，只在用户**真的点按钮**时才跑。
  Future<void> _openTvboxUpdate(String id, String name) async {
    final src = _tvboxSources[id];
    if (src == null) {
      /*
       * 理论上进不来（卡片上没按钮就不会调这里），防御性保留。
       *
       * 判据是 `src == null`（后端不认识这个 id），
       * **不是** `src.sourceUrl == null` —— 后者是「没有链接但能补填」，
       * 必须让它进弹窗，否则用户永远补不上链接。
       */
      _flash('这个 TVBox 源没有登记订阅信息，无法检测更新');
      return;
    }

    final changed = await TvboxUpdateDialog.show(
      context,
      id: id,
      name: name,
      sourceUrl: src.sourceUrl,
    );

    // 弹窗里做过更新 / 改过链接 → 刷新列表（名字、链接都可能变）
    if (changed && mounted) {
      await loadAll();
      widget.onProvidersChanged?.call();
    }
  }

  Future<void> _removePlugin(PluginEntry e) async {
    final ok = await _confirm(
      title: '删除插件',
      message: '确定删除「${e.name}」吗？此操作不可撤销。',
    );
    if (!ok) return;
    try {
      await SourinApi.removePlugin(e.file);
      await loadAll();
      widget.onProvidersChanged?.call();
      _flash('已删除「${e.name}」');
    } catch (err) {
      _flash('删除失败：$err');
    }
  }

  /// 编辑插件（task-10 ③：改成与「添加」共用的表单）
  ///
  /// # 改前
  /// ```text
  /// 直接 `SourinApi.readPlugin(e.file)` 读**整份源码**塞进多行框。
  /// ⇒ 一个按**链接**安装的插件，点「编辑」看到的是 2 万字 JS，
  ///   用户想改的那个链接**根本不显示**（Owner 原话：
  ///   「js插件既然已经用链接了,为什么点击编辑还是显示的插件代码?而不是编辑链接?」）。
  /// ```
  ///
  /// # 改后
  /// ```text
  /// 走共用表单 `showPluginEditDialog(existing: e)`，类型由**表单内部**判定：
  ///   · 有真实安装来源（`plugins/.meta/<id>.json` 的 `source_url`）⇒ 链接型
  ///   · 没有 ⇒ 源码型
  ///
  /// ⚠️ 2026-10-09 修：原来判据是 `PluginEntry.upstream` 非空 —— 那是**上游接口地址**
  ///    （不是安装来源），于是手写插件被误判成链接型 ⇒ 编辑框预填接口地址、
  ///    保存时走 `installPlugin(接口地址)` ⇒ **覆盖坏本地插件**。
  ///    判据现在抽在 `plugin_edit_dialog.dart` 的 `kindForExisting()` 里（纯函数，可单测）。
  /// ```
  Future<void> _editPlugin(PluginEntry e) async {
    if (!mounted) return;
    final r = await showPluginEditDialog(context: context, existing: e);
    if (r == null || !mounted) return;

    try {
      if (r.kind == PluginInputKind.link) {
        /*
         * ★ 链接型：走既有的「按链接安装」（`install_plugin`）。
         *
         * ⚠️ 为什么不调 `savePluginSource`：那个是「编辑已有插件的源码」，
         *    它会把 sidecar 文件覆盖成这段文本 —— 传一个 URL 进去，
         *    插件文件就变成了一行网址，**插件直接坏掉**。
         *    链接型的「改上游」在 Rust 侧就是重新安装（install_plugin 会
         *    按 id 覆盖同名插件并记住新的安装链接）。
         */
        final res = await SourinApi.installPlugin(r.text);
        await loadAll();
        widget.onProvidersChanged?.call();
        _flash('已更新「${res.name}」v${res.version}');
      } else {
        /*
         * ⚠️ `savePluginSource` 是「编辑**已有**插件」——
         *    文件不存在会报错。新建要用 `installPluginSource`。
         */
        await SourinApi.savePluginSource(e.file, r.text);
        await loadAll();
        widget.onProvidersChanged?.call();
        _flash('已保存');
      }
    } catch (err) {
      _flash('保存失败：$err');
    }
  }

  /// 配置插件（按插件声明的字段渲染表单）
  Future<void> _configPlugin(PluginEntry e) async {
    PluginConfig cfg;
    try {
      /*
       * ★ 用 `pluginConfigGet` 拿「声明 + 当前值」
       *
       * ⚠️ 不能从 `listPlugins` 的 `config` 直接渲染 —— 那个字段
       *    来自静态解析，**永远是空的**（原版踩过的坑：设置页
       *    死活不显示「配置」按钮，而且不报错）。
       */
      cfg = await SourinApi.pluginConfigGet(e.id);
    } catch (err) {
      _flash('读取配置失败：$err');
      return;
    }

    if (cfg.fields.isEmpty) {
      _flash('「${e.name}」没有可配置项');
      return;
    }

    if (!mounted) return;
    final values = await showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PluginConfigDialog(name: e.name, config: cfg),
    );
    if (values == null) return;

    try {
      final n = await SourinApi.pluginConfigSet(e.id, values);
      await loadAll();
      widget.onProvidersChanged?.call();
      _flash('已保存 $n 项配置');
    } catch (err) {
      _flash('保存失败：$err');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  合并后的「JS 插件」区块 —— 两个从 `_PluginTile` 并过来的查表
  // ═══════════════════════════════════════════════════════════════════

  /// 已启用的源数（块头 `trailing` 用）
  ///
  /// ⚠️ 用 `_providers` 而不是 `_plugins.plugins` —— 判据是
  ///    `ProviderManifest.enabled`（用户的偏好，后端 `disabled-providers.json`
  ///    的真相），而 `PluginEntry` 上**没有**这个字段。
  int get _enabledCount => _providers.where((p) => p.enabled).length;

  /// 这个源对应的**插件文件名**（`154.js`），没有则 `null`
  ///
  /// # 为什么需要（合并后从 `_PluginTile` 并过来的）
  ///
  /// `_PluginTile` 第二行原本显示 `entry.file`，用户靠它**对上磁盘上的
  /// 文件**（「我改的到底是哪一个」）。删掉 tile 之后这行信息不能丢。
  ///
  /// ⚠️ `PluginEntry.id` 是插件源码里的 `@id`，与 `ProviderManifest.id`
  ///    是**同一个东西**（后端 `list_plugins` 就是按 `meta.id == m.id`
  ///    去 `registry` 里找 manifest 的）—— 所以按 id 匹配是对的。
  ///    匹配不到（内置 / 声明式 / HTTP 源，或插件刚被删）返回 `null`，
  ///    卡片上就不显示文件名，**不编一个出来**。
  /// ★ task-5（缺陷 5）：一次查到**整条** `PluginEntry`（不再只取文件名）
  ///
  /// 卡片要用它的三样东西：
  /// ```text
  /// file      插件文件名（`154.js`）—— 描述行显示，用户靠它对上磁盘文件
  /// author    来源标识的**唯一判据**（tvbox-convert / dsh / sourin）
  /// upstream  上游接口地址（头部注释或正文 `const API`）
  /// ```
  /// 原先是 `_pluginFileOf`（只返回 `file`）—— 加后两样时改成返回整条，
  /// 免得同一张卡做三次 `where(...).firstOrNull` 查找。
  PluginEntry? _pluginOf(String id) =>
      _plugins.plugins.where((e) => e.id == id).firstOrNull;

  /// 这个源的「配置」按钮回调，**没有可配置的插件时返回 `null`**
  ///
  /// # 为什么是 null 而不是"永远给一个回调"
  ///
  /// 原版 `_PluginTile` 的「配置」按钮是**无条件显示**的，注释写着：
  /// > ⚠️ 但这里的 `entry.config` 来自 `listPlugins`，那个字段**永远是空的**
  /// >    （静态解析拿不到）。所以按钮**总是显示**，点进去再调
  /// >    `pluginConfigGet` 拿真实声明 —— 没有可配置项时给明确提示。
  ///
  /// 我们保留这个语义（点进去有明确提示，比"没按钮"更能告诉用户
  /// 「这里本来可以配」），但**只对有插件文件的源**给按钮：
  /// 内置 / 声明式 / HTTP 源根本没有插件配置文件，
  /// `pluginConfigGet(内置源 id)` 必然报错 —— 那不是"没有可配置项"，
  /// 而是"这个东西不存在"，给按钮才是骗人。
  ///
  /// ⚠️ 两个分支都走 `_configPlugin` / `_flash`，**不另写一套逻辑**。
  VoidCallback? _configOf(String id) {
    final e = _pluginOf(id);
    if (e == null) return null;
    return () => _configPlugin(e);
  }

  /// 「移除 / 删除」按钮 —— **按 kind 分派**（合并时发现的关键差异）
  ///
  /// # ★★ 为什么不能只用 `_removeProvider`
  ///
  /// 原版对这两种源用的是**两个不同的后端命令**：
  ///
  /// ```text
  /// JS 插件卡片     confirmRemovePlugin(p)  → plugApi.remove(p.file)
  ///                                          = remove_plugin
  ///                                          **把 .js 文件从磁盘删掉**
  ///
  /// 传统源卡片      remove(p)               → provApi.remove(p.id)
  ///                                          = remove_provider
  ///                                          只从 registry 摘掉
  /// ```
  ///
  /// 我们这边两个命令的语义（`commands_provider.rs`）：
  /// ```text
  /// remove_provider(id)    registry.unregister(id) + 从第三方清单里 retain 掉
  /// remove_plugin(file)    读文件拿 @id → unregister → **std::fs::remove_file**
  /// ```
  ///
  /// ⚠️ 对 JS 插件只用 `remove_provider` 会留下**幽灵源**：
  ///    registry 里没了，但 `plugins/xxx.js` **还在磁盘上** ——
  ///    下次「重新加载」或重启，`load_plugins` 又把它注册回来，
  ///    用户会看到「我明明删了，它又自己回来了」。
  ///
  /// 这正是本项目反复强调的那类 bug ——
  /// `persist_from_registry` 的注释：
  /// > 避免两处状态不一致（用户移除源后忘了同步清单 = **幽灵源复活**）
  ///
  /// # 判据为什么是 `kind == 'js'`
  ///
  /// ```text
  /// js            源的真身在磁盘（plugins/*.js）→ 必须删文件
  /// declarative   真身在 third-party-providers.json → unregister + persist 就够
  /// http          同上
  /// builtin       编译在核心里，**两个都不该调**（调用方已置灰）
  /// ```
  /// 与 `_editProvider` 的分派**同构**（那边也是 `kind == 'js'` 走插件路径）。
  VoidCallback _removeOf(ProviderManifest p) {
    if (p.kind == 'js') {
      final e = _plugins.plugins.where((x) => x.id == p.id).firstOrNull;
      /*
       * 找不到插件条目（文件刚被手工删掉）→ 退回 `_removeProvider`。
       * ⚠️ 不能直接 return null：按钮会变哑巴，用户不知道发生了什么。
       *    退回的那条路至少把 registry 里的残留清掉，并给明确提示。
       */
      if (e != null) return () => _removePlugin(e);
    }
    return () => _removeProvider(p);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  遥控
  // ═══════════════════════════════════════════════════════════════════
  Future<void> _startRemote() async {
    setState(() => _remoteBusy = true);
    try {
      final st = await SourinApi.remoteStart();
      if (mounted) setState(() => _remote = st);
      // ★ 手动开启 = 用户希望它开着 → 后端会记 auto_start=true
      final auto = await SourinApi.remoteAutoStart();
      if (mounted) setState(() => _remoteAutoStart = auto);

      /*
       * ★★ 唤醒遥控桥（2026-09-25 修 —— 少了这行的后果很严重）
       *
       * # 为什么必须在这里叫一声
       *
       * 桥的轮询只在 `RemoteBridgeHost.initState` 里尝试启动一次，
       * 而**那一刻遥控必然还没开**（应用刚起来）→ 桥判定"没开"就
       * 不再轮询。用户随后点这个按钮把服务开起来了，桥却**不知道** ——
       * 于是：
       * ```text
       * 手机上发命令 → 进 Rust 队列 → 没有人 take_commands
       *             → 手机永远"没有找到结果" / 点了没反应
       * ```
       * 用户唯一的出路是**重启应用**，而他完全猜不到要这么做。
       *
       * ⚠️ `notifyEnabled()` 而不是 `setGlobals(...)`：
       *    后者会覆盖已注册的能力（见 remote_bridge.dart 的说明），
       *    而这里只想"叫醒它"。
       *
       * 注：`remote_bridge.dart` 里 `_ensurePolling` 现在也有 5 秒一次的
       *     兜底复查（E），所以**本行不是唯一保障** —— 但它让"点一下
       *     立刻生效"，而不是等最多 5 秒。
       */
      RemoteBridge.instance.notifyEnabled();

      _flash('遥控已开启');
    } catch (e) {
      /*
       * ★ 端口占用的错误文案由后端生成（会区分"谁占了"）——
       *    直接透传给用户，不要再包一层
       */
      _flash('$e');
    } finally {
      if (mounted) setState(() => _remoteBusy = false);
    }
  }

  Future<void> _stopRemote() async {
    setState(() => _remoteBusy = true);
    try {
      final st = await SourinApi.remoteStop();
      if (mounted) setState(() => _remote = st);
      final auto = await SourinApi.remoteAutoStart();
      if (mounted) setState(() => _remoteAutoStart = auto);
      /*
       * ★ 如实告知是否真的停了
       *
       * 原版注释：
       * > 超时了要**如实告诉用户**，而不是假装成功 ——
       * > 否则他下一次点「开启遥控」会撞 10048，又是一头雾水。
       */
      _flash(st.stopped == true ? '遥控已关闭' : '遥控关闭超时，端口可能仍被占用');
    } catch (e) {
      _flash('$e');
    } finally {
      if (mounted) setState(() => _remoteBusy = false);
    }
  }

  Future<void> _refreshPin() async {
    try {
      final st = await SourinApi.remoteRefreshPin();
      if (mounted) setState(() => _remote = st);
      _flash('配对码已更新');
    } catch (e) {
      _flash('$e');
    }
  }

  Future<void> _setFixedPin() async {
    final pin = await _promptText(title: '固定配对码', hint: '4~8 位数字（留空则清除）');
    if (pin == null) return;

    try {
      final st = await SourinApi.remoteSetFixedPin(pin.trim());
      if (mounted) setState(() => _remote = st);
      _flash(pin.trim().isEmpty ? '已清除固定码' : '已设置固定码');
    } catch (e) {
      /*
       * ★ 与随机码重合的错误由后端拒绝（否则「换一个」会把固定码也改掉）
       */
      _flash('$e');
    }
  }

  Future<void> _toggleRemoteAutoStart(bool v) async {
    try {
      await SourinApi.remoteSetAutoStart(v);
      if (mounted) setState(() => _remoteAutoStart = v);
      _flash(v ? '已开启开机自启' : '已关闭开机自启');
    } catch (e) {
      _flash('$e');
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _flash('已复制');
  }

  // ═══════════════════════════════════════════════════════════════════
  //  同步  ★ 2026-09-29 整段搬走
  // ═══════════════════════════════════════════════════════════════════
  //
  // 用户原话：
  // > 云盘同步合并到备份二级页去
  //
  // 原来这里有四个方法 —— `_configureWebdav` / `_testSync` /
  // `_syncNow` / `_disconnectSync` —— 现在都在
  // `lib/ui/widgets/sync_panel.dart` 的 `_SyncPanelState` 里，
  // 逻辑一字未改（只有两处刻意改进，见那个文件头）。
  //
  // 一级页现在只剩 `lib/ui/settings/backup_page.dart` 的入口行
  // （在下面「数据与外观」分组里），点进去才是这些按钮。

  // ═══════════════════════════════════════════════════════════════════
  //  备份
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _backupPreview() async {
    try {
      final p = await SourinApi.backupPreview();
      if (!mounted) return;
      final lines = p.counts.entries
          .map((e) => '${e.key}: ${e.value}')
          .join('\n');
      await _confirm(
        title: '备份内容预览',
        message: '将导出：\n\n$lines\n\n插件：${p.plugins.length} 个',
        okLabel: '知道了',
        cancelLabel: null,
      );
    } catch (e) {
      _flash('$e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  通用对话框
  // ═══════════════════════════════════════════════════════════════════

  Future<bool> _confirm({
    required String title,
    required String message,
    String okLabel = '确定',
    String? cancelLabel = '取消',
  }) async {
    final r = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          if (cancelLabel != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(cancelLabel),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(okLabel),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  Future<String?> _promptText({
    required String title,
    required String hint,
    String initial = '',
    int maxLines = 1,
  }) async {
    final ctl = TextEditingController(text: initial);
    final r = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          maxLines: maxLines,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctl.dispose();
    return r;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  构建
  // ═══════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 这一行的判据与 `loadAll()` 的守卫**同源**（task-3，2026-09-25）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 用户原话
     *
     * > 设置页我往下滑,会自动往上滚动
     *
     * # 真正的修复在 `loadAll()` 的 L356 那行守卫，**不在这一行**
     *
     * 实测统计（`.probe/probe_tests/zz_t3_q_test.dart` 的 PROBE3C Q1，
     * 剥注释后统计全文件的赋值点）：
     * ```text
     * bool _loading = true;                                ← 字段初值
     * if (mounted && !_firstLoadDone) ... _loading = true;  ← ★ 唯一刷新赋值，带守卫
     * finally: _loading = false; _firstLoadDone = true;     ← 同一个 setState
     * ⇒ 状态 (_loading == true AND _firstLoadDone == true) **不可达**
     * ⇒ 所以这一行读裸 `_loading` 与读 `_loading && !_firstLoadDone`
     *   **行为完全等价**
     * ```
     * ⇒ 我一度想把它改成 `if (_loading && !_firstLoadDone)`，
     *   但那经证明是 **behavioral no-op**，而且会**打断**
     *   `test/orchestrator_scroll_fix_verified_test.dart` 里
     *   「★ 转圈分支挂在 _loading 上（不是被短路掉）」那条守卫
     *   （它匹配字面量 `if (_loading)`）。
     *   ★ 为零行为收益去打断一条既有守卫 = 净负，所以**不改**。
     *
     * # 但"等价"是**巧合耦合**，不是设计 —— 后人必须知道
     *
     * ```text
     * 现在的等价性**完全依赖** L356 那行守卫。
     * ⚠️ 若哪天有人在别处加一个 `_loading = true`（比如"下拉刷新"、
     *    "核心重启后重载"），等价立刻破裂 ⇒ `build()` 会走转圈分支
     *    ⇒ ListView 被整个替换 ⇒ **滚动归零的 bug 重新出现**，
     *    而且没人会想到根因在这里。
     * ```
     * ★ 所以这条注释是**防御性记录**（铁律 65：判据与被测属性必须同源
     *   —— 这一行原本正是反例：`_loading` 是"本次请求还在飞"的**瞬时**
     *   状态，而"要不要显示整页转圈"只该由 `_firstLoadDone` 决定）。
     *
     * **若将来真要加第二个 `_loading = true` 赋值点**：
     * 就必须同时把这一行改成 `if (_loading && !_firstLoadDone)`，
     * 并同步更新上面那条测试的匹配串。两件事**必须一起做**。
     */
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        ListView(
          clipBehavior: Clip.antiAlias,
          // ⚠️ 不能加 `const` —— `Sp.bottomBarInset` 是 getter（TV/非 TV 不同值）
          // ★ 内容带（t509）：原版 `SettingsView.vue:1612 <div class="container">`
          //   —— 整页**只有一个** `.container`，`.page-head`（:1613）与各
          //   `section.block` 都是它的子节点、自身无横向内边距
          //   ⇒ 本页是 **×1**（首页分区轨道才是 ×2）。
          //   `Layout.horizontalInsetOf` = 居中留白 + 容器内边距（一次给全）。
          padding:
              Layout.horizontalInsetOf(context) +
              EdgeInsets.only(top: Sp.x8, bottom: Sp.bottomBarInset),
          children: [
            // ── 页头 ──
            /*
             * ★★★ task-44 ③：修「三层字重叠太近」（用户实测报的问题）
             *
             * # 用户原话
             * ```text
             * 3.设置这三层字重叠的太近了
             * ```
             *
             * # 三层字是哪三层（截图像素实测，见 .probe/run-set/）
             * ```text
             * 「设置」                FontSizes.xl = 28   y=75..97
             *    ↕ 实测 7px（其中 SizedBox 只占 4px）
             * 「内容源、网络与同步」    FontSizes.sm = 14   y=105..117
             *    ↕ ★★ 实测 **1px**  ← 用户说的"重叠"
             * 「局域网遥控」           _Block title（lg=20） y=119..136
             * ```
             * ★ 第三层**紧贴**第二层 —— 裁图放大后肉眼可见两行几乎相接。
             *
             * # 根因（不是"字号大"，是**间距来源缺失**）
             * ```text
             * `SettingsBlock` 的 padding 是 `fromLTRB(24, **0**, 24, Sp.x8=32)`
             *   ⇒ **top = 0**：块与块之间靠"前一块的 bottom 32px"撑开 ⇒ 正确
             *   ⇒ ★★ 但**页头之后的第一块**：页头没有 bottom ⇒ **0px** ⇒ 重叠
             * ```
             * ⇒ 所以修法有**两个选择**，我选后者：
             * ```text
             * A. 改 `SettingsBlock.top` ⇒ ✗ **会同时影响所有堆叠块** ⇒ 块间距翻倍
             * B. ★ 给**页头**加底部间距 ⇒ ✓ 只修"页头→首块"这一处，零副作用
             * ```
             *
             * # 间距取值 = 与**块间节奏一致**
             * 实测块与块之间 = **33px**（= `Sp.x8` 32px + 行高余量）
             * ⇒ 这里用 `Sp.x8`（32px）⇒ 页头与首块的节奏和块间**同档**，
             *   不会出现"某处特别松/特别紧"。
             *
             * ⚠️ 标题→副标题也从 `Sp.x1`(4px) 放宽到 `Sp.x2`(8px)：
             *    28px 的标题与 14px 的副标题只隔 4px 偏挤（材料设计惯例
             *    标题与副标题 ≥ 4px，但**对 28px 大标题**应更宽）。
             */
            _Section(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '设置',
                    style: TextStyle(
                      fontSize: FontSizes.xl,
                      fontWeight: FontWeights.semibold,
                      color: colors.onSurface,
                    ),
                  ),
                  // ★ 4px → 8px（28px 大标题与 14px 副标题需要更宽的呼吸）
                  const SizedBox(height: Sp.x2),
                  Text(
                    // ⚠️ 这句副标题被 4 处间距测试当作**锚点字符串**
                    //   （task44_header_spacing / task44_spacing_pixels /
                    //   t88_cloudsync_move），改它会连带让那些像素级守卫失效，
                    //   而它本身并不误导用户 ⇒ 保持原样。
                    '内容源、网络与同步',
                    style: TextStyle(
                      fontSize: FontSizes.sm,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),

            /*
             * ★★★ 页头 → 首块的间距（task-44 ③ 的核心修复）
             *
             * ⚠️ 放在**页头之外**（而不是页头 Column 的末尾）——
             *    这样"页头"这个组件本身不含外部间距，
             *    将来若有人复用页头不会带上一个说不清的 32px。
             */
            const SizedBox(height: Sp.x8),

            // ── 局域网遥控（仅 TV / 桌面，手机端已裁剪）──
            /*
             * ★★★ 2026-10-02 用户原话：
             * > 手机端不需要遥控,需要裁剪掉
             *
             * 手机端**不显示**这一块，两条理由：
             *  1. 手机本身就是那个"遥控器"（用它去遥控 TV），
             *     自己不需要被遥控 —— 这块 UI 对手机是纯负担；
             *  2. 实测这台手机（1080x2400@420dpi ⇒ 逻辑宽 411.43）上，
             *     这一块**独占设置页首屏**（见 .probe\phone-tv-survey\p_set.png），
             *     把「内容源」整个挤到第二屏 —— 而内容源才是设置页的头等事。
             *
             * ⚠️ 用**运行时**判定 Device.isTouchOnly，不用编译期裁剪：
             *    编译期删掉会让 _RemotePanel / _startRemote / _stopRemote /
             *    _refreshPin / _setFixedPin 变成不可达，flutter analyze 报
             *    unused_element。与下面「PC 播放手势」(:1864)、
             *    「播放手势」(:1871) 的既有写法保持一致。
             *
             * ⚠️ 只藏 UI 不够：lib/shell.dart 里 RemoteBridgeHost 的挂载点
             *    也必须按设备门控（见该处注释），否则手机照样在监听遥控端口。
             */
            /*
             * ★★★ 2026-10-10：分组标签提到**首块之前**
             *
             * 改前这一页的结构是：
             * ```text
             * 设置 / 内容源、网络与同步
             * ┌ 局域网遥控 ─────────────┐   ← 没有组，孤零零顶在最上面
             * ┌ JS 插件              ›  ┐
             *   内容源                     ← 组标签跑到第二个块**下面**
             * ┌ Emby                  ›  ┐
             *   播放与观看
             * ```
             * ⇒ 「局域网遥控」没有任何组，「JS 插件」上无组下有组 ⇒ 读不出结构。
             *
             * ⇒ 每一块之前都先给它自己的组标签：组标签的 `top` 间距
             *   会自然把上一组推开，第一组由下面那个 Sp.x8 兜住。
             */
            if (!Device.isTouchOnly) ...[
              const SettingsGroupLabel(text: '远程'),
              _RemoteBlock(
                running: _remote?.running == true,
                autoStart: _remoteAutoStart,
                busy: _remoteBusy,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  /*
                   * ★ 开机自启放在状态区**之上**
                   *
                   * 原版注释：
                   * > 这是「它会不会自己起来」的开关，
                   * > 比「现在开着没有」更该先被看到。
                   */
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _remoteAutoStart,
                    onChanged: _toggleRemoteAutoStart,
                    title: const Text('开机自动开启'),
                    subtitle: Text(
                      '开启后每次启动程序都自动挂上遥控，不用再手动点。'
                      '关掉遥控会自动取消这个勾选。',
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),

                  if (_remote?.running != true)
                    /*
                     * ★ 2026-10-01：按钮与提示在窄屏改为**上下两行**。
                     *   原来 `Row(按钮 + Spacer文字)` 在 363 dp 内容区里
                     *   会把「默认端口 8642」挤成两行、或与按钮贴住。
                     *   宽屏仍是一行（`Wrap` 放得下就不换行 ⇒ 观感不变）。
                     */
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: Sp.x3,
                      runSpacing: Sp.x1,
                      children: [
                        FilledButton(
                          onPressed: _remoteBusy ? null : _startRemote,
                          child: Text(_remoteBusy ? '启动中…' : '开启遥控'),
                        ),
                        Text(
                          '默认端口 8642',
                          style: TextStyle(
                            fontSize: FontSizes.cap,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    )
                  else
                    _RemotePanel(
                      status: _remote!,
                      busy: _remoteBusy,
                      onStop: _stopRemote,
                      onRefreshPin: _refreshPin,
                      onSetFixedPin: _setFixedPin,
                      onCopy: _copy,
                    ),
                  ],
                ),
              ),
            ],
            // ── JS 插件（二级页入口，task-43）──
            /*
             * ★★★ 用户原话：
             * > js插件药放在二级页面
             *
             * 这一块原先是一级页的**整个区块**（370 行：6 个按钮 +
             * 26 张源卡片 + 失败插件列表）。现在整块进二级页，
             * 一级页只留这一行入口。
             *
             * ⚠️ 副标题必须能看出「里面有什么」—— 只写「JS 插件 ›」
             *    用户不知道里面还有安装 / 更新 / 排序 / 代理这些能力。
             *    条数用 `_providers.length` 实时算（与二级页一致）。
             */
            /*
             * ★★★ 2026-10-01：给「JS 插件」补上**分组标签**（Owner 报「排版混乱」）
             *
             * # 症状（手机截图，`.probe\n4_before_js.png`）
             * ```text
             * ┌ 局域网遥控 ──────────────────┐   ← SettingsBlock 标题（20px）
             * │  ……                          │
             * └──────────────────────────────┘
             * ┌ JS 插件              › ──────┐   ← ★ 孤立：上无组、下无组
             * └──────────────────────────────┘
             *   播放与观看                     ← 组标签（12px 小字）
             * ┌ 片头片尾             › ──────┐
             * └──────────────────────────────┘
             *   播放手势                       ← ★ 20px 大字，与「局域网遥控」同号
             * ```
             * # 乱在哪（三层字号互相打架）
             * ```text
             * 20px  SettingsBlock 标题（局域网遥控 / 播放手势 / 动画效果）
             * 12px  SettingsGroupLabel（播放与观看 / 数据与外观）
             * ```
             * ⇒ **12px 的"组"里装着 20px 的"块"** ⇒ 视觉上级别倒挂；
             *   而且「播放手势」「动画效果」与顶层的「局域网遥控」**同号同色**，
             *   看起来像三个平级大区块，实际前两者是「播放与观看」的下级。
             *   再加上「JS 插件」**一个组都没有** ⇒ 读起来没有结构。
             *
             * # 本次只做**最小**修复：把孤儿归组
             * ★ 给「JS 插件」补一个 `SettingsGroupLabel`，让它与下面两组同构。
             * ⚠️ **不动**字号层级（那是更大的改动，会牵动
             *   `task44_*` 三条像素断言与 `SettingsBlock` 的公开契约）——
             *   本次目标是"排版不乱"，不是重做设计系统。
             * ⚠️ 组标签必须放在 `SettingsEntryRow` **之前**，
             *   且**不能**插进 `SettingsBlock` 内部（它自带 padding）。
             */
            const SettingsGroupLabel(text: '内容源与插件'),
            SettingsEntryRow(
              icon: Icons.extension_outlined,
              title: 'JS 插件',
              subtitle: '${_providers.length} 个内容源 · 安装 / 编辑 / 更新 / 排序 / 代理',
              onTap: _openPluginsPage,
            ),
            /*
             * ★★★ 2026-10-06（task-33 ⑦）：Emby 二级页入口 —— 补上**缺失的接线**
             *
             * # 为什么必须补（这是一次真缺陷，不是「锦上添花」）
             * ```text
             * `settings/emby_page.dart` 717 行、task-35 写完并测过，
             * 但全仓 `EmbySettingsPage` 只在它**自己文件里**出现 ⇒
             * 没有任何一行代码能把用户送进去。
             * 首页那张 Emby 卡片点进去看到的是**内容源**，不是配置页。
             * ```
             * 这正是本文件 :151-160 记过的坑：
             * > 两个二级页都写好了，一级页一行入口都没有 ⇒ 功能对用户完全不可见。
             *
             * # 为什么放在「内容源」组里、紧跟「JS 插件」
             * Emby 的接入形态**就是**一个 JS 插件（emby.js），
             * 而这一组管的正是「这台设备上有哪些内容源、怎么配」。
             * 放在这里，用户从「JS 插件」往下看一行就能找到它。
             *
             * ⚠️ 副标题按本页规矩写清「里面有什么」（同 JS 插件那条）：
             *    安装插件 / 填服务器地址账号密码 / 连接自检。
             * ⚠️ 它**不**显示「已启用/未启用」——那要读 `_providers`，
             *    而 Emby 页自己会读插件状态（`plugin_config_get`），
             *    这里再算一次等于两份真相。
             */
            SettingsEntryRow(
              icon: Icons.album_outlined,
              title: 'Emby',
              subtitle: '媒体服务器 · 安装插件 / 服务器地址 / 连接自检',
              onTap: () => _openSubPage(const EmbySettingsPage()),
            ),

            /*
             * ══════════════════════════════════════════════════════════════
             * ★★★ 2026-09-28：「直播源」独立区块**已删除**，并入 JS 插件
             * ══════════════════════════════════════════════════════════════
             *
             * Owner 原话（两句，第二句推翻了第一句的形态）：
             * ```text
             * 直播源的配置也放到二级去
             * 直播源还是跟js源合并吧,毕竟也是插件提供的,开关也方便
             * ```
             *
             * # 为什么合并是**消重**而不是移植
             * ```text
             * 本机 26 个源**全是 JS 插件**，而"直播源"只是其中
             * `capabilities.live` 为真的那批 —— 同一批源。
             * 启停又都走 `setProviderEnabled` → `disabled-providers.json`
             * ⇒ 原先两个区块的两个开关，本来就是**同一个开关**。
             * ```
             *
             * # 能力一条都没少（合并后去哪找）
             * ```text
             * 开关    → JS 插件二级页，每张源卡片的「启用 / 停用」
             * 认直播  → 卡片上的「直播」能力 chip（`_capLabels`）
             * 看总数  → JS 插件块头的 `直播 N/M` chip（本次新增）
             * ```
             * ★ 直播页那两处「去 设置 → 直播源 配置」的提示已同步改成
             *   「设置 → JS 插件」—— 不改的话用户按提示找过去会**扑空**。
             */

            /*
             * ── 云盘同步 ── ★ 2026-09-29 整块搬走
             *
             * 用户原话：
             * > 云盘同步合并到备份二级页去
             *
             * 原来这里是 `_Block(title: '云盘同步', …)`，含「配置云盘 /
             * 测试连接 / 立即同步 / 断开」四个按钮和后端信息。
             * 现在它在 `lib/ui/widgets/sync_panel.dart` 里，挂在
             * 「备份与恢复」二级页（`settings/backup_page.dart`）的
             * 第二个区块 —— 一级页只剩下面「数据与外观」分组里的入口行。
             *
             * ⚠️ 这也是**方案 A 的延续**：原注释（见上）把「云盘同步」
             *    列进了"一级页保留"清单，但它是低频配置项 ——
             *    配一次就不再点，正该和备份一样藏深一层。
             */

            // ── 二级页入口（2026-09-25 任务 ㉙ 方案 A）──
            SettingsGroupLabel(text: '播放与观看'),
            SettingsEntryRow(
              icon: Icons.content_cut_outlined,
              title: '片头片尾',
              subtitle: _skipMarkers.isEmpty
                  ? '还没有设置过 · 在播放器底栏可以设置'
                  : '${_skipMarkers.length} 个作品已设置 · 查看 / 管理',
              onTap: () => _openSubPage(const SkipMarkersSettingsPage()),
            ),
            if (Device.isDesktop)
              SettingsEntryRow(
                icon: Icons.keyboard_outlined,
                title: 'PC 播放手势',
                subtitle: '方向键单击/长按 · 鼠标左右半屏',
                onTap: () => _openSubPage(const PcGesturesSettingsPage()),
              ),
            // ★ task-18：③④⑤ 的二级页（片段下载并发 / 缓存上限 / 分享日志）。
            //   标题「播放与下载」是**刻意**与播放器里那个「播放设置」面板
            //   区分的 —— 面板管字幕/音轨/倍速，这一页管下载与缓存。
            SettingsEntryRow(
              icon: Icons.download_outlined,
              title: '播放与下载',
              /*
               * ★ 2026-10-09：副标题跟着 log-dev 的改名走
               *
               * 他按 Owner 的要求把那一页的区块从「分享日志」重做成
               * 「**日志与反馈**」（并加了场景引导句「出问题时请把这份日志
               * 发给作者」+ 环境信息一键复制）——
               * ⇒ 一级页这行副标题若不跟着改，用户在这里看到的是旧名，
               *    点进去却找不到「分享日志」四个字（入口名与页内名不一致）。
               *
               * ⚠️ 只改**副标题**，标题「播放与下载」一个字不动 ——
               *    `test/task18_entry_test.dart` 把「一级页恰好一个
               *    『播放与下载』入口」钉成断言，不能新增同名入口。
               */
              subtitle: '片段下载并发 · 缓存上限 · 日志与反馈',
              onTap: () => _openSubPage(const PlaybackSettingsPage()),
            ),
            // ★ task-18 ①②：触摸手势的第二个入口（完整版）。
            //   ⚠️ 它和下面那个 `if (Device.isTouchOnly)` 的「播放手势」
            //   区块**是同一批设置的两个入口** —— 两边都读写
            //   `PlayerGestures` 的同一组键（`player.gesture.doubleTap.seconds`
            //   等），不存在两份状态，改哪边另一边的 `_GestureChoice` 都
            //   会在下一次 `setState` 时读到新值。
            //   这里**不**再用 `Device.isTouchOnly` 判断：触摸手势页自己
            //   会在非触摸端渲染一段「仅在触摸端可用」的说明（见
            //   `lib/ui/settings/touch_gestures_page.dart:72-92`），
            //   比把入口整个藏掉更容易让用户明白为什么没有档位可选。
            SettingsEntryRow(
              icon: Icons.touch_app_outlined,
              title: '触摸手势',
              subtitle: '双击左右侧 · 长按左右侧（触摸端生效）',
              onTap: () => _openSubPage(const TouchGesturesSettingsPage()),
            ),

            if (Device.isTouchOnly)
              _Block(
                title: '播放手势',
                trailing: Text(
                  '触摸操作',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                children: [
                  /*
                   * ── ① 双击左右侧快进快退 ──
                   */
                  _GestureToggle(
                    label: '双击左右侧快进快退',
                    hint: '左侧快退、右侧快进',
                    value: PlayerGestures.doubleTapEnabled,
                    onChanged: (v) => setState(() {
                      PlayerGestures.setDoubleTapEnabled(v);
                    }),
                  ),
                  if (PlayerGestures.doubleTapEnabled) ...[
                    const SizedBox(height: Sp.x3),
                    _GestureChoice<int>(
                      label: '双击步长',
                      options: PlayerGestures.doubleTapOptions,
                      value: PlayerGestures.doubleTapSeconds,
                      labelOf: (v) => '$v 秒',
                      onChanged: (v) => setState(() {
                        PlayerGestures.setDoubleTapSeconds(v);
                      }),
                    ),
                  ],

                  const SizedBox(height: Sp.x5),
                  Divider(color: colors.outlineVariant, height: 1),
                  const SizedBox(height: Sp.x5),

                  /*
                   * ── ② 长按左右侧倍速播放 ──
                   */
                  _GestureToggle(
                    label: '长按左右两侧：快进快退',
                    hint:
                        '按住左侧连续快退、按住右侧倍速快进'
                        '，松开恢复原速',
                    value: PlayerGestures.longPressEnabled,
                    onChanged: (v) => setState(() {
                      PlayerGestures.setLongPressEnabled(v);
                    }),
                  ),
                  if (PlayerGestures.longPressEnabled) ...[
                    const SizedBox(height: Sp.x3),
                    _GestureChoice<double>(
                      label: '长按右侧倍率（快进）',
                      options: PlayerGestures.longPressRateOptions,
                      value: PlayerGestures.longPressRate,
                      labelOf: (v) => '${v}x',
                      onChanged: (v) => setState(() {
                        PlayerGestures.setLongPressRate(v);
                      }),
                    ),
                    const SizedBox(height: Sp.x4),
                    /*
                     * ★ 手机自己的“连续快退”每步秒数
                     *
                     * 之前这个值**只能在 PC 那块改**，而手机长按又在读它
                     * —— 手机用户根本看不到自己的快退步长在哪里。
                     * 现在两端各自一个键，互不影响。
                     */
                    _GestureChoice<int>(
                      label: '长按左侧每步（连续快退）',
                      options: PlayerGestures.longPressRewindStepOptions,
                      value: PlayerGestures.longPressRewindStep,
                      labelOf: (v) => '$v 秒',
                      onChanged: (v) => setState(() {
                        PlayerGestures.setLongPressRewindStep(v);
                      }),
                    ),
                  ],
                ],
              ),

            /*
             * ══════════════════════════════════════════════════════════
             * ★★ task-55：动画效果（用户可选、可切换）
             * ══════════════════════════════════════════════════════════
             *
             * 用户原话（逐字）：
             * > 6.动画效果加一下,多个动画效果
             * > 然后还有个动画效果,我说让你多做几个**我来切换的**,这个你也没做
             *
             * ★ 关键在「**多个**」+「**我来切换的**」：
             *   我上一轮只"在某处加了一个淡入" ⇒ 只有一个效果、用户**不能选**
             *   ⇒ 用户说"没做"（他说得对）
             * ⇒ 这里给出 **6 种可选风格**，点了**立刻生效**并持久化。
             *
             * # 为什么放在「数据与外观」组**之前**
             * ```text
             * 它是**外观**类设置（与"主题"同类），
             * ★ 但比"主题"更常被调整（用户会来回试几种效果）
             * ⇒ 放在组内第一个位置，离"播放与观看"组近，容易找到
             * ```
             *
             * # 为什么用 `SettingsGestureChoice`（现成组件）
             * ```text
             * `lib/ui/widgets/settings_kit.dart` L240 已有通用的
             * "从 N 个里选 1 个"组件（`label`/`options`/`value`/`labelOf`/`onChanged`）
             * ⇒ ★ 复用它：外观与其它设置项**一致**，且零新组件
             *   （判据⑤"用惯用法"）
             * ```
             *
             * # 「立刻生效」是怎么做到的
             * ```text
             * `PageTransitionStyleStore.set(s)`：
             *   ① 更新 `ValueNotifier` ⇒ ★ shell 里监听它的
             *      `ValueListenableBuilder` **立刻重建** ⇒ 下次切 tab 用新风格
             *   ② `UiPrefs.set(key, s.name)` ⇒ 自动落盘（重启后仍在）
             * ⇒ 两者都在 `set()` 里，调用方只需一行
             * ```
             *
             * ⚠️ 我只**新增**这一个区块 —— 不碰本页任何既有区块
             *    （片头片尾 / 直播源配置 / JS 插件 / 云存储 / 主题 / 关于）
             */
            const SettingsGroupLabel(text: '外观'),
            _Block(
              title: '动画效果',
              children: [
                SettingsGestureChoice<PageTransitionStyle>(
                  label: '页面切换动画',
                  options: PageTransition.options,
                  value: PageTransitionStyleStore.current.value,
                  labelOf: (s) => s.label,
                  onChanged: (s) => setState(() {
                    // ★ 一行搞定：立刻生效（notifier）+ 持久化（UiPrefs）
                    PageTransitionStyleStore.set(s);
                  }),
                ),
                const SizedBox(height: Sp.x2),
                Text(
                  // ★ 动态显示"当前这种效果是什么样" ——
                  //   用户不用试就知道选了什么
                  PageTransitionStyleStore.current.value.hint,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),

            SettingsGroupLabel(text: '数据与外观'),
            SettingsEntryRow(
              icon: Icons.cloud_sync_outlined,
              title: '备份与恢复',
              subtitle: '导出 / 导入本机数据（合并，不覆盖）',
              onTap: () => _openSubPage(const BackupSettingsPage()),
            ),
            SettingsEntryRow(
              icon: Icons.palette_outlined,
              title: '主题',
              subtitle: '当前：${AppTheme.mode.label} · 跟随系统 / 浅色 / 深色',
              onTap: () => _openSubPage(const ThemeSettingsPage()),
            ),
            SettingsEntryRow(
              icon: Icons.info_outline,
              title: '关于',
              subtitle: '${SourinApi.version} · 架构与设备信息',
              onTap: () => _openSubPage(const AboutSettingsPage()),
            ),
          ],
        ),

        // ── Toast ──
        if (_toast != null)
          Positioned(
            left: 0,
            right: 0,
            /*
             * ★★ 2026-09-24 实测修复：`Sp.x10`(40) → `Sp.bottomBarInset`(90)
             *
             * # 原来的问题（真机截图取证，不是我猜的）
             *
             * 底栏改成了**悬浮玻璃**（`shell.dart` 的 Stack，不占布局空间），
             * 而 toast 只让了 40px —— 于是它**正好落在玻璃底栏底下**：
             * ```text
             * 截图（PrintWindow）：toast 被底栏的模糊层糊住，
             * 文字完全不可辨认，只看得见一团黑色圆角矩形
             * ```
             * 后果：**所有 `_flash()` 的反馈都读不到** ——
             * 包括这次任务 R 刚加的「N 个源不可用」「全部正常」
             *「已重新加载 N 个插件」「已导入「X」」。
             * 提示发出来了、用户看不见 = 等于没发。
             *
             * # 为什么用 `Sp.bottomBarInset` 而不是把数字调大
             *
             * 那个 token 的注释写着它的**存在理由**就是这件事：
             * > 页面内容底部留白 —— **给悬浮底栏让位**
             * > 桌面 底栏 58 + 间隙 12 + 余量 20 = 90
             * 它已经被 ListView 的 padding 用了（见 `build()` 开头），
             * 这里用同一个值，toast 与"内容最底边"对齐 ——
             * 视觉上一致，且**桌面/TV 自动分别取 90 / 110**
             *（TV 底栏更高，写死 90 在 TV 上仍会被盖）。
             *
             * ⚠️ 我自己定的教训：**新增"贴在底部"的浮动元素时，
             *    先看有没有现成的 inset token** —— 这个坑的代价是
             *    一个功能（健康检测）看起来"点了没反应"。
             */
            bottom: Sp.bottomBarInset,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Sp.x5,
                  vertical: Sp.x3,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.85),
                  borderRadius: Radii.rFull,
                ),
                child: Text(
                  _toast!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: FontSizes.sm,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _dataRev.dispose();
    _toastRev.dispose();
    super.dispose();
  }

  /// ★★★ JS 插件区块（含全部内容源）—— task-43 抽成方法，供二级页复用
  ///
  /// 用户原话：
  /// > js插件药放在二级页面
  ///
  /// # 为什么抽成方法，而不是搬到 `settings/plugins_page.dart`
  /// ```text
  /// 这一块 370 行，依赖本 State 的 22 个成员 + 约 1105 行私有 class
  /// （`_ProviderCard` 单它自己 892 行）。跨文件搬 = 22 个成员公开化
  /// + 私有类跟着走 —— 而本文件**有并发写入者**（实测到两次改动），
  /// 在上面做千行级搬移是「在移动的车上换引擎」。
  ///
  /// ⇒ 抽成方法 = **零字节搬动**：二级页调它，与一级页渲染的是
  ///   **同一段代码** ⇒ 功能丢失在结构上不可能，
  ///   而不是靠「我逐个比对过了」。
  /// ```
  /// 有**直播能力**的源（`capabilities.live`）
  ///
  /// # 判据：用**声明的能力位**，不是探测结果
  /// ```text
  /// 直播页 `_providerHasVideo()` 用探测结果（探到可播流才算）
  /// 而这里是**配置页** —— 配置页不该依赖运行期状态（进设置页时
  /// 可能还没探过）⇒ 用声明的能力位。
  /// ⚠️ 两者**判据不同是有意的**：直播页答"现在能看什么"，
  ///    这里答"这个源声称支持直播吗"。
  /// ⇒ 所以"这里列了 3 个、直播页只有 1 个"**不是 bug**，
  ///   是有的源声明了 live 但探不到可播流。
  /// ```
  ///
  /// ★ 2026-09-28：原 `_liveSourcesBlock` 区块已按 Owner 要求并入
  ///   JS 插件列表（理由见 `build()` 里调用点那段注释）。
  ///   本 getter 供块头的 `直播 N/M` chip 汇总用 —— 独立区块没了，
  ///   但"有几个直播源、启用几个"这个信息**不能丢**。
  List<ProviderManifest> get _liveSources =>
      _providers.where((p) => p.capabilities.live).toList(growable: false);

  /// 「JS 插件」tab 该列哪些源 —— **排除**直播源（Owner 2026-10-09）
  ///
  /// # Owner 原话
  /// ```text
  /// > 我在js插件还看到了直播源,这两个要分隔开啊,不要在js插件里面有直播源,
  /// > 两块分开显示
  /// ```
  ///
  /// # 与 2026-09-28 那次合并的关系（这是**推翻**，不是回归）
  /// ```text
  /// 当时 Owner 说「直播源还是跟js源合并吧,毕竟也是插件提供的,开关也方便」
  /// ⇒ 合并成一块。但现在他发现**合并之后同一个源在两个 tab 都出现**，
  ///   看不过来 ⇒ 要求按能力拆开。
  ///
  /// ★ 两次要求不矛盾：
  ///   · 2026-09-28 反对的是"**两个独立区块**各画一遍同一批源"（消重）；
  ///   · 2026-10-09 要求的是"**同一批源按能力分到两个 tab**"（分类）。
  ///   现在两个 tab 已经存在（`_PluginsTab`），只是 plugins 那个没过滤。
  /// ```
  ///
  /// # 为什么判据复用 `capabilities.live`
  /// ```text
  /// 与 `_liveSources` 同一个真源 ⇒ 两个 tab 的并集**恰好**等于全部源，
  /// 交集为空。不新造第二份判据（那是"两边迟早不一致"的经典来源）。
  /// ```
  ///
  /// ⚠️ 一个源**只声明** live（没有点播能力）时，它只出现在直播源 tab ——
  ///    那是对的。而既有点播又有直播的源（例如某些聚合源）会**同时**
  ///    出现在两个 tab：这是有意的 —— 两边都能配置它，
  ///    但用户在任一个 tab 里都只会看到"这一类里该看到的那些"。
  List<ProviderManifest> get _nonLiveProviders =>
      _providers.where((p) => !p.capabilities.live).toList(growable: false);

  /// 直播源子序列的换位 —— **纯函数**（不碰 FFI / 不碰状态，可直接单测）
  ///
  /// # 为什么需要它（而不是直接用 `_onReorderProviders`）
  ///
  /// 「直播源」tab 只显示 `_liveSources`（`_providers` 的子序列），
  /// 而 `_onReorderProviders` / `_moveProviderBy` 收的是 **`_providers`
  /// 的全局下标** ⇒ 把 tab 里的下标直接传进去会**移错人**：
  /// ```text
  /// 全 26 个源里 2 个直播（下标 0 和 5）：
  ///   用户在第 1 张卡上点「下移」→ 传 (0, 1) 给全局路径
  ///   → 它和**下标 1 的非直播源**交换
  ///   → 直播 tab 里两张卡的顺序**一点没变**（看着像"按钮坏了"）
  /// ```
  ///
  /// ⇒ 这里只在**直播子序列内部**换位，返回一份**新的全局顺序**：
  ///   把 `liveIds[oldIndex]` 摘出来，插到 `liveIds[newIndex]` 的
  ///   前/后（按移动方向决定），非直播源的相对顺序**一个都不动**。
  ///
  /// 返回 `null` = 无需改动（越界 / 原地放下 / 找不到锚点）——
  /// 调用方据此**跳过落盘**，避免白写一次盘。
  static List<String>? reorderLiveIds({
    required List<String> allIds,
    required List<String> liveIds,
    required int oldIndex,
    required int newIndex,
  }) {
    if (oldIndex < 0 || oldIndex >= liveIds.length) return null;
    if (newIndex < 0) newIndex = 0;
    if (newIndex >= liveIds.length) newIndex = liveIds.length - 1;
    if (newIndex == oldIndex) return null;

    final moved = liveIds[oldIndex];
    final anchor = liveIds[newIndex];

    final out = List<String>.of(allIds);
    if (!out.remove(moved)) return null;
    final at = out.indexOf(anchor);
    if (at < 0) return null;

    // 往后移 ⇒ 插到锚点**之后**；往前移 ⇒ 插到锚点**之前**
    out.insert(newIndex > oldIndex ? at + 1 : at, moved);
    return out;
  }

  /// 「直播源」tab 拖动排序
  Future<void> _onReorderLive(int oldIndex, int newIndex) async {
    final live = _liveSources;
    final ids = reorderLiveIds(
      allIds: _providers.map((p) => p.id).toList(),
      liveIds: live.map((p) => p.id).toList(),
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    if (ids == null) return;
    await _persistOrder(ids, '顺序已保存（{} 个源）');
  }

  /// 「直播源」tab 的上移 / 下移按钮（在直播子序列内换位）
  Future<void> _moveLiveBy(String id, int delta) async {
    final live = _liveSources;
    final i = live.indexWhere((p) => p.id == id);
    if (i < 0) return;
    final j = i + delta;
    if (j < 0 || j >= live.length) return;

    final ids = reorderLiveIds(
      allIds: _providers.map((p) => p.id).toList(),
      liveIds: live.map((p) => p.id).toList(),
      oldIndex: i,
      newIndex: j,
    );
    if (ids == null) return;
    await _persistOrder(ids, '顺序已保存（{} 个源）');
  }

  /// 「直播源」tab 的内容（task-74 ③）
  ///
  /// # 判据 = **声明的能力位** `capabilities.live`，不是运行时探测
  ///
  /// `test/merge_live_into_plugins_test.dart:255-266` 逐字钉着这条：
  /// > 配置页不该依赖运行期状态（进设置页时可能还没探过）
  ///
  /// ⇒ 直接复用既有的 `_liveSources` getter，**不新造第二份判据**。
  ///
  /// # 控制面 = **复用 `_ProviderCard` 既有的回调**，一个都不新造
  ///
  /// ```text
  /// 启停   _toggleProvider    （它含"写 → 读回真相 → 按真相报"三步）
  /// 编辑   _editProvider
  /// 配置   _configOf
  /// 移除   _removeOf
  /// 更新   _openPluginUpdate  （只有有安装链接的插件才有这个入口）
  /// 排序   _moveLiveBy / _onReorderLive  ← ★ 唯一新增（理由见上面纯函数）
  /// ```
  Widget _liveTab(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final live = _liveSources;
    final enabled = live.where((p) => p.enabled).length;

    // ★ 内容带（t509）：左右那两层 `AppMetrics.contentPadding` 已由
    //   `_tabScrollBody` 那层归零 —— 这里只留底部的 `Sp.x8`。
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '直播源',
                style: TextStyle(
                  fontSize: FontSizes.lg,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(width: Sp.x3),
              /*
               * ★ 启用数**实时算**，不写死 —— 写死会显示过期数据，
               *   比不显示更糟（与本文件块头那枚 `直播 N/M` chip 同一原则）。
               */
              Text(
                '$enabled/${live.length} 已启用',
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: Sp.x4),
          if (live.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.x6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '还没有支持直播的源',
                    style: TextStyle(
                      fontSize: FontSizes.base,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: Sp.x2),
                  /*
                   * ★ 空态必须说清「怎么才会有」—— 只说"没有"用户不知道下一步。
                   *   同时它也是 Owner 那句「导入js插件,自动更新直播源」的
                   *   用户可见承诺：导入后这里会自己长出来。
                   */
                  Text(
                    '在「JS 插件」里导入插件后，声明了直播能力的源会自动出现在这里。',
                    style: TextStyle(
                      fontSize: FontSizes.sm,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          else
            ReorderableCardGrid(
              itemCount: live.length,
              dragSlotWidth: _dragSlotW,
              /*
               * ★ TV 用更宽的列下限（2026-10-02，实测驱动）
               *
               * 起因：android-tv 在 960 逻辑宽的 TV 上截图发现 ——
               *   3 列 × 单格 296px 时，含「插件更新」的第 7 个按钮
               *   （↑ ↓ ⟳ ⚙ 编辑 停用 🗑）放不进一行，🗑 被 Wrap
               *   甩到第二行孤零零一个。桌面 4 列 299px 之所以没
               *   暴露，是因为 TV 的 `Device.textScale = 1.25` 把
               *   两个文字按钮撑大了 25%。
               *
               * 判据：`columnsFor(912, min=290) = 3`（单格 296）；
               *       改 440 后 `columnsFor(912, min=440) = 2`（单格 450），
               *       内容宽 426 > 7 按钮所需 ≈290，余量 136px。
               *
               * 为什么治本：3 列 × 296px 在 10 英尺观看距离上本来就
               * 偏挤（cap 字号 ×1.25 仍偏小），这是"密度不合理"而不是
               * "按钮太多"。既有的响应式规则（900 窗口→2 列）本就是
               * 同一逻辑，TV 只是把 minItemWidth 抬到 440。
               * 桌面/手机不传 440，保持原样零回归。
               */
              minItemWidth: Device.isTv ? 440 : kMinCardWidth,
              onReorder: _onReorderLive,
              itemBuilder: (context, i, dragHandle, cellWidth) => Padding(
                key: ValueKey(live[i].id),
                padding: EdgeInsets.zero,
                child: _ProviderCard(
                  provider: live[i],
                  cellWidth: cellWidth,
                  dragHandle: dragHandle,
                  canMoveUp: i > 0,
                  canMoveDown: i < live.length - 1,
                  onMoveUp: () => _moveLiveBy(live[i].id, -1),
                  onMoveDown: () => _moveLiveBy(live[i].id, 1),
                  onToggle: () => _toggleProvider(live[i]),
                  onRemove: _removeOf(live[i]),
                  onEdit: () => _editProvider(live[i]),
                  pluginEntry: _pluginOf(live[i].id),
                  onConfig: _configOf(live[i].id),
                  onCopy: _copy,
                  onPluginUpdate: _pluginSources.containsKey(live[i].id)
                      ? () => _openPluginUpdate(live[i].id, live[i].name)
                      // 同上：TVBox 源走订阅更新弹窗（判据同 `_providers` 那处）
                      : _tvboxSources.containsKey(live[i].id)
                      ? () => _openTvboxUpdate(live[i].id, live[i].name)
                      : null,
                ),
              ),
            ),
        ],
      ),
    );
  }

  ///
  /// ⚠️ `colors` 在 `build()` 里是**局部变量**，这里自己取一次
  ///    （同一个 `Theme.of(context).colorScheme`，值一致）。
  Widget _pluginsBlock(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    /*
     * ★★★ 2026-10-09（Owner：「我在js插件还看到了直播源,这两个要分隔开啊」）
     *
     * # 这一份列表**不含**直播源
     * ```text
     * 判据与「直播源」tab 同一个真源（`capabilities.live`）⇒
     * 两个 tab 的并集 = 全部源、交集 = 空。
     * 详见 `_nonLiveProviders` 的文档（含为什么这是"推翻 09-28 的合并"
     * 而不是回归）。
     * ```
     *
     * ⚠️ 排序仍然作用于**全局** `_providers`（三条排序路径都没变）——
     *    只是这里**画**的是子集。若改成对子集排序，
     *    非直播源与直播源之间的相对顺序会被打乱（那是另一个 bug）。
     */
    final list = _nonLiveProviders;
    /*
     * ⚠️ 下面这段（102 行）是**原区块的设计说明** —— ⑤ 搬迁时
     *    差点把它连同注释一起删掉。它解释的是"这块为什么长这样"：
     *    原版出处、实测数据、为什么 `thirdParty` 必须排除 js、
     *    为什么标题叫「JS 插件」而不是「内容源」。
     *
     *    区块进了二级页之后**更需要**这段说明 —— 所以补回这里，
     *    而不是让它随搬迁消失。
     */
    // ── JS 插件（含全部内容源）──
    /*
     * ══════════════════════════════════════════════════════════
     * ★★★ 内容源 + JS 插件 —— 合并成**一个区块**（2026-09-25）
     * ══════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 我说的合并还有 js插件和内容源这两块内容合成一个
     *
     * # ★ 原版早就合并过，我们漏了
     *
     * 原版 `SettingsView.vue:1652-1692` 的注释（Owner 原话）：
     * > 把设置页面的内容源删除掉，只保留 js 插件
     * > 然后 js 插件我觉得布局还是留白太多了，优化一下
     *
     * 原版为什么必须合并（原文照抄）：
     * ```text
     * 实测本机 list_providers 返回 26 个源，kind 全是 "js"
     * 于是「内容源」区块变成：
     *   内容源                          ← 标题，下面一张卡片都没有
     *     [排序] [健康检测] [导入源]
     *     （空）
     *   ───────────── 虚线 ─────────────
     *   JS 插件  [外置] [26 个]
     *     [重新加载] [安装插件]
     * 标题栏 + 虚线 + 边距共占约 156px 的纯空白，而且两个标题栏
     * 让用户以为有两类东西，实际只有一类。
     * ```
     *
     * # ★★ 我们这边还有一层原版没有的问题：**同一批源画了两遍**
     *
     * 原版的「内容源」区块只渲染 `builtin` / `declarative` / `http`
     * —— `thirdParty` 是**正向列举**那两个 kind 的，注释写着
     * （`SettingsView.vue:1509`）：
     * > ★ 第三方源 —— **必须排除 JS 插件**
     * >   （实测踩到：同一批源显示了两遍）
     *
     * 我们的 `_providers` 来自 `list_providers()` —— 它返回
     * **registry 里全部已注册的源**（含 js）。实测本机：
     * ```text
     * provider-order.json   26 条
     * plugins 目录下的 .js      26 个文件，@id 解析出 26 个
     * 两个集合**完全相同**（set 相等，两个方向差集都是空）
     * ```
     * 于是「内容源」的 26 张 `_ProviderCard` 和「JS 插件」的
     * 26 个 `_PluginTile` 是**同一批源** —— 用户截图里
     * 「影视天涯 / 影视建安」上下各出现一次，按钮还不一样。
     *
     * 合并后**只保留一份列表**：`_ProviderCard`（它有拖动 +
     * ↑↓ + 编辑/停用/移除 + 代理/登录）。`_PluginTile` 独有的
     * 两样信息**并进卡片**，一样都不丢：
     * ```text
     * · 「配置」按钮（plugin_config_get 的唯一界面入口）
     *       → `_ProviderCard.onConfig`
     * · 插件文件名（`154.js` 这种，用户靠它对上磁盘上的文件）
     *       → `_ProviderCard.pluginEntry.file`，拼进描述行
     *       （★ task-5 起改传整条 `PluginEntry`，见该字段的注释）
     * ```
     * 加载失败的插件仍**单独列出**（`_plugins.failed` +
     * `_plugins.plugins` 里 `loaded == false` 的）—— 不静默。
     *
     * # 合并后的确切结构（照原版 `SettingsView.vue:1693-1742`）
     *
     * ```text
     * ┌─ 区块 ────────────────────────────────────────────────────┐
     * │ JS 插件  [外置] [26 个]                                   │
     * │ [调整顺序][健康检测][导入源] │ [重新加载][从网址安装][粘贴源码安装]
     * │ 放在 plugins/ 下的 .js 文件，能打开看、能自己改            │
     * │ <源卡片列表：拖动 / ↑↓ / 编辑 / 停用 / 移除 / 代理 / 登录> │
     * └───────────────────────────────────────────────────────────┘
     * ```
     *
     * ⚠️ 标题用「JS 插件」而**不是**「内容源」—— 原版的选择，
     *    理由是本机源全是 JS 插件；而「内容源」这个词会让人
     *    以为这里还有别的形态。
     *
     * ⚠️ 5 个按钮用 `Wrap`（原版 `flex-wrap: wrap` 的语义）：
     *    > 手机上五个按钮一行放不下，要能自然折行。
     *    写成 `Row` 会在窄屏**溢出报错**（黄黑条纹），不是折行。
     *
     * ⚠️ 两组之间那条竖线用 `Container(width: 1)` 画，**不是**
     *    `Divider` —— 原版 `.head__sep` 本来就是一个 1px 色块；
     *    而且本项目刚把卡片里的分隔线删干净（用户要求
     *    「配置和登录合并到一起上面」），不要再画回来。
     *
     * # 与原版的**必要差异**（如实说明，不假装一致）
     *
     * ```text
     * · 排序按钮文案    原版是「排序」，我们沿用「调整顺序」
     *                   （`provider_layout_test.dart` 锁了这个字面量，
     *                    而它指的就是同一个入口 `_openOrderDialog`）
     * · 插件目录        原版显示可点击的绝对路径（pluginDir），
     *                   我们只显示 `plugins/` —— 没有任何 FFI
     *                   命令把 data_dir 暴露给这个 widget，
     *                   宁可少显示，也不画一个点了没反应的假路径
     * · 卡片上的 ↑↓      原版**明确拒绝**过（理由：排序是跨分组的，
     *                   卡片箭头管不了跨分组移动）——
     *                   但用户明确要求了，所以三条路径**都保留**
     *                   （拖动 + 卡片箭头 + 排序面板），不冲突
     * ```
     *
     * ⚠️ 不做假 UI：没有的能力就不画按钮（画了点了没反应更糟）。
     */
    return _Block(
      title: 'JS 插件',
      /*
       * ★ 关掉外层大框 —— 见 `_Block.boxed` 的说明。
       *
       * 用户原话「内容源做成卡片式的」：卡片本身早就有圆角边框，
       * 真正让它**不像卡片**的是外面还套着一层容器（盒子套盒子）。
       * 关掉之后 26 张卡各自独立，不再被读成「一个列表盒子」。
       *
       * ⚠️ 合并后**仍然只关这一个区块**。下面 手势/遥控/同步
       *    那些区块的内容不是卡片列表，它们**需要**外框来分组，
       *    保持默认 `true`（`_Block.boxed` 的默认值）。
       */
      boxed: false,
      /*
       * 块头右侧：`[外置] [N 个]`（原版 `block__title` 里的两个 chip）
       *
       * ⚠️ 只在**有源被停用**时才补一句「M 已启用」——
       *    全启用时那行是废话（原版也没有这一句），
       *    有停用时它才是用户想知道的信息。
       */
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _MiniChip(text: '外置'),
          if (_plugins.plugins.isNotEmpty) ...[
            const SizedBox(width: 4),
            _MiniChip(
              text: '${_plugins.plugins.length} 个',
              tone: _ChipTone.brand,
            ),
          ],
          /*
           * ★ 2026-09-28：`直播 N/M` 汇总 chip
           *
           * # 为什么合并之后**必须**补这一枚
           * ```text
           * 原先"哪些源能直播"靠**独立区块**回答（把 live 的源单独列一遍）。
           * 区块并进本列表后，用户得逐张卡片看「直播」chip 才能数出来 ——
           * 26 张卡滚动着数不现实。
           * ⇒ 用一枚 chip 把"N 个直播源、M 个已启用"提到块头。
           * ```
           * ⚠️ 没有直播源时**不画**（画「直播 0/0」是噪声，
           *    与 `_enabledCount != _providers.length` 那条同一个原则：
           *    全启用/全没有时那行是废话）。
           */
          if (_liveSources.isNotEmpty) ...[
            const SizedBox(width: 4),
            _MiniChip(
              text: '直播 '
                  '${_liveSources.where((p) => p.enabled).length}'
                  '/${_liveSources.length}',
              tone: _ChipTone.brand,
            ),
          ],
          if (_enabledCount != _providers.length) ...[
            const SizedBox(width: Sp.x2),
            Text(
              '$_enabledCount 已启用',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
      /*
       * 块头**标题行之下**：5 个按钮 + 插件目录提示
       *
       * 原版把它们都放在 `<section>` 的头部、卡片列表**之上**
       * （`.head__acts` 与 `.plug__hint`），这里同构。
       */
      headerExtra: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          /*
           * ★★ 2026-10-10：8 个按钮 → 2 个常驻 + 一个 ⋮ 菜单
           *
           * 改前（Owner：「3.js插件的ui不好看」）：
           * ```text
           * [调整顺序][健康检测][测速][导入源] │ [重新加载][从网址安装][粘贴源码安装]
           * ```
           * 8 个描边按钮排成两行、还夹一条竖线，在 26 张卡片**上面**压着
           * —— 一眼扫过去最抢眼的是一排按钮，而不是「有哪些源」。
           *
           * ⇒ 按频率分层：
           * ```text
           * 常驻  [从网址安装]  [⋮]   安装是这一页的主要入口
           * 菜单  调整顺序 / 健康检测 / 测速 / 导入源 / 重新加载 / 粘贴源码安装
           * ```
           *   —— 全部**一个没删**，只是收进菜单（菜单项带图标 + 文案，
           *      比 6 个同款描边按钮好认得多）。
           *
           * ⚠️ `PopupMenuButton` 可被方向键聚焦、Enter 打开、
           *    菜单项在菜单路由里可方向键上下选 ⇒ TV 上不失可达。
           */
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _installPlugin,
                icon: const Icon(Icons.download, size: 16),
                label: const Text('从网址安装'),
              ),
              PopupMenuButton<String>(
                tooltip: '更多操作',
                icon: const Icon(Icons.more_vert, size: 18),
                onSelected: (v) {
                  switch (v) {
                    case 'order':
                      _openOrderDialog();
                    case 'health':
                      if (!_sweeping) _healthSweep();
                    case 'import':
                      _openImportDialog();
                    case 'reload':
                      if (!_pluginBusy) _reloadPlugins();
                    case 'source':
                      _installPluginSource();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'order',
                    child: _menuRow(Icons.reorder, '调整顺序'),
                  ),
                  PopupMenuItem(
                    value: 'health',
                    enabled: !_sweeping,
                    child: _menuRow(
                      Icons.monitor_heart_outlined,
                      _sweeping ? '处理中…' : '健康检测',
                    ),
                  ),
                  PopupMenuItem(
                    value: 'import',
                    child: _menuRow(Icons.add, '导入源'),
                  ),
                  PopupMenuItem(
                    value: 'reload',
                    enabled: !_pluginBusy,
                    child: _menuRow(
                      Icons.refresh,
                      _pluginBusy ? '处理中…' : '重新加载',
                    ),
                  ),
                  PopupMenuItem(
                    value: 'source',
                    child: _menuRow(Icons.code, '粘贴源码安装'),
                  ),
                ],
              ),
              // 测速自带自己的按钮态（进度/结果），仍常驻在块头右侧。
              PluginSpeedTestAllButton(
                pluginIds: list
                    .where((p) => p.enabled)
                    .map((p) => p.id)
                    .toList(growable: false),
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          /*
           * 插件目录提示（原版 `.plug__hint`）
           *
           * 原版它挂在「JS 插件」子标题下，合并后并入块头。
           *
           * ⚠️ 只显示 `plugins/` 这个**目录名**，不显示绝对路径 ——
           *    没有任何 FFI 命令把 data_dir 暴露给本 widget，
           *    编一个路径出来就是假 UI（用户会照着一个不存在的
           *    路径去找文件）。原版能显示是因为它前端就知道
           *    `pluginDir`。真路径见「关于」区块里的数据目录。
           */
          Text(
            '放在 plugins/ 下的 .js 文件，能打开看、能自己改',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
      children: [
        /*
         * ══════════════════════════════════════════════════════
         * ★★★ 卡片列表 —— 支持**拖动排序**（2026-09-25 用户要求）
         * ══════════════════════════════════════════════════════
         *
         * 用户原话：
         * > 内容源调整顺序也要支持可拖动排序
         *
         * 原先是一个 `for (final p in _providers) Padding(...)` ——
         * 静态铺开，没有任何拖拽能力。
         *
         * # 三个参数都是必须的，不是可选优化
         *
         * ```text
         * shrinkWrap: true
         *   `ReorderableListView` 内部是个 `CustomScrollView`（可滚动）。
         *   它被放进外层 `build()` 的 `ListView` 里 ——
         *   嵌套两层可滚动区域时，内层拿不到**有界高度**，
         *   直接渲染失败。`shrinkWrap` 让它按内容撑开、
         *   高度由内容决定，滚动仍然只由外层负责。
         *
         * physics: NeverScrollableScrollPhysics()
         *   同上：内层**不能**自己滚，否则滚轮会被它截走 ——
         *   而这一页的滚轮本来就有问题（`spatial_nav.dart`
         *   的 `ensureVisible`，另一个任务在修），
         *   再截一层会让它彻底滚不动。
         *
         * buildDefaultDragHandles: false
         *   默认把手是在**整张卡右侧**盖一条 48px 宽的透明长条。
         *   它会吃掉「编辑 / 停用 / 移除」三个按钮的点击 ——
         *   表现为「点按钮没反应」。所以关掉，改成自己在
         *   卡片里画一个**明确的**把手（见 `_ProviderCard._actions`）。
         * ```
         *
         * # 为什么每张卡都要 `Key`
         *
         * `ReorderableListView` 靠 `Key` 在重排前后**认出同一个条目**
         * （否则会把「移动」当成「整块重建」，拖动动画会跳）。
         * 用 `ValueKey(源 id)` 而不是下标 —— 下标在重排后必然变，
         * 用它等于每次都是新条目。
         *
         * # 为什么列表里还留着 `Padding(bottom: Sp.x3)`
         *
         * 原版 `.cards { gap: var(--sp-3) }` = 卡片间距 12px。
         * 卡片之间**必须有间距**，否则「26 张独立卡片」会糊成
         * 一整块 —— 那就退回到用户不想要的「一个大列表」了。
         *
         * # ★ 合并后这一份列表就是**全部内容源**
         *
         * 见块头那段注释：`_providers` 含 js（本机 26 个全是 js），
         * 所以它就是原版「JS 插件」区块里那张 `.plug__list` ——
         * **不再有第二份** `_PluginTile` 列表。
         */
        /*
         * ══════════════════════════════════════════════════════
         * ★★★ 卡片列表 —— **响应式多列网格** + 拖动排序
         * ══════════════════════════════════════════════════════
         *
         * 用户原话（两条）：
         * ```text
         * 内容源调整顺序也要支持可拖动排序
         * js插件还没改成一行多个的显示(根据宽度动态处理显示)
         * ```
         *
         * # ★ 2026-09-25 从 `ReorderableListView` 换成网格
         *
         * 原来是 `ReorderableListView` —— 它**只有单列**
         * （构造函数里没有 `gridDelegate` 之类的参数），
         * 26 张卡竖排 26 行，一屏只看得到 4~5 个。
         *
         * 现在换成 `ReorderableCardGrid`（`lib/ui/widgets/`）——
         * 列数**由可用宽度动态决定**：
         * ```text
         * 1280 窗口 → 3 列（可用 1232 / 每列约 403）  与原版一致
         *  900 窗口 → 2 列
         *  400 窗口 → 1 列（手机）
         * ```
         * 为什么不用 `SliverReorderableGrid` / `reorderable_grid_view`
         * —— 三条路都逐个查过，理由（含实测数据）写在那个文件的
         * 头部注释里：**这个 Flutter 版本没有前者，而后者的
         * `SliverGridDelegate` 会裁掉会自动展开的代理/登录面板**。
         *
         * # 三个「必须」都还在
         *
         * ```text
         * 卡片间距        → ReorderableCardGrid 的 `spacing`（Sp.x3）
         *                 原版 `.plug__list { gap: var(--sp-2) }`，
         *                 且卡片之间**必须有间距** —— 否则 26 张卡
         *                 会糊成一整块，退回用户不想要的「一个大列表」
         *
         * 每张卡有 Key    → 仍用 `ValueKey(源 id)`（重排前后认条目）。
         *                 ★ 网格版把它放在**行内的 `Expanded`** 上，
         *                 由 `ReorderableCardGrid` 内部保证下标正确
         *
         * 内层不自己滚    → 网格是一个 `Column`（不是 `CustomScrollView`），
         *                 所以**不存在**嵌套滚动的问题 ——
         *                 原先 `ReorderableListView` 需要的
         *                 `shrinkWrap: true` +
         *                 `physics: NeverScrollableScrollPhysics()`
         *                 两个参数随之**不再需要**。
         *                 这同时省掉了"网格要算全部卡片高度"的开销
         *                 （`shrinkWrap` 的网格很贵）。
         * ```
         *
         * # ★ 拖动的机制换了（但语义完全一致）
         *
         * ```text
         * 旧：ReusableDragStartListener（只能在 ReorderableListView
         *     的子树里工作 —— 靠 SliverReorderableList 的
         *     InheritedWidget 找祖先）
         * 新：Draggable（把手）+ DragTarget（每个格子）
         *     —— 拖到第 j 格 = 移到第 j 位，与
         *     `onReorderItem` 的语义一致（已经是目标位，不再 -= 1）
         * ```
         * ⚠️ 把手由 `ReorderableCardGrid` 造好、**传给卡片**
         *    （`_ProviderCard.dragHandle`）—— 因为"把手放在卡片里
         *    哪一格"是卡片的版式知识（它还要与 `_panels()` 的
         *    左缩进逐像素对齐）。
         *
         * ⚠️ 三条排序路径**一条都没少**：
         * ```text
         * ① 拖动        → 本网格（Draggable + DragTarget）
         * ② 卡片 ↑↓     → `_ProviderCard._actions`（不受影响）
         * ③ 排序面板    → 「调整顺序」按钮 → `_OrderDialog`（不受影响）
         * ```
         * 三条最终都走 `_persistOrder`（唯一落盘出口）。
         *
         * # ★ 合并后这一份列表就是**全部内容源**
         *
         * 见块头那段注释：`_providers` 含 js（本机 26 个全是 js），
         * 所以它就是原版「JS 插件」区块里那张 `.plug__list` ——
         * **不再有第二份** `_PluginTile` 列表。
         */
        ReorderableCardGrid(
          // ★ 只画非直播源（见本方法开头的说明）
          itemCount: list.length,
          dragSlotWidth: _dragSlotW,
          // ★ TV 用更宽的列下限 —— 理由同上（live 列表那处有完整说明）。
          minItemWidth: Device.isTv ? 440 : kMinCardWidth,
          onReorder: _onReorderProviders,
          itemBuilder: (context, i, dragHandle, cellWidth) => Padding(
            key: ValueKey(list[i].id),
            padding: EdgeInsets.zero,
            child: _ProviderCard(
              provider: list[i],
              /*
               * ★ 本格宽度由网格传进来（`ReorderableCardGrid` 算的列数
               * 本来就是按它分的）。卡片用它决定按钮横排还是换行。
               *
               * ⚠️ 卡片**不能**自己用 `LayoutBuilder` 量 ——
               *    那会让子树不支持 intrinsics，外层的
               *    `IntrinsicHeight`（负责"同一行卡片等高"）
               *    会直接抛 "LayoutBuilder does not support
               *    returning intrinsic dimensions"（实测踩到）。
               */
              cellWidth: cellWidth,
              /*
               * 拖动把手 —— 由网格造好传进来（见上面的说明）。
               * `ReorderableCardGrid` 靠它知道拖的是第几格。
               */
              dragHandle: dragHandle,
              /*
               * 「上一个 / 下一个」按钮的可用性：
               * 第一张不能上移、最后一张不能下移。
               * ⚠️ 边界按钮**置灰而不是隐藏** ——
               *    隐藏会让每张卡的按钮位置错开，
               *    置灰则整列按钮**竖直对齐**，好点也好认。
               */
              canMoveUp: i > 0,
              canMoveDown: i < list.length - 1,
              onMoveUp: () => _moveProviderBy(list[i].id, -1),
              onMoveDown: () => _moveProviderBy(list[i].id, 1),
              onToggle: () => _toggleProvider(list[i]),
              onRemove: _removeOf(list[i]),
              onEdit: () => _editProvider(list[i]),
              /*
               * ★★ 合并后从原 `_PluginTile` **并过来**的两样
               *
               * ```text
               * pluginFile  插件文件名（`154.js`）
               *             原来在 tile 的第二行显示，
               *             用户靠它对上磁盘上的文件
               * onConfig    「配置」按钮 —— `plugin_config_get`
               *             的**唯一界面入口**（`_configPlugin`）。
               *             删掉 tile 就必须把它接出来，
               *             否则插件的配置项再也点不到
               * ```
               * 非 JS 源（内置 / 声明式 / HTTP）没有对应的插件
               * 文件，两个都传 null → 卡片上不画「配置」按钮、
               * 描述行也不拼文件名。
               */
              pluginEntry: _pluginOf(list[i].id),
              onConfig: _configOf(list[i].id),
              // ★ task-5：标识 chip 可点复制上游链接 —— 复用宿主现成的 `_copy`
              //（它带「已复制」toast，且 `_toastRev` 让二级页也看得到）
              onCopy: _copy,
              /*
               * ★★ 只有**有安装链接**的插件才有这个入口（task-23）
               *
               * `_pluginSources` 来自 `list_plugin_sources`
               *（纯本地读 `plugins/.meta/<id>.json`，零网络）。
               * 查到 null → 传 null → 卡片上**不出现**更新按钮。
               *
               * 实测预期：本机现有 26 个插件**全是手动放入的**
               *（没有任何 meta）→ **26 张卡一个都不会有这个按钮**。
               * 这是**正确行为**，不是 bug —— 见字段注释的原则。
               */
              onPluginUpdate: _pluginSources.containsKey(list[i].id)
                  ? () =>
                        _openPluginUpdate(list[i].id, list[i].name)
                  /*
                   * TVBox 源走**另一个弹窗**（task-14 附加）
                   *
                   * 两者共用卡片上同一个图标按钮（`_ProviderCard.onPluginUpdate`），
                   * 因为对用户来说都是「这个源能不能更新」。
                   *
                   * 判据是 `_tvboxSources.containsKey`，**不是**
                   * `_tvboxSources[id]!.sourceUrl != null` —— 见字段注释：
                   * 没链接的源也要能点进去**补填**链接。
                   *
                   * 两处都查不到 => 仍传 `null` => **不画按钮**
                   * （`test/plugin_update_ui_test.dart` 钉住了这个语义）。
                   */
                  : _tvboxSources.containsKey(list[i].id)
                  ? () => _openTvboxUpdate(list[i].id, list[i].name)
                  : null,
            ),
          ),
        ),

        // 空态（原版 `.prov-empty`：「还没有内容源，点击「导入源」添加」）
        if (_providers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.x6),
            child: Center(
              child: Text(
                '还没有内容源',
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ),

        /*
         * ══════════════════════════════════════════════════════
         * ★ 加载失败的插件必须显示 —— 不静默
         * ══════════════════════════════════════════════════════
         *
         * 两个来源都要列：
         * ```text
         * _plugins.failed            读文件 / 执行脚本失败的（file + 原因）
         * _plugins.plugins !loaded   解析出来了但没注册上（如缺 @id）
         * ```
         * ⚠️ 只列 `failed` 会漏掉第二种：`list_plugins` 对
         *    「解析成功但没注册」的条目**照样塞进 plugins**
         *    （`loaded: false` + `error`）。不在这里显示的话
         *    用户放进去的文件就是"凭空消失"。
         */
        for (final f in _plugins.failed)
          _FailedPlugin(file: f.$1, reason: f.$2),
        for (final e in _plugins.plugins.where((e) => !e.loaded))
          _FailedPlugin(file: e.file, reason: e.error ?? '加载失败'),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  子组件
// ═══════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════
//  「JS 插件」二级页的 tab 条（task-74 ③）
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话（m04668）：
// > js源配置页面加一个直播源 ... 然后在这个直播源 tab下进行控制,
// > 然后这个tab也使用液态玻璃 那个效果实现吧,记住固定在上面,
// > 而不是随着整体下滑
//
// 拆成三件事，分别由下面三个声明承担：
// ```text
// _PluginsTab             两个 tab 的名字（枚举驱动，不手写两份）
// _PluginsTabBar          玻璃 + 滑动药丸（照抄 my_shelf / follow_page）
// _PluginsTabBarDelegate  pinned 的 SliverPersistentHeader delegate
// ```
//
// ⚠️ 药丸**只在外层容器上有一块玻璃**（`GlassContainer` 恰好 1 处）——
//    `my_shelf_test.dart:45-52` 记着这个坑：给每个 tab 各套一块会变成
//    「两个独立小胶囊」，与底栏那条大玻璃完全不像。

/// 二级页的两个 tab
///
/// ⚠️ 用枚举驱动（`_PluginsTab.values`）而不是手写两份 chip ——
///    漏一个就少一个 tab，而且滑动药丸的宽度算不出来。
enum _PluginsTab {
  /// 内容源 / JS 插件 —— 原样复用 `SettingsPageState._pluginsBlock`
  plugins('JS 插件'),

  /// 只列 `capabilities.live` 为真的源，并允许在这一页启停 / 排序
  live('直播源');

  const _PluginsTab(this.label);

  /// tab 上的文字
  final String label;
}

/// 每个 tab 的宽度（与 `follow_page.dart:1119` 的 `_followTabWidth` 同值）
///
/// ★ 用**定宽**而不是测量：本文件里**不能出现会在布局期自测宽度的那个
///   构建器** —— `test/provider_grid_responsive_test.dart:618-639` 断言
///   它不存在，因为卡片住在 `IntrinsicHeight` 下，自测宽会直接抛
///   "does not support returning intrinsic dimensions"（实测踩到）。
///   定宽同时让滑动药丸的 `FractionallySizedBox(widthFactor: 0.5)` 成立。
const double _pluginsTabWidth = 96;

/// tab 本体高度 —— ≥34 才满足触控目标规范（`DEVELOPMENT.md` 坑 35）
const double _pluginsTabH = 34;

/// pinned 条的总高度
///
/// = 玻璃容器（`_pluginsTabH` + 上下各 `Sp.x2` 的 `padding`）+ 下呼吸 `Sp.x2`
const double _pluginsTabBarExtent = _pluginsTabH + Sp.x2 * 2 + Sp.x2;

/// 玻璃 tab 条（外层一块玻璃 + 内部滑动药丸 + 两个**透明** chip）
class _PluginsTabBar extends StatelessWidget {
  const _PluginsTabBar({required this.current, required this.onChanged});

  final _PluginsTab current;
  final ValueChanged<_PluginsTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * ★ 药丸与文字**取同一个调色板**（`colors.primary` / `colors.onPrimary`）
     *
     * `follow_page.dart:1278-1340` 记着这个坑：药丸用一个色、文字却用
     * `colorScheme.onSurface` ⇒ 深色主题下白字压白药丸，**看不见**。
     */
    return GlassContainer(
      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
      quality: GlassQuality.standard,
      /*
       * ★ `padding` 不能省（`theme_page.dart:74` 的实测结论）：
       *   药丸要离玻璃边缘留一口气，否则选中的高亮会盖住折射带，
       *   玻璃"看起来没生效"。
       */
      padding: const EdgeInsets.all(Sp.x2),
      child: SizedBox(
        width: _pluginsTabWidth * 2,
        height: _pluginsTabH,
        child: Stack(
          children: [
            // ① 滑动药丸（在下面一层）
            //
            // ★ 用 `AnimatedPositioned` 而不是 `AnimatedAlign` ——
            //   与 `follow_page.dart:1108-1179` 的 `_FollowTabs` 同一个做法
            //   （`left: current.index * _followTabWidth` + `top/bottom: 0`）。
            //   Stack 的宽度是上面写死的 `_pluginsTabWidth * 2`，
            //   所以药丸的落点是**算出来的**，不需要测量。
            AnimatedPositioned(
              duration: Motion.slow,
              curve: Curves.easeOutCubic,
              left: current == _PluginsTab.plugins ? 0 : _pluginsTabWidth,
              top: 0,
              bottom: 0,
              width: _pluginsTabWidth,
              child: Container(
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: Radii.rFull,
                ),
              ),
            ),
            // ② 两个 chip —— **透明**底（玻璃在外层那一个容器上）
            Positioned.fill(
              child: Row(
                children: [
                  for (final t in _PluginsTab.values)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onChanged(t),
                        child: Center(
                          child: Text(
                            t.label,
                            style: TextStyle(
                              fontSize: FontSizes.sm,
                              fontWeight: current == t
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: current == t
                                  ? colors.onPrimary
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// tab 条的 pinned delegate
///
/// # 为什么照抄 `settings_sub_page.dart:398-451` 而不是 import 它
///
/// `_StickyBackBar` 是那个文件的**私有**类，而那个文件本轮**只读**
/// （Lead 明确禁止改动）。照抄它的两条关键做法：
/// ```text
/// ① minExtent == maxExtent 时 `shrinkOffset` 恒为 0 —— 不写 clamp 也不会
///    算出负高度（负高度会直接抛异常，比视觉错更糟）
/// ② 条**必须有不透明底色** —— 内容会从它下面滚过，
///    透明会让两行文字叠在一起
/// ```
class _PluginsTabBarDelegate extends SliverPersistentHeaderDelegate {
  const _PluginsTabBarDelegate({
    required this.extent,
    required this.background,
    required this.child,
  });

  final double extent;

  /// 条的**不透明**底色 —— 玻璃是半透明的，它自己挡不住下面滚过的文字
  final Color background;

  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Container(
    height: extent,
    color: background,
    alignment: Alignment.centerLeft,
    // ★ 内容带（t509）：本层是 `SliverPersistentHeader(pinned: true)`，
    //   但它整体在 `SettingsSubPage.build` 的那层带之内 ⇒ 这里归零。
    //   原来这里是 `AppMetrics.contentPadding`（24），会与带重复 ⇒ ×2。
    padding: EdgeInsets.zero,
    child: child,
  );

  @override
  bool shouldRebuild(covariant _PluginsTabBarDelegate old) =>
      old.extent != extent ||
      old.background != background ||
      old.child != child;
}

/// 「JS 插件」二级页（task-43）
///
/// # 为什么是**同文件**的顶层私有类
/// ```text
/// 见 `SettingsPageState._pluginsBlock` 的说明：那一块依赖 host 的
/// 22 个成员 + 约 1105 行私有 class，跨文件搬的代价远大于收益，
/// 而本文件有并发写入者。
///
/// 用户要的是「点进去才看到」（UX），不是「代码在哪个文件」（组织）。
/// ```
///
/// ⚠️ 外壳用 `SettingsSubPage`（与另外 5 个二级页**完全一致**）：
///    它自带返回按钮 + Esc/遥控返回 —— 全局标题栏**没有**返回键，
///    自己画会漏掉键盘路径（那个文件的注释记着这个坑）。
class _PluginsPage extends StatefulWidget {
  const _PluginsPage({required this.host});

  /// 宿主设置页 State（提供 `_pluginsBlock` 与全部动作方法）
  final SettingsPageState host;

  @override
  State<_PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<_PluginsPage> {
  /// 当前 tab
  ///
  /// ★ 默认 `plugins` —— 与原行为**逐字一致**：老用户点进来第一眼看到的
  ///   还是那份内容源列表，多出来的只是顶上一根 tab 条。
  _PluginsTab _tab = _PluginsTab.plugins;

  /// 两个 tab 的**共同骨架**
  ///
  /// # ★★★ 为什么必须走 `scrollBody:` 而不是 `children:`
  ///
  /// `SettingsSubPage` 有两条结构路径（`settings_sub_page.dart:100` 逐字写着）：
  /// ```text
  /// scrollBody == null → _scrollingBody → CustomScrollView + SliverList
  /// scrollBody != null → _pinnedBody    → Column + Expanded(scrollBody)
  /// ```
  /// 走 `children:` 的话每个子件是 `CustomScrollView` 里**平级的一个 sliver**
  /// —— 没有任何缝能塞进 `SliverPersistentHeader`，tab 条只能随内容滚走。
  /// 而 Owner 的原话是「记住固定在上面，而不是随着整体下滑」。
  /// ⇒ 自己供给 `CustomScrollView`，把 tab 条放进
  ///   `SliverPersistentHeader(pinned: true)`。
  Widget _tabScrollBody(BuildContext context) {
    final host = widget.host;
    final colors = Theme.of(context).colorScheme;

    // ★ 内容带（t509）：带由 `SettingsSubPage.build` 统一提供（一级/二级页
    //   都在原版那**一个** `.container` 之内）⇒ 这里**不要**再加一层，
    //   否则二级页会变成 ×2。
    return CustomScrollView(
      clipBehavior: Clip.antiAlias,
      slivers: [
        /*
         * ★ tab 条：`pinned: true` 就是「滚到哪都留在视口顶」的**全部来源**。
         *
         * ⚠️ 玻璃是**半透明**的，它自己挡不住下面滚过的文字 ⇒
         *    必须在它后面垫一层**不透明**底（`colors.surface`）。
         *    用 `FTheme.colors.background` 不行 —— forui 的
         *    `neutral.light.background` 是纯白 #FFFFFF，白叠白等于没垫。
         */
        SliverPersistentHeader(
          pinned: true,
          delegate: _PluginsTabBarDelegate(
            extent: _pluginsTabBarExtent,
            background: colors.surface,
            child: _PluginsTabBar(
              current: _tab,
              onChanged: (t) => setState(() => _tab = t),
            ),
          ),
        ),

        /*
         * ★★ 两个 tab 的内容都订阅 `host._dataRev`
         *
         * 本页是**另一条路由**，host 的 setState 不重建它。
         * 而每个操作都靠 host 方法 → `await loadAll()`（它的 `finally` 里
         * `_dataRev.value++`）—— 不订阅的话用户按「编辑」「启用」后
         * 界面不变（像没反应）。
         *
         * ★ Owner 要的「导入 js 插件 → 自动更新直播源」正是**白拿**的：
         *   导入 / 更新 / 回滚 / 启停**全都**走 `loadAll()`，
         *   于是两个 tab 一起刷新 —— 不必为直播源另造一套通知机制。
         */
        ValueListenableBuilder<int>(
          valueListenable: host._dataRev,
          builder: (context, _, __) => SliverToBoxAdapter(
            child: _tab == _PluginsTab.plugins
                ? host._pluginsBlock(context)
                : host._liveTab(context),
          ),
        ),

        // 底部让位（悬浮底栏盖在所有路由之上）
        //
        // ⚠️ 这里**不能**加 `const`：`Sp.bottomBarInset` 是 **getter**
        //    （`tokens.dart:73`：`Device.isTv ? 110 : 90`），
        //    getter 调用不能出现在 const 表达式里 ⇒ `invalid_constant`。
        //    同样的坑在本仓已记过两次：`search_page.dart:605`、
        //    `live_page.dart:1500`（两处注释逐字写着同一条）。
        SliverToBoxAdapter(child: SizedBox(height: Sp.bottomBarInset)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    /*
     * ★★★ 用 `Stack` 包一层 —— 二级页要自己画 toast（task-43）
     *
     * # 为什么必须自己画
     * ```text
     * `_flash()` 把消息写进 host 的 `_toast`，而 host 的 toast 画在
     * **宿主自己的 Stack** 里 —— 被 push 上来的本页整屏盖住。
     *
     * 成功类还能靠列表刷新看出变化；
     * ★ 失败类（"安装失败：…"／"删除失败：…"／"保存失败：…"）
     *   **列表根本不变** ⇒ 用户完全没有反馈，只会以为「点了没反应」。
     * ```
     *
     * ⚠️ 样式与 host 的 toast **逐字一致**（黑底胶囊 + 同一个
     *    `Sp.bottomBarInset` 让位）—— 两处观感不同比没有更糟。
     */
    return Stack(
      children: [
        SettingsSubPage(
          title: 'JS 插件',
          subtitle: '内容源：安装 / 编辑 / 更新 / 排序 / 代理配置',
          /*
           * ★ task-74 ③：从 `children:` 换成 `scrollBody:` ——
           *   理由逐字见 `_tabScrollBody` 的文档注释。
           */
          scrollBody: _tabScrollBody(context),
        ),
        // ── toast（与 host 的渲染逐字一致，见上面的说明）──
        ValueListenableBuilder<String?>(
          valueListenable: host._toastRev,
          builder: (context, msg, __) {
            if (msg == null) return const SizedBox.shrink();
            return Positioned(
              left: 0,
              right: 0,
              bottom: Sp.bottomBarInset,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Sp.x5,
                    vertical: Sp.x3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.85),
                    borderRadius: Radii.rFull,
                  ),
                  child: Text(
                    msg,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: FontSizes.sm,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.child});

  final Widget child;

  // ★ 内容带（t509）：原来这里是 `AppMetrics.contentPadding`（24）
  //   —— 已由上面主列表 `ListView.padding` 的 `Layout.horizontalInsetOf` 提供，
  //   留着会变成 ×2（TV 上会从 72 变 96，与原版不符）。
  //   唯一用点：`lib\ui\settings_page.dart:1655 _Section(`（主设置列表里）。
  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.zero, child: child);
}

/// 能力标签的**有序**列表（单一来源）
///
/// 抽成顶层函数而不是两个地方各写一遍 ——
/// `_hasAnyCap` 与 `_capsRow` 若各写一份"有哪些能力"的判断，
/// 改一处忘另一处就会出现「判断说有、渲染时没有」的空行。
///
/// # ★★ 2026-09-24：字段名跟随 `Capabilities` 的契约修复（代理 P2）
///
/// 这里原先读的是 `c.category` / `c.rank` / `c.login` / `c.platformHistory`
/// 四个**后端从不下发**的键 —— 所以这四个标签**从来没显示过**
///（详见 `models.dart` 里 `Capabilities` 的类文档：那是同一个 bug 的
/// 另一处消费点）。
///
/// 现在按 Rust 真实字段重列：
/// ```text
/// vod                → 点播
/// live               → 直播
/// epg                → 节目单
/// timeshift          → 回看
/// search             → 搜索
/// multi_source       → 多源
/// favorites          → 收藏
/// danmaku            → 弹幕
/// login_required     → 需登录     ★ 只认 required，不认 supported
/// server_side_history→ 平台历史
/// ```
///
/// ⚠️ `login_required` 与 `login_supported` **不是一回事**
///（`models.dart` 的类文档专门讲过）：
/// ```text
/// cycani    必须登录才能取流          → 打「需登录」
/// bilibili  游客能看 1080P，登录是增强 → **不打**，它旁边有「登录」按钮
/// ```
/// 所以这里**只**判 `loginRequired` —— 判 `loginSupported` 会给 B站
/// 也打上「需登录」，那是错的（游客明明能看）。
///
/// 顺序照原版 `SettingsView.vue:1831-1839` 的语义分组
///（**播放形态 → 功能 → 登录**），不按字段声明顺序 ——
/// 用户扫一眼先看到"这个源能干什么"。
List<String> _capLabels(Capabilities c) => [
  if (c.vod) '点播',
  if (c.live) '直播',
  if (c.epg) '节目单',
  if (c.timeshift) '回看',
  if (c.search) '搜索',
  if (c.favorites) '收藏',
  if (c.danmaku) '弹幕',
  if (c.multiSource) '多源',
  if (c.serverSideHistory) '平台历史',
  if (c.loginRequired) '需登录',
];

/// 有没有任何能力位（决定要不要渲染那一行）
///
/// 数据来源与 `_capLabels` **同一份逻辑**（见那里的说明）。
bool _hasAnyCap(Capabilities c) => _capLabels(c).isNotEmpty;

/// 内容源卡片**左侧「拖动把手」那一格**的宽度（常量）
///
/// # ★ 为什么必须是常量、且两处引用
///
/// 卡片第一行现在是：
/// ```text
/// [拖动把手 _dragSlotW] [图标 30] [Sp.x3 = 12] [正文…]        [按钮]
///                         ↑_________________________↑
///                         这一段的右边缘 = 正文（源名）的左边缘
/// ```
/// 而 `_ProviderCard._panels()`（代理配置 + 账号登录）要**与源名左对齐**
/// —— 那是集成任务 M 的成果（用户要求「内容源的配置和登录等，合并到一起上面」）。
///
/// 所以 `_panels()` 的左缩进**必须**等于
/// `_dragSlotW + 30 + Sp.x3`。两处若各写一份数字，
/// 将来改把手宽度就会出现「面板比源名缩进多了 18px」——
/// 这种偏移**看起来很精确、实际是错的**，最难查。
///
/// 定义成一个常量、两处引用 → 对齐关系由**构造保证**，不靠人算。
/// `.versions/` 每个插件保留几档历史（与 Rust 侧 `MAX_PLUGIN_VERSIONS` **必须一致**）
///
/// ⚠️ 这里是**展示用**的文案数字（"最多保留最近 N 档"）。
///    真正的清理逻辑在 Rust（`plugins::prune_plugin_versions`）。
///    两处不一致会让界面说谎（说留 5 档、实际留 3 档）——
///    所以改一处必须改另一处。
const int kMaxPluginVersionsShown = 5;

const double _dragSlotW = 22;

/// 源卡片「横排按钮」所需的最小宽度（低于它就换行，见 `_ProviderCard.build`）
///
/// # ★ 这个数是**算出来的**，不是试出来的（2026-09-25 实测）
///
/// 把一张卡的宽度预算逐项打印出来得到的：
/// ```text
/// 卡片内边距  12×2 ………………………………………… 24
/// 拖动把手 ……………………………………………… 22
/// 图标 …………………………………………………… 30
/// 图标与正文间距 ………………………………………… 12
/// 正文（名称行硬需求）……………………………… 156
/// 正文与按钮间距 …………………………………………  8
/// 操作按钮区（7 个按钮，flex:none）…………… 232
/// ────────────────────────────────────────────────
/// 合计 ………………………………………………… 484
/// ```
/// 向上取整到 10 的倍数 → **520**（当时按钮区是 264，本轮收进 ⋮ 菜单后
/// 降到 232，卡片总需求 484；520 留 36 余量给 chip 与窄列，见下）。
///
/// ⚠️ 这些数字会变：加一个按钮（约 +32~48）、换把手宽度、
///    改图标尺寸，都要**重新量一遍**再改这个常量 ——
///    否则卡片会在某个宽度区间悄悄溢出（`RenderFlex overflowed`）。
///    量法：把窗口扫一遍，看哪里开始出现 overflow（`.probe/` 里有探针）。
///
/// ⚠️ 这些数字会变：加一个按钮（约 +40~48）、换把手宽度、
///    改图标尺寸，都要**重新量一遍**再改这个常量 ——
///    否则卡片会在某个宽度区间悄悄溢出（`RenderFlex overflowed`）。
///    量法：把窗口扫一遍，看哪里开始出现 overflow（`.probe/` 里有探针）。
///
/// ⚠️ 为什么不用 400（原版 `.plug__list` 的 `minmax(400px, 1fr)`）：
///    原版那 400 是给**简化卡片**（`.plug`，名称+标签约 150、
///    3 个按钮约 220）算的，见 `SettingsView.vue:4509` 的注释。
///    本页用的是**富卡片**（`.prov`：把手 + 图标 + 名称 + 版本 +
///    状态 chip + 能力 chip + **5 个按钮**），宽度需求大得多。
///    照搬 400 的结果就是 26 张卡全溢出 115px。
const double _cardWideMinWidth = 520;

/// 内容源卡片（照原版 `.prov` 卡片）
///
/// # 布局（与 `SettingsView.vue` L1812-1935 一一对应）
///
/// ```text
/// ┌────────────────────────────────────────────────────────────┐
/// │ [图标]  源名 [kind标签] [版本] [已停用] [已失效]  [停用] [移除] │
/// │         描述文字或 id                                       │
/// │         [点播] [直播] [搜索] [需登录] [多源]                 │
/// └────────────────────────────────────────────────────────────┘
/// ```
///
/// # 抄原版时最值得记的三条
///
/// ```text
/// ① 名称行**禁止换行**（`nowrap`）
///    原版实测：28 张卡片里 2 张折行（名称行 25px → 57px），
///    那两张就比别人高 30px。Owner 原话：
///    > 这个高度保持一下统一，这高度都不一样显示的太丑了
///
/// ② 名称可收缩 + ellipsis、chip 不可压缩
///    ```text
///    名称 flex: 0 1 auto + min-width: 0  → 超长时省略号
///    chip flex: none                     → 标签永不被挤扁
///    ```
///    ⚠️ 只做①会被撑破：名称不收缩的话内容会溢出卡片盖住右侧按钮。
///    ⚠️ `min-width: 0` 是关键 —— flex 子项默认 `min-width: auto`，
///       不设则内容超宽时**顶开容器**而不是省略（经典陷阱）。
///
/// ③ 停用的卡片整体 `opacity: 0.55`
///    一眼看出"这张是关的"，不用逐个读开关状态。
/// ```
class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.provider,
    required this.onToggle,
    required this.onRemove,
    required this.onEdit,
    this.dragHandle,
    this.cellWidth = double.infinity,
    this.canMoveUp = false,
    this.canMoveDown = false,
    this.onMoveUp,
    this.onMoveDown,
    this.pluginEntry,
    this.onConfig,
    this.onPluginUpdate,
    this.onCopy,
  });

  final ProviderManifest provider;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  /// 拖动把手（**由 `ReorderableCardGrid` 造好传进来**）
  ///
  /// `null` = 这张卡不在可拖动列表里（例如将来的"搜索结果里的源预览"），
  /// 此时**不画把手** —— 画一个拖不动的把手比没有更糟。
  ///
  /// # ★ 2026-09-25：类型从 `int? dragIndex` 改成 `Widget? dragHandle`
  ///
  /// 换成响应式网格后，拖动不再由 `ReorderableDragStartListener` 负责
  ///（那个控件必须在 `ReorderableListView` 的子树里才能工作）。
  /// 现在把手是网格造的 `Draggable`，卡片只负责**把它放进版式里的那一格**。
  ///
  /// ⚠️ 为什么由网格造、而不是卡片自己 `Draggable`：
  ///    网格才知道"我拖的是第几格"（下标是网格的私有知识）；
  ///    卡片只知道"这一格要有一个抓手"。
  ///    而且把手**必须恒定占位**（见下面 `SizedBox` 的说明），
  ///    交给网格造能保证"有没有把手都占满 [_dragSlotW]"。
  final Widget? dragHandle;

  /// 这张卡所在格子的宽度（**由网格传进来**，见调用点）
  ///
  /// 卡片用它决定按钮是**横排**（宽）还是**换到第二行**（窄）——
  /// 见 [build] 里那段宽度预算分析。
  ///
  /// 默认 `double.infinity` = "没被网格管"（单列、直接铺开的场景），
  /// 那种情况下宽度总是够的，于是走宽版（按钮横排），
  /// 与改动前的行为**完全一致** —— 不会因为加了响应式而改变单列的观感。
  final double cellWidth;

  /// 能否上移 / 下移（第一张 / 最后一张为 false）
  ///
  /// ⚠️ 置灰而不是隐藏 —— 见调用点的说明（竖直对齐）。
  final bool canMoveUp;
  final bool canMoveDown;

  /// 上移 / 下移一位
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  /// 这个源对应的插件文件名（`154.js`），非 JS 源为 `null`
  ///
  /// # ★ 2026-09-25 合并「内容源 + JS 插件」时**从 `_PluginTile` 并过来**
  ///
  /// `_PluginTile` 第二行原本显示 `entry.file` —— 用户靠它对上**磁盘上的
  /// 文件**（「我要改的到底是哪一个」）。合并后列表只剩这一份
  ///（见 `_Block(title: 'JS 插件')` 的块头注释），这条信息不能丢。
  ///
  /// 拼在**描述行**（`_descLine`）后面，与 `id` 同级 ——
  /// 它俩都是"这个源在磁盘/注册表里叫什么"的标识信息。
  ///
  /// # ★ task-5（缺陷 5）：`String? pluginFile` → `PluginEntry? pluginEntry`
  ///
  /// Owner 缺陷 5 原文：
  /// > 你既然已经支持了 tvbox，那么就应该把所有的 tvbox 插件都还原成原本的链接，
  /// > 而不是现在转换后的插件，**而且要加上标识**，自己平台的插件还是 tvbox 的兼容
  ///
  /// 两件事都要卡片显示，而两件事的数据都**只在 `PluginEntry` 上**：
  /// ```text
  /// 标识      entry.author    （tvbox-convert / dsh / sourin）
  /// 上游链接   entry.upstream  （**只**取头部注释里的「上游接口」；2026-10-09 起不再看正文 const API）
  /// ```
  /// ⇒ 从"只传文件名"改成"传整条 entry"，三个字段一次带进来。
  ///
  /// ⚠️ `null` = 这个源没有对应的插件文件（内置 / 声明式 / HTTP 源，
  ///    或插件刚被删）→ 描述行不拼文件名、不画标识 chip。
  final PluginEntry? pluginEntry;

  /// ★ task-5（缺陷 5）：复制文本（上游链接）
  ///
  /// 复用**宿主**的 `_copy`（`lib/ui/settings_page.dart:1537`）—— 它已经做了
  /// `Clipboard.setData` + `_flash('已复制')`，且 `_toastRev` 让**二级页**
  ///（本卡片所在的「JS 插件」页）也能看到那条 toast（见 `_flash` 的注释）。
  ///
  /// ⚠️ `null` = 宿主没提供 → 上游 chip **退化成不可点**（仍显示链接文本，
  ///    因为"看得见"才是缺陷 5 的主诉求，"能复制"是顺带）。
  final void Function(String)? onCopy;

  /// 「配置」按钮（插件配置项，`plugin_config_get` 的唯一界面入口）
  ///
  /// # ★ 同样是从 `_PluginTile` 并过来的
  ///
  /// `null` = 这个源**没有插件配置文件**（内置 / 声明式 / HTTP），
  /// 卡片上**不画**「配置」按钮。
  ///
  /// ⚠️ 为什么不"永远显示、点进去再说"（原版 tile 的做法）：
  ///    对内置源调 `pluginConfigGet(id)` 必然报错 —— 那不是
  ///    「没有可配置项」，而是**这个东西不存在**，给按钮是骗人。
  ///    JS 插件（本机 26 个源全部）仍然**总是**显示按钮，
  ///    与原版一致（原版注释：`entry.config` 永远是空的，
  ///    所以点进去再拿真实声明，没有就明确提示）。
  final VoidCallback? onConfig;

  /// 「插件更新」入口（检测更新 + 更新历史/回滚）—— task-23
  ///
  /// # ★★ `null` 时**不画这个按钮** —— 这是本功能最重要的产品原则
  ///
  /// ```text
  /// 只有「从链接安装」的插件才有 sourceUrl（存在 plugins/.meta/<id>.json）。
  /// 用户手动丢进 plugins/ 的 .js **没有来源** → 无从查新版。
  /// ```
  /// 对这类插件：`onPluginUpdate == null` → 卡片上**不出现**更新入口。
  ///
  /// ⚠️ **绝不能**改成"显示按钮但点了提示已是最新" ——
  ///    那等于**假装有能力**：用户会以为"点了没反应 = 没问题"，
  ///    实际我们从没查过。**没有的能力不假装有**。
  ///
  /// ⚠️ 也**不显示**"无安装链接，无法检测更新"这种常驻文案：
  ///    26 张卡里 26 张都这么写是纯噪音。用户想知道时，
  ///    打开「更新历史」弹窗会看到如实说明（那里有足够空间讲清楚）。
  final VoidCallback? onPluginUpdate;

  /// 打开「编辑」（任务 R）
  ///
  /// 只有 `canEdit`（声明式 / HTTP / JS）的源才会画出这个按钮 ——
  /// 判据与原版 `canEdit`（`SettingsView.vue:1354`）一致：
  /// ```ts
  /// function canEdit(p: ProviderManifest): boolean {
  ///   return p.kind === "declarative" || p.kind === "http" || p.kind === "js";
  /// }
  /// ```
  /// 原版注释解释了为什么**正向列举**而不是「不等于 builtin」：
  /// > 判据要正向列举可编辑的，而不是「不等于 builtin」——
  /// > 后者在将来新增源类型时会误放行（点了报错比不放更糟）。
  final VoidCallback onEdit;

  /// 是否第三方（可移除）
  ///
  /// 原版用 `kind` 区分：`js` / `declarative` / `http` 是第三方的，
  /// 其余（内置 Rust 实现）不给删 —— 删了也会"复活"（编译在核心里）。
  bool get _isThirdParty =>
      provider.kind == 'js' ||
      provider.kind == 'declarative' ||
      provider.kind == 'http' ||
      provider.kind == 'tvbox';

  /// 该源能否编辑（★ 正向列举，不是「不等于 builtin」）
  ///
  /// # 三种形态各自能改什么（原版 `SettingsView.vue:1344` 的注释）
  ///
  /// ```text
  /// · declarative / http —— 有原始配置（JSON / URL + 头），可编辑
  /// · js                —— 插件是磁盘上的 .js 文件，可编辑
  /// · builtin           —— 编译进程序的，没有可改的配置
  /// ```
  ///
  /// # 为什么不写成 `provider.kind != 'builtin'`
  ///
  /// 原版注释（照抄）：
  /// > 判据要**正向列举可编辑的**，而不是「不等于 builtin」——
  /// > 后者在将来新增源类型时会误放行（**点了报错比不放更糟**）。
  ///
  /// 具体场景：后端的 `kind` 是 `String` 不是 enum，将来加
  /// `"wasm"` 之类的新形态时，`!= "builtin"` 会立刻放行，
  /// 用户点进去才发现没有可编辑的配置。
  bool get _canEdit =>
      provider.kind == 'declarative' ||
      provider.kind == 'http' ||
      provider.kind == 'js';

  /// kind 的中文标签
  ///
  /// ⚠️ 原版注释特别强调**标签必须反映真实形态**：
  /// > HTTP Provider 跑在独立进程、可用任意语言，与「声明式 JSON」
  /// > 是两回事，**标错会让用户误判能力与隔离性**
  String get _kindLabel => switch (provider.kind) {
    'js' => 'JS 插件',
    'declarative' => '声明式',
    'http' => 'HTTP 插件',
    'tvbox' => 'TVBox',
    '' => '内置',
    _ => provider.kind,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final off = !provider.enabled;

    return Opacity(
      // 原版 `.prov.is-off { opacity: 0.55 }`
      opacity: off ? 0.55 : 1.0,
      child: Container(
        // 原版 `.prov { padding: var(--sp-2) var(--sp-3) }` = 8px 12px
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: Radii.rLg,
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Column(
          /*
           * ⚠️ 从 `Row` 改成 `Column(Row, _panels)`（集成任务 M）
           *
           * 原来整个卡片就是一个横向 `Row`。代理/登录面板是**竖直表单**，
           * 塞进 `Row` 会被挤扁 —— 所以拆成两层：
           * ```text
           * Column
           *  ├ Row(图标 | 名称/描述/能力 | 按钮)   ← 原样保留
           *  └ _panels  代理 + 登录（可折叠，默认收起）
           * ```
           * 视觉上仍是**一张卡片**（同一个 Container 的边框/底色），
           * 不是两张拼在一起。
           */
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            /*
             * ══════════════════════════════════════════════════════════
             * ★★★ 卡片自己也要「根据宽度动态处理」（实测逼出来的）
             * ══════════════════════════════════════════════════════════
             *
             * # 为什么必须加这一层
             *
             * 网格给了 3 列（每列 402.67px），然后**26 张卡全部溢出
             * 115px**。用探针把一张卡的宽度预算逐项打出来才看清：
             * ```text
             * 卡片 402.67
             *  ├ padding 12×2 ………………………………… 24
             *  ├ 拖动把手 ……………………………………… 22
             *  ├ 图标 30 ……………………………………… 30
             *  ├ 间距 ………………………………………… 12
             *  ├ 正文（名称/chip/描述）……  只分到 40.7  ★ 需要 156
             *  ├ 间距 …………………………………………  8
             *  └ 操作按钮区 …………………………… 264  ← 5 个按钮固定这么宽
             * ```
             * 按钮区是 `flex: none`（永不被挤走，这是**对的**），
             * 于是被挤的是正文 —— 名称行硬需求 156px 只拿到 40.7px，
             * 溢出 115px。报错指向 `_nameRow`，根因却在按钮区，
             * 这种"现场离根因很远"的问题只能靠量预算定位。
             *
             * 横排一张卡需要：
             * ```text
             * 24 + 22 + 30 + 12 + 156(正文下限) + 8 + 264 = 516px
             * ```
             *
             * # 为什么不干脆把列宽提到 516
             *
             * ```text
             * 1280 窗口可用宽 1232 → floor(1244/528) = 2 列
             * ```
             * 用户明确要的是「**一行多个**」，1280 下只给 2 列等于
             * 把这次的需求做回去一半；而且原版在 1280 这类宽度下
             * 就是 **3 列**（`SettingsView.vue:4517` 注释写着
             * 「1316px 视口 → 3 列」）。列数必须保住 3，
             * 所以要让**卡片自己**适应窄列，而不是反过来放宽列。
             *
             * # 做法：窄的时候按钮**换到第二行**（右对齐）
             *
             * ```text
             * 宽（≥ 520）              窄（< 520）
             * ┌──────────────────────┐  ┌──────────────────────┐
             * │ ⠿ ▣ 名称 [JS]  ↑↓编辑…│  │ ⠿ ▣ 名称 [JS]        │
             * │       描述            │  │       描述            │
             * └──────────────────────┘  │          ↑↓ 编辑 停用 │
             *                           └──────────────────────┘
             * ```
             * 这是响应式卡片的常规做法：**信息（名称/描述）永远优先，
             * 操作次要时换行**。名称行的 156px 硬需求因此得到满足
             *（窄版一行只要 `24+22+30+12+156 = 244px`），
             * 而按钮仍然**全部可见可点** —— 没有隐藏任何功能。
             *
             * ⚠️ 阈值 520 = 上面那笔加法（516）向上取整到 10 的倍数。
             *    它是一个**算出来的**值，不是试出来的：改按钮数量/尺寸
             *    或把手宽度，这个数就要跟着重算。见 [_cardWideMinWidth]。
             *
             * ⚠️ 宽度是**网格传进来的**（[cellWidth]），不是自己量的：
             *    卡片里放 `LayoutBuilder` 会让子树**不支持 intrinsics**，
             *    外层负责"同一行等高"的 `IntrinsicHeight` 会抛
             *    "LayoutBuilder does not support returning intrinsic
             *    dimensions"（实测踩到）。网格本来就知道每格多宽，
             *    直接传下来既省一趟布局、又不破坏 intrinsics。
             */
            Builder(
              builder: (context) {
                final wide = cellWidth >= _cardWideMinWidth;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        /*
                 * ── 拖动把手（★ 新增，用户要求「可拖动排序」）──
                 *
                 * # 为什么把手**放在最左边**（图标之前）
                 *
                 * 三个候选位置，只有最左是对的：
                 * ```text
                 * ① 最左（现在）   与图标/正文/按钮不在同一视线流上，
                 *                  横向拖拽时不会误碰任何按钮
                 * ② 卡片右侧       会和「编辑/停用/移除」挤在一起，
                 *                  而默认把手正是因为这个原因被关掉
                 * ③ 整张卡都可拖   会吃掉卡片里所有按钮的点击
                 *                  （编辑/停用/移除/代理/登录全都点不动）
                 * ```
                 * ②③ 都是实测会出问题的方案，所以把手必须**独立占一格**。
                 *
                 * # ★ 2026-09-25：把手的**造法**换了，位置与占位规则没变
                 *
                 * ```text
                 * 旧：ReorderableDragStartListener（必须在 ReorderableListView
                 *     子树里才能找到祖先，换成网格后失效）
                 * 新：`dragHandle` 由 `ReorderableCardGrid` 造的 Draggable
                 * ```
                 * 但仍然**按下即可拖**（不是长按版）——
                 * 桌面/电视是鼠标/遥控，长按版是给触屏准备的，
                 * 用鼠标会"按半天没反应"（这条实测结论对两种实现都成立）。
                 *
                 * # ★ 这一格**恒定占位**（不管能不能拖都占 [_dragSlotW]）
                 *
                 * 因为 `_panels()` 的左缩进要跟这里**逐像素对齐**
                 *（集成任务 M 的成果：代理/登录面板与源名左边缘对齐）。
                 * 如果只在可拖时占位，缩进就得跟着变 —— 两处必然desync。
                 * 恒定占位让对齐关系是一个**常量**，不可能算错。
                 * 网格造的把手也是**定宽**的（`dragSlotWidth` 传的就是
                 * `_dragSlotW`），所以这个对齐关系在网格版下同样成立。
                 *
                 * ⚠️ 拖不动的卡（`dragHandle == null`）只画空白，不画把手 ——
                 *    画一个拖不动的把手比没有更糟。
                 */
                        SizedBox(width: _dragSlotW, child: dragHandle),

                        // ── 图标 30px 方块 ──
                        _ProviderIcon(provider: provider, colors: colors),
                        const SizedBox(width: Sp.x3),

                        // ── 正文（可收缩）──
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _nameRow(colors),
                              const SizedBox(height: 3),
                              _descLine(colors),
                              /*
                       * ★ task-5（缺陷 5）：来源标识 + 上游链接
                       *
                       * ⚠️ 单独一行、**不动描述行** —— 描述行是本卡最挤的
                       *    一行（211px 里要装"描述 · v版本 · 文件名"三样），
                       *    再往里塞必然把文件名挤没（见 `_descLine` 注释）。
                       *
                       * ⚠️ 两样都没有时**整行不画** —— 卡片高度与改动前
                       *    逐像素相同（内置源里 `cctv` 有 @author 但没链接，
                       *    只画标识 chip；只有"连作者都没写"的源才完全不画）。
                       */
                              if (_sourceLabel != null ||
                                  _upstream.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                _sourceLine(colors),
                              ],
                              /*
                       * ⚠️ `Capabilities` **没有** `hasAny` 之类的聚合 getter
                       *    （只有 8 个 bool 字段）—— 而 `models.dart` 不在
                       *    我这次允许改动的文件范围内，所以在这里本地算。
                       *    将来若给模型加 `hasAny`，这里可以换成直接调用。
                       */
                              if (_hasAnyCap(provider.capabilities)) ...[
                                const SizedBox(height: 4),
                                _capsRow(colors),
                              ],
                            ],
                          ),
                        ),

                        const SizedBox(width: Sp.x2),

                        // ── 操作按钮（宽版才在这一行；窄版见下面单独一行）──
                        if (wide) _actions(colors),
                      ],
                    ),

                    /*
                     * ── 窄版：操作按钮**换到第二行**，右对齐 ──
                     *
                     * 见上面那段预算分析：横排放不下时，被牺牲的
                     * 不能是名称/描述（信息优先），所以让按钮下来。
                     *
                     * `Align(alignment: centerRight)` 而不是 `Row(...end)`：
                     * 按钮区宽度是 `MainAxisSize.min`（按内容），
                     * 用 `Align` 才能把它推到右边而不拉满整行。
                     */
                    if (!wide) ...[
                      const SizedBox(height: Sp.x2),
                      Align(
                        alignment: Alignment.centerRight,
                        child: _actions(colors),
                      ),
                    ],
                  ],
                );
              },
            ),

            /*
             * ★★★ 2026-10-09：插件测速面板（Owner：「js插件…做一个探测功能…
             *     看哪个视频网站速度快，测速记录要持久化」）
             *
             * 位置：**源名同列**、且在代理/登录之上 ——
             * ```text
             * 测速结果是"这个源快不快"的属性，与源名/能力徽章同类；
             * 而代理/登录是"怎么连这个源"的配置 ⇒ 前者在上更顺。
             * ```
             * ⚠️ 面板自带 `Padding(top: Sp.x1)`，宽版卡片布局逐像素不变。
             *    卡片正文只有 ~211px，面板内部已用 Expanded + ellipsis 防溢出
             *    （speed-dev 实测三个状态 overflow = 0）。
             */
            PluginSpeedTestPanel(
              providerId: provider.id,
              providerName: provider.name,
              enabled: provider.enabled,
            ),

            // ── 源信息正下方：代理配置 + 账号登录（与源信息同一块，不再分隔）──
            _panels(),
          ],
        ),
      ),
    );
  }

  /// 源卡片内：**代理配置 + 账号登录**（集成任务 M 新增）
  ///
  /// # ★ 2026-09-25：从"卡片底部的独立区域"改成"源信息的一部分"
  ///
  /// 用户原话（对着 `.probe/USER-03-settings.png` 说的）：
  /// > 内容源的配置和登录等，合并到一起上面
  ///
  /// 那张截图里卡片长这样：
  /// ```text
  /// ┌──────────────────────────────────────────────────────┐
  /// │ [图标] 影视天涯 [JS 插件] [v1.0.0]       编辑 停用 🗑 │
  /// │        tyyszy                                        │
  /// │        [点播] [搜索]                                 │
  /// │ ──────────────────────────────────────────────────── │ ← Divider
  /// │ ⚙ 直连 ⌄                                             │ ← 看起来是"另挂的一块"
  /// └──────────────────────────────────────────────────────┘
  /// ```
  /// 问题不在"在下面"，而在**那条分隔线 + 缩进归零**：
  /// 源信息是一栏、配置是另一栏，用户得在脑子里把它们合成一个源。
  ///
  /// 现在：
  /// ```text
  /// ┌──────────────────────────────────────────────────────┐
  /// │ [图标] 影视天涯 [JS 插件] [v1.0.0]       编辑 停用 🗑 │
  /// │        tyyszy                                        │
  /// │        [点播] [搜索]                                 │
  /// │        ⚙ 直连 ⌄                    ← 与正文列左对齐   │
  /// │        👤 未登录          登录      ← 同一块，无分隔线 │
  /// └──────────────────────────────────────────────────────┘
  /// ```
  ///
  /// # 为什么是"卡片内的一层"，而不是塞进上面那个 `Row`
  ///
  /// ```text
  /// Row(  ← 水平布局：图标 | 正文 | 编辑/停用/移除
  ///   Expanded(Column(名称/描述/能力))
  /// )
  /// ```
  /// 代理和登录是**竖直展开的表单**（输入框、按钮组），
  /// 塞进横向 `Row` 里会被挤成一条线（右边还有一排按钮在抢宽度）。
  /// 所以保留"整宽一层"，改用两个手段表达"合并"：
  /// ```text
  /// ① 左缩进 42px（= 图标 30 + Sp.x3）→ 左边缘与源名/描述/能力**对齐**
  /// ② 不画 Divider，间距收到 Sp.x2    → 没有"这里是另一块"的视觉断点
  /// ```
  /// ⚠️ 展开后的表单宽度 = 卡片宽 − 卡片内边距 − 42px，仍然充裕；
  ///    真按"塞进 Row"改才会出问题。
  ///
  /// ⚠️ 两个面板**自带显示条件**，调用方不用判断：
  /// ```text
  /// ProxyPanel           永远显示（代理是通用能力）
  /// ProviderLoginPanel   只在 login_required || login_supported 时渲染，
  ///                      否则返回 SizedBox.shrink()
  /// ```
  ///
  /// ⚠️ 登录面板的 `caps` 传 null 会让它**自己再拉一次** provider 列表
  ///    （见 `provider_login_panel.dart` 的构造注释）。
  ///    ⚠️ 这里原先写着"因为 `models.dart` 的 `Capabilities` 少了 4 个
  ///    登录字段" —— 那个模型层 bug 已由任务 P2 修掉（现在有
  ///    `loginRequired` / `loginSupported` / `loginHint` /
  ///    `loginNeedsUsername` / `loginQrSupported` 与 `showLoginEntry`）。
  ///    这里仍然传 null 是**保持行为不变**的取舍（不再是"模型缺字段"）；
  ///    要省掉每卡一次 `listProviders()` 可以把 `provider.capabilities`
  ///    传进去 —— 那是另一个任务，不在本次改动范围。
  Widget _panels() {
    return Padding(
      /*
       * ★ 缩进 = 拖动把手格 + 图标宽 + 图标与正文的间距（`Sp.x3`）
       *   与 `Row` 里 `SizedBox(_dragSlotW)` + `_ProviderIcon`
       *   + `SizedBox(width: Sp.x3)` **逐像素对齐** ——
       *   对齐关系是"合并成一块"的全部依据，改任何一段这里都跟着变。
       *
       * ⚠️ 拖动把手那一格是**恒定占位**的（见 build 里 `SizedBox` 的说明），
       *    所以这里可以无条件算进去；若将来把手改成"可拖时才占位"，
       *    这里的常量就必须跟着变成条件值。
       */
      padding: const EdgeInsets.only(left: _dragSlotW + 30 + Sp.x3, top: Sp.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ProxyPanel(providerId: provider.id, providerName: provider.name),
          ProviderLoginPanel(
            providerId: provider.id,
            providerName: provider.name,
          ),
        ],
      ),
    );
  }

  /// 名称行 —— **禁止换行**（原版最强调的一条）
  ///
  /// # ★★ 2026-09-25：为了「一行 4 个」**精简了这一行**（用户要求卡片再小）
  ///
  /// 用户原话：
  /// > js插件这个尺寸还是太大了,在缩小点,一行我觉得还可以多占一个
  ///
  /// 上一轮 3 列时每格 402.67px，这一轮 4 列 → 每格 **299px**
  ///（`kMinCardWidth` 400→290）。格子窄了 104px，名称行必须让出空间。
  ///
  /// ## 精简了两处（**都照原版已经验证过的做法**，不是我自己拍的）
  ///
  /// ```text
  /// ① 去掉「JS 插件」chip
  ///
  ///    本机 26 个源 **kind 全是 'js'**（探针实测）——
  ///    也就是说这个 chip 在 26 张卡上一字不差地重复 26 遍，
  ///    零信息量，却占了 ~56px（chip + 间距）。
  ///
  ///    而且**块头已经写了「JS 插件」**（合并后的标题），
  ///    每张卡再标一次是同一个词的第二遍。
  ///
  ///    ⚠️ 非 js 的源（内置 / 声明式 / HTTP）**仍然显示**这个 chip ——
  ///       那时它是有信息量的（"这个源不是 JS 插件"），
  ///       而且那种源在本机是 0 个、在别人机器上也是少数。
  ///       完全不显示会让"类型"这一维信息消失，那是过度精简。
  ///
  /// ② 版本号移到**描述行**（`_descLine`）
  ///
  ///    ★ 原版已经这么做过，注释在 `SettingsView.vue:2054`：
  ///    ```
  ///    名称行只有约 241px，塞了「名称 + JS + v1.0.0」之后
  ///    名称只剩 ~145px —— 实测「示例源」被截成「示...」、
  ///    「🐝┃纯净┃采集」被截成「🐝┃纯净┃采...」，比高度不齐更难看。
  ///
  ///    而版本号是**低价值信息**（26 张卡里 25 张都是 v1.0.0），
  ///    放在名称行等于用"最贵的空间"显示"最没用的信息"。
  ///
  ///    移到描述行后名称拿回约 50px，且版本号仍在（信息没丢）。
  ///    ```
  ///    我们上一轮把版本放在名称行（`v1.0.0` chip），正好踩了原版
  ///    已经踩过并记录下来的同一个坑 —— 现在按原版的结论改回去。
  /// ```
  ///
  /// ## 精简后的宽度预算（4 列 / 每格 299px）
  ///
  /// ```text
  /// 窄版一行（卡片自己会把按钮换到第二行，见 build 里的说明）：
  ///   内边距 24 + 把手 22 + 图标 30 + 间距 12 + 正文 = 88 + 正文
  ///   299 − 88 = **211px 给正文**
  ///
  /// 正文里名称行的硬需求（chip 都 `flex:none`）：
  ///   名称(可收缩,最少 ~40) + 间距 8 + [JS chip 56] + [版本 52] + [已停用 60] + [已失效 60]
  ///
  /// · 精简前（每个 chip 都在）：40 + 8+56 + 4+52 + 4+60 + 4+60 = 288 > 211 ★ 溢出
  /// · 精简后（js 不显示 kind chip、版本下移）：
  ///       40 + [8+56 仅非 js] + [4+60 已停用] + [4+60 已失效] = 232（最坏，含 kind chip）
  ///       40 + [4+60] + [4+60]                                 = 168 ✓（js，本机情形）
  /// ```
  /// 名称 `Flexible` + ellipsis 兜底，所以"最坏 232 > 211"时截断的是**名称**
  ///（唯一可收缩项），不会溢出 —— 这正是原版 `flex: 0 1 auto` 的设计。
  Widget _nameRow(ColorScheme colors) {
    /*
     * ★ kind chip 只对**非 js** 源显示（理由见上面 ①）
     *
     * `provider.kind == 'js'` 时它零信息量（26/26 都是），且块头已写了
     * 「JS 插件」。非 js 时保留 —— 那时它告诉用户"这个源不是插件"，
     * 而且 `_kindLabel` 把 '' 映射成「内置」，那也是有意义的区分。
     */
    final showKind = provider.kind != 'js';
    return Row(
      children: [
        // 名称本体：可收缩 + 超长省略号
        Flexible(
          child: Text(
            provider.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: FontSizes.sm,
              fontWeight: FontWeights.regular,
              color: colors.onSurface,
            ),
          ),
        ),
        if (showKind) ...[
          const SizedBox(width: Sp.x2),
          // chip 一律 `flex: none`（不可压缩）
          _MiniChip(text: _kindLabel, tone: _ChipTone.brand),
        ],
        /*
         * ★ 版本号**不在这里**（2026-09-25 移走）——
         *   见方法头 ② 的说明：原版 `SettingsView.vue:2054` 已经验证过
         *   "版本放名称行会把名称挤成『示...』"，现移到 `_descLine`。
         */
        /*
         * ★ 两个状态标签是**两件事**，都要显示（原版注释）
         * ```text
         * 已停用 —— 用户的**选择**（可以改回来）
         * 已失效 —— 站点自身不可用（探测得出，用户改不了）
         * ```
         * 只显示一个会让用户以为"我明明没停用它啊"。
         */
        if (!provider.enabled) ...[
          const SizedBox(width: 4),
          _MiniChip(text: '已停用', tone: _ChipTone.off),
        ],
        if (!provider.working) ...[
          const SizedBox(width: 4),
          Tooltip(
            message: provider.brokenReason ?? '该源当前不可用',
            child: _MiniChip(text: '已失效', tone: _ChipTone.danger),
          ),
        ],
      ],
    );
  }

  Widget _descLine(ColorScheme colors) {
    final d = provider.description;
    /*
     * ★ 描述行 = 描述（或 id）+ 版本 + 插件文件名
     *
     * 原版 `_PluginTile` 的第二行是：
     * ```text
     * 154.js · v1.0.0
     * ```
     *
     * ★★ 2026-09-25：版本号**从名称行移到这一行**（用户要求卡片再小）
     *
     * 这不是新发明 —— 原版 `SettingsView.vue:2054` 早就这么改过，
     * 注释写得很清楚（见 `_nameRow` 方法头 ② 的引用）：
     * 版本是**低价值信息**（26 张里 25 张都是 v1.0.0），
     * 放在名称行等于用"最贵的空间"显示"最没用的信息"。
     *
     * 顺序：`描述 · v版本 · 文件名`
     * ```text
     * 描述      "这个源是干什么的" —— 最需要被看到，放最前
     * 版本      低价值，但从名称行下来了，仍然可见（信息没丢）
     * 文件名    "我该改哪个文件" —— 排最后，超长时它先被截断
     * ```
     * 三者都不显示时退化成 `provider.id`（保证这一行永远有内容）。
     *
     * ⚠️ 整行仍然 `maxLines: 1` + ellipsis：名称行"禁止换行"的约束
     *    （原版最强调的一条）在这里同样适用 —— 多一行就会让 26 张卡
     *    高度参差（原版 Owner：「这高度都不一样显示的太丑了」）。
     */
    final parts = <String>[
      (d == null || d.isEmpty) ? provider.id : d,
      if (provider.version.isNotEmpty) 'v${provider.version}',
      if (pluginEntry != null && pluginEntry!.file.isNotEmpty)
        pluginEntry!.file,
    ];
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: FontSizes.cap,
        color: colors.onSurfaceVariant,
        height: 1.4,
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★ task-5（缺陷 5）：来源标识 + 上游链接
  // ═══════════════════════════════════════════════════════════════════

  /// 上游接口地址（没有则空串）
  String get _upstream => pluginEntry?.upstream ?? '';

  /// 来源标识文案 —— `null` = **不显示**（源码里没写 `@author`，不猜）
  ///
  /// Owner 缺陷 5 原文：
  /// > ……而且要加上标识，**自己平台的插件**还是 **tvbox 的兼容**
  ///
  /// # 判据为什么是 `@author` 而不是 `kind`
  ///
  /// ```text
  /// kind  == 'js'            TVBox **插件**转换来的源
  ///                           和手写 JS 插件（内置 cctv.js / emby.js）
  ///                           **完全无法区分** ⇒ kind 做不到这件事
  /// @author == 'tvbox-convert'  ★ 转换器生成的（本机 22 个全是它）
  /// @author == 'dsh'            ★ 内置源模板（本机 6 个，从原版继承的名字）
  /// @author == 'sourin'         ★ 新增的 emby 模板（仓库 plugins/emby.js）
  /// ```
  ///
  /// ⚠️ `dsh` 与 `sourin` **都是"自己平台"** —— 前者是本项目从原版继承的
  ///    作者名（26 个内置源模板全用它），后者是新插件的品牌名。
  ///    只认 `dsh` 会让 emby 插件显示成"第三方"，那是错的。
  ///
  /// ⚠️ 其它非空作者 → 「第三方」：源码里**真的**有第三方名字，
  ///    显示"第三方"是如实描述，不是猜的。
  String? get _sourceLabel {
    final a = pluginEntry?.author ?? '';
    if (a.isEmpty) return null;
    if (a == 'tvbox-convert') return 'TVBox 兼容';
    if (a == 'dsh' || a == 'sourin') return '源影自研';
    return '第三方';
  }

  /// 来源行：`[标识 chip] [上游链接]` —— 两样都可缺，都不缺才是满配
  ///
  /// ⚠️ 复用 `_MiniChip` 的既有形态（**不新造控件、不加 tone**）——
  ///    `test/provider_layout_test.dart:145` 钉住了 `_ChipTone` 的四个取值，
  ///    加 tone 会动到那份契约。`brand`（primary 13% 底）在描述行的
  ///    灰字里一眼可辨，且描述行**本来就允许省略**（与名称行的纪律不同）。
  ///
  /// ⚠️ 链接那一半用 `Expanded` 吃掉剩余宽度 —— 211px 里 chip 占约 76px
  ///    （「TVBox 兼容」5 个全角字符 + 左右各 8px 内边距），剩下约 130px
  ///    给链接，超出的部分由 `_upstreamLink` 自己 ellipsis，**不溢出**。
  Widget _sourceLine(ColorScheme colors) {
    final label = _sourceLabel;
    return Row(
      children: [
        if (label != null) _MiniChip(text: label, tone: _ChipTone.brand),
        if (label != null && _upstream.isNotEmpty)
          const SizedBox(width: Sp.x2),
        if (_upstream.isNotEmpty) Expanded(child: _upstreamLink(colors)),
      ],
    );
  }

  /// 上游链接 —— 文字可省略，但**链接本体始终完整**（Tooltip + 点击复制）
  ///
  /// # 为什么必须有 Tooltip / 可复制（缺陷 5 的诉求落点）
  ///
  /// > 就应该把所有的 tvbox 插件都**还原成原本的链接**
  ///
  /// 卡片只有 211px 正文宽（4 列 / 299px 格，见 `_nameRow` 的宽度预算），
  /// 而真实接口长这样：
  /// ```text
  /// http://caiji.dyttzyapi.com/api.php/provide/vod/from/dyttm3u8/at/m3u8   （59 字符）
  /// ```
  /// ⇒ **物理上不可能**在卡片里显示全。于是：
  /// ```text
  /// 看得见   文字（可省略）—— 一眼知道"这个源的上游是哪个站"
  /// 拿得到   Tooltip 悬停看全文 / 点击复制到剪贴板 —— 一个字节都不丢
  /// ```
  /// ⚠️ 没有 `onCopy` 时退化成**纯文本**（不画链接图标、不可点）——
  ///    绝不画一个点了没反应的图标。
  Widget _upstreamLink(ColorScheme colors) {
    final text = Text(
      _upstream,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: FontSizes.cap,
        color: colors.primary,
        height: 1.4,
      ),
    );
    if (onCopy == null) return text;
    return Tooltip(
      message: '上游接口\n$_upstream\n\n点击复制',
      child: GestureDetector(
        onTap: () => onCopy!(_upstream),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 图标已在本文件用过（`:5377`）—— 不引入新图标
              Icon(Icons.link, size: 14, color: colors.primary),
              const SizedBox(width: 3),
              Flexible(child: text),
            ],
          ),
        ),
      ),
    );
  }

  /// 能力标签行
  ///
  /// 原版 `capabilities` 有 7 个位：点播/直播/节目单/回看/搜索/需登录/多源。
  /// 我们 `Capabilities` 的字段名不同（`live`/`search`/`login`/`epg`/
  /// `timeshift`/`category`/`rank`/`platformHistory`），映射如下。
  ///
  /// ⚠️ 标签顺序照原版的语义分组（**播放形态 → 功能 → 登录**），
  ///    不按字段声明顺序 —— 用户扫一眼先看到"这个源能干什么"。
  Widget _capsRow(ColorScheme colors) {
    return Wrap(
      spacing: 5,
      runSpacing: 4,
      children: [
        for (final t in _capLabels(provider.capabilities)) _MiniChip(text: t),
      ],
    );
  }

  Widget _actions(ColorScheme colors) {
    /*
     * ★★ 2026-09-25：`Row` → `Wrap`（**实测溢出 31px 逼出来的**）
     *
     * # 症状与量化
     *
     * 加上「插件更新」图标后，**窄版**（4 列 / 单格 299px）的按钮行溢出：
     * ```text
     * 卡片内容宽 273px（299 − 左右内边距 12×2 − 边框）
     * 7 个按钮（↑ ↓ │ ⚙ 编辑 停用 🗑）      = 264  ✓ 放得下
     * 8 个按钮（↑ ↓ │ ⟳ ⚙ 编辑 停用 🗑）    = 304  ✗ 溢出 31px
     * ```
     * 报错：`A RenderFlex overflowed by 31 pixels on the right.`
     *
     * # 为什么不是"少放一个按钮"
     *
     * ```text
     * ↑ ↓      用户明确要求「卡片上的移动按钮」（遥控唯一能用的排序方式）
     * ⟳        本次新增（检测更新/回滚的入口）
     * ⚙        插件配置的**唯一界面入口**（删了用户就配不了插件）
     * 编辑     改插件源码（块头提示就写着「能打开看、能自己改」）
     * 停用     用户日常最常用的开关
     * 🗑        移除源
     * ```
     * **没有一个是可以砍的** —— 砍哪个都是功能倒退。
     *
     * # 所以让按钮**折行**（响应式的常规答案）
     *
     * `Wrap` 在宽度够时与 `Row` **行为完全一致**（单行、不换行），
     * 只在放不下时才折到第二行。于是：
     * ```text
     * 宽版（≥520px，横排一行）      → 一行，与改动前**逐像素相同**
     * 窄版（299px，本来按钮就在第二行）→ 8 个按钮折成两行，**不溢出**
     * ```
     *
     * ⚠️ `spacing: 0`：按钮之间的间距由它们自己的 `padding`
     *    （`IconButton` 的 `visualDensity.compact` / `TextButton` 的
     *    `horizontal: Sp.x3`）提供 —— 再加 `spacing` 会变成双倍间距，
     *    宽版那一行就会比改动前宽（可能把别的卡挤溢出）。
     *    **保持 0 才能让宽版与改动前逐像素一致。**
     *
     * ⚠️ `alignment: WrapAlignment.end`：窄版按钮行是**右对齐**的
     *    （见调用点的 `Align(centerRight)`）；折行后第二行也该右对齐，
     *    否则会看起来"第一行靠右、第二行靠左"。
     *
     * ⚠️ `crossAxisAlignment: WrapCrossAlignment.center`：
     *    一行内按钮高度不同（IconButton 与 TextButton），居中对齐
     *    才能与原来的 `Row(crossAxisAlignment: center)` 一致。
     */
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 0,
      runSpacing: 2,
      children: [
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★ 「上一个 / 下一个」移动按钮（用户明确要求「卡片上的移动按钮」）
         * ══════════════════════════════════════════════════════════════
         *
         * 用户原话：
         * > 也可以支持调整顺序 卡片上的移动按钮 上一个下一个来排序
         *
         * # 为什么按钮是**必需**的，不能只靠拖动
         *
         * ```text
         * · TV / 遥控     —— 遥控只有方向键，**没有拖拽手势**，拖不动
         * · 触屏           —— 拖动要长按，和滚动容易混
         * · 精细定位       —— 26 个源里把第 25 个挪到第 3 个，
         *                     拖动要跨 22 张卡（还得边拖边滚），
         *                     按钮连点 22 次反而更可控
         * ```
         * 所以拖动是"顺手"的路径，按钮是"一定能用"的路径，两者都要。
         *
         * # 为什么放最左边（在「编辑」之前）
         *
         * 这两个按钮改变的是**这张卡在列表里的位置**（列表级操作），
         * 而编辑/停用/移除改的是**这个源自己**（条目级操作）。
         * 把列表级的放前面，扫过去是：
         * ```text
         * [↑][↓]  │  编辑  停用  🗑
         *  位置        └── 这个源本身 ──┘
         * ```
         *
         * # 边界按钮**置灰而不是隐藏**
         *
         * 隐藏会让第一张卡比别的卡少两个按钮、整列按钮左右错开；
         * 置灰则所有卡的按钮**竖直对齐**，位置固定好点。
         * `onPressed: null` 是 Flutter 里"置灰"的标准做法
         *（`IconButton` 会自动用 disabled 颜色）。
         */
        IconButton(
          onPressed: canMoveUp ? onMoveUp : null,
          icon: const Icon(Icons.keyboard_arrow_up, size: 18),
          tooltip: '上移一位',
          visualDensity: VisualDensity.compact,
          color: colors.onSurfaceVariant,
        ),
        IconButton(
          onPressed: canMoveDown ? onMoveDown : null,
          icon: const Icon(Icons.keyboard_arrow_down, size: 18),
          tooltip: '下移一位',
          visualDensity: VisualDensity.compact,
          color: colors.onSurfaceVariant,
        ),
        // 与右侧操作之间留一点间距，避免两组按钮糊成一片
        const SizedBox(width: Sp.x2),
        /*
         * ★ 「配置」（插件配置项）—— 合并时从 `_PluginTile` 并过来的
         *
         * # 为什么必须接出来
         *
         * 原版 `SettingsView.vue:2147`：
         * ```html
         * <button v-if="(p.config?.length || 0) > 0" class="icon-btn"
         *         title="配置" @click="openPluginConfig(p)">
         * ```
         * 它是 `plugin_config_get` 的**唯一界面入口** ——
         * 合并时如果只删 `_PluginTile` 而不把它接出来，
         * 用户就再也配不了插件的配置项（后端能力还在，但点不到）。
         *
         * ⚠️ `onConfig == null`（非 JS 源）时**不画** ——
         *    见字段注释：对内置源调 `pluginConfigGet` 必然报错。
         *
         * ⚠️ 放在「编辑」**左边**：两个都是"改这个源"，
         *    配置是改参数、编辑是改源码，配置更常用也更轻。
         */
        /*
         * ★★ 「插件更新」（检测更新 + 更新历史/回滚）—— task-23
         *
         * # 为什么是**图标按钮**而不是文字按钮
         *
         * 卡片现在是 **4 列、单格 299px**（`kMinCardWidth=290`）——
         * 横排放不下更多文字按钮了（见 `_cardWideMinWidth` 那笔宽度预算：
         * 5 个按钮已经占 264px）。所以更新入口做成**一个图标**，
         * 点开弹窗后再给足空间（弹窗是 480px 宽，能放链接、版本、历史列表）。
         *
         * # ★ `onPluginUpdate == null` 时**不画** —— 见字段注释
         *
         * 没有安装链接的插件（手动放入的）根本不显示这个按钮。
         */
        if (onPluginUpdate != null)
          IconButton(
            onPressed: onPluginUpdate,
            icon: const Icon(Icons.system_update_alt, size: 17),
            tooltip: '插件更新',
            visualDensity: VisualDensity.compact,
            color: colors.onSurfaceVariant,
          ),
        if (onConfig != null)
          IconButton(
            onPressed: onConfig,
            icon: const Icon(Icons.settings_outlined, size: 17),
            tooltip: '配置',
            visualDensity: VisualDensity.compact,
            color: colors.onSurfaceVariant,
          ),
        /*
         * ★ 「编辑」（任务 R）
         *
         * 原版 `SettingsView.vue:1921`：
         * ```html
         * <button v-if="canEdit(p)" class="btn btn--ghost" @click="edit(p)">编辑</button>
         * ```
         * 放在「停用」**左边**（顺序照原版：编辑 / 停用 / 移除）。
         *
         * ⚠️ 原版这里有过一个真 bug，注释记着：
         *    > 原先编辑按钮的条件是 `kind === 'http' || kind === 'declarative'`，
         *    > 而 JS 插件的 kind 是 `"js"` → **编辑按钮不显示**。
         *    > JS 插件当然该能编辑 —— 它就是磁盘上的一个 .js 文件。
         *    所以 `_canEdit` 里必须有 `'js'`。
         */
        if (_canEdit || _isThirdParty)
          PopupMenuButton<String>(
            tooltip: '更多操作',
            padding: EdgeInsets.zero,
            icon: Icon(
              Icons.more_vert,
              size: 17,
              color: colors.onSurfaceVariant,
            ),
            onSelected: (v) {
              if (v == 'edit') onEdit();
              if (v == 'remove') onRemove();
            },
            itemBuilder: (_) => [
              if (_canEdit)
                const PopupMenuItem(
                  value: 'edit',
                  child: Row(children: [
                    Icon(Icons.edit_outlined, size: 16),
                    SizedBox(width: Sp.x3),
                    Text('编辑'),
                  ]),
                ),
              if (_isThirdParty)
                PopupMenuItem(
                  value: 'remove',
                  child: Row(children: [
                    Icon(Icons.delete_outline, size: 16, color: colors.error),
                    SizedBox(width: Sp.x3),
                    Text('移除这个源', style: TextStyle(color: colors.error)),
                  ]),
                ),
            ],
          ),
      ],
    );
  }
}

/// 源图标 —— 30px 方块
///
/// 原版 `.prov__icon`：
/// ```css
/// width: 30px; height: 30px; border-radius: var(--r-md);
/// background: var(--surface-2); color: var(--text-secondary);
/// ```
/// 原版注释解释了为什么是 30 而不是 34：
/// > 图标只是**识别**用的（每个插件都是同一个 layers 图标，
/// > 本身不携带区分信息），34px 偏大了。收到 30px 后正文多出 4px，
/// > 且视觉上与右侧 30px 的图标按钮**等宽对齐**，一排看起来更整齐。
///
/// ⚠️ 原版还有个 `theme_color` 支持（`background: color + '22'`）——
///    我们有 `provider.themeColor` 字段，接上它能让不同源有颜色区分
///    （比原版"每个都是同一个图标"更有信息量）。
class _ProviderIcon extends StatelessWidget {
  const _ProviderIcon({required this.provider, required this.colors});

  final ProviderManifest provider;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    // 源自带图标（emoji / 短文本）
    final icon = provider.icon;
    final hasEmoji =
        icon != null &&
        icon.isNotEmpty &&
        icon.length <= 4 &&
        !icon.startsWith('http');

    // `theme_color` 形如 `#RRGGBB`
    Color? theme;
    final tc = provider.themeColor;
    if (tc != null && tc.startsWith('#') && tc.length == 7) {
      final v = int.tryParse(tc.substring(1), radix: 16);
      if (v != null) theme = Color(0xFF000000 | v);
    }

    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // `theme_color + '22'` = 13% 透明度（原版的写法）
        color: theme != null
            ? theme.withValues(alpha: 0.13)
            : colors.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: Radii.rMd,
      ),
      child: hasEmoji
          ? Text(icon, style: const TextStyle(fontSize: 15))
          : Icon(
              _fallbackIcon,
              size: 16,
              color: theme ?? colors.onSurfaceVariant,
            ),
    );
  }

  /// 没有自带图标时按 kind 给一个（比原版"全都是同一个图标"更能区分）
  IconData get _fallbackIcon => switch (provider.kind) {
    'js' => Icons.extension_outlined,
    'declarative' => Icons.description_outlined,
    'http' => Icons.cloud_outlined,
    'tvbox' => Icons.hub_outlined,
    _ => Icons.live_tv_outlined,
  };
}

class _PluginTile extends StatelessWidget {
  const _PluginTile({
    required this.entry,
    required this.onEdit,
    required this.onConfig,
    required this.onRemove,
  });

  final PluginEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onConfig;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.name.isEmpty ? entry.file : entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: FontSizes.sm,
                          fontWeight: FontWeights.regular,
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                    if (!entry.loaded) ...[
                      const SizedBox(width: Sp.x2),
                      Tooltip(
                        message: entry.error ?? '加载失败',
                        child: Icon(
                          Icons.error_outline,
                          size: 14,
                          color: colors.error,
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  '${entry.file}'
                  '${entry.version.isNotEmpty ? " · v${entry.version}" : ""}',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          /*
           * ★ 有配置声明时才显示「配置」按钮
           *
           * ⚠️ 但这里的 `entry.config` 来自 `listPlugins`，
           *    那个字段**永远是空的**（静态解析拿不到）。
           *    所以按钮**总是显示**，点进去再调 `pluginConfigGet`
           *    拿真实声明 —— 没有可配置项时给明确提示。
           */
          IconButton(
            onPressed: onConfig,
            icon: const Icon(Icons.settings_outlined, size: 18),
            tooltip: '配置',
          ),
          IconButton(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: '编辑',
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: '删除',
          ),
        ],
      ),
    );
  }
}

class _FailedPlugin extends StatelessWidget {
  const _FailedPlugin({required this.file, required this.reason});

  final String file;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x2),
      child: Row(
        children: [
          Icon(Icons.warning_amber, size: 16, color: colors.error),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Text(
              '$file · $reason',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
            ),
          ),
        ],
      ),
    );
  }
}

/// 遥控已开启时的面板
class _RemotePanel extends StatelessWidget {
  const _RemotePanel({
    required this.status,
    required this.busy,
    required this.onStop,
    required this.onRefreshPin,
    required this.onSetFixedPin,
    required this.onCopy,
  });

  final RemoteStatus status;
  final bool busy;
  final VoidCallback onStop;
  final VoidCallback onRefreshPin;
  final VoidCallback onSetFixedPin;
  final void Function(String) onCopy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        /*
         * ★ 局域网 IP 拿不到时必须明确告警
         *
         * 原版注释：
         * > 局域网 IP 拿不到时必须明确告警（否则用户会一直试连）
         */
        if (!status.reachable)
          Container(
            margin: const EdgeInsets.only(bottom: Sp.x3),
            padding: const EdgeInsets.all(Sp.x3),
            decoration: BoxDecoration(
              color: colors.errorContainer.withValues(alpha: 0.35),
              borderRadius: Radii.rSm,
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber, size: 14, color: colors.error),
                const SizedBox(width: Sp.x2),
                Expanded(
                  child: Text(
                    '未检测到局域网地址。请确认已连接 Wi-Fi / 网线，'
                    '否则手机无法访问。',
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.error,
                    ),
                  ),
                ),
              ],
            ),
          ),

        /*
         * ★★★ 2026-10-01：窄屏这块从「左二维码 + 右地址」改成**上下**
         *
         * 症状（Owner 报「排版混乱」，手机 411 dp 逻辑宽 ⇒ 内容区 363 dp）：
         * ```text
         *  ┌──────┐  手机访问地址
         *  │ 二维码│  http://10            ← ★ URL 折成 3 行 "http://10 / .0.2.15:8 / 642/"
         *  │ 140px│  .0.2.15:8
         *  └──────┘  642/                 复制
         * ```
         * 原因：`Row` 左边固定 140 dp 二维码 + `Spacer(20)`
         * ⇒ 右边只剩 363−140−20 = **203 dp**，而
         * `http://10.0.2.15:8642/` 在 `FontSizes.sm`(14) + monospace 下
         * 约需 176 dp —— 加上右边的「复制」按钮就更不够，
         * 于是 URL 被折成三行、`复制` 被挤到奇怪的位置。
         *
         * ★ 与 `SettingsBlock` 的窄屏修复**同一个阈值**（`kNarrowHeaderWidth`）——
         *   同一页上"什么算窄"必须只有一个答案，否则会出现
         *   "块头换了行、这块却没换"的割裂观感。
         */
        Builder(
          builder: (context) {
            final narrow =
                MediaQuery.sizeOf(context).width <
                SettingsBlock.kNarrowHeaderWidth;

            // ── 二维码（窄屏时居中显示，宽屏时靠左）──
            final Widget? qr = status.qrSvg.isEmpty
                ? null
                : Column(
                    children: [
                      QrView(svg: status.qrSvg, size: 140),
                      const SizedBox(height: Sp.x2),
                      Text(
                        '手机扫码打开遥控页',
                        style: TextStyle(
                          fontSize: FontSizes.cap,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  );

            // ── 地址 + 配对码 ──
            final Widget info = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _FieldLabel(text: '手机访问地址'),
                /*
                 * ★ URL 与「复制」也**不能**死板同行：
                 *   `SelectableText` 里的 URL 是不可断的 token，
                 *   窄屏下它会把「复制」挤出去 ⇒ 用 `Wrap` 让它们
                 *   在放不下时自动换行（宽屏仍是一行，观感不变）。
                 */
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SelectableText(
                      status.url,
                      style: TextStyle(
                        fontSize: FontSizes.sm,
                        fontFamily: 'monospace',
                        color: colors.primary,
                      ),
                    ),
                    TextButton(
                      onPressed: () => onCopy(status.url),
                      child: const Text('复制'),
                    ),
                  ],
                ),
                const SizedBox(height: Sp.x3),

                _FieldLabel(text: '配对码（输到手机上）'),
                Row(
                  children: [
                    Text(
                      status.pin,
                      style: TextStyle(
                        fontSize: FontSizes.lg,
                        fontWeight: FontWeights.semibold,
                        fontFamily: 'monospace',
                        letterSpacing: 3,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(width: Sp.x3),
                    TextButton(
                      onPressed: onRefreshPin,
                      child: const Text('换一个'),
                    ),
                  ],
                ),
                if (status.fixedPin != null) ...[
                  const SizedBox(height: Sp.x1),
                  Text(
                    '固定码：${status.fixedPin}（两个码都能进）',
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            );

            // ── 窄屏：二维码在上、信息在下；宽屏：左右并排（与改动前一致）──
            if (qr == null) return info;
            if (narrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(child: qr),
                  const SizedBox(height: Sp.x4),
                  info,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                qr,
                const SizedBox(width: Sp.x5),
                Expanded(child: info),
              ],
            );
          },
        ),

        const SizedBox(height: Sp.x3),
        /*
         * ★ 明确告知「二维码里不含配对码」
         *
         * 原版注释：
         * > 扫码打开页面后**仍需手输配对码** —— 二维码里不含配对码，
         * > 这样只有能看到这台设备的人才能连上。
         */
        Text(
          '扫码打开页面后仍需手输配对码 —— 二维码里不含配对码，'
          '这样只有能看到这台设备的人才能连上。',
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),

        const SizedBox(height: Sp.x4),
        /*
         * ★★★ 图标换成**包自带的标准字形**（Owner 二批第 4 条）
         *
         * # Owner 原话
         * ```text
         * > 关闭遥控 设固定码 icon,不好看,换一个正规一点的,不要你自己绘制
         * ```
         *
         * # 原先两个错在哪
         * ```text
         * · 「设固定码」用的 `Icons.pin_outlined` 是**图钉**（地图打点那种）
         *   —— 与「固定**码**」没有任何关系，字形本身也不对称，看着别扭。
         * · 「关闭遥控」用的 `Icons.stop` 是**实心方块**，夹在一排
         *   `OutlinedButton`（线性描边）里，粗细语言不一致 ⇒ 更显得
         *   "不好看"。Owner 点名的是前一个，这个顺带一起对齐。
         * ```
         *
         * # 为什么选这两个
         * ```text
         * · `Icons.password` —— Material 自带的「密码」字形（钥匙 + 圆点），
         *   语义就是「一串要手输的码」，与「设固定码 / 改固定码」逐字对上。
         * · `Icons.link_off` —— 断开的链环，标准「断开连接」字形，
         *   与「关闭遥控」逐字对上，且是**描边**风格，和 OutlinedButton 同族。
         * ```
         *
         * ⚠️ 两者都来自 `material_ui` 包（`fontFamily: 'MaterialIcons'`），
         *    **没有一个字节是自绘的** —— 正是 Owner 要的「正规一点」。
         * ⚠️ 尺寸仍保持 `size: 16`，与 `OutlinedButton` 的 16px 内边距配套；
         *    调大会把按钮撑高、与左边一排按钮不齐。
         */
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            OutlinedButton.icon(
              onPressed: busy ? null : onStop,
              icon: const Icon(Icons.link_off, size: 16),
              label: const Text('关闭遥控'),
            ),
            OutlinedButton.icon(
              onPressed: onSetFixedPin,
              icon: const Icon(Icons.password, size: 16),
              label: Text(status.fixedPin == null ? '设固定码' : '改固定码'),
            ),
          ],
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: FontSizes.cap,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// 小标签（chip）
///
/// # `tone` 的四档（照原版 `SettingsView.vue` 里的 chip 变体）
///
/// ```text
/// plain   中性     —— 版本号、能力标签（原版 `.chip`）
/// brand   品牌色   —— kind 标签，如「JS 插件」（原版 `.chip--brand`）
/// off     灰       —— 已停用（原版 `.chip--off`）
/// danger  红       —— 已失效（原版内联 `rgb(255 77 94 / 0.2)` + `#ff8a8a`）
/// ```
///
/// ⚠️ 为什么要有色彩区分（不是纯装饰）：
/// 原版把「已停用」和「已失效」做成**两个不同颜色**的标签，
/// 因为它们是**两件事**：
/// ```text
/// 已停用 = 用户的选择（可以改回来）
/// 已失效 = 站点自身不可用（用户改不了）
/// ```
/// 同色的话用户会以为"我明明没停用它啊"。
///
/// ⚠️ 这个 enum **只能有一份定义** —— 我插入 `_MiniChip` 新版本时
///    忘了删旧的那份，编译报 `The name '_ChipTone' is already defined`。
///    Dart 里同名类型不能重复声明（即使内容完全一样）。
enum _ChipTone { plain, brand, off, danger }

/// 菜单项的一行（图标 + 文案）—— 插件块头 / 卡片 ⋮ 菜单共用///
/// 为什么单独抽：两处菜单的项都是同一形态（16px 图标 + 8px 间距 + 文字），
/// 各写一遍的代价是以后调间距时漏一处，菜单里就出现两种行宽。
/// 「局域网遥控」区块外壳 —— **默认收起**（2026-10-10）
///
/// # 为什么要收起（实测依据）
///
/// 改前它是一个常开的 `SettingsBlock`，在手机（412×915）上量得：
/// ```text
/// 组「远程」       top = 135
/// 组「内容源与插件」 top = 835   ← 差 700px
/// ```
/// 也就是**首屏 915px 里有 700px 被遥控一个功能占掉**，
/// 而「内容源与插件」（用户最常用的那一组）要往下滑一整屏才看得到。
/// 遥控还是**默认关闭**的低频功能（Owner 没开过）。
///
/// 根因不只是"说明文字长"—— 开启后的 `_RemotePanel` 里有 PIN 码、
/// 二维码、复制按钮，那一块天生就高。展开时必须让位，没理由让
/// **没启用**时也先占着。
///
/// # 收起态给出什么
///
/// ```text
/// ┌ ⌁▾ 局域网遥控  没开启 · 手机浏览器遥控，不用装 App ┐
/// ```
/// 一行说清「是什么 + 现在什么状态」，想配的人点一下就展开 ——
/// 与本页其它入口行（`SettingsEntryRow`）同一形态。
///
/// # 展开态
///
/// 沿用 `SettingsBlock` 的视觉（同样的标题字号、同样的外框），
/// 末尾多一行「收起」入口 —— 折叠了却没法展开回来是不行的。
class _RemoteBlock extends StatefulWidget {
  const _RemoteBlock({
    required this.running,
    required this.autoStart,
    required this.busy,
    required this.child,
  });

  /// 遥控当前是否**已在运行**
  final bool running;

  /// 「开机自动开启」是否勾上
  final bool autoStart;

  final bool busy;

  /// 展开后的内容（开关 + 启动按钮 / 运行面板）
  final Widget child;

  @override
  State<_RemoteBlock> createState() => _RemoteBlockState();
}

class _RemoteBlockState extends State<_RemoteBlock> {
  /// ★ 默认收起；一旦**用户自己**展开过就记住（否则每次进设置页
  ///   都要重新点开，反复配置的用户会觉得这个折叠很烦）。
  ///
  /// 「已在运行」时**强制展开** —— 那种情况下用户多半是来改 PIN /
  /// 停掉它，折叠起来等于把正在用的功能藏了。
  bool _open = false;

  bool get _shouldOpen => _open || widget.running;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    if (!_shouldOpen) {
      return Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: Radii.rLg,
          onTap: () => setState(() => _open = true),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Sp.x4,
              vertical: Sp.x3,
            ),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: Radii.rLg,
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '局域网遥控',
                        style: TextStyle(
                          fontSize: FontSizes.base,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '没开启 · 手机浏览器遥控，不用装 App',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: FontSizes.cap,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Sp.x2),
                Icon(
                  Icons.expand_more,
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SettingsBlock(
      title: '局域网遥控',
      trailing: TextButton(
        onPressed: widget.busy ? null : () => setState(() => _open = false),
        child: const Text('收起'),
      ),
      children: [
        Text(
          'TV 遥控器打字搜索很难用。开启后，手机浏览器打开下面的网址，'
          '就能搜索、选集、切线路、下一集 —— 手机输入关键词，电视上直接开播。',
          style: TextStyle(
            fontSize: FontSizes.sm,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Sp.x4),
        widget.child,
      ],
    );
  }
}

Widget _menuRow(IconData icon, String label, {Color? color}) => Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: Sp.x3),
        Text(label, style: color == null ? null : TextStyle(color: color)),
      ],
    );

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.text, this.tone = _ChipTone.plain});

  final String text;
  final _ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * 具体色值：
     * ```text
     * plain   透明底 + outlineVariant 描边
     * brand   primary 13% 底（原版用主题色，我们同义）
     * off     onSurface 8% 底 + 更淡的字
     * danger  error 20% 底 + error 字（原版是硬编码的红，我们用语义色）
     * ```
     * ⚠️ 用 `withValues(alpha:)` 而不是 `withOpacity` ——
     *    后者已废弃（analyze 会报 deprecation）。
     */
    final (Color bg, Color fg, bool outline) = switch (tone) {
      _ChipTone.plain => (Colors.transparent, colors.onSurfaceVariant, true),
      _ChipTone.brand => (
        colors.primary.withValues(alpha: 0.13),
        colors.primary,
        false,
      ),
      _ChipTone.off => (
        colors.onSurface.withValues(alpha: 0.08),
        colors.onSurfaceVariant.withValues(alpha: 0.75),
        false,
      ),
      _ChipTone.danger => (
        colors.error.withValues(alpha: 0.20),
        colors.error,
        false,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: Radii.rFull,
        border: outline ? Border.all(color: colors.outlineVariant) : null,
      ),
      child: Text(
        text,
        // ⚠️ 不换行 —— 与名称行的"禁止换行"配套（见 `_nameRow` 的说明）
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: fg,
          fontWeight: tone == _ChipTone.plain
              ? FontWeight.w400
              : FontWeights.regular,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  对话框
// ═══════════════════════════════════════════════════════════════════════

/// 源排序对话框
class _OrderDialog extends StatefulWidget {
  const _OrderDialog({
    required this.draft,
    required this.nameOf,
    required this.offOf,
  });

  final List<String> draft;
  final String Function(String) nameOf;
  final bool Function(String) offOf;

  @override
  State<_OrderDialog> createState() => _OrderDialogState();
}

class _OrderDialogState extends State<_OrderDialog> {
  late List<String> _list = [...widget.draft];

  void _move(int i, int dir) {
    final j = i + dir;
    if (j < 0 || j >= _list.length) return;
    setState(() {
      final t = _list[i];
      _list[i] = _list[j];
      _list[j] = t;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('调整内容源顺序'),
      content: SizedBox(
        width: 420,
        height: 400,
        child: ListView.builder(
          clipBehavior: Clip.antiAlias,
          itemCount: _list.length,
          itemBuilder: (_, i) {
            final id = _list[i];
            return ListTile(
              dense: true,
              leading: Text(
                '${i + 1}',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              title: Text(widget.nameOf(id)),
              // 已停用的标注出来，避免用户以为它消失了
              subtitle: widget.offOf(id)
                  ? Text(
                      '已停用',
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.onSurfaceVariant,
                      ),
                    )
                  : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: i > 0 ? () => _move(i, -1) : null,
                    icon: const Icon(Icons.keyboard_arrow_up),
                    tooltip: '上移',
                  ),
                  IconButton(
                    onPressed: i < _list.length - 1 ? () => _move(i, 1) : null,
                    icon: const Icon(Icons.keyboard_arrow_down),
                    tooltip: '下移',
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _list),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 「插件更新」弹窗 —— 检测更新 + 更新历史（回滚）（task-23）
///
/// # 用户拍板
///
/// > 通过链接检测更新,可以进行回滚
/// > 插件市场暂时不做  github raw 暂时不做
///
/// # 为什么交互是"点按钮才检测"
///
/// ```text
/// 打开弹窗就自动检测 → 用户只想"看一眼历史"也会触发一次网络请求
///                       （慢、可能失败、还可能被 CDN 限流）
/// ```
/// 所以打开时只显示**本地已有**的信息（当前版本 + 来源链接 + 历史档），
/// 「检测更新」是一个**显式动作**。这也是"不自动覆盖"的前提：
/// 检测 → 用户看到结果 → 再决定要不要更新。
///
/// # 三件事的视觉层次
///
/// ```text
/// ① 顶部：当前版本 + 来源链接（截断显示，鼠标悬停看全）
/// ② 中间：「检测更新」按钮 + 检测结果（三种状态如实显示）
/// ③ 底部：更新历史列表（版本 + 时间 + 「回滚」按钮）
/// ```
///
/// ⚠️ 检测的三种结局都要**如实**（见 `PluginUpdateInfo` 的文档）：
/// ```text
/// 无更新        → 「已是最新（v1.0.0）」
/// 有更新        → 「发现新版本 v1.1.0」+ 一个「更新到 v1.1.0」按钮
/// 失败          → 红色显示**失败原因**（网络错/链接失效/不是插件/无版本号）
/// ```
/// **绝不**把失败显示成"已是最新" —— 那是假装成功。
class _PluginUpdateDialog extends StatefulWidget {
  const _PluginUpdateDialog({
    required this.id,
    required this.name,
    required this.sourceUrl,
  });

  final String id;
  final String name;

  /// 安装来源链接（只有**有来源**的插件才会打开这个弹窗）
  final String sourceUrl;

  @override
  State<_PluginUpdateDialog> createState() => _PluginUpdateDialogState();
}

class _PluginUpdateDialogState extends State<_PluginUpdateDialog> {
  /// 历史版本档（新的在前）
  List<PluginVersionEntry> _versions = const [];

  /// 当前版本（从 `listPlugins` 拿不到，用检测结果或历史推断；
  /// 打开时先留空，检测后填上）
  String _current = '';

  bool _loadingVersions = true;
  bool _checking = false;
  bool _updating = false;
  bool _rollingBack = false;

  /// 检测结果（`null` = 还没检测过 —— 与"检测了但失败"是两回事）
  /// 检测结果（字段名避开方法 `_check()` —— 同名会 duplicate_definition）
  PluginUpdateInfo? _result;
  String? _error;

  /// 弹窗里是否做过更新/回滚（关闭时告诉父级要不要刷新）
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _loadVersions();
  }

  /// 拉历史档（**纯本地读目录**，不联网）
  Future<void> _loadVersions() async {
    setState(() => _loadingVersions = true);
    try {
      final v = await SourinApi.listPluginVersions(widget.id);
      if (!mounted) return;
      setState(() {
        _versions = v;
        _loadingVersions = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '读取更新历史失败：$e';
        _loadingVersions = false;
      });
    }
  }

  /// 检测更新（用户**点了才**联网）
  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
      _result = null;
    });
    try {
      final r = await SourinApi.checkPluginUpdate(widget.id);
      if (!mounted) return;
      setState(() {
        _result = r;
        _current = r.version;
        /*
         * ⚠️ 这里**不**把 `r.error` 塞进 `_error`：
         *    检测失败是"这次检测的结论"，要显示在**检测区域**（紧挨着按钮），
         *    而 `_error` 是弹窗级的错误（读历史失败等）。
         *    两者混在一起会让用户分不清"是检测失败还是弹窗坏了"。
         */
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // 命令本身抛错（网络/后端异常）→ 也如实显示
        _result = PluginUpdateInfo(
          id: widget.id,
          version: _current,
          error: '$e',
        );
        _checking = false;
      });
    }
  }

  /// 更新到远端最新版（用户**点了才**覆盖）
  Future<void> _update() async {
    if (_updating) return;
    setState(() {
      _updating = true;
      _error = null;
    });
    try {
      final r = await SourinApi.updatePluginFromSource(widget.id);
      if (!mounted) return;
      setState(() {
        _updating = false;
        _changed = true;
        if (r.updated) {
          _current = r.version;
          _result = null; // 结果过期了，让用户重新检测（或直接看版本变了）
        }
      });
      await _loadVersions();
      if (mounted) {
        _flashLocal(
          r.updated
              ? '已更新到 v${r.version}（旧版 v${r.fromVersion} 已归档，可回滚）'
              : (r.reason ?? '内容一致，无需更新'),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _updating = false;
        _error = '更新失败：$e';
      });
    }
  }

  /// 回滚到某一档
  Future<void> _rollback(String version) async {
    if (_rollingBack) return;
    setState(() {
      _rollingBack = true;
      _error = null;
    });
    try {
      final r = await SourinApi.rollbackPlugin(widget.id, version);
      if (!mounted) return;
      setState(() {
        _rollingBack = false;
        _changed = true;
        _current = r.version;
        _result = null;
      });
      await _loadVersions();
      if (mounted) {
        _flashLocal('已回滚到 v${r.version}（原 v${r.fromVersion} 也已归档，可再切回）');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _rollingBack = false;
        _error = '回滚失败：$e';
      });
    }
  }

  /// 弹窗内的一行提示（不依赖父级的 `_flash` —— 那个显示在页面底部，
  /// 会被弹窗挡住，用户根本看不到）
  void _flashLocal(String msg) {
    if (!mounted) return;
    setState(() => _toast = msg);
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _toast == msg) setState(() => _toast = null);
    });
  }

  String? _toast;

  bool get _busy => _checking || _updating || _rollingBack;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final c = _result;

    return AlertDialog(
      title: Row(
        children: [
          Flexible(
            child: Text(
              '插件更新 · ${widget.name}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        // ★ 有界高度（照 `_SkipHistoryDialog`）：内容再多也只占 460px，内部滚动
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 当前版本 ──
            Row(
              children: [
                Text(
                  '当前版本',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: Sp.x2),
                Text(
                  _current.isEmpty ? '（点「检测更新」后显示）' : 'v$_current',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    fontWeight: FontWeights.regular,
                    color: colors.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Sp.x2),

            // ── 来源链接（截断 + 悬停看全）──
            Tooltip(
              message: widget.sourceUrl,
              child: Row(
                children: [
                  Icon(Icons.link, size: 14, color: colors.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.sourceUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Sp.x3),

            // ── 检测按钮 + 结果 ──
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _check,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(_checking ? '检测中…' : '检测更新'),
                ),
                const SizedBox(width: Sp.x3),
                Expanded(child: _checkResult(colors, c)),
              ],
            ),
            const SizedBox(height: Sp.x2),

            /*
             * ★ 有新版才出现「更新」按钮 —— **绝不自动覆盖**
             *
             * 用户要"检测更新"，不是"自动更新"。发现新版后必须让用户点。
             * （原版「必须确认才导入」的精神。）
             */
            if (c != null && c.hasUpdate) ...[
              FilledButton.icon(
                onPressed: _busy ? null : _update,
                icon: const Icon(Icons.download, size: 16),
                label: Text(_updating ? '更新中…' : '更新到 v${c.remoteVersion}'),
              ),
              const SizedBox(height: Sp.x2),
            ],

            if (_error != null) ...[
              Text(
                _error!,
                style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
              ),
              const SizedBox(height: Sp.x2),
            ],

            Divider(height: 1, color: colors.outlineVariant),
            const SizedBox(height: Sp.x2),

            // ── 历史档 ──
            Row(
              children: [
                Text(
                  '更新历史',
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    fontWeight: FontWeights.regular,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(width: Sp.x2),
                Text(
                  '（可回滚）',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Sp.x2),
            Expanded(child: _historyList(colors)),

            if (_toast != null) ...[
              const SizedBox(height: Sp.x2),
              Text(
                _toast!,
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.primary,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _changed),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  /// 检测结果那一行（**三种状态如实区分**）
  Widget _checkResult(ColorScheme colors, PluginUpdateInfo? c) {
    if (_checking) {
      return Text(
        '正在检查来源链接…',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      );
    }
    if (c == null) {
      return Text(
        '还没检测过',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      );
    }
    /*
     * ★★ 失败必须**如实**显示原因（用户拍板验收里明确要求）
     *
     * 网络错 / 链接失效 / 返回不是 JS / 远端没有 @version ——
     * 全都要让用户看到，**绝不能**显示成"已是最新"。
     *
     * ⚠️ `checked` 这个 getter 的语义就是"查到了结论"：
     *    有来源 + 没错误。失败时不满足 → 走下面那条红色分支。
     */
    if (c.error != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 14, color: colors.error),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '检测失败：${c.error}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
            ),
          ),
        ],
      );
    }
    if (c.hasUpdate) {
      return Text(
        '发现新版本 v${c.remoteVersion}',
        style: TextStyle(
          fontSize: FontSizes.cap,
          fontWeight: FontWeights.regular,
          color: colors.primary,
        ),
      );
    }
    /*
     * 无新版（远端版本 <= 本地）。
     *
     * ⚠️ `sameContent == false` 是个**值得说一句**的情况：
     *    作者改了内容但**忘了改版本号** —— 版本比较得出"没更新"，
     *    但内容其实不同。如实说明，不要假装"完全一致"。
     */
    return Text(
      c.sameContent
          ? '已是最新（v${c.version}）'
          : '已是最新（v${c.version}）· 注意：远端内容与本地不同但版本号未变',
      style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
    );
  }

  /// 历史档列表（**空列表不是错误**，如实说明为什么没有）
  Widget _historyList(ColorScheme colors) {
    if (_loadingVersions) {
      return Center(
        child: Text(
          '读取中…',
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      );
    }
    if (_versions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x3),
          child: Text(
            /*
             * ★★ 如实说明"为什么没有历史"
             *
             * 这里也是**唯一**告诉用户"这个插件没有安装链接"的地方 ——
             * 卡片上刻意不写（26 张卡都写是噪音），
             * 弹窗里有空间把原因讲清楚。
             */
            '还没有历史版本。\n\n'
            '每当你点「更新到 vX」，旧版会自动归档一份到 '
            'plugins/.versions/，之后就能从这里回滚。\n'
            '最多保留最近 $kMaxPluginVersionsShown 档（更旧的自动清理）。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: FontSizes.cap,
              height: 1.6,
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      clipBehavior: Clip.antiAlias,
      itemCount: _versions.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: colors.outlineVariant),
      itemBuilder: (_, i) {
        final v = _versions[i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.x2),
          child: Row(
            children: [
              Icon(Icons.history, size: 15, color: colors.onSurfaceVariant),
              const SizedBox(width: Sp.x2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'v${v.version}',
                      style: TextStyle(
                        fontSize: FontSizes.sm,
                        fontWeight: FontWeights.regular,
                        color: colors.onSurface,
                      ),
                    ),
                    Text(
                      '${_fmtTime(v.at)} · ${(v.bytes / 1024).toStringAsFixed(1)} KB',
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Sp.x2),
              TextButton(
                onPressed: _busy ? null : () => _rollback(v.version),
                child: Text(
                  _rollingBack ? '回滚中…' : '回滚到此版',
                  style: const TextStyle(fontSize: FontSizes.cap),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 时间格式：`MM-DD HH:mm`（够用且不占地方）
  static String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// 插件配置对话框（按声明渲染表单）
class _PluginConfigDialog extends StatefulWidget {
  const _PluginConfigDialog({required this.name, required this.config});

  final String name;
  final PluginConfig config;

  @override
  State<_PluginConfigDialog> createState() => _PluginConfigDialogState();
}

class _PluginConfigDialogState extends State<_PluginConfigDialog> {
  final _controllers = <String, TextEditingController>{};
  final _bools = <String, bool>{};
  final _selects = <String, String>{};

  @override
  void initState() {
    super.initState();
    for (final f in widget.config.fields) {
      final v = widget.config.values[f.key] ?? f.defaultValue;
      switch (f.type) {
        // ★ 归一后的词是 switch（不是 bool）—— 见 models.dart ConfigField
        case 'switch':
          _bools[f.key] = v == true || v == 'true';
        case 'select':
          _selects[f.key] = v?.toString() ?? '';
        // ★ info 是纯说明文字，不建控件也不建控制器
        case 'info':
          break;
        default:
          _controllers[f.key] = TextEditingController(
            text: v?.toString() ?? '',
          );
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('配置「${widget.name}」'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final f in widget.config.fields) ...[
                Text(
                  f.label,
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    fontWeight: FontWeights.regular,
                    color: colors.onSurface,
                  ),
                ),
                if (f.description != null && f.description!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      f.description!,
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: Sp.x2),
                _field(f),
                const SizedBox(height: Sp.x4),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final out = <String, dynamic>{};
            for (final f in widget.config.fields) {
              switch (f.type) {
                // ★ 归一后的词是 switch（不是 bool）
                case 'switch':
                  out[f.key] = _bools[f.key] ?? false;
                case 'select':
                  out[f.key] = _selects[f.key] ?? '';
                case 'number':
                  out[f.key] =
                      num.tryParse(_controllers[f.key]?.text ?? '') ?? 0;
                // ★ info 不接收值：宿主 config_value_ok 对 info 恒 false，
                //   把它一起回写会让**整次保存**以「值类型不对」失败。
                case 'info':
                  break;
                default:
                  out[f.key] = _controllers[f.key]?.text ?? '';
              }
            }
            Navigator.pop(context, out);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _field(ConfigField f) {
    switch (f.type) {
      // ★ 归一后的词是 switch（不是 bool）—— 见 models.dart ConfigField
      case 'switch':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _bools[f.key] ?? false,
          onChanged: (v) => setState(() => _bools[f.key] = v),
          title: const SizedBox.shrink(),
        );
      case 'select':
        return DropdownButtonFormField<String>(
          initialValue: _selects[f.key],
          items: [
            for (final o in f.options)
              DropdownMenuItem(value: o.value, child: Text(o.label)),
          ],
          onChanged: (v) => setState(() => _selects[f.key] = v ?? ''),
        );
      case 'password':
        return TextField(
          controller: _controllers[f.key],
          obscureText: true,
          decoration: InputDecoration(
            hintText: f.placeholder ?? '',
            border: const OutlineInputBorder(),
          ),
        );
      // ★ info = 纯说明文字：它**不接收值**（宿主 config_value_ok 对 info
      //   恒 false），所以这里不能画输入框 —— 画了用户就会去填，
      //   一填整次保存就会以「值类型不对」失败。
      //   标签与说明文字已由上面的通用行渲染，这里只需留空。
      case 'info':
        return const SizedBox.shrink();
      default:
        return TextField(
          controller: _controllers[f.key],
          keyboardType: f.type == 'number'
              ? TextInputType.number
              : TextInputType.text,
          decoration: InputDecoration(
            hintText: f.placeholder ?? '',
            border: const OutlineInputBorder(),
          ),
        );
    }
  }
}
