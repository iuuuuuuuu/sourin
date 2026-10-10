// ///////////////////////////////////////////////////////////////////////////
//  OPS-16 回归探针：下载收尾的**落盘竞态**（旁文件静默丢失 + done 先发布）
// ///////////////////////////////////////////////////////////////////////////
//
// # 缺陷 1：`tmp.rename(target)` 撞锁 ⇒ 旁文件**静默丢**
// ```text
// lib/core/download_queue.dart:705（旧）  await tmp.rename(f.path);
// lib/core/download_queue.dart:706-709（旧）catch (e) { AppLog.write('DL','旁文件写入被忽略：$e'); }
//
// 目标 `_sourin-cache.json` **已存在且被别的句柄开着**时，Windows 上 rename 抛：
//   PathAccessException: Cannot rename file to '…_sourin-cache.json',
//     path = '…_sourin-cache.json.tmp' (OS Error: 拒绝访问。, errno = 5)
// 谁在开它：cache_page 的扫盘/读旁文件、杀软扫描、以及**同一部剧并发下载多集
// 时两集同时收尾**（并发 2/3 是正式功能）⇒ 概率性丢封面/来源。
// 而 catch 把它吞成一行日志 ⇒ 用户看到的是「我明明下过，怎么又没了」。
// ```
//
// # 缺陷 2：`done` 先 publish、旁文件后写 ⇒ 观察者拿到「无旁文件的成品」
// ```text
// lib/core/download_queue.dart:1040-1045（旧）先 copyWith(state: done) + _publish()
// lib/core/download_queue.dart:1059-1061（旧）之后才 await _writeSidecarFor(t, dir)
//
// 「已缓存」页 _onQueueChanged（cache_page.dart:1143）**按 id 集合去重**：
//   final fresh = doneIds.difference(_seenDoneIds); if (fresh.isEmpty) return;
// ⇒ 同一条任务第二次 publish（方案 b）**不会**再触发 load()，也就不会自愈。
// ⇒ 唯一正确的顺序是：旁文件落地之后再发布 done。
// ```
//
// # 判据（与时序无关，逐条核对）
//   ① 目标被占用时：新内容仍必须落盘、`.tmp` 必须清掉、不许静默（日志如实记）；
//
// ⚠️ ★★★ 判据 ① 里「日志如实记」这半条是 **Windows 专属语义**，不是跨平台契约
//    （OPS-16 ① 的 macOS CI 红就出在这）：
// ```text
// Windows：rename 覆盖**已被别的句柄打开**的目标会抛
//          PathAccessException(OS Error: 拒绝访问。, errno = 5)
//          ⇒ 生产必然走到「重试 → 退化为原地写」⇒ 必然留下日志。
// POSIX  ：rename(2) 只要求**路径**可写，被换掉的旧 inode 由已打开它的进程
//          继续持有直到自己关掉 ⇒ 目标被别的 fd 持住**不构成**失败理由
//          ⇒ 第一次 rename 就成功 ⇒ 一行日志都没有（不是「静默吞失败」）。
// ```
// ⇒ OPS-16 ① 用例按 Platform.isWindows **分支断言**（不是整块跳过）：
//    · Windows：必须有那条含 kSidecarName 的「撞锁」日志（原判据，强度不变）；
//    · POSIX  ：① **不许**出现「退化为原地写」日志（POSIX 上 rename 不该失败）；
//      ② **不许**动到我手上那个句柄所指的文件 —— 原子 rename 换的是目录项，
//      旧 inode 应当一个字节都不变；若它的长度变成了目标的新长度，说明收尾是
//      「就地改写同一个文件」。② 不依赖日志，专抓「把 rename 换成原地写」。
//   ② 观察者看到 state==done 的**那一刻**，盘上旁文件必须已经是**最终**内容；
//   ③ 封面文件（同一个撞锁窗口，同一个症状「没有原封面」）同上。
//
// ⚠️ 本文件**不碰**任何真实用户数据：全程只写系统临时目录（DownloadDir.setConfiguredDir）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_log.dart';
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 每片字节数（很小 —— 本用例只关心收尾，不关心吞吐）
const int kSegBytes = 2048;

/// 清单里的分片数
const int kSegCount = 6;

/// 封面图字节数 / 填充值（便于「是不是新写的那张」一眼可验）
const int kCoverBytes = 4096;
const int kCoverByte = 0x5A;

/// 拼 m3u8 用的换行
String kNl() => String.fromCharCode(10);

/// 上游：真 HttpServer + 真 m3u8 + 真分片字节 + 真封面图
class Upstream {
  Upstream({this.segDelayMs = 0});

  /// 每片延时（护栏用例需要「跑得够久」才有可靠的暂停窗口）
  final int segDelayMs;

  late HttpServer _srv;
  int get port => _srv.port;

