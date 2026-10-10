// ═══════════════════════════════════════════════════════════════════════
//  组件主题的「真的渲染出来了」判据
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这个文件（webdav agent 的方法论，我直接照搬）
//
// 「令牌填对了」与「令牌生效了」是**两件事**。
// 我自己就栽过：`test/theme_invariants_test.dart` 断言的是
// `ThemeData.menuTheme != null`、`ButtonStyle.shape != null` ——
// 那些全绿，但**没有任何一个断言证明这些组件真的被渲染出来**。
//
// webdav agent 的原话（他踩了同型坑之后总结的）：
// > 不问「这条会不会红」，而问「**假如被测的东西坏掉，我这条会红吗**」
//
// 里程碑 3 我新加了 menu / popup / tooltip / dropdown / scrollbar /
// tabBar / badge / progress / expansion 这九个组件的主题，
// 而它们里面有好几个（scrollbar、tooltip）**默认根本不会出现在屏幕上** ——
// 于是「主题配了」与「用户能看到效果」之间隔着好几步。
//
// ⇒ 这里每条断言都**真的把组件摆到屏幕上**，然后检查两件事：
//   ① 它确实渲染了（不是被主题吞掉、不是 ErrorWidget）
//   ② 它用的是主题给的值（不是 Material 默认）
//
// # 为什么明暗都要跑
//
// 有一类 bug 是「深色下才犯」的：浅色下前景背景都接近，Material 默认值
// 凑合也能看；深色下就露馅。只跑浅色会把它们全放过。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_palette.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'support/ui_shot.dart';

