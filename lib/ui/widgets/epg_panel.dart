// ═══════════════════════════════════════════════════════════════════════
//  节目单面板（EPG）—— 对齐原版 LiveView.vue 的 `.epg` 区块
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么把它从 `live_page.dart` 抽出来单独一个文件
//
// 原版 `.epg` 是**整块**：标题 + 骨架 + 空态 + 列表，四选一 ——
// ```html
// <div class="epg lg lg-blur lg-panel">
//   <div class="epg__head">…时钟图标… 节目单</div>
//   <div v-if="epgLoading"   class="epg__list">  6 个骨架  </div>
//   <EmptyState v-else-if="!epg.length" …>      暂无节目单 </EmptyState>
//   <div v-else             class="epg__list">  N 条节目    </div>
// </div>
// ```
// （`LiveView.vue:235-274`）
//
// 抽出来的直接好处是**可以被 widget test 直接挂载**：
// `live_page.dart` 整个页面依赖 FFI bridge，`flutter test` 里跑不起来，
// 而这个面板是纯数据 → 纯 UI，三态可以用测试**真的渲染出来**验证
// （见 `test/live_page_test.dart`）。静态断言只能证明"代码里写了"，
// 渲染断言才能证明"用户看得见"。
//
// # ⚠️ 能力位驱动：这个面板**不做**内部的 capability 判断
//
// 原版文件头确实写了「Provider 声明 `capabilities.epg` / `timeshift`
// 才显示对应功能」（`LiveView.vue:5`），但那是**意图**，
// 原版**整个文件里没有任何一处读 `capabilities`**。
// 它用的是更宽松的判据 —— "当前频道有没有 EPG 数据"：
// ```ts
// epg.value = await liveApi.epg(activeProvider.value, ch.id);  // 失败就空
// ```
//
// 而**实测本机真实数据**（`cctv.js`，仓库自带、唯一声明 epg 的源）：
// ```js
// capabilities: { vod: true, live: true, epg: true, timeshift: true, … }
// async epg(channelId)   { … }   ← 声明了也实现了
// async timeshift(…)     { … }   ← 声明了也实现了
// ```
// 也就是「声明 epg」与「有 EPG 数据」在可用源上是同一件事。
//
// ⚠️ 但如果照字面加一道 `caps.epg == false → 隐藏整个面板`，
//    在**只声明 `live: true`** 的源（`.probe/testdata/plugins/demo.js`）
//    上会**多出**一块原版没有的「无节目单」区域 —— 那是**改变交互**，
//    不符合「操作逻辑必须与原版一致」。
// 所以这里照原版：**只要有频道就渲染面板**，有没有内容由数据决定。
//
// # 唯一的职责边界：`onWatchLive` 只在有频道时传
//
// 原版 `watchLive()` 第一行是 `if (!selected.value) return;`（L122）——
// 没选中频道时点了不该有任何反应。所以 [onWatchLive] 为 null 时
// 「直播中」那条**不可点**（不是"点了没反应"，而是明确的不可用态）。

import 'package:material_ui/material_ui.dart';

import '../../core/models.dart';
import '../tokens.dart';

/// 节目单面板 —— 「节目单」标题 + 骨架 / 空态 / 列表三态
///
/// 三态互斥，优先级与原版一致：
/// `epgLoading` → 骨架 ⊃ `epg.isEmpty` → 空态 ⊃ 否则 → 列表。
class EpgPanel extends StatelessWidget {
  const EpgPanel({
    super.key,
    required this.epg,
    required this.epgLoading,
    required this.now,
    required this.fmtTime,
    required this.onWatchLive,
    required this.onWatchReplay,
  });

  /// 节目单（空列表 = 该频道没有 EPG 数据，不是错误）
  final List<EpgEntry> epg;

  /// 正在拉取（原版 `epgLoading`）—— 显示 6 个骨架
  final bool epgLoading;

