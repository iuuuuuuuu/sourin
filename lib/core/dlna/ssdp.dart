// ═══════════════════════════════════════════════════════════════════════
//  SSDP 发现 —— 在局域网里找 UPnP MediaRenderer（task-27）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要从零写
//
// Owner 要求「安卓端要支持投屏功能」。原版 `cctv_to_client` **没有任何投屏
// 代码**（dlna / ssdp / upnp / cast 命中 0），而本机 **pub.dev 不可达**
// ⇒ 不能 `upnp_client` / `dlna_dart` 这类包，只能自己实现协议。
//
// # 分层（这条是本文件唯一重要的设计决定）
//
// ```text
//   纯逻辑（报文构造 / 解析）      SsdpMessage / SsdpResponse.parse
//        ↑ 不碰网络 ⇒ flutter test 能直接证明"报文对不对"
//   网络（组播收发）              SsdpDiscovery.scan
//        ↑ 碰网络 ⇒ 用宿主上的假 renderer 证明"通不通"
// ```
//
// ★ 混在一起写的话，「协议写错了」和「网络不通」会表现成同一个现象
//   （列表为空），而这两种原因的修法完全相反。
//
// # SSDP 的最小知识（M-SEARCH 是 HTTP-over-UDP 的变体）
//
// ```text
// 请求（发到 239.255.255.250:1900，组播）：
//   M-SEARCH * HTTP/1.1
//   HOST: 239.255.255.250:1900      ← ★ 必须与目的地址一致，设备会校验
//   MAN: "ssdp:discover"            ← ★ 带引号，且大小写敏感
//   MX: 2                           ← 设备在这个秒数内**随机**延迟回包（防风暴）
//   ST: urn:schemas-upnp-org:device:MediaRenderer:1
//
// 响应（单播回给发起方的临时端口）：
//   HTTP/1.1 200 OK
//   LOCATION: http://<设备IP>:<port>/desc.xml   ← ★ 唯一有用的字段
//   ST / USN: 设备类型与唯一标识（USN 用来去重）
// ```
//
// # ⚠️ 三个实测坑（写在代码里，别再踩）
//
// ```text
// ① MX 必须 > 0。MX: 0 表示"立刻回"，很多设备直接不回（协议要求 1~5）。
// ② 回包是**单播**到我们的临时端口 —— 不能只 bind 1900 等组播回包。
//    所以这里 bind 的是 0（系统分配），而不是 1900。
// ③ 设备会丢第一条。实测有效的做法是**隔一段时间再发一次**
//    （见 resendAfter），而不是把 MX 调大。
// ```
//
// # ★ Android 上还要一把组播锁（2026-10-05 补）
//
// 上面三条是"协议/用法"层面的坑，但 Android 上还有一条**平台层面**的：
// Wi-Fi 栈默认**不把组播包交给应用** ⇒ 表现是"包发出去了，但永远 0 台设备"。
// `scan()` 因此整体包在 `MulticastLock.scope()` 里（见 `lib/core/net/multicast_lock.dart`）。
// 拿不到锁**不算错误**（非 Android / 模拟器 / 无 Wi-Fi 硬件都会拿不到），
// 照常扫描即可 —— 但锁状态会写进日志，方便真机上一眼区分两种"扫不到"。
//
// 本文档提到的所有"实测"都来自 `.probe/cast/` 里的日志（假 renderer + 模拟器）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../net/multicast_lock.dart';

/// SSDP 组播地址（协议固定值，不可配）
const String kSsdpAddress = '239.255.255.250';

/// SSDP 端口（协议固定值，不可配）
const int kSsdpPort = 1900;

/// 投屏要找的设备类型：UPnP MediaRenderer
///
/// 用 `:1`（版本 1）而不是 `:2`/`:3` —— 版本号在 ST 里是**降级匹配**的：
/// 声明 v2 的设备**必须**同时响应 v1 的搜索，反之不成立。
const String kMediaRendererSt = 'urn:schemas-upnp-org:device:MediaRenderer:1';

/// 兜底搜索目标：让**所有** UPnP 设备回话
///
/// ★ 只在第一轮一无所获时才用。理由：它会把路由器、打印机、NAS 全叫回来，
///   而其中绝大多数不是渲染器。真伪由**设备描述里的 AVTransport** 判定
///   （见 `description.dart`），不靠 ST 猜。
const String kSsdpAllSt = 'ssdp:all';

/// 我们的 User-Agent
///
/// 带项目名而不是装成别人的客户端：抓包/日志里能一眼认出是我们发的。
const String kSsdpUserAgent = 'sourin-spike/1.0 UPnP/1.1 Dart-SSDP/1.0';

