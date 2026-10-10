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
//  ⑤ 日志与反馈 —— 用户拿去向作者反馈的那份东西
// ═══════════════════════════════════════════════════════════════════════
//
// `pubspec.yaml` 里**没有 share_plus**（`pubspec.lock` ABSENT）——
// 本仓库的依赖是锁死的，不新增依赖 ⇒ 系统分享面板这条路走不通。
//
// 所以「分享」落成**三条都能真正拿到内容**的路径：
// ```text
// ① 导出为文件：file_selector 的 getSaveLocation（系统"另存为"对话框）
//               → 平台没有这个能力时降级 getDirectoryPath → 再兜底写应用目录
// ② 复制到剪贴板：Clipboard.setData，用户自己粘到聊天窗口里
// ③ 复制环境信息：版本 / 系统 / 设备形态 / 数据目录（2026-10-09 新增）
// ```
// 这两条的先例都在本仓库里：
// ```text
// 保存对话框  lib/ui/widgets/backup_panel.dart:239-288（含 Android 降级与"把完整路径告诉用户"）
// 剪贴板      lib/shell.dart:5278 / lib/ui/settings_page.dart:1533（后面跟 _flash('已复制')）
// ```
// 导出完成后本页会显示**真实落盘路径 + 真实字节数** ——
// 这是"文件非空"的证据，不是一句"已导出"。
//
// ───────────────────────────────────────────────────────────────────────
//  ★★★ 2026-10-09（task-14）复核「日志够不够拿去向作者反馈」—— 改了四处
// ───────────────────────────────────────────────────────────────────────
//
// 先说结论：**核心能力早就在，缺的是「反馈」这层语义**。
// 复核过的事实（不是推测）：
// ```text
// · 日志确实在写：真机数据目录里 sourin-2026-10-09.log = 1 445 535 字节 / 13 891 行
//   （tag 分布 DL=13741 PLAY=66 LIVE=6；含真实起播 URL、下载目录、缓存淘汰记录）
// · 导出/复制两条路都在，且都有真实落盘读数（上一轮 task-24 已修 Android 分区存储）
// · 但整页**没有任何一句话**告诉用户「出问题了该把这个发给作者」——
//   入口名「分享日志」是**功能视角**（这里能分享），不是**场景视角**（我出问题了，怎么办）。
// · 文件本身也缺上下文：旧表头只有一行「Sourin 播放器日志导出 <时间>」+ 内存条数，
//   作者拿到后还得回头问「你什么版本 / 什么系统 / 数据目录在哪」。
// ```
//
// 所以本轮只补**缺口**，不动已经工作的机制：
// ```text
// ① 区块改名「分享日志」→「日志与反馈」，并加一句场景引导
//    （「出问题时请把这份日志发给作者」）—— 用户是先遇到问题、再回来找日志的
// ② 导出/复制的**表头**换成 `_logHeader()`：版本 / 系统 / 设备形态 / 数据目录
//    全部走**已有 API 真读**（核心版本走 FFI 探针、系统走 dart:io、
//    设备形态走 Device.kind、数据目录与下载缓存同一份解析）
// ③ 新增「复制环境信息」按钮 + 屏幕上**默认就画出来**的读数卡
// ④ 尾注写明日志目录，并说明可以直接把那个目录里的 .log 发给作者
// ```
//
// ⚠️ **没有**做、也不该做的两件事（如实记在这里）：
// ```text
// · 没有在设置一级页再开一个「日志」入口 ——
//   `test/task18_entry_test.dart` 把「一级页恰有一个『播放与下载』入口」
//   钉成断言（三条端形态各跑一次）；新增同名入口会让它读到 2。
//   而现在那一行的副标题已经写明「…· 日志与反馈」，入口可见性够了。
// · 没有去改 `lib/core/app_log.dart`（不在本任务的写范围内），
//   所以表头是在**这一页**拼好再交给 `exportText(header:)` 的。
// ```

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/app_log.dart';
import '../../core/clip_download.dart';
import '../../core/device.dart';
import '../../core/download_dir.dart';
import '../../core/download_queue.dart';
import '../../core/sourin_api.dart';
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

  /// ★★★ 2026-10-09（Owner 第 20 条）**整片**下载并发（与上面那个是两笔账）
  ///
  /// 上面 _concurrency 管的是「片段」（几 MB、进缓存、会被淘汰）；
  /// 这个管的是「整片」（详情页头部那个「下载」按钮，几百 MB，
  /// 落在 视频/源影/<剧名>/，是用户自己的文件）。
  /// ⚠️ 两个上限**互不相通**：整片下载不走 ClipDownloader._withSlot，
  ///   它走 DownloadQueue._pump（见 lib/core/download_queue.dart:247 起）。
  int _queueConcurrency = DownloadQueue.concurrency;

  /// 当前**真实生效**的下载目录（不是 pref 里的原值 —— pref 里可能是
  /// 一个建不出来的路径，那时 root() 会退回默认，界面上要显示**退回后**的）。
  String _dlDir = '';

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

  /// ⑤b 「一键复制环境信息」：**刚复制出去的那段文本**（原样显示给用户核对）
  ///
  /// 实测取值（本机 Windows，2026-10-09，`flutter test` 里真跑出来的）：
  /// ```text
  /// 版本      sourin-core 0.1.0   （SourinApi.version → Rust 的 sourin_core_version()）
  /// 系统      windows · "Windows 10 专业工作站版" 10.0 (Build 19045)
  /// 设备形态  桌面（鼠标键盘）     （Device.kind，走平台通道判定）
  /// 数据目录  C:\Users\…\AppData\Roaming\app.sourin.player
  /// ```
  String _envInfo = '';
  bool _envBusy = false;

  /// 环境信息**已读出的四行**（`initState` 里异步填；空列表 = 还没读到）
  List<(String, String)> _envRows = const [];

  @override
  void initState() {
    super.initState();
    _refreshCache();
    _refreshDownloadDir();
    // ★ 环境信息要在**打开这一页时**就画出来（用户反馈前不会先去点按钮）
    unawaited(_refreshEnv());
  }

  /// 读**真实生效**的下载目录（走 DownloadDir.root()，与下载时同一个函数
  /// ⇒ 界面显示的就是文件真的会落到的地方）
  Future<void> _refreshDownloadDir() async {
    try {
      final dir = await DownloadDir.root();
      if (!mounted) return;
      setState(() => _dlDir = dir);
    } catch (e) {
      AppLog.write('DL', '读下载目录失败：$e');
    }
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
      AppLog.write('LOG', '导出日志（${AppLog.lineCount} 行，含环境信息表头）');
      final path = await _pickSavePath(_stampName());
      if (path == null) {
        _flash('已取消');
        return;
      }
      /*
       * ⚠️ 这里**没有**用 `AppLog.exportToFile(intoPath: path)` ——
       *   它**没有** header 形参（只接受 intoPath），而文件开头必须有
       *   环境信息。所以在这里按同一个语义写盘：
       *   `File(path).writeAsString(exportText(...), flush: true)`，
       *   与 `app_log.dart` 里那个 intoPath 分支**逐字一致**
       *   （覆盖写 + flush + 失败照样抛给调用方的 catch）。
       */
      final text = AppLog.exportText(header: await _logHeader());
      final f = File(path);
      await f.writeAsString(text, flush: true);
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
      final text = AppLog.exportText(header: await _logHeader());
      await Clipboard.setData(ClipboardData(text: text));
      _flash('已复制 ${AppLog.lineCount} 行（含环境信息）到剪贴板');
    } catch (e) {
      _flash('复制失败：$e');
    } finally {
      if (mounted) setState(() => _logBusy = false);
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  ⑤b 环境信息（作者最需要的那几行）
  // ══════════════════════════════════════════════════════════════════════

  /// 反馈用的**环境信息**：版本 / 系统 / 设备形态 / 数据目录。
  ///
  /// # 为什么每个字段都是这个来源（没有一个是编的）
  /// ```text
  /// 版本      SourinApi.version → Rust 的 sourin_core_version()，实测 "sourin-core 0.1.0"
  /// 系统      dart:io 的 Platform.operatingSystem + operatingSystemVersion
  /// 设备形态  Device.kind（桌面 / 触摸 / 电视）—— 它决定焦点环、字号、提示区块，
  ///           用户报「按钮点不到」时这一项能直接区分是鼠标还是遥控器
  /// 数据目录  ClipDownloader.dataDir() —— **与下载、缓存、日志同一份解析**
  /// ```
  ///
  /// ⚠️ **不读** `%APPDATA%/app.sourin.player/device-id`：那是同步用的设备标识，
  ///    会被写进用户发到公开 issue 里的日志 —— 这里只报**位置**不报**值**。
  ///
  /// ⚠️ 每一项**各自 try/catch**：核心库没起来时 `SourinApi.version` 会抛，
  ///    但那是「核心没起来」这个事实本身 —— 必须如实写进日志，
  ///    而不是让整段环境信息一起消失。
  Future<List<(String, String)>> _envFields() async {
    final out = <(String, String)>[];

    String version;
    try {
      version = SourinApi.version;
    } catch (e) {
      version = '读不到（核心未加载：$e）';
    }
    out.add(('版本', version));

    var os = Platform.operatingSystem;
    try {
      final v = Platform.operatingSystemVersion.trim();
      if (v.isNotEmpty) os = '$os · $v';
    } catch (_) {}
    out.add(('系统', os));

    out.add(('设备形态', switch (Device.kind) {
      DeviceKind.desktop => '桌面（鼠标键盘）',
      DeviceKind.touchOnly => '触摸端（手机 / 平板）',
      DeviceKind.tv => '电视（遥控器）',
    }));

    String dir;
    try {
      dir = await ClipDownloader.dataDir();
    } catch (e) {
      dir = '读不到：$e';
    }
    out.add(('数据目录', dir));

    return out;
  }

  /// 读一次环境信息并落进 state（`initState` 调；失败如实记日志，不静默）
  Future<void> _refreshEnv() async {
    try {
      final rows = await _envFields();
      if (!mounted) return;
      setState(() => _envRows = rows);
    } catch (e) {
      AppLog.write('LOG', '读环境信息失败：$e');
    }
  }

  /// 环境信息拼成多行文本（「一键复制环境信息」与日志表头共用一份）
  Future<String> _envText() async {
    final b = StringBuffer();
    for (final f in await _envFields()) {
      b.writeln('${f.$1}：${f.$2}');
    }
    return b.toString().trimRight();
  }

  /// 日志导出/复制时的**表头** —— 把环境信息放在最前面。
  ///
  /// ★ 这一条是「够不够拿去向作者反馈」的关键：旧表头只有一行
  ///   「Sourin 播放器日志导出 <时间>」+ 内存条数 —— 作者拿到文件后
  ///   还得回头问用户「你什么版本、什么系统、数据目录在哪」。
  ///   现在这三问的答案都在文件**第一屏**。
  ///
  /// ⚠️ 这里**不写**「内存条数」和那行分隔线 —— `AppLog.exportText` 在表头
  ///    之后**自己**会补这两行（`app_log.dart:226-227`）。写一遍会变成：
  /// ```text
  /// 内存条数：12 / 上限 2000
  /// ------------------------------------------------------------------------
  /// 内存条数：12 / 上限 2000
  /// ------------------------------------------------------------------------
  /// ```
  Future<String> _logHeader() async {
    final b = StringBuffer();
    b.writeln('Sourin 播放器日志导出');
    b.writeln('导出时间：${DateTime.now().toIso8601String()}');
    b.write(await _envText());
    b.writeln();
    return b.toString();
  }

  /// ⑤b 一键复制环境信息（版本 / 系统 / 设备形态 / 数据目录）
  ///
  /// 先例：`lib/ui/settings/about_page.dart` 的「运行信息」区块（同样四项，
  /// 但那一页**没有复制按钮**，用户只能手动选中再 Ctrl+C）。
  Future<void> _copyEnvInfo() async {
    if (_envBusy) return;
    setState(() => _envBusy = true);
    try {
      final text = await _envText();
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      setState(() => _envInfo = text);
      _flash('已复制环境信息（${text.split('\n').length} 行）到剪贴板');
    } catch (e) {
      _flash('复制环境信息失败：$e');
    } finally {
      if (mounted) setState(() => _envBusy = false);
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
      subtitle: '片段下载并发 · 缓存上限 · 日志与反馈',
      children: [
        _downloadBlock(colors),
        const SizedBox(height: Sp.x5),
        _queueBlock(colors),
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

  // ── ★★★ 2026-10-09（Owner 第 20 条）整片下载：目录 + 并发 ─────────────────
  Widget _queueBlock(ColorScheme colors) {
    return SettingsBlock(
      title: '整片下载',
      trailing: Text(
        DownloadQueue.concurrencyLabel(_queueConcurrency),
        style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
      ),
      children: [
        Text(
          '「下载」按钮（详情页头部 / 每一集）落在哪个目录、同时下几集。'
          '与上面「片段下载并发」是**两笔账**：片段进缓存会被自动淘汰，'
          '整片是你自己的文件，永远不会被自动删。',
          style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: Sp.x4),
        Row(
          children: [
            Text(
              '同时下载',
              style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
            ),
            Expanded(
              child: Slider(
                value: _queueConcurrency
                    .toDouble()
                    .clamp(1, DownloadQueue.maxConcurrency.toDouble()),
                min: 1,
                max: DownloadQueue.maxConcurrency.toDouble(),
                divisions: DownloadQueue.maxConcurrency - 1,
                label: DownloadQueue.concurrencyLabel(_queueConcurrency),
                onChanged: (v) => setState(() {
                  _queueConcurrency = v.round();
                  DownloadQueue.setConcurrency(_queueConcurrency);
                }),
              ),
            ),
            SizedBox(
              width: 84,
              child: Text(
                DownloadQueue.concurrencyLabel(_queueConcurrency),
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x3),
        /*
         * ★ 为什么把「1 = 串行」写成说明而不是默认值里的暗坑：
         *   串行是**为了播放不卡**（见 download_queue.dart 文件头），
         *   不是偷懒。用户把 1 拉到 3 时得知道自己在拿带宽换速度。
         */
        const SettingsInfoRow(
          label: '1 表示',
          value: '串行（默认，把带宽让给播放）',
        ),
        SettingsInfoRow(
          label: '当前正在跑',
          value: '${DownloadQueue.activeCount} 个',
        ),
        SettingsInfoRow(
          label: '本次会话峰值',
          value: '${DownloadQueue.debugMaxObservedRunning()} 个',
        ),
        const SizedBox(height: Sp.x3),
        SettingsInfoRow(label: '下载目录', value: _dlDir),
        const SizedBox(height: Sp.x2),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _pickDownloadDir,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('改目录'),
            ),
            const SizedBox(width: Sp.x2),
            TextButton(
              onPressed: _resetDownloadDir,
              child: const Text('恢复默认'),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _dlDir.isEmpty ? null : () => DownloadDir.open(_dlDir),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('打开'),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        const SettingsInfoRow(
          label: '默认目录',
          value: '视频 / 源影（跟随系统）',
        ),
      ],
    );
  }

  /// 选一个新目录（真的建出来才写进 pref —— 建不出来的目录选了也白选）
  Future<void> _pickDownloadDir() async {
    try {
      final picked = await getDirectoryPath(
        initialDirectory: _dlDir.isEmpty ? null : _dlDir,
        confirmButtonText: '选这里',
      );
      if (picked == null) return;
      DownloadDir.setConfiguredDir(picked);
      final dir = await DownloadDir.root();
      if (!mounted) return;
      setState(() => _dlDir = dir);
      _flash(dir == picked
          ? '下载目录已改为 $dir'
          : '这个目录用不了（$picked），已回到默认：$dir');
    } catch (e) {
      _flash('改目录失败：$e');
    }
  }

  Future<void> _resetDownloadDir() async {
    DownloadDir.setConfiguredDir(null);
    final dir = await DownloadDir.root();
    if (!mounted) return;
    setState(() => _dlDir = dir);
    _flash('下载目录已回到默认：$dir');
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

  // ── ⑤ 日志与反馈 ──────────────────────────────────────────────────────
  //
  // ★ 2026-10-09 改名（原「分享日志」）+ 补足入口：见本文件开头新增的那一段。
  //   这一块现在回答用户出问题时最想知道的四件事：
  //   ```text
  //   ① 日志写在哪、写了多少   → trailing 的真实行数 + 下面的按天文件路径
  //   ② 怎么把它拿出来         → 导出为日志文件 / 复制到剪贴板
  //   ③ 拿去向谁反馈、怎么反馈 → 「反馈问题时请把这份日志发给作者」+ 数据目录行
  //   ④ 作者的第一个问题是什么 → 「一键复制环境信息」（版本/系统/设备形态/数据目录）
  //   ```
  Widget _logBlock(ColorScheme colors) {
    return SettingsBlock(
      title: '日志与反馈',
      trailing: Text(
        '本次会话 ${AppLog.lineCount} 行',
        style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
      ),
      children: [
        /*
         * ★ 这一段是**反馈场景**的入口说明，不是功能介绍。
         *   用户是先遇到问题、再回来找日志的 —— 所以第一句必须是
         *   「出问题时请把这个发给作者」，而不是「这里可以导出文件」。
         */
        Text(
          '出问题时请把这份日志发给作者 —— 里面记录了播放、下载、缓存的操作与失败原因。'
          '本应用没有接入系统分享面板，所以「分享」落成两条路：'
          '导出成 .log 文件，或者复制到剪贴板后自己粘贴。',
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
            OutlinedButton.icon(
              onPressed: _envBusy ? null : _copyEnvInfo,
              icon: const Icon(Icons.info_outline, size: 18),
              label: const Text('复制环境信息'),
            ),
          ],
        ),
        const SizedBox(height: Sp.x3),
        /*
         * ★ 环境信息**默认就画出来**（不是藏在按钮后面）。
         *   理由：用户反馈时贴的第一句话几乎总是「我的是 1.0.0，Win11」——
         *   而这些值就在屏幕上，他照着抄就行，不用先点一次复制。
         *   按钮只是省掉「选中 + Ctrl+C」这一步。
         */
        _envCard(colors),
        if (_envInfo.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          Text(
            '已复制到剪贴板的内容：',
            style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: Sp.x1),
          SettingsInfoRow(label: '环境信息', value: _envInfo),
        ],
        if (_lastExportPath.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          SettingsInfoRow(label: '最近导出', value: _lastExportPath),
          SettingsInfoRow(
            label: '文件大小',
            value: '$_lastExportBytes 字节',
          ),
        ],
        const SizedBox(height: Sp.x3),
        /*
         * ★ 路径必须**可复制**（`SettingsInfoRow` 内部就是 `SelectableText`），
         *   否则用户找不到这个目录时，这一行等于没有。
         */
        Text(
          '日志同时按天写进应用数据目录的 logs/ 下（sourin-YYYY-MM-DD.log），'
          '每次导出都会把当前内容整份写出，并在开头附上环境信息。'
          '反馈问题时也可以直接把上面这个目录里的 .log 文件发给作者。',
          style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }

  /// 环境信息卡片（四行：版本 / 系统 / 设备形态 / 数据目录）
  ///
  /// ★ 读数**异步真取**：`initState` 里读一次；核心还没起来时 `SourinApi.version`
  ///   会返回「读不到（核心未加载…）」而不是编一个版本号。
  Widget _envCard(ColorScheme colors) {
    final rows = _envRows;
    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: Radii.rMd,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '环境信息（反馈时请一并提供）',
            style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: Sp.x2),
          if (rows.isEmpty)
            Text(
              '读取中…',
              style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
            )
          else
            for (final r in rows)
              SettingsInfoRow(label: r.$1, value: r.$2),
        ],
      ),
    );
  }
}
