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

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:material_ui/material_ui.dart';

import '../core/sourin_api.dart';
import '../core/ui_prefs.dart';
import 'live_availability.dart';
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

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ task-11：首页列表的**进程级内存缓存**（切源不重拉 = stale-while-revalidate）
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话（逐字）：
// > 这些封面啊,什么的信息能不能也做一下缓存?不然太耗费流量和使用感觉,
// > 每次都重载
// > 我在首页每次切换源的时候都要重载,我想如果有缓存就好了
//
// # ★ 先把「封面」与「列表」分开 —— 这两个的现状**完全不同**
//
// ```text
// 封面 → ★ 本来就有缓存，而且是**字节级**的：
//          · Flutter 侧 ImageCache（同一个 URL 不会解码两次）
//          · 核心侧 URL→token 复用（同一 URL 复用同一 token，浏览器缓存才生效）
//          ⇒ 这一半用户的直觉（"不是有缓存吗"）是对的：再给封面加一层
//            （precache / 调大 maximumSizeBytes）**买不到任何东西** ——
//            字节本来就在，问题不在字节。
// 列表 → ✗ **零缓存**：切一次源 = 1 次 get_home + 每个区块 1 次 get_list
//          ⇒ 骨架/占位停留数秒 = 用户说的"重载"
// ```
// ⇒ 所以本任务做的是**列表数据**缓存，不是图片缓存。
//
// # 真机读数（隔离数据目录 + 真核心 + 真网络，task-6 探针产物）
//
// ```text
// 源: cctv（已启用 3 个；首页可用 1 个 —— 纯直播源被 homeSourceList 排除）
// 实测 getHome 耗时: 1597ms / 803ms（同一台机器两次读数）
// 待加载区块 9 个（当前源=cctv）        ← 9 次 get_list
// 渲染完成: 分区=9 卡片=160
// ```
// ⇒ 冷切一次源 ≈ 1 次 get_home（0.8~1.6s）+ 9 次 get_list（网络往返）。
//   切走再切回来**每次都重来**，这就是"太耗费流量 + 每次都重载"的成因。
//
// # 设计（三条，先定判据再写代码）
//
// ```text
// ① 键 = provider id（首页没有 tab 这一层 —— 「我的」那三个 tab 走 MyShelf
//    自己的刷新路径，与本缓存无关，别混为一谈）
// ② 命中 ⇒ 数据**进这次 setState**，第一帧就有卡片（不经过骨架屏），
//    紧接着后台 loadAll(force: true) 去对新的 ⇒ 先看旧的、新的自己追上来
// ③ 上限 = LRU 12 个源 + TTL 10 分钟 + 骨架指纹不符即作废
// ```
//
// # ★ 为什么不放在 HomePageState 的字段里
//
// 放字段里 = "本页实例"的缓存，而"切走再回来"有可能换实例
// （本项目踩过：内容区曾用换 key 触发重挂载 ⇒ 整个 State 重建）。
// 放**文件级 final** ⇒ 进程活多久它活多久。
// ⚠️ 代价是必须自己管上限 —— 所以 LRU + TTL 是**硬约束**，不是优化项。

/// 首页列表缓存的**条目上限**（LRU 淘汰用；硬约束，见上面 ③）
///
/// ```text
/// 一个条目 ≈ 该源的 _groups（分区骨架，很小）
///          + 各区块 items 的**引用**（列表对象共享，不做深拷贝）
/// 实测 cctv 源 9 个区块 / 160 张卡 ⇒ 一个条目 ≈ 160 个引用
/// 12 个条目 ≈ 2000 个引用 ⇒ 与"一屏 160 张卡"同一个量级，不会失控
/// ```
/// ★ 定成 12 而不是"无限"：用户可能装几十个源，来回切不能让内存线性涨。
const int kHomeCacheMaxEntries = 12;

/// 快照的**存活时长**：超过就不当"可用缓存"（宁可直接冷加载一次）
///
/// ★ 为什么有后台刷新还要有 TTL（两者不是一回事）
/// ```text
/// 后台刷新 → 保证"命中之后内容会变新"（stale-while-revalidate 的 revalidate）
/// TTL      → 保证"命中之前不会拿**很久以前**的数据当秒开"
///            （应用在后台搁了几小时、期间一次都没刷新 ⇒ 宁可直接冷加载）
/// ```
const Duration kHomeCacheTtl = Duration(minutes: 10);

/// 「新鲜窗口」：快照存下来不到这么久 ⇒ **连后台刷新都不用发**
///
/// ★ 为什么需要（不加它，用户点一下底栏就会立刻重发一轮请求）
/// ```text
/// 回首页 → shell 的 _switchTo(home) → loadAll(force: false)
///   ⇒ 那一步的语义是「内容可能变了，去对一下」
///   ⇒ 但用户刚在 2 秒前看过这个源、缓存就是那一刻存的
///     ⇒ 立刻重新发一轮 get_list = 纯浪费（也正是用户抱怨的"每次都重拉"）
/// ```
/// # 与 TTL 的区别（两个阈值，管的不是同一件事）
/// ```text
/// freshFor(30s) → 命中之后**要不要去后台对新的**（revalidate 的节流）
/// ttl(10min)    → 命中**之前**这份快照还算不算数（stale 的上限）
/// ```
/// ⚠️ 有意的代价：这 30 秒内**不会**发现源那边新上的内容。
///    用户手动下拉刷新永远是 `force: true` ⇒ **不受本窗口影响**。
const Duration kHomeCacheFreshFor = Duration(seconds: 30);
/// 一个源的首页列表快照（分区骨架 + 各区块 items）
///
/// ⚠️ `groups` / `items` 里存的是**引用**，靠的是"只整体替换、从不原地改"
///    （`loadAll` 里 `if (changed) { _groups = next; }`）、
///    存下来的不会被后续刷新改脏 —— 所以不需要深拷贝。
class HomeSnapshot {
  HomeSnapshot({
    required this.fingerprint,
    required this.groups,
    required Map<String, List<MediaItem>> items,
    required this.at,
  }) : items = Map<String, List<MediaItem>>.unmodifiable(items);

  /// 分区骨架指纹（就是 `_fingerprint`）—— 骨架变了，这份快照就不作数了
  final String fingerprint;

  /// 该源的分区列表（只含**这个源**的 ProviderGroup）
  final List<ProviderGroup> groups;

  /// `provider::sectionId` → items（含"已知为空"的键，见 `_switchSource` 的说明）
  final Map<String, List<MediaItem>> items;

  /// 存入时刻（TTL 判据）
  final DateTime at;

  /// 卡片总数（探针读数用：证明"秒开的第一帧"里真的有内容）
  int get cardCount {
    var n = 0;
    for (final l in items.values) {
      n += l.length;
    }
    return n;
  }
}

/// 首页列表的**进程级**缓存（LRU + TTL）
///
/// # 为什么不能只用一个 Map + "看着差不多就清"
///
/// ```text
/// 只清"太大"的表  → 用户装 30 个源来回切 ⇒ 30 份列表常驻（线性涨，无上限）✗
/// LRU（本实现）    → 最近用过的 12 个留下，最久的**真的被删掉**        ✓
/// ```
/// ★ "真的被删掉"是硬约束（任务书第 4 条）：
///   `_entries.remove(oldest)` 之后没有别处再持有它 ⇒ 真的可回收。
///   （只"标记不命中"却留着对象 = 内存照涨，等于没做上限。）
class HomeListCache {
  HomeListCache({
    this.maxEntries = kHomeCacheMaxEntries,
    this.ttl = kHomeCacheTtl,
  });

  final int maxEntries;
  final Duration ttl;

  /// ★ 用 `Map` 的**插入序**当 LRU 序：命中时先 remove 再写回 = 挪到末尾。
  ///   不引第三方 LRU 实现（本仓不许加依赖）。
  final Map<String, HomeSnapshot> _entries = <String, HomeSnapshot>{};

