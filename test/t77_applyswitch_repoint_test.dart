// ═══════════════════════════════════════════════════════════════════════
//  task-77 —— 播放器内**跨源**换源必须 repoint（与合并页同一条路径）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户看到的缺口（Owner 原话的因果链）
//
// ```text
// 播放器里点「换源」→ 换到**另一个 provider**
//   ⇒ 历史 / 追更 / 收藏里出现**两条**（旧源一条、新源一条）
//   ⇒ 且旧源上的进度**不被带走**
// ```
//
// # 为什么"两条"是必然的（不是偶发）
//
// ```text
// 四张表（favorites / progress / history / skip_markers）的 key 都是
// `<provider>:<id>`（commands_write.rs:42 item_key）
// ⇒ 换了 provider ⇒ key 变了 ⇒ 新源的写入是【新行】，旧行原样留着。
// ```
//
// # 本文件负责的判据（Dart 侧能做到的）
//
// ★★ 诚实的边界：`flutter test` 里 `sourin_core.dll` **必然加载失败**
//    （`lib/core/ffi.dart:169 DynamicLibrary.open('sourin_core.dll')`
//     ⇒ `error code: 126`）⇒ **"真的把行搬过去了"在 Dart 单测里测不了**。
//    那条判据由**两处**覆盖，都不在本文件：
// ```text
// · Rust 单测  store.rs 的 15+ 条 `repoint_*`（四表搬迁 / 合并 / 幂等 / 无墓碑）
// · 真 FFI 探针 .probe/t77_repro_repoint.py（直驱交付 DLL，读 SQLite 行数）
//     实测：A（不迁移）history=2 progress=2 keys=[alpha:show1, beta:show1]
//           B（迁移）  history=1 progress=1 keys=[beta:show1]
// ```
// ⇒ 本文件只断言**接线**（Dart 侧唯一能证明的那一半）：
//    ① `_applySwitch` **真的调**了 `repointItem`
//    ② 传的是**旧值作 from、新值作 to**（写反了就是"把新源记录搬回旧源"）
//    ③ 调用点在 `setState` **之前**（否则拿不到旧源 —— `_resolveAndPlay`
//       会把 `_provider`/`_contentId` 改写成新源）
//    ④ `await` 而非 `unawaited`（否则新源的 save_progress 可能先落库）
//    ⑤ 包在 try/catch 里（**失败不许阻断换源**）
//    ⑥ 换源本身照常成功（`_resolveAndPlay` 仍在）
//
// # 跑法
//
// ```powershell
// & .probe\flutter_test_lock.ps1 -Paths 'test/t77_applyswitch_repoint_test.dart' -Agent add-remote-order
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉行注释与块注释（判据对象是**代码**时必做）
///
/// ★ 与 `test/t67_repoint_test.dart:37`、`test/t67_stage1_symptom_test.dart:56`
///   同一实现。
///   ⚠️ **只剥行注释是不够的** —— 本仓大量长块注释里会**引用**被删掉的旧代码
///      （本文件自己就在注释里写着 `SourinApi.repointItem(...)`！）
///      ⇒ 只剥行注释会让下面那条 `isFalse` 的**反面**断言假绿。
String stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ');
  return noBlock
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');
}

String readCode(String path) => stripComments(File(path).readAsStringSync());

