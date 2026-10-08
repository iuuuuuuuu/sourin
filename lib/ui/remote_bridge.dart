// ═══════════════════════════════════════════════════════════════════════
//  局域网遥控桥 —— 客户端与遥控服务的连接
// ═══════════════════════════════════════════════════════════════════════
//
// 移植自原版 `src/composables/remoteBridge.ts`（358 行）。
//
// # 为什么需要它
//
// 播放器状态（在播什么、第几集、进度）**只存在于客户端**，
// Rust 侧拿不到。而手机发来的命令（下一集/搜索）也只有客户端能执行
// （要调 Provider、操作媒体内核）。
//
// 所以这里是**双向桥**：
// ```text
// · 定期把播放器状态**上报**给 Rust（手机读取）
// · 定期从 Rust **取走**待执行命令并执行
// ```
//
// ══════════════════════════════════════════════════════════════════════
// ★ 性能教训（原版 Owner 报「操作十分卡顿」后实测发现，**必须照抄策略**）
// ══════════════════════════════════════════════════════════════════════
//
// 原版第一版是「挂上就无条件 `setInterval` 800ms」—— 实测后果：
// 一次 5 次切页的操作里，`remote_report_state` 与
// `remote_take_commands` **各被调了 12 次**（共 24 次 IPC）。
// 而这些调用在**遥控根本没开启**时也照发不误 ——
// 纯粹的空转，却是每 800ms 两次跨进程调用的固定开销。
//
// 现在的做法（四条，全部照抄）：
// ```text
// 1. **遥控没开就不轮询** —— 启动时查一次状态，之后只在开启时才挂定时器
// 2. **遥控开着时也只在播放页轮询** —— 离开播放页立即停
//    ⚠️ 但 Dart 侧的实现与这里**不同**，见下面「与原版的一处必要差异」
// 3. 状态没变就**跳过上报**（进度每 tick 必然变，但标题/集数不会）
//    —— 靠 `sig()` 签名去重
// 4. 空闲时**降低频率**（没在播 → 2500ms；在播 → 400ms）
// ```
//
// ══════════════════════════════════════════════════════════════════════
// 与原版的一处**必要差异**：轮询 host 的生命周期
// ══════════════════════════════════════════════════════════════════════
//
// 原版第 2 条说「离开播放页立即停」，但它后来**改掉了**自己：
// ```ts
// /**
//  * ⚠️ 与旧版的区别：以前离开播放页会调这个，于是「在首页时遥控全废」。
//  * 现在离开播放页只需 `clearPlayerBridge()`，桥要继续跑（搜索要用）。
//  */
// export function stopRemoteBridge(): void { ... }
// ```
// 因为**搜索/发现是全局能力** —— 用户在首页时手机发搜索，
// 如果桥停了就没人执行，手机永远「搜索中…」然后超时。
//
// Flutter 侧对应：
// ```text
// RemoteBridgeHost（永远挂载，在 MaterialApp.builder 里）
//   → 桥的生命周期与应用一致
//   播放页进出只调 setPlayerBridge / clearPlayerBridge
//   （撤掉/恢复「播放控制」能力，桥本身不停）
// ```
// 这正是原版**最终**的正确形态，不是妥协。
//
// # 与原版的解耦方式一致
//
// 本模块不 import 任何页面，而是接受「能力接口」——
// 这样播放页/搜索页各自注册自己能做的事，桥不认识它们。

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/models.dart';
import '../core/sourin_api.dart';

/// 播放页提供的能力（进播放页注册，离开时清除）
class PlayerBridge {
  const PlayerBridge({required this.getState, required this.exec});

  /// 取当前播放状态
  final RemoteState Function() getState;

  /// 执行命令（不支持的直接忽略）
  final Future<void> Function(RemoteCommand cmd) exec;
}

/// ★ 全局能力（与「哪个页面开着」无关）
///
/// # 为什么必须与 [PlayerBridge] 分开（原版实测踩到的大 bug）
///
/// 原版原先只有「播放页提供的桥」，`search` / `loadHome` 都挂在它上面。
/// 而**播放页只在用户点开视频时才存在** —— 于是：
/// ```text
/// 用户在首页 → 手机发搜索 → 命令进队列 → 没有桥 → 没人执行
///                           → 手机永远看到「搜索中…」然后超时
/// ```
/// 原版实测确认（这是 Owner 报「局域网搜索不支持搜索」的根因）：
/// ```text
/// · 在首页下发命令 → 5 秒后**仍在队列里**（remaining: ["next_episode"]）
/// · 进播放页下发 → 立刻被取走（leftoverCommands: []）
/// ```
/// 而**搜索本来就与播放无关** —— 用户想搜个片，不该先随便点开一个视频。
class GlobalBridge {
  const GlobalBridge({
    required this.search,
    required this.loadHome,
    this.openItem,
    this.liveChannelStep,
  });

  /// 执行搜索并把结果回填（与当前页面无关）
  final Future<void> Function(String keyword) search;

  /// 刷新首页并回填
  final Future<void> Function() loadHome;

  /// ★ 打开某个条目（手机端从搜索结果点进来的场景）
  ///
  /// # 为什么它是**全局能力**而不是播放页能力
  ///
  /// 手机端搜到片子时，客户端**可能还停在首页**（用户根本没打开过任何视频）。
  /// 此时 `execPlayer` 不存在（播放页没挂载），
  /// 而 `play_item` 的语义是「**打开**这个片子」，本质是**导航**。
  ///
  /// # 原版的实测背景（这是一个真 bug）
  ///
  /// 原实现把 `play_item` 归到播放控制类，于是**在首页时被静默跳过**：
  /// ```text
  /// POST /api/cmd {kind:play_item}  → 200 {"ok":true}
  /// 5 秒后 /api/state               → title="" has_media=false   ← 没动
  /// ```
  /// 用户看到的就是「手机点了搜索结果没反应」。
  ///
  /// ★ **本条已实现**（2026-09-25 更正）
  ///
  /// 曾经这里写着「尚未实现，见文件末『未实现』一节」——
  /// 那是**过时的注释**：文件末从来没有那一节，而实现已经接上了：
  /// ```text
  /// shell.dart  RemoteCapabilities.globalsFor(openItem: _openItemFromRemote)
  /// shell.dart  _openItemFromRemote —— 补详情 → 取剧集 → push 播放页
  /// 本文件      case 'play_item': → 调 g.openItem
  /// ```
  /// ⚠️ **不写具体行号**：注释里的行号会随编辑漂移，
  ///    而漂移后的行号比没有行号更糟（它看起来精确，实际指错地方）。
  ///    要定位就搜上面那几个符号名。
  /// 之所以**保留可空**（而不是改成 required）：`GlobalBridge` 也被测试与
  /// 探针构造，它们不需要导航能力；传 null 时 `play_item` 会**如实记日志**
  /// 而不是静默丢弃（见 `case 'play_item'` 里的 else 分支）。
  ///
  /// 回归由 `test/remote_bridge_test.dart` 的
  /// 「★ play_item 不能依赖播放页（原版真 bug）」守着 ——
  /// 它断言 `case 'play_item':` 出现在 `final p = _player;` **之前**。
  final Future<void> Function(String provider, String id, String? title)?
      openItem;

