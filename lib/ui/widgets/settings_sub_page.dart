// ═══════════════════════════════════════════════════════════════════════
//  设置页的**二级页外壳**（2026-09-25 任务 ㉙）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户要求
//
// > 我希望设置页，**这几个功能，拆分到二级页面**，而不是在一级
//
// 方案 A：把 5 个低频区块（片头片尾 / PC 播放手势 / 备份 / 主题 / 关于）
// 搬进二级页，一级页原位留一行入口。这个文件是那 5 个页面的**共用外壳**。
//
// # ★★★ 为什么必须自己画返回按钮（这是本任务最容易漏的一条）
//
// 应用用的是**自绘标题栏**（`shell.dart` 的 `_CustomTitleBar`），
// 它挂在 `MaterialApp.builder` 里、**在 Navigator 之外**，内容只有：
// ```text
// [图标] 源影  ……拖动区……  [—] [□] [×]
// ```
// **没有返回按钮** —— 它是"窗口控制条"，不是"页面导航条"。
//
// 后果：`Navigator.push` 上来的路由如果自己不画返回入口，用户就
// **出不去**（只能靠 Alt+← 或重开应用）。所以现有 pushed 页面
// （`detail_page.dart:677` / `browse_page.dart:188` / `player_page.dart:5075`）
// **全都是页内自画**返回按钮。
//
// # 两种返回方式都接（用户可能用鼠标，也可能用键盘/遥控器）
//
// ```text
// ① 点左上角 [← 返回设置]     —— 鼠标 / 触摸
// ② 按 Esc 或 遥控器返回键     —— PC 键盘 / TV 遥控器
// ```
//
// ⚠️ `LogicalKeyboardKey.goBack` 是**遥控器返回键**的键值
//    （Android TV / 部分 Windows 遥控器），与 `escape` 一起判 ——
//    这是 `player_page.dart:3857` 已有的写法，照抄不发明。
//
// # 为什么用 `Focus(autofocus: true)` 而不是 `Shortcuts`
//
// `Shortcuts` 需要一个**已聚焦**的后代才会触发；二级页刚 push 上来时
// 没有任何控件被聚焦，Esc 会**落空**。`Focus(autofocus: true)` 把焦点
// 收到页面根上，`onKeyEvent` 才能收到按键 —— 与播放页同一个做法
// （`player_page.dart:4184` 的 `Focus(autofocus: true, onKeyEvent: _onKey)`）。

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

/// 设置页二级页的共用外壳
///
/// 用法：
/// ```dart
/// class ThemePage extends StatelessWidget {
///   @override
///   Widget build(BuildContext context) => SettingsSubPage(
///         title: '主题',
///         subtitle: '跟随系统 / 浅色 / 深色',
///         children: [ /* 区块 */ ],
///       );
/// }
/// ```
class SettingsSubPage extends StatelessWidget {
  const SettingsSubPage({
    super.key,
    required this.title,
    required this.subtitle,
    this.children = const [],
    this.pinnedHeader,
    this.scrollBody,
    this.onBack,
  });

  final String title;
  final String subtitle;

  /// 页面内容（通常是一个或多个 `SettingsBlock`）
  ///
  /// ⚠️ 从 `required` 改成**有默认值**（task-44 ⑤）——
  ///    因为用 [scrollBody] 的页面不再需要它。
  ///    对**已有 6 个调用方零影响**（它们本来就都传了）。
  final List<Widget> children;

  /// ★ 固定在顶部、**不随滚动**的内容（task-44 ⑤）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// # 用户原话
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// > 加一个 **搜索功能**，这个搜索要**固定在上面**，结果**在下面滚动**
  ///
  /// # ★ 为什么用"新增可选参数"而不是改外壳的默认结构
  ///
  /// `SettingsSubPage` 有 **6 个调用方**（`settings_page.dart:2543` /
  /// `about:90` / `backup:55` / `pc_gestures:65,86` / `skip:221` / `theme:52`）。
  /// 直接把它改成 `Column + Expanded` 会让**另外 5 个页面**的滚动行为
  /// 一起变 —— 那不是本次要求，属于"顺手改坏"。
  ///
  /// ⇒ 所以：
  /// ```text
  /// scrollBody == null（5 个页面）→ 走**原来的** ListView，结构逐字不变
  /// scrollBody != null（片头片尾）→ 走 Column + Expanded
  /// ```
  /// ★ 这是**结构上**保证零影响，而不是"靠小心别写错"。
  ///
  /// # 为什么选 Column + Expanded（而不是 SliverPersistentHeader）
  ///
  /// ```text
  /// 用户说「**固定在上面**」= 永远固定，不是"滚动时才吸附"
  /// ⇒ pinned: true 的 Sliver 只在需要"滚动到某处才吸顶"时才有价值
  /// ⇒ 这里是过度设计
  /// ```
  ///
  /// ⚠️ [pinnedHeader] 只在 [scrollBody] 非空时生效（单独传它无意义）。
  final Widget? pinnedHeader;

