// ═══════════════════════════════════════════════════════════════════════
//  ★★★ **第二实现，非独立契约** —— 请先读这段再决定要不要引用本文件
// ═══════════════════════════════════════════════════════════════════════
//
// ## ⚠️ 本文件与本契约的**既有实现同契约，且更弱**
// ```text
// 本契约 = 「`_loading = true` 的**每个**赋值点都必须带 `!_firstLoadDone` 守卫」
//
// 既有实现：`test/orchestrator_scroll_fix_verified_test.dart` L277
//     expect(refreshAssigns.length, 1, ...)      ← 数量不变量
//     + expect(line.contains('_firstLoadDone'), ...)
//
// ★ 实测（三种变异，两边都跑；Lead 用**真实测试**独立复现，读数一致）：
//     变异                              orchestrator     本文件
//     V1 加一个**裸**赋值                RED (1→2)        RED (bare 0→1)
//     V2 把唯一那行的守卫**删掉**         RED (无守卫)      RED (bare 0→1)
//     V3 ★ 加一个**带守卫的**第二赋值     RED (1→2)        ★★ **PASS（漏抓）**
//   ⇒ ★★ **本文件抓不到任何 orchestrator 抓不到的东西**；反之不成立
//   ⇒ 对这条契约，本文件是**冗余的**，而且**更弱**（漏 V3 那一类）
// ```
//
// ## 那为什么**保留**（Lead 裁决）
// ```text
// 「重复的测试不危险，未标注的重复才危险」——
//   本文件是**独立第二实现**（不同文件、不同写法）：
//   若既有实现被**误删/误改**，本文件仍会变红。
// ⇒ 保留，但**必须**标注"同契约、更弱"，
//   否则后人会误以为"这里有两道独立防线"（那是**错误**的印象）。
// ```
//
// ## ★★ 我（作者）在这个文件上犯过的两个错 —— 一并留档，防止后人重犯
// ```text
// 【错 1】我最初写：「orchestrator 是**字面量匹配** ⇒ 两者强度不同 ⇒ 不是重复」
//   ★ 根因：**抽样偏差** —— 那个文件有 **13 条** expect，我只读了 **1 条**。
//     L277 那条 `refreshAssigns.length == 1` **就是**不变量判据（我漏看了）。
//   ⇒ 教训：**"只有/全都/不重复"这类全称结论，必须先枚举全域**（铁律 143）
//
// 【错 2】我随后又反过来说"本文件价值降低" —— 也过头了：
//   ★ 正确的区分是「**覆盖**」与「**价值**」两件事：
//     · 覆盖：本文件**没有**增加契约覆盖（V3 已证）⇒ 冗余
//     · 价值：它是独立实现 ⇒ 既有实现被删时它仍会红
// ```
//
// # 本文件做什么（功能不变）
// ```text
// 把 `.probe/probe_tests/zz_t3_q_test.dart` 的 **Q1（不变量）** 固化进常规套件，
// 并保留它原有的两个关键设计：
//   ① ★ **剥注释**（本项目的经典坑：断言匹配到注释文本 ⇒ 假通过）
//   ② ★ **存在性断言在前**（`isNotEmpty`）——
//      否则"0 个违规"与"0 个匹配"无法区分（铁律 78）
//   ③ ★ **排除字段声明**（`bool _loading = true;` 是声明不是赋值）——
//      不加这条会**误报**（我第一版实测踩到：读数里出现
//      `裸: bool _loading = true;` ⇒ 断言失败，但**不是代码有问题**）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉 `//` 与 `/* */`（含**嵌套块注释**，并保护字符串里的 `//`）
///
/// ★ 必须剥（本项目铁律）：`_loading = true` 出现在**注释**里时，
///   不剥会把注释当代码 ⇒ 假阳性；反过来也可能漏。
String codeOnly(String src) {
  final out = StringBuffer();
  var i = 0;
  var depth = 0;
  var inLine = false;
  String? q;
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
      if (c == '\n') out.write('\n');
      i++;
      continue;
    }
    if (q != null) {
      out.write(c);
      if (c == q && (i == 0 || src[i - 1] != r'\')) q = null;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      q = c;
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
      depth++;
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

String readSettings() {
  /*
   * ★★ 源码路径支持**环境变量覆盖**（`T3_SRC`）—— 用于红度证明
   *
   * ```text
   * 红度证明需要**注入变异**，而 `lib/ui/settings_page.dart` 是
   * `fix-settings-merge` 的文件 ⇒ 不能直接改（会覆盖别人的写入）。
   * ⇒ 复制到 `.probe/v48-src/`，用 `T3_SRC=<副本>` 让本测试读副本。
   *
   * ⚠️⚠️ **默认（无 `T3_SRC`）必须读真实文件** ——
   *   否则常规 `flutter test test/` 会去读一个**可能过期的副本**，
   *   变成"测试全绿但测的是旧代码"（比不测更糟）。
   *   ★ 这个开关只服务变异测试，**不改变常规行为**。
   * ```
   */
  final override = Platform.environment['T3_SRC'];
  if (override != null && override.isNotEmpty) {
    final f = File(override);
    if (f.existsSync()) return f.readAsStringSync();
  }
  final f = File('lib/ui/settings_page.dart');
  if (f.existsSync()) return f.readAsStringSync();
  return File('${Directory.current.path}/lib/ui/settings_page.dart')
      .readAsStringSync();
}

void main() {
  group('task-3 ★★★ 不变量：`_loading = true` 的**每个**赋值点都带守卫', () {
    test('★★★ 不允许存在"裸赋值"（不带 `!_firstLoadDone` 守卫）', () {
      final src = readSettings();
      final code = codeOnly(src);

      /*
       * ★★ 匹配规则（这里有个**关键细节**）：
       *
       * ```dart
       * setState(() => _loading = true);           // ← 有 `)` 在 `;` 前
       * if (mounted && !_firstLoadDone) setState(() => _loading = true);
       * ```
       * ⇒ 正则必须是 `_loading\s*=\s*true\s*\)?\s*;`
       *   **`\)?` 不能省** —— 否则 `setState(() => _loading = true);`
       *   这种带右括号的形态**匹配不到** ⇒ 计数为 0 ⇒
       *   ★ 那正是我 task-3 时踩过的坑（当时 `refreshAssigns=0`，
       *     是**我的判据漏了**，不是代码对）。
       * ```
       */
      final re = RegExp(r'_loading\s*=\s*true\s*\)?\s*;');
      final all = re.allMatches(code).toList();

      /*
       * ★★★ 必须**排除字段声明**（我第一次跑就踩到了）
       *
       * ```text
       * 我第一版直接对 `all` 分类 ⇒ 读数：
       *     T3INV|赋值点总数 = 2
       *     T3INV|带守卫的 = 1
       *     T3INV|裸赋值的 = 1
       *     T3INV|  裸: bool _loading = true;      ← ★ 这是**声明**，不是赋值
       *   ⇒ 断言失败，但**不是代码有问题，是我的判据太宽**
       * ```
       * ⇒ 声明与赋值的区别：**声明前面有类型**（`bool `），赋值没有。
       *   ★ 这正是铁律 115 的形态（静态匹配要配"它到底是什么"的判断）——
       *     仅凭 `_loading = true;` 这个串，**两种东西长得一样**。
       */
      bool isDeclaration(String line, int matchStartInLine) {
        final head = line.substring(0, matchStartInLine).trimRight();
        // `bool _loading` / `int _loading` —— 类型 + 空格 + 名字
        return RegExp(r'\b(bool|int|var|final|late)\s*$').hasMatch(head);
      }

      // ★★★ 存在性断言（铁律 78）：
      //   "0 个违规"与"0 个匹配"必须能区分 —— 否则正则写坏时会假绿
      expect(all, isNotEmpty,
          reason: '★★ 前置：必须能找到 `_loading = true` 的出现点。\n'
              '  若为 0 ⇒ 是**我的正则漏了**（不是"代码没有违规"）⇒\n'
              '  这条断言的价值就是让"正则写坏"**立刻暴露**，\n'
              '  而不是安静地假绿（铁律 78）。');

      // ★★★ 核心不变量：每个**赋值点**都必须带 `!_firstLoadDone` 守卫
      final bare = <String>[];
      final guarded = <String>[];
      var declarations = 0;
      for (final m in all) {
        // 取该出现点**所在行**（守卫就在同一行）
        final lineStart = code.lastIndexOf('\n', m.start) + 1;
        var lineEnd = code.indexOf('\n', m.end);
        if (lineEnd < 0) lineEnd = code.length;
        final rawLine = code.substring(lineStart, lineEnd);
        final line = rawLine.trim();

        // ★ 字段声明不算赋值点
        if (isDeclaration(rawLine, m.start - lineStart)) {
          declarations++;
          continue;
        }

        if (line.contains('!_firstLoadDone')) {
          guarded.add(line);
        } else {
          bare.add(line);
        }
      }

      // ignore: avoid_print
      print('T3INV|出现点总数 = ${all.length}（其中字段声明 $declarations 个，'
          '已排除）');
      // ignore: avoid_print
      print('T3INV|赋值点 = ${guarded.length + bare.length}');
      // ignore: avoid_print
      print('T3INV|带守卫的 = ${guarded.length}');
      // ignore: avoid_print
      print('T3INV|裸赋值的 = ${bare.length}');
      for (final b in bare) {
        // ignore: avoid_print
        print('T3INV|  裸: $b');
      }
      for (final g in guarded) {
        // ignore: avoid_print
        print('T3INV|  守卫: $g');
      }

      // ★★ 阳性对照：至少要有 1 个**带守卫**的赋值点
      //   （否则"没有裸赋值"可能只是因为**根本没有赋值点**）
      expect(guarded, isNotEmpty,
          reason: '★ 阳性对照：必须至少存在 1 个带守卫的赋值点 —— '
              '否则"没有裸赋值"这个结论不成立（可能整个赋值逻辑都没了）');

      expect(bare, isEmpty,
          reason: '★★★ 不允许"裸" `_loading = true`（不带 `!_firstLoadDone`）。\n'
              '  ★ 为什么：`_loading` 控制"整页转圈"，而转圈会**销毁 ListView**\n'
              '    ⇒ 滚动位置归零 ⇒ 用户看到"往下滑却自动往上跳"。\n'
              '    只有"**真正的首次**加载"才该转圈，其余刷新必须保持列表。\n'
              '  ★ 危险形态：有人新增一个不带守卫的赋值点\n'
              '    ⇒ 列表存在时也会被换成转圈 ⇒ bug 复发。\n'
              '  ★ 这条是**不变量**（"所有赋值点"），比"某一行存在"更强 ——\n'
              '    后者守不住"新增违规点"。');
    });
  });
}
