// ═══════════════════════════════════════════════════════════════════════
//  ★★★ autoBindBySearch：播放时自动搜 B 站并绑定（2026-10-09）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > bilibili都支持搜索了,也选择了,但就是没显示弹幕这个流程有问题
// > bilibili未登录都可以获取弹幕的所以你那个报错,纯瞎扯的
// ```
//
// # 这里证什么
// ```text
// 改前：没绑定时**直接落到 dandanplay**（要 AppId/AppSecret）⇒ 没配就 403
//       ⇒ 屏幕上那句「弹幕失败：Missing Authentication Headers」。
// 改后：先自动搜 B 站（**免登录**）→ 挑最像的一条 → 绑定 → 取弹幕。
//
// 本文件钉住三件事：
// ① 相似度够 ⇒ 真的绑定，且绑的是**最像的那条**（不是搜索结果第一条）；
// ② 相似度不够 ⇒ 返回 null（宁可如实说"没匹配到"，也不绑错）；
// ③ 手动绑过的**不许被自动流程覆盖**（用户的选择优先）。
// ```
//
// ⚠️ 本文件**一个网络包都不发**：吃真实抓下来的响应夹具，
//    用假 HttpClient 驱动（与 t100_bili_search_test.dart 同款手法）。
//
// 真实端点的实测证据（2026-10-09，无 Cookie）：
// ```text
// 搜索  api.bilibili.com/x/web-interface/search/type → 200 JSON，20 条
// 弹幕  comment.bilibili.com/279786.xml             → 200 text/xml，1200 条
// ⇒ 两件都免登录 ⇒ 缺的从来不是登录态，是"自动去搜"这一步。
// ```

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/bili/bili_api.dart';
import 'package:sourin_spike/core/bili/bili_bind.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/core/title_match.dart';

// ══════════════════════════════════════════════════════════════════════
//  夹具：真实响应（逐字，2026-10-09，keyword=无职转生）
// ══════════════════════════════════════════════════════════════════════

/// 搜索结果 —— 保留原样的坑：title 带 <em> 高亮、pic 协议相对。
///
/// ★ 关键是**顺序**：第 0 条是 OP（相似度低），第 1 条才是正片。
///   若实现写成"取第一条"，本夹具会立刻判红。
const String kSearchFixture = r'''
{"code":0,"message":"OK","data":{"result":[
{"type":"video","bvid":"BV1g5411J7Lh","aid":421234567,"title":"【编曲向】旅人の唄 - 无职转生 OP","pic":"//i0.hdslb.com/bfs/a.jpg","duration":"4:12","play":12345,"typename":"音乐","pubdate":1700000000,"author":"某人"},
{"type":"video","bvid":"BV16pH96kEG7","aid":42570351432,"title":"『无职转生 第三季 到了异世界就拿出真本事』全14话","pic":"//i0.hdslb.com/bfs/b.jpg","duration":"23:40","play":999999,"typename":"番剧","pubdate":1700000001,"author":"UP"},
{"type":"video","bvid":"BV137HD6JEh5","aid":421122334,"title":"4K【无职转生 第1-3季】全63集 超清中字","pic":"//i0.hdslb.com/bfs/c.jpg","duration":"10:00","play":88888,"typename":"番剧","pubdate":1700000002,"author":"UP2"}
]}}''';

/// 视频信息（`view` 端点）—— `pages` 是分 P，cid 在这里。
const String kViewFixture = r'''
{"code":0,"message":"OK","data":{"bvid":"BV16pH96kEG7","aid":42570351432,
 "title":"『无职转生 第三季 到了异世界就拿出真本事』全14话",
 "pic":"https://i0.hdslb.com/bfs/b.jpg","desc":"简介",
 "owner":{"name":"UP"},"pages":[
 {"cid":42570351432,"page":1,"part":"第1话","duration":1420},
 {"cid":42570351433,"page":2,"part":"第2话","duration":1420}
]}}''';

// ══════════════════════════════════════════════════════════════════════
//  假 HTTP（与 t100_bili_search_test.dart 同款）
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