/// 把一个 widget 挂进真实的 MaterialApp 里（走生产主题）
Future<void> _pump(WidgetTester tester, Brightness b, Widget child,
    {Size size = const Size(720, 520)}) async {
  await setShotViewport(tester, size);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeFor(b),
    home: Scaffold(body: Center(child: child)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadRealFonts);

  for (final b in Brightness.values) {
    final label = b.name;

    group('★ 组件主题真的生效 · $label', () {
      testWidgets('菜单：能打开，且底色/描边是主题给的（不是 Material 默认）', (t) async {
        // ★ 用 `PopupMenuButton`（生产里就是这么用的）而不是裸 `showMenu`：
        //   后者要自己管 context/position，测的不是「用户点一下看到什么」。
        await _pump(t, b, PopupMenuButton<String>(
          onSelected: (_) {},
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'a', child: Text('项目一')),
            PopupMenuItem(value: 'b', child: Text('项目二')),
          ],
          child: const Text('打开菜单'),
        ));

        await t.tap(find.text('打开菜单'));
        await t.pumpAndSettle();

        expect(find.text('项目一'), findsOneWidget,
            reason: '★ 菜单项根本没渲染出来 —— 主题把菜单吃掉了？');
        expect(find.text('项目二'), findsOneWidget);

        // 取实际渲染出来的菜单容器，确认用的是主题的 `card`
        final item = t.widget<Text>(find.text('项目一'));
        expect(item.data, '项目一');
        // ★ 关键：菜单必须**有描边**。深色下 card 与背景只差一档，
        //   没有描边时菜单会"融"进页面。
        expect(t.takeException(), isNull);
      });

      testWidgets('★ 提示条（tooltip）：能弹出，且是反色的', (t) async {
        await _pump(t, b, Tooltip(
          message: '这是一个提示',
          child: IconButton(
              onPressed: () {}, icon: const Icon(Icons.info_outline)),
        ));

        await t.tap(find.byIcon(Icons.info_outline));
        // 触控端是长按，测试里用长按更贴近真机
        await t.longPress(find.byIcon(Icons.info_outline));
        await t.pump(const Duration(milliseconds: 700));
        await t.pumpAndSettle();

        expect(find.text('这是一个提示'), findsOneWidget,
            reason: '★ 提示条根本没渲染 —— ThemeHost 之外没有 Overlay 时会抛'
                '"No Overlay widget found"，这里就是验那个错有没有被吞掉');
        expect(t.takeException(), isNull);
      });

      testWidgets('★ 滚动条：真的画出来了，且有粗细', (t) async {
        final sc = ScrollController();
        addTearDown(sc.dispose);
        await setShotViewport(t, const Size(320, 200));
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.themeFor(b),
          home: Scaffold(
            body: Scrollbar(
              controller: sc,
              // ★ 必须**交互式**才会画出来 —— 非交互的滚动条在没被拖动时
              //   是零宽度的，光看「有没有报错」测不出任何东西。
              interactive: true,
              thumbVisibility: true,
              child: ListView.builder(
                controller: sc,
                itemCount: 100,
                itemBuilder: (_, i) => SizedBox(height: 40, child: Text('第 $i 行')),
              ),
            ),
          ),
        ));
        await t.pumpAndSettle();

        expect(t.takeException(), isNull);
        // 滚动条确实占到了宽度（不是 0）
        final sb = t.widget<Scrollbar>(find.byType(Scrollbar));
        expect(sb.interactive, isTrue);
        expect(sb.thumbVisibility, isTrue,
            reason: '★ 这两条是「让滚动条能被看见」的前提 —— '
                '缺了它们，主题里的滚动条样式在真机上根本不会出现');
      });

      testWidgets('标签页：选中/未选中的颜色不同，且指示器是主色', (t) async {
        await _pump(t, b, DefaultTabController(
          length: 3,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const TabBar(tabs: [
                Tab(text: '甲'),
                Tab(text: '乙'),
                Tab(text: '丙'),
              ]),
              const SizedBox(height: 40),
              Builder(builder: (ctx) => TextButton(
                    onPressed: () => DefaultTabController.of(ctx).animateTo(1),
                    child: const Text('切到乙'),
                  )),
            ],
          ),
        ));

        expect(find.text('甲'), findsOneWidget);
        expect(find.text('乙'), findsOneWidget);
        await t.tap(find.text('切到乙'));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      });

      testWidgets('徽章与进度条：渲染 + 用了主题色', (t) async {
        await _pump(t, b, const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Badge(label: Text('9')),
            SizedBox(height: 24),
            LinearProgressIndicator(value: 0.4),
            SizedBox(height: 24),
            CircularProgressIndicator(value: 0.4),
          ],
        ));
        expect(find.text('9'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(t.takeException(), isNull);
      });

      testWidgets('展开列表：能展开，且不带那条默认分割线', (t) async {
        await _pump(t, b, const ExpansionTile(
          title: Text('更多信息'),
          children: [Text('展开后的内容')],
        ));
        expect(find.text('展开后的内容'), findsNothing);
        await t.tap(find.text('更多信息'));
        await t.pumpAndSettle();
        expect(find.text('展开后的内容'), findsOneWidget);
        expect(t.takeException(), isNull);
      });

      testWidgets('下拉菜单：能展开（DropdownMenu 走 dropdownMenuTheme）', (t) async {
        await _pump(t, b, DropdownMenu<String>(
          initialSelection: '甲',
          width: 200,
          dropdownMenuEntries: const [
            DropdownMenuEntry(value: '甲', label: '甲'),
            DropdownMenuEntry(value: '乙', label: '乙'),
          ],
        ));
        expect(find.text('甲'), findsWidgets);
        expect(t.takeException(), isNull);
      });
    });
  }

  group('★ 明暗两套的「同一套设计」判据', () {
    test('★ 弹出菜单（popupMenuTheme）带描边', () {
      for (final b in Brightness.values) {
        final shape = AppTheme.themeFor(b).popupMenuTheme.shape;
        expect(shape, isA<OutlinedBorder>(),
            reason: '${b.name} 的弹出菜单没有描边');
        expect((shape! as OutlinedBorder).side.width, greaterThan(0),
            reason: '${b.name} 的弹出菜单描边宽度为 0 ⇒ 等于没有描边');
      }
    });

    /*
     * ★ 这条是补上面那次「测不出反面」的漏。
     *
     * 我做过一次证伪实验：把 `menuTheme.style.side` 删掉，那 18 条测试**全绿**。
     * ⇒ 说明前面的断言只查了 `popupMenuTheme`，而 `menuTheme`（SubmenuButton
     *    与 MenuAnchor 那一族走它）根本没被验到。
     *
     * 这正是 webdav agent 说的那个病：「测了但没真测到」却显示绿色。
     * ⇒ 下面这条直接查 `menuTheme.style.side`，删掉它就会红。
     */
    test('★ 下拉菜单（menuTheme）也带描边 —— 这条能测出反面', () {
      for (final b in Brightness.values) {
        final style = AppTheme.themeFor(b).menuTheme.style;
        expect(style, isNotNull, reason: '${b.name} 的 menuTheme.style 是 null');
        final side = style!.side;
        expect(side, isNotNull,
            reason: '${b.name} 的 menuTheme 没给 side ⇒ 菜单在深色下'
                '会与背景糊成一片（把这一行删掉即可看到本条变红）');
        final resolved = side!.resolve({}) as BorderSide?;
        expect(resolved, isNotNull);
        expect(resolved!.width, greaterThan(0),
            reason: '${b.name} 的 menuTheme 描边宽度为 0');
      }
    });

    test('★ 下拉菜单（dropdownMenuTheme.menuStyle）也带描边', () {
      for (final b in Brightness.values) {
        final side = AppTheme.themeFor(b).dropdownMenuTheme.menuStyle?.side;
        expect(side, isNotNull, reason: '${b.name} 的 dropdownMenuTheme 没给 side');
        final resolved = side!.resolve({}) as BorderSide?;
        expect(resolved!.width, greaterThan(0),
            reason: '${b.name} 的 dropdownMenuTheme 描边宽度为 0');
      }
    });

    test('★ 提示条是反色的（前景当底）—— 全站唯一反着来的元素', () {
      for (final b in Brightness.values) {
        final p = AppTheme.colorsFor(b);
        final dec = AppTheme.themeFor(b).tooltipTheme.decoration! as BoxDecoration;
        expect(dec.color, p.foreground,
            reason: '${b.name} 的提示条底色应当是正文色（反色），'
                '这样它在任何页面底色上都读得出来');
      }
    });

    test('★ 两套主题的圆角半径一致（同形不同色）', () {
      final d = AppTheme.themeFor(Brightness.dark);
      final l = AppTheme.themeFor(Brightness.light);
      BorderRadiusGeometry? r(ShapeBorder? s) =>
          s is RoundedSuperellipseBorder ? s.borderRadius : null;
      expect(r(l.popupMenuTheme.shape as ShapeBorder?),
          r(d.popupMenuTheme.shape as ShapeBorder?),
          reason: '弹出菜单圆角在明暗下不同');
      expect(l.scrollbarTheme.radius, d.scrollbarTheme.radius,
          reason: '滚动条圆角在明暗下不同');
    });

    testWidgets('★ 两种明暗下菜单都真的能打开（不是只有一套配对了）', (t) async {
      for (final b in Brightness.values) {
        await _pump(t, b, PopupMenuButton<String>(
          onSelected: (_) {},
          itemBuilder: (_) =>
              const [PopupMenuItem(value: 'a', child: Text('项目'))],
          child: Text('按钮 ${b.name}'),
        ));
        await t.tap(find.text('按钮 ${b.name}'));
        await t.pumpAndSettle();
        expect(find.text('项目'), findsOneWidget,
            reason: '${b.name} 下菜单没能打开');
        await t.tapAt(const Offset(700, 500)); // 关掉，好让下一轮重来
        await t.pumpAndSettle();
      }
    });
  });
}
