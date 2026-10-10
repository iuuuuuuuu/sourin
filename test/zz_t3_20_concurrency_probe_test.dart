// ═══════════════════════════════════════════════════════════════════════
//  ⑳ 整片下载并发数 —— 真实并发实测（探针，不入库）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这样测（而不是断言一下 concurrency 配置读到了）
// ```text
// Owner 第 20 条要的是「并发数可配置」。光断言 pref 读回来是 3 毫无意义 ——
// 要证明的是**真的有 3 个任务同时在跑**。所以这份探针做了三件真事：
//   ① 起一个**真的 HttpServer** 当上游（真的收发 HTTP 字节）；
//   ② 服务器端**同时活跃请求数**记峰值（_serverPeak）—— 这是独立读数；
//   ③ 读 DownloadQueue._markRunning 里记的 debugMaxObservedRunning()
//      —— 那是队列自己数的槽位峰值，两边必须对得上。
// ```
//
// ⚠️ 上游故意每个响应 sleep 300ms：不打这个桩的话，任务会瞬间跑完，
//    并发窗口短到测不出峰值（会得到假阴性「峰值=1」）。
//
// ═══════════════════════════════════════════════════════════════════════
//  ★★ 2026-10-09 事故修复：探针产物差点落在**仓库根**
// ═══════════════════════════════════════════════════════════════════════
// ```text
// 事故：第一版的目录名写成了字符串里的 '${Directory.systemTemp.path}'。
//   ★ 那一层是**单引号普通字符串**，${...} 不是插值 ⇒ 它就是一个字面量
//     目录名 '${Directory.systemTemp.path}'（27 个字符的目录名！）。
//   ⇒ Directory('<字面量>/t3_20_conc/c1') 被当成**相对路径**解析，
//     于是产物落在了**仓库根**，多出一个名叫 '${Directory.systemTemp.path}'
//     的目录，里面是 c1-x.mp4.mp4 / c3-x.mp4.mp4。
//   ⇒ 这不是测试失败，是**污染用户仓库**。
//
// 修法（两条都做）：
//   ① 绝对路径只从一处来：_sandboxRoot()，且**断言它是绝对路径**
//      （!isAbsolute ⇒ 立刻 fail，绝不让它退回相对路径）；
//   ② 收尾**自清理**：tearDownAll 删掉整个沙盒（删之前再断言一次绝对路径）。
// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 服务器侧：同时活跃请求数（正在 sleep 的那些）
int _serverActive = 0;
int _serverPeak = 0;

/// ★ 探针沙盒根 —— **必须**是绝对路径，且落在系统临时目录下
///
/// ⚠️ 绝不允许退化成相对路径：相对路径会解析到**仓库根**（已出过一次事）。
Directory _sandboxRoot() {
  final base = Directory.systemTemp.absolute.path;
  final p = '$base${Platform.pathSeparator}t3_20_conc';
  final d = Directory(p);
  if (!d.isAbsolute) {
    fail('★ 探针沙盒必须是绝对路径，实际 = $p —— 绝不允许落回仓库根');
  }
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

Future<HttpServer> _startUpstream() async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) async {
    _serverActive++;
    if (_serverActive > _serverPeak) _serverPeak = _serverActive;
    try {
      /*
       * ★ 每个请求故意慢 300ms：并发窗口必须**宽到**能被观察到。
       *   没有这一句，N 个请求会在同一个事件循环 tick 里跑完，
       *   _serverPeak 恒为 1 —— 那是**探针自己的假阴性**，不是产品的问题。
       */
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final body = List<int>.filled(4096, 0x41);
      req.response.headers.contentType = ContentType.binary;
      req.response.headers.contentLength = body.length;
      req.response.add(body);
      await req.response.close();
    } finally {
      _serverActive--;
    }
  });
  return s;
}

DownloadTask _task(String prefix, int k) => DownloadTask(
      id: '$prefix-$k',
      title: '探针剧',
      episodeTitle: '第${k + 1}集',
      provider: 'cctv',
      mediaId: 'cctv1',
      episodeId: 'ep$k',
      sourceCode: 'src',
      fileName: '$prefix-$k.mp4',
    );

