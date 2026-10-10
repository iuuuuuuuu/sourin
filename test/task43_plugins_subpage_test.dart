// ═══════════════════════════════════════════════════════════════════════
//  task-43：设置页「JS 插件」二级页 —— 两个**必补的坑**的回归守卫
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话
// ```text
// js插件药放在二级页面,局域网遥控设置放在最上面
// ```
// （"药" = 要）
//
// # 这个文件守什么
//
// 二级页是 `Navigator.push` 上来的**另一条路由** —— 不在
// `SettingsPageState` 的子树里。这个事实导致**两个必须补的坑**：
//
// ```text
// ① 数据刷新（_dataRev）
//    host 的 `setState` **不会**重建二级页。
//    而每个卡片动作（编辑/停用/移除/安装/重载）都靠
//      host 的方法 → `await loadAll()`
//    ⇒ 二级页若不订阅 `_dataRev`，用户按下按钮后**界面不变**，
//      看起来像"点了没反应"。
//
// ② ★★ toast 可见性（_toastRev）
//    `_flash()` 把消息写进 host 的 `_toast`，而 host 的 toast 画在
//    **宿主自己的 Stack** 里 ⇒ 被整屏的路由**盖住**。
//    ★ 严重的是**失败类**消息（"安装失败：…"/"删除失败：…"/"保存失败：…"）——
//      **列表根本不变** ⇒ 用户**完全没有反馈** ⇒ 会重复点击（可能重复操作）。
// ```
//
// # ★ 为什么这两个坑"很容易被漏掉"
// ```text
// 它们都**不会**让 analyze 报错、不会让编译失败、也不会让
// "页面能打开"这件事失败 —— 页面看起来完全正常，
// 只有**真的按了按钮**才发现没反应。
// ⇒ 所以必须用断言把契约钉住，否则以后有人重构时会无声破坏。
// ```
//
// # ★★★ 为什么用**静态契约**（而不是 widget 测试）
//
// `SettingsPageState` 的宿主 `SettingsPage` 在 `flutter test` 里**挂不上**：
// ```text
// build() 里 L1912 的 `${SourinApi.version}` →
//   `SourinCore.version` → `_ensureBound()` →
//   `DynamicLibrary.open('sourin_core.dll')`
// ⇒ 测试环境没有那个 DLL ⇒ build() 抛异常 ⇒ 子树被换成 ErrorWidget
// 实测：element=1 / ErrorWidget=1 / 子树 Text=0
// ```
// ★ 这是**独立验证者（fix-autoscroll）实测确认**的结构墙，
//   不是我的推测 —— 见 `.probe/probe_tests/zz_v46b_layers_test.dart`。
//
// ⇒ 行为层（点进/返回跳转链、卡片动作改状态、toast 可见性）在
//   `flutter test` 里**测不到**；能守的是"**接线契约**"：
//   订阅关系是否还在。（真机截图另做 —— 见 `.probe/run-t43/*.png`）
//
// # 与独立验证者的关系
// ```text
// fix-autoscroll 写了静态契约探针（`.probe/probe_tests/zz_v46c_boundary_test.dart`）
// 并做了**红度证明 3/3**（改副本、不碰生产文件）。
// ★ 但那个探针在 `.probe/probe_tests/` 下 —— **`flutter test test/` 不会跑它**。
// ⇒ 本文件是把它**固化进常规测试套件**，让这两个契约有**永久**守卫。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去注释（行注释 + 块注释，**带状态机**）
///
/// # 为什么必须剥注释（本项目踩过至少 7 次）
/// 这个文件要断言 `_dataRev` / `_toastRev` 的**订阅关系**，
/// 而 `settings_page.dart` 里这两个名字**大量出现在注释中**
/// （例如 `_pluginsBlock` 的文档就写了"见 `_dataRev` 的说明"）。
/// 若不剥注释，**删掉真实订阅**后注释仍会被匹配到 ⇒ 断言**假绿**。
///
/// ★ 状态机（而不是逐行判断）是必须的 —— 逐行判断处理不了：
/// ```text
/// 行尾注释   final x = 1; // 提到 _dataRev      ← 行首不是注释
/// 单行块注释 /* _dataRev */ final y = 2;
/// 字符串     'ui/_dataRev.dart'                ← 里面的词不是代码
/// ```
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  String? quote;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    if (inBlock) {
      if (c == '*' && next == '/') {
        inBlock = false;
        i += 2;
        continue;
      }
      if (c == '\n') out.write(c);
      i++;
      continue;
    }

    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }

    if (quote != null) {
      out.write(c);
      if (c == r'\' && next.isNotEmpty) {
        out.write(next);
        i += 2;
        continue;
      }
      // 字符串里的标识符**要保留** —— 但我们要断言的是**代码**，
      // 所以这里也写出去；调用方用 `codeOnly` 时按需处理。
      if (c == quote) quote = null;
      i++;
      continue;
    }

    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }

    if (c == '/' && next == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlock = true;
      i += 2;
      continue;
    }

    out.write(c);
    i++;
  }
  return out.toString();
}

