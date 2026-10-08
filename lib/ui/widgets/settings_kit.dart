// ═══════════════════════════════════════════════════════════════════════
//  设置页**共用零件**（区块外壳 / 手势控件 / 信息行 / 二级页入口行）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要把这些从 `settings_page.dart` 里抽出来（2026-09-25 任务 ㉙）
//
// 用户拍板「方案 A」：把 5 个低频区块拆成**二级页面**。
// 那些二级页在新文件里，而它们要用到的这些控件原本是
// `settings_page.dart` 的**私有类**（`_Block` / `_GestureToggle` …）
// —— 私有类跨文件用不了，所以必须公开并搬到这里。
//
// # ⚠️ 为什么用 `typedef` 而不是改所有调用点
//
// `settings_page.dart` 里有 **10 处** `_Block(...)` 调用（含用户最在意的
// 「JS 插件」区块）。全部改名成 `SettingsBlock(...)` 是纯机械改动，
// 但那个文件**有并发写入者**（task-6 在改插件更新 UI）——
// 动得越多，冲突面越大。
//
// 所以 `settings_page.dart` 那边只留一行别名：
// ```dart
// typedef _Block = SettingsBlock;
// ```
// **调用点一个字都不用改**，而定义只有一份（这里）。
//
// ⚠️ 代价：`test/provider_reorder_cards_test.dart` 里那条
//    「`_Block.boxed` 默认 true」断言原本在 `settings_page.dart` 里找
//    `this.boxed = true` —— 定义搬走后要**跟着搬到这个文件**。
//    这正是项目铁律⑥「断言跟着实际承担者走」，不是把定义搬回去。

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

// ═══════════════════════════════════════════════════════════════════════
//  区块外壳
// ═══════════════════════════════════════════════════════════════════════

/// 设置页一个区块的外壳（标题行 + 可选块头附加层 + 内容外框）
///
/// 原名 `_Block`，2026-09-25 拆二级页时公开并搬到这里。
///
/// # ★★★ 2026-10-01：块头在窄屏改为**上下两行**（Owner 报「排版混乱」）
///
/// 症状（手机 1080x2400 @420dpi ⇒ 逻辑宽 **411 dp**，
/// 减去 `AppMetrics.contentPadding` 两边各 24 ⇒ 内容区只有 **363 dp**）：
/// ```text
/// 局域网遥控                     手机浏览器遥控，不用装 App
/// ^^^^^^^^^^ 标题(lg=20)          ^^^^^^^^^^^^^^^^^^^^^^^^ trailing(cap=12)
/// ```
/// 两者共 363 dp，标题 + `Spacer` + trailing 一挤 ⇒ **trailing 只能折成
/// 竖排两三行**，或者把标题挤成碎片。这就是"排版混乱"的主要来源。
///
/// ★ 这个坑 `headerExtra` 的文档里**早就写着**（`:72-76`）：
/// > **不能**把它塞进 `trailing` —— 那是标题**同一行**的右侧
/// > （`Row` + `Spacer`）。5 个按钮塞进去会把标题挤成一行碎片，
/// > **窄屏直接溢出**；原版也是分两行（`.head__acts` 在窄屏 `width: 100%`
/// > 换到标题下方）。
/// ⇒ 原版 Vue **在窄屏就是换成两行的**，我们漏了这一步。
///
/// # 判据为什么用 `MediaQuery` 而不是 `LayoutBuilder`
///
/// ★ **本文件不得出现 `LayoutBuilder`** ——
/// `test/provider_grid_responsive_test.dart:618` 钉着这条：
/// 「内容源卡片在 `IntrinsicHeight` 子树里，卡片自己量宽度会让 intrinsic
/// 查询撞上它 → `LayoutBuilder does not support returning intrinsic
/// dimensions` → 点设置页就抛」。设置页的卡片是这个块的**后代**，
/// 所以这里也不行。（历史真 bug，有回归测试守着。）
///
/// ⇒ 用 `MediaQuery.sizeOf(context).width`。它拿的是**整页**宽度而不是
/// 本块可用宽度，但判据只用来决定"标题与 trailing 是否同行"，
/// 而本块宽度 = 页宽 − 2×24 是**固定**关系 ⇒ 用页宽判是安全的。
class SettingsBlock extends StatelessWidget {
  const SettingsBlock({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
    this.headerExtra,
    this.boxed = true,
  });

