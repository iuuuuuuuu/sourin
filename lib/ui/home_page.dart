// ═══════════════════════════════════════════════════════════════════════
//  发现页 —— 对齐原版 HomeView.vue（713 行）
// ═══════════════════════════════════════════════════════════════════════
//
// 页面完全数据驱动：拿到什么 Provider 就渲染什么区块，
// **接入新视频站不需要改这个文件**。
//
// # ★★ 三条从原版继承的加载策略（都是实测得出的，别"优化"掉）
//
// ## ① 每次进首页都刷新源列表（不是只在为空时）
//
// 原版注释记录的真 bug：
// > 原写法是 `if (!providerList.length) await loadProviders()`
// > —— 只在"列表为空"时才拉。而**装完插件后列表并不为空**（只是旧数据），
// > 于是永远不会更新。更糟的是在 Android 上装第一个插件时：
// > 装之前列表里只有被停用的 demo，装完回来因为长度非 0，
// > **依然不重新拉** → 首页还是空的。用户必须重启应用。
// >
// > 为什么现在可以无条件拉：`list_providers` 是**纯本地**调用，
// > 不联网、不新建 JS runtime，实测 <10ms。
//
// ## ② 分区骨架没变就不换引用
//
// 原版注释：
// > Vue 的列表渲染按引用比对。`content.home()` 每次都返回新数组，
// > 于是 240 张卡片全部重建 DOM（实测 2158 个节点）。
// > 实测对比：切到搜索页 1ms / 切回首页 **360ms**。
//
// Flutter 侧对应的是：**不要在数据没变时 setState** ——
// 那会让整个 `ListView` 重建。这里用「指纹比对」实现同样的语义。
//
// ## ③ 区块内容按需刷新 + 只拉当前源
//
// 原版注释：
// > 原先无条件重拉全部区块 —— 实测后果：切走再切回首页要 **4.2 秒**
// > （13 个区块 × 每个一次插件调用，央视的栏目列表单次就 ~690ms）。
// > 再加一条：**只拉当前显示的源** —— 4 源 × 8 区块 ≈ 30 次请求
// > 降到 **8 次**。
//
// 现在的策略：
// ```text
// 已有数据 → 保留，不重拉（内容不会秒变）
// 无数据   → 拉
// force    → 全拉（用户手动刷新）
// ```

import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:material_ui/material_ui.dart';

import '../core/sourin_api.dart';
import '../core/ui_prefs.dart';
import 'tokens.dart';
import 'widgets/fade_in_sliver.dart';
import 'widgets/poster_card.dart';
import 'widgets/press_feedback.dart';
import 'widgets/my_shelf.dart';
import 'widgets/source_bar.dart';

/// 首页直播条只展示这几个常用频道，完整列表在「直播」页
///
/// ⚠️ 与原版 `HomeView.vue` L31 的 `LIVE_PREVIEW` **完全一致** ——
///    顺序、id、显示名都不要改（id 是 cctv 源的频道标识）。
const kLivePreview = <({String id, String name})>[
  (id: 'cctv1', name: 'CCTV-1'),
  (id: 'cctv2', name: 'CCTV-2'),
  (id: 'cctv5', name: 'CCTV-5'),
  (id: 'cctv6', name: 'CCTV-6'),
  (id: 'cctv8', name: 'CCTV-8'),
  (id: 'cctv13', name: 'CCTV-13'),
  (id: 'cctvjilu', name: 'CCTV-9'),
  (id: 'cctvchild', name: 'CCTV-14'),
];

/// 这个源能不能给**首页**提供内容（首页分区）
///
/// # 判据是**能力位**，不是源 id 白名单
///
/// ```text
/// providesHomeContent(p)  <=>  p.capabilities.vod
/// ```
/// ★ 绝不写成 `p.id != 'iptv' && p.id != 'tvbox-live'` 这种**枚举** ——
///   新装一个纯直播源就又漏了。本项目已有教训：
///   **生成闸必须是谓词，不是枚举**。
///
/// # 为什么 `vod == false` 就等于「首页没内容」
///
/// 首页的分区来自 `getHome()`，而 `home_all()`
/// （`rust/sourin_core/src/registry.rs:406-435`）只把 `home()` **返回非空**
/// 的源放进聚合（`:428 if let Ok(sections) = p.home().await { if !sections.is_empty() {`）。
/// 而 `MediaProvider::home()` 的默认实现就是 `Ok(vec![])`
/// （`rust/sourin_core/src/provider.rs:230-232`）——
/// 纯直播源**没有覆写它**（实测全仓只有 `cctv.js:386` / `cycani.js:361` /
/// `demo.js:81` 覆写了 `home()`；`iptv.js` / `tvbox-live.js` 里
/// `home` 零命中）。
/// ```text
/// iptv.js:642-647        vod: false, live: true   ← 纯直播
/// tvbox-live.js:44-49    vod: false, live: true   ← 纯直播
/// cctv.js:371            vod: true,  live: true   ← ★ 不是纯直播，必须留下
/// ```
/// ⇒ 选中纯直播源时首页必然只剩空态 —— 而源**明明是启用的**，
///   用户看到「还没有可用的内容源 / 在设置里启用或导入一个内容源」
///   完全摸不着头脑。这就是 Owner 报的那个问题。
///
/// # ★ 字段名核对（不做这一步就会写出一个**永远为假**的闸）
///
/// ```text
/// Dart   lib/core/models.dart:298   vod: j['vod'] as bool? ?? false
/// Rust   rust/sourin_core/src/model.rs:559-561
///        #[derive(Debug, Clone, Default, Serialize, Deserialize)]
///        pub struct Capabilities { pub vod: bool, pub live: bool, ... }
///        ↑ ★ 结构体上**没有** #[serde(rename_all = ...)] ⇒ 原样发 "vod"
/// ```
/// ⇒ 两边**逐字一致**。
/// ⚠️ `models.dart:128-156` 记着一个真 bug：旧 Dart 字段
///    `rank` / `category` / `platform_history` / `login` 后端**从不下发**
///    ⇒ 永远 false（JSON 缺键被 `?? false` 兜住，不抛异常、测试全绿）。
///    所以用能力位之前**必须**像上面这样把两边字段名对一遍。
///
/// # 实测读数（真实 28 个源：`.probe/t352-vod/out/01_providers.json`）
///
/// ```text
/// vod == true    26 个  ← 保留（cycani / bilibili / cctv / 154 / demo /
///                          各 api-* 与 *zyapi 聚合站 …）
/// vod == false    2 个  ← 只有这两个被排除（iptv / tvbox-live）
/// ```
/// ★ 即：这个过滤在真实数据上**只减 2 个**，不会误伤点播源。
bool providesHomeContent(ProviderManifest p) => p.capabilities.vod;

/// 从「已启用的源」里挑出**首页可用的**那些（顺序原样保留）
///
/// ⚠️ 顺序**绝不能重排** —— 那是用户在设置页拖出来的顺序
///    （`provider-order.json`）。这里只做**减法**。
List<ProviderManifest> homeSourceList(List<ProviderManifest> all) =>
    all.where(providesHomeContent).toList();

