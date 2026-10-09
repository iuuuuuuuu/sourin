import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_update/release.dart';
import 'package:sourin_spike/core/app_update/route.dart';
import 'package:sourin_spike/core/app_update/semver.dart';
import 'package:sourin_spike/core/app_update/sha256.dart';

// 版本更新的纯逻辑单测（版本比较 / 资产选择 / 镜像改写 / 校验和解析 / 代理解析）
    // 全部用录制夹具或内联字符串，**不连网**（CI 上必须能跑）。
String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

Map<String, dynamic> _release() =>
    jsonDecode(_fixture('github_release_v1_1_0.json')) as Map<String, dynamic>;

List<dynamic> _releaseList() =>
    jsonDecode(_fixture('github_releases_list.json')) as List<dynamic>;

void main() {
  group('版本比较', () {
    test('解析 v 前缀与缺失的段', () {
      expect(SemVer.tryParse('v1.2.3').toString(), '1.2.3');
      expect(SemVer.tryParse('1.2').toString(), '1.2.0');
      expect(SemVer.tryParse('v2').toString(), '2.0.0');
      expect(stripTagPrefix('v1.2.3'), '1.2.3');
      expect(stripTagPrefix('1.2.3'), '1.2.3');
      expect(stripTagPrefix('v'), 'v', reason: '只有一个 v 不是版本号，不该被剥掉');
    });

    test('解析不了的输入返回 null（不抛）', () {
      for (final bad in ['', '  ', 'abc', 'latest', null, '1.2.3.4.5']) {
        expect(SemVer.tryParse(bad), isNull, reason: '输入="$bad"');
      }
    });

    test('主版本优先，其次次版本，再次修订号', () {
      expect(SemVer.greater('1.0.1', '1.0.0'), isTrue);
      expect(SemVer.greater('1.1.0', '1.0.9'), isTrue);
      expect(SemVer.greater('2.0.0', '1.99.99'), isTrue);
      expect(SemVer.greater('1.0.0', '1.0.1'), isFalse);
      expect(SemVer.greater('1.0.0', '1.0.0'), isFalse);
    });

    test('预览版排在同版本正式版之前', () {
      expect(SemVer.greater('1.0.0', '1.0.0-beta.1'), isTrue);
      expect(SemVer.greater('1.0.0-beta.1', '1.0.0'), isFalse);
      expect(SemVer.greater('1.0.0-beta.2', '1.0.0-beta.1'), isTrue);
      expect(SemVer.greater('1.0.0-beta.10', '1.0.0-beta.2'), isTrue);
      expect(SemVer.greater('1.0.0-alpha.2', '1.0.0-beta.1'), isFalse,
          reason: 'alpha 排在 beta 前面（按标识符字母序）');
      expect(SemVer.greater('1.0.0-beta.1', '1.0.0-alpha.2'), isTrue);
      expect(SemVer.greater('1.0.1-beta.1', '1.0.0'), isTrue);
    });

    test('任一端解析不了就说「不更新」（保守，绝不误报）', () {
      expect(SemVer.greater('garbage', '1.0.0'), isFalse);
      expect(SemVer.greater('1.1.0', null), isFalse);
    });

    test('构建元数据不影响比较（1.0.0+ci.3 == 1.0.0）', () {
      expect(SemVer.greater('1.0.0+ci.3', '1.0.0'), isFalse);
      expect(SemVer.tryParse('1.0.0+ci.3').toString(), '1.0.0');
    });
  });

  group('发布信息解析', () {
    test('从夹具解析出 tag / 说明 / 预发布标记', () {
      final r = parseReleaseJson(_release());
      expect(r.tag, 'v1.1.0');
      expect(r.version, '1.1.0');
      expect(r.prerelease, isFalse);
      expect(r.notes, contains('按 ABI 选择安装包'));
      expect(r.assets.length, 6);
      expect(r.publishedAt, isNotNull);
    });

    test('资产的可读体积', () {
      final r = parseReleaseJson(_release());
      final setup = r.assets.first;
      expect(setup.prettySize, '28.4 MB');
      final dmg = r.assets.firstWhere((a) => a.name.endsWith('.dmg'));
      expect(dmg.prettySize, '124.0 MB');
    });

    test('没��� tag_name ⇒ 明确报错（不静默当成最新）', () {
      expect(() => parseReleaseJson({'assets': []}),
          throwsA(isA<ReleaseParseException>()));
    });

    test('单条坏数据不会让整个列表消失', () {
      final list = parseReleaseListJson([..._releaseList(), {'nope': 1}]);
      expect(list.length, 3);
    });

    test('列表按版本号排序，不按发布时间（预发布排在最前）', () {
      final list = parseReleaseListJson(_releaseList());
      expect(list.map((e) => e.tag), ['v1.2.0-beta.1', 'v1.1.0', 'v1.0.0']);
      expect(list.first.prerelease, isTrue);
    });
  });

  group('按平台选资产', () {
    final r = parseReleaseJson(_release());

    test('Windows 优先安装包，而不是免安装 zip', () {
      final a = selectAsset(r, UpdatePlatform.windows)!;
      expect(a.name, 'Sourin-Setup-1.1.0.exe');
    });

    test('没有安装包时退回任意 exe', () {
      final zipOnly = ReleaseInfo(
        tag: 'v1.0.0',
        name: '',
        notes: '',
        assets: const [
          ReleaseAsset(name: 'sourin-windows-v1.0.0.zip', size: 1, url: 'u', browserUrl: 'u'),
        ],
        prerelease: false,
        htmlUrl: '',
        publishedAt: null,
      );
      expect(selectAsset(zipOnly, UpdatePlatform.windows), isNull);
      final exes = ReleaseInfo(
        tag: 'v1.0.0',
        name: '',
        notes: '',
        assets: const [
          ReleaseAsset(name: 'custom.exe', size: 1, url: 'u', browserUrl: 'u'),
        ],
        prerelease: false,
        htmlUrl: '',
        publishedAt: null,
      );
      expect(selectAsset(exes, UpdatePlatform.windows)!.name, 'custom.exe');
    });

    test('macOS 选 dmg', () {
      expect(selectAsset(r, UpdatePlatform.macos)!.name, 'sourin-macos-v1.1.0.dmg');
    });

    test('Android 按 ABI 选；未知 ABI 退回 arm64', () {
      expect(selectAsset(r, UpdatePlatform.android, abi: 'armeabi-v7a')!.name,
          'sourin-android-armv7-v1.1.0.apk');
      expect(selectAsset(r, UpdatePlatform.android, abi: 'arm64-v8a')!.name,
          'sourin-android-arm64-v1.1.0.apk');
      expect(selectAsset(r, UpdatePlatform.android, abi: '')!.name,
          'sourin-android-arm64-v1.1.0.apk');
      expect(selectAsset(r, UpdatePlatform.android, abi: 'x86_64')!.name,
          'sourin-android-arm64-v1.1.0.apk', reason: '没有 x86_64 就退 arm64');
    });

    test('Android TV 与手机同一个 APK', () {
      expect(selectAsset(r, UpdatePlatform.androidTv, abi: 'arm64-v8a')!.name,
          selectAsset(r, UpdatePlatform.android, abi: 'arm64-v8a')!.name);
    });

    test('Release 里没有本平台产物 ⇒ null（UI 据此显示「没有安装包」）', () {
      final winOnly = ReleaseInfo(
        tag: 'v1.0.0',
        name: '',
        notes: '',
        assets: const [
          ReleaseAsset(name: 'Sourin-Setup-1.0.0.exe', size: 1, url: 'u', browserUrl: 'u'),
        ],
        prerelease: false,
        htmlUrl: '',
        publishedAt: null,
      );
      expect(selectAsset(winOnly, UpdatePlatform.android), isNull);
      expect(selectAsset(winOnly, UpdatePlatform.macos), isNull);
    });
  });

  group('镜像 URL 改写', () {
    final r = parseReleaseJson(_release());
    final winUrl = r.assets
        .firstWhere((a) => a.name.startsWith('Sourin-Setup'))
        .url;

    test('下载直链被镜像接管', () {
      final rr = RouteRewriter(const UpdateRouteConfig(
          route: UpdateRoute.mirror, mirrorName: 'ghfast'));
      expect(rr.rewriteDownloadUrl(winUrl),
          'https://ghfast.top/$winUrl');
    });

    test('直连模式不改写', () {
      final rr = RouteRewriter(const UpdateRouteConfig());
      expect(rr.rewriteDownloadUrl(winUrl), winUrl);
    });

    test('API 地址**不**走镜像（镜像只代理文件），直接回退原地址', () {
      final rr = RouteRewriter(const UpdateRouteConfig(
          route: UpdateRoute.mirror, mirrorName: 'ghfast'));
      final api = Uri.parse('https://api.github.com/repos/a/b/releases/latest');
      expect(rr.resolveApi(api), api.toString());
    });

    test('非 GitHub / 非 release 下载的地址不被改写', () {
      expect(RouteRewriter.isMirrorable(Uri.parse(winUrl)), isTrue);
      expect(RouteRewriter.isMirrorable(
          Uri.parse('https://api.github.com/repos/a/b/releases')), isFalse);
      expect(RouteRewriter.isMirrorable(
          Uri.parse('https://example.com/releases/download/v1/x.zip')), isFalse);
      final rr = RouteRewriter(const UpdateRouteConfig(
          route: UpdateRoute.mirror, mirrorName: 'ghfast'));
      expect(rr.rewriteDownloadUrl('https://example.com/a.zip'),
          'https://example.com/a.zip');
    });

    test('自定义镜像前缀自动补 https:// 与结尾斜杠', () {
      expect(UpdateMirror.normalizePrefix('mirror.example.com'),
          'https://mirror.example.com/');
      expect(UpdateMirror.normalizePrefix('  https://m.io/  '), 'https://m.io/');
      expect(UpdateMirror.normalizePrefix(''), '');
      final rr = RouteRewriter(const UpdateRouteConfig(
          route: UpdateRoute.mirror, customMirror: 'my.mirror'));
      expect(rr.rewriteDownloadUrl(winUrl), 'https://my.mirror/$winUrl');
    });

    test('选了镜像但没填前缀 ⇒ 等同直连（而不是拼出坏 URL）', () {
      final rr = RouteRewriter(const UpdateRouteConfig(route: UpdateRoute.mirror));
      expect(rr.rewriteDownloadUrl(winUrl), winUrl);
    });

    test('预置镜像里选不存在的名字 ⇒ 等同直连', () {
      final rr = RouteRewriter(const UpdateRouteConfig(
          route: UpdateRoute.mirror, mirrorName: 'nope'));
      expect(rr.rewriteDownloadUrl(winUrl), winUrl);
    });
  });

  group('代理配置解析', () {
    test('直连模式即使填了地址也不带代理', () {
      const c = UpdateRouteConfig(
          route: UpdateRoute.direct, proxyHost: '127.0.0.1', proxyPort: 7890);
      expect(c.proxyUri(), isNull);
    });

    test('代理模式解析成完整 URI', () {
      const c = UpdateRouteConfig(
          route: UpdateRoute.proxy, proxyHost: '127.0.0.1', proxyPort: 7890);
      expect(c.proxyUri(), 'http://127.0.0.1:7890');
    });

    test('端口缺失/非法 ⇒ 视为没配代理（不产生半截 URI）', () {
      expect(const UpdateRouteConfig(route: UpdateRoute.proxy, proxyHost: 'a')
          .proxyUri(), isNull);
      expect(const UpdateRouteConfig(
              route: UpdateRoute.proxy, proxyHost: 'a', proxyPort: 0)
          .proxyUri(), isNull);
      expect(const UpdateRouteConfig(
              route: UpdateRoute.proxy, proxyHost: '', proxyPort: 7890)
          .proxyUri(), isNull);
    });

    test('「跟随系统」读环境变量；没有则回落到手工填的地址', () {
      const c = UpdateRouteConfig(
          route: UpdateRoute.proxy,
          followSystemProxy: true,
          proxyHost: '10.0.0.1',
          proxyPort: 1080);
      expect(c.proxyUri(env: const {'HTTPS_PROXY': 'http://s.proxy:8888'}),
          'http://s.proxy:8888');
      expect(c.proxyUri(env: const {}), 'http://10.0.0.1:1080');
      expect(const UpdateRouteConfig(route: UpdateRoute.proxy, followSystemProxy: true)
          .proxyUri(env: const {}), isNull);
    });

    test('环境变量忘了写 scheme ⇒ 补 http://（否则代理连不上）', () {
      const c =
          UpdateRouteConfig(route: UpdateRoute.proxy, followSystemProxy: true);
      expect(c.proxyUri(env: const {'HTTP_PROXY': 's.proxy:8888'}),
          'http://s.proxy:8888');
    });

    test('偏好往返不丢字段', () {
      const c = UpdateRouteConfig(
        route: UpdateRoute.mirror,
        proxyHost: 'h',
        proxyPort: 1,
        followSystemProxy: true,
        mirrorName: 'ghfast',
        customMirror: 'x',
      );
      final back = UpdateRouteConfig.fromPrefs(c.toPrefs());
      expect(back.route, UpdateRoute.mirror);
      expect(back.proxyHost, 'h');
      expect(back.proxyPort, 1);
      expect(back.followSystemProxy, isTrue);
      expect(back.mirrorName, 'ghfast');
      expect(back.customMirror, 'x');
    });

    test('偏好里是垃圾值 ⇒ 回默认直连，不崩', () {
      final c = UpdateRouteConfig.fromPrefs(const {'route': '???', 'proxyPort': 'x'});
      expect(c.route, UpdateRoute.direct);
      expect(c.proxyPort, 0);
    });
  });

  group('SHA256SUMS.txt 解析', () {
    const text = '''
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  sourin-windows-v1.1.0.zip
*ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789 Sourin-Setup-1.1.0.exe

# 注释行应被忽略
not-a-hash-line
''';

    test('两条有效行都读出来，星号前缀也认', () {
      final m = parseSha256Sums(text);
      expect(m.length, 2);
      expect(m['sourin-windows-v1.1.0.zip']!.length, 64);
      expect(m['Sourin-Setup-1.1.0.exe']!.startsWith('abcdef'), isTrue);
    });

    test('取某个文件的摘要；大小写差异也认', () {
      final m = parseSha256Sums(text);
      expect(expectedSha256(m, 'sourin-windows-v1.1.0.zip'),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(expectedSha256(m, 'SOURIN-WINDOWS-V1.1.0.ZIP'),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(expectedSha256(m, 'sourin-android-arm64-v1.1.0.apk'), isNull);
    });
  });

  group('SHA-256 实现（用 package:crypto，自己只验"用法对不对"）', () {
    test('NIST 官方测试向量', () {
      expect(sha256OfBytes(const []),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(sha256OfBytes('abc'.codeUnits),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(
          sha256OfBytes(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'.codeUnits),
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
    });

    test('大文件走流式：结果与一次性算的一致，且不撑爆内存', () async {
      final f = File('${Directory.systemTemp.path}/sourin_sha_stream.bin');
      const oneChunk = 64 * 1024;
      final chunk = List<int>.filled(oneChunk, 0x61);
      final all = List<int>.filled(oneChunk * 16, 0x61);
      final sink = f.openWrite();
      for (var i = 0; i < 16; i++) {
        sink.add(chunk);
      }
      await sink.close();
      // 1 MiB —— 足以走出"分多块 bind"那条路径
      expect(await sha256OfFile(f), sha256OfBytes(all));
      f.deleteSync();
    });
  });
}