  /// 窄屏阈值（dp）：页宽低于它时，块头 trailing **换到标题下方**
  ///
  /// # 这个数是怎么来的（**算出来的，不是试出来的**）
  /// ```text
  /// 手机 1080x2400 @420dpi          → 逻辑宽 411 dp   ← 实测 wm size / wm density
  /// 411 − 2×AppMetrics.contentPadding(24) = 363 dp 内容区
  /// ★ 取 480：留出 480−411 = 69 dp 余量给
  ///   "标题长一点 / trailing 长一点 / 用户系统字体调大" 三种情况。
  ///   360 太紧（411 的手机上一旦 trailing 长就还是挤），600 会把手机
  ///   与小平板一起判成窄屏（那些机器 363~550 dp 其实同行放得下）。
  /// ```
  /// ★ 与 `live_page` 的 `isNarrow = width < 900`（那一页要换整个
  ///   播放器布局，判据自然更宽）**不是**同一个量，别互相套用。
  static const double kNarrowHeaderWidth = 480;

  final String title;
  final Widget? trailing;
  final List<Widget> children;

  /// 块头**标题行之下、内容之上**额外的一层（默认 `null` = 不加）
  ///
  /// # ★ 2026-09-25 新增：为什么需要它
  ///
  /// 合并「内容源 + JS 插件」时，原版把 **5 个按钮**和**插件目录提示**
  /// 都放在块头里（`SettingsView.vue:1711-1742` 的 `.head__acts`
  /// 与 `.plug__hint`）—— 它们在**标题行下面**，但在**卡片列表上面**：
  ///
  /// ```text
  /// JS 插件  [外置] [26 个]              ← Row（title + trailing）
  /// [调整顺序][健康检测][导入源] │ [重新加载][从网址安装][粘贴源码安装]
  /// 放在 plugins/ 下的 .js 文件，能打开看、能自己改
  /// ┌──────────────────────────────┐
  /// │ 次元城动画  [JS 插件] [v1.0.0] │     ← children 从这里开始
  /// └──────────────────────────────┘
  /// ```
  ///
  /// ⚠️ **不能**把它塞进 `trailing` —— 那是标题**同一行**的右侧
  ///    （`Row` + `Spacer`）。5 个按钮塞进去会把标题挤成一行碎片，
  ///    窄屏直接溢出；原版也是分两行（`.block__head` 是
  ///    `justify-content: space-between`，`.head__acts` 在窄屏
  ///    `width: 100%` 换到标题下方）。
  ///
  /// ⚠️ 也**不能**放进 `children` 开头 —— `children` 在 `boxed: false`
  ///    时是裸露的（没有外框），而块头这一层属于"区块的头部"，
  ///    语义上该跟标题绑在一起。分开两个参数，改动面最小：
  ///    **其它 10 个 `SettingsBlock` 调用不传就是 `null`，一个像素都不变。**
  final Widget? headerExtra;

  /// 是否把内容包进**一层外框**（默认 `true`，保持既有视觉不变）
  ///
  /// # ★ 2026-09-25 新增：为什么「内容源」区块要关掉它
  ///
  /// 用户原话：
  /// > 内容源做成卡片式的
  ///
  /// # 之前长什么样（用户为什么这么说）
  ///
  /// `_ProviderCard` 自己**早就有**圆角 + 边框 + 底色（不是没做成卡片），
  /// 问题是它又被塞进了这里的外框里 —— **盒子套盒子**：
  ///
  /// ```text
  /// ┌─ 内容源 ────────────────────────────────────────────┐  ← 外层 Container
  /// │  ┌───────────────────────────────────────────────┐  │
  /// │  │ 次元城动画  [JS 插件] [v1.0.0]   编辑 停用 🗑 │  │  ← _ProviderCard
  /// │  └───────────────────────────────────────────────┘  │
  /// │  ┌───────────────────────────────────────────────┐  │
  /// ```
  /// 读起来是「一个大列表里装了 26 行」，而不是「26 张卡片」。
  ///
  /// ⚠️ **只对「内容源」关**。其它区块（JS 插件 / 手势 / 遥控 …）的
  ///    内容不是卡片列表，它们需要外框来分组 —— 默认值 `true` 保证
  ///    那些区块**一个像素都不变**。
  final bool boxed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * ★★★ 2026-10-01：窄屏把 trailing 换到标题**下方**（见类文档）
     *
     * 宽屏：`局域网遥控 ………………… 手机浏览器遥控，不用装 App`（同行，右侧）
     * 窄屏：`局域网遥控` 换行 `手机浏览器遥控，不用装 App`（两行，左对齐）
     *
     * ⚠️ 宽屏分支必须与改动前**逐像素一致** —— 仍是 `Row` + `Spacer`
     *    + `trailing!`，一个字都没动。只有窄屏才多一层 `Column`。
     */
    final narrow =
        MediaQuery.sizeOf(context).width < SettingsBlock.kNarrowHeaderWidth;