/// ★★ 探针：`loadAll` 的**调用记录**（task-41）
///
/// # 为什么需要它（两个"日志判据失效"的原因叠加）
///
/// 我原本想用 `[HOME] loadAll 开始 (force=..., reason=...)` 的**文本计数**
/// 来断言"保活生效（`initState` 只 1 次）+ 刷新仍在（`tab-switch` 仍在）"。
/// 但实测**两条路都不通**：
/// ```text
/// ① 无核心环境：`loadAll` 在第一个 IPC 就抛 ⇒ 后面的日志打不出
///    （fix-autoscroll 的读数 home_renders = 0→0 就是这个）
/// ② ★ 即使在有输出的情况下，在 `flutter_test` 里覆盖 `debugPrint`
///    **也捕获不到**这些调用（binding 会接管/重置它）
///    ⇒ 我在测试里 `debugPrint = (m,{w}) => log.add(m)`，计数**恒为 0**，
///      而原始输出里明明有那几行
/// ```
/// ⇒ ★ 结论：**要测"某个函数被调用了几次"，就直接记调用本身，
///   不要记它的副作用（一行日志）** —— 判据与被测属性同源。
///
/// ⚠️ 只在 debug 下写入（见 `loadAll` 里的 `kDebugMode` 判断），
///    release 构建**零开销**。
/// ⚠️ 测试用 `debugLoadAllCalls.clear()` 在启动前清空。
final List<({bool force, String reason})> debugLoadAllCalls =
    <({bool force, String reason})>[];

