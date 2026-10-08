
// ═══════════════════════════════════════════════════════════════════════
//  哔哩哔哩弹幕绑定（自动绑定剧集 + 持久化）—— task-28
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件解决什么
//
// 用户原话：「支持一下 哔哩哔哩填入链接导入弹幕，并且自动绑定剧集和
// 自动更新弹幕」。
//
// 「绑定」= 记住「本机某个剧集的第 N 集」对应「B 站某个视频的第 M P」。
// 下次用户点进同一集，不用再填链接，弹幕自动到位。
//
// # 为什么不用 danmaku.dart 里那套 dandanplay 的匹配
//
// dandanplay 是「按文件名搜番剧」，靠的是一个远程数据库；
// B 站没有这样的接口，只有 /x/web-interface/view 拿标题。
// 所以自动绑定走的是**标题相似度**：拿我们的剧集标题去和 B 站视频标题
// 比，够像就自动绑。
//
// 相似度算法直接复用 lib/core/title_match.dart 的 titleSimilarity
// （字符 bigram 的 Jaccard），不另造一套 —— 那会让「像不像」有两份定义。
//
// # 分集怎么对齐（★ 这是最容易做错的地方）
//
// 三种情况：
//   A. B 站视频是**单 P**（videos == 1）
//      ⇒ 整部剧的每一集都指向这同一个 cid。
//        弹幕时间轴对不上是必然的（一 P 只有一条时间轴），但这是用户
//        自己选的，且比「什么都没有」强。故允许，且标注出来。
//   B. B 站视频是**多 P**（videos > 1）
//      ⇒ 按 P 序对齐：我们第 N 集 ↔ B 站第 N P。
//        若我们的集数比 P 多，多出来的集**不绑**（宁缺勿错）。
//   C. 用户手动指定了 P
//      ⇒ 只绑这一集，不扩散到其它集。
//
// # 持久化格式
//
// 走 lib/core/ui_prefs.dart（同一个 JSON 文件，不另开文件）。
// 键：
//   dsh.bili.bind.<provider>:<id>   → 一个 JSON 对象（见 BiliBinding.toJson）
//   dsh.bili.manual.<provider>:<id> → '1' 表示这条是用户手动绑的
//
// 为什么用 <provider>:<id> 当键：与 ui_prefs.dart:130 的 sourcePref 同构，
// 而且 MediaItem 的 (provider, id) 就是全应用里作品的唯一坐标
// （见 lib/ui/media_session.dart:75 的 isSameSessionAs 判据）。

import 'dart:convert';

import '../title_match.dart';
import '../ui_prefs.dart';
import 'bili_api.dart';

/// 自动绑定的相似度门槛。
///
/// 为什么是 0.34：titleSimilarity 是 bigram Jaccard，同一个片名的
/// 「【官方 MV】Never Gonna Give You Up - Rick Astley」vs
/// 「Never Gonna Give You Up」实测约 0.45~0.6；而两个完全不同的片名
/// 通常 < 0.15。0.34 落在中间，宁可让用户手动补，也不要错绑。
const double kBiliAutoBindThreshold = 0.34;

/// 一集 ↔ 一个 B 站分 P 的对应关系。
class BiliEpisodeBinding {
  const BiliEpisodeBinding({
    required this.episodeIndex,
    required this.page,
    required this.cid,
    this.part = '',
  });

  /// 我们的第几集（0 基，与 PlayRequestData.episodeIndex 同一坐标系）。
  final int episodeIndex;

  /// B 站第几 P（1 基）。
  final int page;

  /// 该 P 的 cid（弹幕的 oid）。
  final int cid;

  /// 该 P 的标题（展示用）。
  final String part;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'i': episodeIndex,
        'p': page,
        'c': cid,
        if (part.isNotEmpty) 't': part,
      };

  static BiliEpisodeBinding? fromJson(Object? o) {
    if (o is! Map) return null;
    final i = o['i'];
    final p = o['p'];
    final c = o['c'];
    if (i is! int || p is! int || c is! int) return null;
    if (c <= 0) return null;
    return BiliEpisodeBinding(
      episodeIndex: i,
      page: p,
      cid: c,
      part: o['t'] is String ? o['t'] as String : '',
    );
  }

  @override
  String toString() => 'E$episodeIndex -> P$page(cid=$cid)';
}