  /// ★★ 探针开关：置 false 后本缓存**完全不起作用**（take 恒 null、put 空操作）
  ///
  /// # 为什么必须留这个开关（第一版探针缺了它，得出了一个**站不住的结论**）
  /// ```text
  /// 我原本用一个"阳性对照"来证明判据有效：把缓存 clear() 掉再切回 A，
  /// 期望"第一帧没有卡片"。实测**有 4 张卡片、0 次请求** ⇒ 对照失败。
  /// 原因不在缓存，而在页面**本来就保留着** `_sectionItems`
  ///   （它从不被清空，`build()` 又按 `_currentSource` 过滤）
  ///   ⇒ 切回已看过的源，**改之前也是秒出**。
  /// ⇒ 要量"我的改动到底带来了什么"，必须能真的**退回改之前的行为**，
  ///   而 clear() 做不到这件事（clear 只清缓存，清不掉 `_sectionItems`）。
  /// ```
  bool enabled = true;

  // ── 探针读数（判据必须与判据对象**同源**：要测"命中没有"，就记命中本身）──
  //
  // ★★ 为什么**不**用 `if (kDebugMode)` 门控（第一版就是这么写的，真机读数全 0）
  // ```text
  // 真机探针是 `flutter build windows --release` 构建的 ⇒ kDebugMode=false
  //   ⇒ 计数器一次都不自增 ⇒ hits=0 misses=0 puts=0（而缓存其实工作得好好的）
  //   ⇒ 那几条"仪器同源"的断言全部假红，看起来像缓存没生效。
  // ```
  // 代价：4 个 int 自增。与"切源要不要重发 9 次 get_list"相比可以忽略 ——
  // 而这几个数**是**证明本任务生效的唯一同源证据（见 t11 探针产物）。
  int hits = 0;
  int misses = 0;
  int puts = 0;
  int evictions = 0;

  /// 当前驻留条目数（探针用它证明"上限真的生效"）
  int get length => _entries.length;

  /// 取快照：**未过期** 且 **指纹一致** 才算命中（命中会做 LRU 提升）
  ///
  /// ⚠️ 不命中时**顺手删掉**这一条（过期/作废的数据不占名额、不占内存）。
  HomeSnapshot? take(
    String provider, {
    required String fingerprint,
    required DateTime now,
  }) {
    if (!enabled) {
      misses++;
      return null;
    }
    final s = _entries.remove(provider);
    if (s == null) {
      misses++;
      return null;
    }
    if (now.difference(s.at) > ttl || s.fingerprint != fingerprint) {
      misses++;
      return null;
    }
    _entries[provider] = s; // 挪到末尾 = 最近使用
    hits++;
    return s;
  }

  void put(String provider, HomeSnapshot s) {
    if (provider.isEmpty || !enabled) return;
    _entries.remove(provider);
    _entries[provider] = s;
    puts++;
    while (_entries.length > maxEntries) {
      final oldest = _entries.keys.first; // 插入序最前 = 最久未用
      _entries.remove(oldest);
      evictions++;
    }
  }

  /// 彻底清空（测试启动前调用）
  void clear() {
    _entries.clear();
  }
}

/// ★★ task-11 的缓存实例 —— **产品走的就是这一个**
///
/// # 为什么把产品实例直接当探针（而不是另建一个计数器）
///
/// 本项目踩过两次"仪器与被测对象不是同一个东西"（见 `debugLoadAllCalls`
/// 记的两条教训）。这里反过来：产品调的就是 `homeListCache`，
/// 测试读它的 `hits / misses / puts / evictions / length` ——
/// **判据与被测属性同源**。
///
/// ⚠️ 计数器只在 debug 自增；release 下缓存照常工作，只是不计数。
final HomeListCache homeListCache = HomeListCache();

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

/// ★★ task-6 探针：首页直播条的**过闸读数**（闸前候选 N / 闸后渲染 M）
///
/// # 为什么要成对记两个数
///
/// 判据是这一对**同源**读数：
/// ```text
/// N = 直播条本来会画几个 chip（= `kLivePreview` 的长度，8）
/// M = 过完可用性闸之后**真正画出来**的 chip 数
/// ```
/// ★ 只报 M 没有意义：M=0 既可能是"闸生效了"，也可能是"直播条压根没渲染"
///   （当前源不是 cctv / 页面还在骨架态）—— 两个原因读数**相同**。
/// ⇒ 必须成对记录，且由**渲染路径自己**写（同 `debugLoadAllCalls` 的教训：
///   要测"画了几个"，就直接记渲染时那个数，不要记它的副作用）。
///
/// ⚠️ 只在 debug 下写入（`kDebugMode`），release 构建零开销。
final List<({int candidates, int rendered})> debugHomeLiveStrip =
    <({int candidates, int rendered})>[];

/// 最近一次直播条渲染读数（`null` = 本次会话还没渲染过直播条）
({int candidates, int rendered})? get debugHomeLiveStripLast =>
    debugHomeLiveStrip.isEmpty ? null : debugHomeLiveStrip.last;

/// 探针可读的**闸前候选名单**（`provider::channelId`）
///
/// ★ 有它才能回答"这 8 个候选里**具体哪几个**被闸掉了" ——
///   只看 `rendered=0` 无法区分"全被闸掉"和"渲染路径根本没跑到"。
final List<String> debugHomeLiveStripCandidates = <String>[];

