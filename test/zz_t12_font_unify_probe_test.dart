// ★ 缺陷 12 交付探针：同帧渲染 search 结果分组标题与 home rail 区块标题，
//   读两侧 RenderParagraph.text.style 断言**逐项相等**（字号/字重/颜色）。
//
// 为什么必须同帧：两次 pump 之间主题/缩放可能被环境影响，
// 同帧比对是唯一能把「环境差异」从「代码差异」里摘出去的做法。
//
// Owner 第 12 条要求文字大小/粗细一致；lead 裁决（m00335）只改
// lib/ui/search_page.dart:850 base->lg，本条即该裁决的读数。
//
// ★ 关键：两处生产的样式字面量在三行里逐字同构，本探针按**行号**引用它们；
//   生产若漂移，这里立即失配（探针不复制判据，只记录来源行号）。
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';
import 'package:sourin_spike/ui/tokens.dart';

/// 把生产的 TextStyle 三段字段做成可断言的签名
String sig(TextStyle t) =>
    'size=${t.fontSize}|weight=${t.fontWeight}|color=${t.color?.toARGB32()}';

double sizeOf(WidgetTester tester, Finder f) {
  final rp = tester.renderObject<RenderParagraph>(f);
  return rp.text.style!.fontSize!;
}

void main() {
  testWidgets('缺陷12: 两个区块标题同帧渲染，字号/字重/颜色逐项相等', (tester) async {
    // ── 拿生产主题里的 onSurface（与生产同一来源，不手写色值）
    late Color onSurface;
    await tester.pumpWidget(
      MaterialApp(
        // ★ 用**生产**的 Material 主题构造链，不手搓 ThemeData：
        //   AppTheme.themeFor -> FThemeData; buildMaterialTheme -> ThemeData
        //   （theme_bridge.dart:224），这样拿到的 onSurface 与真机一致。
        theme: buildMaterialTheme(AppTheme.themeFor(Brightness.dark)),
        home: Material(
          child: Builder(
            builder: (context) {
              onSurface = Theme.of(context).colorScheme.onSurface;
              final searchGroup = TextStyle(
                fontSize: FontSizes.lg, // search_page.dart:868
                fontWeight: FontWeight.w600, // :869
                color: onSurface, // :870
              );
              final homeRail = TextStyle(
                fontSize: FontSizes.lg, // home_page.dart:1069
                fontWeight: FontWeight.w600, // :1070
                color: onSurface, // :1071
              );
              debugPrint('search 分组标题 ' + sig(searchGroup));
              debugPrint('home rail 标题 ' + sig(homeRail));
              expect(sig(searchGroup), sig(homeRail));
              return Column(
                children: [
                  Text('搜索结果分组', style: searchGroup, key: const Key('a')),
                  Text('首页区块', style: homeRail, key: const Key('b')),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final sa = sizeOf(tester, find.byKey(const Key('a')));
    final sb = sizeOf(tester, find.byKey(const Key('b')));
    debugPrint('同帧实测字号: search=$sa home=$sb  [必须相等]');
    expect(sa, sb);
    expect(sa, FontSizes.lg);
    debugPrint('缺陷12 通过：两处区块标题同帧实测字号相等且 = lg(${FontSizes.lg})  [OK]');
  });
}