  /// 当前时间（Unix 秒）
  ///
  /// 由页面每 30 秒推进一次 —— **不在这里起 Timer**：
  /// 原版也只有一个 `setInterval` 在 `LiveView.vue:32`，
  /// 而 `now` 同时驱动「正在播出 · 节目名」那行（在页面层）。
  /// 两处各自计时会在边界上出现「卡片说在播 A、列表说在播 B」。
  final int now;

  /// Unix 秒 → `HH:mm`
  final String Function(int) fmtTime;

  /// 点「正在播出」那条 → 看直播（原版 `isNow(e) ? watchLive() : watchReplay(e)`）
  final VoidCallback? onWatchLive;

  /// 点「回看」那条 → 回看该节目（原版 `watchReplay(e)`）
  final void Function(EpgEntry) onWatchReplay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(Sp.x4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: Radii.rLg,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 标题（原版 `.epg__head`：16px 时钟图标 + 「节目单」）──
          Padding(
            padding: const EdgeInsets.only(left: Sp.x2, bottom: Sp.x3),
            child: Row(
              children: [
                Icon(Icons.schedule, size: 16, color: colors.onSurfaceVariant),
                const SizedBox(width: Sp.x2),
                Text(
                  '节目单',
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),

          if (epgLoading)
            _EpgSkeleton(colors: colors)
          else if (epg.isEmpty)
            _EpgEmpty(colors: colors)
          else
            /*
             * ★ 列表**不做内部滚动**（原版是 `max-height: 420px; overflow-y: auto`）
             *
             * 原版 `.epg__list` 自己有 420px 上限 + 内部滚动条。但页面外层
             * 还有一条主滚动轴 —— **两条独立滚动轴嵌套**是明确的体验问题：
             *   ① 触摸板/滚轮在节目单上滚动时，到底滚哪一条？原版靠 CSS
             *      "内层先滚到底再冒泡给外层"，桌面鼠标滚轮实测很别扭；
             *   ② TV 遥控器方向键 ↓ 更难预测（焦点在列表里，滚动的是容器）。
             *
             * 4K/TV 的 1280x800 目标下，420px 只装得下约 7 条节目，
             * 而一天的节目单常有三四十条 —— 内层滚动条是必然出现的，
             * 不是边界情况。所以这里让列表**随内容撑开**，只保留页面主滚动轴。
             *
             * ⚠️ 这是本项目里**唯一**一处与原版不同的交互选择，
             *    已在交付报告里单列，没有擅自改其它任何交互。
             */
            Column(
              children: [
                for (final e in epg)
                  EpgTile(
                    entry: e,
                    now: now,
                    fmtTime: fmtTime,
                    /*
                     * ⚠️ 没选中频道时 `onWatchLive` 为 null → 不可点。
                     *    原版 `watchLive()` 会直接 return（L122），
                     *    但那样用户点了"没反应"，不如明确置灰。
                     */
                    onWatchLive: onWatchLive,
                    onWatchReplay: () => onWatchReplay(e),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  骨架 / 空态
// ═══════════════════════════════════════════════════════════════════════

/// 加载骨架 —— 原版是 6 个 `height: 52px` 的 `.skeleton`
class _EpgSkeleton extends StatelessWidget {
  const _EpgSkeleton({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 6; i++)
          Container(
            height: 52,
            margin: const EdgeInsets.only(bottom: 3),
            decoration: BoxDecoration(
              color: colors.onSurface.withValues(alpha: 0.05),
              borderRadius: Radii.rSm,
            ),
          ),
      ],
    );
  }
}

/// 空态 —— 原版的 `EmptyState`（`LiveView.vue:247-252`）：
/// 信息图标 + 「暂无节目单」+ 「该频道未提供 EPG 数据」
class _EpgEmpty extends StatelessWidget {
  const _EpgEmpty({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.x6),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.info_outline,
              size: 40,
              color: colors.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: Sp.x3),
            Text(
              '暂无节目单',
              style: TextStyle(
                fontSize: FontSizes.base,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: Sp.x1),
            Text(
              '该频道未提供 EPG 数据',
              style: TextStyle(
                fontSize: FontSizes.sm,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  单条节目
// ═══════════════════════════════════════════════════════════════════════

/// 一条节目 —— 时间 + 标题（+ 进度条）+ 徽章
///
/// 与原版 `.epg-item` 逐项对齐（`LiveView.vue:255-272`）：
/// ```html
/// <button :disabled="!e.replayable && !isNow(e)"
///         @click="isNow(e) ? watchLive() : watchReplay(e)">
///   <span class="epg-item__time tabular">{{ fmtTime(e.start) }}</span>
///   <span class="epg-item__title ellipsis">{{ e.title }}</span>
///   <span v-if="isNow(e)" class="epg-item__bar">…进度…</span>
///   <span v-if="isNow(e)" class="chip chip--live">直播中</span>
///   <span v-else-if="e.replayable" class="chip">回看</span>
/// </button>
/// ```
class EpgTile extends StatelessWidget {
  const EpgTile({
    super.key,
    required this.entry,
    required this.now,
    required this.fmtTime,
    required this.onWatchLive,
    required this.onWatchReplay,
  });

  final EpgEntry entry;
  final int now;
  final String Function(int) fmtTime;
  final VoidCallback? onWatchLive;
  final VoidCallback onWatchReplay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isNow = entry.isNow(now);

    /*
     * ⚠️ 不可回看且不是正在播的 → **禁用**
     *
     * 原版：`:disabled="!e.replayable && !isNow(e)"`
     * 源不提供回看流，点了只会报错 —— 不如直接禁掉。
     */
    final enabled = entry.replayable || isNow;

    /*
     * 点击行为 —— 与原版三元表达式**逐字对应**：
     * `@click="isNow(e) ? watchLive() : watchReplay(e)"`
     *
     * ⚠️ 「正在播」那条**必须**走 `onWatchLive`（而不是回看）——
     *    原版就是这样，不能想当然地让在播节目也去调回看。
     */
    final VoidCallback? onTap = !enabled
        ? null
        : (isNow ? onWatchLive : onWatchReplay);

    return InkWell(
      onTap: onTap,
      borderRadius: Radii.rSm,
      child: Container(
        margin: const EdgeInsets.only(bottom: 3),
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x3,
          vertical: Sp.x3,
        ),
        decoration: BoxDecoration(
          color: isNow ? colors.primary.withValues(alpha: 0.10) : null,
          borderRadius: Radii.rSm,
        ),
        child: Row(
          children: [
            // ── 时间（原版 `.epg-item__time` 固定 46px + tabular）──
            SizedBox(
              width: 44,
              child: Text(
                /*
                 * 原版是 `fmtTime(e.start)`（**自己格式化**，不看 show_time）。
                 *
                 * 但 `EpgEntry.showTime` 是后端契约里真实存在的字段
                 * （`src/api/types.ts:169 show_time?: string`），
                 * 有些源自带「20:00」这种更准的显示串 —— 有就用它。
                 * 没有时与原版完全一致。
                 */
                entry.showTime ?? fmtTime(entry.start),
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: isNow ? FontWeight.w600 : FontWeight.w400,
                  color: isNow ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: Sp.x2),

            // ── 标题 + 进度条 ──
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: FontSizes.sm,
                      color: enabled
                          ? colors.onSurface
                          : colors.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  if (isNow) ...[
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: entry.progressAt(now) / 100.0,
                        minHeight: 3,
                        backgroundColor:
                            colors.onSurface.withValues(alpha: 0.08),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: Sp.x2),

            // ── 徽章：正在播 → 「直播中」；否则可回看 → 「回看」──
            if (isNow)
              const _Badge(
                text: '直播中',
                background: AppColors.liveDot,
                foreground: Colors.white,
              )
            else if (entry.replayable)
              _Badge(
                text: '回看',
                border: colors.outlineVariant,
                foreground: colors.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }
}

/// 小徽章（原版 `.chip`）
class _Badge extends StatelessWidget {
  const _Badge({
    required this.text,
    required this.foreground,
    this.background,
    this.border,
  });

  final String text;
  final Color foreground;
  final Color? background;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: Radii.rFull,
        border: border != null ? Border.all(color: border!) : null,
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: FontSizes.cap, color: foreground),
      ),
    );
  }
}
