// ═══════════════════════════════════════════════════════════════════════
//  ⑳ 下载目录可配置 —— **真实读写文件系统**的探针
// ═══════════════════════════════════════════════════════════════════════
//
// 为什么不能只做"纯函数单测"：
//   `DownloadDir` 的语义**全在文件系统上** —— root() 会 create(recursive:true)、
//   forWork() 会建剧名文件夹。不真的碰盘，就测不出"用户填了个不存在的盘符
//   会不会退回去"这种事。
//
// ⚠️ 隔离：本探针**只**用 .probe 下的临时目录当"用户指定目录"，
//   绝不碰 %APPDATA%\app.sourin.player，也绝不写用户的 Videos。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory('D:\\WishProject\\sourin-flutter-spike\\.probe\\t3_20\\dl')
      ..createSync(recursive: true);
    // 每个用例从"空偏好"开始（UiPrefs 是 static，不重置会互相串）
    UiPrefs.debugResetForTest();
    DownloadDir.debugReset();
  });

  tearDown(() {
    UiPrefs.debugResetForTest();
    DownloadDir.debugReset();
  });

  test('① 没配置 ⇒ 走默认（非空、且目录真实存在）', () async {
    expect(DownloadDir.hasConfiguredDir, isFalse);
    final r = await DownloadDir.root();
    debugPrint('DIR[默认] = $r');
    expect(r, isNotEmpty);
    expect(Directory(r).existsSync(), isTrue, reason: '★ root() 必须保证目录真实存在');
  });

  test('② 配置了有效目录 ⇒ root() 真的返回它，且被创建出来', () async {
    final target = Directory('${tmp.path}\\my-custom')..createSync(recursive: true);
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
    final target = '${tmp.path}\\case3-only\\not-yet-made\\deep';
    DownloadDir.setConfiguredDir(target);
    final r = await DownloadDir.root();
    debugPrint('DIR[自动建] = $r');
    expect(r, target, reason: '★ 不存在的目录应当被 create(recursive: true) 建出来');
    expect(Directory(target).existsSync(), isTrue);
  });

  test('④ ★★ 配置了**建不出来**的目录（非法路径）⇒ 必须退回默认，不许整体失败', () async {
    // Windows 上 NUL 关键字 + 空字符做路径，create 必失败
    DownloadDir.setConfiguredDir('\u0000bad\\u0000path');
    final r = await DownloadDir.root();
    debugPrint('DIR[非法路径退回] = $r');
    expect(r, isNot(contains('bad')), reason: '★ 不能用那个非法路径');
    expect(Directory(r).existsSync(), isTrue, reason: '★ 退回来的目录必须可用');
  });

  test('⑤ 清空配置 ⇒ 立刻回到默认（_cached 必须被清掉）', () async {
    final target = Directory('${tmp.path}\\custom2')..createSync(recursive: true);
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
    final target = Directory('${tmp.path}\\root6')..createSync(recursive: true);
    DownloadDir.setConfiguredDir(target.path);
    final work = await DownloadDir.forWork('我的剧');
    debugPrint('DIR[forWork] = $work');
    expect(work.startsWith(target.path), isTrue, reason: '★ 必须落在自定义根下');
    expect(Directory(work).existsSync(), isTrue);
  });
}
