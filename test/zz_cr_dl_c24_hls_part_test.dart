// ==================================================================
//  CodeRabbit CR-24 回归测试：遗留 .part + 全新下载 ⇒ 必须覆盖而不是追加
// ==================================================================
//
// # 缺陷（lib/core/hls_download.dart:327-331）
// ```dart
//   final append = part.existsSync() && part.lengthSync() > 0;
// ```
// 只看盘上有没有非空 .part，不看调用方是不是在续传（initialDone）。
//
// # 为什么这条判据在真机上能红
//   遗留 .part 的常见成因是**进程被杀 / 断电** ⇒ 那次的 catch 根本没跑 ⇒
//   盘上留着一段半截文件。下一轮若用户重试（initialDone = 0），
//   就会把完整分片序列追加到旧半截后面 ⇒ 成品 = 旧半截 + 新完整，在拼接点损坏。
//
// # 断言用「字节内容」而不只看长度
//   长度断言只能证明多/少了多少；字节断言能直接证明
//   **旧半截的字节还留在成品里** —— 那正是「叠在一起」的实质。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/hls_download.dart';

/// 分片数与每片字节（刻意与遗留半截的长度不同，便于按长度反推）
const int kSegCount = 12;
const int kSegBytes = 4096;
const int kFullBytes = kSegCount * kSegBytes;

/// 遗留半截文件里用的字节（真实场景 = 上次被杀时已写下的分片）
const int kStaleByte = 0xEE;
const int kStaleBytes = 1024 * 1024;

/// 拼 m3u8 用的换行（代码生成用常量，免得源文件里再冒出反斜杠）
String kNl() => String.fromCharCode(10);

/// 上游：一段**有 ENDLIST 的媒体列表**（不是直播）
class Upstream {
  Upstream(this.segCount, this.segBytes);
  final int segCount;
  final int segBytes;
  late HttpServer _srv;
  int get port => _srv.port;

  /// 服务器一共发出去多少个分片（用来证明「续传没有重下」）
  int served = 0;

