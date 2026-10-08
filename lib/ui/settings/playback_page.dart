// ═══════════════════════════════════════════════════════════════════════
//  二级页：播放与下载 —— task-18 ③④⑤（2026-10-04）
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话（m13330，配截图）：
// > 这些功能也可以抄一下
//
// 截图里的后三项：
// ```text
// ③ 片段下载并发   0–8 滑杆，默认 4
// ④ 缓存上限       64 / 128 / 256 / 512 MB
// ⑤ 分享日志
// ```
//
// ═══════════════════════════════════════════════════════════════════════
//  ★★ 先说清楚：原版（D:\WishProject\cctv_to_client）**没有这三项**
// ═══════════════════════════════════════════════════════════════════════
//
// 不是"还没找到"，是**确实不存在** —— grep 证据：
// ```text
// 「片段下载」 0 命中      「下载并发」 0 命中
// 「缓存上限」 0 命中      「分享日志」 0 命中
// ```
// 而且 Flutter 侧的产品代码里**原本也没有任何下载层**：
// ```text
// rust/sourin_core/src/  download 只命中 backup.rs:396 dirs_download()（系统下载目录）
//                        cache   只命中 proxy.rs:522/532 测试函数名、cctv.rs:987 注释
// lib/                  「下载」5 处、「片段」2 处，全是注释/文案
//                       sourin_api.dart:1853 ProxyCache 是**进程内配置缓存**，与磁盘无关
// ```
// ⇒ 这三项是**能力新增**，没有可抄的实现。所以本页的每一项都必须
//   有**真实生效路径**，不能只做一个存进 prefs 的死开关。

// ═══════════════════════════════════════════════════════════════════════
//  ③ 片段下载并发 —— 真实生效路径
// ═══════════════════════════════════════════════════════════════════════
//
// 落点是 `lib/core/clip_download.dart` 的 `ClipDownloader`：
// ```text
// ClipDownloader.download(...)  →  _withSlot(body)  →  真正的 HTTP 下载
// ```
// `_withSlot` 是**手写并发池**（不用 Future.wait —— 那会一次性打完）：
// 上限**每次循环重读**，所以用户把滑杆从 4 拉到 1 时，
// 已经在排队的那几个任务会**立刻**按新上限收敛，不需要重启。
//
// 产品里的**真实调用方**是播放器：播放设置面板（PlayerSettingsSheet）
// 的「下载本集到缓存」按钮 → `player_page.dart` 的 `_downloadClip()`
// → `ClipDownloader.download(...)`（带当前流的 url 与 headers）。
//
// ★ 2026-10-04 订正（Lead 审计 team-message-914508ce【中】第 2 条）：
//   上面这句**原先**写的是「用户把并发调到 1，再点两次下载，第二个就真的在等
//   第一个」—— 当时 `_downloadClip()` 开头有一句 `if (_clipDownloading) return;`
//   的**全局**重入守卫，第二次点击被吞掉，根本进不到池子 ⇒ 那句话是错的。
//
//   现在守卫已改成**按流地址（url）去重**（`player_page.dart` 的 `_clipRunning`
//   集合，键 = `st.url`），面板按钮也**不再**在下载中禁用，所以：
//   · 同一集的同一条流连点两次 → 第二次提示「这一集已经在下载了」（不重复下）；
//   · **换一集 / 换源**再点 → 两个 `download()` 真的同时在池子里，滑杆从此可观测。
//   ⇒ 从 UI 起两个并发下载需要**两个不同的流地址**，这一点如实写在这里。
//   （起初键用的是文件名 —— android-phone 发现标题为空时会回落成 `clip.mp4`，
//    两个无标题的集会撞名；Lead 裁决后改用 url，见 player_page.dart 那段注释。）
//
//   `maxObservedActive >= 2` 的判据在 `test/task18_clip_concurrency_test.dart` 里
//   （android-phone 独立写的：本地起 HttpServer，**服务端自己数并发连接**，
//    走公开 API `ClipDownloader.download()` —— 不是探针钩子路径）。
//
// `0 = 不限制`（不是"禁止下载"）—— 理由写在 clip_download.dart 的文件头。

