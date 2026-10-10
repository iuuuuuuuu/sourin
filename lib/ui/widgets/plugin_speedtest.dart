// ═══════════════════════════════════════════════════════════════════════
//  JS 插件测速 —— 「随机挑一部影片，实测下载速率」
//  （task-10 —— 2026-10-09）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 的澄清（逐字，本文件就是照这句写的）
//
// > js插件测速,指的是随机挑一部影片实测速率有多少,是指这个意思,
// > 你不要理解偏差了
//
// 所以这里**不是** ping 接口延迟，而是：
// ```text
// 插件 get_categories → get_list → 随机抽一部
//   → resolve_stream 拿到真实播放地址
//   → 用 dart:io 的 HttpClient 把这条流**真的下下来**
//   → 用 Stopwatch 算 MB/s
// ```
// 「速率」= 二进制单位 MB/s（1 MB = 1048576 B）。选它而不选「Mbps 网络单位」
// 是因为 Windows 上的任务管理器/浏览器下载都以 MB/s 显示 —— 用户拿我们的
// 数字跟它们对照时才不会差 8 倍（还要自己乘）。
//
// # ★★★ 为什么不能只下载 M3U8 清单（这是本功能最容易做错的地方）
//
// 随机抽到的那部片子，它的 resolve_stream 回的是 **HLS 的 m3u8 清单**。
// 清单本身只有 **201~202 字节**（本机实测，见下面的真机读数），
// 里面一行视频数据都没有。如果直接拿它计时：
// ```text
// 201 B ÷ 3 ms ≈ 0.066 MB/s        ← 量到的是"下载一个小文本文件"的速度
// ```
// 这个数字**又假又稳定**：永远是网络往返延迟的倒数，跟这部片子、
// 这条线路、这台机器都无关。它不会报错、不会崩溃，只会一直给出一个错的数。
// ⇒ 必须**钻进清单**里拿真正的分片地址。
//
// ## 但要钻**一层**，而且是主列表那层
//
// HLS 的清单是分层的：
// ```text
// 主列表（master）  里面是 #EXT-X-STREAM-INF + 子清单地址（若干清晰度）
//   └─ 子清单（media） 里面是 #EXTINF + 分片地址（.ts / .m4s）
//        └─ 分片       真正的视频字节
// ```
// 本机实测两种形态**都真实存在**（同一次探针里）：
// ```text
// caiji    主列表 201 B → 1 条 #EXT-X-STREAM-INF → 子清单 1491 片
// suoniapi 主列表 202 B → 1 条 #EXT-X-STREAM-INF → 子清单 3246 片
// ```
// 所以「第几层是子清单」不能写死，只能看内容里有没有 #EXT-X-STREAM-INF，
// 有就再下一层。**最多下钻一次** —— 避免遇到畸形清单时无限循环。
//
// ## 为什么不复用 hls_download 里那个解析器
//
// lib/core/hls_download.dart 已经有一个很完整的 parseHlsPlaylist，
// 但它按「整片下载」的需求设计，**三处语义与测速相反**：
// ```text
// ① 它遇到加密流直接 throw —— 测速只要分片能下下来就能量速度，
//    不该因为"下不出整片"就拒绝测。这里只把"加密"降级成一句如实说明。
// ② 它要 #EXT-X-ENDLIST（点播）才肯干活 —— 直播清单没有 ENDLIST，
//    但它照样是分片，照样能量速度。（本功能取的是点播作品，
//    正常都有 ENDLIST；这里只是**不用它当门槛**。）
// ③ 它把每个分片完整读进内存并拼成文件 —— 测速只要字节数，
//    读完整片既慢又多占内存。
// ```
// ★ 而且它是 lib/core/ 的文件，**不在本次允许改动的范围内**（写范围只有本文件）。
// ⇒ 这里自带一个约 30 行的轻量解析：只管「有哪些子清单 / 有哪些分片」。
// 不是"重复造轮子"，是"两条链路的判据本来就不同"。
//
// # 为什么必须先预热再计时（首片进不了统计）
//
// 本机实测同一条流的读数：
// ```text
// caiji     首片 324488 B /  572 ms = 0.54 MB/s     ← 含连接+TTFB
//           连读 3 片 4936692 B / 1608 ms = 2.93 MB/s
// suoniapi  首片  69560 B / 1415 ms = 0.05 MB/s     ← ★ 慢了 11 倍
//           连读 14 片 3964544 B / 6152 ms = 0.61 MB/s
// ```
// 首片那一段时间里混着：DNS 解析、TCP 握手、TLS 握手、上游回源、
// 有时还有代理侧的预取启动。**这些都是一次性开销**，把它们算进速率
// 会系统性低估 —— suoniapi 那条会从 0.61 被拉到 0.05（12 倍偏差），
// 用户看到"0.05 MB/s"会以为这条线路废了，实际它能正常播。
// ⇒ 正式计时从**读满预热字节之后**才开始（[_warmupBytes]）。
//
// # 为什么窗口取 6 秒（而不是"下满 12MB"或"只下一片"）
//
// ```text
// 只下一片     15 个插件的总耗时不可控 —— 每片大小随源差 5 倍以上
//              （实测 69 KB / 324 KB），慢站一片要 1.4 s
// 下满 12MB    按实测 0.61 MB/s 的慢站要 **20 秒** —— 正好吃掉全部超时预算，
//              快的站（2.93 MB/s）只要 4 秒 ⇒ 快站反而先超时，荒谬
// 固定 6 秒    ★ 快站 6 秒读 ~17MB（被 12MB 上限截断，仍有 4 秒余量）
//              慢站 6 秒读 ~4MB（远不到上限）
//              ⇒ 快慢两台机器最坏都是「6 秒 + 一片的尾巴」，可预期
// ```
// ⚠️ 计时**只在分片数够时**才停（见 [_minSegmentsForWindow]）——
//    否则碰到一片 10 秒的超大分片，窗口会失去意义。
//
// # 为什么在**分片边界**看超时（而不是给整条流程一个 deadline）
//
// 单个分片可能很大（实测 324 KB），上游卡住时一个 await 就能挂住 20 秒。
// 所以把总预算拿到**每个分片开始之前**查一次：
// ```text
// 已经读完的字节**照样算数**（它们是真下下来的），
// 只是不再为下一片冒超时的风险 ⇒ 超时也能给出一个**真实的**速率，
// 而不是像"整条流程超时"那样一个数都拿不到。
// ```
// 这与 hls_download.dart 在分片边界检查暂停/取消是同一个手法
// （那里也解释了为什么边界是安全的切点）。
//
// # ★ 失败与"慢"是两件事，本文件不许把它们混起来
//
// ```text
// 失败    HTTP 403 / 上游 502 / 解析出错 / 一片都没读到
//           → 存 ok=false + 原因原文，**绝不当成 0 MB/s 展示**
//           含义：「这次没量到」，用户该看原因、或者重试
// 慢      读到了字节，但速率低于 [_minMiBps]
//           → 存 ok=true + 真实数字（可能是 0.01）
//           含义：「量到了，就是慢」—— 这是**结论**，不是错误
// ```
// ★ 为什么这条必须写死：本机实测就有一条真的 0 字节失败
// （tyyszy 上游 502，播放列表正文是「取流失败: error sending request …」）。
// 如果把它显示成「0.00 MB/s」，用户会以为这个源"很慢"，而它其实是**这次连不上**。
// 反过来把 0.01 MB/s 的慢源显示成"失败"同样是错的 ——
// **没有的能力不假装有，有的结论也不许打折。**
//
// ⚠️ 还有一个陷阱：上游出错时，代理返回的是 **HTTP 403 / 502 加一段中文说明**，
//    正文不是 m3u8。所以判"失败"不能只看状态码 —— 更要看**正文开头是不是
//    #EXTM3U**。本机实测那两段中文说明就是这样被认出来的
//    （否则会被当成"一个没有分片的清单"，然后报一句误导人的"没有分片"）。
//
// # 超时怎么算
//
// 单插件总预算 [_timeout] 20 秒，覆盖「取列表 → 解析候选 → 预热 → 计时窗口」
// 整条链路；计时窗口自己最多占 [_windowCap] 6 秒 ⇒ 还留了 14 秒给网络往返。
// 列表接口特别慢的源（实测最慢 3.3 秒）也在预算内。
//
// # 持久化
//
// 键：dsh.speedtest.<pluginId>（与仓里 dsh.download.* / dsh.cache.*
// 同一命名风格），值是**一个 JSON 对象**：{items:[…], summary:{…}}。
// items 只保留最近 [_keepRuns] 次，**从旧到新**排列（新的在最后）——
// 这样追加是"push 到队尾"，读倒序就是"最近一次在最前"。
// 写入时连带更新 summary（次数 / 平均 / 最快 / 最慢），它是**从 items
// 算出来的缓存**，不是第二份真相：读的时候会重算，旧文件里没有 summary 也不崩。
//
// ⚠️ 保留上限是**必须**的（不是优化）：26 个插件 × 每 6 秒一条，
//    「全部测速」点几次文件就会无界增长。到上限时丢最旧的一条。
//
// # 地址脱敏（存下来之前必须做）
//
// 采集站的播放地址带一次性签名（本机实测形如 …/index.m3u8?auth_key=…）。
// 测速记录会落到 ui-prefs.json（用户会备份、会贴出来排查），
// 原样存进去等于把播放凭证抄了一份到明文文件里。
// ⇒ 落盘/展示的地址一律过 [redactUrl]，只留 scheme://host/path。
// ⚠️ 这**不影响测速本身** —— 下载用的永远是内存里那条完整地址。
//
// # ⚠️ 测这条链路时被测仪器坑过一次（记下来，别重踩）
//
// 用 flutter test 驱动真机验证时，HttpClient 会**全部回 HTTP 400 且一个字节
// 都不发出去**（flutter_test 的 TestWidgetsFlutterBinding 默认把全局
// HttpClient 换成 mock，见 test/t69_dlna_test.dart:39-61 同一处记录）。
// 本探针第一版就是这样拿到"全部源 400"的，而**产品代码本身是对的**：
// 换成原始 TCP 打同一个地址，回的是干净的 200 + 合法 m3u8
// （见下方真机读数里的实测报文）。⇒ 真机探针必须先把真 HttpClient 装回去，
// 否则量到的全是仪器的 400。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/app_log.dart';
/*
 * ⚠️ 不单独 import models.dart —— sourin_api.dart 已经把它整体 export
 *    出来了（那个文件的注释里写明了「调用方只需一次 import 就拿到
 *    API + 全部模型」，analyze 也会对重复 import 报
 *    unnecessary_import）。
 */
