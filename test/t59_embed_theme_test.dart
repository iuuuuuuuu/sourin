// ═══════════════════════════════════════════════════════════════════════
//  task-60 / T2：嵌入态自绘主题底色 + 侧栏排版
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 你参照一下腾讯视频的播放页面布局，左侧播放器右侧是视频的信息，
// > 你现在做的这个很丑 **而且进来之后只有黑色，文字也反色的看不清**，体验太差了
//
// # 缺陷 ①：嵌入态没有背景 ⇒ 亮色主题下文字不可见
//
// Lead 实测（`.probe/ROOTCAUSE-merge-black.md`）：
// ```text
// 详情区标题文字最亮像素 = #1E2028  (= LightTokens.textPrimary)
// 该文字背后的背景       = #000000
// ⇒ WCAG 对比度 = 1.29 : 1     ← 几乎完全不可见
// ```
// 根因（两条，缺一不可）：
// ```text
// (a) media_page.dart 窗口态曾硬编码 Colors.black     ← T1 负责
// (b) detail_page.dart L943 `if (embedded) return content;`
//     ⇒ 返回**裸 Stack，没有背景**，底色完全依赖父级   ← ★ 本任务负责
// ```
// ⇒ 只修 (a) 是脆的：下次谁改了父级又复发。**两边都修**才是结构性的。
//
// # 缺陷 ②：侧栏排版
//
// T1 把本页放进一个宽 **340–440px** 的右栏（`SizedBox(width: detailW)`）。
//
// ★★★ 这里有一个**关键事实必须先验证**（本文件第 ① 组就是在验证它）：
// ```text
// `SizedBox(width:)` **不会**重新界定 MediaQuery！
// ⇒ `MediaQuery.of(context).size.width` 在侧栏里拿到的仍是**窗口宽度**
// ⇒ 任务描述里假设的"侧栏里 isNarrow 恒为 true"**可能不成立**
// ```
// 这一点决定了排版该怎么做 —— 所以**先测，再改**（不许按假设动手）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/detail_page.dart';

// ═══════════════════════════════════════════════════════════════════════
//  宿主：复刻生产环境的两步主题构造
// ═══════════════════════════════════════════════════════════════════════

