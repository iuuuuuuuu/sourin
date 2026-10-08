// ═══════════════════════════════════════════════════════════════════════
//  片头片尾设置页：**「按钮 → 弹窗」而不是平铺**（task-13 ⑧）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
//
// > 片头片尾，我说了 **做成按钮，点击后弹窗显示配置的影片的片头片尾**，
// > 而不是平铺在上面
//
// # 为什么这个测试**不 pump 真实 SettingsPage**
//
// 真实 `SettingsPage` 起不来，两个原因（都实测过）：
// ```text
// ① 它要 `sourin_core.dll` —— flutter_test 里加载不到（除非手动改 PATH）
// ② 它挂载后会留一个 3 秒的 `Future.delayed`（`_flash` 的 toast），
//    flutter_test 收尾时必报 "A Timer is still pending"
//    —— 这是**它自身的既有问题**，与本任务改动无关
//    （对照探针 `zz_probe_settings_control_test.dart`：零交互也报）
// ```
// 所以这里用**源码静态断言**证明结构正确（和 `skip_marker_test.dart`
// 的做法一致 —— 那个文件 300+ 行都是这么测的），
// 布局/交互的真实验证放在 `.probe\probe_tests\` 的探针里。
//
// # 断言的是什么
//
// ```text
// ① 「片头片尾」区块里**不再** `for (...) _SkipMarkerRow(...)`（平铺）
// ② 有一个 OutlinedButton 指向 `_openSkipHistoryDialog`
// ③ `_openSkipHistoryDialog` 真的 `showDialog`
// ④ 弹窗里**列的是历史**（`_SkipMarkerRow` 在弹窗内，不在设置页区块内）
// ⑤ 每条历史都能「清除」（走 `onClear`）
// ```
//
// ═══════════════════════════════════════════════════════════════════════
// ★★★ 2026-09-25 任务 ㉙：这个区块**搬到了二级页** —— 断言跟着搬
// ═══════════════════════════════════════════════════════════════════════
//
// 用户拍板方案 A（拆 5 个低频块到二级页），「片头片尾」是其中之一：
// ```text
// 改前：settings_page.dart    _Block(title:'片头片尾', ...)
// 改后：settings/skip_page.dart  SettingsBlock(title:'片头片尾', ...)
//        （一级页只留一个 SettingsEntryRow 入口行）
// ```
//
// # ★ 为什么改的是**断言的位置**而不是"把代码搬回去"
//
// 项目铁律⑥：**断言跟着实际承担者走**。
// 锁死一个已被需求移动的字面位置，会把"按需求做对了"误报成"坏了"。
// 用户明确要求拆二级页 —— 所以区块**本来就该**不在 `settings_page.dart`
// 里了，断言必须跟着走。
//
// ⚠️ 但**断言的语义一条都没放松**（这是关键）：
// ```text
// 仍然是「区块里不得平铺历史行」
// 仍然是「必须有一个按钮 → showDialog」
// 仍然是「弹窗高度有界 + 走父级回调」
// ```
// 只是从"在 A 文件里找"改成"在 B 文件里找"。
//
// ═══════════════════════════════════════════════════════════════════════
// ★★★ 2026-09-26 task-52：**「按钮 → 弹窗」被用户要求删掉了** —— 断言反转
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（本次，逐字）
//
// > 设置页面的 片头片尾 二级页，**重叠了功能**，就还有一个 片头片尾的管理
//
// # 我实测到的重复（真机隔离实例 + 用户真实数据只读副本）
//
// ```text
// 进「设置 → 片头片尾」二级页，屏幕上**同时**有两套"管理片头片尾"：
//   ① 平铺的 3 行（标题 + 区间 + 每行「清除」）
//   ② 按钮「查看 / 管理片头片尾（3）」
// ⇒ 点 ② 弹出的弹窗里是**逐字相同的 3 行**
// 证据：.probe\t52_subpage.png（两套并存）
//       .probe\t52_dup_dialog.png（弹窗内容 == 背后的平铺行）
// ```
//
// # ★★★ 为什么这次**可以**反转断言，而不是"放宽"
//
// 铁律⑥ 说"断言跟着实际承担者走"，但它**不允许**把断言删掉了事。
// 区别在于：**需求本身反向了**，而且我能逐字引用用户的两条相反指令：
//
// ```text
// ① 2026-09-25 上旬 「做成按钮，点击后弹窗…而不是平铺在上面」
//                    ⇒ 当时断言"必须有按钮 + 弹窗" —— **正确**
// ② 2026-09-25 任务㉙ 「抽到第二级页了，可以平铺了…」
//                    ⇒ 加了平铺，但按钮被当"次要入口"**保留**了
// ③ 2026-09-26 本次 「**重叠了功能**，就还有一个 片头片尾的管理」
//                    ⇒ 用户点名①的遗留物是重复 ⇒ 删掉
// ```
//
// ⇒ 所以本文件不是"删掉守不住的断言"，而是**把断言掉头**：
// ```text
// 改前：区块里**必须**有 OutlinedButton + _openSkipHistoryDialog + 按钮文案
// 改后：整个文件里**不得**再有这三样（重复入口已删）
// 同时：平铺列表**必须**还在（那是用户②要的，不能连带删掉）
// ```
//
// ★ 新断言的力量**不弱于**旧断言：旧的是"必须存在"，新的是"必须不存在"。
//   任何一次回退（把按钮加回来）都会立刻变红。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 设置页（一级页）—— 现在只剩入口行
  late String src;

  /// ★ 片头片尾二级页 —— 区块本体搬到这里了
  late String page;

  setUpAll(() {
    src = File('lib/ui/settings_page.dart').readAsStringSync();
    page = File('lib/ui/settings/skip_page.dart').readAsStringSync();
  });

  /// `page` 里**剥掉注释**之后的源码
  ///
  /// ⚠️ 必须剥注释（铁律⑤）：task-52 的说明注释里**逐字**提到了
  ///    `查看 / 管理片头片尾`、`_SkipHistoryDialog`、`OutlinedButton`
  ///    （那是给未来的人看的历史记录）。不剥的话
  ///    "不得再出现"这条断言会被**注释**弄成假红。
  String stripped() {
    final out = StringBuffer();
    for (final line in page.split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) {
        continue;
      }
      out.writeln(line);
    }
    return out.toString();
  }

  /// `SettingsBlock(title: '片头片尾', ...)` 那个区块的源码
  ///
  /// 取法：从 `title: '片头片尾'` 往前找到 `SettingsBlock(`，再往后取到
  /// **`children: [` 的闭合 `],`** —— 只取这个区块自己的 children，
  /// 不越界到下一个区块（否则会把别的 `_SkipMarkerRow` 也算进来，
  /// 那条断言就恒假了 —— 我第一版正是这么错的）。
  ///
  /// ★ 2026-09-25 任务 ㉙：区块搬到 `settings/skip_page.dart` 了，
  ///   且类名从 `_Block` 变成公开的 `SettingsBlock`（跨文件必须公开）。
  ///   **切片逻辑一个字没改**，只换了数据源和锚点名。
  ///
  /// # ⚠️ 为什么用 `lastIndexOf` 而不是 `indexOf`（我第一版踩了铁律⑤）
  ///
  /// `skip_page.dart` 的**文件头注释**里就写着
  /// `原来这段是 settings_page.dart 里 title: '片头片尾' 那个 _Block` ——
  /// 于是 `page.indexOf("title: '片头片尾'")` 命中的是**注释里的那句**
  /// （文件第 7 行），接着 `lastIndexOf('SettingsBlock(', 7)` 当然找不到
  /// 真定义（在第 240 行）→ 返回 **-1** → 断言报
  /// `Expected: a value greater than <0>, Actual: <-1>`。
  ///
  /// 真正那个 `title: '片头片尾'` 在文件里是**最后一次**出现 ——
  /// 所以用 `lastIndexOf`，并额外断言"它后面确实跟着 `SettingsBlock(`"。
  ///
  /// ⚠️ **2026-09-26 task-44 ⑤：锚点去歧义（只改锚点，断言一条没动）**
  ///
  /// # 为什么会撞
  ///
  /// 本次改动的二级页新增了
  /// `SettingsSubPage(title: '片头片尾', ...)`（页面标题），
  /// 而 `_block()` 里也有一个 `SettingsBlock(title: '片头片尾', ...)`（区块标题）。
  /// 于是 `lastIndexOf("title: '片头片尾'")` 命中的变成了
  /// **页面标题那一处**（它在文件更后面）→
  /// `lastIndexOf('SettingsBlock(', at)` 往前找不到 → 返回 -1 →
  /// 报 `Expected: false, Actual: true`（切片切到了错误的区域）。
  ///
  /// # 怎么修的（★ 关键：**不改断言语义**）
  ///
  /// 改成"在**所有** `title: '片头片尾'` 里，挑**最近前驱容器是
  /// `SettingsBlock(`** 的那一个"。这正是这个函数**本来就想要**的锚点
  /// （它的名字就叫 `skipBlock`，要的是**区块**不是页面标题）。
  ///
  /// ★ 三条断言**在 task-52 掉头**（见文件头说明）：
  /// ```text
  /// 区块里不得出现 `_SkipMarkerRow`        ← 仍然守（平铺在区块**之外**）
  /// 整个文件**不得**再有 `OutlinedButton`   ← ★ 新增（重复入口已删）
  /// 整个文件**不得**再有 `_openSkipHistoryDialog` ← ★ 新增
  /// ```
  String skipBlock() {
    // 在**所有** `title: '片头片尾'` 里挑"最近前驱是 SettingsBlock("的那个
    var at = -1;
    var from = 0;
    while (true) {
      final i = page.indexOf("title: '片头片尾'", from);
      if (i < 0) break;
      final blk = page.lastIndexOf('SettingsBlock(', i);
      final sub = page.lastIndexOf('SettingsSubPage(', i);
      if (blk > sub) {
        at = i; // 这一处的容器是 SettingsBlock —— 就是它
      }
      from = i + 1;
    }
    expect(at, greaterThan(0), reason: '★ 必须有「片头片尾」区块');
    final start = page.lastIndexOf('SettingsBlock(', at);
    expect(start, greaterThan(0),
        reason: '★ 区块必须用 `SettingsBlock` 包着（搬来后是公开类）');
    // 双重确认：锚点不能落在注释里（注释行以 `//` 或 `*` 开头）
    final lineStart = page.lastIndexOf('\n', at) + 1;
    final line = page.substring(lineStart, page.indexOf('\n', at));
    expect(line.trimLeft().startsWith('//'), isFalse,
        reason: '★★ 锚点落进了注释行 —— 铁律⑤：grep 先剥注释');

    // 从 `children: [` 起做括号配对，找到这个区块的 children 结束
    final chAt = page.indexOf('children: [', at);
    expect(chAt, greaterThan(0), reason: '★ 区块必须有 children');
    var depth = 0;
    var i = page.indexOf('[', chAt);
    for (; i < page.length; i++) {
      final c = page[i];
      if (c == '[') depth++;
      if (c == ']') {
        depth--;
        if (depth == 0) break;
      }
    }
    return page.substring(start, i + 1);
  }

  group('★ task-52 ⑧ 片头片尾二级页：**只有一个管理入口**（平铺列表）', () {
    test('★★★ 整个文件里**不得**再有「查看 / 管理片头片尾」按钮（重复入口）', () {
      /*
       * ★ 剥注释后再查 —— task-52 的历史说明注释里逐字提到了那个按钮，
       *   不剥就会假红（铁律⑤）。
       */
      final code = stripped();
      expect(code.contains('查看 / 管理片头片尾'), isFalse,
          reason: '★★★ 用户原话「二级页，重叠了功能，就还有一个 片头片尾的管理」'
              '—— 那个按钮就是"还有一个"。它若回来，用户会再次看到两套'
              '一模一样的列表（实测截图 .probe\\t52_subpage.png）');
      expect(code.contains('_SkipHistoryDialog'), isFalse,
          reason: '★★★ 重复入口的弹窗本体必须一并删掉 —— '
              '只删按钮会留下一个没人调用的死类');
      expect(code.contains('_openSkipHistoryDialog'), isFalse,
          reason: '★★★ 打开那个弹窗的方法也必须删干净');
      expect(code.contains('OutlinedButton'), isFalse,
          reason: '★ 那个区块里唯一的 OutlinedButton 就是它');
    });

    test('★★★ 阳性对照：平铺列表**必须还在**（别把用户要的一起删了）', () {
      /*
       * ★★ 铁律②/149：上面那条"不得再有按钮"是**否定**断言 ——
       *    如果把整个文件删空，它也照样绿。所以必须同时证明
       *    "用户②要的平铺列表仍然在"，两条合起来才说明
       *    "删对了东西"而不是"删多了"。
       */
      final code = stripped();
      expect(code.contains('_SkipMarkerRow'), isTrue,
          reason: '★★ 阳性对照：平铺的每一行必须还在 —— '
              '用户②说的是"可以平铺了"，那是他明确要的');
      expect(code.contains('for (final m in rows)'), isTrue,
          reason: '★★ 阳性对照：必须真的**遍历渲染**（不是只留个类定义）');
      expect(code.contains('pinnedHeader'), isTrue,
          reason: '★★ 阳性对照：固定搜索框也必须在（同一批要求）');
      expect(code.contains('_query'), isTrue,
          reason: '★★ 阳性对照：搜索状态字段必须在');
    });

    test('★★ 空态仍给引导文案（不是点不动的空按钮）', () {
      final block = skipBlock();
      expect(block.contains('_skipMarkers.isEmpty'), isTrue,
          reason: '★ 要区分空态 —— 没设置过时给引导');
      expect(block.contains('还没有设置过片头片尾'), isTrue,
          reason: '★ 空态要告诉用户去哪设置');
    });

    test('★★ 区块**只剩**计数 + 引导（不再承载任何管理入口）', () {
      final block = skipBlock();
      // 区块里不得再有"能点进某个管理界面"的东西
      expect(block.contains('onPressed'), isFalse,
          reason: '★ 区块里不该再有任何按钮 —— 管理入口只有下面平铺的列表');
      expect(block.contains('_SkipMarkerRow'), isFalse,
          reason: '★ 平铺行在区块**之外**（`scrollBody`），'
              '区块里只放标题/计数/空态引导');
    });
  });

  group('★ task-52 ⑧ 历史弹窗：**已删除**（它的职责由平铺列表承担）', () {
    /*
     * ⚠️ 这个 group 原来叫「历史弹窗本身」，6 条断言守着
     *    `_SkipHistoryDialog`（宽度 460 / 高度 400 / 内部 ListView /
     *    自己维护 `_list` / 委托 `widget.onClear` / 空态文案）。
     *
     * ★ task-52 把那个类**整个删掉**了（用户说"重叠了功能"）——
     *   所以那 6 条断言的**主语已经不存在**。留着的唯一后果是：
     *   `dialogSrc()` 里的 `expect(at, greaterThan(0))` 直接失败，
     *   而失败原因与"用户能不能用"毫无关系。
     *
     * ★ 但那些**约束本身**仍然有效，只是换了承担者（平铺列表）：
     * ```text
     * 每行复用 `_SkipMarkerRow`     → 仍然（见 `_resultList`）
     * 清除委托 `_clearSkipMarker`   → 仍然（`onClear: ... _clearSkipMarker`）
     * 不直接调 `SourinApi.clear`    → 仍然（确认 + 重拉都在父级）
     * 空态有文案                    → 仍然（`没有匹配「…」的作品。`）
     * ```
     * ⇒ 按铁律⑥"断言跟着**实际承担者**走"，把它们改挂到平铺列表上，
     *   而**不是**删掉了事。
     */

    test('★★★ 平铺每一行仍复用 `_SkipMarkerRow`（换承担者，约束不变）', () {
      final code = stripped();
      expect(code.contains('_SkipMarkerRow('), isTrue,
          reason: '★ "哪个影片配了什么片头片尾"那两行字必须复用同一个控件');
      expect(code.contains('marker: m'), isTrue,
          reason: '★ 每一行渲染的是**真实那条**记录');
      // 区间必须显示出来（用户要的就是"看到自己设了哪些"）
      expect(code.contains('片头 \${_range('), isTrue,
          reason: '★ 行里必须显示片头区间');
      expect(code.contains('片尾 \${_range('), isTrue,
          reason: '★ 行里必须显示片尾区间');
    });

    test('★★★ 清除仍走父级 `_clearSkipMarker`（不在行内重写一套）', () {
      final code = stripped();
      /*
       * `_clearSkipMarker` 处理好三件容易漏的事：
       * ① 二次确认 ② 清除后重拉列表 ③ 刷新本页
       */
      expect(code.contains('_clearSkipMarker'), isTrue,
          reason: '★ 清除必须委托给 `_clearSkipMarker`（二次确认在里面）');
      expect(code.contains('SourinApi.clearSkipMarker'), isTrue,
          reason: '★ 真正调 API 的是 `_clearSkipMarker` 自己（父级），'
              '不是在行控件里 —— 这条钉住"唯一出口"');
      // 行控件里不得直接调 API（它只收 onClear 回调）
      final rowAt = page.indexOf('class _SkipMarkerRow extends StatelessWidget');
      expect(rowAt, greaterThan(0));
      final rowSrc = page.substring(rowAt);
      expect(rowSrc.contains('SourinApi.clearSkipMarker'), isFalse,
          reason: '★ 行控件**不得**直接调 API —— 那会绕过二次确认');
      expect(rowSrc.contains('onClear'), isTrue,
          reason: '★ 行控件通过 `onClear` 回调往上抛');
    });

    test('★ 空态有文案（清到最后一条不能白屏）', () {
      final code = stripped();
      expect(code.contains('没有匹配'), isTrue,
          reason: '★ 搜不到/清空后要给文案，不是一片空白');
    });
  });

  group('★ ⑬-B / ⑬-C 不许回退（守住已完成的成果）', () {
    late String dlg;

    setUpAll(() {
      dlg = File('lib/ui/widgets/skip_marker_dialog.dart').readAsStringSync();
    });

    test('★★★ 预览用 `Center` 包住（bug② 不居中 —— 不许回退）', () {
      expect(dlg.contains('child: Center('), isTrue,
          reason: '★ `Center` 必须在 `AspectRatio` 外面 —— 去掉就又不居中了');
      // 顺序：Center 在 AspectRatio 之前
      final c = dlg.indexOf('child: Center(');
      final a = dlg.indexOf('child: AspectRatio(');
      expect(c, greaterThan(0));
      expect(a, greaterThan(c),
          reason: '★ `Center` 必须在 `AspectRatio` **外面**（先出现）——'
              ' 反了的话画面会被压扁');
    });

    test('★★★ 弹窗尺寸自适应（不塌成竖条 —— 不许回退）', () {
      expect(dlg.contains('math.min(kDialogMaxW, availW)'), isTrue,
          reason: '★ 宽度必须跟窗口自适应，不是写死');
      expect(dlg.contains('math.min(kDialogMaxH, availH)'), isTrue,
          reason: '★ 高度同理');
      expect(dlg.contains('const double kDialogMaxW = 820'), isTrue,
          reason: '★★ 上限 820（2026-09-25 用户「中间的预览太小了」'
              '—— 从 720 放大到 820）');
      expect(dlg.contains('const double kDialogMaxH = 740'), isTrue,
          reason: '★★ 上限 740（配合宽度让预览能到 526x296）');
      expect(dlg.contains('insetPadding'), isTrue,
          reason: '★ 必须收紧 `insetPadding` —— `Dialog` 默认的 40*2 '
              '正是窄窗口塌成竖条的原因之一');
      expect(dlg.contains('260.0'), isTrue,
          reason: '★ 可用宽有下限 260（低于它就真的没意义了）');
    });

    test('★★★ 预览必须够大（2026-09-25 用户「中间的预览太小了」）', () {
      /*
       * 真机实测改前预览只有 277x156（`.probe\dlg\dlg-probe.txt`）——
       * 那个尺寸看不出画面内容，而"判断片头设到哪一秒"正是这个弹窗
       * 的唯一目的。所以上限调大 + 预览上限从 228 提到 400。
       */
      expect(dlg.contains('const double kPreviewMaxH = 400'), isTrue,
          reason: '★ 预览上限必须是 400（原来 228，改前实际只有 156）');
      expect(dlg.contains('const double kPreviewMinH = 96'), isTrue,
          reason: '★ 下限保留（窗口极矮时宁可滚动也不压成一条缝）');
    });

    test('★★★ 预览高度由**预算**算出（四行才都可见 —— 不许回退）', () {
      /*
       * 用户报的「进度条只显示片头设置的两个箭头没有显示片尾的」=
       * 只看到前 2 行。根因是高度预算不够，第 4 行被挤出视口。
       * 修法：预览高度 = clamp(弹窗高 - 中段外 - 中段内其余, min, max)。
       */
      expect(dlg.contains('double previewHeightFor(double boxH)'), isTrue,
          reason: '★ 预览高度必须**动态算** —— 写死就会把第 4 行挤出去');
      expect(dlg.contains('kChromeH'), isTrue, reason: '★ 要有中段外的开销常量');
      expect(dlg.contains('kMidRestH'), isTrue, reason: '★ 要有中段内的开销常量');
      expect(dlg.contains('_previewBox(colors, previewHeightFor(boxH))'), isTrue,
          reason: '★ 调用点必须真的把算出来的高度传进去');
    });

    test('★★ 四行 `_EdgeRow` 一个不少（片头两个 + 片尾两个）', () {
      for (final l in ['片头开始', '片头结束', '片尾开始', '片尾结束']) {
        expect(dlg.contains("label: '$l'"), isTrue,
            reason: '★ 「$l」那一行不能少 —— 用户要的是四个边界');
      }
    });

    test('★★ 每行用共享常量 `kRowH`，且行距仍落进高度预算', () {
      /*
       * ★ 2026-10-02 改：原来是 `dlg.contains('const double kRowH = 32')` ——
       *   那是**钉死数值**的语法层断言，task-66 D（用户「四行 +/− 加大」）
       *   把 32 提到 36 后它假红，而功能其实**变强了**。
       *
       * 现在改成**语义断言**：解析真实值，再判两件真正要守的事 ——
       *   ① 行距（`kRowH` + `_EdgeRow` 的 `Padding(bottom: Sp.x1)`）不超过 40px
       *      ⇒ 否则四行撑爆中段，第 4 行「片尾结束」被挤出滚动视口
       *      （用户 2026-09-24 报的「只看到片头设置的两个箭头」）
       *   ② `kRowH` 仍**大于** 32 ⇒ 用户要的「加大」不能被悄悄退回去
       * 这样无论将来把 32 调成 34/36/38，只要还在预算内、且确实加大了，就绿。
       */
      expect(dlg.contains('const stepSize = kRowH'), isTrue,
          reason: '★ 行高必须用共享常量 `kRowH`，不能各写一个数');

      final m = RegExp(r'const double kRowH = ([\d.]+);').firstMatch(dlg);
      expect(m, isNotNull,
          reason: '★ 解析不到 `kRowH` 的值 —— 那样下面的断言会**恒真**（假绿）');
      final rowH = double.parse(m!.group(1)!);
      const rowPad = 4.0; // `_EdgeRow` 的 `Padding(bottom: Sp.x1)`
      expect(rowH + rowPad, lessThanOrEqualTo(40.0),
          reason: '★★★ 行距 kRowH($rowH) + Sp.x1($rowPad) = ${rowH + rowPad}px '
              '超过 40 就会把第 4 行「片尾结束」挤出滚动视口');
      expect(rowH, greaterThan(32.0),
          reason: '★ task-66 D：用户要「四行 +/− 加大」，不能退回 32');
    });

    test('★★ 窄宽度下用 `LayoutBuilder` 量**真实可用宽**', () {
      /*
       * ⚠️ 用 `MediaQuery.sizeOf(context).width`（窗口宽）是错的 ——
       *    实测窗口 300 时每行只有 228，而完整形态要 292 →
       *    `RenderFlex overflowed by 14 pixels`。
       */
      expect(dlg.contains('return LayoutBuilder('), isTrue,
          reason: '★ 必须用 `LayoutBuilder` 拿这一行真正能用的宽');
      /*
       * ⚠️ 只检查 `_EdgeRow` **这个类内部**（到 `class _StepBtn` 为止）——
       *    取到文件末尾的话会把别处的 `MediaQuery.sizeOf(...).width`
       *    也算进来，断言恒假（我第一版就这么错的）。
       */
      final at = dlg.indexOf('class _EdgeRow extends StatelessWidget');
      final end = dlg.indexOf('class _StepBtn', at);
      expect(at, greaterThan(0));
      expect(end, greaterThan(at));
      final body = dlg.substring(at, end);
      expect(body.contains('MediaQuery.sizeOf(context).width'), isFalse,
          reason: '★ `_EdgeRow` 里**不得**用窗口宽判紧凑 —— 那是错的判据');
    });

    test('★ 按钮用外层 `SizedBox` 钉死尺寸（`constraints` 单给不够）', () {
      /*
       * 实测：只给 `IconButton.constraints` 时它**实际**宽度仍会超出
       * （Material 内部还会叠 visualDensity/tapTargetSize）——
       * 导致 `Row` 溢出 14px。只有父级 `SizedBox` 保证"预算 = 实际"。
       */
      expect(dlg.contains('tapTargetSize: MaterialTapTargetSize.shrinkWrap'),
          isTrue,
          reason: '★ 要关掉 48 的强制命中区扩展');
      expect(
        RegExp(r'SizedBox\(\s*width: stepSize,\s*height: stepSize,')
            .hasMatch(dlg),
        isTrue,
        reason: '★ 行内按钮要被 `SizedBox` 从外面钉死',
      );
    });

    // ═══════════════════════════════════════════════════════════════
    //  ★★★ 2026-09-25 用户：「这四个按钮，都是开始不能超过结束的，
    //       这个逻辑你没做」
    // ═══════════════════════════════════════════════════════════════

    test('★★★ 四个点各有**上下界**（`_boundFor`）', () {
      expect(dlg.contains('(int, int) _boundFor(SkipEdge e)'), isTrue,
          reason: '★ 必须有一个"算某点合法区间"的函数 —— '
              '这是"开始不能超过结束"的执行依据');

      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ 2026-10-02：判据从「switch 里四个 case」改成「**语义**」
       * ══════════════════════════════════════════════════════════════════
       *
       * # 为什么改
       * 原判据是 `body.contains('case SkipEdge.introStart:')` ——
       * 它守的是**语法形态**（"必须写成 switch + case"），
       * 而不是**语义**（"四个点都要有界"）。
       *
       * 我把 `_boundFor` 重构成**表驱动**（扫一遍所有邻居），
       * 那修的是两个**真漏洞**（`t463` 实测抓到的）：
       * ```text
       * ① introStart 的上界只看 introEnd ⇒ introEnd==null 时能冲到 total
       *    实测：拖 introStart 到 90% ⇒ [2648, null, 3, null]  ✗
       * ② 连锁：introEnd 的下界被 ① 顶到 2649 > outroStart(3)   ✗
       * ```
       * ⇒ 重构后 `switch` 没了，**旧判据假红** —— 而功能是**变强了**。
       *
       * ★ 教训：**断言要落在语义层，不是语法层**。
       *   否则"把实现改得更好"会被自己的守卫拦住，
       *   而拦住的理由与它声称要守的东西无关。
       *
       * # 新判据
       * ```text
       * ① 函数体里必须出现**四个端点**（表驱动下它们在 order 列表里）
       * ② 必须**真的算**上下界（`-1` / `+1` = 严格不等）
       * ```
       * ⚠️ 取 3000 字符 —— 表驱动版含两个 helper，比原来的 switch 长。
       */
      final at = dlg.indexOf('(int, int) _boundFor(SkipEdge e)');
      final body = dlg.substring(at, at + 3000);
      for (final e in [
        'SkipEdge.introStart',
        'SkipEdge.introEnd',
        'SkipEdge.outroStart',
        'SkipEdge.outroEnd',
      ]) {
        expect(body.contains(e), isTrue,
            reason: '★ `$e` 必须有明确的界 —— 漏一个它就能越界');
      }
      expect(body.contains('- 1'), isTrue,
          reason: '★ 上界必须是 `邻居 - 1` —— 严格 `起点 < 终点`'
              '（后端也这么校验，允许相等会在保存时被打回）');
      expect(body.contains('+ 1'), isTrue,
          reason: '★ 下界必须是 `邻居 + 1` —— 同上');
    });

    test('★★★ `−/+` 和拖拽都必须**夹**进合法区间（不能静默越界）', () {
      /*
       * 真机实测改前：能把「片头开始」点到 10、「片头结束」留在 5，
       * 值**真的越界存下来了**（摘要显示 `片头 00:10 - 00:05`）。
       * 这就是用户说的"这个逻辑你没做"。
       */
      expect(dlg.contains('void _applyEdge(int? want, SkipEdge e)'), isTrue,
          reason: '★ 必须有一个统一的"设值"入口去做 clamp');
      expect(dlg.contains('_clampTo(want, e)'), isTrue,
          reason: '★ `_applyEdge` 里必须真的 clamp');
      // 四行的 onChanged 都要走它（不能有一条漏掉）
      for (final e in [
        'SkipEdge.introStart',
        'SkipEdge.introEnd',
        'SkipEdge.outroStart',
        'SkipEdge.outroEnd',
      ]) {
        expect(dlg.contains('onChanged: (v) => _applyEdge(v, $e)'), isTrue,
            reason: '★★ 「$e」那行必须走 `_applyEdge` —— '
                '漏了它就能越界（用户报的就是这个）');
      }
      // 时间轴拖拽也走同一个出口
      expect(dlg.contains('onSeek: _previewSeek'), isTrue,
          reason: '时间轴拖拽保持原样（拖是"预览位置"，不是"设端点"）');
    });

    test('★★★ 到边界时 `−/+` **置灰**（不能只靠底部红字）', () {
      expect(dlg.contains('enabled: bound == null || (v ?? 0) > bound!.\$1'),
          isTrue,
          reason: '★ 「−」到下限要灰 —— 否则用户以为按钮坏了');
      expect(dlg.contains('enabled: bound == null || (v ?? 0) < bound!.\$2'),
          isTrue,
          reason: '★ 「+」到上限要灰 —— 这就是"开始不能超过结束"');
      expect(dlg.contains('final bool enabled;'), isTrue,
          reason: '★ `_StepBtn` 要支持置灰');
      expect(dlg.contains('onPressed: enabled ? onTap : null'), isTrue,
          reason: '★ 置灰要真的让按钮不可点');
    });

    test('★★★ 行内显示约束（`≤ 00:19`）—— 「不能静默」的就近体现', () {
      /*
       * 底部那行红字距离第 4 行 400px，用户视线不会过去。
       * 所以在**值右边**贴一条小字，说明这一点能设到哪。
       */
      expect(dlg.contains('String? hint;'), isTrue,
          reason: '★ 每行要算自己的约束提示');
      expect(dlg.contains("hint = '≤ \${_fmtSeconds(hi)}'"), isTrue,
          reason: '★ 只有上限时显示「≤ …」');
      expect(dlg.contains("hint = '≥ \${_fmtSeconds(lo)}'"), isTrue,
          reason: '★ 只有下限时显示「≥ …」');
      expect(dlg.contains('kHintW'), isTrue,
          reason: '★ 提示宽度必须是**常量**并计入 `fixedW` —— '
              '否则会把文字列挤出去（我第一版就溢出了）');

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-10-02 改判据：从**字面表达式**改成**语义性质**
       * ══════════════════════════════════════════════════════════════
       *
       * 原来这条断言写的是 `dlg.contains('(hint != null ? kHintW : 0.0)')`
       * —— 它 pin 的是 `fixedW` 里的**一个具体表达式**。
       *
       * 真机缺陷（task-96 取证）暴露了那个设计的错：提示**固定吃 56px**，
       * 四行标签被按比例压到 45px 而四个汉字要 56px ⇒ 渲染成 `片…`。
       * 修法必然要动那个表达式（提示改成"按实测需要、挤不下就让位"）。
       *
       * ⚠️ 这正是 lesson #562 的同一个坑：**断言写在了语法层，
       *    所以一次让功能变强的重构会把它判红。**
       *    ⇒ 改断言**要表达的语义性质**，而不是换个字面量继续 pin。
       *
       * 要守的性质（与实现细节无关）：
       * ```text
       * ① 提示的宽**进入**宽度预算（不能被忽略 —— 那会溢出）
       * ② 提示的宽是**可让位**的（挤不下时让给标签/读数，
       *    否则标签又被压成 `片…`，等于没修）
       * ③ 越界时仍有 toast 兜底（"不静默"没有因为让位而丢）
       * ```
       */
      expect(dlg.contains('hintNeed'), isTrue,
          reason: '★ 提示的宽必须**量出来**并参与预算（性质①）');

      // 性质②：提示的宽来自分配结果，不是写死的常量
      expect(
        RegExp(r'width:\s*math\.max\(hintW\s*-').hasMatch(dlg),
        isTrue,
        reason: '★ 提示的宽必须是**分配值** `hintW`（可让位）—— '
            '写死 `kHintW` 的话标签会被重新压成 `片…`（性质②）',
      );
      expect(dlg.contains('hintW = budget - twoNeed;'), isTrue,
          reason: '★ 标签+读数放得下时，提示拿剩余的全部（可被压到 0）—— '
              '这才是"让位"（性质②）');

      // 性质③：让位不等于静默 —— 越界仍要 toast
      expect(dlg.contains('_toast('), isTrue,
          reason: '★ 提示让位后，"不能超过谁"仍要靠 toast 说清（性质③）');
    });

    test('★ 夹到边界时给 toast（拖拽到头的反馈）', () {
      expect(dlg.contains('_toast('), isTrue);
      expect(dlg.contains('不能超过'), isTrue,
          reason: '★ 提示文案要说清"不能超过谁"');

      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ 2026-10-02：补两条 —— 文案曾经是**乱码**（probe 日志抓到的）
       * ══════════════════════════════════════════════════════════════════
       *
       * # 实测日志
       * ```text
       * [SKIPDLG] …：片头结束不能超过
       * Closure: (SkipEdge) => String from Function '_peerName@…':.(e)（下限 00:04）
       * ```
       * ① `$_peerName(e)` 漏了花括号 ⇒ Dart 只吃掉标识符
       *    ⇒ 把**函数对象**打进字符串，紧跟的 `(e)` 变成字面量。
       * ② 方向写死「不能超过」⇒ 撞**下界**时方向是反的，
       *    用户会去改**右边**那个点（改错了地方）。
       *
       * ⚠️ 行为层由 `test/t464_clamp_toast_test.dart` 守（真开弹窗、
       *    真点 `+`、真读 SnackBar 文案）。这里守**源码形态**：
       *    行为测试跑不到的路径（例如将来上界分支被启用）也不该退回乱码。
       */
      expect(dlg.contains('不能小于'), isTrue,
          reason: '★★★ 撞**下界**时方向词必须是「不能小于」—— '
              '两个方向词都要在，否则就是把方向写死了');
      // ★ 这个正则查的是"漏花括号的函数调用插值"：
      //   `$名字(` 是 bug；`${名字(...)}` 才对。
      //   （`dlg` 已剥注释，见本文件开头的铁律⑤）
      final bad = RegExp(r'\$_[A-Za-z][A-Za-z0-9_]*\s*\(').firstMatch(dlg);
      expect(bad, isNull,
          reason: '★★★ 不许出现 `\$_方法名(` 这种漏花括号的插值 —— '
              '它会把**函数对象**打进文案（实测出现过 '
              '`Closure: (SkipEdge) => String …`）。'
              '找到的是：${bad?.group(0)}');
    });
  });
}
