// ///////////////////////////////////////////////////////////////////////////
//  CR-14 回归探针：_run 必须按**任务本身**定位，不能拿一个跨 await 的下标
// ///////////////////////////////////////////////////////////////////////////
//
// # 缺陷一句话
// _run(int i) 在整个生命周期里都用「下标 i」去读写 _list[i]，而 i 是
// _pump 挑选那一刻的快照。并发 >= 2 时，用户删掉**别的**任务（remove）会让
// _list 左移 ⇒ 仍在跑的那一集的 _list[i] 指向了邻居 ⇒
//   进度 / 取消判据 / 暂停判据 / 收尾（state=done、path）全写到别人身上。
//
// # 后果
// 自己永远停在 running（用户看不到「已完成」），而邻居被**冒名顶替**成
// done —— 而它的 path 指向别人的文件，UI 点开那一集是坏的/空的。
//
// # 判据（与时序无关，逐条核对每条记录）
//   ① 每条 state==done 的记录，其 path 必须是自己那一集的文件；
//   ② state==done ⇒ 那个文件必须真的存在且正好 40 片；
//   ③ 每条记录一旦 state==done，done 与 total 都必须 == 40；
//   ④ 跑完一轮后，每条记录都必须到达终态（done/failed），不许有 running；
//   ⑤ 服务器总共只该发 4 × 40 片（重下会 > 160）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 每片字节数
const int kSegBytes = 4096;

/// 清单里的分片数
const int kSegCount = 40;

/// 单集成品应有的精确长度
const int kFullBytes = kSegCount * kSegBytes;

/// 入队几个任务（并发 2 ⇒ 前两个在跑，后两个排队）
const int kTaskCount = 4;

/// 拼 m3u8 用的换行
String kNl() => String.fromCharCode(10);

Directory _sandboxRoot() {
  final p = Directory(Directory.systemTemp.absolute.path +
      Platform.pathSeparator +
      'cr_dl_c14');
  if (!p.existsSync()) p.createSync(recursive: true);
  return p;
}

/// 上游：真 HttpServer + 真 m3u8 + 真分片字节
class Upstream {
  Upstream(this.segCount, this.segBytes, this.delayMs);
  final int segCount;
  final int segBytes;
  final int delayMs;
  late HttpServer _srv;
  int get port => _srv.port;

  /// 已经**发出去**的分片数（判「有没有重下」的唯一可信读数）
  int served = 0;

