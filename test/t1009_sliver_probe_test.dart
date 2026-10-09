// ══════════════════════════════════════════════════════════════════════
//  探针：SliverGeometry 越界到底出在哪个 tab / 哪个宽度
//  （lead 的 HANDOFF-sliver-to-polish.md 指定的诊断写法）
// ══════════════════════════════════════════════════════════════════════
//
// # 它要回答的三个问题（不是"能不能变绿"）
//
// ```text
// Q1 越界只在**某个 tab**出现，还是任意 tab 都出现？
// Q2 它与**窗口宽度**有关吗（lead 报的是 411.43）？
// Q3 出错那一刻的 remainingPaintExtent / 各 sliver 的 extent 各是多少？
// ```
//
// # 仪器
//
// 直接读 `RenderSliverPinnedPersistentHeader.geometry`：那就是要断言非法
// 的那份几何对象���真出问题时把它**原样打印**（含 parentData），
// 与 Flutter 自己抛的那段字面量对照 —— 一致就说明我们读对了地方。
//
// ⚠️ 只打印事实 + 断言；不打印结论。

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';

Widget _appWith({required Widget home}) {
  final theme = FTheme.neutral.dark.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (context, child) =>
        FTheme(data: theme, child: child ?? const SizedBox()),
    home: home,
  );
}

void _claim(WidgetTester t) {
  var n = 0;
  while (t.takeException() != null && n++ < 400) {}
}

Future<void> _pumpAt(WidgetTester t, Size logical, {double dpr = 1.0}) async {
  t.view.devicePixelRatio = dpr;
  t.view.physicalSize = logical * dpr;
  addTearDown(t.view.reset);
  await t.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
  await t.pump();
  _claim(t);
  await t.pump(const Duration(milliseconds: 1500));
  _claim(t);
}

/// 把当前树上**每一个** pinned header 的几何读出来
List<String> _headers(WidgetTester t) {
  final out = <String>[];
  for (final e in t.allElements) {
    final ro = e.renderObject;
    if (ro is RenderSliverPinnedPersistentHeader) {
      final g = ro.geometry;
      final bad = g != null && g.layoutExtent > g.paintExtent;
      // ★ 找出这个 header 属于哪个页面：往上找最近的 Scaffold/Navigator
      final anc = <String>[];
      e.visitAncestorElements((a) {
        final t = a.widget.runtimeType.toString();
        if (t == 'HomePage' || t == 'SearchPage' || t == 'SettingsPage' ||
            t == 'FollowPage' || t == 'LivePage' || t == 'CachePage' ||
            t == 'Offstage' || t == 'CustomScrollView') {
          anc.add(t);
        }
        return true;
      });
      out.add('${bad ? "★BAD" : "ok  "} '
          'layout=${g?.layoutExtent} paint=${g?.paintExtent} '
          'anc=$anc');
    }
  }
  return out;
}

/// 切到某个 tab，然后跑两帧
Future<void> _switchTo(WidgetTester t, AppTab tab) async {
  debugShellKey.currentState!.debugSwitchTo(tab);
  await t.pump();
  _claim(t);
  await t.pump(const Duration(milliseconds: 400));
  _claim(t);
}

void main() {
  testWidgets('Q1/Q2 逐 tab × 逐宽度：读出越界的几何', (t) async {
    const widths = <double>[411.43, 600, 800, 1280, 1920];
    const tabs = <(String, AppTab)>[
      ('home', AppTab.home),
      ('live', AppTab.live),
      ('follow', AppTab.follow),
      ('search', AppTab.search),
      ('cached', AppTab.cached),
      ('settings', AppTab.settings),
    ];

    for (final w in widths) {
      await _pumpAt(t, Size(w, 900));
      for (final (name, tab) in tabs) {
        await _switchTo(t, tab);
        final hs = _headers(t);
        final bad = hs.where((s) => s.startsWith('★BAD')).toList();
        // ignore: avoid_print
        print('SLV|w=$w tab=$name headers=${hs.length} bad=${bad.length}');
        for (final b in bad) {
          // ignore: avoid_print
          print('SLV|   $b');
        }
      }
    }
  });
}