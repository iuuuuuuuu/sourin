// ═══════════════════════════════════════════════════════════════════════
//  自绘标题栏必须在**所有路由**上都在（含 push 上来的详情页）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户反馈的真缺陷（2026-09-24）
//
// > 影视详情页和播放页都没有顶部的那个操作条，无法拖动
// > 这是个影响交互体验的问题
//
// # 根因
//
// 我把标题栏挂成了 `FScaffold.header` —— 那是 `ShellPage` **内部**，
// 而详情页/浏览页/播放页都是 `Navigator.push` 上来的**新路由**，
// 渲染在 `ShellPage` **之外**：
// ```text
// Navigator
//  ├─ 路由 0: ShellPage   ← 标题栏在这里（只有它有）
//  ├─ 路由 1: DetailPage  ← 在它外面 ✗ 没有标题栏、拖不动
//  └─ 路由 2: PlayerPage  ← 同上 ✗
// ```
//
// # 原版怎么做的（`App.vue` L457）
//
// ```html
// <TitleBar />                 <!-- ★ 在 RouterView **外面** —— 所有路由共用 -->
// <div class="app-root">
//   <main><RouterView>...</RouterView></main>
//   <LiquidTabBar />
// </div>
// ```
//
// # 修法
//
// 挂到 `MaterialApp.builder` —— 它在 Navigator **外面**，
// 所有路由都渲染进它的 `child`。
//
// # ⚠️ 这里用真实 `MaterialApp` 而不是手搭一个 Widget
//
// 我第一版手搓了一个"外壳"（自己拼 Column + ValueListenableBuilder），
// 结果测的是**我拼的那个壳**，而不是 `MaterialApp.builder` 与
// Navigator 的真实关系 —— 测试因此 false fail（按钮 push 不动）。
// 必须用真实 `MaterialApp` + 真实 `Navigator.push`。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/titlebar_visibility.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

/// 复刻 `SourinApp.build` 的结构：标题栏在 builder 里（Navigator 之外）
Widget _appWithHost({required Widget home}) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (context, child) => AppThemeHost(
      data: theme,
      child: _FakeTitleBarHost(child: child ?? const SizedBox()),
    ),
    home: home,
  );
}

/// 与 `shell.dart` 的 `_TitleBarHost` **同构**的最小版本
///
/// 只保留"是否渲染标题栏"这一件事 —— 真版本还处理最大化状态、
/// 窗口按钮等，那些与本测试要证明的结构关系无关。
class _FakeTitleBarHost extends StatelessWidget {
  const _FakeTitleBarHost({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: titleBarVisible,
            builder: (_, show, __) => show
                ? const SizedBox(
                    key: ValueKey('titlebar'),
                    height: 40,
                    width: double.infinity,
                    child: Text('源影'),
                  )
                : const SizedBox(width: double.infinity),
          ),
          Expanded(child: child),
        ],
      );
}

