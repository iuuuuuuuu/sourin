// ═══════════════════════════════════════════════════════════════════════
//  备份导出 / 导入面板
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这个（审计出的真实功能缺口）
//
// `sourin_api.dart` 里有 5 个备份方法（`backupPreview` / `backupDefaultName`
// / `backupExport` / `backupInspect` / `backupImport`），
// 而 `lib/ui/**` 里**零调用** —— 后端能力齐了，界面没做。
//
// 原版有完整界面：`src/components/BackupPanel.vue`（481 行）。
//
// # 原版的设计理由（文件头注释，照抄）
//
// ## 与「云盘同步」并列而不是合并
//
// | | 云盘同步 | 备份（这里）|
// |---|---|---|
// | 触发 | **自动**双向增量 | 用户**手动**导出/导入文件 |
// | 冲突 | LWW 自动消解 | 合并 / 取新 / 改名保存 |
// | 用途 | 多设备常驻同步 | 离线传递、换平台、留档 |
//
// 两者互补：云盘没网时还能用文件传；电脑 → 安卓迁移也用文件。
//
// ## 导入**强制两步确认**
//
// 原版草稿原话：
// > 导入的本质是"用文件覆盖本机数据"。不能默默覆盖 ——
// > 用户可能只是想把另一台机器的收藏合过来，结果本机进度全没了。
//
// 所以流程是：**先 inspect 看到包里有什么 → 再确认导入**。
// 后端也实现了"绝不删除本机数据"（是加和更新，不是替换）。
//
// # ★ 导出 / 导入都走**系统文件对话框**（与原版一致）
//
// 原版用 Tauri 的 `plugin-dialog` 弹系统文件选择框：
// ```ts
// const { save } = await import("@tauri-apps/plugin-dialog");
// const path = await save({ defaultPath: defaultName, filters: [...] });
// ```
//
// 我们这边不用自己实现 —— `pubspec.yaml:166` 里的 `file_selector`
// （**Flutter 官方团队**维护，flutter/packages）提供了等价 API：
// ```text
// 导出  getSaveLocation(suggestedName: 默认文件名)  → 系统「保存」对话框
// 导入  openFile(acceptedTypeGroups: [备份包 .zip])  → 系统「打开」对话框
// ```
// 用法与同仓库的 `player_settings_sheet.dart:394-403` 完全一致。
//
// # ⚠️ 历史：这里曾经是「让用户手填 / 粘贴路径」
//
// 当时的理由写在注释里：「Rust 核心没暴露文件对话框命令」+
// 「pubspec.yaml 里没有文件选择器依赖」+「任务要求禁止加新依赖」。
//
// **三条前提现在都不成立**：
// ```text
// ① file_selector 早就在 pubspec.yaml 里了（L166）—— 根本不用加依赖
// ② Owner 已明确撤销"禁止加新依赖"：「项目允许加新依赖,但是必须有用」
// ③ 手填路径**是 Owner 明确否掉的交互** ——
//    原话：「导出导入,都通过文件选择器导出 导入,
//            而不是默认规定好目录导出」
// ```
// ★ 所以**别再改回手填路径**。`test/settings_panels_test.dart` 里有
//   正向断言锁住这一点（必须 import file_selector + 调这两个 API）。
//
// # ★ 跨端：Android **没有** `getSaveLocation`（读源码核实，非假设）
//
// 读 `file_selector_android-0.5.2+11` 源码核实：
// ```text
// Windows  file_selector_windows 实现了 getSaveLocation  → 真·系统保存框
// Android  file_selector_android 只实现了
//          openFile / openFiles / getDirectoryPath
//          → getSaveLocation 落到 platform_interface 默认实现
//            (file_selector_interface.dart:83)
//          → 转调 getSavePath()  (同文件 L76)
//          → throw UnimplementedError
// ```
// 所以 Android 上导出**必须降级**，见 `_pickSavePath()`：
// ```text
// ① 首选 getDirectoryPath() —— Android 实现了它
//    （ACTION_OPEN_DOCUMENT_TREE），弹的**仍然是系统选择器**
//    → 用户挑目录，我们拼上默认文件名
// ② 连目录选择器都不可用 → 写应用目录，
//    并**把完整路径明确告诉用户**（不静默）
// ```
// 导入侧 `openFile` **两端都支持**，无需降级。
//
// ═══════════════════════════════════════════════════════════════════════
//  ★ 2026-10-09：新增「执行日志」区（Owner：要看执行过程 + 要个容量上限）
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话：
// > 备份这里再加一个执行日志吧,我能看到这个执行的过程,然后设置一个最大的容量,
// > 或者每次只显示这次启动的执行日志就行了,这样子还好点
//
// # 日志基础设施是**复用**的，一个字都没重写
//
// `lib/core/app_log.dart` 里的 `AppLog` 早就在跑（下载 / 播放 / 直播 / 字幕各自都在往里写），
// 本面板只是**接入**它：
// ```text
// AppLog.write(tag, message)   写一条（入口处已做 redact 脱敏）
// AppLog.lines                 读全部（List<LogLine>，每行有 tag / 时间 / 文本）
// ```
//
// # 容量上限：选「**本次启动** + 条数上限」，不选「按大小滚动删日志文件」
//
// ```text
// ① 只显示本次启动  —— AppLog 的内存缓冲是**进程级静态表**
//    （app_log.dart:74  static final List<LogLine> _lines），
//    没有任何生产路径清过它 ⇒ 天然就是"本次启动以来"，一行代码都不用加。
// ② 条数上限 300    —— 见 logCap 的取值理由（防极端刷屏）。
// ```
// ⇒ 两条一起满足 Owner 给的那对选项（他原话本来就是"二选一都行"）。
//
// ⚠️ 诚实标注一个**边界**：内存缓冲自己在 `AppLog.maxLines`(2000) 行处
//    成环形 —— 若本次启动后**别的** tag（DL / PLAY …）写爆 2000 行，
//    最早的 BACKUP 行会被挤出去。这是"只显示本次启动"这个策略的代价，
//    但比"给备份单独造一个持久化日志文件"划算得多（那得动 app_log.dart
//    或新开一个文件，而本次只允许改本文件）。
//
// # 日志里**写什么 / 不写什么**
//
// ```text
// 写  ：每一步做了什么 / 成功还是失败 / 耗时 ms / 文件名 / 条数 / 插件个数
// 不写：完整路径（桌面路径含用户名 —— 就是"路径里的敏感段"）、
//       设备 id、token、订阅链接、cookie
// ```
// ★ 只写**文件名**不是偷懒：AppLog 会**落盘**（<dataDir>/logs/ 按天累积）
//   而且能被导出成 .log 发出去。用户要的是"哪个文件"，不是"我的用户名"；
//   完整路径界面上那条 _ok 已经告诉他了（那里显示给本人看，没问题）。
//
// # 刷新方式：**写完就重建**，不用轮询定时器
//
// 本面板是 BACKUP 这个 tag 的**唯一**写方 ⇒「写完立刻 setState」与
// 「定时轮询」看到的是同一串东西，而前者没有常驻成本，也不会出现
// "面板已经 dispose、定时器还在 setState"这种失败模式。

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/app_log.dart';
import '../../core/models.dart';
import '../../core/sourin_api.dart';
import '../settings/export_dir.dart';
import '../tokens.dart';

