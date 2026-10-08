// ═══════════════════════════════════════════════════════════════════════
//  task-44 ③：设置页「三层字」行距 —— **像素读数**测试
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（逐字）
// ```text
// 3.设置这三层字重叠的太近了
// ```
//
// # 三层字是哪三层（截图实测，见 .probe/run-set/）
// ```text
// 「设置」                FontSizes.xl = 28
//    ↕ 实测 7px
// 「内容源、网络与同步」    FontSizes.sm = 14
//    ↕ ★★ 实测 **1px**  ← 用户说的"重叠"
// 「局域网遥控」           _Block title（lg = 20）
// ```
//
// # 本文件守什么
// ```text
// ① ★★ 「内容源、网络与同步」底 到 「局域网遥控」顶 的**实际像素间距** ≥ 24px
// ② ★  标题→副标题也放宽（≥ 8px）
// ③ ★★ 三层都在**同一页**、且顺序正确（防"把某层删了"式的假通过）
// ```
//
// # ★★★ 为什么用 `RenderBox` 量而不是 `find.text` 存在性
// ```text
// `find.text('局域网遥控')` 能找到 ≠ 间距够 ——
//   存在性与几何是**两个维度**。
// ⇒ 必须取 RenderBox 的 `localToGlobal`，算**实际屏幕 y 差**。
//   （这与 ④ 的"在树里 ≠ 看得见"是同一条纪律。）
// ```
//
// # ⚠️ 为什么测的是**真实 settings_page.dart** 而不是搭一个假页面
// ```text
// 三层字的间距来源是：
//   `_Section`（页头） 与 `_Block`（SettingsBlock，top=0）**之间的空隙**。
// 而这两个组件的组合只出现在**真实设置页**里 ⇒
//   搭假页面就测不到"页头→首块"这个**特定组合**（那正是 bug 所在）。
// ★ 但设置页 build() 需要 FFI（`SourinApi.version`）⇒ flutter test 里挂不上：
//     实测 element=1 / ErrorWidget=1 / Text=0（见 .probe/probe_tests/zz_v46b）
// ⇒ 所以本文件走**源码断言**（量的是"间距代码"），
//   而**像素读数**由截图 + RenderBox 双证据覆盖：
//     · 截图：.probe/run-set/crop-header.png（改前，肉眼可见相接）
//     · 源码：本文件（改后的间距常量）
// ⚠️ 我**不假装**它测了像素 —— 它是"间距来源"的回归守卫，
//    真正的像素读数在同目录的实测报告里。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去注释（行首判断 + 状态机处理块注释）
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  String? quote;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    if (inBlock) {
      if (c == '*' && next == '/') {
        inBlock = false;
        i += 2;
        continue;
      }
      if (c == '\n') out.write(c);
      i++;
      continue;
    }
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (quote != null) {
      out.write(c);
      if (c == r'\' && next.isNotEmpty) {
        out.write(next);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlock = true;
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 取页头 `_Section` 之后、第一个 `_Block(` 之前的片段
String headerToFirstBlock(String code) {
  final hdr = code.indexOf("'内容源、网络与同步'");
  expect(hdr > 0, isTrue, reason: '★ 前置：必须能找到页头副标题');
  // 从副标题往后找第一个 _Block(
  final blk = code.indexOf('_Block(', hdr);
  expect(blk > hdr, isTrue, reason: '★ 前置：页头之后必须有第一个 _Block');
  return code.substring(hdr, blk);
}

void main() {
  late String raw;
  late String code;

  setUpAll(() {
    // ★ 支持环境变量覆盖（红度证明时在副本上跑）
    final override = Platform.environment['TASK44_SRC'];
    final path = (override != null && override.isNotEmpty)
        ? override
        : 'lib/ui/settings_page.dart';
    raw = File(path).readAsStringSync();
    code = stripComments(raw);
  });

  group('task-44 ③ 设置页三层字行距', () {
    test('★★★ 页头 → 首块之间必须有 ≥24px 的间距（用户报的"重叠"）', () {
      /*
       * # 根因
       * `SettingsBlock` 的 padding 是 `fromLTRB(24, 0, 24, Sp.x8)`
       *   ⇒ top = 0（块间靠前一块的 bottom 撑开）
       *   ⇒ ★ 但页头之后的第一块**前面没有块** ⇒ 间距 = 0px
       *
       * # 实测
       * 改前：**1px**（截图像素扫描）⇒ 用户说"重叠太近"
       * 改后：应 ≥ 24px（用 Sp.x8 = 32px）
       */
      final seg = headerToFirstBlock(code);
      expect(
        seg.contains('SizedBox(height: Sp.x8)') ||
            seg.contains('SizedBox(height: Sp.x6)'),
        isTrue,
        reason: '★★★ 页头与首个 `_Block` 之间**必须有间距** '
            '(Sp.x6=24 或 Sp.x8=32) —— '
            '改前实测只有 1px，用户报「这三层字重叠的太近了」',
      );
    });

    test('★★ 标题 → 副标题 ≥ 8px（28px 大标题需要更宽的呼吸）', () {
      final si = code.indexOf("'设置'");
      expect(si > 0, isTrue, reason: '★ 前置：必须能找到页头标题');
      final seg = code.substring(si, si + 400);
      expect(
        seg.contains('SizedBox(height: Sp.x2)') ||
            seg.contains('SizedBox(height: Sp.x3)'),
        isTrue,
        reason: '★★ 页头"设置"(28px) 与副标题(14px) 之间应 ≥ Sp.x2(8px) —— '
            '改前是 Sp.x1(4px)，对 28px 大标题偏挤',
      );
    });

    test('★★ 三层都在同一页且顺序正确（防"删掉某层"式假通过）', () {
      final a = raw.indexOf("'设置'");
      final b = raw.indexOf("'内容源、网络与同步'");
      final c = raw.indexOf("title: '局域网遥控'");
      expect(a > 0 && b > 0 && c > 0, isTrue,
          reason: '★ 前置：三层字都必须存在（缺一层就不是"三层"了）');
      expect(a < b && b < c, isTrue,
          reason: '★★ 顺序必须是 设置 → 副标题 → 局域网遥控');
    });

    test('★★ `SettingsBlock` 的 top 仍为 0（别改它 —— 会双倍块间距）', () {
      /*
       * 这条是**反向守卫**：修 ③ 的正确方式是给**页头**加间距。
       * 若有人为了修 ③ 去改 `SettingsBlock.top` ⇒ 所有堆叠块的间距都会翻倍
       *   （因为块间已经靠前一块的 bottom=Sp.x8 撑开了）。
       */
      final kit = File('lib/ui/widgets/settings_kit.dart').readAsStringSync();
      final kc = stripComments(kit);
      final i = kc.indexOf('class SettingsBlock');
      expect(i > 0, isTrue, reason: '★ 前置：必须能找到 SettingsBlock');
      final seg = kc.substring(i, i + 3000);
      /*
       * ★ 2026-10-04 改写（t509 内容带）
       *
       * 原断言是 `seg.contains('AppMetrics.contentPadding,\n        0,')` ——
       * 它把"top 必须为 0"和"左右必须是 24"**绑死在同一串字面量**上。
       * t509 把内容带（原版 `.container` 那层）补到设置页后，
       * 左右 24 改由**页面根**提供（一级页 `settings_page.dart` 的
       * `ListView.padding`；二级页 `SettingsSubPage.build` 的外层
       * `Padding`）⇒ 这里再留 24 会变成 ×2 = 48。
       *
       * ⇒ 断言改成"**两件事各自成立**"：
       *     ① top 仍是 0（原意图，一字不改地保留）
       *     ② 横向不再自带（带由页面根给）
       * 原版依据：`dist/assets/SettingsView-BE6jt733.css` 220 条顶层规则里
       *   `container` / `settings-block` / `section` 命中**全为 0**
       *   ⇒ 那 24 确实只来自 `SettingsView.vue:1612` 的 `.container`。
       */
      expect(
        seg.contains('EdgeInsets.only(bottom: Sp.x8)'),
        isTrue,
        reason: '★★ `SettingsBlock` 的 padding 必须仍是 **top=0**（只写 bottom）—— '
            '它靠"前一块的 bottom"撑开块间距；改成非 0 会让**所有**'
            '堆叠块间距翻倍（修 ③ 应当改页头，不是改这里）。'
            '★ 同时左右也必须为 0：那 24 由页面根的内容带提供'
            '（t509），这里再留会 ×2',
      );
      expect(
        seg.contains('horizontal: AppMetrics.contentPadding'),
        isFalse,
        reason: '★★ `SettingsBlock` **不得**自带横向内边距 —— '
            '内容带由页面根提供（一级页 `ListView.padding` / '
            '二级页 `SettingsSubPage` 外层 `Padding`），'
            '两处都留就是 ×2 = 48',
      );
    });
  });
}
