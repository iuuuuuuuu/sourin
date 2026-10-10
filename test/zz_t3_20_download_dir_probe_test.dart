@Tags(['needs-isolated-userprofile'])
//
// ★ 必须以隔离的 USERPROFILE 运行（2026-10-10 CI 修复）。
//
// # 为什么
// ```text
// 本文件要真碰文件系统（DownloadDir 的语义全在 create(recursive:true) 上）。
// 而默认兜底根目录 = $USERPROFILE\Videos\源影 —— 不隔离就会在用户真实目录里
// 建目录。Platform.environment 在 flutter_test 里是**只读**的，改不了，
// 所以隔离只能由**进程环境**提供。
//
// 用例 ⓪ 就是这条前提的自检：不满足就红，而不是默默写真实目录。
// ```
//
// # CI 为什么不满足
// ```text
// .github/workflows/build.yml 跑的是裸 \`flutter test\`，没有设 USERPROFILE
// ⇒ ⓪ 必然红（Expected: true / Actual: false），把 Windows 与 macOS 两个 job
//    一起带下去。而文件头注释里引用的 \`tools/run_tests.sh\`（说它负责设
//    隔离环境）**在仓库里根本不存在** —— 那条引用是悬空的（该脚本在本仓库
//    从未存在过；T320 已把引用改成下面那套可直接执行的 PowerShell 命令）。
// ```
//
// # 所以标上标签，默认跳过（与本仓 native-media 同一套办法，见 dart_test.yaml）
// ```powershell
// 默认（CI）：跳过
// 手动跑：
//   $env:USERPROFILE = "$env:TEMP\sourin-isolated-home"
//   flutter test test/zz_t3_20_download_dir_probe_test.dart --run-skipped \
//     --tags needs-isolated-userprofile --concurrency=1
// ```
import 'dart:io';
// ═══════════════════════════════════════════════════════════════════════
//  ⑳ 下载目录可配置 —— **真实读写文件系统**的探针
// ═══════════════════════════════════════════════════════════════════════
//
// 为什么不能只做"纯函数单测"：
//   `DownloadDir` 的语义**全在文件系统上** —— root() 会 create(recursive:true)、
//   forWork() 会建剧名文件夹。不真的碰盘，就测不出"用户填了个不存在的盘符
//   会不会退回去"这种事。
//
// ⚠️ 隔离：本探针**只**用临时目录，**绝不**碰 %APPDATA%\app.sourin.player，
//   也**绝不**写用户的 Videos\源影。
//
// ★★ 2026-10-10（review agent 查出、lead 修）：原文件头声称「绝不写用户的
//    Videos」，但那是**假的** —— 用例 ① / ④ / ⑤ 会走到「未配置」分支，
//    `DownloadDir._resolveRoot()` 读 `Platform.environment['USERPROFILE']`
//    并 `create(recursive:true)` 于 `Videos\源影` ⇒ 真的在用户目录里建了目录。
//    （`setConfiguredDir` 只影响「用户指定目录」这一层，管不到默认兜底。）
//
//    修法：本文件**要求以隔离的 USERPROFILE 运行**（见文件头「手动跑」那
//    段命令）⇒ 默认兜底落在临时盘。（历史上这里写的是 `tools/run_tests.sh`
//    里的调用，而该脚本在本仓库**从未存在** —— T320 已改为指向真实命令。）
//    ⚠️ 不能在测试里改 `Platform.environment['USERPROFILE']` —— 它在
//    `flutter_test` 里是**只读**的（实测 `Unsupported operation: Cannot
//    modify unmodifiable map`），所以隔离必须由**进程环境**提供。
//    用例 ⓪ 是这条前提的自检：前提不成立时它直接红，而不是默默写真实目录。

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 路径是否落在「临时/隔离」目录之下
///
/// ★★ 只按**尾部标记**判，不比整串（2026-10-10 实测踩过）：
/// `Directory.systemTemp` 在 Windows 上解析成 8.3 短名
/// （C:\Users\IUUUUU~1\AppData\Local\Temp），而环境变量里的 USERPROFILE
/// 是长名（C:\Users\iuuuuuuuu\AppData\Local\...）
/// ⇒ 直接 startsWith(systemTemp.path) 会假红。
/// 尾部标记足以区分「系统临时目录」与「真实用户目录 C:\Users\<你>」。
bool underTemp(String p) {
  final n = p.replaceAll('/', r'\').toLowerCase();
  return const [r'\appdata\local\temp', r'\temp', r'\tmp'].any(n.contains);
}
void main() {
  late Directory tmp;


  setUpAll(() {
    // 前提自检：USERPROFILE 必须已经指向临时盘（由**进程环境**提供，
    // Platform.environment 在测试里改不了）。不成立就在用例 ⓪ 里红。
    final home = Platform.environment['USERPROFILE'] ?? '';
    if (!underTemp(home)) {
      // ignore: avoid_print
      print('[T3_20] ⚠ USERPROFILE=$home —— 本文件必须以隔离的 USERPROFILE 运行，'
          '否则会在用户真实的 Videos\\源影 里建目录');
    }
  });

  setUp(() {
    tmp = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}'
            'sourin-t3_20-dl')
      ..createSync(recursive: true);
    // 每个用例从"空偏好"开始（UiPrefs 是 static，不重置会互相串）
    UiPrefs.debugResetForTest();
    DownloadDir.debugReset();
  });

  tearDown(() {
    UiPrefs.debugResetForTest();
    DownloadDir.debugReset();
  });

  test('⓪ ★★ 隔离自检（防假绿）：默认兜底**不许**落到真实用户目录', () async {
    // 本文件的隔离由**进程环境**提供（Platform.environment 在测试里是只读的，
    // 实测报 `Cannot modify unmodifiable map`）⇒ 前提不成立时这条必须红，
    // 而不是默默在用户真实的 Videos\源影 里建目录。
    final home = Platform.environment['USERPROFILE'] ?? '';
    expect(home, isNotEmpty, reason: '本文件必须以隔离的 USERPROFILE 运行');
    expect(underTemp(home), isTrue,
        reason: 'USERPROFILE=$home 必须指向临时目录，否则本文件会写真实用户目录');

    final r = await DownloadDir.root();
    expect(underTemp(r), isTrue,
        reason: '★ 默认下载根必须落在临时目录内（实测 resolve 到 $r）');
  });

  test('① 没配置 ⇒ 走默认（非空、且目录真实存在）', () async {
    expect(DownloadDir.hasConfiguredDir, isFalse);
    final r = await DownloadDir.root();
    debugPrint('DIR[默认] = $r');
    expect(r, isNotEmpty);
    expect(Directory(r).existsSync(), isTrue, reason: '★ root() 必须保证目录真实存在');
  });

  test('② 配置了有效目录 ⇒ root() 真的返回它，且被创建出来', () async {
    final target = Directory('${tmp.path}${Platform.pathSeparator}my-custom')..createSync(recursive: true);
    DownloadDir.setConfiguredDir(target.path);
    expect(DownloadDir.configuredDir, target.path);

    final r = await DownloadDir.root();
    debugPrint('DIR[自定义] = $r');
    expect(r, target.path, reason: '★★ 这里就是「可配置」的全部意义');
    expect(Directory(r).existsSync(), isTrue);
  });

  test('③ 配置了**不存在**的目录 ⇒ 先尝试创建（create recursive）', () async {
    /*
     * ⚠️ 这里**不能**先断言 existsSync()==false：
     *   setUp 里那个 tmp 是所有用例共享的，② 跑完可能已经在它下面留下了东西，
     *   断言"此刻还不存在"在跨用例时不稳定（第一版就是这么挂的：Expected false,
     *   Actual true）。真正要验的是**改完之后**目录被建出来了。
     */
    final target = '${tmp.path}${Platform.pathSeparator}case3-only'
        '${Platform.pathSeparator}not-yet-made${Platform.pathSeparator}deep';
    DownloadDir.setConfiguredDir(target);
    final r = await DownloadDir.root();
    debugPrint('DIR[自动建] = $r');
    expect(r, target, reason: '★ 不存在的目录应当被 create(recursive: true) 建出来');
    expect(Directory(target).existsSync(), isTrue);
  });

  test('④ ★★ 配置了**建不出来**的目录（非法路径）⇒ 必须退回默认，不许整体失败', () async {
    // ★ 2026-10-10 T320 实测：这条**必须**用真 NUL（\u0000），不能用字面文本
    //   「反斜杠 + u0000」—— 后者在 Windows 上靠「反斜杠被当成根解析」才失败，
    //   而反斜杠在 POSIX 上只是普通文件名字符 ⇒ 整条会变成**合法**路径、假绿。
    //   真 NUL 在 Windows 与 POSIX 上**都**非法（POSIX 内核拒绝含 \0 的路径），
    //   所以中间的分隔符也用 Platform.pathSeparator，两边都保证 create 必失败。
    DownloadDir.setConfiguredDir('\u0000bad${Platform.pathSeparator}\u0000path');
    final r = await DownloadDir.root();
    debugPrint('DIR[非法路径退回] = $r');
    expect(r, isNot(contains('bad')), reason: '★ 不能用那个非法路径');
    expect(Directory(r).existsSync(), isTrue, reason: '★ 退回来的目录必须可用');
  });

  test('⑤ 清空配置 ⇒ 立刻回到默认（_cached 必须被清掉）', () async {
    final target = Directory('${tmp.path}${Platform.pathSeparator}custom2')..createSync(recursive: true);
    DownloadDir.setConfiguredDir(target.path);
    final withCustom = await DownloadDir.root();
    expect(withCustom, target.path);

    DownloadDir.setConfiguredDir(null);          // 清空
    expect(DownloadDir.hasConfiguredDir, isFalse);
    final back = await DownloadDir.root();
    debugPrint('DIR[清空后] = $back');
    expect(back, isNot(target.path),
        reason: '★★ setConfiguredDir 里必须清 _cached，否则「改了没反应」');
  });

  test('⑥ forWork：剧名进子目录，且路径落在自定义根下', () async {
    final target = Directory('${tmp.path}${Platform.pathSeparator}root6')..createSync(recursive: true);
    DownloadDir.setConfiguredDir(target.path);
    final work = await DownloadDir.forWork('我的剧');
    debugPrint('DIR[forWork] = $work');
    expect(work.startsWith(target.path), isTrue, reason: '★ 必须落在自定义根下');
    expect(Directory(work).existsSync(), isTrue);
  });
}
