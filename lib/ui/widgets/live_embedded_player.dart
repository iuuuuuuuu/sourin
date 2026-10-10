// ═══════════════════════════════════════════════════════════════════════
//  直播内嵌播放器（task-39 新增）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 直播页面，所支持的直播列表在左边占满高度，右侧放个播放器
// > 默认选中第一个，默认打开就自动直播开始播放
//
// # ★★★ 为什么**不**复用 `PlayerPage`（lead 裁决设计点 1 = B）
//
// ```text
// PlayerPage = 6502 行，自带 Scaffold / Focus / 进度条 / 选集 /
//              字幕设置 / 片头片尾 / 记忆进度 / 遥控桥 …
// 直播只需要：open(url) → pause / play / dispose
// ```
// 复用意味着要把它改造成"可嵌入模式"（拆 Scaffold + 拆全屏假设），
// **回归面极大**；而直播**根本不需要**进度条/选集/字幕。
//
// ★ 但要处理三个真问题（lead 的三条硬约束）：
// ```text
// 约束 1  保活后切走不销毁 ⇒ 后台继续出声 ⇒ 必须监听可见性并 pause
// 约束 2  音频焦点：内嵌与全屏 PlayerPage **不能同时发声**
//         ⇒ 跳全屏前先 pause 内嵌
// 约束 3  真的 dispose 时必须 release（否则解码器泄漏），且只 release 一次
// ```
//
// # ★ 与 `PlayerPage` 的差异（有意为之，不是漏做）
//
// ```text
// 不做：进度条（直播没有"总时长"）、倍速、选集、字幕轨切换、
//       记忆播放位置（直播没有"上次看到哪"）
// 做  ：播放/暂停、音量、静音、全屏入口、加载/错误态、仅音频提示
// ```
//
// # 关于"仅音频"（cctv 源的实际情况）
//
// ```text
// 实测（.probe/t39_decode_v2.py，ffmpeg 真解码）：
//   cctv 高清线  drm_protected=true   197 帧 / 223 个解码错误  ⇒ 不可播
//   cctv 标清线  连不上（myqcloud 那条 403/超时）
//   cctv 仅音频  ★ 可播（OK(音频)）
// ⇒ ★ cctv 频道**不是"全坏"**，它剩一条能用的音频线
//   ⇒ 所以本页对这类频道**默认隐藏但可展开**（lead 裁决 ②）
//     而不是永久剔除 —— 用户可能就想听广播
// ```

import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../../core/app_log.dart';
import '../../core/models.dart';
import '../../core/ui_prefs.dart';
import '../tokens.dart';

/// 直播内嵌播放器
///
/// ★ 生命周期由外部持有（[LiveEmbeddedPlayerState]）——
///   因为 task-41 的保活会让本页切走也不销毁，
///   播放器的"暂停/续播"必须由**可见性信号**驱动，而不是 widget 生命周期。
class LiveEmbeddedPlayer extends StatefulWidget {
  const LiveEmbeddedPlayer({
    super.key,
    required this.stream,
    required this.title,
    this.subtitle,
    this.audioOnly = false,
    this.onToggleFullscreen,
    this.onError,
    this.onUserPause,
    this.isTouchOnly = false,
    this.visible,
  });

  /// 要播的流；null = 还没选频道 / 正在取流
  final StreamCandidate? stream;

  /// 频道名（右上角显示）
  final String title;

  /// 次要信息（分组 / "仅音频"等）
  final String? subtitle;

  /// 是不是"只有音频线可播"（cctv 的情况）⇒ 显示明确提示，不留黑屏
  final bool audioOnly;

  /// 右上角"全屏"按钮（lead 约束 3：必须保留全屏入口）
  final VoidCallback? onToggleFullscreen;

  /// ★★ 是不是**触摸端**（手机/平板）—— 决定双击的语义（用户要求【B】）
  ///
  /// ```text
  /// 用户原话（第 2 条）：
  ///   「还要支持**双击进入全屏播放**」
  ///
  /// ★ 与播放页**同一套判据**（`PlayerGestures.doubleTapEnabledFor`）：
  ///    PC/TV ：双击 ⇒ 全屏（`onDoubleTap`）
  ///    触摸端：双击 ⇒ **左右快进快退**（`onDoubleTapDown`）—— 不夺走
  ///
  /// ⚠️ 两者**绝不能同时挂** —— `GestureDetector` 的 `onDoubleTap` 与
  ///    `onDoubleTapDown` 是**同一个 DoubleTapGestureRecognizer 上的两个回调**，
  ///    一次双击会**两个都跑**（播放页 L5106-5111 记着同一个坑）。
  /// ⇒ 用本字段三向分流，保证只有一个非 null。
  /// ```
  final bool isTouchOnly;

  /// 起播失败时回调（让外层去挑下一条线路）
  final void Function(String message)? onError;

  /// ★ 用户**自己**按了播放/暂停时上报（true = 他暂停了）
  ///
  /// # 为什么需要
  /// ```text
  /// task-41 保活后，本页切走不销毁 ⇒ 我们在不可见时 pause()，
  /// 切回来时想恢复播放。
  /// ★ 但如果**用户自己**按了暂停，切回来就不该自动播 ——
  ///   那是违背他刚做的操作。
  /// ⇒ 外层用这个回调记住"是用户暂停的"，可见性变化时据此决定。
  /// ```
  final void Function(bool paused)? onUserPause;

  /// ★★ task-74 ⑤ 回归修复：本页是否可见（null = 没有信号 ⇒ 视为可见）。
  ///
  /// # 为什么必须传进来
  /// ```text
  /// 原生重活被延后 380ms 后，`_player` 在这段窗口里是 null
  /// ⇒ `isPlaying`（本类）恒为 false
  /// ⇒ 外层 `lib/ui/live_page.dart` 的 `if (st.isPlaying)` 永不成立、
  ///    `_pausedByHide` 永不置位
  /// ⇒ 380ms 后 `_create()` 会把**已经切走的**页面播起来（有声音）。
  /// 改前这个洞只有几毫秒宽，改后是 380ms
  /// ⇒ 必须由本类自己门控起播。
  /// ```
  final ValueListenable<bool>? visible;

  @override
  State<LiveEmbeddedPlayer> createState() => LiveEmbeddedPlayerState();
}

class LiveEmbeddedPlayerState extends State<LiveEmbeddedPlayer> {
  Player? _player;
  VideoController? _controller;

  bool _ready = false;
  String? _error;
  bool _buffering = false;

  /// ★★ task-91：画面输出层没能初始化
  /// （有视频轨、但 mpv 的 `vo-configured` 不是 yes）
  ///
  /// # 为什么必须有（task-87 在**交付 APK** 上实测到的产品缺陷）
  /// ```text
  /// 同一台机器、同一条流：
  ///   · 全屏 `PlayerPage` **有**看门狗，实测真的触发并渲染出横幅
  ///     （`10-01 01:30:44.293 I/flutter : [PLAYER] ★ 画面输出层未能初始化…`）
  ///   · 内嵌播放器（本文件）**没有**任何等价机制
  /// ⇒ 同机同流黑屏，这里**一句提示都没有**（用户只看到一块黑）。
  /// ```
  ///
  /// ⚠️ 与“起播失败”（[_error]）是**两件事**，不能混：
  ///   起播失败 = 流打不开；本旗标 = **流开好了、声音在放、就是没有画面**。
  ///   ⇒ 所以它**不进** `_error`（那会与“正在播放”互斥）。
  bool _videoOutputDead = false;

