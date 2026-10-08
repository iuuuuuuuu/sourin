// ═══════════════════════════════════════════════════════════════════════
//  task-88：云盘同步**整块**搬进「备份与恢复」二级页 —— 结构回归锁
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（2026-09-29）
// ```text
// 云盘同步合并到备份二级页去
// ```
//
// # 这次搬了什么（四个东西，一个都不能留在一级页）
// ```text
// ① UI 区块      settings_page.dart 的 `_Block(title: '云盘同步', …)`
// ② 四个方法     _configureWebdav / _testSync / _syncNow / _disconnectSync
// ③ 对话框       `_WebdavDialog` + `_WebdavDialogState`
// ④ 状态字段     `SyncStatus? _sync` / `bool _syncBusy`
// ⑤ 数据加载     loadAll() 里 Future.wait 的第 4 项 + `results[3]`
// ```
// ⇒ 全部落进**新建的** `lib/ui/widgets/sync_panel.dart`（自包含面板）。
//
// # ★ 为什么这个文件必须存在（不是"锦上添花"）
//
// 这次改动的**唯一验收判据**是"一级页里没有它、二级页里有它"。
// 而那个判据：
// ```text
// ✗ 编译通过证明不了（删掉一块 UI 照样编译）
// ✗ 全量测试绿证明不了（没有任何既有测试引用它）
// ✗ 真机截图**当时**能证明，但**下次**有人搬回去时不会再跑一遍
// ```
// ⇒ 静态结构锁是唯一能**长期**守住"位置"这一事实的东西。
//
// # ★★★ 本文件的核心难点：剥注释（不然全是假绿）
//
// 搬运时我**刻意**在一级页留下了说明注释，里面**逐字提到**
// `_WebdavDialog` / `syncStatus` / `SyncPanel` / `云盘同步`：
// ```text
// /* ── 云盘同步 ── ★ 2026-09-29 整块搬走 …
//    四个方法 _configureWebdav / _testSync / _syncNow / _disconnectSync
//    现在在 widgets/sync_panel.dart 的 _SyncPanelState 里 … */
// ```
// ⇒ 若断言 `raw.contains('SyncStatus')`，**注释会命中** ⇒ 断言恒假红；
//   反过来若有人只把**代码**搬回去、注释留着，恒真绿。
// ⇒ **必须先剥注释，再断言**（铁律 170）。
//
// # ★ 铁律 170：剥注释只有一个实现
//
// `test/_support/strip_comments.dart` 是**唯一**共享实现，文件头逐字写着：
// ```text
// 「★ 判据：写静态断言前，**先找仓里有没有既有的剥注释 helper**；
//   有就**必须用**（import 本文件），**不许**再抄一份。」
// ```
// 本仓已经因为这个踩过坑（`test/search_all_test.dart` 断言
// `_watchReplay` 存在，而它当时**只剩注释** ⇒ 代码里没了、测试却是绿的）。
// ⇒ 所以本文件 `import '_support/strip_comments.dart';`，
//   **不**像其它 20+ 个文件那样各抄一份状态机。
//
// # ★★ 阳性对照：为什么"断言不存在"必须配"断言存在"
//
// 本文件一半的断言是 `isFalse`（"一级页里没有 X"）。
// **一个什么都不做的 strip（比如把全文剥成空串）会让所有 isFalse 全绿。**
// ⇒ 所以每组阴性断言旁边都配一组**阳性对照**（"一级页里必须有 Y"），
//   证明 ① 文件真的读到了 ② strip 没有把代码也吃掉。
//
// # 真机取证（本文件的**补集**，不是替代）
//
// 静态锁只证明"源码里没有"，证明不了"跑起来真的在二级页"。
// 后者由 `lib/t87_cloudsync_probe.dart` 做（挂**生产整棵树**、
// 真点入口行、真扫两级页全区间、真弹对话框）：
// ```text
// [T87] RESULT tag=cloudsync pass=50 fail=0
//   ② 一级页扫到 32 条文本，「云盘同步」= false（阳性对照 6 条全中）
//   ④ 二级页扫到 30 条文本，「云盘同步」= true
//      SyncPanel 祖先链里有 SettingsSubPage、没有 SettingsPage
// ```
// ⇒ 分工：本文件守**长期**（每次 CI 跑），探针守**当下**（一次性真机）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '_support/strip_comments.dart';