  Future<void> start() async {
    _srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _srv.listen((req) async {
      /*
       * ★ 每集速度可以不同：路径前缀 /s<ms>/ 覆盖默认片延时。
       *   master.m3u8 里写的是**相对**路径 media.m3u8、media.m3u8 里
       *   写的是相对的 segN.ts ⇒ Uri 解析会自动带上同一前缀，
       *   于是「一集一个速度」只要换 master 的 URL 就够了。
       *   （为什么需要，见 setUp 里那段「每集速度必须不同」）
       */
      var path = req.uri.path;
      var perSeg = delayMs;
      final mm = RegExp(r'^/s(\d+)(/.*)$').firstMatch(path);
      if (mm != null) {
        perSeg = int.parse(mm.group(1)!);
        path = mm.group(2)!;
      }
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
        for (var i = 0; i < segCount; i++) {
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
        final idx = int.parse(path.substring(4).split('.').first);
        await Future<void>.delayed(Duration(milliseconds: perSeg));
        // 第 i 片全填字节 (i & 0xFF) ⇒ 哪片被写了几遍，块序列一眼可验
        final body = List<int>.filled(segBytes, idx & 0xFF);
        req.response.headers.contentType = ContentType.binary;
        req.response.headers.contentLength = body.length;
        req.response.add(body);
        await req.response.close();
        served++;
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
  }

  Future<void> close() => _srv.close(force: true);
}

/// 第 k 集的任务（4 集同名不同集，文件名前缀不同 ⇒ 盘上产物可区分）
DownloadTask _task(int k) => DownloadTask(
      id: 'cctv:cr14:ep' + k.toString(),
      title: 'CR14 剧',
      episodeTitle: '第' + (k + 1).toString() + '集',
      provider: 'cctv',
      mediaId: 'cr14',
      episodeId: 'ep' + k.toString(),
      sourceCode: 'src',
      fileName: '第' + (k + 1).toString().padLeft(2, '0') + '集 CR14',
      cover: '',
    );

/// 第 k 集成品文件名（与 _task 的 fileName 对齐；不带 '.' ⇒ hls_download 补 .ts）
String _fileNameOf(int k) =>
    '第' + (k + 1).toString().padLeft(2, '0') + '集 CR14.ts';

/// 扫成品：返回「块号与该块本该装的字节不一致」的违规清单
List<String> _scanChunks(File out) {
  final bad = <String>[];
  final bytes = out.readAsBytesSync();
  final chunks = bytes.length ~/ kSegBytes;
  for (var c = 0; c < chunks; c++) {
    final want = c & 0xFF;
    for (var b = 0; b < kSegBytes; b++) {
      if (bytes[c * kSegBytes + b] != want) {
        bad.add('第 ' + c.toString() + ' 块本该是第 ' + c.toString() +
            ' 片(字节 ' + want.toString() + ')，实际首字节 ' +
            bytes[c * kSegBytes].toString());
        break;
      }
    }
    if (bad.length >= 6) break;
  }
  return bad;
}

DownloadTask? _byId(String id) {
  final xs = DownloadQueue.tasks.value.where((x) => x.id == id).toList();
  return xs.isEmpty ? null : xs.first;
}

Future<void> _waitFor(bool Function() pred, {int timeoutMs = 30000}) async {
  final dl = DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (!pred() && DateTime.now().isBefore(dl)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Upstream ups;
  late String dir;

  setUp(() async {
    DownloadQueue.debugReset();
    DownloadDir.debugReset();
    UiPrefs.remove(DownloadQueue.kConcurrencyKey);
    // 每片 30ms ⇒ 一集 ~1.2s ⇒ 有足够的 await 窗口让别人插进来删任务
    ups = Upstream(kSegCount, kSegBytes, 30);
    await ups.start();
    /*
     * ★★ 每集的下载速度**必须不同**（Lead 2026-10-10 修的假红/假绿）
     * ```text
     * 原来所有集都是 30ms/片 ⇒ 4 集几乎同时跑完。而用例 ① 的意图是
     * 「ep0 已完成、ep1 **仍在跑**，此时清掉 ep0 ⇒ ep1 的下标从 1 左移到 0」。
     *   · 若 ep1 也已完成 ⇒ clearFinished() 一次清掉两条 ⇒
     *     前置断言 expect(length, beforeRemove - 1) 报 Expected: <3> Actual: <2>
     *     （实测假红，2026-10-10 11:57 那次运行就是这样）
     *   · 更糟的是：ep1 的 _run 也结束了 ⇒ 根本没有「拿着旧下标的在跑任务」
     *     ⇒ 用例会**空过**（假绿）。
     * ⇒ 给 ep0 快档（30ms/片）、其余集慢档（150ms/片）：
     *   ep0 约 1.2s 完成、ep1 约 6s，差 4.8s ⇒ 下标错位窗口是**确定的**。
     * ```
     */
    DownloadQueue.debugSetResolver((t) async {
      final k = int.tryParse(t.id.split('ep').last) ?? 0;
      final ms = k == 0 ? 30 : 150;
      return StreamCandidate(
          url: 'http://127.0.0.1:' +
              ups.port.toString() +
              '/s' +
              ms.toString() +
              '/master.m3u8');
    });
    final sep = Platform.pathSeparator;
    final d = Directory(_sandboxRoot().path +
        sep +
        'w' +
        DateTime.now().microsecondsSinceEpoch.toString())
      ..createSync(recursive: true);
    DownloadDir.setConfiguredDir(d.path);
    dir = d.path;
    // ★ 并发 2：前两集同时在跑，删掉一个会让后面所有下标左移
    DownloadQueue.setConcurrency(2);
  });

  tearDown(() async {
    await ups.close();
    DownloadQueue.debugReset();
    DownloadQueue.debugSetResolver(null);
    DownloadDir.debugReset();
    UiPrefs.remove(DownloadQueue.kConcurrencyKey);
  });

  /// 等队列里再没有 queued/running 的任务（或超时）
  Future<bool> _waitQuiet({int timeoutMs = 120000}) async {
    final dl = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(dl)) {
      final busy = DownloadQueue.tasks.value.any((t) =>
          t.state == DownloadState.queued || t.state == DownloadState.running);
      if (!busy) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return false;
  }

  String _ownFile(int k) => _fileNameOf(k);

  File _out(int k) => File(dir + Platform.pathSeparator + 'CR14 剧'
      + Platform.pathSeparator + _ownFile(k));

  /// 把「每条记录都必须收在自己身上」这件事一次性核对完，返回违规清单
  List<String> _audit(String phase, List<int> expectDone) {
    final bad = <String>[];
    for (final k in expectDone) {
      final id = 'cctv:cr14:ep' + k.toString();
      final t = _byId(id);
      final out = _out(k);
      if (t == null) {
        bad.add(phase + ' 任务 ' + id + ' 从队列里消失了');
        continue;
      }
      final p = t.path ?? '';
      if (t.state != DownloadState.done) {
        bad.add(phase + ' 任务 ' + id + '（' + t.fileName + '）卡在 ' +
            t.state.name + '，文件却已落盘 ' +
            (out.existsSync() ? out.lengthSync().toString() : '不存在'));
        continue;
      }
      if (!p.endsWith(_ownFile(k))) {
        bad.add(phase + ' 任务 ' + id + ' 的 path 指向了别人的文件：' + p);
        continue;
      }
      if (!out.existsSync()) {
        bad.add(phase + ' 任务 ' + id + ' 标了 done，但成品不存在');
        continue;
      }
      if (out.lengthSync() != kFullBytes) {
        bad.add(phase + ' 任务 ' + id + ' 标了 done，成品长度 ' +
            out.lengthSync().toString() + ' ≠ ' + kFullBytes.toString());
        continue;
      }
      final chunks = _scanChunks(out);
      if (chunks.isNotEmpty) {
        bad.add(phase + ' 任务 ' + id + ' 的成品块序列错位：' + chunks.first);
        continue;
      }
      if (t.done != kSegCount || t.total != kSegCount) {
        bad.add(phase + ' 任务 ' + id + ' 标了 done，但进度是 ' +
            t.done.toString() + '/' + t.total.toString());
      }
    }
    return bad;
  }

  void _dump(String tag) {
    final buf = StringBuffer(tag + ' ⇒');
    for (final x in DownloadQueue.tasks.value) {
      final f = x.fileName;
      final out = File(dir + Platform.pathSeparator + 'CR14 剧'
          + Platform.pathSeparator + f + '.ts');
      buf.write('\n  ' + x.id + ' ' + f + ' state=' + x.state.name +
          ' done=' + x.done.toString() + '/' + x.total.toString() +
          ' path=' + (x.path ?? '-') +
          ' 盘上=' + (out.existsSync() ? out.lengthSync().toString() : '-'));
    }
    debugPrint(buf.toString());
  }

  test('★★ CR-14 ①：跑着的任务**前面**少一个时，收尾必须收在自己身上'
      '（clearFinished 让下标左移）', () async {
    for (var k = 0; k < kTaskCount; k++) {
      expect(DownloadQueue.enqueue(_task(k)), isTrue,
          reason: '前置：第 ' + k.toString() + ' 集必须入队成功');
    }
    // 等前两集真的都进了 running（并发 2 的两个槽都占了）
    await _waitFor(
        () => _byId('cctv:cr14:ep0')?.state == DownloadState.running &&
            _byId('cctv:cr14:ep1')?.state == DownloadState.running,
        timeoutMs: 30000);
    expect(DownloadQueue.debugMaxObservedRunning(), greaterThanOrEqualTo(2),
        reason: '前置：必须真的并发 2 条在跑，否则下标不会错位');

    // 等前两集都下过半，再让第 0 集先完成
    await _waitFor(() => ups.served >= 20, timeoutMs: 30000);
    await _waitFor(() => (_byId('cctv:cr14:ep0')?.state) == DownloadState.done,
        timeoutMs: 60000);
    expect(_byId('cctv:cr14:ep0')?.state, DownloadState.done,
        reason: '前置：第 0 集必须先完成（它待在 _list 下标 0）');
    /*
     * ★ 加强前置（Lead 2026-10-10）：此刻 ep1 **必须仍在跑**。
     *   它是这条用例的全部意义 —— 只有「在跑的任务拿着一个已经左移的下标」
     *   才测得到缺陷。ep1 若已结束，这条用例会**空过**（假绿），
     *   比红更糟（本仓铁律）。
     */
    expect(_byId('cctv:cr14:ep1')?.state, DownloadState.running,
        reason: '前置：第 1 集必须仍在跑，否则测不到「在跑任务的下标左移」');
    final beforeRemove = DownloadQueue.tasks.value.length;
    debugPrint('CR-14① 清记录前 队列长度=' + beforeRemove.toString() +
        ' 服务器已发=' + ups.served.toString());

    // ★★ 制造错位：清掉已完成的那条 ⇒ 第 1 集的下标从 1 变成 0，
    //   而它的 _run 还拿着旧的 i=1 ⇒ 之后的 _list[1] 是**别人**。
    DownloadQueue.clearFinished();
    expect(DownloadQueue.tasks.value.length, beforeRemove - 1,
        reason: '前置：确实少了一条');

    final quiet = await _waitQuiet(timeoutMs: 45000);
    _dump('CR-14① 收尾后');
    debugPrint('CR-14① 队列已静=' + quiet.toString());

    // 只核对**还在队列里**的 3 条（第 0 集刚被我们主动清掉，记录已不存在）；
    // 顺带确认第 0 集落下的文件没被别人的 _run 写坏。
    final bad = _audit('CR-14①', <int>[1, 2, 3]);
    final ep0 = _out(0);
    if (!ep0.existsSync() || ep0.lengthSync() != kFullBytes) {
      bad.insert(0, '★★ 第 0 集的成品被改坏了：' +
          (ep0.existsSync() ? ep0.lengthSync().toString() : '不存在') +
          ' ≠ ' + kFullBytes.toString());
    }
    if (!quiet) {
      bad.insert(
          0,
          '★★ 跑完一轮后队列里仍有 running 的任务 ⇒ 有任务的 _run 早就'
              '结束了却再没被写回终态（下标错位 ⇒ 写到了邻居身上）');
    }
    expect(bad, isEmpty,
        reason: '★★ _run 必须按任务身份（id）定位，不能拿一个跨 await 的下标');
    expect(ups.served, kTaskCount * kSegCount,
        reason: '★ 服务器总共只该发 ' + (kTaskCount * kSegCount).toString() +
            ' 片，实际 ' + ups.served.toString() + '（> 说明有集被重下）');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('★★ CR-14 ②：跑着的任务**自己**被删时，它不得把结论写到邻居身上'
      '（remove 的 400ms 窗口里下标不变，删完之后下一个任务接手同一格）',
      () async {
    for (var k = 0; k < 2; k++) {
      expect(DownloadQueue.enqueue(_task(k)), isTrue,
          reason: '前置：第 ' + k.toString() + ' 集必须入队成功');
    }
    await _waitFor(
        () => _byId('cctv:cr14:ep0')?.state == DownloadState.running &&
            _byId('cctv:cr14:ep1')?.state == DownloadState.running,
        timeoutMs: 30000);
    await _waitFor(() => ups.served >= 16, timeoutMs: 30000);

    // ★ 删除第 0 集：它先进 failed、再等 400ms、再摘出 _list ⇒ 下标左移。
    //   第 1 集的 _run 仍拿着 i=1，此时 _list[1] 已不存在（只剩它自己，i=0），
    //   或已被新任务补位 ⇒ 它必须**什么都不写**。
    final n0 = DownloadQueue.tasks.value.length;
    await DownloadQueue.remove('cctv:cr14:ep0');
    expect(_byId('cctv:cr14:ep0'), isNull,
        reason: '前置：第 0 集的记录必须被摘掉');
    debugPrint('CR-14② 删除完成 删前长度=' + n0.toString() +
        ' 删后长度=' + DownloadQueue.tasks.value.length.toString() +
        ' 服务器已发=' + ups.served.toString());

    final quiet = await _waitQuiet(timeoutMs: 45000);
    _dump('CR-14② 收尾后');

    final bad = _audit('CR-14②', <int>[1]);
    if (!quiet) {
      bad.insert(0, '★★ 第 1 集跑完后仍卡在非终态');
    }
    bad.forEach(debugPrint);
    expect(bad, isEmpty,
        reason: '★★ 被删掉的任务留下的 _run 不得再改别人的状态');
    // 第 0 集已被删 ⇒ 它的 .part 不该留在盘上（remove 会清产物）
    final ep0Part = File(dir + Platform.pathSeparator + 'CR14 剧'
        + Platform.pathSeparator + _fileNameOf(0) + '.part');
    expect(ep0Part.existsSync(), isFalse,
        reason: '★ 被删任务的半截文件必须清掉');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('★★ CR-14 ③：并发 3 且中途插入新任务时，收尾仍按身份落位'
      '（_list 尾部增长，_pump 会给新任务占槽）', () async {
    DownloadQueue.setConcurrency(3);
    for (var k = 0; k < 2; k++) {
      expect(DownloadQueue.enqueue(_task(k)), isTrue,
          reason: '前置：第 ' + k.toString() + ' 集必须入队成功');
    }
    await _waitFor(
        () => _byId('cctv:cr14:ep0')?.state == DownloadState.running &&
            _byId('cctv:cr14:ep1')?.state == DownloadState.running,
        timeoutMs: 30000);
    // ★ 中途插一个**新的**任务（第 2 集）⇒ 它会排在队尾，
    //   不会让老任务下标变化，却会让「按下标找自己」的假设更脆弱。
    expect(DownloadQueue.enqueue(_task(2)), isTrue, reason: '前置：插队必须成功');
    await _waitFor(() => ups.served >= 16, timeoutMs: 30000);
    await _waitQuiet(timeoutMs: 90000);
    _dump('CR-14③ 收尾后');

    final bad = _audit('CR-14③', <int>[0, 1, 2]);
    bad.forEach(debugPrint);
    expect(bad, isEmpty, reason: '★★ 三集并发时收尾必须各归各位');
    expect(ups.served, 3 * kSegCount,
        reason: '★ 服务器总共只该发 ' + (3 * kSegCount).toString() +
            ' 片，实际 ' + ups.served.toString());
  }, timeout: const Timeout(Duration(minutes: 5)));
}