  /// ★★ 直播切频道（task-39 新增）
  ///
  /// `+1` 下一个、`-1` 上一个；**循环**语义由直播页实现
  /// （最后一个 +1 回到第一个 —— 见 `LivePageState.cycleChannel`）。
  ///
  /// # 为什么是"相对步进"而不是"下发频道 id"
  /// ```text
  /// 手机端看到的频道列表可能已经过期（用户在客户端换了源/刷新了列表）。
  /// 发"下一个"则天然安全：客户端拿**自己**当前的列表算下一个 ——
  /// 快照过期最多是"点了个已经不在的台"，那是个无害的 no-op。
  /// ★ 与 `MoveProvider { delta }` 同一个理由。
  /// ```
  ///
  /// 为 null（不在直播页）时**如实记日志**，不静默丢弃
  /// （照 `play_item` 的做法 —— 原版那里踩过"命令被静默跳过"的坑）。
  final void Function(int delta)? liveChannelStep;
}

/// 播放中的轮询间隔
///
/// 原版注释：
/// > 实测：**800ms 太慢**。遥控是"按一下希望立刻有反应"的交互，
/// > 最坏情况要等整整一个间隔才轮到取命令，体感是"卡了"。
/// > 400ms 时最坏延迟 0.4s，体感接近即时 —— 而 IPC 成本可以接受
/// > （`remote_take_commands` 是个队列读取，实测单次 <2ms）。
const _tickPlayingMs = 400;

/// 未播放时的间隔 —— 手机端只需要知道「有没有在播」，不需要高频
const _tickIdleMs = 2500;

/// **遥控还没开**时的复查间隔
///
/// # 为什么是 5 秒（而不是"干脆不查"）
///
/// 见 [_ensurePolling] 的长注释：原设计在"没开"时**完全不挂定时器**，
/// 于是应用启动（那时遥控必然还没开）之后桥**永久死亡** ——
/// 用户必须重启应用才能用遥控。
///
/// 5 秒是有意的折中：
/// ```text
/// 原版反对的「无条件轮询」  = 2 次 IPC / 0.8 秒 ≈ 2.5 次/秒
/// 这里的复查              = 1 次 IPC / 5   秒 = 0.2 次/秒   ← 慢 12 倍
/// ```
/// 代价可忽略（`remote_status` 实测 <2ms），换来的是
/// **遥控开启后最多 5 秒内必定自动接上**，不需要任何手动唤醒。
const _tickDisabledMs = 5000;

/// 遥控桥（单例）
///
/// ⚠️ 做成单例是**刻意的**：轮询状态（`_lastSig` / `_timer` / `_inflight`）
///    必须全局唯一。如果每次 mount 都造一个实例，会出现**两套轮询同时跑**
///    （表现为 IPC 次数翻倍，正是原版那个"卡顿"的成因之一）。
class RemoteBridge {
  RemoteBridge._();

  static final RemoteBridge instance = RemoteBridge._();

  // ── 轮询状态 ──

  Timer? _timer;
  bool _inflight = false;
  bool _stopped = false;

  /// 上一次上报的状态签名 —— 没变就不重复发
  String _lastSig = '';

  /// 缓存的**内容源列表**（手机端「内容源顺序」面板的数据源）
  ///
  /// ⚠️ 它**不属于** `_player.getState()` —— 见 [_refreshProviders] 的说明。
  List<Map<String, dynamic>> _providersJson = const [];

  /// 内容源列表的签名（变了才重发状态）
  String get _providersSig => _providersJson
      .map((e) => '${e['id']}:${e['enabled']}:${e['name']}')
      .join('|');

  /// 还有几个 tick 才去刷新内容源列表
  ///
  /// # 为什么不是每个 tick 都刷（原版"操作十分卡顿"的同一个教训）
  ///
  /// 刷新要两次 IPC（`get_provider_order` + `list_providers`）。
  /// 每个 tick 都刷就是**每 400ms 两次额外 IPC** —— 与文件头记的
  /// 那个性能教训一模一样。
  ///
  /// 但也不能只刷一次：用户在**客户端设置页**改了顺序/启用状态时，
  /// 手机端要能跟上。所以按 tick 计数**低频**刷新：
  /// 播放中约 3.2 秒一次，空闲约 20 秒一次 —— 对"设置"这种低频操作足够。
  int _providersTick = 0;

  GlobalBridge? _globals;
  PlayerBridge? _player;

  /// 桥是否在轮询（供界面显示「遥控已连接」）
  ///
  /// 用 `ValueNotifier` 而不是普通字段 —— 设置页要跟着显示状态。
  final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  // ── ★ 内容源顺序的读写（**测试接缝**）──
  //
  // # 为什么需要它（照 `ProxyCache.overrideFetchers` 的同一套理由）
  //
  // `move_provider` 的硬判据是「**写出去的顺序真的变了**」。但如果这里
  // 写死调 `SourinApi.setProviderOrder`，那在 `flutter test` 里
  // **根本跑不起来**（没有 `sourin_core.dll`）—— 于是测试只能退化成
  // 「断言源码里出现了 `setProviderOrder` 这几个字」，那是**恒真**的废断言
  //（本项目已经踩过至少四次这种"假绿"）。
  //
  // 做成可替换的之后，测试就能：
  // ```text
  // ① 塞一个假的读/写（内存里维护一份顺序 + 自己计数）
  // ② 真的喂一条 move_provider 命令进去
  // ③ 断言假写入**收到了换位后的列表**   ← 这才是真的在测排序
  // ```
  //
  // ⚠️ 生产路径**永远**是默认值（真 `SourinApi` 调用）——
  //    只有测试会替换它，且必须在 tearDown 里还原。
  static Future<List<String>> Function() _readOrder = SourinApi.getProviderOrder;
  static Future<List<String>> Function(List<String>) _writeOrder =
      SourinApi.setProviderOrder;

  /// 替换内容源顺序的读/写实现（**只给测试用**）
  ///
  /// 传 null 的项恢复成真实的 `SourinApi` 调用。
  @visibleForTesting
  static void overrideProviderOrderIO({
    Future<List<String>> Function()? read,
    Future<List<String>> Function(List<String>)? write,
  }) {
    _readOrder = read ?? SourinApi.getProviderOrder;
    _writeOrder = write ?? SourinApi.setProviderOrder;
  }

  /// 直接执行一条命令（**只给测试用**）
  ///
  /// # 为什么需要一个 public 入口
  ///
  /// `_execCommand` 是私有的，测试调不到 —— 而「`move_provider` 到底有没有
  /// 被分发到、分发到之后顺序有没有变」**只能在真实的分发路径上验证**。
  /// 只断言"源码里有 `case 'move_provider':`"是**文本匹配**，
  /// 它证明不了那条 case 真的可达（比如被前面的 `return` 挡住了）。
  @visibleForTesting
  Future<void> execCommandForTest(RemoteCommand c) => _execCommand(c);

