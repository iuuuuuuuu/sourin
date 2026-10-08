// ═══════════════════════════════════════════════════════════════════════
//  核心启动失败 —— 界面**必须**如实告知（任务 AM，2026-09-25 真机实测）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的是什么 bug（Android TV 真机实测撞到）
//
// 把数据目录指向 App **不可访问**的路径，实测日志：
// ```text
// [SHELL] ★ 核心启动失败: PathAccessException: Exists failed,
//         path = '.../tvdata' (OS Error: Permission denied, errno = 13)
// [SHELL] FIRST_FRAME_RENDERED                       ← ★ 界面照常渲染
// [SHELF] 取收藏失败: SourinCoreException(unsupported): 核心尚未启动
// [HOME] ★ loadAll 失败:
// [HOME] 渲染完成: 启用源=0 个（当前=） 分区=0 卡片=0 错误=无
// ```
// **用户看到的是一个空应用**（"还没有可用的内容源"），
// 却完全不知道核心根本没启动。
//
// # 根因（静态扫描确认，剥掉注释后统计）
//
// `coreError` 整条链路都建好了 —— `main()` 里赋值、传给 `SourinApp`、
// 再传给 `ShellPage`，但 **`_ShellPageState` 里出现 0 次**：
// ```text
// shell.dart:335    String? coreError;              ← main() 声明
// shell.dart:366    coreError = e.toString();       ← catch 赋值
// shell.dart:395    runApp(SourinApp(coreError:...))← 传给 App
// shell.dart:482    final String? coreError;        ← SourinApp 接收
// shell.dart:1119   home: ShellPage(coreError:...)  ← 传给 ShellPage
// shell.dart:1131   final String? coreError;        ← ShellPage 接收
// _ShellPageState   coreError 出现【0 次】            ★★★ 最后一跳断了
// ```
// 也就是「拿到却从不使用」—— 这是**静默失败**的典型形态：
// 失败被如实记录了（日志里有），却**从没到达用户**。
//
// # 为什么用 widget test 而不是静态断言
//
// 这个 bug 的本质是"**渲染出来的界面**与真相不符"，
// 静态断言（"文件里有没有出现 coreError"）**恰好会漏掉它** ——
// 因为 `coreError` 在文件里确实出现了 8 次（只是没被用）。
// 必须真的把 `ShellPage` 挂起来、渲染一帧、然后问界面：
// 「你到底显示了什么？」
//
// ⚠️ 这正对应本项目反复踩到的教训：单测绿 ≠ 真机能用，
//    因为**测试脚手架可能测的不是那个东西**。这里刻意
//    用真实的 `ShellPage`（不是手搓的替身），并复刻
//    `SourinApp.build` 的 `MaterialApp.builder → FTheme` 结构 ——
//    因为 `FTheme.of(context)` 能不能取到，取决于这层结构。

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';