  /// ★★ task-91：看门狗代次号（与 `player_page.dart:510` 同一手法）
  ///
  /// 看门狗是个最多跑 10 秒的 `while` 轮询，**没有 Timer 可以 cancel** ——
  /// 它靠代次号自证过期：每轮都查 `token != _videoOutputToken`。
  /// 换台 / 退出 / dispose 时把代次号推进一格，**已在飞行中的那一轮**立刻放弃，
  /// 而不是等它跑完再对着已卸载的 State 调 `setState`。
  int _videoOutputToken = 0;

  /// ★ 已释放标记 —— 保证 `dispose()` 只跑一次（lead 约束 2）
  ///
  /// 为什么要显式标记：`VideoController` + `Player` 都要释放，
  /// 而"切频道"时我们会先释放再重建 ⇒ 容易重复释放。
  /// media_kit 重复 dispose 会抛（或静默损坏原生状态）。
  bool _disposed = false;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;

  /// ★ 2026-10-08（Owner 第 3 条）：流错误订阅（改前直播侧**完全没订**，断声静默）
  StreamSubscription<String>? _errorSub;

  // ★ 2026-10-09：这里**刻意没有** `_volumeSub` ——
  //   加过又撤了，理由见 `_create()` 里那段「刻意不订阅 volume」的注释。
  //   一句话：`pause()` 的自动压 0 与「用户静音」共用同一个信号，
  //   从音量反推静音意图必然误判 ⇒ 会造出「切走回来永久静音」。

  /// ★ task-74 ⑤ 注册值：**380ms** = 300ms 过渡窗 + 80ms 余量。
  ///
  /// 来源：Lead 注册 —— 300ms 是本任务要挪出的窗口上界（切到直播页后
  /// 0~300ms），80ms 是余量，保证重活确实落在窗口之外而不是压在边界上。
  ///
  /// ⚠️ 不许为了"看起来更好"改这个数 —— 它一变，A/B 实测就必须重跑。
  static const Duration _createDelay = Duration(milliseconds: 380);

  /// ★ 延迟窗口内用户换了台 ⇒ 先记住，等播放器建好再补开。
  ///
  /// 改前 `_player` 在 `initState` 的同一帧里就被赋值，所以 `open()`
  /// 几乎不可能看到 `_player == null`；改后这是一条**常规路径**
  /// （见 `open()` 与回归风险 ①）。
  StreamCandidate? _pendingStream;

  /// 延迟建播放器的定时器（`dispose()` 必须取消）。
  Timer? _createTimer;

  /// ★ task-74 ⑤：是否因为“本页不可见”而**抑制**了起播（可见时补播）。
  bool _suppressedStart = false;

  /// ★ task-74 ⑤：当前是否可见（没有信号 ⇒ 视为可见，保持改前行为）。
  bool get _visibleNow => widget.visible?.value ?? true;

  /// ★ task-74 ⑤：可见性变回 true ⇒ 把之前被抑制的起播补上。
  ///
  /// ⚠️ 只补**被抑制的**那种（`_suppressedStart`）——
  ///    “播放中被隐藏”由外层 `live_page.dart` 的 pause() 负责，
  ///    这里**不**碰 `pause()`/`resume()` 的既有语义。
  void _onVisibleChanged() {
    if (!_visibleNow) return;
    if (!_suppressedStart) return;
    _suppressedStart = false;
    final pending = _pendingStream;
    _pendingStream = null;
    debugPrint('[LIVE] 本页恢复可见 ⇒ 补起播');
    unawaited(pending != null ? open(pending) : _openCurrent());
  }

  @override
  void initState() {
    super.initState();
    /*
     * ★★★ task-74 ⑤ 的核心改动：原生重活**不在**这里同步跑
     *
     * 改前是 `_create();` —— 它内部的
     *   `Player(...)` 与 `VideoController(p)`
     * 是**同步**的原生调用（含 D3D11 视频纹理分配），于是"切到直播页"的
     * 首帧就要扛下这段开销 ⇒ 入场突发。
     *
     * 改后：延后 [_createDelay] 再建 ⇒ 过渡窗口（0~300ms）里只画占位
     * spinner（见 `build()` 的 `c == null ||` 分支）。
     *
     * ⚠️ 这到底是**位移**还是**消除**，由 A/B 实测回答（task-74 ⑤ 判据）。
     *    本注释**不**预设结论：重活仍跑在 UI 线程上，只是晚 380ms。
     */
    final t0 = DateTime.now();
    _createTimer = Timer(_createDelay, () {
      _createTimer = null;
      // ⚠️ 窗口内可能已被 dispose（切走 / 换页）⇒ 必须查，
      //    否则建出来的 Player + VideoController 没人释放（原生泄漏）。
      if (_disposed) return;
      /*
       * ★ 打包指纹 + 行为证据（task-74 ⑤）：
       *
       * 这个字符串是**改动确实在二进制里**的静态证据 —— AOT 快照会剥掉
       * 所有标识符名（`_createDelay`/`pendingStreamForTest` 在两臂里都数到 0），
       * 只留字符串字面量（UTF-16LE）。所以"字节数一样"完全不能证明改动进包了。
       *
       * 同时它是**行为**证据：探针会把含 `[LIVE]` 的 app 打印抄进产物，
       * 于是每跑都会留一行"实际等待 = N ms" ⇒ 重活确实落在 380ms 之后，
       * 即被测的 0~300ms 窗口之外。
       *
       * ⚠️⚠️ 前缀必须是**精确的 `[LIVE]`**，不能写成 `[LIVE-EMBED]`：
       *   探针的回显过滤器是 `keys.any(line.contains)`
       *   （`lib/t74_perf_probe.dart:1131`，keys 见 `:1128`），
       *   而 `'[LIVE]' in '[LIVE-EMBED] …'` == **False**
       *   （`[LIVE` 后面是 `-` 不是 `]`）。
       *   我第一版就写成 `[LIVE-EMBED]` ⇒ 这行**永远不会**出现在产物里，
       *   而我会以为"有行为证据"。已实测：121 个极产物里 `app| ` 行 451 条，
       *   含 `[LIVE]` 的 301 条，含 `LIVE-EMBED` 的 **0** 条。
       */
      debugPrint('[LIVE] 延迟建播放器 实际等待='
          '${DateTime.now().difference(t0).inMilliseconds}ms');
      unawaited(_create());
    });
    // ★ task-74 ⑤ 回归修复：订阅可见性（`dispose()` 必须移除）。
    widget.visible?.addListener(_onVisibleChanged);
  }