  /// 最近一次 tick 的统计（诊断用）
  ///
  /// 原版是靠"数 IPC 次数"发现卡顿的；我们把计数留下来，
  /// 这样以后也能在不接调试器的情况下看空转情况。
  int tickCount = 0;
  int reportCount = 0;
  int takeCount = 0;

  /// 注册全局能力（在应用启动时调一次，整个会话有效）
  ///
  /// 注册的同时**启动轮询** —— 桥的职责是「整个会话的遥控开关」，
  /// 所以它该在应用起来时就跑，而不是等用户点开某个视频。
  void setGlobals(GlobalBridge g) {
    _globals = g;
    _stopped = false;
    _lastSig = '';
    unawaited(_ensurePolling());
  }

  /// 注册播放页能力（进播放页时调，离开时 [clearPlayer])
  void setPlayer(PlayerBridge b) {
    _player = b;
    _lastSig = '';
    unawaited(_ensurePolling());
  }

  /// 离开播放页：撤掉播放能力，但**桥继续跑**（搜索还能用）
  ///
  /// ⚠️ 原版注释专门澄清过这个区别：
  /// > 与旧版的区别：以前离开播放页会调 `stopRemoteBridge()`，
  /// > 于是「在首页时遥控全废」。现在离开播放页只需
  /// > `clearPlayerBridge()`，桥要继续跑（搜索要用）。
  ///
  /// # ★ 为什么要传 `b`（2026-09-25 加）
  ///
  /// 天真版是"无条件置 null"，但那会在**换页重叠的瞬间**误伤：
  /// ```text
  /// 用户在播放页 A 点了另一个片子
  ///   → 新播放页 B 的 initState 先跑  → setPlayer(B)
  ///   → 旧播放页 A 的 dispose 后跑    → clearPlayer()  ← 把 B 清了！
  /// ⇒ 手机上立刻又变成"没有播放器"
  /// ```
  /// 所以传进"要注销的那一个"，只在**桥持有的确实是它**时才清。
  /// 传 `null` 时保持旧的"无条件清"语义（测试与探针用得上）。
  void clearPlayer([PlayerBridge? b]) {
    if (b != null && !identical(_player, b)) return;
    _player = null;
    _lastSig = '';
  }

  /// ★ 设置页开启遥控后调用 —— 唤醒轮询
  ///
  /// 没有这个的话，用户「先开应用、再去设置开遥控」的路径下，
  /// 桥已经判定「遥控没开」而不轮询了，必须重启应用才生效。
  void notifyEnabled() {
    if (_stopped) return;
    _lastSig = '';
    unawaited(_ensurePolling());
  }