import '../../core/sourin_api.dart';
import '../../core/ui_prefs.dart';
import '../tokens.dart';

// ═══════════════════════════════════════════════════════════════════════
//  参数（可以调，但改了要重跑真机���数 —— 见文件头各段的实测依据）
// ═══════════════════════════════════════════════════════════════════════

/// 预热的字节数：读满这么多之后才开始正式计时
///
/// 让它大于"最大的一条流的首片"即可 —— 本机实测最大首片 324 KB，
/// 取 1 MiB 有 3 倍余量，同时**足够便宜**：
/// ```text
/// 快站 2.93 MB/s ⇒ 0.34 s（占总耗时 5%）
/// 慢站 0.61 MB/s ⇒ 1.64 s（占 21%，换掉的是 12 倍的偏差，值）
/// ```
const int _warmupBytes = 1024 * 1024;

/// 正式计时窗口：到点就收工（见文件头"窗口取 6 秒"整段推导）
const Duration _windowCap = Duration(seconds: 6);

/// 单次测速的字节上限（防止极快的线路把时间和内存吃光）
///
/// 6 秒 × 2.93 MB/s ≈ 17.6 MB 会撞到这个上限 —— 那是**有意的**：
/// 上限只截断"已经拿到足够多证据"的极快线路，对结论没有影响
/// （17 MB 与 12 MB 算出来的 MB/s 都远超任何"卡不卡"的判据）。
const int _maxBytes = 12 * 1024 * 1024;

/// 计时窗口内**最少要读完的分片数**
///
/// 为什么不只靠时间：一片的真实大小从 69 KB 到 324 KB 都有，
/// 更极端的情况（上游切成 10 秒一片）会让"6 秒"只覆盖半片。
/// 要求至少 3 片，才保证窗口里是**连续的流**而不是一次抖动。
const int _minSegmentsForWindow = 3;

/// 单插件总预算（覆盖列表 → 解析 → 预热 → 窗口 整条链路）
const Duration _timeout = Duration(seconds: 20);

/// 单个 HTTP 请求的连接/响应头超时
const Duration _httpTimeout = Duration(seconds: 12);

/// 低于这个速率就如实标成「很慢」（**不是**失败 —— 见文件头那段）
const double _minMiBps = 0.05;

/// 每个插件保留最近几次结果
const int _keepRuns = 10;

/// 最多跳掉几部不可播的作品（每跳一部都要重新抽）
///
/// 为什么要跳：bilibili 这种源里混着「需要大会员」的条目，
/// 本机实测随机抽就抽到过一次（探针原话：「该内容需要大会员（当前是试看片段）」）。
/// 抱着第一个不可播的作品不放手，会让这个插件永远测不了。
///
/// 为什么有上限：上限 4 次之后**如实**报「连抽 4 部都播不了」——
/// 那本身是有价值的结论（这个源今天整体取不到流），比硬凑一个数字强。
const int _maxRebuildAttempts = 4;

/// 速率配色阈值（MB/s）—— ���影响颜色，不改数字
const double _slowMiBps = 0.5;
const double _fastMiBps = 2.0;

// ═══════════════════════════════════════════════════════════════════════
//  数据模型
// ═══════════════════════════════════════════════════════════════════════

/// 一次测速的结果
class PluginSpeedRun {
  const PluginSpeedRun({
    required this.ts,
    required this.ok,
    required this.mbPerSec,
    this.bytes = 0,
    this.ms = 0,
    this.segments = 0,
    this.sampleTitle,
    this.sampleId,
    this.url,
    this.error,
    this.note,
  });

