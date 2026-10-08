// ═══════════════════════════════════════════════════════════════════════
//  画中画（PiP）—— 对齐原版 PlayerView 的 `P` 键行为
// ═══════════════════════════════════════════════════════════════════════
//
// # 原版怎么做的（以及为什么不能照抄）
//
// ```text
// 原版：hk.add("KeyP", () => { if (art) art.pip = !art.pip; });
//       // ArtPlayer 内置的 pip 开关，底层是 <video>.requestPictureInPicture()
// ```
// 原版跑在 **WebView** 里，直接用浏览器的 PiP API —— 那是浏览器白送的。
//
// ★ 实测确认：**media_kit 没有内置 PiP**（翻过 media_kit 与
//   media_kit_video 的全部源码，没有任何 `pictureInPicture` 相关 API）。
//
// 所以必须**平台侧自己实现**：
// ```text
// Windows  → 把窗口缩成小窗 + 置顶 + 不进任务栏（悬浮窗形态）
// Android  → 系统原生 PiP（enterPictureInPictureMode，API 26+）
// 其他平台 → 不支持（如实返回 false，不假装成功）
// ```
//
// # ★ 为什么不假装支持
//
// `isSupported` 为 false 时，播放器**不显示** PiP 按钮、`P` 键**不做任何事**。
// 假装支持然后什么都不发生，比明确不支持更糟 —— 用户会以为"按坏了"。
//
// # ⚠️ window_manager 在 Android 上会挂（项目踩过）
//
// ```text
// 症状：调 ensureInitialized() 后 await **永不返回** →
//       白屏且**没有任何异常**
// ```
// 但那次的根因是**在 Android 上调用了它**，不是"导入了它"。
// 这里所有调用点都在 `if (Platform.isWindows)` 分支内 ——
// 导入是安全的（`kIsDesktop` 常量分支的写法见 shell.dart）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// PiP 状态变化回调
typedef PipListener = void Function(bool active);

/// 画中画控制器
///
/// 单例 —— 同一时刻只可能有一个播放器在画中画。
class PipController {
  PipController._();

  static final PipController instance = PipController._();

  static const _channel = MethodChannel('sourin/pip');

