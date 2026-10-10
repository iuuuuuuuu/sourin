// ///////////////////////////////////////////////////////////////////////////
//  CR-15 回归探针：暂停收尾必须把**实际落盘的分片数**写回任务
// ///////////////////////////////////////////////////////////////////////////
//
// # 缺陷一句话
// _run 的暂停收尾只 copyWith(path:)，**不写 done**；而 onProg 在
// 'if (cur.state != DownloadState.running) return;' 处提前返回
// （暂停后状态已是 paused）⇒ 任务上的 done 停在最后一次「每 8 片」节流点，
// 而 .part 里其实已经写进了更多片。
//
// # 后果（数据损坏级）
// 继续时 initialDone=t.done 传给 HlsDownloader ⇒ skip 比 .part 里实际
// 已有的片数少 ⇒ 下载器把**已经躺在 .part 里**的那几片又拉一遍并追加 ⇒
// 成品里出现重复分片 ⇒ 播放器播到拼接点就坏掉。
//
// # ★★ 判据为什么这么写（第一版是假门禁，已弃）
//   v1：_waitFor(done >= 8) 之后立刻 pause()。实测**全绿** —— 原因：
//     onProgress(i+1) 与下一个分片边界的 isPaused() 之间**没有 await**，
//     「看到 done 变 8」到「边界检查 i=8」不可插队 ⇒ 暂停**必然**落在与
//     done 对齐的边界上 ⇒ 缺陷永远测不出来。
//     （同一坑的第二版：只写「续传新增分片 < total」—— zz_t11_panel_probe
//     的暂停用例就是它，重复拼接时照样通过。）
//   v2（本版）：按**服务器已发片数**选暂停时机，停在「非 8 的倍数」的片数上，
//     并给每一片**不同的字节**（第 i 片全填 i）⇒ 「重复拼接」在成品里
//     可以逐块验出来，不依赖任何时序猜测。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 每片的字节数（4 KB）
const int kSegBytes = 4096;

/// 清单里的分片数
const int kSegCount = 40;

/// 成品应有的精确长度（40 片 × 4096）
const int kFullBytes = kSegCount * kSegBytes;

/// onProg 的节流步长（每 8 片才写一次 done）
const int kThrottle = 8;

/// ★ 在「服务器已发够这么多片」时才暂停。
///   取 20：20/21/22 都不是 8 的倍数 ⇒ 无论客户端此刻在第几个边界停下，
///   done 都还停在 8（或 16）⇒ 与真实落盘片数**必然不等** ⇒ 缺陷必然暴露。
const int kPauseAfterServed = 20;

/// 拼 m3u8 用的换行
String kNl() => String.fromCharCode(10);

Directory _sandboxRoot() {
  final p = Directory(Directory.systemTemp.absolute.path +
      Platform.pathSeparator +
      'cr_dl_c15');
  if (!p.existsSync()) p.createSync(recursive: true);
  return p;
}

