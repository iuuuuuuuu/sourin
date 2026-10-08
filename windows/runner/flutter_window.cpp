#include "flutter_window.h"

#include <cstdio>
#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "window_shadow.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // ★ 2026-09-30 纯增量日志（不改行为，Lead 批准）：唯一能把"C++ 回调本身
    //   晚"与"锁屏推迟了 raster 完成回调"分开的手段 —— 只有时间戳能区分。
    //   ⚠️ 探针按 "fallback" 关键字判定兜底是否开火（见 .probe/t51_flip.py）：
    //   本行在正常路径上**必然**出现，所以不能让探针继续把"任何 [SHADOW] 行"
    //   当作兜底开火的证据（否则正常启动也报 1 行 ⇒ 判据 3 的二元信号失效）。
    std::printf("[SHADOW] first frame callback\n");
    std::fflush(stdout);
    this->Show();
    // ★ 客户区第一帧真的画出来了 ⇒ 放行阴影（见 window_shadow.h 的长注释）。
    //   放在 Show() 之后：主窗先可见，阴影再出现 —— 与实测的
    //   2821.275ms / 3043.2ms 顺序一致，不再出现"先阴影后客户端"。
    sourin::WindowShadow::Instance().NotifyFirstFrameReady();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