/// 一部作品上挂着的全部 B 站绑定。
class BiliBinding {
  const BiliBinding({
    required this.bvid,
    required this.title,
    this.aid = 0,
    this.episodes = const <BiliEpisodeBinding>[],
    this.manual = false,
    this.updatedAt = 0,
  });

  /// B 站视频号。
  final String bvid;

  /// B 站视频标题（给用户看「绑到哪去了」）。
  final String title;

  final int aid;

  /// 逐集对应表。
  final List<BiliEpisodeBinding> episodes;

  /// 是不是用户手动绑的（手动绑的不许被自动流程覆盖）。
  final bool manual;

  /// 上次同步时间（毫秒时间戳，0 = 未知）。
  final int updatedAt;

  bool get isEmpty => episodes.isEmpty;

  int get episodeCount => episodes.length;

  /// 找第 [index] 集的 cid；没有返回 0。
  int cidFor(int index) {
    for (final e in episodes) {
      if (e.episodeIndex == index) return e.cid;
    }
    return 0;
  }

  /// 找第 [index] 集的 P 号；没有返回 0。
  int pageFor(int index) {
    for (final e in episodes) {
      if (e.episodeIndex == index) return e.page;
    }
    return 0;
  }

  BiliBinding copyWith({
    String? bvid,
    String? title,
    int? aid,
    List<BiliEpisodeBinding>? episodes,
    bool? manual,
    int? updatedAt,
  }) =>
      BiliBinding(
        bvid: bvid ?? this.bvid,
        title: title ?? this.title,
        aid: aid ?? this.aid,
        episodes: episodes ?? this.episodes,
        manual: manual ?? this.manual,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'b': bvid,
        't': title,
        'a': aid,
        'u': updatedAt,
        if (episodes.isNotEmpty)
          'e': episodes.map((e) => e.toJson()).toList(growable: false),
      };

  static BiliBinding? fromJson(Object? o) {
    if (o is! Map) return null;
    final b = o['b'];
    if (b is! String || b.isEmpty) return null;
    final eps = <BiliEpisodeBinding>[];
    final raw = o['e'];
    if (raw is List) {
      for (final it in raw) {
        final e = BiliEpisodeBinding.fromJson(it);
        if (e != null) eps.add(e);
      }
    }
    return BiliBinding(
      bvid: b,
      title: o['t'] is String ? o['t'] as String : '',
      aid: o['a'] is int ? o['a'] as int : 0,
      episodes: eps,
      updatedAt: o['u'] is int ? o['u'] as int : 0,
    );
  }

  @override
  String toString() =>
      'BiliBinding($bvid, "$title", ${episodes.length} 集'
      '${manual ? ', 手动' : ', 自动'})';
}

// ══════════════════════════════════════════════════════════════════════
//  一、偏好键与读写
// ══════════════════════════════════════════════════════════════════════

/// 所有 B 站绑定相关的偏好键都在这里造，别处不要手写字符串。
abstract final class BiliPrefs {
  static const String _ns = 'dsh.bili';

  /// 作品级绑定：dsh.bili.bind.<provider>:<id>
  static String bindKey(String provider, String id) =>
      '$_ns.bind.$provider:$id';

  /// 手动标记：dsh.bili.manual.<provider>:<id>
  static String manualKey(String provider, String id) =>
      '$_ns.manual.$provider:$id';

  /// 用户手动输入的「默认 P」：dsh.bili.page.<provider>:<id>
  static String pageKey(String provider, String id) =>
      '$_ns.page.$provider:$id';

  /// 是否开启自动更新：dsh.bili.autoupdate（全局开关）
  static const String autoUpdateKey = '$_ns.autoupdate';

  /// 上次全量刷新时间：dsh.bili.lastsync
  static const String lastSyncKey = '$_ns.lastsync';

  /// 自动更新间隔（分钟）：dsh.bili.interval
  static const String intervalKey = '$_ns.interval';
}

