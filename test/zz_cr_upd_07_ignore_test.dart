import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_update/app_update_controller.dart';
import 'package:sourin_spike/core/app_update/app_version.dart';
import 'package:sourin_spike/core/app_update/release.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

import 'support/zz_cr_upd_origin.dart';

// ═══════════════════════════════════════════════════════════════════════
//  CR-07 回归测试 —— 「忽略此版本」必须真的不再弹窗
//
//  缺陷：被忽略的版本仍然以 `release != null` 返回，而启动流程只看
//  `res.release == null` 就决定弹不弹窗 ⇒ 忽略按钮等于没按；而且这条分支
//  在写 `_lastCheckAt` **之前**就 return 了，所以 shouldAutoCheck 一直为
//  true ⇒ 每次启动都重新弹同一个被忽略的版本。
// ═══════════════════════════════════════════════════════════════════════

void main() {
  // ★ 故意**不**调 TestWidgetsFlutterBinding.ensureInitialized()：
  //   它会把所有 HttpClient 请求拦成 400（flutter_test 的固定行为），
  //   那样测的就不是真实网络路径了。本组测试不碰 widget，用纯 test() 即可。

  late Directory tmp;
  late TestOrigin api;
  late List<int> releaseJson;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sourin_cr07');
    // UiPrefs.load() 只覆盖文件指针、不清内存 _data ⇒ 必须先 reset，
    // 否则上一个用例写下的 appupdate.lastCheckAt 会漏进下一个用例。
    UiPrefs.debugResetForTest();
    await UiPrefs.load(tmp.path);
    AppVersion.debugSetForTest(const AppVersionInfo(version: '1.0.0', fromRelease: true));
    // 夹具里的最新版本是 v1.1.0，比当前 1.0.0 新 ⇒ 一定会走「有新版」分支
    releaseJson = await File('test/fixtures/github_release_v1_1_0.json').readAsBytes();
    api = await TestOrigin.start({'/repos/sourin-app/sourin/releases/latest': releaseJson});
    AppUpdateController.debugSetApiBaseForTest(api.base);
  });

  tearDown(() async {
    AppUpdateController.debugSetApiBaseForTest(null);
    AppUpdateController.assetUrl =
        'https://github.com/' + AppUpdateController.repoOwner + '/' + AppUpdateController.repoName + '/releases/download';
    await api.stop();
    AppVersion.debugSetForTest(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('CR-07 被忽略的版本', () {
    test('自动检查遇到已忽略版本：release 必须为 null（否则启动照样弹窗）', () async {
      final c = AppUpdateController.instance..loadPrefs();
      c.ignoreVersion('v1.1.0');

      final res = await c.check();

      print('[CR-07A] release=' + res.release.toString() +
          ' message=' + res.message.toString() +
          ' lastCheckAt=' + c.lastCheckAt.toString());
      expect(res.checked, isTrue);
      // ★ 判据：忽略 ⇒ 对调用方等价于「没有新版本」，启动流程才不会弹窗
      expect(res.release, isNull,
          reason: '忽略后仍返回 release，启动流程照样会弹窗 —— 忽略按钮等于没按');
    });

    test('自动检查遇到已忽略版本：必须记下检查时间（否则每次启动都查都弹）', () async {
      final c = AppUpdateController.instance..loadPrefs();
      c.ignoreVersion('v1.1.0');
      // ignoreVersion() 不写检查时间，所以前置就是 null

      await c.check();

      expect(c.lastCheckAt, isNotNull,
          reason: '忽略了却没写 lastCheckAt ⇒ shouldAutoCheck 仍为 true ⇒ 每次启动都弹');
      expect(c.shouldAutoCheck, isFalse);
    });

    test('手动检查仍应把该版本交回「关于」页（不能把手动路径也一起掐掉）', () async {
      final c = AppUpdateController.instance..loadPrefs();
      c.ignoreVersion('v1.1.0');

      final res = await c.check(manual: true);

      print('[CR-07C] manual release=' + res.release.toString());
      expect(res.release?.tag, 'v1.1.0',
          reason: '手动查「关于」页要能再次看到被忽略的版本，用户才有机会反悔');
    });

    test('没被忽略的版本：release 照旧返回（防矫枉过正）', () async {
      final c = AppUpdateController.instance..loadPrefs();

      final res = await c.check();

      print('[CR-07D] release=' + res.release.toString());
      expect(res.release?.tag, 'v1.1.0');
      expect(c.lastCheckAt, isNotNull);
    });
  });
}
