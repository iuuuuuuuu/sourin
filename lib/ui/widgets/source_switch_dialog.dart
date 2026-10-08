// ═══════════════════════════════════════════════════════════════════════
//  跨源换源弹层 —— 对齐原版 SourceSwitchDialog.vue（约 300 行）
// ═══════════════════════════════════════════════════════════════════════
//
// ★★★ 借鉴 阅读(legado) / 洛雪 / 异次元
//
// # Owner 的要求（原话）
//
// > 还是不能切源 同个电视剧,不能切相同的源,你就借鉴一下
// > github有个叫阅读的app 还有 洛雪 还有 异次元 漫画软件,
// > 这些都可以并且支持对同一个视频切换源看的
//
// # 三个参考 App 的共同做法
//
// ```text
// 阅读(legado)  阅读界面 → 换源   按**书名**搜全部书源   保留进度（按章节序号）
// 洛雪          播放失败/手动     按**歌名+歌手**搜      保留进度（按播放位置）
// 异次元漫画    漫画页 → 换源     按**标题**搜全部图源   保留进度（按话数）
// ```
// 三者都是：**按标题去所有源搜 → 列出找到的 → 点一个切过去 → 尽量保留进度**。
//
// # ★ 为什么不做「自动匹配」
//
// 原版注释：
// > 自动匹配一定会出错 —— 各源标题不统一：
// > ```text
// > A站: 无职转生 第三季 ～到了异世界就拿出真本事～
// > B站: 无职转生 第三季
// > C站: 无职转生第3季
// > ```
// > 而《西游记》和《西游记后传》是两个东西 ——
// > 自动配错比让用户点一下更糟。
// >
// > 所以：**搜出来给用户看，由用户确认**。但我会做相似度排序 + 标记，
// > 让正确的那个排在前面。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/ffi.dart';
import '../../core/sourin_api.dart';
import '../../core/title_match.dart';
import 'overlay_motion.dart';
import '../tokens.dart';

/// ★ 向后兼容再导出 —— 见下方「已搬到 lib/core/title_match.dart」的说明。
///   原先 `import 'widgets/source_switch_dialog.dart';` 的调用点
///   （`detail_page.dart:51` / `player_page.dart:111`）**无需任何改动**。
export '../../core/title_match.dart';

// ───────────────────────────────────────────────────────────────────────
//  `titleSimilarity` / `bestTitleScore` / `stableRankDesc`
//
//  ★ task-73：**已搬到 `lib/core/title_match.dart`**
//
//  搬家的原因：搜索页（`search_page.dart`）也要按匹配度排序，
//  而这个判据第一版住在**本文件**（一个 610 行的重 UI 弹层，
//  依赖 ffi / sourin_api / tokens）。
//  ⇒ 让搜索页 import 一个弹层文件只为拿一个纯文本函数，
//    依赖方向是反的，而且**迟早会有人复制第二份**。
//
//  ★ 下面那行 `export` 是**向后兼容**：原先
//    `import 'widgets/source_switch_dialog.dart';` 的两个调用点
//    （`detail_page.dart:51` / `player_page.dart:111`）**一行都不用改**。
//    同 task-58 把 `PlayRequestData` 搬到 `media_session.dart`
//    之后原地 export 的做法。
// ───────────────────────────────────────────────────────────────────────

/// 一个候选源
class SwitchCandidate {
  SwitchCandidate({
    required this.provider,
    required this.providerName,
    required this.items,
    required this.score,
  });

  final String provider;
  final String providerName;
  final List<MediaItem> items;

  /// 该源里**最像**的那条的相似度（用于排序与标记）
  final double score;

  /// 是否"很可能就是同一部"
  ///
  /// ★ 阈值 0.42 是原版**实测**出来的
  ///（同一部剧通常 >0.45，无关的 <0.3）。
  bool get likely => score >= 0.42;
}

/// 换源结果
class SwitchPick {
  const SwitchPick({
    required this.provider,
    required this.id,
    required this.title,
    required this.episodeIndex,
    required this.position,
  });

  final String provider;
  final String id;
  final String title;
  final int episodeIndex;
  final int position;
}

/// 跨源换源弹层
Future<SwitchPick?> showSourceSwitchDialog(
  BuildContext context, {
  required String title,
  required String currentProvider,
  String? currentProviderName,
  int episodeIndex = 0,
  int position = 0,
}) {
  return showAppDialog<SwitchPick>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SourceSwitchDialog(
      title: title,
      currentProvider: currentProvider,
      currentProviderName: currentProviderName,
      episodeIndex: episodeIndex,
      position: position,
    ),
  );
}

class _SourceSwitchDialog extends StatefulWidget {
  const _SourceSwitchDialog({
    required this.title,
    required this.currentProvider,
    this.currentProviderName,
    required this.episodeIndex,
    required this.position,
  });

