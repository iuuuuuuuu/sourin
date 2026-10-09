import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/spatial_nav.dart' show BottomBarMarker;

// ★ 窄端夹紧边界探针（release-dev / task-3 ⑲）
//
// 目的：用与生产完全相同的测量件（ShellPage + BottomBarMarker + GlassContainer），
//   量出「6 个 tab」在**面板被夹到 _tabWidthMin 附近、甚至更窄**时的**真实**行为。
//
// ★ 为什么必须另开一个探针：test/bottom_bar_fit_test.dart 的用例①/⑥/⑦/⑧
//   判据是「标签**中心点**在面板内就通过」。当每项仍等分时，中心点恒在面板内
//   ⇒ 中心点判据**盖不住**「夹紧后字被裁掉一半」这类边界 —— 这是假绿面。
//   本探针改成量**标签矩形两端**是否都在面板内，并对每个宽度算出
//     fit = (W - _kTabRowHorizontalLoss) / AppTab.values.length
//   与生产常量 _tabWidthMin / _tabWidthMax 直接对照，把「是否越过夹紧点」
//   这个事实**打印出来**，而不是只判一个真假。
//
// 探针产物：本文件不写盘（纯几何读数），沙盒规则见 ⑳ 的并发/目录探针。

/// 与 lib/shell.dart 逐值同步的常量（此处**只读**，不改生产代码）
const double _kTabWidthMin = 44; // shell.dart:6234
const double _kTabRowLoss = 48; // shell.dart:6272：Sp.x6 * 2
const int _tabCount = 6; // AppTab.values.length（加「已缓存」后）

const List<String> _tabLabels = <String>[
  '发现',
  '直播',
  '追更',
  '搜索',
  '已缓存',
  '设置',
];

Widget _appWith({required Widget home}) {
  final theme = FTheme.neutral.dark.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (context, child) => FTheme(
      data: theme,
      child: child ?? const SizedBox(),
    ),
    home: home,
  );
}

void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Future<void> _pumpShellAt(WidgetTester tester, Size logical,
    {double dpr = 1.0}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logical * dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
  await tester.pump();
  _claim(tester);
  await tester.pump(const Duration(milliseconds: 1500));
  _claim(tester);
}

Finder _panel() => find.descendant(
      of: find.byType(BottomBarMarker, skipOffstage: false),
      matching: find.byType(GlassContainer, skipOffstage: false),
      skipOffstage: false,
    );

Finder _labelIn(String text) => find.descendant(
      of: find.byType(BottomBarMarker, skipOffstage: false),
      matching: find.text(text, skipOffstage: false),
      skipOffstage: false,
    );

void main() {
  // 662 = 5 项时代的夹紧临界（表观回归对照）；292 = 5×44+72（文档里的溢出阈值）
  for (final w in <double>[662, 320, 300, 292, 291, 288, 240, 205]) {
    testWidgets('窄端 W=${w}：逐项量标签矩形两端是否都在面板内',
        (WidgetTester tester) async {
      await _pumpShellAt(tester, Size(w, 600));
      if (_panel().evaluate().isEmpty) {
        debugPrint('CLAMP W=$w 面板未找到');
        return;
      }
      final panel = tester.getRect(_panel().first);
      final fit = (w - _kTabRowLoss) / _tabCount;
      debugPrint('CLAMP W=$w panelW=${panel.width.toStringAsFixed(2)} '
          'fit=${fit.toStringAsFixed(3)} 夹紧点=$_kTabWidthMin');
      for (final s in _tabLabels) {
        final f = _labelIn(s);
        if (f.evaluate().isEmpty) {
          debugPrint('CLAMP    「$s」在树上 0 份 ⇒ 入口不存在');
          continue;
        }
        final r = tester.getRect(f.first);
        final inside =
            r.left >= panel.left - 0.5 && r.right <= panel.right + 0.5;
        debugPrint('CLAMP    「$s」rect=${r.left.toStringAsFixed(1)}..'
            '${r.right.toStringAsFixed(1)} w=${r.width.toStringAsFixed(1)} '
            '在面板内=$inside 中心=${r.center.dx.toStringAsFixed(1)}');
      }
    });
  }
}
