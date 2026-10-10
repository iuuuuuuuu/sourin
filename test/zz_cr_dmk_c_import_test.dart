// ═══════════════════════════════════════════════════════════════════════
//  ★★★ OPS-10 ⑤ C：B 站弹幕导入之后**一句话都没有**（Owner 第 3 条）
// ═══════════════════════════════════════════════════════════════════════
//
//  # Owner 报（第 3 条，逐字）
//  ```text
//  > 导入之后没有任何提示，返回播放页还是没有弹幕
//  ```
//
//  # 这里证什么（每条都标了"改前红在哪"）
//  ```text
//  ① 导入成功 ⇒ 画面上**真的**出现一句可读的结果（源名 + 多少条）
//       改前红在：`_biliApplyComments` 成功支只有四行 setState，
//                 **一个 _flash 都没有** ⇒ tip == null ⇒ isNotNull 失败。
//
//  ② 导入成功 ⇒ 播放页的弹幕数立刻变成导入的条数（不是 UI 假象）
//       这一条改前就是绿的 —— 故意留着：它证明"上屏"与"提示"是两件事，
//       改后不许把已经好的那条弄坏（回归）。
//
//  ③ 现象 A：B 站取弹幕失败 ⇒ 角标先出现，**随后自己消失**
//       改前红在：`_loadBiliDanmaku` 的失败支（player_page.dart:5320-5334）
//                 只写 `_danmakuError`，**没写 `_danmakuErrorAt`**、
//                 也没起计时器 ⇒ `_danmakuBadge` 那条寿命判据恒为 false
//                 （:4932-4936）⇒ 角标永远画着 = Owner 说的"一直不消失"。
//
//  ④ ⑤ 后半句：导入完**回到播放页** ⇒ 这一集真的用上弹幕
//       改前红在：`_loadDanmakuNamed` 第 2 行就是 `if (!_danmakuEnabled) return;`
//                 （:4545），而弹幕开关出厂是**关**（core/danmaku.dart:19）
//                 ⇒ 有 B 站绑定也照样 return ⇒ 用户看到"导入成功了还是没弹幕"。
//  ```
//
//  # 仪器关键（第一版就是死在这里）
//  ```text
//  本文件全部走**真异步**（假 HttpClient 的 Future 链 + `_flash` 的 1.2 秒
//  Timer + 角标那个 8 秒寿命），而 `testWidgets` 的测试体跑在 **FakeAsync
//  zone** 里 ⇒ 真 Timer / 真 I/O 在里面**永远不推进**。
//  仓内实测先例：test/task18_entry_test.dart:31、test/zz_t53s_settings_live_toggle_test.dart:52
//  （"裸 await 真异步 ⇒ TimeoutException after 0:10:00.000000"）。
//  ⇒ 一律 `t.runAsync(...)`；`pumpWidget`/`pump` **不**放进 runAsync。
//
//  ⚠️ 现象 A 那条（③）必须**真等 8.5 秒墙钟**：生产判据是
//     `DateTime.now().difference(_danmakuErrorAt) > 8s`（:4932-4936），
//     而 `t.pump(Duration)` 只推**假时钟**、墙钟几乎不动 ⇒ 用 pump 等
//     是**假绿**（改前改后都不会消失，测出来的是仪器，不是产品）。
//  ```
//
//  # 为什么单测一个网络包都不发
//  ```text
//  BiliApi 的构造器收 HttpClient（lib/core/bili/bili_api.dart:349-354）
//  ⇒ 换掉 socket，整条链（解析 → view → 弹幕 XML → 落盘 → 上屏）跑的都是
//    **生产代码**。手法与 test/zz_t31_autobind_test.dart 同款。
//  ```
//
//  必备运行参数：
//    --run-skipped --tags native-media --concurrency=1

@Tags(['native-media'])

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/bili/bili_bind.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

// ── 夹具（真实响应形状，2026-10-10）─────────────────────────────────

/// 视频信息：2 个分 P。
const String kView = '{"code":0,"message":"0","data":{"bvid":"BV16pH96kEG7",'
    '"aid":42570351432,"title":"某番 全2话","pages":['
    '{"cid":42570351432,"page":1,"part":"第1话","duration":1420},'
    '{"cid":42570351433,"page":2,"part":"第2话","duration":1420}]}}';