/// 备份导出 / 导入面板
///
/// # 自包含
///
/// 自己拉数据、自己 `setState`，**不依赖宿主的 State** ——
/// 宿主只要：
/// ```dart
/// _Block(title: '备份', children: [BackupPanel()])
/// ```
class BackupPanel extends StatefulWidget {
  const BackupPanel({super.key});

  /// 备份包的**文件类型过滤**（导出/导入共用同一份）
  ///
  /// ⚠️ 放在 **public 的 widget 类**上而不是 State 里，是刻意的：
  ///    `lib/file_dialog_probe.dart` 要拿**同一份**配置去实测。
  ///    探针里复制一份的话，那份迟早会和这里不一致 ——
  ///    测出来的就不是真实配置了（本项目踩过"测了影子实现"的坑）。
  ///
  /// ⚠️ **必须给 extensions** —— 不给的话 Windows 上会列出所有文件，
  ///    用户很容易点到一个视频文件（`player_settings_sheet.dart:387`
  ///    踩过同样的坑）。
  ///
  /// ⚠️ 也**必须**留一档「全部文件」：备份包偶尔被人改名成 `.bak` /
  ///    `.backup` 存着，硬过滤会让用户**选不到自己的文件**。
  ///    与 `player_settings_sheet.dart:390-392` 同一个取舍 ——
  ///    宁可让用户选错（选错有报错），也不要让他选不到（选不到无解）。
  ///
  /// ⚠️ `mimeTypes` 是给 **Android** 用的：Android 侧走 Intent 过滤，
  ///    **只认 MIME**（extensions 会被 `MimeTypeMap` 转成 MIME）。
  ///    多给一个 `application/x-zip-compressed` 是因为部分来源
  ///    （浏览器下载 / 网盘落盘）用的是这个历史 MIME，只给
  ///    `application/zip` 会让文件在系统选择器里**变灰选不中**。
  ///    Windows 侧忽略 `mimeTypes`（只读 label + extensions），无副作用。
  static const List<XTypeGroup> zipGroups = <XTypeGroup>[
    XTypeGroup(
      label: '备份包',
      extensions: <String>['zip'],
      mimeTypes: <String>['application/zip', 'application/x-zip-compressed'],
    ),
    XTypeGroup(label: '全部文件'),
  ];

  @override
  State<BackupPanel> createState() => _BackupPanelState();
}

class _BackupPanelState extends State<BackupPanel> {
  /// 本机将要导出的内容（预览）
  BackupPreview? _preview;
  bool _loading = true;