  /// 彻底停掉桥（**只在应用退出时调**）
  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    active.value = false;
  }

  // ── 内部实现 ──

  /// 确认遥控开着，然后开始轮询；没开就**慢速复查**
  ///
  /// # ★★ 为什么"没开"时要复查（2026-09-25 修 —— 这是一个真 bug）
  ///
  /// 原实现是 `if (!st.running) { return; }` —— **不挂任何定时器**。
  /// 看起来是省电的好设计（原版实测过"无条件轮询时没开也在每 800ms
  /// 发两次 IPC"），但它有一个致命副作用：
  ///
  /// ```text
  /// 应用启动时遥控必然还没开（Rust 侧是异步自启的，见 state.rs ⑫）
  ///   → _ensurePolling 早退，_timer 保持 null
  ///   → 之后**再没有任何东西**会调 _ensurePolling()
  ///     （setGlobals/notifyEnabled 只在 RemoteBridgeHost.initState 调一次）
  /// → 桥从启动到退出，_tick() 执行 0 次
  /// → remote_take_commands() 从不被调 → 手机发的命令**永远躺在队列里**
  /// → 用户看到：手机上点了没反应、搜索永远"没有找到结果"
  /// ```
  /// **这就是「遥控只在重启后才生效」的根因。**
  ///
  /// # 修法：把"不挂定时器"改成"挂一个**慢速**复查"
  ///
  /// ```text
  /// 遥控没开 → 每 5 秒问一次「开了没」（1 次 IPC / 5 秒）
  /// 遥控一开 → 立刻转入正常轮询（400ms）
  /// ```
  ///
  /// # 与原版教训的关系（**不矛盾**）
  ///
  /// 原版那条教训反对的是「**无条件**按 800ms 轮询」，即
  /// `2 次 IPC / 0.8 秒 ≈ 2.5 次/秒`。这里的复查是
  /// `1 次 IPC / 5 秒 = 0.2 次/秒` —— **慢 12 倍还只发一半的调用**，
  /// 而且它带来的是"遥控从此不可能再失联"。
  ///
  /// ⚠️ 这个取舍是**有意的**：原设计的"完全不轮询"会让桥永久死亡，
  ///    而"每 5 秒问一句"最多浪费一次本地 FFI 调用（实测 <2ms）。
  ///    宁可多问一句，也不能让用户的遥控整场失效。
  Future<void> _ensurePolling() async {
    if (_timer != null || _stopped) return;
    try {
      final st = await SourinApi.remoteStatus();
      if (!st.running) {
        active.value = false;
        _scheduleRecheck();
        return;
      }
    } catch (_) {
      // 遥控服务没开时这里会失败 —— 静默降级，但**仍要复查**
      active.value = false;
      _scheduleRecheck();
      return;
    }
    if (_stopped) return;
    _schedule(_tickPlayingMs);
  }

  /// 遥控没开时的**慢速复查**（不是轮询 —— 见 [_ensurePolling] 的说明）
  ///
  /// 与 [_schedule] 分开是为了让"省电的慢速"与"正常轮询的快"在
  /// 代码上就看得出一区别，避免以后有人把复查的间隔也改成 400ms。
  void _scheduleRecheck() {
    if (_stopped || _timer != null) return;
    _timer = Timer(const Duration(milliseconds: _tickDisabledMs), () {
      _timer = null;
      unawaited(_ensurePolling());
    });
  }

  /// 用 `Timer` 链而不是 `Timer.periodic` —— 间隔可以随状态动态调整
  void _schedule(int delayMs) {
    if (_stopped || _timer != null) return;
    _timer = Timer(Duration(milliseconds: delayMs), () {
      _timer = null;
      unawaited(_tick());
    });
  }

  Future<void> _tick() async {
    if (_stopped || _globals == null) return;

    // 上一次还没回来就跳过这一轮（避免请求堆积）
    if (_inflight) {
      _schedule(_tickIdleMs);
      return;
    }
    _inflight = true;
    tickCount++;

    var playing = false;
    try {
      /*
       * ★ 状态上报：**没有播放页时也要报**
       *
       * 报的是「无媒体」。不报的话手机会一直显示上次的标题与进度，
       * 用户以为还在播（实际播放页早关了）。
       */
      final st = _player?.getState() ?? RemoteState.idle();
      playing = st.playing;

      /*
       * ★★ 内容源列表（手机端「内容源顺序」面板的数据源）
       *
       * # 为什么要独立于播放状态准备
       *
       * `st` 是**播放页**的状态，没有播放页时是 `RemoteState.idle()`。
       * 而内容源顺序是**全局设置** —— 与在播什么无关。
       * 用户在首页（甚至没打开过视频）时手机上照样该能排序，
       * 所以列表不能依赖 `_player`。
       *
       * # 为什么低频刷新（每 8 个 tick）
       *
       * 刷新要两次 IPC（`get_provider_order` + `list_providers`）。
       * 每个 tick 都刷 = **每 400ms 两次额外 IPC** ——
       * 正是文件头记的那个「操作十分卡顿」的成因。
       * 播放中 8 个 tick ≈ 3.2 秒、空闲 ≈ 20 秒，对"设置"足够。
       */
      if (_providersTick > 0) {
        _providersTick--;
      } else {
        _providersTick = 7; // 下次再等 8 个 tick
        await _refreshProviders();
      }

      // 1) 状态**变了才**上报（省掉大量无意义的 IPC）
      final s = '${_sig(st)}#$_providersSig';
      if (s != _lastSig) {
        _lastSig = s;
        reportCount++;
        await SourinApi.remoteReportState(_stateJsonWithProviders(st));
      }

      // 2) 取命令并执行（这一步每次都要做 —— 命令低频但不可丢）
      takeCount++;
      final cmds = await SourinApi.remoteTakeCommands();
      var movedProvider = false;
      for (final raw in cmds) {
        final c = RemoteCommand.fromJson(raw);
        try {
          await _execCommand(c);
          // ★ 排序命令要立刻回报（见下面那段的长注释）
          if (c.kind == 'move_provider') movedProvider = true;
        } catch (e) {
          // 单条命令失败不影响后续 —— 遥控场景下「尽力执行」比中断好
          debugPrint('[REMOTE] 命令执行失败 ${c.kind}: $e');
        }
      }

      /*
       * ★★ 执行完命令后**立即重报一次状态**
       *
       * # 为什么需要这一步（原版实测量到的延迟）
       *
       * 原先的顺序是「先报状态、再取命令」，而报状态用的是
       * **本 tick 开始时**的快照 —— 所以命令的效果要到**下一个 tick**
       * 才被报出去。原版实测延迟：
       * ```text
       * skip_toggle_auto → 3.15s 后状态才变
       * skip_config_open → 3.67s
       * skip_confirm     → 3.94s
       * ```
       * 对遥控来说太慢了：用户按一下开关，要等 3 秒手机上才更新，
       * 会以为"没点上"然后反复按。
       *
       * ⚠️ 只在**真的执行了命令**时才多做这一次，空 tick 不额外增加 IPC。
       */
      if (cmds.isNotEmpty && _player != null) {
        final fresh = _player!.getState();
        _lastSig = '${_sig(fresh)}#$_providersSig'; // 先更新签名，避免下一步重复上报
        reportCount++;
        await SourinApi.remoteReportState(_stateJsonWithProviders(fresh));
      }

      /*
       * ★★ 排序命令：**必须立刻**把新顺序回给手机
       *
       * # 为什么单列一段（这是一个真会发生的时序问题）
       *
       * 手机端点完 ↑↓ 后会等 `ORD_WAIT_MS = 2600ms` 确认「服务端顺序
       * 真的变了」，没等到就**回滚 + 提示「未生效」**（见 page.html
       * 的 `moveProvider`）。
       *
       * 而源列表默认是**每 8 个 tick** 才刷新一次（空闲时约 20 秒）——
       * 远超那 2600ms 的确认窗口。结果就是：**排序其实成功了，
       * 但手机上每次都显示「未生效」**，用户以为坏了。
       *
       * 所以排序命令要**立刻**刷新并回报，把那 8 个 tick 的等待消掉。
       * ⚠️ 这段**不依赖 `_player`** —— 排序是全局设置，
       *    用户在首页（没在播）时手机上照样要能看到结果。
       */
      if (movedProvider) {
        _providersTick = 7; // 刚刷过，把下一次常规刷新推后
        await _refreshProviders();
        final st2 = _player?.getState() ?? RemoteState.idle();
        _lastSig = '${_sig(st2)}#$_providersSig';
        reportCount++;
        await SourinApi.remoteReportState(_stateJsonWithProviders(st2));
      }

      active.value = true;
    } catch (_) {
      /*
       * 遥控服务没开/已关闭时这里会失败 —— 静默降级，并且**放慢**轮询
       * （不停止：用户可能在设置页刚开启，我们不想让他必须重启应用）
       */
      active.value = false;
    } finally {
      _inflight = false;
    }

    // 播放中跟得紧一点，没播时慢一点（省 CPU 与 IPC）
    _schedule(playing ? _tickPlayingMs : _tickIdleMs);
  }

  /// ★ 刷新内容源列表（低频），供状态上报带上
  ///
  /// # 为什么它必须独立于播放状态
  ///
  /// 手机端 `page.html` 的「内容源顺序」面板读的是 `state.providers`。
  /// 而那个面板的语义是「**全局**的内容源先后」—— 与当前在播什么无关。
  ///
  /// 若只在有播放页时才准备它，那么**没打开视频时 `providers` 永远是空的**
  /// → 手机上那块面板整块隐藏（`renderOrd` 里 `list.length === 0` 就
  /// `return`）—— 而"想排序"这个需求，用户恰恰常常是在**没在播的时候**
  /// 才想起的（在设置里整理源的时候）。
  ///
  /// # 为什么复用 `remote_report_state` 而不是新加一个 FFI 命令
  ///
  /// Rust 的 `RemoteState` 本来就有 `providers` 字段
  ///（`#[serde(default)]`，见 `rust/sourin_core/src/remote/mod.rs`）——
  /// 它**就是**为这件事加的。再加一条 `remote_report_providers`
  /// 等于同一条通道开两个口子，而且要多改 `ffi.rs` / `commands_remote.rs`。
  /// 一套通道、一个 payload，与文件头的设计原则一致。
  ///
  /// # 上报形状（必须与 Rust 的 `ProviderEntry` 逐字对齐）
  ///
  /// ```json
  /// [{"id":"cycani","name":"次元城","enabled":true}]
  /// ```
  Future<void> _refreshProviders() async {
    try {
      final ids = await _readOrder();
      final list = await SourinApi.listProviders();
      final byId = {for (final p in list) p.id: p};

      /*
       * ⚠️ 按 `ids` 的顺序生成，**不是**按 `listProviders` 的顺序 ——
       *    后者是 registry 的注册顺序，与用户排的顺序可能不同。
       *    手机端看到的顺序必须与设置页一致。
       *
       * 不在 `ids` 里的源（新装还没进顺序文件）追加到末尾，
       * 与后端 `reorder()` 的"稳定排序"语义一致。
       */
      final out = <Map<String, dynamic>>[];
      for (final id in ids) {
        final p = byId[id];
        out.add({
          'id': id,
          'name': p?.name ?? id,
          'enabled': p?.enabled ?? true,
        });
      }
      for (final p in list) {
        if (ids.contains(p.id)) continue;
        out.add({'id': p.id, 'name': p.name, 'enabled': p.enabled});
      }

      _providersJson = out;
    } catch (e) {
      /*
       * 拉不到就保持上一次的（**不清空**）——
       * 清空会让手机上的排序面板突然消失，看起来像坏了。
       */
      debugPrint('[REMOTE] 内容源列表刷新失败（保持上次的）: $e');
    }
  }

  /// 把内容源列表**挂进**要上报的状态 JSON
  ///
  /// ⚠️ 在 `remote_bridge.dart` 里挂、而不是改 `models.dart` 的 `toJson()`：
  ///    `RemoteState` 是**播放页**的状态模型（它连源列表这个概念都没有），
  ///    而内容源顺序是全局的。挂在这里两者的边界才清楚。
  Map<String, dynamic> _stateJsonWithProviders(RemoteState st) {
    final j = st.toJson();
    j['providers'] = _providersJson;
    return j;
  }

  /// 分发一条命令
  ///
  /// # 分类原则（照抄原版）
  ///
  /// ```text
  /// ① 查询类（query_search / query_home）—— 与播放页无关，优先处理
  /// ② play_item —— **导航**语义，也不依赖播放页
  /// ③ 播放控制类 —— 需要播放页；没有播放器时如实记日志，不静默丢
  /// ```
  Future<void> _execCommand(RemoteCommand c) async {
    final g = _globals;
    if (g == null) return;

    /*
     * ★ 查询类命令**与播放页无关**，优先处理
     *
     * 这两类是「用户在手机上想找片」，跟当前有没有在播没关系。
     */
    switch (c.kind) {
      case 'query_search':
        final kw = c.keyword ?? '';
        if (kw.isNotEmpty) await g.search(kw);
        return;

      case 'query_home':
        await g.loadHome();
        return;

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★ `next_channel` / `prev_channel`：直播切频道（task-39 新增）
       * ══════════════════════════════════════════════════════════════
       *
       * 用户原话：
       * > 在直播页面  应该可以往下循环切换直播，并且可以在遥控上控制
       *
       * # ★★★ 为什么**不复用** `next_episode`
       * ```text
       * ① 语义不同：`next_episode` 绑播放器的 `_episodes`（点播剧集）
       *    直播页没有 `_episodes`，它有的是**频道列表**
       * ② 边界相反：`next_episode` 在最后一集**什么都不做**
       *    而 `next_channel` 在最后一个频道要**回到第一个**（用户说"循环"）
       * ⇒ 复用会让 `_gotoNextEpisode` 被迫理解双语义
       *   （"别把两件事塞进一个判据"）
       * ★ 详细论证写在 Rust 侧 `RemoteCommand::NextChannel` 的注释里。
       * ```
       *
       * # 为什么它也在「全局能力」这一组（不依赖播放页）
       * ★ 关键：**直播页现在有内嵌播放器**，但用户可能还没选频道，
       *   或者干脆没在播放页 —— 那两个 case 下"切频道"应该是
       *   "让直播页选下一个台"（而不是被静默跳过）。
       * ⇒ 归到 `execPlayer` 那组的话，`_player == null` 时会被丢弃。
       *
       * ⚠️ 所以这个 case **必须**在 `final p = _player;` 之前。
       */
      case 'next_channel':
        final fwd = g.liveChannelStep;
        if (fwd == null) {
          debugPrint('[REMOTE] 收到 next_channel 但没有注册 liveChannelStep'
              '（可能不在直播页）');
          return;
        }
        fwd(1);
        return;

      case 'prev_channel':
        final back = g.liveChannelStep;
        if (back == null) {
          debugPrint('[REMOTE] 收到 prev_channel 但没有注册 liveChannelStep'
              '（可能不在直播页）');
          return;
        }
        back(-1);
        return;

      /*
       * ★ `play_item`：**不依赖播放页**
       *
       * 手机端在搜索结果里点一个片子，发的是 `play_item`。
       * 若归到「播放控制类」（要求 execPlayer 存在）——
       * 而 execPlayer 只在**播放页挂载时**才注册 ——
       * 于是用户在首页时点手机搜索结果 → 命令被静默跳过。
       *
       * 原版实测证据：
       * ```text
       * POST /api/cmd {kind:play_item}  → 200 {"ok":true}   ← 服务端收下了
       * 5 秒后 /api/state               → title="" has_media=false  ← 客户端没动
       * ```
       */
      case 'play_item':
        final open = g.openItem;
        if (open == null) {
          debugPrint('[REMOTE] 收到 play_item 但没有注册 openItem');
          return;
        }
        await open(c.provider ?? '', c.id ?? '', c.title);
        return;

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★ `move_provider`：遥控端调整**内容源顺序**
       * ══════════════════════════════════════════════════════════════
       *
       * # 为什么它也在「全局能力」这一组（不依赖播放页）
       *
       * 与 `play_item` 同理：内容源的先后是**全局设置**，
       * 跟当前在播什么、有没有在播**毫无关系** ——
       * 用户在首页（甚至没打开过任何视频）时，手机上照样该能排序。
       *
       * 归到下面「需要播放器」那一组的话，`_player == null` 时会被
       * 静默跳过 —— 那正是原版 `play_item` 踩过的坑
       *（见上面 `case 'play_item'` 的实测证据）。
       *
       * ⚠️ 所以这个 case **必须**在 `final p = _player;` 之前 ——
       *    由 `test/remote_bridge_test.dart` 的
       *    「★ move_provider 不能依赖播放页」守着。
       *
       * # wire 格式（**扁平**，与 Rust 的 `MoveProvider` 逐字对应）
       *
       * ```text
       * {"kind":"move_provider","id":"cycani","delta":-1}   ↑ 上移一格
       * {"kind":"move_provider","id":"cycani","delta": 1}   ↓ 下移一格
       * ```
       * `id` 是内容源 id，`delta` 是**相对**位移（负数上移、正数下移）。
       *
       * # 为什么是「相对一格」而不是手机端下发完整顺序
       *
       * 手机端看到的是**上一次轮询的快照**，可能已经过期（用户刚在
       * 客户端装/删了一个源）。发完整顺序会把客户端多出来的那个源
       * **静默丢掉**；发「把 X 上移一格」则天然安全 —— 顺序由
       * **客户端自己当前的真相**决定。
       *
       * # 边界（都不许抛、不许崩）
       *
       * ```text
       * delta == 0        → 无操作
       * 第一项再上移       → 越界，静默不动（与 PrevEpisode 同一做法）
       * 最后一项再下移     → 越界，静默不动
       * id 不存在          → 如实记日志后返回（手机端缓存过期，是正常情况）
       * ```
       * ⚠️ 「静默不动」是**有意的**：这不是错误，是用户点到了头 ——
       *    手机上那两个按钮到头本来就会置灰（见 page.html 的 `buildOrd`）。
       */
      case 'move_provider':
        await _moveProvider(c);
        return;
    }

    /*
     * 播放控制类：需要播放页
     *
     * ⚠️ 没有播放器时要**明确记日志**，不能静默丢 ——
     *    静默丢弃的表现是「手机点了没反应」，最难查。
     */
    final p = _player;
    if (p == null) {
      debugPrint('[REMOTE] 收到播放命令但当前没有播放器: ${c.kind}');
      return;
    }
    await p.exec(c);
  }

  /// ★ 遥控端「上移 / 下移某个内容源」的落地实现
  ///
  /// # 为什么换位逻辑写在这里，而不是让 Rust 侧直接改顺序
  ///
  /// Rust 侧**只做透传**（`RemoteCommand::MoveProvider` 只是入队，
  /// 见 `rust/sourin_core/src/remote/mod.rs`）—— 因为顺序的真相在
  /// **前端的 registry** 里：
  /// ```text
  /// get_provider_order → registry.reorder(saved)  ← 会对齐到**实际注册的源**
  /// set_provider_order → registry.reorder(ids) + save_order  ← 落盘
  /// ```
  /// 若 Rust 自己算好新顺序再下发，就绕开了这两条路径：
  /// ```text
  /// · 内存里的 registry 顺序不会变 → 设置页仍显示旧顺序
  /// · 前端下次上报时又把旧顺序推回去 → 用户看到"排了没用"
  /// ```
  /// 所以这里**复用现成的两个命令**，与设置页的排序弹窗走**同一条路**
  ///（`settings_page.dart` 的 `_openOrderDialog` 也是 `setProviderOrder`）。
  ///
  /// # 为什么用 `getProviderOrder()` 而不是手机端传来的顺序
  ///
  /// 手机端那条命令里**只有 `id` 和 `delta`**，没有完整列表 ——
  /// 顺序必须现取（这就是"相对移动"设计的好处：不信任过期快照）。
  Future<void> _moveProvider(RemoteCommand c) async {
    final id = c.id ?? '';
    final delta = c.number('delta')?.toInt() ?? 0;

    if (id.isEmpty) {
      debugPrint('[REMOTE] move_provider 缺少 id，忽略');
      return;
    }
    if (delta == 0) return; // 无操作

    try {
      final cur = await _readOrder();

      /*
       * ⚠️ 按 **id 找位置**，不是拿 delta 当索引 ——
       *    手机端的列表可能已过期（装了/删了源），
       *    用 id 定位才能保证移的是**用户指的那一个**。
       */
      final i = cur.indexOf(id);
      if (i < 0) {
        /*
         * id 不存在：**如实记日志**（不是静默丢弃）。
         *
         * 常见成因是手机端缓存过期，属于正常情况，不是错误 ——
         * 但留在日志里才能解释"我点了怎么没动"。
         */
        debugPrint('[REMOTE] move_provider 找不到源「$id」'
            '（手机端列表可能过期，当前 ${cur.length} 个源）—— 忽略');
        return;
      }

      final j = i + delta;
      /*
       * 越界：静默不动。
       *
       * 与 `PrevEpisode` 同一做法 —— 第一集再点上一集，前端拿不到
       * 上一集就什么都不做，**不报错**。用户点到了头不是错误。
       */
      if (j < 0 || j >= cur.length) {
        debugPrint('[REMOTE] move_provider「$id」越界'
            '（$i + $delta 超出 0..${cur.length - 1}）—— 忽略');
        return;
      }

      final next = List<String>.from(cur);
      final tmp = next[i];
      next[i] = next[j];
      next[j] = tmp;

      /*
       * ⚠️ 用**返回值**而不是回显 `next` —— `setProviderOrder` 会对齐到
       *    实际注册的源（可能剔除幽灵项 / 追加新源），返回值才是真相。
       *    与 `settings_page.dart` 里那句注释同一个理由。
       */
      final applied = await _writeOrder(next);

      debugPrint('[REMOTE] move_provider「$id」'
          '${delta < 0 ? "上移" : "下移"}：$i → $j'
          '（已落盘，实际 ${applied.length} 个源）');
    } catch (e) {
      /*
       * 单条命令失败不影响后续 —— 与 `_tick()` 里那条原则一致：
       * 遥控场景下「尽力执行」比中断好。
       */
      debugPrint('[REMOTE] move_provider 执行失败（$id, delta=$delta）: $e');
    }
  }

  /// 把状态压成一个签名，用于「变了才上报」的判断
  ///
  /// ⚠️⚠️ **新加的字段必须同步加到这里** —— 否则那一项变化时签名不变，
  /// 状态永远不会上报给手机端（表现为"手机上看不到刚做的修改"）。
  ///
  /// 原版注释记过这个坑（**踩过两次**）：
  /// > 实测踩到的 bug：加了片头片尾字段后忘了改这里，于是
  /// > `skip_config_open` / `skip_toggle_auto` / `skip_clear` 这三条命令
  /// > 在客户端**实际生效了**（DB 写了、弹窗开了），
  /// > 但手机端状态回传永远是旧值 —— 看起来像"命令没生效"。
  String _sig(RemoteState s) => [
        s.hasMedia ? 1 : 0,
        s.playing ? 1 : 0,
        s.title,
        s.episodeOrder,
        s.episodeCount,
        s.currentSource,
        s.muted ? 1 : 0,
        // 进度按秒取整 —— 亚秒级变化不值得每次都发
        s.position,
        s.duration,
        s.volume,
        s.episodes.length,
        s.sources.length,
        // ★ 片头片尾四项（遥控端靠它们知道"现在是什么情况"）
        s.introSkip ?? '-',
        s.outroSkip ?? '-',
        s.introStart ?? '-',
        s.outroEnd ?? '-',
        s.autoSkip ? 1 : 0,
        s.skipEditing ?? '-',
      ].join('|');
}

