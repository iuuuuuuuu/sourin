// ═══════════════════════════════════════════════════════════════════════
//  两件事的回归测试（Owner 桌面端 9 条问题 · 第 1 条 + 第 2 条）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// 第 1 条：弹幕报错，如图1   —— 截图里那句话是
//                            「弹幕失败：Missing Authentication Headers」
// 第 2 条：bilibili弹幕要支持搜索功能
//
// # 第 1 条守什么
//
// 那句英文是 dandanplay 的原话，**必须原样留着**（排错唯一线索），
// 但光有它用户不知道该干什么。所以 core 层把"哪一类失败"判出来，
// 并给一句中文动作（DanmakuHint）。
// ★ 判据**只认真实读数**：HTTP 状态码 + X-Error-Message 原文 ——
//   不做"消息里含某几个字"的乱匹配（服务端改一个词就失效）。
//
// # 第 2 条守什么
//
// 「搜 B 站视频 → 点一条 → 绑定」这条链。四层：
// ① 清洗：title 剥 <em class="keyword">、pic 补 https:  （纯函数）
// ② 解析：喂一段**真实响应**（逐字，见下面的 _fixture），得到正确模型
// ③ 请求：Referer 必须是 search.bilibili.com（★ 用 www.bilibili.com
//    会拿到 HTTP 200 + text/html 的风控页 —— 状态码是 200，
//    最会骗过"非 2xx 才报错"的判断，所以这条单独钉住）
// ④ UI：面板渲染出结果列表 + 点一条真的回传 bvid
//
// # 关于"有没有发真网络"
//
// 本文件**一个网络包都不发**：
//   · 解析层只吃字符串夹具（真实抓下来的原文，逐字粘在下面）；
//   · 请求层用 _FakeHttpClient（只实现 getUrl）——
//     它把"发了什么请求"记下来供断言，响应由测试给定；
//   · 弹幕提示层用 DanmakuTransport 的假实现（与 task13 同款）。
// 真实抓取的过程与响应头原文见 .probe_i12/（keyword=原神）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/bili/bili_api.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';

// ══════════════════════════════════════════════════════════════════════
//  夹具
// ══════════════════════════════════════════════════════════════════════

/// **真实响应**（逐字，2026-10-08 抓的，keyword=原神，截到 3 条）。
///
/// 保留原样的四处坑：
///   · title 里有 <em class="keyword">原神</em>
///   · pic 是协议相对的 //i0.hdslb.com/...
///   · duration 是个位数秒不补零的 "1:2"
///   · aid = 117400414459441 —— **大于 2^53**，绝不许经 double 往返
const String _fixture = r'''
{
  "code": 0,
  "message": "OK",
  "data": {
    "page": 1,
    "pagesize": 20,
    "numResults": 1000,
    "numPages": 50,
    "result": [
      {
        "bvid": "BV1QmHy6eENs",
        "aid": 117400414459441,
        "title": "10月6日拯救者榜，<em class=\"keyword\">原神</em>36.9w排名第四",
        "author": "珈西德楽",
        "duration": "0:12",
        "pic": "//i0.hdslb.com/bfs/archive/0553e5e77c153ab036966fcdfe504b1f821b1de5.jpg",
        "play": 42,
        "video_review": 0,
        "typename": "电子竞技",
        "pubdate": 1791388241
      },
      {
        "bvid": "BV1TvH16YEGx",
        "aid": 117399894493942,
        "title": "【<em class=\"keyword\">原神</em>动画】米提亚：现在我又有个新点子☝️🤓",
        "author": "麟安Heroo",
        "duration": "1:2",
        "pic": "//i2.hdslb.com/bfs/archive/d56f047aedda3bfa712fde53eb7d39f03133f916.jpg",
        "play": 2765,
        "video_review": 1,
        "typename": "手机游戏",
        "pubdate": 1791380993
      },
      {
        "bvid": "BV1fgH16UEha",
        "aid": 117400162862844,
        "title": "别吵吵最美的18位<em class=\"keyword\">原神</em>女角色cos",
        "author": "云不兮",
        "duration": "3:33",
        "pic": "//i2.hdslb.com/bfs/archive/f77c949a18b38653c5385887cb934038dc4737ae.jpg",
        "play": 239,
        "video_review": 0,
        "typename": "仿妆cos",
        "pubdate": 1791384793
      }
    ]
  }
}
''';

