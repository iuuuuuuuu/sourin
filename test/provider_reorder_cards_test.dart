// ═══════════════════════════════════════════════════════════════════════
//  内容源：卡片式 + 三种排序方式（2026-09-25）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（两条需求）
//
// ```text
// 内容源做成卡片式的
// 内容源调整顺序也要支持可拖动排序,也可以支持调整顺序 卡片上的移动按钮
// 上一个下一个来排序,也可以通过遥控面板来排序
// ```
//
// # 这个文件锁住什么
//
// ```text
// ① 卡片式      —— 内容源区块**不再套外层大容器**（盒子套盒子是"不像卡片"的根因）
// ② 拖动排序    —— ReorderableListView + onReorder 的下标换算
// ③ 卡片按钮    —— ↑/↓ 直接在卡片上，不只在排序弹窗里
// ④ 排序落盘    —— 三种方式共用 `_persistOrder`（漏了就是"重启还原"）
// ⑤ 滚动不归零  —— 刷新时不得把整页换成转圈（用户报「往下滑会自动往上滚」）
// ⑥ 不破坏集成任务 M —— 无 Divider、面板左缩进与源名对齐
// ```
//
// ⚠️ 本文件与 `provider_layout_test.dart` 一样是**静态断言真实路径** ——
//    设置页需要真核心（FFI）才能构造，`flutter_test` 里跑不起来。
//    真实观感由真机截图覆盖（见 `.probe/cards-*.png`）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String src;

  setUpAll(() {
    src = File('lib/ui/settings_page.dart').readAsStringSync();
  });

  /// 取 `_ProviderCard` 类的正文（从 class 声明到下一个顶层 class）
  String cardBody() {
    final start = src.indexOf('class _ProviderCard');
    final end = src.indexOf('class _ProviderIcon');
    expect(start > 0 && end > start, isTrue, reason: '应能找到 _ProviderCard 段落');
    return src.substring(start, end);
  }

  /// 取**合并后**的「JS 插件」区块正文
  ///
  /// # ★★ 2026-09-25：切片锚点从 `title: '内容源'` 改到这里
  ///
  /// 本文件原先用 `src.indexOf("title: '内容源'")` 当切片起点。
  /// 合并任务（「我说的合并还有 js插件和内容源这两块内容合成一个」）
  /// **删掉了那个标题** —— 于是 4 条断言全部假红，报错是
  /// 「应能找到「内容源」区块」，看起来像功能坏了，其实
  /// **正是合并成功的证据**。
  ///
  /// ⚠️ 教训与 `provider_import_test.dart` 里那条一样：
  ///    断言锁死一个**已被需求删除**的字面量，会把"做对了"误报成
  ///    "坏了"。所以锚点必须跟着需求走，而不是反过来把需求改回去。
  ///
  /// # ★★★ 2026-09-25 第二次同样的坑（task-43：JS 插件移二级页）
  ///
  /// 用户：「js插件药放在二级页面」
  /// ⇒ 区块从 `build()` 的 children 里**搬进了 `_pluginsBlock()` 方法**
  ///   （见那里的注释：零字节搬动，二级页复用同一段代码）。
  ///
  /// 旧切片是：
  /// ```dart
  /// final start = src.indexOf("title: 'JS 插件'");   // ← 命中一级页入口行
  /// final end   = src.indexOf('_Block(', start);     // ← 命中「云盘同步」
  /// ```
  /// 现在**第一个** `title: 'JS 插件'` 是一级页的 `SettingsEntryRow`，
  /// 于是切出 205 字符的**入口行**，4 条断言又全部假红 ——
  /// 而 `boxed: false` / `ReorderableCardGrid` / `ValueKey` /
  /// `canMoveUp` 全都在新区块里、契约**一条没坏**。
  ///
  /// ⇒ 这次的修法与上次**同一条原则**：锚点从"第一个出现的标题"
  ///   改成**实际承载区块的那个方法**（`_pluginsBlock`），
  ///   而不是把需求改回去。
  ///
  /// ⚠️ 用方法名而不是"第 N 个 title"：后者会在下次插入入口行时再坏一次。
  String mergedBlock() {
    final start = src.indexOf('Widget _pluginsBlock(BuildContext context) {');
    expect(start > 0, isTrue,
        reason: '应能找到 `_pluginsBlock` 方法（JS 插件区块的宿主）—— '
            'task-43 把区块从 build() 抽进了这个方法');
    /*
     * 终点用 `_ProviderIcon` 的 class 声明：
     * `_pluginsBlock` 是 State 的最后一个方法之一，其后紧跟
     * 下一个顶层 class。用 class 边界比"下一个 _Block("稳 ——
     * 方法体内本来就有 `_Block(`，用它当终点会切在**开头**。
     */
    final end = src.indexOf('class _ProviderCard extends StatelessWidget', start);
    expect(end > start, isTrue,
        reason: '应能找到 `_pluginsBlock` 之后的下一个顶层 class（切片终点）');
    return src.substring(start, end);
  }

  /// 去掉注释后的源码（**只用于"不得出现"这类否定断言**）
  ///
  /// # 为什么需要它
  ///
  /// 本次修复在 `loadAll()` 上留了一段很长的文档注释，里面**引用了
  /// 修复前的旧代码**：
  /// ```dart
  /// /// // 本方法原先的第一行
  /// /// if (mounted) setState(() => _loading = true);   // ← 整页变转圈
  /// ```
  /// 如果直接对整份源码做 `contains('if (mounted) setState(...)')`，
  /// 会**命中注释里的那行**，于是"旧写法必须消失"这个断言永远失败 ——
  /// 而代码其实已经修好了。
  ///
  /// 这类"断言把文档当成代码"的误判必须在这里修掉，
  /// 而不是把那段有用的注释删掉（注释解释了根因，价值很高）。
  ///
  /// ⚠️ 只做**行首判断**（`//` / `*` / `/*` 开头的行算注释），
  ///    不做完整的词法分析 —— 够用且不会误伤字符串里的 `//`
  ///    （例如 URL `https://…` 不在行首）。
  String codeOnly() {
    final buf = StringBuffer();
    for (final line in src.split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) {
        continue; // 注释行（含 `///` 文档注释、`*` 续行、`/*` 块注释）
      }
      buf.writeln(line);
    }
    return buf.toString();
  }

  group('① 卡片式', () {
    test('★ 内容源区块关掉外层大容器（boxed: false）', () {
      /*
       * 用户说「内容源做成卡片式的」—— 但 `_ProviderCard` **早就**有
       * 圆角 + 边框 + 底色。真正让它"不像卡片"的是外面还套着
       * `_Block` 的 Container → **盒子套盒子**，读起来是
       * 「一个大列表里装了 26 行」而不是「26 张卡片」。
       */
      expect(
        src.contains('boxed: false'),
        isTrue,
        reason: '★ 内容源区块必须关掉外层容器 —— 否则还是"盒子套盒子"',
      );

      // 确认它出现在合并后的区块里，不是别的区块
      final block = mergedBlock();
      expect(
        block.contains('boxed: false'),
        isTrue,
        reason: '★ `boxed: false` 必须在「JS 插件」区块内',
      );
    });

    test('★ _Block.boxed 默认 true —— 其它区块一个像素都不变', () {
      /*
       * JS 插件 / 手势 / 遥控那些区块的内容**不是卡片列表**，
       * 它们需要外框来分组。默认值必须是 true，否则会误伤。
       *
       * ★ 2026-09-25 任务 ㉙：`_Block` 搬进 `widgets/settings_kit.dart`
       *   并公开为 `SettingsBlock`（二级页要复用它，私有类跨文件用不了）。
       *   项目铁律⑥：**断言跟着实际承担者走** ——
       *   所以这条改成在 `settings_kit.dart` 里查默认值。
       *
       * ⚠️ 断言的**实质不变**：默认必须是 boxed，否则其它区块的外框会消失。
       */
      final kit = File('lib/ui/widgets/settings_kit.dart').readAsStringSync();
      expect(
        kit.contains('this.boxed = true'),
        isTrue,
        reason: '★ 默认必须 boxed —— 否则其它区块的外框会一起消失',
      );
      // 顺带确认公开类名（二级页依赖它）
      expect(
        kit.contains('class SettingsBlock extends StatelessWidget'),
        isTrue,
        reason: '★ 区块外壳必须是公开的 `SettingsBlock` —— '
            '二级页（独立文件）要用它',
      );
    });

    test('★ 卡片间距仍在（26 张卡不能糊成一整块）', () {
      /*
       * 原版 `.cards { gap: var(--sp-3) }` = 12px。
       *
       * ★ 2026-09-25：间距的**承担者**从"每张卡自己加 bottom padding"
       *    改成了「网格的 `spacing` 参数」——
       *    因为换成了多列网格（`ReorderableCardGrid`），
       *    间距要**横向纵向都管**，不能再由卡片自己加下边距。
       *
       * 所以断言跟着实现走：**网格必须显式传间距**。
       * 这个不变量的实质是"卡片之间有空隙"，不是"哪一行代码写的"。
       */
      final block = mergedBlock();
      expect(
        block.contains('ReorderableCardGrid('),
        isTrue,
        reason: '合并后应该是网格（一行多个 —— 用户后来提的）',
      );
      // 网格的默认 spacing 就是 Sp.x3（原版的 12px），且调用方没有覆盖成 0
      expect(
        block.contains('spacing: 0') || block.contains('spacing: Sp.x0'),
        isFalse,
        reason: '★ 间距不得被覆盖成 0 —— 那样 26 张卡会糊成一整块',
      );
      final grid = File('lib/ui/widgets/reorderable_card_grid.dart')
          .readAsStringSync();
      expect(
        grid.contains('this.spacing = Sp.x3'),
        isTrue,
        reason: '★ 网格默认间距必须是 Sp.x3（原版 gap: 12px）',
      );
    });
  });

  group('② 拖动排序', () {
    test('★ 用可拖拽网格（从 ReorderableListView 换成网格）', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★ 为什么断言从 `ReorderableListView` 改成 `ReorderableCardGrid`
       * ══════════════════════════════════════════════════════════════
       *
       * 用户后来又提了一条：
       * > js插件还没改成一行多个的显示(根据宽度动态处理显示)
       *
       * `ReorderableListView` **只有单列**（构造函数里没有 `gridDelegate`），
       * 26 张卡竖排 26 行、一屏只看得到 4~5 个 —— 满足不了"一行多个"。
       * 所以换成了 `ReorderableCardGrid`：
       * ```text
       * 列数由可用宽度动态决定（1280 → 3 列 / 900 → 2 列 / 400 → 1 列）
       * 拖动 = Draggable(把手) + DragTarget(每格)
       * 落点格下标就是目标位（与 onReorderItem 语义一致，不再 -= 1）
       * ```
       *
       * ★ 断言**跟着"实际承担者"走**，不跟着类名走 ——
       *   否则实现换了、行为没变，测试却红了（假红）。
       *   本 group 真正要守的是「拖动能改变顺序」，分两层锁：
       * ```text
       * ① 用了可拖拽网格（调用方）
       * ② 网格内部真有 Draggable + DragTarget（机制）
       * ```
       */
      expect(src.contains('ReorderableCardGrid('), isTrue,
          reason: '★ 用户要求「可拖动排序」+「一行多个」→ 可拖拽网格');
      expect(src.contains('onReorder: _onReorderProviders'), isTrue,
          reason: '必须接上重排回调');
    });

    test('★★ 网格内部真的用 Draggable + DragTarget（不是静态布局）', () {
      /*
       * 只看调用方有没有 `ReorderableCardGrid(` 是**不够**的 ——
       * 那可能是个纯展示网格。必须去它内部确认拖动机制真的在。
       */
      final grid = File('lib/ui/widgets/reorderable_card_grid.dart')
          .readAsStringSync();
      expect(grid.contains('Draggable<int>('), isTrue,
          reason: '★ 把手必须是 Draggable —— 否则拖不动');
      expect(grid.contains('DragTarget<int>('), isTrue,
          reason: '★ 每个格子必须是 DragTarget —— 否则没有落点');
      expect(grid.contains('onAcceptWithDetails:'), isTrue,
          reason: '★ 落点必须回调 onReorder（否则拖了不生效）');
      /*
       * ★★ 为什么这里必须比 **itemIndex** 而不是格子下标（2026-09-25）
       *
       * 加了「拖动实时预览」之后，**被拖的那一项在松手前就已经被
       * `_previewOrder` 挪到别的格子里了**。此时若拿"格子下标"去比
       * "拖来的 id"，就会在**真正属于自己的那一格**上误判成"不是自己"
       * → 拖回原位时被当成合法落点 → 轻点把手仍会白写一次盘。
       *
       * 所以断言锁 `itemIndex`（条目下标）而不是 `index`（格子下标）——
       * 这不是"变量名过时"，**变量名的改变本身就是那次语义修正**。
       */
      expect(
        grid.contains('onWillAcceptWithDetails: (d) => d.data != itemIndex'),
        isTrue,
        reason: '★ 拖到自己身上要拒绝 —— 否则轻点把手就白写一次盘；'
            '且必须比【条目】下标（实时预览后格子下标已不可信）',
      );
      expect(
        grid.contains('onWillAcceptWithDetails: (d) => d.data != index'),
        isFalse,
        reason: '★ 反向锁：不得退回比【格子】下标的旧写法',
      );
      // 把手由网格造好传给卡片（版式知识在卡片里，见调用点注释）
      expect(grid.contains('dragHandle'), isTrue,
          reason: '★ 网格要把把手传给卡片（把手位置是卡片的版式知识）');
    });

    test('★ 内层不自己滚（否则滚轮被截走）', () {
      /*
       * 原先 `ReorderableListView` 是 `CustomScrollView`，
       * 嵌在页面 ListView 里必须 `shrinkWrap` + `NeverScrollableScrollPhysics`。
       *
       * 换成网格后它是个 `Column`（不是可滚动区域），那两个参数**不再需要**；
       * 但**"内层不自己滚"这个不变量仍必须成立** ——
       * 这一页的滚轮本来就敏感（`spatial_nav` 的 ensureVisible 坑），
       * 内层再截一层会让它彻底滚不动。
       *
       * ⚠️ 必须**剥掉注释**再查：那个文件的注释里大量引用了
       *    `ReorderableListView` / `ListView` 这些**词**
       *   （解释"为什么不用它们"）—— 直接 `contains` 会命中注释，
       *    变成永远失败的假红。
       */
      final grid = File('lib/ui/widgets/reorderable_card_grid.dart')
          .readAsStringSync();
      final gridCode = StringBuffer();
      for (final line in grid.split('\n')) {
        final t = line.trimLeft();
        if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) {
          continue;
        }
        gridCode.writeln(line);
      }
      expect(
        gridCode.toString().contains('NeverScrollableScrollPhysics') ||
            gridCode.toString().contains('SingleChildScrollView') ||
            gridCode.toString().contains('ListView'),
        isFalse,
        reason: '★ 网格不得内嵌可滚动区域 —— 会截走滚轮（滚动归外层页面）；'
            '（注释里提到这些词不算）',
      );
    });

    test('★ 每张卡有 ValueKey(id) —— 重排要靠它认条目', () {
      final block = mergedBlock();
      expect(
        block.contains('key: ValueKey(_providers[i].id)'),
        isTrue,
        reason: '★ 没有 Key 会把"移动"当成"整块重建"，拖动动画会跳',
      );
    });

    test('★★ newIndex 语义：落点格 = 目标位（不 -= 1）', () {
      /*
       * `ReorderableListView.onReorder` 要求调用方自己
       * `if (newIndex > oldIndex) newIndex -= 1`（它的 newIndex 是"移除前"）。
       * 而**网格版**（`Draggable`+`DragTarget`）的语义是
       * **落点格下标就是目标位** —— 与已废弃的 `onReorderItem` 一致。
       *
       * ⚠️ 若误加 `-= 1`，往下拖一格会变成"原地不动"。
       */
      final start = src.indexOf('Future<void> _onReorderProviders');
      expect(start > 0, isTrue, reason: '应能找到 _onReorderProviders');
      final body = src.substring(start, start + 1800);
      expect(
        body.contains('newIndex -= 1'),
        isFalse,
        reason: '★★ 网格的 newIndex 已是目标位 —— 再减一次会移动错误位置',
      );
      expect(
        body.contains('if (newIndex == oldIndex) return;'),
        isTrue,
        reason: '★ 原地放下不该白写一次盘',
      );
      expect(
        body.contains('if (oldIndex < 0 || oldIndex >= _providers.length) return;'),
        isTrue,
        reason: '★ 下标越界防护（遥控/程序调用可能绕过 UI 的置灰）',
      );
    });
  });

  group('③ 卡片上的移动按钮', () {
    test('★ 卡片上有 ↑/↓（不只是排序弹窗里有）', () {
      final body = cardBody();
      expect(body.contains('Icons.keyboard_arrow_up'), isTrue,
          reason: '★ 用户明确要「卡片上的移动按钮 上一个下一个」');
      expect(body.contains('Icons.keyboard_arrow_down'), isTrue,
          reason: '★ 下移按钮同样要在卡片上');
      expect(body.contains("tooltip: '上移一位'"), isTrue);
      expect(body.contains("tooltip: '下移一位'"), isTrue);
    });

    test('★ 边界置灰而不是隐藏（保证竖直对齐）', () {
      /*
       * 隐藏会让第一张卡比别的卡少两个按钮、整列按钮左右错开；
       * 置灰则所有卡的按钮竖直对齐，位置固定好点。
       * `onPressed: null` 是 Flutter 里"置灰"的标准做法。
       */
      final body = cardBody();
      expect(
        body.contains('onPressed: canMoveUp ? onMoveUp : null'),
        isTrue,
        reason: '★ 第一张卡的上移按钮要置灰，不是隐藏',
      );
      expect(
        body.contains('onPressed: canMoveDown ? onMoveDown : null'),
        isTrue,
        reason: '★ 最后一张卡的下移按钮要置灰，不是隐藏',
      );
    });

    test('★ 调用点正确传边界（第一张不能上移、最后一张不能下移）', () {
      final block = mergedBlock();
      expect(block.contains('canMoveUp: i > 0'), isTrue,
          reason: '★ 第一张（i=0）不能上移');
      expect(
        block.contains('canMoveDown: i < _providers.length - 1'),
        isTrue,
        reason: '★ 最后一张不能下移',
      );
    });
  });

  group('④ 排序落盘（核心验收：重启后顺序仍在）', () {
    test('★★ 三种排序方式共用同一个落盘出口', () {
      /*
       * 拖动 / 卡片按钮 都必须走 `_persistOrder` ——
       * 它内部调 `SourinApi.setProviderOrder`（后端会 `save_order` 落盘）。
       * 若某一条路径自己算顺序不落盘，表现就是"UI 动了但重启还原"。
       */
      expect(src.contains('Future<void> _persistOrder('), isTrue,
          reason: '★ 必须有一个统一的落盘出口');
      expect(
        src.contains('await SourinApi.setProviderOrder(ids)'),
        isTrue,
        reason: '★ 落盘出口必须调 setProviderOrder（后端 save_order）',
      );
      // 拖动和按钮都走它
      final dragStart = src.indexOf('Future<void> _onReorderProviders');
      final dragBody = src.substring(dragStart, dragStart + 1500);
      expect(dragBody.contains('await _persistOrder('), isTrue,
          reason: '★ 拖动排序必须落盘');
      final btnStart = src.indexOf('Future<void> _moveProviderBy');
      final btnBody = src.substring(btnStart, btnStart + 1500);
      expect(btnBody.contains('await _persistOrder('), isTrue,
          reason: '★ 卡片按钮排序必须落盘');
    });

    test('★ 落盘后刷新 UI + 通知首页', () {
      final start = src.indexOf('Future<void> _persistOrder(');
      final body = src.substring(start, start + 1200);
      expect(body.contains('await loadAll()'), isTrue,
          reason: '不刷新 UI，用户会以为没生效再点一次');
      expect(body.contains('widget.onProvidersChanged?.call()'), isTrue,
          reason: '不通知首页，首页/搜索页的顺序还是旧的');
    });

    test('★ 用返回值刷新，不是自己算的顺序', () {
      // 后端 `registry.reorder()` 会剔除不存在的 id、补上缺失的 id
      final start = src.indexOf('Future<void> _persistOrder(');
      final body = src.substring(start, start + 1200);
      expect(body.contains('final applied = await SourinApi.setProviderOrder(ids)'),
          isTrue,
          reason: '★ 必须用后端返回的 applied（真实生效顺序）');
    });

    test('★ 按钮排序的边界与原排序弹窗一致（静默不动）', () {
      final start = src.indexOf('Future<void> _moveProviderBy');
      final body = src.substring(start, start + 1500);
      expect(body.contains('if (j < 0 || j >= ids.length) return;'), isTrue,
          reason: '★ 第一项再上移/最后一项再下移要静默不动（不报错）');
    });
  });

  group('⑤ 刷新不把整页变转圈（滚动位置不再归零）', () {
    test('★★ loadAll 只在首次显示整页转圈', () {
      /*
       * 用户报「设置页往下滑会自动往上滚」。
       * 真根因：`loadAll()` 开头 `setState(() => _loading = true)`
       * → build() 里 `if (_loading) return Center(CircularProgressIndicator())`
       * → **ListView 被整个替换** → 重建时滚动位置从 0 开始。
       *
       * 而 `loadAll()` 在 12 处被调用（每个源操作后都会刷新）——
       * 所以「滚到中间 → 点任意开关 → 跳回顶部」。
       *
       * ★★★ 2026-09-25 更新：判据从 `_providers.isEmpty` 改成 `_firstLoadDone`
       *
       * 原来那版判据（`_providers.isEmpty`）只是"首次加载"的**代理**，两者不等价：
       * ```text
       * _providers.isEmpty == true 有两种可能：
       *   ① 真的还没加载过            ← 该转圈
       *   ② 加载过，但这次结果为空     ← ★ 不该转圈（会销毁 ListView → 滚动归零）
       * ```
       * ② 是真实可达的（核心重启 / 插件重载 / `listProviders()` 瞬时失败），
       * 所以旧判据**仍然会**让「往下滑自动往上滚」复现。
       *
       * 实测证据：`.probe/probe_tests/zz_probe_t3_scroll_guard_test.dart`
       * 与 `test/settings_scroll_guard_test.dart`（组 A 阳性对照 / 组 B 漏洞 / 组 C 修法）。
       */
      expect(
        src.contains('if (mounted && !_firstLoadDone) setState(() => _loading = true);'),
        isTrue,
        reason: '★ 刷新时不能把整页换成转圈 —— 那会销毁 ListView、滚动归零。'
            '判据必须是显式的「首次加载完成」标志，'
            '不能是 `_providers.isEmpty` 这个代理（加载过但结果为空时会误判）',
      );
      /*
       * ⚠️ 这条必须用 `codeOnly()`（去注释后的源码）——
       *    上面那段修复说明的文档注释里**引用了旧代码**，
       *    直接查整份源码会命中注释、永远失败。
       */
      expect(
        codeOnly().contains('if (mounted) setState(() => _loading = true);'),
        isFalse,
        reason: '★ 旧的"每次都转圈"写法必须消失（注释里的引用不算）',
      );
      // ★ 代理判据必须从转圈条件里消失（它区分不了"没加载过"和"加载过但为空"）
      expect(
        codeOnly()
            .contains('if (mounted && _providers.isEmpty) setState(() => _loading = true);'),
        isFalse,
        reason: '★ 代理判据不得再用于转圈条件 —— 否则「加载过但列表为空」时'
            '每次刷新都会销毁 ListView、滚动归零',
      );
    });
  });

  group('⑥ 不破坏集成任务 M（配置/登录合并到源信息）', () {
    test('★★ 卡片内不得出现 Divider（用户要求"合并到一起"）', () {
      /*
       * 用户原话：「内容源的配置和登录等,合并到一起上面」。
       * 做法就是**删掉分隔线** + 面板左缩进与源名对齐。
       * 如果这次改卡片样式时把 Divider 画回来，等于把那个需求推翻了。
       */
      expect(
        cardBody().contains('Divider('),
        isFalse,
        reason: '★ 卡片内不得有 Divider —— 那是"另一块"的视觉断点，'
            '用户明确要求合并',
      );
    });

    test('★★ _panels 左缩进 = 把手格 + 图标 + 间距（与源名逐像素对齐）', () {
      /*
       * 第一行：`[把手 _dragSlotW][图标 30][Sp.x3][正文…]`
       * 面板缩进必须等于 `_dragSlotW + 30 + Sp.x3`。
       *
       * ⚠️ 本次加了拖动把手，所以缩进**必须**跟着加 `_dragSlotW` ——
       *    否则面板会比源名少缩进 22px，对齐关系就断了。
       */
      expect(
        src.contains('left: _dragSlotW + 30 + Sp.x3'),
        isTrue,
        reason: '★ 面板缩进必须包含把手格 —— 否则与源名对不齐',
      );
      expect(
        src.contains('const double _dragSlotW = 22;'),
        isTrue,
        reason: '★ 把手宽度必须是常量，两处引用才不会 desync',
      );
    });

    test('★ 把手那一格恒定占位（对齐关系不随可拖性变化）', () {
      final body = cardBody();
      // SizedBox 无条件存在，只有 child 受 dragIndex 影响
      expect(
        body.contains('width: _dragSlotW,'),
        isTrue,
        reason: '★ 把手格必须恒定占位，否则缩进要跟着变、两处必然 desync',
      );
    });
  });
}
