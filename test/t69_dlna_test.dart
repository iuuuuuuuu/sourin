// ═══════════════════════════════════════════════════════════════════════
//  task-27 ② 安卓投屏 DLNA/UPnP —— 纯 Dart 单测
// ═══════════════════════════════════════════════════════════════════════
//
// 这条测试**不依赖真实网络**：
// ```text
//   · SSDP 部分只做报文构造/解析（不真的发组播）
//   · SOAP / 代理部分全部打本机 127.0.0.1 上的假 renderer
// ```
//
// # 为什么要用「假 renderer」而不是真电视
//
// ```text
// 1. CI/本机不一定有电视；有电视也不能保证每次跑都在线。
// 2. 投屏最容易出错的地方是**协议细节**（SOAPAction 的引号、
//    CurrentURI 的 XML 转义、controlURL 的相对路径），
//    这些用假 renderer 才能断言到字节级。
// 3. ★ 防盗链只有「真收到请求」才能证明：假 renderer 去拉
//    App 起的代理地址，代理再打上游，上游记下 Referer —— 一条真链路。
// ```
//
// ⚠️ 铁律：所有监听都用端口 0（系统分配）+ 只绑回环，跑完立刻 close，
//    否则并发跑测试时会撞端口（本项目踩过）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/dlna/cast_manager.dart';
import 'package:sourin_spike/core/dlna/description.dart';
import 'package:sourin_spike/core/dlna/dlna_http.dart';
import 'package:sourin_spike/core/dlna/referer_proxy.dart';
import 'package:sourin_spike/core/dlna/soap.dart';
import 'package:sourin_spike/core/dlna/ssdp.dart';

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 为什么需要这个 HttpOverrides（实测踩坑，不是可选项）
// ═══════════════════════════════════════════════════════════════════════
//
// flutter_test 的 TestWidgetsFlutterBinding 默认把 **全局 HttpClient**
// 换成一个 mock（flutter_test/lib/src/_binding_io.dart 的 _MockHttpOverrides），
// 它的行为是：**所有** 请求都回 HTTP 400 且**一个字节都不发出去**，
// 并在失败时打印一句 Warning。
//
// 后果（本次实测）：① 代理转发拿不到 200；② 假 renderer 拉描述拿到 400；
// ⇒ 所有「真 HTTP」的断言全红，而**代码本身是对的**。
//
// 我们这条测试的全部价值就在「真 HTTP 打本机假 renderer」——
// 所以必须把真 HttpClient 还给被测量的代码。
//
// ⚠️ 只对本机地址放行（回环 + 本机自己的局域网 IPv4），其它 host 一律抛：
//   这样即使有人误加了真外网地址，测试也不会偷偷联网（不 flaky、不泄流量）。
class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner = super.createHttpClient(context);
    return _LoopbackOnlyHttpClient(inner);
  }
}

/// 把非本机请求挡掉（抛 SocketException），本机请求原样交给真 HttpClient。
class _LoopbackOnlyHttpClient implements HttpClient {
  _LoopbackOnlyHttpClient(this._inner);

  final HttpClient _inner;

  /// 本机地址集合 = 回环 + **本机自己的局域网 IPv4**。
  ///
  /// 代理绑 anyIPv4 并把局域网地址投给电视（回环对另一台设备不可达），
  /// 所以放行名单必须跟上，否则端到端那条会被我们自己的守卫拦掉。
  /// 放行名单：回环 + 本机局域网地址。
  ///
  /// `init()` 在 main 里 await 一次（pickLanAddress 是 async，而 _guard 必须同步）。
  /// 拿不到局域网地址就只放行回环 —— 让失败发生在断言处，而不是守卫处。
  static Set<String> _localHosts = const <String>{'127.0.0.1', 'localhost', '::1'};

  static Future<void> init() async {
    try {
      final lan = await pickLanAddress();
      _localHosts = <String>{..._localHosts, lan};
    } on Object {
      // 保持只放行回环
    }
  }

  bool _isLoopback(Uri url) => _localHosts.contains(url.host);

  HttpClientRequest _guard(HttpClientRequest req) {
    if (_isLoopback(req.uri)) return req;
    throw SocketException(
      '测试不允许访问非本机地址：${req.uri}（t69 只打本机假 renderer；允许 ${_localHosts.join('、')}）',
    );
  }

  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;
  @override
  bool Function(X509Certificate cert, String host, int port)? badCertificateCallback;
  @override
  void Function(String line)? keyLog;
  @override
  String Function(Uri url)? findProxy;
  @override
  Future<ConnectionTask<Socket>> Function(Uri url, String? proxyHost, int? proxyPort)?
      connectionFactory;
  @override
  Future<bool> Function(Uri url, String scheme, String realm)? authenticate;
  @override
  Future<bool> Function(String host, int port, String scheme, String realm)? authenticateProxy;

  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) {}
  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) {}

  @override
  void close({bool force = false}) => _inner.close(force: force);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _guard(await _inner.openUrl(method, url));
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _guard(await _inner.getUrl(url));
  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _guard(await _inner.postUrl(url));
  @override
  Future<HttpClientRequest> putUrl(Uri url) async => _guard(await _inner.putUrl(url));
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) async => _guard(await _inner.deleteUrl(url));
  @override
  Future<HttpClientRequest> headUrl(Uri url) async => _guard(await _inner.headUrl(url));
  @override
  Future<HttpClientRequest> patchUrl(Uri url) async => _guard(await _inner.patchUrl(url));

  @override
  Future<HttpClientRequest> open(String method, String host, int port, String path) async =>
      _guard(await _inner.open(method, host, port, path));
  @override
  Future<HttpClientRequest> get(String host, int port, String path) async =>
      _guard(await _inner.get(host, port, path));
  @override
  Future<HttpClientRequest> post(String host, int port, String path) async =>
      _guard(await _inner.post(host, port, path));
  @override
  Future<HttpClientRequest> put(String host, int port, String path) async =>
      _guard(await _inner.put(host, port, path));
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) async =>
      _guard(await _inner.delete(host, port, path));
  @override
  Future<HttpClientRequest> head(String host, int port, String path) async =>
      _guard(await _inner.head(host, port, path));
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) async =>
      _guard(await _inner.patch(host, port, path));
}

// ═══════════════════════════════════════════════════════════════════════
//  假 renderer：一个能被投屏的最小 UPnP MediaRenderer（只有 HTTP 面）
// ═══════════════════════════════════════════════════════════════════════

/// 记录一次 SOAP 调用
class SoapHit {
  SoapHit(this.action, this.body);

  /// SOAPAction 头（原样，含引号）—— 断言引号是否还在
  final String action;