  /// 完成时刻（本地时间）
  final DateTime ts;

  /// 有没有**真的量到**速率
  ///
  /// false = 没有量到（原因见 [error]），此时 [mbPerSec] 恒为 0
  /// 且**不该当成绩展示** —— 见文件头"失败与慢是两件事"整段。
  final bool ok;

  /// 二进制 MB/s（1 MB = 1048576 B）
  final double mbPerSec;

  /// 计时窗口内读到的字节数（不含预热部分）
  final int bytes;

  /// 计时窗口的毫秒数
  final int ms;

  /// 计时窗口内读完的分片数
  final int segments;

  /// 随机抽中的那部片子（给用户看"测的是哪一部"）
  final String? sampleTitle;
  final String? sampleId;

  /// 实���下载的地址（**已脱敏** —— 见 [redactUrl]）
  final String? url;

  /// 没量到时的**原因原文**（如 HTTP 403、连抽 4 部都不可播放）
  final String? error;

  /// 量到了、但值得说明一句时的事实（如 这条流是加密的、已到 20 秒预算）
  final String? note;

  double get mb => bytes / 1048576.0;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ts': ts.millisecondsSinceEpoch,
    'ok': ok,
    'mbps': mbPerSec,
    'bytes': bytes,
    'ms': ms,
    'segments': segments,
    if (sampleTitle != null) 'title': sampleTitle,
    if (sampleId != null) 'id': sampleId,
    if (url != null) 'url': url,
    if (error != null) 'error': error,
    if (note != null) 'note': note,
  };

  static PluginSpeedRun? fromJson(Object? j) {
    if (j is! Map) return null;
    final ts = j['ts'];
    return PluginSpeedRun(
      ts: DateTime.fromMillisecondsSinceEpoch(
        ts is num ? ts.toInt() : DateTime.now().millisecondsSinceEpoch,
      ),
      ok: j['ok'] == true,
      mbPerSec: (j['mbps'] as num?)?.toDouble() ?? 0,
      bytes: (j['bytes'] as num?)?.toInt() ?? 0,
      ms: (j['ms'] as num?)?.toInt() ?? 0,
      segments: (j['segments'] as num?)?.toInt() ?? 0,
      sampleTitle: j['title'] as String?,
      sampleId: j['id'] as String?,
      url: j['url'] as String?,
      error: j['error'] as String?,
      note: j['note'] as String?,
    );
  }
}

/// 一个插件的历史（**所有统计量都从 items 现算**，不存第二份真相）
class PluginSpeedHistory {
  const PluginSpeedHistory(this.items);

  /// 从旧到新
  final List<PluginSpeedRun> items;

  int get runs => items.length;
  int get okRuns => items.where((e) => e.ok).length;

  /// 最近一次（没有则 null）
  PluginSpeedRun? get last => items.isEmpty ? null : items.last;

  /// 最近一次**量到过**的结果（全失败时是 null）
  PluginSpeedRun? get lastOk {
    for (var i = items.length - 1; i >= 0; i--) {
      if (items[i].ok) return items[i];
    }
    return null;
  }

  double get avgMiBps {
    final ok = items.where((e) => e.ok).toList();
    if (ok.isEmpty) return 0;
    return ok.fold<double>(0, (a, e) => a + e.mbPerSec) / ok.length;
  }

  double get bestMiBps => items
      .where((e) => e.ok)
      .fold<double>(0, (a, e) => math.max(a, e.mbPerSec));

  double get worstMiBps {
    final ok = items.where((e) => e.ok).toList();
    if (ok.isEmpty) return 0;
    return ok.fold<double>(double.infinity, (a, e) => math.min(a, e.mbPerSec));
  }

  static PluginSpeedHistory parse(String? raw) {
    if (raw == null || raw.isEmpty) return const PluginSpeedHistory([]);
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return const PluginSpeedHistory([]);
      final list = j['items'];
      if (list is! List) return const PluginSpeedHistory([]);
      final out = <PluginSpeedRun>[];
      for (final e in list) {
        final r = PluginSpeedRun.fromJson(e);
        if (r != null) out.add(r);
      }
      return PluginSpeedHistory(out);
    } on Object {
      // 文件坏了 → 当"从没测过"，不崩、不谎报（同 UiPrefs 的降级策略）
      return const PluginSpeedHistory([]);
    }
  }

  String encode() => jsonEncode(<String, dynamic>{
    'items': <dynamic>[for (final e in items) e.toJson()],
    // ★ summary 只是给人/别的工具看的缓存，读的时候不看它（见文件头）
    'summary': <String, dynamic>{
      'runs': runs,
      'ok': okRuns,
      'avg': avgMiBps,
      'best': bestMiBps,
      'worst': items.any((e) => e.ok) ? worstMiBps : 0,
    },
  });
}

// ═══════════════════════════════════════════════════════════════════════
//  持久化（键前缀 dsh.speedtest.）
// ═══════════════════════════════════════════════════════════════════════

/// 测速结果的本地存储
///
/// # 为什么是**静态类**而不是实例
/// UiPrefs 本身就是进程级静态存储（它对应原版的 localStorage），
/// 没有"多个实例"的语义。做成实例方法会让人以为可以有几份互不相干的记录。
class PluginSpeedTest {
  PluginSpeedTest._();

  static const String keyPrefix = 'dsh.speedtest.';

  /// ★★★ 记录变化通知（一次测速完成 / 清空时 +1）
  ///
  /// # 为什么**必须**有它（这是真机实测抓出来的一个真缺陷）
  ///
  /// 「全部测速」是顺序跑 26 个源的，跑的时候**卡片早就挂在那里了**
  /// —— 它们各自的 `initState` 早在打开二级页时就跑完了。
  /// 面板只在 initState 里读一次历史，于是：测完 26 个源，
  /// **26 张卡上一片空白，直到退出再进来才看得到读数**。
  ///
  /// 实测证据（本任务的验证探针，修之前）：
  /// ```text
  /// 空态文本    = [测速, 还没测过 —— 随机挑一部影片，真下一段算 MB/s]
  /// 写入一条记录后再 pump：
  /// 有记录时的文本 = [测速, 还没测过 —— 随机挑一部影片，真下一段算 MB/s]   ← ★ 没变
  /// ```
  /// 数据明明写进去了（磁盘上都有），**界面上看不出来** —— 这就是
  /// 「数据有 ≠ 用户看得见」，也正是本仓反复记录的那类静默缺陷。
  ///
  /// 用 `ValueNotifier<int>` 而不是让 26 个面板各自轮询：轮询要么慢
  /// （用户以为没反应）要么费（每 100ms 读 26 次磁盘 JSON）。
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static String keyOf(String pluginId) => '$keyPrefix$pluginId';

  /// 读某个插件的历史（**按需现算**，见 [PluginSpeedHistory]）
  static PluginSpeedHistory read(String pluginId) =>
      PluginSpeedHistory.parse(UiPrefs.get(keyOf(pluginId)));