// ── 被测文件（真源码，不是 .probe 下的旧副本）────────────────────────
//
// ⚠️ `.probe/` 下有 7 份 `settings_page.dart` 的历史副本
//    （`settings_page.dart.bak29` / `v46c-src/` / `v60-src/` / `t3cmp/` /
//     `v48-src/` / `t43-redness/` / `lib/ui/settings_page.dart.t23bak`）
//    —— 它们**全是搬走之前的**，拿错一个就会得到"云盘同步还在"的假红。
const _host = 'lib/ui/settings_page.dart';
const _subPage = 'lib/ui/settings/backup_page.dart';
const _panel = 'lib/ui/widgets/sync_panel.dart';

String _codeOf(String path) => stripComments(File(path).readAsStringSync());

void main() {
  group('① 一级页：云盘同步的**代码**必须清零（配阳性对照）', () {
    late String code;

    setUpAll(() {
      code = _codeOf(_host);
    });

    test('★ 阳性对照：一级页确实读到了（否则下面的 isFalse 全是假绿）', () {
      /*
       * 这组断言存在的**唯一**理由，是给下面的阴性断言当"仪器灵敏度证明"。
       * 若 strip 把代码也吃掉了，或者路径写错了读到空文件，
       * 这一组会先红 ⇒ 不会出现"阴性全绿但其实什么都没测"。
       */
      for (final anchor in const [
        '内容源、网络与同步', // 页头副标题
        '局域网遥控', // 保留在一级页的区块（方案 A 之后）
        'JS 插件', // 同上
        '备份与恢复', // ★ 二级页入口行 —— 搬迁的**起点**
        'BackupSettingsPage', // 入口行 push 的目标
        '_openSubPage', // 入口行的导航方法
        'results[0]', // loadAll 的返回值下标（证明 strip 保留了代码）
        'results[2]', // ★ 删掉第 4 项后**最后**一个有效下标
      ]) {
        expect(
          code.contains(anchor),
          isTrue,
          reason: '★ 阳性对照失败：一级页代码里找不到 `$anchor` ⇒ '
              '要么文件路径错了，要么 stripComments 把代码也剥掉了。'
              '**此时下面的阴性断言全部无信息量**（会假绿）。',
        );
      }
    });

    test('★★★ 核心阴性：四个方法名 + 对话框 + 状态类型全不在代码里', () {
      /*
       * ★ 这六个 token 是**代码级**身份：
       *   `SyncStatus` / `SyncPanel` 是类型
       *   `_WebdavDialog` 是对话框类
       *   其余四个是 `SourinApi` 的调用名（在方法名里）
       * ⇒ 只要它们**出现在代码里**，就说明有人把云盘同步又搬回来了。
       */
      for (final gone in const [
        'SyncStatus',
        'SyncPanel',
        '_WebdavDialog',
        'configureWebdav',
        'testSync',
        'syncNow',
        'disconnectSync',
        'syncStatus',
      ]) {
        expect(
          code.contains(gone),
          isFalse,
          reason: '★★★ 一级页代码里出现了 `$gone` ⇒ 云盘同步又被搬回一级页了。'
              '（用户 2026-09-29 要求它住在「备份与恢复」二级页）',
        );
      }
    });

    test('★★ loadAll() 的下标已收缩到 3（防 `results[3]` 复活/越界）', () {
      /*
       * 删掉 `Future.wait` 第 4 项之后，合法下标是 `results[0..2]`。
       * 这里**不是**在测"下标对不对"（那是运行时的事），
       * 而是在锁"这次改动的形状"：
       * ```text
       * 若有人把 `SourinApi.syncStatus()` 加回 Future.wait 而忘了
       * 同步加 `results[3]` 的赋值 ⇒ 运行时才炸（且只在真机上）
       * 若有人把 `results[3]` 留下而删了第 4 项 ⇒ 立即 RangeError
       * ```
       * ⇒ 两个方向都锁：`results[3]` **不存在**。
       */
      expect(
        code.contains('results[3]'),
        isFalse,
        reason: '★★ 一级页的 loadAll 里出现了 `results[3]` —— '
            '第 4 项（syncStatus）已随云盘同步搬走，下标只有 0..2；'
            '留着它会在真机上 RangeError',
      );
    });
  });

  group('② 二级页：真的挂了 SyncPanel', () {
    late String code;

    setUpAll(() {
      code = _codeOf(_subPage);
    });

    test('★ 阳性对照：二级页确实读到了', () {
      for (final anchor in const [
        'SettingsSubPage(',
        "title: '备份与恢复'",
        'BackupPanel()',
        'SyncPanel()',
        'SettingsBlock(',
      ]) {
        expect(
          code.contains(anchor),
          isTrue,
          reason: '★ 阳性对照失败：二级页代码里找不到 `$anchor`',
        );
      }
    });

    test('★★★ 核心阳性：SyncPanel 出现在**备份之后**（同页两个区块）', () {
      /*
       * ★ 只断言"存在"不够 —— 还要断言**顺序**：
       * 用户说的是"合并到备份二级页"，视觉上应该是
       * ```text
       * 备份与恢复
       *   ├─ 备份        ← 先
       *   └─ 云盘同步    ← 后
       * ```
       * 若顺序反了，页面读起来像"云盘页里塞了个备份"。
       */
      final backupAt = code.indexOf('BackupPanel()');
      final syncAt = code.indexOf('SyncPanel()');
      expect(backupAt > 0, isTrue, reason: '★ 前置：必须能找到 BackupPanel()');
      expect(syncAt > 0, isTrue, reason: '★ 前置：必须能找到 SyncPanel()');
      expect(
        syncAt > backupAt,
        isTrue,
        reason: '★★ 云盘同步必须排在备份**之后** —— 用户要的是"备份二级页"，'
            '备份是主、云盘是副',
      );
    });

    test('★ build 仍是 const（两个面板都自包含 ⇒ 本页零状态传递）', () {
      /*
       * 这不是洁癖 —— `const` 是**结构性证据**：
       * 它只有在"两个面板都不需要本页传任何参数/回调"时才可能成立。
       * 若将来有人给 `SyncPanel` 加 `onChanged: () => setState(...)`，
       * 这个 `const` 立刻编译不过 ⇒ 强制他重新想清楚宿主依赖。
       */
      expect(
        code.contains('return const SettingsSubPage('),
        isTrue,
        reason: '★ 二级页的 build 必须仍是 `const SettingsSubPage(` —— '
            '两个面板都是无参自包含 widget；若这里不再 const，'
            '说明有人给面板加了宿主回调（会破坏自包含性）',
      );
    });
  });

  group('③ 面板：自包含（task43 结构测试对它正确地静默）', () {
    late String code;

    setUpAll(() {
      code = _codeOf(_panel);
    });

    test('★ 阳性对照：五个云盘 API 的调用点都在这个面板里', () {
      for (final call in const [
        'SourinApi.configureWebdav(',
        'SourinApi.testSync(',
        'SourinApi.syncNow(',
        'SourinApi.disconnectSync(',
        'SourinApi.syncStatus()',
      ]) {
        expect(
          code.contains(call),
          isTrue,
          reason: '★ 阳性对照失败：`sync_panel.dart` 里找不到 `$call` ⇒ '
              '面板没把能力带过来（搬了个空壳）',
        );
      }
    });

    test('★★★ 自包含：不碰宿主（无 host / 无 _dataRev / 无 _toastRev）', () {
      /*
       * ★ 这条是**为了 task43 那条结构测试**才必须成立的：
       * `test/task43_plugins_subpage_test.dart:460-506` 规定
       * 「凡是名字像 `_\\w+PageState` **或** 体内用到 `host` 的 State，
       *   都必须订阅 `valueListenable: host._dataRev` 与 `host._toastRev`」。
       * ```text
       * `_SyncPanelState` 名字**不像** `_XxxPageState`（不是二级页）
       * 且**不用** `host` ⇒ 它正确地**不在**候选集里 ⇒ 那条测试对它静默。
       * ★ 但这是**脆的**：只要有人在面板里写一句 `host.`，
       *   它立刻被拉进候选集，task43 会红 —— 而报错信息指向 task43，
       *   不指向这里 ⇒ 那时候很难查。
       * ⇒ 所以在本文件里**提前**把它锁死。
       * ```
       */
      for (final forbidden in const ['host.', '_dataRev', '_toastRev']) {
        expect(
          code.contains(forbidden),
          isFalse,
          reason: '★★ 云盘同步面板里出现了 `$forbidden` ⇒ 它不再是自包含面板。'
              '若确实需要订阅宿主，必须**同时**去 '
              '`test/task43_plugins_subpage_test.dart` 更新候选集口径',
        );
      }
    });

    test('★ 是 const 无参 widget（与 BackupPanel 同构）', () {
      expect(
        code.contains('const SyncPanel({super.key})'),
        isTrue,
        reason: '★ 必须与 `const BackupPanel({super.key})` 同构 —— '
            '无参、无回调，宿主只要写 `SyncPanel()`',
      );
    });
  });

  group('④ ★★ 全仓唯一调用点（防"搬回去"与"复制一份"两个方向）', () {
    /*
     * ★ 这一组是**最强**的守卫，因为它不依赖任何具体文件的内容：
     *   它扫描 `lib/` 全树，断言"改数据的四个 API 全仓只有**一个**调用者"。
     * ```text
     * 方向 A（搬回去）：settings_page.dart 又出现 configureWebdav
     *                   ⇒ 调用者变成 2 个 ⇒ 红
     * 方向 B（复制一份）：新建 sync_panel2.dart 抄一遍
     *                   ⇒ 调用者变成 2 个 ⇒ 红
     * ```
     * ⚠️ 只扫**改数据**的四个（configureWebdav / testSync / syncNow /
     *    disconnectSync）。`syncStatus` 是**只读**查询，合法调用者还有
     *    两个探针 + `about_page.dart`（读设备 ID）⇒ 不能纳入。
     */
    const mutators = <String>[
      'SourinApi.configureWebdav',
      'SourinApi.testSync',
      'SourinApi.syncNow',
      'SourinApi.disconnectSync',
    ];

    test('★★★ 四个改数据的云盘 API，全仓调用者恰好 = [sync_panel.dart]', () {
      final callers = <String, Set<String>>{for (final m in mutators) m: {}};

      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final p = e.path.replaceAll(r'\', '/');
        final code = stripComments(e.readAsStringSync());
        for (final m in mutators) {
          if (code.contains(m)) callers[m]!.add(p);
        }
      }

      for (final m in mutators) {
        expect(
          callers[m],
          {_panel},
          reason: '★★★ `$m` 的调用者必须是且仅是 `$_panel`。\n'
              '实测调用者: ${callers[m]}\n'
              '· 多出 `$_host` ⇒ 云盘同步又被搬回一级页了\n'
              '· 多出别的文件 ⇒ 有人复制了一份面板（两份会漂移）',
        );
      }
    });

    test('★★★ `SyncPanel()` 的使用点全仓恰好 = [backup_page.dart]', () {
      /*
       * 上一条守"能力只有一个实现"，这条守"**页面**只有一个使用者"。
       * 两者是不同的失效模式：
       * ```text
       * 上一条：能力被复制 / 被搬回
       * 这一条：面板被**多处挂载**（比如一级页也挂一个"快捷入口"）
       * ```
       * ⚠️ 用 `SyncPanel()`（带括号）而不是 `SyncPanel` ——
       *    定义文件自己含 `const SyncPanel({super.key})`，
       *    用裸名会把定义处也算成使用点。
       */
      final users = <String>{};
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final p = e.path.replaceAll(r'\', '/');
        if (p == _panel) continue; // 定义处不算使用
        if (stripComments(e.readAsStringSync()).contains('SyncPanel()')) {
          users.add(p);
        }
      }
      expect(
        users,
        {_subPage},
        reason: '★★★ `SyncPanel()` 只应被 `$_subPage` 挂载。\n'
            '实测: $users\n'
            '· 多出 `$_host` ⇒ 云盘同步同时出现在两级页（用户要的是只在二级页）',
      );
    });
  });
}
