// ═══════════════════════════════════════════════════════════════════════
//  装完之后的最后一步：把安装包交给系统
// ═══════════════════════════════════════════════════════════════════════
//
// # 各平台的做法（能到��一步就到哪一步，不到的地方如实说）
// ```text
// Windows : Process.start(安装包) → 立刻 exit(0)
//           安装包是 NSIS 自解压，起来就是安装向导
// macOS   : open( dmg )  —— 用户自己把 App 拖进「应用程序」
// Android : ⚠️ 装 APK 需要 FileProvider + REQUEST_INSTALL_PACKAGES，
//           是**原生改动**且在 Android 11+ 需要用户手动授权。
//           本轮不引入 ⇒ 降级为「用浏览��打开下载页」，
//           系统浏览器会自己处理 APK（这是 Android 上最省事也最合规的路）。
// ```
//
// # 为什么「交给系统」比「自己实现」对
//
// 打开一个文件是**操作系统**的职责（注册表关联、用户会话、
// UAC 提权、来源校验）。Flutter 侧绕过去只会做出一份更差的复制品。

import 'dart:io';

import '../app_log.dart';

class InstallLaunch {
  InstallLaunch._();

  /// 返回一句给用户看的说明；失败返回 null（调用方只提示"请手动打开"）
  static Future<String?> open(File file) async {
    try {
      if (Platform.isWindows) {
        await Process.start(file.path, const [], mode: ProcessStartMode.detached);
        return null; // 成功：直接退出应用，不打扰
      }
      if (Platform.isMacOS) {
        await Process.run('open', [file.path]);
        return '已打开安装镜像，把「源影」拖进「应用程序」即可完成更新。';
      }
    } catch (e) {
      AppLog.write('UPDATE', '拉起安装包失败: $e');
      return '没能自动打开安装包，请在「下载」文件夹里手动打开。';
    }
    return null;
  }

  /// Android：用系统默认浏览器打开下载页（APK 由浏览器/系统安装器接手）
  static Future<String?> openInBrowser(String url) async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await Process.run('am', ['start', '-a', 'android.intent.action.VIEW', '-d', url]);
        return '已用浏览器打开下载页，按提示完成安装即可。';
      }
      if (Platform.isMacOS) {
        await Process.run('open', [url]);
        return '已在浏览器中打开下载页。';
      }
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url]);
        return '已在浏览器中打开下载页。';
      }
    } catch (e) {
      AppLog.write('UPDATE', '打开下载页失败: $e');
    }
    return null;
  }

  /// 这个平台能不能「下载完直接装」
  static bool get canInstallDirectly => Platform.isWindows || Platform.isMacOS;
}