/// 发现页
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.onOpenDetail,
    this.onOpenLive,
    this.onBrowse,
    this.onShelfPlay,
    this.onSeeAllShelf,
    this.isTv = false,
  });

  /// 点卡片 → 详情页
  ///
  /// ⚠️ 原版注释：
  /// > 这里必须**跳详情页**，不能直接开播放器：
  /// > 多集内容需要选集、多源内容需要换源，这些都挂在 DetailView 上。
  /// > 直接开播放器会让用户**永远只能看第一集**。
  final void Function(String provider, String id)? onOpenDetail;

  /// 点直播频道 → 直接进播放器（直播没有剧集/多源，跳详情是多余一步）
  final void Function(String channelId, String name)? onOpenLive;

  /// 「查看全部」→ 浏览页
  final void Function(String provider, String sectionTitle, SectionSource src)?
      onBrowse;

  /// 点「我的」卡片 → 进播放器（续播）
  ///
  /// ⚠️ 与其它区块不同：这些是"我自己的数据"，
  ///    用户点它就是要**接着看**，不是去浏览详情。
  final void Function(
    String provider,
    String id,
    String title,
    String? cover,
    String? episodeId,
  )? onShelfPlay;

  /// ★★ task-65：「我的」版块的「查看更多」→ 切到追更页并激活对应 tab
  ///
  /// 参数是**追更页的 tab key**（`'following'` / `'all'` / `'continue'`）——
  /// 由 `MyShelf` 按当前 tab 算好（见 `shelfTabToFollowKey`）。
  ///
  /// ⚠️ 为什么不让本页自己切：切 tab 是 **shell** 的职责
  ///    （`AppTab` 与底栏选中态都在那里）。本页只上报意图。
  final void Function(String followTabKey)? onSeeAllShelf;

  final bool isTv;

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  /// 「我的」版块的 key —— 切回首页时要刷新它
  ///
  /// 原版注释：
  /// > 本页在 `keepAlivePages` 里，`onMounted` **只执行一次**。
  /// > 而首页内容是会变的：用户在设置页导入/停用了源、
  /// > 「我的」三合一的收藏/追更/历史变了。
  final _shelfKey = GlobalKey<MyShelfState>();
  List<ProviderGroup> _groups = [];

  /// 区块内容缓存：`provider::sectionId` → items
  ///
  /// 用双冒号分隔（原版也是）—— 因为 provider id 里可能含单冒号，
  /// 单冒号做分隔符会切错。
  final Map<String, List<MediaItem>> _sectionItems = {};

  bool _loading = true;
  String? _error;

  /// 当前显示的源
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 持久化：从 `UiPrefs` 读回上次选中的源（2026-09-24 补齐）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # 用户指出「首页的选中源记录」没做
  ///
  /// 之前 `_currentSource` **只在内存里** —— 关掉应用再打开就回到第一个源。
  /// 用户在多源之间选了一个想看的，下次打开又得重选。
  ///
  /// # 原版怎么做（`stores/app.ts`）
  ///
  /// ```ts
  /// const HOME_SOURCE_KEY = "dsh.homeSource";
  /// const homeSource = ref<string>(readHomeSource());
  ///
  /// // 写盘防抖（用户可能快速连点几个源）
  /// watch(homeSource, (v) => {
  ///   saveTimer = window.setTimeout(() => {
  ///     if (v) localStorage.setItem(HOME_SOURCE_KEY, v);
  ///     else localStorage.removeItem(HOME_SOURCE_KEY);
  ///   }, 300);
  /// });
  /// ```
  ///
  /// ⚠️ 原版注释特别强调**键要独立**：
  /// > 它和播放偏好（`dsh.playprefs`）没关系。混在一起的话，
  /// > 「清空播放偏好」会顺带把首页选中的源也清掉 ——
  /// > 那是两件不相干的事。
  ///
  /// 所以用 `UiPrefs.homeSource`（键 `dsh.homeSource`），
  /// **不是** `dsh.srcpref.*`（那是"某作品用哪条播放线路"）。
  ///
  /// # 为什么不用自己写防抖
  ///
  /// 原版要防抖是因为 `localStorage.setItem` 是**同步 + 落盘**的，
  /// 连点会阻塞主线程。而 `UiPrefs.set` 本身就有
  /// `_flushSoon()` 合并（见那里的注释）—— 所以直接调即可。
  String _currentSource = UiPrefs.homeSource;

  /// 已启用**且首页可用**的源（切换条用）
  ///
  /// ⚠️ 它**不是**「所有已启用的源」—— 纯直播源
  ///    （`capabilities.vod == false`）已在 [homeSourceList] 里被排除。
  ///    「一共启用了几个」这个读数仍然完整保留在日志里
  ///    （见 `loadAll` 的 `[HOME] 已启用 → N 个` 那一行）。
  List<ProviderManifest> _enabled = [];

  /// 每个源各记各的滚动位置（同一页面内换源用）
  final Map<String, double> _railScroll = {};
  final _scrollController = ScrollController();

  /// 分区骨架指纹（用于「没变就不换引用」）
  String _fingerprint = '';

  @override
  void initState() {
    super.initState();
    // 原版 `onMounted(() => loadAll({ force: true }))`
    //
    // ★ `reason: 'initState'` —— **只有这里**代表"页面被重建"
    //   （保活失效时它会在每次切回时多跑一次；见 `loadAll` 的说明）
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => loadAll(force: true, reason: 'initState'),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 拉取首页全部数据
  ///
  /// [force] 强制重新拉取（忽略缓存）
  ///
  /// [reason] **仅用于日志**的调用来源标记（task-41 加）
  ///
  /// # 为什么需要它（一个读数、三个原因）
  ///
  /// `[HOME] loadAll 开始 (force=$force)` 这行日志的 `force=true` 有**三个**来源：
  /// ```text
  /// ① initState                → force=true   ← ★ **只有这条**代表"页面被重建"（缺陷）
  /// ② onRefresh（用户下拉）      → force=true
  /// ③ shell 的 onProvidersChanged → force=true
  ///    （在设置页改源后刷新首页）
  /// ```
  /// ⇒ ★ 拿"`force=true` 出现几次"当"页面有没有重建"的判据**会误判**：
  ///   用户在设置页停用了一个源、再回首页 → 计数 +1 → 断言失败，
  ///   **但保活是好的**。
  ///
  /// ⇒ 所以加一个**枚举**形式的 `reason`（白名单，不是自由文本 ——
  ///   后人加调用点时会被类型系统提醒）。
  ///   判据变成：**`reason=initState` 只出现 1 次**（只有启动那一次）。
  ///
  /// ★ 一般教训（铁律 71）：
  ///   **读数有多因时，判据必须先分离原因** ——
  ///   否则修好一个原因后读数不变，会被误判为"没修好"；
  ///   弄坏另一个原因后读数变好，会被误判为"修好了"。
  ///   ★ 尤其是多个原因**分属不同人的不同任务**时（这里是 task-36 / task-41 /
  ///     设置页逻辑），最容易漏掉第三者 ⇒ 设计判据时要把**所有调用点 grep 全**。
  ///
  /// ⚠️ 它**只影响 debugPrint**，零行为影响。
  Future<void> loadAll({bool force = false, String reason = 'unspecified'}) async {
    debugPrint('[HOME] loadAll 开始 (force=$force, reason=$reason)');
    /*
     * ★★ 探针记录（task-41）—— 让 `reason` 变成**可运行时读取**的计数
     *
     * # 为什么不能靠 `debugPrint` 的文本捕获（我实测踩到）
     *
     * 我在测试里 `debugPrint = (m, {wrapWidth}) => log.add(m)`，
     * 结果 **计数恒为 0**，而日志**确实打印了**（原始输出里能看到）。
     * ⇒ 在 `flutter_test` 里覆盖 `debugPrint` **捕获不到**这些调用
     *   （binding 会在测试启动时接管/重置它）。
     * ★ 这是**第二个**独立的"日志判据失效"原因 ——
     *   第一个是"无核心时 loadAll 在 IPC 前就抛，日志打不出"。
     *   ⇒ 两个原因叠加，难怪 fix-autoscroll 的探针读数恒为 0。
     *
     * ⇒ 改成**运行时变量**记录：不依赖日志管线，直接读数组。
     *   ★ 这与"判据要同源"一致：我要测"loadAll 被谁调用了几次"，
     *     那就直接记**调用本身**，而不是它的副作用（一行日志）。
     *
     * ⚠️ 只在 debug 下记录（`kDebugMode`），release 构建**零开销**。
     *    测试跑在 debug 下 ⇒ 能读到。
     */
    if (kDebugMode) {
      debugLoadAllCalls.add((force: force, reason: reason));
    }
    /*
     * ★ 同时刷新「我的」版块
     *
     * 原版注释：
     * > 而首页内容是会变的：用户在设置页导入/停用了源、
     * > 「我的」三合一的收藏/追更/历史变了。
     *
     * ⚠️ 不 await —— 「我的」是独立数据平面，
     *    让它自己慢慢加载，不阻塞内容分区（那要 4 秒）。
     */
    unawaited(_shelfKey.currentState?.load() ?? Future.value());
    try {
      // ① 无条件刷新源列表（见文件头注释 —— 这是修过的真 bug）
      final providers = await SourinApi.listProviders();
      debugPrint('[HOME] listProviders → ${providers.length} 个');
      final enabled = providers.where((p) => p.enabled).toList();
      /*
       * ★★★ 首页源条只显示**能给首页提供内容**的源（2026-10-01）
       *
       * # Owner 原话
       * > 然后直播源不能作为首页的,只能作为直播源显示在直播页
       *
       * # 为什么必须有这一步
       *
       * `enabled` 只回答了「用户要不要它」，没回答「它能不能给首页内容」。
       * 纯直播源（`vod == false`）的 `home()` 是默认实现 ⇒ 返回空 vec
       * ⇒ 用户在首页选中它以后**什么都看不到**，而源明明是启用的。
       * 判据与实测见 [providesHomeContent]。
       *
       * ⚠️ `_enabled` 从此装的是**过滤后**的列表 —— 下游两处都靠它：
       *    ① 源切换条（`SourceBar(sources: _enabled, …)`）
       *    ② `_currentSource` 的回退解析（见下面那段）
       * 两处必须**同源**：只改一处就会出现「条上没有它、
       * 当前源却还是它」的错配（那正是空态与解析打架的成因）。
       */
      final homeSources = homeSourceList(enabled);
      debugPrint('[HOME] 已启用 → ${enabled.length} 个: '
          '${enabled.take(5).map((p) => p.id).join(", ")}');
      debugPrint('[HOME] 其中首页可用 → ${homeSources.length} 个'
          '（排除纯直播源 ${enabled.length - homeSources.length} 个：'
          '${enabled.where((p) => !providesHomeContent(p)).map((p) => p.id).join(", ")}）');

      /*
       * 当前源的解析顺序（与原版 `store.activeHomeSource` 等价）：
       * ```text
       * ① 用户上次选的（_currentSource）—— 前提是它还在启用列表里
       * ② 否则取第一个启用的源（优雅回退，而不是白屏）
       * ```
       * ⚠️ 原版注释强调过：**上次选的那个源被停用/删掉了**时要优雅回退。
       */
      var current = _currentSource;
      /*
       * ⚠️ 这里判的是 `homeSources` 而**不是** `enabled`（2026-10-01）
       *
       * 边界：用户上次在首页选的正是某个纯直播源（比如 `iptv`），
       * 而它现在被过滤掉了。若这里仍按 `enabled` 判，`current` 会
       * **保持 `iptv` 不变** ⇒ 源条上没有它、`visible` 又取不到它的分区
       * ⇒ 页面停在空态，且 `UiPrefs` 里一直存着这个首页用不了的 id。
       * 按 `homeSources` 判 ⇒ 走「上次选的源不可用」那条既有回退路径，
       * 优雅落到第一个首页可用的源上，并落盘。
       *
       * 若 `homeSources` 为空（用户只启用了纯直播源）⇒ `current = ''`
       * ⇒ `visible` 为空 ⇒ 显示空态。这是**唯一自洽**的结果：
       * 首页确实一个可展示的源都没有。此时不会与解析打架 ——
       * 两者用的是同一个列表，不存在「有当前源但没内容」的中间态。
       * ⚠️ 但空态那句文案（`_EmptyState` 的
       *    `title: '还没有可用的内容源'`）在这种情形下**是误导的** ——
       *    用户明明启用了源。
       *    本轮**不改**（超出「一处过滤」的范围），已记入交付报告。
       *    ★ 这里刻意**不写行号** —— 本文件每次改动都会让行号漂，
       *      写死行号的注释必然过期（我自己这一轮就把空态从 :714
       *      推到了 :837）。引用**内容**比引用**位置**耐用。
       */
      if (current.isEmpty || !homeSources.any((p) => p.id == current)) {
        current = homeSources.isNotEmpty ? homeSources.first.id : '';
        /*
         * ★ 回退后也要落盘（2026-09-24）
         *
         * 原版注释强调过这个场景：
         * > **上次选的那个源被停用/删掉了**时要优雅回退。
         *
         * 回退发生时不写盘的话，下次启动又会读到那个**已失效的 id**
         * （`UiPrefs` 里还存着旧的），于是一次次走回退逻辑 ——
         * 功能上没错，但存的是脏数据。
         *
         * ⚠️ 用 `setHomeSource`（空串 = 清除）而不是直接 `set`。
         */
        UiPrefs.setHomeSource(current);
      }

      /*
       * ② 首次进入才显示骨架屏
       *
       * 原版注释：
       * > 返回本页时若把 loading 置回 true，整个首页会**闪一下骨架**
       * > （内容明明还在内存里）。只在「没有任何数据」时才显示加载态。
       */
      final showSkeleton = _groups.isEmpty;

      final t0 = DateTime.now();
      debugPrint('[HOME] 调 getHome()…（25 个源，可能要几秒）');
      final next = await SourinApi.getHome();
      debugPrint('[HOME] getHome 返回: ${next.length} 个分组，'
          '耗时 ${DateTime.now().difference(t0).inMilliseconds}ms');

      /*
       * ③ 分区没变就不换引用
       *
       * 指纹 = provider + 每个区块的 id。内容变了
       *（用户导入/停用了源）才真的换 —— 那种情况本来也该重渲。
       */
      final fp = next
          .map((g) => '${g.provider}:${g.sections.map((s) => s.id).join(",")}')
          .join('|');
      final changed = fp != _fingerprint;

      if (mounted) {
        setState(() {
          _enabled = homeSources;
          _currentSource = current;
          if (changed) {
            _groups = next;
            _fingerprint = fp;
          }
          _loading = showSkeleton;
          _error = null;
        });
      }

      /*
       * ④ 区块内容按需刷新 + **只拉当前源**
       *
       * 已有数据 → 跳过；force → 全拉；只处理当前源的分区。
       */
      final pending = <Future<void>>[];
      for (final g in _groups) {
        if (current.isNotEmpty && g.provider != current) continue;
        for (final s in g.sections) {
          final key = '${g.provider}::${s.id}';
          final has = (_sectionItems[key]?.isNotEmpty) ?? false;
          if (force || !has) {
            pending.add(_loadSection(g.provider, s.id, s.source));
          }
        }
      }
      debugPrint('[HOME] 待加载区块 ${pending.length} 个'
          '（当前源=$current）');
      await Future.wait(pending);
      debugPrint('[HOME] 全部区块加载完成');

      if (mounted) setState(() => _loading = false);

      /*
       * ★ 渲染探针（2026-09-23）—— **不依赖屏幕**
       *
       * # 为什么必须有它
       *
       * 截图验证有个致命前提：屏幕得是亮的、会话得是解锁的。
       * 实测踩到过：机器锁屏后抓到的全是锁屏画面，多次截图 SHA256
       * 完全相同 —— 看起来极像「应用没渲染」，实际是验证手段失效。
       *
       * 所以把**真实渲染的数据量**打到 stdout。这个探针在锁屏下依然有效，
       * 而且比截图更能说明问题：
       * ```text
       * 截图只能看出「有没有内容」
       * 这个能看出「渲染了几个源 / 几个区块 / 几张卡片」
       * ```
       */
      var sections = 0;
      var cards = 0;
      for (final g in _groups) {
        if (_currentSource.isNotEmpty && g.provider != _currentSource) continue;
        for (final s in g.sections) {
          sections++;
          cards += _itemsOf(g.provider, s.id).length;
        }
      }
      /*
       * ⚠️ 这个探针报的是**首页可用**的源数，不是「一共启用了几个」
       *    （2026-10-01 明确语义，免得两个数被读成同一个）
       *
       * ```text
       * [HOME] 已启用 → N 个            ← 全部已启用（含纯直播源）
       * [HOME] 其中首页可用 → M 个      ← 过滤后
       * [HOME] 渲染完成: 启用源=M 个    ← ★ 本行 = M，与源条上药丸数一致
       * ```
       * 为什么让本行报 M：它是**渲染**探针（注释开头就写了
       * 「把真实渲染的数据量打到 stdout」），而源条现在渲染的正是
       * `_enabled` = M 个。报 N 会与源条上实际药丸数**对不上**。
       * N 没有丢 —— 上面那两行仍然完整打印。
       */
      debugPrint('[HOME] 渲染完成: 启用源=${_enabled.length} 个'
          '（首页可用，已排除纯直播源）'
          '（当前=$_currentSource）'
          ' 分区=$sections 卡片=$cards 错误=${_error ?? "无"}');
    } catch (e, st) {
      debugPrint('[HOME] ★ loadAll 失败: ');
      debugPrint('');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  /// 加载一个首页区块
  ///
  /// # ★ 必须**同时支持 category 与 rank 两种来源**
  ///
  /// 原版注释：
  /// > 早先只处理 `category`，而 cycani 的首页声明的是
  /// > `SectionSource::Rank`（「TV番组榜」「剧场番组榜」）——
  /// > 于是那两个区块永远显示「暂无内容」
  /// > （声明了却拉不到，是真实的半成品缺陷）。
  ///
  /// `custom` 型（直播条）不需要拉数据，模板里直接渲染固定频道，
  /// 故这里显式跳过而不是报错。
  Future<void> _loadSection(
    String provider,
    String sectionId,
    SectionSource src,
  ) async {
    final key = '$provider::$sectionId';
    try {
      if (src.isCategory && src.categoryId != null) {
        final page = await SourinApi.getList(provider, src.categoryId!);
        if (mounted) {
          setState(() => _sectionItems[key] = page.items);
        }
      } else if (src.isRank && src.rankId != null) {
        final page = await SourinApi.getRank(provider, src.rankId!);
        if (mounted) {
          setState(() => _sectionItems[key] = page.items);
        }
      }
      // 其它类型（custom / static / recent）由界面自行处理，无需预取
    } catch (e) {
      /*
       * ★ 错误隔离：单个区块失败**不影响**其他区块
       *
       * 原版 `console.warn` 后继续 —— 这里同理，只记日志。
       * 不 setState 报错：一个源挂了不该让整页显示错误条。
       */
      debugPrint('[HOME] 区块 $sectionId 加载失败: $e');
    }
  }

  List<MediaItem> _itemsOf(String provider, String sectionId) =>
      _sectionItems['$provider::$sectionId'] ?? const [];

  /// 补拉某个源里**还没有数据**的区块（切源时调用）
  ///
  /// 为什么不一次拉全部源的：那正是要避免的 ——
  /// 4 个源 × 8 区块 ≈ 30 次请求。按需拉，切到才拉。
  Future<void> _loadSectionsOf(String provider) async {
    final g = _groups.where((x) => x.provider == provider).firstOrNull;
    if (g == null) return;

    final pending = <Future<void>>[];
    for (final s in g.sections) {
      final key = '$provider::${s.id}';
      if ((_sectionItems[key]?.isEmpty) ?? true) {
        pending.add(_loadSection(provider, s.id, s.source));
      }
    }
    await Future.wait(pending);
  }

  /// 切源
  ///
  /// 同一页面内换源，**每个源各记各的滚动位置**
  ///（切走再切回来要回到原位置，不被别的源带跑）。
  void _switchSource(String id) {
    if (id == _currentSource) return;

    // 记下当前源的位置，切走之后能回来
    if (_scrollController.hasClients) {
      _railScroll[_currentSource] = _scrollController.offset;
    }

    setState(() => _currentSource = id);
    /*
     * ★ 落盘（2026-09-24 补齐「首页的选中源记录」）
     *
     * 原版是 `watch(homeSource)` 自动写；这里是显式调用 ——
     * Dart 没有响应式，只有一个入口（这个方法），显式更清楚。
     *
     * ⚠️ 必须放在 `setState` **之后** —— 顺序上"先改 UI 状态、
     *    再持久化"，这样即使写盘抛异常，界面也已经切过去了。
     */
    UiPrefs.setHomeSource(id);

    // 切源后补拉该源还没加载过的区块
    _loadSectionsOf(id);

    // 恢复目标源的位置（下一帧 —— 等列表换完）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _railScroll[id] ?? 0;
      _scrollController.jumpTo(
        target.clamp(0, _scrollController.position.maxScrollExtent),
      );
    });
  }

  /// `cctv:abc` → (provider, id)
  (String, String) _splitKey(String key) {
    final i = key.indexOf(':');
    if (i < 0) return ('', key);
    return (key.substring(0, i), key.substring(i + 1));
  }

  void _openDetail(MediaItem item) {
    final (provider, id) = _splitKey(item.id);
    widget.onOpenDetail?.call(provider, id);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _groups.where((g) => g.provider == _currentSource).toList();

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 从 `ListView` 改成 `CustomScrollView`（2026-09-24 用户要求 sticky）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 这个源切换,随着页面滚动也没有媳妇(吸附)在顶部
     *
     * # 为什么要换 widget（不能用 ListView 做到）
     *
     * ```text
     * ListView          → 所有子项都是**平级**的，没有一个能"钉住"
     * CustomScrollView  → 子项是 **sliver**，而
     *                     `SliverPersistentHeader(pinned: true)`
     *                     正是"滚到顶就钉住"的标准做法
     * ```
     * 原版是 CSS `position: sticky` —— `SliverPersistentHeader` 是
     * Flutter 里语义完全对应的东西。
     *
     * # 层级（与原版一致）
     *
     * ```text
     * CustomScrollView
     *  ├ SliverToBoxAdapter  错误条（可选）
     *  ├ SliverToBoxAdapter  「我的」
     *  ├ SliverPersistentHeader(pinned) ← ★ 源条吸附
     *  ├ SliverToBoxAdapter  骨架 / 空状态
     *  └ SliverList          内容分区
     * ```
     *
     * ⚠️ `padding` 的处理变了：`ListView(padding:)` 现在要拆开——
     *    顶部内边距放进第一个 sliver、底部放进最后一个。
     *    直接丢掉的话顶部会贴着标题栏、底部会被悬浮底栏盖住。
     */
    return RefreshIndicator(
      // 用户手动刷新 → force 全拉（原版的刷新语义）
      onRefresh: () => loadAll(force: true, reason: 'user-refresh'),
      /*
       * ★★★ 2026-10-03【内容带】补上原版 `.container` 那一层（**本页唯一缺的层**）
       *
       * # 原版长什么样（`src/design/base.css:549-554`）
       * ```text
       * .container { width:100%; max-width:var(--content-max-w); margin:0 auto;
       *              padding: 0 var(--sp-6) }
       * 窄档       { padding: 0 var(--sp-4) }
       * TV 档      { max-width:none; padding: max(var(--sp-6), var(--tv-safe-x)) }  --tv-safe-x = 5vw
       * ```
       * 原版 7 个视图的根**都是** `div.container`（`HomeView.vue:348` 等）⇒ 首页本来就有这层。
       *
       * # 为什么必须用**外层 `Padding`**（不是 `Center` / `ConstrainedBox`）
       * 见 `lib/ui/tokens.dart:364-380`：`Center` 给子件的是 **loose** 约束，
       * `RenderViewport.sizedByParent == true` 取 `constraints.biggest` ⇒ 视口仍是整窗宽 ⇒ 空操作。
       * `Padding` 先把 maxWidth 减掉 2*side 再传下去 ⇒ 视口真的变窄。
       * 而 `CustomScrollView` **没有** `padding:` 参数（SDK `scroll_view.dart:722-747` 只有 `slivers:`）
       * ⇒ 只能用外层 `Padding`（browse/search 两页同形，见 `browse_page.dart:445`）。
       *
       * # 判据（真浏览器权威读数，`.probe/_m4_readings.txt`）
       * ```text
       * TV 逻辑 960 : 容器 padL = max(24, 960×5%) = 48  ⇒ 分区卡左沿 48+24 = 72  dp = 144 px
       * 桌面 1904   : 容器 padL = 24，居中 (1904−1440)/2 = 232 ⇒ 分区卡左沿 280
       * 窄档 500    : 容器 padL = 16 ⇒ 分区卡左沿 32
       * ```
       *
       * ★ 上表是**原版**读数。★ 2026-10-04 起我们不再封顶 1440
       *   ⇒ 桌面 1904 的居中偏移 232 变成 **0**，分区卡左沿 = 24+24 = **48**
       *   （TV / 窄档两档本来就没有居中那一步，读数不变）。
       *
       * ⚠️ 本页此前**只有** 24 dp 那**一层**（子件各自写死 `AppMetrics.contentPadding` 扮演
       *    `.container`）⇒ TV 实测内容左边界只有 **48 px**，而搜索页是 96 px
       *    （`.probe/layout-dev/g-00-boot.png` vs `tv1-d-results.png`，同设备同会话）。
       *    ⇒ 首页当时是**侵入了 TV 5vw 安全区**的，本次一并消掉这个不一致。
       *
       * ⚠️ `sideInsetForWindow` 在 TV 档返回 0（`tokens.dart:357-362`），这是**对的**：
       *    原版 TV 的 `max-width: none` ⇒ 没有居中那一步，只有 5vw 内边距。
       *    所以 TV 的容器层 = `0 + max(24, 5%×band)`，逐位等于 `max(var(--sp-6), --tv-safe-x)`。
       */
      child: Padding(
        padding: Layout.horizontalInsetOf(context),
        child: CustomScrollView(
        clipBehavior: Clip.antiAlias,
        controller: _scrollController,
        slivers: [
          // ── 顶部内边距（原来是 ListView.padding.top）──
          const SliverToBoxAdapter(
            child: SizedBox(height: AppMetrics.homeTopPadding),
          ),

          // ── 错误条 ──
          if (_error != null)
            /*
             * ★ 内容带：这里**不再**自己给横向内边距。
             *
             * 原版 `HomeView.vue:375` 的 `div.alert` 是 `div.container`（`:348`）的
             * **直接子元素** ⇒ 它的左沿就是容器的 24 px。
             * Flutter 侧那一层现在由页根的 `Layout.horizontalInsetOf` 提供
             * ⇒ 这里再给一次就是 ×2（桌面 48 / TV 96 dp，规格是 24 / 48）。
             *
             * ⚠️ `_ErrorBar` **自己**的 `padding: EdgeInsets.symmetric(horizontal: Sp.x4)
             *    不能动 —— 那是原版 `.alert { padding: var(--sp-3) var(--sp-4) }
             *    （`HomeView.vue:531`）里的卡片内边距，与容器内边距是两回事。
             */
            SliverToBoxAdapter(child: _ErrorBar(message: _error!)),

          /*
           * ★★★ 「我的」三合一版块（收藏 / 追更 / 历史）
           *
           * 原版注释解释了为什么合成一个版块：
           * > 这三者都是「用户自己的数据」（独立平面），且**高度重叠**
           * > —— 同一部番可能同时出现在收藏和历史里。分成三个横排
           * > 区块会让首页变成一长条重复内容，故用 **tabs 切换**。
           *
           * ⚠️ 放在 SourceBar **之前**（原版也是这个顺序）——
           *    原版注释：
           *    > 它管的是**下面的内容区显示哪个源**，
           *    > 所以「我的」在前、源切换条在后。
           */
          SliverToBoxAdapter(
            child: MyShelf(
              key: _shelfKey,
              isTv: widget.isTv,
              onPlay: widget.onShelfPlay,
              onOpenDetail: widget.onOpenDetail,
              // ★ task-65：「查看更多」→ 交给 shell 切 tab
              onSeeAll: widget.onSeeAllShelf,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: Sp.x6)),

          // ── ★ 多源切换条（吸附在顶部）──
          SliverPersistentHeader(
            /*
             * `pinned: true` 才是"吸附"
             *
             * ```text
             * pinned: true   → 滚上去之后**钉在顶部**，一直可见   ✓ 我们要的
             * pinned: false  → 滚上去就跟着滚走（floating 也只管收缩）
             * ```
             */
            pinned: true,
            delegate: _StickySourceBar(
              // ⚠️ 必须传**同一个 GlobalKey** 给 SourceBar
              //    （见 `_sourceBarKey` 的说明：不用 key 的话
              //     delegate 每次重建都会**丢 ScrollController 状态**）
              child: SourceBar(
                key: sourceBarKey,
                sources: _enabled,
                current: _currentSource,
                onSelect: _switchSource,
              ),
            ),
          ),

          /*
           * ══════════════════════════════════════════════════════════
           * ★★★ 骨架 → 内容：淡入过渡（task-44 B 项，2026-09-26）
           * ══════════════════════════════════════════════════════════
           *
           * 用户原话：
           * > 6.动画效果加一下,多个动画效果
           *
           * # 改之前是什么
           * ```text
           * if (_loading)   SliverToBoxAdapter(child: _SkeletonSections())
           * if (!_loading)  SliverList(...)
           * ⇒ ★ **硬 if 切换**：骨架瞬间消失、内容瞬间出现
           *   ⇒ 视觉上"闪一下"，用户分不清"内容加载好了"还是"画面抖了"
           * ```
           *
           * # 现在
           * ```text
           * 内容侧（SliverList / 空态）包一层 `FadeInSliver`
           *   ⇒ 首帧 opacity 0 → 200ms 内升到 1（**淡入**）
           * ★ 骨架侧**不动**（它被移除时本来就不可见，无需淡出——
           *   因为它的位置被内容接管，视觉上就是"内容盖上来"）
           * ```
           *
           * # ⚠️ 为什么 `FadeInSliver` 用 `SliverFadeTransition` 而不是 `Opacity`
           * ```text
           * `Opacity` 是**盒模型** ⇒ 要放进 `slivers:` 必须再套
           * `SliverToBoxAdapter` ⇒ ★ 那会把整个 `SliverList` 变成一个盒模型孩子
           * ⇒ **丢掉懒加载与 sticky**（性能回归）。
           * ⇒ `SliverFadeTransition` 的 child 就是 **sliver**
           *   ⇒ 淡入的同时**完全保留** `SliverList` 的懒加载 ✓
           * ```
           *
           * # 判据（Lead 的五条）
           * ```text
           * ① 有目的    → 引导注意（告诉用户"内容就绪了"）
           * ② 不拖慢    → 200ms ≤ 300ms；且加载本就是等待态
           * ③ 可打断    → 隐式补间不劫持手势
           * ④ Reduce Motion → 走 `MotionPrefs.duration`（开了 ⇒ 0ms 直接到位）
           * ⑤ 惯用法    → `TweenAnimationBuilder` + `SliverFadeTransition`
           * ```
           */

          // ── 骨架屏 ──
          if (_loading)
            const SliverToBoxAdapter(child: _SkeletonSections()),

          // ── 空状态（★ 淡入）──
          if (!_loading && visible.isEmpty)
            const FadeInSliver(
              sliver: SliverToBoxAdapter(
                child: _EmptyState(
                  icon: Icons.movie_outlined,
                  title: '还没有可用的内容源',
                  desc: '在设置里启用或导入一个内容源即可开始',
                ),
              ),
            ),

          // ── 内容分区（只渲染当前源；★ 淡入）──
          if (!_loading)
            FadeInSliver(
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  for (final g in visible)
                    for (final s in g.sections)
                      _SectionBlock(
                        provider: g.provider,
                        section: s,
                        items: _itemsOf(g.provider, s.id),
                        onOpenDetail: _openDetail,
                        onOpenLive: widget.onOpenLive,
                        onBrowse: widget.onBrowse,
                      ),
                ]),
              ),
            ),

          // ── 底部内边距（原来是 ListView.padding.bottom）──
          // ★ 页面级留白只在这里放一次（Sp.bottomBarInset = 90dp，给悬浮底栏让位）；
          //   分区自己的间距走 _SectionBlock 里的 Sp.x8。
          // ⚠️ 这里**不能**加 `const`：`Sp.bottomBarInset` 是 getter
          //   （`tokens.dart:73 static double get bottomBarInset => Device.isTv ? 110 : 90;`），
          //   带 getter 就不是常量表达式 ⇒ `flutter build` 的 kernel_snapshot 阶段直接报
          //   "The invocation of 'bottomBarInset' is not allowed in a constant expression"。
          //   （同类警告见 search_page.dart:632 / live_page.dart:1588 / settings_page.dart:3203）
          SliverToBoxAdapter(child: SizedBox(height: Sp.bottomBarInset)),
        ],
      ),
      ),   // ← 内容带那层 Padding 的收口（见上面那段长注释）
    );
  }
}