/// 弹幕 XML：p 属性是 B 站那 9 段（颜色在第 3 段）。
const String kXml =
    '<?xml version="1.0" encoding="UTF-8"?><i>'
    '<d p="11,1.5,25,16777215,1,25,0,0,0">第一条</d>'
    '<d p="22,2.5,26,16777215,1,26,0,0,0">第二条</d>'
    '<d p="33,3.5,27,16777215,1,27,0,0,0">第三条</d>'
    '</i>';

/// 第一集绑的那个 cid（与 kView 的 page=1 对齐）。
const int kCid = 42570351432;

// ── 假 HTTP 栈（与 test/zz_t31_autobind_test.dart 同款）──────────────

class _FakeHeaders implements HttpHeaders {
  _FakeHeaders([Map<String, List<String>>? seed]) : _m = <String, List<String>>{...?seed};
  final Map<String, List<String>> _m;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _m[name.toLowerCase()] = <String>[value.toString()];
  }
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _m.putIfAbsent(name.toLowerCase(), () => <String>[]).add(value.toString());
  }
  @override
  List<String>? operator [](String name) => _m[name.toLowerCase()];
  @override
  String? value(String name) {
    final v = _m[name.toLowerCase()];
    return (v == null || v.isEmpty) ? null : v.first;
  }
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw StateError('假 HttpHeaders 不支持：${i.memberName}');
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse({required this.statusCode, required this.body, Map<String, List<String>>? headers})
      : _headers = _FakeHeaders(headers);
  @override
  final int statusCode;
  final List<int> body;
  final _FakeHeaders _headers;
  @override
  HttpHeaders get headers => _headers;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream<List<int>>.value(body).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw StateError('假 HttpClientResponse 不支持：${i.memberName}');
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.uri, this._response);
  @override
  final Uri uri;
  final _FakeResponse _response;
  /// ★ BiliApi._get 第一步就是 req.headers.set(referer/user-agent/accept)
  ///   （lib/core/bili/bili_api.dart:391-393）—— 少了它，假 request 的
  ///   noSuchMethod 会直接抛，整个导入链在发请求前就断了。
  final _FakeHeaders sentHeaders = _FakeHeaders();
  @override
  HttpHeaders get headers => sentHeaders;
  @override
  Future<HttpClientResponse> close() async => _response;
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw StateError('假 HttpClientRequest 不支持：${i.memberName}');
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._respond);
  final _FakeResponse Function(Uri uri) _respond;
  final List<Uri> uris = <Uri>[];
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    uris.add(url);
    return _FakeRequest(url, _respond(url));
  }
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw StateError('单测不许用真 HttpClient（成员：${i.memberName}）');
}

/// 正常的 B 站应答：view 200 + 弹幕 XML 200。
_FakeResponse _ok(Uri uri) {
  if (uri.path.contains('web-interface/view')) {
    return _FakeResponse(
        statusCode: 200,
        body: utf8.encode(kView),
        headers: <String, List<String>>{
          'content-type': <String>['application/json; charset=utf-8']
        });
  }
  if (uri.host.contains('comment.bilibili.com')) {
    return _FakeResponse(
        statusCode: 200,
        body: utf8.encode(kXml),
        headers: <String, List<String>>{
          'content-type': <String>['text/xml; charset=utf-8']
        });
  }
  return _FakeResponse(statusCode: 404, body: utf8.encode('{}'));
}

// ── 真树夹具 ──────────────────────────────────────────────────────────

List<Episode> fakeEpisodes(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(id: 'ep$i', title: '第$i集', url: 'https://example.invalid/$i.m3u8'),
    ];

Future<void> mountPlayer(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '弹幕导入回归',
        episodes: fakeEpisodes(5),
        episodeIndex: 0,
        episodeId: 'ep1',
        episodeTitle: '第1集',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
}

Future<void> drain(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
}

/// ★ 让**真**时间流逝（不是 pump 的假时钟）—— 见文件头「仪器关键」。
Future<void> realWait(WidgetTester t, Duration d) async {
  await t.runAsync(() => Future<void>.delayed(d));
  await t.pump();
}

