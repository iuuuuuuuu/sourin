// ═══════════════════════════════════════════════════════════════════════
//  播放会话的**契约** —— task-58「合并页」与播放器之间的公共类型
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件（而不是放在 media_page.dart 或 player_page.dart）
//
// ```text
// media_page.dart   → import player_page.dart（要用 PlayerPage）
// player_page.dart  → 需要 PlayRequestData + MediaSession
// ```
// ⇒ 若把契约放在 `media_page.dart`，`player_page.dart` 就得反向 import 它
//   ⇒ **循环依赖**（Dart 允许，但依赖方向反了：低层组件依赖高层页面）。
// ⇒ 所以契约住在**中立位置**：两个方向都只 import 它。
//
// # 与 `detail_page.dart` 的关系（★ 那个文件已退役）
//
// `PlayRequestData` 原来住在 `detail_page.dart`（L56）。
// task-58 之后详情页不再是独立页面 ⇒ 让**新架构**去 import 一个**退役文件**
// 是反向的（"新代码依赖旧代码"）⇒ 搬到这里。
// `detail_page.dart` 改为 `export` 本文件，保持它自己的 import 者不受影响。

import '../core/models.dart';

/// 播放请求 —— 「要播哪一个作品的哪一集/哪条线路」
///
/// ⚠️ 必须把**当前源 + 该源下的剧集列表 + 剧集下标**一起交给播放器：
///    右侧栏的「选集」与「下一集」都依赖它们。若只传单集 id，
///    播放器就无法知道下一集是谁，自动连播无从实现。
class PlayRequestData {
  const PlayRequestData({
    required this.provider,
    required this.id,
    required this.title,
    this.cover,
    this.episodeId,
    this.episodeTitle,
    this.sourceCode,
    this.episodes = const [],
    this.episodeIndex,
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

  /// ★★★ task-12 ④ 改动 B（2026-10-09）：本地文件**绝对路径**（`null` = 走网络解析）
  ///
  /// # 为什么必须进这个「请求」对象（真机缺陷，不是设计洁癖）
  /// ```text
  /// `PlayerPage.localPath` 是**页面级不可变**的：`shell.dart:4773` 一次性决定，
  /// 作构造参数传入。而**换集**走的是「对同一个 State 下命令」：
  ///   media_page._onDetailPlay -> applySession(req)   （不重建页面）
  /// ⇒ 只把路径放在构造参数里，本地会话就只能播「进页面时那一集」；
  ///   用户点右侧第 2 集 => applySession 走网络解析 => 对本地会话报
  ///   「无法路由: local:<路径>」（真机证据，Owner 截图）。
  /// ```
  ///
  /// ⚠️ 只有**本地会话**才非 null：在线作品的换集仍然走 `resolveStream`。
  final String? localPath;

  /// ★ task-58：**会话等价**判据 —— 两个请求是否指向"同一集同一条线路"
  ///
  /// # 为什么需要它
  ///
  /// 合并页里「换源」「选集」「点播放」都会调 `applySession`。若每次都
  /// 无脑重新解析流，用户**点一下已经在播的那一集**也会导致：
  /// ```text
  /// ① 画面黑一下（重新 open）
  /// ② 播放位置丢失（从头开始）
  /// ③ 白耗一次上游请求
  /// ```
  /// ⇒ 所以必须先判"是不是同一个会话"。
  ///
  /// # ⚠️ 判据**不含** `episodes` / `title` / `cover`
  ///
  /// 那些是**展示信息**：同一集的剧集列表多了一集、或标题被上游改了，
  /// 都不该被当成"换了一个会话"（否则每次刷新详情都会重启播放）。
  /// 真正决定"播哪条流"的只有 `provider` / `id` / `episodeId` / `sourceCode`。
  ///
  /// ⚠️ `sourceCode` 用**宽松**比较（null 与空串等价）：调用方一处传
  ///    `_activeSource.isEmpty ? null : _activeSource`、另一处可能传 `''`，
  ///    那是同一个意思。若严格比较 `null != ''`，就会把"同一条线路"
  ///    误判成"换了线路" ⇒ 多一次重启（正是本节要避免的）。
  bool isSameSessionAs(PlayRequestData other) {
    String norm(String? s) => (s == null || s.isEmpty) ? '' : s;
    return provider == other.provider &&
        id == other.id &&
        norm(episodeId) == norm(other.episodeId) &&
        norm(sourceCode) == norm(other.sourceCode) &&
        /*
         * ★★★ task-12 ④ 改动 B（2026-10-09）：`localPath` 也纳入判据。
         *
         * # 为什么**必须**纳入（我按 lead 的意见逐条推导过）
         * ```text
         * 判据的语义是「这两个请求会不会**解析出同一条流**」。
         * 而本地会话的流**完全由 localPath 决定**：
         *   本地文件 A 与 本地文件 B => 两条完全不同的流 => 两个不同会话。
         * 把它们判成「同一会话」的后果与本节开头那三条一样恶劣：
         * 用户点另一个本地文件 => 早退 => **画面根本不变**（连黑屏都没有，纯不动）
         * => 看起来像「点了没反应」。
         * ```
         *
         * # ★ 为什么不与 `episodeId` 混判（lead 特别提醒的点）
         * ```text
         * 「同一个文件换集号」是**合法**的：本地目录里同一集可能有
         *   `第01集.mp4` / `第01集.part` 两个候选（cache_page.dart:141-143
         *   剥 `.part` 后缀时就是这么处理的）=> 路径不同、集号相同。
         * 反过来，**已确认**的两种映射是：
         *   同一文件  => 同一集号（episodeId 由调用方给 fileName）
         *   不同文件  => 不同路径
         * => 两者本来就一致，**不需要**交叉判断（交叉判断只会多一处会漂的逻辑）。
         *    所以这里是**并列**加一个字段，不是把它们合并成一个复合键。
         * ```
         *
         * ⚠️ 用与 `sourceCode` **同款**的宽松比较（null 与空串等价）：
         *   在线会话两边的 localPath 都是 null/'' => 归一后相等 => 判据对
         *   **既有在线路径逐字节不变**（这是零影响的关键）。
         */
        norm(localPath) == norm(other.localPath);
  }
}

/// ★★★ task-58：合并页对「当前播放会话」下命令的**唯一接口**
///
/// # 为什么需要它（而不是重新构造一个 `PlayerPage`）
///
/// `Player` 在 `_PlayerPageState.initState` 里创建
/// （`player_page.dart` L1253 `_player = Player(`）⇒
/// **重新构造 = 新 State = 重建播放器** ⇒ 换源/切集时会黑屏重载。
/// 所以合并页必须"对**同一个** State 下命令"。
///
/// # 为什么是接口而不是直接暴露 State
///
/// `_PlayerPageState` 是私有的。暴露它会把合并页绑死在实现细节上；
/// 用接口则只承诺"能换会话"这一件事
/// （与 `skip_marker_dialog.dart` 的 `SkipPreviewHost` 同一手法：
///  只暴露必要能力，弹窗在类型层面就做不到越界的事）。
///
/// # 实现方必须遵守
///
/// ```text
/// ① 只改"会话相关"的 state，**不得**重建 Player
/// ② 换会话后要重新解析流（走既有的原地换源路径，见 `_resolveAndPlay`）
/// ③ 同一会话（`isSameSessionAs`）必须**早退**，不白重启一次流
/// ```
abstract interface class MediaSession {
  /// 把当前会话换成 [req]（换源 / 选集 / 换集都走它）
  Future<void> applySession(PlayRequestData req);

  /// ★ 只更新**展示用**的元信息（标题 + 封面），**不动流**
  ///
  /// # 为什么必须与 `applySession` 分开（我第一版合在一起，错了）
  ///
  /// 合并页的启动顺序是"**播放器先起播、详情后加载**"：
  /// ```text
  /// ① 一进页就创建 PlayerPage ⇒ 立刻解析流并播（那一刻还不知道标题）
  /// ② 详情随后拉到 MediaDetail ⇒ 这时才拿到真标题
  /// ```
  /// 第 ② 步想做的**只是"把标题补上"**。若它去调 `applySession`：
  /// ```dart
  /// // ✗ 我第一版这么写：
  /// applySession(PlayRequestData(
  ///   provider: _provider, id: _contentId, title: d.title,
  ///   // episodeId / sourceCode 没传 ⇒ 默认 null
  /// ));
  /// ```
  /// 而 `isSameSessionAs` 的四元组**含** `episodeId`/`sourceCode`
  /// ⇒ 当前会话是第 3 集时，`null != "ep3"` ⇒ **判为"换了会话"**
  /// ⇒ ★ **白重启一次流**（黑屏 + 丢进度）—— 正是 `isSameSessionAs`
  ///   想避免的那件事，却被"补个标题"这个无害动作触发了。
  ///
  /// ⇒ 正确做法：**把"改展示信息"与"改会话"分成两个方法**。
  ///   本方法不碰任何流相关状态，因此**不可能**导致重启。
  ///
  /// ⚠️ 实现方只需更新渲染用的标题/封面（以及上报用的），
  ///    **不得**重新解析流、不得重置播放位置。
  ///
  /// # ★ 为什么 `cover` 是**可选命名参数**而不是新方法（2026-09-26 第二轮）
  ///
  /// Owner 报「播放记录多了几个显示 **？** 的记录，没有封面没有名字」。
  /// 根因（`.probe/ROOTCAUSE-panel-and-history.md`）：
  /// ```text
  /// `_saveProgress` 写的是 `widget.title` / `widget.cover` —— **final 构造参数**，
  /// 而合并页的入口 `_mediaRoute()` 传的是 `title: ''`、没有 cover
  ///   ⇒ 那两样**恒为空** ⇒ 写进库就是空标题 + 空封面 ⇒ 列表显示「？」
  /// 而真标题其实**已经到了**（`_onDetailLoaded` ⇒ 本方法 ⇒ `_title`），
  /// 只是 `_saveProgress` 从来没读它；`cover` 则**根本没有转发路径**。
  /// ```
  /// ⇒ 修法是"让展示元信息这一条路**同时**带上封面"。
  ///   用**可选命名参数**（而不是新增 `updateDisplayCover`）的理由：
  /// ```text
  /// ① 标题与封面是**同一次详情加载**的产物 ⇒ 天然应当一次送达，
  ///    分成两个方法会出现"只更新了一个"的中间态（而调用方只有一个）
  /// ② 可选 ⇒ **现有调用点零改动**（`updateDisplayTitle(t)` 仍合法）
  /// ```
  void updateDisplayTitle(String title, {String? cover});

  /// ★★★ 当前是否处于**全屏**（task-58 真机实测后新增）
  ///
  /// # 为什么"全屏"必须问播放器，而不是自己监听窗口事件
  ///
  /// 合并页（`MediaPage`）要"全屏时只剩视频" ⇒ 它必须知道播放器是否全屏。
  /// 我第一版用 `windowManager` 的 `WindowListener.onWindowEnterFullScreen`
  /// 监听 —— **真机实测证明它在本项目里永远不会触发**：
  ///
  /// ```text
  /// window_manager-0.5.2\windows\window_manager_plugin.cpp L291-295：
  ///   } else if (message == WM_SIZE) {
  ///     if (IsFullScreen() && wParam == SIZE_MAXIMIZED && …) {
  ///       _EmitEvent("enter-full-screen");      ← ★ 只在 SIZE_MAXIMIZED 发
  /// 而 window_manager.cpp 的 SetFullScreen 对**无边框**窗口走：
  ///   ::SetWindowPos(mainWindow, HWND_TOP, 0, 0, rcMonitor 的宽高, …)
  ///   ⇒ ★ 直接改尺寸，**不产生 SIZE_MAXIMIZED**
  /// ```
  /// 本项目的窗口是**无边框**的（`WindowFrame` 靠这一点画圆角/投影）⇒
  /// ★★ 事件永远不会发 ⇒ 窗口全屏了但合并页不知道 ⇒ 详情区不收起来。
  ///
  /// # 为什么播放器是**权威来源**
  ///
  /// `PlayerPage` 的 `_fullscreen` 就是"用户按了全屏键"的直接结果
  /// （`_toggleFullscreen` 里 `setState(() => _fullscreen = next)`）——
  /// 它**不依赖任何窗口事件**，所以没有上面那个失效模式。
  ///
  /// ⚠️ 这是**只读**查询：实现方不得因为被读而改变任何状态。
  bool get isFullscreen;

  /// ★★★ 注册"全屏状态变化"的回调（`null` = 注销）
  ///
  /// # 为什么光有 [isFullscreen] 这个 getter 还不够
  ///
  /// `MediaPage` 需要"全屏时收起详情区"，也就是它必须**重建**。
  /// 而 `PlayerPage` 是它的**子节点** —— 子节点 `setState` **不会**
  /// 让父节点重建（Flutter 的正常行为）⇒ 父节点读到的仍是旧值。
  ///
  /// # 两个触发源，都要有（★ 这是"权威 + 兜底"的组合）
  ///
  /// ```text
  /// ① 本通知（权威）：播放器按全屏键时**主动**告诉合并页
  ///    ⇒ 不依赖任何窗口行为 ⇒ 最可靠
  /// ② 尺寸依赖（兜底）：合并页在 build 里读一次 MediaQuery
  ///    ⇒ 窗口 resize 时自动重建（真机实测：全屏会把窗口从
  ///      1280x800 改成 2560x1440 ⇒ 尺寸依赖确实会触发）
  ///    ⇒ 覆盖"从别处全屏进来"/"通知丢失"等边界
  /// ```
  ///
  /// ⚠️ 与 `WindowFrame` 的 `_filled` 同一手法：一个**显式来源**由事件维护，
  ///    未收到时（`null`）落到兜底判据。见 `window_frame.dart` L615。
  ///
  /// ⚠️ 实现方在 `dispose` 时必须**不再调用**它（避免回调打到已卸载的页面上）。
  set onFullscreenChanged(void Function(bool fullscreen)? cb);

  /// ★★★ 当前**正在播**的剧集 id（`null` = 单集片 / 还没定集）
  ///
  /// # 为什么需要它（2026-09-26 第二轮，Owner 原话）
  ///
  /// > 加一个剧集自动滚动到当前观看剧集位置的功能，当然进入到这个页面
  /// > **上一集 下一集**，也都要自动联动滚动到当前剧集到可视区域
  ///
  /// 右侧栏的「选集」是一块**固定高度、可滚动**的区域。当用户按「下一集」时：
  /// ```text
  /// 播放器   _epIndex 变了 ⇒ 换流、播下一集        ✓ 一直是好的
  /// 详情页   _activeEpisodeId **没变** ⇒ 高亮不动、也不滚动   ✗ 这就是缺口
  /// ```
  /// 详情页的 `_activeEpisodeId` 只由"用户在选集里点了哪一集 / 上次观看记录"
  /// 决定 —— 它**感知不到**播放器自己切了集。
  ///
  /// ⇒ 所以要有一个**从播放器到合并页**的"当前集"来源，与
  ///   [isFullscreen] / [onFullscreenChanged] **完全同构**（同一个理由：
  ///   子节点 `setState` 不会让父节点重建）。
  ///
  /// ⚠️ 这是**只读**查询：实现方不得因为被读而改变任何状态。
  String? get currentEpisodeId;

  /// ★★★ 注册"当前剧集变化"的回调（`null` = 注销）
  ///
  /// 触发时机（实现方必须覆盖全部三条，缺一条就会"高亮不跟着走"）：
  /// ```text
  /// ① `applySession` 换了集（用户在选集里点了另一集 / 换源）
  /// ② 「下一集」（含自动连播倒计时结束）
  /// ③ 「上一集」
  /// ```
  ///
  /// ⚠️ 与 [onFullscreenChanged] 同一纪律：`dispose` 时必须注销。
  set onEpisodeChanged(void Function(String? episodeId)? cb);

  /// ★★★ 让详情页把**剧集列表**回填给播放器
  ///
  /// # 为什么需要它（Owner 原话）
  ///
  /// > 加一个剧集自动滚动到当前观看剧集位置的功能，当然进入到这个页面
  /// > **上一集 下一集**，也都要自动联动滚动到当前剧集到可视区域
  ///
  /// 而「上一集/下一集」要能工作，播放器**必须知道剧集列表**。实测：
  /// ```text
  /// 首页入口走 `_mediaRoute(provider, id)` ⇒ 只给 id，**没给 episodes**
  /// ⇒ `PlayerPage.episodes` 恒为空
  /// ⇒ `_nextEpisode` == null ⇒ ★ 按 N（下一集）**没有任何反应**
  /// ```
  /// ★ 这正是 task-58 记下的**已知边界**（`media_page.dart` 里那段长注释）：
  /// ```text
  /// "换源后 episodes 尚未就绪 …… 修它要让'详情区拉到剧集后回填给播放器'
  ///  —— 那需要给 MediaSession 加一个新方法（'稍后补 episodes'），
  ///    是**新的接口设计** ⇒ 值得单独一个 task。"
  /// ```
  /// ⇒ 本方法就是那个"稍后补 episodes"。
  ///
  /// # 为什么**不能**用 [applySession] 代劳
  ///
  /// ```text
  /// `applySession` 会重新解析流（换集/换源语义）⇒ 白重启一次流（黑屏 + 丢进度）
  /// 而本方法只是"把列表补上"，**不换会话、不动流、不重置位置**
  /// ```
  /// ★ 与 [updateDisplayTitle] 同一形态：**只补展示/导航信息，绝不碰流**。
  ///
  /// ⚠️ 实现方必须在**剧集列表真的变了**时才更新（幂等），并在
  ///    更新后触发一次 [onEpisodeChanged]（这样"当前集"能立刻被高亮/滚入视野）。
  void updateEpisodes(List<Episode> episodes);
}