/// 源条的 GlobalKey —— 让 `SliverPersistentHeader` 重建时**保住 State**
///
/// # 为什么必须有（2026-09-24 踩到的坑）
///
/// `SliverPersistentHeaderDelegate.build()` 会在滚动时被**反复调用**。
/// 每次调用都 `new SourceBar(...)` —— 如果**没有 key**：
/// ```text
/// Flutter 比对 widget 树 → runtimeType 相同 → 复用 Element
/// ```
/// 通常能保住 State，但 `SliverPersistentHeader` 在 pinned 状态切换时
/// 会**重建整棵子树**，State 丢失后：
/// ```text
/// · ScrollController 重新创建 → 滚动位置归零
/// · 用户滚到第 10 个源，一滚动全跳回第 1 个
/// ```
/// 显式给 GlobalKey 让 Flutter **跨位置**保持同一个 Element，
/// 这是唯一可靠的保证。
final sourceBarKey = GlobalKey();

/// 「吸附在顶部」的源条 sliver
class _StickySourceBar extends SliverPersistentHeaderDelegate {
  _StickySourceBar({required this.child});

  final Widget child;

  /// 源条自身高度 44 + 上下各 8 的呼吸空间
  ///
  /// # 为什么留 8px（而不是贴死在顶部）
  ///
  /// 原版注释：
  /// > `top: var(--sp-3)` 而不是 0 —— 否则滚动时切换条会**贴死在窗口顶部**
  ///
  /// ⚠️ `minExtent` 必须**等于** `maxExtent`：
  ///    不等的话源条会随滚动**伸缩**（`SliverPersistentHeader` 的
  ///    默认行为是把手势位移映射成 extent 变化）——
  ///    那是给"可折叠大标题"用的，我们不想要。
  static const double _extent = 44 + 8 + 8;