/// 探针可读的**过闸后名单**（同上，两者都为空 = 直播条没渲染）
final List<String> debugHomeLiveStripPassed = <String>[];

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
  ///
  /// ⚠️ ★ task-6：第一个参数是**频道所属的源**（旧签名只有 channelId/name）。
  ///
  /// # 错在哪
  ///
  /// 旧签名不带源 ⇒ 接收方（`shell.dart:4913 _openLiveChannel`）只能把
  /// `provider` **写死成 'cctv'`**（`shell.dart:4923`）。
  /// 于是"从哪个源看到的频道"这个信息**在回调边界上被丢掉了**，
  /// 播放器永远去 cctv 取流 —— 换成别的源必然取不到流（黑屏/报错）。
  ///
  /// # 为什么这么改
  ///
  /// 源不是"猜"出来的：直播条里的每个频道都是**按 (provider, channelId)
  /// 探出来的**（见 `HomePageState._probeLiveStrip`），
  /// ⇒ 让同一个 provider 原样带上去，回调两侧才指向同一个源。
  final void Function(String provider, String channelId, String name)?
      onOpenLive;

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

  /// ★★★ task-11：**已经拉过**（哪怕结果是空）的区块键集合
  ///
  /// # 为什么必须有它 —— 否则"空区块"会让缓存与请求**无限循环**
  ///
  /// 判"要不要拉"原来只看 `_sectionItems[key]?.isEmpty ?? true`（见 `_loadSectionsOf`），
  /// 而"拉过但结果为空"与"从来没拉过"**在这个判据下完全同形**。
  /// 以前无所谓（每次进页面都全拉一遍），但缓存命中后就成了真问题：
  /// ```text
  /// 命中缓存 → 后台 force 重拉 → 某区块**仍然为空**（源那边确实没有内容）
  ///   → 没有本集合 ⇒ 它下一帧又算"没拉过" ⇒ 再拉 ⇒ …
  /// ```
  /// ⇒ 把"拉过"记成**独立的事实**，别用"列表是不是空的"去推断。
  ///   （同一条纪律见 `MyShelf` 的 `return null`：失败/空/没拉过必须分得开。）
  ///
  /// ★★ task-11 改成**按源分表**（原来是全局一张表）
  ///
  /// # 为什么必须按源分（我发现的一处真实错配）
  /// ```text
  /// 全局表 + 缓存命中时 `_sectionLoaded.addAll(snapshot.keys)`：
  ///   快照里的键格式是 `provider::sectionId` ⇒ 加进去是**带前缀**的，
  ///   而第 ④ 步判断用的是 `g.provider::s.id` ⇒ 前缀与区块所属的源**都对**，
  ///   看起来没事。但反过来：用户切到 A 源时拉过 A 的区块，
  ///   切到 B 源后 `_sectionLoaded` 里仍留着 A 的键 —— 一旦两个源有**同名**区块 id
  ///   （聚合站很常见：`hot` / `new` / `tv`），B 源的同名区块就会被误判成"拉过"
  ///   ⇒ **永远显示空轨道**，而且没有任何报错。
  /// ```
  /// ⇒ 按源分表，语义上根本不可能串台。
  final Map<String, Set<String>> _loadedBy = <String, Set<String>>{};

  bool _loading = true;
  String? _error;

  /// ★★ task-11：dispose 后禁止再写状态（异步回来的后台刷新 / 缓存写入检查它）
  ///
  /// 原来这里只有一个 `mounted` —— 那对**同步**的 setState 够用，
  /// 但缓存写入（`_cacheSource`）不是 setState，它会在 State 已经销毁后
  /// 继续往进程级缓存里写。写进去的内容本身没问题（就是那个源的快照），
  /// 但**读 `_groups` / `_sectionItems` 去组装**这个动作在已销毁的 State 上
  /// 是没有意义的 —— 显式记一个 flag 比靠 `mounted` 的边界语义更清楚。
  bool _disposed = false;
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
  ///
  /// ★ task-11 明确语义：它**始终是 `getHome()` 全量结果的指纹**，
  ///   而不是 `_groups` 当前装的那份的指纹。
  ///   为什么必须钉死这一点：缓存快照的命中判据与写入判据都是它 ——
  ///   若这里改成「子集的指纹」，那 `_switchSource` 与 `loadAll` 两条路径
  ///   就会用**两个不同的值**去查同一份快照 ⇒ 永远不命中，而且是**静默**的
  ///   （表现只是「缓存好像没生效」，不会有任何报错）。
  String _fingerprint = '';

  /// ★★ task-11：最近一次 `loadAll` **显示过**的源（判「源真的换了」用）
  ///
  /// 与 `_currentSource` 的区别：那个在 `_switchSource` 里就改了（立刻生效），
  /// 这个只在 `loadAll` 走完时更新 —— 用来区分「换源」与「同一个源刷新」。
  String _shownSource = '';

  /// ★★ task-11：最近一次 `getHome()` 的**全量**分组（只含骨架，很小）
  ///
  /// # 为什么需要留着它
  ///
  /// 缓存命中后 `_groups` 会收窄成「当前源的子集」（那样才有「秒开」：
  /// 命中那一刻的 `_groups` 必须**就是**要画的那份，不能等下一轮全量回来）。
  /// 但收窄之后就再也解析不出**别的源**的分区了 —— 用户点另一个源时会看到空态。
  /// ⇒ 全量骨架单独留一份，切到没缓存的源时从它里面取子集。
  ///
  /// ⚠️ 它只在 `loadAll` 里整体替换（`_allGroups = next`），从不原地改。
  List<ProviderGroup> _allGroups = [];
  // ════════════════════════════════════════════════════════════════════
  //  ★★★ task-6：首页直播条的**可用性闸**（Owner 第 8 条）
  // ════════════════════════════════════════════════════════════════════
  //
  // Owner 原话（逐字）：
  // > 只能黑屏的兼容不了直接放弃不要出现
  //
  // # 错在哪（行号）
  //
  // 直播条整条链路**零可用性判定**：
  // ```text
  // :1099-1100  if (src.type == 'custom') _LiveStrip(onOpenLive: onOpenLive)
  // :1285       itemCount: kLivePreview.length          ← 恒 8
  // :1288       final ch = kLivePreview[i]
  // :1291       onTap: () => onOpenLive?.call(ch.id, ch.name)
  // ```
  // 它直接渲染 `kLivePreview` 里写死的 8 个频道名，**一次网络都不发**
  // ⇒ 无论这 8 个台此刻有没有可播线路，都会画出来；
  //   用户点进去 ⇒ 播放器取到的全是 `drmProtected: true` 的线
  //   ⇒ 黑屏。用户看到的就是"一排能点、点了全黑"的假入口。
  //
  // # 为什么这么改（而不是"写死 cctv 不可用"）
  //
  // 判据必须**动态探测**，理由见 `live_availability.dart` 文件头：
  // 央视 CDN 地址会过期/更换，内容方哪天取消加密就会变成可用 ——
  // 写死过滤会造成**永久性假阴性**，比多显示几个台危险得多。
  //
  // 所以复用直播页（`live_page.dart:188`）那一套：
  // `LiveAvailabilityProbe` 探测 → `classifyStreams` 分类。
  // ★ 本页**自己持有一个探针实例**（不跨页共享）——
  //   本页与直播页的刷新时机、TTL 需求都不同，共享一个对象会让
  //   两页互相污染缓存（还多一条跨文件依赖）。
  LiveAvailabilityProbe _liveProbe = LiveAvailabilityProbe();

  /// 上一次「直播条探测」的批次号
  ///
  /// ⚠️ 与 `live_page.dart` 的批次守卫同一个理由：探测是**异步**的，
  ///    用户可能在探测期间切源/刷新 —— 回来时必须丢掉**过期批次**的结果，
  ///    否则会把旧源的可用性写到新源的头上（串台）。
  int _liveProbeGen = 0;

  /// 直播条过闸（只留 `playable`；其余一律不画）
  ///
  /// # 四档怎么处理（判据与直播页**刻意不同**，这里必须说清）
  ///
  /// ```text
  /// playable     → 画        有带视频的可播线路
  /// audioOnly    → ★ 不画    只有音频线 ⇒ 点进去是黑屏，正是 Owner 第 8 条
  /// unavailable  → 不画      一条可播线路都没有
  /// unknown      → ★ 不画    还没探到 / 探测失败
  /// ```
  ///
  /// ## ★ 为什么这里把 `unknown` 也闸掉（直播页却把它当"显示"）
  ///
  /// `shouldShowByDefault(unknown) == true` 的理由是"**探不到 ≠ 不可用**"，
  /// 那条规则针对的是**直播页的完整频道列表** —— 少一个台是用户的损失。
  /// 但首页这条是 `kLivePreview` 写死的 **8 个入口**，不是用户的频道清单：
  /// ```text
  /// 画出来 = 给用户一个"能点"的承诺
  /// 而 unknown 档的承诺**兑现不了**（要么黑屏、要么多等一次取流）
  /// ⇒ 首页宁可不画：用户想看直播，走「直播」页那条完整列表（那里
  ///   会把 unknown 如实显示出来，一个台都不少）
  /// ```
  /// ⇒ 一句话：**「不漏台」的诉求在直播页满足，「不画假入口」的诉求在首页满足。**
  ///   两处判据不同是**有意的**，不是不一致。
  ///
  /// ## ★ 为什么不能"塞个 unknown 占位"（Lead 明确要求）
  ///
  /// 那等于把"探不到"伪装成"可以点" —— 用户点下去还是黑屏，
  /// 只是多绕一圈。宁可**整块不出现**（见 `_LiveStrip` 的空列表分支）。
  List<({String id, String name})> _liveStripGate(String provider) {
    final passed = <({String id, String name})>[];
    for (final ch in kLivePreview) {
      if (_liveProbe.cached(provider, ch.id) == LiveAvailability.playable) {
        passed.add(ch);
      }
    }
    return passed;
  }

  /// 记录一次直播条渲染读数（★ 只在 debug 下，见顶部 `debugHomeLiveStrip`）
  void _recordLiveStrip(int candidates, int rendered, String provider) {
    if (!kDebugMode) return;
    debugHomeLiveStrip.add((candidates: candidates, rendered: rendered));
    debugHomeLiveStripCandidates
      ..clear()
      ..addAll(kLivePreview.map((c) => '$provider::${c.id}'));
    debugHomeLiveStripPassed
      ..clear()
      ..addAll(_liveStripGate(provider).map((c) => '$provider::${c.id}'));
    debugPrint('[HOME] 直播条: 闸前候选=$candidates 闸后渲染=$rendered'
        '（源=$provider）');
  }

  /// 探测当前源的直播条频道（**只为过闸**，结果进探针缓存）
  ///
  /// # 为什么用 `probe()` 而不是自己循环 `cached()`
  ///
  /// `probe()` 内部有并发池（`concurrency: 8`）与 TTL 跳过逻辑，
  /// 自己循环等于把那份逻辑抄一遍（还容易抄漏"已缓存就跳过"）。
  ///
  /// ★ 只探 `kLivePreview` 这 8 个 —— **不探该源的全部频道**：
  ///   首页只需要这 8 个的结论，多探的请求是纯浪费
  ///   （直播页要探全部，是因为它要显示全部）。
  ///
  /// ⚠️ 探测**失败**时 `probe()` 会记 `unknown`（见那里的注释）——
  ///    本闸把 unknown 当"不画"处理，所以失败不会变成假入口。
  Future<void> _probeLiveStrip(String provider) async {
    final gen = ++_liveProbeGen;
    // 拿不到频道列表也照探：探针只按 (provider, channelId) 取流，
    // 列表只是用来喂 probe() 的形状（LiveGroup）。
    final groups = <LiveGroup>[
      LiveGroup(
        provider: provider,
        providerName: provider,
        channels: [
          for (final c in kLivePreview) LiveChannel(id: c.id, name: c.name),
        ],
      ),
    ];
    try {
      final n = await _liveProbe.probe(groups);
      // ★ 过期批次直接丢（用户可能已切源）
      if (!mounted || gen != _liveProbeGen) return;
      debugPrint('[HOME] 直播条探测完成: 新探到 $n 个'
          '（源=$provider）⇒ 可播=${_liveStripGate(provider).length}'
          '/${kLivePreview.length}');
      setState(() {});
    } catch (e) {
      // 探测整体失败不影响首页其它内容（错误隔离，同 _loadSection）
      debugPrint('[HOME] 直播条探测失败: $e');
    }
  }

  /// 若当前源有 `type:'custom'`（直播条）区块 ⇒ 排一次探测
  ///
  /// ★ 判据用 `_groups` 而不是 `_enabled`：区块列表只有 `getHome()`
  ///   回来之后才知道（`_groups` 是它的缓存），而"这个源有没有直播条"
  ///   正是由区块决定的。
  ///
  /// ⚠️ 只在 `!_loading` 之后调用（见 `loadAll` 尾部）——
  ///    探测本身与骨架无关，但它会 setState，提前跑会白重建一次。
  void _maybeProbeLiveStrip() {
    final provider = _currentSource;
    if (provider.isEmpty) return;
    final hasCustom = _groups
        .where((g) => g.provider == provider)
        .expand((g) => g.sections)
        .any((s) => s.source.type == 'custom');
    if (!hasCustom) return;
    unawaited(_probeLiveStrip(provider));
  }

  /// 探针钩子：让测试注入一个假 fetch（**不碰真网络**）
  ///
  /// ⚠️ 只在测试里用。生产路径永远走 `LiveAvailabilityProbe` 的默认实现
  ///    （`SourinApi.getLiveStream`）。
  @visibleForTesting
  void debugSetLiveProbeFetch(
    Future<List<StreamCandidate>> Function(String provider, String channelId)
        fetch,
  ) {
    _liveProbe = LiveAvailabilityProbe(fetch: fetch);
  }

  /// ★★★ task-11 探针读数值：**渲染真正会用到的那几份状态**
  ///
  /// # 为什么必须有它（而不是在探针里数屏幕上的组件）
  ///
  /// 判据必须是「**用户看到卡片了没有**」，而：
  /// ```text
  /// 数屏幕上的 PosterCard → 受懒加载 / sliver cacheExtent 影响
  ///                         （屏幕外的区块根本没 build ⇒ 数出来恒偏小）
  /// 数 debugPrint 的文本   → 本项目已实测：binding 会接管 debugPrint ✗
  /// ```
  /// ⇒ 直接读「这一帧要拿去画卡片的那两份状态」（`_groups` × `_sectionItems`），
  ///   与 `build()` 里 `_itemsOf(g.provider, s.id)` 读的**是同一份数据**。
  ///   （同一条纪律见文件头的 `debugLoadAllCalls`：判据要与被测属性同源。）
  ///
  /// ⚠️ 只读不写；`@visibleForTesting` 只影响 lint 提示，不影响行为。
  @visibleForTesting
  ({String source, int groups, int sections, int cards, bool loading})
      get debugHomeReadout {
    var sections = 0;
    var cards = 0;
    for (final g in _groups) {
      if (_currentSource.isNotEmpty && g.provider != _currentSource) continue;
      for (final s in g.sections) {
        sections++;
        cards += _itemsOf(g.provider, s.id).length;
      }
    }
    return (
      source: _currentSource,
      groups: _groups.length,
      sections: sections,
      cards: cards,
      loading: _loading,
    );
  }

  /// ★★ task-11 探针入口：**完全走生产路径**地切一次源
  ///
  /// 就是源条 `onSelect` 接的那个函数（`SourceBar(onSelect: _switchSource)`）——
  /// 探针不自己模拟点击（指针注入会受窗口位置/遮挡影响），
  /// 直接调同一个回调 ⇒ 走的还是同一条代码路径。
  @visibleForTesting
  void debugSwitchSource(String id) => _switchSource(id);

  /// ★★ task-11 探针入口：跑一次**生产的按需补拉**（`_ensureSections`）
  ///
  /// 探针用它把"装完源之后可能存在的空快照"补实，然后再开始测量 ——
  /// ⚠️ 走的是产品路径，不是探针自己造的请求。
  @visibleForTesting
  Future<void> debugEnsureSections(String provider) => _ensureSections(provider);
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
    // ★ task-11：先置 flag 再 super —— 异步回来的后台刷新会看它
    _disposed = true;
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
      /*
       * ★★★ task-11：整页刷新时也先亮缓存
       *
       * 这条路径覆盖「回首页 / 刷新 / 设置页改完源 / 用户下拉」——
       * 与 _switchSource 的命中判据**同源**（都用 homeListCache.take），
       * 所以不会出现「切源秒开、回首页还是要等」这种只修一半的状态。
       *
       * ⚠️ `_groups.isEmpty` 这个判据的方向**反了**：它是「没有骨架就不显示加载态」，
       *    而缓存命中意味着**数据已经在手上** ⇒ 同样不该显示加载态。
       *    ⇒ 改成 `_groups.isEmpty && cachedTop == null`。
       */
      final cachedTop = homeListCache.take(
        current,
        fingerprint: _fingerprint,
        now: DateTime.now(),
      );
      final showSkeleton = _groups.isEmpty && cachedTop == null;
      if (cachedTop != null && _groups.isEmpty) {
        debugPrint('[HOME] 整页刷新前命中缓存（源=$current）：'
            '分区=${cachedTop.groups.length} 卡片=${cachedTop.cardCount} ⇒ 先画它');
        if (mounted) {
          setState(() {
            /*
             * ★ 这里**只补内容，不动 `_groups`**
             *
             * `_groups` 在本函数稍后会被全量 `next` 覆盖（它是**全量**语义），
             * 而「收窄成子集」只发生在 `_switchSource` 的命中路径上 ——
             * 两条路径各管一段，语义不重叠（见 `_groups` 那段说明）。
             */
            _sectionItems.addAll(cachedTop.items);
            // ⚠️ 不动 `_loadedBy`：它是"这个 State 拉过"的事实，
            //    而快照是**上一个** State 拉的（见那个字段的说明）。
            //    这里要的都是"有没有数据可画"，`_sectionItems` 已经回答了。
          });
        }
      }
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
      // ★ task-11：全量骨架单独留一份（切到没缓存的源时要用，见 _allGroups）
      _allGroups = next;

      /// ★ task-11：骨架变了但**当前源的分区没变** ⇒ 保留当前源的子集 + 数据，
      /// 只让下面第 ④ 步去把内容拉新（见那段长注释）
      var keepSubset = false;

      if (mounted) {
        setState(() {
          _enabled = homeSources;
          _currentSource = current;
          /*
           * ★ task-11：骨架变了时**不能**拿全量 `next` 去覆盖 `_groups`
           *
           * # 为什么（不这么改，缓存的第一帧就白做了）
           *
           * 缓存命中的那一刻 `_groups` 已经缩成**当前源的子集**
           * （`_switchSource` 命中路径干的就是这件事），于是：
           * ```text
           * 用户切回首页 → loadAll（tab-switch）→ 命中缓存 → 画出来（1 帧，卡片全在）
           *   → 拿到 next（全量）→ 指纹与缓存的子集指纹**必然不同** ⇒ changed=true
           *   → _groups = next（全量）⇒ visible 又能解析了…但 _fingerprint 也变成了全量指纹
           *   → ★ 于是**下一次** take() 拿着全量指纹去比子集指纹 ⇒ 永不命中
           * ```
           * ⇒ 复用已有的 `_refreshSource`：它把**当前源**的数据补齐 + 重新存快照，
           *   存的是**同一个语义**（子集 + 子集指纹），命中链就不断。
           *
           * ⚠️ 只在 `_groups` **非空**时走这条路：首屏冷启动（_groups 为空）
           *    必须老老实实 `_groups = next`，否则永远没有骨架可渲染。
           */
          if (changed) {
            if (_groups.isNotEmpty && current.isNotEmpty) {
              /*
               * 当前源的分区 id 串**逐字相同** ⇒ 骨架没变，只刷新内容。
               * ⚠️ 用 id 串比而不是「个数相同」：区块**换了一个**（数量不变）
               *    同样是骨架变了，那种情况必须换引用（否则画的是旧标题）。
               */
              final newSubset =
                  next.where((g) => g.provider == current).toList();
              final oldIds = _groups
                  .expand((g) => g.sections.map((s) => s.id))
                  .join(',');
              final newIds = newSubset
                  .expand((g) => g.sections.map((s) => s.id))
                  .join(',');
              if (newSubset.isNotEmpty && oldIds == newIds) {
                keepSubset = true;
                debugPrint('[HOME] 骨架变了但当前源（$current）的分区没变'
                    ' ⇒ 保留子集，只刷内容');
              } else {
                _groups = newSubset;
                _fingerprint = fp;
              }
            } else {
              _groups = next;
              _fingerprint = fp;
            }
          }
          _loading = showSkeleton;
          _error = null;
        });
      }

      /*
       * ④ 区块内容按需刷新 + **只拉当前源**
       *
       * 已有数据 → 跳过；force → 全拉；只处理当前源的分区。
       *
       * ★★ task-11：加了一条**新鲜度闸**（recentlyFresh）
       *
       * # 为什么（不加它，用户点回首页的**那一刻**就会重新发一轮请求）
       *
       * ```text
       * 回首页 → _switchTo(home) → loadAll(force: false, reason: tab-switch)
       *   这条路径**本来就是设计成「要刷新」的**（原版 onActivated）——
       *   对「内容可能变了」是对的，但对着**刚刚缓存过 2 秒**的源就是纯浪费：
       *   用户点一下底栏 ⇒ 立刻重新发一轮 get_list。
       * ```
       * ⇒ 快照足够新（kHomeCacheFreshFor）时跳过补拉。
       * ⚠️ 这是**有意的权衡**，代价写清楚：这段时间内不会去对新的，
       *    而窗口只有 30 秒（用户手动下拉刷新**永远**是 force，不受它影响）。
       */
      final recent = homeListCache.take(
        current,
        fingerprint: _fingerprint,
        now: DateTime.now(),
      );
      final recentlyFresh = recent != null &&
          DateTime.now().difference(recent.at) <= kHomeCacheFreshFor;
      if (recentlyFresh) {
        debugPrint('[HOME] 快照足够新（源=$current，存了 '
            '${DateTime.now().difference(recent.at).inSeconds}s）'
            ' ⇒ 这一轮不发区块请求');
      }

      final pending = <Future<void>>[];
      for (final g in _groups) {
        if (current.isNotEmpty && g.provider != current) continue;
        for (final s in g.sections) {
          final key = '${g.provider}::${s.id}';
          final has = (_sectionItems[key]?.isNotEmpty) ?? false;
          final tried =
              (_loadedBy[g.provider] ?? const <String>{}).contains(s.id);
          /*
           * ⚠️ tried 参与判据是**必须**的：没有它，一个「拉过但确实是空」的区块
           *    会在**每一帧**都被算成「没拉过」⇒ 无限重拉（见 _loadedBy 的说明）。
           */
          if (force || (!has && !tried && !recentlyFresh)) {
            pending.add(_loadSection(g.provider, s.id, s.source));
          }
        }
      }
      debugPrint('[HOME] 待加载区块 ${pending.length} 个'
          '（当前源=$current）'
          '${keepSubset ? "（骨架未变 ⇒ 只刷内容）" : ""}');
      await Future.wait(pending);
      debugPrint('[HOME] 全部区块加载完成');

      if (mounted) setState(() => _loading = false);

      /*
       * ★ task-11：loadAll 换源时把视口复位到顶部
       *
       * # 为什么需要（缓存**放大**了这个问题）
       *
       * 冷加载时 `_loading = true` ⇒ 骨架屏高度很短 ⇒ `ScrollPosition`
       * 自动被钳到 0（反正没内容可滚）。而缓存命中时 `_loading = false`
       * 且**满屏内容**：用户上一次在 A 源滚到 3000，切到 B 源后
       * 视口**留在 3000** ⇒ 看到的是 B 源中段（甚至一片空白）。
       * 对用户来说这正是「切源没生效 / 又白屏了」。
       *
       * ⚠️ 只在**当前显示的源真的换了**时复位：同一个源的下拉刷新/后台刷新
       *    不该把用户正在看的位置顶掉（那是「刷新把页面弹回顶部」的老毛病）。
       */
      if (mounted && current != _shownSource) {
        _shownSource = current;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) return;
          _scrollController.jumpTo(0);
        });
      }

      /*
       * ★★★ task-11：把这一轮的结果存进缓存（stale-while-revalidate 的写入端）
       *
       * ⚠️ 必须放在 `await Future.wait(pending)` **之后** ——
       *    存早了会把「还没拉回来的空 items」当结果存进缓存，
       *    于是下次命中直接画出空轨道（看起来像「源里没内容」）。
       *
       * ⚠️ 存的是**当前源的子集 + 子集指纹**（见 _cacheSource）——
       *    命中判据与写入判据必须是同一个指纹，否则永不命中。
       */
      _cacheSource(current);

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

      /*
       * ★★★ task-6：首页直播条的**可用性探测**（Owner 第 8 条）
       *
       * # 为什么要在这里排、而不是在 build 里排
       *
       * ```text
       * build 每次重建都会跑（滚动、setState、主题变化…）
       *   ⇒ 排在这里等于"每帧都可能触发一次探测调度"
       * ```
       * 而 `loadAll` 是"页面数据刷新"的唯一入口
       *（initState / 下拉刷新 / 切源 / shell 通知）—— 与探测的
       * 生命周期**天然对齐**：内容刷新了，可用性跟着重判一次。
       *
       * ★ 只探**当前源**且该源真的声明了 `type:'custom'` 区块 ——
       *   实测（task-4）28 个源里只有 `cctv` 有这种区块，
       *   其余源在这里**零请求**（见下面 `hasCustom`）。
       *
       * ⚠️ **不 await**：直播条探测要发 8 个取流请求，
       *    await 会把"首页渲染完成"推迟到探测结束之后 ——
       *    而直播条是**次要内容**，不该拖慢首屏。
       *    结果回来后由 `_probeLiveStrip` 自己 setState 补画。
       */
      _maybeProbeLiveStrip();
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
          setState(() {
            _sectionItems[key] = page.items;
            // ★ task-11：**空结果也算"拉过"** —— 否则缓存命中后的后台刷新
            //   会把这个空区块判成"没拉过"，一帧一次地重拉（见 _loadedBy）。
            _markLoaded(provider, sectionId);
          });
        }
      } else if (src.isRank && src.rankId != null) {
        final page = await SourinApi.getRank(provider, src.rankId!);
        if (mounted) {
          setState(() {
            _sectionItems[key] = page.items;
            _markLoaded(provider, sectionId);
          });
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
  ///
  /// ★★★ task-11：加了 [force]（缓存命中后的后台刷新要它）
  ///
  /// ```text
  /// force=false（切源用）→ 只补"从来没拉过"的 ⇒ 缓存命中的区块**不发请求**
  ///                         （用户要的"不重拉"就是这一条）
  /// force=true（后台刷新用）→ 全拉一遍 ⇒ 保证旧的会被新的追上
  /// ```
  /// ⚠️ 判据用 `_loadedBy[provider]` 而**不是** `items.isEmpty` ——
  ///    见那个字段的说明（空结果的区块也要算"拉过"，否则会无限重拉）。
  Future<void> _loadSectionsOf(String provider, {bool force = false}) async {
    // ⚠️ 同 `_ensureSections`：必须用**全量骨架** `_allGroups`。
    //    用 `_groups`（已被 loadAll 收窄成当前源）时，后台刷新**非当前源**会静默失效。
    //    ★ 这条正是"C 过期后 revalidate 请求=0"的成因：刷新根本没发生。
    final g = (_allGroups.isEmpty ? _groups : _allGroups)
        .where((x) => x.provider == provider)
        .firstOrNull;
    if (g == null) return;

    final loaded = _loadedBy[provider] ?? const <String>{};
    final pending = <Future<void>>[];
    for (final s in g.sections) {
      final has = loaded.contains(s.id) || _hasItems(provider, s);
      if (force || !has) {
        pending.add(_loadSection(provider, s.id, s.source));
      }
    }
    await Future.wait(pending);
  }

  /// 标记「provider 的这个区块已经拉过」（**空结果也算**）
  void _markLoaded(String provider, String sectionId) {
    (_loadedBy[provider] ??= <String>{}).add(sectionId);
  }

  /// 该区块**有没有数据可画**
  ///
  /// ⚠️ 只看 `_sectionItems`，**不看** `_loadedBy` —— 两者回答的是不同问题：
  /// ```text
  /// _sectionItems 有内容吗 → "现在画得出来吗"  ⇒ 决定**切源那一刻要不要补拉**
  /// _loadedBy 拉过了吗     → "还要不要再试一次" ⇒ 决定**按需刷新要不要跳过**
  /// ```
  /// ★ 分开的理由：一个区块可能"拉过但确实是空的"（源那边没有内容）。
  ///   那时切源**不该**为它发请求（用户要的"不重拉"），
  ///   而按需刷新时也没必要再打一次（`_loadedBy` 让它跳过）。
  bool _hasItems(String provider, Section s) =>
      (_sectionItems['$provider::${s.id}']?.isNotEmpty) ?? false;

  /// ★★ task-11：进入一个源时**按需**补数据（「不重拉」真正落地的地方）
  ///
  /// # 为什么必须有它（原来的路径会**无条件**重拉）
  ///
  /// ```text
  /// 老路径：_switchSource → unawaited(_loadSectionsOf(id))
  ///   判据 = loaded.contains(s.id) || items 非空
  ///   缓存命中时 _loadedBy 是**空的**（State 是新的），items 非空 ⇒ 不发 ✓
  ///   —— 但一个**拉过且确实是空**的区块：items 空 + loaded 空 ⇒ has=false
  ///      ⇒ **立刻发请求**，与用户诉求（"切回来不要重拉"）直接冲突。
  /// ```
  ///
  /// # 判据（`_hasItems`，而不是 `_loadedBy`）
  /// ```text
  /// 有数据 → 一个请求都不发（缓存命中就该是 0 请求）
  /// 没数据 → 补拉（不能因为"以前拉过是空的"就永远空着）
  /// ```
  /// ★ 这条判据天然就对：**发请求的唯一理由是「现在画不出东西」**。
  Future<void> _ensureSections(String provider) async {
    /*
     * ⚠️⚠️ 必须从 `_allGroups` 取骨架，**不能**用 `_groups`
     *
     * ```text
     * `loadAll` 会把 `_groups` 收窄成"当前源的那一份"（keepSubset）⇒
     *   对**非当前源**，`_groups.where(provider==x)` 是**空的** ⇒ 这里 `return`，
     *   一个区块都不拉、快照也不写。
     * ★ 真机读数就是这么露出来的：探针在"当前源=cctv"时预热 t11a ⇒
     *   预热静默失效 ⇒ 后面切回 t11a **永远不命中**（读数 720ms/2 请求，与冷加载一样）。
     * ⇒ 那不是缓存坏了，是**找不到骨架就悄悄放弃**。
     * ```
     * `_allGroups` 存的正是**完整骨架**（所有源），它的存在就是为了解析任意源的子集。
     * 收窄 `_groups` 是渲染优化，不该让"预取别的源"跟着失效。
     */
    final g = (_allGroups.isEmpty ? _groups : _allGroups)
        .where((x) => x.provider == provider)
        .firstOrNull;
    if (g == null) return;

    final pending = <Future<void>>[];
    for (final s in g.sections) {
      /*
       * ⚠️ 只处理**能预取**的区块（category / rank）。
       *
       * `custom` / `static` / `recent` 由界面自己画（见 `_loadSection` 的说明）——
       * 对它们调 `_loadSection` 是**空操作**：一个请求都不发，但会进 `pending`，
       * 于是日志里出现"补拉 1 个区块"而实际零请求 ⇒ 读数与日志对不上。
       * ★ cctv 源的「正在直播」正是 custom ⇒ 这条不加，切到 cctv 每次都多一行假日志。
       */
      final fetchable = (s.source.isCategory && s.source.categoryId != null) ||
          (s.source.isRank && s.source.rankId != null);
      if (fetchable && !_hasItems(provider, s)) {
        pending.add(_loadSection(provider, s.id, s.source));
      }
    }
    if (pending.isNotEmpty) {
      debugPrint('[HOME] 按需补拉（源=$provider）：${pending.length} 个区块'
          '（其余 ${g.sections.length - pending.length} 个已有数据 ⇒ 零请求）');
    }
    await Future.wait(pending);
    /*
     * ★★★ 收尾必须**存快照** —— 这一行是「切源缓存」成立的关键
     *
     * # 少了它会怎样（我自己第一版就漏了，靠真机探针的读数才发现）
     * ```text
     * 快照只在两处写入：loadAll 尾部、_refreshSource 尾部。
     * 而用户切源的路径是：_switchSource →（未命中）→ _ensureSections
     *   ⇒ 这条路上**一次都没写** ⇒ 用户切到 B、再切回 A、再切回 B…
     *     **永远不命中**（缓存里只有 loadAll 那一刻的源）。
     *   ⇒ 用户报的正是「每次切换源都要重载」—— 修了却对这条路径无效。
     * ```
     * ⇒ 放在 `Future.wait` 之后：数据已经落进 `_sectionItems`，快照才完整。
     */
    _cacheSource(provider);
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

    /*
     * ══════════════════════════════════════════════════════════════
     * ★★★ task-11：缓存命中 ⇒ **同一次 setState 里**把数据换上去
     * ══════════════════════════════════════════════════════════════
     *
     * Owner 原话：
     * > 我在首页每次切换源的时候都要重载,我想如果有缓存就好了
     *
     * # 为什么必须放在**这一次** setState 里（不能"先切源、再补数据"）
     *
     * ```text
     * 两次 setState → 中间那一帧 _groups/_sectionItems 还是空的
     *   ⇒ build 走的是 `visible.isEmpty` 分支 ⇒ **空态**
     *   （比骨架更糟：骨架至少说明"在加载"，空态是在说"这个源没内容"）
     * ⇒ 一次 setState 换完 ⇒ **第一帧就有卡片**，不经过骨架也不经过空态
     * ```
     *
     * ⚠️ 判据取的是 `_fingerprint`（当前骨架的指纹），不是"缓存里有没有这个源"：
     *    骨架变了（用户刚在设置页启停过源）⇒ 旧快照的分区列表与指纹对不上
     *    ⇒ `take()` 直接判不命中（那一条也顺手删掉，不占名额）。
     */
    final cached = homeListCache.take(
      id,
      fingerprint: _fingerprint,
      now: DateTime.now(),
    );

    setState(() {
      _currentSource = id;
      if (cached != null) {
        // ★ 命中路径把 _groups 收窄成**这个源**的子集 ——
        //   这样同一帧里 visible 就能解析出内容（见上面那段说明）。
        //   冷路径会从 _allGroups 重新取子集，两者互不干扰。
        _groups = cached.groups;
        _sectionItems.addAll(cached.items);
        _loading = false;
        _error = null;
      }
    });

    if (cached != null) {
      /*
       * ★ task-11：命中路径也要落盘
       *
       * ⚠️ 上面那段「落盘」的注释写着"必须放在 setState 之后" —— 它原来在
       *    **函数末尾**，而命中路径会 `return`，所以**整段落盘被跳过了**：
       *    用户在多个源之间切来切去，只有"切到没缓存的源"才写盘，
       *    切到有缓存的源**不写** ⇒ 下次启动回到的是那个没缓存的源。
       *    （同一条：`_restoreScroll` 也是末尾那段，命中路径原本也漏了。）
       */
      UiPrefs.setHomeSource(id);
      debugPrint('[HOME] 缓存命中（源=$id）：分区=${cached.groups.length} '
          '区块=${cached.items.length} 卡片=${cached.cardCount} '
          '（存了 ${DateTime.now().difference(cached.at).inSeconds}s）');
      /*
       * ★★ 后台刷新：这就是 stale-while-revalidate 的 revalidate 那一半
       *
       * ★★ 但**必须过一道新鲜度闸** —— 这一条是我第一版写错、后面改的，
       *   记在这里免得后人再"优化"回去：
       * ```text
       * 第一版：命中就无条件 unawaited(_refreshSource(...))
       *   ⇒ 用户切回一个 2 秒前才拉过的源 ⇒ **立刻又发一轮 get_list**
       *   ⇒ 与 Owner 的诉求（"每次切换源都要重载"）方向相反：
       *     观感上是"先画旧内容"，但流量照花，而且探针实测会看到
       *     "切源第一帧就有请求" ⇒ 判据本身被污染。
       * ```
       * ⇒ 只有快照**不够新**（超过 kHomeCacheFreshFor）才去 revalidate。
       *   30 秒内的第二次切回：一个请求都不发。
       *
       * ⚠️ 顺序：**先按需补拉**（`_ensureSections`，可能一个请求都不发），
       *   再整源后台刷新（`_refreshSource`）。两者写同一批键，
       *   串行执行才不会有"后完成的赢"把新数据盖回旧的。
       */
      final age = DateTime.now().difference(cached.at);
      final stale = age > kHomeCacheFreshFor;
      unawaited(() async {
        await _ensureSections(id);
        if (stale) {
          await _refreshSource(id, reason: 'cache-stale');
        } else {
          debugPrint('[HOME] 快照够新（源=$id，存了 ${age.inSeconds}s ≤ '
              '${kHomeCacheFreshFor.inSeconds}s）⇒ 跳过后台刷新');
        }
      }());
      _maybeProbeLiveStrip();
      _restoreScroll(id);
      return;
    }

    debugPrint('[HOME] 缓存未命中（源=$id）⇒ 走冷加载路径');
    setState(() {
      _currentSource = id;
      /*
       * ★ task-11：`_groups` 可能已经收窄成**别的源的子集**（上一次命中留下的），
       * 那样这里会解析不出目标源的分区 ⇒ 用户看到空态。
       * 所以冷路径必须从 `_allGroups`（全量骨架）重新取一次子集。
       *
       * ⚠️ 没有 `_allGroups`（还没跑过 loadAll）时保持原样 ——
       *    `loadAll` 迟早会填上，别在这里造一个空分组。
       */
      if (_allGroups.isNotEmpty) {
        final sub = _allGroups.where((g) => g.provider == id).toList();
        if (sub.isNotEmpty) _groups = sub;
      }
    });
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
    // ⚠️ 走 `_ensureSections` 而**不是** `_loadSectionsOf`：
    //    后者对"拉过但是空"的区块会立刻重发请求（见 `_ensureSections` 的说明）。
    unawaited(_ensureSections(id));

    /*
     * ★ task-6：切源后重探直播条
     *
     * 两个源的可播线路完全无关（cctv 全 DRM，iptv 全可播）——
     * 不重探就会拿 A 源的结论去画 B 源的条（串台）。
     * ★ 探针按 (provider, channelId) 分键缓存 ⇒ 切回来时是**命中缓存**，
     *   不会重复发请求。
     */
    _maybeProbeLiveStrip();

    _restoreScroll(id);
  }

  /// 恢复目标源的滚动位置（下一帧 —— 等列表换完）
  ///
  /// ★ task-11 把它抽成方法：命中缓存与冷加载**两条路径都要恢复位置**
  ///   （原来这段内联在 _switchSource 末尾，命中路径提前 return 就漏掉了 ——
  ///    而「切回来位置也回来了」正是用户对「缓存」的另一个期待）。
  void _restoreScroll(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = _railScroll[id] ?? 0;
      _scrollController.jumpTo(
        target.clamp(0, _scrollController.position.maxScrollExtent),
      );
    });
  }

  /// ★★★ task-11：把**一个源**的数据补齐 + 存进缓存
  ///
  /// # 为什么不是「重跑一遍 loadAll」
  ///
  /// ```text
  /// loadAll() 会连带 listProviders()（重扫插件目录）+ 重解析当前源的回退 +
  ///           重画「我的」+ 重算整页探针读数
  /// ```
  /// 那些都属于「整页刷新」，与「把**这一个源**的内容拉新」不是一回事。
  /// 而且 loadAll 拿的是 getHome() 的**全量**结果，会把 _groups 换成全量
  /// （_switchSource 命中路径靠的正是「当前源的子集」），语义会漂。
  /// ⇒ 这里只做两件事：拉这个源的区块 + 存快照。
  ///
  /// ⚠️ force 必须是 true：缓存命中的意义就是「这些区块已经有数据了」，
  ///    而 force=false 会被 _sectionLoaded 判成「拉过」⇒ 一个请求都不发 ——
  ///    那就不是 revalidate，是「永远用旧的」。
  Future<void> _refreshSource(String provider, {required String reason}) async {
    if (_disposed) return;
    debugPrint("[HOME] 后台刷新开始（源=$provider, reason=$reason）");
    final t0 = DateTime.now();
    try {
      await _loadSectionsOf(provider, force: true);
    } catch (e) {
      // 单个区块失败已在 _loadSection 里隔离；这里只兜「整体」失败
      debugPrint("[HOME] 后台刷新失败（源=$provider）: $e");
    }
    // ★ 用户可能在刷新期间又切走了 ⇒ 这份快照仍然值得存（它就是这个源的），
    //   但**不要再 setState**（当前显示的是别的源，刷上去就是串台）。
    _cacheSource(provider);
    debugPrint("[HOME] 后台刷新完成（源=$provider）："
        "耗时 ${DateTime.now().difference(t0).inMilliseconds}ms");
  }

  /// 把 provider 当前的 _groups + _sectionItems 存成快照（LRU + TTL）
  ///
  /// ⚠️ items 只挑**属于这个源**的键（provider:: 前缀）——
  ///    否则会把别的源的数据一起塞进这个条目，上限与命中语义都会失真。
  /// ⚠️ 存**引用**不深拷贝：_sectionItems 的值只被整体替换（见 _loadSection），
  ///    不会被原地改 ⇒ 共享安全，且省掉一次 160 元素的复制。
  void _cacheSource(String provider) {
    // ★ dispose 之后不再组装快照：State 已经没了，_groups/_sectionItems 的语义
    //   在这里不再保证（见 _disposed 的说明）。缓存里那一份保持不变即可。
    if (_disposed || provider.isEmpty || _groups.isEmpty) return;
    final prefix = "$provider::";
    final mine = <String, List<MediaItem>>{};
    for (final e in _sectionItems.entries) {
      if (e.key.startsWith(prefix)) mine[e.key] = e.value;
    }
    final groups = _groups.where((g) => g.provider == provider).toList();
    if (groups.isEmpty) return;
    homeListCache.put(
      provider,
      HomeSnapshot(
        fingerprint: _fingerprint,
        groups: groups,
        items: mine,
        at: DateTime.now(),
      ),
    );
    debugPrint("[HOME] 缓存写入（源=$provider）：分区=${groups.length} "
        "区块=${mine.length} 驻留=${homeListCache.length}/"
        "${homeListCache.maxEntries}");
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

  /// ★★ task-11 探针：当前**已经建到树上**的卡片元素数（用户真能看到的那些）
  ///
  /// # 为什么它和 debugHomeReadout.cards 是两个不同的数，且两个都要
  ///
  /// ```text
  /// debugHomeReadout.cards  = 这一帧**有数据**的卡片数（状态层）
  /// debugBuiltCards         = 其中**已经真的 build 出元素**的（渲染层）
  /// ```
  /// 只看前者可能被「数据在但没渲染」骗过（懒加载、布局异常、可见性闸）；
  /// 只看后者则分不清「没数据」与「没滚到」。两个一起看才能说「用户看到了」。
  ///
  /// ⚠️ `visitChildElements` 会触发**按需 build**（这正是我们要的：
  ///    它量的就是「如果现在要画，能画出来几张」），且不会改任何状态。
  @visibleForTesting
  int get debugBuiltCards {
    var n = 0;
    void walk(Element e) {
      if (e.widget is PosterCard) n++;
      e.visitChildElements(walk);
    }

    final el = context as Element;
    el.visitChildElements(walk);
    return n;
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
                        /*
                         * ★ task-6：把"**过闸后的名单**"和"记录读数"交给区块。
                         *
                         * # 为什么闸在这里过（而不是在 build 里算好）
                         *
                         * 闸的键是 `(provider, channelId)` —— 这里的
                         * `g.provider` 就是**这个区块自己的源**，
                         * 两者天然对齐，不会串台。
                         *
                         * # 为什么 `custom` 型才过闸
                         *
                         * `custom` 是"区块内容由界面自己画"的类型
                         *（实测只有 `cctv` 的「正在直播」用了它，
                         * 见 `cctv.js:391`）⇒ 只有它才需要直播条的判定；
                         * 其它类型的区块传空名单，不产生任何请求/查询。
                         */
                        liveStrip: s.source.type == 'custom'
                            ? _liveStripGate(g.provider)
                            : const <({String id, String name})>[],
                        onLiveStripRendered: _recordLiveStrip,
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
    this.liveStrip = const <({String id, String name})>[],
    this.onLiveStripRendered,
  });

  final String provider;
  final Section section;
  final List<MediaItem> items;
  final void Function(MediaItem) onOpenDetail;

  /// 点直播频道 → 进播放器
  ///
  /// ★ task-6：第一个参数是**频道所属的源**（旧签名丢了它，
  ///   接收方只能把 provider 写死成 'cctv'）。详见 [HomePage.onOpenLive]。
  final void Function(String provider, String channelId, String name)?
      onOpenLive;

  final void Function(String provider, String sectionTitle, SectionSource src)?
      onBrowse;

  /// ★ task-6：**已过闸**的直播频道名单（只含 `playable`）
  ///
  /// ⚠️ 这里**不再是** `kLivePreview` 全量 —— 由 `HomePageState._liveStripGate`
  ///    按 (provider, channelId) 的探测结果筛过。空列表 = 整块不渲染。
  final List<({String id, String name})> liveStrip;

  /// 直播条**渲染完**之后的回调（参数：闸前候选数 / 闸后渲染数）
  ///
  /// ★ 探针读数必须由**渲染路径自己**上报 —— 见 `debugHomeLiveStrip` 的说明。
  final void Function(int candidates, int rendered, String provider)?
      onLiveStripRendered;

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
          /*
           * ★★★ task-6：**先过闸，再决定画不画**（Owner 第 8 条）
           *
           * # 错在哪
           *
           * 旧代码这里只有一句 `if (src.type == 'custom')` ——
           * 只要区块是 custom 型就无条件画直播条，
           * 条里的频道名直接来自写死的 `kLivePreview`，
           * **完全没问过"这些台现在能不能播"**。
           *
           * # 为什么这么改
           *
           * `liveStrip` 是**已过闸**的名单（只含 `playable`，见
           * `HomePageState._liveStripGate`）。★ 空名单时
           * `_LiveStrip` 返回零尺寸组件 ⇒ 这一块**整个消失**，
           * 不会留下一条 44dp 的空带（那看起来像"加载失败"，
           * 比不显示更糟 —— 与 `_Rail` 的「暂无内容」占位是两回事：
           * 那里是"区块有标题但没有内容"，这里是"区块本身不该存在"）。
           *
           * ⚠️ `onLiveStripRendered` 把**闸前/闸后**两个数一起报上去 ——
           *    只报闸后数无法区分"闸生效了"与"直播条压根没渲染"。
           */
          if (src.type == 'custom')
            _LiveStrip(
              provider: provider,
              channels: liveStrip,
              onOpenLive: onOpenLive,
              onRendered: onLiveStripRendered,
            )

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
///
/// ★★★ task-6 改动（Owner 第 8 条「只能黑屏的兼容不了直接放弃不要出现」）
///
/// # 错在哪
///
/// 旧实现里这一条的数据源是**写死的常量**：
/// ```text
/// :1285  itemCount: kLivePreview.length     ← 恒 8，与网络无关
/// :1288  final ch = kLivePreview[i]
/// ```
/// 它**不接收任何"哪些台可用"的输入**，也从不发请求 ⇒ 8 个台名
/// 必然画出来。而实测（task-4）这 8 个台在 cctv 源里**全部**只有
/// `drmProtected: true` 的视频线（0 个非 DRM 视频线、20/20 仅音频）
/// ⇒ 用户点任意一个都是黑屏。这就是"一排能点、点了全黑"的假入口。
///
/// # 为什么这么改
///
/// 把数据源从"写死的 `kLivePreview`"换成"**调用方过闸后的名单**"
///（`channels`）。本组件从此**不再自己决定画什么** ——
/// 它只负责把名单画出来，以及**名单为空时整块不出现**：
/// ```text
/// channels.isEmpty ⇒ 返回零尺寸组件
///   ⇒ 连外面那层 44dp 的 SizedBox 都不存在（不是"空盒子"）
/// ```
/// ★ 为什么必须是"整块消失"而不是"留个空盒子"：
///   空盒子看起来像**加载失败/坏了**，用户会以为应用出问题；
///   而这一块本来就只是"快捷入口"，没有它首页依然完整
///   （想看直播走「直播」页那条完整列表）。
class _LiveStrip extends StatelessWidget {
  const _LiveStrip({
    required this.provider,
    required this.channels,
    this.onOpenLive,
    this.onRendered,
  });