  Future<void> _create() async {
    // ★ task-74 ⑤：现在是被**延后**调用的 ⇒ 期间可能已经 dispose
    //   （回归风险 ③）。改前这里没有这个检查是因为它跟 `initState`
    //   在同一帧、不可能被抢先。
    if (_disposed) return;
    /*
     * ★ 缓冲调小 —— 直播换台要快（与 PlayerPage 注释里同一理由）
     *
     * ⚠️ 直播**不开** libass：直播没有字幕轨，开了只是白占内存。
     */
    final p = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 16 * 1024 * 1024,
      ),
    );
    final c = VideoController(p);
    _player = p;
    _controller = c;

    /*
     * ★ task-74 ⑤：延迟窗口内被 `open()` 挂起的换台（见 `open()` 的注释）。
     *
     * 在这里**同步**取走 —— 从这行到下面第一个 `await` 之间没有 await 点，
     * 而 `_player` 上面刚被赋值 ⇒ 之后的 `open()` 都走直连路径，
     * 不存在"取走之后又被覆盖"的竞态。
     */
    final pending = _pendingStream;
    _pendingStream = null;

    /*
     * ★★★ 2026-10-09 修复（Owner 缺陷 ①的**真正修法**，逐字）：
     * ```text
     * > 切换到直播页,默认显示的是静音,但是实际还是有声音,
     * > 再次点击 静音图标也没变化,但是却没有声音了,这是一处逻辑缺陷
     * ```
     * Owner 追加澄清（我第一版理解反了，这是关键）：
     * ```text
     * > 切换到直播页应该默认静音
     * ```
     *
     * # 语义拆解（三条现象 ↔ 三处修复）
     * ```text
     * ① 「默认显示的是静音」= **产品意图，是对的** —— 直播页进来就该静音
     *    （直播是"先看到画面再决定听不听"，突然出声会吓人）。
     * ② 「但是实际还是有声音」= ★ **这才是 bug** ——
     *    图标说静音，音量却没压 ⇒ UI 与真实状态不一致。
     *    ⇒ 本处修复：**建播放器时就把 _muted 置真、并真的下发音量 0**。
     * ③ 「再次点击也没变化，但是却没有声音了」= 状态机缺失 ——
     *    旧 `toggleMute` 用「当前音量」反推，第一次点算出 0（没变化）
     *    第二次点才算成 0（静音）⇒ 用户看到"点两次才静音、图标不变"。
     *    ⇒ 见下面 `toggleMute` 的显式状态机（`_muted` + 快照）。
     * ```
     *
     * # ⚠️ 为什么必须在**这里**下发（而不是只置标志）
     * ```text
     * mpv 起来时的默认音量是 100 ⇒ 不真下发 0 的话，画面一出来就出声，
     * 那正是 Owner 报的「实际还是有声音」。
     * `_muted = true` 单独置是**不够**的 —— 它只驱动图标。
     * ```
     *
     * ⚠️ 顺序：必须在 `_playingSub` 等订阅**之前**置 `_muted`，
     *   否则 volume 订阅回流的 0 会先撞上 `_muted == false`（无害，但会多一次 setState）。
     */
    _muted = true;
    unawaited(p.setVolume(0));
    AppLog.write('LIVE', '默认静音 ⇒ _muted=true 且音量下发 0');

    _playingSub = p.stream.playing.listen((v) {
      if (!mounted) return;
      setState(() => _ready = v);
    });
    _bufferingSub = p.stream.buffering.listen((v) {
      if (!mounted) return;
      setState(() => _buffering = v);
    });
    /*
     * ★★★ 2026-10-09：**刻意不订阅 volume**（这是一个被否决的方案，如实记录）
     *
     * ```text
     * 我第一版加过 `_volumeSub`（mpv 回流 0 ⇒ _muted = true），
     * 目的是「让图标能响应真实音量」，但真机点一次就发现它**造出更坏的 bug**：
     *
     *   用户在看（未静音）⇒ 切走 ⇒ `pause()` 因为不可见而 setVolume(0)
     *   ⇒ 音量流回流 0 ⇒ 订阅把 _muted 置真（**那不是用户静音**）
     *   ⇒ 切回来 `resume()` 看到 _muted 为真 ⇒ **不还原音量**
     *   ⇒ ★ 永久静音，且用户没点过静音按钮。
     *
     * ★ 根因：`pause()` 的压 0 与「用户静音」在**同一个信号（音量=0）**上，
     *   从音量反推意图必然分不清这两者。
     * ⇒ 正确做法：`_muted` 只由**显式动作**驱动（默认静音 / 点按钮 / 音量>0），
     *   绝不从 mpv 回流的音量反推。
     * ```
     *
     * 顺带说明「图标不变」这条不需要订阅来修：
     * 改前图标是**写死的常量**（见 `_EmbedBar` 的注释），
     * 且两处显式动作（`_create` 的默认静音、`toggleMute`）现在都会 `setState`
     * ⇒ 重建自然发生，无需监听音量。
     */
    /*
     * ★ 2026-10-08（Owner 第 3 条）：订阅流错误 —— 直播侧原来**完全没订**
     *
     * ```text
     * grep `stream.error` 在本文件改前 = 0 命中（VOD 侧有，见
     * `player_page.dart:2592`）⇒ 流死掉是**静默**的：没有日志、没有提示。
     * 这正是用户报的「再没声音」查不出原因的直接原因。
     * ```
     * ⚠️ 只记日志，**不改** `_error` —— 直播换台/重连期间报错是常态，
     *    弹一个全屏错误会把本来正常的画面盖掉（与播放页「出过画面就算
     *    可恢复抖动」是同一条纪律）。
     */
    _errorSub = p.stream.error.listen((e) {
      debugPrint('[LIVE] 播放错误: $e');
    });

    if (mounted) setState(() {});
    if (pending != null) {
      // 窗口内换过台 ⇒ 开他最后点的那个，而不是 widget.stream 的旧值。
      await open(pending);
    } else {
      await _openCurrent();
    }
  }

  /// 打开/切换当前流
  Future<void> _openCurrent() async {
    final p = _player;
    final st = widget.stream;
    if (p == null) return;
    if (st == null) {
      _error = null;
      // ★ task-91：没有流 ⇒ 旧判决作废（否则会留着一个“没画面”的提示）
      _videoOutputDead = false;
      if (mounted) setState(() {});
      return;
    }
    if (st.url.isEmpty) {
      _error = '这条线路没有地址';
      if (mounted) setState(() {});
      widget.onError?.call(_error!);
      return;
    }
    /*
     * ★ task-74 ⑤ 回归修复：不可见 ⇒ **不起播**。
     *   380ms 窗口内切走时，外层看不到 `isPlaying`（_player==null）
     *   ⇒ 不会 pause、不会置 `_pausedByHide`。门控只能在本类。
     *   恢复可见时由 `_onVisibleChanged()` 补播。
     */
    if (!_visibleNow) {
      _suppressedStart = true;
      debugPrint('[LIVE] 本页不可见 ⇒ 抑制起播（可见时补播）');
      return;
    }
    _error = null;
    // ★ task-91：换流后旧的判决作废（看门狗靠代次号自行放弃）
    _videoOutputDead = false;
    if (mounted) setState(() {});
    try {
      /*
       * ★ headers 是 **`Media` 的构造参数**（不是 `open()` 的参数）——
       *   实测 API：`Media(url, httpHeaders: {...})`，
       *   与 `player_page.dart:1765` 的写法一致。
       *
       * ⚠️ 用 `StreamCandidate.httpHeaders`（那个 getter 把 `List<(k,v)>`
       *    转成 `Map`，并处理了"同名头只保留第一个"）——
       *    **不能**直接用 `st.headers`（那是 `List<(String,String)>`，
       *    类型不匹配，编译不过）。
       * ⚠️ 传空 Map 与不传等价 —— media_kit 用 `isEmpty` 判。
       */
      await p.open(Media(st.url, httpHeaders: st.httpHeaders));
      await p.play();
      /*
       * ★★ task-91：起播成功 ⇒ 起**画面输出层看门狗**。
       *
       * ★ 为什么放在这里（`play()` 之后）而不是 `_create()` 里：
       *   1. 判据要的是“**有视频轨**但输出层没起来” —— 轨是 `open()` 之后
       *      才有的；提前起只会空转，还会把 10 秒预算浪费在 open 上。
       *   2. 换台也走本方法 ⇒ 看门狗**跟着换台重启**（与 `player_page`
       *      在 `_startPlayback` 里起是同一处语义）。
       *   ⚠️ 若只在 `_create()` 里起一次，换台后**永远不会**重新判 ——
       *      从“坏台”换到“好台”会一直挂着“没画面”的提示（真 bug）。
       */
      unawaited(_watchVideoOutput(++_videoOutputToken));
      /*
       * ★ 2026-10-08（Owner 第 3 条）：起播成功必须留一行日志。
       *
       * # 为什么（这是下一次真机定位的唯一手段）
       * ```text
       * 本文件原来的 9 条日志里**没有一条**「播放已开始/出声」——
       * 断声时 `.probe/android_fix/` 全目录里 `换台失败|起播失败` 全 = 0 命中
       * ⇒ 用户报的「没声音」在现有日志里**不可观测**。
       * ```
       * ⚠️ 前缀必须是 `[LIVE]`（**不是** `[LIVE-EMBED]`）——
       *    探针的回显过滤器是 `keys.any(line.contains)`
       *    （`lib/t74_perf_probe.dart:1131`），而
       *    `'[LIVE]' in '[LIVE-EMBED] …'` == **False**。
       */
      debugPrint('[LIVE] 起播 OK host=${Uri.tryParse(st.url)?.host ?? st.url}');
      /*
       * ★★★ task-74 ⑤ 残余竞态修复（第二侧）：`play()` **之后**再查一次可见性。
       *
       * 为什么只能在这里兜：
       *   上面 :318 那次 `_visibleNow` 检查通过之后、这两行 await 期间，
       *   页面可能已经变不可见。此时外层的 `pause()` 要么是**空操作**
       *   （`_player` 还没建好），要么被这里在途的 `play()` **覆盖掉**
       *   ⇒ 隐藏页会带着声音播起来（RED 实测：翻转后第 16 轮 ≈2062ms 起播）。
       *
       * ⚠️ 这里**不置** `_suppressedStart`：流已经 open 好了，只是暂停；
       *   切回时由外层**无条件**置的 `_pausedByHide` 触发 `resume()` 续播。
       *   （置了反而会让 `_onVisibleChanged()` 再 open 一次，白缓冲一遍。）
       */
      if (!_disposed && !_visibleNow) {
        await p.pause();
        debugPrint('[LIVE] 起播完成时本页已不可见 ⇒ 立即暂停（切回时补播）');
      }
    } catch (e) {
      debugPrint('[LIVE-EMBED] 起播失败: $e');
      if (!mounted) return;
      _error = '起播失败：$e';
      setState(() {});
      widget.onError?.call(_error!);
    }
  }

  /// ★ 切到另一条流（同一个播放器实例 —— 不重建，换台更快）
  ///
  /// 返回是否成功。失败时把错误写进 `_error` 并回调外层。
  Future<void> open(StreamCandidate st) async {
    if (_disposed) return;
    final p = _player;
    if (p == null) {
      /*
       * ★★ task-74 ⑤ 回归风险 ①：延迟窗口内换台**不能被静默丢弃**
       *
       * 改前 `_player` 在 `initState` 同一帧就被赋值 ⇒ 这里几乎走不到。
       * 改后 `_player` 要等 [_createDelay] 才存在 ⇒ 用户在 380ms 内换台
       * **一定**走到这里。原实现是 `return;`（静默丢弃）
       * ⇒ 表现为"点了台却停在上一个"，而且**没有任何报错**。
       * ⇒ 挂起，由 `_create()` 建好播放器后补开。
       */
      _pendingStream = st;
      return;
    }
    if (st.url.isEmpty) {
      _error = '这条线路没有地址';
      if (mounted) setState(() {});
      return;
    }
    /*
     * ★ task-74 ⑤ 回归修复：不可见 ⇒ **不换台起播**，
     *   只记住最后点的那个（走 `_pendingStream`，与“播放器还没建好”同一条路）。
     */
    if (!_visibleNow) {
      _pendingStream = st;
      _suppressedStart = true;
      debugPrint('[LIVE] 本页不可见 ⇒ 抑制换台起播（可见时补播）');
      return;
    }
    _error = null;
    // ★ task-91：换流后旧的判决作废（看门狗靠代次号自行放弃）
    _videoOutputDead = false;
    if (mounted) setState(() {});
    try {
      // ★ headers 是 `Media` 的构造参数（见 `_openCurrent` 的说明）
      await p.open(Media(st.url, httpHeaders: st.httpHeaders));
      await p.play();
      /*
       * ★★ task-91：起播成功 ⇒ 起**画面输出层看门狗**。
       *
       * ★ 为什么放在这里（`play()` 之后）而不是 `_create()` 里：
       *   1. 判据要的是“**有视频轨**但输出层没起来” —— 轨是 `open()` 之后
       *      才有的；提前起只会空转，还会把 10 秒预算浪费在 open 上。
       *   2. 换台也走本方法 ⇒ 看门狗**跟着换台重启**（与 `player_page`
       *      在 `_startPlayback` 里起是同一处语义）。
       *   ⚠️ 若只在 `_create()` 里起一次，换台后**永远不会**重新判 ——
       *      从“坏台”换到“好台”会一直挂着“没画面”的提示（真 bug）。
       */
      unawaited(_watchVideoOutput(++_videoOutputToken));
      /*
       * ★★★ task-74 ⑤ 残余竞态修复（第二侧，换台路径）：
       *   `play()` **之后**再查一次可见性 —— 理由与 `_openCurrent()`
       *   里那段完全一致（外层 `pause()` 会被在途的 `play()` 覆盖掉）。
       */
      if (!_disposed && !_visibleNow) {
        await p.pause();
        debugPrint('[LIVE] 换台完成时本页已不可见 ⇒ 立即暂停（切回时补播）');
      }
    } catch (e) {
      debugPrint('[LIVE-EMBED] 换台失败: $e');
      if (!mounted) return;
      _error = '换台失败：$e';
      setState(() {});
      widget.onError?.call(_error!);
    }
  }

  /// ★★ task-91：画面输出层看门狗
  /// —— **判据逐字沿用 `player_page.dart:1787-1836`**，不自创。
  ///
  /// # 判据（五臂实测，`.probe\t376_matrix.py` ⇒ `pass=14 fail=0`）
  /// ```text
  /// hasVideoTrack = player.state.videoParams.dw != null   ← Dart 侧
  /// voConfigured  = mpv 属性 'vo-configured' == 'yes'    ← mpv 侧
  /// 告警 = hasVideoTrack && !voConfigured
  /// ```
  ///
  /// ★ 为什么**不能**只用一个信号（与 `player_page.dart:1766-1772` 同因）：
  ///   * 只用 `vo-configured` → 纯音频台（合法无视频）上它是 `yes`，
  ///     而失败臂上是 `no`。单用会把**每个只有音频的电台**判成故障。
  ///   * 只用 `videoParams.dw` → 失败臂上它也是真（它是
  ///     `mpv_observe_property` 事件推送的**残留**，只证明“曾经解析出
  ///     视频轨”，不证明“此刻有输出”）。
  ///
  /// ⚠️ 更不能用 `controller.rect > 1x1` / `waitUntilFirstFrameRendered`：
  ///    这两个是 `media_kit_video` 自己用来决定“要不要画 Texture”的判据
  ///    （`video_texture.dart:427-437`），而实测它们在**失败臂上依然为真**。
  ///
  /// # 时序：★ 必须轮询，不能只读一次
  /// ```text
  /// 成功臂的 `vo-confirmed` 是 **t=1980ms 才变 yes**（首个采样 t=1143ms
  /// 时还是 `no`）⇒ 读一次就判会把正常播放误报成故障。
  /// ⇒ 预算 10 秒（40 × 250ms），远超实测的 1980ms。
  /// ```
  ///
  /// ⚠️ 没有视频轨（纯音频流）时**不告警** —— 那是合法状态，不是故障。
  ///
  /// ⚠️ 这里**不重试、不换 vo**：同族实测（`.probe\t376_report_android-video.txt`）
  ///    `opengl-es=no` 让 mpv 改走 Desktop GL 后**同样失败**。换 VO 重试只会把
  ///    黑屏时间拉长 ⇒ 正确做法是**告诉用户**，而不是假装能修。
  Future<void> _watchVideoOutput(int token) async {
    /*
     * ★ 与 `player_page.dart` 的差异：本文件 `_player` 是 **nullable** 的，
     *   而且 `dispose()` 会把它置 null ⇒ 这里先抓一份引用，
     *   并在每轮额外查 `_disposed`（`player_page` 那边是 `late final`，不需要）。
     */
    final p = _player;
    if (p == null) return;
    final native = p.platform;
    if (native is! NativePlayer) return;

    Future<bool> voConfigured() async {
      try {
        final v = await native.getProperty('vo-configured');
        return v == 'yes';
      } catch (_) {
        // 属性还没建好（或播放器已 dispose）时可能抛错 ——
        // 当作“还没配好”继续等
        return false;
      }
    }

    var waited = 0;
    while (waited < 40) {
      // 换台 / 退出 ⇒ 这一轮作废
      if (token != _videoOutputToken || !mounted || _disposed) return;
      if (p.state.videoParams.dw != null) {
        if (await voConfigured()) {
          // 画面正常，收工
          debugPrint('[LIVE] 画面输出层就绪'
              '（vo-configured=yes，等了 ${waited * 250}ms）');
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      waited++;
    }

    // 超时：最后再判一次，避免把“刚好在最后一刻起来”误报
    if (token != _videoOutputToken || !mounted || _disposed) return;
    final hasVideo = p.state.videoParams.dw != null;
    final ok = await voConfigured();
    if (token != _videoOutputToken || !mounted || _disposed) return;
    if (!hasVideo || ok) return;

    /*
     * ★ 前缀必须是 `[LIVE]`（**不是** `[LIVE-EMBED]`）——
     *   探针的回显过滤器是 `keys.any(line.contains)`
     *   （`lib/t74_perf_probe.dart:1131`，keys 见 `:1128`），
     *   而 `'[LIVE]' in '[LIVE-EMBED] …'` == **False**
     *   （`[LIVE` 后面是 `-` 不是 `]`）⇒ 写成 `[LIVE-EMBED]` 这行
     *   **永远不会**出现在产物里（`initState` 里记着同一个坑）。
     */
    debugPrint('[LIVE] ★ 画面输出层未能初始化'
        '（有视频轨但 vo-configured≠yes，等了 ${waited * 250}ms）'
        ' —— 音频正常，画面不会有');
    setState(() => _videoOutputDead = true);
  }

  /// ★ 探针钩子（task-91）：内嵌播放器的「画面输出层已死」旗标。
  ///
  /// 与 `player_page.dart:8054 debugPlayerVideoOutputDead()` 同一个用途 ——
  /// 让装机实测能直接读到这个旗标，而不是靠“看屏幕上有没有横幅”。
  @visibleForTesting
  bool get videoOutputDeadForTest => _videoOutputDead;

  /// ★ 探针钩子（task-91）：直接置旗标（**仅供横幅渲染验证**）
  ///
  /// 真失败需要一台“GL 上下文建不起来”的机器；但横幅**渲染对不对**
  /// （位置 / 文案 / 不盖住底部控件）是独立的另一件事，
  /// 必须能在任何机器上验证（先例：`player_page.dart:1844`）。生产代码无调用点。
  @visibleForTesting
  void debugSetVideoOutputDead(bool v) {
    setState(() => _videoOutputDead = v);
  }

  /// 暂停（可见性变化时由外层调用 —— **不是** dispose）
  ///
  /// ★ 为什么是 pause 而不是 dispose：
  ///   保活后切回来要能立刻续播，重建播放器要重新缓冲（用户会看到转圈）。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-10-08（Owner 第 3 条）不可见时**连音量一起压掉**
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// 用户原话：
  /// > 从其他页面切换到直播页会突然有声音,然后再没声音
  ///
  /// # 为什么只 `pause()` 不够（真机上音频还在走）
  /// ```text
  /// 内嵌播放器实测常处于「音频正常、画面没有」的状态
  /// （`.probe/android_fix/t82/logcat.txt:904` 等 14 份日志同句；
  ///  唯一「画面输出层就绪」的样本只有 t35/logcat_A.txt:559）。
  /// 此时 `pause()` 只改 mpv 的 pause 位，**原生侧仍可能在解码输出** ⇒
  /// 切走之后声音还在，切回来那次 `resume()` 就表现为「突然有声音」。
  /// ⇒ 这里额外把音量压到 0：物理上不可能出声。
  /// ```
  ///
  /// ⚠️ 恢复时**还原到暂停前的音量**（不是写死 100）——
  ///    用户可能自己调过音量，写死会把它顶掉。
  ///    mpv 的音量单位是 0..100 的 double。
  /// ⚠️ 只在**不可见**时压音量：可见时用户按暂停，音量必须原样保留。
  /// ★★★ 2026-10-09：与「默认静音」的交互（Owner 缺陷 ① 的配套修复）
  ///
  /// ```text
  /// 本方法在**不可见**时把音量压到 0、并在 [resume] 时还原 `_volumeBeforeHide`。
  /// 而「默认静音」下用户**根本没取消过静音** ⇒ 还原它会把静音顶掉 ⇒
  /// 切走再回来就**出声**了，正好违背 Owner 要的「默认静音」。
  ///
  /// ⇒ 静音态下**不参与**这套自动音量管理：
  ///    · pause：已经是 0，不需要再压、也**不要**抓快照（0 不是有效音量）；
  ///    · resume：静音态下**不还原** —— 保持 0（用户的静音意图优先）。
  /// ```
  Future<void> pause() async {
    if (_disposed) return;
    final p = _player;
    if (p != null && !_visibleNow && !_muted) {
      final cur = p.state.volume;
      if (cur > 0) _volumeBeforeHide = cur;
      await p.setVolume(0);
      debugPrint('[LIVE] 不可见 ⇒ 压音量到 0（原 $_volumeBeforeHide，'
          'playing=${p.state.playing}）');
    }
    await p?.pause();
  }

  /// 续播（只该在"确实是我们暂停的"情况下调用）
  Future<void> resume() async {
    if (_disposed) return;
    final p = _player;
    if (p != null) {
      /*
       * ★ 先还原音量**再** play：反过来的话会有一小段「出声但音量为 0」，
       *   而 `play()` 之后紧接着的 setVolume 在 mpv 上是异步属性写，
       *   用户可能听到一个音量跳变。
       */
      // ★ 静音态 ⇒ 不还原（见 pause() 的注释：用户的静音意图优先）
      final v = _volumeBeforeHide;
      if (!_muted && v != null && v > 0) {
        _volumeBeforeHide = null;
        await p.setVolume(v);
      }
    }
    await p?.play();
    if (p != null) {
      debugPrint('[LIVE] 续播（visible=$_visibleNow，playing=${p.state.playing}）');
    }
  }

  /// 不可见期间被压掉的音量（null = 没压过）
  ///
  /// ★ 见 [pause] 的长注释：恢复时要用它还原，**不能**写死 100。
  double? _volumeBeforeHide;

  bool get isPlaying => _player?.state.playing ?? false;

  /// 当前音量（0~100）
  double get volume => _player?.state.volume ?? 100;

  Future<void> setVolume(double v) async {
    if (_disposed) return;
    await _player?.setVolume(v.clamp(0, 100));
  }

  /*
   * ★★★ 2026-10-09 修复（Owner 真机报的缺陷，逐字）：
   * ```text
   * > 切换到直播页,默认显示的是静音,但是实际还是有声音,
   * > 再次点击 静音图标也没变化,但是却没有声音了,这是一处逻辑缺陷
   * ```
   *
   * # 三条现象 ↔ 三个根因（都在本文件）
   * ```text
   * ① 「默认显示的是静音」
   *      `_EmbedBar` 的图标是**写死的常量** `Icons.volume_off_outlined`
   *      ⇒ 无论实际音量多少，永远画成"已静音"。UI 在说谎。
   * ② 「再次点击图标也没变化」
   *      本类的订阅里**没有 volume**（只订了 playing / buffering / error）
   *      ⇒ 音量变化不触发重建 ⇒ 图标永远不动。
   * ③ 「但是却没有声音了」
   *      旧实现：setVolume((state.volume ?? 100) > 0 ? 0 : 100)
   *      它用**当前音量**当判据，而不是「我是否处于静音态」。
   *      而 `pause()`（不可见时）**会把音量压成 0**（:646-657）。
   *      ⇒ 从直播页切走再回来：音量已是 0 ⇒ 旧实现算出 `100`…
   *        但更常见的路径是「音量本来就是 0」⇒ 旧实现算出 100 ⇒ 出声；
   *        再点一次算出 0 ⇒ 没声音，而图标**始终**是"静音"⇒ 用户看到的
   *        「点两次结果不一样、图标却一直不变」正是这么来的。
   * ```
   *
   * # 修法：把静音做成**显式状态**，与 VOD 侧同一套语义
   * ```text
   * · `_muted` 由**我们**维护（不再从 state.volume 反推）；
   * · 订阅 volume ⇒ mpv 回流的真实音量能驱动图标重建；
   * · 静音前把音量存进 `_volumeBeforeMute`，取消静音时还原**它**
   *   （不是写死 100，也不是读当前音量 —— 后者静音时恒为 0）。
   * ```
   */
  Future<void> toggleMute() async {
    if (_disposed) return;
    final p = _player;
    if (p == null) return;
    AppLog.write('LIVE', '静音按钮被点击：_muted=$_muted '
        'volume=${p.state.volume}');
    if (_muted) {
      /*
       * 取消静音：三级瀑布求恢复目标（**绝不下发 0**）
       * ```text
       * 1) 快照（本次静音前的真实音量，最准）
       * 2) 偏好 dsh.playprefs.lastVolume（跨会话的「用户习惯音量」）
       * 3) 出厂 100（理论上到不了，纯粹兜底）
       * ```
       * ★ 与 VOD 侧 `player_page.dart::_toggleMute` 的瀑布**同一套语义**
       *   （那里是 `_volumeBeforeMute` → `_lastVolume*100` → 100）。
       *
       * ⚠️ 默认静音进来时快照是 null ⇒ 走第 2 级 ——
       *   用户第一次点"取消静音"应该听到**他习惯的音量**，不是 100。
       */
      var restore = _volumeBeforeMute ?? 0;
      if (restore <= 0) {
        final v = double.tryParse(
            UiPrefs.get('dsh.playprefs.lastVolume') ?? '');
        restore = (v != null && v >= 0 && v <= 1) ? v * 100 : 100;
      }
      if (restore <= 0) restore = 100;
      _volumeBeforeMute = null;
      await p.setVolume(restore.clamp(1, 100));
      if (mounted) setState(() => _muted = false);
      AppLog.write('LIVE', '取消静音 ⇒ 音量还原到 ${restore.round()}');
    } else {
      // 静音：先抓快照再压 0（顺序不能反 —— 反了就抓不到原音量）
      final cur = p.state.volume;
      if (cur > 0) _volumeBeforeMute = cur;
      await p.setVolume(0);
      if (mounted) setState(() => _muted = true);
      AppLog.write('LIVE', '已静音 ⇒ 音量压到 0（快照 $_volumeBeforeMute）');
    }
  }

  /// 是否处于静音态（驱动底栏图标）
  ///
  /// ★ 与 VOD 侧（`player_page.dart::_muted`）同一套语义：
  ///   它是**显式状态**，不由 `state.volume == 0` 反推 ——
  ///   因为 `pause()` 在不可见时也会把音量压成 0（那不是"用户静音"）。
  bool get muted => _muted;
  bool _muted = false;

  /// 静音前的音量（null = 没静音过）
  double? _volumeBeforeMute;

  /// 重新尝试当前流（用户点"重试"）
  Future<void> retry() => _openCurrent();

  /// ★ 测试注入口（`@visibleForTesting`）：播放器是否**还没**被建出来。
  ///
  /// 存在的唯一理由：让测试能证明「原生重活没有发生在首帧」
  /// （task-74 ⑤ 的核心主张）。生产代码不该读它。
  @visibleForTesting
  bool get hasPlayerForTest => _player != null;

  /// ★ 测试注入口：延迟窗口内被挂起的换台（null = 没有挂起的）。
  ///
  /// 用来证明回归风险 ①「窗口内换台被静默丢弃」确实已修。
  @visibleForTesting
  StreamCandidate? get pendingStreamForTest => _pendingStream;

  /// ★ 测试注入口：底层原生播放器（null = 还没建出来）。
  ///
  /// 存在的唯一理由：让测试能读到**独立于 `isPlaying` 标志**的第二量 ——
  /// `state.position`（>0 = 解码器真的在推进）、`state.width/height`
  /// （>0 = 已解出视频帧）。`isPlaying` 只是 mpv 的 pause 属性，
  /// 单靠它无法区分"标志为真"与"真的在播"。
  ///
  /// ⚠️ 这是**只读注入**，不改变任何行为；生产代码不该读它。
  @visibleForTesting
  Player? get playerForTest => _player;

  @override
  void didUpdateWidget(covariant LiveEmbeddedPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // ★ task-74 ⑤：可见性信号换了实例 ⇒ 换订阅（否则补起播永不触发）。
    if (!identical(oldWidget.visible, widget.visible)) {
      oldWidget.visible?.removeListener(_onVisibleChanged);
      widget.visible?.addListener(_onVisibleChanged);
    }
    /*
     * ★ 频道换了 ⇒ 换流
     *
     * ⚠️ 判据用 **url** 而不是对象引用：
     *    同一个频道重新取流会拿到**新的** StreamCandidate 对象
     *    （但 url 可能一样）。用对象比较会导致"每次都重开"，
     *    在直播里表现为**画面闪一下**。
     */
    final a = oldWidget.stream?.url;
    final b = widget.stream?.url;
    if (a != b) {
      if (b == null) {
        /*
         * ★ task-74 ⑤：也要丢掉**挂起的**换台。
         *   否则"窗口内先选台、再取消选择"会让 `_create()` 末尾
         *   把那个已作废的台开起来（挂起值比 widget.stream 更旧）。
         */
        _pendingStream = null;
        // ★ task-91：没选中频道 ⇒ 旧判决作废（否则会留着“没画面”的提示）。
        //   `didUpdateWidget` 之后紧跟一次 build ⇒ 直接赋值即可，不需 setState。
        _videoOutputDead = false;
        _videoOutputToken++; // 作废在飞的那一轮
        // 没选中频道 ⇒ 停掉，不要留着上一个台的声音
        unawaited(_player?.stop() ?? Future.value());
      } else {
        unawaited(open(widget.stream!));
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    /*
     * ★ task-91：画面输出层看门狗作废（它是个 while 轮询，最多 10 秒）
     *
     * 没有 Timer 可以 cancel —— 它靠代次号自证过期（每轮都查
     * `token != _videoOutputToken || !mounted || _disposed`）。这里把代次号推进一格，
     * 让**已在飞行中的那一轮**立刻放弃，而不是等它跑完再对着
     * 已卸载的 State 调 `setState`。
     */
    _videoOutputToken++;
    /*
     * ★★★ 必须释放（lead 约束 2：否则解码器泄漏）
     *
     * 顺序：先取消订阅，再 dispose 播放器。
     * ⚠️ 不 await —— `dispose()` 是同步的。
     */
    // ★ task-74 ⑤：定时器必须先取消 —— 否则它在 dispose 之后仍会触发
    //   （`_create()` 里的 `_disposed` 检查是第二道闸，不是第一道）。
    _createTimer?.cancel();
    _createTimer = null;
    _pendingStream = null;
    // ★ task-74 ⑤ 回归修复：可见性订阅必须移除（否则 dispose 后仍被回调）。
    widget.visible?.removeListener(_onVisibleChanged);
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _errorSub?.cancel();
    _playingSub = null;
    _bufferingSub = null;
    _errorSub = null;
    final p = _player;
    _player = null;
    _controller = null;
    unawaited(p?.dispose() ?? Future.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final c = _controller;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 用户要求【B】：直播页播放器支持**双击进入全屏**
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话（第 2 条）：
     * > 右侧就一个播放器也固定,**还要支持双击进入全屏播放**
     *
     * # ★ 为什么必须复用播放页的判据（不能自己写一套）
     * ```text
     * 播放页的既有约定（`PlayerGestures.doubleTapEnabledFor`）：
     *    · PC/TV 上双击 ≈ **空档**（用户 2026-09-24 明确要求
     *      「pc端不应该双击左右侧快进快退」）⇒ 让给"全屏"是**零冲突**的
     *    · 触摸端双击 = 左右快进快退（既有功能）⇒ ★ **不能夺走**
     * ⇒ 本页沿用同一判据，两个平台各走各的、**互斥**
     * ```
     *
     * # ★★ 为什么"两者绝不能同时挂"
     * ```text
     * `GestureDetector` 的 `onDoubleTap` 与 `onDoubleTapDown` 挂在
     * **同一个 `DoubleTapGestureRecognizer`** 上 ⇒
     * 一次双击会把**两个回调都跑一遍**（播放页 L5106-5111 记着这个坑）。
     * ⇒ 用 `_isTouch` 三向分流，保证**只有一个非 null**。
     * ```
     *
     * ⚠️ 触摸端这里**不**实现左右快进快退（直播是**实时流**，
     *    快进没有意义 —— 那是点播才有的语义）。
     *    所以触摸端双击**保持"什么都不做"**（与改造前一致），
     *    而不是硬塞一个"快退到直播开始"这种莫名其妙的行为。
     */
    final isTouch = widget.isTouchOnly;
    // ★ 与播放页同源：触摸端 != 全屏；PC/TV = 全屏
    final doubleTapToFullscreen =
        !isTouch && widget.onToggleFullscreen != null;

    return ClipRRect(
      borderRadius: Radii.rLg,
      child: GestureDetector(
        // ★ 只在"全屏可用且非触摸端"时挂 —— 否则为 null（见上面互斥说明）
        onDoubleTap: doubleTapToFullscreen
            ? () {
                debugPrint('[LIVE] 双击 ⇒ 进入全屏');
                widget.onToggleFullscreen!();
              }
            : null,
        child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (c != null)
              Video(
                controller: c,
                /*
                 * ⚠️ `fill` 用默认黑边策略 —— 直播分辨率杂，
                 *    拉伸会让画面变形（与 PlayerPage 的取舍一致）。
                 */
                controls: NoVideoControls,
              ),

            // ── 加载 / 缓冲 ──
            /*
             * ★ task-74 ⑤ 方向 B：`c == null` 也必须画占位。
             *
             * 延迟期间 `_controller` 还是 null ⇒ 上面的 `Video` 不画；
             * 若这里也不画，Stack 里就只剩黑色 `ColoredBox`
             * ⇒ 用户看到**纯黑框**（视觉回归，看起来像播放器挂了）。
             */
            /*
             * ★ task-91：输出层已死时**不画转圈** —— 转圈暗示“在加载、马上就有”，
             *   而这种情况下永远不会有画面。下面那条提示才是真相。
             */
            if (!_videoOutputDead &&
                (c == null ||
                    widget.stream == null ||
                    (_buffering && !_ready)))
              const _EmbedLoading(),

            // ── 错误 ──
            if (_error != null) _EmbedError(message: _error!, onRetry: retry),

            // ── 仅音频提示（cctv）──
            //   ★ task-91：与“输出层已死”互斥 —— 两者都是居中卡片，同时出现会叠字。
            if (widget.audioOnly && _error == null && !_videoOutputDead)
              const _AudioOnlyBadge(),

            /*
             * ── ★★ task-91：画面输出层没能初始化 ──
             *
             * 由 `_watchVideoOutput()` 立旗（判据：有视频轨 &&
             * `vo-configured != yes`，五臂实测见 `.probe\t376_matrix.txt`）。
             *
             * ⚠️ 与 `_EmbedError` 互斥（`_error == null`）—— 起播失败与“流开好了但没画面”
             *   是两种不同失败，不该叠着告诉用户两件事。
             *
             * ★ 为什么用**居中卡片**而不是 `player_page` 那种 `bottom: 0` 横幅：
             *   内嵌区域小，底部 `_EmbedBar`（播放/静音）**不能被挤没**。
             */
            if (_videoOutputDead && _error == null)
              const _EmbedVideoOutputDead(),

            // ── 右上角：标题 + 全屏 ──
            Positioned(
              top: Sp.x3,
              right: Sp.x3,
              child: Row(
                children: [
                  if (widget.onToggleFullscreen != null)
                    _RoundBtn(
                      icon: Icons.fullscreen,
                      tooltip: '全屏播放',
                      onTap: widget.onToggleFullscreen!,
                    ),
                ],
              ),
            ),
            Positioned(
              left: Sp.x3,
              top: Sp.x3,
              right: 56,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: FontSizes.base,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                    ),
                  ),
                  if (widget.subtitle != null)
                    Text(
                      widget.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.72),
                        fontSize: FontSizes.cap,
                        shadows: const [
                          Shadow(blurRadius: 6, color: Colors.black54),
                        ],
                      ),
                    ),
                ],
              ),
            ),

            // ── 底部：播放/暂停 + 静音（直播必需的最小控制）──
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _EmbedBar(
                playing: _ready,
                muted: muted,
                onTogglePlay: () async {
                  final p = _player;
                  if (p == null) return;
                  if (p.state.playing) {
                    await p.pause();
                    // ★ 上报"是用户暂停的" —— 可见性变化时不要自动播
                    widget.onUserPause?.call(true);
                  } else {
                    await p.play();
                    widget.onUserPause?.call(false);
                  }
                },
                onMute: toggleMute,
                accent: colors.primary,
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

// ─────────────────────────── 内部小件 ───────────────────────────

class _EmbedLoading extends StatelessWidget {
  const _EmbedLoading();

  @override
  Widget build(BuildContext context) => const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
}

class _EmbedError extends StatelessWidget {
  const _EmbedError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Sp.x5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white70, size: 32),
              const SizedBox(height: Sp.x3),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: FontSizes.cap),
              ),
              const SizedBox(height: Sp.x3),
              TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      );
}