  @override
  double get minExtent => _extent;

  @override
  double get maxExtent => _extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    /*
     * ⚠️ 用 `Padding` 包一层（而不是让子项自己撑）——
     *    `SliverPersistentHeader` 给的是**紧约束**（高度 == extent），
     *    子项如果直接是 44px 的 Center 会溢出。
     */
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: child,
    );
  }

  @override
  bool shouldRebuild(_StickySourceBar old) => old.child != child;
}

// ═══════════════════════════════════════════════════════════════════════
//  区块
// ═══════════════════════════════════════════════════════════════════════

class _SectionBlock extends StatelessWidget {
  const _SectionBlock({
    required this.provider,
    required this.section,
    required this.items,
    required this.onOpenDetail,
    this.onOpenLive,
    this.onBrowse,
  });

  final String provider;
  final Section section;
  final List<MediaItem> items;
  final void Function(MediaItem) onOpenDetail;
  final void Function(String channelId, String name)? onOpenLive;
  final void Function(String provider, String sectionTitle, SectionSource src)?
      onBrowse;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final src = section.source;

    /*
     * ★ 内容带（t508）：本块自带的「第二层」横向内边距
     *
     * 原版 `.section__head` 自己就带 `padding: 0 var(--sp-6)`
     *   （`src\design\base.css:867-874`，窄档 `:877` 换成 `var(--sp-4)`）——
     * 它是 `.container` 的**子元素**，所以视觉上是 ×2：
     *   容器内边距(24) + 轨道内边距(24) = **48**。
     * ⇒ 页面根那层带（`horizontalInsetOf`）落地后，这里**保留** 24，
     *   正好还原原版的 ×2；若也归零就只剩 24（少一层）。
     *
     * ⚠️ 与 `_Rail` 的 `padding` 必须**同源同值**：两处都调
     *    `Layout.railPaddingOf(context)`，任何一处漏改都会让
     *    标题行与卡片左边缘错位（原版这两者对齐）。
     *
     * ★★ t510 修正：原来调的是 `Layout.contentPaddingOf`（= `paddingFor`），
     *   它在 TV 上会走 `tvPaddingFor` = `max(24, 5vw)` ⇒ TV@960 得 **48**，
     *   于是 48(容器) + 48(轨道) = **96dp = 192px**（模拟器实测就是这个数，
     *   目标 144px）。原版轨道那层在 TV 上**恒为 24** —— m4 读数
     *   `secHeadPadL=24px` / `secRailPadL=24px`（四档全是 24）
     *   ⇒ 换成 `railPaddingOf`（窄档 16 / 其余 24）。
     */
    final railInset = Layout.railPaddingOf(context);