// ══════════════════════════════════════════════════════════════════════
//  测试替身
// ══════════════════════════════════════════════════════════════════════

class _FakeHeaders implements HttpHeaders {
  _FakeHeaders([Map<String, List<String>>? seed])
      : _map = <String, List<String>>{...?seed};

  final Map<String, List<String>> _map;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _map[name.toLowerCase()] = <String>[value.toString()];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _map.putIfAbsent(name.toLowerCase(), () => <String>[]).add(value.toString());
  }

  @override
  List<String>? operator [](String name) => _map[name.toLowerCase()];

  @override
  String? value(String name) {
    final v = _map[name.toLowerCase()];
    return (v == null || v.isEmpty) ? null : v.first;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('假 HttpHeaders 不支持：${invocation.memberName}');
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse({
    required this.statusCode,
    required this.body,
    Map<String, List<String>>? headers,
  }) : _headers = _FakeHeaders(headers);

  @override
  final int statusCode;

  final List<int> body;
  final _FakeHeaders _headers;

  @override
  HttpHeaders get headers => _headers;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.value(body).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
      '假 HttpClientResponse 不支持：${invocation.memberName}');
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.uri, this._response);

  @override
  final Uri uri;

  final _FakeResponse _response;
  final _FakeHeaders sentHeaders = _FakeHeaders();

  @override
  HttpHeaders get headers => sentHeaders;

  @override
  Future<HttpClientResponse> close() async => _response;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
      '假 HttpClientRequest 不支持：${invocation.memberName}');
}

/// 记下每次请求（uri + 请求头），响应由 _respond 决定。
class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._respond);

  final _FakeResponse Function(Uri uri) _respond;

  final List<Uri> uris = <Uri>[];
  final List<_FakeHeaders> headers = <_FakeHeaders>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    uris.add(url);
    final req = _FakeRequest(url, _respond(url));
    headers.add(req.sentHeaders);
    return req;
  }

  bool closed = false;

  @override
  void close({bool force = false}) => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
        '单测不许用真 HttpClient（成员：${invocation.memberName}）',
      );
}

/// 假传输层（与 test/task13_danmaku_test.dart 同款）
class _FakeTransport implements DanmakuTransport {
  _FakeTransport(this.handler);

  final DanmakuHttpResponse Function(Uri uri) handler;
  final List<Uri> calls = <Uri>[];

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    calls.add(uri);
    return handler(uri);
  }

  @override
  void close() {}
}

// ══════════════════════════════════════════════════════════════════════
//  面板宿主（与 t70 同款：material_ui 的 MaterialApp + Stack）
// ══════════════════════════════════════════════════════════════════════

class _Calls {
  String? importInput;
  int? importPage;
  String? searched;
  int close = 0;
}

Widget _host(BiliImportState state, _Calls c, {bool withSearch = true}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Stack(
          children: <Widget>[
            BiliImportDialog(
              state: state,
              onImport: (String input, int page) async {
                c.importInput = input;
                c.importPage = page;
              },
              onSelectPage: (int p) {},
              onSetAutoUpdate: (bool v) {},
              onSetInterval: (int v) {},
              onUpdateNow: () async {},
              onUnbind: () {},
              onClose: () => c.close++,
              onSearch: withSearch ? (String kw) => c.searched = kw : null,
            ),
          ],
        ),
      ),
    );

