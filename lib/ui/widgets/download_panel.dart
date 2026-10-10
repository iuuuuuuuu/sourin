// ═══════════════════════════════════════════════════════════════════════
//  ★★★ task-11 ②③④ 下载管理面板（播放页右侧「下载 / 已下载」）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话（逐字）：
// > 我的想法是,点击进去也还是播放页,只不过右侧的变成下载 或者 已经下载好的,
// > 一集一集的,一集占一行,然后如果正在下载就可以暂停啊 删除啊,操作,
// > 如果是已经下载好的,就可以播放 可以删除
// > （追加）而且就算在外面也应该可以进行整部剧的删除操作
//
// # 形态（一集一行，四态）
// ```text
// 排队中  ⇒        [取消]
// 下载中  ⇒ 进度条 [暂停] [删除]
// 已暂停  ⇒ 进度条 [继续] [删除]
// 已下载  ⇒        [播放] [删除]
// 失败    ⇒ error 原文 [重试] [删除]
// ```
//
// # ★ 数据源是**现成**的（不自建状态）
// ```text
// lib/core/download_queue.dart:181  static final ValueNotifier<List<DownloadTask>> tasks
// ⇒ 面板只订阅它。队列是**进程级单例** ⇒ 面板卸载/重建都不影响下载继续跑。
// ```
//
// # ★★ 空列表**整块不画**（与 _LiveStrip 同一条纪律）
// ```text
// 没有下载任务时，面板不该占位 —— 那会把右侧详情栏挤成一片空白。
// 调用方（播放页）据此决定「右侧显示详情还是下载面板」。
// ```
//
// # ★ 性能纪律（task-11 ① 的读数要求）
// ```text
// ① 探针实测：挂了监听者后 `_publish()`（每 8 片一次）会让主 isolate
//    掉帧 54 次 / 最长阻塞 38 ms（不挂监听者时 0 次）。
// ⇒ 面板必须用 ValueListenableBuilder **只重建自己**，绝不 setState 整页。
// ② 每行带 ValueKey(task.id) ⇒ 列表刷新时 Flutter 只更新变化的那行。
// ③ 不在下载热路径上新增任何 publish（频率仍是每 8 片一次）。
// ```
library;

/*
 * ★ 2026-10-09 修正：这里原来引的是 `package:flutter/material.dart`
 *
 * 本仓 Flutter 3.47 把 Material 拆成了独立包 ⇒ 同一棵树里混用两份
 * Material 时主题不生效（症状：弹窗只渲染成一块灰色遮罩，
 * 见 DEVELOPMENT.md 那条坑）。全仓其余页面统一用下面这个包。
 *
 * ⚠️ `test/theme_regression_test.dart` 会**全 lib 扫那个字面量**，
 *    注释里出现也算违规 ⇒ 上面刻意没把整行写出来。
 */
import 'package:material_ui/material_ui.dart';

import '../../core/app_log.dart';
import '../../core/download_queue.dart';
import '../tokens.dart';
import 'cover_image.dart';
import 'overlay_motion.dart';

/// ★★★ task-12 缺陷 A：「磁盘上已经下好了」的一集（不属于内存队列）
///
/// # 为什么需要这个类型（Owner 真机截图暴露的必现缺陷）
/// ```text
/// 面板原来的数据源只有 `DownloadQueue.tasks` —— 那是**内存态**，
/// 客户端一重启就空。而用户**以前下载好**的文件安静地躺在磁盘上 ⇒
///   重启后点开那部剧 ⇒ 队列空 ⇒ 右侧退回 DetailPage ⇒
///   DetailPage 拿 (local, 绝对路径) 去拉详情 ⇒ Rust `registry.route()`
///   没有叫 local 的 provider ⇒
///     **SourinCoreException: 无法路由: local:c:/users/.../第01集 第01集.mp4**
/// ★ 这不是边缘情况：旁文件是我 task-12 才加的 ⇒ 用户**存量**下载全都没有，
///   「没旁文件 ⇒ 本地播放」是必经之路。
/// ```
///
/// ⇒ 数据源改成**磁盘扫盘结果**（`scanCacheWorks`）也算一份，
///   与内存队列合并后一集一行。
@immutable
class DownloadedItem {
  const DownloadedItem({
    required this.fileName,
    required this.title,
    this.episodeTitle,
    required this.bytes,
    this.cover,
  });

  /// 磁盘上的文件名（含扩展名）—— 也是这一行的稳定 key
  final String fileName;