// ═══════════════════════════════════════════════════════════════════════
//  现成的全局能力实现（search / loadHome）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要在这里实现，而不是留给调用方
//
// 原版把这两段写在 `App.vue` 的 `setRemoteGlobals({...})` 回调里 ——
// 它们**不碰任何页面**，纯粹是"调 Provider → 整理数据 → 回填给 Rust"。
//
// 放在这里的好处：
// ```text
// ① 挂载方只需一行 `RemoteBridgeHost(child: ...)`，不必自己抄 150 行
// ② 逻辑与桥在同一文件，改协议时不会漏改（原版就是分散两处才出过 bug）
// ```
//
// ⚠️ `openItem` **不在这里** —— 它需要导航能力（要改路由/推播放页），
//    必须由挂载方注入。见 `RemoteCapabilities.globalsFor` 的说明。

/// 遥控回填的条目上限
///
/// 原版是 60 —— 手机屏幕小，再多也滑不完，而且每个条目都要传 JSON。
const _remoteSearchLimit = 60;

/// 遥控流式搜索里「一个源的结果」
///
/// 为什么用类而不是 Record：它要被**反复重算**（每到一个新源就重跑一遍
/// round-robin），用 Record 每次重建可读性差，而这个类只有两个字段。
class _RemoteSearchGroup {
  const _RemoteSearchGroup({required this.provider, required this.items});