/// 读一个作品的绑定；没有 / 损坏都返回 null（不抛）。
BiliBinding? loadBinding(String provider, String id) {
  final raw = UiPrefs.get(BiliPrefs.bindKey(provider, id));
  if (raw == null || raw.isEmpty) return null;
  try {
    final o = jsonDecode(raw);
    final b = BiliBinding.fromJson(o);
    if (b == null) return null;
    // 手动标记单独存一个键（这样自动流程改绑时不会把它抹掉）
    final manual = UiPrefs.get(BiliPrefs.manualKey(provider, id)) == '1';
    return b.copyWith(manual: manual);
  } catch (_) {
    return null;
  }
}

/// 写一个作品的绑定。
void saveBinding(String provider, String id, BiliBinding b) {
  UiPrefs.set(BiliPrefs.bindKey(provider, id), jsonEncode(b.toJson()));
  if (b.manual) {
    UiPrefs.set(BiliPrefs.manualKey(provider, id), '1');
  } else {
    UiPrefs.remove(BiliPrefs.manualKey(provider, id));
  }
}

/// 删一个作品的绑定（连同手动标记）。
void clearBinding(String provider, String id) {
  UiPrefs.remove(BiliPrefs.bindKey(provider, id));
  UiPrefs.remove(BiliPrefs.manualKey(provider, id));
  UiPrefs.remove(BiliPrefs.pageKey(provider, id));
}

/// 是否手动绑过。
bool isManualBinding(String provider, String id) =>
    UiPrefs.get(BiliPrefs.manualKey(provider, id)) == '1';

// ══════════════════════════════════════════════════════════════════════
//  二、分集对齐
// ══════════════════════════════════════════════════════════════════════

/// 把「B 站视频的分 P 表」铺到「我们的剧集表」上。
///
/// [episodeTitles] 是本地剧集的标题（按集序），[pages] 是 B 站的分 P。
/// [forcedPage] > 0 时只绑这一集（用户手动指定 P 的情形）。
///
/// 返回的 episodeIndex 是**本地**集序（0 基）。
List<BiliEpisodeBinding> alignEpisodes({
  required List<String> episodeTitles,
  required List<BiliPage> pages,
  int forcedPage = 0,
  int forcedEpisode = -1,
}) {
  final out = <BiliEpisodeBinding>[];
  if (pages.isEmpty) return out;

  // C. 用户手动指定了 P —— 只绑一集。
  if (forcedPage > 0) {
    BiliPage? target;
    for (final p in pages) {
      if (p.page == forcedPage) {
        target = p;
        break;
      }
    }
    target ??= pages.first;
    final ei = forcedEpisode >= 0 ? forcedEpisode : 0;
    return <BiliEpisodeBinding>[
      BiliEpisodeBinding(
        episodeIndex: ei,
        page: target.page,
        cid: target.cid,
        part: target.part,
      ),
    ];
  }

  // A. 单 P —— 每一集都指向它。
  if (pages.length == 1) {
    final p = pages.first;
    for (var i = 0; i < episodeTitles.length; i++) {
      out.add(BiliEpisodeBinding(
        episodeIndex: i,
        page: p.page,
        cid: p.cid,
        part: p.part,
      ));
    }
    return out;
  }

  // B. 多 P —— 按 P 序对齐，多出来的本地集不绑。
  final n = episodeTitles.length < pages.length
      ? episodeTitles.length
      : pages.length;
  for (var i = 0; i < n; i++) {
    out.add(BiliEpisodeBinding(
      episodeIndex: i,
      page: pages[i].page,
      cid: pages[i].cid,
      part: pages[i].part,
    ));
  }
  return out;
}