  /// 追加一次结果，只保留最近 [_keepRuns] 次
  static PluginSpeedHistory append(String pluginId, PluginSpeedRun run) {
    final old = read(pluginId);
    final items = <PluginSpeedRun>[...old.items, run];
    // 超出上限时丢**最旧**的（列表是旧的在前）
    final kept = items.length > _keepRuns
        ? items.sublist(items.length - _keepRuns)
        : items;
    final h = PluginSpeedHistory(kept);
    UiPrefs.set(keyOf(pluginId), h.encode());
    // ★ 通知已挂载的面板重读（见 changes 的说明：没有这一步，
    //   「全部测速」跑完界面上还是"还没测过"）
    changes.value++;
    return h;
  }

  /// 清空某个插件的记录
  static void clear(String pluginId) {
    UiPrefs.remove(keyOf(pluginId));
    changes.value++;
  }

  /// 清空一批插件的记录 → 返回被清掉几个
  static int clearAll(Iterable<String> pluginIds) {
    var n = 0;
    for (final id in pluginIds.toSet()) {
      if (UiPrefs.get(keyOf(id)) != null) {
        UiPrefs.remove(keyOf(id));
        n++;
      }
    }
    if (n > 0) changes.value++;
    return n;
  }

  // ── 展示用的格式化（把"数字怎么读"收敛在一处，别在 UI 里各写一遍）──

  /// 速率：统一两位小数（2.93 MB/s / 0.61 MB/s），低于 0.01 才用三位
  static String speedText(double mbps) {
    if (mbps <= 0) return '0.00 MB/s';
    final s = mbps < 0.01 ? mbps.toStringAsFixed(3) : mbps.toStringAsFixed(2);
    return '$s MB/s';
  }

  /// 体积：MB 一位小数；不足 1 MB 用 KB（否则会显示 0.0 MB，丢信息）
  static String sizeText(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).round()} KB';
  }

  /// 时长：1 秒以上用 1.6 s，以下用 572 ms
  static String msText(int ms) {
    if (ms >= 1000) return '${(ms / 1000).toStringAsFixed(1)} s';
    return '$ms ms';
  }

  /// 相对时间：刚刚 / N 分钟前 / N 小时前 / 昨天 hh:mm / MM-dd hh:mm
  static String agoText(DateTime t, [DateTime? now]) {
    final n = now ?? DateTime.now();
    final d = n.difference(t);
    if (d.inSeconds < 60) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    if (d.inDays == 1) return '昨天 ${_two(t.hour)}:${_two(t.minute)}';
    return '${_two(t.month)}-${_two(t.day)} '
        '${_two(t.hour)}:${_two(t.minute)}';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

/// 把地址里的**签名 query 抹掉**再存/再显示
///
/// # 为什么必须做
/// 采集站的地址长这样（本机真实读数的形态，已脱敏）：
/// ```text
/// https://vip.xxx.com/20261009/40301_f74b25a7/index.m3u8?auth_key=...
/// ```
/// 那把 auth_key 常常就是**一次性播放凭证**。测速记录会落到
/// ui-prefs.json（用户会备份、会贴给群友排查），原样存进去等于
/// 把凭证抄了一份到明文文件里。
/// ⇒ 只保留 scheme://host/path，query 一律省略。
///
/// ⚠️ 这**不影响测速本身**（下载用的永远是内存里那条完整地址），
///    只影响"存下来给你看的那一份"。
String redactUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return url;
  final hasQuery = u.hasQuery || u.hasFragment;
  final base = '${u.scheme}://${u.authority}${u.path}';
  return hasQuery ? '$base?…' : base;
}

// ═══════════════════════════════════════════════════════════════════════
//  测量引擎
// ═══════════════════════════════════════════════════════════════════════

/// 速率测量的真机读数都写在文件头，改动前先读那几段
class PluginSpeedTestRunner {
  PluginSpeedTestRunner._();

  /// 测一个插件（**只测量、不落盘** —— 落盘由调用方决定）
  ///
  /// # 谁调用它
  /// ```text
  /// ① 卡片上的「测速」按钮        → PluginSpeedTestPanel
  /// ② 「全部测速」（顺序跑）      → PluginSpeedTestAllButton
  /// ```
  /// 返回的 [PluginSpeedRun] **总是非空** —— 失败也如实返回一条
  /// ok=false 的记录，绝不抛异常让界面自己收拾
  /// （界面要显示"为什么失败"，而异常只能给出一个类型名）。
  static Future<PluginSpeedRun> run(String pluginId) async {
    final budget = Stopwatch()..start();
    try {
      return await _measure(pluginId, budget).timeout(
        _timeout,
        // 超时也要**如实**说明是多少秒的预算，不是一句"超时了"
        onTimeout: () => throw _BudgetExceeded(
          '超过 ${_timeout.inSeconds} 秒预算（还没读到可用分片）',
        ),
      );
    } on _BudgetExceeded catch (e) {
      return _fail(budget, e.message);
    } on Object catch (e) {
      /*
       * ★ 不吞错误 —— 把原文（含 SourinCoreException 的中文原因）带回去。
       *
       * 本机实测会遇到的两类：
       *   cycani  「登录已失效，请到「设置 → 账号登录」重新登录」
       *   bilibili「该内容需要大会员（当前是试看片段）」
       * 这两句本身就是用户要的答案，压成"测速失败"反而没用。
       */
      return _fail(budget, _short(e));
    }
  }

  static PluginSpeedRun _fail(Stopwatch budget, String reason) =>
      PluginSpeedRun(
        ts: DateTime.now(),
        ok: false,
        mbPerSec: 0,
        ms: budget.elapsedMilliseconds,
        error: reason,
      );

