// ═══════════════════════════════════════════════════════════════════════
//  代理配置缓存 —— 任务 AE 的回归锁（缺口 ①②）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★ 先说清楚这个任务里 ①② 的**真实情况**（与派单描述不同）
//
// 派单说这两个命令「零 UI 调用点」。我做了独立审计
// （`.probe/ae_reach.py`，含**调用图传递闭包**），结论是：
//
// ```text
// has_proxy_password    ✓ 已可达 —— proxy_panel.dart → proxyConfigWithPassword()
//                                  → hasProxyPassword()（**类内裸调用**）
// list_proxy_configs    ✓ 已可达 —— proxy_panel.dart → proxyConfigFor()
//                                  → listProxyConfigs()（同上）
// get_provider_enabled  ✗ 真的不可达  ← 只有这一个是真的缺口
// ```
//
// 为什么上一版审计会误报「零调用点」：它的判据是
// 「在 UI 文件里 grep `SourinApi.xxx(`」。而
// `proxyConfigWithPassword` 内部是**裸调用** `hasProxyPassword(provider)`
// （不带 `SourinApi.` 前缀），于是整条链被漏掉 —— 这是**假红**。
//
// # 那 ①② 的真缺口是什么？—— **没有缓存**（原版专门修过）
//
// 原版 `SettingsView.vue:482-495` 原文：
// > ★ 代理配置的缓存（性能优化，Owner 报「操作卡顿」后加）
// >
// > 实测：一次 5 次切页的操作里 `has_proxy_password` 被调了 **15 次**
// > （每次进设置页都要逐个源问一遍）。而这些数据**极少变化** ——
// > 只在用户自己改代理设置时才会变。
// >
// > 做法：加载过一次就标记，之后进设置页直接用缓存；
// > 用户改了代理设置时主动失效（见 `proxyDirty`）。
//
// 我们这边**放大倍数更大**：面板是**每张源卡片一个**，每个实例
// `initState` 都拉一次 → 26 个源 = 26×(全量 + 密码 + 系统提示) = 78 次 IPC。
//
// # ★ 断言方式（本轮「断言在错误范围上跑」踩了 5 次的教训）
//
// 「有没有缓存」**只能靠计数证明**：
// ```text
// ✗ expect(await proxyConfigFor(id), isNotNull)      ← 恒真，缓存坏了也过
// ✗ expect(a == b, isTrue)  // 两次调用返回相同对象  ← 值相同不代表没重复 IPC
// ✓ expect(ProxyCache.configFetches, 1)              ← 真的抓得到没缓存
// ```
// 所以本文件断言的是 **`ProxyCache.*Fetches` 计数器**，
// 以及**底层命令真的被调了几次**（用 `SourinCore.callAsync` 的计数包装）。
//
// ⚠️ 本文件**不需要 FFI**：`ProxyCache` 的依赖点是
//    `SourinApi.listProxyConfigs()` 等静态方法，用 `TestWidgetsFlutterBinding`
//    + 真实调用会因为没有 `sourin_core.dll` 而失败。
//    所以这里测的是**缓存逻辑本身**（注入假的取值函数），
//    真实 FFI 往返由 `lib/ae_probe.dart` 在真机做。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';

