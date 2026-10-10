import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 测试用的回环 HTTP 源站。
///
/// 为什么用真服务器而不是 mock HTTP：dart:io 3.x 里 [HttpClient] /
/// [HttpClientRequest] / [HttpClientResponse] 都是 interface class
/// （final class + 内部接口），测试里 implements 会直接编译失败。
///
/// 为什么绑 ::1 而不是 127.0.0.1：[client.dart] 里 `findProxy` 回调会对
/// host 做 `== '127.0.0.1' || == 'localhost'` 的短路，绑 ::1 才能让
/// 代理/镜像逻辑真的被走到；而且同一个 ::1 地址既能当源站也能被直连命中。
class TestOrigin {
  TestOrigin._(this.server, this._bodies);

  final HttpServer server;
  final Map<String, List<int>> _bodies;

  /// 按 path 记下所有收到的请求（`/pkg` 这种，不含 query）。
  final List<String> hits = [];

  /// 端口**必须在 close 之前读**：server 关掉后 dart:io 的 `HttpServer.port`
  /// 会抛 `HttpServer is not bound to a socket`。
  int get port => server.port;

  /// 形如 `http://[::1]:<port>` 的基址。
  String get base => 'http://[' + InternetAddress.loopbackIPv6.address + ']:' + port.toString();

  static Future<TestOrigin> start(Map<String, List<int>> bodies) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv6, 0);
    final o = TestOrigin._(s, Map<String, List<int>>.from(bodies));
    s.listen((req) async {
      o.hits.add(req.uri.path);
      final body = o._bodies[req.uri.path];
      final r = req.response;
      if (body == null) {
        r.statusCode = 404;
        r.headers.contentType = ContentType.binary;
        final e = utf8.encode('no route: ' + req.uri.path);
        r.headers.contentLength = e.length;
        r.add(e);
        await r.close();
        return;
      }
      r.statusCode = 200;
      r.headers.contentType = ContentType.binary;
      r.headers.contentLength = body.length;
      r.add(body);
      await r.close();
    });
    return o;
  }

  /// 换掉某个 path 的应答（同一端口上扮演两个源：可信源 / 被控镜像）。
  void serve(String path, List<int> body) => _bodies[path] = body;

  Future<void> stop() async {
    try {
      await server.close(force: true);
    } catch (_) {}
  }
}