  /// 原生 → Dart 的回调（Android 用户点小窗的 X 关闭时通知）
  ///
  /// ⚠️ 这个回调**必须**接上：
  ///    不接的话 Flutter 侧不知道用户已经关了小窗，
  ///    播放器上的 PiP 按钮会一直显示"已激活"，再点一下反而进不去。
  static void _installHandler() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPipChanged') {
        final args = call.arguments;
        final active = (args is Map && args['active'] == true);
        instance.onNativeStateChanged(active);
      }
      return null;
    });
  }

  static bool _handlerInstalled = false;

  /// Windows PiP 小窗宽度
  ///
  /// 420 是实测比较舒服的值：够看清字幕，又不挡太多。
  static const _pipWidth = 420.0;

  /// 进入 PiP 前的最小窗口尺寸（与 shell 初始化时一致）
  static const _minSize = Size(900, 600);

  bool _active = false;
  bool _supported = false;
  bool _probed = false;

  final _listeners = <PipListener>[];

  /// Windows 进入 PiP 前的窗口状态（退出时还原）
  _WinState? _saved;

  bool get isActive => _active;
  bool get isSupported => _supported;

  /// 探测平台支持
  ///
  /// ⚠️ 必须 await 一次 —— Android 要问系统 API 版本。
  Future<bool> probe() async {
    if (_probed) return _supported;
    _probed = true;

    if (kIsWeb) return _supported = false;

    if (Platform.isAndroid) {
      // ★ 接上原生回调（只接一次）
      if (!_handlerInstalled) {
        _handlerInstalled = true;
        _installHandler();
      }
      try {
        _supported =
            await _channel.invokeMethod<bool>('isPipSupported') ?? false;
      } catch (e) {
        debugPrint('[PIP] Android 探测失败（视为不支持）: $e');
        _supported = false;
      }
      return _supported;
    }

    /*
     * 桌面端用「缩小窗口 + 置顶」模拟 PiP。
     *
     * ⚠️ 这不是系统级 PiP（那个只有 macOS 有原生支持），
     *    但**用户要的效果**达到了：小窗浮在别的窗口上面、能继续看。
     */
    _supported = Platform.isWindows;
    return _supported;
  }

  void addListener(PipListener l) {
    if (!_listeners.contains(l)) _listeners.add(l);
  }

  void removeListener(PipListener l) => _listeners.remove(l);

  void _notify(bool v) {
    _active = v;
    for (final l in [..._listeners]) {
      l(v);
    }
  }

  /// 进入画中画
  ///
  /// [aspectRatio] 视频宽高比（宽/高）。返回是否成功。
  Future<bool> enter({double aspectRatio = 16 / 9}) async {
    if (!await probe()) return false;
    if (_active) return true;

    if (Platform.isAndroid) {
      try {
        final ok = await _channel.invokeMethod<bool>('enterPip', {
          'aspectRatio': aspectRatio,
        });
        if (ok == true) _notify(true);
        return ok == true;
      } catch (e) {
        debugPrint('[PIP] Android 进入失败: $e');
        return false;
      }
    }

    if (Platform.isWindows) return _enterWindows(aspectRatio);

    return false;
  }

  /// 退出画中画
  Future<bool> exit() async {
    if (!_active) return true;

    if (Platform.isAndroid) {
      try {
        final ok = await _channel.invokeMethod<bool>('exitPip');
        _notify(false);
        return ok == true;
      } catch (e) {
        debugPrint('[PIP] Android 退出失败: $e');
        _notify(false);
        return false;
      }
    }

    if (Platform.isWindows) return _exitWindows();

    _notify(false);
    return true;
  }

  /// 切换（`P` 键用）
  Future<bool> toggle({double aspectRatio = 16 / 9}) async {
    if (_active) return exit();
    return enter(aspectRatio: aspectRatio);
  }

  /// 由原生侧主动通知状态变化（Android 用户点了小窗的关闭按钮）
  void onNativeStateChanged(bool active) {
    if (_active != active) _notify(active);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Windows：缩小窗口 + 置顶
  // ═══════════════════════════════════════════════════════════════════

  Future<bool> _enterWindows(double aspectRatio) async {
    try {
      // ① 先存原状态（退出时要精确还原）
      _saved = _WinState(
        size: await windowManager.getSize(),
        position: await windowManager.getPosition(),
        alwaysOnTop: await windowManager.isAlwaysOnTop(),
        resizable: await windowManager.isResizable(),
        skipTaskbar: await windowManager.isSkipTaskbar(),
      );

      /*
       * ⚠️ 必须**先解除最小尺寸限制**
       *
       * 窗口初始化时设了 `minimumSize: Size(900, 600)` ——
       * 不解除的话 `setSize(420, ...)` 会被静默钳到 900x600，
       * 用户看到的是「按了 P 但窗口没变小」。
       */
      await windowManager.setMinimumSize(Size.zero);

      final h = (_pipWidth / aspectRatio).clamp(160.0, 640.0);
      await windowManager.setSize(Size(_pipWidth, h));

      await windowManager.setAlwaysOnTop(true);
      await windowManager.setResizable(false);

      // 不进任务栏 —— 否则 PiP 小窗会在任务栏留一个条目（不像 PiP）
      try {
        await windowManager.setSkipTaskbar(true);
      } catch (e) {
        // 某些平台不支持，不影响主功能
        debugPrint('[PIP] setSkipTaskbar 不支持: $e');
      }

      _notify(true);
      return true;
    } catch (e) {
      debugPrint('[PIP] Windows 进入失败: $e');
      return false;
    }
  }

  Future<bool> _exitWindows() async {
    final s = _saved;
    if (s == null) {
      _notify(false);
      return true;
    }
    try {
      await windowManager.setResizable(true);
      await windowManager.setAlwaysOnTop(s.alwaysOnTop);
      await windowManager.setSize(s.size);
      await windowManager.setPosition(s.position);
      try {
        await windowManager.setSkipTaskbar(s.skipTaskbar);
      } catch (_) {}
      // 恢复最小尺寸（与初始化时一致）
      await windowManager.setMinimumSize(_minSize);
      await windowManager.setResizable(s.resizable);
      _saved = null;
      _notify(false);
      return true;
    } catch (e) {
      debugPrint('[PIP] Windows 退出失败: $e');
      _saved = null;
      _notify(false);
      return false;
    }
  }
}

/// 窗口状态快照
class _WinState {
  const _WinState({
    required this.size,
    required this.position,
    required this.alwaysOnTop,
    required this.resizable,
    required this.skipTaskbar,
  });

  final Size size;
  final Offset position;
  final bool alwaysOnTop;
  final bool resizable;
  final bool skipTaskbar;
}