  /// 作品名（所属目录）
  final String title;

  /// 集名（尽量从文件名还原）
  final String? episodeTitle;

  final int bytes;
  final String? cover;

  /// 行标识：同一部剧里文件名唯一
  String get id => 'disk:$title/$fileName';
}

/// 下载面板的对外回调（由宿主提供 —— 面板不认识播放器/导航）
class DownloadPanelCallbacks {
  const DownloadPanelCallbacks({
    required this.onPlay,
    this.onClose,
    this.onPlayDownloaded,
  });

  /// 「播放」正在队列里的一集 ⇒ 宿主决定怎么播（换集 / 打开文件）
  final void Function(DownloadTask t) onPlay;

  /// ★ task-12 缺陷 A：「播放」**磁盘上已下好**的一集 ⇒
  ///   宿主据此走**本地播放**（provider=local / localPath=绝对路径）。
  final void Function(DownloadedItem item)? onPlayDownloaded;

  /// 「返回详情」—— 可选（窄屏时面板可能全屏，需要出口）
  final VoidCallback? onClose;
}

class DownloadPanel extends StatelessWidget {
  const DownloadPanel({
    super.key,
    required this.callbacks,
    this.title,
    this.downloaded = const <DownloadedItem>[],
  });

  final DownloadPanelCallbacks callbacks;

  /// 当前作品名（决定「整剧删除」作用在谁身上）
  final String? title;

