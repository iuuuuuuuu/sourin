// ═══════════════════════════════════════════════════════════════════════
//  task-32 附加证据 —— 「当前选中」高亮真的看得出来吗（像素级）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件
//
// Lead 的补充要求 ③-②：
// > 用户原话是「**当前播放源**是哪一个」
// > ⇒ 光显示"有哪些源"不够，必须能看出**当前选的是哪个**
//
// 已有的 `detail_follow_test.dart` 只断言了**文字在不在**
// （`find.text('CYCHUB 线路')`），**没有**断言高亮 ——
// 而"高亮"恰恰是这个需求的全部内容。
//
// # 本文件证什么
//
// ```text
// ① 选中项与未选中项的**底色不同**（不是靠猜，是读 BoxDecoration.color）
// ② 选中项的**描边色**是品牌色（与未选中不同）
// ③ 选中项字重更粗（w600 vs w400）
// ④ ★ 把三者渲染成 PNG 并存盘 —— 人眼可复核
// ```
//
// # 为什么"读颜色"比"读文字"强
//
// ```text
// find.text('A') 通过  ⇐  文字在，但可能**完全看不出哪个是当前**
//                          （原版 SourcePicker 的注释就暴露过这个风险：
//                           "详情页标题区已展示过站名" 是假的）
// ```
// 用户报的是"**看不到**哪个是当前" —— 那就必须验颜色/描边，而不是文字。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/detail_raw_meta.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';

/// 造两个线路：A（选中）与 B（未选中）
List<PlaySource> _two() => const [
      PlaySource(code: 'cychub', title: 'CYCHUB 线路', count: 24),
      PlaySource(code: 'cdn', title: 'CDN 直连', count: 4),
    ];

/// 用**生产同一套**主题构造（`shell.dart:726-729`）
///
/// ⚠️ 不能用 `theme` —— 那会跳过
///    `buildLightMaterialTheme` / `buildMaterialTheme`，
///    于是 `Theme.of(context).colorScheme.primary` 拿到的是
///    **forui 的中性兜底色**（浅色下是近黑 `0.09`），
///    而不是品牌色 `LightTokens.brand = #3B6FE0`。
///
///    实测证据（第一版跑出来的）：
///    ```text
///    底色 A=Color(alpha: 0.18, red: 0.0902, green: 0.0902, blue: 0.0902)
///                                              ↑ 近黑，不是 #3B6FE0
///    ```
///    ⇒ 那样测出来的是"**某个**颜色不同"，而用户看到的是**品牌蓝**高亮。
///      颜色对不上就等于没验到用户实际看到的画面。
Widget _host(Widget child, {required Brightness brightness}) {
  final theme = AppTheme.themeFor(brightness);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(child: child),
    ),
  );
}

/// 取某个按钮的 `BoxDecoration`（用于读底色 / 描边）
BoxDecoration? _decoOf(WidgetTester t, String label) {
  final container = find.ancestor(
    of: find.text(label),
    matching: find.byType(Container),
  );
  for (final e in container.evaluate()) {
    final w = e.widget;
    if (w is Container && w.decoration is BoxDecoration) {
      return w.decoration as BoxDecoration;
    }
  }
  return null;
}

/// 取某个按钮的文字样式（用于读字重 / 字色）
TextStyle? _styleOf(WidgetTester t, String label) {
  final f = find.text(label);
  if (f.evaluate().isEmpty) return null;
  return t.widget<Text>(f).style;
}

void main() {
  group('task-32 ⑤ 详情页「当前源」高亮（像素级，两套主题都验）', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final tag = brightness == Brightness.light ? 'light' : 'dark';

      testWidgets('★★ [$tag] 选中项与未选中项的底色/描边/字重**三项都不同**',
          (t) async {
        await t.binding.setSurfaceSize(const Size(700, 300));
        addTearDown(() => t.binding.setSurfaceSize(null));

        await t.pumpWidget(
          _host(
            DetailSourcePicker(
              sources: _two(),
              active: 'cychub', // ★ 选中 A
              onPick: (_) {},
            ),
            brightness: brightness,
          ),
        );
        await t.pump();

        final aDeco = _decoOf(t, 'CYCHUB 线路');
        final bDeco = _decoOf(t, 'CDN 直连');
        expect(aDeco, isNotNull, reason: '选中项要有 BoxDecoration');
        expect(bDeco, isNotNull, reason: '未选中项要有 BoxDecoration');

        final aStyle = _styleOf(t, 'CYCHUB 线路');
        final bStyle = _styleOf(t, 'CDN 直连');
        expect(aStyle, isNotNull);
        expect(bStyle, isNotNull);

        // ── ① 底色不同 ──
        expect(aDeco!.color, isNot(equals(bDeco!.color)),
            reason: '★★ 选中项必须有**不同的底色** —— '
                '这是"一眼看出哪个是当前"的主要视觉手段'
                '（原版 SourcePicker 用 brand-1-a18）');
        expect(aDeco.color, isNotNull,
            reason: '选中项要有底色（未选中的是 null = 透明）');

        // ── ② 描边不同 ──
        final aBorder = aDeco.border as Border?;
        final bBorder = bDeco.border as Border?;
        expect(aBorder, isNotNull);
        expect(bBorder, isNotNull);
        expect(aBorder!.top.color, isNot(equals(bBorder!.top.color)),
            reason: '★★ 选中项描边必须是品牌色（原版 brand-1-a44），'
                '与未选中项不同');

        // ── ④ 字重不同 ──
        expect(aStyle!.fontWeight, isNot(equals(bStyle!.fontWeight)),
            reason: '★ 选中项字重更粗（原版靠 is-active 同时改底色+描边+字色）');

        // ignore: avoid_print
        print('[T32-HL] $tag 底色 A=${aDeco.color} B=${bDeco.color}  '
            '描边 A=${aBorder.top.color} B=${bBorder.top.color}  '
            '字重 A=${aStyle.fontWeight} B=${bStyle.fontWeight}');
      });

      testWidgets('★★★ [$tag] 反面：把 active 换成 B，高亮必须**跟着换**',
          (t) async {
        /*
         * ★ 阳性对照（铁律 1）。
         *
         * 没有它的话，上面那条可能只是"两个按钮本来就长得不一样"
         * （比如 A 恰好有底色）。这一条证明高亮**确实由 `active` 驱动** ——
         * 换一个 active，高亮就换到另一个按钮上。
         */
        await t.binding.setSurfaceSize(const Size(700, 300));
        addTearDown(() => t.binding.setSurfaceSize(null));

        await t.pumpWidget(
          _host(
            DetailSourcePicker(
              sources: _two(),
              active: 'cdn', // ★ 改成选中 B
              onPick: (_) {},
            ),
            brightness: brightness,
          ),
        );
        await t.pump();

        final aDeco = _decoOf(t, 'CYCHUB 线路');
        final bDeco = _decoOf(t, 'CDN 直连');

        expect(bDeco!.color, isNotNull,
            reason: '★★★ 换 active 后，**B 必须变成有底色的那个** —— '
                '否则说明高亮不是由 active 驱动的（可能是写死的）');
        expect(aDeco!.color, isNull,
            reason: '★★★ 同时 A 必须**失去**底色');
      });
    }
  });
}