/// ★★★ 收尾配方（与 test/zz_t3_flash_probe_test.dart:171-176 同款，
///     少了这一步整个进程 exit=1：episode_strip.dart:1209 的 dispose
///     会从已失活元素上找 MediaQuery）
Future<void> finish(WidgetTester t) async {
  await t.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await drain(t);
  expect(t.takeException(), isNull);
}

/// 第一集那份绑定（与 kView 的 page=1 对齐）—— 走**生产** saveBinding。
void saveFirstEpisodeBinding() {
  saveBinding(
    'cctv',
    'cctv1',
    const BiliBinding(
      bvid: 'BV16pH96kEG7',
      title: '某番 全2话',
      aid: 42570351432,
      episodes: <BiliEpisodeBinding>[
        BiliEpisodeBinding(
          episodeIndex: 0,
          page: 1,
          cid: kCid,
          part: '第1话',
        ),
      ],
      manual: true,
      updatedAt: 1,
    ),
  );
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() {
    RemoteBridge.instance.stop();
    // ★ 每个用例都从**干净的偏好**开始：本文件有两条用例会真的落盘
    //   （探针的 persistOutcome / saveBinding），不隔离就会互相顶掉。
    //   `debugResetForTest()` 把 `_file` 也置空 ⇒ flush() 直接返回，无真 I/O。
    UiPrefs.debugResetForTest();
  });
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('★★★ ① 导入成功 ⇒ 真的说了一句可读结果（源名 + 条数）', (t) async {
    await mountPlayer(t);

    final n = await t.runAsync(() => debugPlayerBiliImportForProbe(
          input: 'BV16pH96kEG7',
          page: 0,
          fake: _FakeHttpClient(_ok),
        ));
    await t.pump();

    // ── ② 上屏（改前就是绿的，留着当回归）──────────────────────────
    expect(n, isPositive, reason: '★★★ 导入之后弹幕必须**真的**取到（不是 UI 假象）');
    expect(debugPlayerDanmakuCount(), n,
        reason: '★★★ 渲染层拿到的就是刚导入的那一批');

    // ── ① 提示（改前红在这里：一个 _flash 都没有）──────────────────
    final tip = debugPlayerFlashForProbeText();
    expect(tip, isNotNull, reason: '★★★ 导入成功必须有一句提示（改前一个字都没有）');
    expect(tip, contains('3'), reason: '★ 必须说清多少条：$tip');
    expect(tip, contains('B 站'), reason: '★ 必须说清这是哪个源的弹幕：$tip');

    /*
     * ★ OPS-10 B：「UI 上如实反映实际用的是哪个源的弹幕」
     *
     * `res.summary` 自己只有「新增 N 条，共 M 条」/「某番 第 3 集 · 842 条弹幕」，
     * **两条路都不含源名** ⇒ 用户分不清这些弹幕是 B 站给的还是 dandanplay 给的，
     * 而 B 站不要凭证、dandanplay 要 —— 这正是他排错时要分清的那件事。
     * 读的是**生产写进面板读数**的那个字段（`_danmakuStatus`），不是测试自己拼的。
     */
    final status = debugPlayerDanmakuStatus();
    expect(status, isNotNull);
    expect(status, startsWith('B 站 · '),
        reason: '★★ 面板读数必须点名来源，否则「如实反映来源」是空话：$status');
    debugPrint('[DMK-C] ① 导入后提示条 = $tip（共 $n 条上屏）');

    // ★ 这句话必须**真的画在树上**（不是只写进了 _tip 字段）
    expect(find.text(tip!), findsOneWidget,
        reason: '★★★ 提示条必须真的被 _TipBubble 画出来（字段写了没人画 = 用户看不见）');

    // 等真 1.2 秒让它自己走掉（_flash 的既有行为），别把真 Timer 留到收尾
    await realWait(t, const Duration(milliseconds: 1400));
    await finish(t);
  });

  testWidgets('★★★ ③ 现象 A：B 站取弹幕失败 ⇒ 角标先出现，随后自己消失', (t) async {
    await mountPlayer(t);

    // 一个必然失败的 B 站接口（500）⇒ updateDanmaku 返回 error 非空
    final err = await t.runAsync(() => debugPlayerBiliLoadForProbe(
          cid: kCid,
          fake: _FakeHttpClient(
              (uri) => _FakeResponse(statusCode: 500, body: utf8.encode('{}'))),
        ));
    await t.pump();
    expect(err, isNotEmpty, reason: '★ 前置条件：这一趟确实失败了');

    debugPrint('[DMK-C] ③ 诊断：controlsVisible=' +
        '${debugPlayerControlsVisibleForProbe()} ' +
        'error=${debugPlayerDanmakuError()} ' +
        'badge=${debugPlayerDanmakuBadgeForProbe()}');

    // ★ 前置条件：弹幕开关是**关**的（与用户真机一致）—— 改前正是这道门
    //   把失败角标一起挡掉了（player_page.dart:4912）。
    expect(debugPlayerDanmakuEnabledForProbe(), isFalse,
        reason: '★ 前置条件：没开弹幕，正是用户报那条时的状态');

    final badge = debugPlayerDanmakuBadgeForProbe();
    expect(badge, isNotNull, reason: '★ 刚失败时必须看得见（这不是缺陷）');
    expect(badge, startsWith('弹幕失败'), reason: '★ 角标说的就是这件事：$badge');
    debugPrint('[DMK-C] ③ 失败角标（刚失败）= $badge');

    // ★★★ 缺陷所在：改前 `_danmakuErrorAt` 是 null ⇒ 这条判据恒为 false
    //     ⇒ 角标**永远**画着（Owner：「这个失败提示一直不消失」）。
    // ⚠️ 必须真等墙钟 8.5 秒：生产判据是 DateTime.now() 的差值。
    await realWait(t, const Duration(milliseconds: 8500));
    expect(debugPlayerDanmakuBadgeForProbe(), isNull,
        reason: '★★★ 失败角标必须会自己消失（改前它常驻）');

    await finish(t);
  });

  testWidgets('★★★ ④ ⑤后半：导入完回到播放页 ⇒ 这一集真的用上弹幕', (t) async {
    // 真机上这一步发生在**上一次**会话里（用户点完「导入并绑定」）——
    // 这里直接用生产 saveBinding 把那份绑定放进去。
    saveFirstEpisodeBinding();
    await mountPlayer(t);

    expect(debugPlayerDanmakuEnabledForProbe(), isFalse,
        reason: '★ 前置条件：弹幕开关是**出厂值（关）** —— 这正是改前挡住整条路的那道门');
    expect(debugPlayerDanmakuCount(), 0, reason: '★ 前置条件：此刻一条都没有');

    final n = await t.runAsync(
        () => debugPlayerReloadDanmakuForProbe(fake: _FakeHttpClient(_ok)));
    await t.pump();

    expect(n, isPositive,
        reason: '★★★ 有绑定 + 有 cid ⇒ 回到播放页这一集必须真的取到弹幕'
            '（改前被 `if (!_danmakuEnabled) return;` 挡在门外 ⇒ 这里恒为 0）');
    expect(debugPlayerDanmakuCount(), n);
    expect(debugPlayerDanmakuEnabledForProbe(), isTrue,
        reason: '★ 取回来了 ⇒ 开关也该真的打开（用户不需要再去点一次）');
    debugPrint('[DMK-C] ④ 回到播放页取到 $n 条（开关已打开）');

    await finish(t);
  });

  testWidgets('★★ ⑤ 导入失败 ⇒ 说清原因，不许沉默', (t) async {
    await mountPlayer(t);

    await t.runAsync(() => debugPlayerBiliImportForProbe(
          input: '这不是一个链接',
          page: 0,
          fake: _FakeHttpClient(
              (uri) => _FakeResponse(statusCode: 500, body: utf8.encode('{}'))),
        ));
    await t.pump();

    final tip = debugPlayerFlashForProbeText();
    expect(tip, isNotNull, reason: '★★ 导入失败也必须有提示');
    expect(tip, contains('没认出'), reason: '★ 必须说清为什么：$tip');
    debugPrint('[DMK-C] ⑤ 失败提示条 = $tip');

    await realWait(t, const Duration(milliseconds: 1400));
    await finish(t);
  });
}