/// 上游：真 HttpServer，真 m3u8，真分片字节
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
        if (delayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
        // ★★ 第 i 片全填字节 (i & 0xFF) ——
        //   这样「哪一片被写了几遍」在成品里一眼可验，不靠猜。
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

/// 把 .part 的字节数换算成「已落盘分片数」（独立读数，不看任务字段）
int _segmentsInPart(File part) {
  if (!part.existsSync()) return 0;
  return part.lengthSync() ~/ kSegBytes;
}

/// 扫成品：返回「块号 → 该块实际装的字节值」的违规清单
List<String> _scanDuplicates(File out) {
  final bad = <String>[];
  final bytes = out.readAsBytesSync();
  final chunks = bytes.length ~/ kSegBytes;
  for (var c = 0; c < chunks; c++) {
    final want = c & 0xFF;
    var ok = true;
    for (var b = 0; b < kSegBytes; b++) {
      if (bytes[c * kSegBytes + b] != want) {
        ok = false;
        break;
      }
    }
    if (!ok) {
      bad.add('第 ' + c.toString() + ' 块本该是第 ' + c.toString() +
          ' 片(字节 ' + want.toString() + ')，实际首字节 ' +
          bytes[c * kSegBytes].toString());
      if (bad.length >= 6) break;
    }
  }
  return bad;
}

DownloadTask _task(String title, int k) => DownloadTask(
      id: 'cctv:cr15:ep' + k.toString(),
      title: title,
      episodeTitle: '第' + (k + 1).toString() + '集',
      provider: 'cctv',
      mediaId: 'cr15',
      episodeId: 'ep' + k.toString(),
      sourceCode: 'src',
      fileName: '第' + (k + 1).toString().padLeft(2, '0') + '集 CR15',
      cover: '',
    );

/// 等这一集的暂停收尾真的做完（句柄已释放）⇒ .part 变成静止读数。
/// 返回是否等到了（false = 没等到，调用方的断言会自己报出来）。
Future<bool> _waitForSettled({int timeoutMs = 15000}) async {
  final dl = DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (DateTime.now().isBefore(dl)) {
    if (DownloadQueue.debugSettlingCount() == 0) {
      final t = _byId('cctv:cr15:ep0');
      if (t != null && t.state == DownloadState.paused) return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return false;
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

Future<void> _waitTerminal(String id, {int timeoutMs = 120000}) async {
  final dl = DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (DateTime.now().isBefore(dl)) {
    final t = _byId(id);
    if (t == null) return;
    final s = t.state;
    if (s == DownloadState.done || s == DownloadState.failed) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Upstream ups;
  late String dir;

  setUp(() async {
    DownloadQueue.debugReset();
    DownloadDir.debugReset();
    UiPrefs.remove(DownloadQueue.kConcurrencyKey);
    // 每片 20ms ⇒ 40 片要 ~0.8s，足够在分片边界观察到暂停
    ups = Upstream(kSegCount, kSegBytes, 20);
    await ups.start();
    DownloadQueue.debugSetResolver((t) async => StreamCandidate(
        url: 'http://127.0.0.1:' + ups.port.toString() + '/master.m3u8'));
    final sep = Platform.pathSeparator;
    final d = Directory(_sandboxRoot().path +
        sep +
        'w' +
        DateTime.now().microsecondsSinceEpoch.toString())
      ..createSync(recursive: true);
    DownloadDir.setConfiguredDir(d.path);
    dir = d.path;
  });

  tearDown(() async {
    await ups.close();
    DownloadQueue.debugReset();
    DownloadQueue.debugSetResolver(null);
    DownloadDir.debugReset();
    UiPrefs.remove(DownloadQueue.kConcurrencyKey);
  });

  test('★★ CR-15：暂停收尾必须把 .part 里**真实落盘**的分片数写回任务；'
      '继续后成品必须正好是 40 片、一片不重一片不漏', () async {
    final sep = Platform.pathSeparator;
    expect(DownloadQueue.enqueue(_task('CR15 剧', 0)), isTrue,
        reason: '前置：入队必须成功');

    // ★ 关键手法：等到**服务器已发够 20 片**才暂停。
    //   20 不是 8 的倍数 ⇒ 无论停在 20/21/22 哪个边界，
    //   任务上的 done 都还停在 8 或 16 ⇒ 与真实落盘片数必然不等。
    await _waitFor(() => ups.served >= kPauseAfterServed, timeoutMs: 30000);
    final okPause = DownloadQueue.pause('cctv:cr15:ep0');
    await _waitFor(
        () => (_byId('cctv:cr15:ep0')?.state) == DownloadState.paused,
        timeoutMs: 10000);

    // ★ 等「暂停收尾真的做完了」再量 —— 这才是 .part 的静止读数。
    //   判据用**句柄已释放**这个已有读数（DownloadQueue.debugSettlingCount()==0，
    //   见 _run 结尾「暂停收尾完成（句柄已释放）」那行日志）：
    //   状态刚变 paused 时下载器还可能在补写最后一片，此刻读 .part 会偏小，
    //   实测就会让 done==真实落盘数 而让判据变成假门禁。
    final settled = await _waitForSettled();
    final t1 = _byId('cctv:cr15:ep0');
    final part = File(dir + sep + 'CR15 剧' + sep + '第01集 CR15.ts.part');
    final inPart = _segmentsInPart(part);
    debugPrint('CR-15 暂停调用=' + okPause.toString() +
        ' 暂停时服务器已发=' + ups.served.toString() +
        ' 任务done=' + (t1?.done ?? -1).toString() +
        ' 任务total=' + (t1?.total ?? -1).toString() +
        ' .part真实落盘=' + inPart.toString() +
        ' 节流步长=' + kThrottle.toString());

    expect(t1, isNotNull, reason: '前置：任务必须还在队列里');
    expect(t1!.state, DownloadState.paused, reason: '暂停后状态必须是 paused');
    expect(part.existsSync(), isTrue, reason: '前置：暂停必须保留 .part');
    expect(inPart, greaterThan(kThrottle),
        reason: '前置：必须已经下过不止一片且超过第一个节流点，'
            '否则「done 恰好等于真实落盘数」会让这条判据变成假门禁');

    expect(settled, isTrue, reason: '前置：暂停收尾必须真的结束（句柄已释放）');
    debugPrint('CR-15 收尾已静止（settled=' + settled.toString() +
        ' settling=' + DownloadQueue.debugSettlingCount().toString() + ')');
    // ★★ 判据①（判因）：任务上的 done 必须等于 .part 里真实落盘的分片数
    expect(t1.done, inPart,
        reason: '★★ 暂停收尾没把下载器回报的分片数写回任务：'
            '任务说已下 ' + t1.done.toString() + ' 片，.part 里其实有 ' +
            inPart.toString() + ' 片 ⇒ 继续时 initialDone 偏小 ⇒ '
            '已落盘的片会被**再拉一遍并追加**（重复分片 ⇒ 成品损坏）');
    // 继续：initialDone 由 _run 取自 t1.done
    DownloadQueue.resume('cctv:cr15:ep0');
    await _waitTerminal('cctv:cr15:ep0');
    final t2 = _byId('cctv:cr15:ep0');
    final out = File(dir + sep + 'CR15 剧' + sep + '第01集 CR15.ts');
    final outLen = out.existsSync() ? out.lengthSync() : -1;
    debugPrint('CR-15 继续后 state=' + (t2?.state ?? '?').toString() +
        ' 成品存在=' + out.existsSync().toString() +
        ' 长度=' + outLen.toString() +
        ' 期望=' + kFullBytes.toString() +
        ' 服务器共发片数=' + ups.served.toString());
    expect(t2, isNotNull);
    expect(t2!.state, DownloadState.done, reason: '继续后必须下完');
    expect(out.existsSync(), isTrue, reason: '前置：续传完应有成品');

    // ★★ 判据②（判果·长度）：成品必须正好是 40 片 × 4096。
    //   多一片 = 重复拼接（损坏）；少一片 = 漏片（损坏）。
    expect(outLen, kFullBytes,
        reason: '★★ 成品必须是 40 片 × 4096 = ' + kFullBytes.toString() +
            ' 字节，实际 ' + outLen.toString() +
            '（多 = 重复拼接，少 = 漏片，两种都是文件损坏）');

    // ★★ 判据③（判果·内容）：第 i 块必须是第 i 片 —— 重复拼接的直接物证
    final bad = _scanDuplicates(out);
    debugPrint('CR-15 成品块序列违规 ' + bad.length.toString() + ' 处');
    bad.forEach(debugPrint);
    expect(bad, isEmpty,
        reason: '★★ 成品里出现了错位/重复的分片（每片字节=i，块 i 必须是 i）');

    // 旁证：服务器总共只该发 40 片；重下会让它 > 40
    expect(ups.served, kSegCount,
        reason: '★ 服务器总共被拉的片数必须正好是 ' + kSegCount.toString() +
            '，实际 ' + ups.served.toString() +
            '（> 40 说明续传时重下了已落盘的片）');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