  final String provider;
  final List<MediaItem> items;
}

/// 现成的全局能力工厂
abstract final class RemoteCapabilities {
  /// 构造默认的 [GlobalBridge]
  ///
  /// [openItem] 需要调用方提供（导航能力桥不认识页面）；
  /// 传 null 时 `play_item` 会被如实记日志而不是静默丢弃。
  static GlobalBridge globalsFor({
    Future<void> Function(String provider, String id, String? title)? openItem,
    void Function(int delta)? liveChannelStep,
  }) =>
      GlobalBridge(
        search: remoteSearch,
        loadHome: remoteLoadHome,
        openItem: openItem,
        liveChannelStep: liveChannelStep,
      );

  /// 执行全源搜索并把结果**陆续**回填给遥控服务
  ///
  /// # ★★★ 为什么必须流式（2026-09-25 用户报「遥控搜不到、客户端搜得到」）
  ///
  /// 原实现走 `searchAll` —— 它要等**所有源**都返回才给结果：
  /// ```text
  /// 客户端  searchAllStream  → 每搜到一个源就追加显示（首个结果 0.25s）
  /// 遥控    searchAll        → ★ 等全部源跑完（实测「庆余年」24.64s）
  /// ```
  /// 而手机端的等待预算只有 18.2 秒（`page.html` 26 × 700ms）……
  /// 于是**遥控必然先超时**，用户看到「没有找到结果」——
  /// 而同一时刻客户端早就把结果列出来了。
  ///
  /// 改成流式后：**每到一个源就立刻回填**，手机下一次轮询
  ///（≤700ms 后）就能看到 —— 与客户端「搜完一个显示一个」一致。
  ///
  /// # ★ 保留「按轮次交替取」（round-robin）
  ///
  /// 原版注释记录过这个**真 bug**（Owner 搜「从零开始」找不到次元城的番）：
  /// > 原先的写法是外层遍历源、内层遍历条目，凑够 60 条就 `break` 两层循环
  /// > —— 于是**第一个源（央视）用 60 条配额全吃掉了**，
  /// > 次元城的 12 条完全没机会出现。
  /// >
  /// > 而用户搜「从零开始」想找的多半是《Re:从零开始的异世界生活》
  /// > （在次元城），结果满屏都是央视的《老兵你好》之类 ——
  /// > 看着就像「搜索坏了」。
  ///
  /// ★ 流式 + round-robin 的组合方式：**把"已知的源"作为一个整体轮转**。
  /// ```text
  /// 源 A 到了 → [A0]
  /// 源 B 到了 → [A0, B0, A1, B1, ...]      ← 重算，B 立刻加入轮转
  /// 源 C 到了 → [A0, B0, C0, A1, B1, C1...] ← C 也加入
  /// ```
  /// 全部源都到齐时，结果与「一次性 round-robin」**完全相同** ——
  /// 所以既拿到了增量效果，又没改变最终顺序语义。
  static Future<void> remoteSearch(String keyword) async {
    /*
     * ★ 走可注入的接缝（见 [overrideSearchIO]）——
     *   生产路径**永远**是真实的 `SourinApi` 调用。
     */
    final stream = _searchStream ?? SourinApi.searchAllStream;
    final setSearch = _setSearch ?? SourinApi.remoteSetSearch;

    /*
     * 每个源一份"可轮转的游标"。
     *
     * ⚠️ 用 `List` 而不是 `Map` —— **到达顺序**要保留（轮转按这个顺序走）。
     */
    final groups = <_RemoteSearchGroup>[];

    /// 按当前已知的源重算轮转结果并回填给遥控服务
    Future<void> flush() async {
      final items = <Map<String, dynamic>>[];

      /*
       * 游标从 0 开始临时走一遍，**不改动 groups 里保存的 cursor** ——
       * 每次 flush 都要能从头上重算（否则第二次 flush 会接着上次的位置，
       * 前面的结果就丢了）。
       *
       * 内层每轮每个源取 **1** 条 —— 1 条最公平，也不会让某个源刷屏
       *（原版定的是 `PER_ROUND = 1`）。
       */
      final cursors = List<int>.filled(groups.length, 0);
      var progress = true;
      while (items.length < _remoteSearchLimit && progress) {
        progress = false;
        for (var i = 0; i < groups.length; i++) {
          if (items.length >= _remoteSearchLimit) break;
          if (cursors[i] >= groups[i].items.length) continue;
          final it = groups[i].items[cursors[i]];
          cursors[i]++;
          progress = true;
          items.add({
            'provider': groups[i].provider,
            'id': it.id,
            'title': it.title,
            if (it.cover != null) 'cover': it.cover,
            if (it.note != null) 'subtitle': it.note,
          });
        }
      }

      await setSearch({'keyword': keyword, 'items': items});
    }

    try {
      await stream(keyword, (ev) {
        switch (ev.kind) {
          case SearchEventKind.hit:
            if (ev.items.isEmpty) return true;
            groups.add(_RemoteSearchGroup(provider: ev.provider, items: ev.items));
            /*
             * ★ 立刻回填 —— 不 await（回调是同步的，返回 bool）。
             *
             * 手机上每 700ms 轮询一次，所以它能"陆续看到结果越来越长"。
             * 不 await 是安全的：`remoteSetSearch` 只是把 payload 存进
             * Rust 的 Mutex，多次并发调用最多是"后写的赢"，
             * 而我们的 items 是**单调增长**的 —— 后写的一定更全。
             */
            unawaited(flush());
            return true;

          case SearchEventKind.miss:
            // 单个源失败不影响其他 —— 与客户端的错误隔离策略一致
            debugPrint('[REMOTE] 源 ${ev.provider} 未返回: ${ev.reason}');
            return true;

          case SearchEventKind.done:
          case SearchEventKind.error:
            return true;
        }
      });

      // 收尾再写一次（拿到**最终**的完整轮转结果）
      await flush();
      final total = groups.fold<int>(0, (n, g) => n + g.items.length);
      debugPrint('[REMOTE] 搜索「$keyword」流式回填完成：'
          '${groups.length} 个源 / $total 条原始结果（轮流取，上限 $_remoteSearchLimit）');
    } catch (e) {
      /*
       * ⚠️ 失败也要**回填**（空结果 + 关键词）
       *
       * 原版注释：
       * > 不回填的话手机端会一直轮询到超时，用户以为是卡住了。
       *
       * ⚠️ 流式下还有一层：可能**已经有部分源回填过了**。
       *    这时不能再写空列表 —— 那会把已经显示出来的结果擦掉。
       */
      debugPrint('[REMOTE] 搜索失败: $e');
      if (groups.isEmpty) {
        await setSearch({
          'keyword': keyword,
          'items': const <Map<String, dynamic>>[],
        }).catchError((_) {});
      }
    }
  }