// ═══════════════════════════════════════════════════════════════════════
//  报文构造
// ═══════════════════════════════════════════════════════════════════════

/// M-SEARCH 报文的构造与解析（**纯函数，不碰 socket**）
abstract final class SsdpMessage {
  /// 构造一条 M-SEARCH 请求
  ///
  /// 返回的是**完整字节序列**（含结尾空行），调用方直接 send。
  ///
  /// ⚠️ 行尾必须是 CRLF（`\r\n`）。用 `\n` 时部分设备会静默忽略整条报文 ——
  ///    协议是 HTTP/1.1 的子集，HTTP 规定行尾是 CRLF。
  static List<int> buildSearch({
    String st = kMediaRendererSt,
    int mx = 2,
    String host = '$kSsdpAddress:$kSsdpPort',
    String userAgent = kSsdpUserAgent,
  }) {
    final safeMx = mx < 1 ? 1 : (mx > 5 ? 5 : mx);
    final text = <String>[
      'M-SEARCH * HTTP/1.1',
      'HOST: $host',
      'MAN: "ssdp:discover"',
      'MX: $safeMx',
      'ST: $st',
      'USER-AGENT: $userAgent',
      '',
      '',
    ].join('\r\n');
    return utf8.encode(text);
  }

  /// 把报文渲染成可读文本（**给日志/测试用**，不参与收发）
  ///
  /// 存在的理由：验收要求"真实 SSDP 报文收发日志"，而字节数组写进日志
  /// 没人看得懂。这个方法让日志里出现的**就是线上真正发出去的那串字符**。
  static String describe(List<int> datagram) =>
      utf8.decode(datagram, allowMalformed: true);
}

// ═══════════════════════════════════════════════════════════════════════
//  回包解析
// ═══════════════════════════════════════════════════════════════════════

/// 一条 SSDP 回包（或 NOTIFY 通告）
class SsdpResponse {
  const SsdpResponse({
    required this.source,
    required this.headers,
    required this.statusLine,
  });

  /// 报文来源地址（单播回包时 = 设备 IP；组播通告时 = 设备 IP）
  final String source;

  /// 首行（`HTTP/1.1 200 OK` 或 `NOTIFY * HTTP/1.1`）
  final String statusLine;

  /// 头字段，**键统一大写**（协议里字段名大小写不敏感，设备实现五花八门）
  final Map<String, String> headers;

  /// 设备描述地址 —— **唯一真正有用的字段**
  ///
  /// 没有它的回包一律丢弃：UPnP 后续所有交互都要从这里读到的 URL 出发。
  String? get location {
    final v = headers['LOCATION']?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  String get st => headers['ST']?.trim() ?? headers['NT']?.trim() ?? '';

  String get usn => headers['USN']?.trim() ?? '';

  String get server => headers['SERVER']?.trim() ?? '';

  /// 解析一条 SSDP 报文
  ///
  /// 返回 `null` 的情形（都是"这条没用"，不是错误）：
  /// ```text
  /// · 不是 SSDP（首行既不是 HTTP/1.1 也不是 NOTIFY）
  /// · 没有 LOCATION（拿不到设备描述地址 ⇒ 后续一步都做不了）
  /// · 空报文
  /// ```
  ///
  /// ★ 刻意**不抛异常**：局域网里什么怪包都有（别的协议的广播、
  ///   被截断的报文）。一条坏包不该让整次扫描失败。
  static SsdpResponse? parse(String datagram, {String source = ''}) {
    if (datagram.trim().isEmpty) return null;

    // ── 按 CRLF 切；容忍设备只发 LF（实测有）──
    final lines = datagram
        .split('\n')
        .map((l) => l.endsWith('\r') ? l.substring(0, l.length - 1) : l)
        .toList();
    if (lines.isEmpty) return null;

    final statusLine = lines.first.trim();
    final upper = statusLine.toUpperCase();
    if (!upper.startsWith('HTTP/1.1') && !upper.startsWith('NOTIFY')) {
      return null;
    }

    final headers = <String, String>{};
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final key = line.substring(0, colon).trim().toUpperCase();
      final value = line.substring(colon + 1).trim();
      // 重复字段取**第一个**：UPnP 没有多值字段，重复即设备 bug
      headers.putIfAbsent(key, () => value);
    }

    final r = SsdpResponse(
      source: source,
      headers: headers,
      statusLine: statusLine,
    );
    if (r.location == null) return null;
    return r;
  }

  /// 去重键：优先 USN（协议规定的设备唯一标识），退化到 LOCATION
  String get dedupeKey {
    if (usn.isNotEmpty) return usn;
    return location ?? '$source/$st';
  }

