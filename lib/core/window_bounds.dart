/// ★★★ m13655 (B)：窗口几何（尺寸 + 位置）的持久化与还原
///
/// # 需求（Owner 原话，2026-10-04）
///
/// > 「调整窗口大小后记录，下次打开要还原  而不是默认的」
///
/// # 存储
///
/// 写进**已有的** `ui-prefs.json`（`lib/core/ui_prefs.dart`，与其它 UI 偏好
/// 同一个文件、同一套读写）：
///
/// ```text
/// dsh.window.bounds = "x,y,w,h"
/// ```
///
/// ⚠️ 四个值**全部是 DIP**（逻辑像素），逗号分隔，无空格。
///
/// # 为什么必须是 DIP（这里错过一次就会「窗口越开越小」）
///
/// ```text
/// window_manager 的 getBounds() / setBounds() **两边都是 DIP**：
///   Windows 侧 window_manager.cpp:759-766
///     x = static_cast<int>(*v * devicePixelRatio)
///   Windows 侧 window_manager.cpp:718-740 GetBounds
///     返回 GetWindowRect() ÷ devicePixelRatio
/// ⇒ 存物理像素会**多除一次**：150% 缩放的机器上窗口会缩到 2/3。
/// ```
///
/// ⚠️ 已知代价（如实记录，不假装没有）：
/// ```text
/// ① static_cast<int> 是**截断**而不是四舍五入
/// ② 换了显示器（DPR 变了）时，存下来的 DIP 位置会有偏差
/// 两条都是插件层的既有行为 —— 本文件不修它，也不声称修好了。
/// ```
///
/// # ★★ 为什么要有一个单独的类，而不是在 `shell.dart` 里写十行
///
/// 因为**还原的时机**与 `show()` 强耦合（见 `restore()` 的说明），
/// 而"记录"发生在 `window_frame.dart` 的 `WindowListener` 里 ——
/// 两处都需要同一套解析/夹取逻辑，且都要能在**没有窗口**的单测里跑。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'ui_prefs.dart';

/// 窗口几何的读写 + 落屏夹取
class WindowBoundsStore {
  WindowBoundsStore._();

  /// 存储键 —— 故意**不**放在 `dsh.srcpref.*` 命名空间里
  ///
  /// 「窗口多大/在哪儿」和「某作品用哪条播放线路」是完全不相干的两件事，
  /// 混在一起的话，将来做"清空播放偏好"会把窗口几何一起清掉。
  static const String key = 'dsh.window.bounds';

  /// 最小尺寸 —— **与原版 Tauri 一致**
  ///
  /// `src-tauri/tauri.conf.json` 里是 `"minWidth": 900, "minHeight": 600`，
  /// `lib/shell.dart` 的 `windowOptions.minimumSize` 也是这两个值。
  ///
  /// ⚠️ 不要调小：右侧详情面板在 <900 宽时会走上下分栏，头部 + 选集放不下
  ///    （完整论证见 `shell.dart` 里 `minimumSize` 上方那段注释）。
  static const double minWidth = 900;
  static const double minHeight = 600;

  /// 本平台是否支持（桌面才有 window_manager / screen_retriever 的原生实现）
  static bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  // ── 序列化（**纯函数**，单测直接打这两个） ──

