// ═══════════════════════════════════════════════════════════════════════
//  ★★★ task-58：合并页 —— 「上播放器 + 下详情」（Owner 裁决）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 的三条裁决（2026-09-26，不要重新设计）
//
// ```text
// ① 布局：**上播放器 + 下详情**（B站那种）
// ② 全屏：**全屏时只剩视频**，退出后回到合并页
// ③ 旧详情页：**完全去掉**，所有入口（首页卡片/搜索/追更/浏览）直接进合并页
// ```
//
// # 为什么是"组合"而不是"重写"
//
// 播放器（`player_page.dart` 8172 行）与详情（`detail_page.dart`）都已各自被
// 真机验证过。重写任何一边都会把那些验证作废。
// ⇒ 本页只负责**两件事**：布局（上下分栏）与**会话转发**（详情区点选集 ⇒
//   对**同一个**播放器下命令，而不是 push 一个新路由）。
//
// # ★★★ 布局的硬约束（有实测读数，改结构前必读）
//
// 「全屏时只剩视频」**不能**写成"切换父级"：
// ```dart
// ✗ _fullscreen
//     ? playerWidget                                        // 父级 = 根
//     : Column(children: [SizedBox(child: playerWidget), …]) // ★ 父级变了
// ```
// 因为 `Player` 在 `_PlayerPageState.initState` 里创建
// （`player_page.dart` L1253 `_player = Player(`）⇒
// **父级一变 ⇒ Element 卸载 ⇒ 新 State ⇒ 重建播放器**
// ⇒ 症状是"全屏后黑屏/重新加载"，而且极难归因。
//
// ⇒ 正确写法：**类型与位置恒定**，只改 flex 与"详情区在不在"：
// ```dart
// Column(children: [
//   Expanded(flex: videoFlex, child: playerWidget),   // ← 恒定，不换父级
//   if (!fullscreen) Expanded(flex: detailFlex, child: detailWidget),
// ])
// ```
//
// ★ 实测依据（`test/t58_embed_layout_test.dart`，5/5 通过，1280×800）：
// ```text
// [EMBED] 内层 Scaffold(播放器) = (0,0)-(1280,360)    ← 尊重 SizedBox 约束
// [EMBED] 控制条 = (0,304)-(1280,360)                 ← 贴在视频区底部
// [EMBED] 详情区 = (360)-(800)                        ← 紧接视频区、占满剩余
// [FULL]  视频盒 = (0,0)-(1280,800)                   ← 全屏态铺满
// [STATE] 窗口态 initState = 1 → 全屏态 initState = 1  ← ★ State 复用（不重建播放器）
// [STATE-反面] 换父级 ⇒ identical(currentState) = false ← 证明仪器有区分力
// ```
//
// # 全屏怎么检测（★ 不是读 PlayerPage 的私有 `_fullscreen`）
//
// `PlayerPage` 全屏时调 `windowManager.setFullScreen(true)`
// （`player_page.dart` L4675）—— 那是**窗口级**状态，本页用 `WindowListener`
// 监听（与 `window_frame.dart` 同一手法）。
// ⇒ 两页**不需要互相知道对方的私有状态**，耦合最小。
//
// ⚠️ 不用"窗口尺寸 == 屏幕尺寸"去猜：`isWindowFullscreen` 的注释明确写过
//    那是**有缺陷的判据**（任何"窗口恰好等于屏幕"的场合都会误判）。
//    事件来源是**结构性**的，比尺寸推断可靠。
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../core/models.dart' show Episode, MediaDetail;
import '../core/sourin_api.dart' show SourinApi;
import 'detail_page.dart';
import 'media_session.dart';
import 'player_page.dart';
import 'tokens.dart';
import 'widgets/window_frame.dart' show isWindowFullscreen;

