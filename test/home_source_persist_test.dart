// ═══════════════════════════════════════════════════════════════════════
//  首页选中源的持久化
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户指出：「首页的选中源记录」
//
// 之前 `_currentSource` **只在内存里** —— 关掉应用再打开就回到第一个源。
// 用户在 25 个源里选了一个想看的，下次打开又得重选。
//
// # 原版怎么做（`src/stores/app.ts`）
//
// ```ts
// const HOME_SOURCE_KEY = "dsh.homeSource";
// const homeSource = ref<string>(readHomeSource());
// watch(homeSource, (v) => { /* 300ms 防抖写 localStorage */ });
// ```
//
// # ★ 最容易做错的一点：键必须**独立**
//
// 原版注释专门解释了：
// > 它和播放偏好（`dsh.playprefs`）没关系。混在一起的话，
// > 「清空播放偏好」会顺带把首页选中的源也清掉 ——
// > 那是两件不相干的事。
//
// 我们已有的 `UiPrefs.sourcePref` 是 `dsh.srcpref.<provider>:<id>`
// —— 那是**「某作品用哪条播放线路」**，与「首页看哪个内容源」
// 完全是两回事。把首页源塞进那个命名空间会导致：
// ```text
// · 清播放偏好时误删首页选择
// · 键名语义混乱（一个 key 两种含义）
// ```
//
// ⚠️ 本文件用**真实 `UiPrefs`** 测（不是复刻一份）——
//    这是我前几轮反复踩的坑：「测了抽出来的影子，没测真实路径」。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/ui_prefs.dart';

void main() {
  group('首页选中源的持久化', () {
    setUp(() {
      // 每个用例开始前清干净
      UiPrefs.setHomeSource('');
    });

    tearDown(() {
      UiPrefs.setHomeSource('');
    });

    test('★ 键名必须是 dsh.homeSource（与原版一致，便于将来迁移）', () {
      expect(
        UiPrefs.homeSourceKey,
        'dsh.homeSource',
        reason: '键名要与原版 `HOME_SOURCE_KEY` 完全相同 —— '
            '将来做"从原版导入设置"时能直接对上',
      );
    });

    test('★★ 键必须**独立于**播放源偏好（原版专门强调过）', () {
      /*
       * 原版注释：
       * > 它和播放偏好没关系。混在一起的话，「清空播放偏好」会顺带
       * > 把首页选中的源也清掉 —— 那是两件不相干的事。
       */
      expect(
        UiPrefs.homeSourceKey.startsWith('dsh.srcpref.'),
        isFalse,
        reason: '★ 不得塞进 `dsh.srcpref.*` 命名空间 —— 那是'
            '「某作品用哪条播放线路」，与「首页看哪个内容源」是两回事',
      );

      // 实证：设了首页源之后，播放源偏好不受影响；反过来也一样
      UiPrefs.setHomeSource('provider-A');
      UiPrefs.setSourcePref('prov', 'id1', 'line-x');

      expect(UiPrefs.homeSource, 'provider-A',
          reason: '写播放源偏好不该覆盖首页源');
      expect(UiPrefs.sourcePref('prov', 'id1'), 'line-x',
          reason: '写首页源不该覆盖播放源偏好');
    });

    test('★ 写入后能读回（往返一致）', () {
      UiPrefs.setHomeSource('bilibili');
      expect(UiPrefs.homeSource, 'bilibili');
    });

    test('★ 传空串 = 清除（与原版 removeItem 等价）', () {
      UiPrefs.setHomeSource('bilibili');
      expect(UiPrefs.homeSource, 'bilibili');

      UiPrefs.setHomeSource('');
      expect(
        UiPrefs.homeSource,
        '',
        reason: '空串应清除 —— 读回来是空串',
      );
      expect(
        UiPrefs.get(UiPrefs.homeSourceKey),
        isNull,
        reason: '★ 必须是**真的删掉这个键**，而不是存一个空串进 JSON —— '
            '后者会在文件里留 `"dsh.homeSource": ""` 的垃圾键',
      );
    });

    test('★ 没设过时返回空串（不是 null，调用方少一层判空）', () {
      expect(UiPrefs.homeSource, '');
    });
  });

  group('首页源码里的接线（静态断言真实路径）', () {
    late String src;

    setUpAll(() {
      src = File('lib/ui/home_page.dart').readAsStringSync();
    });

    test('★ 初始值来自 UiPrefs（而不是空的字符串字面量）', () {
      expect(
        src.contains('String _currentSource = UiPrefs.homeSource;'),
        isTrue,
        reason: '★ `_currentSource` 的初始值必须从 `UiPrefs` 读 —— '
            '写 `= \'\'` 就是"不记忆"，正是用户指出的问题',
      );
      expect(
        src.contains("String _currentSource = '';"),
        isFalse,
        reason: '不得留下空的字面量初始化',
      );
    });

    test('★ 切换源时要落盘', () {
      expect(
        src.contains('UiPrefs.setHomeSource(id);'),
        isTrue,
        reason: '用户点选某个源后必须持久化',
      );
    });

    test('★ 回退到第一个源时也要落盘（避免存脏数据）', () {
      /*
       * 场景：上次选的源被停用/删掉了 → 回退到第一个。
       * 不写盘的话，`UiPrefs` 里还存着那个**已失效的 id**，
       * 下次启动读到它、又走一遍回退逻辑 —— 功能没错，但存的是脏数据。
       */
      expect(
        src.contains('UiPrefs.setHomeSource(current);'),
        isTrue,
        reason: '★ 回退路径也要落盘 —— 否则 UiPrefs 里一直存着'
            '那个已失效的源 id',
      );
    });
  });
}
