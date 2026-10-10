// CR-08 · 镜像模式下校验表必须来自可信来源（CWE-494）
//
// 缺陷（两个，互相独立）：
//  ① verifySha256() 把 SHA256SUMS.txt 也按当前路线（镜像）改写，于是被控镜像
//     可以**同时**替换「校验表」和「安装包」—— 摘要对得上，校验形同虚设；
//  ② 取不到校验表 / 表里没有该资产条目，旧代码一律 return true（跳过校验）。
//
// 本文件的四个用例（全部走回环，不访问外网）：
//  1a 正常镜像下载照旧成功（防止把镜像整个掐死）；
//  1b ★ 完整攻击：被控镜像同时提供「篡改过的校验表」和「篡改过的安装包」
//     ⇒ 必须被拒，且镜像上不允许出现校验表请求；
//  2  校验表取不到 ⇒ 判为校验失败，安装包被删；
//  3  校验表里没有该资产条目 ⇒ 判为校验失败（不许「跳过校验」）；
//  4  直连模式照旧从直连源取（防止矫枉过正）。
//
// 镜像用 customMirror 指到回环源（UpdateRouteConfig(route: mirror, customMirror:
// mirror.base + '/')），这样 RouteRewriter 改写出来的地址也落在回环里 —— 旧代码
// 发起的那次「经镜像取校验表」同样不会出网，RED 证据才是干净的。
//
// ⚠ 故意不调 TestWidgetsFlutterBinding.ensureInitialized()：它会把所有
//   HttpClient 请求拦成 400，那样测的就不是真实网络路径了。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_update/app_update_controller.dart';
import 'package:sourin_spike/core/app_update/release.dart';
import 'package:sourin_spike/core/app_update/route.dart';
import 'package:sourin_spike/core/app_update/sha256.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

import 'support/zz_cr_upd_origin.dart';

const _setup = 'Sourin-Setup-1.1.0.exe';
const _other = 'sourin-macos-v1.1.0.dmg';
const _tag = 'v1.1.0';
/// 可信源上的路径前缀（= AppUpdateController.assetUrl 的形态）
const _assetBase = '/repos/sourin-app/sourin/releases/download';
const _rel = _assetBase + '/' + _tag + '/';
/// 镜像改写后的路径前缀（RouteRewriter = mirrorPrefix + 原 URL）
const _mir = '/https://github.com/sourin-app/sourin/releases/download/' + _tag + '/';
/// Release 里资产的标准地址（可被镜像改写）
const _githubPkg = 'https://github.com/sourin-app/sourin/releases/download/' + _tag + '/' + _setup;

ReleaseInfo _release(String url) => ReleaseInfo(
  tag: _tag,
  name: 'v1.1.0',
  notes: '',
  prerelease: false,
  htmlUrl: 'https://example.invalid/r',
  publishedAt: null,
  assets: [
    ReleaseAsset(name: _setup, size: 4, url: url, browserUrl: 'https://example.invalid/b'),
  ],
);

List<int> _sums(List<int> pkg, String name) =>
    utf8.encode(sha256OfBytes(pkg) + '  ' + name + '\n');