  Future<void> start() async {
    _srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _srv.listen((req) async {
      final path = req.uri.path;
      if (path == '/master.m3u8') {
        req.response.headers.contentType =
            ContentType.parse('application/vnd.apple.mpegurl');
        req.response.write(<String>[
          '#EXTM3U',
          '#EXT-X-STREAM-INF:BANDWIDTH=2000000',
          'media.m3u8',
          '',
        ].join(kNl()));
        await req.response.close();
        return;
      }
      if (path == '/media.m3u8') {
        final b = StringBuffer(<String>[
          '#EXTM3U',
          '#EXT-X-VERSION:3',
          '#EXT-X-TARGETDURATION:4',
          '',
        ].join(kNl()));
        for (var i = 0; i < kSegCount; i++) {
          b.write('#EXTINF:4.0,' + kNl() + 'seg' + i.toString() + '.ts' + kNl());
        }
        b.write('#EXT-X-ENDLIST' + kNl());
        req.response.headers.contentType =
            ContentType.parse('application/vnd.apple.mpegurl');
        req.response.write(b.toString());
        await req.response.close();
        return;
      }
      if (path.startsWith('/seg')) {
        if (segDelayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: segDelayMs));
        }
        final body = List<int>.filled(kSegBytes, 0x11);
        req.response.headers.contentType = ContentType.binary;
        req.response.headers.contentLength = body.length;
        req.response.add(body);
        await req.response.close();
        return;
      }
      if (path == '/cover.jpg') {
        final body = List<int>.filled(kCoverBytes, kCoverByte);
        req.response.headers.contentType = ContentType.parse('image/jpeg');
        req.response.headers.contentLength = body.length;
        req.response.add(body);
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
  }

  Future<void> close() => _srv.close(force: true);
}

/// 第 k 集的任务
DownloadTask _task(int k, {String cover = ''}) => DownloadTask(
      id: 'cctv:ops16:ep' + k.toString(),
      title: 'OPS16 剧',
      episodeTitle: '第' + (k + 1).toString() + '集',
      provider: 'cctv',
      mediaId: 'ops16',
      episodeId: 'ep' + k.toString(),
      sourceCode: 'src',
      fileName: '第' + (k + 1).toString().padLeft(2, '0') + '集 OPS16',
      cover: cover,
      description: 'OPS-16 简介',
      year: '2026',
      area: '大陆',
      kind: '剧',
      badges: const <String>['悬疑'],
    );

void main() {
  late Upstream ups;

  setUp(() async {
    DownloadQueue.debugReset();
    // 接缝必须归零：任何一条用例把它留在非 0 上，后面的用例就会测到别的东西
    DownloadQueue.debugForceRenameFailures = 0;
    DownloadDir.debugReset();
    UiPrefs.remove(DownloadQueue.kConcurrencyKey);
    AppLog.debugClear();
    ups = Upstream();
    await ups.start();
    DownloadQueue.debugSetResolver((t) async =>
        StreamCandidate(url: 'http://127.0.0.1:' + ups.port.toString() + '/master.m3u8'));
    final sep = Platform.pathSeparator;
    final d = Directory(Directory.systemTemp.absolute.path +
        sep +
        'cr_dl_sidecar_' +
        DateTime.now().microsecondsSinceEpoch.toString())
      ..createSync(recursive: true);
    DownloadDir.setConfiguredDir(d.path);
  });

  tearDown(() async {
    await ups.close();
    DownloadQueue.debugReset();
    DownloadQueue.debugSetResolver(null);
    DownloadDir.debugReset();
    UiPrefs.remove(DownloadQueue.kConcurrencyKey);
  });

  /// 等队列里再没有 queued/running 的任务（或超时）
  Future<bool> _waitQuiet({int timeoutMs = 60000}) async {
    final dl = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(dl)) {
      final busy = DownloadQueue.tasks.value.any((t) =>
          t.state == DownloadState.queued || t.state == DownloadState.running);
      if (!busy) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return false;
  }

  File _sidecar(String workDir) =>
      File(workDir + Platform.pathSeparator + DownloadQueue.kSidecarName);

  /// 读旁文件并解析；返回 null = 不存在，抛 = 解析不了
  Map<String, Object?>? _readSidecar(File f) {
    if (!f.existsSync()) return null;
    return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  }

/// OPS-16 ① 的平台契约（**纯函数**：平台用显式参数传，不读 Platform）。
///
/// 返回 null = 没有违规；非 null = 违规描述（① 用例会把它塞进 bad 并让它红）。
///
/// 为什么抽成显式参数的纯函数：本机是 Windows、跑不了 macOS，而 CI 上的红
/// 恰恰出在 POSIX 那一侧。把「平台分派」变成参数之后，**两侧契约都能在任意
/// 主机上被断言**（文件末尾 'OPS-16 ① 平台语义' 那组就是喂两侧的假想观测），
/// 而不是用 Platform.isWindows 把一侧跳掉（跳过 = 那一侧什么都没测）。
///
/// 两侧契约的**机制**（逐条对应参数）：
///  · Windows：rename 覆盖**已被别的句柄打开**的目标 ⇒
///    PathAccessException(OS Error: 拒绝访问。, errno = 5)
///    ⇒ renameFailed=true ⇒ 生产走「重试 → 退化为原地写」⇒ logPresent 必须为真。
///  · POSIX：rename(2) 只要求**路径**可写，谁开着旧 inode 与它无关
///    ⇒ renameFailed 恒为 false、**0 条日志才是对的**；
///    且原子替换换的是**目录项** ⇒ 收尾前打开的旧句柄仍指旧 inode，
///    它的长度不许变（oldHandleTouched 必须为假）。
///    「退化为原地写」= 打开目标就地写（O_TRUNC）⇒ 那个句柄与目标路径是
///    同一个文件、长度会变成新长度 ⇒ 一旦出现就是原子性被改坏。
String? sidecarPlatformViolation({
  required bool windows,
  required bool renameFailed,
  required bool logPresent,
  required bool fallbackLogPresent,
  required bool oldHandleTouched,
}) {
  if (windows) {
    if (renameFailed && !logPresent) {
      return '★★ 撞锁这件事在 AppLog 里没有任何记录（要求：如实记，含目标路径）';
    }
    return null;
  }
  if (fallbackLogPresent) {
    return '★★ POSIX 上不许退化：rename 覆盖一个已被打开的目标不会失败，'
        '出现「退化为原地写」= 原子替换被改成了就地覆盖写';
  }
  if (oldHandleTouched) {
    return '★★ POSIX 上收尾动到了旧句柄所指的文件 ⇒ 不是原子 rename，而是就地覆盖写';
  }
  return null;
}

  // ══════════════════════════════════════════════════════════════════════
  //  缺陷 1：撞锁
  // ══════════════════════════════════════════════════════════════════════

  test('★★ OPS-16 ①：目标旁文件被占用时，新内容仍必须落盘、.tmp 必须清掉',
      () async {
    final workDir = await DownloadDir.forWork('OPS16 剧');
    final f = _sidecar(workDir);
    // 盘上先有一份**旧**旁文件（模拟：上一轮留下的 / 另一集刚写的）
    f.writeAsStringSync(jsonEncode(<String, Object?>{
      'provider': 'old-provider',
      'id': 'old-id',
      'title': '旧标题',
    }));
    /*
     * ★ 持住目标（**这就是撞锁本身**）：
     *   与 cache_page 的扫盘/读旁文件、杀软扫描、另一集同时收尾同一种占用。
     *
     * ⚠️ 这个「占用」的**后果是平台相关的**（OPS-16 ① 的 macOS CI 红就出在这）：
     *   · Windows：rename 覆盖一个**已被别的句柄打开**的目标会抛
     *     PathAccessException(OS Error: 拒绝访问。, errno = 5)
     *     ⇒ 生产走「重试 → 退化为原地写」⇒ **必然**留下日志（断言见下）。
     *   · POSIX：rename(2) 只要求**路径**可写，**根本不看**有没有别的 fd 打开它
     *     （被换掉的旧 inode 由已打开它的进程继续持有，直到它自己关掉）
     *     ⇒ 第一次 rename 就成功 ⇒ 生产**不会**退化 ⇒ 一行日志都没有。
     * ⇒ 「AppLog 里必须有那条撞锁日志」是 **Windows 专属语义**，不是跨平台契约；
     *   在 POSIX 上照抄它，测到的是「平台恰好不锁」，而不是产品的原子性保证 ——
     *   这正是 CI 上 macOS 必红的根因。所以下面按平台分成两条**都带牙齿**的断言：
     *   Windows 钉「撞锁必须如实记」，POSIX 钉「不许退化」（见 :273 起）。
     */
    final hold = f.openSync(mode: FileMode.append);
    /*
     * ★ POSIX 分支的**物证**：先记下「我手上这个句柄所指文件的长度」。
     *
     * 机制：POSIX 的 rename(2) 换的是**目录项**，收尾前打开的 fd 仍然指着
     * 被换掉的旧 inode —— 这个句柄会继续持有旧 inode，而旧 inode 的**内容
     * 一个字节都不会被碰**。于是收尾之后：
     *   · 原子 rename ⇒ 句柄所指的还是旧 inode ⇒ 长度仍是 oldSidecarLen；
     *   · 就地改写   ⇒ 句柄与目标路径是**同一个文件**，被 truncate 后按新内容
     *                  重写 ⇒ 长度 == 目标新长度 ≠ oldSidecarLen。
     * 这条不依赖任何日志，是「目标路径到底有没有被换成新 inode」的直接见证。
     */
    final oldSidecarLen = hold.lengthSync();
    try {
      final t = _task(0, cover: 'http://127.0.0.1:' + ups.port.toString() + '/cover.jpg');
      expect(DownloadQueue.enqueue(t), isTrue, reason: '前置：入队必须成功');
      final quiet = await _waitQuiet(timeoutMs: 60000);
      // 让收尾后的日志/文件状态彻底安定
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final bad = <String>[];
      if (!quiet) {
        bad.add('★ 队列没跑完（仍卡在 queued/running）—— 用例失去意义，不是通过');
      }
      final task = DownloadQueue.tasks.value
          .where((x) => x.id == t.id)
          .toList();
      if (task.isEmpty || task.first.state != DownloadState.done) {
        bad.add('前置：任务没到 done（state=' +
            (task.isEmpty ? '记录没了' : task.first.state.name) +
            ' error=' +
            (task.isEmpty ? '-' : (task.first.error ?? '-')) +
            '）⇒ 这条用例测的是收尾，不是下载本身');
      }

      final meta = _readSidecar(f);
      if (meta == null) {
        bad.add('★★ 旁文件不见了：' + f.path);
      } else {
        if (meta['provider'] != t.provider) {
          bad.add('★★ 旁文件内容还是**旧的**：provider=' +
              meta['provider'].toString() +
              '（新任务应为 ' +
              t.provider +
              '）⇒ 撞锁时新内容被静默丢弃');
        }
        if (meta['id'] != t.mediaId) {
          bad.add('★★ 旁文件内容还是**旧的**：id=' +
              meta['id'].toString() +
              '（新任务应为 ' +
              t.mediaId +
              '）');
        }
        if (meta['title'] != t.title) {
          bad.add('★ 旁文件 title=' + meta['title'].toString() + ' ≠ ' + t.title);
        }
        // 封面文件也应该真的落地，且旁文件里指向它
        final coverName = meta[DownloadQueue.kSidecarCoverFileKey];
        if (coverName == null) {
          bad.add('★ 旁文件里的 coverFile 是 null ⇒ 本地封面又没了（缺陷 1 的同一个窗口）');
        } else {
          final cf = File(workDir + Platform.pathSeparator + coverName.toString());
          if (!cf.existsSync()) {
            bad.add('★ 旁文件指向的封面文件不存在：' + cf.path);
          }
        }
      }
      final tmp = File(f.path + '.tmp');
      if (tmp.existsSync()) {
        bad.add('★★ .tmp 残留没清掉：' + tmp.path);
      }
      // 「不许再静默」：这条日志是本缺陷的签名，修好后不该再出现
      final silent = AppLog.lines
          .where((l) => l.message.contains('旁文件写入被忽略'))
          .map((l) => l.message)
          .toList();
      if (silent.isNotEmpty) {
        bad.add('★★ 仍然静默吞掉了失败：' + silent.first);
      }
      final told = AppLog.lines
          .where((l) =>
              l.message.contains(DownloadQueue.kSidecarName) &&
              l.message.contains('旁文件'))
          .map((l) => l.message)
          .toList();
      final fellBack = AppLog.lines
          .where((l) => l.message.contains('退化为原地写'))
          .map((l) => l.message)
          .toList();
      /*
       * ★ POSIX 支的**物证**：收尾前持住的旧句柄，所指文件的长度不许被碰。
       *   原子 rename 换的是目录项 ⇒ 旧 inode 归这个句柄继续持有，一个字节
       *   都不该变；「就地覆盖」则会把长度变成新内容的长度。
       *   （这个判据的机制在文件末尾 'OPS-16 ① 的平台语义' 那组里两侧都钉死了。）
       */
      final oldHandleTouched = hold.lengthSync() != oldSidecarLen;
      /*
       * ★★★ OPS-16 ①（macOS CI 红）修复点：把「必须有一条撞锁日志」这条
       * **Windows 专属**判据，换成两侧**都带牙齿**的平台契约。
       *
       * 分派逻辑写进纯函数 sidecarPlatformViolation（本文件 :236 起）—— 平台
       * 是**显式参数**。理由：本机（Windows）永远只跑 Windows 那一支，而 CI
       * 上的红恰恰出在 POSIX 那一支，本机跑不了 macOS；只有把平台变成参数，
       * 两侧契约才都能被断言（文件末尾那组就是喂两侧的**假想观测**）。
       * ★ 这里不是整块跳过：Windows 上照样执行、照样红，断言强度逐字不变。
       *
       * renameFailed 由平台机制决定，不是「假设」：
       *   Windows：目标被别的句柄持住 ⇒ rename 必抛 errno=5（机制见 :236 起；
       *            末尾「原子替换 vs 就地覆盖」那条测试的 Windows 路也是实测）；
       *   POSIX  ：rename(2) 只看路径 ⇒ 必成功。
       */
      final violation = sidecarPlatformViolation(
        windows: Platform.isWindows,
        renameFailed: Platform.isWindows,
        logPresent: told.isNotEmpty,
        fallbackLogPresent: fellBack.isNotEmpty,
        oldHandleTouched: oldHandleTouched,
      );
      if (violation != null) bad.add(violation);
      if (Platform.isWindows) {
        if (told.isNotEmpty) {
          debugPrint('OPS-16①[Windows] 日志如实记录 ⇒ ' + told.first);
        }
      } else {
        debugPrint('OPS-16①[POSIX] 未退化（撞锁日志 ' +
            told.length.toString() +
            ' 条；POSIX 上 0 条才对；旧句柄长度被碰=' +
            (oldHandleTouched ? '是' : '否') +
            '）');
      }
      bad.forEach(debugPrint);
      expect(bad, isEmpty,
          reason: '★★ 原子替换必须有重试 + 兜底：撞锁时也要把**新**旁文件写进去');
    } finally {
      hold.closeSync();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('★★ OPS-16 ①-封面：目标封面文件被占用时，封面仍必须落盘',
      () async {
    final workDir = await DownloadDir.forWork('OPS16 剧');
    final target = File(workDir + Platform.pathSeparator + '_sourin-cover.jpg');
    target.writeAsBytesSync(List<int>.filled(64, 0x07)); // 旧封面
    final hold = target.openSync(mode: FileMode.append);
    try {
      final got = await DownloadQueue.cacheCoverImage(
          'http://127.0.0.1:' + ups.port.toString() + '/cover.jpg', workDir);
      final bad = <String>[];
      if (got != '_sourin-cover.jpg') {
        bad.add('★★ cacheCoverImage 返回 ' +
            got.toString() +
            '（应为 _sourin-cover.jpg）⇒ 撞锁时封面被放弃，旁文件里的 coverFile 只能是 null');
      }
      final bytes = target.readAsBytesSync();
      if (bytes.length != kCoverBytes) {
        bad.add('★★ 封面长度 ' +
            bytes.length.toString() +
            ' ≠ ' +
            kCoverBytes.toString() +
            ' ⇒ 还是旧的那张');
      } else if (!bytes.every((b) => b == kCoverByte)) {
        bad.add('★★ 封面内容不是这次抓下来的那张');
      }
      final tmp = File(target.path + '.tmp');
      if (tmp.existsSync()) bad.add('★★ .tmp 残留没清掉：' + tmp.path);
      bad.forEach(debugPrint);
      expect(bad, isEmpty, reason: '★★ 封面与旁文件是同一个撞锁窗口（Owner：已缓存的也要显示原封面）');
    } finally {
      hold.closeSync();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  // ══════════════════════════════════════════════════════════════════════
  //  缺陷 2：done 先发布
  // ══════════════════════════════════════════════════════════════════════

  test('★★ OPS-16 ②：看到 state==done 的那一刻，盘上旁文件必须已是最终内容',
      () async {
    final workDir = await DownloadDir.forWork('OPS16 剧');
    final f = _sidecar(workDir);
    final bad = <String>[];
    final seen = <String>{};

    /*
     * ★ 判据就在这个监听器里：DownloadQueue._publish() 是**同步**通知的，
     *   所以这段代码跑在「done 刚被写进 tasks.value」的那一瞬间 ——
     *   此刻盘上还没有旁文件，就是缺陷本身。
     */
    void onQueue() {
      for (final t in DownloadQueue.tasks.value) {
        if (t.state != DownloadState.done) continue;
        if (!seen.add(t.id)) continue;
        if (!f.existsSync()) {
          bad.add('★★ 任务 ' + t.id + ' 变成 done 的那一刻，盘上**还没有**旁文件：' + f.path);
          continue;
        }
        Map<String, Object?>? meta;
        try {
          meta = _readSidecar(f);
        } catch (e) {
          bad.add('★★ done 的那一刻旁文件还解析不了（半截 JSON？）：' + e.toString());
          continue;
        }
        if (meta == null || meta['provider'] != t.provider || meta['id'] != t.mediaId) {
          bad.add('★★ done 的那一刻旁文件还不是最终内容：' +
              (meta == null ? 'null' : jsonEncode(meta)) +
              '（应为 provider=' +
              t.provider +
              ' id=' +
              t.mediaId +
              '）');
        }
      }
    }

    DownloadQueue.tasks.addListener(onQueue);
    try {
      final t = _task(0, cover: 'http://127.0.0.1:' + ups.port.toString() + '/cover.jpg');
      expect(DownloadQueue.enqueue(t), isTrue, reason: '前置：入队必须成功');
      final quiet = await _waitQuiet(timeoutMs: 60000);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!quiet) bad.add('★ 队列没跑完 —— 用例失去意义');
      /*
       * ★ 反假绿：必须**真的观察到**那次 done 的发布，
       *   否则「没观察到」会伪装成「没违规」。
       */
      expect(seen, contains(t.id),
          reason: '前置：必须真的观察到 done 的发布（否则本用例空过）');
      bad.forEach(debugPrint);
      expect(bad, isEmpty,
          reason: '★★ 旁文件落地后才能发布 done（cache_page 按 id 集合去重，第二次 publish 不会重扫）');
    } finally {
      DownloadQueue.tasks.removeListener(onQueue);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  // ══════════════════════════════════════════════════════════════════════
  //  护栏（**不是**缺陷证据：改前改后都应该是绿的）
  //  —— 上面那条修复把「写旁文件」挪进了 else 分支里，这条用例钉住
  //     「暂停的任务不许留下旁文件」，防止将来重构把它挪出去。
  // ══════════════════════════════════════════════════════════════════════

  test('护栏：暂停收尾**不许**留下旁文件（半截文件不该进「已缓存」列表）', () async {
    await ups.close();
    ups = Upstream(segDelayMs: 60); // 慢档：6 片 × 60ms ⇒ 有可靠的暂停窗口
    await ups.start();
    final workDir = await DownloadDir.forWork('OPS16 剧');
    final f = _sidecar(workDir);
    final t = _task(0, cover: 'http://127.0.0.1:' + ups.port.toString() + '/cover.jpg');
    expect(DownloadQueue.enqueue(t), isTrue, reason: '前置：入队必须成功');
    // 等它真的跑起来，再暂停（暂停点在分片边界，见 hls_download.dart:389）
    final dl = DateTime.now().add(const Duration(seconds: 30));
    while (DownloadQueue.debugRunningCount() == 0 &&
        DateTime.now().isBefore(dl)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    DownloadQueue.pause(t.id);
    /*
     * ★ 反假绿的关键：pause() 是**同步**把状态置成 paused 的，而 _run 要到
     *   分片边界才收尾（.part 句柄、旁文件写入都在那之后）。
     *   ⇒ 只等「队列静下来」会在 _run 收尾**之前**就返回 ⇒ 本用例会空过。
     *   ⇒ 必须等 _settling 清空 —— 它是 _run 最后一行才摘的（download_queue.dart
     *      _run 尾部），那一刻旁文件该写的都写完了。
     */
    var sawSettling = false;
    final dl2 = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(dl2)) {
      if (DownloadQueue.debugSettlingCount() > 0) sawSettling = true;
      final st = DownloadQueue.tasks.value
          .where((x) => x.id == t.id)
          .map((x) => x.state)
          .toList();
      if (st.isNotEmpty &&
          st.first == DownloadState.paused &&
          DownloadQueue.debugSettlingCount() == 0 &&
          DownloadQueue.debugRunningCount() == 0) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final task = DownloadQueue.tasks.value.where((x) => x.id == t.id).toList();
    final bad = <String>[];
    if (task.isEmpty || task.first.state != DownloadState.paused) {
      bad.add('前置：任务没到 paused（state=' +
          (task.isEmpty ? '记录没了' : task.first.state.name) +
          '）—— 本护栏失去意义');
    }
    if (!sawSettling) {
      bad.add('★★ 前置：从没观察到收尾窗口（_settling 一直为空）'
          '⇒ 暂停可能发生在下载**已结束之后**，本用例是空过的，不算通过');
    }
    if (DownloadQueue.debugSettlingCount() != 0) {
      bad.add('★ 前置：_run 还没收尾完就下了结论 ⇒ 本用例是空过的，不算通过');
    }
    if (f.existsSync()) {
      bad.add('★ 暂停的任务留下了旁文件（会让「已缓存」页把一个半截文件当成已下载）：' + f.path);
    }
    bad.forEach(debugPrint);
    expect(bad, isEmpty, reason: '旁文件只在**成功**时写');
  }, timeout: const Timeout(Duration(minutes: 3)));

  // ══════════════════════════════════════════════════════════════════════
  //  OPS-16 ① 的平台语义：两侧契约在任意主机上都必须被断言
  // ══════════════════════════════════════════════════════════════════════

  /*
   * 为什么需要这一组：
   *   ① 用例按 Platform.isWindows **分支**断言，本机（Windows）只跑 Windows 那
   *   一支；而 CI 上的红恰恰出在 POSIX 那一支，本机跑不了 macOS。
   *   ⇒ 把「平台」变成**显式参数**（纯函数 sidecarPlatformViolation，:236 起），
   *     再用**假想观测**把两侧契约都在本机钉死 —— 不是用 Platform.isWindows 把
   *     一侧跳掉（跳过 = 那一侧什么都没测 = 另一种假门禁）。
   *     范本：test/zz_t12_defect_a_probe_test.dart:225-302。
   */

  test('平台契约：Windows 与 POSIX 两侧都带牙齿（显式参数 + 假想观测）', () {
    /*
     * ── Windows 侧：rename 覆盖**被别的句柄打开**的目标必抛 errno=5
     *    ⇒ renameFailed=true 时，没有日志就是「静默吞失败」⇒ 必须判违规。
     */
    expect(
      sidecarPlatformViolation(
        windows: true,
        renameFailed: true,
        logPresent: false,
        fallbackLogPresent: false,
        oldHandleTouched: true,
      ),
      isNotNull,
      reason: '★★ Windows：撞锁（renameFailed=true）却一行日志都没有 = 静默吞失败，'
          '必须判违规（这正是原判据要钉的东西）',
    );
    expect(
      sidecarPlatformViolation(
        windows: true,
        renameFailed: true,
        logPresent: true,
        fallbackLogPresent: true,
        oldHandleTouched: true,
      ),
      isNull,
      reason: '★ Windows：如实记了日志就不算违规（原判据的通过路径）',
    );
    // 反向自检：Windows 上**没有**撞锁时，不许凭空要求日志（否则是假红）
    expect(
      sidecarPlatformViolation(
        windows: true,
        renameFailed: false,
        logPresent: false,
        fallbackLogPresent: false,
        oldHandleTouched: false,
      ),
      isNull,
      reason: '★ Windows 反向自检：rename 没失败（没撞锁）时不该要求日志',
    );

    /*
     * ── POSIX 侧：rename(2) 只看**路径** ⇒ 目标被别的 fd 持住不构成失败理由
     *    ⇒ 0 条日志才是对的；一旦出现「退化为原地写」= 原子性被改坏。
     */
    expect(
      sidecarPlatformViolation(
        windows: false,
        renameFailed: false,
        logPresent: false,
        fallbackLogPresent: true,
        oldHandleTouched: true,
      ),
      contains('退化为原地写'),
      reason: '★★ POSIX：出现「退化为原地写」必须判违规 —— 这就是「有人把 rename '
          '换成就地覆盖写」的回归哨兵（本机也能断言，不靠 macOS）',
    );
    // 第二道哨兵：退化日志可能被删掉，但「就地写」必然动到旧句柄
    expect(
      sidecarPlatformViolation(
        windows: false,
        renameFailed: false,
        logPresent: false,
        fallbackLogPresent: false,
        oldHandleTouched: true,
      ),
      isNotNull,
      reason: '★★ POSIX：即使不写日志，就地覆盖也会改到收尾前打开的旧句柄 ⇒ '
          '必须判违规（不依赖日志的第二道哨兵）',
    );
    expect(
      sidecarPlatformViolation(
        windows: false,
        renameFailed: false,
        logPresent: false,
        fallbackLogPresent: false,
        oldHandleTouched: false,
      ),
      isNull,
      reason: '★ POSIX 通过路径：未退化 + 旧句柄没被碰 = 原子替换正常',
    );
    /*
     * ★ 两侧契约必须**真的不同**：同一条观测（有退化日志）在 Windows 上不违规、
     *   在 POSIX 上违规 —— 否则上面的参数化断言是空的（两侧同一套逻辑）。
     */
    expect(
      sidecarPlatformViolation(
        windows: true,
        renameFailed: true,
        logPresent: true,
        fallbackLogPresent: true,
        oldHandleTouched: true,
      ),
      isNull,
      reason: '★ 对照：同一条观测在 Windows 上合法 ⇒ 平台分派不是空转',
    );
    // ① 用例的实际分派：契约必须与 Platform.isWindows 一致（两侧都会执行）
    expect(
      sidecarPlatformViolation(
        windows: Platform.isWindows,
        renameFailed: Platform.isWindows,
        logPresent: true,
        fallbackLogPresent: false,
        oldHandleTouched: false,
      ),
      isNull,
      reason: '★ 本机平台分派自检：本机这一支在「如实记了日志 / 未退化」时必须是绿的',
    );
  });

  test('原子替换 vs 就地覆盖：旧句柄的长度能分辨（平台机制实测）', () async {
    final d = await Directory.systemTemp.createTemp('ops16_atomic_');
    try {
      final target = File(d.path + Platform.pathSeparator + 'sidecar.json');
      const oldBody = '{"provider":"old-provider","id":"old-id"}';
      target.writeAsStringSync(oldBody);
      // 收尾前持住目标 —— 与 ① 用例同一个动作（Windows 上这就是撞锁）
      final hold = target.openSync(mode: FileMode.append);
      try {
        final oldLen = hold.lengthSync();
        expect(oldLen, utf8.encode(oldBody).length,
            reason: '前置：句柄应指着刚写的那份旧内容（长度按**字节**算，不是 UTF-16 码元）');

        final tmp = File(target.path + '.tmp');
        const newBody = '{"provider":"cctv","id":"ops16","title":"OPS16 剧"}';
        expect(utf8.encode(newBody).length, isNot(oldLen),
            reason: '前置：新旧内容长度必须不同，否则「长度」这个判据分辨不了两侧');
        tmp.writeAsStringSync(newBody, flush: true);

        Object? renameError;
        var renamed = false;
        try {
          await tmp.rename(target.path);
          renamed = true;
        } catch (e) {
          renameError = e;
        }

        if (Platform.isWindows) {
          /*
           * ★ Windows 机制实测：目标被别的句柄持住 ⇒ rename 必抛 errno=5。
           *   这就是 ① 用例里 renameFailed=true 的**实测依据**，也是「撞锁必须
           *   如实记」那条判据成立的机制（Windows 上「占用」是真的会挡住 rename）。
           */
          expect(renamed, isFalse,
              reason: '★★ Windows：rename 覆盖被别的句柄打开的目标必须失败'
                  '（① 用例里 renameFailed=true 的实测依据）');
          expect(renameError.toString(), contains('errno = 5'),
              reason: '★ Windows：失败原因必须是「拒绝访问」errno=5，不是别的错'
                  '（否则机制论证不成立）');
          debugPrint('OPS-16①[Windows] rename 实测抛：' + renameError.toString());
          // 生产的兜底分支就是这么写的（lib/core/download_queue.dart:794-810）
          final raf = await target.open(mode: FileMode.write);
          try {
            await raf.writeFrom(utf8.encode(newBody));
            await raf.flush();
          } finally {
            await raf.close();
          }
          expect(target.readAsStringSync(), newBody,
              reason: '前置：兜底就地写之后目标必须是新内容');
          expect(hold.lengthSync(), utf8.encode(newBody).length,
              reason: '★★ Windows 兜底是**就地覆盖** ⇒ 旧句柄长度必然变成新长度；'
                  '这条同时证明「旧句柄长度」这个判据在就地覆盖下确实会变'
                  '（＝ POSIX 支那条断言不是空门）');
        } else {
          /*
           * ★ POSIX 机制实测：rename(2) 只要求**路径**可写，与谁开着旧 inode 无关
           *   ⇒ 必成功 ⇒ ① 用例里 renameFailed=false、0 条日志才是对的。
           */
          expect(renamed, isTrue,
              reason: '★★ POSIX：rename 覆盖一个已被打开的目标不会失败'
                  '（① 用例里 renameFailed=false 的实测依据）');
          expect(renameError, isNull);
          expect(target.readAsStringSync(), newBody,
              reason: '★ POSIX：原子替换后目标必须是新内容');
          expect(hold.lengthSync(), oldLen,
              reason: '★★ POSIX：原子 rename 换的是目录项 ⇒ 旧句柄仍指旧 inode，'
                  '长度不许变 —— 这正是 ① 用例 POSIX 支判据的机制基础');
        }
      } finally {
        hold.closeSync();
      }
    } finally {
      await d.delete(recursive: true);
    }
  });

  // ══════════════════════════════════════════════════════════════════════
  //  OPS-16 ① 的**平台无关**接缝：任何平台都必须真的跑到「重试 → 兜底 → 记日志」
  // ══════════════════════════════════════════════════════════════════════

  /*
   * 与上面「平台契约」那组的区别（两组互补，缺一不可）：
   *   · 上面那组把**平台**变成显式参数、用假想观测在本机钉住两侧判据 ——
   *     它证明的是**判据函数**在两侧都对；
   *   · 这一组要证明的是**产品代码**里那条「重试 → 兜底 → 如实记日志」的路径
   *     在任意平台都被**真的执行过**。
   *
   * 为什么光有上面那组不够：POSIX 的 rename(2) 只要求**路径**可写（谁开着旧
   * inode 与它无关）⇒ 第一次 rename 就成功 ⇒ 退避、兜底、那两条日志在
   * macOS/Linux 上**一次都不会被执行**，门禁在那一侧是空的。
   *
   * 接缝 = lib/core/download_queue.dart 的 debugForceRenameFailures（默认 0）：
   *   > 0 时前 N 次 rename 先减一、再抛一个与 Windows 实测**同形**的
   *   PathAccessException(OS Error: 拒绝访问。, errno = 5)。
   * ⚠️ 接缝只接管「rename 这一步失败」这一个事实 —— 退避序列、兜底原地写、
   *    三条日志**全是产品代码**（不是 mock 掉整条路径）。
   * ⚠️ 默认 0 时只多一次静态读 + 比较，控制流与改前逐字节一致（下面的用例
   *    有一条专门钉这一点）。
   */

  test(
      '★★ OPS-16 ①-接缝：撞锁的三级处理（重试 5 次 → 兜底 → 如实记日志）在**任何平台**都必须真的执行到',
      () async {
    final workDir = await DownloadDir.forWork('OPS16 剧');
    final f = _sidecar(workDir);
    // 盘上先有一份**旧**旁文件（与 ① 用例同一前置：撞锁时必须换成新的）
    f.writeAsStringSync(jsonEncode(<String, Object?>{
      'provider': 'old-provider',
      'id': 'old-id',
      'title': '旧标题',
    }));
    /*
     * ★ 5 = 退避序列长度 + 1 = 生产代码里 rename 的总尝试次数
     *   （_replaceBackoffMs = [20, 50, 120, 250] ⇒ 立即 1 次 + 退避 4 次）。
     *   把 5 次全用掉 ⇒ 必然走到**兜底原地写**那一支。
     * ⚠️ 这里**不持住目标**：本用例要的是「三级处理被执行」，而不是「平台恰好
     *   会锁」—— 后者在 POSIX 上不存在，正是 CI 上 macOS 红的根因。
     * ⚠️ 任务**不带封面**（cover 默认 ''）：cacheCoverImage 会立刻返回 null，
     *   不会先消耗掉接缝计数（封面路径由下面两条用例覆盖）。
     */
    DownloadQueue.debugForceRenameFailures = 5;
    try {
      final t = _task(0);
      expect(DownloadQueue.enqueue(t), isTrue, reason: '前置：入队必须成功');
      final quiet = await _waitQuiet(timeoutMs: 60000);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final bad = <String>[];
      if (!quiet) {
        bad.add('★ 队列没跑完（仍卡在 queued/running）—— 用例失去意义，不是通过');
      }
      final task = DownloadQueue.tasks.value.where((x) => x.id == t.id).toList();
      if (task.isEmpty || task.first.state != DownloadState.done) {
        bad.add('前置：任务没到 done（state=' +
            (task.isEmpty ? '记录没了' : task.first.state.name) +
            ' error=' +
            (task.isEmpty ? '-' : (task.first.error ?? '-')) +
            '）⇒ 这条用例测的是收尾，不是下载本身');
      }
      final meta = _readSidecar(f);
      if (meta == null) {
        bad.add('★★ 旁文件不见了：' + f.path);
      } else {
        if (meta['provider'] != t.provider) {
          bad.add('★★ 旁文件内容还是**旧的**：provider=' +
              meta['provider'].toString() +
              '（新任务应为 ' +
              t.provider +
              '）⇒ 兜底原地写没把**新**内容写进去');
        }
        if (meta['id'] != t.mediaId) {
          bad.add('★★ 旁文件内容还是**旧的**：id=' +
              meta['id'].toString() +
              '（新任务应为 ' +
              t.mediaId +
              '）');
        }
      }
      final tmp = File(f.path + '.tmp');
      if (tmp.existsSync()) {
        bad.add('★★ .tmp 残留没清掉：' + tmp.path);
      }
      // 「不许再静默」：这条日志是本缺陷的签名，修好后不该再出现
      final silent = AppLog.lines
          .where((l) => l.message.contains('旁文件写入被忽略'))
          .map((l) => l.message)
          .toList();
      if (silent.isNotEmpty) {
        bad.add('★★ 仍然静默吞掉了失败：' + silent.first);
      }
      /*
       * ★★★ 本用例的**签名判据**（原 Windows 专属那条，现在平台无关）：
       *   强制 5 次 rename 失败 ⇒ 生产代码必然走「重试 5 次 → 兜底 → 记日志」
       *   ⇒ 任何平台都**必须**在 AppLog 里留下一条含目标路径的撞锁记录。
       *   删掉日志、把兜底改成静默 return、或把重试次数改小 —— 都会在这里红。
       */
      final told = AppLog.lines
          .where((l) =>
              l.message.contains(DownloadQueue.kSidecarName) &&
              l.message.contains('旁文件'))
          .map((l) => l.message)
          .toList();
      if (told.isEmpty) {
        bad.add('★★ 撞锁这件事在 AppLog 里没有任何记录（要求：如实记，含目标路径）');
      }
      final fellBack =
          told.where((m) => m.contains('退化为原地写')).toList();
      if (fellBack.isEmpty) {
        bad.add('★★ 强制 5 次 rename 失败后，日志里没有「退化为原地写」⇒ '
            '三级处理里最关键的兜底那一级没有被执行到');
      } else {
        final m = fellBack.first;
        if (!m.contains('rename 重试 5 次仍被占用')) {
          bad.add('★★ 兜底日志里的重试次数不是 5 次（立即 1 次 + 退避 4 次）：' + m);
        }
        if (!m.contains(f.path)) {
          bad.add('★★ 兜底日志没有写明**目标路径**（「如实记」的最低要求）：' + m);
        }
        if (!m.contains('errno = 5')) {
          bad.add('★ 兜底日志没有带上 rename 失败的原文（errno = 5）：' + m);
        }
      }
      final totalFail = AppLog.lines
          .where((l) => l.message.contains('原子替换彻底失败'))
          .map((l) => l.message)
          .toList();
      if (totalFail.isNotEmpty) {
        bad.add('★★ 目标本来可写（兜底该成功），却报了「彻底失败」：' + totalFail.first);
      }
      if (DownloadQueue.debugForceRenameFailures != 0) {
        bad.add('★★ 接缝没被用干净（剩 ' +
            DownloadQueue.debugForceRenameFailures.toString() +
            '）⇒ rename 的尝试次数不是 5 次，退避/重试的级数被改过');
      }
      bad.forEach(debugPrint);
      expect(bad, isEmpty,
          reason: '★★「重试 → 兜底 → 如实记」是**跨平台**契约，不是 Windows 专属语义');
    } finally {
      DownloadQueue.debugForceRenameFailures = 0;
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      '★★ OPS-16 ①-接缝：退避后成功必须记「rename 第 3 次」；接缝为 0 时与改前逐字节等价',
      () async {
    final workDir = await DownloadDir.forWork('OPS16 剧');
    final target = File(workDir + Platform.pathSeparator + '_sourin-cover.jpg');
    final url = 'http://127.0.0.1:' + ups.port.toString() + '/cover.jpg';
    final bad = <String>[];

    /*
     * ① 接缝为 0 = **生产路径**：干净目标必须一次 rename 成功，
     *    而且**不许**留下任何「原子替换成功（rename 第 N 次）」日志
     *    —— 这就是「默认 0 ⇒ 与改前逐字节等价」的可观测证据。
     */
    AppLog.debugClear();
    final first = await DownloadQueue.cacheCoverImage(url, workDir);
    if (first != '_sourin-cover.jpg') {
      bad.add('★ 接缝为 0（生产路径）时封面就没抓到：' + first.toString());
    }
    final retryLogs0 = AppLog.lines
        .where((l) => l.message.contains('原子替换成功'))
        .map((l) => l.message)
        .toList();
    if (retryLogs0.isNotEmpty) {
      bad.add('★★ 接缝为 0 时不该有任何重试日志（生产路径第一次 rename 就该成功）：' +
          retryLogs0.first);
    }

    /*
     * ② 接缝 = 2：前两次 rename 必失败 ⇒ 第三次成功。
     *    这条路（退避之后**成功**的那一支）在 POSIX 上同样永远走不到，
     *    而它正是「重试不是白重试」的证据：成功了要说，且要说清第几次。
     */
    AppLog.debugClear();
    DownloadQueue.debugForceRenameFailures = 2;
    try {
      final second = await DownloadQueue.cacheCoverImage(url, workDir);
      if (second != '_sourin-cover.jpg') {
        bad.add('★ 重试后封面必须仍然落地：' + second.toString());
      }
      final bytes = target.readAsBytesSync();
      if (bytes.length != kCoverBytes || !bytes.every((b) => b == kCoverByte)) {
        bad.add('★★ 退避后成功的那次替换没把新封面写进去（长度=' +
            bytes.length.toString() +
            '，应=' +
            kCoverBytes.toString() +
            '）');
      }
      if (File(target.path + '.tmp').existsSync()) {
        bad.add('★★ .tmp 残留没清掉：' + target.path + '.tmp');
      }
      final okLogs = AppLog.lines
          .where((l) => l.message.contains('原子替换成功'))
          .map((l) => l.message)
          .toList();
      if (okLogs.isEmpty) {
        bad.add('★★ 重试 2 次后成功，却没有任何「原子替换成功」日志 ⇒ 重试成功了也不说');
      } else {
        if (okLogs.length != 1) {
          bad.add('★ 成功日志应恰好 1 条，实际 ' + okLogs.length.toString() + ' 条');
        }
        if (!okLogs.first.contains('第 3 次')) {
          bad.add('★★ 重试次数记错了（重试 2 次后成功应为「第 3 次」）：' + okLogs.first);
        }
        if (!okLogs.first.contains(target.path)) {
          bad.add('★★ 成功日志没写目标路径：' + okLogs.first);
        }
      }
      if (DownloadQueue.debugForceRenameFailures != 0) {
        bad.add('★★ 接缝剩 ' +
            DownloadQueue.debugForceRenameFailures.toString() +
            ' ⇒ 实际尝试次数不是 3（前 2 次失败 + 第 3 次成功）');
      }
    } finally {
      DownloadQueue.debugForceRenameFailures = 0;
    }
    bad.forEach(debugPrint);
    expect(bad, isEmpty,
        reason: '★★ 退避重试的**成功**那一支也必须在任何平台被真的执行到');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      '★★ OPS-16 ①-接缝：兜底也失败时必须如实记「彻底失败」、清掉 .tmp、不留垃圾（任何平台）',
      () async {
    final workDir = await DownloadDir.forWork('OPS16 剧');
    final url = 'http://127.0.0.1:' + ups.port.toString() + '/cover.jpg';
    /*
     * ★ 用一个**目录**冒充封面目标：
     *   · rename 到一个已存在的目录 ⇒ 两侧平台都必失败（POSIX 是 EISDIR/ENOTDIR，
     *     Windows 实测 errno=5）；
     *   · 兜底 `target.open(mode: FileMode.write)` 打开一个目录 ⇒ 两侧也都必失败。
     * ⇒ 不依赖平台差异就能构造出「重试 + 兜底都没成」的第三级。
     */
    final target = Directory(workDir + Platform.pathSeparator + '_sourin-cover.jpg')
      ..createSync();
    DownloadQueue.debugForceRenameFailures = 5;
    try {
      final got = await DownloadQueue.cacheCoverImage(url, workDir);
      final bad = <String>[];
      if (got != null) {
        bad.add('★★ 兜底必然失败时 cacheCoverImage 必须返回 null（不能假装成功）：' +
            got);
      }
      if (!target.existsSync()) {
        bad.add('★★ 占位目录被删了/被改了：' + target.path);
      }
      if (File(target.path + '.tmp').existsSync()) {
        bad.add('★★ 彻底失败后 .tmp 残留没清掉：' + target.path + '.tmp');
      }
      final failed = AppLog.lines
          .where((l) => l.message.contains('原子替换彻底失败'))
          .map((l) => l.message)
          .toList();
      if (failed.isEmpty) {
        bad.add('★★ 重试 + 兜底都没成，AppLog 里却没有「彻底失败」这条 ⇒ 又回到静默');
      } else {
        final m = failed.first;
        if (!m.contains('封面')) {
          bad.add('★ 彻底失败日志没说是**哪一个**替换（旁文件/封面）：' + m);
        }
        if (!m.contains(target.path)) {
          bad.add('★★ 彻底失败日志没写目标路径：' + m);
        }
        if (!m.contains('rename=PathAccessException')) {
          bad.add('★★ 彻底失败日志没带上 rename 的异常原文：' + m);
        }
        if (m.trimRight().endsWith('兜底=')) {
          bad.add('★★ 彻底失败日志里兜底的异常是空的（等于没记）：' + m);
        }
      }
      if (DownloadQueue.debugForceRenameFailures != 0) {
        bad.add('★★ 接缝没被用干净（剩 ' +
            DownloadQueue.debugForceRenameFailures.toString() +
            '）⇒ 兜底之前 rename 的尝试次数不是 5 次');
      }
      bad.forEach(debugPrint);
      expect(bad, isEmpty,
          reason: '★★ 第三级（彻底失败）也必须如实记，且不留垃圾');
    } finally {
      DownloadQueue.debugForceRenameFailures = 0;
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