  /// `"x,y,w,h"` ⇒ `Rect`；解析不了就返回 `null`（调用方退回默认几何）
  ///
  /// ⚠️ 这里**只做解析**，不做任何屏幕夹取 —— 夹取要用到显示器信息，
  ///    那是异步的（`_fitToDisplays`）。分成两步是为了单测能不碰插件。
  static Rect? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split(',');
    if (parts.length != 4) return null;
    final v = <double>[];
    for (final part in parts) {
      final d = double.tryParse(part.trim());
      if (d == null || !d.isFinite) return null;
      v.add(d);
    }
    return Rect.fromLTWH(v[0], v[1], v[2], v[3]);
  }

  /// `Rect` ⇒ `"x,y,w,h"`（整数 DIP）
  ///
  /// ⚠️ 取整而不是原样 `toString()`：`getBounds()` 是 `int ÷ dpr` 算出来的，
  ///    在 125%/150% 缩放下会是 `1023.9999999999999` 这种值 ——
  ///    原样存进 JSON 又长又难读，而且每次读回来的字符串都可能不同
  ///    （`UiPrefs.set` 里有"值没变就不写"的短路，那样会失效）。
  static String format(Rect r) =>
      '${r.left.round()},${r.top.round()},'
      '${r.width.round()},${r.height.round()}';

  /// 读上次记住的几何（没存过 / 存坏了 ⇒ `null`）
  static Rect? read() => parse(UiPrefs.get(key));

  // ── 记录 ──

  /// 直接记一个矩形（单测用；生产走 `recordCurrent()`）
  static void set(Rect r) {
    final v = format(r);
    if (UiPrefs.get(key) == v) return;
    UiPrefs.set(key, v);
    /*
     * ★ 立刻落盘，不等 `UiPrefs` 那 300ms 的合并窗口。
     *
     * 为什么：`UiPrefs.set` 的落盘是 `Future.delayed(300ms)`；
     * 而用户完全可能"拖完窗口 → 马上点关闭"—— 那时进程已经退了，
     * 300ms 后的那次写永远不会发生 ⇒ **这次拖动白记了**。
     *
     * 开销可忽略：一次几十字节的 `writeAsString`，且只在
     * `WM_EXITSIZEMOVE`（一次拖拽手势结束）时发生一次。
     */
    unawaited(UiPrefs.flush());
    debugPrint('[WINDOW-BOUNDS] 记住 $v');
  }

  /// 记住**当前**窗口几何 —— 由 `window_frame.dart` 的 `WindowListener` 调用
  ///
  /// # 为什么这三种状态要**跳过**
  ///
  /// ```text
  /// 最大化 / 全屏  窗口矩形是"整块屏"，记下来下次就会以最大化尺寸打开，
  ///                而且再也回不到用户真正调好的那个大小
  /// 最小化         矩形是 (−32000,−32000) 这种哨兵值
  /// ```
  ///
  /// ⚠️ 必须**自己查**这三种状态，不能靠 `_WindowFrameState._filled`：
  ///    那个字段是异步刷新的，事件到达时可能还是上一轮的旧值。
  static Future<void> recordCurrent() async {
    if (!isSupported) return;
    try {
      if (await windowManager.isMaximized()) return;
      if (await windowManager.isFullScreen()) return;
      if (await windowManager.isMinimized()) return;
      final r = await windowManager.getBounds();
      if (r.width < minWidth || r.height < minHeight) return;
      set(r);
    } catch (e) {
      debugPrint('[WINDOW-BOUNDS] 读取窗口几何失败（忽略）: $e');
    }
  }

  // ── 还原 ──

  /// 把记住的几何应用到窗口 —— ★ **必须在 `windowManager.show()` 之前调**
  ///
  /// # 为什么顺序是硬要求（这是本功能唯一容易做错的地方）
  ///
  /// ```text
  /// window_manager 的 Show()（window_manager.cpp:276-287）做的是
  ///   SetWindowLong(GWL_STYLE |= WS_VISIBLE) + ShowWindowAsync(SW_SHOW)
  /// ⇒ 一旦调过，窗口**立刻**可见。
  ///
  /// 而 UiPrefs 要到 shell.dart 的 `await UiPrefs.load(dir)` 才加载完 ——
  /// 那是 waitUntilReadyToShow 之后几百毫秒。
  ///
  /// 所以：把 show() 从 waitUntilReadyToShow 的回调里**搬出来**，
  ///       搬到「UiPrefs 已加载 → 还原几何 → 才 show」的位置。
  /// ⇒ 窗口**第一次出现在屏幕上时就已经是记住的位置**，没有任何跳动。
  /// ```
  ///
  /// ⚠️ 反例（实测过，不要退回去）：在 `waitUntilReadyToShow` 的回调里
  ///    `show()`、之后再 `setBounds`。窗口会在 (640,300) 出现一帧再跳走。
  ///
  /// 返回值：真的应用了才 `true`（没存过 / 平台不支持 / 出错 ⇒ `false`，
  /// 调用方**照常** show，绝不能因为还原失败就不显示窗口）。
  static Future<bool> restore() async {
    if (!isSupported) return false;
    final saved = read();
    if (saved == null) return false;
    try {
      final target = await _fitToDisplays(saved);
      await windowManager.setBounds(target);
      /*
       * ⚠️ 用 `format()` 而不是直接插值 `Rect`：`Rect.toString()` 在 AOT
       *    Release 里输出的是 `Instance of 'Rect'`（实测日志），
       *    那样这条日志就等于没打。
       */
      debugPrint('[WINDOW-BOUNDS] 还原 ${format(saved)} -> ${format(target)}');
      return true;
    } catch (e) {
      debugPrint('[WINDOW-BOUNDS] 还原失败（退回默认几何）: $e');
      return false;
    }
  }

  /// 把矩形夹进**目标显示器的工作区**（= 显示器矩形**减去任务栏**）
  static Future<Rect> _fitToDisplays(Rect saved) async {
    final w = saved.width < minWidth ? minWidth : saved.width;
    final h = saved.height < minHeight ? minHeight : saved.height;
    final want = Rect.fromLTWH(saved.left, saved.top, w, h);

    final primary = await screenRetriever.getPrimaryDisplay();
    var work = _workAreaOf(primary);

    /*
     * 多显示器：优先用"**存下来的窗口中心点**落在哪个显示器的工作区里"，
     * 而不是无脑用主显示器 —— 否则副屏上摆好的窗口每次重启都会被拽回主屏。
     *
     * ⚠️ `getAllDisplays()` 失败不影响主流程（退化成主显示器）。
     */
    try {
      final center = want.center;
      for (final d in await screenRetriever.getAllDisplays()) {
        final a = _workAreaOf(d);
        if (a.contains(center)) {
          work = a;
          break;
        }
      }
    } catch (e) {
      debugPrint('[WINDOW-BOUNDS] 枚举显示器失败（只用主显示器）: $e');
    }

    return clampTo(want, work);
  }

  /// 显示器的工作区（DIP）
  ///
  /// ★★ 只能用 `visiblePosition` / `visibleSize`
  ///
  /// ```text
  /// screen_retriever_windows_plugin.cpp:107-135
  ///   visiblePosition / visibleSize  ← GetMonitorInfo 的 **rcWork**（已扣任务栏）
  ///   size                           ← rcMonitor 的**整个**显示器（含任务栏）
  /// ⇒ 用 size 做夹取会把窗口塞到任务栏底下。
  ///    本机任务栏 40px，实测见 shell.dart 里 2560x1400 vs 2560x1440 那段。
  /// ```
  ///
  /// ⚠️ 两个字段在平台接口里都是**可空**的（`display.dart:34,37`），
  ///    插件没给就退回整个显示器 —— 宁可差 40px，也不要抛异常。
  static Rect _workAreaOf(Display d) {
    final size = d.visibleSize ?? d.size;
    final pos = d.visiblePosition ?? Offset.zero;
    return Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height);
  }

  /// 夹取：尺寸不超工作区、位置保证整个窗口在可见区域内
  ///
  /// 为什么是"整个窗口都在里面"而不是"留一条边能抓"：
  /// Windows 拖动时本来就保证标题栏在屏内，用户不可能有意把窗口拖出去；
  /// 而**换了显示器/改了分辨率**之后，旧坐标完全可能落在屏幕外 ——
  /// 那时用户看到的是"窗口没了"，只能去任务栏右键"移动"，非常难查。
  ///
  /// ⚠️ `@visibleForTesting` 但**不是**纯测试用：`_fitToDisplays()` 是它的
  ///    唯一生产调用点。公开它是因为「屏幕外坐标会不会被夹回来」是
  ///    本功能里唯一会**让窗口整个消失**的分支，必须能被单测直接打。
  @visibleForTesting
  static Rect clampTo(Rect r, Rect work) {
    var w = r.width;
    var h = r.height;
    if (w > work.width) w = work.width;
    if (h > work.height) h = work.height;
    if (w < minWidth) w = minWidth;
    if (h < minHeight) h = minHeight;

    var x = r.left;
    var y = r.top;
    if (x + w > work.right) x = work.right - w;
    if (y + h > work.bottom) y = work.bottom - h;
    if (x < work.left) x = work.left;
    if (y < work.top) y = work.top;

    return Rect.fromLTWH(x, y, w, h);
  }
}