  /// 刷新首页并把区块回填给遥控服务
  ///
  /// # 两个上限（都是原版定的，理由照抄）
  ///
  /// ```text
  /// 每区块 20 条 —— 手机屏幕小，给太多反而难滑
  /// 最多 8 个区块 —— 手机端是纵向列表，再多要滑很久；
  ///                  更重要的：**每个区块都是一次网络请求**，
  ///                  全拉一遍在电视盒子上要好几秒，用户在手机上等不起
  /// ```
  static Future<void> remoteLoadHome() async {
    try {
      final groups = await SourinApi.getHome();
      final sections = <Map<String, dynamic>>[];

      for (final g in groups) {
        for (final sec in g.sections) {
          /*
           * 首页区块内容是**按类型分别拉**的（`getHome()` 只给分区骨架）。
           *
           * ⚠️ 判据必须与首页保持一致 —— 两边不一致会出现
           *    「电视上有这个区块、手机上没有」的怪现象。
           *    只有 `category` / `rank` 两种需要预取，其余
           *    （custom/static/recent）由各端自行处理。
           */
          List<MediaItem> items = const [];
          try {
            if (sec.source.isCategory && sec.source.categoryId != null) {
              items = (await SourinApi.getList(
                g.provider,
                sec.source.categoryId!,
              ))
                  .items;
            } else if (sec.source.isRank && sec.source.rankId != null) {
              items = (await SourinApi.getRank(g.provider, sec.source.rankId!))
                  .items;
            }
          } catch (_) {
            // 单个区块失败不影响其他 —— 与客户端的错误隔离策略一致
            continue;
          }
          if (items.isEmpty) continue;

          sections.add({
            'title': sec.title.isEmpty ? sec.id : sec.title,
            'items': [
              for (final it in items.take(20))
                {
                  'provider': g.provider,
                  'id': it.id,
                  'title': it.title,
                  if (it.cover != null) 'cover': it.cover,
                  if (it.note != null) 'subtitle': it.note,
                },
            ],
          });
          if (sections.length >= 8) break;
        }
        if (sections.length >= 8) break;
      }

      await SourinApi.remoteSetHome({'sections': sections});
      debugPrint('[REMOTE] 首页回填 ${sections.length} 个区块');
    } catch (e) {
      debugPrint('[REMOTE] 首页加载失败: $e');
      // 同上：失败也要回填，否则手机端一直转圈
      await SourinApi.remoteSetHome({'sections': const <Map<String, dynamic>>[]})
          .catchError((_) {});
    }
  }

