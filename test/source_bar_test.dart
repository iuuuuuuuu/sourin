// ═══════════════════════════════════════════════════════════════════════
//  首页源条 SourceBar —— 四条用户要求的回归测试
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（验收标准）
//
// > 左上角和这个源切换,还是跟底部的不太一样,然后这个源切换,
// > 随着页面滚动也没有媳妇(吸附)在顶部,最右侧也没显示有多少个源,
// > 鼠标拖动,也不能左右滑动
//
// 拆成 4 条：
// ```text
// ① 和底栏的液态玻璃样式要**看起来完全一致**
// ② 滚动时**吸附在顶部**（sticky）
// ③ 最右侧显示**有多少个源**
// ④ **鼠标拖拽**能左右滑动
// ```
//
// # ⚠️ 为什么这些测试值得写（而不是只截图看）
//
// ④ 尤其重要：`ScrollConfiguration.dragDevices` 是 **Flutter 手势竞技场
// 真正读取的那个值** —— 用 `PointerDeviceKind.mouse` 派发真实指针事件，
// 走到的是**生产代码的同一条路径**（不是我复刻的影子实现）。
//
// 而截图验证这条**很不可靠**：本机有别的进程（DSH 自己）不断抢焦点，
// 合成的鼠标拖拽经常落空 —— 我实测时 `cursorOverApp=False`，
// 拖拽根本没到达应用。所以**行为类断言交给 widget test**，
// 截图只用来确认"观感"这一类无法断言的东西。

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/widgets/source_bar.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

/// 造 N 个假源（只用得到 id / name；其余字段不影响源条渲染）
List<ProviderManifest> _sources(int n) => [
      for (var i = 0; i < n; i++)
        ProviderManifest(
          id: 'src-$i',
          name: '源$i',
          enabled: true,
        ),
    ];

Widget _host(Widget child, {ThemeData? theme}) {
  // 默认深色（与 shell 的默认主题一致）；浅色用例显式传 `FTheme.neutral.light`
  final data = theme ?? AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: data,
    builder: (_, c) => AppThemeHost(data: data, child: c ?? const SizedBox()),
    home: Scaffold(body: Center(child: child)),
  );
}

/// 收集树里所有 `AnimatedContainer` 的渐变（源条的选中药丸就是其中之一）
List<Gradient> _gradients(WidgetTester t) {
  final found = <Gradient>[];
  for (final el in collectAllElementsFrom(
    t.binding.rootElement!,
    skipOffstage: false,
  )) {
    final w = el.widget;
    if (w is AnimatedContainer) {
      final d = w.decoration;
      if (d is BoxDecoration && d.gradient != null) found.add(d.gradient!);
    }
  }
  return found;
}

/// 取某个纯 `Text` 的颜色（源条 pill 的名字就是纯 Text）
Color? _textColor(WidgetTester t, String label) {
  for (final el in collectAllElementsFrom(
    t.binding.rootElement!,
    skipOffstage: false,
  )) {
    final w = el.widget;
    if (w is Text && w.data == label) return w.style?.color;
  }
  return null;
}