  @override
  String toString() => 'SsdpResponse($source, st=$st, location=$location)';
}

// ═══════════════════════════════════════════════════════════════════════
//  扫描结果
// ═══════════════════════════════════════════════════════════════════════

/// 一次扫描的**完整**结果
///
/// ★ 为什么要区分 `sent` / `errors` / `responses` 三样，而不是只返回列表：
/// ```text
///   列表空 + sent=true  ⇒ "网发得出去，是**没人应答**"  → 提示检查设备
///   列表空 + sent=false ⇒ "**根本没发出去**"（无组播路由/权限）→ 提示查网络
/// ```
/// 这两种空态对用户的下一步动作完全不同。只返回空列表等于把两种原因
/// 混成一句「没找到设备」——那正是本项目禁止的「假装有能力」。
class SsdpScanResult {
  const SsdpScanResult({
    this.responses = const [],
    this.errors = const [],
    this.sent = 0,
    this.unicast = 0,
    this.multicast = 0,
    this.duration = Duration.zero,
    this.searches = const [],
  });

  /// 去重后的回包（按 USN）
  final List<SsdpResponse> responses;

  /// 发送/绑定失败的原因（空 = 一路顺利）
  final List<String> errors;

  /// 成功发出的 M-SEARCH 条数（0 ⇒ 一条都没发出去）
  final int sent;

  /// 收到的**单播**回包数（正常的 M-SEARCH 应答走单播）
  final int unicast;

  /// 收到的**组播**包数（设备主动 NOTIFY 通告；也有设备用组播回 M-SEARCH）
  final int multicast;

  final Duration duration;

  /// 每条搜索目标各自的结果统计（`ST → 收到几条`）
  final List<String> searches;

  bool get anySent => sent > 0;
  bool get found => responses.isNotEmpty;
}

// ═══════════════════════════════════════════════════════════════════════
//  网络层
// ═══════════════════════════════════════════════════════════════════════

/// SSDP 组播扫描
///
/// 用法（UI 层）：
/// ```dart
/// final r = await SsdpDiscovery.scan(timeout: const Duration(seconds: 4));
/// if (!r.anySent) => 显示"发不出去" + r.errors
/// else if (!r.found) => 显示"发了 N 条，没人应答"
/// ```
abstract final class SsdpDiscovery {
  /// 扫一轮
  ///
  /// [st] 为 `null` 时**自动两轮**：先 `MediaRenderer:1`，若无应答再补 `ssdp:all`。
  /// 两轮的等待时间各自独立（`timeout`），所以最坏耗时 = 2 × timeout。
  ///
  /// [onLog] 会收到**线上真实字节**的可读形式（验收要求的收发日志就靠它）。
  static Future<SsdpScanResult> scan({
    Duration timeout = const Duration(seconds: 4),
    String? st,
    int mx = 2,
    void Function(String line)? onLog,
  }) {
    /*
     * ★ 整个扫描期（含两次 timeout 等待）都持有组播锁 —— 释放早了会漏掉
     *   设备在等待期后段才回的包。scope() 保证异常路径也会释放。
     *   拿不到锁不算错误（见 multicast_lock.dart 文件头），照常扫描。
     */
    return MulticastLock.scope(
      () => _scan(timeout: timeout, st: st, mx: mx, onLog: onLog),
    );
  }

