// ═══════════════════════════════════════════════════════════════════════
//  task-74 ③：「JS 插件」二级页加「直播源」tab（液态玻璃 + 吸顶）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（m04668）
//
// ```text
// js源配置页面加一个直播源,导入js插件,自动更新直播源,或者js插件变更 也自动更新,
// 然后在这个直播源 tab下进行控制,然后这个tab也使用液态玻璃 那个效果实现吧,
// 记住固定在上面,而不是随着整体下滑
// ```
//
// # 这个文件锁住什么
//
// ```text
// ① 换位纯函数 —— reorderLiveIds 只在【直播子序列】内换位，
//                 非直播源的相对顺序一个都不动
//                 ★ 这一组是**真跑生产代码**（static 方法可直接调），
//                   不是"源码里有没有这个字符串"
// ② 吸顶        —— SliverPersistentHeader(pinned: true) + minExtent == maxExtent
// ③ 液态玻璃    —— GlassContainer 恰好 1 块；不得用 BackdropFilter 冒充折射
// ④ 自动刷新    —— tab 内容订阅 host._dataRev（loadAll 的 finally 里自增）
// ⑤ 触控目标    —— tab 本体 ≥ 34px（DEVELOPMENT.md 坑 35）
// ```
//
// # ⚠️ 本文件**不验证**什么（如实说明，不假装覆盖）
//
// ```text
// · 玻璃的**真实折射观感** —— 需要 shader + LiquidGlassWidgets.wrap，
//   flutter_test 里构造不出真实渲染。`my_shelf_test.dart:13-15` 逐字记着
//   这条教训：硬测只会得到"测了我自己搭的壳"这种**假绿**。
//
// · tab 条**逐像素**的吸顶几何 —— 构造 SettingsPage 要真核心（FFI）：
//   build() 里 `SourinApi.version` → `DynamicLibrary.open('sourin_core.dll')`，
//   在 flutter_test 里整棵子树会被**静默换成 ErrorWidget**（真因只在 stderr）。
//   ⇒ ② 只能锁**结构不变量**（pinned: true / min == max / 不透明底），
//     真实吸顶由真机截图覆盖。
//
// · 「导入 js 插件后直播源自动出现」的**端到端**行为 —— 见 ④：
//   这里锁的是"两个 tab 订阅了同一个刷新信号"，不是"真跑了一次导入"。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/settings_page.dart';