  /// 把异常压成一行（异常原文可能带整段栈信息与 JSON）
  static String _short(Object e) {
    var s = e.toString();
    if (s.startsWith('SourinCoreException')) {
      final i = s.indexOf(': ');
      if (i > 0) s = s.substring(i + 2);
    }
    s = s.split('\n').first.trim();
    if (s.isEmpty) s = '未知错误';
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  static Future<PluginSpeedRun> _measure(
    String pluginId,
    Stopwatch budget,
  ) async {
    // ── ① 随机抽一部影片（跳掉不可播的，见 [_maxRebuildAttempts]）──
    ({MediaItem item, StreamCandidate? cand})? sample;
    final tried = <String>[];
    var lastFail = '没有可用的影片（分类/列表都是空的）';

    for (var attempt = 0; attempt < _maxRebuildAttempts; attempt++) {
      final pick = await _pickRandom(pluginId);
      if (pick == null) {
        lastFail = '这个源没有返回任何作品（分类为空或列表为空）';
        break;
      }
      final name = pick.item.title.isEmpty ? pick.item.id : pick.item.title;
      tried.add(name);

      if (pick.cand == null) {
        lastFail = '《$name》解析不出可播放的地址';
        continue;
      }
      sample = pick;
      break;
    }

    if (sample == null) {
      final reason = tried.length > 1
          ? '连抽 ${tried.length} 部都播不了（最后一部：$lastFail）'
          : lastFail;
      return PluginSpeedRun(
        ts: DateTime.now(),
        ok: false,
        mbPerSec: 0,
        ms: budget.elapsedMilliseconds,
        sampleTitle: tried.isEmpty ? null : tried.last,
        error: reason,
      );
    }

    final cand = sample.cand!;
    final title = sample.item.title;
    final sampleId = sample.item.id;
    final shownUrl = redactUrl(cand.url);

    // ── ② 把清单钻成"能直接下的一串分片" ──
    final client = HttpClient()
      ..connectionTimeout = _httpTimeout
      ..userAgent = 'SourinSpike/1.0';

    try {
      final playlist = await _openPlaylist(client, cand, budget);
      if (playlist.segments.isEmpty) {
        /*
         * ★ 走到这里说明：HTTP 是通的、正文也像清单，但一个分片都没有。
         *
         * 实测最容易出现的是**加密流**（存在 #EXT-X-KEY 且 METHOD 不是 NONE）：
         * 这种流的地址确实在清单里，但是密文，我们没有 AES 依赖。
         * hls_download.dart 对同一情形也是**明确报错**而不是硬下 ——
         * 这里同样如实说明，不假装量到了一个数字。
         */
        return PluginSpeedRun(
          ts: DateTime.now(),
          ok: false,
          mbPerSec: 0,
          ms: budget.elapsedMilliseconds,
          sampleTitle: title,
          sampleId: sampleId,
          url: shownUrl,
          error: playlist.encrypted
              ? '这条流是加密的（AES-128），当前版本不支持解密下载'
              : '播放列表里没有可下载的分片',
        );
      }

      // ── ③ 真下载：先预热，再计时 ──
      final sw = Stopwatch()..start();
      var total = 0; // 预热 + 计时，用于总量上限
      var warm = 0; // 预热已读
      var bytes = 0; // ★ 计时窗口内已读
      var segs = 0; // ★ 计时窗口内读完的分片数
      var timed = false;
      var stoppedEarly = false;
      String? note =
          playlist.encrypted ? '这条流是加密的，只有部分分片能直接下' : null;
      var segIndex = 0;

      for (final seg in playlist.segments) {
        // 预算用完 → 停在分片边界（已读字节照样算数，见文件头）
        if (budget.elapsedMilliseconds >= _timeout.inMilliseconds) {
          stoppedEarly = true;
          note = '已到 ${_timeout.inSeconds} 秒预算，按已读部分计速';
          break;
        }
        if (total >= _maxBytes) break;
        if (timed && sw.elapsed >= _windowCap && segs >= _minSegmentsForWindow) {
          break;
        }

        final got = await _downloadSegment(client, seg, cand.headers);
        segIndex++;
        if (got.bytes <= 0) {
          /*
           * 分片失败：**如果还一片都没读到**，那是真失败（上游拒绝/地址过期）；
           * 如果已经读到了字节，就用已读部分计速 —— 真实读数比
           * 「因为最后一片 403 就全盘作废」有用得多（用户要的是"这条线快不快"）。
           */
          if (!timed && segs == 0 && bytes == 0) {
            return PluginSpeedRun(
              ts: DateTime.now(),
              ok: false,
              mbPerSec: 0,
              ms: budget.elapsedMilliseconds,
              sampleTitle: title,
              sampleId: sampleId,
              url: shownUrl,
              error: '分片下载失败（第 $segIndex 片，${got.reason}）',
            );
          }
          note ??= '第 $segIndex 片起上游拒绝，按已读部分计速';
          stoppedEarly = true;
          break;
        }

        total += got.bytes;
        if (!timed) {
          warm += got.bytes;
          // 预热够了就翻面：此刻起计时的字节才进统计
          if (warm >= _warmupBytes) {
            timed = true;
            sw.reset();
          }
        } else {
          bytes += got.bytes;
          segs++;
        }
      }

      final ms = sw.elapsedMilliseconds;

      /*
       * ★ 预算耗尽或全程预热 ⇒ **没有计时段**。
       *
       * 这里必须如实报"没量到"，不能拿预热那段的字节凑一个数 ——
       * 那段的数字里混着握手/回源开销（详见文件头"为什么必须先预热"）。
       */
      if (!timed || bytes <= 0 || ms <= 0) {
        return PluginSpeedRun(
          ts: DateTime.now(),
          ok: false,
          mbPerSec: 0,
          ms: ms,
          segments: segs,
          sampleTitle: title,
          sampleId: sampleId,
          url: shownUrl,
          error: total > 0
              ? '只读到预热用的 ${PluginSpeedTest.sizeText(total)}，没进入计时窗口'
              : '一个字节都没读到',
        );
      }

      final mbps = (bytes / 1048576.0) / (ms / 1000.0);
      if (mbps < _minMiBps) {
        note = <String>[
          if (note != null) note,
          '这条线路很慢（低于 ${_minMiBps.toStringAsFixed(2)} MB/s）',
        ].join('；');
      }
      if (stoppedEarly && note == null) note = '按已读部分计速';

      return PluginSpeedRun(
        ts: DateTime.now(),
        ok: true,
        mbPerSec: mbps,
        bytes: bytes,
        ms: ms,
        segments: segs,
        sampleTitle: title,
        sampleId: sampleId,
        url: shownUrl,
        note: note,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 随机抽一部 + 解析出第一个可播候选
  ///
  /// 返回 null = 这个源（这次）根本没有可用内容。
  /// cand 为 null = 抽中的那一部解析不出可播地址（调用方会再抽一次）。
  static Future<({MediaItem item, StreamCandidate? cand})?> _pickRandom(
    String pluginId,
  ) async {
    List<Category> cats = const [];
    try {
      cats = await SourinApi.getCategories(pluginId);
    } on Object {
      // 部分源本来就没有分类（本机实测 iptv / tvbox-live 返回 0 个），
      // 那不是错误 —— 继续走"列表为空"那条如实分支。
      cats = const [];
    }

    final rnd = math.Random();
    var items = const <MediaItem>[];
    if (cats.isNotEmpty) {
      final cat = cats[rnd.nextInt(cats.length)];
      final page = await SourinApi.getList(pluginId, cat.id);
      items = page.items;
    }
    if (items.isEmpty) return null;

    final item = items[rnd.nextInt(items.length)];
    try {
      final cands = await SourinApi.resolveStream(pluginId, item.id);
      StreamCandidate? first;
      for (final c in cands) {
        if (c.isPlayable) {
          first = c;
          break;
        }
      }
      return (item: item, cand: first);
    } on Object {
      // 需要登录 / 需要大会员 —— 由调用方决定是再抽一次还是放弃
      return (item: item, cand: null);
    }
  }

  /// 打开播放清单，必要时**下钻一层**拿到真正的分片地址
  ///
  /// 见文件头的"要钻一层"整段：主列表里是子清单、子清单里才是分片。
  static Future<_Playlist> _openPlaylist(
    HttpClient client,
    StreamCandidate cand,
    Stopwatch budget,
  ) async {
    final master = await _httpText(client, cand.url, cand.headers, budget);
    if (master == null) {
      throw _BudgetExceeded('播放列表取不到（连接失败或超时）');
    }
    if (!master.text.startsWith('#EXTM3U')) {
      /*
       * ★ 最关键的一行判据：**正文开头不是 #EXTM3U 就不是清单**。
       *
       * 上游出错时核心层的代理会回一段中文说明的正文，本机实测两种：
       *   「上游返回 403 （可能被防盗链拦截或地址已过期）」
       *   「取流失败: error sending request for url (…)」
       * 只看状态码是不够的（状态码可能是 200 带 HTML 播放器页面）。
       */
      throw _BudgetExceeded(
        '返回的不是播放列表（HTTP ${master.status}）：'
        '${_oneLine(master.text)}',
      );
    }

    var pl = _Playlist.parse(master.text);
    if (pl.variants.isNotEmpty) {
      final next = await _httpText(
        client,
        pl.variants.first,
        cand.headers,
        budget,
      );
      if (next == null) {
        throw _BudgetExceeded('子播放列表取不到（主列表里的第一条清晰度）');
      }
      if (!next.text.startsWith('#EXTM3U')) {
        throw _BudgetExceeded(
          '子播放列表不是 m3u8（HTTP ${next.status}）：'
          '${_oneLine(next.text)}',
        );
      }
      pl = _Playlist.parse(next.text);
    }
    return pl;
  }

  static String _oneLine(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return '(空响应)';
    return t.length > 120 ? '${t.substring(0, 120)}…' : t;
  }

  /// 读一个分片；失败返回**原因**（不是抛异常 —— 见调用点那段说明）
  static Future<_SegResult> _downloadSegment(
    HttpClient client,
    String url,
    List<(String, String)> headers,
  ) async {
    try {
      final req = await client.getUrl(Uri.parse(url));
      for (final h in headers) {
        req.headers.set(h.$1, h.$2);
      }
      final resp = await req.close().timeout(_httpTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        // 必须把流抽干，否则连接不会回收（keep-alive 的坑）
        await resp.drain<void>();
        return _SegResult.fail('HTTP ${resp.statusCode}');
      }
      var n = 0;
      await for (final chunk in resp) {
        n += chunk.length;
      }
      if (n <= 0) return const _SegResult.fail('HTTP 200 但正文是空的');
      return _SegResult.ok(n);
    } on Object catch (e) {
      return _SegResult.fail(_short(e));
    }
  }

  /// 取一段文本（清单）。失败返回 null，由调用方给出语义化的原因。
  static Future<_TextResult?> _httpText(
    HttpClient client,
    String url,
    List<(String, String)> headers,
    Stopwatch budget,
  ) async {
    if (budget.elapsedMilliseconds >= _timeout.inMilliseconds) return null;
    try {
      final req = await client.getUrl(Uri.parse(url));
      for (final h in headers) {
        req.headers.set(h.$1, h.$2);
      }
      final resp = await req.close().timeout(_httpTimeout);
      final bytes = <int>[];
      await for (final chunk in resp) {
        bytes.addAll(chunk);
        // 清单是几 KB 的东西；读到 4 MB 还在涨说明这不是清单
        if (bytes.length > 4 * 1024 * 1024) break;
      }
      /*
       * 非 2xx **也要把正文带回去** —— 上面那段中文说明正是从
       * 403/502 的正文里读出来的，丢掉它我们就只能报一句
       * "HTTP 403"，用户不知道是防盗链还是地址过期。
       */
      return _TextResult(
        utf8.decode(bytes, allowMalformed: true),
        resp.statusCode,
      );
    } on Object {
      return null;
    }
  }
}

/// 取到的一段文本（不是产品数据，故私有）
class _TextResult {
  const _TextResult(this.text, this.status);
  final String text;
  final int status;
}

/// 一个分片的读取结果
class _SegResult {
  const _SegResult.ok(this.bytes) : reason = null;
  const _SegResult.fail(this.reason) : bytes = 0;
  final int bytes;
  final String? reason;
}

/// 超时/预算用尽（**内部信号**，最终都会被翻成 ok=false 的结果）
class _BudgetExceeded implements Exception {
  _BudgetExceeded(this.message);
  final String message;
}

/// 从 m3u8 正文里取"有哪些子清单 / 有哪些分片"
///
/// # 为什么自带一个（不复用 hls_download 那个解析器）
/// 理由写在文件头那一整段：那边按整片下载设计，加密流直接 throw、
/// 没有 ENDLIST 直接 throw，而测速两样都要放行。
/// 这里只做两件事，逻辑越少越不可能给出错的地址。
class _Playlist {
  const _Playlist({
    required this.variants,
    required this.segments,
    required this.encrypted,
  });

  /// 主列表里的子清单地址（非空 ⇒ 这是主列表，要下钻）
  final List<String> variants;

  /// 分片地址
  final List<String> segments;

  /// 有 #EXT-X-KEY 且 METHOD 不是 NONE
  final bool encrypted;

  /// # 为什么分片地址**原样取用、不做拼接**
  ///
  /// 本机实测清单里的地址已经是**核心层代理改写过的完整地址**：
  /// ```text
  /// http://127.0.0.1:61095/p/<token>/https/snv14.tscjzy.com/…/BqNhCoWd7r.ts
  /// ```
  /// 这正是"分片不需要我们自己传 Referer"的原因（hls_download.dart
  /// 对同一机制有完整说明）。再自己拼一次只会拼错。
  /// 本机实测两条清单（1491 片 / 3246 片）**全部**是完整地址。
  ///
  /// ⚠️ 没有 #EXTINF 铺垫的裸地址**不**当分片 —— 清单里还可能混进
  ///    #EXT-X-I-FRAME-STREAM-INF 的关键帧清单地址，下载它等于下错东西。
  static _Playlist parse(String text) {
    final variants = <String>[];
    final segments = <String>[];
    var encrypted = false;
    var sawStreamInf = false;
    var pendingInf = false;

    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        sawStreamInf = true;
        continue;
      }
      if (line.startsWith('#EXT-X-KEY')) {
        if (!line.contains('METHOD=NONE')) encrypted = true;
        continue;
      }
      if (line.startsWith('#EXTINF')) {
        pendingInf = true;
        continue;
      }
      if (line.startsWith('#')) continue;

      // 非注释行 = 地址
      if (sawStreamInf) {
        variants.add(line);
        sawStreamInf = false;
        continue;
      }
      if (pendingInf) {
        segments.add(line);
        pendingInf = false;
      }
    }
    return _Playlist(
      variants: variants,
      segments: segments,
      encrypted: encrypted,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  界面
// ═══════════════════════════════════════════════════════════════════════

/// 单个插件的测速条（挂在源卡片里）
///
/// # 布局：一行放得下就是一行
/// ```text
/// [⚡ 测速]  2.93 MB/s · 1.6 s · 3 片 · 刚刚 · 《野孩子2008》
/// ```
/// 没测过时右半边是一句如实说明（「还没测过 —— 随机挑一部影片，真下一段算 MB/s」），
/// 而不是一个占位的「-- MB/s」（那会被读成"测过了，是 0"）。
class PluginSpeedTestPanel extends StatefulWidget {
  const PluginSpeedTestPanel({
    super.key,
    required this.providerId,
    required this.providerName,
    this.enabled = true,
  });

  final String providerId;

  /// 只用于提示文案
  final String providerName;

  /// 源被停用时置灰 —— 停用的源调不动它的命令，测了也只会失败
  final bool enabled;

  @override
  State<PluginSpeedTestPanel> createState() => _PluginSpeedTestPanelState();
}

class _PluginSpeedTestPanelState extends State<PluginSpeedTestPanel> {
  PluginSpeedHistory _history = const PluginSpeedHistory([]);
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _history = PluginSpeedTest.read(widget.providerId);
    /*
     * ★★★ 必须订阅 —— 见 [PluginSpeedTest.changes] 的说明。
     *
     * 光在 initState 读一次是**不够**的：「全部测速」跑的时候本面板
     * 早就挂在那里了，它的 initState 不会再跑，于是 26 个源全测完
     * 界面上还是"还没测过"。真机实测就是这么暴露出来的。
     */
    PluginSpeedTest.changes.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    PluginSpeedTest.changes.removeListener(_onStoreChanged);
    super.dispose();
  }

  /// 存储变了 → 重读一次（**只重读自己的那一条**，不是全表重建）
  void _onStoreChanged() {
    if (!mounted) return;
    setState(() => _history = PluginSpeedTest.read(widget.providerId));
  }

  Future<void> _run() async {
    if (_busy || !widget.enabled) return;
    setState(() => _busy = true);
    try {
      /*
       * ★ run 里**不**写存储（那是调用方的决定），所以「全部测速」能一次
       *   测 15 个、每个各写一条，而单个按钮就写这一条 ——
       *   两条路径共用同一份测量代码，不会漂移。
       */
      final r = await PluginSpeedTestRunner.run(widget.providerId);
      PluginSpeedTest.append(widget.providerId, r);
      // 记进应用日志：用户报"测出来不对"时我们才拿得到当时的参数
      AppLog.write(
        'SPEED',
        '${widget.providerId} '
        '${r.ok ? PluginSpeedTest.speedText(r.mbPerSec) : '失败'}  '
        '${r.bytes} B / ${r.ms} ms / ${r.segments} 片'
        '${r.error == null ? '' : '  err=${r.error}'}',
      );
    } finally {
      /*
       * ⚠️ 这里**只**关忙碌态：历史的刷新交给 changes 监听器
       *    （append 已经通知过了）。两处都重读会让同一次测速
       *    触发两次 setState，白重建一遍。
       */
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final last = _history.last;

    final Widget detail;
    if (_busy) {
      detail = Text(
        '正在真下几秒…',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      );
    } else if (last == null) {
      detail = Text(
        '还没测过 —— 随机挑一部影片，真下一段算 MB/s',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      );
    } else if (last.ok) {
      /*
       * ★ 2026-10-10：读数从**一串挤在一起的字**改成「等级色 chip + 关键读数」
       *
       * 改前一行里塞了：速率 / 耗时 / 片数 / 多久前 / 片名，
       * 窄列（211px）上必然只剩省略号，用户看不到任何东西。
       * 改后：速率与等级永远可见（一枚 chip），其余细节收进 Tooltip。
       */
      detail = Row(
        children: [
          _SpeedBadge(run: last),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Text(
              [
                PluginSpeedTest.speedText(last.mbPerSec),
                PluginSpeedTest.msText(last.ms),
                PluginSpeedTest.agoText(last.ts),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    } else {
      detail = Text(
        '测速失败：${last.error ?? '原因未知'} · '
        '${PluginSpeedTest.agoText(last.ts)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: Sp.x1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _SpeedButton(
            busy: _busy,
            enabled: widget.enabled,
            hasHistory: _history.items.isNotEmpty,
            onPressed: _run,
          ),
          const SizedBox(width: Sp.x2),
          /*
           * ★ Expanded + maxLines/ellipsis：卡片正文只有约 211px（4 列 / 299px 格），
           *   而一行里要装速率、耗时、片数、时间、片名 —— **必须**允许省略，
           *   否则在窄列上会 RenderFlex overflow。
           *   （同一类问题在 _ProviderCard._actions 里实测过一次 31px 溢出，
           *     那处有完整的宽度预算加法。）
           */
          Expanded(child: Tooltip(message: _tooltip(last), child: detail)),
        ],
      ),
    );
  }

  String _tooltip(PluginSpeedRun? last) {
    final b = StringBuffer()
      ..writeln('随机挑一部影片，真下一段算 MB/s（二进制 MB）')
      ..writeln(
        '预热 ${PluginSpeedTest.sizeText(_warmupBytes)} 后计时 '
        '${_windowCap.inSeconds} 秒 / 上限 '
        '${PluginSpeedTest.sizeText(_maxBytes)}',
      )
      ..writeln('单个源最多 ${_timeout.inSeconds} 秒');
    if (last != null) {
      b
        ..writeln('')
        ..writeln('最近一次：${PluginSpeedTest.agoText(last.ts)}');
      if (last.sampleTitle != null) {
        b.writeln(
          '样本：《${last.sampleTitle}》（${last.sampleId ?? '-'}）',
        );
      }
      if (last.ok) {
        b.writeln(
          '读数：${PluginSpeedTest.speedText(last.mbPerSec)}'
          '（${PluginSpeedTest.sizeText(last.bytes)} / '
          '${PluginSpeedTest.msText(last.ms)}，${last.segments} 片）',
        );
      } else {
        b.writeln('结果：没量到 —— ${last.error ?? '原因未知'}');
      }
      if (last.note != null) b.writeln('说明：${last.note}');
      if (last.url != null) b.writeln('地址：${last.url}');
    }
    if (_history.runs > 1) {
      b
        ..writeln('')
        ..writeln(
          '最近 ${_history.runs} 次：'
          '平均 ${PluginSpeedTest.speedText(_history.avgMiBps)} · '
          '最快 ${PluginSpeedTest.speedText(_history.bestMiBps)} · '
          '最慢 ${PluginSpeedTest.speedText(_history.worstMiBps)}',
        );
    }
    return b.toString().trimRight();
  }
}

/// 测速结果的等级徽章（速率 + 快/中/慢 三档色）
///
/// # 为什么单独一个零件
///
/// Owner 要的是「看哪个视频网站速度快」—— 用户真正要读的是
/// **一个可以横向比较的等级**，而不是一串精确到小数点的数字。
///
/// ```text
/// 改前  「12.34 MB/s · 842 ms · 3 片 · 5 分钟前 · 《某剧名》」 ← 窄列只剩「…」
/// 改后  [快 12.34 MB/s]  842 ms · 5 分钟前                    ← 等级永远可见
/// ```
///
/// 三档阈值与 [_PluginSpeedTestPanelState._tone] 同源（快 / 中 / 慢），
/// 徽章色与正文色一致，不会出现"徽章说快、正文说慢"。
class _SpeedBadge extends StatelessWidget {
  const _SpeedBadge({required this.run});

  final PluginSpeedRun run;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fast = run.mbPerSec >= _fastMiBps;
    final slow = run.mbPerSec < _slowMiBps;
    final tone =
        fast ? colors.primary : (slow ? colors.error : colors.onSurfaceVariant);
    // ★ 三档，不做小数分级 —— 用户比的是「哪个快」，不是「快多少」
    final label = fast ? '快' : (slow ? '慢' : '中');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 2),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withValues(alpha: 0.45)),
      ),
      child: Text(
        '$label ${PluginSpeedTest.speedText(run.mbPerSec)}',
        style: TextStyle(
          fontSize: FontSizes.cap,
          fontWeight: FontWeight.w600,
          color: tone,
        ),
      ),
    );
  }
}

/// 「测速」按钮
///
/// 为什么自绘而不是用 OutlinedButton：源卡片上的 8 个按钮已经用满了宽度预算
/// （settings_page.dart 里 _actions 那处有 304px / 273px 的加法实录），
/// 这里是一个"有图标 + 有忙碌态 + 有历史态"的小按钮，尺寸必须可控。
class _SpeedButton extends StatelessWidget {
  const _SpeedButton({
    required this.busy,
    required this.enabled,
    required this.hasHistory,
    required this.onPressed,
  });

  final bool busy;
  final bool enabled;
  final bool hasHistory;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final on = enabled && !busy;
    final fg = on ? colors.primary : colors.onSurfaceVariant;

    return Tooltip(
      message: !enabled
          ? '这个源已停用 —— 启用后才能测速'
          : '随机挑一部影片，真下一段算下载速率',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: on ? onPressed : null,
          borderRadius: Radii.rFull,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Sp.x3,
              vertical: Sp.x1 + 2,
            ),
            decoration: BoxDecoration(
              borderRadius: Radii.rFull,
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.primary,
                    ),
                  )
                else
                  Icon(
                    hasHistory ? Icons.speed : Icons.bolt,
                    size: 15,
                    color: fg,
                  ),
                const SizedBox(width: Sp.x1 + 2),
                Text(
                  busy ? '测速中' : '测速',
                  style: TextStyle(fontSize: FontSizes.cap, color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「全部测速」入口（放在 JS 插件区块的块头，与「健康检测」同一排）
///
/// # ★ 为什么必须**顺序**跑
///
/// 一次测速会真实读几 MB 数据。15 个源并发跑 = 15 条流同时抢带宽，
/// 每条都拿不到真实速率（**全部**读数会被互相污染，测出来的数字比不测更糟），
/// 而且会把用户的网络打满。所以这里就是一个简单的串行循环。
///
/// # 进度为什么必须显示
/// 15 个源 × 最坏 4 秒 ≈ 1 分钟。没有进度用户会以为界面卡死了。
/// 进度给两段读数：**已完成 N/M**（还剩多少）+ **当前在对谁测**。
class PluginSpeedTestAllButton extends StatefulWidget {
  const PluginSpeedTestAllButton({
    super.key,
    required this.pluginIds,
    this.label = '全部测速',
    this.onChanged,
  });

  /// 要测的插件 id（调用方负责过滤掉停用的源）
  final List<String> pluginIds;

  final String label;

  /// 每完成一个就回调（宿主可以借此刷新别处的展示）
  final VoidCallback? onChanged;

  @override
  State<PluginSpeedTestAllButton> createState() =>
      _PluginSpeedTestAllButtonState();
}

class _PluginSpeedTestAllButtonState extends State<PluginSpeedTestAllButton> {
  bool _busy = false;
  bool _disposed = false;
  int _done = 0;
  int _total = 0;
  int _ok = 0;
  String _current = '';

  @override
  void dispose() {
    /*
     * ⚠️ 用标志位守住 dispose 之后的 setState，而不是靠"用户不会中途离开"——
     *    二级页是可以被返回键弹掉的，而一次全部测速要跑一分钟。
     */
    _disposed = true;
    super.dispose();
  }

  Future<void> _runAll() async {
    final ids = widget.pluginIds.toList();
    if (_busy || ids.isEmpty) return;
    setState(() {
      _busy = true;
      _done = 0;
      _ok = 0;
      _total = ids.length;
      _current = '';
    });

    try {
      for (final id in ids) {
        if (_disposed) return;
        setState(() => _current = id);
        // ★ 顺序：前一个 await 没回来，绝不开始下一个（见类文档）
        final r = await PluginSpeedTestRunner.run(id);
        PluginSpeedTest.append(id, r);
        if (_disposed) return;
        setState(() {
          _done++;
          if (r.ok) _ok++;
        });
        /*
         * ★ 让宿主也有机会刷新（比如它自己有一份"最近一次速率"的汇总）。
         *   注意**不是**靠这个刷新面板 —— append 已经通过 changes 通知过，
         *   宿主不需要做任何事，面板自己就会更新。
         */
        widget.onChanged?.call();
      }
      AppLog.write(
        'SPEED',
        '全部测速完成：$_done/$_total，其中 $_ok 个测到速率',
      );
    } finally {
      if (!_disposed) {
        setState(() {
          _busy = false;
          _current = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final empty = widget.pluginIds.isEmpty;

    if (_busy) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.primary,
            ),
          ),
          const SizedBox(width: Sp.x2),
          Text(
            '测速 $_done/$_total'
            '${_current.isEmpty ? '' : '  ·  $_current'}',
            style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurface),
          ),
          const SizedBox(width: Sp.x2),
          Text(
            '成功 $_ok}',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    return Tooltip(
      message: empty
          ? '没有可测速的源'
          : '顺序测 ${widget.pluginIds.length} 个源，'
              '每个真下一段（全部跑完约 ${widget.pluginIds.length}~'
              '${widget.pluginIds.length * 4} 秒）',
      child: OutlinedButton.icon(
        onPressed: empty ? null : _runAll,
        icon: const Icon(Icons.speed, size: 16),
        label: Text(widget.label),
      ),
    );
  }
}

/// 「清空测速记录」—— 区块里的次要入口
///
/// 做成独立按钮而不是塞进 [PluginSpeedTestAllButton]：清空与测速是两件
/// 互不相关的事，混在一个按钮里用户不敢点（怕顺手触发一次全量测速）。
class PluginSpeedTestClearButton extends StatelessWidget {
  const PluginSpeedTestClearButton({
    super.key,
    required this.pluginIds,
    this.onCleared,
  });

  final List<String> pluginIds;
  final VoidCallback? onCleared;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '清空这些源的测速记录（只删记录，不动插件）',
      child: OutlinedButton.icon(
        onPressed: pluginIds.isEmpty
            ? null
            : () {
                final n = PluginSpeedTest.clearAll(pluginIds);
                onCleared?.call();
                final messenger = ScaffoldMessenger.maybeOf(context);
                if (messenger != null) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        n == 0
                            ? '没有测速记录可以清空'
                            : '已清空 $n} 个源的测速记录',
                      ),
                    ),
                  );
                }
              },
        icon: const Icon(Icons.delete_sweep_outlined, size: 16),
        label: const Text('清空测速记录'),
      ),
    );
  }
}