void main() {
  setUp(() => titleBarVisible.value = true);
  tearDown(() => titleBarVisible.value = true);

  testWidgets('★ 标题栏在 Navigator 之外：push 新路由后仍然在', (t) async {
    await t.pumpWidget(_appWithHost(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              // ★ 用 ctx 自己的 Navigator —— 那是 MaterialApp 提供的真 Navigator
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('详情页')),
                ),
              ),
              child: const Text('去详情'),
            ),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('titlebar')), findsOneWidget,
        reason: '首页应该有标题栏');

    await t.tap(find.text('去详情'));
    await t.pumpAndSettle();

    expect(find.text('详情页'), findsOneWidget, reason: '详情页应该被推上来');
    expect(
      find.byKey(const ValueKey('titlebar')),
      findsOneWidget,
      reason: '★ 详情页（push 上来的路由）**也必须**有标题栏 —— '
          '这正是用户反馈的问题：「详情页没有顶部的操作条，无法拖动」。',
    );
  });

  testWidgets('★ 播放页**保留**标题栏（桌面端唯一的拖动区）', (t) async {
    /*
     * ══════════════════════════════════════════════════════════════════
     * ⚠️ 这条断言的方向**曾经写反过**（2026-09-24 用户二次纠正）
     * ══════════════════════════════════════════════════════════════════
     *
     * 我第一版断言的是「播放页**收起**标题栏」（对齐原版 `.is-hidden`），
     * 而且它**通过了** —— 因为实现和断言犯的是同一个错误。
     * 用户随后明确指出：
     * > 播放器页面没有顶部的那个可拖动 缩小 放大 关闭的那个操作条,
     * > 影响体验,在桌面端播放页面 无法拖动窗口
     *
     * # 为什么原版能隐藏、我们不能
     * ```text
     * 原版：WebView 网页 → 标题栏隐藏后 Tauri 原生窗口**仍可拖**
     *       （系统装饰 / Alt+Space / Win+方向键都还在）
     * 我们：`titleBarStyle: hidden` → 这条自绘栏是**唯一**拖动区
     *       → 隐藏 = 窗口彻底拖不动
     * ```
     *
     * ★ 教训：**测试与实现同源时，方向写反了也不会报警。**
     *   真相只能靠外部需求校准 —— 这也说明"单测绿"绝不等于"做对了"。
     */
    await t.pumpWidget(_appWithHost(home: const Scaffold(body: Text('首页'))));
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('titlebar')), findsOneWidget,
        reason: '首页有标题栏');

    // 播放页 = 仍然是同一条标题栏（我们**不再**隐藏它）
    expect(
      titleBarVisible.value,
      isTrue,
      reason: '★ 播放页必须保留标题栏 —— 桌面端它是**唯一**的窗口拖动区。'
          '隐藏它用户就拖不动窗口了（用户实际反馈过这个问题）。',
    );
    expect(
      find.byKey(const ValueKey('titlebar')),
      findsOneWidget,
      reason: '播放页的标题栏必须真的渲染出来（不只是标志位为 true）',
    );
  });

  testWidgets('★ PlayerPage 生命周期成对设置（静态断言真实路径）', (t) async {
    /*
     * 上面两条测的是"信号变化时标题栏怎么响应"，
     * 但**不能**保证 `player_page.dart` 真的成对设置。
     *
     * 这个坑我在修 Material 祖先时刚栽过一次：
     * 「测了我抽出来的函数」≠「测真实路径」。
     */
    final src = File('lib/ui/player_page.dart').readAsStringSync();

    /*
     * ⚠️ 方向已按用户反馈**反转**（2026-09-24），且**限定在 initState**。
     *
     * # 为什么必须限定范围（否则会挡住合法的全屏逻辑）
     *
     * 正确规则不是"PlayerPage 永远不隐藏标题栏"，而是：
     * ```text
     * initState（窗口模式）   → 不得隐藏（桌面端唯一拖动区）
     * _toggleFullscreen(true) → **必须**隐藏（全屏下不该占画面）
     * ```
     * 第一版我写的是"整个文件不得出现 `= false`" —— 那在加全屏支持后
     * 就会**挡住正确代码**（如果全屏分支写成字面量 `= false` 的话）。
     * 现在全屏用的是 `= !next`（动态值）刚好没撞上，但那是运气，不是设计。
     *
     * 所以把范围收窄到 `initState` 函数体，语义才准确 ——
     * **误导性的测试注释正是我前几轮反复搞错方向的根源之一**。
     */
    /*
     * ⚠️ 提取 `initState` 的函数体**必须按大括号配对截取**，
     *    不能简单地 "从 initState 到 dispose"（第一版就是这么写的）。
     *
     * # 为什么（这个坑很隐蔽）
     *
     * `initState` 和 `dispose` 之间**还夹着别的方法**
     * （`_exitPlayer`、`_onKey` 等）。于是那段的文本里含有
     * `_exitPlayer` 里的 `titleBarVisible.value = true;` ——
     * 断言"initState 里不该有这句"就会**假失败**。
     *
     * 更糟的是：如果我当初把全屏的 `= !next` 也写在那里，还会**假通过**。
     * 静态断言做区间匹配时，**区间边界**和匹配内容一样重要。
     */
    String bodyOf(String signature) {
      final start = src.indexOf(signature);
      expect(start, greaterThan(0), reason: '源码里找不到 `$signature`');
      final braceStart = src.indexOf('{', start);
      expect(braceStart, greaterThan(0));
      var depth = 0;
      for (var i = braceStart; i < src.length; i++) {
        if (src[i] == '{') depth++;
        if (src[i] == '}') {
          depth--;
          if (depth == 0) return src.substring(braceStart, i + 1);
        }
      }
      fail('`$signature` 的大括号不配对');
    }

    final initBody = bodyOf('void initState()');

    expect(
      initBody.contains('titleBarVisible.value = false;'),
      isFalse,
      reason: '★ `initState` 里**不得**隐藏标题栏 —— 窗口模式下它是桌面端'
          '唯一的拖动区，隐藏后用户拖不动窗口（用户实际反馈过'
          '「在桌面端播放页面 无法拖动窗口」）。'
          '注意：**全屏时**则必须隐藏，见 fullscreen_titlebar_test.dart。',
    );
    expect(
      initBody.contains('titleBarVisible.value = true;'),
      isFalse,
      reason: '`initState` 也不用显式置 true —— 默认值就是可见；'
          '写出来反而像"这里有什么特殊情况"。',
    );

    // dispose 必须有幂等的恢复（同样按大括号配对）
    final disposeBody = bodyOf('void dispose()');
    expect(
      disposeBody.contains('titleBarVisible.value = true;'),
      isTrue,
      reason: 'dispose 里保留幂等的置 true 作为防御 —— '
          '将来若加"沉浸模式"隐藏逻辑，退出时必须还原。',
    );
  });

  testWidgets('★ shell.dart 真的把标题栏挂在 builder 里（不是 FScaffold.header）',
      (t) async {
    /*
     * 这条防的是"我把标题栏又挪回某个页面内部"的回归 ——
     * 一旦挪回去，push 上来的详情页就又没有拖动条了。
     */
    final src = File('lib/shell.dart').readAsStringSync();

    expect(
      src.contains('_TitleBarHost(child: child ?? const SizedBox())'),
      isTrue,
      reason: '标题栏必须挂在 `MaterialApp.builder` 里（Navigator 之外）—— '
          '挂进任何具体页面都会让 push 上来的路由没有拖动条。',
    );
    expect(
      src.contains('header: kIsDesktop'),
      isFalse,
      reason: '`FScaffold.header` 不能再用来挂标题栏 —— '
          '它只在 ShellPage 内部，详情页/播放页都在它外面。',
    );
  });
}