    final titleText = Text(
      title,
      style: TextStyle(
        fontSize: FontSizes.lg,
        fontWeight: FontWeight.w600,
        color: colors.onSurface,
      ),
    );

    final Widget header;
    if (narrow) {
      /*
       * 窄屏：标题一行，trailing 一行（左对齐）。
       * ★ 用 `SizedBox(height: Sp.x1)`（4dp）而不是 `Sp.x2` ——
       *   两行文字本来就需要视觉上的"同一组"感，间距大会读成两个区块。
       * ★ 用 `crossAxisAlignment.start`（不是 `stretch`）——
       *   trailing 里的文字块宽度随内容，不该被拉满。
       */
      header = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleText,
          if (trailing != null) ...[
            const SizedBox(height: Sp.x1),
            trailing!,
          ],
        ],
      );
    } else {
      header = Row(
        children: [
          titleText,
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      );
    }

    final inner = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );

    /*
     * ★ 内容带（t509）：左右那两层 `AppMetrics.contentPadding`(24) **已去掉**。
     *
     * 原版 `SettingsView.vue:1612` 只有一个 `<div class="container">`，
     * 其内部（含 `.settings-block`）**没有任何横向 padding**
     *   —— 实测 `dist\assets\SettingsView-BE6jt733.css` 220 条顶层规则里
     *   `container` / `settings-block` / `section` 命中数**全为 0**，
     *   只有对话框用的 `.pcfg` / `.modal` 那类才自带 `padding: var(--sp-6)`。
     * ⇒ 那 24 全部来自 `.container` 那一层。
     *
     * Flutter 侧那一层现在由页面根提供
     * （一级页 `settings_page.dart` 的 `ListView.padding`；
     *   二级页 `SettingsSubPage.build` 的外层 `Padding`）。
     * 若这里再留 24 ⇒ **×2 = 48**。
     *
     * ⚠️ `top` **必须仍是 0** —— 块间距靠"前一块的 bottom(Sp.x8)"撑开，
     *    见 `test\task44_header_spacing_test.dart:187-205`（反向守卫）。
     */
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: Sp.x4),
          /*
           * ★ 块头附加层（默认 null，其它区块一个像素都不变）
           *
           * 放在**标题行之后、内容之前** —— 见 `headerExtra` 的说明。
           * ⚠️ 间距用 `Sp.x4`（与标题行一致），且它**自带**尾部间距
           *    （调用方在它内部放 `SizedBox(height: Sp.x3)`）——
           *    这里不再补 `SizedBox`，否则 `boxed: false` 的区块
           *    会多出一段说不清来源的空白。
           */
          if (headerExtra != null) ...[
            headerExtra!,
            const SizedBox(height: Sp.x4),
          ],
          if (!boxed)
            inner
          else
            Container(
              padding: const EdgeInsets.all(Sp.x4),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: Radii.rLg,
                border: Border.all(color: colors.outlineVariant),
              ),
              child: inner,
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  手势控件
// ═══════════════════════════════════════════════════════════════════════

