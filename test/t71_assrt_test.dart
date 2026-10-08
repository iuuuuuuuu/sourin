// ═══════════════════════════════════════════════════════════════════════
//  task-29⑤ 射手字幕（assrt.net）接入 —— 真样本回归守卫
// ═══════════════════════════════════════════════════════════════════════
//
// # 这一层守什么
//
// 站点侧有两个**反直觉**的事实，任何一条被写错都会让功能悄悄失灵：
//
// ① 下载链接的**扩展名不可信**
//    GET /download/646901/....zip -> 2681242 B，头 8 字节 52 61 72 21 1a 07 01 00
//    = Rar!\x1a\x07\x01\x00（RAR5），**不是** PK。
//    ⇒ 判类型必须读魔数。本测试直接用**真实下载到的字节**断言。
//
// ② 失败**不一定**是非 200
//    /download/<不存在的 id> -> 493 + text/xml 错误页（831 B）
//    CDN 无签名 URL -> 302 -> /download/failed/<b64> -> 492
//    但站点也可能 200 + XML 错误页正文 ⇒ 两种都要判。
//    ⇒ 本测试用**本地 HttpServer** 把这两种形态喂给真实客户端。
//
// # 样本从哪来
//
// 全部是**真实抓取**、逐字节落盘的：
//   .probe/assrt/search_huoying.html  32050 B  真实搜索页（火影，15 条）
//   .probe/assrt/detail_663565.html  150695 B  真实详情页（384 个文件）
//   .probe/assrt/arch_663565.rar     7457646 B RAR5（真实字幕包）
//   .probe/assrt/zip_try.bin         2681242 B **名字是 .zip、内容是 RAR5**
//   .probe/assrt/direct_714927.ass     29748 B 真实 ASS 文本
//   .probe/assrt/cdn_noq.bin             869 B 492 错误页
//
// 样本缺失时**跳过并打印原因**，不伪装成通过（见 skipReason 的用法）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/assrt/archive.dart';
import 'package:sourin_spike/core/assrt/assrt_api.dart';
import 'package:sourin_spike/core/assrt/subtitle_store.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/subtitle/subtitle_panel.dart';

/// 拼路径（不依赖手写分隔符）
String j(String dir, String name) => '$dir${Platform.pathSeparator}$name';

/// 剥掉注释 —— 本项目踩过「注释让测试假绿」至少四次
String stripComments(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    if (s.startsWith('//', i)) {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
    } else if (s.startsWith('/*', i)) {
      i += 2;
      while (i < s.length && !s.startsWith('*/', i)) {
        i++;
      }
      i += 2;
    } else {
      out.write(s[i]);
      i++;
    }
  }
  return out.toString();
}

// ── 真实样本 ───────────────────────────────────────────────────────────
File sample(String name) => File(j('.probe/assrt', name));

/// 样本在不在？不在就**跳过并说明**（不静默通过）
String? skipReason(List<String> names) {
  final missing = names.where((n) => !sample(n).existsSync()).toList();
  if (missing.isEmpty) return null;
  return '缺少真实样本：${missing.join('、')}（应先跑 .probe/assrt 的抓取）';
}

List<int> sampleBytes(String name) => sample(name).readAsBytesSync();
String sampleText(String name) => sample(name).readAsStringSync();