/// 多 P 时，若本地某一集的标题与某个 P 明显更像，就用它覆盖按序的结论。
///
/// 为什么需要：B 站的 P 顺序和我们的集顺序**未必**一致
/// （搬运工把 P 顺序放乱是常事）。按序对齐是默认，标题对齐是修正。
///
/// 只有当标题相似度 >= [kBiliAutoBindThreshold] 时才覆盖，且一个 P 只能
/// 被一集占用（先到先得，不抢）。
List<BiliEpisodeBinding> refineByTitle({
  required List<String> episodeTitles,
  required List<BiliPage> pages,
  required List<BiliEpisodeBinding> base,
  double threshold = kBiliAutoBindThreshold,
}) {
  if (pages.length < 2 || base.isEmpty) return base;

  final used = <int>{};
  final result = <BiliEpisodeBinding>[];

  for (final b in base) {
    final title = b.episodeIndex < episodeTitles.length
        ? episodeTitles[b.episodeIndex]
        : '';
    if (title.trim().isEmpty) {
      result.add(b);
      used.add(b.page);
      continue;
    }

    var bestPage = b.page;
    var bestScore = 0.0;
    for (final p in pages) {
      if (used.contains(p.page)) continue;
      final s = titleSimilarity(title, p.part);
      if (s > bestScore) {
        bestScore = s;
        bestPage = p.page;
      }
    }

    if (bestScore >= threshold && bestPage != b.page) {
      BiliPage? target;
      for (final p in pages) {
        if (p.page == bestPage) {
          target = p;
          break;
        }
      }
      if (target != null && !used.contains(target.page)) {
        result.add(BiliEpisodeBinding(
          episodeIndex: b.episodeIndex,
          page: target.page,
          cid: target.cid,
          part: target.part,
        ));
        used.add(target.page);
        continue;
      }
    }

    if (!used.contains(b.page)) used.add(b.page);
    result.add(b);
  }
  return result;
}

// ══════════════════════════════════════════════════════════════════════
//  三、自动绑定
// ══════════════════════════════════════════════════════════════════════

/// 一次自动绑定的结果 —— 给 UI 显示「绑上了没、绑到哪」。
class BiliBindOutcome {
  const BiliBindOutcome({
    required this.binding,
    required this.score,
    required this.reason,
    this.created = false,
  });

  final BiliBinding binding;

  /// 视频标题与本地标题的最高相似度。
  final double score;

  /// 为什么是现在这个结果（给用户看的一句话）。
  final String reason;

  /// 这次是不是新建的绑定（false = 复用了已有的）。
  final bool created;

  bool get ok => !binding.isEmpty;

  @override
  String toString() => 'BiliBindOutcome(ok=$ok, '
      'score=${score.toStringAsFixed(3)}, $reason)';
}

/// 根据 B 站视频信息，给一部作品自动建/更新绑定。
///
/// [episodeTitles] 按集序；[localTitle] 是作品标题（用来算相似度）。
/// [existing] 是已有绑定（会保留手动标记，且**不会**覆盖手动绑定）。
///
/// 纯函数式：只算不写盘。落盘由 [persistOutcome] 或调用方决定 ——
/// 这样单测不用碰 UiPrefs。
BiliBindOutcome planBinding({
  required BiliVideoInfo info,
  required String localTitle,
  required List<String> episodeTitles,
  int forcedPage = 0,
  int forcedEpisode = -1,
  BiliBinding? existing,
}) {
  // 手动绑定过就不动它。
  if (existing != null && existing.manual && existing.bvid == info.bvid) {
    return BiliBindOutcome(
      binding: existing,
      score: titleSimilarity(localTitle, info.title),
      reason: '这是你手动绑的，自动流程不动它',
    );
  }

  final score = titleSimilarity(localTitle, info.title);

  var episodes = alignEpisodes(
    episodeTitles: episodeTitles,
    pages: info.pages,
    forcedPage: forcedPage,
    forcedEpisode: forcedEpisode,
  );
  if (forcedPage <= 0) {
    episodes = refineByTitle(
      episodeTitles: episodeTitles,
      pages: info.pages,
      base: episodes,
    );
  }

  final binding = BiliBinding(
    bvid: info.bvid,
    title: info.title,
    aid: info.aid,
    episodes: episodes,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
  );

  final String reason;
  if (episodes.isEmpty) {
    reason = 'B 站那边一个分 P 都没有，没法绑';
  } else if (forcedPage > 0) {
    reason = '按你指定的 P$forcedPage 绑了第 ${forcedEpisode + 1} 集';
  } else if (info.pages.length == 1) {
    reason = 'B 站是单 P 视频，${episodes.length} 集共用这一条弹幕时间轴';
  } else if (episodes.length < episodeTitles.length) {
    reason = 'B 站只有 ${info.pages.length} P，本地 '
        '${episodeTitles.length} 集，多出来的集没绑';
  } else {
    reason = '按 P 序对齐了 ${episodes.length} 集';
  }

  return BiliBindOutcome(
    binding: binding,
    score: score,
    reason: reason,
    created: existing == null || existing.bvid != info.bvid,
  );
}