  /// 可滚动的正文（与 [pinnedHeader] 配对使用）
  ///
  /// [null] = 用 [children]（**原行为**，5 个页面走这条）。
  ///
  /// ⚠️ 传了它就必须自己带**底部留白**（`Sp.bottomBarInset`）——
  ///    悬浮底栏盖在所有路由之上，不留给白会被遮住。
  ///    见 `skip_page.dart` 的用法。
  final Widget? scrollBody;

  /// 返回键的**分层**拦截（task-14 ⑤）—— 返回 true = 本层已消费，不要 pop

  /// ══════════════════════════════════════════════════════════════════
  /// # 借鉴了什么（FlClash）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// ```text
  /// .probe\refs\FlClash\lib\widgets\scaffold.dart
  ///   :497-500  BackLayerScope(
  ///               onBack: _handleExitAppBarLayer,   // ← 先退内层
  ///               child: ...
  ///             )
  /// ```
  /// FlClash 的页面可以有**多层**（搜索层 / 多选层）：返回键先退最上面
  /// 那一层，层退光了才离开页面 —— 而不是按一下就走人。
  ///
  /// # 我们为什么需要它
  /// ```text
  /// 片头片尾页（`lib/ui/settings/skip_page.dart`）的搜索框是**内层**：
  /// 改前按返回（Esc / 遥控器返回）**直接 pop 离开整页**，
  /// 用户刚输入的搜索词**无声丢失** —— 用户必须先精确点中那个 16px 的
  /// 「清除」小图标才能只退一层（在遥控器上基本点不中）。
  /// ```
  ///
  /// # 缺省值 = 与改前**逐字相同**
  /// ```text
  /// `null`（6 个既有调用方**全部**走这条）⇒ `_onKey` / [_backButton]
  /// 都直接 `Navigator.maybePop()`，不新增任何分支 ⇒ 零回归。
  /// ```
  ///
  /// ⚠️ 只在**本页**生效：它拦截的是「返回键 / 返回按钮」，不影响系统手势返回。
  final bool Function(BuildContext context)? onBack;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      // 与设置页同一底色 —— 跳转时不应出现色差闪烁
      backgroundColor: colors.surface,
      /*
       * ★★★ 2026-10-01：二级页**必须自己**吃安全区（Owner 报「排版混乱」）
       *
       * # 症状（手机截图 `.probe\n8_about.png`）
       * ```text
       * ┌──────────────┐  ← 状态栏（1080x2400 @420dpi，挖孔 128px）
       * │ ← 返回设置    │  ← ★ 返回按钮**压在状态栏/挖孔下面**，点不到
       * ```
       * 实测设备读数（`dumpsys window displays`）：
       * ```text
       * InsetsSource type=statusBars frame=[0,0][1080,128]
       * mDisplayCutout insets=Rect(0,128 - 0,0)   ← 128/2.625 = 48.76 逻辑 px
       * ```
       *
       * # 为什么 shell 的 SafeArea 救不了这一页
       * ```text
       * shell.dart:3436 有 `SafeArea(top: true, …)`，但它的作用域是
       * **内容区那一支**（5 个 tab 的保活 Stack）。
       * 而二级页是 `Navigator.push(MaterialPageRoute(...))`
       * （`settings_page.dart` 的 `_openSubPage`）——
       * 它挂在**同一棵 Navigator 的新路由**上，**不在** shell 那个
       * SafeArea 的子树里 ⇒ 继承不到"已清零的 padding.top"。
       * ```
       * ★ 这正是 shell 那段注释里点名的同一类缺陷
       *   （`shell.dart:3400`：「全项目 `SafeArea|…` 共 9 处命中，
       *   **shell 一处都没有** ⇒ 这是 shell 级缺陷」）——
       *   二级页当时**不在** shell 的修复范围内，所以漏了。
       *
       * # 只吃顶部，与 shell 同一口径
       * `bottom: false` —— 底部各页自己留 `Sp.bottomBarInset`；
       * `left/right: false` —— 横屏/分屏的左右内边距由系统窗口决定。
       * ⇒ 与 `shell.dart:3436` 的 `top:true, bottom:false, left:false, right:false`
       *   **逐字同构**，两处不会出现"一级页让了、二级页没让"的错位。
       *
       * ⚠️ 桌面/TV 上 `padding.top == 0` ⇒ 这一层是**严格 no-op**，
       *    不会改变既有观感（与 shell 那条的负对照同理）。
       */
      body: SafeArea(
        top: true,
        bottom: false,
        left: false,
        right: false,
        child: Focus(
          autofocus: true,
          /*
           * ⚠️ 闭包捕获 `context`，**不用** `node.context`
           *
           * `onKeyEvent` 的第一个参数是 `FocusNode`，它的 `context` 指向
           * `Focus` widget **自己**那个 element —— 拿它去 `Navigator.of()`
           * 虽然通常也能找到（Navigator 在更上层），但那是"碰巧对"：
           * 一旦 `Focus` 被塞进别的结构（比如 `Navigator` 之下的某个
           * 嵌套 `Navigator`），就会拿到**错误的那一个**。
           * 直接用 build 的 `context` 语义明确、不受结构影响。
           */
          onKeyEvent: (node, event) => _onKey(context, event),
          /*
           * ★ 内容带（t509）：原版 `SettingsView.vue:1612 <div class="container">`
           *   —— 原版**没有**二级页路由，所有面板（外观 / 内容源 / 同步 /
           *   备份 / 关于 / JS 插件 …）都在那**同一个** `.container` 之内
           *   （`src\router.ts:8-85` 只有 7 条路由，`settings` 是唯一一条设置路由）。
           *   Flutter 侧把它们拆成了 `Navigator.push` 的二级页
           *   （`settings_page.dart` 的 `_openSubPage`）⇒ 带必须在**每一页**
           *   各来一层；包在这里 = 一级/二级**同构**，两侧的
           *   `contentPadding` 也就都只算这一层（×1）。
           */
          child: Padding(
            padding: Layout.horizontalInsetOf(context),
            child: scrollBody == null
                ? _scrollingBody(context)
                : _pinnedBody(context),
          ),
        ),
      ),
    );
  }

  /// 页头（返回 + 标题 + 副标题）
  ///
  /// ★ 抽出来是因为两种结构都要用它（见 [scrollBody] 的说明）。
  ///   内容与**改前逐字相同**。
  ///
  /// ⚠️ 参数用 `ColorScheme`（不是 forui 的 `AppPalette`）——
  ///    改动前的原代码用的就是 `Theme.of(context).colorScheme`，
  ///    这里**不改配色来源**，避免引入视觉差异。
  ///    （也顺带免掉给本文件 import forui —— 少一个依赖面。）
  Widget _header(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // ★ 内容带（t509）：带已由 `build` 提供 ⇒ 这里归零。
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: _backButton(context),
          ),
          const SizedBox(height: Sp.x3),
          Text(
            title,
            style: TextStyle(
              fontSize: FontSizes.xl,
              fontWeight: FontWeights.semibold,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: Sp.x1),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: FontSizes.sm,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// **原行为**：整页一个 `ListView`（5 个页面走这条）
  ///
  /// # ★★★ task-44 ④：返回按钮改成 **sticky**（用户诉求）
  ///
  /// ## 用户原话
  /// ```text
  /// 4.进入二级页应该要优化交互,比如 返回一开始是在左上方,随着页面下滑,
  ///   然后固定在上面,而不是随着下滑,就看不到了
  /// ```
  ///
  /// ## 改前的问题（实测）
  /// 返回按钮是 `ListView` 的**第一个 child** ⇒ 跟着内容一起滚走。
  /// 实测（`test/task44_subpage_sticky_back_test.dart`）：
  /// ```text
  /// 滚动 200px 后 `find.text('返回设置')` = **null**（已不在树里）
  /// ⇒ ★ 与用户描述完全一致：「随着下滑，就看不到了」
  /// ```
  /// ★ 而本项目**自绘标题栏没有返回按钮**（见文件头长注释）⇒
  ///   返回按钮滚走 = 用户**出不去**（只能 Esc / Alt+← / 重开）。
  ///   ⇒ 这不只是"体验差"，是**可达性缺陷**。
  ///
  /// ## 为什么用 `SliverPersistentHeader(pinned: true)`
  /// ```text
  /// ① Flutter 的**惯用法**（用户说"参考 github 开源项目"）
  /// ② pinned 的语义就是"滚到哪都留在视口顶" —— 正是用户要的
  /// ③ 比"监听滚动偏移 + AnimatedPositioned 自己摆"稳：
  ///    后者要与滚动物理/回弹/焦点滚动打架，本项目已有 `spatial_nav`
  ///    的 `ensureVisible` 与滚轮互相干扰的前例（task-3）
  /// ```
  ///
  /// ## ⚠️ 为什么返回条要是**不透明**的
  /// ```text
  /// 它 pinned 在顶部、内容从**它下面**滚过 —— 若透明，
  /// 文字会与返回按钮叠在一起（那正是用户抱怨的"重叠"形态）。
  /// ⇒ 用 `colors.surface`（与页面底色同一来源，见 Scaffold）。
  /// ```
  ///
  /// ## ⚠️ 顶距为什么放在**返回条内部**（而不是外面）
  /// ```text
  /// `AppMetrics.homeTopPadding`（=20）原本是 ListView 的 padding.top。
  /// 若把它留在滚动区外，pinned 之后它会一直占 20px（滚下去也不收）；
  /// 放进返回条内部 ⇒ 它随 shrinkOffset **自然收掉**
  ///   （展开时 64px、吸顶后 44px）—— 与 GitHub / Material 的
  ///   "大标题收起"观感一致，且不引入额外状态。
  /// ```
  Widget _scrollingBody(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // ★ 内容带（t509）：带已由 `build` 那一层 `Padding` 提供 ⇒
    //   本方法内（返回条 / 标题 / 正文）**都不要再加横向内边距**，否则 ×2。
    return CustomScrollView(
      clipBehavior: Clip.antiAlias,
      slivers: [
        // ① 返回条（pinned ⇒ 永远留在视口顶）
        SliverPersistentHeader(
          pinned: true,
          delegate: _StickyBackBar(
            minExtent: _backBarMin,
            maxExtent: _backBarMin + AppMetrics.homeTopPadding,
            background: colors.surface,
            child: _backRow(context),
          ),
        ),
        // ② 标题 + 副标题（正常滚走）
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.zero,
            child: _titles(context),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: Sp.x6)),
        // ③ 正文
        SliverList(
          delegate: SliverChildListDelegate(children),
        ),
        // ④ 底部让位（悬浮底栏盖在所有路由之上）
        SliverToBoxAdapter(child: SizedBox(height: Sp.bottomBarInset)),
      ],
    );
  }

  /// 返回条的最小高度（按钮 36 + 上下各 4 的呼吸）
  static const double _backBarMin = 44;

  /// 只有返回按钮那一行（★ 不含标题 —— 标题在它下面的 sliver 里滚）
  Widget _backRow(BuildContext context) => Padding(
        // ★ 内容带（t509）：带已由 `build` 提供 ⇒ 这里归零。
        padding: EdgeInsets.zero,
        child: Align(
          alignment: Alignment.centerLeft,
          child: _backButton(context),
        ),
      );

  /// 「返回设置」按钮 —— **单点定义**（task-14 ⑤）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// # 借鉴了什么（FlClash）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// ```text
  /// .probe\refs\FlClash\lib\widgets\scaffold.dart
  ///   :351-391  Widget _buildLeadingButton(BuildContext context) {
  ///               final route = ModalRoute.of(context);
  ///               if (route?.impliesAppBarDismissal == false) {
  ///                 return const SizedBox();
  ///               }
  ///               return route?.fullscreenDialog == true
  ///                   ? CloseButton(...) : BackButton(...);
  ///             }
  /// ```
  /// FlClash 的 `CommonScaffold`（全项目 49 处使用）**只有这一处**画返回
  /// 控件，页头与页身都引用它 —— 而不是各画一份。
  ///
  /// # 我们为什么也要抽
  /// ```text
  /// 改前 [_header] 与 [_backRow] 各写了一份**逐字相同**的
  /// `OutlinedButton.icon(...)`。本次要给返回加 [onBack] 分层拦截 ——
  /// 两份写法就必须改两处，漏一处 = 「有的结构能分层返回、有的不能」
  /// 的静默不一致（而且只有 `scrollBody == null` 的页面会露馅）。
  /// ⇒ 抽成一个方法后，行为只有**一个**定义点。
  /// ```
  ///
  /// # ⚠️ 为什么**不**换成 SDK 的 `BackButton() / CloseButton()`
  /// ```text
  /// 那两个画的是 `IconButton`（**无文字、无边框**）。
  /// 我们的「返回设置」是**带文字的 OutlinedButton**，且文案被
  /// `test/task44_subpage_sticky_back_test.dart:172` 与
  /// `test/skip_page_search_test.dart:349` 断言为 `findsOneWidget`。
  /// 换成 `BackButton()` 是**用户可见的视觉回归** ——
  /// 本次只借鉴 FlClash 的**结构**（单点定义 + 可拦截），不换外观。
  /// ```
  ///
  /// # ⚠️ 为什么**不**用 `ModalRoute.impliesAppBarDismissal` 判空
  /// ```text
  /// FlClash 用它是为了「根路由不画返回」。我们这一层是
  /// `SettingsSubPage` **自己的**外壳，只可能被 push 成二级页
  /// （6 个调用方全是 `Navigator.push(MaterialPageRoute(...))`）⇒
  /// 判断永远为真，加它只是多一条死分支。
  /// ```
  Widget _backButton(BuildContext context) => OutlinedButton.icon(
        onPressed: () {
          // ★ 先问本页「这一层要不要自己消费」（见 [onBack]）
          if (onBack != null && onBack!(context)) return;
          Navigator.of(context).maybePop();
        },
        icon: const Icon(Icons.arrow_back, size: 18),
        label: const Text('返回设置'),
      );

  /// 标题 + 副标题（滚走的部分）
  ///
  /// ⚠️ 返回按钮**不在这里** —— 它已被提到上面的 pinned sliver。
  ///    若两边都画，页面上会出现**两个**「返回设置」（测试会 findsNWidgets(2)）。
  ///
  /// ★ task-44 ③：标题→副标题 从 `Sp.x1`(4px) 放宽到 `Sp.x2`(8px)，
  ///   与**一级页页头**同一取值 —— 两处都是 28px 大标题 + 14px 副标题，
  ///   间距不同会让"设置页"与"二级页"看起来不是同一套设计。
  Widget _titles(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: FontSizes.xl,
            fontWeight: FontWeights.semibold,
            color: colors.onSurface,
          ),
        ),
        const SizedBox(height: Sp.x2),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: FontSizes.sm,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// **新结构**：页头 + [pinnedHeader] 固定，只有 [scrollBody] 滚动
  ///
  /// # ⚠️ 为什么页头也固定在顶部（而不是让它滚走）
  ///
  /// ```text
  /// 用户要的是「搜索固定在上面，结果在下面滚动」。
  /// 若页头（返回/标题/副标题）滚走、搜索框留下 ——
  /// 搜索框会**顶到最上面**，用户失去"我在哪一页"的上下文；
  /// 而且返回按钮滚走 = 用户滚下去后**出不去**（本项目硬约束：
  /// 自绘标题栏没有返回按钮，返回只能靠页内这个）。
  /// ```
  /// ⇒ 页头 + [pinnedHeader] 一起固定，只有结果区滚动。
  Widget _pinnedBody(BuildContext context) => Column(
        children: [
          Padding(
            padding: EdgeInsets.only(top: AppMetrics.homeTopPadding),
            child: _header(context),
          ),
          const SizedBox(height: Sp.x4),
          if (pinnedHeader != null) pinnedHeader!,
          const SizedBox(height: Sp.x2),
          Expanded(child: scrollBody!),
        ],
      );

  /// 键盘 / 遥控器返回
  ///
  /// # ⚠️ 我第一版写错了：只 `return handled` 但**没有真的 pop**
  ///
  /// ```dart
  /// if (k == escape) return KeyEventResult.handled;   // ← 错的
  /// ```
  /// `handled` 只是"告诉框架这个键我处理了，别往下传"——
  /// **它本身不做任何事**。必须自己调 `pop`，否则用户按 Esc 毫无反应，
  /// 而且更糟：因为返回了 `handled`，连系统默认的返回行为也被吞掉了。
  ///
  /// ⚠️ 用 `maybePop` 而不是 `pop`：`maybePop` 在没有可弹出的路由时
  ///    **什么都不做**（而不是抛异常）。二级页理论上总在设置页之上，
  ///    但用户可能用 Alt+← 或其它方式先弹掉了，这时再按 Esc 不该崩。
  ///
  /// ⚠️ 只接 `KeyDownEvent` —— 长按 Esc 会产生一串 `KeyRepeatEvent`，
  ///    不判的话会连续 pop 多层（用户只想退一层，结果退到首页了）。
  KeyEventResult _onKey(BuildContext context, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.goBack) {
      /*
       * ★ 分层返回（task-14 ⑤）—— 先退**内层**，再退页面。
       *   范式来自 FlClash `scaffold.dart:497-500` 的
       *   `BackLayerScope(onBack: _handleExitAppBarLayer)`：
       *   它的页面可以有搜索层 / 多选层，返回键先退最上面那一层。
       *   [onBack] 返回 true = 本层已消费 ⇒ 这里必须 `return handled`
       *   而**不能**继续 pop（否则会「清空搜索 + 同时退出页面」，
       *   比改前更糟）。
       *   [onBack] == null（6 个既有调用方）⇒ 与改前**逐字相同**。
       */
      if (onBack != null && onBack!(context)) return KeyEventResult.handled;
      // ★ 真的返回 —— 见上面那段"我第一版写错了"
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

/// 吸顶返回条的 delegate（task-44 ④）
///
/// # 为什么单独一个类
/// `SliverPersistentHeader` 要求 `SliverPersistentHeaderDelegate` 的实现，
/// 而它的 `shouldRebuild` 必须**如实**回答"要不要重建" ——
/// 写在页面里会让 `build` 内联一个匿名类，无法复用到 [SettingsSubPage._pinnedBody]。
///
/// # ⚠️ `shouldRebuild` 为什么比较这三个字段
/// ```text
/// 只比较 child 的 **identity** 就够了吗？—— 不够：
///   本 delegate 的 `maxExtent` 依赖 `AppMetrics.homeTopPadding`，
///   而那是 `Device.isTv` 的 getter（TV 与桌面可能不同）。
/// ⇒ 把 background / extent 一起比，避免"设备类型变了但条没重建"。
/// ```
class _StickyBackBar extends SliverPersistentHeaderDelegate {
  _StickyBackBar({
    required this.minExtent,
    required this.maxExtent,
    required this.background,
    required this.child,
  });

  @override
  final double minExtent;

  @override
  final double maxExtent;

  /// 条的**不透明**底色 —— 内容会从它下面滚过（透明会让文字叠在一起）
  final Color background;

  final Widget child;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    /*
     * ★ 收起量 = `shrinkOffset`（0 = 完全展开，maxExtent-minExtent = 完全收起）
     *
     * 高度 = maxExtent - shrinkOffset，但**不小于 minExtent**：
     * `SliverPersistentHeader` 理论上保证 shrinkOffset ∈ [0, max-min]，
     * 这里 clamp 是**防御性**的 —— 若将来 Flutter 改了语义，
     * 也不会算出负高度（负高度会直接抛异常，比视觉错更糟）。
     */
    final h = (maxExtent - shrinkOffset).clamp(minExtent, maxExtent);
    /*
     * 顶部呼吸随收起量**线性收掉**：
     *   展开时 = homeTopPadding（20）；吸顶后 = 0。
     * ⇒ 这样它不占"永远都在的 20px"，又与原来的视觉起点一致。
     */
    final padTop = ((maxExtent - shrinkOffset) - minExtent)
        .clamp(0.0, maxExtent - minExtent);

    return Container(
      height: h,
      color: background,
      padding: EdgeInsets.only(top: padTop),
      alignment: Alignment.centerLeft,
      child: child,
    );
  }

  @override
  bool shouldRebuild(covariant _StickyBackBar old) =>
      old.minExtent != minExtent ||
      old.maxExtent != maxExtent ||
      old.background != background ||
      old.child != child;
}
