import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_update/app_update_controller.dart';
import 'package:sourin_spike/core/app_update/app_version.dart';
import 'package:sourin_spike/core/app_update/release.dart';
import 'package:sourin_spike/core/app_update/route.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 控制器的偏好/节流部分不碰网络，可以在单测里直接驱动。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sourin_update_prefs');
    await UiPrefs.load(tmp.path);
    AppVersion.debugSetForTest(null);
  });

  tearDown(() async {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('自动检查的节流', () {
    test('从没查过 ⇒ 该查', () {
      final c = AppUpdateController.instance..loadPrefs();
      expect(c.shouldAutoCheck, isTrue);
    });

    test('刚查过 ⇒ 今天不再查（每天最多一次）', () async {
      final c = AppUpdateController.instance..loadPrefs();
      UiPrefs.set('appupdate.lastCheckAt', DateTime.now().toIso8601String());
      c.loadPrefs();
      expect(c.shouldAutoCheck, isFalse);
    });

    test('上次是 25 小时前 ⇒ 又可以查了', () async {
      final c = AppUpdateController.instance..loadPrefs();
      UiPrefs.set(
          'appupdate.lastCheckAt',
          DateTime.now().subtract(const Duration(hours: 25)).toIso8601String());
      c.loadPrefs();
      expect(c.shouldAutoCheck, isTrue);
    });

    test('用户关掉自动检查 ⇒ 永远不自动查（但手动仍可用）', () async {
      final c = AppUpdateController.instance..loadPrefs();
      c.setAutoCheck(false);
      c.loadPrefs();
      expect(c.shouldAutoCheck, isFalse);
      expect(c.autoCheck, isFalse);
    });

    test('偏好能落盘并读回', () async {
      final c = AppUpdateController.instance..loadPrefs();
      c.setAutoCheck(false);
      c.setIncludePrerelease(true);
      await UiPrefs.flush();
      UiPrefs.debugResetForTest();
      await UiPrefs.load(tmp.path);
      final c2 = AppUpdateController.instance..loadPrefs();
      expect(c2.autoCheck, isFalse);
      expect(c2.includePrerelease, isTrue);
    });

    test('「忽略此版本」会让该版本不再作为可更新项出现', () {
      final c = AppUpdateController.instance..loadPrefs();
      c.ignoreVersion('v9.9.9');
      expect(c.ignoredVersion, 'v9.9.9');
      c.loadPrefs();
      expect(c.ignoredVersion, 'v9.9.9',
          reason: '忽略状态必须跨启动保留');
    });
  });

  group('下载方式偏好', () {
    test('设成镜像后能读回，并且确实改写下载链接', () {
      final c = AppUpdateController.instance..loadPrefs();
      c.setRoute(const UpdateRouteConfig(
        route: UpdateRoute.mirror,
        mirrorName: 'gh-proxy',
      ));
      c.loadPrefs();
      expect(c.route.route, UpdateRoute.mirror);
      expect(c.route.mirrorPrefix, 'https://gh-proxy.com/');
    });

    test('设成代理后能读回地址与端口', () {
      final c = AppUpdateController.instance..loadPrefs();
      c.setRoute(const UpdateRouteConfig(
        route: UpdateRoute.proxy,
        proxyHost: '127.0.0.1',
        proxyPort: 7890,
      ));
      c.loadPrefs();
      expect(c.route.proxyUri(), 'http://127.0.0.1:7890');
    });
  });

  group('App 版本来源', () {
    test('没注入 dart-define 时回退到兜底版本', () async {
      AppVersion.debugSetForTest(null);
      final v = await AppVersion.load();
      expect(v.version, '1.0.0');
      expect(v.fromRelease, isFalse);
    });

    test('读版本不会抛（平台通道不可用也能给个值）', () async {
      AppVersion.debugSetForTest(null);
      await expectLater(AppVersion.load(), completes);
    });
  });

  group('镜像前缀的可用性', () {
    test('预置的四个镜像都以斜杠结尾（拼接才不会坏）', () {
      for (final m in UpdateMirror.list) {
        expect(m.prefix.endsWith('/'), isTrue, reason: m.name);
        expect(m.prefix.startsWith('https://'), isTrue, reason: m.name);
      }
    });

    test('自定义前缀为空时镜像模式退化为直连，不产生坏 URL', () {
      const c = UpdateRouteConfig(route: UpdateRoute.mirror);
      expect(c.mirrorPrefix, '');
    });
  });

  group('Release JSON 解析的健壮性', () {
    test('assets 字段缺失也不崩（当成没有资产）', () {
      final r = parseReleaseJson({'tag_name': 'v2.0.0'});
      expect(r.assets, isEmpty);
      expect(r.version, '2.0.0');
    });

    test('size 是字符串也能读成数字', () {
      final r = parseReleaseJson({
        'tag_name': 'v2.0.0',
        'assets': [
          {'name': 'a.exe', 'size': '123', 'browser_download_url': 'https://x/a.exe'}
        ],
      });
      expect(r.assets.first.size, 123);
      expect(r.assets.first.prettySize, '123 B');
    });

    test('没有 browser_download_url 的资产被丢掉（没法下）', () {
      final r = parseReleaseJson({
        'tag_name': 'v2.0.0',
        'assets': [
          {'name': 'a.exe', 'size': 1},
        ],
      });
      expect(r.assets, isEmpty);
    });

    test('列表里混入非 Map 元素不抛（那一条被跳过，其余照常）', () {
      final list = parseReleaseListJson(jsonDecode('["x", {"tag_name":"v3.0.0"}]'));
      expect(list.length, 1);
      expect(list.single.tag, 'v3.0.0');
    });
  });
}