Future<void> _waitIdle() async {
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (DownloadQueue.activeCount > 0 && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() {
    _serverActive = 0;
    _serverPeak = 0;
    DownloadQueue.debugReset();
    UiPrefs.remove(DownloadQueue.kConcurrencyKey);
  });

  tearDown(() {
    DownloadQueue.debugReset();
    DownloadQueue.debugSetResolver(null);
    UiPrefs.remove(DownloadQueue.kConcurrencyKey);
  });

  tearDownAll(() {
    /*
     * ★ 收尾自清理：探针产物一律不许留下（尤其不许落在仓库根）。
     *   删之前**再断言一次**绝对路径 —— 一旦有人把它改回相对路径，
     *   这里就会红，而不是默默去删仓库里的东西。
     */
    final d = Directory('${Directory.systemTemp.absolute.path}${Platform.pathSeparator}t3_20_conc');
    if (!d.isAbsolute) {
      fail('★ 清理路径必须是绝对路径，实际 = ${d.path}');
    }
    if (d.existsSync()) d.deleteSync(recursive: true);
    debugPrint('CLEANUP 已删除探针沙盒 ${d.path} 存在=${d.existsSync()}');
  });

  test('★ 并发 1（缺省）⇒ 同时最多 1 个任务在跑', () async {
    final srv = await _startUpstream();
    DownloadQueue.debugSetResolver((t) async =>
        StreamCandidate(url: 'http://127.0.0.1:${srv.port}/seg'));
    final dir = Directory('${_sandboxRoot().path}${Platform.pathSeparator}c1')
      ..createSync(recursive: true);
    DownloadDir.setConfiguredDir(dir.path);
    for (var k = 0; k < 4; k++) {
      DownloadQueue.enqueue(_task('c1', k));
    }
    await _waitIdle();
    final queuePeak = DownloadQueue.debugMaxObservedRunning();
    debugPrint('MEASURE 队列观测峰值(配 1) = $queuePeak');
    debugPrint('MEASURE 服务器观测峰值(配 1) = $_serverPeak');
    debugPrint('MEASURE 落盘目录(配 1) = \${dir.path}');
    expect(queuePeak, 1, reason: '★ 缺省串行 ⇒ 队列侧峰值必须是 1');
    expect(_serverPeak, 1, reason: '★ 服务器侧也必须是 1（两边对得上）');
    await srv.close(force: true);
  });

  test('★★ 并发 3 ⇒ 真的有 3 个任务同时在跑（服务器侧也数到 3）', () async {
    final srv = await _startUpstream();
    DownloadQueue.debugSetResolver((t) async =>
        StreamCandidate(url: 'http://127.0.0.1:${srv.port}/seg'));
    final dir = Directory('${_sandboxRoot().path}${Platform.pathSeparator}c3')
      ..createSync(recursive: true);
    DownloadDir.setConfiguredDir(dir.path);
    DownloadQueue.setConcurrency(3);
    debugPrint('MEASURE concurrency 读回 = ${DownloadQueue.concurrency}');
    for (var k = 0; k < 6; k++) {
      DownloadQueue.enqueue(_task('c3', k));
    }
    await _waitIdle();
    final queuePeak = DownloadQueue.debugMaxObservedRunning();
    debugPrint('MEASURE 队列观测峰值(配 3) = $queuePeak');
    debugPrint('MEASURE 服务器观测峰值(配 3) = $_serverPeak');
    expect(queuePeak, 3, reason: '★ 配 3 就必须真的跑到 3 个同时在跑');
    expect(_serverPeak, 3,
        reason: '★★ 服务器侧独立数出来的峰值也必须是 3（两个独立读数互证）');
    await srv.close(force: true);
  });

  test('★ 越界值被夹住：999 ⇒ 3，0 ⇒ 1', () async {
    DownloadQueue.setConcurrency(999);
    final hi = DownloadQueue.concurrency;
    debugPrint('MEASURE 夹上界 999 => $hi');
    expect(hi, 3, reason: '★ 上界 = maxConcurrency');
    DownloadQueue.setConcurrency(0);
    final lo = DownloadQueue.concurrency;
    debugPrint('MEASURE 夹下界 0 => $lo');
    expect(lo, 1, reason: '★ 下界 = 1（绝不退化成无上限）');
  });
}
