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
     */
    final hold = f.openSync(mode: FileMode.append);
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
      // 反过来：必须有一条**如实**记录（含目标路径）
      final told = AppLog.lines
          .where((l) =>
              l.message.contains(DownloadQueue.kSidecarName) &&
              l.message.contains('旁文件'))
          .map((l) => l.message)
          .toList();
      if (told.isEmpty) {
        bad.add('★★ 撞锁这件事在 AppLog 里没有任何记录（要求：如实记，含目标路径）');
      } else {
        debugPrint('OPS-16① 日志如实记录 ⇒ ' + told.first);
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
}