void main() {
  late Directory tmp;
  TestOrigin? trusted; // 可信直连源：校验表只能从这里取
  TestOrigin? mirror; // 被控镜像：安装包走这里

  setUp(() async {
    UiPrefs.debugResetForTest();
    tmp = await Directory.systemTemp.createTemp('zz_cr_upd_08');
    await UiPrefs.load(tmp.path);
    ClipDownloader.debugSetDataDir(tmp.path);
  });
  tearDown(() async {
    AppUpdateController.assetUrl =
        'https://github.com/sourin-app/sourin/releases/download';
    AppUpdateController.instance.setRoute(const UpdateRouteConfig());
    ClipDownloader.debugSetDataDir(null);
    await trusted?.stop();
    await mirror?.stop();
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 可能还持着刚校验完那个文件的句柄；临时目录留在 TEMP 里无妨
    }
  });

  /// 装好路由：镜像 = 回环源，可信基址 = 回环源
  AppUpdateController _wire(String? mirrorBase) {
    AppUpdateController.assetUrl = trusted!.base + _assetBase;
    final c = AppUpdateController.instance;
    c.debugResetAvailable();
    c.setRoute(UpdateRouteConfig(
      route: UpdateRoute.mirror,
      customMirror: mirrorBase == null ? '' : mirrorBase + '/',
    ));
    return c;
  }

  File _dest() =>
      File(tmp.path + Platform.pathSeparator + 'updates' + Platform.pathSeparator + _setup);
  test('CR-08-1a 正常镜像下载照旧成功（防止把镜像整个掐死）', () async {
    final pkg = utf8.encode('GOOD-PACKAGE-BYTES');
    trusted = await TestOrigin.start({_rel + 'SHA256SUMS.txt': _sums(pkg, _setup)});
    mirror = await TestOrigin.start({_mir + _setup: pkg});

    final c = _wire(mirror!.base);
    final file = await c.downloadRelease(_release(_githubPkg), onProgress: (_) {});

    expect(file, isNotNull, reason: '干净的镜像下载必须照旧成功');
    expect(c.download.error, isNull);
    expect(_dest().existsSync(), isTrue);
    expect(trusted!.hits, contains(_rel + 'SHA256SUMS.txt'),
        reason: '校验表要从可信源取');
    expect(mirror!.hits.where((h) => h.endsWith('SHA256SUMS.txt')), isEmpty,
        reason: '镜像上不允许出现校验表请求');
  });

  test('CR-08-1b ★完整攻击：被控镜像同时换掉校验表和安装包 ⇒ 必须拒装', () async {
    final goodPkg = utf8.encode('GENUINE-PACKAGE-BYTES');
    final evilPkg = utf8.encode('MALICIOUS-PACKAGE-BYTES');
    // 可信源：真校验表（真包的哈希）
    trusted = await TestOrigin.start({_rel + 'SHA256SUMS.txt': _sums(goodPkg, _setup)});
    // 被控镜像：假校验表（替身包的哈希）+ 替身包 —— 两条自洽，旧的「经镜像取表」会放行
    mirror = await TestOrigin.start({
      _mir + 'SHA256SUMS.txt': _sums(evilPkg, _setup),
      _mir + _setup: evilPkg,
    });

    final c = _wire(mirror!.base);
    final file = await c.downloadRelease(_release(_githubPkg), onProgress: (_) {});

    expect(mirror!.hits, contains(_mir + _setup), reason: '安装包仍走镜像');
    expect(mirror!.hits.where((h) => h.endsWith('SHA256SUMS.txt')), isEmpty,
        reason: '校验表绝不能经镜像取：被控镜像会把表和包一起换掉');
    expect(trusted!.hits, contains(_rel + 'SHA256SUMS.txt'),
        reason: '真校验表必须从可信直连源取');
    expect(file, isNull, reason: '替身包对不上真哈希 ⇒ 必须拒绝安装');
    expect(_dest().existsSync(), isFalse, reason: '被拒的安装包不能留在磁盘上');
  });

  test('CR-08-2 校验表取不到 ⇒ 判为校验失败，安装包必须被删掉', () async {
    final pkg = utf8.encode('GOOD-PACKAGE-BYTES');
    trusted = await TestOrigin.start({}); // 什么都不提供 ⇒ 404
    mirror = await TestOrigin.start({_mir + _setup: pkg});

    final c = _wire(mirror!.base);
    final file = await c.downloadRelease(_release(_githubPkg), onProgress: (_) {});

    expect(file, isNull, reason: '证明不了完整性就不许装');
    expect(_dest().existsSync(), isFalse);
  });

  test('CR-08-3 校验表里没有该资产条目 ⇒ 判为校验失败（不许「跳过校验」）', () async {
    final pkg = utf8.encode('GOOD-PACKAGE-BYTES');
    trusted = await TestOrigin.start({
      _rel + 'SHA256SUMS.txt': _sums(pkg, _other), // 只有别的平台的包
    });
    mirror = await TestOrigin.start({_mir + _setup: pkg});

    final c = _wire(mirror!.base);
    final file = await c.downloadRelease(_release(_githubPkg), onProgress: (_) {});

    expect(file, isNull, reason: '表里没这个资产 = 无法证明完整性 ⇒ 必须拒绝');
    expect(_dest().existsSync(), isFalse);
  });

  test('CR-08-4 直连模式：安装包和校验表都照旧从直连源取（防止矫枉过正）', () async {
    final pkg = utf8.encode('GOOD-PACKAGE-BYTES');
    trusted = await TestOrigin.start({
      _rel + 'SHA256SUMS.txt': _sums(pkg, _setup),
      _rel + _setup: pkg,
    });

    AppUpdateController.assetUrl = trusted!.base + _assetBase;
    final c = AppUpdateController.instance;
    c.debugResetAvailable();
    c.setRoute(const UpdateRouteConfig()); // 直连

    final file = await c.downloadRelease(
      ReleaseInfo(
        tag: _tag,
        name: 'v1.1.0',
        notes: '',
        prerelease: false,
        htmlUrl: 'https://example.invalid/r',
        publishedAt: null,
        assets: [
          ReleaseAsset(
            name: _setup,
            size: 4,
            url: trusted!.base + _rel + _setup,
            browserUrl: 'https://example.invalid/b',
          ),
        ],
      ),
      onProgress: (_) {},
    );

    expect(file, isNotNull);
    expect(c.download.error, isNull);
    expect(trusted!.hits, contains(_rel + 'SHA256SUMS.txt'));
  });
}