  Future<void> start() async {
    _srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _srv.listen((req) async {
      final path = req.uri.path;
      if (path == '/media.m3u8') {
        final b = StringBuffer();
        b.write('#EXTM3U' + kNl());
        b.write('#EXT-X-VERSION:3' + kNl());
        b.write('#EXT-X-TARGETDURATION:4' + kNl());
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
        final body = List<int>.filled(segBytes, 0xCD);
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

Directory _sandboxRoot() {
  final sep = Platform.pathSeparator;
  final d = Directory('${Directory.systemTemp.absolute.path}${sep}cr_dl_c24');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

/// 一个干净的工作目录（每条用例用新目录，避免上一条的成品干扰）
Directory _freshWorkDir(String tag) {
  final sep = Platform.pathSeparator;
  final d = Directory('${_sandboxRoot().path}${sep}$tag');
  if (d.existsSync()) d.deleteSync(recursive: true);
  d.createSync(recursive: true);
  return d;
}

/// ★ 手工造一段「上次被杀留下的半截文件」
File _writeStalePart(Directory dir, String fileName) {
  final sep = Platform.pathSeparator;
  // fileName 不含点号 ⇒ 成品扩展名是 .ts ⇒ 半截文件是 <fileName>.ts.part
  final f = File('${dir.path}${sep}$fileName.ts.part');
  f.writeAsBytesSync(List<int>.filled(kStaleBytes, kStaleByte));
  return f;
}

void main() {
  late Upstream ups;

  setUp(() async {
    ups = Upstream(kSegCount, kSegBytes);
    await ups.start();
  });

  tearDown(() async {
    await ups.close();
  });

  String url() => 'http://127.0.0.1:' + ups.port.toString() + '/media.m3u8';

  test('★ 遗留 .part + 全新下载 ⇒ 成品长度 = 清单分片总长度（旧字节不许残留）',
      () async {
    const name = 'CR24 第01集';
    final dir = _freshWorkDir('stale_part');
    final stale = _writeStalePart(dir, name);
    debugPrint('CR-24 造遗留半截 ' + stale.path + ' ' + kStaleBytes.toString() + ' 字节');
    expect(stale.lengthSync(), kStaleBytes, reason: '前置：半截文件已就位');

    // ★ 不传 initialDone = 这是一次全新下载（用户重试场景）
    final r =
        await HlsDownloader.download(url: url(), intoDir: dir.path, fileName: name);
    final sep = Platform.pathSeparator;
    final out = File('${dir.path}${sep}$name.ts');
    debugPrint('CR-24 全新下载完成 长度=' + (out.existsSync() ? out.lengthSync().toString() : '-1') +
        ' 报告字节=' + r.bytes.toString() + ' 报告分片=' + r.segments.toString() +
        ' 期望=' + kFullBytes.toString());
    expect(out.existsSync(), isTrue, reason: '前置：应有成品');
    expect(out.lengthSync(), kFullBytes,
        reason: '★★ 全新下载必须覆盖半截文件。实际长度 ' + out.lengthSync().toString() +
            ' = 半截 ' + kStaleBytes.toString() + ' + 新 ' + kFullBytes.toString() +
            ' ⇒ 正是「旧半截 + 新完整」叠在一起');
    expect(r.bytes, kFullBytes, reason: '回报的字节数也必须只算新的');

    // ★ 更硬的证据：旧半截的字节一个都不许留在成品里
    final all = out.readAsBytesSync();
    final staleLeft = all.where((x) => x == kStaleByte).length;
    debugPrint('CR-24 成品里旧半截字节数=' + staleLeft.toString() + '（必须 0）');
    expect(staleLeft, 0, reason: '★ 成品里还残留上次被杀写下的字节 ⇒ 文件已损坏');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('★ initialDone>0 但 .part 已被清掉 ⇒ 不能凭空跳过前 N 片', () async {
    const name = 'CR24 第02集';
    final dir = _freshWorkDir('missing_part');
    final sep = Platform.pathSeparator;
    final out = File('${dir.path}${sep}$name.ts');
    final part = File('${dir.path}${sep}$name.ts.part');
    expect(part.existsSync(), isFalse, reason: '前置：盘上没有 .part');

    // 调用方以为「已经下好 5 片」（暂停后 .part 被清理工具/用户删了）
    final r = await HlsDownloader.download(
        url: url(), intoDir: dir.path, fileName: name, initialDone: 5);
    debugPrint('CR-24 无 .part 却报 initialDone=5 ⇒ 长度=' +
        (out.existsSync() ? out.lengthSync().toString() : '-1') +
        ' 期望=' + kFullBytes.toString() +
        ' 分片=' + r.segments.toString() + ' 服务器已发=' + ups.served.toString());
    expect(out.existsSync(), isTrue, reason: '前置：应有成品');
    expect(out.lengthSync(), kFullBytes,
        reason: '★★ .part 不存在 ⇒ 前面 5 片根本没写过，跳过它们 = 成品缺 5 片');
    expect(r.segments, kSegCount);
    expect(ups.served, kSegCount, reason: '★ 必须真的把 12 片都拉一遍');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('★ 正常续传仍然成立：initialDone>0 且 .part 非空 ⇒ 接着写且不重下', () async {
    const name = 'CR24 第03集';
    final dir = _freshWorkDir('resume_ok');
    final sep = Platform.pathSeparator;
    final out = File('${dir.path}${sep}$name.ts');

    // 第一轮：下到第 4 片就暂停（isPaused 在分片边界被问）
    var reached = 0;
    final p1 = await HlsDownloader.download(
      url: url(),
      intoDir: dir.path,
      fileName: name,
      onProgress: (d, t) => reached = d,
      isPaused: () => reached >= 4);
    final part = File('${dir.path}${sep}$name.ts.part');
    debugPrint('CR-24 第一轮 paused=' + p1.paused.toString() +
        ' 已下片=' + p1.segments.toString() + ' .part 存在=' + part.existsSync().toString() +
        ' 长度=' + (part.existsSync() ? part.lengthSync().toString() : '0'));
    expect(p1.paused, isTrue, reason: '前置：应该是暂停收尾');
    expect(p1.segments, 4, reason: '前置：应停在第 4 片边界');
    expect(part.existsSync(), isTrue, reason: '前置：.part 必须保留');
    expect(part.lengthSync(), 4 * kSegBytes);
    expect(out.existsSync(), isFalse, reason: '前置：还没下完，不该有成品');

    // 第二轮：从 initialDone = 4 续传
    final servedBefore = ups.served;
    final r = await HlsDownloader.download(
        url: url(), intoDir: dir.path, fileName: name, initialDone: p1.segments);
    debugPrint('CR-24 续传后 长度=' + (out.existsSync() ? out.lengthSync().toString() : '-1') +
        ' 期望=' + kFullBytes.toString() +
        ' 续传新增拉片=' + (ups.served - servedBefore).toString());
    expect(r.paused, isFalse);
    expect(out.existsSync(), isTrue, reason: '续传完应有成品');
    expect(out.lengthSync(), kFullBytes, reason: '★ 续传成品必须正好是 12 片之和');
    expect(ups.served - servedBefore, kSegCount - p1.segments,
        reason: '★ 续传只补剩下的片，不能重下已落盘的片');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
