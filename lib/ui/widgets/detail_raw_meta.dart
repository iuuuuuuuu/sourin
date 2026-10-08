// ═══════════════════════════════════════════════════════════════════════
//  详情页的线路选择器（支持任意深度嵌套）
// ═══════════════════════════════════════════════════════════════════════
//
// # 本文件的历史（**绕行已撤除，根因已修**）
//
// 这里原本是「原始 JSON 读取层」—— 因为 `models.dart` 的 `PlaySource`
// 三个键名全错、`MediaDetail` 缺 `badges` / `meta`，所以它自己按 Rust
// 真名读原始 JSON，并定义了 `DetailSourceNode` / `DetailRawMeta` /
// `parseDetailSources` / `sourcesFromModels` 一整套**平行的类型**。
//
// 那层绕行**已经撤掉**：`models.dart` 的根因修好了（`PlaySource` 补上
// `title` / `count` / `nested`，`MediaDetail` 补上 `badges` / `meta`）。
//
// ★ 为什么必须撤（不是"能用就行"）：
// ```text
// 留着就是仓库里的**第二份契约** ——
// 以后 Rust 改了字段名，两处都要改，而漏掉哪一处都不报错。
// 那正是这个文件原本要修的那类静默 bug，不能自己再造一个。
// ```
// 前两批（`ProxyCfg` / `_call`）也是这么处理的：**没有留兼容层**。
//
// 现在这里只剩**纯渲染**：`DetailSourcePicker` + `_Level` + `_SourceButton`，
// 数据一律用 `models.dart` 的 `PlaySource`。
//
// # 与原版 `SourcePicker.vue` 的逐条对应
//
// | 原版（SourcePicker.vue） | 这里 |
// |---|---|
// | `:35` `visible = sources.length > 1` 单选项隐藏该层 | [_Level] 的 `_show` |
// | `:38-44` 收集所有子层的 `nested` 平铺成下一层 | [PlaySource.nested] 直接用 |
// | `:49-52` `containsActive` 命中子树即高亮 | [_Level] 的 `_containsActive` |
// | `:60-69` `s.title \|\| s.code` + `v-if="s.count"` 角标 | [PlaySource.label] / `count > 0` |
// | `:74-80` 递归渲染子层 | [_Level] 递归 `_Level` |
//
// ⚠️ 原版把「所有父项的子线路**合并**成一个平铺层」（`:38-44`），
//    而不是"点开某一项才展开它的子层"。这里**照抄合并**——
//    否则交互就与原版不一致了（原版没有"展开/收起"这个概念）。

import 'package:material_ui/material_ui.dart';

import '../../core/models.dart';
import '../tokens.dart';
import 'motion_prefs.dart';

/// 线路选择器（支持任意深度嵌套）
class DetailSourcePicker extends StatelessWidget {
  const DetailSourcePicker({
    super.key,
    required this.sources,
    required this.active,
    required this.onPick,
  });

  /// 顶层线路
  final List<PlaySource> sources;

  /// 当前选中的 code（任意层级）
  final String active;

  /// 用户点了某一项（可能是嵌套里的）
  final ValueChanged<PlaySource> onPick;

  @override
  Widget build(BuildContext context) {
    return _Level(
      sources: sources,
      active: active,
      depth: 0,
      onPick: onPick,
    );
  }
}

/// 一层线路 + 它下面的所有层
class _Level extends StatelessWidget {
  const _Level({
    required this.sources,
    required this.active,
    required this.depth,
    required this.onPick,
  });

  final List<PlaySource> sources;
  final String active;
  final int depth;
  final ValueChanged<PlaySource> onPick;

  /// 单选项的层**不渲染**（原版 `SourcePicker.vue:35`）
  bool get _show => sources.length > 1;

  /// 收集所有子线路，合并成下一层（原版 `:38-44`）
  List<PlaySource> get _children => [
        for (final s in sources) ...s.nested,
      ];

