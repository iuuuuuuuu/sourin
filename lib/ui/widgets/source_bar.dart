// ═══════════════════════════════════════════════════════════════════════
//  多源切换条 —— 对齐原版 SourceBar.vue
// ═══════════════════════════════════════════════════════════════════════
//
// # 它管什么
//
// 「**下面的内容区显示哪个源**」—— 通栏横排，放在「我的」之后、
// 内容之前。位置上贴着内容，而不是贴着页头。
//
// # ★ 只有一个源时**自己隐藏**
//
// 原版 `visible` 计算属性：`sources.length > 1` 才显示。
// 理由：只有一个源时这一条是纯噪音（占一行却没有可切换的东西）。
//
// # 为什么用横向滚动而不是下拉
//
// 源可能有 20+ 个，下拉要多两次点击；横向条一次点击直达，
// 而且当前选中项**始终可见**（滚动位置自动跟随）。

import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import '../../core/sourin_api.dart';
import '../../ui/app_palette.dart';

/// ★★★ 源条的**可见性判据** —— 照抄原版 `stores/app.ts` 的 `enabledProviders`
///
/// # 原版那个真 bug（务必照抄语义，不要"简化"）
///
/// 原版 `src/stores/app.ts:259-283` 的注释原文：
/// > ## ⚠️ 这里曾是一个真 bug：用了 `working` 而不是 `enabled`
/// >
/// > 两个字段是**完全不同**的东西：
/// >
/// > | 字段 | 含义 | 谁能改 |
/// > |---|---|---|
/// > | `working` | **站点自身**是否可用（探测出来的）| 用户改不了 |
/// > | `enabled` | **用户**是否要使用它（持久化的偏好）| 用户的选择 |
/// >
/// > 原实现用 `working` 过滤 —— 后果：**用户在设置里停用的源
/// > 仍然出现在首页/搜索/直播里**（`enabled=false` 被完全忽略）。
/// >
/// > 实测证据：停用 cctv 后 `get_provider_enabled('cctv')` 返回 `false`，
/// > 但首页的切换条里它还在，`list_providers` 也把它算作可用。
/// >
/// > 修法：`working` 与 `enabled` **都要**满足。
/// > `enabled` 缺省（undefined）时按启用处理 —— 兼容老数据，
/// > 且内置源若没写这个字段也不会被误判为停用。
///
/// 也就是判据必须是**两个条件的合取**：
/// ```text
/// working && enabled !== false
///   ↑ 站点能用    ↑ 用户要它（缺省 = 要）
/// ```
///
/// # ⚠️ 为什么写成 `enabled != false` 而不是直接 `enabled`
///
/// 这就是原版那个 `!== false` 的字面翻译，而且它**对未来是稳的**：
/// ```text
/// 现在  models.dart: bool  enabled（非空，缺省 true）→ 两者等价
/// 将来  若改成 bool?（Z 正在改 models.dart）
///       · `p.enabled`        → 编译不过 / 或 null 被当 false 用 ✗
///       · `p.enabled != false` → null != false → true = 启用 ✓
/// ```
/// 后者的语义正好是原版要的「缺省按启用处理」。
///
/// ⚠️ **不要**把这里改成只看 `enabled`：那会让 `working=false` 的
///    坏源继续留在切换条里（用户点了没内容，且不知道原因）。
bool sourceIsUsable(ProviderManifest p) => p.working && p.enabled != false;

/// 从源列表里挑出**该出现在切换条里的**那些（顺序保持不变）
///
/// ⚠️ 顺序**原样保留** —— 那是用户保存的排序（`provider-order.json`），
///    前端绝不能再 sort 一次（原版 `loadProviders` 注释强调过）。
List<ProviderManifest> visibleSourceList(List<ProviderManifest> all) =>
    all.where(sourceIsUsable).toList();

/// 源切换条
class SourceBar extends StatefulWidget {
  const SourceBar({
    super.key,
    required this.sources,
    required this.current,
    required this.onSelect,
    this.focusedIndex = -1,
  });

  /// 可切换的源（**已启用的**，顺序即显示顺序）
  ///
  /// ⚠️ 调用方传进来的可能仍含**不该显示的**源（`enabled=false` 或
  ///    `working=false`）—— 本组件在渲染前**自己再过一遍**
  ///    [visibleSourceList]（见 [visible]）。这样"什么该显示"
  ///    只有**一处**判据，不依赖每个调用方都记得过滤。
  final List<ProviderManifest> sources;

