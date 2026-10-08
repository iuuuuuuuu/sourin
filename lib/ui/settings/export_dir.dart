// ═══════════════════════════════════════════════════════════════════════
//  导出落点：**先探再写**（task-24 缺陷 A / B 的公共修法）
// ═══════════════════════════════════════════════════════════════════════
//
// 真机事实（task-24，Android 14 / targetSdk 36）：
// ```text
// SAF 选目录（file_selector 的 getDirectoryPath）返回的路径长这样：
//   /storage/emulated/0/Movies
// 但本应用 AndroidManifest.xml 里**没有** MANAGE_EXTERNAL_STORAGE，
// 分区存储下用 dart:io 直接写这个路径 →
//   PathAccessException: Cannot open file, path =
//   '/storage/emulated/0/Movies/sourin-log-20261004-150033.log'
//   (OS Error: Operation not permitted, errno = 1)
// ```
// ⇒ 「用户选了目录」**不等于**「我们能写那个目录」。
//    所以这里不假设 —— 真的写一次空文件（probeWritableFile）。
//
// 兜底目录按优先级：
// ```text
// ① <外部存储>/Android/media/<包名>   应用可写 + 系统文件管理器可见
// ② <应用数据>/exports                一定可写（用户看不到，靠路径告知）
// ```
// ⚠️ 曾经用过的 `/storage/emulated/0/Android/data/<包名>/files` 是**错的**：
//    真机上该目录根本不存在（`ls` = No such file or directory），
//    而且 Android 11+ 起 `Android/data` 对文件管理器也是屏蔽的。
//
// ⚠️ 这里**不新增依赖**：只用 dart:io + path_provider + ClipDownloader.dataDir()。

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/clip_download.dart';

/// 一次导出的落点
///
/// [userVisible] = 系统文件管理器里**看得见**（决定文案怎么写）
typedef ExportDir = ({String path, bool userVisible});

/// **真的写一次空文件**再删掉 —— 返回"这个路径到底能不能写"
///
/// 为什么不只看 `Directory.exists()`：
/// Android 分区存储下目录**在**（`/storage/emulated/0/Movies` 当然在），
/// 但普通应用没有写权限 —— 只有真写一次才暴露得出来。
///
/// 探针文件会被删掉，不留垃圾。
Future<bool> probeWritableFile(String path) async {
  final f = File(path);
  var ok = false;
  try {
    await f.writeAsString('', flush: true);
    ok = true;
  } catch (_) {
    ok = false;
  }
  if (ok) {
    try {
      await f.delete();
    } catch (_) {
      // 删不掉也不影响结论（能写就是能写）
    }
  }
  return ok;
}

/// Android 应用专属媒体目录：`<外部存储>/Android/media/<包名>`
///
/// 为什么是它：
/// ```text
/// Android/data/<包名>/files   真机不存在 + Android 11+ 起文件管理器屏蔽
/// Android/media/<包名>        分区存储下应用自己可写 + 文件管理器看得见
/// ```
///
/// 拿不到外部存储 / 建不出来 / 写不进去 → 返回 `null`（不抛，交给调用方兜底）。
///
/// ⚠️ 曾经踩过的坑：这里一度拼成 `<sdcard>/media/<包名>`（少了 `Android` 段），
///    真机上 `/storage/emulated/0/media` **不存在** ⇒ `create()` 必失败 ⇒
///    整条 media 分支静默失效（导出被迫落回应用私有目录）。
///    现在拼串抽成下面的纯函数，由 `test/t65_export_fallback_test.dart` 钉死。
///
/// 从 `getExternalStorageDirectory()` 的结果推出 `<外部存储>/Android/media/<包名>`
///
/// 抽成**纯函数**是为了可测：这个拼串曾因少写一段（`Android`）而整条分支静默失效，
/// 纯函数能在 flutter test 里直接断言，不必上真机。
///
/// 输入形如 `/storage/emulated/0/Android/data/<包名>/files`；
/// 形状不对（段数不足 / 尾巴不是 Android/data/<包名>/files）→ 返回 `null`。
String? androidMediaDirFrom(String extStorageDir) {
  final sep = Platform.pathSeparator;
  final parts = extStorageDir
      .split(sep)
      .where((s) => s.isNotEmpty)
      .toList();
  // 期望尾部：Android / data / <包名> / files
  if (parts.length < 4) return null;
  final n = parts.length;
  if (parts[n - 1] != 'files' ||
      parts[n - 3] != 'data' ||
      parts[n - 4] != 'Android') {
    return null;
  }
  final pkg = parts[n - 2];
  final root = parts.sublist(0, n - 4).join(sep);
  // ⚠️ 开头那个空段就是根分隔符：`where(isNotEmpty)` 会把它吃掉，
  //    拼出来会变成 `storage/emulated/0/Android/media/<pkg>`（**丢开头的 /**）。
  //    真机上这样的相对路径 create() 直接失败 —— 由 t65 的纯函数测试钉住。
  final lead = extStorageDir.startsWith(sep) ? sep : '';
  return '$lead$root$sep' 'Android$sep' 'media$sep' '$pkg';
}

Future<String?> androidMediaExportDir() async {
  try {
    final ext = await getExternalStorageDirectory();
    if (ext == null) return null;
    final dir = androidMediaDirFrom(ext.path);
    if (dir == null) return null;
    final media = Directory(dir);
    await media.create(recursive: true);
    final sep = Platform.pathSeparator;
    final probe = '${media.path}$sep.write-probe';
    if (await probeWritableFile(probe)) return media.path;
    return null;
  } catch (_) {
    return null;
  }
}

/// 应用自己的导出目录：`<应用数据>/exports`（**一定**可写）
///
/// 数据目录来自 `ClipDownloader.dataDir()`（测试可用 `debugSetDataDir` 隔离）。
Future<String> appExportDir() async {
  try {
    final base = await ClipDownloader.dataDir();
    final sep = Platform.pathSeparator;
    final d = Directory('$base${sep}exports');
    await d.create(recursive: true);
    if (await probeWritableFile('${d.path}$sep.write-probe')) return d.path;
  } catch (_) {
    // 落到下面的系统临时目录
  }
  return Directory.systemTemp.path;
}

/// 兜底导出目录 —— **返回的一定可写**（每一步都探过）
Future<ExportDir> writableExportDir() async {
  final media = await androidMediaExportDir();
  if (media != null) return (path: media, userVisible: true);
  return (path: await appExportDir(), userVisible: false);
}
