// ═══════════════════════════════════════════════════════════════════════
//  t94：Emby 二级页的**入口接线**守卫（task-33 ⑦）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条守卫针对的**真缺陷**（不是防将来，是修当下）
// ```text
// lib/ui/settings/emby_page.dart 有 700+ 行、EmbySettingsPage 写完了，
// 但全仓 grep EmbySettingsPage 只命中它**自己那个文件** ⇒
// 用户**没有任何路径**能进入这个页面。
// ```
// ★ 这与本仓记过的 task-18 老坑**完全同型**：
//   > 两个二级页都写好了，一级页一行入口都没有 ⇒ 功能对用户完全不可见。
//
// # 为什么用**静态契约**（而不是 widget 测试）
// ```text
// 与 task43_plugins_subpage_test.dart 同一个理由：
// SettingsPage 的宿主在 flutter test 里挂不上 ——
//   build() 里 SourinApi.version → SourinCore.version →
//   DynamicLibrary.open('sourin_core.dll')
// 测试环境没有那个 DLL ⇒ 子树被换成 ErrorWidget。
// ⇒ 能守的是「接线是否存在」，行为层（真机点进去）另做。
// ```
//
// # ★★★ 本文件最后一条是**通用**守卫（比 Emby 本身更重要）
// ```text
// 「设置页里每个 *SettingsPage 类都必须被自己文件之外引用至少一次」
// ⇒ 将来任何人再写一个二级页却忘了接入口，这条会**当场报红**，
//   不用等到用户来报「点不进去」。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去注释（状态机，处理字符串里的 // 与块注释）
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
      if (c == '\\') {
        out.write(c);
        if (next.isNotEmpty) out.write(next);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
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
    if (c == "'" || c == '"') {
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
  final raw = File('lib/ui/settings_page.dart').readAsStringSync();
  final code = stripComments(raw);

  group('t94 Emby 入口接线', () {
    test('★ 一级页 import 了 emby_page.dart', () {
      expect(
        code.contains("import 'settings/emby_page.dart';"),
        isTrue,
        reason: '★ 没有 import 就调不到 EmbySettingsPage（编译不过）',
      );
    });

    test('★★ 有一行 SettingsEntryRow 指向 EmbySettingsPage', () {
      expect(
        code.contains('onTap: () => _openSubPage(const EmbySettingsPage()),'),
        isTrue,
        reason: '★★ 只有 import 不够 —— 必须有可点的入口行，否则页面仍然不可达（这正是本缺陷的形态）',
      );
    });

    test('★ 入口标题是 Emby，且副标题说清里面有什么', () {
      expect(code.contains("title: 'Emby',"), isTrue,
          reason: '★ 入口标题必须与页面名一致，否则用户找不到');
      expect(
        code.contains("subtitle: '媒体服务器 · 安装插件 / 服务器地址 / 连接自检',"),
        isTrue,
        reason: '★ 副标题按本页规矩写清里面有什么（同 JS 插件那条）',
      );
    });

    test('★ 入口落在「内容源与插件」分组内（不是散落别处）', () {
      // ★ 2026-10-10：组名从「内容源」改成「内容源与插件」——
      //   这一组里除了 JS 插件还有 Emby 源，原名盖不住。
      //   判据（同语义，只是锚点字符串跟着改）：Emby 必须在该组标签与
      //   下一个组标签「播放与观看」**之间**。
      final group =
          code.indexOf("SettingsGroupLabel(text: '内容源与插件')");
      final entry = code.indexOf("title: 'Emby',");
      final nextGroup = code.indexOf("SettingsGroupLabel(text: '播放与观看')");
      expect(group > 0 && entry > 0 && nextGroup > 0, isTrue,
          reason: '★ 前置：三个锚点都必须找得到');
      expect(group < entry && entry < nextGroup, isTrue,
          reason: '★ Emby 是内容源（JS 插件形态）⇒ 必须落在「内容源与插件」组里',
      );
    });

    test('★★★ 通用守卫：每个 *SettingsPage 都必须被外部引用（防下一个漏接）', () {
      /*
       * ★ 这条比 Emby 本身重要：它把「二级页写完了但没接入口」
       *   从「等用户报」变成「测试当场报红」。
       *
       * ⚠️ 只在 lib/ui/settings/ 下扫「页面类」（*SettingsPage），
       *   不扫 _Hint / _Bullet 这类私有部件（它们本就不该被外部引用）。
       * ⚠️ 引用计数排除**定义它自己那个文件** ——
       *   类名在自身文件里当然出现，那不是接线。
       */
      final pageRe = RegExp(
        r'^class (\w+SettingsPage) extends (?:StatefulWidget|StatelessWidget)',
        multiLine: true,
      );
      final dir = Directory('lib/ui/settings');
      final unreachable = <String>[];
      var scanned = 0;

      for (final e in dir.listSync()) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final path = e.path.replaceAll(r'\', '/');
        final src = stripComments(e.readAsStringSync());
        for (final m in pageRe.allMatches(src)) {
          final cls = m.group(1)!;
          scanned++;
          var refs = 0;
          for (final f in Directory('lib').listSync(recursive: true)) {
            if (f is! File || !f.path.endsWith('.dart')) continue;
            final fp = f.path.replaceAll(r'\', '/');
            if (fp == path) continue;
            if (stripComments(f.readAsStringSync()).contains(cls)) refs++;
          }
          if (refs == 0) unreachable.add('$cls ($path)');
        }
      }

      expect(scanned, greaterThanOrEqualTo(8),
          reason: '★ 前置：至少要扫到 8 个二级页类，否则是扫描口径坏了');
      expect(
        unreachable, isEmpty,
        reason: '★★★ 这些二级页写完了却没有任何入口 ⇒ 用户点不进去（task-18 / Emby 同型）',
      );
    });
  });
}