/// 复刻 `SourinApp.build` 的树结构（`FTheme` 在 `MaterialApp.builder` 里）
///
/// # 为什么不能图省事直接 `MaterialApp(home: ShellPage(...))`
///
/// `_CoreErrorView` 用 `FTheme.of(context)` 取色 —— 而 `FTheme`
/// 是 `MaterialApp.builder` 注入的。少了这一层，取色会抛异常，
/// 于是测试**测不出真实渲染**（只会看到"我的壳拼错了"）。
///
/// 这与 `titlebar_route_test.dart` 里记录的那次 false fail 是同一类坑：
/// 手搓的壳测的是壳，不是被集成的那层结构。
Widget _appWith({required Widget home}) {
  final theme = FTheme.neutral.dark.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (context, child) => FTheme(
      data: theme,
      child: child ?? const SizedBox(),
    ),
    home: home,
  );
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 核心启动失败 → 必须有**可见的**错误提示
  // ═══════════════════════════════════════════════════════════════════
  group('核心启动失败时界面如实告知', () {
    /// 真机实测那条错误（Android TV，Permission denied）
    const realError =
        'PathAccessException: Exists failed, path = '
        "'/storage/emulated/0/tvdata' (OS Error: Permission denied, errno = 13)";

    testWidgets('★ 用户一眼能看到「核心未能启动」（不是误导性空态）', (t) async {
      await t.pumpWidget(_appWith(
        home: const ShellPage(
          coreError: realError,
          coreDataDir: '/storage/emulated/0/tvdata',
        ),
      ));
      // 一帧就够 —— 错误页是同步渲染的（没有异步依赖）
      await t.pump();

      expect(
        find.textContaining('核心未能启动'),
        findsOneWidget,
        reason: '★ 这是整个修复的核心：核心没起来时，界面**必须**'
            '明说"核心未能启动"。修之前这里渲染的是发现页的空态。',
      );

      /*
       * ★ 反向断言：**不能**再出现误导性的空态文案。
       *
       * 这是"修好了"与"看起来修好了"的分界线 ——
       * 只在顶部加条 banner、下面仍写着"还没有可用的内容源"的话，
       * 用户依然会以为是"没配源"而去折腾源。
       */
      expect(
        find.textContaining('还没有可用的内容源'),
        findsNothing,
        reason: '★ 核心没启动时**绝不能**显示"还没有可用的内容源" —— '
            '那句话把"没配置源"和"核心挂了"混为一谈，'
            '正是本 bug 误导用户的根源。',
      );
    });

    testWidgets('★ 显示 coreError 的**实际内容**（不是一句笼统的"出错了"）', (t) async {
      await t.pumpWidget(_appWith(
        home: const ShellPage(
          coreError: realError,
          coreDataDir: '/storage/emulated/0/tvdata',
        ),
      ));
      await t.pump();

      /*
       * 断言错误原文里**有辨识度的那几个片段**，而不是整串相等 ——
       * 整串相等会把"排版/换行"的变化也算成失败，那是假失败。
       * 这里要证明的是：**原始错误信息确实到达了界面**。
       */
      expect(
        find.textContaining('PathAccessException'),
        findsOneWidget,
        reason: '错误类型必须可见 —— 用户/我们才能据此判断是权限还是别的',
      );
      expect(
        find.textContaining('Permission denied'),
        findsOneWidget,
        reason: '★ 系统给的原因（Permission denied）是**最有诊断价值**的一句，'
            '不能只显示我们自己的转述',
      );
      expect(
        find.textContaining('errno = 13'),
        findsOneWidget,
        reason: 'errno 也要在 —— 它才是能拿去搜索/报 bug 的东西',
      );
    });

    testWidgets('★ 给出数据目录（可操作的下一步）', (t) async {
      await t.pumpWidget(_appWith(
        home: const ShellPage(
          coreError: realError,
          coreDataDir: '/storage/emulated/0/tvdata',
        ),
      ));
      await t.pump();

      expect(
        find.textContaining('/storage/emulated/0/tvdata'),
        findsWidgets,
        reason: '★ "哪个目录出问题"是**唯一可操作**的线索 —— '
            '用户改不了代码，但他能改存储权限 / 换回内置存储。'
            '不显示路径的话，用户只能干瞪眼。',
      );
      expect(
        find.textContaining('数据目录'),
        findsOneWidget,
        reason: '要标出这块内容是"数据目录"，否则一串路径没有语境',
      );
    });

    testWidgets('★ 给出可操作的处置建议', (t) async {
      await t.pumpWidget(_appWith(
        home: const ShellPage(
          coreError: realError,
          coreDataDir: '/storage/emulated/0/tvdata',
        ),
      ));
      await t.pump();

      expect(find.textContaining('可以这样处理'), findsOneWidget);
      expect(
        find.textContaining('权限'),
        findsWidgets,
        reason: '真机实测的原因就是权限 —— 建议里必须提到它',
      );
      expect(
        find.textContaining('重新尝试启动'),
        findsOneWidget,
        reason: '★ 核心的 `sourin_start` 是**幂等**的，所以"重试"是'
            '安全的。用户修好权限后不该被迫杀进程重开（TV 上很不直观）。',
      );
    });

    testWidgets('★ 不做全屏接管：底栏与外壳仍在（错误是持续的，但退路要留着）', (t) async {
      await t.pumpWidget(_appWith(
        home: const ShellPage(
          coreError: realError,
          coreDataDir: '/storage/emulated/0/tvdata',
        ),
      ));
      await t.pump();

      /*
       * # 为什么断言底栏还在
       *
       * 核心没起来时所有页面都是死的（发现/直播/追更/搜索全空）。
       * 只在首页加 banner 的话，用户一切到「直播」就看不到错误了 ——
       * 又变回"这个应用怎么是空的"。
       *
       * 但**也不能**全屏接管：底栏让用户能确认"应用本身是活的"，
       * 而且「设置」是修复入口（换数据目录 / 看诊断）。
       * 拆掉底栏等于把退路也拆了。
       *
       * 所以设计是「**内容区**被错误页接管，外壳保留」——
       * 这条断言守的就是这个边界。
       */
      for (final label in const ['发现', '直播', '追更', '搜索', '设置']) {
        expect(
          find.text(label),
          findsWidgets,
          reason: '★ 底栏的「$label」应该仍在 —— '
              '错误页只接管**内容区**，外壳（底栏）必须保留',
        );
      }
    });

    testWidgets('★ 切 tab 时错误信息**始终可见**（不随 tab 消失）', (t) async {
      /*
       * ⚠️ 必须把 `debugShellKey` 交给这个 `ShellPage` ——
       *
       * 它是探针读取 State 的**唯一**入口（`_ShellPageState` 是私有的，
       * 测试无法用类型去 `t.state<>`）。不传 key 的话
       * `debugShellKey.currentState` 是 null，测试会以
       * "ShellPage 应已挂载" 失败 —— 那是**测试自己的问题**，
       * 不是被测代码的问题（我第一版就是这么写错的）。
       */
      await t.pumpWidget(_appWith(
        home: ShellPage(
          key: debugShellKey,
          coreError: realError,
          coreDataDir: '/storage/emulated/0/tvdata',
        ),
      ));
      await t.pump();

      /*
       * 用探针的显式切换（`debugSwitchTo`）而不是模拟按键 ——
       * 按键路径依赖焦点系统，而那个在 flutter_test 下不可靠
       *（本项目已记录过多次）。这里要证明的是**渲染**关系，
       * 不是按键派发。
       */
      final state = debugShellKey.currentState;
      expect(state, isNotNull, reason: 'ShellPage 应已挂载');

      for (final tab in AppTab.values) {
        state!.debugSwitchTo(tab);
        /*
         * ⚠️ 必须**等切换动画走完**再断言（260ms 的 AnimatedSwitcher）。
         *
         * 动画期间新旧两个 child **同时存在**（旧的还没被移除），
         * 于是「核心未能启动」会短暂出现 **2 次** ——
         * `findsOneWidget` 会以 "is too many" 失败。
         * 那是**动画的正常行为**，不是 bug（我第一版就是这么误判的）。
         */
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        expect(
          find.textContaining('核心未能启动'),
          findsOneWidget,
          reason: '★ 切到「${tab.label}」之后错误提示也必须还在 —— '
              '否则用户切个页面就以为应用是空的（本 bug 的另一种形态）',
        );
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 核心正常启动 → **零回归**
  // ═══════════════════════════════════════════════════════════════════
  group('核心正常启动时不显示错误页', () {
    testWidgets('★ coreError == null → 渲染的是**真页面**，不是错误页', (t) async {
      /*
       * ══════════════════════════════════════════════════════════════
       * ⚠️ 这段"静音 + 认领异常"是**测试环境**的限制，不是被测代码的问题
       * ══════════════════════════════════════════════════════════════
       *
       * `coreError == null` 时内容区渲染的是**真的发现页**，
       * 而 `HomePage` 在 `flutter_test` 里必然抛异常，有两个原因
       *（**都与本改动无关**，改动前完全一样 —— 我单独挂 `HomePage`
       *  验证过，见下面的注释）：
       *
       * ```text
       * ① initState 的 postFrameCallback 调 SourinApi.listProviders()
       *    → 需要 FFI 核心（测试环境没有 sourin_core.dll）
       *    → Invalid argument(s): Failed to load dynamic library
       * ② SliverPersistentHeader（吸附的源切换条）在测试视口下报
       *    "layoutExtent exceeds paintExtent" → 连带把 element 树搞坏
       * ```
       *
       * ⚠️ ②**不是**"视口太小" —— 我在 1280x720 / 1920x1080 /
       *    2560x1440 都试过，**同样报错、同样 8 个异常**。
       *    所以这不是"调下测试参数就能过"，而是"这个页面本来就
       *    无法在无核心的测试环境里完整渲染"。
       *
       * # 关键：树坏掉之后 `find` 的默认遍历会抛 `_TypeError`
       *
       * 所以下面的 finder 全部用 `skipOffstage: false`（实测可用）——
       * 默认的 `skipOffstage: true` 会去访问坏掉的 RenderObject，
       * 抛 `_TypeError` 而不是给出 0。**这是找法（finder）的问题，
       * 不是断言太弱**：`skipOffstage: false` 走的是完整的 element 树，
       * 找得更全，断言只强不弱。
       *
       * # 为什么照测而不是 skip 掉
       *
       * 因为**这条恰恰要证明"没回归"** —— 如果错误页在
       * `coreError == null` 时误触发，那是个比原 bug 更严重的新 bug。
       * 用 `skip` 把它藏起来就等于没测。
       *（"正常路径观感与之前完全一致"另由**真机截图对比**覆盖。）
       */
      final oldOnError = FlutterError.onError;
      FlutterError.onError = (details) {}; // 静音（见上面的说明）
      addTearDown(() => FlutterError.onError = oldOnError);

      await t.pumpWidget(_appWith(home: const ShellPage()));
      await t.pump();

      FlutterError.onError = oldOnError;
      while (t.takeException() != null) {
        // 认领上面说明的环境噪声（见长注释）
      }

      /*
       * ★ 正向对照（**必须有**）
       *
       * 只断言"错误页不出现"是不够的 —— 一个**什么都不渲染**的
       * 空树也能让那条断言通过。所以先证明"外壳确实渲染出来了"：
       * 底栏的 5 个 tab 都在。
       * 有了这个对照，"错误页不出现"才是**有意义的**结论。
       */
      for (final label in const ['发现', '直播', '追更', '搜索', '设置']) {
        expect(
          find.text(label, skipOffstage: false),
          findsWidgets,
          reason: '正向对照：底栏的「$label」应该在 —— '
              '先证明树真的渲染了，下面的"没有错误页"才有意义',
        );
      }

      expect(
        find.textContaining('核心未能启动', skipOffstage: false),
        findsNothing,
        reason: '★ 核心正常启动时**绝不能**显示错误页（否则就是新的 bug）',
      );
      expect(
        find.textContaining('可以这样处理', skipOffstage: false),
        findsNothing,
        reason: '错误页的处理建议也不该出现',
      );
      expect(
        find.textContaining('重新尝试启动', skipOffstage: false),
        findsNothing,
        reason: '错误页的重试按钮也不该出现',
      );
    });
  });
}
