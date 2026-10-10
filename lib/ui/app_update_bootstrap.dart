// ═══════════════════════════════════════════════════════════════════════
//  启动时的更新检查（壳里唯一的挂钩点）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独抽一个文件而不是把逻辑塞进 shell.dart
//
// `shell.dart` 归 polish agent，且它已经 6800 行。
// 这边只留**一行**调用（`unawaited(AppUpdateBootstrap.run())`），
// 其余全在这里 —— 以后要改节流/提示时机，改的都是这个文件。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/app_tray.dart';
import '../../core/app_update/app_update_controller.dart';
import '../../core/app_update/client.dart';
import '../../core/app_update/install.dart';
import '../../core/app_update/release.dart';
import 'widgets/update_dialog.dart';

abstract final class AppUpdateBootstrap {
  static bool _done = false;

  /// 启动后调一次。自己判断该不该查（每天最多一次，且用户可关闭）。
  static Future<void> run() async {
    if (_done) return;
    _done = true;
    final c = AppUpdateController.instance;
    c.loadPrefs();
    if (!c.shouldAutoCheck) return;

    // 延后一点：不要和首屏的数据加载抢网络
    await Future<void>.delayed(const Duration(seconds: 3));
    final res = await c.check();
    final rel = res.release;
    if (rel == null) return; // 没新版本 / 没连上 —— 都不打扰

    final ctx = _dialogContext;
    if (ctx == null) return;

    final platform = UpdateHttp.currentTarget().$1;
    // 过了 3 秒延迟与一次网络请求，界面可能已经没了（用户退出/切场景）
    if (!ctx.mounted) return;
    final wantDownload = await showUpdateDialog(ctx, rel, platform: platform);
    if (!wantDownload) return;

    final file = await c.downloadRelease(rel);
    if (file == null) return;
    if (!InstallLaunch.canInstallDirectly) {
      await InstallLaunch.openInBrowser(
          selectAsset(rel, platform)?.browserUrl ?? rel.htmlUrl);
      return;
    }
    final msg = await InstallLaunch.open(file);
    if (msg != null) {
      final c2 = _dialogContext;
      if (c2 != null && c2.mounted) {
        ScaffoldMessenger.maybeOf(c2)
            ?.showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  /// 一个「能弹 dialog」的 context
  ///
  /// ⚠️ 不要再用 `WidgetsBinding.instance.rootElement`（CR-22）：根 Element 位于
  ///   `MaterialApp` **之上**，而 `Navigator.of` 只向上找祖先 —— 它上面没有
  ///   Navigator，必然抛
  ///   `Navigator operation requested with a context that does not include a Navigator`，
  ///   于是 catch 返回 null，`run()` 在 `if (ctx == null) return;` 静默退出，
  ///   启动更新弹窗**永远不出现**，而 `_lastCheckAt` 已经写进去了。
  ///
  /// 现在用 `AppTray.navigatorKey`：shell.dart 已经把它挂在 `MaterialApp` 上，
  ///   `key.currentContext` 位于真正的 Navigator **之下**，弹窗挂在正确的那一层，
  ///   并且不需要本仓再提供第二个全局 key（见 app_tray.dart:75-88 的同类教训）。
  /// 首帧之前拿不到时返回 null —— 那时安静跳过即可。
  static BuildContext? get _dialogContext {
    final ctx = AppTray.navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return null;
    if (Navigator.maybeOf(ctx, rootNavigator: true) == null) return null;
    return ctx;
  }

  /// 测试用：允许重跑
  static void debugReset() => _done = false;

  /// 测试用：暴露当前"能不能拿到可弹窗的 context"。
  @visibleForTesting
  static BuildContext? debugDialogContext() => _dialogContext;
}