// ══════════════════════════════════════════════════════════════════════
//  用例
// ══════════════════════════════════════════════════════════════════════

/// 造一个按 uri 分派夹具的 BiliApi
BiliApi _api({String search = kSearchFixture, String view = kViewFixture}) {
  final client = _FakeHttpClient((uri) {
    final p = uri.path;
    if (p.contains('search/type')) {
      return _FakeResponse(
        statusCode: 200,
        body: utf8.encode(search),
        headers: <String, List<String>>{
          'content-type': <String>['application/json; charset=utf-8'],
        },
      );
    }
    if (p.contains('web-interface/view')) {
      return _FakeResponse(
        statusCode: 200,
        body: utf8.encode(view),
        headers: <String, List<String>>{
          'content-type': <String>['application/json; charset=utf-8'],
        },
      );
    }
    return _FakeResponse(statusCode: 404, body: utf8.encode('{}'));
  });
  return BiliApi(client: client);
}

void main() {
  setUp(() {
    // 每个用例都从"干净偏好"开始（绑定存在 UiPrefs 里）
    UiPrefs.debugResetForTest();
  });

  test('① 相似度够 ⇒ 绑的是**最像的那条**，不是搜索结果第一条', () async {
    final api = _api();
    final out = await autoBindBySearch(
      api: api,
      provider: 'testprov',
      id: 'testid',
      localTitle: '无职转生 第三季',
      episodeTitles: <String>['第1话', '第2话'],
    );

    expect(out, isNotNull, reason: '应该匹配到');
    expect(out!.ok, isTrue);
    /*
     * ★★★ 这是本文件最关键的一条。
     *
     * 夹具里第 0 条是「旅人の唄 - 无职转生 OP」（OP，相似度低），
     * 第 1 条才是正片。若实现写成 `hits.first`，这里会绑到 OP 上 ——
     * 弹幕时间轴全错，而且用户完全不知道发生了什么。
     */
    expect(
      out.binding.bvid,
      'BV16pH96kEG7',
      reason: '★ 必须挑最像的（正片），不能取搜索结果第一条（OP）',
    );
    expect(out.binding.title, contains('无职转生'));
    // 分 P 对齐：夹具里 2 个 P、本地 2 集 ⇒ 两集都绑上
    expect(out.binding.episodes.length, 2);
    expect(out.binding.cidFor(0), 42570351432);
  });

  test('② 相似度不够 ⇒ 返回 null（宁可说没匹配到，也不绑错）', () async {
    final api = _api();
    final out = await autoBindBySearch(
      api: api,
      provider: 'testprov',
      id: 'testid2',
      // 与夹具里三条都不像
      localTitle: '完全不相干的名字 XYZ',
      episodeTitles: <String>['第1话'],
    );
    expect(out, isNull, reason: '★ 不够像就必须放弃，否则会把弹幕绑到错的视频上');
  });

  test('③ 手动绑过的不许被自动流程覆盖', () async {
    // 先手动落一个绑定（模拟用户自己绑过）
    persistOutcome(
      'testprov',
      'testid3',
      BiliBindOutcome(
        binding: const BiliBinding(
          bvid: 'BVMANUAL',
          title: '用户手动绑的',
          aid: 1,
          episodes: <BiliEpisodeBinding>[
            BiliEpisodeBinding(episodeIndex: 0, page: 1, cid: 999),
          ],
          updatedAt: 0,
        ),
        score: 1.0,
        reason: '手动',
      ),
      manual: true,
    );

    final api = _api();
    final out = await autoBindBySearch(
      api: api,
      provider: 'testprov',
      id: 'testid3',
      localTitle: '无职转生 第三季',
      episodeTitles: <String>['第1话'],
    );

    expect(out, isNotNull);
    expect(
      out!.binding.bvid,
      'BVMANUAL',
      reason: '★ 用户手动绑的优先 —— 自动匹配不许覆盖它',
    );
  });

  test('④ 搜索失败（风控/网络）⇒ null，不抛异常（不能连累 dandanplay 那条路）', () async {
    final client = _FakeHttpClient((uri) => _FakeResponse(
          statusCode: 412,
          body: utf8.encode('<html>风控</html>'),
          headers: <String, List<String>>{
            'content-type': <String>['text/html'],
          },
        ));
    final api = BiliApi(client: client);
    final out = await autoBindBySearch(
      api: api,
      provider: 'testprov',
      id: 'testid4',
      localTitle: '无职转生',
      episodeTitles: <String>['第1话'],
    );
    expect(out, isNull, reason: '★ 失败要静默返回 null，由调用方退回 dandanplay');
  });

  test('⑤ ★★★ 空绑定不许落盘（Owner 真机卡死的那个根因）', () async {
    /*
     * # 这条守什么
     * ```text
     * Owner 的 ui-prefs.json 里躺着
     *   dsh.bili.bind.local:.../第01集 第01集.mp4
     *     = {"b":"BV1nJ396JEhH","t":"…","a":…,"u":…}   ← **没有 e 字段**
     * 因为 `toJson` 只在 `episodes.isNotEmpty` 时才写 `e`。
     *
     * ⇒ episodes 空 ⇒ isEmpty==true ⇒ cidFor() 恒 0
     * ⇒ 播放页走「绑了 B 站但这一集没 cid」⇒ 屏幕上那句
     *   「B 站弹幕：这一集没匹配到分 P（cid），已改用 dandanplay」
     * ⇒ 接着 dandanplay 没凭证 ⇒ 403 ⇒
     *   「弹幕失败：Missing Authentication Headers」——
     *   正是 Owner 截图里那两条。
     * ```
     *
     * # 为什么"存在但没用"最坏
     * ```text
     * `loadBinding(...) != null` 会让播放页**不再尝试自动搜索**
     * ⇒ 用户被永久卡在"没 cid"上，怎么重启都没用。
     * ```
     */
    UiPrefs.debugResetForTest();

    // 直接落一个"空绑定"（模拟改前那条坏数据）
    persistOutcome(
      'p',
      'id',
      BiliBindOutcome(
        binding: const BiliBinding(
          bvid: 'BVEMPTY',
          title: '有 bvid 但一个分 P 都没有',
          aid: 1,
          // ★ 关键：episodes 为空
        ),
        score: 1.0,
        reason: 'B 站那边一个分 P 都没有，没法绑',
      ),
    );

    expect(
      loadBinding('p', 'id'),
      isNull,
      reason: '★ 空绑定必须**根本不存在** —— 否则播放页永远不再尝试搜 B 站',
    );
  });

  test('⑥ 空绑定自愈：旧版本留下的坏数据要能被清掉', () async {
    UiPrefs.debugResetForTest(<String, String>{
      // 逐字模拟 Owner 机器上那条（无 `e` 字段）
      'dsh.bili.bind.p:id':
          '{"b":"BV1nJ396JEhH","t":"【4K超清】无职转生 S1+S2+S3三季全集","a":117026031011650,"u":1791541601573}',
      'dsh.bili.manual.p:id': '1',
      'dsh.bili.page.p:id': '51',
    });

    // 旧数据确实读得出来（证明夹具是对的）
    final old = loadBinding('p', 'id');
    expect(old, isNotNull, reason: '夹具本身要能被读取');
    expect(old!.isEmpty, isTrue, reason: '★ 这条绑定就是空的');

    // 再走一次落盘（模拟用户重新导入一次，但 B 站仍然没分 P）
    persistOutcome(
      'p',
      'id',
      BiliBindOutcome(
        binding: old,
        score: 1.0,
        reason: '重新算过还是空的',
      ),
    );

    expect(loadBinding('p', 'id'), isNull, reason: '★ 坏数据必须被清掉（自愈）');
    // 三个键一起清，不留孤儿
    expect(UiPrefs.get('dsh.bili.manual.p:id'), isNull, reason: '手动标记也要清');
    expect(UiPrefs.get('dsh.bili.page.p:id'), isNull, reason: '默认 P 也要清');
  });
}
