// ===========================================================================
// 窗口投影 —— 用**独立的 WS_EX_LAYERED 窗口**在主窗口后面画高斯模糊阴影
// ===========================================================================
//
// # 用户诉求（原话）
//
// > 那为什么 qq 就能实现，你不行？你死磕这个问题给解决了
//
// # 为什么必须走这条路（三条被实测否掉的替代方案）
//
// ```text
// ① 让 DWM 画阴影 —— ★ 本机拿不到（系统级）
//    实测（.probe/orch_fresh_window.txt）：
//      新建一个【全新】WS_OVERLAPPEDWINDOW 窗口（CAPTION=Y THICK=Y）
//      DwmGetWindowAttribute(EXTENDED_FRAME_BOUNDS) 外扩 = (0,0,0,0)
//      窗口外像素 = 249 249 249 ...（均匀，无渐变）
//    ⇒ 不是我们的样式问题，是【系统不给任何窗口画阴影】
//      根因：VisualFXSetting = 2（「调整为最佳性能」← 关闭窗口阴影）
//
// ② 在窗口【内侧】画投影 —— ★ 结构上不可能对
//    实测（.probe/RING-real2.png）：窗口最外 5~16px 是"比内容暗 19 级"的实色带
//    用户反馈：「现在就是一圈实色的边缘，根本就不是阴影」
//    ⇒ 真投影必须画在窗口【外面】；画在内侧会被窗口边界【硬切】
//
// ③ SetWindowRgn 的二值裁剪 —— 做不出渐变（只能 7 级台阶）
// ```
//
// # 为什么"独立 layered 窗口"可行（原型已实测成功）
//
// ```text
// 关键洞察：阴影是**静态**的 —— 只在窗口移动/缩放时重画一次。
// ⇒ 不需要"每帧拷贝整窗"（那条路实测 16.1ms/帧，视频播放器不可接受），
//   只需要在 WM_MOVE / WM_SIZE 时调一次 UpdateLayeredWindow。
//
// 实现（.probe/shadow_proto3.py 原型，实测 UpdateLayeredWindow -> 1）：
//   ① 算 alpha：圆角矩形 -> 分离式高斯模糊（sigma=8）
//   ② 组装 32bpp premultiplied BGRA（黑色阴影）
//   ③ 建 WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT
//      + WS_POPUP 窗口，用 UpdateLayeredWindow 贴位图
//   ④ 用 SetWindowPos(hwnd, main, ...) 插到主窗口【正下方】的 Z 序
//
// 实测渐变（.probe/SHADOW3-TL.png，主窗口左边 28px）：
//   255 255 255 255 254 254 253 253 252 251 250 248 246 244 242 239
//   235 231 227 222 217 212 206 200 | 255（窗口内容）
//   ⇒ ★ 从远到近平滑变暗 —— 这就是 QQ 那种"边缘模糊阴影"
// ```
//
// ⚠️ 注意 `UpdateLayeredWindow` 的 `SIZE` 参数是 **8 字节**（两个 LONG），
//    不是 4 字节。原型第一版用 `c_ulong` 传 ⇒ 返回 0 / GetLastError=31。
//
// ===========================================================================

#ifndef SOURIN_WINDOW_SHADOW_H_
#define SOURIN_WINDOW_SHADOW_H_

#include <windows.h>

namespace sourin {

/// 阴影窗口的生命周期管理（单例，跟随主窗口）
///
/// 用法（在 `Win32Window` 里）：
/// ```cpp
/// sourin::WindowShadow::Instance().Attach(window);   // 创建后
/// sourin::WindowShadow::Instance().Update();         // WM_MOVE/WM_SIZE 时
/// sourin::WindowShadow::Instance().Detach();         // WM_DESTROY 时
/// ```
class WindowShadow {
 public:
  static WindowShadow& Instance();

  /// 创建阴影窗口并跟随 `main_window`
  ///
  /// ⚠️ 幂等：重复调用只更新位置，不重复创建
  /// ⚠️ 失败不抛：阴影是"锦上添花"，不该让主窗口画不出来
  void Attach(HWND main_window);

  /// 重新计算位置/尺寸并重画（主窗口移动或缩放后调用）
  ///
  /// ⚠️ 首帧就绪之前**只维护位置/尺寸，不显示**（见 NotifyFirstFrameReady）
  void Update();

