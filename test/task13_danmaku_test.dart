// task-13 ⑦ 弹幕功能单测 —— 纯 Dart，不碰 widget、不联网。
//
// 覆盖四层：
// ```text
// 1. SHA-256       公开测试向量（自己实现的摘要必须和标准一致，否则签名必错）
// 2. 解析          p 字段（出现时间,模式,颜色,用户ID）的容错 + shift 叠加
// 3. 配置          DanmakuConfig 的锁定键名、缺省值、往返读写
// 4. 轨道分配      ★ 不重叠：对时间轴密集采样，逐帧做矩形相交检测
// ```
//
// 第 4 项是验收点「不重叠」的**可计算证明**，不依赖截图肉眼看。
// 真网络那一层（403 的 X-Error-Message 原文）在 t513 真进程探针里做，
// 单测里只用假传输层，保证确定性。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 假传输层：按路径给预设响应，并把请求记下来供断言
class FakeTransport implements DanmakuTransport {
  FakeTransport(this.handler);

  final DanmakuHttpResponse Function(String method, Uri uri, Map<String, String> headers, String? body)
      handler;

  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];
  bool closed = false;

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    calls.add(<String, Object?>{
      'method': method,
      'uri': uri.toString(),
      'path': uri.path,
      'query': uri.queryParameters,
      'headers': headers,
      'body': body,
    });
    return handler(method, uri, headers, body);
  }

  @override
  void close() => closed = true;
}

DanmakuHttpResponse _json(Object o, {int status = 200, Map<String, String> headers = const {}})
    => DanmakuHttpResponse(
          statusCode: status,
          body: jsonEncode(o),
          headers: <String, String>{'content-type': 'application/json', ...headers},
        );