void main() {
  late String src;

  setUpAll(() {
    src = File('lib/ui/settings_page.dart').readAsStringSync();
  });

  /// 剥注释（行首版，与 `provider_reorder_cards_test.dart:119-129` 同一判据）
  ///
  /// ⚠️ 必须与那个测试**用同一个剥法**：它的 `codeOnly()` 只剥**行首**
  ///    注释。若这里用状态机版（连行内注释一起剥），某条负断言可能在
  ///    我这儿是绿的、在它那儿是红的。
  String codeOnly(String s) {
    final buf = StringBuffer();
    for (final line in s.split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) {
        continue;
      }
      buf.writeln(line);
    }
    return buf.toString();
  }

  /// 取 `anchor` 起、到收尾大括号为止的片段
  ///
  /// ⚠️ 收尾标记必须区分**顶层类/枚举**（`\n}`）与**类内方法**（`\n  }`）——
  ///    若类内方法也用 `\n}`，切片会一路吃到**整个类的末尾**，
  ///    于是 `contains('ReorderableCardGrid(')` 这类断言会被
  ///    `_pluginsBlock` 里的同名串**误判为真**（假绿）。
  String blockOf(String s, String anchor, {String close = '\n}'}) {
    final a = s.indexOf(anchor);
    expect(a >= 0, isTrue, reason: '应能找到锚点：$anchor');
    final b = s.indexOf(close, a);
    expect(b > a, isTrue, reason: '应能找到 $anchor 的收尾大括号（$close）');
    return s.substring(a, b + close.length);
  }

  /// 非直播源 id 的子序列（保序）
  List<String> nonLive(List<String> all, List<String> live) =>
      all.where((id) => !live.contains(id)).toList();

  // ═════════════════════════════════════════════════════════════════════
  // ① 换位纯函数 —— 真跑生产代码
  // ═════════════════════════════════════════════════════════════════════
  //
  // # 为什么这一组是**真执行**而不是静态断言
  //
  // 「直播源」tab 只显示 `_providers` 的**子序列**，而既有的
  // `_onReorderProviders` / `_moveProviderBy` 收的是**全局下标**。
  // 把 tab 里的下标直接传进去会**移错人**：
  // ```text
  // 全 6 个源里 3 个直播（下标 1 / 3 / 5）：
  //   用户在第 1 张卡上点「下移」→ 传 (0, 1) 给全局路径
  //   → 它和**下标 1 的非直播源**交换
  //   → 直播 tab 里两张卡的顺序**一点没变**（看着像"按钮坏了"）
  // ```
  // 这个 bug 是**纯逻辑**的，不需要渲染就能验 —— 而 `reorderLiveIds`
  // 是 public static，所以这里直接调它，跑的是**发布出去的那份代码**。
  group('① 换位纯函数（真跑生产代码）', () {
    List<String>? reorder(
      List<String> all,
      List<String> live,
      int oldIndex,
      int newIndex,
    ) =>
        SettingsPageState.reorderLiveIds(
          allIds: all,
          liveIds: live,
          oldIndex: oldIndex,
          newIndex: newIndex,
        );

    // 交错夹具：直播源被非直播源**隔开**（这正是"下标错位"会暴露的形状）
    const all = ['a', 'L1', 'b', 'L2', 'c', 'L3'];
    const live = ['L1', 'L2', 'L3'];

    test('★ 往下拖两格：直播顺序变、非直播源一个都不动', () {
      final r = reorder(all, live, 0, 2);
      expect(r, isNotNull, reason: '合法换位不该返回 null');
      expect(
        r,
        orderedEquals(['a', 'b', 'L2', 'c', 'L3', 'L1']),
        reason: 'L1 要落到直播子序列的**末位**（L3 之后），'
            '而不是全局下标 2 那个位置',
      );
      // ★ 阳性对照：同一次读数里同时证明"变了"和"没变"
      expect(
        nonLive(r!, live),
        orderedEquals(['a', 'b', 'c']),
        reason: '★ 非直播源的相对顺序必须一个都不动 —— '
            '否则用户在「JS 插件」tab 里会看到顺序莫名其妙变了',
      );
    });

    test('★ 往上拖两格：插到锚点**之前**', () {
      final r = reorder(all, live, 2, 0);
      expect(r, orderedEquals(['a', 'L3', 'L1', 'b', 'L2', 'c']),
          reason: 'L3 要落到直播子序列的**首位**（L1 之前）');
      expect(nonLive(r!, live), orderedEquals(['a', 'b', 'c']));
    });

    test('★ 相邻换位（下移一格 / 上移一格）', () {
      // 下移一格：插到锚点**之后**
      expect(reorder(all, live, 0, 1),
          orderedEquals(['a', 'b', 'L2', 'L1', 'c', 'L3']));
      // 上移一格：插到锚点**之前**
      expect(reorder(all, live, 2, 1),
          orderedEquals(['a', 'L1', 'b', 'L3', 'L2', 'c']));
    });

    test('★ 越界 clamp：拖到末尾 / 拖到开头', () {
      const dense = ['L1', 'L2', 'L3'];
      expect(reorder(dense, dense, 0, 5), orderedEquals(['L2', 'L3', 'L1']),
          reason: 'newIndex 超界要 clamp 到末位');
      expect(reorder(dense, dense, 2, -3), orderedEquals(['L3', 'L1', 'L2']),
          reason: 'newIndex 为负要 clamp 到首位');
    });

    test('★★ 返回 null = 不落盘（原地放下 / 越界 / 找不到锚点）', () {
      /*
       * 返回 null 的语义是「无需改动」—— 调用方据此**跳过落盘**。
       * 若这里误返回一份"看起来一样"的列表，每次轻点都会白写一次盘
       * （与 `_onReorderProviders` 里 `if (newIndex == oldIndex) return;`
       *  同一个不变量）。
       */
      expect(reorder(all, live, 1, 1), isNull, reason: '原地放下不该白写盘');
      expect(reorder(all, live, -1, 1), isNull, reason: 'oldIndex 越界');
      expect(reorder(all, live, 3, 0), isNull, reason: 'oldIndex 超出子序列');
      // moved 不在全局列表里（数据不一致）⇒ 宁可不动，也不写出残缺顺序
      expect(reorder(['L2'], ['L1', 'L2'], 0, 1), isNull,
          reason: 'moved 不在 allIds 里时要放弃，不能返回残缺顺序');
      // anchor 不在全局列表里
      expect(reorder(['L1'], ['L1', 'L2'], 0, 1), isNull,
          reason: 'anchor 找不到时要放弃');
    });

    test('★★ 返回值恒为 allIds 的**排列**（不增不减、不改名）', () {
      /*
       * 落盘出口会把这份列表整个写给后端（`setProviderOrder`）。
       * 少一个 id ⇒ **那个源从 registry 里消失**；
       * 多一个 ⇒ 后端补一个不存在的 id。
       * 两种都是数据损坏，所以这条按"排列"来锁，不按具体顺序。
       */
      for (final (o, n) in const [(0, 1), (0, 2), (1, 0), (2, 0), (1, 2), (2, 1)]) {
        final r = reorder(all, live, o, n);
        expect(r, isNotNull, reason: '($o → $n) 应当是合法换位');
        expect(r!.length, all.length, reason: '($o → $n) 长度不得变');
        expect(r.toSet(), all.toSet(), reason: '($o → $n) 元素集合不得变');
        expect(
          r.where((id) => live.contains(id)).toList(),
          isNot(orderedEquals(const ['L1', 'L2', 'L3'])),
          reason: '★ 阳性对照：($o → $n) 必须**真的**改变了直播顺序 —— '
              '否则上面几条"没坏"是空的',
        );
      }
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  // ② 吸顶结构
  // ═════════════════════════════════════════════════════════════════════
  group('② tab 条吸顶（结构不变量）', () {
    test('★★ 走 scrollBody: 而不是 children:（children: 塞不进 pinned sliver）', () {
      /*
       * `settings_sub_page.dart` 有两条结构路径：
       * ```text
       * scrollBody == null → _scrollingBody → CustomScrollView + SliverList
       * scrollBody != null → _pinnedBody    → Column + Expanded(scrollBody)
       * ```
       * 走 `children:` 的话每个子件是 `CustomScrollView` 里**平级的一个
       * sliver** —— 没有任何缝能塞进 `SliverPersistentHeader`。
       * ⇒ 必须自己供给 `CustomScrollView`。
       */
      final i = src.indexOf('SettingsSubPage(');
      expect(i > 0, isTrue, reason: '应能找到 SettingsSubPage 调用点');
      final call = src.substring(i, i + 500);
      expect(call.contains('scrollBody: _tabScrollBody(context)'), isTrue,
          reason: '★ 必须走 scrollBody: —— children: 做不到吸顶');
      /*
       * ⚠️ 这条负断言必须查**剥注释后**的窗口 —— 调用点上方那段注释里
       *    逐字写着「从 `children:` 换成 `scrollBody:`」（记录为什么改），
       *    直接查原串会命中**我自己的注释** ⇒ 永远失败（假红）。
       */
      expect(codeOnly(call).contains('children:'), isFalse,
          reason: '★ 不得同时传 children:（那会走 _scrollingBody 那条路）');
    });

    test('★★ pinned: true 是「固定在上面」的全部来源', () {
      final body = blockOf(src, 'Widget _tabScrollBody(BuildContext context) {',
          close: '\n  }');
      expect(body.contains('CustomScrollView('), isTrue,
          reason: '自己供给可滚动体');
      expect(body.contains('SliverPersistentHeader('), isTrue);
      expect(body.contains('pinned: true'), isTrue,
          reason: '★ Owner 原话「记住固定在上面，而不是随着整体下滑」');
      expect(body.contains('slivers:'), isTrue);
      // tab 条必须在 slivers 列表里（不是塞在某个 sliver 内部）
      expect(
        body.indexOf('SliverPersistentHeader(') < body.indexOf('SliverToBoxAdapter('),
        isTrue,
        reason: 'tab 条要在内容**之前**（上面）',
      );
    });

    test('★★ minExtent == maxExtent —— 不缩水才叫"固定"', () {
      /*
       * `SliverPersistentHeader` 的 delegate 若 min < max，条会随滚动
       * **收缩**（那是"折叠标题栏"的用法）。Owner 要的是一条**恒定**的
       * tab 条，所以两个 extent 必须取同一个字段。
       */
      final d = blockOf(src, 'class _PluginsTabBarDelegate extends SliverPersistentHeaderDelegate {');
      expect(d.contains('double get minExtent => extent;'), isTrue,
          reason: '★ minExtent 必须就是 extent');
      expect(d.contains('double get maxExtent => extent;'), isTrue,
          reason: '★ maxExtent 必须就是 extent');
      // 反向锁：不得出现"缩水"写法
      expect(RegExp(r'get (min|max)Extent =>[^;]*[-+]\s*shrinkOffset').hasMatch(d),
          isFalse,
          reason: '★ 不得让 extent 随 shrinkOffset 变化 —— 那是折叠栏，不是固定条');
    });

    test('★★ 条必须有不透明底（玻璃是半透明的，挡不住滚过的文字）', () {
      final d = blockOf(src, 'class _PluginsTabBarDelegate extends SliverPersistentHeaderDelegate {');
      expect(d.contains('color: background'), isTrue,
          reason: '★ 内容会从条下面滚过，透明底会让两行文字叠在一起');
      // 传进来的必须是**不透明**的 surface，不是 background（forui 的
      // neutral.light.background 是纯白 #FFFFFF，白叠白等于没垫）
      expect(src.contains('background: colors.surface,'), isTrue,
          reason: '★ 垫的必须是不透明的 colors.surface');
      expect(codeOnly(src).contains('FTheme.colors.background'), isFalse,
          reason: '★ 不得用 FTheme.colors.background 当垫底（白叠白）');
    });

    test('★ 条的厚度把玻璃的 padding 也算进去（否则玻璃被裁）', () {
      /*
       * `_pluginsTabBarExtent` 若不包含 `GlassContainer` 的
       * `padding: Sp.x2`（上下各一份），玻璃的折射带会被切掉一条边。
       */
      final m = RegExp(r'const double _pluginsTabBarExtent = ([^;]+);')
          .firstMatch(src);
      expect(m, isNotNull, reason: '应能找到 _pluginsTabBarExtent 定义');
      final expr = m!.group(1)!;
      expect(expr.contains('_pluginsTabH'), isTrue,
          reason: '条高必须由 tab 本体高度推导');
      expect(expr.contains('Sp.x2 * 2'), isTrue,
          reason: '★ 必须含 GlassContainer 上下各一份 padding');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  // ③ 液态玻璃
  // ═════════════════════════════════════════════════════════════════════
  group('③ 液态玻璃（真折射，不是模糊冒充）', () {
    test('★ 用 GlassContainer，且全文件**恰好一块**', () {
      /*
       * `my_shelf_test.dart:45-52` 记着这个坑：给每个 tab 各套一块玻璃
       * 会变成"两个独立小胶囊"，与底栏那条大玻璃完全不像。
       * ⇒ 玻璃只在外层容器上，chip 自己是**透明**的。
       */
      expect(src.contains('GlassContainer('), isTrue,
          reason: '★ 液态玻璃 = liquid_glass_widgets 的 GlassContainer');
      expect(RegExp(r'GlassContainer\(').allMatches(src).length, 1,
          reason: '★ 全文件恰好一块玻璃 —— 每个 tab 各套一块就不像了');
      expect(src.contains('GlassQuality.standard'), isTrue);
      expect(src.contains('LiquidRoundedSuperellipse(borderRadius: 999)'), isTrue,
          reason: '照抄 theme_page.dart:66-80 的胶囊形状');
      expect(src.contains('padding: const EdgeInsets.all(Sp.x2)'), isTrue,
          reason: '★ padding 不能省（theme_page.dart:74 的实测结论）：'
              '药丸会盖住折射带，玻璃"看起来没生效"');
    });

    test('★★ 不得用 BackdropFilter 冒充折射', () {
      /*
       * `BackdropFilter` 只能**模糊**，不能折射（`lib/shell.dart:3959-3967`）。
       * 用它顶替会得到一个"毛玻璃"，与液态玻璃是两种东西。
       */
      expect(codeOnly(src).contains('BackdropFilter'), isFalse,
          reason: '★ 只能模糊、不能折射 —— 与液态玻璃是两种东西');
    });

    test('★ 药丸与文字取**同一个**调色板（深色主题下不能白字压白药丸）', () {
      /*
       * `follow_page.dart:1278-1340` 记着这个坑：药丸用一个色、文字却用
       * `colorScheme.onSurface` ⇒ 深色主题下白字压白药丸，**看不见**。
       */
      final bar = blockOf(src, 'class _PluginsTabBar extends StatelessWidget {');
      expect(bar.contains('colors.primary'), isTrue, reason: '药丸底色');
      expect(bar.contains('colors.onPrimary'), isTrue,
          reason: '★ 选中态文字必须用 onPrimary（与药丸同一调色板）');
    });

    test('★ 用 AnimatedPositioned 滑动（与 follow_page 的 _FollowTabs 同一做法）', () {
      final bar = blockOf(src, 'class _PluginsTabBar extends StatelessWidget {');
      expect(bar.contains('AnimatedPositioned('), isTrue);
      expect(bar.contains('current == _PluginsTab.plugins ? 0 : _pluginsTabWidth'),
          isTrue,
          reason: '落点必须是**算出来的**（Stack 宽度写死 ⇒ 不需要测量）');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  // ④ 自动刷新
  // ═════════════════════════════════════════════════════════════════════
  group('④ 自动刷新（导入 js 插件 → 直播源 tab 自己更新）', () {
    test('★★ 两个 tab 订阅同一个 _dataRev（不必另造通知机制）', () {
      /*
       * Owner：「导入js插件,自动更新直播源,或者js插件变更 也自动更新」。
       *
       * 本页是**另一条路由**，host 的 setState 不重建它。而每个操作都靠
       * host 方法 → `await loadAll()`（它的 `finally` 里 `_dataRev.value++`）
       * —— 不订阅的话用户按「编辑」「启用」后界面不变（像没反应）。
       *
       * ⇒ 「导入插件 → 直播源自动更新」是**白拿**的：导入 / 更新 / 回滚 /
       *   启停全都走 `loadAll()`。
       */
      final body = blockOf(src, 'Widget _tabScrollBody(BuildContext context) {',
          close: '\n  }');
      expect(body.contains('valueListenable: host._dataRev,'), isTrue,
          reason: '★ 订阅刷新信号 —— 这是"自动更新"的唯一机制');
      expect(body.contains('host._pluginsBlock(context)'), isTrue);
      expect(body.contains('host._liveTab(context)'), isTrue,
          reason: '★ 两个 tab 都要订阅（同一个 builder 里分支 ⇒ 天然一致）');
    });

    test('★ _dataRev 的自增点在 loadAll 的 finally（所有操作共用）', () {
      final i = src.indexOf('Future<void> loadAll(');
      expect(i > 0, isTrue, reason: '应能找到 loadAll');
      final body = src.substring(i, i + 6000);
      expect(body.contains('_dataRev.value++'), isTrue,
          reason: '★ 刷新信号必须在 loadAll 里自增 —— '
              '所有源操作都走 loadAll，于是直播源列表自动跟着更新');
      expect(body.contains('finally'), isTrue,
          reason: '★ 要在 finally 里自增：失败也要让界面回到真实状态');
    });

    test('★ 判据是**声明的能力位** capabilities.live，不是运行时探测', () {
      expect(src.contains('p.capabilities.live'), isTrue,
          reason: '★ 配置页不该依赖运行期状态（进设置页时可能还没探过）');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  // ⑤ 控制面 + 触控目标
  // ═════════════════════════════════════════════════════════════════════
  group('⑤ 直播源 tab 的控制面', () {
    test('★ tab 标签由枚举驱动（不手写两份 chip）', () {
      final e = blockOf(src, 'enum _PluginsTab {');
      expect(e.contains("plugins('JS 插件')"), isTrue);
      expect(e.contains("live('直播源')"), isTrue);
      // 恰好两个 tab
      expect(RegExp(r"^\s{2}\w+\('", multiLine: true).allMatches(e).length, 2,
          reason: '★ 恰好两个 tab');
      expect(src.contains('for (final t in _PluginsTab.values)'), isTrue,
          reason: '★ 枚举驱动 —— 手写两份 chip 会漏一个，'
              '而且滑动药丸的宽度算不出来');
    });

    test('★★ 复用既有动作，不新造第二套控制面', () {
      /*
       * 「在这个直播源 tab下进行控制」= 启停 / 编辑 / 配置 / 移除 / 更新
       * —— 这些 `_ProviderCard` 的既有回调**全都能用**，
       * 唯一的差别是排序要在直播子序列内换位（见 ①）。
       */
      final tab = blockOf(src, 'Widget _liveTab(BuildContext context) {',
          close: '\n  }');
      for (final call in const [
        'onToggle: () => _toggleProvider(',
        'onEdit: () => _editProvider(',
        'onConfig: _configOf(',
        'onRemove: _removeOf(',
      ]) {
        expect(tab.contains(call), isTrue, reason: '★ 必须复用：$call');
      }
      expect(tab.contains('ReorderableCardGrid('), isTrue,
          reason: '★ 拖动排序（与 JS 插件 tab 同一个网格）');
      expect(tab.contains('onReorder: _onReorderLive'), isTrue);
      expect(tab.contains('_moveLiveBy('), isTrue,
          reason: '★ 卡片上的 ↑↓ 走直播子序列内换位');
    });

    test('★ 空态说清"怎么才会有"（只说没有，用户不知道下一步）', () {
      final tab = blockOf(src, 'Widget _liveTab(BuildContext context) {',
          close: '\n  }');
      expect(tab.contains('还没有支持直播的源'), isTrue);
      expect(tab.contains('在「JS 插件」里导入插件后'), isTrue,
          reason: '★ 空态要把 Owner 那句"导入插件就会自动出现"讲给用户');
    });

    test('★★ tab 本体 ≥ 34px（DEVELOPMENT.md 坑 35：触控目标）', () {
      /*
       * `follow_page.dart:1362-1376` 记着实测：`Sp.x2*2(16) + 17(文字行高)
       * = 33` 差 1px 不合格，实测 `InkWell = 96 x 33 → under34 = true`。
       * ⇒ tab 本体高度必须显式 ≥ 34，不能靠 padding 凑。
       */
      final m = RegExp(r'const double _pluginsTabH = ([\d.]+);').firstMatch(src);
      expect(m, isNotNull, reason: '应能找到 _pluginsTabH 定义');
      final h = double.parse(m!.group(1)!);
      expect(h, greaterThanOrEqualTo(34.0),
          reason: '★ 触控目标不得小于 34px（实测 33 不合格）');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  // ⑥ 仪器自检（阳性对照 —— 证明上面的负断言不是空转）
  // ═════════════════════════════════════════════════════════════════════
  group('⑥ 仪器自检', () {
    test('★ codeOnly 真的剥得掉注释（否则负断言是空的）', () {
      expect(codeOnly('// BackdropFilter\n'), isNot(contains('BackdropFilter')),
          reason: '行首 // 必须剥掉');
      expect(codeOnly('  /// BackdropFilter\n'),
          isNot(contains('BackdropFilter')),
          reason: '文档注释也必须剥掉');
      expect(codeOnly('/* BackdropFilter */\n'),
          isNot(contains('BackdropFilter')));
      // ★ 阳性对照：真代码不得被剥掉
      expect(codeOnly('final x = BackdropFilter(\n'),
          contains('BackdropFilter'),
          reason: '★ 真代码必须留下 —— 否则"不存在"这条永远为真');
    });

    test('★ 查找仪器能找到确实存在的串（阳性对照）', () {
      final shelf = File('lib/ui/widgets/my_shelf.dart').readAsStringSync();
      expect(RegExp(r'GlassContainer\(').allMatches(shelf).length, 1,
          reason: '★ 阳性对照：同一个正则在一个**已知有玻璃**的文件里命中 1 次'
              '—— 证明上面"settings_page 恰好 1 处"不是仪器坏了');
      expect(RegExp(r'GlassContainer\(').allMatches(src).length, 1);
      // 阴性对照：乱码串命中 0
      expect(src.contains('__NO_SUCH_TOKEN_zzz__'), isFalse);
    });
  });
}