/// 取源码里某个**类/方法体**的正文（按大括号配对）
///
/// ⚠️ 用配对而不是"到下一个 class" —— 因为类体里本身可能嵌套
/// （`_PluginsPageState.build` 里有 `ValueListenableBuilder` 的闭包）。
String bodyOf(String code, String signature) {
  final start = code.indexOf(signature);
  expect(start >= 0, isTrue,
      reason: '★ 前置断言：必须能找到 `$signature`（找不到≠合规，见铁律 78）');
  var depth = 0;
  var started = false;
  for (var i = start; i < code.length; i++) {
    final ch = code[i];
    if (ch == '{') {
      depth++;
      started = true;
    } else if (ch == '}' && started) {
      depth--;
      if (depth == 0) return code.substring(start, i + 1);
    }
  }
  fail('★ `$signature` 的大括号不配对');
}

void main() {
  late String raw;
  late String code;

  setUpAll(() {
    /*
     * ★★★ 被测源码路径支持**环境变量覆盖**（`TASK43_SRC`）
     *
     * # 为什么需要这个开关（不是为了炫技）
     * 本文件有 11 条断言，要证明它们**不是空的**，唯一办法是
     * **故意破坏实现**看是否变红（红度证明）。
     *
     * 而 `lib/ui/settings_page.dart` **有并发写入者** ——
     * 直接改它做变异测试，等于在别人可能正在写的文件上注入错误。
     *
     * ⇒ 所以留这个开关：红度脚本把源码**复制**到 `.probe/`，
     *   在**副本**上注入变异，用 `TASK43_SRC=<副本>` 跑本文件。
     *   生产文件**一个字节都不动**。
     *
     * ★ 默认（无环境变量）仍读**真实文件** —— 常规 `flutter test test/`
     *   跑的就是生产代码，不会因为有了开关就"测副本不测真的"。
     *   （这个默认值很重要：否则会出现"测试全绿但测的是过期副本"。）
     */
    final override = Platform.environment['TASK43_SRC'];
    final path = (override != null && override.isNotEmpty)
        ? override
        : 'lib/ui/settings_page.dart';
    raw = File(path).readAsStringSync();
    code = stripComments(raw);
  });

  group('task-43 二级页：坑① 数据刷新（_dataRev）', () {
    test('★★ host 声明了 `_dataRev`', () {
      expect(
        code.contains('final _dataRev = ValueNotifier<int>(0);'),
        isTrue,
        reason: '★ 二级页要订阅它 —— 声明没了，订阅就编译不过',
      );
    });

    test('★★ host 在 loadAll() 的 finally 里自增（刷新链条的唯一触发点）', () {
      /*
       * ★ 这条是整个刷新机制的**根**：
       * ```text
       * 卡片动作 ⇒ await loadAll() ⇒ finally ⇒ _dataRev++ ⇒ 二级页重建
       * ```
       * ⚠️ 若挪到 `try` 的成功分支里 ⇒ **加载失败时不再通知**
       *    （与 `_firstLoadDone` 那个坑同一个形状：失败路径被漏掉）。
       */
      final loadAll = bodyOf(code, 'Future<void> loadAll() async {');
      expect(
        loadAll.contains('_dataRev.value++;'),
        isTrue,
        reason: '★★ `_dataRev.value++` 必须在 `loadAll()` 内 —— '
            '那是"动作完成后通知二级页"的唯一触发点',
      );
      // 必须在 finally 段里（覆盖成功与失败两条路径）
      final finallyIdx = loadAll.lastIndexOf('finally');
      final incIdx = loadAll.indexOf('_dataRev.value++;');
      expect(finallyIdx >= 0, isTrue, reason: '★ loadAll 必须仍有 finally');
      expect(
        incIdx > finallyIdx,
        isTrue,
        reason: '★★ `_dataRev++` 必须在 **finally** 里（不是只在成功路径）—— '
            '否则加载失败时二级页不刷新',
      );
    });

    test('★★ 二级页订阅了 `host._dataRev`（否则列表不刷新）', () {
      final page = bodyOf(code, 'class _PluginsPageState');
      expect(
        page.contains('valueListenable: host._dataRev,'),
        isTrue,
        reason: '★★ 二级页必须订阅 `host._dataRev` —— 否则卡片动作'
            '（编辑/停用/移除/安装）改了数据但**列表不刷新**，'
            '用户看到"点了没反应"',
      );
      expect(
        page.contains('host._pluginsBlock(context)'),
        isTrue,
        reason: '★ 二级页必须渲染 **host 的** `_pluginsBlock`（同一段代码）'
            '—— 那是"功能零丢失"的结构性保证',
      );
    });

    test('★★★ 【普遍性】每个二级页 State 都必须订阅 `host._dataRev`', () {
      /*
       * # 为什么单独有这一条（它是 fix-autoscroll 那轮教我的）
       *
       * 上面那条断言是「**存在**至少一处订阅」——
       * ```text
       * 守得住：有人**删掉**订阅        ⇒ 变红 ✓（红度证明 M1 已验证）
       * 守不住：有人**新增第二个**二级页而忘了订阅
       *         ⇒ 上面那条**仍然通过**（它只要求"至少一处存在"）
       * ```
       * ⇒ 这是"**存在性**"与"**普遍性**"的强度差
       *   （同族判据见 `test/t3_loading_invariant_test.dart`：
       *     字面量"某行在" vs 不变量"所有赋值点都带守卫"）。
       *
       * # 为什么需要多一条（现在的状态其实是安全的）
       * 当前文件里只有 **1 个** 二级页 State ⇒ "存在"与"普遍"**恰好重合**。
       * 但这是**巧合**，不是**保证**：下一个加二级页的人不会知道要订阅。
       *
       * # ⚠️ 刻意**不**写成"所有 ValueListenableBuilder 都必须订阅"
       * 那会**断言过强**：将来完全可能合法地加一个不订阅的 Builder
       * （例如只订阅主题/进度的），那时断言会**误红**。
       * ⇒ 所以这里只钉"**二级页 State**"这一类，精确到不会误伤。
       *
       * # ★★★ 已知边界（实测量化过，**写清楚以免后人误信**）
       *
       * ```text
       * 判据靠**类名约定**：`class (_\w+PageState)\b`
       * ⇒ 若有人新增一个**别的命名**的二级页 State（如 `_FooSubPage`），
       *    本断言**抓不到** —— 它只覆盖"按 `_*PageState` 命名的"那一类。
       * ```
       * ★ 但这不是**重复**：实测（`.probe/run-settings-merge/redundancy_audit.txt`）
       *   常规套件里 **18 个**测试读 `settings_page.dart`，
       *   **没有任何一个**数 `_*PageState` / `ValueListenableBuilder` 的个数 ⇒
       *   本断言是这条契约的**唯一**实现。
       * ★ 对照：`orchestrator_scroll_fix_verified_test.dart` L278 数的是
       *   「`_loading = true` 的**刷新赋值**个数」—— **另一条契约**，
       *   对"新增一个不订阅的二级页"（本测试的 V8 变异）**不变红**。
       *
       * ★ 为什么用"只新增、不修改"的 V8 当**试金石**：
       *   它不碰任何现有行 ⇒ 所有 `code.contains(X)`（存在型）都仍为真，
       *   只有"**数量 / 全域型**"断言才可能变红 ⇒ 能精确区分两类强度。
       *
       * # ★★★ 判据取**并集**（名字 ∪ 使用 host）—— 由实测定出，不是选的
       *
       * 实测三条路（`.probe/run-settings-merge/union_criterion.txt`）：
       * ```text
       * 变异                        ①按名字   ②按"使用host"   ③并集
       * V8 新增·**不触达**host       红        不红             红
       * V9 新增·**触达**host·换名字  不红      红               红
       * ```
       * ⇒ ★★ **两者互补，谁都不支配谁** ⇒ 取并集覆盖最广。
       *   · 按名字的盲区：**换名字**（真实第二页可能不叫 `*PageState`）
       *   · 按"使用 host"的盲区：**不触达 host**（V8 那种空壳）
       *
       * # ★★★ 但"检测到"不等于"**该**检测到"（语义更正，实测）
       * ```text
       * V8 那格**不是"①抓到"**，而是 ★ **①误报（过强）** ——
       *   它名字像二级页、但**完全不触达 host** ⇒ 因果上**不需要**订阅
       *   ⇒ ①对它报红是过强；②保持沉默才是**正确**。
       * ```
       * ⇒ ★ 所以①对 V8 是**误报**、对 V9 是**漏**（两种不同性质的失效）；
       *   ②对 V8 **正确**、对 V9 **抓到**。
       * ⇒ ★★ 而**并集继承了①对 V8 的误报** ——
       *   所以"并集不过强"**不成立**，正确的是：**检测面最广，但会误报"名字像却不触达"的类**。
       * ⇒ ★ 判"该不该红"的**唯一可靠依据是因果**：**它能不能触达 host**
       *   （触达 ⇒ 必须订阅；不触达 ⇒ 不该红）。
       *
       * # ★★★ 精确表述：这是**精确率 / 召回率**的权衡，不是"谁最强"
       *
       * 三维实测（因果真值**由构造给出**，不是用正则推的 —— 见下注）：
       * ```text
       * 变异  触达?  该红?   ①名字    ②用host   ③并集
       * V8    否     否      ★误报     沉默       ★误报
       * VG    是     是      ★漏      抓到       抓到
       * VH    是     是      ★漏      ★漏        ★漏
       * W1    否     否      沉默      ★误报      ★误报   ← ★ 见下"同名不同义"
       *
       * 汇总（真阳性 / 误报 / 漏）：
       *   ① 名字     ⇒ 高召回，**会误报**（名字像但不触达）
       *   ② 用 host  ⇒ **精确率较高**、会漏（不留痕迹）
       *                ★ 但**不是零误报**（见 W1）
       *   ③ 并集     ⇒ 召回最高；误报 = ①∪② 的**并集**，另**继承②的漏**
       * ```
       * ⇒ ★ 所以正确的说法是：
       *   · ① **高召回、低精确**
       *   · ② **精确率较高**（不是"从不误报"！）、低召回
       *   · ③ 并集 = **召回最高，但精确率没有提升**（继承 ①∪② 的误报）
       * ★ "最强"这种**一维**词描述不了它 —— 要说清**是哪个维度**。
       * ★★ 而**三条判据都同时有误报与漏**，只是**面不同** ⇒
       *    "某条从不误报"这类**绝对说法站不住**（我上一版就写错了，见下）。
       *
       * # ⚠️ 我上一版写错过一次：「② 误报**恒**为 0」
       * 我的样本只有 V8/VG/VH 三个，而它们里**唯一的 `host` 恰好就是宿主**
       * ⇒ 那个前提在我样本域内成立 ⇒ 我得出"误报=0"，还用了「**恒**」字。
       * ★ 反例 W1（**惯例内**、现实中会出现）：
       * ```dart
       * final host = RemoteHost.current;   // ★ 局域网遥控的"远端主机"
       * return Text(host.address);         //   与 SettingsPageState 无关
       * ```
       * ⇒ `\bhost\s*\.` 命中 `host.address` ⇒ ②**误报**（它不需要订阅）
       * ★ 阳性对照 W2（`host` 确实是宿主且未订阅）⇒ ②**正确抓到**
       *   ⇒ 说明判据本身正常，W1 的红**确实是误报**，不是仪器问题。
       * ★ 而它**符合本项目惯例**：`final host = …` 是普通局部变量，
       *   且本文件**已有「局域网遥控」功能** ⇒ 这种命名**很自然**。
       * ⇒ ★ 正确表述是**带前提**的：
       *   「② 误报 = 0 **当且仅当**『类体内出现的 `host` 就是宿主』」
       *   （该前提在**当前代码**里成立 —— 只有 `_PluginsPageState` 用 host）
       * ⇒ ★ 教训：这正是**"全称结论必须先枚举全域"**的应用 ——
       *   **这次是我自己**在"②误报恒为0"上越过了样本域。
       *
       * # ⚠️ 一个容易犯的方法错误（两位验证者都踩过，我避开了）
       * 上表的"**触达?**"列是**因果关系**，必须**由构造给出**
       * （我写 VH 时就知道 `h` 是宿主 ⇒ 触达=true）。
       * ★ 若也用 `\bhost\s*\.` 之类的**同款正则**去推这个真值，
       *   就会与被测的② **共享同一个盲区** ⇒ VH 被判成"不触达" ⇒
       *   整张表**自相矛盾**（"不该红"却三列全漏）⇒ 那是**假独立**。
       * ⇒ ★ 纪律：**"独立验证"要用不同的观测手段** ——
       *   若与被测对象共享表达式，只是在**重复它的盲区**。
       *
       * # ⚠️⚠️ 为什么不能只写"State 类里有 `SettingsPageState` 字段"
       * 实测：那种读法命中 **0 个类** ⇒ 循环体一次都不跑 ⇒
       *   ★ **空断言**（永远绿灯）—— 比"判据更弱"危险得多。
       * 根因：`final SettingsPageState host;` 声明在 **StatefulWidget**
       *   （`_PluginsPage`）里，**不在** State（`_PluginsPageState`）里；
       *   State 侧是靠 `final host = widget.host;` **局部变量**拿的。
       * ⇒ 所以这里按"**State 里出现 `widget.host` 或 `host.`**"判定（行为），
       *   而**不是**按"声明了字段"（那会命中 0）。
       *
       * # ✅ 并集**不会**误伤这 4 个 Dialog（实测）
       * `_OrderDialogState` / `_PluginUpdateDialogState` /
       * `_PluginConfigDialogState` / `_WebdavDialogState`：
       *   **既不叫** `*PageState`、**也不使用** host ⇒ **不被检查** ⇒ 正确沉默 ✓
       * （结构式 `extends State<` 之所以过强，正是因为它把 4 个 Dialog 也纳入。）
       *
       * # ⚠️ 并集**的边界 = 它枚举的"触达痕迹"的范围**（实测）
       * ```text
       * 已枚举的触达痕迹：① 类名 `*PageState`  ② 类体内 `widget.host` / `host.`
       * 未枚举的触达方式：
       *   · 把宿主存进**别的名字**的变量（`h` / `svc` / `ctrl` …）
       *   · 经 `InheritedWidget` / 单例且字段名不含 `host`
       *   · 传参给子 widget…
       * ⇒ 出现这些形态时**会漏**。
       * ```
       * 实测（`.probe/run-settings-merge/vg_recheck.txt`）：
       *   构造 `_BarPaneState`：`final h = _globalSettingsHost!;` 后用 `h._dataRev`
       *   ⇒ ①不命中（名字不符）、②不命中（没有 `host.` 字样）
       *   ⇒ ★★ **并集漏它** ⇒ 这是**对本实现有效**的边界。
       * ★ 如实标注性质：这些写法**符合语法、但不符合本项目惯例** ——
       *   惯例是**构造函数注入**（`_PluginsPage({required this.host})`），
       *   现状只有 `_PluginsPageState` 一个二级页。
       *   ⇒ 属**理论边界 / 惯例外的写法**，不是"高危漏网"。
       *   ★ 若将来真出现（例如改用单例），需把判据改成
       *     「**凡能触达 host 的 State 都必须订阅**」并把触达方式列全。
       *
       * # ★★★ ② 的**判定表达式**（报"边界"时必须连表达式一起给）
       * ```text
       * ① nameRe   = RegExp(r'class (_\w+PageState)\b')         ← 类名
       * ② usesHost = body.contains('widget.host')
       *              || RegExp(r'\bhost\s*\.').hasMatch(body)   ← ★ 类体内出现 `host.`
       * ```
       * ★ 为什么要写出来：**同一个判据名（"属性式"）下可以有多种定义，
       *   它们的盲区不同**（实测）：
       * ```text
       * 形态                     ②=字段注入   ②=使用 `host.`（本文件）
       * VG   `host._dataRev`     漏            ★ **命中**
       * VH   `h._dataRev`        漏            ★ 漏
       * ```
       * ⇒ ★ 所以"②有盲区 X"这句话，**不声明是哪版实现就没有意义** ——
       *   本文件的 ② 是「**使用 `host.`**」，所以：
       *     · 对 VG **不漏**（它字面含 `host.`）
       *     · ★ 对 VH **漏**（触达但不含 `host.` 字样）⇒ **这才是本实现的边界**
       *   ★ 后人若报"这里有盲区"，请先比对上表，确认自己测的是哪一版 ②。
       *
       * # ★★★ 已知边界（**四条**，按性质分组）
       * ```text
       * 【会漏】—— 该红却不红
       *   ① 换名字（不叫 `*PageState`）           ：① 盲
       *   ② 触达但不留 `host.` 字样（`h._dataRev`）：① ② 都盲（VH）
       *      未枚举的触达方式：InheritedWidget、单例字段名不含 host、
       *      传参给子 widget、别的变量名（svc/ctrl）…
       * 【会误报】—— 不该红却红
       *   ③ 名字像二级页但**不触达**（`_V8FakePageState`）：① 盲 ⇒ ② 正确沉默
       *   ④ ★ **同名不同义**：类体内有叫 `host` 的东西但**不是宿主**
       *      实测（`.probe/run-settings-merge/w1_counterexample.txt`）：
       *      ```dart
       *      final host = RemoteHost.current;  // ★ 局域网遥控的"远端主机"
       *      return Text(host.address);        //   与 SettingsPageState 无关
       *      ```
       *      ⇒ `\bhost\s*\.` 命中 `host.address` ⇒ **②误报**
       *      ★ 阳性对照：`host` 确实是宿主且未订阅 ⇒ ②**正确抓到**
       *        ⇒ 判据本身正常，这确实是误报。
       *      ★ 且它**符合惯例**（普通局部变量；本文件已有「局域网遥控」功能
       *        ⇒ `RemoteHost` 这类命名很自然）⇒ **惯例内、现实中会出现**。
       * ```
       * ⇒ ★★ 正确表述（**带前提**）：
       *   「② 误报 = 0 **当且仅当**『类体内出现的 `host` 就是宿主』」
       *   该前提在**当前代码**里成立（只有 `_PluginsPageState` 用 host）。
       * ⇒ ★ 判"该不该红"的因果依据要更精确：
       *   「**它能不能触达宿主（SettingsPageState）**」，
       *   而**不是**「它体内有没有叫 `host` 的东西」。
       */
      final structRe = RegExp(r'class (_\w+)\s+extends\s+State<[^>]+>');
      final nameRe = RegExp(r'class (_\w+PageState)\b');
      final namedClasses = nameRe.allMatches(code).map((m) => m.group(1)!).toSet();

      // 候选 = 名字匹配 **或** 类体内使用 host（并集）
      final candidates = <String>[];
      for (final m in structRe.allMatches(code)) {
        final cls = m.group(1)!;
        final body = bodyOf(code, 'class $cls');
        final usesHost = body.contains('widget.host') ||
            RegExp(r'\bhost\s*\.').hasMatch(body);
        if (namedClasses.contains(cls) || usesHost) {
          candidates.add(cls);
        }
      }

      /*
       * ★★ 空断言守卫（必需）
       *
       * 上面那三行如果哪天失效（例如正则不再匹配、或 `bodyOf` 取不到类体），
       * `candidates` 会变空 ⇒ 下面的循环**一次都不执行** ⇒
       * 断言**永远通过** ⇒ 保护**静默消失**，而测试仍显示绿灯。
       * ⇒ 所以必须**显式断言候选非空**（找不到 ≠ 合规）。
       */
      expect(
        candidates, isNotEmpty,
        reason: '★★★ 前置：必须至少能定位一个"需要订阅的类" —— '
            '若为 0，下面的循环不执行 ⇒ 本断言会变成**空断言**（永远绿灯）',
      );

      for (final cls in candidates) {
        final body = bodyOf(code, 'class $cls');
        expect(
          body.contains('valueListenable: host._dataRev,'),
          isTrue,
          reason: '★★★ `$cls` 必须订阅 `host._dataRev` —— '
              '它拿宿主、渲染在另一条路由上，收不到宿主 setState；'
              '不订阅 ⇒ 动作改了数据但界面不变（看起来"点了没反应"）',
        );
        expect(
          body.contains('valueListenable: host._toastRev,'),
          isTrue,
          reason: '★★★ `$cls` 必须订阅 `host._toastRev` —— '
              '宿主的 toast 画在宿主 Stack 里，被整屏路由盖住；'
              '不订阅 ⇒ 所有提示（尤其失败提示）用户看不到',
        );
      }
    });
  });

  group('task-43 二级页：坑② toast 可见性（_toastRev）', () {
    test('★★ host 声明了 `_toastRev`', () {
      expect(
        code.contains('final _toastRev = ValueNotifier<String?>(null);'),
        isTrue,
      );
    });

    test('★★ `_flash` 走统一 toast（`_toastRev` 已退役为死通道）', () {
      /*
       * ★ 2026-10-10：这条原来断言 `_flash` 必须写 `_toastRev.value = msg;`
       *   —— 那是**旧机制**：当时 host 的 toast 画在自己的 Stack 里，被整屏
       *   push 路由盖住，所以二级页看不到任何反馈，才需要这条同步链路。
       *
       *   现在 `_flash` 走 `showAppToast`，而宿主 `ToastHost` 挂在
       *   `lib/shell.dart` 的 `MaterialApp.builder` 里、**Navigator 之外**
       *   ⇒ 二级页天然能弹，同步链路不再需要。
       *   （那 5 条「ToastHost 真的挂在树上」的守卫在
       *    `test/toast_host_mounted_test.dart`，本轮实测 5/5 绿。）
       *
       *   ⚠️ `_toastRev` **故意保留**（恒 null 的死通道）：删掉它要连带改
       *   所有读取点，漏一个就是「二级页没反馈」的新回归。
       */
      final flash = bodyOf(code, 'void _flash(String msg) {');
      expect(
        flash.contains('showAppToast(context, msg)'),
        isTrue,
        reason: '★★ `_flash` 必须走统一 toast —— 它挂在 Navigator 之外，'
            '二级页也看得见（这正是 `_toastRev` 存在的理由已消失的原因）',
      );
      expect(
        flash.contains('_toastRev.value = msg;'),
        isFalse,
        reason: '★ `_flash` 不该再写 `_toastRev`（那条通道已退役，恒 null）',
      );
    });

    test('★★ 二级页订阅了 `host._toastRev` 并自己画 toast', () {
      final page = bodyOf(code, 'class _PluginsPageState');
      expect(
        page.contains('valueListenable: host._toastRev,'),
        isTrue,
        reason: '★★ 二级页必须订阅 `host._toastRev` —— 否则所有提示'
            '（尤其"安装失败/删除失败"）**用户完全看不到**，'
            '而失败时列表不变 ⇒ 用户会以为"点了没反应"并重复点击',
      );
      // 自己画：样式与 host 一致（同一个让位 token）
      expect(
        page.contains('bottom: Sp.bottomBarInset,'),
        isTrue,
        reason: '★ 二级页的 toast 要与 host **同款让位**（悬浮底栏会盖住）',
      );
    });

    test('★ 两个 notifier 都被 dispose（不泄漏）', () {
      final dispose = bodyOf(code, 'void dispose() {');
      expect(dispose.contains('_dataRev.dispose();'), isTrue);
      expect(dispose.contains('_toastRev.dispose();'), isTrue);
    });
  });

  group('task-43 结构：搬到二级页（不是删除）', () {
    test('★★ 一级页只剩**一行入口**（不再是完整区块）', () {
      // 一级页：入口行用 `SettingsEntryRow` + `_openPluginsPage`
      expect(
        code.contains('onTap: _openPluginsPage,'),
        isTrue,
        reason: '★ 一级页必须有一行入口指向二级页',
      );
      // 入口的副标题要说清"里面有什么"（Lead 的硬性要求）
      //
      // ⚠️ 用 **raw string**（`r'...'`）：普通字符串里的 `${...}` 会被
      //    Dart **插值**（编译不过：`Undefined name '_providers'`）。
      //    这里要匹配的是**源码字面量**，必须原样。
      expect(
        code.contains(
            r"'${_providers.length} 个内容源 · 安装 / 编辑 / 更新 / 排序 / 代理'"),
        isTrue,
        reason: '★ 入口副标题必须能看出里面有什么 —— 只写「JS 插件 ›」不合格',
      );
    });

    test('★★ 区块被抽成方法（零字节搬动 = 功能不丢的结构保证）', () {
      expect(
        code.contains('Widget _pluginsBlock(BuildContext context) {'),
        isTrue,
        reason: '★★ 区块必须在 `_pluginsBlock()` 里 —— 二级页调**同一个方法**，'
            '一级/二级渲染同一段代码 ⇒ 功能丢失在结构上不可能',
      );
    });

    test('★ 二级页用 `SettingsSubPage` 做外壳（自带返回 + Esc/遥控返回）', () {
      // 全局标题栏**没有**返回键 ⇒ 外壳必须自带
      expect(
        code.contains("import 'widgets/settings_sub_page.dart';"),
        isTrue,
        reason: '★ 必须 import 外壳（原本一级页不直接用，漏了就编译不过）',
      );
      final page = bodyOf(code, 'class _PluginsPageState');
      expect(page.contains('return Stack('), isTrue,
          reason: '★ 需要 Stack 才能把 toast 浮在页面之上');
      expect(page.contains('SettingsSubPage('), isTrue);
    });

    test('★★ ⑥「远程」分组排在「内容源与插件」之前（Owner：放最上面）', () {
      /*
       * ★ 2026-10-10：设置页信息架构重做后，遥控不再是一个裸区块，
       *   而是被归进「远程」分组；JS 插件归在「内容源与插件」分组里。
       *   ⇒ 判据改成比较**分组标签**的位置（那才是屏幕上真实看到的顺序），
       *     而不是某个具体条目的标题。
       *
       *   Owner 的原话「局域网遥控设置放在最上面」依然成立：
       *   「远程」是第一个分组。
       */
      final remote = raw.indexOf("SettingsGroupLabel(text: '远程'");
      final plugins = raw.indexOf("SettingsGroupLabel(text: '内容源与插件'");
      expect(remote > 0, isTrue, reason: '★ 前置：必须能找到「远程」分组');
      expect(plugins > 0, isTrue, reason: '★ 前置：必须能找到「内容源与插件」分组');
      expect(remote, lessThan(plugins),
          reason: '★★ Owner 原话「局域网遥控设置放在最上面」⇒ '
              '「远程」分组必须在「内容源与插件」之前');
      // 「远程」还必须是**第一个**分组标签
      final firstOther = raw.indexOf('SettingsGroupLabel(');
      expect(firstOther, remote,
          reason: '★★「远程」必须是第一个分组（Owner 要求的「放最上面」）');
    });
  });
}