  /// 请求体原文 —— 断言 CurrentURI 转义、DIDL 是否带上
  final String body;

  /// 取某个元素里的文本（模拟 renderer 读参数的方式）
  String? arg(String tag) {
    final m = RegExp('<$tag(?:\\s[^>]*)?>(.*?)</$tag>', dotAll: true).firstMatch(body);
    return m == null ? null : _unesc(m.group(1)!);
  }

  static String _unesc(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

/// 最小假 renderer
///
/// 只实现投屏链路真正会走到的三个面：
/// ```text
///   GET  /desc.xml    设备描述（controlURL 故意写成**相对路径**，
///                     用来验证 resolveUrl 真的把它拼成了绝对地址）
///   POST /avt/ctrl    AVTransport 控制端点（记下每次调用的原文）
///   GET  /other      其它服务（证明我们不会把 SetAVTransportURI 发错地方）
/// ```
class FakeRenderer {
  HttpServer? _srv;

  /// 收到的全部 SOAP 调用（按顺序）
  final List<SoapHit> hits = <SoapHit>[];

  /// 打到「别的服务」上的请求数 —— 必须是 0
  int otherServiceHits = 0;

  /// 设备自报的名字
  String friendlyName = '客厅的假电视';

  /// 返回给 GetTransportInfo 的状态
  String transportState = 'PLAYING';

  /// 强制让 SetAVTransportURI 返回 UPnP 错误（测错误分支）
  int? forceErrorCode;

  int get port => _srv?.port ?? 0;

  String get location => 'http://127.0.0.1:$port/desc.xml';

  Future<void> start() async {
    _srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final req in _srv!) {
        try {
          await _route(req);
        } catch (_) {
          try {
            req.response.statusCode = 500;
            await req.response.close();
          } catch (_) {}
        }
      }
    }());
  }

  Future<void> stop() async {
    await _srv?.close(force: true);
    _srv = null;
  }

  Future<void> _route(HttpRequest req) async {
    final path = req.uri.path;
    if (path == '/desc.xml') {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
        ..write(descriptionXml);
      await req.response.close();
      return;
    }
    if (path == '/avt/ctrl') {
      final body = await utf8.decoder.bind(req).join();
      final action = req.headers.value('soapaction') ?? '<none>';
      final h = SoapHit(action, body);
      hits.add(h);
      final which = action.contains('#') ? action.split('#').last.replaceAll('"', '') : '';
      final err = forceErrorCode;
      if (err != null && which == 'SetAVTransportURI') {
        req.response
          ..statusCode = 500
          ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
          ..write('''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
<s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
<detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
<errorCode>$err</errorCode><errorDescription>Resource not found</errorDescription>
</UPnPError></detail></s:Fault></s:Body></s:Envelope>''');
        await req.response.close();
        return;
      }
      final payload = which == 'GetTransportInfo'
          ? '<CurrentTransportState>$transportState</CurrentTransportState>'
          : '';
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
        ..write('<?xml version="1.0"?>'
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
            '<s:Body><u:${which}Response xmlns:u="$kAvTransportService">'
            '$payload</u:${which}Response></s:Body></s:Envelope>');
      await req.response.close();
      return;
    }
    if (path == '/other') {
      otherServiceHits++;
      req.response.statusCode = 200;
      await req.response.close();
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  /// 设备描述 XML（刻意用相对 controlURL + 前面塞一个别的服务）
  String get descriptionXml => '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>$friendlyName</friendlyName>
    <manufacturer>Fake Inc.</manufacturer>
    <modelName>FakeRenderer-1</modelName>
    <UDN>uuid:11111111-2222-3333-4444-555555555555</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/other</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>avt/ctrl</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';
}

// ═══════════════════════════════════════════════════════════════════════
//  上游媒体服务器：记录收到的请求头（证明代理注入了 Referer）
// ═══════════════════════════════════════════════════════════════════════

class UpstreamMedia {
  UpstreamMedia({
    this.path = '/video.mp4',
    this.mimeType = 'video/mp4',
    List<int>? payload,
  }) : payload = payload ?? body;

  HttpServer? _srv;

  final List<Map<String, String>> hits = <Map<String, String>>[];

  /// 上游路径（用来构造 `.m3u8` / `.mp4` 等不同后缀的地址）
  final String path;

  /// 响应 content-type（`application/octet-stream` 用来测「没有类型时只看后缀」那一支）
  final String mimeType;

  /// 响应体（默认 [body]）
  final List<int> payload;

  int get port => _srv?.port ?? 0;

  String get url => 'http://127.0.0.1:$port$path';

  /// 假媒体字节（够断言 Range 生效）
  static final List<int> body = List<int>.generate(1024, (i) => i % 251);

  Future<void> start() async {
    _srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final req in _srv!) {
        hits.add(<String, String>{
          '__path': req.uri.hasQuery ? '${req.uri.path}?${req.uri.query}' : req.uri.path,
          '__referer': req.headers.value('referer') ?? '<none>',
          '__ua': req.headers.value('user-agent') ?? '<none>',
          '__range': req.headers.value('range') ?? '<none>',
          '__host': req.headers.value('host') ?? '<none>',
        });
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.parse(mimeType);
        req.response.add(payload);
        await req.response.close();
      }
    }());
  }

  Future<void> stop() async {
    await _srv?.close(force: true);
    _srv = null;
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  伪「核心层代理」（task-34）：模仿 rust/sourin_core/src/streamproxy.rs
// ═══════════════════════════════════════════════════════════════════════
//
// 关键特征（照抄核心层）：
//   ① 只监听 127.0.0.1（它自己就是「手机回环口上的代理」）；
//   ② 把 m3u8 里**每一行**子地址都改写成它自己的回环地址，形如
//      `http://127.0.0.1:<port>/p/<tok>/https/<host><path>`；
//   ③ 改写后 content-type 一定是 `application/vnd.apple.mpegurl`。
//
// 这三点合起来就是 R1 的成因：外层代理把这份**已经是回环地址**的清单
// 原样透传给电视 ⇒ 电视拿到的分片地址指向**电视自己的** 127.0.0.1 ⇒ 黑屏。
// 本类存在的唯一目的：在单测里复现这条链路（不联网、只打本机）。
class FakeCoreProxy {
  HttpServer? _srv;

  /// 收到的全部请求（按顺序）—— 断言「分片真的被转发回核心层」
  final List<Map<String, String>> hits = <Map<String, String>>[];

  /// 假分片字节（够断言「一字不差地透传」）
  static final List<int> segBytes = List<int>.generate(4096, (i) => (i * 31) % 256);

  int get port => _srv?.port ?? 0;

  String get origin => 'http://127.0.0.1:$port';

  /// 点播**主清单**（多码率）：里面指向子清单 ⇒ 用来验证「两级清单各改写一次」
  String get masterUrl => '$origin/p/TOK/https/cdn.example.com/live/master.m3u8';

  /// 主清单内容（子清单地址也是核心层的回环地址）
  String get master => '#EXTM3U\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=800000\n'
      '$origin/p/TOK/https/cdn.example.com/live/index.m3u8\n';

  /// 点播子清单：核心层给出的地址（**回环 + /p/<tok>/ 前缀**）
  String get indexUrl => '$origin/p/TOK/https/cdn.example.com/live/index.m3u8';

  /// 核心层改写过的 m3u8：子地址是**它自己的回环地址**（这就是 R1 的输入）
  String get playlist => '#EXTM3U\n'
      '#EXT-X-VERSION:3\n'
      '#EXT-X-TARGETDURATION:4\n'
      '#EXTINF:4.000,\n'
      '$origin/p/TOK/https/cdn.example.com/live/seg1.ts\n'
      '#EXT-X-ENDLIST\n';

  Future<void> start() async {
    _srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final req in _srv!) {
        hits.add(<String, String>{
          '__path': req.uri.hasQuery ? '${req.uri.path}?${req.uri.query}' : req.uri.path,
          '__referer': req.headers.value('referer') ?? '<none>',
          '__ua': req.headers.value('user-agent') ?? '<none>',
        });
        if (req.uri.path.endsWith('master.m3u8')) {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..write(master);
        } else if (req.uri.path.endsWith('.m3u8')) {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..write(playlist);
        } else if (req.uri.path.endsWith('.ts')) {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType('video', 'mp2t')
            ..add(segBytes);
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      }
    }());
  }

  Future<void> stop() async {
    await _srv?.close(force: true);
    _srv = null;
  }
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ★★★ 把真 HttpClient 装回去（理由见文件头 _RealHttpOverrides 注释）
  //
  // 实测教训：`HttpOverrides.runZoned(...)` **不管用** ——
  // package:test 的用例体是在**它自己新建的 zone** 里跑的，
  // 那个 zone 的父级是 runner 的 zone，**不是** main 里这个 zone，
  // 所以 zone 级覆盖传不进用例体（现象：用例里拿到的仍是 mock 的 400）。
  // ⇒ 只能改 **global**（HttpOverrides.current 是「先查 zone 值，再退到 global」）。
  HttpOverrides.global = _RealHttpOverrides();
  // 代理绑 anyIPv4 并把**局域网地址**投给电视，所以放行名单要把本机局域网地址也算进去
  await _LoopbackOnlyHttpClient.init();
  _declareTests();
}