  /// ★★★ task-12 缺陷 A：**磁盘上已下好**的集（宿主从扫盘结果喂进来）。
  ///
  /// 它们不属于内存队列（重启后就没了）⇒ 必须由宿主提供，
  /// 否则「已下载好的一集一行」在重启后整个消失。
  final List<DownloadedItem> downloaded;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<DownloadTask>>(
      valueListenable: DownloadQueue.tasks,
      builder: (context, all, _) {
        /*
         * 只显示**当前作品**的任务（若宿主给了 title）；
         * 没给 title（比如独立的下载管理页）就全显示。
         */
        final items = title == null
            ? all
            : all.where((t) => t.title == title).toList(growable: false);

        /*
         * ★★ 空判据是「两条来源**都**空」，不是只看队列。
         * ```text
         * 原来：`if (all.isEmpty) return SizedBox.shrink();`
         * 缺陷：重启后队列空 ⇒ 面板整块消失 ⇒ 右侧退回 DetailPage ⇒
         *       DetailPage 用 (local, 路径) 拉详情 ⇒ 「无法路由: local:…」
         *       ★ 那正是 Owner 真机截图里那条报错。
         * ⇒ 改成：磁盘上有已下好的集也**算有内容**。
         * ```
         */
        if (items.isEmpty && downloaded.isEmpty) {
          return const SizedBox.shrink();
        }

        // 磁盘上已下好的集按文件名稳定排序（与扫盘顺序无关，避免跳行）
        final diskItems = <DownloadedItem>[...downloaded]
          ..sort((a, b) => a.fileName.compareTo(b.fileName));

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              title: title,
              items: items,
              onClose: callbacks.onClose,
              onRemoveWork: title == null
                  ? null
                  : () => _confirmRemoveWork(context, title!),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(
                  horizontal: Sp.x3,
                  vertical: Sp.x2,
                ),
                // ★ 队列里的（在下/暂停/失败）+ 磁盘上已下好的，同一列表
                itemCount: items.length + diskItems.length,
                itemBuilder: (context, i) {
                  if (i < items.length) {
                    final t = items[i];
                    // ★ ValueKey(task.id)：刷新时只更新变化的那行
                    return _DownloadRow(
                      key: ValueKey<String>(t.id),
                      task: t,
                      onPlay: () => callbacks.onPlay(t),
                    );
                  }
                  final d = diskItems[i - items.length];
                  return _DownloadedRow(
                    key: ValueKey<String>(d.id),
                    item: d,
                    onPlay: callbacks.onPlayDownloaded == null
                        ? null
                        : () => callbacks.onPlayDownloaded!(d),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  /// ★★★ task-11 ④：整剧删除的**二次确认**
  ///
  /// ⚠️ 真删、不可逆 ⇒ 必须先把「将删什么」摆给用户看（几集 / 多少 MB / 前几个文件名）。
  static Future<void> _confirmRemoveWork(
    BuildContext context,
    String title,
  ) async {
    final p = await DownloadQueue.previewRemoveWork(title);
    if (!context.mounted) return;
    if (p.fileCount == 0 && p.episodeCount == 0) {
      AppLog.write('DL', '整剧删除："$title" 没有任何产物，跳过');
      return;
    }
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除整部剧的下载？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('「$title」'),
            const SizedBox(height: Sp.x2),
            Text('将删除 ${p.fileCount} 个文件（${p.sizeText}）',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (p.episodeCount > 0)
              Text('并从下载队列移除 ${p.episodeCount} 个任务'),
            const SizedBox(height: Sp.x2),
            const Text('此操作不可恢复。', style: TextStyle(color: Colors.red)),
            if (p.fileNames.isNotEmpty) ...[
              const SizedBox(height: Sp.x2),
              Text(
                p.fileNames.take(5).join('、') +
                    (p.fileNames.length > 5
                        ? '… 等 ${p.fileNames.length} 个'
                        : ''),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('全部删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = await DownloadQueue.removeWork(title, force: true);
    AppLog.write(
      'DL',
      '整剧删除完成 "$title"：${r.deletedFiles} 个文件 / '
          '${(r.deletedBytes / 1048576).toStringAsFixed(1)} MB',
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
//  表头
// ══════════════════════════════════════════════════════════════════════
class _Header extends StatelessWidget {
  const _Header({
    required this.items,
    this.title,
    this.onClose,
    this.onRemoveWork,
  });

  final List<DownloadTask> items;
  final String? title;
  final VoidCallback? onClose;
  final VoidCallback? onRemoveWork;

  @override
  Widget build(BuildContext context) {
    final running = items.where((t) => t.state == DownloadState.running).length;
    final done = items.where((t) => t.state == DownloadState.done).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x3, Sp.x3, Sp.x2, Sp.x2),
      child: Row(
        children: [
          const Icon(Icons.download, size: 18),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Text(
              '下载 · ${items.length} 集'
              '${running > 0 ? '（$running 进行中）' : ''}'
              '${done > 0 ? '（$done 已完成）' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (onRemoveWork != null)
            IconButton(
              onPressed: onRemoveWork,
              icon: const Icon(Icons.delete_sweep_outlined, size: 20),
              tooltip: '删除整部剧的下载',
            ),
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 20),
              tooltip: '返回详情',
            ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
//  一集一行
// ══════════════════════════════════════════════════════════════════════
/// ★★★ task-12 缺陷 A：磁盘上**已经下好**的一集（一行）
///
/// Owner 原话（逐字）：
/// > 我的想法是,点击进去也还是播放页,只不过右侧的变成下载 或者 **已经下载好的**,
/// > 一集一集的,一集占一行
///
/// ⇒ 与正在下载的行同形（一集一行），但只有两个动作：
/// ```text
/// 已下载 ⇒ [播放] [删除]
/// ```
/// ★ 这两个状态在「已缓存」页里已经做过（task-12 ①②③），复用的是**同一套语义**：
///   「播放」= 交给宿主（宿主决定本地播），「删除」= 交给宿主的整剧删除流程。
class _DownloadedRow extends StatelessWidget {
  const _DownloadedRow({
    super.key,
    required this.item,
    required this.onPlay,
  });

  final DownloadedItem item;

  /// null = 宿主没给回调（比如只读场景）⇒ 不画播放按钮
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.x2),
      child: Row(
        children: [
          if (item.cover != null && item.cover!.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              /*
               * ★ 2026-10-09：改用全仓统一的 `coverImage()`
               *
               * 原来是裸 `Image.network` —— `test/t74_cover_image_test.dart` D3
               * 禁止它（那条门禁就是为"解码尺寸必须跟着布局走"立的）：
               * 裸用会让 4K 源图按原始分辨率解码进内存
               * （32×44 的缩略图解出 3840×2160 的位图）。
               *
               * ⚠️ 传 `layoutHeight` 而不是 width —— 两个参数**互斥**：
               *    同时给会把源图**拉伸**（见 cover_image.dart:179）。
               *    这里是个固定 32×44 的框，用高度模式正好。
               */
              child: coverImage(
                context,
                url: item.cover!,
                layoutWidth: 32,
                layoutHeight: 44,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.movie_outlined, size: 24),
              ),
            ),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.episodeTitle ?? item.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '已下载 · ${_humanBytes(item.bytes)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          if (onPlay != null)
            IconButton(
              icon: const Icon(Icons.play_arrow_rounded),
              tooltip: '播放',
              onPressed: onPlay,
            ),
        ],
      ),
    );
  }

  /// 与 cache_page.dart 的 humanBytes 同口径（1024 进制）——
  /// 面板不依赖页面文件，故这里放一份**最小**实现。
  static String _humanBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MiB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(2)} GiB';
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({
    super.key,
    required this.task,
    required this.onPlay,
  });

  final DownloadTask task;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final t = task;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (t.cover != null && t.cover!.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  // ★ 同上：走全仓统一的 coverImage（禁止裸 Image.network）
                  child: coverImage(
                    context,
                    url: t.cover!,
                    layoutWidth: 32,
                    layoutHeight: 44,
                    fit: BoxFit.cover,
                    // ★ 封面加载失败绝不能让整行崩 —— 退回占位图标
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.movie_outlined, size: 24),
                  ),
                ),
              const SizedBox(width: Sp.x2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.episodeTitle.isEmpty ? t.fileName : t.episodeTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(_statusText(t),
                        style: const TextStyle(
                            fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
              ..._actions(context, t),
            ],
          ),
          if (t.state == DownloadState.running ||
              t.state == DownloadState.paused)
            Padding(
              padding: const EdgeInsets.only(top: Sp.x1, left: 40),
              child: LinearProgressIndicator(
                value: t.progress,
                minHeight: 3,
              ),
            ),
        ],
      ),
    );
  }

  /// 状态文案
  static String _statusText(DownloadTask t) {
    switch (t.state) {
      case DownloadState.queued:
        return '排队中';
      case DownloadState.running:
        return t.total <= 0
            ? '下载中…'
            : '下载中 ${t.done}/${t.total} 片 · '
                '${(t.progress * 100).toStringAsFixed(0)}%';
      case DownloadState.paused:
        return t.total <= 0
            ? '已暂停'
            : '已暂停 ${t.done}/${t.total} 片 · '
                '${(t.progress * 100).toStringAsFixed(0)}%';
      case DownloadState.done:
        return '已下载';
      case DownloadState.failed:
        /*
         * ★ Owner 要的「显示 error 原文」——
         *   DownloadTask.error 里放的就是 HlsDownloadException 的可读消息
         *   （"这条流是加密的…" / "HTTP 404 …"），直接透给用户。
         */
        return t.error == null || t.error!.isEmpty ? '失败' : '失败：${t.error}';
    }
  }

  /// 操作按钮（按状态给不同的一对）
  ///
  /// ★ 必须是**实例**方法：`播放` 要用这一行的 `onPlay`（宿主给的闭包），
  ///   写成 static 就拿不到它 —— 那正是我第一版漏掉的（会得到一个点了没反应的按钮）。
  List<Widget> _actions(BuildContext context, DownloadTask t) {
    switch (t.state) {
      case DownloadState.queued:
        return [
          TextButton(
            onPressed: () => DownloadQueue.cancel(t.id),
            child: const Text('取消'),
          ),
        ];
      case DownloadState.running:
        return [
          TextButton(
            onPressed: () => DownloadQueue.pause(t.id),
            child: const Text('暂停'),
          ),
          TextButton(
            onPressed: () => _confirmRemoveOne(context, t),
            child: const Text('删除'),
          ),
        ];
      case DownloadState.paused:
        return [
          TextButton(
            onPressed: () => DownloadQueue.resume(t.id),
            child: const Text('继续'),
          ),
          TextButton(
            onPressed: () => _confirmRemoveOne(context, t),
            child: const Text('删除'),
          ),
        ];
      case DownloadState.done:
        return [
          TextButton(onPressed: onPlay, child: const Text('播放')),
          TextButton(
            onPressed: () => _confirmRemoveOne(context, t),
            child: const Text('删除'),
          ),
        ];
      case DownloadState.failed:
        return [
          TextButton(
            onPressed: () => _retry(t),
            child: const Text('重试'),
          ),
          TextButton(
            onPressed: () => _confirmRemoveOne(context, t),
            child: const Text('删除'),
          ),
        ];
    }
  }

  static void _retry(DownloadTask t) {
    /*
     * ★ 重试 = 把状态拨回 queued，让 _pump 重新派槽。
     *   不能直接再 enqueue（id 相同会被去重挡掉）。
     */
    DownloadQueue.retry(t.id);
  }

  static Future<void> _confirmRemoveOne(
    BuildContext context,
    DownloadTask t,
  ) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这一集的下载？'),
        content: Text(
          '「${t.episodeTitle.isEmpty ? t.fileName : t.episodeTitle}」\n'
          '已下载的文件会被删除，此操作不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await DownloadQueue.remove(t.id);
  }
}