// ═══════════════════════════════════════════════════════════════════════
//  ④ 缓存上限 —— 真实生效路径
// ═══════════════════════════════════════════════════════════════════════
//
// 每次 `ClipDownloader.download` 成功后都会 `await enforceCacheLimit()`：
// 按 mtime 从**最旧**开始删，直到总量 <= 上限。上限同样**每次重读**。
// 本页另外提供「立即按上限清理」和「清空缓存」两个按钮，
// 以及**真实读数**（占用字节 / 文件数），不是写死的文本。

// ═══════════════════════════════════════════════════════════════════════
//  ⑤ 分享日志 —— 「分享」在这里落成什么
// ═══════════════════════════════════════════════════════════════════════
//
// `pubspec.yaml` 里**没有 share_plus**（`pubspec.lock` ABSENT）——
// 本仓库的依赖是锁死的，不新增依赖 ⇒ 系统分享面板这条路走不通。
//
// 所以「分享日志」落成**两条都能真正拿到文件内容**的路径：
// ```text
// ① 导出为文件：file_selector 的 getSaveLocation（系统"另存为"对话框）
//               → 平台没有这个能力时降级 getDirectoryPath → 再兜底写应用目录
// ② 复制到剪贴板：Clipboard.setData，用户自己粘到聊天窗口里
// ```
// 这两条的先例都在本仓库里：
// ```text
// 保存对话框  lib/ui/widgets/backup_panel.dart:239-288（含 Android 降级与"把完整路径告诉用户"）
// 剪贴板      lib/shell.dart:5278 / lib/ui/settings_page.dart:1533（后面跟 _flash('已复制')）
// ```
// 导出完成后本页会显示**真实落盘路径 + 真实字节数** ——
// 这是"文件非空"的证据，不是一句"已导出"。

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/app_log.dart';
import '../../core/clip_download.dart';
import 'export_dir.dart';
import '../tokens.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';
// ★ ④「回读 mpv 设置」按钮直接调 player_page 的探针钩子 —— 那是**生产**
//   播放页里的 `_readMpvCacheSettings()`，不是这里另写一份。
import '../player_page.dart';

/// 日志文件类型（Windows 的保存框靠它过滤；其它平台忽略）
const List<XTypeGroup> _logGroups = <XTypeGroup>[
  XTypeGroup(label: '日志文件', extensions: <String>['log', 'txt']),
  XTypeGroup(label: '全部文件'),
];

class PlaybackSettingsPage extends StatefulWidget {
  const PlaybackSettingsPage({super.key});

