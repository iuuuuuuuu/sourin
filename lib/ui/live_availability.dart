// ═══════════════════════════════════════════════════════════════════════
//  直播频道可用性判定（task-39 新增）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 不可用的央视网直播就不要显示出来了
//
// # ★★★ 为什么必须在**取流阶段**判定（而不是列表阶段）
//
// 实测（`.probe/t39_recon_full.py`，真核心 FFI）：
// ```text
// get_live_channels 返回的字段 = ['group', 'id', 'logo', 'name']
//   ⇒ ★ 没有任何可用性 / DRM 字段
// ```
// 而 `drm_protected` 是 `get_live_stream` 才返回的
// （`cctv.js:341` 硬编码在 `liveUrls()` 里）——
// **列表阶段拿不到**。
//
// ⇒ 所以"不显示不可用"只能：
// ```text
// ① 取流阶段探测（本文件）—— 真实，但要多一轮请求
// ② 或硬编码"cctv 全不可用"  —— ★ 危险（见下）
// ```
//
// # ★★★ 为什么**不**硬编码"cctv 全不可用"
//
// ```text
// 我实测过：20/20 个 cctv 频道的**视频线全部 drm_protected: true**
//   ⇒ 很容易得出"cctv 天生如此，直接过滤掉"
// ★ 但那是**此刻的快照**：
//   · 央视 CDN 地址会过期/更换（实测过 404 / 504 / SSL EOF 三种）
//   · 哪天内容方取消加密，硬编码的过滤会让用户**永远看不到**
//     ⇒ 这是**永久性假阴性**，比"多显示几个台"危险得多
// ⇒ 所以判定必须**动态探测**，且结果**带 TTL 缓存**（别每次进页面都探）。
// ```
//
// # ★ 探测失败 ≠ 不可用（铁律 51 的同一教训）
//
// ```text
// 网络抖动 / 源临时挂了 ⇒ 探测拿不到结果
// ⇒ ★ 必须当成"未知"并**照常显示**，绝不能因为"探不到"就隐藏
//   （否则用户的频道列表会随网络状况**随机变少**，那比不隐藏更糟）
// ```
//
// # 与 `player_page.dart:1544-1550` 的关系
//
// 那里也判过"只剩音频可播"（`hasDrmVideo && onlyAudioPlayable`）。
// ★ 但那是**播放时**的提示（已经点进去了）；本文件是**列表阶段**的分类，
//   目的是决定"要不要显示"。两者结论要一致，所以判据刻意写成同一套：
//   都是「可播线路里有没有带视频的」。

import 'package:material_ui/material_ui.dart';

import '../core/sourin_api.dart';

/// 一个频道的可用性
enum LiveAvailability {
  /// 有带视频的可播线路 —— 正常显示
  playable,

  /// ★ 只有音频线可播（cctv 的实际情况）——
  ///   默认隐藏但**可展开**（用户可能就想听广播）
  audioOnly,

  /// 一条可播线路都没有 —— 显示也没意义
  unavailable,

  /// 还没探测 / 探测失败
  ///
  /// ★★ 这一档**必须存在**，且 UI 必须把它当"显示"处理 ——
  ///    否则"探不到"会被当成"不可用"（假阴性，见文件头）。
  unknown,
}

/// 判定一条线路是不是"只有声音"（没有视频轨）
///
/// # 判据来源
/// `cctv.js` 给音频线的 `quality` 是 `'仅音频'`、`label` 是 `'广播'`
/// （实测 `get_live_stream(cctv, cctv1)` 的第三条）。
///
/// ⚠️ 这是**插件约定**不是协议字段 —— 所以判据写成"包含关键字"而不是等值，
///    将来插件换个说法（`'音频'` / `'伴音'`）也还能命中。
///    命中不了时的后果是**当成视频线**（保守：倾向显示）。
///
/// ★★★ 必须**大小写不敏感**（被单测抓出来的真 bug）
/// ```text
/// 我第一版写 `t.contains('audio')` ⇒ 'Audio' / 'AUDIO' 都命中不了
/// ⇒ 那条线路被当成**视频线** ⇒ 若它是唯一可播的，
///   分类会从 audioOnly 变成 playable ⇒ 列表里显示出来，
///   用户点进去看到黑屏（音频流没有画面）—— 正是要修的那个症状。
/// ★ 用 `toLowerCase()` 统一后再比。
/// ```
bool isAudioOnlyLine(StreamCandidate s) {
  final t = '${s.quality ?? ''}${s.label ?? ''}'.toLowerCase();
  return t.contains('音频') || t.contains('广播') || t.contains('audio');
}