/// 「仅音频」角标 —— cctv 的实际情况（视频线全 DRM，只剩音频）
///
/// ★ 用户报过「cctv看得到但是点开黑屏」⇒ 必须**明确告知**，不能静默黑屏
///   （与 `player_page.dart` 的 `_LiveAudioOnlyBanner` 同一结论）。
class _AudioOnlyBadge extends StatelessWidget {
  const _AudioOnlyBadge();

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Sp.x4,
            vertical: Sp.x3,
          ),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: Radii.rMd,
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.volume_up_outlined, color: Colors.white70, size: 30),
              SizedBox(height: Sp.x2),
              Text(
                '仅音频',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: FontSizes.base,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 2),
              Text(
                '视频线路受内容方保护，客户端无法播放',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: FontSizes.cap),
              ),
            ],
          ),
        ),
      );
}

/// ★★ task-91：「画面无法显示」提示（内嵌版）
///
/// # 文案来源
/// ```text
/// 沿用 `player_page.dart:7858-7867 _VideoOutputDeadBanner` 的说法，
/// 但把“可以**返回**换一条线路”改成“可以**换**一条线路”。
/// ```
///
/// ★ 为什么去掉了「返回」按钮（**有意为之**）：
///   内嵌播放器没有“返回”语义（它就在直播页里，左侧就是频道列表）
///   ⇒ 用户的下一步是**点另一个台**，而不是“返回”。
///   所以这里**不放按钮** —— 也避免在小区域里再挤一个控件。
class _EmbedVideoOutputDead extends StatelessWidget {
  const _EmbedVideoOutputDead();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x4),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Sp.x4,
              vertical: Sp.x3,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: Radii.rMd,
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.warning_amber_outlined,
                  color: Colors.white70,
                  size: 30,
                ),
                SizedBox(height: Sp.x2),
                Text(
                  '画面无法显示',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: FontSizes.base,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '本机图形输出层没能初始化，声音是正常的。'
                  '可以换一条线路或换一个源再试。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: FontSizes.cap,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _EmbedBar extends StatelessWidget {
  const _EmbedBar({
    required this.playing,
    required this.muted,
    required this.onTogglePlay,
    required this.onMute,
    required this.accent,
  });

  final bool playing;

  /// ★ 2026-10-09：是否静音（驱动图标）。
  ///
  /// 改前这里没有这个字段，图标是**写死的常量** `Icons.volume_off_outlined`
  /// ⇒ 永远画成"已静音"，与真实音量无关（Owner 缺陷 ①）。
  final bool muted;

  final Future<void> Function() onTogglePlay;
  final Future<void> Function() onMute;
  final Color accent;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x3,
          vertical: Sp.x2,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withValues(alpha: 0.62),
              Colors.transparent,
            ],
          ),
        ),
        child: Row(
          children: [
            _RoundBtn(
              icon: playing ? Icons.pause : Icons.play_arrow,
              tooltip: playing ? '暂停' : '播放',
              onTap: () => unawaited(onTogglePlay()),
            ),
            const SizedBox(width: Sp.x2),
            /*
             * ★★★ 2026-10-09 修复（Owner 缺陷 ①：「默认显示的是静音，**但实际还是有声音**」）
             *
             * # ★ 我第一次理解错了（如实记录，防止后人重踩）
             * ```text
             * 我第一版以为「图标显示静音」是**假象**（UI 在说谎），于是把图标改成
             * 由实际音量驱动 ⇒ 默认显示"未静音"。
             * ★ 但 Owner 的本意正好相反：
             *   「切换到直播页应该默认静音」——
             *   图标显示静音是**对的**（产品意图），
             *   真正错的是「实际还有声音」⇒ **声音没被静音**。
             * ```
             *
             * # 正确的语义（三段，与下面的默认静音实现配套）
             * ```text
             * ① 切到直播页 ⇒ **默认静音**（`_muted = true`、音量真下发 0）；
             * ② 图标显示「已静音」—— 与 ① 一致，不说谎；
             * ③ 点一下 ⇒ 取消静音并**还原到偏好音量**；
             *    再点一下 ⇒ 静音。★ 图标每次都跟着变（这是原来缺的）。
             * ```
             */
            _RoundBtn(
              icon: muted ? Icons.volume_off_outlined : Icons.volume_up_outlined,
              tooltip: muted ? '取消静音' : '静音',
              onTap: () => unawaited(onMute()),
            ),
          ],
        ),
      );
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.black.withValues(alpha: 0.42),
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
          ),
        ),
      );
}