/// 把 [child] 放进一个指定宽度的盒子里（复刻 T1 的 `SizedBox(width: detailW)`）
///
/// ★ 关键：**故意不**包 `MediaQuery` —— 因为要验证的就是
///   "生产代码（T1）也没有包" 这个事实下会发生什么。
Widget hostInSidebar({
  required double sidebarWidth,
  required double windowWidth,
  required Widget child,
  Brightness brightness = Brightness.light,
}) {
  final theme = brightness == Brightness.light
      ? FTheme.neutral.light.desktop
      : FTheme.neutral.dark.desktop;
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: MediaQuery(
      // 模拟"窗口宽 1280"
      data: MediaQueryData(size: Size(windowWidth, 800)),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Scaffold(
          body: Row(
            children: [
              const Expanded(child: ColoredBox(color: Colors.black)),
              // ★ 与 media_page.dart L604 逐字同构：SizedBox 定宽，不重新界定 MQ
              SizedBox(width: sidebarWidth, child: child),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 剥掉 `//` 行注释与 `/* */` 块注释，**保留字符串字面量**
///
/// ⚠️ 保留字符串是必须的：断言的目标（`'LayoutBuilder'`、`tooltip: '返回'`）
///    有些就在字符串里，剥掉会让断言看不见它们。
///
/// ★ 为什么需要它：本文件 ④ 组的静态断言会命中**我自己写的证据链注释**
///   （我在源码注释里刻意引用了旧写法来解释为什么改）⇒ 假失败。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (n.isNotEmpty) {
          out.write(n);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && n == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && n == '*') {
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 先验证前提：侧栏里 isNarrow 到底是 true 还是 false
  // ═══════════════════════════════════════════════════════════════════

  group('① 前提验证：SizedBox 不重新界定 MediaQuery', () {
    testWidgets('★★★ 侧栏 384px 内，MediaQuery 读到的仍是**窗口**宽度',
        (t) async {
      /*
       * ★ 这条决定排版怎么做，所以必须先测。
       *
       * 任务描述假设："侧栏里 `isNarrow` 恒为 true ⇒ 走 Column"。
       * 但 `detail_page.dart` 用的是 `MediaQuery.of(context).size.width`，
       * 而 T1 用的是 `SizedBox(width:)` —— **不重新界定 MediaQuery**。
       *
       * ⇒ 若本条实测 `mq.width == 1280`，则 `isNarrow == false`
       *   ⇒ 侧栏里走的是 **Row(封面 212 + 信息)**，
       *     而 384px 宽的栏里放 212 封面 + 24 间距 = 只剩 148px 给信息
       *   ⇒ ★ 这才是"很丑"的真正形态（不是任务描述的 Column）
       */
      double? seen;
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(
        hostInSidebar(
          sidebarWidth: 384,
          windowWidth: 1280,
          child: Builder(
            builder: (ctx) {
              seen = MediaQuery.of(ctx).size.width;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      await t.pump();

      // ignore: avoid_print
      print('[T60] 侧栏宽 384 / 窗口宽 1280 ⇒ MediaQuery.width = $seen');

      expect(seen, 1280.0,
          reason: '★★★ 实测：`SizedBox` **不会**重新界定 MediaQuery ⇒ '
              '侧栏里 `isNarrow` 读到的是**窗口**宽度(1280)，'
              '⇒ isNarrow = (1280 < 760) = **false**。'
              '任务描述里"侧栏里恒为 true"的假设**不成立** —— '
              '排版必须按这个事实改。');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 缺陷 ①：嵌入态必须自绘主题底色
  // ═══════════════════════════════════════════════════════════════════

  group('② 嵌入态自绘主题底色（缺陷 ①）', () {
    /// 找出 widget 树里所有 `ColoredBox` 的颜色
    List<Color> coloredBoxColors(WidgetTester t) => t
        .widgetList<ColoredBox>(find.byType(ColoredBox))
        .map((w) => w.color)
        .toList();

    testWidgets('★★★ embedded 时必须有一个铺 colorScheme.surface 的底色节点',
        (t) async {
      await t.binding.setSurfaceSize(const Size(384, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));

      late Color surface;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              surface = Theme.of(ctx).colorScheme.surface;
              return const DetailPage(
                provider: 'cycani',
                id: 'probe',
                embedded: true,
              );
            },
          ),
        ),
      );
      await t.pump();

      final cols = coloredBoxColors(t);
      // ignore: avoid_print
      print('[T60] embedded ColoredBox colors = $cols ; surface = $surface');

      expect(cols, contains(surface),
          reason: '★★★ embedded 分支必须**自己**画主题底色 —— '
              '`ColoredBox(color: colors.surface)`。'
              '修之前它返回裸 Stack ⇒ 亮色主题下 #1E2028 落在父级的 '
              '#000000 上 ⇒ WCAG 1.29:1（Owner：「文字也反色的看不清」）');
    });

    testWidgets('★★ embedded 时**不出现** Scaffold（外壳由父级负责）', (t) async {
      await t.binding.setSurfaceSize(const Size(384, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(
        const MaterialApp(
          home: DetailPage(provider: 'cycani', id: 'probe', embedded: true),
        ),
      );
      await t.pump();

      /*
       * ⚠️ 实测：`MaterialApp` 自己**不**产生 `Scaffold`
       *    （我第一版以为它有一层，期望 2，实测 0/1 ⇒ 已按实测改正）。
       * ```text
       * embedded     → Scaffold 层数 = 0   ← 本页没画（正确）
       * 非 embedded  → Scaffold 层数 = 1   ← 本页画了（见阳性对照）
       * ```
       */
      final scaffolds = find.byType(Scaffold).evaluate().length;
      // ignore: avoid_print
      print('[T60] embedded Scaffold 层数 = $scaffolds（期望 0）');

      expect(scaffolds, 0,
          reason: '★ embedded 时不许自己画 Scaffold —— '
              '外层 MediaPage 已提供页面骨架，再套一层会多一层 Material + '
              'SafeArea 把"下半屏"当整屏算内边距');
    });

    testWidgets('★★ embedded 时**不出现**返回按钮（返回语义由父级负责）',
        (t) async {
      await t.binding.setSurfaceSize(const Size(384, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(
        const MaterialApp(
          home: DetailPage(provider: 'cycani', id: 'probe', embedded: true),
        ),
      );
      await t.pump();

      /*
       * ⚠️ 这条在测试里**必然通过**，但原因是"返回按钮压根不在这条分支上"，
       *    而不是"守卫生效"（`_detail == null` ⇒ `_buildBody` 不跑）。
       *    ⇒ 它**单独不足以**证明守卫存在 —— 所以 ④ 组另有一条静态断言
       *      `if (!widget.embedded)` 钉住那个守卫。这里保留它作为**联合**证据。
       */
      expect(find.byTooltip('返回'), findsNothing,
          reason: '★ 合并页里不该有返回按钮（语义由 MediaPage 顶层负责）');
    });

    testWidgets('★★ 阳性对照：非 embedded 时**自己画了** Scaffold', (t) async {
      /*
       * ★ 铁律①：先证明仪器能测出反面。
       *
       * 上面那条是"embedded 时 Scaffold 层数 = 0"。若 `find.byType(Scaffold)`
       * 本身失效（比如树没挂上），它会**假通过**。所以用同一套 finder 在
       * **非 embedded** 下断言 Scaffold **必须存在** —— 证明 finder 看得见。
       *
       * ⚠️ 我第一版还断言了 `find.byTooltip('返回')` —— **那是错的**：
       *    返回按钮在 `_buildBody` 里，而 `_buildBody` 只在
       *    `_detail != null` 时才跑；测试里没有原生 DLL ⇒ `_detail` 恒 null
       *    ⇒ 返回按钮**永远不会渲染** ⇒ 那条断言必然失败。
       *    ★ 实测确认（`Found 0 widgets`）后按事实改正，而不是放宽它。
       */
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(
        const MaterialApp(
          home: DetailPage(provider: 'cycani', id: 'probe'),
        ),
      );
      await t.pump();

      final scaffolds = find.byType(Scaffold).evaluate().length;
      // ignore: avoid_print
      print('[T60] 非 embedded Scaffold 层数 = $scaffolds（期望 1）');

      expect(scaffolds, 1,
          reason: '★★ 阳性对照：非 embedded 时 DetailPage **自己**画了 Scaffold '
              '⇒ 总数 = 1（MaterialApp 不产生 Scaffold，实测已确认）。'
              '若这条不成立，说明 finder 看不见 Scaffold，'
              '那么上面"embedded 为 0"的结论也作废');
    });

    testWidgets('★ 静态断言：返回按钮**只在非 embedded 分支**里画', (t) async {
      /*
       * ★ 这条补上上面那条去掉的覆盖。
       *
       * `find.byTooltip` 在测试里拿不到返回按钮（`_detail == null` ⇒
       * `_buildBody` 不跑）⇒ 用**静态断言**证明它被 `!widget.embedded` 守卫。
       *
       * ★ 必须**剥注释**：源码注释里引用了这个写法来解释返回语义。
       */
      final code = stripComments(
        File('lib/ui/detail_page.dart').readAsStringSync(),
      );

      expect(code.contains("tooltip: '返回'"), isTrue,
          reason: '★ 返回按钮本身必须还在（非 embedded 时用）');
      expect(code.contains('if (!widget.embedded)'), isTrue,
          reason: '★★★ 返回按钮必须被 `!widget.embedded` 守卫 —— '
              '合并页的返回由 MediaPage 顶层统一处理，'
              '这里再画一个会让用户看到**两个返回入口**且语义不一致');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 缺陷 ②：侧栏宽度下的排版（不丑 + 不溢出）
  // ═══════════════════════════════════════════════════════════════════
  //
  // ⚠️⚠️ 这里必须先说清一个**测试环境的硬限制**（我第一版就栽在这）：
  //
  // ```text
  // DetailPage 的内容分支是：
  //   _loading ? 转圈 : _error != null ? 错误页 : _detail != null ? _buildBody : 空
  // 而 `_detail` 只能由 `SourinApi.getDetail()` 填上 —— 那要**原生 DLL**
  // （sourin_core.dll），在 `flutter test` 里**必然失败**
  //   ⇒ _error != null ⇒ 渲染的是 `_ErrorView`
  //   ⇒ ★ `_buildBody` / `_buildHeader` / `_Info` **根本不会执行**
  // ```
  // ⇒ 所以"在测试里挂真 DetailPage 然后量 `_Info` 的宽度"是**做不到的** ——
  //   不是写法问题，是这一层压根没跑（我第一版断言 `FilledButton('播放')`
  //   找不到，就是这个原因，不是布局坏了）。
  //
  // ⇒ 正确做法：**直接测 `_buildHeader` 的判据函数**（纯布局逻辑），
  //   外加一条"真 DetailPage 在侧栏宽度下不抛异常"的集成断言。

  group('③ 侧栏 340–440px：布局判据（直接测分档函数）', () {
    /*
     * 把 `_buildHeader` 的**分档判据**抽成一个可独立测的纯函数来验。
     *
     * ★ 这不是"测影子"：下面 [tierOf] 的实现与
     *   `detail_page.dart::_buildHeader` 里的阈值是**同一组**，
     *   而本文件另有一条**静态断言**钉住源码里就是这几个数
     *   （见 ④ 组）—— 两者一起保证"测的判据 == 生产的判据"。
     *
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-26 第二轮：阈值与**档位含义**都变了（Owner 新要求）
     * ══════════════════════════════════════════════════════════════════
     *
     * # Owner 原话
     *
     * > 右侧封面空白区域太多，重新设计一下……
     * > 其他倒没啥大问题了 主要就是优化一下右侧布局的合理性
     *
     * # 为什么这组测试的"期望"必须**掉头**（不是放宽）
     *
     * 旧设计：侧栏可用宽 < 420 ⇒ 紧凑档（封面在上、信息在下）。
     * Lead 逐像素量出后果：
     * ```text
     * 面板 409 − contentPadding 24×2 = 可用 **361**
     * 封面宽 112 ⇒ 右边空 **273px**（信息在**下面**，填不到右边）
     * ```
     * ⇒ ★ 那个 273px 是**白丢的** —— 而 361px 明明放得下并排。
     *
     * 新设计（阈值 300 起就并排）：
     * ```text
     * < 300     紧凑档：封面 112 在上（真手机竖屏，并排会挤成缝）
     * 300..420  ★ 窄档：封面 96  + 信息并排（361 落这里 ⇒ 消掉 273px 空洞）
     * 420..620  中档：封面 138 + 信息并排
     * >= 620    宽档：封面 212 + 信息并排   ← ★ 冻结契约，**一字未动**
     * ```
     *
     * ★ 断言的**强度没有降低**：
     * ```text
     * 旧：断言"361 必须走紧凑档"（一个档位名）
     * 新：断言"361 必须走窄档 **且封面 + 间距 + 信息的下限都放得下**"
     *     —— 后者更强（它同时排除了"并排了但信息被挤成缝"）
     * ```
     */
    const compactMax = 300.0; // < 300 ⇒ 紧凑档（封面在上）
    const mediumMin = 420.0; // 300..420 窄档 / 420..620 中档
    const wideMin = 620.0; // >= 620 ⇒ 宽档（封面 212 + 并排）

    String tierOf(double w) {
      if (w < compactMax) return 'compact';
      if (w < mediumMin) return 'narrow';
      if (w >= wideMin) return 'wide';
      return 'medium';
    }

    double coverWidthOf(double w) {
      if (w < compactMax) return 112;
      if (w < mediumMin) return 96;
      return w >= wideMin ? 212 : 138;
    }

    test('★★★ 侧栏 409（可用 361）⇒ 必须走**窄档并排**，消掉那 273px 空洞', () {
      /*
       * ★ 这是本轮 Owner 报的核心问题。
       *
       * 修之前：361 < 420 ⇒ 紧凑档 ⇒ 封面 112 在上、信息在下
       *         ⇒ 封面右边 **273px** 永久空着。
       */
      const sidebar = 409.0;
      const avail = sidebar - 48; // contentPadding 24×2
      final tier = tierOf(avail);
      final cover = coverWidthOf(avail);
      final infoW = avail - cover - 16; // 16 = Sp.x4 间距

      // ignore: avoid_print
      print('[T62] 侧栏 ${sidebar}px ⇒ 可用 ${avail}px ⇒ 档位=$tier '
          '封面=${cover}px 信息=${infoW}px');

      expect(tier, 'narrow',
          reason: '★★★ Owner 的侧栏（可用 ${avail}px）必须**并排** —— '
              '走紧凑档就会让封面右边空 273px（Owner 原话"空白区域太多"）');
      expect(cover, 96.0, reason: '★ 窄档封面必须是 96');
      expect(infoW, greaterThanOrEqualTo(240.0),
          reason: '★★ 信息区必须 ≥ 240px —— 否则"并排了但信息被挤成缝"，'
              '等于换了个方式难看（旧问题是右边空着，新问题会是标题放不下）');
    });

    test('★★★ 空洞判据：封面右边**不再**有 > 60px 的连续空白', () {
      /*
       * ★ 把 Owner 的定性抱怨（"空白区域太多"）变成**可量化的判据**。
       *
       * 旧设计下：封面右边 273px 空白（信息在下面，永远填不到右边）。
       * 新设计下：信息区紧跟封面右边 ⇒ 剩余空白 = 0（由 Expanded 吃掉）。
       *
       * ⚠️ 这里量的是"封面右边到信息区右边"的**空隙** ——
       *    并排布局下它就是那 16px 间距，远小于 60。
       */
      const sidebar = 409.0;
      const avail = sidebar - 48;
      final cover = coverWidthOf(avail);
      final tier = tierOf(avail);

      // 并排档：空隙 = 间距（16px）；紧凑档：空隙 = 整行宽（因为信息在下面）
      final gap = tier == 'compact' ? avail - cover : 16.0;

      // ignore: avoid_print
      print('[T62] 封面右边连续空白 = ${gap}px（档位=$tier）');

      expect(gap, lessThanOrEqualTo(60.0),
          reason: '★★★ Owner 报的"封面空白区域太多"必须被消除 —— '
              '旧设计这里是 **273px**（> 60）⇒ 这条断言在旧设计下会**红**');
    });

    test('★★ 阳性对照：**极窄**时仍必须走紧凑档（不能一路并排到底）', () {
      /*
       * ★ 铁律①：若 `tierOf` 恒返回 'narrow'，上面的断言会假通过。
       *   这条证明紧凑档**仍然可达**，且它存在的理由是**量化的**：
       * ```text
       * 真手机竖屏 360dp ⇒ 可用 360−48 = 312 ⇒ 窄档（并排）✓ 仍能用
       * 分屏 280dp      ⇒ 可用 232 < 300   ⇒ 紧凑档
       *   若这里并排：232 − 96 − 16 = 信息只剩 **120px** ⇒ 标题挤成缝 ⇒ 更糟
       * ```
       */
      expect(tierOf(232), 'compact',
          reason: '★★ 232px 可用宽必须走紧凑档 —— '
              '并排会让信息只剩 120px（比"上下堆叠"更难用）');
      expect(coverWidthOf(232), 112.0, reason: '★ 紧凑档封面必须是 112');
    });

    test('★★ 冻结契约：宽视口（>=760）判据**不变**', () {
      /*
       * 原判据：窗口 < 760 ⇒ 窄屏 Column；否则 Row(封面 212 + 并排)。
       * 新判据按**可用宽度**：窗口 760 ⇒ 可用 712 ≥ 620 ⇒ **宽档**（并排 212）。
       * ⇒ 两者在 >=760 上**一致** ⇒ 冻结契约满足。
       */
      for (final win in [760.0, 900.0, 1280.0, 1920.0]) {
        final avail = win - 48;
        final tier = tierOf(avail);
        // ignore: avoid_print
        print('[T62] 窗口 ${win}px ⇒ 可用 ${avail}px ⇒ 档位=$tier '
            '封面=${coverWidthOf(avail)}px');
        expect(tier, 'wide',
            reason: '★★ 窗口 ${win}px 必须走宽档（封面 212 + 信息并排）—— '
                '这是**改动前的行为**，冻结契约要求不变');
        expect(coverWidthOf(avail), 212.0,
            reason: '★★ 宽档封面必须仍是 212（改动前的值）');
      }
    });

    test('★ 阳性对照：判据**能区分**四档（不是恒返回同一个值）', () {
      /*
       * ★ 铁律①：若判据恒返回同一个值，上面几条里会有假通过。
       *   这条证明四档都真的可达。
       */
      expect(tierOf(232), 'compact');
      expect(tierOf(292), 'compact');
      expect(tierOf(361), 'narrow');
      expect(tierOf(500), 'medium');
      expect(tierOf(1232), 'wide');
      expect(coverWidthOf(232), 112.0);
      expect(coverWidthOf(361), 96.0);
      expect(coverWidthOf(500), 138.0);
      expect(coverWidthOf(1232), 212.0);
    });
  });

  group('③b 集成：真 DetailPage 在侧栏宽度下不抛异常', () {
    for (final w in [340.0, 380.0, 440.0]) {
      testWidgets('★★★ [$w px] 挂真 DetailPage ⇒ takeException 必须为 null',
          (t) async {
        /*
         * ★ 这条测的是"**真的挂起来不炸**"，而不是"布局好看"。
         *
         * `flutter analyze` 抓不到 RenderFlex overflow ——
         * 它只在**布局时**发生。所以必须真的挂起来。
         *
         * ⚠️ 本用例**不**断言 `_Info` 的宽度：测试里 `_detail == null`
         *    （无原生 DLL）⇒ `_buildBody` 不会执行（见本组开头的说明）。
         *    但"页面在 340–440 宽下不抛异常"仍然是**真**的、有价值的断言
         *    （错误页 / 转圈 / Toast 那几层都在真约束下跑过了）。
         */
        await t.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => t.binding.setSurfaceSize(null));

        await t.pumpWidget(
          hostInSidebar(
            sidebarWidth: w,
            windowWidth: 1280,
            child: const DetailPage(
              provider: 'cycani',
              id: 'probe',
              embedded: true,
            ),
          ),
        );
        await t.pump();

        final ex = t.takeException();
        // ignore: avoid_print
        print('[T60] 侧栏 ${w}px 真 DetailPage ⇒ takeException = $ex');

        expect(ex, isNull,
            reason: '★★★ 侧栏 ${w}px 下不许有布局异常。实测 = $ex');
      });
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 静态断言：源码里的阈值必须与上面测的**是同一组**
  // ═══════════════════════════════════════════════════════════════════

  group('④ 静态审计：分档阈值与"不再用窗口宽度"', () {
    /*
     * ⚠️⚠️ **必须先剥注释** —— 我第一版直接 `readAsStringSync().contains()`
     * 于是**两条断言都假失败**（实测）：
     * ```text
     * 「不许出现 MediaQuery...size.width < 760」→ 命中我自己的**证据链注释**
     *   （我在 _buildHeader 的文档里**刻意引用了旧写法**来解释为什么改）
     * ```
     * ★ 本项目已踩过多次同类坑（"grep 命中注释导致假通过/假失败"）。
     *   这里的方向是**假失败** —— 同样有害：它会让人以为代码没改干净。
     */
    final src = stripComments(
      File('lib/ui/detail_page.dart').readAsStringSync(),
    );

    test('★★★ 必须用 LayoutBuilder 拿真实约束，不许再用 MediaQuery 判窄',
        () {
      expect(src.contains('LayoutBuilder'), isTrue,
          reason: '★★★ 分档必须基于**本区可用宽度**（LayoutBuilder）—— '
              '`SizedBox` 不重新界定 MediaQuery，用窗口宽度会得到错的档位');

      expect(src.contains('MediaQuery.of(context).size.width < 760'), isFalse,
          reason: '★★★ 旧的"窗口宽度 < 760"判据必须消失（**剥注释后**）—— '
              '它让 340px 侧栏里走宽档（封面 212）⇒ 信息只剩 56px ⇒ Owner：「很丑」');
    });

    test('★ 仪器自检：stripComments 真的剥掉了注释里的旧写法', () {
      final raw = File('lib/ui/detail_page.dart').readAsStringSync();
      final code = stripComments(raw);

      // 原始文本里**有**（我的文档注释刻意引用了它作为证据）……
      expect(raw.contains('MediaQuery.of(context).size.width < 760'), isTrue,
          reason: '★ 文档注释里保留了旧写法作为"历史证据"');
      // ……但剥掉注释后**没有**（那才是真代码）
      expect(code.contains('MediaQuery.of(context).size.width < 760'), isFalse,
          reason: '★★ 剥注释后不许有 —— 这条同时证明 stripComments 有效。'
              '★ 若这条失败，上面那条"判据必须消失"就是假通过');
    });

    test('★★ 阈值必须是 300 / 420 / 620（与 ③ 组测的同一组）', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-09-26 第二轮：紧凑档阈值 420 → **300**
       * ══════════════════════════════════════════════════════════════
       *
       * ★ 这条断言**不能删**，只能改数 —— 它是"测的判据 == 生产的判据"
       *   这条闭合链的**静态那一半**（另一半在 ③ 组的纯函数里）。
       *
       * ⚠️ 这里暴露了 ③ 组的一个**真实缺陷**（我改阈值时发现的）：
       *    ③ 组的 `tierOf` 是测试里**自己抄的一份**副本 ⇒
       *    我只改源码不改测试时，③ 组**照样绿**（假通过）。
       *    而 ④ 组这条静态断言**立刻变红** —— 它才是真正咬住源码的那一环。
       *    ⇒ ★ 两个数字必须一起改；只改一处就会有一半在说谎。
       *
       * ★ 新阈值 300 的取值理由（不是为了让测试过）：
       * ```text
       * 并排所需最小宽 = 封面 96 + 间距 16 + 信息下限 188 = 300
       * 而 Owner 侧栏可用宽 = 409 − 48 = 361 ≥ 300 ⇒ 并排 ✓
       * ⇒ 消掉封面右边那 **273px** 空洞
       * ```
       */
      expect(src.contains('w < kHeaderCompactMax'), isTrue,
          reason: '紧凑档阈值（常量名，见 detail_page.dart 顶部）');
      expect(src.contains('kHeaderCompactMax = 300'), isTrue,
          reason: '★★ 紧凑档阈值必须是 300 —— 旧值 420 会让 361px 侧栏走紧凑档 '
              '⇒ 封面右边空 273px（Owner 报的"空白区域太多"）');
      /*
       * ⚠️ 2026-09-27 第三轮：宽档不再是三目里的一个分支，而是**单独一条 Row**。
       *
       * 旧写法 `w >= 620 ? 212.0 : …` 已被拆掉 —— Owner 第二次投诉
       * 「还是有留白，看着不协调」的根因正是"封面 + 全部信息并排"这个结构。
       * ⇒ 现在阈值 620 出现在 `if (w < 620)` 的**早退**里（更直白）。
       */
      expect(src.contains('if (w < 620)'), isTrue,
          reason: '★★ 宽档阈值必须是 620 —— 窄/中档在它之前早退，'
              '剩下的就是宽档（封面 212 + 并排，冻结契约）');
      expect(src.contains('_Cover(detail: d, width: 212.0)'), isTrue,
          reason: '★★ 宽档封面 212（与 `if (w < 620)` 配对 —— 两者必须同时在）');
    });

    test('★★★ 封面宽度必须真的是 112 / 96 / 138 / 212（钉住四档的具体值）', () {
      /*
       * ★★★ 这条是 **red-proof 抓出来的缺口**（M4 一开始没被抓到）。
       *
       * 我原来的 ③ 组只断言了**档位名**（compact/medium/wide），
       * 而档位名来自**测试里自己的副本**（`tierOf`）。
       * ⇒ 若把源码里的 `w >= 620 ? 212.0 : 138.0` 改成 `w >= 2000 ? …`，
       *   档位名**不变**（仍是 wide）⇒ 测试照样绿 ⇒ **缺口**。
       *
       * ⇒ 必须直接断言**源码里的具体数值**，才能钉住"宽档封面就是 212"。
       *
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-09-27 第三轮：窄档的**结构**变了（Owner 第二次投诉）
       * ══════════════════════════════════════════════════════════════
       *
       * Owner：「还是有留白，可以好好优化一下吗？看着不协调」
       * 逐带实测发现**两条左基准线**：
       * ```text
       * 封面/徽章/选集  左起 926
       * 简介/按钮/续播  左起 1038   ← ★ 在封面右边那一列里
       * ```
       * ⇒ 窄档改成「封面 + **标题/徽章**并排，其余**通栏**」
       *   ⇒ 左基准线唯一（除封面那一行），按钮行 46% → 82%+
       *
       * ⚠️ 所以**旧的单行三目写法不再存在**（那正是造成两条基准线的结构）：
       * ```dart
       * // ✗ 旧：封面 + **全部**信息并排 ⇒ 简介/按钮/续播都被挤进右列
       * final coverW = w >= 620 ? 212.0 : (w >= 420 ? 138.0 : kCoverNarrow);
       * return Row([_Cover(coverW), gap, Expanded(child: info())]);
       * ```
       * ★ 新结构把「宽档」单独写成一条 `Row`（**与改动前逐字相同**），
       *   而窄档/中档走「并排 head + 通栏 rest」。
       *   ⇒ 断言必须跟着**结构**走，否则它会去守一个已经不存在的写法。
       */
      // ★ 宽档：封面 212 —— **冻结契约**，与改动前逐字相同
      expect(src.contains('_Cover(detail: d, width: 212.0)'), isTrue,
          reason: '★★★ 宽档（>= 620）封面必须是 212 —— 冻结契约，'
              '独立详情页/宽视口的既有观感不能变');
      // ★ 中档：封面 138
      expect(src.contains('w >= 420 ? 138.0 : kCoverNarrow'), isTrue,
          reason: '★★ 中档（420..620）封面必须是 138');
      // ★ 窄档：封面 96
      expect(src.contains('kCoverNarrow = 96'), isTrue,
          reason: '★★ 窄档封面必须是 96 —— 361px 可用宽下：'
              '96 + 16 + 249(信息) = 361 ✓');
      // ★ 紧凑档：封面 112
      expect(src.contains('_Cover(detail: d, width: 112)'), isTrue,
          reason: '★★ 紧凑档封面必须是 112（极窄屏上下堆叠时用）');
    });

    test('★★★ 窄档必须把「标题/徽章」与「其余」**分开摆**（Owner 第二次投诉）',
        () {
      /*
       * ★ Owner 原话：「还是有留白，可以好好优化一下吗？看着不协调」
       *
       * 上一轮修好了"封面右边 273px"，但**又冒出另一处**：
       * ```text
       * 封面/徽章/选集  左起 926     ← 面板内边距
       * 简介/按钮/续播  左起 1038    ← 封面 96 + 间距 16 之后
       * ⇒ ★ **两条左基准线** = "不协调"的直接来源
       * ```
       * 根因：`_Info` 的**全部**内容都在封面右边，而「选集」在它外面
       * （`_buildHeader` 与 `_buildBody` 不是同一个排版上下文）。
       *
       * ⇒ 修法：窄档只让「标题 + 徽章」跟着封面并排，其余**通栏**。
       *
       * ══════════════════════════════════════════════════════════════
       * ★★★ 这条断言的第一版**是空的**（red-proof 当场抓到）
       * ══════════════════════════════════════════════════════════════
       *
       * 我第一版写的是 `src.contains('_InfoPart.head')` —— 而那个字符串
       * **光靠枚举定义与 `full` 分支里的引用就满足了**
       * ⇒ 把窄档改回"封面 + 全部信息并排"（正是 Owner 投诉的结构）时
       *   **测试照样绿**（实测：M1 EXIT=0 +47 passed）。
       * ```text
       * ★ 这是"断言存在性"而不是"断言结构"的典型失败：
       *   符号还在 ⇒ 断言过 ⇒ 但它**用在哪**完全没被检查。
       * ```
       * ⇒ 必须**按结构断言**：
       * ```text
       * ① 窄档那段代码里（`if (w < 620)` 之后），`Row` 的 child 是
       *    `Expanded(child: info(part: _InfoPart.head))`   ← 只有 head 在 Row 里
       * ② `info(part: _InfoPart.rest)` 出现在 `Row` **之后**
       *    （= 通栏，与选集同基准线）
       * ```
       */
      final narrow = src.substring(
        src.indexOf('if (w < 620)'),
        src.indexOf('_Cover(detail: d, width: 212.0)'),
      );
      expect(narrow.isNotEmpty, isTrue,
          reason: '★ 找不到窄档分支（`if (w < 620)` 到宽档 `_Cover(212)` 之间）');

      // ① Row 里装的必须是 **head**（不是整个 info）
      expect(narrow.contains('Expanded(child: info(part: _InfoPart.head))'),
          isTrue,
          reason: '★★★ 窄档的 `Row` 里必须只放 `_InfoPart.head`（标题+徽章）—— '
              '若放的是整个 `info()`，简介/按钮/续播会被挤进封面右边那一列 '
              '⇒ 左基准线与选集不一致 ⇒ Owner 说的「不协调」复发');
      expect(narrow.contains('Expanded(child: info())'), isFalse,
          reason: '★★★ 旧的"整个 info 进 Row"写法不许回来（那正是两条基准线的来源）');

      // ② rest 必须在 Row **之后**（通栏）
      final iRow = narrow.indexOf('Row(');
      final iRest = narrow.indexOf('info(part: _InfoPart.rest)');
      expect(iRest, greaterThan(iRow),
          reason: '★★★ `_InfoPart.rest` 必须出现在 `Row` **之后** —— '
              '这样它才落在面板内边距上（与「选集」同一条左基准线）');
      expect(iRest, greaterThan(0), reason: '★★ 窄档必须渲染 rest');

      expect(src.contains('enum _InfoPart'), isTrue,
          reason: '★ 拆分必须是**一个组件按 part 渲染**（数据来源唯一），'
              '而不是两个独立组件（那样可能出现"两半用了不同数据"）');
      expect(src.contains('case _InfoPart.full:'), isTrue,
          reason: '★ `full` 分支必须存在 —— 宽档走它，保证"两半合起来与拆分前'
              '逐字等价"（冻结契约）');
    });

    test('★★★ embedded 分支必须自绘 colors.surface 底色', () {
      expect(
        src.contains('if (widget.embedded) {\n      return ColoredBox('
            'color: colors.surface, child: content);'),
        isTrue,
        reason: '★★★ 冻结契约 ①：embedded 必须**自己**画主题底色 —— '
            '不能依赖父级（否则下次谁改父级又复发，WCAG 1.29:1 重现）',
      );
      // 旧写法（裸 Stack，无底色）不许回来
      expect(src.contains('if (widget.embedded) return content;'), isFalse,
          reason: '★★★ 旧的"返回裸 Stack"写法不许回来 —— 那正是缺陷 ①');
    });
  });
}
