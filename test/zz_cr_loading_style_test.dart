// OPS-14 回归测试：loading 样式（颜色太浅、圈太大）
//
// ★ Owner 原话（逐字）：
//   「还有这个loading样式,那个转圈的颜色太浅了,然后这个圆圈是不是有点大?
//     我感觉这个效果不太好 优化一下」
//
// # 这个文件钉住什么
// ```text
// 1. 渲染级：共享组件 AppLoading 真渲染出来的 CircularProgressIndicator
//    strokeWidth >= 2.5、渲染盒直径 <= 32、颜色不是浅灰白
//    （alpha 不低于 0.5，且不等于 Colors.white —— player 两处写死的就是纯白）。
// 2. 明暗两档都验：深底用主题主色/明确白，浅底用 onSurfaceVariant 一档。
// 3. 源码门禁：player 的 _LoadingOverlay 已换成共享组件，
//    且 player 里不再有 CircularProgressIndicator(color: Colors.white)。
// ```
//
// ⚠ 为什么渲染盒直径和 strokeWidth 都要断言：
//    只断言 strokeWidth 的话，一个「4px 描边但外面套 44 盒子」的圈照样能过
//    —— 那正是现状（player 缓冲显式 SizedBox 44）。
//    两道一起钉，「圈太大」这个缺陷才真的被看住。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_loading.dart';

/// 把共享组件挂到真实主题里渲染（AppThemeHost 与生产同一条接线）
///
/// ⚠ 为什么这里必须自己套 [Directionality]：
///    `AppThemeHost` 只注入 ThemeData，**不提供** Directionality；
///    生产里这层是 MaterialApp 给的。少了它，`label != null` 那条分支里的
///    `Text` 会在 RichText.createRenderObject 处抛 'No Directionality widget found' ——
///    那是**测试宿主**缺东西，不是组件缺陷，所以补在宿主里而不是改组件。
Widget _host(Widget child, Brightness b) => Directionality(
      textDirection: TextDirection.ltr,
      child: AppThemeHost(
        data: AppTheme.themeFor(b),
        child: Center(child: child),
      ),
    );

/// ★ 剥掉注释，只留**代码**
///
/// 为什么必须剥（这条门禁第一版就栽在这儿）：
/// 它原本直接对 `lib/ui/player_page.dart` 全文跑正则，于是**我自己的说明注释**
/// 里那句「原来这里是裸的 CircularProgressIndicator」被判成了违规 ——
/// 门禁对散文开火。缺陷是**门禁本身**的：它该管代码，不该管注释。
/// ⇒ 现在先剥注释再匹配，`//` 落在引号内（URL 之类）也不误伤。
String _stripComments(String src) {
  // ① 块注释 /* ... */（可跨行）
  var out = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  // ② 行注释 // ...，且必须逐字符扫过字符串字面量，避免把 URL 的 // 当注释
  final buf = StringBuffer();
  var quote = '';
  var escaped = false;
  for (var i = 0; i < out.length; i++) {
    final ch = out[i];
    if (escaped) {
      escaped = false;
      buf.write(ch);
      continue;
    }
    if (ch == r'\') {
      escaped = true;
      buf.write(ch);
      continue;
    }
    if (quote.isNotEmpty) {
      if (ch == quote) quote = '';
      buf.write(ch);
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      buf.write(ch);
      continue;
    }
    if (ch == '/' && i + 1 < out.length && out[i + 1] == '/') {
      while (i < out.length && out[i] != '\n') {
        i++;
      }
      buf.write('\n');
      continue;
    }
    buf.write(ch);
  }
  return buf.toString();
}

/// 取渲染树里唯一的那个 CircularProgressIndicator
CircularProgressIndicator _onlyIndicator(WidgetTester tester) {
  final all = tester
      .widgetList<CircularProgressIndicator>(find.byType(CircularProgressIndicator))
      .toList();
  expect(all.length, 1, reason: '应当恰好渲染出一个 CircularProgressIndicator');
  return all.single;
}

