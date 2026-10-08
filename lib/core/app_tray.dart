// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 2026-10-08（Owner 第 8 条）托盘图标 + 关闭确认
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话（逐字）：
// > 要注册一个托盘图标,点击x,第一次提示是关闭还是彻底退出,
// > 然后后面就按照上次的选择的来 托盘图标,单击打开,右键出现菜单 点击退出
//
// # 三件事，逐条对齐
// ```text
// ① 托盘图标        `TrayManager.setIcon('assets/tray.ico')` + 悬停提示
// ② 点 X 第一次问   `setPreventClose(true)` 拦住系统关闭，弹一个三选一
// ③ 之后按上次的来  `dsh.closeAction` 落盘（'ask' / 'tray' / 'quit'）
// ```
//
// # 为什么必须 `setPreventClose(true)`（否则整个需求做不出来）
// ```text
// window_manager 的 `close()` 直接 DestroyWindow —— 没有钩子就**没有机会**
// 弹窗、也没有机会藏到托盘。官方给的唯一拦截点是 `setPreventClose(true)`
// + `WindowListener.onWindowClose()`（`window_manager.dart:158/451`）。
// ⇒ 必须开，否则「点 X 问一次」这件事在架构上就不成立。
// ```
//
// # 三选一的语义（对齐用户原话的两个动作）
// ```text
// 最小化到托盘  藏窗口 + 留着进程（还能从托盘点回来）
// 彻底退出      真的关掉（先 destroy 托盘再 close，否则托盘图标会留尸）
// 取消          什么都不做
// ```
//
// ⚠️ 「关闭」与「退出」是两个**不同的**动作 —— 用户原话把这两者并列问了
//    （「是关闭还是彻底退出」），所以不能只给「是/否」。
// ⚠️ 托盘图标必须在 `runApp` **之后**注册：`setIcon` 要走 MethodChannel，
//    而 channel 的 handler 由 Flutter engine 建（`TrayManager._()` 构造里
//    `_channel.setMethodCallHandler`）—— 但**原生侧**注册图标不依赖帧，
//    所以放在 `main()` 里 `runApp` 之后立刻调即可。
library;

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../ui/widgets/overlay_motion.dart';
import 'ui_prefs.dart';

/// 关闭行为（落盘在 `dsh.closeAction`）
enum CloseAction {
  /// 第一次点 X —— 每次都要问
  ask,

  /// 最小化到托盘（进程留着，托盘图标还在）
  tray,

  /// 彻底退出
  quit,
}

/// 托盘 + 关闭确认的总入口
///
/// ⚠️ 整个类在**非桌面平台**上是空操作 —— `tray_manager` /
///    `window_manager` 的原生端只在 Windows/macOS/Linux 注册，
///    Android 上调会抛 `MissingPluginException`（本项目在 `shell.dart:300`
///    为 `window_manager` 记过同一条教训）。
class AppTray with TrayListener, WindowListener {
  AppTray._();

  static final AppTray instance = AppTray._();

  static const String closeActionKey = 'dsh.closeAction';

  /// ★ 全局 Navigator key —— 由 `shell.dart` 挂到 `MaterialApp.navigatorKey` 上。
  ///
  /// # 为什么需要它（而不是随便拿个 context）
  /// ```text
  /// `MaterialApp.builder` 的 context 在 Navigator **外面**
  ///   ⇒ `Navigator.of(那个 context)` 会一路往上找到**根**，
  ///     拿不到 MaterialApp 自己那个 Navigator（它就在 builder 里面）。
  /// 而关闭确认弹窗必须挂在**这个** Navigator 上（否则弹窗跑到
  ///   外层去，`barrierDismissible: false` 也挡不住下面的页面）。
  /// ```
  /// ⚠️ 不能改成「从 `_ShellPageState` 里读 `_navKey`」—— 那个 State 本身
  ///    就在 Navigator 里，弹窗要等它挂载后才拿得到，而关闭事件
  ///    可能在挂载前就到（进程启动瞬间点 X）。
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// 托盘图标资源（相对 `assets/`，与 pubspec 声明一致）
  static const String _iconAsset = 'assets/tray.ico';

  bool _started = false;

  /// 真的退出中（`_quit()` 里先置位再 `close()`）
  ///
  /// ★ 没有它就会**递归**：`_quit()` 调 `windowManager.close()` ⇒ 触发
  ///   `onWindowClose()` ⇒ 又走一遍「要不要问」的逻辑 ⇒ 如果用户选的是
  ///   quit，就会再次 `close()` …… 死循环。
  bool _quitting = false;

  /// 当前生效的关闭行为
  CloseAction get action {
    switch (UiPrefs.get(closeActionKey)) {
      case 'tray':
        return CloseAction.tray;
      case 'quit':
        return CloseAction.quit;
      default:
        return CloseAction.ask;
    }
  }