  @override
  State<PlaybackSettingsPage> createState() => _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends State<PlaybackSettingsPage> {
  int _concurrency = ClipDownloader.concurrency;
  int _cacheLimit = ClipDownloader.cacheLimitMb;

  int _cacheBytes = 0;
  int _cacheFiles = 0;
  bool _cacheBusy = false;

  /// ④ mpv（播放器）自己的解复用缓存占用 —— 与 _cacheBytes 是两笔账
  int _mpvBytes = 0;

  /// ★ 截图目录（shots）占用 —— Owner 第 6 条之前这个数**根本不存在**：
  ///   设置页看不见它，上限也不管它。探针 P2 实测它躺着 209715200 字节
  ///   而 `enforceCacheLimit()` 一个字节都不管。
  int _shotsBytes = 0;

  /// 三个目录的合计（只用于「和上限比一比」，分项读数才是用户要看的）。
  int _totalBytes = 0;
  String _mpvReadback = '';
  bool _mpvReadBusy = false;

  bool _logBusy = false;
  String? _toast;
  String _lastExportPath = '';
  int _lastExportBytes = 0;

  @override
  void initState() {
    super.initState();
    _refreshCache();
  }

  /// 读**真实**缓存占用（不是估算，也不是写死的文本）
  Future<void> _refreshCache() async {
    try {
      final bytes = await ClipDownloader.cacheBytes();
      final es = await ClipDownloader.cacheEntries();
      final mpv = await ClipDownloader.mpvCacheBytes();
      final shots = await ClipDownloader.shotsBytes();
      if (!mounted) return;
      setState(() {
        _cacheBytes = bytes;
        _cacheFiles = es.length;
        _mpvBytes = mpv;
        _shotsBytes = shots;
        _totalBytes = bytes + mpv + shots;
      });
    } catch (e) {
      AppLog.write('DL', '读缓存占用失败：$e');
    }
  }

  void _flash(String msg) {
    if (!mounted) return;
    setState(() => _toast = msg);
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _toast == msg) setState(() => _toast = null);
    });
  }

  // ══════════════════════════════════════════════════════════════════════
  //  ⑤ 导出 / 复制
  // ══════════════════════════════════════════════════════════════════════

  /// 系统"另存为"对话框 → 返回用户选定的完整路径
  ///
  /// 返回 `null` = 用户取消（不是错误）。
  /// 平台没有这个能力时走 `_pickSavePathFallback`（照抄 backup_panel.dart:239-288）。
  Future<String?> _pickSavePath(String suggestedName) async {
    try {
      final loc = await getSaveLocation(
        acceptedTypeGroups: _logGroups,
        suggestedName: suggestedName,
      );
      if (loc == null) return null;
      return _ensureLog(loc.path);
    } on UnimplementedError {
      // Android：file_selector_android 没实现 getSaveLocation —— 不是错误，是没这个能力
      AppLog.write('LOG', '本平台无 getSaveLocation → 降级选目录');
    } catch (e) {
      AppLog.write('LOG', 'getSaveLocation 异常: $e → 降级');
    }
    return _pickSavePathFallback(suggestedName);
  }

  Future<String?> _pickSavePathFallback(String suggestedName) async {
    try {
      final dir = await getDirectoryPath(confirmButtonText: '保存到此处');
      if (dir == null) return null;
      if (dir.isNotEmpty) {
        /*
         * ★★ task-24 缺陷 A 的根因就在这一行（原先是直接 `_join` 返回）：
         *
         * SAF 的 `getDirectoryPath()` 返回的是**真实文件系统路径**
         * （如 `/storage/emulated/0/Movies`），不是 content:// URI。
         * 本应用 `AndroidManifest.xml` 里**没有** MANAGE_EXTERNAL_STORAGE，
         * targetSdk=36 的分区存储下，dart:io 往那个路径写文件必失败：
         * ```text
         * PathAccessException: Cannot open file, path =
         *   '/storage/emulated/0/Movies/sourin-log-20261004-150033.log'
         *   (OS Error: Operation not permitted, errno = 1)
         * ```
         * ⇒ 「用户选了目录」**不等于**「我们能写那个目录」。
         *   所以这里**先探再写**（真的写一次空文件再删掉），
         *   探不通就往下走兜底目录，而不是把异常丢给用户。
         */
        final target = _join(dir, suggestedName);
        if (await probeWritableFile(target)) return target;
        AppLog.write('LOG', '用户选的目录不可写（分区存储）→ 走兜底：$dir');
      }
    } catch (e) {
      AppLog.write('LOG', 'getDirectoryPath 不可用: $e');
    }
    /*
     * 兜底：写进**我们能写的**目录（`export_dir.dart` 里探过再返回）。
     * ⚠️ 必须把完整路径显示给用户 —— 静默存到他找不到的地方，
     *    他会以为"导出没成功"。
     */
    final dir = await writableExportDir();
    _flash(dir.userVisible
        ? '已存到 ${dir.path}'
        : '已存到应用目录（系统文件管理器看不到），完整路径见下方「最近导出」');
    return _join(dir.path, suggestedName);
  }

  /// Windows 的系统保存框**不会**自动补后缀 ⇒ 手动补 `.log`
  /// （同款先例：backup_panel.dart:225-226 `_ensureZip`）
  static String _ensureLog(String path) =>
      path.toLowerCase().endsWith('.log') ? path : '$path.log';

  static String _join(String dir, String name) {
    final sep = Platform.pathSeparator;
    if (dir.endsWith(sep) || dir.endsWith('/')) return '$dir$name';
    return '$dir$sep$name';
  }

  static String _stampName() {
    final t = DateTime.now();
    String p2(int n) => n.toString().padLeft(2, '0');
    return 'sourin-log-${t.year}${p2(t.month)}${p2(t.day)}-'
        '${p2(t.hour)}${p2(t.minute)}${p2(t.second)}.log';
  }

  Future<void> _exportLog() async {
    if (_logBusy) return;
    setState(() => _logBusy = true);
    try {
      // 先写一行"这次导出"本身 —— 导出的文件里要能看到它
      AppLog.write('LOG', '导出日志（${AppLog.lineCount} 行）');
      final path = await _pickSavePath(_stampName());
      if (path == null) {
        _flash('已取消');
        return;
      }
      final f = await AppLog.exportToFile(intoPath: path);
      final len = await f.length();
      if (!mounted) return;
      setState(() {
        _lastExportPath = f.path;
        _lastExportBytes = len;
      });
      // ★ 把**真实落盘路径**一起告诉用户（task-24 验收：路径必须可见）
      _flash('已导出 $len 字节 → ${f.path}');
    } catch (e) {
      _flash('导出失败：$e');
      AppLog.write('LOG', '导出失败：$e');
    } finally {
      if (mounted) setState(() => _logBusy = false);
    }
  }

  Future<void> _copyLog() async {
    if (_logBusy) return;
    setState(() => _logBusy = true);
    try {
      final text = AppLog.exportText();
      await Clipboard.setData(ClipboardData(text: text));
      _flash('已复制 ${AppLog.lineCount} 行到剪贴板');
    } catch (e) {
      _flash('复制失败：$e');
    } finally {
      if (mounted) setState(() => _logBusy = false);
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  build
  // ══════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SettingsSubPage(
      title: '播放与下载',
      subtitle: '片段下载并发 · 缓存上限 · 分享日志',
      children: [
        _downloadBlock(colors),
        const SizedBox(height: Sp.x5),
        _cacheBlock(colors),
        const SizedBox(height: Sp.x5),
        _logBlock(colors),
        if (_toast != null) ...[
          const SizedBox(height: Sp.x4),
          Text(
            _toast!,
            style: TextStyle(fontSize: FontSizes.sm, color: colors.primary),
          ),
        ],
      ],
    );
  }

  // ── ③ 片段下载并发 ────────────────────────────────────────────────────
  Widget _downloadBlock(ColorScheme colors) {
    return SettingsBlock(
      title: '片段下载并发',
      trailing: Text(
        '同时最多 ${ClipDownloader.concurrencyLabel(_concurrency)}',
        style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
      ),
      children: [
        Text(
          '限制**同时进行**的片段下载任务数。排队中的任务不占带宽，'
          '前面的下载完成一个，后面的才开始一个。',
          style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: Sp.x4),
        Row(
          children: [
            Text(
              '并发数',
              style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
            ),
            Expanded(
              child: Slider(
                value: _concurrency.toDouble().clamp(0, 8),
                min: 0,
                max: 8,
                divisions: 8,
                label: ClipDownloader.concurrencyLabel(_concurrency),
                onChanged: (v) => setState(() {
                  _concurrency = v.round();
                  ClipDownloader.setConcurrency(_concurrency);
                }),
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                ClipDownloader.concurrencyLabel(_concurrency),
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x3),
        const SettingsInfoRow(
          label: '0 表示',
          value: '不限制（同时开满所有任务）',
        ),
        SettingsInfoRow(
          label: '当前正在跑',
          value: '${ClipDownloader.activeCount} 个',
        ),
        SettingsInfoRow(
          label: '本次会话峰值',
          value: '${ClipDownloader.maxObservedActive} 个',
        ),
        SettingsInfoRow(
          label: '已完成',
          value: '${ClipDownloader.completedCount} 个',
        ),
        const SizedBox(height: Sp.x3),
        Text(
          /*
           * ★ 如实说明入口在哪
           *
           * 这一段如果只写"并发生效了"用户没法验证 ——
           * 必须告诉他从哪点能触发下载，否则这个滑杆看起来就是死的。
           */
          '片段缓存入口：播放页 → 播放设置（齿轮）→ 「下载本集到缓存」。'
          '那里用的就是上面这个上限。\n\n'
          '★ 整片下载（详情页头部的「下载」按钮）**不占**这个上限 —— '
          '它落在「视频 / 源影 / <剧名>/」下，是用户自己的文件，'
          '不会被自动淘汰。',
          style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }

  // ── ④ 缓存上限 ────────────────────────────────────────────────────────
  Widget _cacheBlock(ColorScheme colors) {
    return SettingsBlock(
      title: '缓存上限与管理',
      trailing: Text(
        '合计 ${ClipDownloader.humanBytes(_totalBytes)} · 上限 $_cacheLimit MB',
        style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
      ),
      children: [
        Text(
          '应用数据目录里有**三个**缓存目录，用途不同、能不能删也不同。'
          '下面每个数字都是**真实读盘**得到的，不是估算。',
          style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: Sp.x4),
        SettingsGestureChoice<int>(
          label: '上限',
          options: ClipDownloader.cacheLimitOptions,
          value: _cacheLimit,
          labelOf: (v) => '$v MB',
          onChanged: (v) {
            setState(() {
              _cacheLimit = v;
              ClipDownloader.setCacheLimitMb(v);
            });
            /*
             * ★ 改上限之后**必须真的清一次**（Owner 第 6 条 / 探针 P7）。
             *   旧实现只写偏好、不淘汰：探针 P7 把上限从 256MB 改成 64MB，
             *   占用仍停在 104857600 字节不动 —— 用户以为「我调小了所以清了」，
             *   实际磁盘一个字节都没变。现在改成「写偏好 + 立刻按新上限清」。
             */
            _applyLimitNow();
          },
        ),
        const SizedBox(height: Sp.x4),
        /*
         * ★ 三个目录**分项**报（铁律，见 clip_download.dart 的 ④b 注释）：
         *   clip-cache 用户看得见的成品（可淘汰）
         *   mpv-cache  播放器临时解复用（删了只是重缓冲）
         *   shots      用户主动截的图（**不可再生**）
         *   合计只用来「和上限比一比」，绝不能替代分项 ——
         *   用户要判断「我该清哪个」必须看到分项。
         */
        SettingsInfoRow(
          label: '片段缓存',
          value: '${ClipDownloader.humanBytes(_cacheBytes)}'
              '（$_cacheFiles 个文件）· clip-cache',
        ),
        SettingsInfoRow(
          label: '播放器缓存',
          value: '${ClipDownloader.humanBytes(_mpvBytes)} · mpv-cache',
        ),
        SettingsInfoRow(
          label: '截图',
          value: '${ClipDownloader.humanBytes(_shotsBytes)} · shots',
        ),
        SettingsInfoRow(
          label: '合计',
          value: '${ClipDownloader.humanBytes(_totalBytes)}'
              ' / 上限 $_cacheLimit MB'
              '${_overLimit ? '（已超限）' : ''}',
        ),
        const SizedBox(height: Sp.x3),
        Wrap(
          spacing: Sp.x3,
          runSpacing: Sp.x2,
          children: [
            OutlinedButton(
              onPressed: _cacheBusy ? null : _applyLimitNow,
              child: const Text('按上限清理（三个目录）'),
            ),
            OutlinedButton(
              onPressed: _cacheBusy ? null : _clearCache,
              child: const Text('清空片段缓存'),
            ),
            OutlinedButton(
              onPressed: _cacheBusy ? null : _clearMpvCache,
              child: const Text('清空播放器缓存'),
            ),
            TextButton(
              onPressed: _cacheBusy ? null : _refreshCache,
              child: const Text('刷新读数'),
            ),
            TextButton(
              onPressed: _mpvReadBusy ? null : _readMpvNow,
              child: const Text('回读 mpv 设置'),
            ),
          ],
        ),
        const SizedBox(height: Sp.x3),
        Text(
          /*
           * ★ 「清理」到底清了什么，必须逐字说清（Owner 第 6 条「可以进行
           *   管理」）。三档的删除代价差别很大，混成一句「已清理」就是在骗人。
           */
          '「按上限清理」只腾出**超限的那部分**，顺序是：'
          '① 播放器缓存（删了只是重缓冲）→ ② 片段缓存（删了要重新下）'
          '→ ③ 截图（**不可再生**，只在①②都不够时才动）。'
          '「清空片段缓存」只清 clip-cache，**不碰**截图与播放器缓存。',
          style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
        ),
        if (_mpvReadback.isNotEmpty) ...[
          const SizedBox(height: Sp.x4),
          SettingsInfoRow(label: 'mpv 回读', value: _mpvReadback),
        ],
      ],
    );
  }

  /// ④ 回读 mpv 实际生效的缓存设置，并与「上限」比对
  ///
  /// # 为什么必须回读（这是 ④ 唯一的验收判据）
  ///
  /// `setProperty` 的返回值被 media_kit **丢弃**（`real.dart:1223-1246`）
  /// —— 设不进去**不会抛异常**。所以「我设了」永远不能证明「它生效了」。
  /// 只能读回来比。
  ///
  /// ★ `getProperty` 读不到时返回**空串**且**不抛**（`real.dart:1278`）
  ///   ⇒ 空串一律按**失败**处理，绝不把「没读到」当成「设对了」。
  ///
  /// ★ 播放器没在播放时 `_livePlayerState` 为 null（或 mpv 还没建起来），
  ///   这时如实说「读不到」，**不**编一个数字出来。
  Future<void> _readMpvNow() async {
    setState(() => _mpvReadBusy = true);
    try {
      final m = await debugPlayerReadMpvCacheForProbe();
      if (m.isEmpty) {
        setState(() => _mpvReadback = '');
        _flash('读不到：播放器还没起来（先去播放页播一个片）');
        return;
      }
      final parts = <String>[];
      for (final e in m.entries) {
        parts.add('${e.key}=${e.value.isEmpty ? '(读不到)' : e.value}');
      }
      setState(() => _mpvReadback = parts.join(' · '));
      final want = ClipDownloader.cacheLimitBytes;
      final raw = m[ClipDownloader.kMpvMaxBytesKey] ?? '';
      final got = ClipDownloader.parseMpvByteSize(raw);
      if (got == null) {
        _flash('回读失败：mpv 没有返回 demuxer-max-bytes（原始串「$raw」）');
      } else if (got == want) {
        _flash('回读一致：mpv=$got 字节，上限=$want 字节');
      } else {
        _flash('回读不一致：mpv=$got 字节，上限=$want 字节');
      }
    } finally {
      if (mounted) setState(() => _mpvReadBusy = false);
    }
  }

  /// 三个目录合计是否已超上限（UI 用它给一个「已超限」的显式标记）。
  bool get _overLimit => _totalBytes > _cacheLimit * 1024 * 1024;

  /// ★ 第 6 条：按上限清理 —— **三个目录一起**（不再只管 clip-cache）。
  ///
  /// 淘汰顺序见 `ClipDownloader.sweepAllLimits()` 的 doc：
  /// ① 播放器缓存（删了只是重缓冲）→ ② 片段缓存（要重新下）
  /// → ③ 截图（**不可再生**，最后一档）。
  /// 每个目录**只腾出超限的那部分**，不是各自裁到上限。
  Future<void> _applyLimitNow() async {
    if (_cacheBusy) return;
    setState(() => _cacheBusy = true);
    try {
      final r = await ClipDownloader.sweepAllLimits();
      await _refreshCache();
      /*
       * ★ 结果必须**逐项**说清删了什么（尤其删了截图要明说）。
       *   旧实现只说「已删除 N 个最旧文件」，用户无从知道删的是哪一类。
       */
      _flash(ClipDownloader.describeSweep(r));
    } catch (e) {
      _flash('清理失败：$e');
    } finally {
      if (mounted) setState(() => _cacheBusy = false);
    }
  }

  /// 清空**片段缓存**（clip-cache）。
  ///
  /// ⚠️ 只动 clip-cache：**不许**顺手删截图或播放器缓存。
  ///    `test/t63_shot_save_test.dart:155-174` 逐字钉住了这条。
  Future<void> _clearCache() async {
    setState(() => _cacheBusy = true);
    try {
      final n = await ClipDownloader.clearCache();
      await _refreshCache();
      _flash('已清空片段缓存（clip-cache）$n 个文件；截图与播放器缓存未动');
    } catch (e) {
      _flash('清空失败：$e');
    } finally {
      if (mounted) setState(() => _cacheBusy = false);
    }
  }

  /// 清空**播放器（mpv）解复用缓存** —— 不动片段与截图。
  Future<void> _clearMpvCache() async {
    setState(() => _cacheBusy = true);
    try {
      final n = await ClipDownloader.clearMpvCache();
      await _refreshCache();
      _flash('已清空播放器缓存（mpv-cache）$n 个文件；片段与截图未动');
    } catch (e) {
      _flash('清空失败：$e');
    } finally {
      if (mounted) setState(() => _cacheBusy = false);
    }
  }

  // ── ⑤ 分享日志 ────────────────────────────────────────────────────────
  Widget _logBlock(ColorScheme colors) {
    return SettingsBlock(
      title: '分享日志',
      trailing: Text(
        '${AppLog.lineCount} 行',
        style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
      ),
      children: [
        Text(
          '本应用没有接入系统分享面板（依赖里没有分享插件），'
          '所以「分享」落成两条路：**导出成 .log 文件**，或者'
          '**复制到剪贴板**后自己粘贴。',
          style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: Sp.x4),
        Wrap(
          spacing: Sp.x3,
          runSpacing: Sp.x2,
          children: [
            FilledButton.icon(
              onPressed: _logBusy ? null : _exportLog,
              icon: const Icon(Icons.save_alt, size: 18),
              label: const Text('导出为日志文件'),
            ),
            OutlinedButton.icon(
              onPressed: _logBusy ? null : _copyLog,
              icon: const Icon(Icons.copy_all, size: 18),
              label: const Text('复制到剪贴板'),
            ),
          ],
        ),
        if (_lastExportPath.isNotEmpty) ...[
          const SizedBox(height: Sp.x4),
          SettingsInfoRow(label: '最近导出', value: _lastExportPath),
          SettingsInfoRow(
            label: '文件大小',
            value: '$_lastExportBytes 字节',
          ),
        ],
        const SizedBox(height: Sp.x3),
        Text(
          '日志同时按天写进应用数据目录的 logs/ 下'
          '（sourin-YYYY-MM-DD.log），每次导出都会把当前内容整份写出。',
          style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}
