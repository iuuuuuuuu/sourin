// CR-06 回归测试：代理模式下 download 不传 proxyPort（发往 PROXY host:0）、
// 头部注释承诺的「代理失败回退直连」没实现、_open() 的 HttpClient 从不 close。
//
// 三条独立断言：
//   A 代理端口真的被用上 —— 假代理收到的是绝对形式的请求行；
//   B 代理不可用时自动回退直连 —— 文件照样完整落盘；
//   C 每个 HttpClient 用完都被关闭 —— keep-alive 连接数 == 已结束连接数。
//
// 全部走 loopback，不访问外网。A/B 用 IPv6 回环 ::1 当「远端」：dart:io 的
// findProxy 回调拿到的 host 是 ::1，不等于 127.0.0.1/localhost，所以代码里
// 那个 local?DIRECT 的短路判断不会生效，代理真的会被用到。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_update/client.dart';
import 'package:sourin_spike/core/app_update/route.dart';

List<int> _payload(int n) => List<int>.generate(n, (i) => i % 251);

typedef _Responder = Future<void> Function(
    String head, Socket socket, void Function(List<int>) send);

class _Raw {
  _Raw(this.server);
  final ServerSocket server;
  int accepted = 0;
  int finished = 0;
  final List<String> requestLines = <String>[];
  int get port => server.port;
  Future<void> shutdown() => server.close();
}

/// 起一个原始 TCP 服务器，按 HTTP/1.1 应答；不发 Connection: close，
/// 所以连接会一直挂着，直到**客户端主动关闭**（这正是 CR-06 的探测点）。
Future<_Raw> _startRaw(_Responder responder) async {
  final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final r = _Raw(sock);
  sock.listen((Socket socket) async {
    r.accepted++;
    var buf = '';
    try {
      await for (final chunk in socket) {
        buf += utf8.decode(chunk, allowMalformed: true);
        var idx = buf.indexOf('\r\n\r\n');
        while (idx >= 0) {
          final head = buf.substring(0, idx);
          buf = buf.substring(idx + 4);
          r.requestLines.add(head.split('\r\n').first);
          await responder(head, socket, socket.add);
          await socket.flush();
          idx = buf.indexOf('\r\n\r\n');
        }
      }
    } catch (_) {
      // 对端掐断连接是本测试的正常结局，不算失败
    }
    r.finished++;
  });
  return r;
}

Future<void> _serveBytes(List<int> body, String status, Socket socket,
    void Function(List<int>) send) async {
  send(<int>[
    ...utf8.encode(status
        + 'Content-Type: application/octet-stream\r\n'
        'Content-Length: ' + body.length.toString() + '\r\n\r\n'),
    ...body,
  ]);
}