  final String title;
  final String currentProvider;
  final String? currentProviderName;
  final int episodeIndex;
  final int position;

  @override
  State<_SourceSwitchDialog> createState() => _SourceSwitchDialogState();
}

class _SourceSwitchDialogState extends State<_SourceSwitchDialog> {
  /// 搜索用的关键词 —— **允许用户改**（阅读 App 就有这个）
  late final TextEditingController _kw = TextEditingController(
    text: widget.title,
  );

  bool _searching = false;
  int _settled = 0;
  int _totalProviders = 0;

  final List<SwitchCandidate> _candidates = [];
  final List<({String provider, String reason})> _misses = [];

  @override
  void initState() {
    super.initState();
    /*
     * ★ 打开就自动搜一次
     *
     * 原版注释：
     * > 用户点「换源」就是要看有哪些源 —— 不该还要再点一下「搜索」。
     */
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    /*
     * ★ 关闭时一定要取消，别让后台白跑十几个源
     */
    _cancel();
    _kw.dispose();
    super.dispose();
  }

  void _cancel() {
    // callStream 的取消由 searchAllStream 内部管理（token 在它那儿）
    // 这里只需阻止后续 setState
  }

  Future<void> _run() async {
    final kw = _kw.text.trim();
    if (kw.isEmpty) return;

    setState(() {
      _searching = true;
      _settled = 0;
      _totalProviders = 0;
      _candidates.clear();
      _misses.clear();
    });

    try {
      final providers = await SourinApi.listProviders();
      if (mounted) {
        setState(
          () => _totalProviders = providers.where((p) => p.enabled).length,
        );
      }

      await SourinApi.searchAllStream(kw, (ev) {
        if (!mounted) return false;
        switch (ev.kind) {
          case SearchEventKind.hit:
            /*
             * ★ 算相似度并**按相似度排序**（最可能"同一部"的排前面）
             *
             * 用该源里最像的那条的分数作为整个源的分数。
             */
            // ★ 与搜索页用的是**同一个函数**（`bestTitleScore`），
            //  不再是"两处各写一份、靠记得改两遍"。
            final best = bestTitleScore(widget.title, ev.items);
            setState(() {
              _candidates.add(
                SwitchCandidate(
                  provider: ev.provider,
                  providerName: ev.providerName,
                  /*
                 * ★ task-73 ⑥：**组内也按匹配度排序**
                 *
                 * 改之前这里是 `items: ev.items` —— 组内顺序 = 源自己返回的
                 * 顺序，而 UI 只显示前 8 条（`candidate.items.take(8)`）
                 * ⇒ 最像的那条**可能根本不在前 8 条里**，
                 *   用户看到的是 8 条无关的，而最像的那条被折叠进
                 *   「还有 N 个…」里。
                 *
                 * ⚠️ 排序放在**这里**（而不是渲染前）还有一个好处：
                 *   `take(8)` 天然就是"最像的 8 条"，
                 *   而「还有 ${items.length - 8} 个…」的语义不受影响（长度没变）。
                 *
                 * ⚠️ 必须用 `stableRankDesc`（同分保持原顺序）——
                 *   Dart 的 `List.sort` 不是稳定排序，同分项会乱跳。
                 */
                  items: rankItemsByTitleDesc(widget.title, ev.items),
                  score: best,
                ),
              );
              _settled++;
            });
          case SearchEventKind.miss:
            setState(() {
              if (ev.reason != null && ev.reason!.isNotEmpty) {
                _misses.add((provider: ev.provider, reason: ev.reason!));
              }
              _settled++;
            });
          case SearchEventKind.done:
          case SearchEventKind.error:
            break;
        }
        return true;
      });
    } catch (e) {
      debugPrint('[SWITCH] 搜索失败: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _pick(MediaItem item) {
    final i = item.id.indexOf(':');
    if (i < 0) return;
    Navigator.pop(
      context,
      SwitchPick(
        provider: item.id.substring(0, i),
        id: item.id.substring(i + 1),
        title: item.title,
        episodeIndex: widget.episodeIndex,
        position: widget.position,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * ★ 按相似度从高到低排
     *
     * ⚠️ 用 `stableRankDesc` 而不是裸 `..sort(...)` —— 后者不是稳定排序，
     *    同分的源（很常见：多个源都只搜到"有点沾边"的内容）相对顺序
     *    不确定 ⇒ 弹层每次重建都可能换序，用户看到列表在跳。
     *    与搜索页**同一套判据**（本仓铁律：判据只有一个来源）。
     */
    final sorted = stableRankDesc(_candidates, (c) => c.score);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── 标题 ──
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x5, Sp.x3, Sp.x3),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '换源',
                          style: TextStyle(
                            fontSize: FontSizes.lg,
                            fontWeight: FontWeights.semibold,
                            color: colors.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '按标题搜索其他源；'
                          '${widget.currentProviderName ?? widget.currentProvider}'
                          ' 是当前源',
                          style: TextStyle(
                            fontSize: FontSizes.cap,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),

            // ── 关键词（可改）──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.x5),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _kw,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _run(),
                      decoration: const InputDecoration(
                        hintText: '关键词（可修改后重搜）',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: Sp.x2),
                  FilledButton(
                    onPressed: _searching ? null : _run,
                    child: const Text('重搜'),
                  ),
                ],
              ),
            ),

            // ── 进度 ──
            if (_searching)
              Padding(
                padding: const EdgeInsets.only(top: Sp.x3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: Sp.x2),
                    Text(
                      '搜索中…（已搜 $_settled'
                      '${_totalProviders > 0 ? "/$_totalProviders" : ""} 个源）',
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: Sp.x2),
            const Divider(height: 1),

            // ── 结果 ──
            Expanded(
              child: sorted.isEmpty && !_searching
                  ? Center(
                      child: Text(
                        '没有找到其他源',
                        style: TextStyle(
                          fontSize: FontSizes.sm,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView(
                      clipBehavior: Clip.antiAlias,
                      padding: const EdgeInsets.all(Sp.x3),
                      children: [
                        for (final c in sorted)
                          _CandidateBlock(
                            candidate: c,
                            // ★ 传入原标题用于逐条算相似度 ——
                            //   不用 `findAncestorStateOfType`（那是脆弱写法，
                            //   依赖 widget 树形状，重构一下就崩）
                            targetTitle: widget.title,
                            isCurrent: c.provider == widget.currentProvider,
                            onPick: _pick,
                          ),
                        if (_misses.isNotEmpty) ...[
                          const SizedBox(height: Sp.x3),
                          Padding(
                            padding: const EdgeInsets.all(Sp.x2),
                            child: Text(
                              '${_misses.length} 个源未能返回结果：'
                              '${_misses.map((m) => m.provider).join("、")}',
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
          ],
        ),
      ),
    );
  }
}

class _CandidateBlock extends StatelessWidget {
  const _CandidateBlock({
    required this.candidate,
    required this.targetTitle,
    required this.isCurrent,
    required this.onPick,
  });

  final SwitchCandidate candidate;

  /// 当前在看的标题（逐条相似度的基准）
  final String targetTitle;

  final bool isCurrent;
  final void Function(MediaItem) onPick;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // ★ 很像的用品牌色点标出来
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: candidate.likely
                      ? colors.primary
                      : colors.onSurfaceVariant.withValues(alpha: 0.4),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: Sp.x2),
              Text(
                candidate.providerName,
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(width: Sp.x2),
              Text(
                '${candidate.items.length} 个结果',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
              /*
               * ★ 相似度标记
               *
               * 原版注释说明了为什么要标：
               * > 各源标题写法不同，用户要在几十个结果里找"同一部"很累。
               * > 把像的排前面、并标出来，能大幅减少寻找成本。
               */
              if (candidate.likely) ...[
                const SizedBox(width: Sp.x2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Sp.x2,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.16),
                    borderRadius: Radii.rFull,
                  ),
                  child: Text(
                    '很可能是同一部',
                    style: TextStyle(fontSize: FontSizes.cap, color: colors.primary),
                  ),
                ),
              ],
              /*
               * ★ 当前源**要显示**而不是过滤掉
               *
               * 原版注释：
               * > 用户需要看到"我现在这个源也搜到了"，
               * > 这能确认搜索是对的；过滤掉反而让人以为搜漏了。
               */
              if (isCurrent) ...[
                const SizedBox(width: Sp.x2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Sp.x2,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: Radii.rFull,
                    border: Border.all(color: colors.outlineVariant),
                  ),
                  child: Text(
                    '当前',
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: Sp.x2),
          for (final it in candidate.items.take(8))
            InkWell(
              onTap: () => onPick(it),
              borderRadius: Radii.rSm,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Sp.x2,
                  vertical: Sp.x2,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        it.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: FontSizes.sm,
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                    if (it.note != null && it.note!.isNotEmpty)
                      Text(
                        it.note!,
                        style: TextStyle(
                          fontSize: FontSizes.cap,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(width: Sp.x2),
                    // 逐条也标出相似度（用户能看出哪个最像）
                    Text(
                      '${(titleSimilarity(targetTitle, it.title) * 100).round()}%',
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (candidate.items.length > 8)
            Padding(
              padding: const EdgeInsets.only(left: Sp.x2, top: 2),
              child: Text(
                '还有 ${candidate.items.length - 8} 个…',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
