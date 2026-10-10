// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 2026-10-08（Owner 第 4 条）下载目录：**按组存放**
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话（逐字）：
// > 支持一下下载整个视频,然后按照一组存放
//
// # 「按照一组存放」是什么意思
// ```text
// 一部剧下载 24 集 ⇒ 不要 24 个文件平铺在一个目录里，
// 而是一个以**剧名**命名的文件夹装它。
// ```
//
// # ★ 为什么不能复用 clip-cache（那会「下载完就消失」）
// ```text
// clip-cache 归 ClipDownloader.sweepAllLimits() 管：
//   默认上限 256 MB，**超了就从最旧的开始删**
//   （clip_download.dart:863-885 的 _enforceCacheLimitLocked）。
// 一部 1080p 剧动辄 2~4 GB ⇒ 用户点了「下载所有集」，
// 下到第 3 集就把第 1 集删了 —— 那是**灾难**，不是缓存。
// ⇒ 整片下载必须落在**用户可见、不被自动淘汰**的地方。
// ```
//
// # 落点（Windows）
// ```text
// ① 用户在【设置 → 播放 → 下载目录】里显式指定过 ⇒ 就用它（本次新增）
// 优先   %USERPROFILE%\Videos\源影\<剧名>\
// 退路   数据目录\downloads\<剧名>\（拿不到 Videos 时）
// ```
//
// # ★★★ 2026-10-09（Owner 第 20 条）下载目录要**可配置**
//
// 用户原话（逐字）：
// > 下载目录可配置
//
// ```text
// 改前：root() 只有一条路 —— 硬解析 _resolveRoot()，
//       %USERPROFILE%\Videos 拿不到就退数据目录，用户**没有任何话语权**。
//       用户的 C 盘可能只剩几个 G，而下载一部剧要 2~4 GB。
// 改后：_resolveRoot() **先读** pref 键 dsh.download.dir，
//       用户填了且可用 ⇒ 直接用；没填/失效 ⇒ 逐字回到改动前那两条路。
// ```
//
// ⚠️ 判据是「**目录真的能被创建**」而不是「字符串非空」——
//    用户可能填了个已经拔掉的 U 盘盘符，那种情况必须**退回去**而不是让下载全失败。
library;

import 'dart:io';

import 'app_log.dart';
import 'clip_download.dart';
import 'ui_prefs.dart';

/// 下载目录的解析与「一部剧一个文件夹」的落地
class DownloadDir {
  DownloadDir._();

  /// 根目录名（用户可见的那个）
  static const String appFolderName = '源影';

  /// ★★★ 2026-10-09（Owner 第 20 条）：用户指定的下载根目录
  ///
  /// 键名对齐既有的 `dsh.download.concurrency`（`clip_download.dart:279`），
  /// 同一个「下载」前缀，用户/后人一眼能看出是同一组偏好。
  static const String kDirKey = 'dsh.download.dir';

  /// 读用户填的目录；未填 / 全空白 ⇒ null（调用方走默认两条路）
  ///
  /// ⚠️ 这里**不判目录是否存在** —— 那是 [resolveRoot] 的事（要看文件系统，
  ///    是异步的），本 getter 只回答"用户填没填"。
  static String? get configuredDir {
    final raw = UiPrefs.get(kDirKey);
    if (raw == null) return null;
    final t = raw.trim();
    return t.isEmpty ? null : t;
  }

  /// 用户是否显式指定过下载目录（UI 用来显示"已自定义"）
  static bool get hasConfiguredDir => configuredDir != null;

  /// 写用户指定的目录；传 null / 空白 ⇒ 清除（回到默认两条路）
  ///
  /// ★ 要不要清 `_cached`：**要**。它缓存的是上一次解析出来的路径，
  ///   用户改了目录却还用旧缓存 ⇒ 「改了没反应」，那是最难查的一类 bug。
  static void setConfiguredDir(String? dir) {
    final t = dir?.trim() ?? '';
    if (t.isEmpty) {
      UiPrefs.set(kDirKey, '');
    } else {
      UiPrefs.set(kDirKey, t);
    }
    _cached = null;
    AppLog.write('DL', t.isEmpty ? '下载目录 -> 默认（跟随系统视频库）' : '下载目录 -> $t');
  }

  /// 缓存进内存 —— 解析要碰文件系统，而每个文件名都要用它
  static String? _cached;

  /// 下载根目录（**保证存在**）
  static Future<String> root() async {
    final c = _cached;
    if (c != null) return c;
    final d = await _resolveRoot();
    _cached = d.path;
    return d.path;
  }

  /// 测试用：清掉内存里的缓存（下次重新解析）
  static void debugReset() => _cached = null;

  /// 把「用户指定目录」解析出来（可用才返回，否则 null）
  ///
  /// ★ 判据是**真的能建出来**（`create(recursive: true)` 不抛），不是字符串非空：
  ///   用户可能填了已拔掉的 U 盘、没权限的 `C:\\Windows\\`、或者一个手滑打错的路径。
  ///   那些情况**必须**退回默认两条路 —— 让下载整体失败是最坏的结果。
  ///
  /// ⚠️ 不回写 pref：用户填错的路径要**留着**让他自己看到并改，
  ///   悄悄清掉会变成「我明明填过，怎么没了」。
  static Future<Directory?> _resolveConfigured() async {
    final raw = configuredDir;
    if (raw == null) return null;
    try {
      final d = Directory(raw);
      await d.create(recursive: true);
      return d;
    } catch (e) {
      AppLog.write('DL', '指定的下载目录不可用（$e）⇒ 退回默认目录');
      return null;
    }
  }

