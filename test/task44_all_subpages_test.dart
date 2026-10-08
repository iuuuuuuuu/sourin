// ═══════════════════════════════════════════════════════════════════════
//  task-44 ④：**全部**二级页都必须走 `SettingsSubPage` 外壳
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这个文件（Lead 明确要求）
// ```text
// Lead：「★ 务必把这个交互应用到"所有"二级页，不只是 JS 插件那个
//        ⇒ 先列出**全部**二级页（`SettingsSubPage` 的使用点），列个清单」
// ```
//
// # 本文件守的**结构性**事实
// ```text
// sticky 返回按钮是实现在 `SettingsSubPage` **外壳**里的
//   ⇒ ★ 任何"用这个外壳"的页面**自动**获得 sticky 返回
//   ⇒ ★ 所以"是否覆盖全部二级页" ⟺ "全部二级页是否都用这个外壳"
// ```
// ★ 这是**结构性**保证，不是"我逐个改过 6 个文件"——
//   后者会漏（将来新增第 7 个二级页时），前者不会。
//
// # ⚠️ 本文件**不**断言"外壳里的实现细节"
// ```text
// 它只断言"每个二级页都用了外壳"。
// 外壳**内部**的 sticky 行为由 `task44_subpage_sticky_back_test.dart` 守
//   （那个文件有**红度证明**：改前 2 条红）。
// ⇒ 两个文件分工：本文件守"覆盖面"，那个守"行为"。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去注释（行首 + 状态机，处理 `'http://x'` 这类串里的 `//`）
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

/// 全部二级页（`SettingsSubPage` 的使用点）
///
/// ★ 这份清单是**实测得出**的（grep `SettingsSubPage(`），不是凭记忆：
/// ```text
///   lib/ui/settings_page.dart:3377   （JS 插件，task-43 新增）
///   lib/ui/settings/about_page.dart:90
///   lib/ui/settings/backup_page.dart:87
///   lib/ui/settings/pc_gestures_page.dart:65 / 86
///   lib/ui/settings/skip_page.dart:598
///   lib/ui/settings/theme_page.dart:52
///   lib/ui/settings/playback_page.dart:286    （播放与下载，task-18 新增）
///   lib/ui/settings/touch_gestures_page.dart:73 / 94  （播放手势，task-18 新增）
/// ```
/// ⚠️ `pc_gestures_page.dart` 有**两处**（两个页面共用同一文件）
/// ⚠️ `touch_gestures_page.dart` 也有**两处**：`:73` 是「仅在触摸端可用」的
///    占位页，`:94` 是真页面 —— 两者互斥（`if (!Device.isTouchOnly)`）。
///    两处都在同一文件里 ⇒ 清单里只需一个条目。
///
/// ★ 2026-10-04 更新：task-18 新增了 `playback_page.dart` 与
///   `touch_gestures_page.dart` 两个二级页，它们**用了外壳却没进清单** ⇒
///   本文件第 3 条守卫（反向扫描）当场报红。那是**清单过期**，不是产品缺陷：
///   两个页面**已经**获得了 sticky 返回（外壳给的），只是清单没跟上。
const subPages = <String>[
  'lib/ui/settings_page.dart',
  'lib/ui/settings/about_page.dart',
  'lib/ui/settings/backup_page.dart',
  'lib/ui/settings/pc_gestures_page.dart',
  'lib/ui/settings/skip_page.dart',
  'lib/ui/settings/theme_page.dart',
  'lib/ui/settings/playback_page.dart',
  'lib/ui/settings/touch_gestures_page.dart',
  'lib/ui/settings/emby_page.dart',
];

