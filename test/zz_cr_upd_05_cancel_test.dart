// CR-05 回归测试：cancelled() 的返回值被丢掉 => UpdateCancelled 永远不会抛。
//
// 契约（lib/core/app_update/client.dart 的 download）：
//   1) 写每个 chunk 之前调用一次 cancelled()；
//   2) cancelled() 返回 true 表示「用户已取消」=> 必须抛 UpdateCancelled；
//   3) cancelled() 返回 false 表示「继续」=> 不得抛，文件完整落盘；
//   4) 取消后不留半截文件（.part 被删掉）。
//
// 判据：第 1 次回调就返回 true。缺陷代码把返回值直接 await 掉，
// 于是下载一路写完、返回 dest，**一个异常都不抛**，控制器的
// 「已取消下载」分支永远进不去，用户看到的是别的错或什么都不看到。
//
// ⚠️ 这条测试在缺陷代码上编译就失败，因为 download 的 cancelled 形参
//    被声明成 Future<void> Function()?，无法表达「取消」这个信号 ——
//    编译错误本身就是缺陷的直接证据（见报告 RED 段）。
//
// 不访问外网：被下载源是本机 loopback HttpServer。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_update/client.dart';
import 'package:sourin_spike/core/app_update/route.dart';

const String _host = '127.0.0.1';

/// 起一个 loopback 服务器，分 [chunks] 块返回 [body]，块间留出可取消的窗口。
Future<HttpServer> _serveBytes(List<int> body, {int chunks = 4}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final per = body.length ~/ chunks;
  server.listen((req) async {
    req.response.headers.contentType = ContentType.binary;
    req.response.contentLength = body.length;
    var sent = 0;
    for (var i = 0; i < chunks; i++) {
      final end = (i == chunks - 1) ? body.length : (i + 1) * per;
      req.response.add(body.sublist(sent, end));
      await req.response.flush();
      sent = end;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await req.response.close();
  });
  return server;
}

void main() {
  test('CR-05 cancelled() 返回 true 时必须抛 UpdateCancelled 且不落盘', () async {
    final payload = List<int>.generate(64 * 1024, (i) => i % 251);
    final server = await _serveBytes(payload, chunks: 6);
    final dir = await Directory.systemTemp.createTemp('zz_cr_upd_05_');
    final dest = File(dir.path + '/pkg.bin');
    final part = File(dir.path + '/pkg.bin.part');

    var calls = 0;
    Object? caught;
    try {
      await UpdateHttp(const UpdateRouteConfig()).download(
        Uri.parse('http://' + _host + ':' + server.port.toString() + '/pkg.bin'),
        dest,
        cancelled: () async {
          calls++;
          return true;
        },
      );
    } catch (e) {
      caught = e;
    }
    await server.close(force: true);
    final destLeft = dest.existsSync();
    final partLeft = part.existsSync();
    await dir.delete(recursive: true);

    // ignore: avoid_print
    print('[CR-05] cancelled() 调用 ' + calls.toString()
        + ' 次, 抛出类型=' + caught.runtimeType.toString()
        + ', dest 残留=' + destLeft.toString()
        + ', .part 残留=' + partLeft.toString());

    expect(calls, greaterThan(0), reason: 'cancelled() 一次都没被调用，取消检查形同虚设');
    expect(caught, isA<UpdateCancelled>(),
        reason: 'cancelled() 返回 true 却没抛 UpdateCancelled，实际抛了 ' + caught.toString());
    expect(destLeft, isFalse, reason: '取消后不能把半截包当成下载完成');
    expect(partLeft, isFalse, reason: '取消后必须删掉 .part');
  });

  test('CR-05 cancelled() 返回 false 时下载必须正常完成（防矫枉过正）', () async {
    final payload = List<int>.generate(32 * 1024, (i) => i % 97);
    final server = await _serveBytes(payload, chunks: 5);
    final dir = await Directory.systemTemp.createTemp('zz_cr_upd_05b_');
    final dest = File(dir.path + '/pkg.bin');

    var calls = 0;
    await UpdateHttp(const UpdateRouteConfig()).download(
      Uri.parse('http://' + _host + ':' + server.port.toString() + '/pkg.bin'),
      dest,
      cancelled: () async {
        calls++;
        return false;
      },
    );
    await server.close(force: true);

    expect(calls, greaterThan(0), reason: 'cancelled() 一次都没被调用，取消检查形同虚设');
    expect(dest.existsSync(), isTrue);
    expect(dest.lengthSync(), payload.length);
    await dir.delete(recursive: true);
  });
}