  // ── ★ 搜索的两个接缝（**只给测试用**）──
  //
  // 与 `RemoteBridge.overrideProviderOrderIO` 同一套理由：
  // `remoteSearch` 直接调 `SourinApi.*` 的话，`flutter test` 里
  // **根本跑不起来**（没有 `sourin_core.dll`），于是"流式有没有真的
  // 边搜边回填"就只能靠**文本断言** —— 那证明不了回调真的被调用，
  // 更证明不了回填是**多次且递增**的。
  //
  // 注入之后测试能：
  // ```text
  // ① 塞一个假的流（按顺序吐 3 个源，每个 2 条）
  // ② 断言 setSearch 被调了 **3 次以上**，且条数是 2 → 4 → 6 递增
  // ```
  // ← 这才是「手机上陆续看到结果」的硬判据。

  /// 可注入的流式搜索（默认 = 真实的 `SourinApi.searchAllStream`）
  static Future<void> Function(
    String, bool Function(SearchStreamEvent), {
    int page,
  })? _searchStream;

  /// 可注入的"回填搜索结果"（默认 = 真实的 `SourinApi.remoteSetSearch`）
  static Future<void> Function(Map<String, dynamic>)? _setSearch;

  /// 替换搜索的两个接缝（**只给测试用**，传 null 还原成真实实现）
  @visibleForTesting
  static void overrideSearchIO({
    Future<void> Function(
      String, bool Function(SearchStreamEvent), {
      int page,
    })? stream,
    Future<void> Function(Map<String, dynamic>)? setSearch,
  }) {
    _searchStream = stream;
    _setSearch = setSearch;
  }
}

/// ★ 可挂载的宿主 widget —— **让别人一行接上，不用改 shell.dart**
///
/// # 为什么做成 widget 而不是让调用方直接调 `setGlobals`
///
/// 原版在 `App.vue` 的 `onMounted` 里注册（Vue 的生命周期）。
/// Flutter 侧如果也要求"某处记得调 `setGlobals`"，
/// 就会有一个**隐式契约**：漏掉它遥控就完全没反应，而且没有任何报错。
///
/// 做成 widget 后：
/// ```dart
/// MaterialApp(
///   builder: (context, child) => RemoteBridgeHost(child: child!),
/// )
/// ```
/// **挂上就有遥控**，卸载自动停 —— 契约是显式的、编译期可见的。
///
/// # 挂在哪里
///
/// 必须在 `MaterialApp.builder`（Navigator **外面**）——
/// 与自绘标题栏同理：挂在某个页面里的话，切页就没了。
///
/// ⚠️ 但**不能重复挂**（比如 builder 里挂一次、home 里又挂一次）：
///    那会造成两个 `RemoteBridgeHost` 同时 `setGlobals`，
///    虽然单例桥能容忍（后注册的覆盖），但两个 `dispose` 会互相干扰。
///    一个应用只挂一处。
class RemoteBridgeHost extends StatefulWidget {
  const RemoteBridgeHost({
    super.key,
    required this.child,
    this.globals,
  });

  final Widget child;

  /// 全局能力（搜索 / 首页 / 打开条目）
  ///
  /// 允许外部注入是为了**可测性**：测试里塞一个假的就能验证桥的行为，
  /// 不必真的起 HTTP 服务。
  final GlobalBridge? globals;

  @override
  State<RemoteBridgeHost> createState() => _RemoteBridgeHostState();
}

class _RemoteBridgeHostState extends State<RemoteBridgeHost> {
  @override
  void initState() {
    super.initState();
    final g = widget.globals;
    if (g != null) {
      RemoteBridge.instance.setGlobals(g);
    } else {
      /*
       * 没注入 globals 时也要**唤醒轮询** ——
       *
       * 否则「应用起来时遥控已经开着」的路径下桥不会跑，
       * 用户必须去设置页点一下（或被 notifyEnabled 唤醒）才生效。
       *
       * 这里用 `notifyEnabled()` 而不是 `setGlobals(...)`：
       * 它只唤醒轮询、不覆盖已注册的能力。
       */
      RemoteBridge.instance.notifyEnabled();
    }
  }

  @override
  void dispose() {
    /*
     * ⚠️ 这里**不**调 `RemoteBridge.instance.stop()`。
     *
     * 理由：`RemoteBridgeHost` 可能因为热重载 / 页面重建而被短暂 dispose，
     * 停掉桥之后**没人会重新启动它**（`_stopped = true` 是终态）——
     * 表现为"遥控用着用着就死了"，而且不可恢复。
     *
     * 桥的生命周期应当与**进程**一致（单例），宿主只负责"注册能力"。
     * 真要停只在应用退出时 —— Flutter 侧没有可靠的退出钩子，
     * 进程结束自然就停了。
     */
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