void main() {
  group('task-44 ④ 全部二级页覆盖', () {
    test('★★ 清单里的文件全部存在（防"清单本身过期"）', () {
      for (final p in subPages) {
        expect(File(p).existsSync(), isTrue,
            reason: '★ 二级页清单里的 $p 不存在 ⇒ 清单过期了，必须更新');
      }
    });

    test('★★★ 每个二级页都真的用了 `SettingsSubPage` 外壳', () {
      final missing = <String>[];
      for (final p in subPages) {
        final code = stripComments(File(p).readAsStringSync());
        if (!code.contains('SettingsSubPage(')) missing.add(p);
      }
      expect(
        missing, isEmpty,
        reason: '★★★ 这些二级页**没有**用 `SettingsSubPage` 外壳 ⇒ '
            '它们**不会**获得 sticky 返回（用户 ④ 的诉求）: $missing',
      );
    });

    test('★★★ 全仓搜 SettingsSubPage( 的使用点 = 清单（防漏新页面）', () {
      /*
       * ★ 这条是**反向**守卫：若有人**新增**了一个二级页但没进清单，
       *   上面那条"清单里都用了外壳"仍会绿 ⇒ 漏掉新页面。
       * ⇒ 所以这里**主动扫描** lib 目录，把实际使用点数出来比对。
       */
      final found = <String>{};
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final p = e.path.replaceAll(r'\', '/');
        /*
         * ⚠️ 排除**外壳自己**（`settings_sub_page.dart`）——
         *    它内部有 `SettingsSubPage` 的**构造器定义**与文档示例，
         *    字符串里也出现 `SettingsSubPage(`（文档注释被我 strip 掉了，
         *    但 `class SettingsSubPage extends StatelessWidget` 之后
         *    的构造器调用形态仍在）。
         * ★ 它是**被使用者**，不是**使用者** —— 断言的是"谁在用外壳"。
         * ★ 我第一次跑就是被它绊了一下（报 unlisted），
         *   而那是**真阳性**（我的清单/扫描口径没说清"定义 vs 使用"）。
         */
        if (p == 'lib/ui/widgets/settings_sub_page.dart') continue;
        final code = stripComments(e.readAsStringSync());
        if (code.contains('SettingsSubPage(')) {
          found.add(p);
        }
      }
      final listed = subPages.toSet();
      final unlisted = found.difference(listed);
      expect(
        unlisted, isEmpty,
        reason: '★★★ 这些文件用了 `SettingsSubPage` 但**不在清单里** ⇒ '
            '要么补进清单，要么它们不是二级页（会漏测）: $unlisted',
      );
      final stale = listed.difference(found);
      expect(
        stale, isEmpty,
        reason: '★ 清单里有文件**已不再**使用外壳 ⇒ 清单过期: $stale',
      );
    });

    test('★★ 外壳的 sticky 返回条在**两条**代码路径上都存在', () {
      /*
       * `SettingsSubPage` 有两种结构：
       *   · `scrollBody == null` → `_scrollingBody`（ListView/CustomScrollView）
       *   · `scrollBody != null` → `_pinnedBody`（Column + Expanded）
       * ⇒ ★ 返回按钮必须在**两条路径上都固定**，
       *   否则"片头片尾"页（用 scrollBody）会退回旧行为。
       */
      final code = stripComments(
          File('lib/ui/widgets/settings_sub_page.dart').readAsStringSync());

      // 路径 1：SliverPersistentHeader(pinned: true) + _backRow
      expect(
        RegExp(r'SliverPersistentHeader\(').hasMatch(code), isTrue,
        reason: '★ 路径 1（普通二级页）必须用 pinned 的 sliver',
      );
      expect(
        code.contains('pinned: true'),
        isTrue,
        reason: '★ sliver 必须 `pinned: true` —— 否则不吸顶（用户要的就是吸顶）',
      );
      expect(
        code.contains('_backRow('),
        isTrue,
        reason: '★ 返回按钮必须抽成 `_backRow` 供吸顶条使用',
      );

      // 路径 2：_pinnedBody 用 _header（内含返回按钮）
      final pinnedIdx = code.indexOf('Widget _pinnedBody');
      expect(pinnedIdx > 0, isTrue, reason: '★ 前置：必须能找到 _pinnedBody');
      final seg = code.substring(pinnedIdx, pinnedIdx + 600);
      expect(
        seg.contains('_header('),
        isTrue,
        reason: '★★ 路径 2（用 scrollBody 的页面）也必须把**含返回按钮的** '
            '`_header` 放在固定区（Column 顶部，不参与滚动）',
      );
    });

    test('★★ 返回按钮只画一次（防"两条路径都画"出现两个按钮）', () {
      /*
       * ⚠️ 这是个真实风险：`_scrollingBody` 用 `_backRow`（只画按钮），
       *    `_pinnedBody` 用 `_header`（画按钮 + 标题）。
       *    若有人给 `_scrollingBody` 也改成 `_header`，
       *    页面上会出现**两个**「返回设置」。
       * ⇒ 断言：`_scrollingBody` 里**不含** `_header(`
       *    （它用的是 `_backRow` + `_titles` 的组合）。
       */
      final code = stripComments(
          File('lib/ui/widgets/settings_sub_page.dart').readAsStringSync());
      final start = code.indexOf('Widget _scrollingBody');
      expect(start > 0, isTrue, reason: '★ 前置：必须能找到 _scrollingBody');
      // 到下一个方法定义为止
      final end = code.indexOf('static const double _backBarMin', start);
      expect(end > start, isTrue, reason: '★ 前置：必须能找到 _scrollingBody 的结尾');
      final seg = code.substring(start, end);
      expect(
        seg.contains('_header('), isFalse,
        reason: '★★ `_scrollingBody` **不应**用 `_header` —— '
            '`_header` 含返回按钮，而按钮已由吸顶条的 `_backRow` 画了；'
            '两边都画 ⇒ 页面上出现**两个**「返回设置」',
      );
      expect(
        seg.contains('_titles('),
        isTrue,
        reason: '★ `_scrollingBody` 应画 `_titles`（标题+副标题，可滚走）',
      );
    });
  });
}