/// 把一次 `getLiveStream` 的结果分类
LiveAvailability classifyStreams(List<StreamCandidate> list) {
  final playable = list.where((s) => s.isPlayable).toList();
  if (playable.isEmpty) return LiveAvailability.unavailable;
  final withVideo = playable.where((s) => !isAudioOnlyLine(s)).toList();
  if (withVideo.isEmpty) return LiveAvailability.audioOnly;
  return LiveAvailability.playable;
}

/// 是否应该**默认显示**这个频道
///
/// ```text
/// playable    → 显示
/// audioOnly   → ★ 默认隐藏（用户要求"不可用的不要显示"），但可展开
/// unavailable → 隐藏
/// unknown     → ★ 显示（探不到不等于不可用）
/// ```
bool shouldShowByDefault(LiveAvailability a) =>
    a == LiveAvailability.playable || a == LiveAvailability.unknown;

/// 可用性探测 + 缓存
///
/// # 为什么要缓存
/// ```text
/// 实测单个 get_live_stream 延迟 22~105ms（中位 24ms）
/// 用户目录里 cctv 20 + iptv 28 = 48 个频道
///   ⇒ 串行 ≈ 1.2s，8 路并发 ≈ 0.2s
/// ★ 进一次直播页探一遍可以接受，但**每次 setState 都探**就不行 ——
///   所以按 (provider, channelId) 缓存，TTL 10 分钟。
/// ```
class LiveAvailabilityProbe {
  LiveAvailabilityProbe({
    this.ttl = const Duration(minutes: 10),
    this.concurrency = 8,
    Future<List<StreamCandidate>> Function(String provider, String channelId)?
        fetch,
  }) : _fetch = fetch ?? SourinApi.getLiveStream;

  final Duration ttl;

  /// 并发上限 —— 别把核心/网络打爆（实测 8 路时中位仍 ~24ms）
  final int concurrency;

  final Future<List<StreamCandidate>> Function(String, String) _fetch;

  final Map<String, LiveAvailability> _result = {};
  final Map<String, DateTime> _at = {};

  String _key(String provider, String channelId) => '$provider\u0000$channelId';

  /// 取缓存（过期返回 null）
  LiveAvailability? cached(String provider, String channelId) {
    final k = _key(provider, channelId);
    final t = _at[k];
    if (t == null) return null;
    if (DateTime.now().difference(t) > ttl) return null;
    return _result[k];
  }

  /// 探测一批频道；返回**新探到**的数量
  ///
  /// ★ 已经有有效缓存的会跳过（除非 [force]）。
  Future<int> probe(
    List<LiveGroup> groups, {
    bool force = false,
    void Function()? onProgress,
  }) async {
    final todo = <(String, String)>[];
    for (final g in groups) {
      for (final c in g.channels) {
        if (!force && cached(g.provider, c.id) != null) continue;
        todo.add((g.provider, c.id));
      }
    }
    if (todo.isEmpty) return 0;

    var done = 0;
    // 手写并发池（不引依赖；`Future.wait` 会一次性打完）
    final queue = List.of(todo);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final (provider, channelId) = queue.removeAt(0);
        LiveAvailability a;
        try {
          final list = await _fetch(provider, channelId);
          a = classifyStreams(list);
        } catch (e) {
          /*
           * ★★ 探测失败 ⇒ unknown（**不是** unavailable）
           *
           * 否则用户的频道列表会随网络状况随机变少。
           * ⚠️ 也不能只留 unknown 不记时间 —— 否则会被当成"已探测过"
           *    而永不重试。这里记时间，让 TTL 后再试。
           */
          debugPrint('[LIVE-PROBE] 探测失败 $provider/$channelId: $e');
          a = LiveAvailability.unknown;
        }
        _result[_key(provider, channelId)] = a;
        _at[_key(provider, channelId)] = DateTime.now();
        done++;
        onProgress?.call();
      }
    }

    final n = concurrency < 1 ? 1 : concurrency;
    await Future.wait(List.generate(n, (_) => worker()));
    return done;
  }

  /// 统计（给 UI 显示"已隐藏 N 个"）
  int countOf(Iterable<(String, String)> keys, LiveAvailability a) =>
      keys.where((k) => _result[_key(k.$1, k.$2)] == a).length;
}