void main() {
  group('OPS-14 · AppLoading 渲染级规格', () {
    testWidgets('深色底：strokeWidth 够实、圈不大、颜色不是浅灰白', (tester) async {
      await tester.pumpWidget(_host(const AppLoading(), Brightness.dark));
      final ind = _onlyIndicator(tester);

      // ── 描边不能是发丝 ──
      expect(
        ind.strokeWidth,
        greaterThanOrEqualTo(2.5),
        reason: '描边太细，视觉上就是一根发丝（Owner：效果不好）',
      );

      // ── 取**实际渲染出来**的盒径，而不是只读常量 ──
      final size = tester.getSize(find.byType(AppLoading));
      expect(
        size.width,
        lessThanOrEqualTo(32),
        reason: '圈太大（现状：player 缓冲显式 44，默认 40）',
      );
      expect(size.width, lessThanOrEqualTo(size.height));

      // ── 颜色不是浅灰白 ──
      final color = ind.color;
      expect(color, isNotNull, reason: '必须显式给颜色，不能落到主题兜底的浅灰');
      final c = color!;
      expect(
        c == Colors.white,
        isFalse,
        reason: 'player 两处写死 Colors.white，正是 Owner 说「太浅」的那一版',
      );
      expect(
        (c.a * 255.0).round(),
        greaterThanOrEqualTo(128),
        reason: 'alpha 低于 0.5，叠在深底上就是灰白发丝',
      );

      // ── 深色底上必须真的看得见：与深底有亮度差 ──
      final bg = AppTheme.colorsFor(Brightness.dark).background;
      expect(
        c.computeLuminance(),
        greaterThan(bg.computeLuminance() + 0.15),
        reason: '转圈与深底亮度差太小 = 用户说的「太浅」',
      );
    });

    testWidgets('浅色底：改用更深的一档，仍然看得清', (tester) async {
      await tester.pumpWidget(_host(const AppLoading(), Brightness.light));
      final ind = _onlyIndicator(tester);
      final c = ind.color!;

      final bg = AppTheme.colorsFor(Brightness.light).background;
      expect(
        c.computeLuminance(),
        lessThan(bg.computeLuminance() - 0.15),
        reason: '浅色底上转圈必须明显更暗，否则同样「看不见」',
      );
      expect((c.a * 255.0).round(), greaterThanOrEqualTo(128));
      expect(c, isNot(Colors.white));
    });

    testWidgets('带文案时不塌陷：文案保留且不再用纯白', (tester) async {
      await tester.pumpWidget(
        _host(const AppLoading(label: '正在加载…'), Brightness.dark),
      );
      _onlyIndicator(tester);
      final text = tester.widget<Text>(find.text('正在加载…'));
      final style = text.style;
      expect(style?.color, isNotNull);
      expect(style!.color, isNot(Colors.white));
    });
  });

  group('OPS-14 · 源码门禁：player 换用共享组件', () {
    late String playerSrc;
    setUpAll(() {
      playerSrc = _stripComments(
        File('lib/ui/player_page.dart').readAsStringSync(),
      );
    });

    test('_LoadingOverlay 已换成共享组件 AppLoading', () {
      final m = RegExp(
        r'class _LoadingOverlay.*?\{(.*?)\n\}',
        dotAll: true,
      ).firstMatch(playerSrc);
      expect(m, isNotNull, reason: '找不到 _LoadingOverlay 定义');
      final classBody = m!.group(1)!;
      expect(
        classBody.contains('AppLoading'),
        isTrue,
        reason: '_LoadingOverlay 必须改用共享组件 AppLoading',
      );
      expect(
        classBody.contains('CircularProgressIndicator'),
        isFalse,
        reason: '_LoadingOverlay 内不得再有裸 CircularProgressIndicator',
      );
    });

    test('player 不再写死 Colors.white 的转圈', () {
      final bad = RegExp(
        r'CircularProgressIndicator\s*\(\s*color:\s*Colors\.white',
      ).allMatches(playerSrc).length;
      expect(
        bad,
        0,
        reason: '仍有 $bad 处 CircularProgressIndicator(color: Colors.white)',
      );
    });
  });
}