  /// 注册托盘图标 + 接管关闭事件
  ///
  /// ⚠️ 失败**不抛** —— 托盘起不来不该让应用起不来（用户至少还能用窗口）。
  ///    但必须留日志，不能静默吞（本项目的一贯纪律）。
  Future<void> start() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      debugPrint('[TRAY] 非桌面平台 ⇒ 不注册托盘');
      return;
    }
    if (_started) return;
    _started = true;
    try {
      /*
       * ★ 顺序：先 `setPreventClose` 再注册图标。
       *
       * 反过来的话，图标注册失败时关闭拦截**还没生效** —— 用户点 X
       * 会直接退出，而他以为已经开了托盘（表现为「最小化到托盘没生效」）。
       * 拦截先立起来，最差也只是没有图标但关闭仍会问。
       */
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
      trayManager.addListener(this);
      await trayManager.setIcon(_iconAsset);
      await trayManager.setToolTip('源影 —— 跨端视频客户端');
      await trayManager.setContextMenu(
        Menu(items: [
          MenuItem(key: 'show', label: '打开主界面'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: '退出'),
        ]),
      );
      debugPrint('[TRAY] 托盘图标已注册（关闭行为=${action.name}）');
    } catch (e) {
      debugPrint('[TRAY] ★ 托盘注册失败（窗口仍可用，关闭将走普通退出）: $e');
    }
  }

  /// 应用退出前清掉托盘图标
  ///
  /// ★ 必须做：Windows 的托盘图标**不会**随进程退出自动消失，
  ///   它会变成「幽灵图标」停在通知区，要等鼠标划过去才消失。
  Future<void> dispose() async {
    if (!_started) return;
    _started = false;
    try {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
      await trayManager.destroy();
    } catch (e) {
      debugPrint('[TRAY] 清理失败: $e');
    }
  }

  // ── 托盘事件 ──────────────────────────────────────────────────────

  /// 单击托盘图标 ⇒ 打开主界面（用户原话：「托盘图标,单击打开」）
  @override
  void onTrayIconMouseDown() {
    debugPrint('[TRAY] 单击托盘 ⇒ 打开主界面');
    unawaited(restoreWindow());
  }

  /// 右键 ⇒ 弹菜单（用户原话：「右键出现菜单」）
  ///
  /// ★ 必须显式 `popUpContextMenu()` —— `tray_manager` 只是把右键事件
  ///   报上来，**不会**自动弹菜单（Windows 原生那侧没有默认行为）。
  @override
  void onTrayIconRightMouseDown() {
    debugPrint('[TRAY] 右键托盘 ⇒ 弹菜单');
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    debugPrint('[TRAY] 菜单项 ${menuItem.key}');
    switch (menuItem.key) {
      case 'show':
        unawaited(restoreWindow());
      case 'quit':
        unawaited(quitNow());
    }
  }

  // ── 窗口事件 ──────────────────────────────────────────────────────

  @override
  void onWindowClose() {
    if (_quitting) {
      // 已经在退出流程里 ⇒ 放行（真正关掉）
      unawaited(_destroyAndClose());
      return;
    }
    unawaited(_handleClose());
  }

  Future<void> _handleClose() async {
    switch (action) {
      case CloseAction.tray:
        debugPrint('[TRAY] 关闭 ⇒ 按上次选择：最小化到托盘');
        await hideToTray();
      case CloseAction.quit:
        debugPrint('[TRAY] 关闭 ⇒ 按上次选择：彻底退出');
        await quitNow();
      case CloseAction.ask:
        await _askOnce();
    }
  }

  /// 第一次点 X：问一次，并把答案记住
  Future<void> _askOnce() async {
    /*
     * ⚠️ `windowManager.close()` 在 Windows 上是**同步**的 DestroyWindow 路径，
     *    所以这里必须等一帧再弹窗 —— 否则对话框的 route 还没挂到
     *    Navigator 上，窗口就已经不可见了。
     * ★ 用 `_dialogContext`（MaterialApp 的 navigatorKey）而不是随便一个
     *    context：`showAppDialog` 需要 Navigator 祖先。
     */
    final ctx = navigatorKey.currentContext;
    if (ctx == null) {
      debugPrint('[TRAY] ★ 拿不到 Navigator context ⇒ 退化为直接退出');
      await quitNow();
      return;
    }
    final choice = await showAppDialog<CloseAction>(
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        title: const Text('要关闭还是彻底退出？'),
        content: const Text(
          '最小化到托盘：窗口收起来，程序继续在后台运行，'
          '点托盘图标可以随时打开。\n\n'
          '彻底退出：结束程序，后台下载等任务会一起停止。\n\n'
          '选择后会被记住，下次点 X 直接按这次的选择执行'
          '（在设置页里可以改回来）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(CloseAction.tray),
            child: const Text('最小化到托盘'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(CloseAction.quit),
            child: const Text('彻底退出'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (choice == null) {
      debugPrint('[TRAY] 用户取消 ⇒ 什么都不做');
      return;
    }
    rememberCloseAction(choice);
    switch (choice) {
      case CloseAction.tray:
        await hideToTray();
      case CloseAction.quit:
        await quitNow();
      case CloseAction.ask:
        break;
    }
  }

  /// 记住用户的选择（设置页也用它改回来）
  static void rememberCloseAction(CloseAction a) {
    UiPrefs.set(closeActionKey, a.name);
    debugPrint('[TRAY] 记住关闭行为 = ${a.name}');
  }

  /// 藏到托盘
  Future<void> hideToTray() async {
    try {
      await windowManager.hide();
      /*
       * ★ 顺手把「跳过任务栏」打开 —— 否则窗口虽然 hidden，
       *   任务栏上仍留一个占位（Windows 的 hidden 窗口默认仍在
       *   taskbar 里有条目，视 DWM 版本而定）。
       * ⚠️ 恢复时**必须**关掉它，否则窗口回来了但任务栏没有它。
       */
      await windowManager.setSkipTaskbar(true);
    } catch (e) {
      debugPrint('[TRAY] 隐藏窗口失败: $e');
    }
  }

  /// 从托盘恢复窗口
  Future<void> restoreWindow() async {
    try {
      await windowManager.setSkipTaskbar(false);
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('[TRAY] 恢复窗口失败: $e');
    }
  }

  /// 彻底退出（托盘菜单「退出」与关闭确认都走这里）
  Future<void> quitNow() async {
    _quitting = true;
    await dispose();
    await _destroyAndClose();
  }

  Future<void> _destroyAndClose() async {
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (e) {
      debugPrint('[TRAY] 退出失败，退回 close(): $e');
      try {
        await windowManager.close();
      } catch (_) {}
    }
  }
}