    return Padding(
      // 段间距走原版 .section + .section { margin-top: var(--sp-8) }（= 32px）。
      // ⚠️ 这里不是放 Sp.bottomBarInset 的地方 —— 那是页面级底部留白
      //（给悬浮底栏让位，见 tokens.dart:53-73），放在每个分区上会累加：
      // 8 个分区 × 90dp ≈ 720dp 死白，真机实测段间距 89.9dp。
      //（Sp.x8 是 `static const double x8 = 32` ⇒ 这里可以加 const；
      //  别和上面那个 getter 的坑搞混）
      padding: const EdgeInsets.only(bottom: Sp.x8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 标题行 + 「查看全部」──
          Padding(
            padding: EdgeInsets.symmetric(horizontal: railInset),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    section.title,
                    style: TextStyle(
                      fontSize: FontSizes.lg,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                  ),
                ),
                /*
                 * 「查看全部」的三种去向（与原版一一对应）：
                 * ```text
                 * category → 浏览页（带分类参数）
                 * rank     → 浏览页（带榜单参数，复用同一页面）
                 * custom   → 直播页
                 * ```
                 */
                if (src.isCategory || src.isRank)
                  _MoreButton(
                    label: '查看全部',
                    onTap: () => onBrowse?.call(provider, section.title, src),
                  )
                else if (src.type == 'custom')
                  _MoreButton(
                    label: '去直播',
                    onTap: () => onBrowse?.call(provider, section.title, src),
                  ),
              ],
            ),
          ),
          const SizedBox(height: Sp.x4),

          // ── 直播区块：横向频道条 ──
          if (src.type == 'custom')
            _LiveStrip(onOpenLive: onOpenLive)

          // ── 榜单区块：带序号的紧凑卡片 ──
          /*
           * ★ 为什么榜单用「带序号」而不是普通海报轨道
           *
           * 原版注释：
           * > 主流站点（Netflix Top 10 / B站排行榜 / 腾讯热榜）都用大序号，
           * > 因为「排行」本身就是核心信息 —— 用海报轨道会把这个信息丢掉。
           * > 仍然可横向滚动，信息与操作与原来完全一致。
           */
          else if (src.isRank && items.isNotEmpty)
            _Rail(
              items: items,
              ranked: true,
              onOpenDetail: onOpenDetail,
            )

          // ── 普通区块：海报轨道 ──
          else
            _Rail(
              items: items,
              ranked: false,
              onOpenDetail: onOpenDetail,
            ),
        ],
      ),
    );
  }
}