/// 真正的测试声明。
void _declareTests() {
  // 每个用例前再兜一次（flutter_test 里任何一处 ensureInitialized 都会重装 mock）
  setUp(() => HttpOverrides.global = _RealHttpOverrides());

  // ═════════════════════════════════════════════════════════════════════
  //  ① SSDP 报文
  // ═════════════════════════════════════════════════════════════════════

  group('SSDP 报文', () {
    test('M-SEARCH 是合法报文：CRLF 行尾 + MAN 带引号 + MX 钳在 1..5', () {
      final raw = SsdpMessage.buildSearch(st: kMediaRendererSt, mx: 2);
      final text = utf8.decode(raw);
      expect(text.startsWith('M-SEARCH * HTTP/1.1\r\n'), isTrue);
      expect(text.endsWith('\r\n\r\n'), isTrue);
      // ★ 协议要求 MAN 的值**带双引号**，写错设备会直接不理你
      expect(text.contains('MAN: "ssdp:discover"\r\n'), isTrue);
      expect(text.contains('HOST: 239.255.255.250:1900\r\n'), isTrue);
      expect(text.contains('MX: 2\r\n'), isTrue);
      expect(text.contains('ST: $kMediaRendererSt\r\n'), isTrue);
      // 没有 LF-only 的裸行
      expect(RegExp('(?<!\\r)\\n').hasMatch(text), isFalse);

      expect(utf8.decode(SsdpMessage.buildSearch(mx: 99)).contains('MX: 5\r\n'), isTrue);
      expect(utf8.decode(SsdpMessage.buildSearch(mx: 0)).contains('MX: 1\r\n'), isTrue);
    });

    test('解析 200 OK：LOCATION 取到、键统一大写、ST/USN/SERVER 可读', () {
      const raw = 'HTTP/1.1 200 OK\r\n'
          'Cache-Control: max-age=1800\r\n'
          'Location: http://192.168.1.7:49152/description.xml\r\n'
          'Server: Linux/3.18 UPnP/1.0 Android/9 FakeTV/1.0\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'USN: uuid:abc::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          '\r\n';
      final r = SsdpResponse.parse(raw, source: '192.168.1.7');
      expect(r, isNotNull);
      expect(r!.location, 'http://192.168.1.7:49152/description.xml');
      expect(r.headers['LOCATION'], isNotNull);
      expect(r.st, 'urn:schemas-upnp-org:device:MediaRenderer:1');
      expect(r.usn, startsWith('uuid:abc'));
      expect(r.server, contains('FakeTV'));
      expect(r.source, '192.168.1.7');
    });

    test('★ 没有 LOCATION 的回包一律丢弃（返回 null，不抛异常）', () {
      // 这是本项目「没有的能力不假装有」的协议层版本：
      // 拿不到 LOCATION 就一步都做不了，假装成设备只会让后面全是假成功。
      expect(SsdpResponse.parse('HTTP/1.1 200 OK\r\nST: ssdp:all\r\n\r\n'), isNull);
      // 别的协议的广播（首行不是 HTTP/1.1 / NOTIFY）
      expect(SsdpResponse.parse('M-SEARCH * HTTP/1.1\r\nLOCATION: x\r\n\r\n'), isNull);
      expect(SsdpResponse.parse(''), isNull);
      expect(SsdpResponse.parse('   \n\n'), isNull);
    });

    test('容忍 LF-only 行尾（实测有设备这么发）', () {
      const raw = 'HTTP/1.1 200 OK\n'
          'LOCATION: http://10.0.0.9:1234/d.xml\n'
          'ST: ssdp:all\n\n';
      final r = SsdpResponse.parse(raw);
      expect(r, isNotNull);
      expect(r!.location, 'http://10.0.0.9:1234/d.xml');
    });

    test('去重键优先 USN，退化到 LOCATION（同一台设备只出现一次）', () {
      const a = 'HTTP/1.1 200 OK\r\nLOCATION: http://1.1.1.1/d.xml\r\n'
          'USN: uuid:same\r\nST: ssdp:all\r\n\r\n';
      const b = 'HTTP/1.1 200 OK\r\nLOCATION: http://1.1.1.1/other.xml\r\n'
          'USN: uuid:same\r\nST: ssdp:all\r\n\r\n';
      expect(SsdpResponse.parse(a)!.dedupeKey, SsdpResponse.parse(b)!.dedupeKey);
      const c = 'HTTP/1.1 200 OK\r\nLOCATION: http://2.2.2.2/d.xml\r\n\r\n';
      const d = 'HTTP/1.1 200 OK\r\nLOCATION: http://2.2.2.2/d.xml\r\n\r\n';
      expect(SsdpResponse.parse(c)!.dedupeKey, SsdpResponse.parse(d)!.dedupeKey);
      expect(SsdpResponse.parse(a)!.dedupeKey, isNot(SsdpResponse.parse(c)!.dedupeKey));
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ② 设备描述解析
  // ═════════════════════════════════════════════════════════════════════

  group('设备描述解析', () {
    const xml = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>客厅 &amp; 卧室的电视</friendlyName>
    <manufacturer>Some Vendor</manufacturer>
    <modelName>X1</modelName>
    <UDN>uuid:aaaa-bbbb</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>/cm/ctrl</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/upnp/control/AVTransport</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

    test('挑出 AVTransport 的 controlURL，并解掉 XML 实体', () {
      final d = parseDescription(xml, 'http://192.168.1.7:49152/desc.xml');
      expect(d, isNotNull);
      expect(d!.friendlyName, '客厅 & 卧室的电视');
      expect(d.avTransportControlUrl, 'http://192.168.1.7:49152/upnp/control/AVTransport');
      expect(d.canCast, isTrue);
      expect(d.serviceTypes.length, 2);
      expect(d.displayName, contains('X1'));
      // ★ 不能把 SetAVTransportURI 发到 ConnectionManager 上
      expect(d.avTransportControlUrl, isNot(contains('/cm/ctrl')));
    });

    test('★ controlURL 是相对路径时必须拼成绝对地址（三种形式都要对）', () {
      String pick(String ctl) => parseDescription(
            '<root><device><friendlyName>F</friendlyName><serviceList><service>'
            '<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
            '<controlURL>$ctl</controlURL>'
            '</service></serviceList></device></root>',
            'http://10.0.0.5:1234/a/b/desc.xml',
          )!
          .avTransportControlUrl!;

      // 根相对
      expect(pick('/upnp/ctrl'), 'http://10.0.0.5:1234/upnp/ctrl');
      // 文档相对（UPnP 规范里相对**文档**，不是相对目录）
      expect(pick('ctrl'), 'http://10.0.0.5:1234/a/b/ctrl');
      // 已经是绝对地址则原样保留
      expect(pick('http://10.0.0.9:9/x'), 'http://10.0.0.9:9/x');
    });

    test('★ 没有 AVTransport 的设备：canCast=false 且理由说人话（不许假装能投）', () {
      final d = parseDescription(
        '<root><device><friendlyName>路由器</friendlyName><serviceList><service>'
        '<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>'
        '<controlURL>/wan</controlURL></service></serviceList></device></root>',
        'http://192.168.1.1/d.xml',
      )!;
      expect(d.canCast, isFalse);
      final dev = CastDevice(location: 'http://192.168.1.1/d.xml', host: '192.168.1.1', description: d);
      expect(dev.why, contains('不支持 AVTransport'));
      expect(dev.why, isNot(contains('没有拿到设备信息')));
    });

    test('拿不到描述时名字退回 IP（不编一个假名字）', () {
      final dev = CastDevice(location: 'http://1.2.3.4/d.xml', host: '1.2.3.4', error: '连不上');
      expect(dev.name, '1.2.3.4');
      expect(dev.canCast, isFalse);
      expect(dev.why, '连不上');
    });

    test('不是 UPnP 文档时返回 null（不抛异常）', () {
      expect(parseDescription('<html><body>hello</body></html>', 'http://x/d'), isNull);
      expect(parseDescription('', 'http://x/d'), isNull);
    });

    test('子设备不会串到父设备（只取第一个 device 段）', () {
      final d = parseDescription(
        '<root><device><friendlyName>父</friendlyName><serviceList><service>'
        '<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
        '<controlURL>/p</controlURL></service></serviceList>'
        '<deviceList><device><friendlyName>子</friendlyName></device></deviceList>'
        '</device></root>',
        'http://h/d',
      )!;
      expect(d.friendlyName, '父');
      expect(d.avTransportControlUrl, 'http://h/p');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ③ SOAP 报文
  // ═════════════════════════════════════════════════════════════════════

  group('SOAP 报文', () {
    test('信封结构正确：s:Envelope/s:Body/u:Action + xmlns:u', () {
      final b = buildEnvelope('Play', args: {'InstanceID': '0', 'Speed': '1'});
      expect(b, contains('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'));
      expect(b, contains('<u:Play xmlns:u="$kAvTransportService">'));
      expect(b, contains('<InstanceID>0</InstanceID>'));
      expect(b, contains('<Speed>1</Speed>'));
      expect(b, endsWith('</u:Play></s:Body></s:Envelope>'));
    });

    test('★ SOAPAction 头必须带双引号（去掉设备就回 400/500）', () {
      expect(soapActionHeader('Play'), '"$kAvTransportService#Play"');
      expect(soapActionHeader('Play').startsWith('"'), isTrue);
      expect(soapActionHeader('Play').endsWith('"'), isTrue);
    });

    test('★ CurrentURI 里的 & 必须转义（不转义设备回 Invalid Args）', () {
      final b = buildEnvelope('SetAVTransportURI', args: {
        'InstanceID': '0',
        'CurrentURI': 'http://h/v.mp4?a=1&b=2<x>',
      });
      expect(b, contains('&amp;'), reason: '& 没转义');
      expect(b, contains('&lt;x&gt;'), reason: '尖括号没转义');
      // 原始未转义的形态一个都不能出现
      expect(b.contains('a=1&b=2'), isFalse);
    });

    test('DIDL-Lite 元数据带上标题与协议信息', () {
      final d = buildDidlLite('http://h/v.mp4', title: '第 3 集');
      expect(d, contains('<dc:title>第 3 集</dc:title>'));
      expect(d, contains('object.item.videoItem'));
      expect(d, contains('protocolInfo='));
      expect(d, contains('http://h/v.mp4'));
    });

    test('★ 成败判据是 body 不是 HTTP 状态码（500 + Fault 才是失败）', () {
      const fault = '<s:Envelope><s:Body><s:Fault>'
          '<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>'
          '<detail><UPnPError><errorCode>716</errorCode>'
          '<errorDescription>Resource not found</errorDescription>'
          '</UPnPError></detail></s:Fault></s:Body></s:Envelope>';
      final r = parseSoapResponse(fault, statusCode: 500);
      expect(r.ok, isFalse);
      expect(r.isFault, isTrue);
      expect(r.errorCode, 716);
      expect(r.message, contains('打不开这个地址'));

      // 200 但带 Fault ⇒ 仍然是失败（有些设备这么干）
      expect(parseSoapResponse(fault, statusCode: 200).ok, isFalse);

      // 500 但**没有** Fault ⇒ 不是 SOAP 失败（别乱报错）
      expect(parseSoapResponse('<x/>', statusCode: 500).ok, isFalse);
      expect(parseSoapResponse('<x/>', statusCode: 500).isFault, isFalse);

      final okr = parseSoapResponse(
          '<s:Envelope><s:Body><u:GetTransportInfoResponse>'
          '<CurrentTransportState>PLAYING</CurrentTransportState>'
          '</u:GetTransportInfoResponse></s:Body></s:Envelope>',
          statusCode: 200);
      expect(okr.ok, isTrue);
    });

    test('错误码表：常见码有中文解释，未知码返回 null（不编）', () {
      expect(upnpErrorText(716), contains('打不开这个地址'));
      expect(upnpErrorText(701), contains('状态不允许'));
      expect(upnpErrorText(714), isNotNull);
      expect(upnpErrorText(999999), isNull);
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ④ 防盗链代理（★ 本任务的核心风险点）
  // ═════════════════════════════════════════════════════════════════════

  group('防盗链代理', () {
    test('★ 注入 Referer/UA：上游收到的头证明防盗链真的被解决了', () async {
      final up = UpstreamMedia();
      await up.start();
      final proxy = MediaProxy();
      try {
        final proxyUrl = await proxy.register(up.url, headers: {
          'Referer': 'https://www.bilibili.com/',
          'User-Agent': 'Mozilla/5.0 (Test) SourinSpike/1.0',
        }, label: '第 3 集');

        // ★★ 投给电视的主机名必须是**本机局域网地址**，不能是 127.0.0.1：
        //    回环对另一台设备不可达（电视拿它去拉就是拉它自己 ⇒ UPnP 716）。
        final lan = await pickLanAddress();
        expect(proxyUrl.startsWith('http://$lan:'), isTrue,
            reason: '给电视的地址是 $proxyUrl，但本机局域网地址是 $lan');
        expect(proxyUrl.contains('127.0.0.1'), isFalse,
            reason: '回环地址电视拉不到');
        expect(proxy.isRunning, isTrue);

        final client = HttpClient();
        final req = await client.getUrl(Uri.parse(proxyUrl));
        final res = await req.close();
        final got = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        client.close();

        expect(res.statusCode, 200);
        expect(got.length, UpstreamMedia.body.length);
        expect(up.hits.length, 1);
        // ★★ 这两行就是「防盗链解决了」的证据
        expect(up.hits.first['__referer'], 'https://www.bilibili.com/');
        expect(up.hits.first['__ua'], 'Mozilla/5.0 (Test) SourinSpike/1.0');
        // Host 必须是上游的，不能是代理自己
        expect(up.hits.first['__host'], contains('127.0.0.1:${up.port}'));
      } finally {
        await proxy.stop();
        await up.stop();
      }
    });

    test('★ 透传 Range（不透传电视拖进度条会跳回开头）', () async {
      final up = UpstreamMedia();
      await up.start();
      final proxy = MediaProxy();
      try {
        final proxyUrl = await proxy.register(up.url);
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse(proxyUrl));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=100-199');
        final res = await req.close();
        await res.drain<void>();
        client.close();

        expect(up.hits.length, 1);
        expect(up.hits.first['__range'], 'bytes=100-199');
      } finally {
        await proxy.stop();
        await up.stop();
      }
    });

    test('★ 没登记/已撤销的 token 回 410 并说明原因（不假装 200）', () async {
      final proxy = MediaProxy();
      try {
        await proxy.start();
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:${proxy.port}/m/nosuchtoken'));
        final res = await req.close();
        final body = await utf8.decoder.bind(res).join();
        client.close();
        expect(res.statusCode, 410);
        expect(body, contains('已失效'));
      } finally {
        await proxy.stop();
      }
    });

    test('只接受 http/https（本地文件路径不能投）', () async {
      final proxy = MediaProxy();
      try {
        await expectLater(
          proxy.register('file:///C:/secret.mp4'),
          throwsA(isA<DlnaException>()),
        );
        await expectLater(proxy.register('magnet:?xt=urn:btih:x'), throwsA(isA<DlnaException>()));
      } finally {
        await proxy.stop();
      }
    });

    test('/ping 健康检查可用（真机取证时用它确认代理活着）', () async {
      final proxy = MediaProxy();
      try {
        await proxy.start();
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:${proxy.port}/ping'));
        final res = await req.close();
        final body = await utf8.decoder.bind(res).join();
        client.close();
        expect(res.statusCode, 200);
        expect(body, contains('ok'));
      } finally {
        await proxy.stop();
      }
    });

    test('stop() 之后 token 全失效、端口释放（避免换集时旧地址还能拉）', () async {
      final proxy = MediaProxy();
      final up = UpstreamMedia();
      await up.start();
      final u = await proxy.register(up.url);
      expect(proxy.entryFor(u), isNotNull);
      final port = proxy.port;
      await proxy.stop();
      expect(proxy.isRunning, isFalse);
      expect(proxy.entryFor(u), isNull);
      // 端口真的放开了：能重新 bind 同一个端口
      final again = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      await again.close(force: true);
      await up.stop();
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ⑤ 端到端：真 HTTP 打假 renderer（SSDP 部分用真实解析过的回包喂进去）
  // ═════════════════════════════════════════════════════════════════════

  group('端到端（假 renderer）', () {
    test('★ 发现 → 下发 → 播放：SetAVTransportURI 收到的是**代理地址**且 renderer 能拉到流', () async {
      final renderer = FakeRenderer();
      final up = UpstreamMedia();
      await renderer.start();
      await up.start();
      final proxy = MediaProxy();
      final manager = CastManager(proxy: proxy);
      try {
        // ── 1. 把假 renderer 的 SSDP 回包喂给真实解析器 ──
        final raw = 'HTTP/1.1 200 OK\r\n'
            'LOCATION: ${renderer.location}\r\n'
            'ST: $kMediaRendererSt\r\n'
            'USN: uuid:fake::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
            'SERVER: FakeOS/1.0 UPnP/1.1 FakeTV/1.0\r\n\r\n';
        final parsed = SsdpResponse.parse(raw, source: '127.0.0.1');
        expect(parsed, isNotNull);

        // ── 2. 拉描述（真 HTTP）──
        final desc = await fetchDescription(parsed!.location!);
        expect(desc.friendlyName, '客厅的假电视');
        // ★ controlURL 在 XML 里是相对的 `avt/ctrl`，这里必须是绝对地址
        expect(desc.avTransportControlUrl, 'http://127.0.0.1:${renderer.port}/avt/ctrl');

        final dev = CastDevice(
          location: parsed.location!,
          host: '127.0.0.1',
          description: desc,
          usn: parsed.usn,
          server: parsed.server,
        );
        expect(dev.canCast, isTrue);

        // ── 3. 投屏（带防盗链头）──
        final s = await manager.cast(
          dev,
          up.url,
          headers: {'Referer': 'https://www.bilibili.com/'},
          title: '第 3 集',
        );
        expect(s.phase, CastPhase.playing, reason: s.error ?? '');
        expect(s.transportState, 'PLAYING');
        // 给电视的是本机局域网地址（回环不可达）
        expect(s.proxyUrl, startsWith('http://${await pickLanAddress()}:'));

        // ── 4. renderer 收到的到底是什么 ──
        final actions = renderer.hits
            .map((h) => h.action.replaceAll('"', '').split('#').last)
            .toList();
        expect(actions, contains('SetAVTransportURI'));
        expect(actions, contains('Play'));
        expect(renderer.otherServiceHits, 0, reason: '发到别的服务上了');

        final setUri = renderer.hits.firstWhere((h) => h.action.contains('SetAVTransportURI'));
        final currentUri = setUri.arg('CurrentURI');
        expect(currentUri, isNotNull);
        // ★★ 给电视的必须是**本机代理地址**（且是电视可达的局域网地址），不是上游原始地址
        expect(currentUri!.startsWith('http://${await pickLanAddress()}:'), isTrue,
            reason: '下发给电视的 CurrentURI 是 $currentUri');
        expect(currentUri.contains('127.0.0.1'), isFalse);
        expect(currentUri, isNot(up.url));
        // DIDL 元数据带上了（部分电视只认 DIDL）
        expect(setUri.arg('CurrentURIMetaData'), contains('第 3 集'));
        expect(setUri.arg('CurrentURIMetaData'), contains('DIDL-Lite'));

        // ── 5. ★ 让 renderer 真的去拉一次那个地址：这是防盗链的端到端证明 ──
        final client = HttpClient();
        final rq = await client.getUrl(Uri.parse(currentUri));
        final rs = await rq.close();
        await rs.drain<void>();
        client.close();
        expect(rs.statusCode, 200);
        expect(up.hits, isNotEmpty, reason: '代理没把请求转给上游');
        expect(up.hits.last['__referer'], 'https://www.bilibili.com/');
      } finally {
        await proxy.stop();
        await renderer.stop();
        await up.stop();
      }
    });

    test('★ 设备回 716 时如实报错，**不**显示成投屏中', () async {
      final renderer = FakeRenderer()..forceErrorCode = 716;
      await renderer.start();
      final proxy = MediaProxy();
      final manager = CastManager(proxy: proxy);
      try {
        final desc = await fetchDescription(renderer.location);
        final dev = CastDevice(location: renderer.location, host: '127.0.0.1', description: desc);
        final s = await manager.cast(dev, 'http://127.0.0.1:9/never.mp4');

        expect(s.phase, CastPhase.failed);
        expect(s.active, isFalse, reason: '失败态不能算 active');
        expect(s.error, contains('716'));
        expect(s.error, contains('打不开这个地址'));
        // 失败后不许再发 Play（设备都拒了地址，发 Play 只会更乱）
        final actions = renderer.hits.map((h) => h.action).toList();
        expect(actions.any((a) => a.contains('#Play')), isFalse);
      } finally {
        await proxy.stop();
        await renderer.stop();
      }
    });

    test('暂停/继续/停止真的发到设备上', () async {
      final renderer = FakeRenderer();
      final up = UpstreamMedia();
      await renderer.start();
      await up.start();
      final proxy = MediaProxy();
      final manager = CastManager(proxy: proxy);
      try {
        final desc = await fetchDescription(renderer.location);
        final dev = CastDevice(location: renderer.location, host: '127.0.0.1', description: desc);
        final s = await manager.cast(dev, up.url);
        expect(s.phase, CastPhase.playing, reason: s.error ?? '');

        final p1 = await manager.pause();
        expect(p1!.phase, CastPhase.paused);
        final p2 = await manager.resume();
        expect(p2!.phase, CastPhase.playing);

        await manager.stop();
        expect(manager.session, isNull);
        expect(proxy.isRunning, isFalse, reason: '停止投屏后代理必须关掉');

        final actions = renderer.hits.map((h) => h.action).toList();
        expect(actions.any((a) => a.contains('#Pause')), isTrue);
        expect(actions.any((a) => a.contains('#Stop')), isTrue);
      } finally {
        await proxy.stop();
        await renderer.stop();
        await up.stop();
      }
    });

    test('不支持 AVTransport 的设备：cast 直接失败并说原因（不硬发指令）', () async {
      final renderer = FakeRenderer();
      await renderer.start();
      final proxy = MediaProxy();
      final manager = CastManager(proxy: proxy);
      try {
        final dev = CastDevice(
          location: renderer.location,
          host: '127.0.0.1',
          description: parseDescription(
            '<root><device><friendlyName>NAS</friendlyName><serviceList><service>'
            '<serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>'
            '<controlURL>/cd</controlURL></service></serviceList></device></root>',
            renderer.location,
          ),
        );
        final s = await manager.cast(dev, 'http://127.0.0.1:9/x.mp4');
        expect(s.phase, CastPhase.failed);
        expect(s.error, contains('不支持 AVTransport'));
        // 一条 SOAP 都不该发出去
        expect(renderer.hits, isEmpty);
      } finally {
        await proxy.stop();
        await renderer.stop();
      }
    });

    test('本地文件路径不投（在起代理前就说清楚）', () async {
      final renderer = FakeRenderer();
      await renderer.start();
      final proxy = MediaProxy();
      final manager = CastManager(proxy: proxy);
      try {
        final desc = await fetchDescription(renderer.location);
        final dev = CastDevice(location: renderer.location, host: '127.0.0.1', description: desc);
        final s = await manager.cast(dev, 'C:\\movies\\a.mkv');
        expect(s.phase, CastPhase.failed);
        expect(s.error, contains('只支持 http/https'));
      } finally {
        await proxy.stop();
        await renderer.stop();
      }
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ⑥ 点播 R1 修复：播放列表改写（纯函数，三形态 + 标签 + 非回环）
  // ═════════════════════════════════════════════════════════════════════

  group('播放列表改写（纯函数）', () {
    // 核心层改写后的子地址长这样：回环 + `/p/<tok>/<scheme>/<host><path>`
    const base = 'http://127.0.0.1:5000/p/TOK/https/cdn.example.com/live/index.m3u8';
    const lan = 'http://192.168.1.5:6000';

    /// 取播放列表里第一条 URI（非空、非 `#` 行）
    String firstUri(String text) => text
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty && !l.startsWith('#'));

    test('★ 形态一：绝对回环分片被改写成本代理地址（这就是 R1 的正解）', () {
      final out = rewritePlaylist(
        [
          '#EXTM3U',
          '#EXT-X-VERSION:3',
          '#EXTINF:4.000,',
          'http://127.0.0.1:5000/p/TOK/https/cdn.example.com/live/seg1.ts',
          '#EXT-X-ENDLIST',
          '',
        ].join('\n'),
        base,
        lan,
      );
      expect(
        firstUri(out),
        'http://192.168.1.5:6000/x/5000/p/TOK/https/cdn.example.com/live/seg1.ts',
      );
      // ★ 核心断言：改写后**一个回环地址都不能剩**（电视拉 127.0.0.1 = 拉它自己）
      expect(out.contains('127.0.0.1'), isFalse, reason: '改写后的清单里还有回环地址：$out');
      expect(out.contains('localhost'), isFalse);
      // 标签行一个字都不许动
      expect(out, contains('#EXT-X-VERSION:3'));
      expect(out, contains('#EXT-X-ENDLIST'));
    });

    test('★ 形态二：相对路径分片也能被解析到本代理（靠 base 目录解析）', () {
      final out = rewritePlaylist('#EXTM3U\nseg1.ts\n', base, lan);
      expect(
        firstUri(out),
        'http://192.168.1.5:6000/x/5000/p/TOK/https/cdn.example.com/live/seg1.ts',
        reason: '相对路径要按**播放列表自己的 URL** 解析，不能直接拼到 /x/ 后面',
      );
    });

    test('★ 形态三：根相对路径（`/` 开头）按 base 的 origin 解析', () {
      final out = rewritePlaylist('#EXTM3U\n/20260820/hls/000.ts\n', base, lan);
      expect(firstUri(out), 'http://192.168.1.5:6000/x/5000/20260820/hls/000.ts');
    });

    test('非回环的完整 URL 一个字都不动（跨主机分片直连，且不该带 Referer）', () {
      const text = '#EXTM3U\n'
          'https://cdn2.example.com/a.ts\n'
          '//cdn3.example.com/b.ts\n';
      final out = rewritePlaylist(text, base, lan);
      expect(out, text, reason: '只许改写回环地址，别的必须原样');
    });

    test('带 URI="…" 的标签也要改写（#EXT-X-KEY / #EXT-X-MAP）', () {
      final out = rewritePlaylist(
        '#EXTM3U\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1:5000/p/TOK/https/cdn.example.com/key.bin"\n'
        '#EXT-X-MAP:URI="https://cdn2.example.com/init.mp4"\n',
        base,
        lan,
      );
      expect(
        out,
        contains('URI="http://192.168.1.5:6000/x/5000/p/TOK/https/cdn.example.com/key.bin"'),
        reason: '加密流的密钥地址不改写，电视拿不到 key 会直接播不了',
      );
      expect(out, contains('URI="https://cdn2.example.com/init.mp4"'));
      // 引号必须成对保留（下标算错会吃掉引号，电视解析就崩）
      expect('"'.allMatches(out).length, 4);
    });

    test('query 与百分号编码原样保留（签名参数解错就是 403）', () {
      final out = rewritePlaylist(
        '#EXTM3U\nhttp://127.0.0.1:5000/p/TOK/https/cdn.example.com/seg.ts?sign=a%3Db&x=1\n',
        base,
        lan,
      );
      expect(
        firstUri(out),
        'http://192.168.1.5:6000/x/5000/p/TOK/https/cdn.example.com/seg.ts?sign=a%3Db&x=1',
      );
    });

    test('localhost / ::1 也算回环（一起改写）', () {
      final out = rewritePlaylist(
        '#EXTM3U\nhttp://localhost:5000/a.ts\nhttp://[::1]:5000/b.ts\n',
        base,
        lan,
      );
      expect(out, contains('http://192.168.1.5:6000/x/5000/a.ts'));
      expect(out, contains('http://192.168.1.5:6000/x/5000/b.ts'));
    });

    test('空行与行尾换行保持原样（不要多吐或少吐换行）', () {
      final out = rewritePlaylist('#EXTM3U\n\nseg.ts\n', base, lan);
      expect(out.split('\n').length, 4);
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ⑦ 点播 R1 修复：真 HTTP 走通「核心层代理 → 外层代理 → 电视」
  // ═════════════════════════════════════════════════════════════════════

  group('点播 R1 修复（真 HTTP）', () {
    /// 取一条真 HTTP（记录状态码/字节/content-type）
    Future<({int code, List<int> bytes, String? ct, String text})> fetchBytes(
      String url, {
      String method = 'GET',
    }) async {
      final client = HttpClient();
      final req = await client.openUrl(method, Uri.parse(url));
      final res = await req.close();
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      final ct = res.headers.contentType?.mimeType;
      client.close();
      return (
        code: res.statusCode,
        bytes: bytes,
        ct: ct,
        text: utf8.decode(bytes, allowMalformed: true),
      );
    }

    /// 把「给电视的局域网地址」换成本机回环，便于在**一台机器上**跑完整条链路。
    ///
    /// 换的只有 host：**路径与端口语义一字不变**，而改写结果本身在纯函数组里
    /// 已经逐字断言过（含 `http://<lan>:<port>` 前缀）。本机测不出「另一台设备
    /// 连得到」这件事 —— 那条在 task-27 的真机验收里用假 renderer 证过。
    String asLocal(String lanUrl) => Uri.parse(lanUrl).replace(host: '127.0.0.1').toString();

    test('★ 两级清单都被改写：电视拿到的每个地址都不再是 127.0.0.1，且分片真被转发回核心层',
        () async {
      final core = FakeCoreProxy();
      await core.start();
      final proxy = MediaProxy();
      try {
        await proxy.start();
        final lan = await pickLanAddress();
        final proxyUrl = await proxy.register(
          core.masterUrl,
          headers: {'Referer': 'https://www.bilibili.com/'},
          label: '点播',
        );

        // ── 第一跳：主清单 ──
        final r1 = await fetchBytes(asLocal(proxyUrl));
        expect(r1.code, 200);
        expect(r1.ct, contains('mpegurl'), reason: '核心层给的 content-type 要透传');
        expect(r1.text.contains('127.0.0.1'), isFalse,
            reason: '改写后的主清单里还有回环地址（电视拉它 = 拉它自己）：${r1.text}');
        final subUrl = 'http://$lan:${proxy.port}/$kLoopPrefix/${core.port}'
            '/p/TOK/https/cdn.example.com/live/index.m3u8';
        expect(r1.text, contains(subUrl), reason: '主清单里的子清单地址没指向本代理');
        expect(proxy.rewrittenCount, 1);

        // ── 第二跳：子清单（电视拿到的就是上面那条地址）──
        final r2 = await fetchBytes(asLocal(subUrl));
        expect(r2.code, 200);
        expect(r2.text.contains('127.0.0.1'), isFalse,
            reason: '子清单里的分片地址还是回环（这就是 R1 的成因）：${r2.text}');
        final segUrl = 'http://$lan:${proxy.port}/$kLoopPrefix/${core.port}'
            '/p/TOK/https/cdn.example.com/live/seg1.ts';
        expect(r2.text, contains(segUrl));
        expect(proxy.rewrittenCount, 2, reason: '两级清单各改写一次');

        // ── 第三跳：分片（二进制，必须一字不差）──
        final r3 = await fetchBytes(asLocal(segUrl));
        expect(r3.code, 200);
        expect(r3.ct, 'video/mp2t');
        expect(r3.bytes, FakeCoreProxy.segBytes, reason: '分片必须逐字节透传');

        // ── 证据：核心层真的收到了分片请求，且**没被注入 Referer** ──
        final segHit = core.hits.where((h) => h['__path']!.endsWith('seg1.ts')).toList();
        expect(segHit.length, 1, reason: '核心层没收到分片请求：${core.hits}');
        expect(segHit.first['__referer'], '<none>',
            reason: '回环中转不该注入任何头（Referer 由核心层按登记表自己带）');
        // 核心层自己那份请求，路径与端口都是**手机回环**（合法：代理就在手机上）
        expect(segHit.first['__path'], '/p/TOK/https/cdn.example.com/live/seg1.ts');
      } finally {
        await proxy.stop();
        await core.stop();
      }
    });

    test('★ 非播放列表的响应体一字不改（二进制流不许走改写）', () async {
      final up = UpstreamMedia(payload: utf8.encode('127.0.0.1 不该被改写'), mimeType: 'video/mp4');
      await up.start();
      final proxy = MediaProxy();
      try {
        final u = await proxy.register(up.url);
        final r = await fetchBytes(asLocal(u));
        expect(r.code, 200);
        expect(r.ct, 'video/mp4');
        expect(utf8.decode(r.bytes), '127.0.0.1 不该被改写',
            reason: '二进制响应被当成播放列表改了 —— 会毁掉文件');
        expect(proxy.rewrittenCount, 0);
      } finally {
        await proxy.stop();
        await up.stop();
      }
    });

    test('★ 大响应仍逐字节转发（不整读进内存）', () async {
      final big = List<int>.generate(256 * 1024, (i) => (i * 7 + 13) % 256);
      final up = UpstreamMedia(path: '/movie.mp4', payload: big);
      await up.start();
      final proxy = MediaProxy();
      try {
        final u = await proxy.register(up.url);
        final r = await fetchBytes(asLocal(u));
        expect(r.bytes.length, big.length);
        expect(r.bytes, big, reason: '大响应字节被改动了');
      } finally {
        await proxy.stop();
        await up.stop();
      }
    });

    test('content-type 是 application/octet-stream 时退回看后缀（CDN 常这么发 m3u8）', () async {
      final up = UpstreamMedia(
        path: '/live/index.m3u8',
        mimeType: 'application/octet-stream',
        payload: utf8.encode('#EXTM3U\nhttp://127.0.0.1:9/a.ts\n'),
      );
      await up.start();
      final proxy = MediaProxy();
      try {
        final u = await proxy.register(up.url);
        final r = await fetchBytes(asLocal(u));
        expect(r.text.contains('127.0.0.1'), isFalse,
            reason: 'octet-stream + .m3u8 后缀也要改写：${r.text}');
        expect(r.text, contains('/$kLoopPrefix/9/a.ts'));
        expect(proxy.rewrittenCount, 1);
      } finally {
        await proxy.stop();
        await up.stop();
      }
    });

    test('octet-stream + 非清单后缀：不读进内存、不改写', () async {
      final payload = utf8.encode('#EXTM3U\nhttp://127.0.0.1:9/a.ts\n');
      final up = UpstreamMedia(
        path: '/movie.mp4',
        mimeType: 'application/octet-stream',
        payload: payload,
      );
      await up.start();
      final proxy = MediaProxy();
      try {
        final u = await proxy.register(up.url);
        final r = await fetchBytes(asLocal(u));
        expect(r.bytes, payload, reason: '后缀不是 .m3u8/.m3u 就不该走改写');
        expect(proxy.rewrittenCount, 0);
      } finally {
        await proxy.stop();
        await up.stop();
      }
    });

    test('★ /m/<token>/<rest> 按登记地址的相对语义拼回（清单里出现相对路径分片时靠它）', () async {
      final core = FakeCoreProxy();
      await core.start();
      final proxy = MediaProxy();
      try {
        await proxy.start();
        final u = await proxy.register(core.indexUrl);
        // 相对分片：电视会解析成 `<代理地址>/seg1.ts`
        final rel = '${Uri.parse(u).path}/seg1.ts';
        final r = await fetchBytes('http://127.0.0.1:${proxy.port}$rel');
        expect(r.code, 200);
        expect(r.bytes, FakeCoreProxy.segBytes);
        final hit = core.hits.last;
        expect(hit['__path'], '/p/TOK/https/cdn.example.com/live/seg1.ts',
            reason: '相对路径要拼到**登记地址的目录**下，不是拼到根上');
      } finally {
        await proxy.stop();
        await core.stop();
      }
    });

    test('/x/ 路由的坏输入如实报错（不假装成功）', () async {
      final proxy = MediaProxy();
      try {
        await proxy.start();
        final base = 'http://127.0.0.1:${proxy.port}/$kLoopPrefix';
        final r1 = await fetchBytes('$base/99999/a.ts');
        expect(r1.code, 400);
        expect(r1.text, contains('端口不合法'));
        final r2 = await fetchBytes('$base/5000');
        expect(r2.code, 400);
        expect(r2.text, contains('回环中转路径'));
        final r3 = await fetchBytes('$base/5000/a.ts', method: 'POST');
        expect(r3.code, 405);
      } finally {
        await proxy.stop();
      }
    });
  });
}