  /// 这些频道所属的源（点进去时要原样带上去 —— 见 [onOpenLive]）
  final String provider;

  /// ★ **已过闸**的频道名单（只含 `playable`；由 `_liveStripGate` 产出）
  final List<({String id, String name})> channels;

  /// 点频道 → 进播放器
  ///
  /// ★ task-6：第一个参数是 `provider`（本组件自己那份，不是猜的）——
  ///   旧签名只有 `(channelId, name)`，接收方只能写死 'cctv'。
  final void Function(String provider, String channelId, String name)?
      onOpenLive;

  /// 渲染读数上报（闸前候选数 / 闸后渲染数 / 源）
  final void Function(int candidates, int rendered, String provider)? onRendered;

  @override
  Widget build(BuildContext context) {
    /*
     * ★ 先上报读数，再决定画不画
     *
     * # 为什么上报必须放在"空名单提前 return"**之前**
     *
     * 验收要的是「闸前候选 N / 闸后渲染 M」这一对读数 ——
     * 而本次实测的恰恰是 **N=8 / M=0**（全被闸掉）那一档。
     * 若空名单不上报，这一档就**根本没有读数**（读数只在"有台可播"时才有），
     * 而那正是要证明的那一档 ⇒ 判据会缺掉最关键的一次测量。
     *
     * # 那"读数存在"会不会把两种情况混起来？
     *
     * 不会 —— 读数本身就是**渲染路径跑过的证据**：
     * ```text
     * 有读数            = 本源的 custom 区块真的渲染过 ⇒ (N, M) 可信
     * 没有任何读数       = 这条路径压根没跑（源没有 custom 区块 / 还在骨架态）
     * ```
     * 两个问题分别由"读数的**值**"和"读数的**有无**"回答，互不干扰。
     */
    onRendered?.call(kLivePreview.length, channels.length, provider);

    /*
     * ★★★ 全不可播 ⇒ **整块不渲染**（Owner 第 8 条）
     *
     * 返回零尺寸组件而不是"高度 44 的空容器"：
     * 空盒子看起来像**加载失败/坏了**，而这一块本来就只是快捷入口 ——
     * 没有它首页依然完整（想看直播走「直播」页那条完整列表）。
     */
    if (channels.isEmpty) return const SizedBox.shrink();

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
        // ★ task-6：数据源从写死的 kLivePreview 换成**过闸后的名单**
        //   （长度可能小于 kLivePreview，为 0 时上面已提前 return）
        itemCount: channels.length,
        separatorBuilder: (_, __) => const SizedBox(width: Sp.x2),
        itemBuilder: (context, i) {
          final ch = channels[i];
          return Center(
            child: InkWell(
              // ★ task-6：把 provider 原样带上 —— 接收方不再猜源
              onTap: () => onOpenLive?.call(provider, ch.id, ch.name),
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
