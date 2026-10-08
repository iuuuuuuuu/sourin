// ═══════════════════════════════════════════════════════════════════════
//  追更页「更新提示」区块
// ═══════════════════════════════════════════════════════════════════════
//
// # 本文件的历史（**绕行已撤除，根因已修**）
//
// 这里原本自己调核心层拿原始 JSON，并定义了 `FollowUpdateItem` /
// `checkUpdatesRaw` / `buildUpdateItems` —— 因为 `models.dart` 的
// `UpdateInfo` 读的是 `new_count`（总数，语义用错）与
// `new_episode_title`（后端**从不下发**，真名 `latest_title`）。
//
// 那层绕行**已经撤掉**：`models.dart` 的 `UpdateInfo` 补上了
// `added` / `latestTitle`（外加 `oldCount` / `provider` / `cover`）。
//
// ★ 为什么必须撤（不是"能用就行"）：
// ```text
// 留着就是仓库里的**第二份契约** ——
// 以后 Rust 改了字段名，两处都要改，而漏掉哪一处都不报错。
// 那正是这个文件原本要修的那类静默 bug，不能自己再造一个。
// ```
//
// 现在这里只剩**纯渲染**：`FollowUpdateNotice` + `_UpdateRow`，
// 数据一律用 `models.dart` 的 `UpdateInfo`（走 `SourinApi.checkUpdates`）。
//
// # 对齐原版 `FollowView.vue:246-262`
//
// ```vue
// <span class="ellipsis t-primary">{{ u.title }}</span>
// <span class="chip chip--brand">+{{ u.added }} 集</span>          ← added，不是 new_count
// <span class="t-tertiary t-xs">{{ u.latest_title }}</span>        ← latest_title
// ```

import 'package:material_ui/material_ui.dart';

import '../../core/models.dart';
import '../tokens.dart';

/// 更新提示区块（对齐原版 `FollowView.vue:246-262` 的 `.updates`）
class FollowUpdateNotice extends StatelessWidget {
  const FollowUpdateNotice({super.key, required this.items});

  final List<UpdateInfo> items;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(Sp.x4),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.10),
        borderRadius: Radii.rLg,
        border: Border.all(color: colors.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 头部：「N 部有更新」──
          Row(
            children: [
              Icon(
                Icons.notifications_active,
                size: 17,
                color: colors.primary,
              ),
              const SizedBox(width: Sp.x2),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${items.length}',
                      style: const TextStyle(fontWeight: FontWeights.semibold),
                    ),
                    const TextSpan(text: ' 部有更新'),
                  ],
                ),
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  color: colors.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),

          // ── 逐条：标题 + 「+N 集」+ 最新一集名 ──
          for (final u in items) _UpdateRow(item: u),
        ],
      ),
    );
  }
}

class _UpdateRow extends StatelessWidget {
  const _UpdateRow({required this.item});

  final UpdateInfo item;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          // 标题（原版 `.ellipsis.t-primary`）
          Expanded(
            child: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: FontSizes.sm,
                color: colors.onSurface,
              ),
            ),
          ),

          // ★「+N 集」—— N 必须是 **added**（新增），不是 newCount（总数）
          //
          // ⚠️ 这两个字段**语义不同**，用错会让用户看到一个"看起来很合理"
          //    的错误数字（从 10 集更到 13 集时显示「+13 集」而不是「+3 集」）。
          //    宁可不管：那是总集数，不是"这次更了几集"。
          const SizedBox(width: Sp.x3),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Sp.x2,
              vertical: 1,
            ),
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.2),
              borderRadius: Radii.rFull,
            ),
            child: Text(
              '+${item.added} 集',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.primary,
              ),
            ),
          ),

          // ★ 最新一集标题（原版 `u.latest_title`，如「第13集」）
          //   null / 空 就**不渲染** —— 原版没有 v-if，但 Vue 里
          //   `{{ undefined }}` 渲染成空串，效果同样是"看不见"。
          if (item.latestTitle != null && item.latestTitle!.isNotEmpty) ...[
            const SizedBox(width: Sp.x2),
            Text(
              item.latestTitle!,
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