  static Future<Directory> _resolveRoot() async {
    /*
     * ★★★ 2026-10-09（Owner 第 20 条）：**先看用户指定**。
     * 这是本次唯一新增的分支；下面两条与改动前**逐字相同**。
     */
    final custom = await _resolveConfigured();
    if (custom != null) return custom;

    /*
     * ★ 优先 `%USERPROFILE%\\Videos\\源影`：
     *   · 那是 Windows「视频」库，用户在资源管理器左侧栏一点就到
     *   · 与系统「已知文件夹」一致 ⇒ 备份/迁移工具会一起带上
     * 退路是数据目录下的 downloads —— 只在拿不到 USERPROFILE 时用。
     * ⚠️ 两条路都**必须** create(recursive: true)：用户可能删掉它。
     */
    final profile = Platform.environment['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) {
      final d = Directory(
        '$profile${Platform.pathSeparator}Videos'
        '${Platform.pathSeparator}$appFolderName',
      );
      try {
        await d.create(recursive: true);
        return d;
      } catch (e) {
        AppLog.write('DL', '视频库不可用（$e）⇒ 退回数据目录');
      }
    }
    final d = Directory(
      '${await ClipDownloader.dataDir()}'
      '${Platform.pathSeparator}downloads',
    );
    await d.create(recursive: true);
    return d;
  }

  /// 一部作品的专属文件夹（**保证存在**）
  ///
  /// [title] 是剧名；会被清洗成合法目录名（见 ClipDownloader.safeName）。
  ///
  /// # ★★★ CR-16：必须挡掉 "." 与 ".."（目录穿越）
  /// ```text
  /// 缺陷：safeName 只做 `raw.split(RegExp(r'[<>]')).last` + 非法字符替换，
  ///       对 '.' 与 '..' **原样返回**。于是 title='..' 得到目录
  ///       '<下载根>/..' = **下载根的上级目录**，
  ///       title='.' 直接拿到下载根本身。
  /// 后果：DownloadQueue.removeWork(title, force:true) 里对 forWork(title)
  ///       的目录做 delete(recursive:true) ⇒ 能把下载根、以及下载根的上级
  ///       目录整棵删掉。用户看到一个名字是 ".." 的剧就够了。
  /// 判据：test/zz_cr_dl_c16_workdir_test.dart —— 实测未修时
  ///       `Directory(forWork('..')).delete(recursive:true)` 之后
  ///       下载根本身**已经不在了**（那条断言的红就是它）。
  /// ```
  ///
  /// ★ 判据必须按**解析后**的路径算，光比字符串前缀是假门禁：
  ///   '<root>/..'.startsWith('<root>') 恒为真。第一次写判据时正是这么写的，
  ///   结果缺陷代码 5 条断言全绿 —— 假门禁比红更糟。
  ///
  /// 兜底做法是**双保险**：safeName 之后仍再判一次，
  /// 万一将来 safeName 的规则变了也不至于重新开一个洞。
  static Future<String> forWork(String title) async {
    final base = await root();
    final raw = title.trim().isEmpty ? '未命名' : title.trim();
    var name = ClipDownloader.safeName(raw);
    // ★ CR-16：'.' 会让目录等于下载根本身，'..' 会指向下载根的上级 ——
    //   两者都能让 removeWork(force) 的递归删除跳出下载根。
    if (name == '.' || name == '..') name = '未命名';
    final d = Directory('$base${Platform.pathSeparator}$name');
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  /// 一集的落点文件名（**不含目录**）
  ///
  /// # 为什么序号要补零到两位（第01集 而不是 第1集）
  /// ```text
  /// 资源管理器按名字排序时，第1集/第10集/第2集 会乱序；
  /// 补零之后就是 01/02/…/10 ⇒ 与观看顺序一致。
  /// ```
  ///
  /// ⚠️ 只在**多集**时才加序号：电影加个「第01集」很怪。
  static String episodeFileName({
    required String title,
    required String episodeTitle,
    required int index,
    required bool multiEpisode,
  }) {
    final ep = episodeTitle.trim();
    final base = ep.isEmpty ? title.trim() : ep;
    if (!multiEpisode) return ClipDownloader.safeName(base);
    final n = (index + 1).toString().padLeft(2, '0');
    return ClipDownloader.safeName('第$n集 $base');
  }

  /// 在系统文件管理器里打开一个目录（返回是否真的打开了）
  ///
  /// # ⚠️ 为什么这里**没有**复用 `player_page.clipDirOpenStrategy`
  /// ```text
  /// 那个函数带 `@visibleForTesting`（它是为单测抽的纯函数），
  /// 在 `lib/core/**` 里引用会报 `invalid_use_of_visible_for_testing_member`。
  /// 而它**必须**留在 `player_page.dart`：`t68_android_adapt_test.dart:310`
  /// 用切片断言 `_openClipDir` 的函数体里有 `final strategy = clipDirOpenStrategy(`。
  /// ⇒ 两边各自 4 行，比为了共用去动那条断言划算。
  /// ```
  static Future<bool> open(String dir) async {
    if (Platform.isWindows) {
      await Process.run('explorer', [dir]);
      return true;
    }
    if (Platform.isMacOS) {
      await Process.run('open', [dir]);
      return true;
    }
    if (Platform.isLinux) {
      await Process.run('xdg-open', [dir]);
      return true;
    }
    return false;
  }
}