  /// 该项自己或其子树里含选中项（原版 `:49-52`）
  bool _containsActive(PlaySource s) {
    if (s.code == active) return true;
    return s.nested.any(_containsActive);
  }

  @override
  Widget build(BuildContext context) {
    final children = _children;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_show)
          Padding(
            // 非首层缩进，让"层级"看得见（原版靠 CSS 的 `.src-level` 间距区分）
            padding: EdgeInsets.only(
              left: AppMetrics.contentPadding + depth * Sp.x4,
              right: AppMetrics.contentPadding,
              bottom: Sp.x3,
            ),
            child: Wrap(
              spacing: Sp.x2,
              runSpacing: Sp.x2,
              children: [
                for (final s in sources)
                  _SourceButton(
                    label: s.label,
                    count: s.count,
                    active: _containsActive(s),
                    onTap: () => onPick(s),
                  ),
              ],
            ),
          ),

        // 递归：子层
        if (children.isNotEmpty)
          _Level(
            sources: children,
            active: active,
            depth: depth + 1,
            onPick: onPick,
          ),
      ],
    );
  }
}

/// 一条线路的按钮
///
/// ⚠️ 这里**必须**用 `Material` 包一层
///
/// `InkWell` 需要一个 `Material` 祖先来画水波纹。详情页是
/// `Scaffold(body: ...)`，本身有 `Material`，但换源弹层之类的宿主
/// 不一定有 —— 缺了会抛 `No Material widget found`。
/// 自己包一层最稳，代价只是一个透明的 `Material`。
class _SourceButton extends StatelessWidget {
  const _SourceButton({
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.rMd,
        /*
         * ★ task-50 候选 C3：选中态用**隐式动画**过渡（原来是硬切）
         *
         * # 为什么这一处值得加（判据①）
         * ```text
         * 换源是详情页的**高频动作**，而"点一下"的反馈就是这条按钮本身：
         * 底色（透明 → 品牌色 18%）、描边（outlineVariant → 品牌色）
         * 与字重同时变化。硬切时用户会觉得"没点上"，从而**重复点击**。
         * ⇒ 目的 = **反馈操作**（不是"为了好看"）。
         * ```
         *
         * # 为什么是 `AnimatedContainer` 而不是 `AnimatedScale`（判据⑤）
         * ```text
         * 这里变的是**装饰**（颜色/描边），`AnimatedContainer` 正是
         * 为"装饰补间"设计的专用组件 ⇒ 最贴切的惯用法。
         * ★ 且它**不插 `Transform`**（`AnimatedScale` 会）⇒ 不会影响
         *   任何按 `Transform` 做断言的既有测试。
         * ```
         *
         * # 时长 150ms（判据②③④）
         * ```text
         * `Motion.fast` = 150ms —— 换源是高频操作，走最低档。
         * 隐式动画**天然可打断**（判据③）：连点两条线路，第二次会从
         * **当前中间值**继续补间，不会"排队播完"。
         * `MotionPrefs` 包一层 ⇒ 系统开「减少动态效果」时
         * `Duration.zero`（判据④）—— 状态仍在，只是无过渡。
         * ```
         */
        child: AnimatedContainer(
          duration: MotionPrefs.duration(context, Motion.fast),
          curve: MotionPrefs.curve(context, Motion.easeOut),
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.symmetric(
            horizontal: Sp.x4,
            vertical: 9,
          ),
          decoration: BoxDecoration(
            color: active ? colors.primary.withValues(alpha: 0.18) : null,
            borderRadius: Radii.rMd,
            border: Border.all(
              color: active ? colors.primary : colors.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color:
                        active ? colors.primary : colors.onSurfaceVariant,
                  ),
                ),
              ),
              // ★ 集数角标 —— 原版 `v-if="s.count"`，0 就**不显示**
              //   （0 的语义是"该源没报集数"，不是"有 0 集"）
              if (count > 0) ...[
                const SizedBox(width: Sp.x2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest.withValues(
                      alpha: 0.6,
                    ),
                    borderRadius: Radii.rFull,
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
