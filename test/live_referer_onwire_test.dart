@Tags(['native-media'])
library;

// ═══════════════════════════════════════════════════════════════════════
//  ★ 本文件被标记为 `native-media`（默认不跑）—— 原因见下
// ═══════════════════════════════════════════════════════════════════════
//
// 本文件调用 `MediaKit.ensureInitialized()`，它会加载 **libmpv-2.dll**。
// 实测：在 `flutter test` 的 flutter_tester 进程里加载该原生库，
// 会**偶发 native 崩溃**（访问违例 c0000005，进程退出码 79）。
//
// ```text
// 失败形态：整文件用例一起 `did not complete`（不是单用例失败）
// 实测崩溃率：加载 libmpv 6/25；不加载 0/25（干净交错 A/B）
// 与并发无关：串行 8 次里红 5 次；单文件串行也红（1/5）
// ```
//
// ★ 完整证据链与已排除清单：`.probe/native-media-tests.md`
// ★ 标签配置：`dart_test.yaml`
//
// 手动跑（改播放器 / media_kit 相关代码时**应该**跑一遍）：
// ```powershell
// flutter test test/ --tags native-media --concurrency=1
// ```
//
// ⚠️ `--concurrency=1` 并不能避免崩溃，只是让输出更易读。
// ═══════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════
//  任务⑰⑧：Referer **真的发出去了**吗（线上证据，不是对象断言）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么还需要这一层
//
// `live_stream_headers_test.dart` 证明的是：
// ```text
// Media(url, httpHeaders: {...}) 这个**对象**确实带着 Referer
// ```
// 但用户看到的是"黑屏" —— 真正决定成败的是 **HTTP 请求里有没有 Referer**。
// 中间还隔着 media_kit → libmpv → http 这一整条链路，任何一环丢掉它，
// 对象断言都看不出来。
//
// # 本测试怎么做
//
// 起一个**本地 HTTP 回显服务器**，把它当作流地址交给 **真实** Player，
// 然后读服务器收到的请求头：
// ```text
// 服务器收到 referer: https://tv.cctv.com/   → ★ 证明真的发出去了
// 服务器收到 referer: None                   → 说明链路上被丢了
// ```
// 本地地址不需要外网，所以这条证据**离线可复现**。
//
// ⚠️ libmpv 的 HTTP 栈在**独立进程/线程**里发请求，测试进程要等它到达 ——
//    所以用轮询而不是固定 sleep。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

const String kReferer = 'https://tv.cctv.com/';

/// 找一个含 `libmpv-2.dll` 的目录（构建产物），没有则返回 null
String? _findMpvDir() {
  const candidates = <String>[
    r'build\windows\x64\runner\Release',
    r'build\windows\x64\runner\Debug',
    r'build\windows\x64\runner\Profile',
    r'.probe\run-final',
    r'.probe\run-shadow',
    r'.probe\run-c4',
  ];
  for (final c in candidates) {
    final d = Directory(c);
    if (!d.existsSync()) continue;
    for (final f in d.listSync()) {
      if (f is File && f.path.toLowerCase().endsWith('libmpv-2.dll')) {
        return d.absolute.path;
      }
    }
  }
  return null;
}

/// 极简 HLS 回显服务器：记录每个请求的头，返回一个合法 playlist
///
/// ⚠️ 端口用 0（由系统分配空闲端口）—— 避免和外部 probe 撞车导致跳过。
class _Echo {
  HttpServer? _srv;
  final List<Map<String, String>> hits = <Map<String, String>>[];

  int get port => _srv?.port ?? 0;

  Future<void> start() async {
    _srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final req in _srv!) {
        hits.add(<String, String>{
          '__referer': req.headers.value('referer') ?? '<none>',
          '__ua': req.headers.value('user-agent') ?? '<none>',
          '__path': req.uri.path,
        });

        const body = '#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXT-X-MEDIA-SEQUENCE:0\n'
            '#EXTINF:10.0,\n'
            'seg0.ts\n'
            '#EXT-X-ENDLIST\n';
        req.response
          ..statusCode = 200
          ..headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl')
          ..write(body);
        await req.response.close();
      }
    }());
  }

  Future<void> stop() async {
    await _srv?.close(force: true);
    _srv = null;
  }

  bool get sawReferer => hits.any((h) => h['__referer'] == kReferer);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /*
   * ⚠️ 这条测试需要 **libmpv-2.dll**（media_kit 的原生依赖）。
   *    `flutter test` 的 Dart 宿主默认**不在**那个 DLL 的目录里，
   *    直接跑会 `Failed to load dynamic library` —— 那会让整套
   *    `flutter test test/` 变红，而根因只是环境，不是代码。
   *
   *    所以这里**先探一次**：拿不到就 SKIP（打印原因），
   *    拿到才跑。真正的 CI 门禁由 `live_stream_headers_test.dart`
   *    那几条纯 Dart 断言承担（它们不需要原生库）。
   */
  final hasMpv = _findMpvDir() != null;
  if (!hasMpv) {
    test('真实 Player 发出的请求里带上了 Referer（SKIP：缺 libmpv-2.dll）',
        () {
      // ignore: avoid_print
      print('SKIP: 未找到 libmpv-2.dll —— 这条需要原生依赖。'
          '把 build\\windows\\x64\\runner\\Release 加进 PATH 后可跑。');
    });
    return;
  }

  /*
   * ⚠️ 即便 DLL 文件**存在**于构建目录，`flutter test` 的 Dart 宿主也
   *    未必能加载它 —— media_kit 是在 **%PATH%** 里找的，而不是
   *    "可执行文件同目录"。所以这里 try 一次：加载失败就 SKIP，
   *    绝不让"环境缺依赖"把整套 `flutter test test/` 变红。
   *
   *    纯 Dart 的契约断言（`live_stream_headers_test.dart`）才是 CI 门禁，
   *    它们不需要原生库。
   */
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    test('真实 Player 发出的请求里带上了 Referer（SKIP：libmpv 不可加载）',
        () {
      // ignore: avoid_print
      print('SKIP: libmpv 不可加载（$e）。'
          '把构建目录加进 PATH 后可跑：'
          r'$env:PATH = "<repo>\build\windows\x64\runner\Release;$env:PATH"');
    });
    return;
  }

  test('真实 Player 发出的请求里带上了 Referer', () async {
    final echo = _Echo();
    await echo.start();
    final url = 'http://127.0.0.1:${echo.port}/live/index.m3u8';

    final player = Player();
    try {
      await player.open(
        Media(url, httpHeaders: const {'Referer': kReferer}),
        play: false,
      );

      // 轮询等请求到达（libmpv 的 http 在自己的线程里）
      var waited = 0;
      while (waited < 10000 && !echo.sawReferer) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        waited += 250;
      }

      // 打印实际收到的，便于人工核对
      for (final h in echo.hits.take(6)) {
        // ignore: avoid_print
        print('ECHO-HIT path=${h['__path']} referer=${h['__referer']} '
            'ua=${h['__ua']}');
      }

      expect(
        echo.hits,
        isNotEmpty,
        reason: '播放器根本没向本地流地址发请求 —— 说明 open() 没走到 HTTP',
      );
      expect(
        echo.sawReferer,
        isTrue,
        reason: '★ 服务器收到的 Referer 不是 `$kReferer`（实际：'
            '${echo.hits.map((h) => h['__referer']).toList()}）—— '
            '说明 media_kit → libmpv 这一段把 httpHeaders 丢了，'
            '直播就会 403/黑屏',
      );
    } finally {
      await player.dispose();
      await echo.stop();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
