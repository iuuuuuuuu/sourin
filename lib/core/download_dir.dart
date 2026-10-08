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
// 优先   %USERPROFILE%\Videos\源影\<剧名>\
// 退路   数据目录\downloads\<剧名>\（拿不到 Videos 时）
// ```
library;

import 'dart:io';

import 'app_log.dart';
import 'clip_download.dart';

/// 下载目录的解析与「一部剧一个文件夹」的落地
class DownloadDir {
  DownloadDir._();

  /// 根目录名（用户可见的那个）
  static const String appFolderName = '源影';

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

  static Future<Directory> _resolveRoot() async {
    /*
     * ★ 优先 `%USERPROFILE%\Videos\源影`：
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
  static Future<String> forWork(String title) async {
    final base = await root();
    final name = ClipDownloader.safeName(
      title.trim().isEmpty ? '未命名' : title.trim(),
    );
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