/// 合并页 —— 上播放器 + 下详情
class MediaPage extends StatefulWidget {
  const MediaPage({
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
    this.isTv = false,
    this.isTouchOnly = false,
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
  final bool isTv;
  final bool isTouchOnly;

  @override
  State<MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<MediaPage> with WindowListener {
  /// ★ 取播放器 State 的通道
  ///
  /// `PlayerPage` 的 State 类型是**私有**的（`_PlayerPageState`），
  /// 但它 `implements MediaSession`（公开接口）⇒ 用 `State<PlayerPage>`
  /// 拿句柄、再**向上转型**到 `MediaSession`。
  /// ⇒ 本页只依赖"能换会话"这一件事，不依赖播放器的任何内部细节。
  final GlobalKey<State<PlayerPage>> _playerKey =
      GlobalKey<State<PlayerPage>>();

  /// ★ m01887 第③条（2026-10-04）：窄档（手机竖屏）的**视频区高度**
  ///
  /// # 为什么从「9:11 定比例」改成「按画面宽高比算高」
  ///
  /// Owner 原话（配截图）：
  /// > 手机端这个播放详情下面还是有很多留白，选集区域太矮，操作太麻烦
  ///
  /// 真机几何实测（`.probe/android_fix/p1_media.png`，360×800dp，emulator-5554）：
  /// ```text
  /// [MEDIA] build: mq=360.0x800.0 wide=false detailW=340
  /// [DETAIL] 选集之上实测高 = 382.0px ⇒ 选集视口 148.0px
  /// 9:11 ⇒ 视频 360 / 详情 440
  /// 详情内容想要 382 + 24（`Sp.x6`）+ 64（`Sp.x16`）+ 148（`kEpsViewportH`）= 618 > 440
  /// ⇒ `Flexible` 把选集网格夹到 440 − 382 − 24 − 64 = **−30 ⇒ 0px**
  /// ⇒ ★ 手机上「选集」标题以下**全被裁掉**（截图里只剩标题的上半截）
  ///
  /// ⚠️ `Sp.x6=24` / `Sp.x16=64` 不是猜的：`detail_page.dart:343-350`
  ///   `episodeViewportHeight()` 逐字就是 `rest = availH - topH - Sp.x6 - Sp.x16`，
  ///   它被 `t61_panel_scroll_test.dart:157` 与 `t64_panel_fixed_test.dart:400`
  ///   钉住 ⇒ **不许改那个函数**，只能喂给它更多 `availH`。
  /// ```
  ///
  /// # 修法
  ///
  /// 视频区按**画面本身的宽高比**（16:9）算高，详情区吃掉剩下的全部：
  /// ```text
  /// 360×800 ⇒ 视频 202.5 / 详情 597.5
  ///           ⇒ 选集网格 597.5 − 382 − 24 − 64 = **127.5px**（原来 0px）
  ///             行高 30.7 + 行距 16.3 ⇒ 约 **2.9 行**可见且**内部可滚**
  /// ⚠️ 127.5 仍 < 148 下限 ⇒ 下限**没有**被突破，只是不再是"负数"；
  ///   这也意味着**不许**为了凑满 148 去动 `episodeViewportHeight`。
  /// ```
  ///
  /// ★ 上限 45% 屏高：极矮窗口下不许视频把详情挤没。
  ///   ⚠️ 这条上限让**横向窄窗口的几何逐像素不变**：
  ///   `800×800 ⇒ min(450, 360) = 360` —— 与原来的 9:11（800×9/20）**完全相同**
  ///   ⇒ 只有"比 1.25:1 更高"的竖屏手机才会走到新分支。
  /// ★ 下限 120px：再矮就连播放器控制条都放不下。
  static double _narrowVideoHeight(Size size) {
    final byAspect = size.width * 9 / 16;
    final cap = size.height * 0.45;
    final h = byAspect < cap ? byAspect : cap;
    return h < 120 ? 120 : h;
  }

  /// 窗口是否全屏（**结构性来源**：`windowManager` 的事件）
  bool _windowFullscreen = false;

  /// ★ 当前在看的作品 —— 换源会改它，所以**不能**直接用 `widget.provider/id`
  ///   （它们是 final）。与 `player_page` 的 `_provider`/`_contentId` 同一理由。
  late String _provider = widget.provider;
  late String _contentId = widget.id;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // 进来时同步一次（可能从别处已经全屏了）
    unawaited(_syncFullscreen());
    /*
     * ★★★ 等播放器挂上后注册"全屏变化"回调（`MediaSession` 的权威来源）
     *
     * ⚠️ 必须等**第一帧之后** —— 那时 `_playerKey.currentState` 才有值。
     *    在 `initState` 里直接读会拿到 null（子节点还没 build）。
     */
    WidgetsBinding.instance.addPostFrameCallback((_) => _bindPlayerCallbacks());
  }

  /// 把"全屏变化"回调注册到播放器上（幂等）
  ///
  /// # 为什么需要这个（真机实测的教训）
  ///
  /// 播放器是**子**节点 ⇒ 它 `setState` 不会让本页重建 ⇒
  /// 本页读 `isFullscreen` 拿到的还是旧值 ⇒ 详情区不收起来。
  /// 所以由播放器**主动**通知（见 `_toggleFullscreen` 里的 `_onFullscreenChanged`）。
  ///
  /// ⚠️ 重试**必须有上限**：`_session` 为 null 时若无限重排 postFrame，
  ///    会变成"每帧都排一帧"的空转（CPU 白烧，且日志被刷爆）。
  ///    ★ 我的第一版就是无上限递归 —— 它只在"播放器永远挂不上"时才发作，
  ///      而那正是最难注意到的情况。这里用 `_bindAttempts` 封顶。
  void _bindPlayerCallbacks() {
    if (!mounted) return;
    final s = _session;
    if (s == null) {
      _bindAttempts++;
      if (_bindAttempts > 5) {
        /*
         * ★ 不静默 —— 否则"全屏后详情区不收"会变成一个没有任何线索的现象。
         *   真机实测的教训：我第一版的全屏判据坏了，日志里**什么都没有**，
         *   只能靠"[MEDIA] 进入全屏"的**缺失**来反推。
         */
        debugPrint('[MEDIA] ★ 播放器始终未挂上（已试 $_bindAttempts 次）⇒ '
            '放弃注册全屏回调：全屏时将退化为"尺寸兜底"判据');
        return;
      }
      debugPrint('[MEDIA] 播放器尚未挂上 ⇒ 下一帧再试（第 $_bindAttempts 次）');
      WidgetsBinding.instance.addPostFrameCallback((_) => _bindPlayerCallbacks());
      return;
    }
    s.onFullscreenChanged = (full) {
      if (!mounted) return;
      debugPrint('[MEDIA] 播放器通知：全屏=$full '
          '⇒ ${full ? "收起详情区（只剩视频）" : "恢复合并页"}');
      /*
       * ★ 记进"显式来源"（权威），**不是**去改 `_windowFullscreen`
       *   —— 后者是尺寸兜底的缓存，两者不能混（否则又多一个第二真相）。
       */
      setState(() => _explicitFullscreen = full);
    };

    /*
     * ★★★ 2026-09-26 第二轮：注册"当前集变化"回调
     *
     * # 为什么需要它（Owner 原话）
     *
     * > 加一个剧集自动滚动到当前观看剧集位置的功能，当然进入到这个页面
     * > **上一集 下一集**，也都要自动联动滚动到当前剧集到可视区域
     *
     * 详情页的 `_activeEpisodeId` 只由"用户点了哪一集 / 上次观看记录"决定，
     * 它**感知不到**播放器自己切了集 ⇒ 按「下一集」后高亮不动、也不滚动。
     * ⇒ 由播放器**主动**通知（与 `onFullscreenChanged` 完全同构的理由：
     *   子节点 `setState` 不会让父节点重建）。
     *
     * ⚠️ 这里**只存起来**（`_currentEpisodeId`），真正的"滚动到那一集"由
     *    `DetailPage` 自己做 —— 因为**滚动是详情页内部的事**
     *    （它有自己的 `ScrollController`，见那里的注释：
     *     必须只滚选集那个，不得动外层 ListView）。
     */
    s.onEpisodeChanged = (epId) {
      if (!mounted) return;
      if (epId == _currentEpisodeId) return;
      debugPrint('[MEDIA] 播放器通知：当前集=$epId ⇒ 转给详情区（高亮 + 滚入可视区）');
      setState(() => _currentEpisodeId = epId);
    };

    /*
     * ★★★ 注册成功后**必须重建一次**（`test/t58_media_page_layout_test.dart` 抓到的）
     *
     * # 为什么（这是"第二版 bug"的真正机制）
     *
     * 本页的**第一次 build 早于播放器挂载** ⇒ 那一刻 `_session == null`、
     * `_explicitFullscreen == null` ⇒ 只能落到**尺寸兜底**判据。
     * 而 `isWindowFullscreen` 是有缺陷的度量判据（见 `_resolveFullscreen` 的
     * 长注释）：任何"窗口 == 屏幕"的场合都返回 true ⇒ **详情区被误收起**。
     *
     * 若这里不重建，那个**错误的首次求值结果会一直留着** ——
     * 因为之后**没有任何东西**会触发本页重建（播放器 `setState` 不会
     * 让父节点重建）⇒ ★ 症状：**详情区永远不出现**（用户看不到选集/换源），
     * 而且日志里只有一行"⇒ 详情区收起"，看不出是误判。
     *
     * ★ 实测日志（修复前）：
     * ```text
     * [MEDIA] build: mq=800.0x600.0 playerFullscreen=null ⇒ 详情区收起（只剩视频）
     * [MEDIA] 已注册播放器的全屏变化回调（第 0 次尝试）   ← 播放器其实已挂上！
     * [MEDIA] build: … playerFullscreen=null ⇒ 详情区收起（只剩视频）
     * ```
     * ⇒ 注意 `已注册…` 那行说明 `_session` **已经非 null** ——
     *   只要重建一次，`_resolveFullscreen` 就会走"① 问播放器"这条**权威**路径。
     *
     * ⚠️ 用 `setState` 而不是"直接改 `_explicitFullscreen`" ——
     *    因为要的是**重新求值**（让权威来源生效），不是写一个新值。
     */
    if (mounted) setState(() {});

    debugPrint('[MEDIA] 已注册播放器的全屏变化回调（第 $_bindAttempts 次尝试）'
        '⇒ 已触发一次重建，让权威判据取代首次的尺寸兜底');
  }

  /// 注册重试次数（见 `_bindPlayerCallbacks` 的上限说明）
  int _bindAttempts = 0;

  @override
  void dispose() {
    windowManager.removeListener(this);
    /*
     * ★ 注销回调 —— 否则播放器（若比本页活得久）会打到已卸载的 State 上。
     *   虽然回调里有 `mounted` 守卫，但注销是**结构性**的保证，更强。
     */
    final s = _session;
    if (s != null) {
      s.onFullscreenChanged = null;
      // ★ 2026-09-26 第二轮：同一个纪律 —— 也要注销"当前集变化"
      s.onEpisodeChanged = null;
    }
    super.dispose();
  }

  /// ★ 播放器报告的**当前正在播的剧集 id**（`null` = 单集片 / 还没定集）
  ///
  /// # 为什么它必须住在**本页**（而不是详情页自己持有）
  ///
  /// ```text
  /// 真相来源是**播放器**（它在播哪一集，只有它知道）
  ///   ⇒ 详情页**看不到**播放器的私有 state（`_PlayerPageState` 是私有的）
  ///   ⇒ 必须由本页（同时持有播放器与详情区的那一层）**转发**下去
  /// ```
  /// ★ 与 `_explicitFullscreen` 完全同构：一个**显式来源**由回调维护。
  ///
  /// ⚠️ 传给详情区的是 `null` 与"还没收到通知"是**两种不同状态** ——
  ///    所以这里用 `String?` 而不是"空串代表未知"
  ///    （空串在 `Episode.id` 的语义里是"真的没有 id"）。
  String? _currentEpisodeId;

  Future<void> _syncFullscreen() async {
    try {
      final full = await windowManager.isFullScreen();
      if (!mounted) return;
      if (full != _windowFullscreen) {
        setState(() => _windowFullscreen = full);
      }
    } catch (e) {
      debugPrint('[MEDIA] 读全屏状态失败: $e');
    }
  }

  // ── WindowListener：★ 目前在本项目里**不会触发**（见 `_resolveFullscreen`）──
  //
  // 保留它们不是"以防万一" —— 而是因为：
  // ```text
  // ① 它们在 macOS / 有边框窗口上是**会**触发的（插件那边的条件能成立）
  // ② 万一将来 window_manager 修了无边框那条路，这里自动就开始工作
  // ③ 它们是**零成本**的（只是 setState 一次）
  // ```
  // ⚠️ 但它们**不是**判据的来源 —— 判据在 `_resolveFullscreen`（读播放器 +
  //    尺寸兜底）。这里只是"有事件就提前重建一次"，**不写任何状态**
  //    （★ 否则就又多了一个可能过期的"第二真相"）。
  @override
  void onWindowEnterFullScreen() {
    debugPrint('[MEDIA] 收到 enter-full-screen 事件（Windows 无边框下通常不会来）');
    if (mounted) setState(() {});
  }

  @override
  void onWindowLeaveFullScreen() {
    debugPrint('[MEDIA] 收到 leave-full-screen 事件（Windows 无边框下通常不会来）');
    if (mounted) setState(() {});
  }

  /// ★ 当前是否全屏 —— **先问播放器**，尺寸判据只在最后兜底
  ///
  /// # 我第一版错在哪（真机实测抓到的）
  ///
  /// 我用 `WindowListener.onWindowEnterFullScreen` 监听 ⇒ **永远不会触发**：
  /// ```text
  /// window_manager 的 Windows 插件只在 `WM_SIZE` + `SIZE_MAXIMIZED` 时发事件；
  /// 而对**无边框**窗口 `SetFullScreen` 连 `SetWindowPos` 都不调
  /// ⇒ 不产生 SIZE_MAXIMIZED ⇒ 事件永不发出。
  /// 实测：'[MEDIA] 进入全屏' = 0 次，
  ///      而 '[WINDOWFRAME#3] … physical=2560x1440 … => fullscreen=true'
  ///      证明窗口**确实**全屏了
  /// ⇒ 窗口全屏了，合并页却不知道 ⇒ ★ 详情区没收起（判据⑥ FAIL）
  /// ```
  ///
  /// # ★★★ 第二版错在哪（`test/t58_media_page_layout_test.dart` 抓到的）
  ///
  /// 我第二版把"尺寸判据"当成了**并列的兜底**：
  /// ```dart
  /// final fromPlayer = _explicitFullscreen ?? _session?.isFullscreen;
  /// if (fromPlayer != null) return fromPlayer;
  /// return isWindowFullscreen(context);
  /// ```
  /// 而 `isWindowFullscreen` **自己的文档就写了它是有缺陷的判据**
  /// （`window_frame.dart` L221-231，逐字）：
  /// > 它比较的是**同一个 `View`** 的 `physicalSize` 与 `display.size`
  /// > ⇒ 在**任何"窗口恰好与显示同尺寸"的环境**里都会返回 true。
  /// > ⚠️ 这**不是**"测试环境的巧合"，而是**度量判据的结构性缺陷**
  ///
  /// ⇒ 后果在**两个调用点**上**代价完全不同**：
  /// ```text
  /// WindowFrame（决定画不画圆角）  误判 ⇒ 少画一次圆角 ⇒ **只是不好看**
  /// MediaPage（本页，决定详情区在不在）误判 ⇒ 详情区**整块消失**
  ///                                        ⇒ ★ 用户看不到选集/换源/简介，
  ///                                          而且**不知道为什么**
  /// ```
  /// ★ 而我的 widget 测试**当场复现了它**：`flutter_test` 里
  ///   `physicalSize == display.size` ⇒ 尺寸判据恒为 true ⇒
  ///   详情区不在树里 ⇒ `Expected: <2> / Actual: <1>`。
  ///
  /// # 正确顺序：**先问播放器**（它在树里 ⇒ 永远是最新的）
  ///
  /// ```text
  /// ① 播放器就在树里 ⇒ 直接读它的 `isFullscreen`
  ///    ★ 这是**结构性来源**（用户按全屏键的结果），不是度量 ⇒ 无上述缺陷
  /// ② 播放器还没挂上（极短窗口）⇒ 用**通知缓存**过的值（同样来自播放器）
  /// ③ 连缓存都没有 ⇒ 才用尺寸兜底
  /// ```
  /// ★ 与 `WindowFrame` 的 `explicit ?? (filled || size)` **形态同源**，
  ///   但**优先级不同** —— 因为两者的**误判代价不对称**（见上）。
  ///   ⚠️ 这正是"照抄形态"与"照抄语义"的区别：
  ///     **代价不同 ⇒ 优先级必须不同**。
  bool? _explicitFullscreen;

  bool _resolveFullscreen(BuildContext context) {
    // ① 播放器在树里 ⇒ 直接问它（权威，且不依赖通知是否到过）
    final s = _session;
    if (s != null) return s.isFullscreen;
    // ② 播放器还没挂上 ⇒ 用通知缓存（同样来自播放器，权威）
    final cached = _explicitFullscreen;
    if (cached != null) return cached;
    // ③ 最后才用尺寸兜底（★ 它是有缺陷的度量判据，见上）
    return isWindowFullscreen(context);
  }

  /// ★ 当前播放会话（拿不到时返回 null）
  ///
  /// ⚠️ 这里必须**显式转型**：`State<PlayerPage>` 与 `MediaSession` 是
  ///    互不相关的类型（前者是框架基类、后者是我们的接口），
  ///    Dart 的 `is` 在这里**不做类型提升** ⇒ 直接 `return st` 会报
  ///    `A value of type 'State<PlayerPage>?' can't be returned …`。
  ///    （我第一版就是这么写的，`flutter analyze` 当场报出来。）
  MediaSession? get _session {
    final st = _playerKey.currentState;
    if (st is MediaSession) return st as MediaSession;
    return null;
  }

  /// 详情区请求"播这一集 / 换这条线路" ⇒ **对同一个播放器下命令**
  ///
  /// # 为什么是 `applySession` 而不是重新构造一个 `PlayerPage`
  ///
  /// 见 `media_session.dart` 的 `MediaSession` 文档：重建 = 新 State =
  /// 重建播放器 ⇒ 黑屏 + 丢进度。这里走的正是"对同一个 State 下命令"。
  Future<void> _onDetailPlay(PlayRequestData req) async {
    final s = _session;
    if (s == null) {
      /*
       * 播放器还没挂上（极短的窗口：进页第一帧就点了选集）。
       * ★ 不静默 —— 否则用户会觉得"点了没反应"。
       */
      debugPrint('[MEDIA] 播放器尚未就绪 ⇒ 丢弃这次请求 '
          '(${req.provider}:${req.id} ep=${req.episodeId})');
      return;
    }
    debugPrint('[MEDIA] 详情区请求播放 ⇒ 转发给当前播放器 '
        '(${req.provider}:${req.id} ep=${req.episodeId ?? "(无)"} '
        'src=${req.sourceCode ?? "(默认)"})');
    await s.applySession(req);
  }

  /// 详情区"换源"⇒ 在**页内**换（不 pushReplacement）
  ///
  /// # 与旧行为的区别（这是风险⑤）
  ///
  /// 旧实现是 `pushReplacement(_detailRoute(p2, id2))` —— 整页换掉。
  /// 合并页里那个动作会**把播放器一起销毁**（新路由 = 新 `Player`）。
  /// ⇒ 正确做法：把新源当成"一次换会话"，播放器原地换流。
  ///
  /// ⚠️ 换源后 `_provider`/`_contentId` 变了 ⇒ 详情区用 `ValueKey` 重建
  ///    （它要按新源重新拉详情/剧集），而**播放器的 key 是稳定的
  ///    `GlobalKey`** ⇒ 它不会被重建 ✓（这正是"只重建该重建的那一半"）。
  Future<void> _onDetailSwitchSource(String provider, String id) async {
    if (provider == _provider && id == _contentId) return;
    debugPrint('[MEDIA] 详情区请求换源 ⇒ 页内换 '
        '$_provider:$_contentId → $provider:$id');

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-67 需求⑤：把记录**搬到**新源（否则列表里还是旧源）
     * ══════════════════════════════════════════════════════════════════
     *
     * # Owner 原话（逐字）
     * ```text
     * 追更收藏历史，当我换源之后，这三个记录却没有更新，
     * 返回再进去却还是老的源，这也是错误的
     * ```
     *
     * # 根因
     * ```text
     * 四张表（favorites / progress / history / skip_markers）的 key
     * 都是 `<provider>:<id>`（commands_write.rs:42 item_key）
     * 换源 ⇒ provider 变 ⇒ ★ key 变 ⇒ 写入是【新行】，旧行原样留着
     * ⇒ 列表里那一条仍指向**旧源**（点进去是旧源的详情页）
     * ```
     *
     * # ★ 为什么放在 `setState` **之前**
     * ```text
     * `_provider` 一旦被改写，下面就再也拿不到"旧源是谁"了
     * ⇒ 必须在覆盖之前把 from/to 都取出来
     * ```
     *
     * # ★★ 为什么 `await` 它（而不是 `unawaited`）
     * ```text
     * 迁移是一个事务，很快（纯本地 SQLite，无网络）。
     * 而下面紧接着的 `applySession` 会**立刻起播**并**写新进度** ——
     * 若迁移还没做完，新源的 save_progress 可能先落库，
     * 之后迁移再"把旧行合并进新行"就会把刚写的进度覆盖掉。
     * ⇒ 顺序上必须先迁移、后起播。
     * ```
     *
     * # ★★★ 失败**绝不阻断**换源
     * ```text
     * 记录搬不动也得让用户能看 —— 换源本身是用户刚做的动作。
     * ⇒ catch 住 + 如实记日志 + 继续走下面的 applySession
     *   （Lead 裁决："catch 住 + debugPrint 如实记 + 继续走 applySession"）
     * ```
     */
    try {
      await SourinApi.repointItem(
        fromProvider: _provider,
        fromId: _contentId,
        toProvider: provider,
        toId: id,
      );
      debugPrint('[MEDIA] ★ 换源迁移记录完成: '
          '$_provider:$_contentId → $provider:$id');
    } catch (e) {
      /*
       * ★ 不静默：明确说明"记录没搬过去"，但**不中断**换源。
       *   症状会是"列表里仍有一条旧源的记录" —— 有这行日志就能直接定位。
       */
      debugPrint('[MEDIA] ★ 换源迁移记录失败（不阻断换源，列表可能仍显示旧源）: $e');
    }

    if (!mounted) return;

    setState(() {
      _provider = provider;
      _contentId = id;
    });
    /*
     * ★ 换源后**播放器也要跟着换**（否则上面播的还是旧源）。
     *   这里不传 episodes ⇒ `applySession` 里 `_epIndex` 退到 0，
     *   与"没指定就播第一集"一致；等详情区拉到新剧集、用户点某一集时，
     *   会带着新列表再走一次 `_onDetailPlay`（那次才带 episodes）。
     */
    await _session?.applySession(PlayRequestData(
      provider: provider,
      id: id,
      title: widget.title,
      cover: widget.cover,
    ));

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★ 已知边界（Lead 已裁决"记为已知边界"，此处只做**可诊断化**）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 现象
     *
     * 上面那次 `applySession` **没有带 `episodes`**（新源的剧集要等详情区
     * 重新拉一次 `getEpisodes` 才知道）⇒ 在"换源完成"到"新详情加载完"
     * 这**几秒**里，播放器的剧集列表是**空的**：
     * ```text
     * · "下一集"按钮暂时不可用（点了没反应）
     * · 选集面板暂时是空的
     * ```
     *
     * # 为什么**不在这里**修
     *
     * 修它要让"详情区拉到剧集后**回填**给播放器" —— 那需要给
     * `MediaSession` 加一个新方法（"稍后补 episodes"），是**新的接口设计**
     * ⇒ 超出 task-58 的范围，值得单独一个 task。
     *
     * # 但**必须可诊断**（否则用户报"下一集没反应"时无从下手）
     *
     * 真机实测的教训：我第一版的全屏判据坏了，日志里**什么都没有**，
     * 只能靠某行日志的**缺失**来反推 —— 那是最难查的一类。
     * ⇒ 所以这里**明确打一行**：把"已知边界"变成"可诊断的已知边界"。
     *   下次有人报"下一集没反应"，日志会直接说明原因。
     */
    debugPrint('[MEDIA] ★ 换源后 episodes 尚未就绪（新源详情还在加载）⇒ '
        '这期间「下一集」/选集面板暂时不可用（已知边界，非故障）'
        '；详情区拉到剧集后用户点选集即可恢复');
  }

  /// 详情加载完成 ⇒ 把**真标题**转给播放器顶栏
  ///
  /// # 为什么需要这一步（否则顶栏一直是空的）
  ///
  /// 合并页的启动顺序：
  /// ```text
  /// ① `MediaPage` 一构建就创建 `PlayerPage` ⇒ 它**立刻**开始解析流并起播
  /// ② `DetailPage` 随后才异步拉到 `MediaDetail`（要一次 IPC）
  /// ```
  /// 而播放器的顶栏标题来自 `widget.title` ⇒ 第 ① 步那一刻**可能还是空的**
  /// （首页卡片只给了 id，标题要详情才有）。
  ///
  /// ⇒ 详情一拉到就再调一次 `applySession`（会话四元组**全同**）
  ///   ⇒ `PlayerPage.applySession` 的"同一会话"分支**只更新标题、不重启流**
  ///   （那条分支的存在理由就是这件事，见它的注释）。
  Future<void> _onDetailLoaded(MediaDetail d) async {
    debugPrint('[MEDIA] 详情已加载: 「${d.title}」⇒ 转给播放器顶栏');
    /*
     * ★ 用 `updateDisplayTitle`（**不是** `applySession`）——
     *   本方法只补展示信息，绝不能重启流。
     *
     * ⚠️ 我第一版这里调的是 `applySession(PlayRequestData(provider, id, title))`，
     *    而 `episodeId`/`sourceCode` 没传 ⇒ 默认 null ⇒ 与当前会话
     *    （第 N 集 / 某线路）**四元组不同** ⇒ `isSameSessionAs` 判为"换会话"
     *    ⇒ ★ **白重启一次流**（黑屏 + 丢进度）。
     *    这正是"无害动作触发了昂贵副作用"的典型形态 —— 所以拆成两个方法。
     *
     * ★★★ 2026-09-26 第二轮：**必须同时转发 `cover`**（Owner 报的「播放记录 ？」）
     *
     * ```text
     * 不转发 cover ⇒ 播放器永远不知道封面 ⇒ `_saveProgress` 写库时 cover 为 null
     *              ⇒ 播放记录列表没有封面 ⇒ 显示「？」
     * ```
     * 而本方法手里**正好**有 `d.cover` ⇒ 一次送达（理由见 `MediaSession` 的文档）。
     */
    _session?.updateDisplayTitle(d.title, cover: d.cover);

    /*
     * ★★★ 2026-09-26 第二轮：**回填剧集列表**（Owner「上一集 下一集」的前提）
     *
     * # 为什么必须有这一步（真机实测的缺口）
     *
     * ```text
     * 首页入口 `_mediaRoute(provider, id)` **只给 id** ⇒ `widget.episodes` 为空
     * ⇒ `PlayerPage.episodes` 恒为空 ⇒ `_nextEpisode == null`
     * ⇒ ★ 按 N（下一集）**没有任何反应**（真机日志只有"收到 N"就没了）
     * ```
     * ★ 这正是 task-58 记下的**已知边界**（本文件 `_onDetailSwitchSource`
     *   那段长注释逐字写过：「修它要让详情区拉到剧集后**回填**给播放器 ——
     *   那需要给 `MediaSession` 加一个新方法（"稍后补 episodes"）」）。
     *   ⇒ 现在实现了那个方法：`updateEpisodes`。
     *
     * ⚠️ 必须用 `updateEpisodes` 而**不是** `applySession` ——
     *    后者会重新解析流（黑屏 + 丢进度），而这里只是"补列表"。
     */
    _session?.updateEpisodes(d.episodes);
  }

  @override
  Widget build(BuildContext context) {
    /*
     * ★★★ 布局：类型与位置**恒定**（见文件头的硬约束）
     *
     * 视频区永远是 Column 的第 0 个 child；详情区只是"在不在"。
     * 全屏时只剩视频 ⇒ 它自然拿到 100% 高度。
     *
     * ⚠️ 播放器用**稳定的** `GlobalKey` ⇒ 无论 flex 怎么变、
     *    详情区在不在，它的 Element 位置都不变 ⇒ State 复用 ⇒
     *    `Player` 不重建 ✓
     */
    /*
     * ★★★ 注册"窗口尺寸"依赖（**这一行是修复的核心**）
     *
     * `_resolveFullscreen` 的兜底分支用 `isWindowFullscreen(context)`，
     * 那是**尺寸判据**。若不在这里读一次 `MediaQuery`，本页就**不依赖**
     * 窗口尺寸 ⇒ 全屏（= 窗口 resize）时**不会重建** ⇒
     * 判据永远不会被重新求值 ⇒ 详情区永不收起。
     *
     * ⚠️ 这个读取**看起来是多余的**（`_resolveFullscreen` 内部也能拿到
     *    context）⇒ 后人极可能"清理"掉它 ⇒ **bug 静默复发**。
     *    这正是 task-54 踩过的坑，`window_frame.dart` L627 有逐字记录：
     *    「不读 MediaQuery ⇒ resize 时不重建 ⇒ 判据从未被重新求值」。
     *    而 task-54 的 A/B 实测（`.probe/t54_dep_ab.py`）证明过它的必要性。
     *    ★ 所以**保留它**，并留下这条注释。
     */
    final mq = MediaQuery.of(context);
    final fullscreen = _resolveFullscreen(context);
    /*
     * ★ task-59：窗口态**不再**硬编码黑底
     *
     * # 为什么（Owner 原话 + Lead 实测）
     * Owner：「进来之后只有黑色，文字也反色的看不清」
     * Lead 实测（`.probe/ROOTCAUSE-merge-black.md`）：
     *   详情区标题文字最亮像素 = `#1E2028`（= `LightTokens.textPrimary`），
     *   背后背景 = `#000000` ⇒ WCAG **1.29:1**（几乎不可见）；
     *   整页纯黑占比 **66.8%**。
     *
     * # 根因
     * `Colors.black` 是**播放页**的假设（播放页整页都是视频 ⇒ 黑底合理）。
     * 但合并页里 55% 面积是**详情区**，它是用**应用主题令牌**画的
     * （`detail_page.dart` 全部走 `Theme.of(context).colorScheme`）
     * ⇒ 亮色主题下深色文字落在纯黑上 ⇒ 不可见。
     *
     * # 修法
     * ```text
     * fullscreen（整页都是视频）⇒ 仍用 Colors.black ✓（那是对的）
     * 窗口态（有详情区）        ⇒ 用主题的 `surface`
     * ```
     * ⇒ 两种主题下都正确：亮色 ⇒ 浅底深字；深色 ⇒ 深底浅字。
     * ★ 这正是"**用令牌而不是字面量**"那条纪律在页面级底色的应用。
     */
    final surface = Theme.of(context).colorScheme.surface;
    /*
     * ★ task-59：轴向阈值 —— 宽屏左右分栏，窄屏回退上下
     *
     * Owner 要求「参照腾讯视频：**左侧播放器右侧是视频的信息**」。
     * ⚠️ 但手机上左右分栏会把两者都挤到不可用（播放器只剩 ~390px 宽）
     *    ⇒ 所以 <900px 回退**上下**（原 task-58 形态）。
     * ★ 900 这个数与 `live_page.dart` 的窄屏断点**同源**（原版 @media max-width: 900px），
     *   不是随手取的。
     */
    final wide = mq.size.width >= 900;
    /*
     * ★ 右侧信息栏宽度：30% 视口，夹在 [340, 440]
     *   · 下限 340 ⇒ 保证卡片/按钮不被压变形（详情区最小可用宽度）
     *   · 上限 440 ⇒ 超宽屏上不让信息栏无限拉伸（腾讯视频也是定宽侧栏）
     */
    /*
     * ★★★ 2026-10-07 修复：**取整到设备像素**（Owner 报的「右侧卡片两根竖线」）
     *
     * # 现象（Owner 截图 owner2.png 逐像素实测）
     * ```text
     * 1444 宽窗口：x<=1009 全黑（播放器），x=1010 整列灰 (128,129,132)，
     *              x>=1011 是 surface (238,240,246)
     * ⇒ 面板左边那条 1px 灰缝，在上下两个 Radii.lg 圆角缺口处
     *   上下各露一小段 ⇒ 看起来像「两根竖线」
     * ```
     *
     * # 根因
     * ```text
     * 1444 * 0.30 = 433.2（小数）⇒ 面板左边界 = 1444 - 433.2 = 1010.8
     * 落在小数像素上 ⇒ 黑底与 surface 做 AA 混合 ⇒ 半像素灰缝
     * ```
     *
     * # 修法
     * ```text
     * 先把宽度换算成**设备像素**再取整，最后换回逻辑像素：
     *   dpr=1.0  ⇒ 433.2 → 433.0 ⇒ 左边界恰好 1011.0（整数）
     *   dpr=1.25 ⇒ 541.5 → 542   ⇒ 设备像素整数，不会 AA
     * ⚠️ 不能直接 `.roundToDouble()`：那在高 DPR 下仍可能落到半个设备像素。
     * ```
     */
    final double rawDetailW = (mq.size.width * 0.30).clamp(340.0, 440.0);
    final double detailW =
        (rawDetailW * mq.devicePixelRatio).roundToDouble() / mq.devicePixelRatio;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 圆角方向（逐角判断"它紧邻谁"）
     * ══════════════════════════════════════════════════════════════════
     *
     * Owner 第二次指出：
     * > 右边详情右上角还是直角
     *
     * # ★ 我上一次的判据**错了**（这条要记住）
     * ```text
     * 我当时想的是"面板右边 = 窗口边缘 ⇒ 右上角也在窗口边缘上 ⇒ 保持直角"。
     *
     * ✗ 错在：**右上角属于"上边"，不属于"右边"。**
     *   而面板的**上边**紧邻的是**标题栏（黑色，通栏）**，
     *   不是窗口外沿 ⇒ 它与左上角是**同一个处境** ⇒ 必须圆。
     * ```
     * 实测（Owner 截图 1017×861，面板 x[541,924] y[44,820]）：
     * ```text
     * 左上角   y=44 first=562 → y=65 first=541   ✅ 已圆（半径 ≈ 21）
     * 右上角   y=44..65 last=**924 恒定**        ❌ 仍是直角 ← Owner 报的
     * ```
     *
     * # 正确的判据（列出每个角**紧邻什么**）
     * ```text
     * 合并页结构：标题栏（黑，通栏）在上，下面是 Row([视频(黑), 面板])
     *
     * 角          紧邻                          该圆吗
     * topLeft     上=标题栏(黑) 左=视频(黑)      ✅ 永远圆
     * topRight    上=标题栏(黑)                  ✅ 永远圆   ← ★ 这次补上
     * bottomLeft  左=视频(黑)                    ✅ 宽档圆（窄档时它是窗口左下角 ⇒ 不圆）
     * bottomRight 右=窗口边缘 下=窗口边缘        ❌ 永远不圆（那里加圆角会变成
     *                                               "窗口边缘上的黑色缺口"）
     * ```
     *
     * ⇒ ★ 归纳：**"上边两个角"永远圆**（上边永远紧邻标题栏/视频），
     *   **右下角永远不圆**，只有左下角随档位变。
     *
     * ⚠️ 我两次都在"方向"上出错（第一次是窄档圆成对角线，
     *    第二次是把右上角误判成窗口边缘）⇒ **方向判据必须逐角写清"它紧邻谁"**，
     *    不能靠"哪边朝视频"这种整体直觉。
     */
    final roundDetailLeft = wide && !fullscreen;
    /*
     * ★ m01887 第③条：窄档视频区高度（只在本分支用；宽档是 Row，不吃这个）。
     *   推导与实测见 `_narrowVideoHeight` 的注释。
     */
    final videoH = _narrowVideoHeight(mq.size);
    /*
     * ⚠️ 显式打印 `.width x .height`，**不要**直接插值 `mq.size`
     *    —— AOT 构建里它打印成 `Instance of 'Size'`（真机实测），
     *    那样这行日志就失去了"判据输入可读"的作用。
     */
    debugPrint('[MEDIA] build: mq=${mq.size.width}x${mq.size.height} '
        'playerFullscreen=${_session?.isFullscreen} '
        'wide=$wide detailW=${detailW.toStringAsFixed(0)} '
        '⇒ 详情区${fullscreen ? "收起（只剩视频）" : "显示"}');

    final player = PlayerPage(
      key: _playerKey,
      provider: _provider,
      id: _contentId,
      title: widget.title,
      cover: widget.cover,
      episodeId: widget.episodeId,
      episodeTitle: widget.episodeTitle,
      sourceCode: widget.sourceCode,
      episodes: widget.episodes,
      episodeIndex: widget.episodeIndex,
      isTv: widget.isTv,
      isTouchOnly: widget.isTouchOnly,
    );

    // ★ 换源后重建**详情区**（只重建这一半）—— key 与 task-58 逐字相同
    final detail = DetailPage(
      key: ValueKey('detail:$_provider:$_contentId'),
      provider: _provider,
      id: _contentId,
      isTv: widget.isTv,
      // ★ 详情区不再自己 push 播放器 ⇒ 请求交回本页转发
      onPlay: _onDetailPlay,
      onOpenDetail: _onDetailSwitchSource,
      // ★ 详情加载完 ⇒ 把真标题转给播放器顶栏（见 `_onDetailLoaded`）
      onLoaded: _onDetailLoaded,
      // ★ 合并页里详情区**不画返回按钮**（顶层负责返回）
      embedded: true,
      /*
       * ★★★ 2026-09-26 第二轮：把"播放器正在播哪一集"喂给详情区
       *
       * 详情页靠它做两件事（Owner 原话「上一集 下一集，也都要自动联动滚动到
       * 当前剧集到可视区域」）：
       * ```text
       * ① 高亮当前集（原来只认"用户点过哪一集 / 上次观看记录"）
       * ② 把它滚进选集区可视范围
       * ```
       * ⚠️ `null` = "播放器还没报告" ⇒ 详情页应当**回退**到它自己的判断
       *    （`_activeEpisodeId`），**不能**当成"没有当前集"。
       */
      currentEpisodeId: _currentEpisodeId,
    );

    /*
     * ★★★ 2026-09-27 第三轮：详情面板**朝视频那一侧**要圆角
     *
     * # Owner 原话（逐字）
     * > 播放详情页右边也应该圆角，直角看起来不协调
     *
     * # 逐像素实测（Owner 截图 1280×800）
     * ```text
     * 面板占 x[896,1279] y[40,799]
     * 左上 ★ 直角（每行都是 896）   右上 ★ 直角（每行都是 1279）
     * 左下 ★ 直角（每行都是 896）   右下   圆角（那是**窗口自己**的裁剪）
     * ⇒ 三个直角 + 一个圆角 = Owner 说的「不协调」
     * ```
     * ★ 而同一界面里**其它元素都是圆角**：
     * ```text
     * 窗口自身  半径 ≈ 8（Radii.xs）
     * 封面图片  Radii.rLg（`_Cover` 的 ClipRRect）
     * 全应用卡片/大面  Radii.rLg（20 处）/ Radii.rMd（17 处）
     * ```
     *
     * # ⚠️ 只加 `ClipRRect` **不够** —— 圆角会"隐形"
     * ```text
     * 面板后面是 `Scaffold.backgroundColor`，窗口态 = surface（#eef0f6）
     * ⇒ 切掉的那块露出的**还是同色 surface**
     * ⇒ 像素上**什么都不会变**（代码里有圆角，用户看不见）
     * ```
     * ⇒ 必须在面板后面**铺一层黑底**，圆角才可见。
     *   而黑底本来就是对的：面板左/上侧紧邻的正是黑色（播放器 + 标题栏）。
     *
     * ⚠️ **不能**把 `Scaffold.backgroundColor` 改成黑 ——
     *    `t58_media_page_layout_test.dart` 冻结契约要求窗口态必须是
     *    `surface`（那是上一轮「进来之后只有黑色」缺陷的防回归）。
     *    ⇒ 黑底必须是**局部**的，只铺在面板这一块。
     *
     * # 为什么只圆**一侧**（不是四角）
     * ```text
     * 宽档（左右分栏）视频在**左** ⇒ 圆**左**侧两角
     * 窄档（上下分栏）视频在**上** ⇒ 圆**上**侧两角
     * ★ 窗口边缘那一侧保持直角：面板本来就与窗口边缘齐平，
     *   在那里加圆角会变成"窗口边缘上的一个黑色缺口"（像渲染瑕疵）
     * ```
     *
     * # 为什么用 `Radii.lg`（22）
     * ```text
     * ① 本仓"卡片/大面"的约定就是 rLg / rMd
     * ② ★ 直接先例：`live_page.dart` 的右栏正是
     *      ClipRRect(Radii.rLg) + ColoredBox(Colors.black) —— 同一形态
     * ③ 与封面同值（封面也是 rLg）⇒ 内外圆角一致
     * ```
     *
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-27（task-68）Owner 报：浅色模式下右上角**漏出黑色**
     * ══════════════════════════════════════════════════════════════════
     *
     * # Owner 原话（逐字）
     * ```text
     * > 浅色模式下右上角有漏出的黑色,能不能优化优化这个
     * ```
     *
     * # 逐像素实测（Owner 截图，缩放到 1280×800 后量）
     * ```text
     * 黑色区  x[1263..1279] y[40..55]   ← 一个 **16×16 的黑色四分之一圆**
     *    y=40 最左黑 x=1263 → y=55 最左黑 x=1279   ← 弧线，正是右上角的圆角
     * 面板    (1000,200) = #EEF0F6
     * 标题栏  ( 600, 20) = #E7EAF2      ← ★ 浅色
     * ⇒ 黑块紧贴在**浅色标题栏**的下沿
     * ```
     *
     * # 根因：上一轮的"黑底"理由在**合并页**不成立
     * ```text
     * 上一轮为了让圆角"看得见"，在面板后面铺了整块 `Colors.black`，
     * 理由是「面板左/上侧紧邻的正是黑色（播放器 + 标题栏）」。
     *
     * ✗ 其中「标题栏是黑的」**只对播放页成立** ——
     *   `titleBarDark = true` 只在 `player_page.dart` 里设；
     *   而**合并页（本页）的标题栏是浅色液态玻璃**（实测 #E7EAF2）。
     * ⇒ 圆角切掉的那块露出黑底，而它的邻居是浅色标题栏
     * ⇒ 读起来就是"漏出来的一块黑"（Owner 的原话）。
     * ```
     *
     * # 修法：黑底**只铺在紧邻视频（黑）的那条边**
     * ```text
     * 宽档  视频在**左** ⇒ 黑只铺左边一条（宽 Radii.lg）→ 左侧两角"从视频里挖出来"
     * 窄档  视频在**上** ⇒ 黑只铺上边一条（高 Radii.lg）→ 上方两角同理
     * 其余  ⇒ 兜底色 = `surface`（= 面板自己的底色）
     *        ⇒ 右上 / 右下角的缺口与面板同色 ⇒ **不可能"漏黑"**
     * ```
     * ★ 厚度为什么取 `Radii.lg`：缺口本身就是一个半径 `Radii.lg` 的四分之一圆，
     *   铺满这个半径恰好盖住它；多铺无益，反而会在别处露出来。
     *
     * ⚠️ **不能**图省事把黑底整个删掉 —— 那样左侧两角的圆角会**再次隐形**
     *    （切掉那块露出的还是同色 `surface`），
     *    而 Owner 上一轮为"圆角看不见"投诉过**两次**
     *    （见上面 `roundDetailLeft` 的说明）。黑底要留，只是要**留对地方**。
     *
     * ⚠️ 深色主题下这个改动同样正确：标题栏是深色、`surface` 也是深色，
     *    右上角缺口与邻居同色 ⇒ 不漏。
     */
    final detailPanel = DecoratedBox(
      /*
       * ★ 兜底色 = 面板自己的底色（`surface`）
       *
       * 见上面 task-68 的说明：**不能**再整块铺黑 ——
       * 合并页的标题栏是浅色的，黑底会在右上角露出来。
       */
      decoration: BoxDecoration(color: surface),
      child: Stack(
        children: [
          /*
           * ── 黑底：只铺**紧邻视频**的那条边（宽 Radii.lg）──
           *
           * 让那一侧的两个圆角"从视频里挖出来"（可见），
           * 而**另一侧**（紧邻浅色标题栏 / 窗口边缘）不铺黑 ⇒ 不漏。
           */
          Positioned(
            left: 0,
            top: 0,
            // 宽档：视频在左 ⇒ 黑铺左边一条
            // 窄档：视频在上 ⇒ 黑铺上边一条
            bottom: roundDetailLeft ? 0 : null,
            right: roundDetailLeft ? null : 0,
            width: roundDetailLeft ? Radii.lg : null,
            height: roundDetailLeft ? null : Radii.lg,
            child: const ColoredBox(color: Colors.black),
          ),
          ClipRRect(
            borderRadius: BorderRadius.only(
              /*
               * ★ **上边两个角永远圆** —— 上边永远紧邻标题栏（黑，通栏）。
               *
               * ⚠️ 我上一版只圆了 `topLeft`，把 `topRight` 留给"窄档" ——
               *    因为当时以为"面板右边 = 窗口边缘 ⇒ 右上角也在窗口边缘上"。
               *    ✗ 错在：**右上角属于"上边"，不属于"右边"**。
               *    ⇒ Owner 第二次投诉：「右边详情右上角还是直角」
               */
              topLeft: const Radius.circular(Radii.lg),
              topRight: const Radius.circular(Radii.lg),
              // ★ 左下角：宽档时它紧邻视频（黑）⇒ 圆；窄档时它是窗口左下角 ⇒ 不圆
              bottomLeft: Radius.circular(roundDetailLeft ? Radii.lg : 0),
              // ★ 右下角**永远不圆** —— 它落在窗口边缘上，
              //   在那里加圆角会变成"窗口边缘上的一个黑色缺口"（像渲染瑕疵）
              bottomRight: const Radius.circular(0),
            ),
            child: detail,
          ),
        ],
      ),
    );

    return Scaffold(
      // ★ 全屏 = 整页都是视频 ⇒ 黑底正确；窗口态 ⇒ 跟随主题
      backgroundColor: fullscreen ? Colors.black : surface,
      /*
       * ★★★ 「播放器永远是第 0 个 child」—— 这是**硬约束**，不是风格偏好
       *
       * `_playerKey` 是稳定的 `GlobalKey` ⇒ 只要播放器在 child 列表里的
       * **位置**不变，Element 就被复用 ⇒ `Player` 的 State 不重建。
       *
       * ```text
       * 全屏切换：Row 从 [player, detail] 变成 [player]  ⇒ 位置 0 不变 ✓
       * 轴向切换：Row [player, …] ⇄ Column [player, …]  ⇒ 位置 0 不变 ✓
       * ```
       * ⚠️ 若把详情区放到播放器**前面**（或让播放器在 Column 里排第 1），
       *    Element 位置就会变 ⇒ `Player` 被重建 ⇒ **正在播的视频被打断**。
       *    ⇒ `test/t59_media_layout_test.dart` 有一条测试专门证明
       *      「Row↔Column 切换后播放器 State 是**同一个实例**」。
       */
      body: (fullscreen || wide)
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ★ 第 0 个 child（见上面那段硬约束）
                Expanded(
                  flex: fullscreen ? 1 : 3,
                  child: player,
                ),
                // 全屏时**没有**详情区 ⇒ Row 只剩一个 child
                if (!fullscreen) SizedBox(width: detailW, child: detailPanel),
              ],
            )
          : Column(
              /*
               * ⚠️ 本分支只有 `!fullscreen && !wide` 才会走到
               *    （见上面的三目条件）⇒ 详情区**必然**存在 ⇒
               *    这里**不需要** `if (!fullscreen)` 守卫。
               *
               * ★ m01887 第③条：flex 不再写死 9:11，而是由
               *   `_narrowVideoHeight` 按 16:9 算出来的高度换算。
               *   ⚠️ 仍然**必须是 `Expanded`**（第 0 个 child 的"类型与位置恒定"
               *   是 State 复用的前提，见上面的硬约束注释）—— 只是 flex 变成变量。
               *   `Expanded` 只吃整数 ⇒ 两边同乘 10（比例不变，高度精确到 0.1px）。
               */
              children: [
                // ★ 同样是第 0 个 child
                Expanded(
                  flex: (videoH * 10).round(),
                  child: player,
                ),
                Expanded(
                  flex: ((mq.size.height - videoH) * 10).round(),
                  child: detailPanel,
                ),
              ],
            ),
    );
  }
}