void main() {
  // -------------------------------------------------------------------
  group('SHA-256 公开测试向量', () {
    test('空串', () {
      expect(
        sha256Hex(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('abc', () {
      expect(
        sha256Hex('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('56 字节长串（跨分组边界）', () {
      expect(
        sha256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('中文按 UTF-8 字节算（与 PowerShell 的 .NET 实现一致）', () {
      // 期望值由本机 PowerShell 的 SHA256Managed 独立算出，不是自己算自己。
      expect(
        sha256Hex('弹幕'),
        '2591ec68705cd1eb2be7ac12db95bc944a32ea52a4454b6bc1964589fe4dde3f',
      );
    });
  });

  // -------------------------------------------------------------------
  group('弹幕解析（p 字段容错 + shift）', () {
    test('标准形态：时间,模式,颜色,用户ID', () {
      final c = DanmakuComment.parse(cid: 7, p: '12.5,1,16711680,abc123', m: '前方高能');
      expect(c, isNotNull);
      expect(c!.cid, 7);
      expect(c.time, 12.5);
      expect(c.mode, DanmakuMode.scroll);
      expect(c.color, 0xFF0000); // 16711680 = 0xFF0000 红
      expect(c.userId, 'abc123');
      expect(c.text, '前方高能');
    });

    test('模式 4 = 底部、5 = 顶部，未知值归滚动', () {
      expect(DanmakuComment.parse(cid: 1, p: '1,4,16777215,u', m: 'a')!.mode, DanmakuMode.bottom);
      expect(DanmakuComment.parse(cid: 2, p: '1,5,16777215,u', m: 'a')!.mode, DanmakuMode.top);
      expect(DanmakuComment.parse(cid: 3, p: '1,7,16777215,u', m: 'a')!.mode, DanmakuMode.scroll);
      expect(DanmakuComment.parse(cid: 4, p: '1,0,16777215,u', m: 'a')!.mode, DanmakuMode.scroll);
      expect(DanmakuMode.scroll.isFixed, isFalse);
      expect(DanmakuMode.top.isFixed, isTrue);
      expect(DanmakuMode.bottom.label, '底部');
    });

    test('只有时间也能解析（后面的段缺失用默认值）', () {
      final c = DanmakuComment.parse(cid: 9, p: '3.25', m: '只有时间');
      expect(c!.time, 3.25);
      expect(c.mode, DanmakuMode.scroll);
      expect(c.color, 0xFFFFFF);
      expect(c.userId, '');
    });

    test('颜色只留 24 位（有些源塞了超过 0xFFFFFF 的值）', () {
      final c = DanmakuComment.parse(cid: 1, p: '1,1,4294967295,u', m: 'x');
      expect(c!.color, 0xFFFFFF);
    });

    test('空文本 / 时间不是数字 -> 丢弃（返回 null）', () {
      expect(DanmakuComment.parse(cid: 1, p: '1,1,0,u', m: '   '), isNull);
      expect(DanmakuComment.parse(cid: 2, p: '不是数字,1,0,u', m: 'x'), isNull);
      expect(DanmakuComment.parse(cid: 3, p: '', m: 'x'), isNull);
    });

    test('shift 叠加：正数延后、负数提前、提前到负数直接丢', () {
      final a = DanmakuComment.parse(cid: 1, p: '10,1,0,u', m: 'x', shift: 90);
      expect(a!.time, 100);
      final b = DanmakuComment.parse(cid: 2, p: '10,1,0,u', m: 'x', shift: -4.5);
      expect(b!.time, 5.5);
      expect(DanmakuComment.parse(cid: 3, p: '2,1,0,u', m: 'x', shift: -10), isNull);
    });

    test('fromJson：cid 可以是数字也可以是字符串（int64 走 JSON 的常见形态）', () {
      final a = DanmakuComment.fromJson(<String, dynamic>{'cid': 123, 'p': '1,1,0,u', 'm': 'a'});
      expect(a!.cid, 123);
      final b = DanmakuComment.fromJson(<String, dynamic>{'cid': '456', 'p': '1,1,0,u', 'm': 'b'});
      expect(b!.cid, 456);
      expect(DanmakuComment.fromJson(<String, dynamic>{'p': '1,1,0,u', 'm': 'c'}), isNull);
    });

    test('匹配结果：label 里带上偏移，方便用户核对"匹配对不对"', () {
      final m = DanmakuMatch.fromJson(<String, dynamic>{
        'episodeId': 99,
        'animeTitle': '某番',
        'episodeTitle': '第3集',
        'shift': 90.0,
      });
      expect(m!.episodeId, 99);
      expect(m.shift, 90.0);
      expect(m.label, '某番 第3集（偏移 +90.0s）');
      final n = DanmakuMatch.fromJson(<String, dynamic>{'episodeId': 0});
      expect(n, isNull); // 0 / 负数不是合法弹幕库 ID
      final p = DanmakuMatch.fromJson(<String, dynamic>{'episodeId': 5});
      expect(p!.label, '弹幕库 #5');
    });
  });

  // -------------------------------------------------------------------
  group('配置（锁定键名 + 缺省值）', () {
    setUp(() {
      UiPrefs.debugResetForTest(<String, String>{});
    });

    test('键名就是锁定值，缺省全空 / 关闭', () {
      expect(DanmakuConfig.keyEnabled, 'dsh.danmaku.enabled');
      expect(DanmakuConfig.keyAppId, 'dsh.danmaku.appId');
      expect(DanmakuConfig.keyAppSecret, 'dsh.danmaku.appSecret');
      expect(DanmakuConfig.enabled, isFalse);
      expect(DanmakuConfig.appId, '');
      expect(DanmakuConfig.appSecret, '');
      expect(DanmakuConfig.isConfigured, isFalse);
      expect(DanmakuConfig.statusText, '弹幕已关闭');
    });

    test('开关往返：setEnabled(true) 落成 "1"，false 落成 "0"', () {
      DanmakuConfig.setEnabled(true);
      expect(UiPrefs.get(DanmakuConfig.keyEnabled), '1');
      expect(DanmakuConfig.enabled, isTrue);
      DanmakuConfig.setEnabled(false);
      expect(UiPrefs.get(DanmakuConfig.keyEnabled), '0');
      expect(DanmakuConfig.enabled, isFalse);
    });

    test('凭证往返：前后空格被裁掉，空串 -> remove（不留垃圾键）', () {
      DanmakuConfig.setAppId('  abcdefgh  ');
      DanmakuConfig.setAppSecret(' secret ');
      expect(DanmakuConfig.appId, 'abcdefgh');
      expect(DanmakuConfig.appSecret, 'secret');
      expect(DanmakuConfig.isConfigured, isTrue);
      DanmakuConfig.setAppId('   ');
      expect(DanmakuConfig.appId, '');
      expect(UiPrefs.get(DanmakuConfig.keyAppId), isNull);
      expect(DanmakuConfig.isConfigured, isFalse);
    });

    test('显示参数有范围保护，坏值回落缺省', () {
      expect(DanmakuConfig.fontScale, 1.0);
      expect(DanmakuConfig.opacity, 1.0);
      expect(DanmakuConfig.speed, 8.0);
      expect(DanmakuConfig.area, 1.0);
      DanmakuConfig.setFontScale(99);
      expect(DanmakuConfig.fontScale, DanmakuConfig.fontScaleMax);
      DanmakuConfig.setOpacity(-5);
      expect(DanmakuConfig.opacity, DanmakuConfig.opacityMin);
      UiPrefs.set(DanmakuConfig.keySpeed, '不是数字');
      expect(DanmakuConfig.speed, DanmakuConfig.defaultSpeed);
      UiPrefs.set(DanmakuConfig.keyArea, '0.5');
      expect(DanmakuConfig.area, 0.5);
    });

    test('打码后的 AppId 不泄露全文', () {
      DanmakuConfig.setAppId('abcdefghij');
      expect(DanmakuConfig.maskedAppId, 'abcd****');
      expect(DanmakuConfig.maskedAppId.contains('efghij'), isFalse);
      DanmakuConfig.setAppId('ab');
      expect(DanmakuConfig.maskedAppId, '****');
    });

    test('clearCredentials 清掉两个键', () {
      DanmakuConfig.setAppId('a');
      DanmakuConfig.setAppSecret('b');
      DanmakuConfig.clearCredentials();
      expect(DanmakuConfig.appId, '');
      expect(DanmakuConfig.appSecret, '');
    });
  });

  // -------------------------------------------------------------------
  group('HTTP 客户端（假传输层，确定性）', () {
    test('签名头：X-Signature = base64(sha256(AppId + Timestamp + Path + AppSecret))', () async {
      final fake = FakeTransport((m, u, h, b) => _json(<String, dynamic>{'success': true, 'matches': <dynamic>[]}));
      final client = DandanplayClient(
        transport: fake,
        appId: 'myid',
        appSecret: 'mysecret',
        clock: () => DateTime.fromMillisecondsSinceEpoch(1735660800 * 1000, isUtc: true),
      );
      await client.match(fileName: 'EP01');
      expect(fake.calls, hasLength(1));
      final h = fake.calls.first['headers']! as Map<String, String>;
      expect(h['X-AppId'], 'myid');
      expect(h['X-Timestamp'], '1735660800');
      // Path 必须是以斜杠开头、不含域名与查询串的小写路径
      final expectSig = sha256Base64('myid' '1735660800' '/api/v2/match' 'mysecret');
      expect(h['X-Signature'], expectSig);
      expect(fake.calls.first['method'], 'POST');
      expect(fake.calls.first['path'], '/api/v2/match');
      final body = jsonDecode(fake.calls.first['body']! as String) as Map<String, dynamic>;
      expect(body['fileName'], 'EP01');
      expect(body['matchMode'], 'fileNameOnly'); // 拿不到 fileHash 时的模式
      expect(body['fileHash'], '');
    });

    test('查询参数不进签名（官方要求 Path 不含问号后的内容）', () async {
      final fake = FakeTransport((m, u, h, b) => _json(<String, dynamic>{'success': true, 'comments': <dynamic>[]}));
      final client = DandanplayClient(
        transport: fake,
        appId: 'id1',
        appSecret: 'sec1',
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000 * 1000, isUtc: true),
      );
      await client.fetchComments(123450001);
      final call = fake.calls.first;
      expect(call['path'], '/api/v2/comment/123450001');
      expect((call['query']! as Map<String, String>)['withRelated'], 'true');
      final h = call['headers']! as Map<String, String>;
      expect(h['X-Signature'], sha256Base64('id1' '1000' '/api/v2/comment/123450001' 'sec1'));
    });

    test('403 必须带出 X-Error-Message 原文（无凭证时的真实错误面）', () async {
      final fake = FakeTransport((m, u, h, b) => const DanmakuHttpResponse(
            statusCode: 403,
            body: '',
            headers: <String, String>{'x-error-message': 'Missing Authentication Headers'},
          ));
      final client = DandanplayClient(transport: fake, appId: '', appSecret: '');
      try {
        await client.fetchComments(1);
        fail('应该抛异常');
      } on DanmakuException catch (e) {
        expect(e.statusCode, 403);
        expect(e.xErrorMessage, 'Missing Authentication Headers');
        expect(e.isAuthProblem, isTrue);
        expect(e.message.contains('Missing Authentication Headers'), isTrue);
        expect(e.detail.contains('X-Error-Message: Missing Authentication Headers'), isTrue);
      }
    });

    test('403 的原因不在正文里也能给出有用提示（正文是空的）', () async {
      final fake = FakeTransport((m, u, h, b) => const DanmakuHttpResponse(
            statusCode: 403,
            body: '',
            headers: <String, String>{'x-error-message': 'Invalid Signature'},
          ));
      final client = DandanplayClient(transport: fake, appId: 'a', appSecret: 'b');
      final e = await _capture(() => client.match(fileName: 'x'));
      expect(e!.xErrorMessage, 'Invalid Signature');
      expect(e.errorCode, 0);
    });

    test('业务错误（HTTP 200 + success:false）要带出 errorCode / errorMessage', () async {
      final fake = FakeTransport((m, u, h, b) => _json(<String, dynamic>{
            'success': false,
            'errorCode': 404,
            'errorMessage': '弹幕库不存在',
          }));
      final client = DandanplayClient(transport: fake, appId: 'a', appSecret: 'b');
      final e = await _capture(() => client.fetchComments(5));
      expect(e!.errorCode, 404);
      expect(e.errorMessage, '弹幕库不存在');
      expect(e.message.contains('弹幕库不存在'), isTrue);
    });

    test('match 解析多条结果 + shift；comment 解析并叠加 shift 且按时间排序', () async {
      final fake = FakeTransport((m, u, h, b) {
        if (u.path == '/api/v2/match') {
          return _json(<String, dynamic>{
            'success': true,
            'isMatched': true,
            'matches': <dynamic>[
              <String, dynamic>{'episodeId': 100, 'animeTitle': 'A', 'episodeTitle': 'E1', 'shift': 90.0},
              <String, dynamic>{'episodeId': 101, 'animeTitle': 'B', 'episodeTitle': 'E2'},
            ],
          });
        }
        return _json(<String, dynamic>{
          'success': true,
          'count': 3,
          'comments': <dynamic>[
            <String, dynamic>{'cid': 3, 'p': '20,1,0,u', 'm': '第三'},
            <String, dynamic>{'cid': 1, 'p': '1,1,0,u', 'm': '第一'},
            <String, dynamic>{'cid': 2, 'p': '坏数据', 'm': '应丢弃'},
          ],
        });
      });
      final client = DandanplayClient(transport: fake, appId: 'a', appSecret: 'b');
      final ms = await client.match(fileName: 'x');
      expect(ms, hasLength(2));
      expect(ms.first.episodeId, 100);
      expect(ms.first.shift, 90.0);
      final cs = await client.fetchComments(100, shift: 90);
      expect(cs, hasLength(2)); // 坏数据那条被丢掉
      expect(cs.first.time, 91); // 1 + 90
      expect(cs.last.time, 110); // 20 + 90，且排到了后面
    });

    test('loadFor：match 命中就直接取；空结果走 search 退路', () async {
      final paths = <String>[];
      final fake = FakeTransport((m, u, h, b) {
        paths.add(u.path);
        if (u.path == '/api/v2/match') {
          return _json(<String, dynamic>{'success': true, 'matches': <dynamic>[]});
        }
        if (u.path == '/api/v2/search/episodes') {
          return _json(<String, dynamic>{
            'success': true,
            'animes': <dynamic>[
              <String, dynamic>{
                'animeTitle': '搜到的番',
                'episodes': <dynamic>[
                  <String, dynamic>{'episodeId': 777, 'episodeTitle': '第1集'},
                ],
              },
            ],
          });
        }
        return _json(<String, dynamic>{
          'success': true,
          'comments': <dynamic>[<String, dynamic>{'cid': 1, 'p': '1,1,0,u', 'm': 'x'}],
        });
      });
      final client = DandanplayClient(transport: fake, appId: 'a', appSecret: 'b');
      final r = await client.loadFor(fileName: 'EP03', anime: '某番', episode: '3');
      expect(r.matchedBy, 'search');
      expect(r.match!.episodeId, 777);
      expect(r.comments, hasLength(1));
      expect(paths, <String>['/api/v2/match', '/api/v2/search/episodes', '/api/v2/comment/777']);
    });

    test('loadFor：两条都匹配不到 -> 明确抛错（不要静默返回空）', () async {
      final fake = FakeTransport((m, u, h, b) {
        if (u.path == '/api/v2/match') return _json(<String, dynamic>{'success': true, 'matches': <dynamic>[]});
        return _json(<String, dynamic>{'success': true, 'animes': <dynamic>[]});
      });
      final client = DandanplayClient(transport: fake, appId: 'a', appSecret: 'b');
      final e = await _capture(() => client.loadFor(fileName: 'nothing'));
      expect(e, isNotNull);
      expect(e!.message.contains('没有匹配到弹幕库'), isTrue);
    });

    test('close 会透传到传输层', () {
      final fake = FakeTransport((m, u, h, b) => _json(<String, dynamic>{'success': true}));
      DandanplayClient(transport: fake).close();
      expect(fake.closed, isTrue);
    });
  });

  // -------------------------------------------------------------------
  group('轨道分配：不重叠（可计算证明，不靠肉眼）', () {
    const double w = 640;
    const double h = 480;
    const double fs = 20;

    List<DanmakuComment> make(int n, {DanmakuMode mode = DanmakuMode.scroll, double step = 0.3}) {
      return List<DanmakuComment>.generate(n, (i) {
        final c = DanmakuComment.parse(
          cid: i,
          p: '${(i * step).toStringAsFixed(2)},1,16777215,u',
          m: '第$i条弹幕内容',
        );
        if (c == null) throw StateError('构造失败');
        return mode == DanmakuMode.scroll
            ? c
            : DanmakuComment.parse(
                cid: i,
                p: '${(i * step).toStringAsFixed(2)},${mode == DanmakuMode.bottom ? '4' : '5'},16777215,u',
                m: '第$i条弹幕内容',
              )!;
      });
    }

    /// 逐帧两两相交检测；返回第一处相交的描述（没有就是 null）
    String? firstOverlap(DanmakuLayout layout, {double until = 30, int steps = 900}) {
      for (var i = 0; i <= steps; i++) {
        final t = until * i / steps;
        final boxes = layout.boxesAt(t);
        for (var a = 0; a < boxes.length; a++) {
          for (var b = a + 1; b < boxes.length; b++) {
            if (boxes[a].overlaps(boxes[b])) {
              return 't=${t.toStringAsFixed(2)} ${boxes[a].toString()} x ${boxes[b].toString()}';
            }
          }
        }
      }
      return null;
    }

    test('轨道数 = 可用高度 / 行高（向下取整），行高 = 字号 * 1.35', () {
      final l = DanmakuTrackAllocator.layout(
        comments: const <DanmakuComment>[],
        canvasWidth: w,
        canvasHeight: h,
        fontSize: fs,
      );
      expect(l.lineHeight, closeTo(27.0, 0.001));
      expect(l.laneCount, 17); // floor(480 / 27)
      expect(l.isEmpty, isTrue);
      expect(l.dropped, 0);
    });

    test('area 只占一部分高度时轨道数按比例减少', () {
      final l = DanmakuTrackAllocator.layout(
        comments: const <DanmakuComment>[],
        canvasWidth: w,
        canvasHeight: h,
        fontSize: fs,
        area: 0.5,
      );
      expect(l.laneCount, 8); // floor(240 / 27)
    });

    test('★ 60 条密集滚动弹幕：900 帧逐帧两两检测，零相交', () {
      final l = DanmakuTrackAllocator.layout(
        comments: make(60),
        canvasWidth: w,
        canvasHeight: h,
        fontSize: fs,
        speed: 120,
      );
      expect(l.length, 60);
      expect(l.dropped, 0);
      expect(firstOverlap(l), isNull);
    });

    test('★ 顶部 + 底部 + 滚动混排：依然零相交', () {
      // step 取 1.0s：让 60 条**全都排得下**（密度不够时 allocator 会如实丢弃，
      // 那条路径由下面「轨道不够」的用例单独证明）。本条只证明一件事：混排也不相交。
      final all = <DanmakuComment>[
        ...make(20, step: 1.0),
        ...make(20, mode: DanmakuMode.top, step: 1.0),
        ...make(20, mode: DanmakuMode.bottom, step: 1.0),
      ]..sort((a, b) => a.time.compareTo(b.time));
      final l = DanmakuTrackAllocator.layout(
        comments: all,
        canvasWidth: w,
        canvasHeight: h,
        fontSize: fs,
        speed: 120,
      );
      expect(l.length, 60);
      expect(l.dropped, 0);
      expect(firstOverlap(l), isNull);
    });

    test('同轨道的两条滚动弹幕：后一条进画时，前一条已经整体进画 + 留出 gap', () {
      final l = DanmakuTrackAllocator.layout(
        comments: make(40, step: 0.1),
        canvasWidth: w,
        canvasHeight: h,
        fontSize: fs,
        speed: 120,
        gap: 24,
      );
      // ★ 关键：allocator 会把**时间上不相邻**的弹幕塞进同一条轨道（上一条走开后再复用），
      //   所以这里必须按轨道分组、比同一条轨道内的前后两条，而不是比全局相邻的两条。
      final byLane = <int, List<DanmakuPlacement>>{};
      for (final p in l.placements) {
        byLane.putIfAbsent(p.lane, () => <DanmakuPlacement>[]).add(p);
      }
      var pairs = 0;
      for (final entry in byLane.entries) {
        final lane = entry.value;
        for (var i = 1; i < lane.length; i++) {
          final prev = lane[i - 1];
          final cur = lane[i];
          pairs++;
          final a = prev.boxAt(cur.enterAt, w, l.lineHeight);
          final b = cur.boxAt(cur.enterAt, w, l.lineHeight);
          expect(a.right + 24, lessThanOrEqualTo(b.left + 0.001),
              reason: '轨道 ${entry.key.toString()} 的第 $i 次复用');
        }
      }
      expect(pairs, greaterThan(0), reason: '这组参数必须真的出现同轨道前后两条，否则本条断言是空转');
    });

    test('底部固定从下往上排（第一条待在最下面那条轨道）', () {
      final l = DanmakuTrackAllocator.layout(
        comments: make(3, mode: DanmakuMode.bottom, step: 0.2),
        canvasWidth: w,
        canvasHeight: h,
        fontSize: fs,
      );
      expect(l.placements[0].lane, l.laneCount - 1);
      expect(l.placements[1].lane, l.laneCount - 2);
      expect(l.placements[0].fixed, isTrue);
      expect(l.placements[0].speed, 0);
    });

    test('顶部固定从上往下排', () {
      final l = DanmakuTrackAllocator.layout(
        comments: make(3, mode: DanmakuMode.top, step: 0.2),
        canvasWidth: w,
        canvasHeight: h,
        fontSize: fs,
      );
      expect(l.placements[0].lane, 0);
      expect(l.placements[1].lane, 1);
    });

    test('固定弹幕水平居中（不随 time 平移）', () {
      final l = DanmakuTrackAllocator.layout(
        comments: make(1, mode: DanmakuMode.top),
        canvasWidth: w,
        canvasHeight: h,
        fontSize: fs,
      );
      final p = l.placements.first;
      final a = p.boxAt(p.enterAt + 0.1, w, l.lineHeight);
      final b = p.boxAt(p.enterAt + 3.0, w, l.lineHeight);
      expect(a.left, b.left);
      expect(a.left, closeTo((w - p.width) / 2, 0.001));
    });

    test('滚动弹幕从右边进、往左走，到 -width 出画', () {
      final l = DanmakuTrackAllocator.layout(
        comments: make(1),
        canvasWidth: w,
        canvasHeight: h,
        fontSize: fs,
        speed: 120,
      );
      final p = l.placements.first;
      expect(p.boxAt(p.enterAt, w, l.lineHeight).left, closeTo(w, 0.001));
      expect(p.boxAt(p.exitAt, w, l.lineHeight).left, closeTo(-p.width, 0.001));
      expect(p.visibleAt(p.enterAt - 0.1), isFalse);
      expect(p.visibleAt(p.enterAt + 0.1), isTrue);
      expect(p.visibleAt(p.exitAt + 0.1), isFalse);
    });

    test('轨道不够时如实计入 dropped（不静默丢）', () {
      final l = DanmakuTrackAllocator.layout(
        comments: make(30, step: 0.0), // 30 条同一时刻
        canvasWidth: w,
        canvasHeight: 60, // 只有 floor(60/27) = 2 条轨道
        fontSize: fs,
      );
      expect(l.laneCount, 2);
      expect(l.length, 2);
      expect(l.dropped, 28);
      expect(l.summary.contains('丢弃 28 条'), isTrue);
    });

    test('文本宽度估算：越长越宽，同字数中文比英文宽', () {
      expect(estimateTextWidth('短', fs), lessThan(estimateTextWidth('长一些的文本', fs)));
      expect(estimateTextWidth('abcd', fs), lessThan(estimateTextWidth('中文四字', fs)));
      expect(estimateTextWidth('', fs), 0);
    });
  });

}

/// 捕获一个 DanmakuException（没有抛出就返回 null）
Future<DanmakuException?> _capture(Future<void> Function() body) async {
  try {
    await body();
    return null;
  } on DanmakuException catch (e) {
    return e;
  }
}