  /// ★ 首帧已画出 ⇒ 放行阴影显示（由 `FlutterWindow` 的首帧回调调用）
  ///
  /// ```text
  /// 为什么需要它（实测 .probe/t51_flip.py，2026-09-30）：
  ///   主窗口由 Dart 侧 `windowManager.show()` 显示 —— 2821.275 ms；
  ///   客户区第一帧到 3043.2 ms 才画出来（[SHELL] FIRST_FRAME_RENDERED）。
  ///   ⇒ 中间 187.1 ms 里，阴影（layered 窗口，UpdateLayeredWindow 立刻出
  ///     像素）已经可见，客户区却还是空白矩形
  ///   ⇒ 用户看到的就是"先显示阴影，再显示客户端"。
  /// ⇒ 阴影必须等首帧。
  /// ```
  ///
  /// ⚠️ 幂等：重复调用无副作用。
  void NotifyFirstFrameReady();

  /// ★ 超时兜底：首帧回调始终没来时，到这里放行（由内部定时器调用）
  ///
  /// ⚠️ 只给定时器回调一个入口用；**不要**在别处调用。
  void OnFirstFrameFallbackTimeout();

  /// 逐帧重同步定时器回调（由内部定时器调用）
  ///
  /// ⚠️ 只给定时器回调一个入口用；**不要**在别处调用。
  /// ⚠️ 必须是 **public**：`ShadowWindowProc` 是匿名命名空间里的自由函数，
  ///    不是本类的成员，调不了 private 方法（`OnFirstFrameFallbackTimeout`
  ///    同理由，也是 public）。
  void OnResyncTimeout();

  /// ★ 尺寸变化**在途**：布防一段**有界**的逐帧重同步
  ///
  /// 背景（`.probe/t51_result.md` 4.1 (2) 实测）：最大化/还原时阴影会**整段**
  /// 停在旧矩形上——最差 800px，且逐样本比对「阴影 vs 它自己上一帧」恒为
  /// (0,0,0,0)，即更新路径**根本没被触发过**，因为窗口尺寸落地晚于触发它的
  /// 那次消息。只靠 `WM_WINDOWPOSCHANGED` 里那一次 `Update()` 跟不上。
  /// 这里补一段「自己按帧读主窗口矩形」的节奏；布防点在 `win32_window.cpp`
  /// 的 `WM_WINDOWPOSCHANGING`（那里最早知道「即将变尺寸」，next 已经算好了）。
  ///
  /// ★ 有界：最多 `kResyncTicks` 拍（约 320ms）后自动 `KillTimer`，绝不常驻。
  /// ★ 幂等 + 可续期：重复调用只重置拍数，不会重复 `SetTimer`（拖动时每帧都进）。
  /// ★ 只负责「让 `Update()` 多跑几拍」；位图重建仍由 `Update()` 里
  ///    「尺寸没变就复用位图」的短路把关，没有尺寸变化时每拍只是一次
  ///    `GetWindowRect` + `SetWindowPos`。
  void NotifySizeChangeInFlight();

  /// 销毁阴影窗口（主窗口销毁时调用）
  void Detach();

  /// 是否启用（`SOURIN_WIN_SHADOW=0` 可关，便于 A/B）
  static bool Enabled();

 private:
  WindowShadow() = default;
  ~WindowShadow();
  WindowShadow(const WindowShadow&) = delete;
  WindowShadow& operator=(const WindowShadow&) = delete;

  bool CreateShadowWindow();
  bool BuildBitmap(int width, int height);
  void DestroyShadowWindow();

  HWND main_ = nullptr;      ///< 主窗口
  HWND shadow_ = nullptr;    ///< 阴影窗口
  int width_ = 0;            ///< 上次的位图宽（尺寸变了才重建位图）
  int height_ = 0;
  HBITMAP bitmap_ = nullptr; ///< DIB section
  void* bits_ = nullptr;     ///< DIB 像素指针

  /// ★ 首帧是否已画出（未就绪时**只定位、不显示**，见 NotifyFirstFrameReady）
  bool first_frame_ready_ = false;
  /// ★ 1500ms 兜底定时器是否已布防（只布防一次）
  bool fallback_armed_ = false;
  /// ★ 逐帧重同步定时器是否已布防（见 NotifySizeChangeInFlight）
  bool resync_armed_ = false;
  /// ★ 逐帧重同步已经走了几拍（到 kResyncTicks 自动 KillTimer）
  int resync_tick_ = 0;
};

}  // namespace sourin

#endif  // SOURIN_WINDOW_SHADOW_H_