// ── 手搓 zip（用来证明解压真的能解，而不是"看起来能解"）───────────────
/// 造一个 zip。deflate=true 时用 method 8（真压缩），否则 method 0（存储）。
///
/// 用 [crc32]（archive.dart 里那份）算校验和 —— 解压侧也用它校验，
/// 所以这里必须**独立**算对，否则两侧一起错还能互相"验证"通过。
Uint8List buildZip(
  List<(String, List<int>)> entries, {
  bool deflate = false,
  int? corruptCrcFor,
}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  final offsets = <int>[];
  final crcs = <int>[];
  final comps = <List<int>>[];

  for (var i = 0; i < entries.length; i++) {
    final (name, data) = entries[i];
    final nameBytes = utf8.encode(name);
    final rawData = deflate ? ZLibEncoder(raw: true).convert(data) : data;
    var crc = crc32(data);
    if (corruptCrcFor == i) crc = (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
    offsets.add(out.length);
    crcs.add(crc);
    comps.add(rawData);

    final h = BytesBuilder();
    h.add(<int>[0x50, 0x4B, 0x03, 0x04]); // local header
    h.add(<int>[20, 0]); // version
    h.add(<int>[0x08, 0x00]); // flags: bit 11 = UTF-8 名
    h.add(<int>[deflate ? 8 : 0, 0]); // method
    h.add(<int>[0, 0, 0, 0]); // time+date
    h.add(_le32(crc));
    h.add(_le32(rawData.length));
    h.add(_le32(data.length));
    h.add(_le16(nameBytes.length));
    h.add(<int>[0, 0]); // extra len
    h.add(nameBytes);
    h.add(rawData);
    out.add(h.takeBytes());
  }

  final cdStart = out.length;
  for (var i = 0; i < entries.length; i++) {
    final nameBytes = utf8.encode(entries[i].$1);
    final c = BytesBuilder();
    c.add(<int>[0x50, 0x4B, 0x01, 0x02]); // central dir header
    c.add(<int>[20, 0, 20, 0]);
    c.add(<int>[0x08, 0x00]);
    c.add(<int>[deflate ? 8 : 0, 0]);
    c.add(<int>[0, 0, 0, 0]);
    c.add(_le32(crcs[i]));
    c.add(_le32(comps[i].length));
    c.add(_le32(entries[i].$2.length));
    c.add(_le16(nameBytes.length));
    c.add(<int>[0, 0]); // extra
    c.add(<int>[0, 0]); // comment
    c.add(<int>[0, 0]); // disk
    c.add(<int>[0, 0]); // internal attrs
    c.add(<int>[0, 0, 0, 0]); // external attrs
    c.add(_le32(offsets[i]));
    c.add(nameBytes);
    central.add(c.takeBytes());
  }
  out.add(central.takeBytes());
  final cdBytes = central.length;
  out.add(<int>[
    0x50, 0x4B, 0x05, 0x06, // EOCD
    0, 0, 0, 0,
    ..._le16(entries.length),
    ..._le16(entries.length),
    ..._le32(cdBytes),
    ..._le32(cdStart),
    0, 0,
  ]);
  return out.takeBytes();
}

List<int> _le16(int v) => <int>[v & 0xFF, (v >> 8) & 0xFF];
List<int> _le32(int v) =>
    <int>[v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

// ── 假传输（给面板与客户端用，不碰网）────────────────────────────────
class _FakeTransport implements AssrtTransport {
  _FakeTransport(this.routes);

  /// path -> (status, contentType, body)
  final Map<String, (int, String, List<int>)> routes;

  /// path -> 额外的响应头（默认没有）
  final Map<String, Map<String, String>> extraHeaders =
      <String, Map<String, String>>{};
  final List<Map<String, String>> seenHeaders = <Map<String, String>>[];
  final List<Uri> seenUris = <Uri>[];

  @override
  Future<AssrtHttpResponse> get(Uri uri,
      {Map<String, String> headers = const <String, String>{}}) async {
    seenUris.add(uri);
    seenHeaders.add(Map<String, String>.from(headers));
    final r = routes[uri.path] ?? routes['*'];
    if (r == null) {
      return AssrtHttpResponse(
          statusCode: 404, bytes: utf8.encode('nope'), headers: const {});
    }
    return AssrtHttpResponse(
      statusCode: r.$1,
      bytes: r.$3,
      headers: <String, String>{
        'content-type': r.$2,
        ...?extraHeaders[uri.path],
      },
      finalUrl: uri.toString(),
    );
  }

  @override
  void close() {}
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 为什么必须把真 HttpClient 装回去（本仓实测踩坑，不是可选项）
// ═══════════════════════════════════════════════════════════════════════
//
// flutter_test 的 TestWidgetsFlutterBinding 会把**全局** HttpClient 换成
// flutter_test/lib/src/_binding_io.dart 的 _MockHttpOverrides：
// **所有**请求直接回 HTTP 400，**一个字节都不发出去**。
//
// 后果（本次实测，第一次跑 t71 时就是这样）：
//   「下载请求真的带上了 Referer」→ 收到 400，断言红
//   「493 + text/xml -> 抛异常」→ 实际抛的是「下载失败：HTTP 400」，断言红
//   —— 代码是对的，红的是测试环境。
//
// ⚠️ 只对回环地址放行，别的 host 一律抛 SocketException：
//    这样即使以后误加了真外网地址，测试也不会偷偷联网（不 flaky、不泄流量）。
//    （这份包装照抄 test/t69_dlna_test.dart:56-156，同一条理由。）
class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _LoopbackOnlyHttpClient(super.createHttpClient(context));
}

class _LoopbackOnlyHttpClient implements HttpClient {
  _LoopbackOnlyHttpClient(this._inner);

  final HttpClient _inner;

  static bool _isLoopback(Uri url) {
    final h = url.host;
    return h == '127.0.0.1' || h == 'localhost' || h == '::1';
  }

  HttpClientRequest _guard(HttpClientRequest req) {
    if (_isLoopback(req.uri)) return req;
    throw SocketException('t71 只允许访问本机回环地址，拒绝了：${req.uri}');
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
  bool Function(X509Certificate cert, String host, int port)?
      badCertificateCallback;
  @override
  void Function(String line)? keyLog;
  @override
  String Function(Uri url)? findProxy;
  @override
  Future<ConnectionTask<Socket>> Function(
      Uri url, String? proxyHost, int? proxyPort)? connectionFactory;
  @override
  Future<bool> Function(Uri url, String scheme, String realm)? authenticate;
  @override
  Future<bool> Function(
      String host, int port, String scheme, String realm)? authenticateProxy;

  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) {}
  @override
  void addProxyCredentials(
      String host, int port, String realm, HttpClientCredentials credentials) {}

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
  Future<HttpClientRequest> deleteUrl(Uri url) async =>
      _guard(await _inner.deleteUrl(url));
  @override
  Future<HttpClientRequest> headUrl(Uri url) async => _guard(await _inner.headUrl(url));
  @override
  Future<HttpClientRequest> patchUrl(Uri url) async =>
      _guard(await _inner.patchUrl(url));

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ★ 装回真 HttpClient（理由见上面那段注释）
  // 实测教训（t69 留下的）：HttpOverrides.runZoned 传不进用例体
  // （用例体在 package:test 自己新建的 zone 里跑）⇒ 只能改 global。
  HttpOverrides.global = _RealHttpOverrides();
  setUp(() => HttpOverrides.global = _RealHttpOverrides());

  // ═══ ① 真实搜索页解析 ═══════════════════════════════════════════════
  group('搜索页解析（真实样本）', () {
    test('解析出 15 条，且不把 top-banner 广告位当成结果', () {
      final why = skipReason(<String>['search_huoying.html']);
      if (why != null) {
        markTestSkipped(why);
        return;
      }
      final html = sampleText('search_huoying.html');
      final list = parseSearchHtml(html);

      // 站点自己声明每页 15 条；用 subitem 切会多出 banner（18 段）
      expect(list.length, 15,
          reason: '真实页每页 15 条；若变成 16+ 说明把广告位/别的块也算进来了');

      for (final s in list) {
        expect(s.id, isNotEmpty);
        expect(RegExp(r'^\d+$').hasMatch(s.id), isTrue, reason: 'id 应为数字：${s.id}');
        expect(s.title, isNotEmpty);
        expect(s.detailPath, startsWith('/xml/sub/'));
        expect(s.downloadPath, startsWith('/download/'),
            reason: '每条结果都带自己的下载入口（onclick 里的 location.href）');
        expect(s.downloadPath, contains(s.id),
            reason: '下载路径里的 id 必须与详情 id 一致，否则点 A 下到 B');
      }

      // 广告位绝不会带 detailPath
      expect(list.any((s) => s.detailPath.isEmpty), isFalse);

      // 逐字抽查第一条（维琴河 663565）
      final first = list.firstWhere((s) => s.id == '663565');
      expect(first.format, contains('Subrip'));
      expect(first.languages, contains('简'));
      expect(first.languages, contains('繁'));
      expect(first.downloads, greaterThan(0));
      expect(first.downloadPath, endsWith('.rar'));
    });

    test('语言字段缺失的条目不会让整条解析失败', () {
      final why = skipReason(<String>['search_huoying.html']);
      if (why != null) {
        markTestSkipped(why);
        return;
      }
      final list = parseSearchHtml(sampleText('search_huoying.html'));
      // 实测 4/15 条没有「语言：」整段 —— 必须有条目是空列表且其余字段完好
      final empty = list.where((s) => s.languages.isEmpty).toList();
      expect(empty, isNotEmpty,
          reason: '真实样本里就有 4 条无语言字段；若一条都没有，说明解析器可能臆造了语言');
      for (final s in empty) {
        expect(s.id, isNotEmpty);
        expect(s.downloadPath, isNotEmpty);
      }
    });

    test('详情页：384 个文件、下载锚、格式都对得上', () {
      final why = skipReason(<String>['detail_663565.html']);
      if (why != null) {
        markTestSkipped(why);
        return;
      }
      final html = sampleText('detail_663565.html');
      final d = parseDetailHtml(html);
      expect(d.id, '663565');
      expect(d.title, contains('維琴河'));
      expect(d.format, contains('Subrip'));
      expect(d.downloadPath, startsWith('/download/663565/'));
      expect(d.packSizeText, isNotEmpty);
      expect(d.files.length, 384,
          reason: '真实详情页 filelist-name 计数 = 384（onthefly 三元组也是 384 条）');
      expect(d.files.first.name, contains('.srt'));
      expect(d.files.first.index, '1');
    });
  });

  // ═══ ② 魔数嗅探（★ 核心：扩展名不可信）═══════════════════════════════
  group('魔数嗅探（真实下载字节）', () {
    test('真实 .rar 样本 = RAR5', () {
      final why = skipReason(<String>['arch_663565.rar']);
      if (why != null) {
        markTestSkipped(why);
        return;
      }
      final b = sampleBytes('arch_663565.rar');
      expect(b.length, 7457646);
      expect(b.take(8).toList(), <int>[0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]);
      expect(sniffKind(b), SubtitleArchiveKind.rar5);
    });

    test('★ 名字是 .zip 的样本其实是 RAR5（扩展名不可信）', () {
      final why = skipReason(<String>['zip_try.bin']);
      if (why != null) {
        markTestSkipped(why);
        return;
      }
      final b = sampleBytes('zip_try.bin');
      expect(sniffKind(b), SubtitleArchiveKind.rar5,
          reason: '这份字节来自 /download/646901/....zip，但魔数是 Rar!\\x1a\\x07\\x01\\x00');
    });

    test('真实 ASS 文本被识别为 text，不是压缩包', () {
      final why = skipReason(<String>['direct_714927.ass']);
      if (why != null) {
        markTestSkipped(why);
        return;
      }
      final b = sampleBytes('direct_714927.ass');
      expect(b.length, 29748);
      expect(sniffKind(b), SubtitleArchiveKind.text);
      final t = decodeSubtitleBytes(b);
      expect(t.text, contains('[Script Info]'));
      expect(t.lossy, isFalse, reason: '真实样本是 UTF-8，不应标 lossy');
    });

    test('rar 明确报「不支持」，且消息里说清了怎么办', () {
      final why = skipReason(<String>['arch_663565.rar']);
      if (why != null) {
        markTestSkipped(why);
        return;
      }
      expect(
        () => extractSubtitles(sampleBytes('arch_663565.rar')),
        throwsA(isA<AssrtException>().having(
            (e) => e.message, 'message', contains('不支持'))),
      );
    });

    test('空 zip（只有 EOCD）也认得出是 zip', () {
      final z = buildZip(const <(String, List<int>)>[]);
      expect(sniffKind(z), SubtitleArchiveKind.zip);
      expect(readZipEntries(z), isEmpty);
    });
  });

  // ═══ ③ zip 解压（自己造的包，往返验证）═══════════════════════════════
  group('zip 解压', () {
    test('存储（method 0）往返', () {
      final payload = utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n你好\n');
      final z = buildZip(<(String, List<int>)>[('a/第01集.srt', payload)]);
      final subs = extractSubtitles(z, hintName: 'x.zip');
      expect(subs.length, 1);
      expect(subs.first.baseName, '第01集.srt');
      expect(subs.first.bytes, payload);
      expect(subs.first.crcOk, isTrue, reason: 'CRC32 必须与中央目录里记的一致');
    });

    test('deflate（method 8）往返 —— 证明 ZLibDecoder(raw:true) 用对了', () {
      final payload = utf8.encode('[Script Info]\n' * 200);
      final z = buildZip(
        <(String, List<int>)>[('b.ass', payload)],
        deflate: true,
      );
      // 压缩确实生效（否则这条测试没测到 deflate 分支）
      expect(z.length, lessThan(payload.length),
          reason: 'deflate 后应当明显变小，否则等于没测到解压分支');
      final subs = extractSubtitles(z, hintName: 'x.zip');
      expect(subs.single.bytes, payload);
      expect(subs.single.crcOk, isTrue);
    });

    test('CRC 对不上时 crcOk=false（不静默交出坏字幕）', () {
      final payload = utf8.encode('hello subtitle');
      final z = buildZip(
        <(String, List<int>)>[('c.srt', payload)],
        corruptCrcFor: 0,
      );
      final subs = extractSubtitles(z, hintName: 'x.zip');
      expect(subs.single.crcOk, isFalse);
    });

    test('zip 里没有字幕文件时报错，并把包内文件名列出来', () {
      final z = buildZip(<(String, List<int>)>[
        ('readme.txt', utf8.encode('hi')),
        ('cover.jpg', <int>[1, 2, 3]),
      ]);
      expect(
        () => extractSubtitles(z, hintName: 'x.zip'),
        throwsA(isA<AssrtException>()
            .having((e) => e.message, 'message', contains('没有 .srt/.ass'))),
      );
    });

    test('非 zip 字节不会被当成 zip 硬解', () {
      expect(
        () => readZipEntries(utf8.encode('definitely not a zip file at all')),
        throwsA(isA<AssrtException>()),
      );
    });
  });

  // ═══ ④ 文本解码 ════════════════════════════════════════════════════
  group('字幕文本解码', () {
    test('UTF-8 / UTF-8 BOM / UTF-16LE 各自正确', () {
      final plain = decodeSubtitleBytes(utf8.encode('你好\n'));
      expect(plain.text.trim(), '你好');
      expect(plain.encoding, 'utf-8');
      expect(plain.lossy, isFalse);

      final bom = decodeSubtitleBytes(<int>[
        0xEF, 0xBB, 0xBF, ...utf8.encode('你好\n'),
      ]);
      expect(bom.text.trim(), '你好');
      expect(bom.encoding, 'utf-8-bom');
      expect(bom.text.codeUnitAt(0), isNot(0xFEFF), reason: 'BOM 必须被吃掉');

      final u16 = decodeSubtitleBytes(<int>[
        0xFF, 0xFE, 0x60, 0x4F, 0x7D, 0x59, 0x0A, 0x00,
      ]);
      expect(u16.text, '你好\n');
      expect(u16.encoding, 'utf-16le');
    });

    test('★ 非法 UTF-8 标 lossy=true（不假装解出来了）', () {
      // 0xC4 0xE3 0xBA 0xC3 是 GBK 的「你好」，不是合法 UTF-8
      final gbk = decodeSubtitleBytes(<int>[0xC4, 0xE3, 0xBA, 0xC3]);
      expect(gbk.lossy, isTrue,
          reason: 'Dart 没有内置 GBK 解码器 ⇒ 必须如实标注，让 UI 提示用户');
      expect(gbk.encoding, 'latin1');
    });
  });

  // ═══ ⑤ 集号抽取 ════════════════════════════════════════════════════
  group('集号抽取', () {
    test('常见命名都能抽到；抽不到就是 null', () {
      expect(episodeNumberOf('Show.S01E03.720p.srt'), 3);
      expect(episodeNumberOf('E07.ass'), 7);
      expect(episodeNumberOf('EP12 简体.ssa'), 12);
      expect(episodeNumberOf('第05集.srt'), 5);
      expect(episodeNumberOf('[09].srt'), 9);
      expect(episodeNumberOf('subtitle.ass'), isNull);
    });
  });

  // ═══ ⑥ 落盘 / 绑定 ═════════════════════════════════════════════════
  group('字幕落盘与绑定', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('t71_store');
      SubtitleStore.debugSetRoot(tmp.path);
    });

    tearDown(() {
      SubtitleStore.debugSetRoot(null);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('save 真写出文件，listFor 能读回，集号正确', () async {
      final key = SubtitleStore.videoKey(title: '维琴河', episodeTitle: 'S01E01');
      final res = await SubtitleStore.save(
        videoKey: key,
        items: <ExtractedSubtitle>[
          ExtractedSubtitle(name: 'Show.S01E01.srt', bytes: utf8.encode('a')),
          ExtractedSubtitle(name: 'Show.S01E02.ass', bytes: utf8.encode('bb')),
        ],
        sourceTitle: '维琴河 S01 简繁',
        sourceId: '663565',
      );
      expect(res.files.length, 2);
      expect(res.truncatedFrom, isNull);
      for (final f in res.files) {
        expect(File(f.path).existsSync(), isTrue, reason: '必须真的在磁盘上');
        expect(await File(f.path).length(), greaterThan(0));
      }
      // 写盘时加了 nn- 前缀，但返回给用户的名字是原始名
      expect(res.files.first.name, 'Show.S01E01.srt');
      expect(res.files.first.episode, 1);

      final listed = await SubtitleStore.listFor(key);
      expect(listed.length, 2);
      expect(listed.map((e) => e.episode).toList(), <int?>[1, 2],
          reason: 'listFor 必须按集号排序');
      expect(listed.first.name, 'Show.S01E01.srt',
          reason: 'listFor 要剥掉落盘用的 nn- 前缀');
    });

    test('超出 maxFiles 时截断，并如实报出原始数量', () async {
      final key = SubtitleStore.videoKey(title: '大包');
      final items = List<ExtractedSubtitle>.generate(
        384,
        (i) => ExtractedSubtitle(
            name: 'Show.S01E${(i + 1).toString().padLeft(2, '0')}.srt',
            bytes: utf8.encode('x')),
      );
      final res = await SubtitleStore.save(
        videoKey: key,
        items: items,
        sourceTitle: 't',
        sourceId: '1',
        maxFiles: 8,
      );
      expect(res.files.length, 8);
      expect(res.truncatedFrom, 384,
          reason: '真实样本一个包 384 个文件；截断必须让用户看得见');
    });

    test('bind/boundFor：重启后仍能找回上次挂的字幕', () async {
      final key = SubtitleStore.videoKey(title: '维琴河');
      final dir = await SubtitleStore.dirFor(key);
      final p = j(dir, '01-x.srt');
      File(p).writeAsStringSync('hello');
      await SubtitleStore.bind(
        key,
        SubtitleBinding(
          path: p,
          name: 'x.srt',
          sourceTitle: 't',
          sourceId: '9',
          savedAt: DateTime.now(),
        ),
      );
      final got = await SubtitleStore.boundFor(key);
      expect(got, isNotNull);
      expect(got!.path, p);
      expect(got.sourceId, '9');

      // 索引文件必须无 BOM（本仓别的读取器遇到 BOM 会静默返回空）
      final idx = File(j(dir, 'index.json')).readAsBytesSync();
      expect(idx.take(3).toList(), isNot(<int>[0xEF, 0xBB, 0xBF]));
    });

    test('绑定指向的文件被删掉后，boundFor 返回 null（不返回死路径）', () async {
      final key = SubtitleStore.videoKey(title: 'gone');
      final dir = await SubtitleStore.dirFor(key);
      final p = j(dir, '01-x.srt');
      File(p).writeAsStringSync('x');
      await SubtitleStore.bind(
        key,
        SubtitleBinding(
            path: p, name: 'x.srt', sourceTitle: 't', sourceId: '1', savedAt: DateTime.now()),
      );
      File(p).deleteSync();
      expect(await SubtitleStore.boundFor(key), isNull);
    });

    test('clear 清空该视频目录', () async {
      final key = SubtitleStore.videoKey(title: 'clr');
      await SubtitleStore.save(
        videoKey: key,
        items: <ExtractedSubtitle>[
          ExtractedSubtitle(name: 'a.srt', bytes: utf8.encode('a')),
        ],
        sourceTitle: 't',
        sourceId: '1',
      );
      expect((await SubtitleStore.listFor(key)).length, 1);
      final n = await SubtitleStore.clear(key);
      expect(n, greaterThan(0));
      expect(await SubtitleStore.listFor(key), isEmpty);
    });

    test('videoKey 稳定且不含路径分隔符', () {
      final a = SubtitleStore.videoKey(title: '维琴河', episodeTitle: 'S01E01');
      final b = SubtitleStore.videoKey(title: '维琴河', episodeTitle: 'S01E01');
      expect(a, b);
      expect(a, isNot(SubtitleStore.videoKey(title: '别的剧')));
      expect(a.contains('/'), isFalse);
      expect(a.contains('\\'), isFalse);
      expect(a.contains(':'), isFalse);
    });
  });

  // ═══ ⑦ 偏好 ════════════════════════════════════════════════════════
  group('字幕偏好', () {
    setUp(() => UiPrefs.debugResetForTest(<String, String>{}));

    test('默认值 + 存取往返', () {
      final d = SubtitleConfig.fromPrefs();
      expect(d.enabled, isTrue);
      expect(d.preferredLanguages, contains('简'));
      d
          .copyWith(enabled: false, preferredLanguages: <String>['英'], lastKeyword: '火影')
          .save();
      final r = SubtitleConfig.fromPrefs();
      expect(r.enabled, isFalse);
      expect(r.preferredLanguages, <String>['英']);
      expect(r.lastKeyword, '火影');
    });

    test('语言偏好影响排序打分（简/繁 > 英）', () {
      const cfg = SubtitleConfig(preferredLanguages: <String>['简', '繁', '英']);
      const zh = AssrtSubtitle(
        id: '1', title: 't', detailPath: '/xml/sub/1/1.xml',
        downloadPath: '/download/1/a.rar', downloadName: 'a.rar',
        format: 'srt', languages: <String>['简', '繁'], source: '', date: '',
        views: 0, downloads: 0, rating: null,
      );
      const en = AssrtSubtitle(
        id: '2', title: 't2', detailPath: '/xml/sub/2/2.xml',
        downloadPath: '/download/2/a.rar', downloadName: 'a.rar',
        format: 'srt', languages: <String>['英'], source: '', date: '',
        views: 0, downloads: 0, rating: null,
      );
      const none = AssrtSubtitle(
        id: '3', title: 't3', detailPath: '/xml/sub/3/3.xml',
        downloadPath: '/download/3/a.rar', downloadName: 'a.rar',
        format: 'srt', languages: <String>[], source: '', date: '',
        views: 0, downloads: 0, rating: null,
      );
      expect(cfg.languageScore(zh), greaterThan(cfg.languageScore(en)));
      expect(cfg.languageScore(en), greaterThan(cfg.languageScore(none)));
      expect(cfg.languageScore(none), 0);
    });
  });

  // ═══ ⑧ 线上证据（本地 HttpServer，不看对象看请求）═════════════════════
  group('线上证据：Referer / 失败判定', () {
    late HttpServer server;
    late String base;
    final seen = <String, List<String?>>{};

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        seen.putIfAbsent(req.uri.path, () => <String?>[]).add(req.headers.value('referer'));
        final p = req.uri.path;
        if (p == '/download/ok.rar') {
          req.response.headers.contentType = ContentType.binary;
          req.response.add(<int>[0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00, 1, 2, 3]);
        } else if (p == '/download/dead.rar') {
          req.response.statusCode = 493;
          req.response.headers.contentType = ContentType.parse('text/xml');
          // ⚠️ 不能用 req.response.write() 写中文：HttpResponse.write 用 latin1 编码，
          // 实测抛 Invalid argument (string): Contains invalid characters.
          req.response.add(utf8.encode('<msgtitle>啊呀</msgtitle><msg>下载链接好像有点问题</msg>'));
        } else if (p == '/download/xml200.rar') {
          // ★ 关键形态：HTTP 200，但正文是站点的 XML 错误页
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.parse('text/xml');
          req.response.add(utf8.encode('<msgtitle>啊呀</msgtitle>'));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('下载请求真的带上了 Referer（服务器侧读到，不是对象断言）', () async {
      final c = AssrtClient(base: base);
      try {
        final dl = await c.download(
          downloadPath: '/download/ok.rar',
          referer: 'https://assrt.net/sub/?searchword=火影',
        );
        expect(dl.bytes.length, 11);
        expect(seen['/download/ok.rar'], isNotEmpty);
        final got = seen['/download/ok.rar']!.first;
        // ★ 头值只能是 ASCII：中文必须按 UTF-8 百分号编码（真实浏览器也是这样）
        expect(got, 'https://assrt.net/sub/?searchword=%E7%81%AB%E5%BD%B1',
            reason: '★ 必须在**请求头**里出现，而不是只存在于 Dart 对象里');
        expect(RegExp(r'^[\x20-\x7E]*$').hasMatch(got!), isTrue,
            reason: '★ 头值里不允许出现非 ASCII 字节（否则 dart:io 直接抛）');
      } finally {
        c.close();
      }
    });

    test('HTTP 493 + text/xml 错误页 -> AssrtException（不是"下载成功 831 字节"）', () async {
      final c = AssrtClient(base: base);
      try {
        await expectLater(
          c.download(downloadPath: '/download/dead.rar'),
          throwsA(isA<AssrtException>()
              .having((e) => e.statusCode, 'statusCode', 493)),
        );
      } finally {
        c.close();
      }
    });

    test('★ HTTP 200 但正文是 XML 错误页 -> 仍然算失败', () async {
      final c = AssrtClient(base: base);
      try {
        await expectLater(
          c.download(downloadPath: '/download/xml200.rar'),
          throwsA(isA<AssrtException>()
              .having((e) => e.message, 'message', contains('失效'))),
        );
      } finally {
        c.close();
      }
    });

    test('搜索走 /sub/?searchword=，且带上 Referer', () async {
      final t = _FakeTransport(<String, (int, String, List<int>)>{
        '/sub/': (200, 'text/html', utf8.encode('<html>没结果</html>')),
      });
      final c = AssrtClient(transport: t, base: 'https://assrt.net');
      final r = await c.search('火影');
      expect(r, isEmpty);
      expect(t.seenUris.single.path, '/sub/');
      expect(t.seenUris.single.queryParameters['searchword'], '火影');
      expect(t.seenHeaders.single['Referer'], isNotNull);
    });
  });

  // ═══ ⑨b 文件名：latin1 读出来的 UTF-8 头值要能还原 ═══════════════════
  //
  // 这一组是**实测踩到**的回归守卫，不是假想：
  // CDN 回的 Content-Disposition 里中文是**裸 UTF-8 字节**（curl 抓头逐字节确认过
  // e8 bf 9b e5 87 bb … = 「进击…」），而 Dart 的 HttpHeaders 按 latin1 解码头值，
  // 于是文件名变成 [è¿å»çå·¨äºº…].srt，并且这个乱码会一路变成落盘文件名。
  // 根因与字节证据见 .probe/assrt/TASK29-REPORT.md（事实 5）。
  group('文件名字节还原（latin1 头值 → UTF-8）', () {
    test('★ 真实头值还原成中文，不再 mojibake', () {
      // 这是真实响应头里那一串 latin1 视图（逐字节照抄 curl -D 抓到的头）
      const mojibake = '[è¿å»çå·¨äººå§åºçï¼å®ç»ç¯Â·æåçè¿å»].srt';
      expect(utf8HeaderText(mojibake),
          '[进击的巨人剧场版：完结篇·最后的进击].srt');
    });

    test('纯 ASCII 与本来就是中文的字符串都不动', () {
      expect(utf8HeaderText('Show.S01E01.srt'), 'Show.S01E01.srt');
      expect(utf8HeaderText(''), '');
      // 已经解好的字符串（codeUnit > 0xFF）不许再当字节解一遍 —— 否则会二次损坏
      expect(utf8HeaderText('进击的巨人.srt'), '进击的巨人.srt');
    });

    test('latin1 合法但非 UTF-8 的字节原样保留（不吞掉真 latin1 名）', () {
      // 0xE9 0x20 = é + 空格：单字节不成合法 UTF-8 序列
      expect(utf8HeaderText('café.srt'), 'café.srt');
    });

    test('★ 下载响应里的头值真的被用上（假传输喂 mojibake 头）', () async {
      const raw = '[è¿å»çå·¨äººå§åºç].srt';
      final t = _FakeTransport(<String, (int, String, List<int>)>{
        '/download/1/x.srt': (200, 'application/octet-stream', utf8.encode('1')),
      });
      t.extraHeaders['/download/1/x.srt'] = <String, String>{
        'content-disposition': 'subtitle; filename="$raw"',
      };
      final c = AssrtClient(transport: t, base: 'https://assrt.net');
      final dl = await c.download(downloadPath: '/download/1/x.srt');
      expect(dl.fileName, '[进击的巨人剧场版].srt',
          reason: '★ 头值必须还原，否则乱码会直接变成磁盘上的文件名');
      expect(dl.fileName.contains('è¿'), isFalse);
    });
  });

  // ═══ ⑨c 下载路径推断文件名（不碰网）═════════════════════════════════
  group('下载路径兜底文件名', () {
    test('路径里的百分号编码要解码（这是没有 Content-Disposition 时的兜底）',
        () async {
      final t = _FakeTransport(<String, (int, String, List<int>)>{
        '*': (200, 'application/octet-stream', utf8.encode('1')),
      });
      final c = AssrtClient(transport: t, base: 'https://assrt.net');
      final dl = await c.download(
          downloadPath:
              '/download/714127/%5B%E8%BF%9B%E5%87%BB%5D.srt');
      expect(dl.fileName, '[进击].srt');
    });
  });

  // ═══ ⑨ 面板（假传输，不碰网）════════════════════════════════════════
  group('字幕面板', () {
    testWidgets('搜索 -> 结果列表 -> 下载 -> 挂载回调', (tester) async {
      final why = skipReason(<String>['search_huoying.html']);
      if (why != null) {
        markTestSkipped(why);
        return;
      }
      final html = sampleText('search_huoying.html');
      final tmp = Directory.systemTemp.createTempSync('t71_panel');
      SubtitleStore.debugSetRoot(tmp.path);

      final t = _FakeTransport(<String, (int, String, List<int>)>{
        '/sub/': (200, 'text/html', utf8.encode(html)),
        // 面板下载时走 /download/<id>/...；给一个**真的 zip**（自己造的）
        '*': (
          200,
          'application/octet-stream',
          buildZip(<(String, List<int>)>[
            ('Show.S01E01.srt', utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nhi\n')),
          ])
        ),
      });

      SubtitleFileRef? mounted;
      // ⚠️ 必须包一层 Material：面板里有 TextField，
      // 没有 Material 祖先时 TextField 会直接抛
      // 「No Material widget found.」（实测踩到）
      await tester.pumpWidget(MaterialApp(
        home: Material(
          child: Stack(children: <Widget>[
            SubtitlePanel(
              onClose: () {},
              videoTitle: '维琴河',
              client: AssrtClient(transport: t, base: 'https://assrt.net'),
              onMount: (f) => mounted = f,
            ),
          ]),
        ),
      ));

      // 搜索（find.text 是**精确**匹配：结果行里的「下载 967」不会被当成按钮）
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(find.textContaining('找到 15 条'), findsOneWidget,
          reason: '面板必须把解析结果的数量如实显示出来');
      expect(find.text('下载'), findsWidgets);

      // 下载第一条
      // ⚠️ 这一段是本文件里最难写的地方，两个坑叠在一起（都实测踩到）：
      //   ① busy 期间 footer 有 CircularProgressIndicator（无限动画）⇒ pumpAndSettle 永远超时；
      //   ② _download 是在 testWidgets 的 **FakeAsync 区**里跑起来的：它每 await 一次真实 IO，
      //      续体就被排进**假**微任务队列，而真实文件 IO 又只有在 runAsync 里才会推进。
      //      所以必须 pump()（冲假队列）与 runAsync()（放真 IO）**交替**推进，缺一个都卡死。
      // 判据用**磁盘**而不是 widget 树：runAsync 期间不重建，树上的文字不会变。
      await tester.tap(find.text('下载').first);
      // ⚠️ 判据必须是**界面状态**而不是「磁盘上出现了文件」：save() 先写字幕文件、
      // 再写 index.json、再 bind()，看到 .srt 落地时 save() 其实还没返回
      // （实测：只等磁盘就会在「已保存」这一步红）。
      var sawSaved = false;
      for (var i = 0; i < 80; i++) {
        await tester.pump(); // 冲掉假微任务队列，让 _download 往下走一个 await
        // 判据用状态行的专属尾巴「· 原始格式」：
        // 「已保存」两个字也被区块标题「已保存的字幕文件」命中（实测 2 个 widget）。
        if (find.textContaining('· 原始格式').evaluate().isNotEmpty) {
          sawSaved = true;
          break;
        }
        // 放行真实事件循环，让真实的目录创建 / 写文件 / 写 index.json 落地
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      await tester.pump(); // 让最终状态渲染出来

      expect(sawSaved, isTrue, reason: '★ 面板必须走到「已保存」这一步');
      final onDisk = tmp
          .listSync(recursive: true)
          .whereType<File>()
          .any((f) => f.path.endsWith('.srt'));
      expect(onDisk, isTrue,
          reason: '★ 下载 + 解压 + 落盘这条链必须真的把字幕写到磁盘上');
      expect(find.textContaining('· 原始格式'), findsOneWidget,
          reason: '状态行必须如实报出保存数量与原始压缩格式');
      expect(find.text('已保存的字幕文件'), findsOneWidget);
      expect(find.text('挂到当前播放'), findsOneWidget);
      await tester.tap(find.text('挂到当前播放'));
      await tester.pumpAndSettle();

      expect(mounted, isNotNull, reason: '★ 挂载回调必须真的被调用');
      expect(File(mounted!.path).existsSync(), isTrue,
          reason: '★ 交给播放页的必须是磁盘上真实存在的文件（mpv sub-add 需要路径）');

      SubtitleStore.debugSetRoot(null);
      tmp.deleteSync(recursive: true);
    });
  });

  // ═══ ⑩ 源码契约 ════════════════════════════════════════════════════
  group('源码契约', () {
    test('新文件不得引 package:flutter/material.dart（本仓用 material_ui）', () {
      const files = <String>[
        'lib/core/assrt/assrt_api.dart',
        'lib/core/assrt/archive.dart',
        'lib/core/assrt/subtitle_store.dart',
        'lib/ui/subtitle/subtitle_panel.dart',
      ];
      for (final p in files) {
        final code = stripComments(File(p).readAsStringSync());
        expect(code.contains('package:flutter/material.dart'), isFalse,
            reason: '$p 必须用 package:material_ui/material_ui.dart');
      }
    });

    test('核心层不得依赖 UI 层（不得 import player_page / material_ui）', () {
      for (final p in <String>[
        'lib/core/assrt/assrt_api.dart',
        'lib/core/assrt/archive.dart',
        'lib/core/assrt/subtitle_store.dart',
      ]) {
        final code = stripComments(File(p).readAsStringSync());
        expect(code.contains('player_page'), isFalse);
        expect(code.contains('material_ui'), isFalse);
        expect(code.contains('package:flutter/'), isFalse);
      }
    });

    test('★ 不得改播放页：面板只通过回调把路径交出去', () {
      final code = stripComments(
          File('lib/ui/subtitle/subtitle_panel.dart').readAsStringSync());
      expect(code.contains('player_page.dart'), isFalse,
          reason: '面板不 import 播放页 —— 挂载由宿主接线（见 .probe/assrt/INTEGRATION.md）');
      expect(code.contains('onMount'), isTrue);
      // 署名是站点 API 文档的要求，不能悄悄删掉
      expect(code.contains('assrt.net'), isTrue);
    });

    test('★ 桌面取证探针不被产品代码 import（它不参与产品构建）', () {
      // 探针 lib/t71_assrt_probe.dart 只为桌面取证存在；一旦有产品代码 import 它，
      // 它就会进产品二进制 —— 那属于「悄悄扩大交付面」，必须拦下。
      const probe = 't71_assrt_probe';
      for (final dir in <String>['lib/core', 'lib/ui']) {
        final files = Directory(dir)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'));
        for (final f in files) {
          final code = stripComments(f.readAsStringSync());
          expect(code.contains(probe), isFalse,
              reason: '${f.path} 不得 import 桌面取证探针');
        }
      }
      // pubspec 也不能把它当入口
      final pub = File('pubspec.yaml').readAsStringSync();
      expect(pub.contains(probe), isFalse);
    });
  });
}