/// 切某个 Dart 方法的函数体（按**大括号配平**，不靠魔数）
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ 为什么不能 `substring(i, i + N)`
/// ══════════════════════════════════════════════════════════════════
/// `t67_repoint_test.dart:175-199` 记着同族的血账 —— 那里 ①③④ 三条断言
/// 原来用 `i + 1600` / `i + 2500` / `i + 17000` 三个魔数，**各错各的**：
/// ```text
/// · i + 1600  越过函数结束大括号 ⇒ 把下一个方法的 key 也收进来（**假红**）
/// · i + 2500  超出文件末尾       ⇒ substring 抛异常（不是断言失败）
/// · i + 17000 恰好盖住目标       ⇒ 纯属侥幸（往函数里加 10 行注释就失效）
/// ```
/// ⇒ 判据的边界要**算出来**，不许**估一个够大的数**。
///
/// ★ 本例的 `_applySwitch` 尤其危险：它内部嵌套 try / if / setState 三层，
///   任何魔数窗口都可能只切到一半 —— 而"只切到一半"的症状恰好是
///   **找不到 repointItem** ⇒ 会得到一个**看起来合理的假红**。
String dartFnBody(String path, String signature) {
  final code = readCode(path);
  final at = code.indexOf(signature);
  expect(at, greaterThan(-1), reason: '★ 找不到 `$signature`（$path）');

  final open = code.indexOf('{', at);
  expect(open, greaterThan(-1), reason: '`$signature` 后面必须有 `{`');

  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}') {
      depth--;
      if (depth == 0) return code.substring(at, i + 1);
    }
  }
  fail('`$signature` 的大括号不配平');
}

/// 把 `_applySwitch` 里**包住 repointItem 的那个 catch 块**切出来
///
/// ★ 存在理由（照抄 `t67_repoint_test.dart:70-103` 的教训）：
///   只断言"出现过 `catch`"是**假绿洞** —— `.probe\t67u_dart_redproof.py`
///   的 M11 变异在 `} catch (e) {` 之后插一行 `rethrow;`，
///   于是后面的代码**永远不可达**（= 换源被阻断），
///   而原来四条"结构位置"断言**全部照绿**。
/// ⇒ 要断言的是 **catch 体内部做了什么**，不是"catch 这个词出现过"。
String repointCatchBody(String body) {
  final iRepoint = body.indexOf('repointItem');
  expect(iRepoint, greaterThan(-1), reason: '★ 必须能找到 repointItem');

  final catchAt = body.indexOf('} catch', iRepoint);
  expect(catchAt, greaterThan(-1),
      reason: '★ repointItem 之后必须有 `} catch` —— 否则迁移失败会打断换源');

  final open = body.indexOf('{', catchAt);
  expect(open, greaterThan(-1), reason: 'catch 后面必须有 `{`');

  var depth = 0;
  for (var i = open; i < body.length; i++) {
    if (body[i] == '{') depth++;
    if (body[i] == '}') {
      depth--;
      if (depth == 0) return body.substring(open, i + 1);
    }
  }
  fail('catch 块的大括号不配平');
}