/// 剥掉注释行 —— 静态断言里做文本匹配**必须先剥注释**
///
/// ⚠️ 本项目踩过至少四次：注释里提到某标识符，纯文本匹配把它当真实调用，
///    测试**假绿**。而 `proxy_panel.dart` 文件头正好有一大段
///    「读 → SourinApi.proxyConfigFor(id)」的注释 —— 不剥就必然误判。
String _code(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

void main() {
  group('① 代理缓存 —— 真的省掉了重复 IPC', () {
    setUp(ProxyCache.reset);
    tearDown(ProxyCache.reset);

    test('★★★ 全量配置拉 3 次只穿透 1 次（26 张卡片 = 1 次 IPC）', () async {
      /*
       * ★ 这是"有没有缓存"的**唯一硬判据**。
       *
       * 假 fetcher **自己**计数 —— 断言的是"底层真的被调了几次"，
       * 而不是"计数器字段存在"（后者是恒真的废断言）。
       *
       * 模拟 26 张卡片各拉一次：`ProxyCache.configs()` × 26
       * → 底层必须**只**被调 1 次。
       */
      var realCalls = 0;
      ProxyCache.overrideFetchers(configs: () async {
        realCalls++;
        return {'cctv': const ProxyConfig(mode: ProxyMode.custom, url: 'x')};
      });

      for (var i = 0; i < 26; i++) {
        await ProxyCache.configs();
      }

      expect(
        realCalls,
        1,
        reason: '★★ 26 次读取必须只穿透 1 次 —— 这就是原版"15 次 IPC"要修的东西',
      );
      expect(ProxyCache.configFetches, 1, reason: '内部计数器也要与真实调用一致');
    });

    test('★★ 同一个源问 3 次密码 = 穿透 1 次；不同源各穿透 1 次', () async {
      final seen = <String>[];
      ProxyCache.overrideFetchers(hasPassword: (id) async {
        seen.add(id);
        return id == 'cctv';
      });

      await ProxyCache.hasPassword('cctv');
      await ProxyCache.hasPassword('cctv');
      await ProxyCache.hasPassword('cctv');
      expect(seen, ['cctv'], reason: '同一个源问 3 次 → 底层只该被调 1 次');

      await ProxyCache.hasPassword('bilibili');
      expect(seen, ['cctv', 'bilibili'], reason: '不同源要各问一次（缓存按 id 分键）');

      expect(ProxyCache.passwordFetches, 2);
    });

    test('★★ 系统代理提示全局只问一次', () async {
      var n = 0;
      ProxyCache.overrideFetchers(sysHint: () async {
        n++;
        return 'http://127.0.0.1:7890';
      });

      final a = await ProxyCache.systemHint();
      final b = await ProxyCache.systemHint();
      final c = await ProxyCache.systemHint();

      expect(n, 1, reason: '★ 全局唯一值 → 26 张卡片问一次就够');
      expect(a, 'http://127.0.0.1:7890');
      expect(b, a);
      expect(c, a);
    });

    test('★★ 缓存"空结果"也要缓存（否则每次都要重新穿透）', () async {
      /*
       * ⚠️ 这是个真陷阱：如果实现写成 `if (hit != null && hit.isNotEmpty)`，
       *    那么"没有任何源配过代理"（**最常见的情况**）永远不缓存，
       *    26 张卡片就是 26 次穿透 —— 缓存等于没有。
       */
      var n = 0;
      ProxyCache.overrideFetchers(configs: () async {
        n++;
        return <String, ProxyConfig>{}; // 空的
      });

      await ProxyCache.configs();
      await ProxyCache.configs();
      await ProxyCache.configs();

      expect(n, 1, reason: '★ 空 Map 也必须被缓存（"一个源都没配"是最常见的情况）');
    });

    test('★ reset() 必须把计数归零并还原 fetcher（否则用例互相污染）', () async {
      var n = 0;
      ProxyCache.overrideFetchers(configs: () async {
        n++;
        return {};
      });
      await ProxyCache.configs();
      expect(n, 1);

      ProxyCache.reset();

      expect(ProxyCache.configFetches, 0);
      expect(ProxyCache.passwordFetches, 0);
      expect(ProxyCache.sysHintFetches, 0);
      // fetcher 已还原成真的 SourinApi（没有 DLL → 抛错 = 证明它去穿透了）
      expect(
        () => ProxyCache.configs(),
        throwsA(anything),
        reason: '★ reset() 必须还原 fetcher —— 否则生产代码在测试后被"投毒"',
      );
    });

    test('★★ invalidate() 之后必须重新穿透（不是返回旧值）', () async {
      var n = 0;
      ProxyCache.overrideFetchers(configs: () async {
        n++;
        return {'k': const ProxyConfig()};
      });

      await ProxyCache.configs();
      expect(n, 1, reason: '第一次穿透');

      // 写操作后失效 → 下次必须再穿透
      ProxyCache.invalidate();
      await ProxyCache.configs();
      expect(
        n,
        2,
        reason: '★★ invalidate() 后必须重新穿透 —— 否则用户改完代理看到的是旧值',
      );
    });

    test('★ invalidatePassword 只失效**那一个**源（不动全量配置）', () async {
      var cfgN = 0, pwN = 0;
      ProxyCache.overrideFetchers(
        configs: () async {
          cfgN++;
          return {};
        },
        hasPassword: (id) async {
          pwN++;
          return false;
        },
      );

      await ProxyCache.configs();
      await ProxyCache.hasPassword('a');
      await ProxyCache.hasPassword('b');
      expect([cfgN, pwN], [1, 2]);

      ProxyCache.invalidatePassword('a');
      await ProxyCache.hasPassword('a'); // 要重问
      await ProxyCache.hasPassword('b'); // 不用重问
      await ProxyCache.configs(); // 全量配置不受影响

      expect(
        [cfgN, pwN],
        [1, 3],
        reason: '★ 只失效 a 的密码 → pwN+1；b 仍命中；全量配置保持命中',
      );
    });
  });

  group('② 写路径必须主动失效（原版注释：用户改了代理设置时主动失效）', () {
    late String apiCode;

    setUpAll(() {
      apiCode = _code(File('lib/core/sourin_api.dart').readAsStringSync());
    });

    test('★ setProxyConfig 写后失效缓存', () {
      final i = apiCode.indexOf('setProxyConfig(String provider');
      expect(i >= 0, isTrue, reason: '找不到 setProxyConfig');
      final body = apiCode.substring(i, i + 600);
      expect(
        body.contains('ProxyCache.invalidate()'),
        isTrue,
        reason: '★ setProxyConfig 之后必须失效 —— 否则用户改完看到旧值',
      );
    });

    test('★ clearProxyConfig 写后失效缓存', () {
      final i = apiCode.indexOf('clearProxyConfig(String provider');
      expect(i >= 0, isTrue, reason: '找不到 clearProxyConfig');
      final body = apiCode.substring(i, i + 400);
      expect(body.contains('ProxyCache.invalidate()'), isTrue);
    });

    test('★ setProxyPassword 写后失效该源的密码标记', () {
      final i = apiCode.indexOf('setProxyPassword(String provider');
      expect(i >= 0, isTrue, reason: '找不到 setProxyPassword');
      final body = apiCode.substring(i, i + 500);
      expect(
        body.contains('ProxyCache.invalidatePassword(provider)'),
        isTrue,
        reason: '★ 改密码后那个源的「已保存密码」标记必须失效',
      );
    });

    test('★ 读路径走缓存（不是每次都穿透）', () {
      final i = apiCode.indexOf('proxyConfigFor(String provider');
      expect(i >= 0, isTrue, reason: '找不到 proxyConfigFor');
      final body = apiCode.substring(i, i + 400);
      expect(
        body.contains('ProxyCache.configs()'),
        isTrue,
        reason: '★ proxyConfigFor 必须走共享缓存 —— '
            '26 张卡片各拉一次全量 Map 就是原版那次 15 次 IPC 的放大版',
      );
      expect(
        body.contains('await listProxyConfigs()'),
        isFalse,
        reason: '★ 不得直接穿透（那等于没缓存）',
      );
    });

    test('★ proxyConfigWithPassword 的两个读都走缓存', () {
      final i = apiCode.indexOf('proxyConfigWithPassword(String provider');
      expect(i >= 0, isTrue);
      final body = apiCode.substring(i, i + 500);
      expect(
        body.contains('ProxyCache.hasPassword(provider)'),
        isTrue,
        reason: '★ 密码标记也要走缓存',
      );
      expect(
        body.contains('await hasProxyPassword('),
        isFalse,
        reason: '★ 不得直接穿透',
      );
    });
  });

  group('③ 代理面板接线（缺口 ①② 的落点）', () {
    late String panelCode;

    setUpAll(() {
      panelCode = _code(
        File('lib/ui/widgets/proxy_panel.dart').readAsStringSync(),
      );
    });

    test('★ 面板真的调了那两条 API（不是画了个静态界面）', () {
      expect(
        panelCode.contains('SourinApi.proxyConfigWithPassword('),
        isTrue,
        reason: '这条链最终触达 list_proxy_configs + has_proxy_password',
      );
      expect(
        panelCode.contains('SourinApi.systemProxyHintCached()'),
        isTrue,
        reason: '系统代理提示也走缓存',
      );
    });

    test('★★ 密码状态真的驱动了 UI（不只是读回来丢掉）', () {
      /*
       * 原版 `ProviderProxy.vue:225`：
       * ```html
       * :placeholder="hasPassword ? '已保存密码（留空则不修改）' : '代理密码（可选）'"
       * ```
       * 也就是 `has_proxy_password` 的返回值**必须影响渲染** ——
       * 读回来只存不用的话，那个命令等于没有 UI 入口。
       */
      expect(
        panelCode.contains('cfg.hasPassword'),
        isTrue,
        reason: '★★ has_proxy_password 的结果必须驱动 UI（原版用它改 placeholder）',
      );
    });

    test('★ 写路径（保存配置 / 保存密码 / 清除）都要经过 SourinApi', () {
      for (final m in [
        'SourinApi.setProxyConfig(',
        'SourinApi.setProxyPassword(',
        'SourinApi.clearProxyConfig(',
      ]) {
        expect(panelCode.contains(m), isTrue, reason: '缺少 $m');
      }
    });

    test('★ 缓存不会让"改完密码再看"显示旧值（面板每次进入都重读）', () {
      /*
       * 面板在 `initState` 里 `_load()` —— 每次打开/重建都读一次。
       * 而写路径会 invalidate，所以读到的是新值。
       * 这条断言防的是"有人为了省 IPC 把 _load() 也缓存掉"。
       */
      expect(
        panelCode.contains('_load();'),
        isTrue,
        reason: '★ initState 必须真的调 _load()',
      );
    });
  });

  group('④ 项目铁律（本轮踩过的）', () {
    test('★ 禁止 import package:flutter/material.dart', () {
      for (final f in [
        'lib/ui/widgets/proxy_panel.dart',
        'lib/ui/widgets/source_bar.dart',
        'lib/core/sourin_api.dart',
      ]) {
        final src = File(f).readAsStringSync();
        expect(
          src.contains("package:flutter/material.dart"),
          isFalse,
          reason: '★ $f 不得 import material —— '
              'Flutter 3.47 拆了 material 到 material_ui，混用会造成'
              '"两套 Theme 串台"（本项目因此出过 1.16:1 对比度事故）',
        );
      }
    });

    test('★ 中文注释写"为什么"（原版 15 次 IPC 的教训要在注释里）', () {
      final src = File('lib/core/sourin_api.dart').readAsStringSync();
      expect(
        src.contains('15 次'),
        isTrue,
        reason: '★ 原版那条实测教训（15 次 IPC）必须抄进注释 —— '
            '否则后来者不知道为什么要这个缓存',
      );
    });
  });
}
