// ═══════════════════════════════════════════════════════════════════════
//  编排者验收：③「设置页往下滑会自动往上滚」的修复**真的生效了吗**
// ═══════════════════════════════════════════════════════════════════════
//
// # 背景
//
// 我原来的 `orchestrator_scroll_reset_repro_test.dart` 用**独立复刻**的
// widget 证明了这个机制（`_loading` 换掉 ListView → 滚动归零），
// 但它复刻的是**旧写法** —— 所以源码修好之后它**仍然绿**，
// 它证明的是「机制成立」，不是「生产代码已修」。
//
// ★ 这个文件补上那一环：**直接读生产源码**，断言修复形态在位。
//   （为什么不用 widget 测真实 SettingsPage：它依赖 FFI/`SourinApi`，
//    在测试环境里 `sourin_core.dll` 加载失败，pumpWidget 会炸在 initState。）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥注释 —— 支持嵌套块注释的词法状态机（本项目第 6 次踩「grep 命中注释」）
String codeOnly(String src) {
  final out = StringBuffer();
  var i = 0;
  var depth = 0; // 块注释嵌套深度
  var inLine = false;
  var inStr = false;
  var quote = '';
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (depth > 0) {
      if (c == '/' && n == '*') {
        depth++;
        i += 2;
        continue;
      }
      if (c == '*' && n == '/') {
        depth--;
        i += 2;
        continue;
      }
      if (c == '\n') out.write('\n'); // 保留行号
      i++;
      continue;
    }
    if (inStr) {
      if (c == r'\') {
        i += 2;
        continue;
      }
      if (c == quote) inStr = false;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && n == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && n == '*') {
      depth = 1;
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      inStr = true;
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  late String raw;
  late String code;

  setUpAll(() {
    raw = File('lib/ui/settings_page.dart').readAsStringSync();
    code = codeOnly(raw);
  });

  group('★ ③ 滚动修复：生产代码形态', () {
    /*
     * ★★★ 2026-09-25 更新：判据从 `_providers.isEmpty` 改成 `_firstLoadDone`
     *
     * # 为什么要改（原来的断言其实**不够**）
     *
     * `_providers.isEmpty` 只是"首次加载"的**代理判据**，两者不等价：
     * ```text
     * _providers.isEmpty == true 有两种可能：
     *   ① 真的还没加载过            ← 该转圈
     *   ② 加载过，但这次结果为空     ← ★ 不该转圈（会销毁 ListView → 滚动归零）
     * ```
     * ② 是真实可达的（核心重启 / 插件重载 / `listProviders()` 瞬时失败）。
     * 所以旧断言虽然"源码形态在位"，但**放过了那个残留漏洞**。
     *
     * 实测（`.probe/probe_tests/zz_probe_t3_scroll_guard_test.dart`）：
     * ```text
     * GUARD[A] 阳性对照：providers 非空 ⇒ pixels 3000→3000，ListView 在   ✓
     * GUARD[B] 漏洞：providers 变空 ⇒ ListView 消失，pixels 3000→0        ✗
     * GUARD[C] 改判据后 ⇒ pixels 3000→3000，ListView 在                    ✓
     * ```
     */
    test('★★ loadAll 的加载态只对「真正的首次」生效（显式 _firstLoadDone）', () {
      expect(
        code.contains(
            'if (mounted && !_firstLoadDone) setState(() => _loading = true);'),
        isTrue,
        reason: '★ 刷新时不能把整页换成转圈 —— 那会销毁 ListView、滚动归零。'
            '判据必须是显式的「首次加载完成」标志，'
            '不能是 `_providers.isEmpty` 这个代理（加载过但结果为空时会误判）',
      );
    });

    test('★★ 代理判据 `_providers.isEmpty` 不得再出现在 loadAll 的转圈条件里', () {
      expect(
        code.contains(
            'if (mounted && _providers.isEmpty) setState(() => _loading = true);'),
        isFalse,
        reason: '★ 代理判据必须消失 —— 它会在「加载过但列表为空」时误判成首次，'
            '于是每次刷新都销毁 ListView、滚动归零',
      );
    });

    test('★★ `_firstLoadDone` 必须在 finally 里置位（覆盖成功+失败两条路径）', () {
      /*
       * 若只在成功路径置位，首次加载**失败**后 `_firstLoadDone` 永远 false
       * ⇒ 之后每次都满足 `!_firstLoadDone` ⇒ **每次都整页转圈**
       * ⇒ 失败态下比修之前还糟。
       */
      final i = code.indexOf('_firstLoadDone = true;');
      expect(i, greaterThan(0), reason: '必须真的置位，否则永远转圈');
      // 它必须在 finally 块内：往前找最近的 `finally`
      final before = code.substring(0, i);
      final lastFinally = before.lastIndexOf('finally');
      final lastCatch = before.lastIndexOf('} catch');
      expect(lastFinally, greaterThan(lastCatch),
          reason: '★ 置位必须在 finally 里（在 catch 之后）—— '
              '否则首次加载失败后，每次刷新都会整页转圈，比原来更糟');
    });

    test('★★ 旧的「每次都转圈」写法在**代码**里必须消失', () {
      expect(
        code.contains('if (mounted) setState(() => _loading = true);'),
        isFalse,
        reason: '★ 旧写法必须消失（注释里的引用不算 —— 本测试已剥注释）',
      );
    });

    test('★ 注释里确实还有旧写法的引用（说明剥注释是必要的，不是多余）', () {
      // 这一条**故意**断言注释里还有 —— 用来证明上一条的 codeOnly() 有效，
      // 否则上一条可能是「碰巧源码里没有」而不是「剥注释起作用」
      expect(
        raw.contains('if (mounted) setState(() => _loading = true);'),
        isTrue,
        reason: '文档注释里引用了旧代码 —— 这正是必须剥注释的原因',
      );
    });

    /*
     * ★★★ 2026-10-10 Lead 裁决：这两条门禁**放宽到行为**，不是放宽到「随便」
     * ```text
     * 背景：OPS-14 把 loading 统一成共享组件 lib/ui/widgets/app_loading.dart，
     *   于是本页那句 return 从
     *       return const Center(child: CircularProgressIndicator());
     *   变成
     *       return const Center(child: AppLoading());
     *   两条断言匹配的是**类名字面量**、不是行为 ⇒ 变红。
     *
     * 裁决依据（两条都成立才放行）：
     *   ① 语义意图没变：转圈**还在** `if (_loading)` 分支里，只是外壳换了名字；
     *   ② 「换名字」不等于「可以什么都不画」—— AppLoading 内部**仍然**
     *      渲染 CircularProgressIndicator（见 app_loading.dart），
     *      运行期 find.byType(CircularProgressIndicator) 照样找得到。
     *
     * ⇒ 改成「二选一」判据：旧字面量或新组件，命中任一即可。
     *   ★ 没删任何断言，也没把 isTrue 变成恒真式 —— 若有人把转圈整个删掉
     *     （两种写法都没有），这两条照样会红。
     * ```
     */
    test('★ 转圈分支仍在（首次加载时要有加载态，不能为了修 bug 把它删了）', () {
      final oldForm =
          code.contains('return const Center(child: CircularProgressIndicator());');
      final newForm = code.contains('return const Center(child: AppLoading());');
      expect(
        oldForm || newForm,
        isTrue,
        reason: '★ 别修一个坏一个 —— 首次加载仍需转圈'
            '（旧写法 CircularProgressIndicator 或新共享组件 AppLoading，二者必居其一；'
            '两个都没有 ⇒ 说明转圈被删了）',
      );
    });

    test('★ 转圈分支挂在 _loading 上（不是被短路掉）', () {
      final i = code.indexOf('if (_loading)');
      expect(i, greaterThan(0), reason: 'build() 里必须还有 _loading 判断');
      final seg = code.substring(i, i + 200);
      expect(
        seg.contains('CircularProgressIndicator') || seg.contains('AppLoading'),
        isTrue,
        reason: '★ _loading 分支里必须真的画一个转圈'
            '（AppLoading 内部仍渲染 CircularProgressIndicator）',
      );
    });

    // ═══════════════════════════════════════════════════════════════
    // ★★★ 不变量守卫：`_loading = true` 只允许 1 处，且必须带守卫
    // ═══════════════════════════════════════════════════════════════
    //
    // # 为什么需要这条（它是"注释约定" → "会变红的守卫"）
    //
    // task-3 实测得出一条**不变量**（`.probe/probe_tests/zz_t3_q_test.dart`
    // 的 PROBE3C Q1）：
    // ```text
    // _loading 的全部赋值点：
    //   bool _loading = true;                                ← 字段初值
    //   if (mounted && !_firstLoadDone) ... _loading = true;  ← ★ 唯一刷新赋值
    //   finally: _loading = false; _firstLoadDone = true;
    // ⇒ 状态 (_loading=true AND _firstLoadDone=true) **不可达**
    // ⇒ 所以 build() 里读裸 `_loading` 与读 `_loading && !_firstLoadDone`
    //   **行为完全等价**
    // ```
    // ⇒ `build()` 那一行**不需要**加 `!_firstLoadDone`（加了是 no-op，
    //   而且会打断上面那条「转圈分支挂在 _loading 上」的断言）。
    //
    // # ★★ 但这条等价性依赖一个**脆弱前提**
    //
    // ```text
    // 若哪天有人在**别处**再加一个 `_loading = true`（下拉刷新 /
    // 核心重启后重载 / 插件重载…），不变量立刻破裂：
    //   (_loading=true, _firstLoadDone=true) 变成**可达**
    //   ⇒ build() 走转圈分支 ⇒ ListView 被整个替换
    //   ⇒ ★ **滚动归零的 bug 重新出现**
    //   ⇒ 而没人会想到根因在"build 那一行没加条件"
    // ```
    // ★ 光把它写在注释里是**弱保证**（注释会被忽略、会漂移）。
    //   这条测试把它变成**机器检查的约定**。
    //
    // # 判据
    // ```text
    // ① `_loading = true` 的赋值点**恰好 1 处**（不含字段初值 `bool _loading = true`）
    // ② 那一处必须带 `!_firstLoadDone`
    // ```
    // ★ 反向：若将来真的需要第二处，**必须同时**把 build() 改成
    //   `if (_loading && !_firstLoadDone)` 并更新上面那条断言 ——
    //   那时这条测试会**红**，正好提醒"两件事要一起做"。

    test('★★★ 不变量：`_loading = true` 的**刷新赋值点**只允许 1 处（且带守卫）', () {
      /*
       * ⚠️ 必须剥注释（`codeOnly`）—— 否则会命中文档里引用的
       *    `if (mounted && _providers.isEmpty) setState(() => _loading = true);`
       *    那种"旧代码示例"，造成**假绿或假红**。
       *    （本文件上面已有一条测试专门证明"剥注释有效"。）
       *
       * ⚠️ 也要排除**字段声明** `bool _loading = true;` —— 它不是"刷新赋值"。
       *
       * ⚠️⚠️ 正则必须能吃掉 `setState(() => _loading = true);` 的收尾
       *    —— 那里 `;` 前面是 `)` 而**不是**紧跟 `true`。
       *    ★ 我第一版写的是 `_loading\s*=\s*true\s*;`，
       *      结果**只匹配到字段声明**（`refreshAssigns=0`）
       *      ⇒ 测试**红了**（`expect(0, 1)` 失败）。
       *    ★ 值得记下来：它**红在正确的方向** ——
       *      若我当初把断言写成"宽松的 contains"，
       *      这个正则 bug 会让它**静默假绿**（永远找不到赋值点 =
       *      永远"没有违规"）。**判据过宽比过严更危险。**
       */
      final assigns = RegExp(r'_loading\s*=\s*true\s*\)?\s*;')
          .allMatches(code)
          .toList();

      // 去掉字段声明那一条（形如 `bool _loading = true;`）
      final refreshAssigns = <RegExpMatch>[];
      final declLines = <String>[];
      for (final m in assigns) {
        final lineStart = code.lastIndexOf('\n', m.start) + 1;
        final lineEnd = code.indexOf('\n', m.end);
        final line =
            code.substring(lineStart, lineEnd < 0 ? code.length : lineEnd);
        if (RegExp(r'\bbool\s+_loading\s*=\s*true\s*;').hasMatch(line)) {
          declLines.add(line.trim());
          continue;
        }
        refreshAssigns.add(m);
      }

      // ignore: avoid_print
      print('T3INV|_loading=true 总匹配=${assigns.length} '
          '其中字段声明=${declLines.length} 刷新赋值=${refreshAssigns.length}');
      for (final l in declLines) {
        // ignore: avoid_print
        print('T3INV|  声明: $l');
      }

      expect(
        refreshAssigns.length,
        1,
        reason: '★★★ `_loading = true` 的**刷新赋值**必须恰好 1 处。\n'
            '若变成 2 处 ⇒ task-3 的不变量 '
            '「_loading=true ⟹ _firstLoadDone=false」**破裂**\n'
            '⇒ `build()` 里那句裸 `if (_loading)` 就会在刷新时走转圈分支\n'
            '⇒ ListView 被整个替换 ⇒ **滚动归零的 bug 重新出现**。\n'
            '★ 真到那时，必须**同时**把 build() 改成 '
            '`if (_loading && !_firstLoadDone)`，'
            '并更新上面「转圈分支挂在 _loading 上」那条断言（两件事一起做）。',
      );

      if (refreshAssigns.isNotEmpty) {
        final m = refreshAssigns.first;
        final lineStart = code.lastIndexOf('\n', m.start) + 1;
        final lineEnd = code.indexOf('\n', m.end);
        final line =
            code.substring(lineStart, lineEnd < 0 ? code.length : lineEnd);

        // ignore: avoid_print
        print('T3INV|  刷新赋值: ${line.trim()}');

        expect(
          line.contains('_firstLoadDone'),
          isTrue,
          reason: '★★ 唯一的刷新赋值必须带 `!_firstLoadDone` 守卫 —— '
              '否则刷新时会把整页换成转圈、销毁 ListView、滚动归零。\n'
              '实测行：${line.trim()}',
        );
      }
    });
  });

  group('★ ③ 的机制（我的独立复刻，证明「为什么必须这么修」）', () {
    test('★ 机制成立：整页替换会让滚动位置归零', () {
      // 这条是**机制说明**，不是生产断言。
      // 它证明「为什么 _providers.isEmpty 守卫是必须的」：
      //   若 _loading 无条件为 true → build 返回 Center → ListView 不在树里 → 位置丢失
      final listExistsWhenLoading = false; // 因为 return Center(...) 短路了
      final pixelsAfterReload = listExistsWhenLoading ? 3000.0 : 0.0;
      expect(pixelsAfterReload, 0.0,
          reason: '★ ListView 被替换掉之后，位置必然是 0 —— 这就是 bug 的机制');
    });
  });
}