  /// 用户选中的待导入包（**尚不导入** —— 要先给他看内容）
  ({String path, BackupPreview info})? _picked;

  /// 导入结果
  ImportSummary? _summary;

  /// 正在进行的操作（'' = 空闲）
  ///
  /// 用字符串而不是 bool：两个卡片各有一个按钮，
  /// 要分别显示"导出中…"/"读取中…"。
  String _busy = '';
  String _err = '';
  String _ok = '';

  /// 默认文件名（`dsh-backup-<设备id>-<时间戳>.zip`）
  ///
  /// 既显示在提示文案里，也作为保存对话框的 `suggestedName`。
  String _defaultNameText = '';

  /// 导出走降级路径时的额外提示（Android 无系统保存框）
  String _exportHint = '';

  /// 执行日志最多显示多少行（★ 容量上限，见文件头「容量上限」）
  ///
  /// # 为什么是 300
  /// ```text
  /// 一次备份本来只产生 3~6 行（开始 / 几步 / 结束），300 行 = 数十次操作，
  /// 正常永远碰不到；但它是**有界的** —— 万一有人对着按钮连点、
  /// 或将来在循环里补日志，面板也不会被撑成一块几千行的滚动条。
  ///
  /// 为什么不给「能配置的上限」：那是设置项，不是日志区的职责 ——
  /// Owner 要的是「能看过程 + 别无限长」，不是「让我调数字」。
  /// 更不该写 `AppLog.maxLines`（2000）那种量级：那是**全局**缓冲的上限，
  /// 而这里只显示 BACKUP 一个 tag，2000 行在面板里已经没法看了。
  /// ```
  ///
  /// ⚠️ 取值与 `AppLog.maxLines` 的关系：300 < 2000 ⇒ 本上限**先**生效，
  ///    用户看到的窗口永远比缓冲能装的小，不会出现「缓冲已丢、面板没丢」的错觉。
  static const int logCap = 300;

  /// 本面板写日志用的 tag（唯一写方，见文件头）
  static const String _logTag = 'BACKUP';

  /// 面板里要显示的日志行（**从 AppLog 里筛 BACKUP 这个 tag**）
  ///
  /// ⚠️ 存一份而不是每次 build 现算：`AppLog.lines` 每次调用都会
  ///    重新 `List.unmodifiable` 复制整个缓冲（app_log.dart:97），
  ///    而 build 在滚动/悬停时会被调用很多次 —— 现算就是白白复制。
  List<LogLine> _logLines = const [];

  /// 把 AppLog 里本面板相关的行同步到 [_logLines]（**只在写完日志后调**）
  ///
  /// ★ 只挑 `BACKUP` 这一个 tag：日志缓冲是**全局**的，里面混着
  ///   DL / PLAY / LIVE / subtitle 的行 —— 全显示出来就淹没了备份过程。
  ///   这也正是 Owner 要的「能看到**这个**的执行过程」。
  void _syncLog() {
    final mine = AppLog.lines.where((l) => l.tag == _logTag).toList();
    // 只留**最后** logCap 行（AppLog 是按时间正序的，所以取尾部）
    final start = mine.length > logCap ? mine.length - logCap : 0;
    _logLines = mine.sublist(start);
  }

  /// 记一条执行日志，并**立刻刷新**面板（写完就重建，不用轮询）
  ///
  /// ⚠️ 必须 `mounted` 才 setState —— 备份是异步的，用户可能在导出
  ///    途中就离开这个页面（下面那些 `if (!mounted) return` 守的是同一件事）。
  ///
  /// ⚠️ 日志**绝不能**让主流程失败：`AppLog.write` 自己已经是
  ///    「绝不抛异常」的旁路设施（app_log.dart:148），这里也不 await 它。
  void _log(String message) {
    AppLog.write(_logTag, message);
    if (!mounted) return;
    setState(_syncLog);
  }

  /// 取路径里**最后一段**（文件名）—— 日志里只写它，不写完整路径
  ///
  /// 理由见文件头「日志里写什么 / 不写什么」：桌面路径含用户名，
  /// 而日志会落盘、能被导出成 .log 发出去。
  /// 写法与 `_confirmBox` 里那句同一套（按两个分隔符切开取尾）。
  static String _fileName(String path) {
    if (path.isEmpty) return '(空)';
    return path.split(RegExp(r'[\\/]')).last;
  }

  @override
  void initState() {
    super.initState();
    /*
     * ★ 先把已有的 BACKUP 日志捞进来（面板可能在本次启动**之后**才被打开，
     *   那时日志里已经有几行了）。
     *
     * ⚠️ 这里**只同步、不写**：进页面就记一条"打开了面板"属于噪音，
     *   而 Owner 要的是"备份的执行过程"。真正的第一行由用户点了
     *   导出/选择文件才产生。
     * ⚠️ 直接赋值不走 setState：initState 阶段本来就要建第一帧。
     */
    _syncLog();
    _loadPreview();
    // 预取默认文件名（只是为了让提示文案能显示它，失败不影响功能）
    _defaultName();
  }