  static Future<SsdpScanResult> _scan({
    required Duration timeout,
    required String? st,
    required int mx,
    required void Function(String line)? onLog,
  }) async {
    final started = DateTime.now();
    final log = onLog ?? (String _) {};
    // ★ 组播锁状态写进日志：真机上"扫不到设备"时，这一行能立刻区分
    //   「锁没拿到（权限/无 Wi-Fi）」和「拿到了但设备没回」。
    final lockNote = MulticastLock.held
        ? '已持有'
        : '未持有${MulticastLock.lastFailure == null ? "" : "（${MulticastLock.lastFailure}）"}';
    log('[SSDP] 组播锁：$lockNote');

    RawDatagramSocket? socket;
    try {
      // ★ bind 0（临时端口），**不是** 1900：
      //   M-SEARCH 的回包是单播到发起端口的，不是回给 1900。
      //   绑 1900 会在 Android 上撞端口占用（系统里已有别的 SSDP 客户端）。
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (e) {
      return SsdpScanResult(
        errors: ['无法创建 UDP socket：$e'],
        duration: DateTime.now().difference(started),
      );
    }

    final localPort = socket.port;
    final errors = <String>[];
    var sent = 0;
    var unicast = 0;
    var multicast = 0;
    final byKey = <String, SsdpResponse>{};
    final searches = <String>[];

    try {
      socket.broadcastEnabled = true;
      // 多播跳数：1 就够（同一网段）。设大一点不影响，设 0 会出不去。
      socket.multicastHops = 4;
    } catch (e) {
      log('[SSDP] 设置 socket 选项失败（继续尝试）：$e');
    }

    final done = Completer<void>();
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? dg;
      try {
        dg = socket!.receive();
      } catch (e) {
        log('[SSDP] receive 失败：$e');
        return;
      }
      if (dg == null) return;

      final from = dg.address.address;
      final text = utf8.decode(dg.data, allowMalformed: true);
      // ★ Dart 的 Datagram **不给目的地址**，所以这里按**报文类型**分：
      //   `NOTIFY * HTTP/1.1`  = 设备主动组播通告
      //   `HTTP/1.1 200 OK`    = 对 M-SEARCH 的单播应答
      //   ⚠️ 这是**语义分类**，不是链路层分类（诚实标注，别当成 tcpdump）。
      if (text.trimLeft().toUpperCase().startsWith('NOTIFY')) {
        multicast++;
      } else {
        unicast++;
      }
      log('[SSDP] ← 收到 ${dg.data.length} B 来自 $from:${dg.port}');
      log(text.trim());

      final r = SsdpResponse.parse(text, source: from);
      if (r == null) {
        log('[SSDP]    ↳ 丢弃：不是有效 SSDP 应答（没有 LOCATION 或首行不对）');
        return;
      }
      final key = r.dedupeKey;
      if (byKey.containsKey(key)) {
        log('[SSDP]    ↳ 丢弃：与已有设备重复（USN 相同）');
        return;
      }
      byKey[key] = r;
      log('[SSDP]    ↳ 新设备：${r.st} @ ${r.location}');
    }, onError: (Object e) {
      errors.add('监听 UDP 失败：$e');
      log('[SSDP] 监听出错：$e');
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    });

    Future<void> sendRound(String searchTarget, String label) async {
      final datagram = SsdpMessage.buildSearch(st: searchTarget, mx: mx);
      try {
        final n = socket!.send(
          datagram,
          InternetAddress(kSsdpAddress),
          kSsdpPort,
        );
        sent++;
        searches.add('$label → 发出 $n B');
        log('[SSDP] → $label 发往 $kSsdpAddress:$kSsdpPort（本地端口 $localPort）');
        log(SsdpMessage.describe(datagram).trim());
      } catch (e) {
        errors.add('发送 M-SEARCH（$label）失败：$e');
        searches.add('$label → 发送失败：$e');
        log('[SSDP] → $label 发送失败：$e');
      }
    }

    // ── 第一轮：MediaRenderer ──
    final targets = <String>[st ?? kMediaRendererSt];
    await sendRound(targets.first, 'ST=${targets.first}');

    // ★ 隔一段时间**再发一次**：设备会丢第一条（实测）。
    //   第二次发送安排在等待期的中点，而不是结束后 —— 那时 socket 还在听。
    final resendAt = Duration(milliseconds: timeout.inMilliseconds ~/ 2);
    final resendTimer = Timer(resendAt, () {
      unawaited(sendRound(targets.first, 'ST=${targets.first}（重发 #2）'));
    });

    await Future<void>.delayed(timeout);
    resendTimer.cancel();

    // ── 第二轮（仅在 st 未指定且一无所获时）：ssdp:all ──
    if (st == null && byKey.isEmpty) {
      log('[SSDP] 第一轮无应答 ⇒ 补一轮 ST=$kSsdpAllSt（设备可能只认它）');
      targets.add(kSsdpAllSt);
      await sendRound(kSsdpAllSt, 'ST=$kSsdpAllSt');
      final t2 = Timer(resendAt, () {
        unawaited(sendRound(kSsdpAllSt, 'ST=$kSsdpAllSt（重发 #2）'));
      });
      await Future<void>.delayed(timeout);
      t2.cancel();
    }

    await sub.cancel();
    if (!done.isCompleted) done.complete();
    socket.close();

    final result = SsdpScanResult(
      responses: byKey.values.toList(),
      errors: errors,
      sent: sent,
      unicast: unicast,
      multicast: multicast,
      duration: DateTime.now().difference(started),
      searches: searches,
    );
    log('[SSDP] 扫描结束：发出 $sent 条，收到 单播 $unicast / 组播 $multicast 个包，'
        '去重后 ${result.responses.length} 台设备，耗时 ${result.duration.inMilliseconds} ms');
    return result;
  }
}