void main() {
  test('CR-06A 代理端口必须真的用上（缺陷码发往 PROXY host:0，必然失败）', () async {
    final body = _payload(16 * 1024);
    final proxy = await _startRaw((h, s, send) =>
        _serveBytes(body, 'HTTP/1.1 200 OK\r\n', s, send));
    final dir = await Directory.systemTemp.createTemp('zz_cr_upd_06a_');
    final dest = File(dir.path + '/pkg.bin');

    Object? caught;
    try {
      await UpdateHttp(UpdateRouteConfig(
        route: UpdateRoute.proxy,
        proxyHost: '127.0.0.1',
        proxyPort: proxy.port,
      )).download(Uri.parse('http://[::1]:1/pkg.bin'), dest);
    } catch (e) {
      caught = e;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final lines = List<String>.from(proxy.requestLines);
    await proxy.shutdown();

    // ignore: avoid_print
    print('[CR-06A] 代理收到的请求行=' + lines.toString()
        + '\n         抛出=' + caught.toString()
        + '\n         dest 落盘=' + dest.existsSync().toString()
        + ', 大小=' + (dest.existsSync() ? dest.lengthSync() : -1).toString());

    expect(lines, isNotEmpty,
        reason: '假代理一个请求都没收到 —— 请求根本没走代理：' + caught.toString());
    expect(lines.first, 'GET http://[::1]:1/pkg.bin HTTP/1.1',
        reason: '经代理时请求行必须是绝对形式');
    expect(caught, isNull, reason: '代理可用时不该失败，实际：' + caught.toString());
    expect(dest.existsSync(), isTrue, reason: '代理可用时文件应落盘');
    expect(dest.lengthSync(), body.length);
    await dir.delete(recursive: true);
  });

  test('CR-06B 代理不可用必须自动回退直连（头部注释承诺的行为）', () async {
    final body = _payload(12 * 1024);
    // 源站：IPv6 回环，findProxy 回调拿到 ::1，绕不开代理判断。
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv6, 0);
    final originUrl = 'http://[::1]:' + origin.port.toString() + '/pkg.bin';
    origin.listen((req) async {
      req.response.headers.contentType = ContentType.binary;
      req.response.contentLength = body.length;
      req.response.add(body);
      await req.response.close();
    });
    // 假代理：接了连接立刻掐断（等价于代理进程崩了）。
    final dead = await _startRaw((h, s, send) async { s.destroy(); });

    final dir = await Directory.systemTemp.createTemp('zz_cr_upd_06b_');
    final dest = File(dir.path + '/pkg.bin');
    Object? caught;
    try {
      await UpdateHttp(UpdateRouteConfig(
        route: UpdateRoute.proxy,
        proxyHost: '127.0.0.1',
        proxyPort: dead.port,
      )).download(Uri.parse(originUrl), dest);
    } catch (e) {
      caught = e;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final proxyHits = dead.accepted;
    await dead.shutdown();
    await origin.close(force: true);

    // ignore: avoid_print
    print('[CR-06B] 代理被尝试=' + proxyHits.toString()
        + ', 抛出=' + caught.toString()
        + ', dest 落盘=' + dest.existsSync().toString()
        + ', 大小=' + (dest.existsSync() ? dest.lengthSync() : -1).toString());

    expect(proxyHits, greaterThan(0), reason: '必须先试代理');
    expect(caught, isNull,
        reason: '代理挂了应回退直连，而不是把异常抛给用户：' + caught.toString());
    expect(dest.existsSync(), isTrue, reason: '回退直连后文件应完整落盘');
    expect(dest.lengthSync(), body.length);
    await dir.delete(recursive: true);
  });

  test('CR-06C 每个 HttpClient 用完必须 close（否则每次请求泄漏一个连接）', () async {
    // 纯 ASCII：getText 会把 body 当 UTF-8 解码。
    final body = utf8.encode('sourin-' + 'x' * 4095);
    final srv = await _startRaw((h, s, send) =>
        _serveBytes(body, 'HTTP/1.1 200 OK\r\n', s, send));
    final url = Uri.parse('http://127.0.0.1:' + srv.port.toString() + '/pkg.bin');
    final dir = await Directory.systemTemp.createTemp('zz_cr_upd_06c_');
    final http = UpdateHttp(const UpdateRouteConfig());
    final t1 = await http.getText(url);
    final t2 = await http.getText(url);
    await http.download(url, File(dir.path + '/pkg.bin'));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final accepted = srv.accepted;
    final finished = srv.finished;
    await srv.shutdown();

    // ignore: avoid_print
    print('[CR-06C] 服务端 accept=' + accepted.toString()
        + ', 客户端已结束连接=' + finished.toString()
        + ', 文本长度=' + t1.length.toString() + '/' + t2.length.toString());

    expect(accepted, greaterThan(0));
    expect(finished, accepted,
        reason: '有 ' + accepted.toString()
        + ' 个 keep-alive 连接没被客户端关闭 —— HttpClient 泄漏');
    await dir.delete(recursive: true);
  });
}