void main() {
  const playerPage = 'lib/ui/player_page.dart';
  const applySwitchSig = 'Future<void> _applySwitch(SwitchPick p) async {';

  group('⑦ ★★★ task-77：播放器内跨源换源要 repoint（此前**没有**这一步）', () {
    test('★★★ _applySwitch 里必须真的调 repointItem', () {
      final body = dartFnBody(playerPage, applySwitchSig);

      // ★ 仪器自检 —— 先证明"切出来的真是那个函数体"。
      //   否则下面的断言可能是在一个空串/错片段上通过或失败。
      expect(body.contains('_resolveAndPlay'), isTrue,
          reason: '★ 仪器自检：`_applySwitch` 结尾确实调 `_resolveAndPlay`'
              '（`player_page.dart:3405` 附近）—— 切错片段就没有它');
      expect(body.contains('_flash'), isTrue,
          reason: '★ 仪器自检：`_applySwitch` 里有 `_flash`（进度提示）');

      expect(body.contains('repointItem'), isTrue,
          reason: '★★★ task-77 缺口：`_applySwitch` **必须**调 '
              '`SourinApi.repointItem` —— 否则跨源换源后同一部剧在'
              '历史/追更/收藏里是**两条**（旧源一条、新源一条），'
              '且旧源进度不被带走。'
              '★ 合并页 `lib/ui/media_page.dart:476` 早就调了，'
              '播放器内漏了 —— 这就是"两条路不一致"。');
    });

    test('★★★ from 用**旧值**、to 用**新值**（写反了就是把新源搬回旧源）', () {
      final body = dartFnBody(playerPage, applySwitchSig);

      final m = RegExp(
        r'await\s+SourinApi\.repointItem\(\s*'
        r'fromProvider:\s*_provider\s*,\s*'
        r'fromId:\s*_contentId\s*,\s*'
        r'toProvider:\s*p\.provider\s*,\s*'
        r'toId:\s*p\.id\s*,?\s*\)',
      ).firstMatch(body);

      expect(m, isNotNull,
          reason: '★★★ 参数必须是 '
              '`fromProvider: _provider, fromId: _contentId, '
              'toProvider: p.provider, toId: p.id`。\n'
              '★ 为什么 from 只能是 `_provider`/`_contentId`：'
              '它们是**当前正在播的**（= 旧源），'
              '而 `SwitchPick`（`source_switch_dialog.dart:93-107`）'
              '里只有**新源**的 provider/id ⇒ 换源前的旧源**只能**从'
              '这两个字段取。\n'
              '★ 写反的后果：把**新源**的记录搬到**旧源**上 —— '
              '用户换到新源，记录却留在旧源，比不迁移更糟。');
    });

    test('★★★ 调用点在 setState **之前**（否则再也拿不到旧源）', () {
      final body = dartFnBody(playerPage, applySwitchSig);

      final iRepoint = body.indexOf('repointItem');
      expect(iRepoint, greaterThan(-1), reason: '★ 必须能找到 repointItem');

      // ★ 用**方法调用**定位 setState，不用字段名（`_provider` 到处都是）
      final iSetState = body.indexOf('setState(');
      expect(iSetState, greaterThan(-1), reason: '★ 必须能找到 setState');

      expect(iRepoint, lessThan(iSetState),
          reason: '★★★ 迁移必须在 `setState` **之前**。\n'
              '★ 理由（`media_page.dart:434-474` 的裁决逐字）：'
              '「`_provider` 一旦被改写，下面就再也拿不到"旧源是谁"了」。\n'
              '★ 在 `_applySwitch` 里这条**更紧**：`setState` 之后紧接着'
              '`_resolveAndPlay`（`:3405` 附近），而它**自己也会 setState** '
              '把 `_provider`/`_contentId` 改写成新源（`:4508-4518`）'
              '⇒ 那时 from 就变成新源了，迁移会把新源搬到新源（空操作）。');

      // ★ 更强的判据：迁移必须在 **_resolveAndPlay 之前**
      final iResolve = body.indexOf('_resolveAndPlay');
      expect(iResolve, greaterThan(-1), reason: '★ 必须能找到 _resolveAndPlay');
      expect(iRepoint, lessThan(iResolve),
          reason: '★★★ 迁移必须在 `_resolveAndPlay` **之前** —— '
              '它会**立刻起播并写新进度**，而 `_provider` 也在那里被改写');
    });

    test('★★★ 必须 `await`（不是 unawaited —— 否则新进度先落库会被覆盖）', () {
      final body = dartFnBody(playerPage, applySwitchSig);

      expect(RegExp(r'await\s+SourinApi\.repointItem\(').hasMatch(body), isTrue,
          reason: '★★★ 必须 `await`。\n'
              '★ 理由（`media_page.dart` 裁决逐字）：迁移是一个事务、很快'
              '（纯本地 SQLite，无网络）；而紧接着的换源会**立刻起播**并'
              '**写新进度** —— 若迁移还没做完，新源的 save_progress 可能'
              '先落库，之后迁移再"把旧行合并进新行"就会把刚写的进度覆盖掉。');

      expect(RegExp(r'unawaited\s*\(\s*SourinApi\.repointItem\(').hasMatch(body),
          isFalse,
          reason: '★★★ 不许用 `unawaited` 包 —— 那就是上面那个覆盖竞态');
    });

    test('★★★ 失败**不阻断**换源（catch 住 + 继续走 _resolveAndPlay）', () {
      final body = dartFnBody(playerPage, applySwitchSig);

      // ① repointItem 必须在 try 里
      final iRepoint = body.indexOf('repointItem');
      final iTry = body.lastIndexOf('try {', iRepoint);
      expect(iTry, greaterThan(-1),
          reason: '★★★ repointItem 必须在 `try {` 里 —— '
              '否则迁移一失败就抛到外层 catch，**换源直接失败**');

      // ② catch 体里**不许**有 rethrow / return / 抛异常（= 不许阻断）
      final catchBody = repointCatchBody(body);
      expect(catchBody.contains('rethrow'), isFalse,
          reason: '★★★ catch 里**不许** `rethrow` —— '
              '这正是 `.probe\t67u_dart_redproof.py` 的 M11 变异：'
              '它让后面的代码永远不可达 = **换源被阻断**，'
              '而当时四条"结构位置"断言**全部照绿**（假绿洞）。\n'
              '★ 用户视角：记录搬不动也得让用户能看 —— '
              '换源本身是用户刚做的动作。');
      expect(RegExp(r'\breturn\b').hasMatch(catchBody), isFalse,
          reason: '★★★ catch 里不许 `return` —— 同样是阻断换源'
              '（`media_page.dart` 的裁决是"只记日志、继续往下走"）');
      expect(catchBody.contains('debugPrint'), isTrue,
          reason: '★★★ catch 里必须**如实记日志**（debugPrint）—— '
              '静默吞掉会让"记录没搬过去"变成无法诊断的问题');

      // ③ 迁移之后仍然要走到 _resolveAndPlay（换源照常成功）
      final iResolve = body.indexOf('_resolveAndPlay');
      expect(iResolve, greaterThan(iRepoint),
          reason: '★★★ 换源本身必须照常成功 —— '
              '`_resolveAndPlay` 要仍在迁移**之后**被执行');
    });

    test('★★★ 同 provider 的情形**不在 Dart 侧判**（判据只有一份）', () {
      final body = dartFnBody(playerPage, applySwitchSig);

      expect(body.contains('commands_write.rs'), isFalse,
          reason: '★ 仪器自检：判据对象是**代码**，注释已被剥掉 —— '
              '若这里还能看到 `.rs` 文件名，说明 stripComments 没生效');

      // ★ 关键：Dart 侧**不许**自己加一道 `p.provider == _provider` 守卫。
      //   理由：Rust `commands_write.rs:527` 已有
      //   `if from_provider == to_provider { … return Ok(()); }`
      //   ⇒ 两道守卫 = 两份判据 = 迟早漂移
      //   （本仓铁律：判据只有一份）。
      expect(
        RegExp(r'if\s*\(\s*p\.provider\s*==\s*_provider\s*\)').hasMatch(body),
        isFalse,
        reason: '★★ 不许在 Dart 侧另写一道"同 provider 就不迁移"的守卫 —— '
            'Rust `commands_write.rs:527` 已有那道守卫（同 provider 直接 '
            'Ok(())）。两道守卫 = 两份判据 ⇒ 迟早漂移。');
    });

    test('★★ 反面：_remoteSwitchSource（换线路）**仍然**不该 repoint', () {
      /*
       * `player_page.dart:4165 _remoteSwitchSource(code)` 是
       * **按 code 换线路**（同一个 provider 内）——
       * provider/id 原样传，只有 code 变 ⇒ **不该**迁移。
       *
       * ★ 这条与 `t67_repoint_test.dart` / `t67_stage1_symptom_test.dart`
       *   里那两条是**同一族**：task-77 把那两条的口径从「**整文件**不含
       *   repointItem」收窄成「**这个函数体**不含」，本文件独立再守一道
       *   （防止别人把口径又改回"整文件"从而把 task-77 的修复判成回归）。
       */
      final body = dartFnBody(playerPage,
          'Future<void> _remoteSwitchSource(String code) async {');
      expect(body.contains('_resolveAndPlay'), isTrue,
          reason: '★ 仪器自检：切出来的必须真是那个函数体');
      expect(body.contains('repointItem'), isFalse,
          reason: '★★★ `_remoteSwitchSource` 不该调 repointItem —— '
              '它是"同 provider 换线路"，provider 没变 ⇒ 不该迁移');
    });
  });
}