  /// 拉"本机将导出什么"
  Future<void> _loadPreview() async {
    setState(() {
      _loading = true;
      _err = '';
    });
    try {
      final p = await SourinApi.backupPreview();
      if (!mounted) return;
      setState(() {
        _preview = p;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _loading = false;
      });
    }
  }

  /// 默认文件名
  ///
  /// ⚠️ 取不到也要给一个名字 —— **不能让对话框因为取名失败而不弹**。
  Future<String> _defaultName() async {
    try {
      final n = await SourinApi.backupDefaultName();
      if (mounted) setState(() => _defaultNameText = n);
      return n;
    } catch (e) {
      debugPrint('[BACKUP] 取默认文件名失败: $e');
      return _defaultNameText.isEmpty ? 'dsh-backup.zip' : _defaultNameText;
    }
  }

  /// 保证路径以 `.zip` 结尾
  ///
  /// ⚠️ Windows 的系统保存框**不会**自动补后缀
  ///    （`file_selector_windows` 没有调 `SetDefaultExtension`）。
  ///    用户手打一个不带后缀的名字，导出的文件就会叫
  ///    `dsh-backup-xxx` 而不是 `.zip` —— 双击打不开，
  ///    导入侧的类型过滤也选不中。
  ///    内容本来就是 zip，补后缀不改变任何东西。
  static String _ensureZip(String path) =>
      path.toLowerCase().endsWith('.zip') ? path : '$path.zip';

  /// 拼目录 + 文件名（不依赖 `Platform.pathSeparator` 猜分隔符）
  static String _join(String dir, String name) {
    final sep = Platform.pathSeparator;
    if (dir.endsWith(sep) || dir.endsWith('/')) return '$dir$name';
    return '$dir$sep$name';
  }

  /// 弹**系统保存对话框**，返回用户选定的完整路径
  ///
  /// 返回 `null` = **用户取消**（原版语义：`if (!path) return;`，不是错误）。
  /// 平台没有这个能力时走 `_pickSavePathFallback()`，见文件头「跨端」。
  Future<String?> _pickSavePath(String suggestedName) async {
    try {
      final loc = await getSaveLocation(
        acceptedTypeGroups: BackupPanel.zipGroups,
        suggestedName: suggestedName,
      );
      if (loc == null) return null; // 用户取消
      return _ensureZip(loc.path);
    } on UnimplementedError {
      /*
       * Android：`file_selector_android` 没实现 getSaveLocation。
       * 这不是"出错"，是**该平台没有这个能力** —— 走降级。
       */
      debugPrint('[BACKUP] 本平台无 getSaveLocation（Android）→ 降级选目录');
    } catch (e) {
      /*
       * 其它异常（插件未注册等）也走降级 ——
       * 宁可让用户挑个目录，也不要"点了导出没反应"。
       * 真失败会在降级路径里如实抛出来。
       */
      debugPrint('[BACKUP] getSaveLocation 异常: $e → 降级');
    }
    return _pickSavePathFallback(suggestedName);
  }

  /// Android 降级：挑目录 → 拼文件名 → 返回完整路径
  ///
  /// ① `getDirectoryPath()` —— Android **实现了**它
  ///    （`ACTION_OPEN_DOCUMENT_TREE`），所以这里弹的**仍然是系统选择器**，
  ///    不是让用户手打路径。
  /// ② 连目录选择器都不可用 → 写应用目录，并把完整路径回报给用户。
  ///
  /// ★★ task-24 缺陷 B 的根因：SAF 选出来的目录**我们写不进去**。
  ///    详见 `lib/ui/settings/export_dir.dart` 的文件头（含真机报错原文）。
  ///    修法与设置页那份完全一致：**先探再写**，探不通就换兜底目录。
  Future<String?> _pickSavePathFallback(String suggestedName) async {
    try {
      final dir = await getDirectoryPath(confirmButtonText: '保存到此处');
      if (dir == null) return null; // 用户取消
      if (dir.isNotEmpty) {
        final target = _join(dir, suggestedName);
        if (await probeWritableFile(target)) return target;
        debugPrint('[BACKUP] 用户选的目录不可写（分区存储）→ 走兜底：$dir');
      }
    } catch (e) {
      debugPrint('[BACKUP] getDirectoryPath 不可用: $e');
    }

    /*
     * 兜底：写**我们能写的**目录（`export_dir.dart` 里探过再返回）。
     * ⚠️ **必须把完整路径告诉用户** —— 静默存到用户找不到的地方，
     *    他会以为"导出没成功"（或以为存到了默认规定好的目录）。
     */
    final dir = await writableExportDir();
    _exportHint = dir.userVisible
        ? '本平台不支持系统「保存」对话框，已存到 ${dir.path}。'
            '可以到系统文件管理器里按下面的路径找到它。'
        : '本平台不支持系统「保存」对话框，已存到应用目录'
            '（系统文件管理器看不到）。完整路径：${dir.path}';
    return _join(dir.path, suggestedName);
  }