/// 手势开关行（标签 + 说明 + Switch）
///
/// 原名 `_GestureToggle`。
class SettingsGestureToggle extends StatelessWidget {
  const SettingsGestureToggle({
    super.key,
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                hint,
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: Sp.x3),
        // 用 Switch 而不是自定义控件 —— 系统语义（无障碍朗读会用上）
        Switch(
          value: value,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// 手势参数选择（一行几个 pill，选中高亮）
///
/// 泛型是为了 int（秒数）和 double（倍率）共用 —— 两者的 UI 完全一样，
/// 只是显示文本不同（由 `labelOf` 提供）。
///
/// 原名 `_GestureChoice`。
class SettingsGestureChoice<T> extends StatelessWidget {
  const SettingsGestureChoice({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.labelOf,
    required this.onChanged,
  });

  final String label;
  final List<T> options;
  final T value;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Sp.x2),
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            for (final o in options)
              SettingsGesturePill(
                text: labelOf(o),
                selected: o == value,
                onTap: () => onChanged(o),
              ),
          ],
        ),
      ],
    );
  }
}

/// 一颗药丸（选中高亮）
///
/// 原名 `_GesturePill`。
///
/// ⚠️ **本体不得加玻璃**（`GlassContainer`）—— 它被手势配置**多处复用**，
///    而用户只要求改「主题」那一块。玻璃包在**调用方**的容器上
///    （见 `theme_page.dart`），见 `task16_glass_autorefresh_test.dart`
///    里那条断言。
class SettingsGesturePill extends StatelessWidget {
  const SettingsGesturePill({
    super.key,
    required this.text,
    required this.selected,
    required this.onTap,
  });

  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x4,
          vertical: Sp.x2,
        ),
        decoration: BoxDecoration(
          color: selected ? colors.primary : colors.secondary,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? colors.primary : colors.outlineVariant,
            width: 1,
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: FontSizes.cap,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected
                ? colors.onPrimary
                : colors.onSurface,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  信息行 / 入口行
// ═══════════════════════════════════════════════════════════════════════

/// 一行「标签 : 值」（用于「关于」区块）
///
/// 原名 `_InfoRow`。
class SettingsInfoRow extends StatelessWidget {
  const SettingsInfoRow({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: TextStyle(
                fontSize: FontSizes.sm,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: FontSizes.sm,
                color: colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一级页上的**二级页入口行**（2026-09-25 任务 ㉙ 新增）
///
/// # 用户要求
///
/// > 我希望设置页，**这几个功能，拆分到二级页面**，而不是在一级
///
/// 方案 A 把 5 个低频区块搬进二级页，一级页原位留一行入口：
///
/// ```text
/// ┌────────────────────────────────────────────┐
/// │ 片头片尾                                ›  │   ← 标题（base）
/// │ 已配置 3 个作品 · 查看 / 管理              │   ← 副标题（cap，次要色）
/// └────────────────────────────────────────────┘
/// ```
///
/// # 为什么做成「整行可点」而不是「标题 + 右边一个小按钮」
///
/// ```text
/// ① 整行命中区大得多 —— 鼠标/触摸都好点（本项目一贯要求 ≥32px 命中）
/// ② 与「设置项列表」的通行心智一致（iOS/Android/Material 都是整行可点）
/// ③ 右侧 `›` 是**可点的信号**，用户一眼知道"点进去还有东西"
/// ```
///
/// ⚠️ 用 `InkWell` + `Material` 的组合 —— `InkWell` 需要祖先里有
///    `Material` 才能画出涟漪。设置页外层是 `Scaffold`（自带 `Material`），
///    但二级页可能不是，所以这里**自带一层 `Material`** 保底
///    （`type: MaterialType.transparency` 不改变视觉）。
class SettingsEntryRow extends StatelessWidget {
  const SettingsEntryRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // ★ 内容带（t509）：左右那两层已去掉（理由同 `SettingsBlock`）。
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x3),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: Radii.rLg,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Sp.x4,
              vertical: Sp.x3,
            ),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: Radii.rLg,
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: FontSizes.base,
                          fontWeight: FontWeights.regular,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: FontSizes.cap,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Sp.x2),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一级页上的**分组小标题**（"播放与观看" / "数据与外观"）
///
/// 5 个入口行平铺会显得散，分两组让用户扫起来有结构。
class SettingsGroupLabel extends StatelessWidget {
  const SettingsGroupLabel({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // ★ 内容带（t509）：左右那两层已去掉（理由同 `SettingsBlock`）。
    return Padding(
      padding: const EdgeInsets.only(top: Sp.x3, bottom: Sp.x2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: FontSizes.cap,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