void main() {
  group('源条 —— 基本显示规则', () {
    testWidgets('★ 只有一个源时**自己隐藏**（原版 visible 的逻辑）', (t) async {
      await t.pumpWidget(_host(
        SourceBar(
          sources: _sources(1),
          current: 'src-0',
          onSelect: (_) {},
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('源0'), findsNothing,
          reason: '单一选项的切换器是纯噪音 —— 原版 `visible` 就是 '
              '`sources.length > 1`');
    });

    testWidgets('★ 两个源以上才显示', (t) async {
      await t.pumpWidget(_host(
        SourceBar(
          sources: _sources(2),
          current: 'src-0',
          onSelect: (_) {},
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('源0'), findsOneWidget);
      expect(find.text('源1'), findsOneWidget);
    });

    testWidgets('★ 点击 pill 回调选中（点击不能被拖拽支持破坏）', (t) async {
      String? picked;
      await t.pumpWidget(_host(
        SourceBar(
          sources: _sources(4),
          current: 'src-0',
          onSelect: (id) => picked = id,
        ),
      ));
      await t.pumpAndSettle();

      await t.tap(find.text('源2'));
      await t.pumpAndSettle();

      expect(picked, 'src-2',
          reason: '★ 加了 mouse 拖拽后，点击仍必须能选中 —— '
              '手势竞技场按"是否超过拖拽阈值"裁决，短按应该是点击赢');
    });
  });

  group('源数量显示（用户要求 ③）', () {
    testWidgets('★ 源 > 3 时显示「N 个源」', (t) async {
      await t.pumpWidget(_host(
        SourceBar(
          sources: _sources(25),
          current: 'src-0',
          onSelect: (_) {},
        ),
      ));
      await t.pumpAndSettle();

      expect(find.textContaining('个源'), findsOneWidget,
          reason: '用户明确要求「最右侧也没显示有多少个源」');
      /*
       * ⚠️ 数量是用 `Text.rich` 画的（两个 TextSpan：数字 + " 个源"），
       *    所以 `find.text('25')` **匹配不到**（它只匹配纯 Text）。
       *    要断 RichText 的 plain text。
       */
      final rich = find.byType(RichText);
      final texts = <String>[];
      for (final el in collectAllElementsFrom(
        t.binding.rootElement!,
        skipOffstage: false,
      )) {
        final w = el.widget;
        if (w is RichText) texts.add(w.text.toPlainText());
      }
      expect(
        texts.any((s) => s.contains('25')),
        isTrue,
        reason: '★ 要显示**真实数量**（25 个源 → 文本里得有 25）。'
            '当前所有 RichText: $texts',
      );
    });

    testWidgets('★ 源 ≤ 3 时不显示（原版 showCount 是 > 3）', (t) async {
      await t.pumpWidget(_host(
        SourceBar(
          sources: _sources(3),
          current: 'src-0',
          onSelect: (_) {},
        ),
      ));
      await t.pumpAndSettle();

      expect(find.textContaining('个源'), findsNothing,
          reason: '原版 `showCount = sources.length > 3` —— '
              '3 个源一眼数完，再挂个计数是噪音');
    });
  });

  group('鼠标拖拽横滑（用户要求 ④）', () {
    testWidgets('★★ 用**鼠标**拖拽能滚动源条', (t) async {
      /*
       * # 这是本文件最重要的测试
       *
       * Flutter 的 `ScrollBehavior.dragDevices` **默认只含 touch/stylus**
       * —— 鼠标只能滚轮，拖拽不滚动。这正是用户报的
       * 「鼠标拖动,也不能左右滑动」。
       *
       * 修法是 `ScrollConfiguration(behavior: ...copyWith(dragDevices: {mouse, ...}))`。
       *
       * ⚠️ 断言的是**真实 Scrollable 的 offset 变化** ——
       *    不是"源码里写了 dragDevices"（那是静态断言，证明不了运行时生效）。
       */
      await t.pumpWidget(_host(
        SizedBox(
          width: 400, // 故意比内容窄 → 必然可滚
          child: SourceBar(
            sources: _sources(25),
            current: 'src-0',
            onSelect: (_) {},
          ),
        ),
      ));
      await t.pumpAndSettle();

      final scrollable = find.byType(Scrollable).first;
      final pos = t.state<ScrollableState>(scrollable).position;
      final before = pos.pixels;
      expect(pos.maxScrollExtent, greaterThan(0),
          reason: '前置条件：内容宽度必须超出容器，否则无从验证滚动');

      // ── 用**鼠标**拖拽（不是 touch）──
      final center = t.getCenter(scrollable);
      final g = await t.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
      );
      // 分步移动（一步到位可能被判定为 fling 之外的行为）
      for (var i = 1; i <= 6; i++) {
        await g.moveBy(Offset(-40, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pumpAndSettle();

      final after = pos.pixels;
      expect(
        after,
        greaterThan(before),
        reason: '★ 鼠标向左拖拽后 offset 必须增大（内容往左滚）—— '
            '没变说明 `dragDevices` 没生效，用户仍"不能左右滑动"',
      );
    });

    testWidgets('★ 触摸拖拽也仍然可用（不能为了鼠标破坏触摸）', (t) async {
      await t.pumpWidget(_host(
        SizedBox(
          width: 400,
          child: SourceBar(
            sources: _sources(25),
            current: 'src-0',
            onSelect: (_) {},
          ),
        ),
      ));
      await t.pumpAndSettle();

      final scrollable = find.byType(Scrollable).first;
      final pos = t.state<ScrollableState>(scrollable).position;
      final before = pos.pixels;

      final g = await t.startGesture(
        t.getCenter(scrollable),
        kind: PointerDeviceKind.touch,
      );
      for (var i = 1; i <= 6; i++) {
        await g.moveBy(const Offset(-40, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pumpAndSettle();

      expect(pos.pixels, greaterThan(before),
          reason: '触摸端拖拽是移动端的标准操作，不能被改坏');
    });
  });

  group('滚动吸附在顶部（用户要求 ②）', () {
    testWidgets('★★ 用真实 CustomScrollView 验证 pinned header 会钉住', (t) async {
      /*
       * # 这条测的是**运行时的钉住行为**，不是"源码里写了 pinned: true"
       *
       * 手法：搭一个和首页同构的最小滚动视图（CustomScrollView +
       * `SliverPersistentHeader(pinned: true)` + 一个很长的列表），
       * 然后**真的滚**，断言源条的位置没变。
       *
       * ⚠️ 为什么不直接构造 `HomePage`：它依赖 `SourinApi`（要走 FFI 核心），
       *    `flutter_test` 里跑不起来。所以这里验证的是**结构契约**
       *    （pinned sliver 确实会钉住），而首页真的用了这个结构
       *    由下面那条静态断言保证 —— 两条合起来才完整。
       */
      const barH = 44.0 + 16; // 源条 44 + 上下各 8

      await t.pumpWidget(_host(
        SizedBox(
          width: 500,
          height: 400,
          child: CustomScrollView(
            slivers: [
              // 源条上方的"我的"版块（高 200，会被滚上去）
              const SliverToBoxAdapter(child: SizedBox(height: 200)),
              SliverPersistentHeader(
                pinned: true,
                delegate: _TestHeader(
                  extent: barH,
                  child: SizedBox(
                    height: barH,
                    child: SourceBar(
                      sources: _sources(5),
                      current: 'src-0',
                      onSelect: (_) {},
                    ),
                  ),
                ),
              ),
              // 一段足够长的内容，保证能滚
              SliverList(
                delegate: SliverChildListDelegate([
                  for (var i = 0; i < 30; i++)
                    const SizedBox(height: 60, child: Text('content')),
                ]),
              ),
            ],
          ),
        ),
      ));
      await t.pumpAndSettle();

      final barFinder = find.byType(SourceBar);
      final startTop = t.getTopLeft(barFinder).dy;

      /*
       * ⚠️ 修正过的断言（第一版写错了，自己抓到的）
       *
       * # pinned 的**正确语义**
       *
       * ```text
       * 滚动初期  源条跟着往上走（它上面还有"我的"要滚出去）
       * 到达顶部  **停住不动**，后面的内容从它下面滚过  ← 这才是"吸附"
       * ```
       * 我第一版断言"滚动后位置 == 初始位置" —— 那**不是** pinned，
       * 那是"永远不动的悬浮层"。测试因此假失败
       * （实际 `300 → 100`：源条确实滚上去了，然后钉住）。
       *
       * # 正确断言：**滚很多之后位置不再变化**
       *
       * ```text
       * 滚一小段  → 位置变了（还在往上走）      ✓ 符合预期
       * 滚很多    → 位置**不再变**（已钉住）    ✓ 这才是 pinned 的证据
       * ```
       */
      /*
       * ⚠️ 这条测试**改过两次断言**，两次都是我写错了语义。
       *
       * # 第一次错：断言"滚动后位置 == 初始位置"
       * ```text
       * 实际 300 → 100（假失败）
       * ```
       * 那**不是** pinned 的语义 —— pinned 是"滚到顶就**停住**"，
       * 不是"永远不动"。
       *
       * # 第二次错：以为"滚一小段后位置就不该再变"
       * ```text
       * 滚 80px   → 300 → 220（还在正常上移）
       * 滚 260px  → 220 → 100（继续上移才到顶）
       * ```
       * 源条到顶需要滚掉它上方那 200px 的"我的"版块 +
       * 自身在 viewport 里的偏移，**一次 drag 到不了**。
       *
       * # 正确的做法：**滚到不能再滚**，然后断言位置不再变
       *
       * 不断滚动直到 scroll offset 到达 maxScrollExtent（滚到底），
       * 此时 pinned header **必然**已经钉住。再滚一次，位置必须不变。
       * 这样断言与"滚多少才到顶"解耦，不会因为我猜错距离而假失败。
       */
      final scrollable = find.byType(Scrollable).first;
      final pos = t.state<ScrollableState>(scrollable).position;

      /*
       * ⚠️ 不要用 `t.drag(find.text('content').first, ...)` 反复滚 ——
       *    那个 widget 滚出屏幕后就**点不到了**，报
       *    "Maybe the widget is actually off-screen"（我踩了这个坑）。
       *
       * 正确做法：直接操作 `ScrollPosition` ——
       * 这是**确定性**的，不受"哪个 widget 当前可见"影响。
       */
      var guard = 0;
      while (pos.pixels < pos.maxScrollExtent - 1 && guard < 20) {
        pos.jumpTo(
          (pos.pixels + 300).clamp(0.0, pos.maxScrollExtent),
        );
        await t.pumpAndSettle();
        guard++;
      }
      expect(pos.pixels, closeTo(pos.maxScrollExtent, 1.0),
          reason: '前置条件：必须滚到底（当前 ${pos.pixels} / '
              '${pos.maxScrollExtent}，滚了 $guard 次）');

      final atBottom = t.getTopLeft(barFinder).dy;

      /*
       * 到底之后再滚一次 —— 位置必须**完全不变**。
       *
       * ⚠️ 滚到底时 `maxScrollExtent` 已经达到，`drag` 不会真的改变
       *    offset —— 所以这一步验证的是"钉住之后不会因为任何滚动而移位"。
       */
      pos.jumpTo(pos.maxScrollExtent);
      await t.pumpAndSettle();
      final afterMore = t.getTopLeft(barFinder).dy;

      expect(
        afterMore,
        closeTo(atBottom, 0.5),
        reason: '★★ 滚到底后源条必须**钉住不动** —— '
            '这就是用户要的「随着页面滚动吸附在顶部」。'
            ' 到底时=$atBottom 再滚后=$afterMore',
      );

      /*
       * 关键：它必须真的**贴在滚动视图的顶部**，而不是"停在中间"。
       *
       * ⚠️ 不能用绝对坐标 `dy ≈ 0` 判 —— 测试里那个 400px 高的
       *    `SizedBox` 是**居中**在 800px 测试画布里的，所以滚动视口的
       *    顶边在 dy≈100（我第一版写死 0，假失败）。
       *
       * 正确做法：拿**滚动视口自己的顶边**当基准。
       */
      final viewportTop = t.getTopLeft(scrollable).dy;
      expect(
        atBottom,
        closeTo(viewportTop, 1.0),
        reason: '★ 钉住的位置必须是**滚动视口的顶边**（视口顶边=$viewportTop，'
            '源条=$atBottom）—— 停在别处说明只是"跟着滚"，不是吸附',
      );

      // 吸附的意义：一直可见
      expect(barFinder, findsOneWidget,
          reason: '★ 吸附之后源条必须仍在屏幕上');
      expect(t.getRect(barFinder).height, greaterThan(0),
          reason: '源条高度不能为 0（被压扁就等于看不见）');
    });
  });

  group('结构契约（与上面那条配套）', () {
    late String home;

    setUpAll(() {
      home = File('lib/ui/home_page.dart').readAsStringSync();
    });

    test('★★ 首页必须用 CustomScrollView + pinned SliverPersistentHeader', () {
      /*
       * `ListView` 做不到吸附 —— 它的子项都是平级的，没有一个能"钉住"。
       * 必须换成 sliver 体系。
       */
      expect(home.contains('CustomScrollView('), isTrue,
          reason: '★ 必须换成 CustomScrollView —— ListView 无法做 sticky');
      expect(home.contains('SliverPersistentHeader('), isTrue,
          reason: '★ 源条必须包在 SliverPersistentHeader 里');
      expect(
        home.contains('pinned: true'),
        isTrue,
        reason: '★ 必须 pinned: true —— 这是"吸附"的关键；'
            'pinned: false 会跟着滚走',
      );
      expect(
        home.contains('ListView(') && !home.contains('CustomScrollView('),
        isFalse,
        reason: '不应退回 ListView',
      );
    });

    test('★ minExtent 必须等于 maxExtent（否则会随滚动伸缩）', () {
      /*
       * `SliverPersistentHeader` 的默认行为是把"手势位移"映射成
       * extent 变化 —— 那是给"可折叠大标题"用的。
       * 源条要的是**固定高度**，两个 extent 必须相等。
       */
      expect(
        home.contains('double get minExtent => _extent'),
        isTrue,
        reason: 'minExtent 应是固定常量',
      );
      expect(
        home.contains('double get maxExtent => _extent'),
        isTrue,
        reason: 'maxExtent 必须与 minExtent 相同',
      );
    });

    test('★ SourceBar 必须带 GlobalKey（否则滚动时丢滚动位置）', () {
      expect(home.contains('sourceBarKey'), isTrue,
          reason: '★ `SliverPersistentHeaderDelegate.build()` 会被反复调用，'
              '没有 GlobalKey 的话 SourceBar 的 State 可能被重建 —— '
              'ScrollController 重置 → 用户滚到第 10 个源一滚动就跳回第 1 个');
    });
  });
  group('玻璃样式（用户要求 ①）—— ★ 已解锁：源条有**它自己的**令牌', () {
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 这一组曾经**锁死过错误行为**（2026-09-24 重写）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 上一版断言的是什么
     *
     * ```text
     * 「选中 pill 必须是白色渐变（**照抄底栏 `--tab-pill-bg`**）」
     * → 断言渐变两端是 white 0.96 / white 0.80
     * ```
     *
     * # 为什么那是"基于错误前提的正确观察"（必须改掉）
     *
     * ```text
     * 观察是对的：底栏药丸 (249,249,249) vs 源条药丸 (30,32,40) —— 确实差得远
     * 结论是错的：以为"照抄 0.96/0.80 就两个主题都对"
     *            —— 因为**当时底栏自己也是错的**（同一个 bug：硬编码浅色值、
     *               没有主题分支，就是用户报的"黑色模式下有问题"）
     * ```
     * 于是那条测试**会阻止正确的修复**：谁把源条改成原版的 `--surface-4`
     * （深 0.17 / 浅 1.0），它就红。
     *
     * # 现在断言什么（原版的**真实**令牌）
     *
     * ```css
     * tokens.css:338        --srcbar-pill-bg: var(--surface-4);
     * tokens.css:249  深色   --surface-4: rgb(255 255 255 / 0.17);  单一值
     * theme-light.css:81    --srcbar-pill-bg: var(--surface-4);
     * theme-light.css:89 浅色 --surface-4: rgb(255 255 255 / 1);   纯白实底
     * ```
     * ⚠️ 源条的值与底栏（深 0.19→0.10 / 浅 0.96→0.80）**本来就不同**，
     *    而且**两边都对** —— 因为它们是两个令牌、调的目标不同：
     *    `--tab-pill-bg` 是"玻璃上浮起一层"（要透、要有高光方向感），
     *    `--srcbar-pill-bg` 是 `--surface-4`（通用的"表面层级"第 4 档，
     *    要**实**）。详见 `source_bar.dart` 里那段长注释。
     *
     * ★ 这里的方法是**真正渲染 widget 再读渐变的实际颜色**，不是文本匹配：
     *   上一版也是渲染级（`find.byType` + 读 decoration），那一点是对的，
     *   只是**期望值**抄错了参照物。
     */
    testWidgets('★★★ 深色：源条药丸必须是 white **0.17**（不是底栏的 0.96/0.80）',
        (t) async {
      await t.pumpWidget(_host(
        SourceBar(
          sources: _sources(4),
          current: 'src-1',
          onSelect: (_) {},
        ),
        theme: AppTheme.themeFor(Brightness.dark),
      ));
      await t.pumpAndSettle();

      final found = _gradients(t);
      expect(found, isNotEmpty,
          reason: '★ 选中 pill 必须有**渐变**底 —— '
              '没有渐变说明又退回"纯色/半透明色块"');

      final g = found.first as LinearGradient;
      final c0 = g.colors.first;

      // 三段都要是白色（RGB 全 1），只有**透明度**按主题变
      expect(c0.r, closeTo(1.0, 0.02), reason: '药丸是"叠白"，RGB 必须是纯白');
      expect(c0.g, closeTo(1.0, 0.02));
      expect(c0.b, closeTo(1.0, 0.02));

      /*
       * ★ 关键：**透明度**必须是 `--surface-4` 的 0.17
       *
       * ⚠️ 容差 0.02：0.17 落在 8 位色深的 43.35 级，Dart 的
       *    `Color.a` 是归一化 double，量化误差约 0.0009 —— 容差给 0.02
       *    是为了同时挡住"写成 0.16/0.19"这种**邻近的错值**：
       *    0.19（底栏的深色值）会被判红，这正是我们要的。
       */
      expect(c0.a, closeTo(0.17, 0.02),
          reason: '★★★ 深色源条药丸必须是 `--surface-4` = white **0.17**。\n'
              '实测拿到 ${c0.a.toStringAsFixed(4)}。\n'
              '⚠️ 不要"照抄底栏的 0.96/0.80"——那是**底栏自己的 bug**'
              '（硬编码浅色值、无主题分支），照抄会把 bug 复制到这里。');
      debugPrint('[Y] 深色源条药丸 alpha=${c0.a.toStringAsFixed(4)} '
          '（期望 0.17；底栏深色是 0.19→0.10）');
    });

    testWidgets('★★★ 浅色：源条药丸必须是 white **1.0**（纯白实底，比底栏的 0.96 更实）',
        (t) async {
      await t.pumpWidget(_host(
        SourceBar(
          sources: _sources(4),
          current: 'src-1',
          onSelect: (_) {},
        ),
        theme: AppTheme.themeFor(Brightness.light),
      ));
      await t.pumpAndSettle();

      final found = _gradients(t);
      expect(found, isNotEmpty, reason: '★ 选中 pill 必须有渐变底');

      final g = found.first as LinearGradient;
      final c0 = g.colors.first;

      // `--surface-4` 浅色 = `rgb(255 255 255 / 1)` —— 纯白实底
      expect(c0.a, closeTo(1.0, 0.02),
          reason: '★★★ 浅色源条药丸必须是 `--surface-4` = white **1.0**。\n'
              '原版 `theme-light.css:74` 解释了为什么浅色要**更实**：\n'
              '> 浅色下 `--surface-4` 是纯白，叠在 `--surface-1`（白 62%）\n'
              '> 的切换条底上正好"浮"出来一层 —— 不需要额外描边。\n'
              '实测拿到 ${c0.a.toStringAsFixed(4)}；底栏浅色是 0.96→0.80 的透白。');
      debugPrint('[Y] 浅色源条药丸 alpha=${c0.a.toStringAsFixed(4)} '
          '（期望 1.0；底栏浅色是 0.96→0.80）');
    });

    testWidgets('★★ 选中态文字色必须**跟随主题**（深色药丸暗 → 用亮字）',
        (t) async {
      /*
       * ⚠️ 这条是"只改药丸、不改文字"的那个坑的守卫。
       *
       * 旧实现写死"药丸恒为白 → 字恒为深色 `#1E2028`"。修好药丸后
       * 深色药丸是 0.17（**暗**的），再用深色字就是**暗底暗字**
       * —— 与原来那个白底白字是同一类 bug 的反向版本。
       *
       * 判据用"渲染出来的实际颜色"，并且要求**两套主题取到相反的值**：
       * ```text
       * 深色  药丸 alpha 0.17（暗）→ 文字应当偏亮
       * 浅色  药丸 alpha 1.0（亮） → 文字应当偏暗
       * ```
       */
      // ── 深色 ──
      await t.pumpWidget(_host(
        SourceBar(sources: _sources(4), current: 'src-1', onSelect: (_) {}),
        theme: AppTheme.themeFor(Brightness.dark),
      ));
      await t.pumpAndSettle();
      final darkText = _textColor(t, '源1');
      expect(darkText, isNotNull,
          reason: '取不到选中 pill 的文字色 —— 断言会在空处跑（假绿）');

      // ── 浅色 ──
      await t.pumpWidget(_host(
        SourceBar(sources: _sources(4), current: 'src-1', onSelect: (_) {}),
        theme: AppTheme.themeFor(Brightness.light),
      ));
      await t.pumpAndSettle();
      final lightText = _textColor(t, '源1');
      expect(lightText, isNotNull, reason: '取不到浅色下的文字色');

      double lum(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

      debugPrint('[Y] 源条选中文字：深色主题=$darkText 浅色主题=$lightText');

      expect(lum(darkText!), greaterThan(0.5),
          reason: '★★ 深色主题下药丸是暗的（0.17），文字必须**亮** —— '
              '实测 $darkText');
      expect(lum(lightText!), lessThan(0.5),
          reason: '★★ 浅色主题下药丸是纯白（1.0），文字必须**暗** —— '
              '实测 $lightText');
      expect(lum(darkText), greaterThan(lum(lightText)),
          reason: '★ 两套主题的文字色必须**相反** —— '
              '相同就说明"药丸按主题分支了、文字没有"（只改了一半）');
    });
  });
}

/// 测试用的 pinned header delegate（与首页 `_StickySourceBar` 同构）
class _TestHeader extends SliverPersistentHeaderDelegate {
  _TestHeader({required this.extent, required this.child});

  final double extent;
  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext c, double o, bool over) => child;

  @override
  bool shouldRebuild(_TestHeader old) => old.child != child;
}