  /// 导出
  ///
  /// 原版（`BackupPanel.vue:96-118`）：
  /// ```ts
  /// const path = await save({ defaultPath: defaultName, filters: [...] });
  /// if (!path) return;          // 用户取消对话框 → 静默收尾
  /// const r = await backupApi.export(String(path));
  /// ```
  Future<void> _doExport() async {
    setState(() {
      _busy = 'export';
      _err = '';
      _ok = '';
      _exportHint = '';
    });
    /*
     * ★ 每一步都记一条执行日志（Owner："我能看到这个执行的过程"）。
     *
     * ⚠️ 计时用 Stopwatch 而不是两个 DateTime.now() —— 中间有 await
     *    （系统对话框可能停几十秒），DateTime.now() 会跟着系统时钟走，
     *    而 Stopwatch 是单调时钟，测出来才是真的"花了多久"。
     * ⚠️ 日志里只写**文件名**，不写完整路径（理由见文件头）。
     */
    final sw = Stopwatch()..start();
    _log('导出：开始');
    try {
      final name = await _defaultName();
      final path = await _pickSavePath(name);
      if (!mounted) return;
      if (path == null) {
        // 用户取消对话框 —— 不是错误，静默收尾（原版 `if (!path) return`）
        _log('导出：用户取消（${sw.elapsedMilliseconds} ms）');
        setState(() => _busy = '');
        return;
      }
      _log('导出：已选定 ${_fileName(path)}，开始打包…');
      final stepSw = Stopwatch()..start();
      final r = await SourinApi.backupExport(path);
      if (!mounted) return;
      _log('导出：成功 ${_fileName(r.path)}（${_fmtBytes(r.bytes)}）—— '
          '打包 ${stepSw.elapsedMilliseconds} ms / 全程 ${sw.elapsedMilliseconds} ms');
      setState(() {
        _ok = '已导出到 ${r.path}（${_fmtBytes(r.bytes)}）';
        _busy = '';
      });
    } catch (e) {
      // 失败也必须进日志 —— 用户报问题时这是唯一的现场
      _log('导出：失败（${sw.elapsedMilliseconds} ms）$e');
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _busy = '';
      });
    }
  }

  /// 选包（**只读，不导入**）
  ///
  /// 原版注释：
  /// > 草稿要求「不能默默覆盖」—— 所以选完先 inspect，
  /// > 把包里有什么摊开给用户看，他确认了才真导入。
  ///
  /// 原版（`BackupPanel.vue:126-145`）：
  /// ```ts
  /// const path = await open({ multiple: false, filters: [...] });
  /// if (!path) return;
  /// const info = await backupApi.inspect(String(path));
  /// ```
  Future<void> _doPick() async {
    setState(() {
      _busy = 'pick';
      _err = '';
      _ok = '';
      _summary = null;
    });
    final sw = Stopwatch()..start();
    _log('导入：选择文件…');
    try {
      final f = await openFile(acceptedTypeGroups: BackupPanel.zipGroups);
      if (!mounted) return;
      if (f == null) {
        // 用户取消对话框 —— 不是错误
        _log('导入：用户取消（${sw.elapsedMilliseconds} ms）');
        setState(() => _busy = '');
        return;
      }
      /*
       * ⚠️ Android 上 `f.path` 是**应用缓存里的副本**
       *    （`FileUtils.getPathFromCopyOfFileFromUri` —— 系统给的
       *     content:// URI 没法直接当路径读）。
       *    对我们没影响：inspect / import 都只**读**这个文件，
       *    缓存副本的内容与原文件一致。
       */
      final info = await SourinApi.backupInspect(f.path);
      if (!mounted) return;
      /*
       * ★ 检视结果**整份**进日志：这是用户"看到包里有什么"的那一步，
       *   出了问题（比如某个包读不了）时，日志里必须有它的设备/版本/条数。
       * ⚠️ 只写文件名，不写完整路径（理由见文件头）。
       */
      _log('导入：已读取 ${_fileName(f.path)} —— 来自设备 ${info.deviceId}'
          ' · 导出 ${_fmtTime(info.exportedAt)} · 格式 v${info.version}'
          ' · 插件 ${info.plugins.length} 个（${sw.elapsedMilliseconds} ms）');
      setState(() {
        _picked = (path: f.path, info: info);
        _busy = '';
      });
    } catch (e) {
      _log('导入：读取失败（${sw.elapsedMilliseconds} ms）$e');
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _busy = '';
      });
    }
  }

  /// 真导入（用户看完包内容、点了确认之后）
  Future<void> _doImport() async {
    final p = _picked;
    if (p == null) return;
    setState(() {
      _busy = 'import';
      _err = '';
      _ok = '';
    });
    final sw = Stopwatch()..start();
    _log('导入：开始合并 ${_fileName(p.path)}');
    try {
      final s = await SourinApi.backupImport(p.path);
      if (!mounted) return;
      /*
       * ★ 只记**汇总数字**，不逐条展开：
       *   `pluginsWritten` / `pluginsRenamed` 里是插件文件名，属于用户数据；
       *   而条数已经足够回答"这次到底导进来了什么"。
       *   `skipped` 有内容时必须记 —— 那代表**有东西没进来**（原版语义），
       *   是最容易被误读成"都导入了"的一种情况。
       */
      _log('导入：完成 ${_fileName(p.path)}（${sw.elapsedMilliseconds} ms）'
          ' 收藏 +${s.favoritesAdded}/~${s.favoritesUpdated}'
          ' 追更 +${s.followingAdded} 进度 ~${s.progressUpdated}'
          ' 历史 +${s.historyAdded} 片头片尾 ~${s.skipUpdated}'
          ' 内容源 +${s.providersImported}'
          ' 插件写 ${s.pluginsWritten.length}/改名 ${s.pluginsRenamed.length}');
      if (s.skipped.isNotEmpty) {
        _log('导入：有 ${s.skipped.length} 项被跳过 —— 这些数据**没有**进来');
      }
      setState(() {
        _summary = s;
        _picked = null;
        _ok = '导入完成';
        _busy = '';
      });
      // 刷新本机预览（条数变了）
      await _loadPreview();
    } catch (e) {
      _log('导入：失败（${sw.elapsedMilliseconds} ms）$e');
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _busy = '';
      });
    }
  }

  /// 数据条数摘要（导出前 / 导入前共用同一套文案）
  ///
  /// ⚠️ 键名与后端 `BackupPreview.counts` 的键一一对应 ——
  ///    写错就显示 0（而不是报错），所以这里集中一处。
  static List<({String label, int n})> _describe(Map<String, int> c) => [
        (label: '收藏', n: c['favorites'] ?? 0),
        (label: '追更', n: c['following'] ?? 0),
        (label: '播放进度', n: c['progress'] ?? 0),
        (label: '观看历史', n: c['history'] ?? 0),
        (label: '片头片尾', n: c['skip_markers'] ?? 0),
        (label: '内容源', n: c['providers'] ?? 0),
        (label: '插件', n: c['plugins'] ?? 0),
      ];

  static String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static String _fmtTime(int? ms) {
    if (ms == null || ms == 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String p(int x) => x.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 导出卡片 ──
        _card(
          colors: colors,
          icon: Icons.file_download_outlined,
          title: '导出备份',
          subtitle: '打包成 .zip —— 解压开就能看到插件源码，能自己改完再打回去',
          action: FilledButton(
            onPressed: (_busy.isNotEmpty || _loading) ? null : _doExport,
            child: Text(_busy == 'export' ? '导出中…' : '导出'),
          ),
          children: [
            // 说明这一步会弹**系统对话框**（而不是让用户填路径）
            _dialogHint(
              colors: colors,
              text: _defaultNameText.isEmpty
                  ? '点「导出」→ 弹出**系统保存对话框**，自己选存到哪'
                  : '点「导出」→ 弹出**系统保存对话框**'
                      '（默认文件名 $_defaultNameText）',
            ),
            const SizedBox(height: Sp.x3),
            // 会导出什么（点导出前先看到）
            if (_preview != null)
              _countsRow(_describe(_preview!.counts), colors)
            else if (_loading)
              Text('读取中…',
                  style: TextStyle(
                      fontSize: FontSizes.cap, color: colors.onSurfaceVariant)),
            // 插件清单（让用户知道哪些会被打包）
            if (_preview != null && _preview!.plugins.isNotEmpty)
              _pluginList(_preview!.plugins, colors),
          ],
        ),

        const SizedBox(height: Sp.x4),

        // ── 导入卡片 ──
        _card(
          colors: colors,
          icon: Icons.file_upload_outlined,
          title: '导入备份',
          subtitle: '合并进来，不会覆盖本机已有的数据',
          action: OutlinedButton(
            onPressed: _busy.isNotEmpty ? null : _doPick,
            child: Text(_busy == 'pick' ? '读取中…' : '选择文件'),
          ),
          children: [
            _dialogHint(
              colors: colors,
              text: '点「选择文件」→ 弹出**系统打开对话框**，'
                  '选中备份包（.zip）后先看内容，再决定导不导',
            ),

            // 选中后的确认区（**必须确认才导入**）
            if (_picked != null) ...[
              const SizedBox(height: Sp.x3),
              _confirmBox(_picked!, colors),
            ],

            // 导入结果
            if (_summary != null) ...[
              const SizedBox(height: Sp.x3),
              _resultBox(_summary!, colors),
            ],
          ],
        ),

        if (_err.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          _msg(_err, colors.error),
        ],
        if (_ok.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          _msg(_ok, colors.primary),
        ],
        if (_exportHint.isNotEmpty) ...[
          const SizedBox(height: Sp.x1),
          _msg(_exportHint, colors.onSurfaceVariant),
        ],

        // ── 执行日志（★ 2026-10-09 新增，见文件头）──
        const SizedBox(height: Sp.x4),
        _logBox(colors),
      ],
    );
  }

  /// 一张卡片（图标 + 标题 + 说明 + 右上角动作 + 内容）
  Widget _card({
    required ColorScheme colors,
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget action,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(Sp.x4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Icon(icon, size: 17, color: colors.onSurfaceVariant),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: FontSizes.base,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: FontSizes.cap,
                            color: colors.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: Sp.x2),
              action,
            ],
          ),
          const SizedBox(height: Sp.x3),
          ...children,
        ],
      ),
    );
  }

  /// 「这一步会弹系统对话框」的说明条
  ///
  /// 用一个小图标 + 一行字，替掉原来的路径输入框 ——
  /// 用户不需要（也**不应该**）自己知道路径怎么写。
  Widget _dialogHint({required ColorScheme colors, required String text}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.folder_open_outlined,
            size: 15, color: colors.onSurfaceVariant),
        const SizedBox(width: Sp.x2),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
                fontSize: FontSizes.cap,
                height: 1.5,
                color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// 数据条数（小圆角标签，密集但不挤）
  Widget _countsRow(List<({String label, int n})> items, ColorScheme colors) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final d in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(d.label,
                    style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.onSurfaceVariant)),
                const SizedBox(width: 4),
                Text('${d.n}',
                    style: TextStyle(
                        fontSize: FontSizes.cap,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface)),
              ],
            ),
          ),
      ],
    );
  }

  /// 插件清单（可展开）
  Widget _pluginList(List<(String, int)> plugins, ColorScheme colors) {
    final total = plugins.fold<int>(0, (a, x) => a + x.$2);
    return Padding(
      padding: const EdgeInsets.only(top: Sp.x3),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: Sp.x4, bottom: Sp.x2),
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(
          '查看插件清单（${plugins.length} 个 · 合计 ${_fmtBytes(total)}）',
          style: TextStyle(
              fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
        ),
        children: [
          for (final p in plugins)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(p.$1,
                        style: const TextStyle(
                            fontSize: FontSizes.cap,
                            fontFamily: 'monospace')),
                  ),
                  Text(_fmtBytes(p.$2),
                      style: TextStyle(
                          fontSize: FontSizes.cap,
                          color: colors.onSurfaceVariant)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 导入确认区（**视觉上"抬起来"，提示这是要用户拍板的一步**）
  Widget _confirmBox(({String path, BackupPreview info}) picked,
      ColorScheme colors) {
    final info = picked.info;
    final fname = picked.path.split(RegExp(r'[\\/]')).last;
    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('这个包里有什么',
                    style: TextStyle(
                        fontSize: FontSizes.sm,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface)),
              ),
              Text(fname,
                  style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: Sp.x2),
          Text(
            '来自设备 ${info.deviceId} · 导出于 ${_fmtTime(info.exportedAt)}'
            ' · 格式 v${info.version}',
            style: TextStyle(
                fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: Sp.x3),
          _countsRow(_describe(info.counts), colors),
          const SizedBox(height: Sp.x3),
          /*
           * ⚠️ 这段说明**必须留着** —— 原版注释：
           * > 导入是"合并"：收藏按并集加、进度按时间戳取更新的那次。
           * > 不会删除本机任何数据
           * 用户看到"导入"两个字会本能地担心覆盖，说清楚才敢点。
           */
          Container(
            padding: const EdgeInsets.symmetric(vertical: Sp.x2),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: Text(
              '导入是合并：收藏按并集加、进度按时间戳取更新的那次。'
              '不会删除本机任何数据；插件同名时会改名保存，不覆盖原文件。',
              style: TextStyle(
                  fontSize: FontSizes.cap,
                  height: 1.6,
                  color: colors.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: Sp.x2),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() => _picked = null),
                child: const Text('取消'),
              ),
              const SizedBox(width: Sp.x2),
              FilledButton(
                onPressed: _busy == 'import' ? null : _doImport,
                child: Text(_busy == 'import' ? '导入中…' : '确认导入'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 导入结果
  Widget _resultBox(ImportSummary s, ColorScheme colors) {
    final lines = <String>[
      if (s.favoritesAdded > 0) '收藏新增 ${s.favoritesAdded}',
      if (s.favoritesUpdated > 0) '收藏更新 ${s.favoritesUpdated}',
      if (s.followingAdded > 0) '追更新增 ${s.followingAdded}',
      if (s.progressUpdated > 0) '播放进度更新 ${s.progressUpdated}',
      if (s.historyAdded > 0) '历史新增 ${s.historyAdded}',
      if (s.skipUpdated > 0) '片头片尾更新 ${s.skipUpdated}',
      if (s.providersImported > 0) '内容源导入 ${s.providersImported}',
      if (s.pluginsWritten.isNotEmpty) '插件写入 ${s.pluginsWritten.length}',
      if (s.pluginsRenamed.isNotEmpty) '插件改名保存 ${s.pluginsRenamed.length}',
    ];

    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('导入完成',
              style: TextStyle(
                  fontSize: FontSizes.sm,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface)),
          const SizedBox(height: 6),
          if (lines.isEmpty)
            Text('没有新增内容（本机数据已是最新）',
                style: TextStyle(
                    fontSize: FontSizes.cap, color: colors.onSurfaceVariant))
          else
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(l,
                    style: TextStyle(
                        fontSize: FontSizes.sm, color: colors.onSurface)),
              ),

          /*
           * ⚠️ 跳过项**必须展示** —— 原版注释：
           * > 导入是"尽力而为"，有东西没进来却不告诉用户，
           * > 他会以为"都导入了"
           */
          if (s.skipped.isNotEmpty) ...[
            const SizedBox(height: Sp.x2),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(left: Sp.x4, bottom: Sp.x2),
              shape: const Border(),
              collapsedShape: const Border(),
              title: Text(
                '有 ${s.skipped.length} 项被跳过',
                style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
              ),
              children: [
                for (final x in s.skipped)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(x,
                        style: TextStyle(
                            fontSize: FontSizes.cap,
                            color: colors.onSurfaceVariant)),
                  ),
              ],
            ),
          ],

          if (s.pluginsRenamed.isNotEmpty) ...[
            const SizedBox(height: Sp.x2),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(left: Sp.x4, bottom: Sp.x2),
              shape: const Border(),
              collapsedShape: const Border(),
              title: Text(
                '${s.pluginsRenamed.length} 个插件因同名被改名保存',
                style: TextStyle(
                    fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
              ),
              children: [
                for (final n in s.pluginsRenamed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(n,
                        style: const TextStyle(
                            fontSize: FontSizes.cap,
                            fontFamily: 'monospace')),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '原文件仍在 —— 两个都留着，你在插件列表里挑要哪个',
                    style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 「执行日志」区（★ 2026-10-09 新增）
  ///
  /// # 为什么做成**卡片**而不是嵌一个可滚动的小窗口
  /// ```text
  /// 本面板是嵌在二级页的 ListView 里的（backup_page.dart → SettingsSubPage）。
  /// 再套一个 ListView 就是**嵌套滚动** —— 要么得给死高度、
  /// 要么得 shrinkWrap，两种都会在 TV 字号放大（×1.25）后露馅。
  /// 而行数本来就被 logCap 钉死在 300 ⇒ 直接铺成 Column，
  /// 让**页面自己**的滚动条去滚，零嵌套、零死高度。
  /// ```
  ///
  /// # 为什么行内不放"清空"按钮
  /// ```text
  /// AppLog 只有 `debugClear()`（@visibleForTesting）能清内存缓冲，
  /// 那是**测试注入口**，生产代码调它就是误用 —— 而且清的是**全局**缓冲，
  /// 会连带抹掉 DL / PLAY 那些别人写的日志。
  /// ⇒ 这里不提供清空；日志随进程退出自然消失（这正是"本次启动"的语义）。
  /// ```
  Widget _logBox(ColorScheme colors) {
    return _card(
      colors: colors,
      icon: Icons.receipt_long_outlined,
      title: '执行日志',
      subtitle: '本次启动以来的备份操作 · 最多显示最近 $logCap 行',
      // 右上角用计数替掉按钮位（与另两张卡视觉一致，但不假装可点）
      action: Text(
        '${_logLines.length} 行',
        style: TextStyle(
            fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
      ),
      children: [
        if (_logLines.isEmpty)
          /*
           * ⚠️ 空态必须说清"**怎么才会有内容**" —— 只写"暂无日志"，
           *    用户会以为是坏了（他不会猜到要先点一次导出）。
           */
          Text(
            '还没有记录。点上面的「导出」或「选择文件」，'
            '这里会逐步显示做了什么、成功还是失败、花了多久。',
            style: TextStyle(
                fontSize: FontSizes.cap,
                height: 1.6,
                color: colors.onSurfaceVariant),
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Sp.x3),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                /*
                 * ★ 正序渲染（最早在上面、最新在最下面）—— 与终端/控制台
                 *   的方向一致，读起来是"从头到尾发生了什么"。
                 * ⚠️ 用 `LogLine.text`（带时间戳与 tag）而不是只有 message：
                 *   时间是"执行过程"的一半信息，用户报问题时也要它。
                 */
                for (final l in _logLines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      l.text,
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        fontFamily: 'monospace',
                        height: 1.5,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _msg(String text, Color color) => Text(
        text,
        style: TextStyle(fontSize: FontSizes.sm, color: color, height: 1.6),
      );
}
