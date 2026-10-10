// CR-08 · 镜像模式下校验表必须来自可信来源（CWE-494）
//
// 缺陷（两个，互相独立）：
//  ① verifySha256() 把 SHA256SUMS.txt 也按当前路线（镜像）改写，于是被控镜像
//     可以**同时**替换「校验表」和「安装包」—— 摘要对得上，校验形同虚设；
//  ② 取不到校验表 / 表里没有该资产条目，旧代码一律 return true（跳过校验）。
//
// 本文件的用例（全部走回环，不访问外网）：
//  0  ★ 资产选择（纯函数）：Windows 与 macOS 两侧都必须挑得到各自的包；
//  1a 正常镜像下载照旧成功（防止把镜像整个掐死）；
//  1b ★ 完整攻击：被控镜像同时提供「篡改过的校验表」和「篡改过的安装包」
//     ⇒ 必须被拒，且镜像上不允许出现校验表请求；
//  2  校验表取不到 ⇒ 判为校验失败，安装包被删；
//  3  校验表里没有该资产条目 ⇒ 判为校验失败（不许「跳过校验」）；
//  4  直连模式照旧从直连源取（防止矫枉过正）。
//
// ══════════════════════════════════════════════════════════════════════
// ★★★ UPD08：原用例在 macOS 上必红 —— 机制（逐字核对过生产代码）
// ══════════════════════════════════════════════════════════════════════
// 原 _release() 造的 ReleaseInfo **只挂一条 .exe 资产**，而生产是这样选资产的：
//
//   app_update_controller.dart:296-299  assetFor(rel)
//     → client.dart:46-54  UpdateHttp.currentTarget()
//         · Windows   ⇒ (UpdatePlatform.windows, null)
//         · macOS/iOS ⇒ (UpdatePlatform.macos,   null)
//     → release.dart:168-195 selectAsset(rel, platform)
//         · case UpdatePlatform.macos (release.dart:186-189)
//           先找 name 以 .dmg 结尾的资产，找不到再退 .zip
//   ⇒ macOS 上：.dmg 找不到（只有 .exe）、.zip 也没有 ⇒ 返回 null
//   ⇒ app_update_controller.dart:313-321 提前 return null
//   ⇒ **下载根本没开始**：mirror.hits == []，也没有任何网络异常
//
// CI 红文本正是这个形状（.probe/ops/_ci_macOS_log.fixed.txt:8639-8668）：
//
//   CR-08-1a :109  Expected: not null / Actual: <null>
//   CR-08-1b :132  Expected: contains
//                  '/https://github.com/sourin-app/sourin/releases/download/v1.1.0/Sourin-Setup-1.1.0.exe'
//                  Actual: [] / Which: does not contain ...
//   CR-08-4  :199  Expected: not null / Actual: <null>
//   CR-08-2 / CR-08-3 ✅ —— 它们**期望失败**，所以资产选不到也会「绿」
//                  （= 假绿：什么都没测到。见下面 CR-08-2/3 里新加的
//                    「安装包确实下过」断言）
//
// # 修法（两层，缺一不可）
//
// ① _release() 同时挂 .exe 与 .dmg 两条资产，期望资产名按当前平台取
//    （final _pkg = Platform.isWindows ? _setup : _other）—— 让 macOS 上
//    真的能选到包，下载真的开始。
// ② ★ 不止于此：selectAsset() 是**纯函数且收显式 UpdatePlatform 参数**
//    （release.dart:168），所以 CR-08-0 用显式参数在 Windows 机器上把
//    **两侧语义都真断言**，并用「只挂 .exe」的构造复现 macOS 分支必空选到
//    的机制（范本：test/zz_t12_defect_a_probe_test.dart:237-280）。
//    绝不用 Platform.isWindows 把 macOS 那一侧整块跳掉 —— 跳过 = 在 macOS 上
//    什么都没测，是另一种假门禁。
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
import 'package:sourin_spike/core/app_update/client.dart';
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
/// GitHub 上资产的标准前缀（可被镜像改写）
const _mirrorPrefix = 'https://github.com/sourin-app/sourin/releases/download/';
/// 镜像改写后的路径前缀（RouteRewriter = mirrorPrefix + 原 URL）
const _mir = '/$_mirrorPrefix$_tag/';
/// Release 里资产的标准地址（可被镜像改写）
const _githubPkg = '$_mirrorPrefix$_tag/$_setup';
const _githubDmg = '$_mirrorPrefix$_tag/$_other';