  /// 当前选中的源 id
  final String current;

  final ValueChanged<String> onSelect;

  /// TV 遥控：当前聚焦的下标（-1 = 无）
  final int focusedIndex;

  @override
  State<SourceBar> createState() => _SourceBarState();
}

class _SourceBarState extends State<SourceBar> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(SourceBar old) {
    super.didUpdateWidget(old);
    // 选中项变化时让它滚进可视区（否则用户在 20 个源里点了最后一个，
    // 选中的那个可能在屏幕外，看起来像"没反应"）
    if (old.current != widget.current) {
      _scrollToCurrent();
    }
  }

  void _scrollToCurrent() {
    /*
     * ⚠️ 下标必须算在**过滤后**的列表上（任务 AE）
     *
     * 渲染用的是 `_visible`，所以"第几个药丸"也得按 `_visible` 数。
     * 用 `widget.sources` 数的话，只要前面有被停用的源，
     * 下标就会**偏大** —— 选中项被滚过头（实测：停用 3 个后偏 3 个位置）。
     */
    final i = _visible.indexWhere((s) => s.id == widget.current);
    if (i < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_controller.hasClients) return;
      // 每个 chip 估算宽度（原版是自适应宽度，这里按内容估）
      const approx = 108.0;
      final target = (i * approx) - 120;
      _controller.animateTo(
        target.clamp(0, _controller.position.maxScrollExtent),
        duration: Motion.base,
        curve: Motion.easeOut,
      );
    });
  }

  /// ★ 真正要渲染的源 —— **已停用的不在里面**
  ///
  /// # 这就是原版修掉的那个 bug 的落点
  ///
  /// 原版实测：停用 cctv 后 `get_provider_enabled('cctv')` 返回 `false`，
  /// 但首页切换条里**它还在**（旧实现只看 `working`）。
  ///
  /// ⚠️ 过滤放在**组件内部**而不是只靠调用方传干净的列表：
  ///    调用方有首页/直播/搜索多处，漏一处那个 bug 就回来 ——
  ///    这正是原版把它收进 store 计算属性的理由（"集中判定才不会漏"）。
  List<ProviderManifest> get _visible => visibleSourceList(widget.sources);

  /// 是否显示源数量（原版 `showCount`）
  ///
  /// > 源少时不显示 —— 3 个源一眼就数完了，
  /// > 再挂一个"3 个源"是纯噪音。
  ///
  /// ⚠️ 用**过滤后**的数量 —— 否则会出现「停用了 5 个源，
  ///    条上只剩 2 个药丸，右下角却写着 7 个源」这种自相矛盾。
  bool get _showCount => _visible.length > 3;

  @override
  Widget build(BuildContext context) {
    final sources = _visible;

    // ★ 只有一个源时不显示（原版 `visible` 的逻辑）
    if (sources.length <= 1) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 源条 = **一个悬浮胶囊容器**（2026-09-24 第二次修正）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 上面那两个液态玻璃,跟底部的液态玻璃样式根本就不一样
     *
     * # 我第一版错在哪（结构错，不是参数错）
     *
     * 给**每个源 pill** 各套一块 `GlassContainer` ——
     * 于是 25 个源 = 25 块独立玻璃，看起来像一排小胶囊，
     * 而底栏是"一条大玻璃"。
     *
     * 原版 `SourceBar.vue` 的注释把这件事讲得很明白：
     * > ★★ 方案 A：悬浮胶囊（与底部 tab 栏同款造型）
     * > 之前是"满宽矩形横板"（1224px × 45px、border-radius: 0、
     * > 带硬底边线），与软件里其它同类控件（底部 tab 栏、「我的」
     * > 分段控件）完全不是一套语言。
     * > 现在改成：**内容宽度 + 居中 + 全圆角 + 玻璃**。
     * > 好处是**用户不用学新东西** —— 底部那条 tab 栏就在它正下方，
     * > 两个胶囊上下呼应。
     *
     * 所以结构是（与 `.mine__tabs` 完全同构）：
     * ```text
     * GlassContainer        ← 内容宽度 + 居中 + 全圆角 + 玻璃 + padding 5
     *   └ 横向滚动列表
     *       └ pill × 25     ← transparent；只有选中那个有"更亮一层"的底
     * ```
     *
     * ★ 教训（连续踩两次）：**"看起来不像"时先怀疑结构，不要先调参数**。
     */
    return Center(
      child: GlassContainer(
        shape: const LiquidRoundedSuperellipse(borderRadius: 999),
        quality: GlassQuality.standard,
        child: ConstrainedBox(
          // `max-width: 100%` —— 源很多时不要把屏幕撑破
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width - Sp.x8,
          ),
          child: SizedBox(
            height: 44,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── 可横向滚动的 pill 列表 ──
                Flexible(
                  child: ScrollConfiguration(
                    /*
                     * ══════════════════════════════════════════════════
                     * ★★★ 允许**鼠标拖拽**横滑（2026-09-24 用户要求）
                     * ══════════════════════════════════════════════════
                     *
                     * 用户原话：
                     * > 鼠标拖动,也不能左右滑动
                     *
                     * # 为什么默认不行
                     *
                     * Flutter 的 `ScrollBehavior.dragDevices` 默认**只含
                     * touch/stylus** —— 鼠标只能滚轮，拖拽不滚动。
                     * 这是移动优先的默认值，在桌面上就成了功能缺失。
                     *
                     * 加 `PointerDeviceKind.mouse` 即可。
                     *
                     * ⚠️ 会不会和点击 pill 冲突？
                     *    不会 —— 手势竞技场按"是否超过拖拽阈值"裁决：
                     *    ```text
                     *    按下后几乎没动（< kTouchSlop） → 点击 wins → InkWell.onTap
                     *    按下后拖动了超过阈值            → 拖拽 wins → 列表滚动
                     *    ```
                     *    这正是用户直觉（点=选源，拖=滚动）。
                     */
                    behavior: const MaterialScrollBehavior().copyWith(
                      dragDevices: {
                        PointerDeviceKind.touch,
                        PointerDeviceKind.mouse,
                        PointerDeviceKind.stylus,
                        PointerDeviceKind.trackpad,
                      },
                    ),
                    child: ListView.separated(
                      clipBehavior: Clip.antiAlias,
                      controller: _controller,
                      scrollDirection: Axis.horizontal,
                      // 原版 `.srcbar { padding: 5px }` + 内层 `padding: 0 var(--sp-2)`
                      padding: const EdgeInsets.symmetric(horizontal: Sp.x2),
                      itemCount: sources.length,
                      separatorBuilder: (_, __) => const SizedBox(width: Sp.x1),
                      itemBuilder: (context, i) {
                        // ⚠️ 用**过滤后**的 `sources`（任务 AE）——
                        //    用 `widget.sources` 会把停用的源渲染回药丸里
                        final s = sources[i];
                        final active = s.id == widget.current;
                        final focused = i == widget.focusedIndex;

                        return Center(
                          child: _SourcePill(
                            source: s,
                            active: active,
                            focused: focused,
                            colors: colors,
                            onTap: () => widget.onSelect(s.id),
                          ),
                        );
                      },
                    ),
                  ),
                ),

                /*
                 * ── 数量显示（原版 `showCount`）──
                 *
                 * 原版：
                 * ```ts
                 * const showCount = computed(() => props.sources.length > 3);
                 * ```
                 * > 源少时不显示 —— 3 个源一眼就数完了，
                 * > 再挂一个"3 个源"是纯噪音。
                 *
                 * 样式照抄原版 `.srcbar__count`：
                 * ```css
                 * padding: 0 var(--sp-4) 0 var(--sp-3);
                 * margin-left: var(--sp-1);
                 * font-size: var(--fs-cap);
                 * color: var(--text-tertiary);
                 * border-left: 1px solid var(--divider);   ← 左侧分隔线
                 * ```
                 * 注意它在**滚动区之外**（`flex: none`）——
                 * 滚到第 20 个源时数量仍然可见。
                 */
                if (_showCount) ...[
                  const SizedBox(width: Sp.x2),
                  Container(height: 18, width: 1, color: colors.outlineVariant),
                  Padding(
                    padding: const EdgeInsets.only(
                      left: Sp.x3,
                      right: Sp.x4,
                    ),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            // ⚠️ 过滤后的数量（任务 AE）—— 见 `_showCount` 的说明
                            text: '${sources.length}',
                            style: TextStyle(
                              fontSize: FontSizes.cap,
                              fontWeight: FontWeight.w600,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          TextSpan(
                            text: ' 个源',
                            style: TextStyle(
                              fontSize: FontSizes.cap,
                              color: colors.onSurfaceVariant
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个源 pill（**透明**；只有选中那个有"更亮一层"的底）
///
/// 照原版 `.srcbar__pill` / `.srcbar__pill.is-active`：
/// ```css
/// .srcbar__pill            { background: transparent; color: var(--text-secondary); }
/// .srcbar__pill.is-active  { background: var(--surface-4); box-shadow: var(--shadow-sm); }
/// ```
/// ⚠️ **不是玻璃** —— 玻璃在外层容器上（见 `build` 里的说明）。
class _SourcePill extends StatelessWidget {
  const _SourcePill({
    required this.source,
    required this.active,
    required this.focused,
    required this.colors,
    required this.onTap,
  });

  final dynamic source;
  final bool active;
  final bool focused;
  final ColorScheme colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = source;
    final icon = s.icon as String?;
    final name = s.name as String;
    final working = s.working as bool;
    final brokenReason = s.brokenReason as String?;

    /*
     * ★ 主题判据（`--srcbar-pill-bg` 的两套值）
     *
     * 用 **forui** 的 `colors.brightness`（`AppPalette` 自带 `brightness`，
     * forui `src/theme/colors.dart:32`），与 `_SourceBarState.build` 里
     * `Theme.of(context).colorScheme` 的 `colors` 参数**不是同一个来源** ——
     * 刻意如此：`FTheme` 那层才是本文件渲染真正依赖的主题，
     * 而 Material 侧在本项目里出过一次"两套 Theme 串台"的兜底事故。
     */
    final isLight = AppPalette.of(context).brightness == Brightness.light;

    /// 原版 `--srcbar-pill-bg: var(--surface-4)`
    ///
    /// ```text
    /// 深色 tokens.css:249      --surface-4: rgb(255 255 255 / 0.17)
    /// 浅色 theme-light.css:89  --surface-4: rgb(255 255 255 / 1)
    /// ```
    /// ⚠️ **不是**底栏的 0.19/0.10，也**不是** 0.96/0.80 ——
    ///    源条用的是另一套令牌，见上面 `gradient` 那段的长注释。
    final pillAlpha = isLight ? 1.0 : 0.17;

    return InkWell(
      onTap: onTap,
      borderRadius: Radii.rFull,
      child: AnimatedContainer(
        duration: Motion.fast,
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x4,
          vertical: Sp.x2,
        ),
        decoration: BoxDecoration(
          /*
           * ══════════════════════════════════════════════════════════
           * ★★★ 选中药丸 —— 按主题取 `--srcbar-pill-bg`，**不是**底栏那一套
           *     （2026-09-24 第二次修正：修掉"照抄正在出错的参照物"）
           * ══════════════════════════════════════════════════════════
           *
           * # 用户原话
           * > 左上角和这个源切换,还是跟底部的不太一样
           *
           * # 第一轮：我"猜颜色"，两张都翻车
           *
           * ```text
           * 第一版  colors.primary.withValues(alpha: 0.16)   ← 染成品牌色
           * 第二版  colors.onSurface.withValues(alpha: 0.14) ← 灰底
           * ```
           * 实测像素差得很远（浅色主题下）：
           * ```text
           * 底栏药丸   (249,249,249)  ← 近白
           * 源条药丸   ( 30, 32, 40)  ← 近黑  ✗ 完全相反
           * ```
           * 原因：`onSurface` 在**浅色**主题下是近黑（那是给文字用的），
           * 拿它当"提亮层"当然变成暗块。
           *
           * # 第二轮：我"照抄底栏那两行" —— 观察对，结论错
           *
           * 我当时的推理是：
           * ```text
           * 白色渐变在深浅两个主题下都成立：
           *   深色主题  白 96%→80% 叠在暗玻璃上 = 提亮 → 药丸 ✓
           *   浅色主题  白 96%→80% 叠在亮玻璃上 = 更白 → 药丸 ✓
           * ```
           * **这个推理本身没错，但它默认了"底栏那两行是对的"。**
           * 而当时底栏**自己就是坏的** —— 同样的硬编码、同样没有主题分支
           * （那是 bug ③，用户报的"黑色模式下有问题"）。于是我把一个 bug
           * 从底栏**复制**到了源条：
           * ```text
           * 深色主题  白 96% 叠在暗玻璃上 = 接近纯白 ✗ 不是"提亮"，是"糊白"
           * ```
           *
           * ★ 教训（原版 `tokens.css:325-330` 记的是同一件事）：
           * ```text
           * 「这个项目里已经有好几个"选中药丸"了（底部 tab 栏、
           *   「我的」分段控件）。做新的之前应该先找**已有的同类控件**
           *   对齐，而不是自己发明一套材质。」
           * ```
           * 而"找同类控件对齐"的**前提**是那个控件本身是对的 ——
           * 先确认它有主题分支吗？值有出处吗？**修 A 的时候不要把 A
           * 当成"正确样板"去抄 B**。
           *
           * # 第三轮（现在）：源条用的是**另一个令牌**，所以值本来就不同
           *
           * ```css
           * tokens.css:338（深色，默认主题）
           *   --srcbar-pill-bg: var(--surface-4);
           * tokens.css:249
           *   --surface-4: rgb(255 255 255 / 0.17);      ← 单一值，不是渐变
           *
           * theme-light.css:81（浅色）
           *   --srcbar-pill-bg: var(--surface-4);
           * theme-light.css:89
           *   --surface-4: rgb(255 255 255 / 1);         ← 纯白实底
           * ```
           *
           * ## ⚠️ 为什么源条与底栏"值不同但**都对**"
           *
           * ```text
           * 底栏 / 「我的」分段控件   --tab-pill-bg   深 0.19→0.10（渐变）浅 0.96→0.80
           * 首页源条                 --srcbar-pill-bg 深 0.17（单值）    浅 1.0
           * ```
           * 两个令牌**各自**在两套主题里都调好过，只是**调的目标不同**：
           * ```text
           * --tab-pill-bg      = "在玻璃上浮起一层"→ 要透明的渐变（有高光方向感）
           * --srcbar-pill-bg   = var(--surface-4)  = 一套通用的"表面层级"
           *                      第 4 档 = "实心感最强的那个表面"→ 要**实**
           * ```
           * 源条在深色下 0.17 比底栏上端 0.19 略**暗**一点点、且**上下同色**；
           * 浅色下它直接是**纯白**（1.0），比底栏的 0.96 透白更实
           * —— 原版 `theme-light.css:74` 解释了为什么浅色要更实：
           * > 浅色下 `--surface-4` 是纯白，叠在 `--surface-1`（白 62%）的
           * > 切换条底上正好"浮"出来一层 —— 不需要额外描边。
           *
           * ⚠️ 原版 `tokens.css:336` 那句「但现在两边的**值是一样的**」
           *    **不是**说源条 = 底栏：它说的是 `--srcbar-pill-bg` 与
           *    **`--surface-4`** 相同（因为就是 `var(--surface-4)`）。
           *    原版措辞歧义，已核实。
           *
           * ## ⚠️ 为什么两者在深色下"看起来还是很像"
           *
           * 因为源条的 pill 是**压在源条自己的玻璃上**的，不是压在底栏上；
           * 0.17 与 0.19 的差在 8 位色深下只有 2 级，肉眼分不出 ——
           * 但**语义必须分开写**：谁合并成一个常量，谁就把"将来单独微调
           * 其中一个"的路堵死了（这正是原版保留独立令牌名的理由：
           * `tokens.css:333-335`「万一将来切换条需要微调……只改令牌即可」）。
           *
           * ★ 形态也**不复用**：原版源条药丸是**单一值**（`--surface-4` 是
           *   一个色，不是 gradient）。这里保留 `LinearGradient` 两段同色，
           *   只是为了让 `AnimatedContainer` 的隐式动画与"有药丸/无药丸"
           *   两种状态间的过渡保持一致 —— 渲染结果与纯色**完全等价**。
           */
          gradient: active
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    // `--surface-4`：深 0.17（单一值）/ 浅 1.0（纯白实底）
                    Colors.white.withValues(alpha: pillAlpha),
                    Colors.white.withValues(alpha: pillAlpha),
                  ],
                )
              : null,
          borderRadius: Radii.rFull,
          /*
           * 原版 `--srcbar-pill-shadow: var(--shadow-sm)`（**不再是**底栏的
           * `--tab-pill-shadow`）：
           * ```css
           * tokens.css:156（深色）    --shadow-sm: 0 1px 2px rgb(0 0 0 / 0.3);
           * theme-light.css:54（浅色） --shadow-sm: 0 1px 2px rgb(16 18 26 / 0.06);
           * ```
           * 与底栏的 `inset 高光 + 8px 投影` 不同 —— 源条的阴影**更小更闷**
           * （浅色下只有 0.06，几乎看不见）。这与"药丸更实"是同一套意图：
           * 实底不需要靠阴影撑层次。
           * ⚠️ 之前这里写死 `0.16` 并且注释说"与底栏同一个值" —— 那既不是
           *    `--shadow-sm`（深色 0.3），也不是主题分支的值。
           */
          boxShadow: active
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isLight ? 0.06 : 0.30),
                    // `0 1px 2px`
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
          // TV 遥控器的焦点环（触摸端不显示）
          border: focused && !active
              ? Border.all(color: colors.primary, width: 2)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            /*
             * ★ 源图标：原版用 manifest.icon（emoji 或 URL）。
             *
             * 这里只处理**短文本**（emoji/单字）——
             * 如果是 URL 就跳过（那是网络图，单独加载会闪）。
             * 原版也是这么做的（`icon.length <= 2` 才算 emoji）。
             */
            if (icon != null &&
                icon.isNotEmpty &&
                icon.length <= 4 &&
                !icon.startsWith('http'))
              Padding(
                padding: const EdgeInsets.only(right: Sp.x1),
                child: Text(
                  icon,
                  style: const TextStyle(fontSize: FontSizes.sm),
                ),
              ),
            Text(
              name,
              style: TextStyle(
                fontSize: FontSizes.sm,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                /*
                 * ⚠️ 选中态文字：**药丸暗就用亮字，药丸亮就用暗字**
                 *    （2026-09-24 第二次修正）
                 *
                 * # 上一版为什么错
                 *
                 * 上一版写的是"药丸**恒为白色**（深浅主题都是），
                 * 所以字也恒为深色（`#1E2028`），与主题无关"。
                 * **两个前提都已不成立**：
                 * ```text
                 * ① 药丸不再恒为白 —— 深色下是白 17%（暗药丸）
                 * ② 即使药丸是白的，"恒为深色"也不对 ——
                 *    浅色主题下深字可用，深色主题下它压在 17% 的药丸上
                 *    会变成"暗底暗字"（同一类 bug 的反向版本）
                 * ```
                 *
                 * # 现在怎么取
                 *
                 * 直接用 `--text-primary`（`theme-light.css:39` /
                 * `tokens.css:50`）对应的主题角色 —— 也就是 `AppPalette`
                 * 在这套主题下给"背景上的文字"的那一个：
                 * ```text
                 * 浅色  #0A0A0A 近黑  ← 压在纯白药丸（1.0）上 ✓
                 * 深色  #FAFAFA 近白  ← 压在 0.17 暗药丸上 ✓
                 * ```
                 * 这与原版 `.srcbar__btn.is-on { color: var(--text-primary) }`
                 * （`SourceBar.vue:592`）逐字对应。
                 *
                 * ★ 关键：`AppPalette` **自带 `brightness`**，所以取到的角色
                 *   天然跟随主题 —— 这里不需要自己写 `isLight ? 黑 : 白`，
                 *   写了反而会与 forui 的主题解析链路产生第二个真值来源。
                 *   **真正需要显式分支的只有药丸本身**（那是"白色叠多少"
                 *   这个与主题无关的原始 alpha，forui 没有对应角色）。
                 */
                color: active
                    ? AppPalette.of(context).foreground
                    : colors.onSurfaceVariant,
              ),
            ),
            // 失效标记：源探测失败时明确标出来，
            // 而不是让用户点了没反应还不知道为什么
            if (!working)
              Padding(
                padding: const EdgeInsets.only(left: Sp.x1),
                child: Tooltip(
                  message: brokenReason ?? '该源当前不可用',
                  child: Icon(
                    Icons.error_outline,
                    size: FontSizes.sm,
                    color: colors.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