/// 自动绑定要不要**拒绝**（标题差太多 + 用户没手动指定）。
///
/// 单 P 视频不做标题门槛：用户填了链接就是想绑，标题像不像无所谓。
bool shouldRejectAutoBind(BiliBindOutcome o, {bool isMultiPart = false}) {
  if (!isMultiPart) return false;
  return o.score < kBiliAutoBindThreshold;
}

/// 把 [planBinding] 的结果落盘。
void persistOutcome(
  String provider,
  String id,
  BiliBindOutcome o, {
  bool manual = false,
}) {
  final b = manual ? o.binding.copyWith(manual: true) : o.binding;
  saveBinding(provider, id, b);
}

// ══════════════════════════════════════════════════════════════════════
//  四、高层入口
// ══════════════════════════════════════════════════════════════════════

/// 一部作品 + 一个 B 站链接 → 绑定（含真实网络请求）。
///
/// 这是 UI 层唯一需要调的函数。它做四件事：
///   1. 解析输入（BV / av / 链接 / b23 短链）
///   2. 拉视频信息
///   3. 算分集对齐
///   4. 落盘
///
/// [manual] = true 时无条件接受（用户自己填的链接，不必过标题门槛）。
Future<BiliBindOutcome> bindFromInput({
  required BiliApi api,
  required String input,
  required String provider,
  required String id,
  required String localTitle,
  required List<String> episodeTitles,
  int forcedPage = 0,
  int forcedEpisode = -1,
  bool manual = true,
}) async {
  final parsed = parseBiliInput(input);
  if (parsed == null) {
    throw ArgumentError('没认出 BV 号 / av 号 / 链接');
  }
  final ref = await api.resolveShortLink(parsed);
  final info = await api.videoInfo(ref);

  final existing = loadBinding(provider, id);
  final outcome = planBinding(
    info: info,
    localTitle: localTitle,
    episodeTitles: episodeTitles,
    forcedPage: forcedPage,
    forcedEpisode: forcedEpisode,
    existing: existing,
  );

  persistOutcome(provider, id, outcome, manual: manual);
  return outcome;
}

// ══════════════════════════════════════════════════════════════════════
//  五、取某一集该用哪个 cid
// ══════════════════════════════════════════════════════════════════════

/// 给定「作品 + 第几集」，算出该用哪个 B 站 cid 去拉弹幕。
///
/// 返回 0 = 这一集没有绑定。
///
/// [episodeIndex] 是 0 基；[episodeId] 是可选的作品内集 id（有些源的集
/// 没有稳定序号，用 id 更靠得住 —— 但我们没有它的 B 站映射，故只用于
/// 单 P 情形的兜底判定）。
int resolveCid({
  required String provider,
  required String id,
  required int episodeIndex,
}) {
  final b = loadBinding(provider, id);
  if (b == null || b.isEmpty) return 0;
  final cid = b.cidFor(episodeIndex);
  if (cid > 0) return cid;
  // 越界（本地集数比绑定多）时退回第 0 集：单 P 场景下所有集共用一个 cid，
  // 这样「第 5 集但只绑了 3 集」也不会空手。
  if (b.episodes.length == 1) return b.episodes.first.cid;
  return 0;
}

/// 同上，但返回整个 [BiliEpisodeBinding]（UI 要显示「绑到 P 几」）。
BiliEpisodeBinding? resolveEpisodeBinding({
  required String provider,
  required String id,
  required int episodeIndex,
}) {
  final b = loadBinding(provider, id);
  if (b == null || b.isEmpty) return null;
  for (final e in b.episodes) {
    if (e.episodeIndex == episodeIndex) return e;
  }
  return b.episodes.length == 1 ? b.episodes.first : null;
}