/// 横向海报轨道
class _Rail extends StatelessWidget {
  const _Rail({
    required this.items,
    required this.ranked,
    required this.onOpenDetail,
  });

  final List<MediaItem> items;
  final bool ranked;
  final void Function(MediaItem) onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    if (items.isEmpty) {
      /*
       * 原版：`暂无内容` 的占位（而不是留空白，那看起来像加载失败）
       *
       * ★ 内容带（t508）：`.rail-empty` 是 `.section__rail` 的**子元素**
       *   （`src\views\HomeView.vue:515-517`）⇒ 它前面已经吃了轨道那层
       *   `--sp-6` ⇒ 这里仍是 ×2，与下面的 `padding` 同值。
       *   `.section__rail` 自己的 `padding: 0 var(--sp-6) var(--sp-2)`
       *   见 `src\design\base.css:906-915`。
       */
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: Layout.railPaddingOf(context),
        ),
        child: Text(
          '暂无内容',
          style: TextStyle(
            fontSize: FontSizes.sm,
            color: colors.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      );
    }

    return SizedBox(
      // ★ 标题两行（原版 base.css:844-854 -webkit-line-clamp:2）
      height: AppMetrics.railHeight(titleLines: 2),
      child: ListView.separated(
        clipBehavior: Clip.antiAlias,
        scrollDirection: Axis.horizontal,
        // ★ 内容带（t508）：轨道那层 —— 原版 `.section__rail` 的
        //   `padding: 0 var(--sp-6) var(--sp-2)`（`base.css:906-915`，
        //   窄档 `:918` 换成 `var(--sp-4)`）。
        //   页面根那层带落地后，这里保留 ⇒ 视觉 ×2（与原版一致）。
        padding: EdgeInsets.symmetric(
          horizontal: Layout.railPaddingOf(context),
        ),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: Sp.x3),
        itemBuilder: (context, i) {
          final it = items[i];
          /*
           * ══════════════════════════════════════════════════════════
           * ★★ 按下反馈（task-44 A 项，2026-09-26）
           * ══════════════════════════════════════════════════════════
           *
           * 用户原话：
           * > 6.动画效果加一下,多个动画效果
           *
           * # 为什么在这里包（而不是改 `PosterCard` 内部）
           * ```text
           * `lib/ui/widgets/poster_card.dart` 归 `fix-source-cards`（它在改占位色）
           * ★ 而本文件的调用点**是我的**（home_page.dart）
           * ⇒ 在这里包一层 ⇒ **零冲突**，且效果完全一样
           *   （按下反馈是"卡片外面"的事，不属于卡片自身）
           * ```
           *
           * # 为什么用 `PressFeedback` 而不是 `InkWell` 的水波纹
           * ```text
           * `PosterCard` 内部已有 `onTap`（点击行为**不动**）。
           * `PressFeedback` 用 `Listener`（**不消费手势**）
           *   ⇒ 缩放只是**视觉叠加**，点击行为**一个字节都没改** ✓
           * ```
           *
           * 判据映射：① 反馈操作 ② 90/150ms（最高频 ⇒ 最低档）
           *          ③ 可打断 ④ 走 `MotionPrefs` ⑤ `AnimatedScale`（惯用法）
           */
          final card = PressFeedback(
            child: PosterCard(
              title: it.title,
              cover: it.cover,
              subtitle: it.note,
              titleLines: 2,
              onTap: () => onOpenDetail(it),
            ),
          );

          if (!ranked) return card;

          // 榜单：序号 + 卡片
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 30,
                child: Padding(
                  padding: const EdgeInsets.only(top: Sp.x4),
                  child: Text(
                    '${i + 1}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: FontSizes.xl,
                      fontWeight: FontWeights.semibold,
                      // 前三名用主色强调（原版 `is-top` 的语义）
                      color: i < 3
                          ? colors.primary
                          : colors.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
              card,
            ],
          );
        },
      ),
    );
  }
}