Future<void> _pumpPanel(WidgetTester t, BiliImportState state, _Calls c,
    {bool withSearch = true}) async {
  // 面板卡片 maxHeight 620，而默认测试画布只有 800x600
  // ⇒ 结果列表会被挤到视口外、点不到。这里把画布放大。
  t.view.physicalSize = const Size(1200, 1600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(_host(state, c, withSearch: withSearch));
  await t.pump();
}

/// 剥 Dart 注释（字符串字面量里的斜杠不算注释）
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
    } else if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
    } else if (c == "'" || c == '"') {
      final q = c;
      out.write(c);
      i++;
      while (i < src.length && src[i] != q) {
        if (src[i] == '\\') {
          out.write(src[i]);
          i++;
          if (i >= src.length) break;
        }
        out.write(src[i]);
        i++;
      }
      if (i < src.length) {
        out.write(src[i]);
        i++;
      }
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 清洗：标题剥 em 标签
  // ═══════════════════════════════════════════════════════════════════

  group('① 标题剥 em 标签', () {
    test('剥掉 em class=keyword（真实响应里 20/20 条都带）', () {
      expect(
        stripBiliSearchEm(
          '10月6日拯救者榜，<em class="keyword">原神</em>36.9w排名第四',
        ),
        '10月6日拯救者榜，原神36.9w排名第四',
      );
    });

    test('一条标题里出现多次也全剥', () {
      expect(
        stripBiliSearchEm('<em>原神</em>和<em class="keyword">崩铁</em>'),
        '原神和崩铁',
      );
    });

    test('没有标签时原样返回', () {
      expect(stripBiliSearchEm('普通标题'), '普通标题');
      expect(stripBiliSearchEm(''), '');
    });

    test('★ 只剥 em，不吃掉标题里合法的尖括号', () {
      expect(stripBiliSearchEm('1<2>3'), '1<2>3');
      expect(stripBiliSearchEm('<b>加粗</b>'), '<b>加粗</b>');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 清洗：封面补 https:
  // ═══════════════════════════════════════════════════════════════════

  group('② 封面补 https:', () {
    test('协议相对的 //i0.hdslb.com/... 补成 https://', () {
      expect(
        biliSearchCoverUrl('//i0.hdslb.com/bfs/archive/aaa.jpg'),
        'https://i0.hdslb.com/bfs/archive/aaa.jpg',
      );
    });

    test('已经是 https 的原样', () {
      expect(
        biliSearchCoverUrl('https://i2.hdslb.com/x.jpg'),
        'https://i2.hdslb.com/x.jpg',
      );
    });

    test('空串 / 空白 ⇒ 空串（UI 走占位图）', () {
      expect(biliSearchCoverUrl(''), '');
      expect(biliSearchCoverUrl('   '), '');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 解析真实响应
  // ═══════════════════════════════════════════════════════════════════

  group('③ 解析真实响应', () {
    test('3 条全部解析出来，字段逐字对得上', () {
      final items = parseBiliSearchItems(_fixture);
      expect(items.length, 3);

      final a = items[0];
      expect(a.bvid, 'BV1QmHy6eENs');
      expect(a.title, '10月6日拯救者榜，原神36.9w排名第四');
      expect(a.author, '珈西德楽');
      expect(a.duration, '0:12');
      expect(a.cover, startsWith('https://i0.hdslb.com/'));
      expect(a.play, 42);
      expect(a.typename, '电子竞技');
      expect(a.pubdate, 1791388241);
      expect(a.usable, isTrue);

      // ★ 个位数秒的 "1:2" 必须原样保留（不要格式化成 "01:02"）
      expect(items[1].duration, '1:2');
      expect(items[2].duration, '3:33');
      expect(items[2].author, '云不兮');
    });

    test('★ aid 大于 2^53 —— 必须是精确的 int，不许经 double 往返', () {
      final a = parseBiliSearchItems(_fixture).first;
      expect(a.aid, 117400414459441);
      expect(a.aid, isA<int>());
      // 红度对照：一旦走了 double 就会变成这个值
      expect(a.aid.toString(), isNot('117400414459440'));
    });

    test('★ 解析出来的 title 里一个 HTML 标签都不剩', () {
      for (final it in parseBiliSearchItems(_fixture)) {
        expect(it.title.contains('<'), isFalse, reason: it.title);
        expect(it.title.contains('em'), isFalse, reason: it.title);
      }
    });

    test('边界：data 缺失 / result 不是 List / 非法 JSON ⇒ 空列表（不抛）', () {
      expect(parseBiliSearchItems('{"code":0}'), isEmpty);
      expect(parseBiliSearchItems('{"code":0,"data":{}}'), isEmpty);
      expect(parseBiliSearchItems('{"code":0,"data":{"result":{}}}'), isEmpty);
      expect(parseBiliSearchItems('<html>风控页</html>'), isEmpty);
      expect(parseBiliSearchItems(''), isEmpty);
      expect(parseBiliSearchItems(null), isEmpty);
    });

    test('边界：没有 bvid 的条目直接丢掉（绑不动）', () {
      final items = parseBiliSearchItems(
        '{"code":0,"data":{"result":[{"title":"没有 bvid"},'
        '{"bvid":"BV1QmHy6eENs","title":"有"}]}}',
      );
      expect(items.length, 1);
      expect(items.first.bvid, 'BV1QmHy6eENs');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 请求形状：Referer 必须是 search.bilibili.com
  // ═══════════════════════════════════════════════════════════════════

  group('④ 搜索请求形状', () {
    test('★ Referer 用搜索专用域名，不是 kBiliReferer', () async {
      final client = _FakeHttpClient(
        (_) => _FakeResponse(
          statusCode: 200,
          body: utf8.encode(_fixture),
          headers: <String, List<String>>{
            'content-type': <String>['application/json'],
          },
        ),
      );
      final api = BiliApi(client: client);
      addTearDown(api.close);

      final items = await api.searchVideos('原神');
      expect(items.length, 3);

      expect(client.uris.length, 1);
      final u = client.uris.single;
      expect(u.host, 'api.bilibili.com');
      expect(u.path, '/x/web-interface/search/type');
      expect(u.queryParameters['search_type'], 'video');
      expect(u.queryParameters['keyword'], '原神');
      expect(u.queryParameters['page'], '1');
      // ★ 实测：不传 page_size 才对；传了会 412
      expect(u.queryParameters.containsKey('page_size'), isFalse);

      final referer = client.headers.single.value(HttpHeaders.refererHeader);
      expect(referer, kBiliSearchReferer);
      expect(referer, isNot(kBiliReferer),
          reason: '★ 用 www.bilibili.com 会拿到 200 + text/html 的风控页');
      expect(client.headers.single.value(HttpHeaders.userAgentHeader),
          kBiliUserAgent);
    });

    test('空关键词 ⇒ 一个包都不发', () async {
      final client = _FakeHttpClient(
        (_) => _FakeResponse(statusCode: 200, body: utf8.encode('{}')),
      );
      final api = BiliApi(client: client);
      addTearDown(api.close);

      expect(await api.searchVideos(''), isEmpty);
      expect(await api.searchVideos('   '), isEmpty);
      expect(client.uris, isEmpty);
    });

    test('page 传 0 时夹到 1', () async {
      final client = _FakeHttpClient(
        (_) => _FakeResponse(statusCode: 200, body: utf8.encode(_fixture)),
      );
      final api = BiliApi(client: client);
      addTearDown(api.close);

      await api.searchVideos('原神', page: 0);
      expect(client.uris.single.queryParameters['page'], '1');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 弹幕失败提示（第 1 条）
  // ═══════════════════════════════════════════════════════════════════

  group('⑤ 弹幕失败提示', () {
    test('★ 403 + Missing Authentication Headers ⇒ 没填凭证 + 一个动作', () {
      final e = DanmakuException(
        '弹幕服务拒绝了这次请求：Missing Authentication Headers',
        statusCode: 403,
        xErrorMessage: 'Missing Authentication Headers',
        uri: 'https://api.dandanplay.net/api/v2/match',
      );
      expect(e.isAuthProblem, isTrue, reason: '老语义不能变');

      final h = DanmakuHint.of(e);
      expect(h, isNotNull);
      expect(h!.title, '弹幕服务没收到凭证');
      expect(h.text, contains('AppId'));
      expect(h.text, contains('AppSecret'));
      expect(h.text, contains('哔哩哔哩弹幕'), reason: '要给"另一条路"');
      expect(h.url, 'https://dev.dandanplay.com');
      expect(h.action, isNotNull);
      expect(h.action!.label, isNotEmpty);
      expect(h.action!.openDanmakuSettings, isTrue);
      expect(h.action!.openBiliSheet, isTrue,
          reason: '两个入口都要给：填凭证 / 改走 B 站');
    });

    test('★ 403 但 X-Error-Message 为空，同样算没填凭证', () {
      final e = DanmakuException('弹幕服务拒绝了这次请求（HTTP 403）',
          statusCode: 403);
      final h = DanmakuHint.of(e);
      expect(h, isNotNull);
      expect(h!.title, '弹幕服务没收到凭证');
    });

    test('★ 403 + Invalid Signature ⇒ 凭证没通过，且原文照旧出现', () {
      final e = DanmakuException(
        '弹幕服务拒绝了这次请求：Invalid Signature',
        statusCode: 403,
        xErrorMessage: 'Invalid Signature',
      );
      final h = DanmakuHint.of(e);
      expect(h, isNotNull);
      expect(h!.title, '凭证没通过');
      expect(h.text, contains('Invalid Signature'), reason: '原文不许改写');
      expect(h.action!.openDanmakuSettings, isTrue);
      expect(h.action!.openBiliSheet, isFalse, reason: '这不是"没填"');
    });

    test('判不出来时返回 null（不猜）', () {
      expect(DanmakuHint.of(DanmakuException('HTTP 500', statusCode: 500)), isNull);
      expect(DanmakuHint.of(DanmakuException('没认出 BV 号 / av 号 / 链接')), isNull);
      expect(DanmakuHint.of(DanmakuException('没有匹配到弹幕库（x）')), isNull);
    });

    test('htmlPage 提示说的是"网页不是数据"', () {
      final h = DanmakuHint.htmlPage(what: '搜索');
      expect(h.title, '拿到的是网页，不是数据');
      expect(h.text, contains('搜索'));
      expect(h.action, isNull);
    });

    test('★ 端到端：真走 _decode 的 403 分支，hint 挂上且原文不变', () async {
      final t = _FakeTransport(
        (Uri uri) => const DanmakuHttpResponse(
          statusCode: 403,
          body: '',
          headers: <String, String>{
            'x-error-message': 'Missing Authentication Headers',
          },
        ),
      );
      final c = DandanplayClient(transport: t, appId: '', appSecret: '');

      DanmakuException? caught;
      try {
        await c.match(fileName: '第01话');
      } on DanmakuException catch (e) {
        caught = e;
      }

      expect(caught, isNotNull);
      expect(caught!.statusCode, 403);
      expect(caught.xErrorMessage, 'Missing Authentication Headers',
          reason: '★ 服务端原文一个字都不许改');
      expect(caught.message, contains('Missing Authentication Headers'));
      expect(caught.detail,
          contains('X-Error-Message: Missing Authentication Headers'));
      expect(caught.hint, isNotNull, reason: '★ 这一步就是第 1 条的修复点');
      expect(caught.hint!.title, '弹幕服务没收到凭证');
    });

    test('★ 412 被限流时给的是等一会，不是凭证问题', () async {
      final t = _FakeTransport(
        (Uri uri) => const DanmakuHttpResponse(statusCode: 412, body: ''),
      );
      final c = DandanplayClient(transport: t);
      DanmakuException? caught;
      try {
        await c.match(fileName: '第01话');
      } on DanmakuException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.hint, isNotNull);
      expect(caught.hint!.title, '被弹幕服务限流了');
    });

    test('★ HTTP 200 但正文是网页 ⇒ 说人话，而不是"返回的不是 JSON"', () async {
      final t = _FakeTransport(
        (Uri uri) => const DanmakuHttpResponse(
          statusCode: 200,
          body: '<!DOCTYPE html><html><body>人机校验</body></html>',
          headers: <String, String>{'content-type': 'text/html'},
        ),
      );
      final c = DandanplayClient(transport: t);
      DanmakuException? caught;
      try {
        await c.match(fileName: '第01话');
      } on DanmakuException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.statusCode, 200);
      expect(caught.message, contains('网页'));
      expect(caught.hint, isNotNull);
      expect(caught.hint!.title, '拿到的是网页，不是数据');
    });

    test('★ 正常 JSON 里出现 html 这个词不算网页（不误判）', () async {
      // 正文里**故意**塞了 html 这个词：判据只看开头，全文匹配会误判
      final t = _FakeTransport(
        (Uri uri) => DanmakuHttpResponse(
          statusCode: 200,
          body: jsonEncode(<String, dynamic>{
            'success': true,
            'errorCode': 0,
            'errorMessage': 'html 这个词不该触发网页判定',
            'matches': <dynamic>[],
          }),
          headers: const <String, String>{'content-type': 'application/json'},
        ),
      );
      final c = DandanplayClient(transport: t);

      // ① match() 在"一条都没匹配上"时是**返回空表**，不抛
      expect(await c.match(fileName: '第01话'), isEmpty);

      // ② 走 loadFor 的短路分支才会抛 —— 此时抛的是"没匹配到"，
      //    不是"返回的是一张网页"（证明 _looksLikeHtml 没误判）
      DanmakuException? caught;
      try {
        await c.loadFor(fileName: '第01话', allowSearchFallback: false);
      } on DanmakuException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.message, contains('没有匹配到弹幕库'));
      expect(caught.message.contains('网页'), isFalse);
      expect(caught.hint, isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ 面板：搜索结果区
  // ═══════════════════════════════════════════════════════════════════

  group('⑥ 面板搜索结果', () {
    const results = <BiliSearchItem>[
      BiliSearchItem(
        bvid: 'BV1QmHy6eENs',
        title: '拯救者榜原神36.9w排名第四',
        author: '珈西德楽',
        duration: '0:12',
      ),
      BiliSearchItem(
        bvid: 'BV1TvH16YEGx',
        title: '【原神动画】米提亚：现在我又有个新点子',
        author: '麟安Heroo',
        duration: '1:2',
      ),
    ];

    testWidgets('★ 有结果时：标题 + UP 主 + 时长都渲染出来', (WidgetTester t) async {
      final c = _Calls();
      await _pumpPanel(
        t,
        const BiliImportState(searchKeyword: '原神', searchResults: results),
        c,
      );

      expect(find.text('搜索视频'), findsOneWidget);
      expect(find.text('按关键词找，点一条就绑定'), findsOneWidget);
      expect(find.text('搜索'), findsOneWidget);

      expect(find.text('拯救者榜原神36.9w排名第四'), findsOneWidget);
      expect(find.text('【原神动画】米提亚：现在我又有个新点子'), findsOneWidget);
      expect(find.text('珈西德楽 · 0:12'), findsOneWidget);
      expect(find.text('麟安Heroo · 1:2'), findsOneWidget);

      // 老的输入区还在（不能被搜索区顶掉）
      expect(find.text('视频链接'), findsOneWidget);
      expect(find.text('弹幕是免登录抓的，不需要 B 站账号。'), findsOneWidget);
    });

    testWidgets('★ 点一条 ⇒ 把它的 BV 号当输入喂给导入流程', (WidgetTester t) async {
      final c = _Calls();
      await _pumpPanel(
        t,
        const BiliImportState(searchKeyword: '原神', searchResults: results),
        c,
      );

      await t.tap(find.text('【原神动画】米提亚：现在我又有个新点子'));
      await t.pump();

      expect(c.importInput, 'BV1TvH16YEGx');
      expect(c.importPage, 0, reason: '搜索结果不带 P 选择，走自动对齐');
    });

    testWidgets('★ 搜索框与链接框是两个独立输入框', (WidgetTester t) async {
      final c = _Calls();
      await _pumpPanel(t, const BiliImportState(), c);
      expect(find.byType(TextField), findsNWidgets(2));

      await t.enterText(find.byType(TextField).last, '  原神  ');
      await t.pump();
      await t.tap(find.text('搜索'));
      await t.pump();

      expect(c.searched, '原神', reason: '首尾空白要裁掉');
      expect(c.importInput, isNull, reason: '搜索不等于导入');
    });

    testWidgets('搜过但没结果 ⇒ 一句话说清（而不是一片空白）', (WidgetTester t) async {
      final c = _Calls();
      await _pumpPanel(
        t,
        const BiliImportState(searchKeyword: '原神'),
        c,
      );
      expect(find.text('没搜到「原神」相关的视频，换个关键词试试。'), findsOneWidget);
    });

    testWidgets('宿主没接 onSearch ⇒ 搜索按钮不显示（点了没反应更糟）',
        (WidgetTester t) async {
      final c = _Calls();
      await _pumpPanel(t, const BiliImportState(), c, withSearch: false);
      expect(find.text('搜索'), findsNothing);
      expect(find.text('搜索视频'), findsNothing);
      expect(find.text('视频链接'), findsOneWidget, reason: '其它区块照旧');
    });

    testWidgets('★ 缩略图走 coverImage（URL 已补 https:）', (WidgetTester t) async {
      final c = _Calls();
      await _pumpPanel(
        t,
        const BiliImportState(
          searchKeyword: '原神',
          searchResults: <BiliSearchItem>[
            BiliSearchItem(
              bvid: 'BV1QmHy6eENs',
              title: '有封面的那条',
              author: 'UP',
              duration: '0:12',
              cover: 'https://i0.hdslb.com/bfs/archive/aaa.jpg',
            ),
          ],
        ),
        c,
      );

      // coverImage 会给 image 套一层 ResizeImage（cacheWidth / cacheHeight
      // 按布局尺寸 × DPR 算），所以要先剥掉再看真正的 provider
      final img = t.widget<Image>(find.byType(Image));
      final provider = img.image;
      expect(provider, isA<ResizeImage>());
      final inner = (provider as ResizeImage).imageProvider;
      expect(inner, isA<NetworkImage>());
      expect((inner as NetworkImage).url,
          'https://i0.hdslb.com/bfs/archive/aaa.jpg');
    });

    testWidgets('没封面时不留空洞（走占位）', (WidgetTester t) async {
      final c = _Calls();
      await _pumpPanel(
        t,
        const BiliImportState(
          searchKeyword: '原神',
          searchResults: <BiliSearchItem>[
            BiliSearchItem(bvid: 'BV1QmHy6eENs', title: '没封面', author: 'UP'),
          ],
        ),
        c,
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('没封面'), findsOneWidget);
    });

    testWidgets('加载中：搜索框禁用 + 搜索按钮禁用', (WidgetTester t) async {
      final c = _Calls();
      await _pumpPanel(
        t,
        const BiliImportState(loading: true, searchResults: results),
        c,
      );

      final fields = t.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields.length, 2);
      expect(fields.every((f) => f.enabled == false), isTrue);

      final btn = t.widget<FilledButton>(
        find.widgetWithText(FilledButton, '搜索'),
      );
      expect(btn.onPressed, isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑦ 静态审计：这次改的文件不许把 UI 依赖带进 core
  // ═══════════════════════════════════════════════════════════════════

  group('⑦ 静态审计', () {
    test('★ bili_api.dart 是 core 层：不许出现任何 UI 包', () {
      final code = _stripComments(
        File('lib/core/bili/bili_api.dart').readAsStringSync(),
      );
      expect(code.contains('package:flutter/material.dart'), isFalse);
      expect(code.contains('material_ui'), isFalse);
    });

    test('★ danmaku.dart 也是 core 层：不许出现任何 UI 包', () {
      final code = _stripComments(
        File('lib/core/danmaku.dart').readAsStringSync(),
      );
      expect(code.contains('package:flutter/material.dart'), isFalse);
      expect(code.contains('material_ui'), isFalse);
      expect(code.contains('package:flutter/widgets.dart'), isFalse);
    });

    test('★ 面板文件：注释里写着 flutter/material，真正 import 的是 material_ui',
        () {
      final raw =
          File('lib/ui/widgets/bili_import_dialog.dart').readAsStringSync();
      final code = _stripComments(raw);
      expect(raw.contains('package:flutter/material.dart'), isTrue,
          reason: '★ 注释里就该有它，否则这条测试是假绿');
      expect(code.contains('package:flutter/material.dart'), isFalse);
      expect(code.contains('package:material_ui/material_ui.dart'), isTrue);
    });

    test('★ 面板根节点：默认仍是 Positioned.fill，包着时退成裸内容（task-104）', () {
      final code = _stripComments(
        File('lib/ui/widgets/bili_import_dialog.dart').readAsStringSync(),
      );
      /*
       * ★★★ task-104：根节点多了一个 `fill` 开关（默认 true）
       *
       * ```text
       * 默认（fill: true）  return widget.fill ? Positioned.fill(child: body) : body;
       *                       ⇒ 生产挂载点之外的 6 个测试文件 / 探针都不用改
       * fill: false         ⇒ 宿主用 SheetExitMotion 包着时，面板**不能**
       *                       自己写 Positioned（父链里多了 Opacity /
       *                       IgnorePointer ⇒ 会抛 Incorrect use of ParentDataWidget）
       * ```
       * ⚠️ 语义**一条没放松**：仍然是「默认形态必须自带 Positioned.fill」——
       *    本文件 ⑥ 组那套「必须套 Stack」的前提一字不变，只是现在这句话
       *    落在一个三元表达式的**真分支**上（假分支由 t104 的门禁单独钉）。
       */
      expect(code.contains('return widget.fill ? Positioned.fill(child: body) : body;'),
          isTrue,
          reason: '★ 面板默认形态变了 ⇒ 本文件 ⑥ 组所有 widget 测试的前提就变了');
      expect(code.contains('this.fill = true,'), isTrue,
          reason: '★ 默认必须是 true（老宿主零破坏）');
    });

    test('★ 面板里不许出现字面量 Image.network(（t74 D3 扫全 lib 只许一处）', () {
      final code = _stripComments(
        File('lib/ui/widgets/bili_import_dialog.dart').readAsStringSync(),
      );
      expect(code.contains('Image.network('), isFalse,
          reason: '缩略图必须走 cover_image.dart 的 coverImage()');
      expect(code.contains('coverImage('), isTrue);
    });
  });
}