/// 当前平台该下的那个包 —— ★ UPD08：期望名必须按平台取
/// （原来写死 _setup ⇒ macOS 上 selectAsset 返回 null ⇒ CI 红）
final _pkg = Platform.isWindows ? _setup : _other;

/// **另一个**平台的包（CR-08-3 要造「表里只有别人的条目」）
final _altPkg = Platform.isWindows ? _other : _setup;

/// ★ UPD08：同时挂 .exe 与 .dmg 两条资产
///
/// 原构造只挂一条 .exe，于是 macOS 上 release.dart:186-189 找不到 .dmg
/// ⇒ selectAsset 返回 null ⇒ downloadRelease 提前 return ⇒ 三条用例必红。
ReleaseInfo _release(String exeUrl, String dmgUrl) => ReleaseInfo(
  tag: _tag,
  name: 'v1.1.0',
  notes: '',
  prerelease: false,
  htmlUrl: 'https://example.invalid/r',
  publishedAt: null,
  assets: [
    ReleaseAsset(name: _setup, size: 4, url: exeUrl, browserUrl: 'https://example.invalid/b'),
    ReleaseAsset(name: _other, size: 4, url: dmgUrl, browserUrl: 'https://example.invalid/b'),
  ],
);

/// 所有下载用例都走这一个构造点
///
/// [base] 为空 ⇒ 资产用 GitHub **绝对地址**（镜像模式下由 RouteRewriter 改写，
/// 落回环镜像上）；非空 ⇒ 资产用 [base] 打头的**回环绝对地址**（直连模式用）。
/// 两条都是绝对 URL —— 绝不能把 base 拼在 _githubPkg 前面（那会拼出
/// 'http://[::1]:port' + 'https://github.com/...' 这种非法端口，见 CR-08-4）。
///
/// CR-08-0 的门禁断言的**就是**这个对象 —— 免得门禁测的是另一个构造。
ReleaseInfo _releaseUnderTest(String base) => base.isEmpty
    ? _release(_githubPkg, _githubDmg)
    : _release(base + _rel + _setup, base + _rel + _other);

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
      File(tmp.path + Platform.pathSeparator + 'updates' + Platform.pathSeparator + _pkg);

  // ══════════════════════════════════════════════════════════════════
  //  CR-08-0 ★ 资产选择：两侧语义都用显式参数钉死（不靠平台跳过）
  // ══════════════════════════════════════════════════════════════════
  test('CR-08-0 ★资产选择（纯函数）：Windows 与 macOS 两侧都必须挑得到自己的包', () {
    final rel = _releaseUnderTest('');

    // ── ① 两侧都用**显式平台参数**断言（release.dart:168 selectAsset） ──
    final win = selectAsset(rel, UpdatePlatform.windows);
    final mac = selectAsset(rel, UpdatePlatform.macos);
    expect(win, isNotNull, reason: 'Windows 必须挑得到资产（.exe）');
    expect(mac, isNotNull,
        reason: '★★ macOS 必须挑得到资产（.dmg）—— 这条在 Windows 机器上也真跑，'
            '原用例只挂 .exe ⇒ 这里就是 macOS 上必红的那个点');
    expect(win!.name, _setup, reason: 'Windows 选中安装包 .exe');
    expect(mac!.name, _other,
        reason: '★ macOS 选中 .dmg（release.dart:186-189：先 .dmg，找不到才退 .zip）');
    expect(win.name, isNot(equals(mac.name)),
        reason: '★ 两个平台必须选中**不同**的包，否则上面的断言是空的');

    // ── ② ★★ 机制复现：把资产减回原用例的「只挂 .exe」，macOS 分支必然选不到 ──
    //   这条在 Windows 上照样真跑（纯函数 + 显式平台），所以「macOS 上必红」
    //   这件事**在本机就被证明**，不依赖真 macOS、也不是靠跳过。
    final exeOnly = ReleaseInfo(
      tag: rel.tag,
      name: rel.name,
      notes: rel.notes,
      prerelease: rel.prerelease,
      htmlUrl: rel.htmlUrl,
      publishedAt: rel.publishedAt,
      assets: rel.assets.where((a) => a.name.endsWith('.exe')).toList(),
    );
    expect(selectAsset(exeOnly, UpdatePlatform.windows)?.name, _setup,
        reason: '阳性对照：同一份 Release 在 Windows 上仍然选得到');
    expect(selectAsset(exeOnly, UpdatePlatform.macos), isNull,
        reason: '★★ 只挂 .exe ⇒ macOS 分支（找 .dmg、再退 .zip）什么都找不到 ⇒ '
            'app_update_controller.dart:313-321 提前 return null ⇒ **下载根本没开始** '
            '⇒ CI 红文本的形状：mirror.hits == [] 且没有任何网络异常');
    expect(selectAsset(rel, UpdatePlatform.macos), isNotNull,
        reason: '反向自检：补上 .dmg 之后同一个 macOS 分支**必须**选得到 '
            '—— 否则上面那条「选不到」是空的（两边一样就什么都没证明）');

    // ── ③ 把门禁接到**生产入口**上：本机生产挑的那个包 == 用例期望的 _pkg ──
    final c = AppUpdateController.instance;
    c.debugResetAvailable();
    expect(c.assetFor(rel)?.name, _pkg,
        reason: '★ 生产路径（assetFor → currentTarget）挑中的包必须正是用例下载的那个');

    // 平台 → 枚举 的映射只能在本机验证本机那一侧（macOS 那一侧无法在 Windows 上
    // 真跑），但它**不是**本次缺陷所在：缺陷在「枚举 → 资产」这半段，已被 ① ② 钉死。
    final (platform, _) = UpdateHttp.currentTarget();
    if (Platform.isWindows) {
      expect(platform, UpdatePlatform.windows,
          reason: '本机是 Windows ⇒ currentTarget 必须给 windows');
    } else if (Platform.isMacOS || Platform.isIOS) {
      expect(platform, UpdatePlatform.macos,
          reason: '本机是 macOS/iOS ⇒ currentTarget 必须给 macos');
    } else if (Platform.isAndroid) {
      expect(platform, UpdatePlatform.android,
          reason: '本机是 Android ⇒ currentTarget 必须给 android');
    }
  });

  test('CR-08-1a 正常镜像下载照旧成功（防止把镜像整个掐死）', () async {
    final pkg = utf8.encode('GOOD-PACKAGE-BYTES');
    trusted = await TestOrigin.start({_rel + 'SHA256SUMS.txt': _sums(pkg, _pkg)});
    mirror = await TestOrigin.start({_mir + _pkg: pkg});

    final c = _wire(mirror!.base);
    final file = await c.downloadRelease(_releaseUnderTest(''), onProgress: (_) {});

    expect(file, isNotNull, reason: '干净的镜像下载必须照旧成功');
    expect(c.download.error, isNull);
    expect(_dest().existsSync(), isTrue);
    expect(mirror!.hits, contains(_mir + _pkg),
        reason: '★ 安装包确实经镜像下过（$_pkg）—— 防止「选不到资产」被当成「成功」');
    expect(trusted!.hits, contains(_rel + 'SHA256SUMS.txt'),
        reason: '校验表要从可信源取');
    expect(mirror!.hits.where((h) => h.endsWith('SHA256SUMS.txt')), isEmpty,
        reason: '镜像上不允许出现校验表请求');
  });

  test('CR-08-1b ★完整攻击：被控镜像同时换掉校验表和安装包 ⇒ 必须拒装', () async {
    final goodPkg = utf8.encode('GENUINE-PACKAGE-BYTES');
    final evilPkg = utf8.encode('MALICIOUS-PACKAGE-BYTES');
    // 可信源：真校验表（真包的哈希）
    trusted = await TestOrigin.start({_rel + 'SHA256SUMS.txt': _sums(goodPkg, _pkg)});
    // 被控镜像：假校验表（替身包的哈希）+ 替身包 —— 两条自洽，旧的「经镜像取表」会放行
    mirror = await TestOrigin.start({
      _mir + 'SHA256SUMS.txt': _sums(evilPkg, _pkg),
      _mir + _pkg: evilPkg,
    });

    final c = _wire(mirror!.base);
    final file = await c.downloadRelease(_releaseUnderTest(''), onProgress: (_) {});

    expect(mirror!.hits, contains(_mir + _pkg), reason: '安装包仍走镜像');
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
    mirror = await TestOrigin.start({_mir + _pkg: pkg});

    final c = _wire(mirror!.base);
    final file = await c.downloadRelease(_releaseUnderTest(''), onProgress: (_) {});

    // ★ UPD08：这条**期望失败**，所以「资产选不到 ⇒ 提前 return null」也会绿。
    //   必须证明安装包真的下过（否则整条用例什么都没测到 = 假绿）。
    expect(mirror!.hits, contains(_mir + _pkg),
        reason: '★ 安装包确实下过（$_pkg）—— 否则这条是假绿：选不到资产也会「失败」');
    expect(file, isNull, reason: '证明不了完整性就不许装');
    expect(_dest().existsSync(), isFalse);
  });

  test('CR-08-3 校验表里没有该资产条目 ⇒ 判为校验失败（不许「跳过校验」）', () async {
    final pkg = utf8.encode('GOOD-PACKAGE-BYTES');
    trusted = await TestOrigin.start({
      _rel + 'SHA256SUMS.txt': _sums(pkg, _altPkg), // 只有别的平台的包
    });
    mirror = await TestOrigin.start({_mir + _pkg: pkg});

    // ★ UPD08 仪器自检：这条表里确实**没有**本平台包的条目
    //   （表里必须留的是 _altPkg —— 原写法把名字写死成 _other，在 macOS 上
    //     _pkg 就等于 _other ⇒ 表里**正好有**该条目 ⇒ 这条会红；
    //     反过来在 Windows 上若不自检，也可能悄悄变成空的）
    final table = parseSha256Sums(utf8.decode(_sums(pkg, _altPkg)));
    expect(table.containsKey(_altPkg), isTrue, reason: '表里有另一个平台的包');
    expect(expectedSha256(table, _pkg), isNull,
        reason: '★ 表里没有本平台包（$_pkg）⇒「缺条目」分支真的会被走到');

    final c = _wire(mirror!.base);
    final file = await c.downloadRelease(_releaseUnderTest(''), onProgress: (_) {});

    expect(mirror!.hits, contains(_mir + _pkg),
        reason: '★ 安装包确实下过（$_pkg）—— 否则这条是假绿：选不到资产也会「失败」');
    expect(file, isNull, reason: '表里没这个资产 = 无法证明完整性 ⇒ 必须拒绝');
    expect(_dest().existsSync(), isFalse);
  });

  test('CR-08-4 直连模式：安装包和校验表都照旧从直连源取（防止矫枉过正）', () async {
    final pkg = utf8.encode('GOOD-PACKAGE-BYTES');
    trusted = await TestOrigin.start({
      _rel + 'SHA256SUMS.txt': _sums(pkg, _pkg),
      _rel + _pkg: pkg,
    });

    AppUpdateController.assetUrl = trusted!.base + _assetBase;
    final c = AppUpdateController.instance;
    c.debugResetAvailable();
    c.setRoute(const UpdateRouteConfig()); // 直连

    final file = await c.downloadRelease(
      _releaseUnderTest(trusted!.base),
      onProgress: (_) {},
    );

    expect(file, isNotNull);
    expect(c.download.error, isNull);
    expect(_dest().existsSync(), isTrue, reason: '直连模式下包要真的落地');
    expect(trusted!.hits, contains(_rel + 'SHA256SUMS.txt'));
    expect(trusted!.hits, contains(_rel + _pkg),
        reason: '★ 安装包也必须从直连源取（$_pkg）');
  });
}