/// 直播频道条
class _LiveStrip extends StatelessWidget {
  const _LiveStrip({this.onOpenLive});

  final void Function(String channelId, String name)? onOpenLive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SizedBox(
      height: 44,
      child: ListView.separated(
        clipBehavior: Clip.antiAlias,
        scrollDirection: Axis.horizontal,
        /*
         * ★ 内容带：**零**横向内边距（原来是 24）。
         *
         * 原版 `.live-strip { display:flex; gap:var(--sp-2); padding-bottom:var(--sp-2) }
         * （`HomeView.vue:680-684`）**没有**横向 padding，而且它（`:466`）是
         * `.section__head`（`:426`）的**兄弟**、直接挂在 `.section` 里
         * ⇒ 左沿 = `.container` 那一层，**没有**第二层。
         * ⇒ 现在由页根的 `Layout.horizontalInsetOf` 给。
         *
         * ⚠️ 与 `.section__rail` 的区别正在这里：轨道自己也带 `--sp-6`
         *    （`base.css:906-915`）⇒ 轨道是 ×2，直播条是 ×1。
         */
        padding: EdgeInsets.zero,
        itemCount: kLivePreview.length,
        separatorBuilder: (_, __) => const SizedBox(width: Sp.x2),
        itemBuilder: (context, i) {
          final ch = kLivePreview[i];
          return Center(
            child: InkWell(
              onTap: () => onOpenLive?.call(ch.id, ch.name),
              borderRadius: Radii.rFull,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Sp.x4,
                  vertical: Sp.x2,
                ),
                decoration: BoxDecoration(
                  borderRadius: Radii.rFull,
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 「正在播」的圆点
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: AppColors.liveDot,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: Sp.x2),
                    Text(
                      ch.name,
                      style: TextStyle(
                        fontSize: FontSizes.sm,
                        color: colors.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 「查看全部」按钮
class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x2),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: colors.onSurfaceVariant,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: FontSizes.sm)),
          const Icon(Icons.chevron_right, size: 15),
        ],
      ),
    );
  }
}

/// 错误条
class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Sp.x6),
      padding: const EdgeInsets.symmetric(
        horizontal: Sp.x4,
        vertical: Sp.x3,
      ),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: 0.35),
        borderRadius: Radii.rLg,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 17, color: colors.error),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: FontSizes.sm, color: colors.error),
            ),
          ),
        ],
      ),
    );
  }
}

/// 骨架屏
class _SkeletonSections extends StatelessWidget {
  const _SkeletonSections();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            // 与 _SectionBlock 一致：段间距 Sp.x8（页面级 bottomBarInset 只在页尾）
            padding: const EdgeInsets.only(bottom: Sp.x8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                /*
                 * ★ 内容带：骨架标题**不再**自己给横向内边距。
                 *
                 * 原版 `.skeleton-sections` / `.skeleton-section`
                 * （`HomeView.vue:559-560`）都没有横向 padding —— 它们直接挂在
                 * `.container` 里，横向内边距只有容器那一层。
                 * ⇒ 现在由页根的 `Layout.horizontalInsetOf` 给。
                 */
                const _Shimmer(width: 130, height: 20),
                const SizedBox(height: Sp.x4),
                SizedBox(
                  // 与 _SectionBlock 的轨道逐值相同（否则骨架→内容跳高）
                  height: AppMetrics.railHeight(titleLines: 2),
                  child: ListView.separated(
                    clipBehavior: Clip.antiAlias,
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    // ★ 内容带：骨架轨道也是 ×1（原版 `.skeleton-rail` 无横向 padding，
                    //   `HomeView.vue:561-566`）⇒ 横向由页根那层给，这里归零。
                    padding: EdgeInsets.zero,
                    itemCount: 6,
                    separatorBuilder: (_, __) => const SizedBox(width: Sp.x3),
                    itemBuilder: (_, __) => const _Shimmer(
                      width: AppMetrics.posterWidth,
                      height: double.infinity,
                      radius: Radii.md,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 骨架块（带呼吸动画）
class _Shimmer extends StatefulWidget {
  const _Shimmer({
    required this.width,
    required this.height,
    this.radius = Radii.sm,
  });

  final double width;
  final double height;
  final double radius;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: colors.onSurface.withValues(
            alpha: 0.04 + 0.04 * _c.value,
          ),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

/// 空状态
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
    // ★ 内容带（t508）：整页空态在原版里也是 `.container` 的子节点、
    //   自身不带横向内边距 ⇒ 只该有页面根那**一层** 24。
    //   ⚠️ 这里原来是 24，页面根加带后会变成 ×2 ⇒ 归零。
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: Sp.x16,
      ),
      child: Column(
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
    );
  }
}
