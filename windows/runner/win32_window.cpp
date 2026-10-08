#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>  // GET_X_LPARAM / GET_Y_LPARAM（WM_NCHITTEST 用）

#include <cstdio>
#include <string>

#include "resource.h"
#include "window_shadow.h"  // ★ 窗口投影（独立 layered 窗口，见该文件头）

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

/// 可见窗口边框（不含 Win10 那圈**隐形**缩放边框）
///
/// `ExtFrameBounds` 与 `GetWindowRect` 之差 = DWM 为该窗口保留的边框，
/// 也就是**投影所在的那一圈**。判"去投影有没有生效"就看它俩是否重合。
///
/// 同样做兜底定义，避免老 SDK 上编译不过。
#ifndef DWMWA_EXTENDED_FRAME_BOUNDS
#define DWMWA_EXTENDED_FRAME_BOUNDS 9
#endif

/*
 * ═══════════════════════════════════════════════════════════════════════
 *  ★ 圆角窗口：让"裁剪区之外"真正透出桌面
 * ═══════════════════════════════════════════════════════════════════════
 *
 * # 问题（用户报的，实测确认）
 *
 * Dart 侧已经用 `WindowFrame` 的 `ClipRRect` 把应用裁成圆角
 *（`lib/ui/widgets/window_frame.dart`），但裁剪区**之外**的像素
 * 是 Flutter 的"清屏色"，而清屏色是 `(0,0,0,0)` —— RGB 全 0。
 * 引擎在 HWND 上呈现时**忽略 alpha**，于是那圈透明像素渲染成
 * **纯黑**。实测：
 * ```text
 * 左上角 16x16：近黑(<=6) 123 px / 纯白 6 px
 * 对角线 (0,0)..(6,6) 全 R0 G0 B0
 * 左边 x=0 整列 15px 纯黑
 * ```
 * 也就是说圆角**画出来了**，但角上填的是黑块。
 *
 * # 为什么 `WindowOptions(backgroundColor: transparent)` 不管用
 *
 * 那条走的是 `window_manager` 的 `SetBackgroundColor` →
 * `SetWindowCompositionAttribute`(ACCENT_ENABLE_TRANSPARENTGRADIENT)，
 * 那是 **DWM 对窗口的着色策略**，不是"让客户区像素带 alpha"。
 * 它改不了"清屏色是黑"这件事。
 *
 * # 三条路，以及为什么选 `DwmEnableBlurBehindWindow`
 *
 * ```text
 * A. WS_EX_LAYERED + SetLayeredWindowAttributes(LWA_COLORKEY)
 *    → 需要四个角是**唯一的键色**。但角上现在是清屏色黑，
 *      而播放页的视频区本来就是纯黑 —— 用黑做键色会把视频区
 *      也挖空。Dart 侧又改不了 WindowFrame（文件归属限制），
 *      造不出唯一键色。**否决**。
 *
 * B. SetWindowRgn(圆角 region)
 *    → 二值裁剪，Win10 不给抗锯齿。而且裁剪区之内、ClipRRect
 *      之外**仍然**是清屏色黑 —— 硬边内侧照样有一条黑弧。
 *      原版也实测否决过它（"零个过渡像素"）。**否决**。
 *
 * C. DwmEnableBlurBehindWindow（空 blur region）← ★ 选它
 *    → 这是**原版（Tauri/tao 0.35.3）在同一台 Win10 上用过的
 *      同一条路**，已证明可行：
 *      `tao-0.35.3/src/platform_impl/windows/window.rs:1284`
 *      ```rust
 *      if attributes.transparent && !pl_attribs.no_redirection_bitmap {
 *        // Empty region for the blur effect, so the window is fully transparent
 *        let region = CreateRectRgn(0, 0, -1, -1);
 *        let bb = DWM_BLURBEHIND {
 *          dwFlags: DWM_BB_ENABLE | DWM_BB_BLURREGION,
 *          fEnable: true.into(), hRgnBlur: region, ...
 *        };
 *        DwmEnableBlurBehindWindow(real_window.0, &bb);
 *      }
 *      ```
 *      空 region 意味着"哪里都不模糊"，但 DWM 会把窗口当成
 *      **玻璃合成**目标 —— 客户区里 alpha=0 的像素就透出桌面。
 *      这一条让 Dart 侧**抗锯齿的圆角**原样生效（不用 SetWindowRgn）。
 * ```
 *
 * # 为什么要支持多种方案（A/B）
 *
 * 每换一种方案就要重新编译 C++ 并重启验证，成本很高。所以这里
 * 用**环境变量**做运行时开关 —— 一次构建就能测完所有方案：
 * ```text
 * SOURIN_WIN_ALPHA = none | blur | blurframe | region
 * SOURIN_WIN_ALPHA_RADIUS = <逻辑像素半径，默认 10>
 * ```
 * 不留环境变量时用默认值（见 kDefaultAlphaMode）。
 */
/*
 * ═══════════════════════════════════════════════════════════════════════
 *  ★★ 实测结论：Flutter 的 Windows 表面是**不透明**的
 * ═══════════════════════════════════════════════════════════════════════
 *
 * 我实现了四种"让圆角外透出桌面"的方案，并在**同一位置、同一内容**下
 * 逐像素对比（`.probe/aa-v1`（blur）vs `.probe/aa-z-none`（none））。
 *
 * 结果：**客户区像素完全相同**。
 * ```text
 * mode=none  左上对角线:  10  10   7   6   8  10  29 255 152 241
 * mode=blur  左上对角线: 247 245   7   6   8  10  29 255 152 241
 *                        ↑ 这两像素的差别来自**背景窗口变了**（别的代理的
 *                          窗口在动），第 2 像素之后**逐字节一致**
 * ```
 * 也就是说 `DwmEnableBlurBehindWindow` **对 Flutter 窗口毫无作用**。
 *
 * # 为什么（这才是真根因）
 *
 * Flutter 的 Windows embedder 用 ANGLE 在 HWND 上建 **D3D11 swapchain**，
 * 它的 alpha 通道对 DWM 是**被忽略**的（不是 per-pixel-alpha 合成目标）。
 * 于是：
 * ```text
 * 窗口表面永远是**不透明**的 → alpha=0 的像素被画成**黑色**（清屏色），
 * 而不是"透出桌面"。
 * ```
 * 所以 `ClipRRect` 裁掉的那部分露出的**不是桌面**，而是 Flutter 的
 * 清屏色 —— 深色下就是用户看到的**黑角**。
 *
 * # 这也解释了"为什么原版（Tauri/WebView2）能行"
 *
 * `tao` 用的是同一招（空 region 的 blur-behind，
 * `tao-0.35.3/.../window.rs:1284`），但 WebView2 走的是
 * **DirectComposition**，它的视觉树本来就带 per-pixel alpha。
 * Flutter 没有这一层 —— **同样一行代码，在 WebView2 上有效，
 * 在 Flutter 上无效**。这不是配置问题，是渲染架构差异。
 *
 * # 那"真透明圆角"在 Win10 + Flutter 上能做到吗
 *
 * ```text
 * 做不到（在不改引擎的前提下）。
 * 理由：
 *   ① Win10 无原生圆角 API（DWMWA_WINDOW_CORNER_PREFERENCE 要 Win11 22000+）
 *   ② 自绘圆角 + 透明窗口 这条路需要"表面带 alpha"，
 *      而 Flutter 的 D3D11 swapchain 不提供（上面已实测证明）
 *   ③ SetWindowRgn 是二值裁剪，Win10 不给抗锯齿 —— 原版已明确否决
 *      （实测：有它时对角线 0 个过渡像素，去掉后 26 个）
 * ```
 *
 * # 保留这些模式做什么
 *
 * 全部保留、环境变量门控，但**默认关闭**（[kNone]）——
 * 它们是**已实测无效**的对照实现，留着是为了：
 * ```text
 * ① 将来 Flutter 引擎若支持 alpha 合成，可以直接切过来复测
 * ② 避免后人重复走这四条弯路（每条都花了真实编译+重启验证成本）
 * ```
 * ⚠️ 默认值写成"有效但其实是 no-op"的方案是**误导** ——
 *    所以这里如实默认 `kNone`。
 */
enum class AlphaMode {
  kNone,       ///< 什么都不做（对照用；**四角是方的不透明块**）
  kBlur,       ///< C：DwmEnableBlurBehindWindow 空 region（实测无效）
  kBlurFrame,  ///< C + DwmExtendFrameIntoClientArea(-1)（实测无效，Win10 填不透明白）
  kRegion,     ///< B：SetWindowRgn 圆角（硬边，但**唯一能透出桌面**的路）★ 默认
  kColorKey,   ///< A：WS_EX_LAYERED + LWA_COLORKEY（实测无效）
  /*
   * ★★★ 任务㉗⑤ 新增 —— 但 ★★ **已证伪，勿启用** ★★
   *
   * # ⚠️ 结论：整窗透明，**内容也一起透掉** ⇒ 不适合生产
   *
   * 实测（品红全屏垫底，窗口 1600x1000）：
   * ```text
   * 透明像素 = 100000 / 100000  = 100%
   * 标题栏图标 (20,20)  → #ff00ff（图标没了）
   * 窗口中心 (800,500)  → #ff00ff（内容没了）
   * ```
   * 也就是说 `ACCENT_ENABLE_BLURBEHIND` **不是**"只让窗口背景透明"，
   * 而是把窗口的整个合成层变成"透出背后 + 模糊" ——
   * Flutter 的 swapchain 输出没有 alpha 通道（已实测），
   * DWM 于是把它当成"没有内容"，整块都透出背后。
   *
   * # ★ 保留它的理由（**不要删**）
   *
   * ```text
   * 删掉的话，后人可能重新发现这个 API 再试一遍，浪费同样的时间。
   * 留着 + 写明结论 = 后人一眼看到"此路不通"。
   * ```
   *
   * # 真正生效的修法在 Dart 侧（不在这里）
   *
   * 真凶是 `window_manager` 插件的 `setBackgroundColor()` ——
   * 它内部用 `ACCENT_ENABLE_GRADIENT` + 我们的 backdrop 色给窗口着色，
   * DWM 把"region 裁掉 / Flutter 没覆盖"的那块填成那个色
   * = 用户看到的"假圆角"方块。
   * ⇒ 修法：`window_frame.dart` 改推 `Colors.transparent`
   *   （插件会走 `ACCENT_ENABLE_TRANSPARENTGRADIENT` 分支，nColor=0）。
   *
   * 实测（`.probe/t27_swca.py`，品红底；22x22 左上角）：
   * ```text
   *                      我们的 tint(#EEF0F6) 像素数
   * GRADIENT（插件现状）        44          ← 用户看到的方块
   * TRANSPARENTGRADIENT          0          ← ★ 真修法（内容完好）
   * BLURBEHIND                   0          ← 本枚举：连内容都透掉
   * ACRYLIC                      0          ← 同上
   * ```
   *
   * # ⚠️ 两个测量教训（都真实踩过，写在这里防止后人重犯）
   *
   * ```text
   * ① 必须用**品红底**：黑底无法区分"真透明"与"被模糊成黑" ——
   *    我第一版就是黑底，误判成"acrylic 修好了"。
   * ② 量之前必须确认"角上那个点属于我们"：实测时另一个实例停在
   *    (10,10)-(1290,730)，把我的测试点盖住，于是我量到的是**别人的像素**。
   *    现在 `.probe/t27_swca.py` 会先 `WindowFromPoint` 校验归属，
   *    不属于自己就**拒绝测量**（"测不了"比"测错了"好一万倍）。
   * ```
   *
   * ⚠️ 本枚举**默认不启用**（`kDefaultAlphaMode` 仍是 `kRegion`）。
   *    只用于对照复测：`SOURIN_WIN_ALPHA=composition`。
   *
   * ════════════════════════════════════════════════════════════════════
   * ★★★ 重要更正（2026-09-25）—— 「已证伪」必须绑定**实验条件**
   * ════════════════════════════════════════════════════════════════════
   *
   * 上面曾写「已证伪：整窗透明（内容也透掉）」。**那句话不够准确** ——
   * 它把一个**有条件**的观察写成了**无条件**的结论，从而**误杀了一个可能的正解**。
   *
   * 真正的情况（读本文件的 `case AlphaMode::kComposition` 即可确认）：
   * ```text
   * kComposition : ApplyWindowComposition() + SetWindowRgn(window, nullptr, TRUE)
   *                ⇒ ★ region 被**清掉** ⇒ 整窗透明（内容也没了）
   * 对照实验      : 只调 SetWindowCompositionAttribute(BLURBEHIND)，
   *                **region 保留** ⇒ 只有 region 外透明
   *                实测：角上 #FF00FF（真透出背景）+ 内容色 356/484（完好）
   * ```
   * ⇒ 两次实验**条件不同** ⇒ 两个结论**都成立**、并不矛盾。
   *   被证伪的是「**清掉 region 时**整窗透明」，不是「BLURBEHIND 本身」。
   *
   * ★★ 锁屏下可得的补充证据（`.probe/t27_blur_content.py`，全窗口 PrintWindow）：
   * ```text
   * GRADIENT(对照)        unique=1     corner=#eef0f6
   * TRANSPARENTGRADIENT   unique=1     corner=#000000
   * BLURBEHIND            unique=323   corner=#ffffff   ← ★ 只有它能看到内容
   * DISABLED              unique=1     corner=#000000
   * ```
   * 即：BLURBEHIND 下窗口的**背景层仍有内容**（1 → 300+ 色），
   * 且已排除「抓到的是桌面」（直接抓 `Progman` 的直方图全黑，与此完全不同）。
   *
   * ⚠️ 仍未验证（必须解锁）：region 外是否**真的透出桌面**、内容是否清晰。
   *    PrintWindow 看不到 Flutter（ANGLE/D3D）层，所以它证明不了"观感"。
   *
   * ★ 教训：**写下"已证伪"时必须同时写清"在什么条件下证伪"** ——
   *    否则后人会当成"无条件不成立"，从而放弃一条可能有效的路。
   */
  kComposition,  ///< ★ 仅"清掉 region"的条件下才整窗透明。见上方更正。
  /*
   * ★★★ 任务㉗⑤ 新增（2026-09-25）—— `kComposition` 的"**保留 region**"版本
   *
   * # 为什么需要它（铁律 39：结论必须绑定条件）
   *
   * 上面 `kComposition` 曾被写成"已证伪：整窗透明"。**那句话漏了条件** ——
   * 它真正证伪的是「**清掉 region 时**整窗透明」，而不是「BLURBEHIND 本身」：
   * ```text
   * kComposition        : SWCA(BLURBEHIND) + SetWindowRgn(nullptr)  ⇒ 整窗透明
   * 对照实验（品红垫底）  : 只调 SWCA(BLURBEHIND)，**region 保留**
   *                        ⇒ 角上 #FF00FF（真透出背景）
   *                        + 内容色 356/484（**完好**）
   * ```
   * ⇒ 两个条件不同 ⇒ 两个结论都成立、并不矛盾。
   *   被"误杀"的正是「SWCA(BLURBEHIND) + region 保留」这条**可能的正解**。
   *
   * # 锁屏下可得的证据（`.probe/t27_blur_content.py`，全窗口 PrintWindow）
   *
   * ```text
   * GRADIENT(对照)        unique=1     corner=#eef0f6
   * TRANSPARENTGRADIENT   unique=1     corner=#000000
   * BLURBEHIND            unique=323   corner=#ffffff   ← ★ 只有它能看到内容
   * DISABLED              unique=1     corner=#000000
   * ```
   * 已排除"抓到的是桌面"：直接抓 `Progman` 的直方图全黑，与此完全不同。
   *
   * ⚠️ **仍未验证**（必须解锁）：
   *    · region 外是否**真的透出桌面**
   *    · 内容是否**清晰**（不是被模糊到不可用），尤其**视频播放中**
   * ⇒ 所以**不动默认值**（仍是 `kRegion`）。
   */
  kCompositionBlur,  ///< ★ SWCA(BLURBEHIND) + **保留 region**（待解锁验证）
};

/// `SetWindowCompositionAttribute` 的 accent 状态
///
/// 未公开 API，值来自社区逆向（`AccentPolicy`）。
enum AccentState {
  kAccentDisabled = 0,
  kAccentEnableGradient = 1,
  kAccentEnableTransparentGradient = 2,
  kAccentEnableBlurBehind = 3,          ///< ★ 实测真透明
  kAccentEnableAcrylicBlurBehind = 4,   ///< ★ 实测真透明
  kAccentInvalidState = 5,
};

/// `WCA_ACCENT_POLICY` —— `SetWindowCompositionAttribute` 的 attribute 编号
constexpr int kWcaAccentPolicy = 19;

/// `SetWindowCompositionAttribute` 的参数结构（未公开，手写）
struct AccentPolicy {
  int accent_state;
  int accent_flags;
  DWORD gradient_color;  ///< 0xAABBGGRR（**alpha 在高字节**）
  int animation_id;
};

struct WindowCompositionAttributeData {
  int attribute;
  void* data;
  SIZE_T size_of_data;
};

/// 默认方案 —— ★ `kRegion`（2026-09-25 任务㉑① 改）
///
/// # 为什么从 `kNone` 改成 `kRegion`
///
/// 用户原话：
/// > 现在阴影没了,但是**四个角多出来直角阴影**
///
/// `kNone` 下四角是**方的不透明块**（实测 `#eef0f6` = backdrop 色）
/// —— 那正是用户看到的"直角阴影"。`kRegion` 之后那四个角
/// **根本不属于窗口**，桌面直接透出来。
///
/// # ★ 更正一处**误读**（上一轮把结论理解反了）
///
/// 上面曾写着「`SetWindowRgn` ……原版已明确否决」。**那是误读。**
/// 原版 `src-tauri/src/rounded_window.rs` 的真实结论是：
/// ```text
/// 三条路都试过，只有第三条（SetWindowRgn）成立 —— 选的就是它。
/// 被否决的是【另外两条】（transparent / DwmExtendFrameIntoClientArea）。
/// 原版明确写：
///   「这是**当前方案固有**的代价，不是 bug。权衡过：
///     · 有台阶但**没有黑框/白底**（选了这个）
///     · 圆角平滑但**外面套着一圈底色**（实际观感更差，Owner 也否了）」
/// ```
/// 也就是说原版**接受**了硬边台阶，因为它比"外面套一圈底色"好。
/// 而"外面套一圈底色"正是我们现在 `kNone` 的状态（`#eef0f6` 方角）。
///
/// # 本机实测（A/B，`.probe/region_probe.py`，`GetWindowRgn` 为准）
///
/// ```text
/// mode=none    GetWindowRgn = ERROR（无区域）→ 四角像素【属于我们】
///              (0,0)/(1,1)/(1279,0)/(0,799)/(1279,799) 全在区域内
/// mode=region  GetWindowRgn = 有区域，包围盒 (0,0)-(1280,800)
///              (0,0)/(1,1)/(1279,0)/(0,799)/(1279,799) 【不在】区域内
///              WindowFromPoint(窗口左上角) -> 不是我们 → 桌面透出来了
/// ```
/// 关键：`client == window`（`nonclient=0x0`）之后，
/// `SetWindowRgn` 用窗口坐标就能精确覆盖客户区 —— 这条**现在才成立**
/// （原版在 Tauri 下客户区还有 8px 偏移，得额外换算）。
///
/// # 代价（如实记录，不粉饰）
///
/// ```text
/// SetWindowRgn 是二值裁剪，Win10 不给抗锯齿 → 凑近看四角有轻微台阶。
/// 这是 Win10 的固有限制，不是实现缺陷：
///   · Win10 无原生圆角 API（DWMWA_WINDOW_CORNER_PREFERENCE 需 Win11 22000+）
///   · Flutter 的 D3D11 swapchain 不提供 per-pixel alpha（已实测）
/// ⇒ 只能在「有台阶但透出桌面」与「圆角平滑但套一圈底色」之间选，
///   原版与用户都选了前者。
/// ```
constexpr AlphaMode kDefaultAlphaMode = AlphaMode::kRegion;

constexpr double kDefaultCornerRadius = 10.0;

AlphaMode g_alpha_mode = kDefaultAlphaMode;
double g_corner_radius = kDefaultCornerRadius;
bool g_alpha_config_resolved = false;

/*
 * ═══════════════════════════════════════════════════════════════════════
 *  ★★★ region 缓存 —— "上次设过的圆角区域尺寸"（修「放大缩小非常卡顿」）
 * ═══════════════════════════════════════════════════════════════════════
 *
 * # 为什么需要它
 *
 * `ApplyRoundedRegion()` 从 `WM_WINDOWPOSCHANGED` 进来，而那条消息
 * **拖动和缩放都会触发**。于是**纯拖动**（位置变、尺寸没变）也会赔上：
 * ```text
 * ① GetWindowRect   ② GetWindowScale
 * ③ CreateRoundRectRgn    ④ ★ SetWindowRgn(..., TRUE)
 * ```
 * ★ 第 ④ 步第 3 个参数是 **TRUE = 整个窗口失效并重绘**（系统级操作）
 *   ⇒ 拖动时每帧做一次 ⇒ 用户报的**卡顿**。
 *
 * # 为什么可以缓存
 *
 * `CreateRoundRectRgn(0, 0, w + 1, h + 1, ...)` 的坐标是**窗口坐标**
 * （永远从 (0,0) 起）⇒ region 只依赖 **(尺寸, 半径)**，
 * **与窗口在屏幕上的位置无关** ⇒ 纯拖动不需要重建 ✓
 *
 * # ⚠️ 放在文件作用域（而不是函数内静态）的理由
 *
 * 有**多条路径**会把 region 清掉或改掉，任何一条之后缓存都必须失效：
 * ```text
 * · ApplyRoundedRegion() 的全屏分支 —— 清 region
 * · case kComposition              —— L1480 清 region（走另一条路，不经过本函数）
 * ```
 * 若缓存藏在 `ApplyRoundedRegion()` 里，`kComposition` 那条路就**碰不到**它
 * ⇒ 从 `kComposition` 切回 `kRegion` 时，若尺寸恰好与上次相同，
 *   缓存会误判"region 已经设好了" ⇒ **圆角永久丢失**。
 * 放文件作用域 + 一个显式的 `InvalidateRegionCache()`，所有路径都能清。
 */
LONG g_region_cache_w = -1;
LONG g_region_cache_h = -1;
int g_region_cache_diameter = -1;

/// 让 region 缓存失效 —— **任何**改动/清除窗口 region 的路径都必须调用
void InvalidateRegionCache() {
  g_region_cache_w = -1;
  g_region_cache_h = -1;
  g_region_cache_diameter = -1;
}

/*
 * ═══════════════════════════════════════════════════════════════════════
 *  ★★ 真正的根因：非客户区（实测抓到）
 * ═══════════════════════════════════════════════════════════════════════
 *
 * 光把客户区设透明**修不好四角**，因为四角根本不全是客户区。
 *
 * 实测（`GWL_STYLE` + `GetWindowRect`/`GetClientRect` 对比）：
 * ```text
 * GWL_STYLE   = 0x14CF0000  → WS_CAPTION=True  WS_THICKFRAME=True
 * WINDOW      1280x800
 * CLIENT      1264x792      ← 少了 16 x 8
 * ★ 非客户区   16 x 8        ← 左8 右8 下8
 * ```
 * `window_manager` 的 `TitleBarStyle.hidden` 只去掉**标题栏高度**
 * （39 → 8），**没有**去掉 `WS_THICKFRAME` 那条 8px 边框。
 * 那圈边框由 **DWM 画**，是不透明的，而且是**方的** ——
 * Dart 侧的 `ClipRRect` 只能裁到客户区，管不到它。
 * 所以用户看到的是"圆角内容 + 外面一圈方框"。
 * 深色主题下 DWM 把这圈画成近黑 → 就是用户报的"四个角是黑色"。
 *
 * # 修法：`WM_NCCALCSIZE` 返回 0（客户区 = 整个窗口）
 *
 * 这是 Electron `frame:false`、Chromium、Qt 无边框窗口用的同一条路：
 * 保留 `WS_THICKFRAME`（这样**缩放和贴靠还在**），但让非客户区
 * 尺寸为 0 —— 窗口矩形 == 客户区矩形，那圈方框就不存在了。
 * 剩下的可见边缘就只有 Flutter 自己画的抗锯齿圆角。
 *
 * # 为什么不用"把边框也变透明"
 *
 * 试过 `DwmExtendFrameIntoClientArea(-1)`（`blurframe` 模式）——
 * 那会把**整个窗口**变成玻璃，Flutter 的不透明内容会被 DWM 的
 * 玻璃合成影响，颜色会整体发灰。而且方形的边框区域即使透明，
 * 形状仍是方的（只是看不见而已），遇到不透明内容就露馅。
 *
 * # 代价（如实记录）
 *
 * ```text
 * 丢失  DWM 自带的窗口投影（本来就是圆角窗口，投影是方的更难看；
 *       原版 Tauri 也是 shadow:false 主动关掉的）
 * 保留  缩放（靠下面 WM_NCHITTEST 自己实现，见那段注释）
 * 保留  最大化 / 最小化 / 关闭（自绘标题栏本来就有按钮）
 * ```
 *
 * # ⚠️ 为什么默认**关**（`g_frameless = false`）
 *
 * 实测（`DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`）：
 * ```text
 * 无边框化 关  可见非客户区 = 左1 上0 右1 下1    style=0x14CF0000 CAPTION=True
 * 无边框化 开  可见非客户区 = 左2 上0 右2 下2    style=0x140F0000 CAPTION=False
 * ```
 * 也就是说：**去掉 `WS_CAPTION` 并没有减小可见边框**（那"16x8"里
 * 绝大部分是 Win10 的**隐形**缩放边框，本来就不显示）。
 * 而开启它会带来真实代价（自实现的缩放热区、最大化特判、全屏交互）。
 * **零收益 + 有风险 ⇒ 默认关闭**，代码保留供将来复测。
 */
bool g_frameless = false;
bool g_frameless_resolved = false;

/// 是否**同时**去掉 `WS_THICKFRAME`（对照实验，默认关）
///
/// 见 `ResolveFramelessConfig` 里的说明。
bool g_drop_thickframe = false;

/*
 * ═══════════════════════════════════════════════════════════════════════
 *  ★★★ 消除 DWM 窗口阴影 —— 用户报的「背景一圈阴影」的真正根因
 * ═══════════════════════════════════════════════════════════════════════
 *
 * # 用户原话
 *
 * > 这个背景怎么有一圈阴影?
 *
 * # 现象（像素证据）
 *
 * `.probe/USER-02-home.png`（1280x800，用户真实数据跑的实例）在 `y=400`
 * 横向扫描，窗口最外 7 像素是一条**向外变暗**的渐变：
 * ```text
 * x=0  #e0e2e8   ← 最外
 * x=1  #dfe1e6
 * x=2  #dcdee4
 * x=3  #d8dae0
 * x=4  #d4d6db
 * x=5  #ced0d5
 * x=6  #c7c8cd   ← 最暗（紧贴内容）
 * x=7  #eef0f6   ← 窗口自己的边（LightTokens.bgBase）
 * x=8  #ffffff   ← 内容
 * ```
 * 上边**没有**这条渐变（`y=0` 只有 1px 过渡），下边有（7px）。
 *
 * # 怎么证明它是 DWM 画的（不是 Flutter）
 *
 * ```text
 * ① DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS=9) 实测：
 *      GetWindowRect        = 1280x800
 *      ExtFrameBounds       = 1266x793
 *      ★ DWM 边距            L=7  T=0  R=7  B=7
 *    → 那 7px 与「DWM 边距」**逐边一一对应**：
 *      左右下各有 7px，上边 0px（所以上边没有渐变）。
 *
 * ② 把窗口矩形**向外**扩 36px 抓图（`.probe/wide_scan.py`），
 *    阴影**继续延伸到窗口矩形之外**并向外衰减：
 *      outside -6  #fefefe(254)
 *      outside -3  #fbfbfb(251)
 *      outside -1  #f8f8f8(248)
 *      EDGE        #e6e8ee(232)   ← 窗口矩形边界
 *    「从可见边缘向外衰减」= 投影（drop shadow）的定义。
 *    应用自己画的东西**不可能**画到窗口矩形之外。
 *
 * ③ 逐条排除其它可能（都在**同一台机器、同一内容**下实测）：
 *      DwmSetWindowAttribute(DWMWA_NCRENDERING_POLICY=DISABLED)  → 无变化
 *      DwmExtendFrameIntoClientArea({0,0,0,0})                   → 无变化
 *      WS_EX_LAYERED + LWA_ALPHA                                 → 无变化
 *      SetWindowRgn 内缩 7px                                      → 无变化
 *      DwmEnableBlurBehindWindow（既有 4 条路）                   → 无变化
 *    ⚠️ 这些**运行期**改动都改不动它 —— 说明 DWM 的框架/阴影是
 *       **窗口创建时**就定下来的，之后再 `SWP_FRAMECHANGED` 也不会重算。
 * ```
 *
 * # 修法：在**创建时**就去掉 `WS_THICKFRAME`
 *
 * 实测（`SOURIN_WIN_FRAMELESS=1 SOURIN_WIN_DROP_THICKFRAME=1`，即
 * 「创建早期就去掉 `WS_THICKFRAME`」）：
 * ```text
 *                    DWM 边距              窗口最外 7px
 * 保留 THICKFRAME      L=7 T=0 R=7 B=7      #e0e2e8→#c7c8cd（有阴影）
 * 去掉 THICKFRAME      L=0 T=0 R=0 B=0      #ffffff x16（★ 完全消失）
 * ```
 * 去掉之后 `ExtFrameBounds` 与 `GetWindowRect` **完全重合**
 * （都是 1280x800）→ DWM 不再为这个窗口保留边框、也就不再投影。
 *
 * # 代价（如实记录）
 *
 * ```text
 * 丢失  DWM 原生窗口投影（这**正是**用户要的）
 * 丢失  Aero Snap（拖到屏幕边缘自动半屏）—— `WS_THICKFRAME` 是它的来源
 * 丢失  系统边框拖拽缩放 —— 由下面 `WM_NCHITTEST` 自实现的热区接管
 * 保留  `WS_CAPTION`（原生标题栏 + 最小化/最大化/关闭按钮照旧）
 * 保留  最大化 / 最小化 / 关闭
 * ```
 * ⚠️ 这是「去掉投影」与「保留 Snap」之间的**二选一**：实测
 *    `WS_THICKFRAME` 一在，DWM 就一定投影。用户明确报的是阴影，
 *    所以这里选**去掉投影**。
 *
 * # 环境变量开关（用于复测，不设则用默认值）
 *
 * ```text
 * SOURIN_WIN_NOSHADOW=0   关闭本修复（回到有阴影的状态，仅用于对照）
 * 不设 / =1               ★ 默认：消除阴影
 * ```
 */
bool g_no_shadow = true;
bool g_no_shadow_resolved = false;

/// 非客户区宽度（逻辑像素）—— 用于自己做缩放热区
constexpr int kResizeBorderDip = 6;

void ResolveFramelessConfig() {
  if (g_frameless_resolved) {
    return;
  }
  g_frameless_resolved = true;
  char buf[16] = {0};
  DWORD n = ::GetEnvironmentVariableA("SOURIN_WIN_FRAMELESS", buf, sizeof(buf));
  if (n > 0 && n < sizeof(buf)) {
    g_frameless = (buf[0] != '0');
  }

  /*
   * ★ 是否**同时**去掉 `WS_THICKFRAME`（对照实验用）
   *
   * # 为什么要做成开关
   *
   * 实测：去掉 `WS_CAPTION` + `WM_NCCALCSIZE` 返回 0 之后，
   * 非客户区**仍然**是 16x8（`caption=0 thickframe=1`：
   * `.probe/aa-fl4/out.txt` 的 self-heal 连续 15 次都是 16x8）。
   * 说明 `WS_THICKFRAME` 本身就足以让系统保留一圈非客户区。
   *
   * 但直接去掉它会丢掉 Aero Snap（拖到屏幕边缘自动半屏）。
   * 所以先做成开关**实测**两种取向，再决定默认值 —— 不拍脑袋。
   *
   * ```text
   * SOURIN_WIN_DROP_THICKFRAME=1  去掉（四角应能真透明，代价是丢 Snap）
   * 不设 / =0                      保留（保 Snap，四角可能仍有黑框）
   * ```
   */
  char tbuf[16] = {0};
  DWORD tn = ::GetEnvironmentVariableA("SOURIN_WIN_DROP_THICKFRAME", tbuf,
                                       sizeof(tbuf));
  if (tn > 0 && tn < sizeof(tbuf)) {
    g_drop_thickframe = (tbuf[0] != '0');
  }

  /*
   * ★ 消除 DWM 窗口阴影（见 `g_no_shadow` 上方那段长注释）
   *
   * 只在显式设成 '0' 时关闭 —— 不设就是**默认开启**（用户报的是阴影）。
   */
  char sbuf[16] = {0};
  DWORD sn = ::GetEnvironmentVariableA("SOURIN_WIN_NOSHADOW", sbuf,
                                       sizeof(sbuf));
  if (sn > 0 && sn < sizeof(sbuf)) {
    g_no_shadow = (sbuf[0] != '0');
  }

  /*
   * ═══════════════════════════════════════════════════════════════════
   * ★★★ 去投影 = 复用「无边框化 + 去掉 THICKFRAME」这条**已验证**的路
   * ═══════════════════════════════════════════════════════════════════
   *
   * # 为什么不是在 CreateWindow 时改样式位（我第一版就是这么写的，**失败**）
   *
   * 第一版把 `WS_CAPTION|WS_BORDER|WS_THICKFRAME` 从传给 `CreateWindow`
   * 的样式里掩掉。实测日志（`.probe/run-shadow/out.txt`）：
   * ```text
   * [NOSHADOW] style=0x04CB0000 window=1280x720 efb=1280x720 dwmMargin 0,0,0,0
   * ```
   * 创建那一刻看着是对的（`dwmMargin` 全 0）—— **但那是假象**：
   * ```text
   * 运行中再查同一个窗口：
   * GWL_STYLE = 0x14CB0000   CAPTION=1  ← ★ CAPTION 又回来了
   * DWM margin L=7 T=0 R=7 B=7           ← 阴影照旧
   * ```
   * 也就是说 **`CreateWindow` 内部会把 `WS_CAPTION` 加回来**
   *（窗口带 `WS_SYSMENU`/`WS_MINIMIZEBOX`/`WS_MAXIMIZEBOX` 时系统会补
   * 上装饰位）。所以"在创建时掩样式位"这条路**根本走不通**。
   *
   * # 正确的路（本文件里早就有，且已实测有效）
   *
   * `ApplyFramelessStyle()` 是**创建之后**再扒样式位，并紧跟一次
   * `SetWindowPos(SWP_FRAMECHANGED)` 强制系统重算框架 —— 实测
   *（`.probe/CTL-nothick-after.png`）：
   * ```text
   * style=0x140B0000  CAPTION=0 BORDER=0 THICKFRAME=0
   * efb=1280x800 == GetWindowRect  →  dwmMargin L=0 T=0 R=0 B=0
   * 窗口最外 16 像素： #ffffff x16（★ 阴影完全消失）
   * ```
   * 所以这里**不去另造一套**，而是让 `g_no_shadow` 直接复用
   * `g_frameless` + `g_drop_thickframe` 这套已验证的机制：
   * ```text
   * g_frameless = true        → ApplyFramelessStyle 扒掉 CAPTION/BORDER/DLGFRAME
   *                             + WM_NCCALCSIZE 归零 + 自愈定时器
   * g_drop_thickframe = true  → 连 WS_THICKFRAME 一起去掉（投影的必要条件）
   * ```
   * ⚠️ 代价（与 `g_frameless` 相同）：失去 Aero Snap；
   *    缩放由 `WM_NCHITTEST` 自实现的热区接管（见那段注释）。
   *    UI 上**没有**损失：`shell.dart` 本来就用 `TitleBarStyle.hidden`
   *    + 自绘标题栏，原生标题栏的像素是 Flutter 自己画的。
   *
   * # 两个开关的关系（都可独立复测）
   *
   * ```text
   * SOURIN_WIN_NOSHADOW=0    关掉去投影（回到有阴影，仅用于对照）
   * SOURIN_WIN_FRAMELESS=0   关掉无边框化本身
   * ★ 只要 g_no_shadow 为真，就强制走无边框化 + 去 THICKFRAME ——
   *   因为「保留 CAPTION/THICKFRAME」与「没有投影」在 Win10 上
   *   实测**不可兼得**（两者同时存在时 dwmMargin 必然 L=7 R=7 B=7）。
   * ```
   */
  /*
   * =======================================================================
   * 2026-10-05: 不再强制 g_drop_thickframe = true
   *   -- Owner 报「鼠标移到窗口边缘没有缩放光标、拖不动大小」的修复
   * =======================================================================
   *
   * # 为什么要拆掉这一行
   *
   * 去 THICKFRAME 是为了消掉 DWM 那圈边框，但它顺带把系统缩放能力一起删了。
   * 实测两条独立根因，缺一不可：
   *   ① 子窗口 FLUTTERVIEW 被刻意铺满整个窗口矩形（见 WM_SIZE /
   *      SetChildContent），真实鼠标命中永远落在子窗口上，父窗口的
   *      WM_NCHITTEST 热区根本不会被问到；
   *      => 由 MaybeSubclassChild() 的子窗口子类化解决（边缘带返回 HTTRANSPARENT）
   *   ② 没有 WS_THICKFRAME 时，DefWindowProc 收到 WM_NCLBUTTONDOWN(HTLEFT)
   *      会直接返回，不进入缩放模态循环 -- 实测 SENDRET 0 / DELTA 0 0
   *      （SC_SIZE 要求窗口有 sizing border；SC_MOVE 不要求，
   *        所以标题栏拖动一直是好的，只有"拖边改大小"坏了）
   *      => 必须把 WS_THICKFRAME 还回来
   *
   * # 代价与验证要求
   *
   * WS_THICKFRAME 一在，DWM 就可能重新保留一圈边框（dwmMargin 非 0）。
   * 这一条必须实测，不能拍脑袋：
   *   复测 SOURIN_WIN_DROP_THICKFRAME=1    -> 回到旧行为（无系统缩放）
   *   复测 SOURIN_WIN_NCRENDERING=disabled -> 试 DwmSetWindowAttribute 关 NC 渲染
   * 若截图确认出现可见暗边，就走 SOURIN_WIN_NCRENDERING=disabled 那条路。
   */
  if (g_no_shadow) {
    g_frameless = true;
    // 2026-10-05 起不再强制：保留 WS_THICKFRAME，缩放交给系统模态循环
    // （旧写法：g_drop_thickframe = true;  <- 已移除，见上方长注释）
  }
}

/// 从环境变量解析方案名（只做一次）
void ResolveAlphaConfig() {
  if (g_alpha_config_resolved) {
    return;
  }
  g_alpha_config_resolved = true;

  char buf[64] = {0};
  DWORD n = ::GetEnvironmentVariableA("SOURIN_WIN_ALPHA", buf, sizeof(buf));
  if (n > 0 && n < sizeof(buf)) {
    const std::string mode(buf);
    if (mode == "none") {
      g_alpha_mode = AlphaMode::kNone;
    } else if (mode == "blur") {
      g_alpha_mode = AlphaMode::kBlur;
    } else if (mode == "blurframe") {
      g_alpha_mode = AlphaMode::kBlurFrame;
    } else if (mode == "region") {
      g_alpha_mode = AlphaMode::kRegion;
    } else if (mode == "colorkey") {
      g_alpha_mode = AlphaMode::kColorKey;
    } else if (mode == "composition") {
      // ★ 任务㉗⑤：真透明（SetWindowCompositionAttribute），实测有效
      g_alpha_mode = AlphaMode::kComposition;
    } else if (mode == "compositionblur") {
      // ★ 任务㉗⑤：SWCA(BLURBEHIND) + **保留 region**（待解锁验证的正解候选）
      g_alpha_mode = AlphaMode::kCompositionBlur;
    }
  }

  char rbuf[32] = {0};
  DWORD rn =
      ::GetEnvironmentVariableA("SOURIN_WIN_ALPHA_RADIUS", rbuf, sizeof(rbuf));
  if (rn > 0 && rn < sizeof(rbuf)) {
    const double parsed = atof(rbuf);
    // 半径 0 等于没圆角；上限防止误配把整窗裁没
    if (parsed > 0.0 && parsed <= 200.0) {
      g_corner_radius = parsed;
    }
  }
}

/// 取窗口当前 DPI 缩放（区域坐标是物理像素，半径是逻辑像素）
double GetWindowScale(HWND window) {
  // GetDpiForWindow 需要 Win10 1607+（本机 19045，可用）
  using GetDpiForWindowFn = UINT(WINAPI*)(HWND);
  HMODULE user32 = ::GetModuleHandleA("user32.dll");
  if (user32 != nullptr) {
    auto fn = reinterpret_cast<GetDpiForWindowFn>(
        ::GetProcAddress(user32, "GetDpiForWindow"));
    if (fn != nullptr) {
      const UINT dpi = fn(window);
      if (dpi > 0) {
        return dpi / 96.0;
      }
    }
  }
  return 1.0;
}

/*
 * ★★ 无边框化：去掉 `WS_CAPTION`，**保留** `WS_THICKFRAME`
 *
 * # 为什么"只让 WM_NCCALCSIZE 返回 0"不够（实测）
 *
 * 第一版只加了 `WM_NCCALCSIZE` 返回 0，并加了诊断打印。实测：
 * ```text
 * [ALPHA] NCCALCSIZE#2 wp=1 frameless=1 placed=1 showCmd=1
 * ```
 * 消息**确实**到了、`wParam=TRUE`（正是该返回 0 的情形）——
 * 但 `GetWindowRect - GetClientRect` 仍然是 **16x8**。
 *
 * 原因：`GWL_STYLE = 0x14CF0000` 里 **`WS_CAPTION` 还在**。
 * 有 `WS_CAPTION` 时系统会为标题栏/边框保留空间，且
 * `window_manager` 之后又调 `SetWindowPos(SWP_FRAMECHANGED)`
 * 触发重算，把我们的归零结果覆盖掉了。
 *
 * # 正确的组合（Electron / Chromium / Qt 无边框窗口的通行做法）
 *
 * ```text
 * 去掉  WS_CAPTION      (0x00C00000)  ← 标题栏 + 边框的"装饰"来源
 * 保留  WS_THICKFRAME   (0x00040000)  ← 可缩放 + Aero Snap
 * 保留  WS_MINIMIZEBOX / WS_MAXIMIZEBOX / WS_SYSMENU  ← 自绘按钮要用
 * 配合  WM_NCCALCSIZE 返回 0
 * ```
 * 只去掉 `WS_CAPTION` 而保留 `WS_THICKFRAME` 的关键点：
 * **`WS_CAPTION` 才是"要画非客户区"的开关**；
 * `WS_THICKFRAME` 单独存在时只提供缩放热区，不强制画边框。
 *
 * # ⚠️ 为什么必须**每次都强制重算**（第一轮踩的坑，实测日志）
 *
 * 第一版有个"优化"：样式位已经对了就早退（不调 `SetWindowPos`）。
 * 实测打脸 —— 诊断日志（`.probe/aa-fl1/out.txt`）：
 * ```text
 * #1  window=1280x720 client=1280x720 nonclient=0x0  changed=1  ← 对了
 * #2  window=1280x720 client=1280x720 nonclient=0x0  changed=0  ← 还对
 * #3  window=1280x720 client=1280x720 nonclient=0x0  changed=0  ← 还对
 * #4  window=1280x720 client=1264x712 nonclient=16x8 changed=0  ← ★ 又回来了
 * #6  window=1280x800 client=1264x792 nonclient=16x8 changed=0  ← 一直错
 * ```
 * 中间 `caption=0 thickframe=1` **一直是对的**，但非客户区在 `#4`
 * 突然变回 16x8 —— 因为 `window_manager`（`SetTitleBarStyle` /
 * 进出全屏 / `SetResizable`）会自己 `SetWindowPos(SWP_FRAMECHANGED)`，
 * 让系统**重新计算**一次非客户区。那次重算不一定走到我们的归零分支
 *（`wParam` / 窗口状态都可能不同），于是 16x8 就回来了。
 * 而早退让代码**不会**再补一次强制重算 → 错误状态被固化。
 *
 * 结论：**不能靠"样式位没变就跳过"** —— 必须每次被叫到都
 * 重新强制一次框架重算，把 `WM_NCCALCSIZE → 0` 的结果重新建立起来。
 * 本函数因此设计成**无条件幂等**。
 *
 * # ⚠️ 关于递归
 *
 * `SetWindowPos(SWP_FRAMECHANGED)` 会触发 `WM_WINDOWPOSCHANGED`，
 * 而我们在那条消息里又调 `ApplyWindowAlpha` → 可能无限递归。
 * 由 `ApplyWindowAlpha` 里的 `g_applying` 重入标志挡住
 *（本函数总是从那里调用）。
 *
 * @return 是否真的改动了样式位（仅用于诊断）
 */
bool ApplyFramelessStyle(HWND window) {
  ResolveFramelessConfig();
  /*
   * ★ 这里**只**跟 `g_frameless` 走，不跟 `g_no_shadow`
   *
   * 本函数是"运行期把样式位再扒一遍"的补刀。`g_no_shadow` 已经在
   * `Create` 里**创建时**就把 `WS_CAPTION|WS_BORDER|WS_THICKFRAME`
   * 去掉了（那是唯一有效的时机，实测运行期改不动 DWM 投影），
   * 所以这里不需要、也不应该再动样式位 —— 让它保持纯粹。
   */
  if (!g_frameless) {
    return false;
  }

  LONG_PTR style = ::GetWindowLongPtr(window, GWL_STYLE);
  bool changed = false;

  /*
   * 去掉 `WS_CAPTION`、`WS_BORDER` 这些"要画装饰"的样式。
   *
   * ⚠️ `WS_BORDER` 也要去：它是 1px 的细边框，同样会占非客户区。
   */
  const LONG_PTR kDecorationMask =
      WS_CAPTION | WS_BORDER | WS_DLGFRAME;
  if ((style & kDecorationMask) != 0) {
    style &= ~kDecorationMask;
    changed = true;
  }

  /*
   * ⚠️ 这里**不要**去动 `WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX`。
   *
   * # 为什么留这条警告（我踩过，别再踩）
   *
   * 我曾根据 "style=0x140B0000 里还有 WS_SYSMENU" 推断
   * "这三个位让系统合成了一圈标题栏边框，所以 client 才小 16x8"，
   * 于是把它们也扒掉、还额外补了个 `WM_SYSCOMMAND` 给 `Alt+F4` 兜底。
   *
   * **那个推断是错的。** 真实根因是 `window_manager` 插件在
   * `WM_NCCALCSIZE` 里**故意**把 `rgrc[0]` 收缩了 8px
   * （`window_manager_plugin.cpp:170-179`，`TitleBarStyle.hidden` 分支）。
   * 修好 `WndProc` 的抢占之后，实测 `client == window` 达成，
   * 而 `WS_SYSMENU` 一直在那儿 —— 它跟那 16x8 **毫无关系**：
   * 扒掉它只带来代价（丢系统菜单、`Alt+F4` 需要兜底、多一处行为改动），
   * 没有任何收益。所以**回滚**。
   *
   * 教训：`dwmMargin=0,0,0,0` 已经证明 DWM 不认边框了 ——
   * 那时就该知道"还有个不在 DWM 里的东西在收缩客户区"，
   * 而不是继续在样式位里猜。
   */

  /*
   * ⚠️ 上面那段（去掉 WS_SYSMENU 等）**不是** 16x8 的根因 ——
   *    真正的根因在 `WndProc` 里的 `WM_NCCALCSIZE` 抢占，见那里。
   *    这里保留是因为它顺带避免系统再合成标题栏，
   *    且 `WM_SYSCOMMAND` 已为 `Alt+F4` 兜底。
   */

  /*
   * ★ 对照开关：是否连 `WS_THICKFRAME` 一起去掉
   *
   * 实测（`.probe/aa-fl4`）：只去 `WS_CAPTION` 时非客户区**仍** 16x8，
   * 说明 `WS_THICKFRAME` 单独也能撑出非客户区。
   * 默认**保留**它（保住 Aero Snap），用开关实测另一取向。
   */
  if (g_drop_thickframe && (style & WS_THICKFRAME) != 0) {
    style &= ~static_cast<LONG_PTR>(WS_THICKFRAME);
    changed = true;
  }

  if (changed) {
    ::SetWindowLongPtr(window, GWL_STYLE, style);
  }

  /*
   * ⚠️ 这里**不要**去动扩展样式里的 `WS_EX_WINDOWEDGE / WS_EX_CLIENTEDGE /
   *    WS_EX_STATICEDGE`。（我加过，已回滚 —— 记下来别再走这条弯路。）
   *
   * # 为什么当时以为要去掉
   *
   * 曾观察到 `GWL_EXSTYLE = 0x00000100`（`WS_EX_WINDOWEDGE`），
   * 而 `client` 仍比 `window` 小 16x8，就推断"是它在撑那圈非客户区"。
   *
   * # 为什么那个推断是错的
   *
   * 真正的原因是 `window_manager` 插件在 `WM_NCCALCSIZE` 里
   * **主动改写 `rgrc[0]`**（`window_manager_plugin.cpp:170-179`）。
   * 修好 `WndProc` 的抢占后，`client == window` 达成，而
   * `GWL_EXSTYLE` 依然是 `0x00000100` —— 它跟那 16x8 **毫无关系**。
   *
   * 盲改扩展样式会带来真实副作用（改变窗口边缘的绘制/命中行为），
   * 却换不来任何收益。**判据只有一个：`client == window`。**
   */

  /*
   * ★ 无条件强制框架重算（即便样式位没变）
   *
   * `SWP_FRAMECHANGED` 会让系统重新发 `WM_NCCALCSIZE`。
   *
   * ⚠️ 注意这里的语义比我原先写的更微妙：**我们的 handler 并不是**
   *    "非客户区归零"的唯一执行者 —— `window_manager` 插件的
   *    top-level proc delegate 会**先**拿到 `WM_NCCALCSIZE` 并 `return 0`，
   *    从而把这条消息整个吞掉（详见 `WndProc` 里抢占那段的长注释）。
   *    所以真正让 `client == window` 成立的是 **`WndProc` 的抢占**；
   *    这里保留 `SWP_FRAMECHANGED` 是为了让样式位改动尽快生效。
   *
   * `SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE`：
   * 只重算框架，不动位置/尺寸/Z 序/焦点。
   */
  ::SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_FRAMECHANGED);
  return changed;
}

/*
 * ═══════════════════════════════════════════════════════════════════════
 *  ★★ 自愈定时器 —— 保留但**默认不启用**（`g_frameless` 默认 false）
 * ═══════════════════════════════════════════════════════════════════════
 *
 * 这是无边框化（`SOURIN_WIN_FRAMELESS=1`）实验路径的一部分，
 * 记录的是"为什么不能只在一处修"这个真实踩坑过程。
 *
 * 实测日志（`.probe/aa-fl3/out.txt`，`WM_NCCALCSIZE` 与窗口度量交替）：
 * ```text
 * NCCALCSIZE#3 wp=1
 * #3  window=1280x720 client=1280x720 nonclient=0x0   ← 归零成功
 * #4  window=1280x720 client=1264x712 nonclient=16x8  ← ★ 变回来了
 *      ↑ 这中间**没有任何 NCCALCSIZE 消息**
 * ```
 * 关键点：**没有重算消息，非客户区却变了**。说明
 * `window_manager` 在它自己的一次 `SetWindowPos` 里，
 * 用**缓存下来的 NC 度量**重新算了客户区尺寸，把我们的归零结果覆盖了。
 * 我们那次"当场修正"发生在这个调用栈**内部**，
 * 所以修正结果紧接着又被它后续的动作冲掉。
 *
 * # 解法：错开一个消息周期再校正
 *
 * 用 `SetTimer` 在一个**新的消息周期**里做同样的强制重算 ——
 * 那时 `window_manager` 的调用栈已经退干净，没人会再覆盖我们。
 *
 * # 为什么是"有界自愈"而不是"每 100ms 一直修"
 *
 * ```text
 * ① 一直跑会白白唤醒 CPU（这是播放器，功耗/占用有硬指标）
 * ② 真正需要修的只有"启动 + window_manager 设置样式"那几秒
 * ```
 * 所以只在前 [kSelfHealTicks] 个 tick 里校正，之后自动 `KillTimer`。
 * 每次校正都会检查"是否已经是 0x0"，是则不产生额外 DWM 调用。
 */
constexpr UINT_PTR kSelfHealTimerId = 0xAA01;
/// 校正次数（每次 120ms，共约 1.8 秒 —— 覆盖 window_manager 的设置窗口）
constexpr int kSelfHealTicks = 15;
constexpr UINT kSelfHealIntervalMs = 120;

int g_self_heal_tick = 0;

/// 若发现 DWM 边框（= 投影）又回来了，就重新扒样式位 + 强制重算
void SelfHealClientArea(HWND window) {
  ResolveFramelessConfig();
  /*
   * ★ `g_no_shadow` 也要自愈
   *
   * `window_manager` 的 `SetTitleBarStyle(hidden)` / `SetResizable` /
   * `SetAsFrameless` 会自己 `SetWindowPos(SWP_FRAMECHANGED)`，并可能
   * **重新写 `GWL_STYLE`** —— 实测（`.probe/run-user/out.txt`）：
   * ```text
   * [ALPHA] #1 ... nonclient=0x0     ← 归零成功
   * [ALPHA] #4 ... nonclient=16x8 caption=1   ← ★ 又回来了
   * ```
   * `caption` 一回来，DWM 就重新为窗口保留一圈边框 → **投影也跟着回来**。
   * 所以这条自愈对去投影是**必需**的。
   */
  if (!g_frameless && !g_no_shadow) {
    return;
  }

  /*
   * ★★★ 两个判据**都要查** —— 这是本轮（任务⑰④）修正的关键
   *
   * ```text
   * 判据 A：DWM 边距 != 0        → 有投影（阴影）
   * 判据 B：非客户区 != 0x0       → Flutter 表面盖不满窗口
   *                                 → 露出的那圈 = 用户说的「背景色块」
   * ```
   *
   * # 为什么必须两个都查（我上一轮只查了 A，于是 ④ 没修好）
   *
   * 上一轮我把判据改成"只看 DWM 边距"，理由是实测发现
   * "非客户区 16x8 但不产生投影"。**那半句是对的，但结论下错了**：
   * ```text
   * style=0x140B0000 window=1280x800 client=1264x792  nonclient=16x8
   * dwmMargin L=0 T=0 R=7 B=7  → 投影确实没了 ✓
   * 但 Flutter 画面只有 1264x792，窗口是 1280x800
   *   → 左边 8px 右边 8px 下面 8px **没有画面覆盖**
   *   → 那圈露出的是**窗口背景色**（WindowFrame 推的 backdrop）
   *   → 用户看到「背景还是有色块,左右跟下面」★ 逐边完全对上
   * ```
   * 实测（`.probe/c4.ps1` 枚举子窗口）：
   * ```text
   * child class='F'  1264x792     ← Flutter 表面
   * top-level        1280x800     ← 窗口
   * 差额            16x8          ← 左8 右8 下8 上0
   * ```
   *
   * # 两个判据分别对应两个不同的用户可见症状
   *
   * ```text
   * A 不满足 → 窗口【外】一圈投影       （任务②⑪ 的"阴影"）
   * B 不满足 → 窗口【内】一圈色块       （任务⑰ 的"色块"）
   * ```
   * 两者独立，所以**不能只用其中一个当"已经修好"的判据**。
   */
  RECT wr = {};
  RECT efb = {};
  ::GetWindowRect(window, &wr);
  ::DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &efb,
                          sizeof(efb));
  const long ml = efb.left - wr.left;
  const long mt = efb.top - wr.top;
  const long mr = wr.right - efb.right;
  const long mb = wr.bottom - efb.bottom;

  RECT cr = {};
  ::GetClientRect(window, &cr);
  const long nc_w = (wr.right - wr.left) - cr.right;
  const long nc_h = (wr.bottom - wr.top) - cr.bottom;

  const bool margin_ok = (ml == 0 && mt == 0 && mr == 0 && mb == 0);
  const bool client_ok = (nc_w == 0 && nc_h == 0);

  if (margin_ok && client_ok) {
    return;  // 两条都正确，不做任何多余调用（省 CPU —— 这是播放器）
  }

  /*
   * ① 先把装饰样式位**再扒一遍**
   *
   * `window_manager` 可能刚把 `WS_CAPTION`/`WS_BORDER` 写回来，
   * 只调 `SetWindowPos` 是没用的 —— 必须先把样式位纠正，
   * 否则系统会按新样式重新把 DWM 边框/投影建起来。
   */
  ApplyFramelessStyle(window);

  /*
   * ② 再 `SWP_FRAMECHANGED`：重发 `WM_NCCALCSIZE`，我们返回 0 → 归零。
   *    这次是在 window_manager 的调用栈**之外**，所以不会立刻被覆盖。
   */
  ::SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_FRAMECHANGED);

  ::GetWindowRect(window, &wr);
  ::DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &efb,
                          sizeof(efb));
  {
    RECT cr2 = {};
    ::GetClientRect(window, &cr2);
    const long ml2 = efb.left - wr.left;
    const long mt2 = efb.top - wr.top;
    const long mr2 = wr.right - efb.right;
    const long mb2 = wr.bottom - efb.bottom;
    const long nw2 = (wr.right - wr.left) - cr2.right;
    const long nh2 = (wr.bottom - wr.top) - cr2.bottom;
    const bool m_ok = (ml2 == 0 && mt2 == 0 && mr2 == 0 && mb2 == 0);
    const bool c_ok = (nw2 == 0 && nh2 == 0);
    ::printf("[ALPHA] self-heal tick=%d dwmMargin L=%ld T=%ld R=%ld B=%ld "
             "nonclient=%ldx%ld -> %s\n",
             g_self_heal_tick, ml2, mt2, mr2, mb2, nw2, nh2,
             (m_ok && c_ok) ? "CLEAN (no shadow, no band)"
                            : (m_ok ? "still: client band left"
                                    : (c_ok ? "still: dwm margin left"
                                            : "still fixing...")));
  }
  ::fflush(stdout);
}

/// C：空 region 的 blur-behind —— 让 alpha=0 的像素透出桌面
///
/// 返回 DWM 的 HRESULT，便于诊断"代码跑了但 DWM 不认"。
HRESULT ApplyBlurBehind(HWND window) {
  // 空 region：CreateRectRgn(0,0,-1,-1) 是一个**空**区域，
  // 意思是"没有任何地方需要模糊"。DWM 仍然把窗口当作玻璃合成，
  // 于是客户区里 alpha=0 的像素就透出桌面（tao 用的是同一招）。
  HRGN region = ::CreateRectRgn(0, 0, -1, -1);
  DWM_BLURBEHIND bb = {};
  bb.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION;
  bb.fEnable = TRUE;
  bb.hRgnBlur = region;
  bb.fTransitionOnMaximized = FALSE;
  HRESULT hr = ::DwmEnableBlurBehindWindow(window, &bb);
  ::DeleteObject(region);
  return hr;
}

/// C+：把整个客户区扩展成玻璃（-1 边距）
HRESULT ApplyExtendFrameGlass(HWND window) {
  MARGINS margins = {-1, -1, -1, -1};
  return ::DwmExtendFrameIntoClientArea(window, &margins);
}

/// A：色键透明 —— 把**接近纯黑**的像素整片抠掉
///
/// ⚠️ 这是"能让四角真的透明"的唯一确定手段，但它有个致命前提：
///    **键色必须只出现在要透明的地方**。我们四角露的是清屏色
///    `(0,0,0)`，而播放页的视频背景**也是**黑 —— 用黑色做键色
///    会把视频区一起抠穿。
///
///    所以这里**不用纯黑**做键色，而是要求 Dart 侧把圆角外的像素
///    涂成一个"不可能出现在 UI 里"的颜色。当前 Dart 侧做不到
///    （`WindowFrame` 不在本次文件归属内）——
///    保留此模式是为了**实测确认黑角到底是不是清屏色造成的**，
///    以及给后续"给四角填主题色"留一条已验证的退路。
void ApplyColorKey(HWND window) {
  LONG_PTR ex_style = ::GetWindowLongPtr(window, GWL_EXSTYLE);
  ::SetWindowLongPtr(window, GWL_EXSTYLE, ex_style | WS_EX_LAYERED);
  // LWA_COLORKEY(0x1)：键色处完全透明；alpha 参数被忽略
  ::SetLayeredWindowAttributes(window, RGB(0, 0, 0), 0, LWA_COLORKEY);
}

/// 用 `SetWindowCompositionAttribute` 让**窗口背景真透明** —— ★ 任务㉗⑤
///
/// # 它解决的是什么
///
/// 用户报「客户端**假圆角**,四个角都有直角边」。实测根因：
/// ```text
/// 窗口里那块"region 裁掉、Flutter 又没覆盖"的面积
///   → 被 DWM 的 accent tint 填成 WindowFrame 的 backdrop 色（#EEF0F6）
///   → 于是圆角外是一圈**同色系方块** = 用户说的"假圆角"
/// ```
/// 本函数把窗口背景变成**真透明** —— 那圈方块就透出桌面，
/// 圆角由 Dart 的 `ClipRRect` 独自决定（它**确实抗锯齿**，已实测
/// 14 个中间值），于是圆角第一次是**平滑**的。
///
/// # 为什么必须在 region 之前调用
///
/// ```text
/// ① 先让窗口背景透明（本函数）
/// ② 再决定 region 裁不裁
/// 顺序反了的话，第一帧仍会画出那圈方块（用户会看到闪一下）
/// ```
///
/// # 返回值
///
/// `user32.SetWindowCompositionAttribute` 是**未公开** API ——
/// 有些系统上不存在。用 `GetProcAddress` 动态取，取不到就**如实返回 false**
/// （不假装成功；调用方据此回退到 region）。
bool ApplyWindowComposition(HWND window) {
  /*
   * ⚠️ 未公开 API：不能用 `::SetWindowCompositionAttribute(...)` 直接调，
   *    链接器找不到符号（不在任何 .lib 的导入表里）。
   *    必须 `GetProcAddress`。
   */
  using SetWindowCompositionAttributeFn =
      BOOL(WINAPI*)(HWND, WindowCompositionAttributeData*);

  static SetWindowCompositionAttributeFn fn = nullptr;
  static bool resolved = false;
  if (!resolved) {
    resolved = true;
    HMODULE user32 = ::GetModuleHandleW(L"user32.dll");
    if (user32 != nullptr) {
      fn = reinterpret_cast<SetWindowCompositionAttributeFn>(
          ::GetProcAddress(user32, "SetWindowCompositionAttribute"));
    }
    ::printf("[COMPOSITION] SetWindowCompositionAttribute %s\n",
             fn != nullptr ? "FOUND" : "NOT FOUND (unsupported OS)");
  }
  if (fn == nullptr) {
    return false;
  }

  AccentPolicy policy = {};
  /*
   * ★ `ACRYLIC` 与 `BLURBEHIND` 实测**都**能真透明（品红底各透出 44px）。
   *   选 `BLURBEHIND`：它不需要 acrylic 那套（Win10 上 acrylic 偶有
   *   输入延迟问题，且它本意是"模糊背后内容"，而我们要的是"透出桌面"）。
   *   `accent_flags = 0` + `gradient_color` 全零 → 不额外着色。
   */
  policy.accent_state = kAccentEnableBlurBehind;
  policy.accent_flags = 0;
  // 0x00000000 = alpha 0 + 不染色（alpha 在最高字节）
  policy.gradient_color = 0x00000000;
  policy.animation_id = 0;

  WindowCompositionAttributeData data = {};
  data.attribute = kWcaAccentPolicy;
  data.data = &policy;
  data.size_of_data = sizeof(policy);

  const BOOL ok = fn(window, &data);
  ::printf("[COMPOSITION] accent=blurbehind a=0 -> %d (0=failed)\n",
           ok ? 1 : 0);
  return ok != FALSE;
}

/// 窗口是否**铺满它所在的那台显示器**（= 全屏）—— ★ 修「全屏四角白底」
///
/// # 用户报的现象（2026-09-25）
///
/// > 全屏播放的时候,四个角有白色的底
///
/// # 根因（实测，见 `.probe/fs_measure.py` / `fs_predict_fix.py`）
///
/// `ApplyRoundedRegion()` 是从 `WM_SIZE -> ApplyWindowAlpha()` 进来的，
/// 而那里**没有全屏判断** —— 于是**全屏时也照裁圆角**：
/// ```text
/// 窗口态   1280x800  → GetWindowRgn=3  TL=0 TR=0 BL=0 BR=0  ← 圆角正确
/// 全屏态   2560x1440 → GetWindowRgn=3  TL=0 TR=0 BL=0 BR=0  ← ★ 仍被裁圆角
/// ```
/// ⇒ 全屏时那四块**不属于窗口** ⇒ 露出窗口背后的东西（桌面/壁纸）
/// ⇒ 用户看到的「四个角有白色的底」。
///
/// ★ 为什么不能靠外部 `SetWindowRgn(NULL)` 修（实测）：
/// ```text
/// 外部清 region 后**立刻**读数（连 0 延迟都算上）→ 仍是 3 (COMPLEX)
/// ```
/// 因为 `WM_WINDOWPOSCHANGED` 每次位置/尺寸变化都会调
/// `ApplyWindowAlpha()` 重新裁一遍（本文件 L2314）。**必须在源头改。**
///
/// ★ 全屏的正确定义：全屏 = 铺满整块屏幕、**没有圆角**。圆角是"窗口"
///   的装饰；铺满屏幕时不存在"窗口边界"，所以不该有圆角。
///
/// ⚠️ 判据用**窗口矩形 vs 监视器矩形**（都是物理像素），
///    不用 `GWL_STYLE` —— 因为 `window_manager` 的全屏与"最大化"在样式上
///    可能相似，而"铺满显示器"才是用户能看到的那个状态。
bool IsFullscreenOnMonitor(HWND window) {
  if (window == nullptr) {
    return false;
  }
  RECT wr = {};
  if (::GetWindowRect(window, &wr) == 0) {
    return false;
  }
  HMONITOR monitor = ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  if (monitor == nullptr) {
    return false;
  }
  MONITORINFO mi = {};
  mi.cbSize = sizeof(MONITORINFO);
  if (::GetMonitorInfo(monitor, &mi) == 0) {
    return false;
  }
  const RECT& mr = mi.rcMonitor;
  // 容差 1px：全屏时窗口矩形理论上等于监视器矩形，但 DPI/取整可能差 1px
  return wr.left <= mr.left + 1 && wr.top <= mr.top + 1 &&
         wr.right >= mr.right - 1 && wr.bottom >= mr.bottom - 1;
}

/// 窗口是否**铺满了可用区域**（= 放大 或 全屏）—— ★ 修「放大时四角白底」
///
/// ═══════════════════════════════════════════════════════════════════════
/// ★★★ 为什么不能只用 `IsFullscreenOnMonitor()`
/// ═══════════════════════════════════════════════════════════════════════
///
/// 用户实测报的（2026-09-26）：
/// ```text
/// 「还有这三个中间的按钮,是窗口放大,不是窗口全屏,纠正一下」
/// ```
/// 而实测（`.probe/t54_states.py`，真实屏幕 BitBlt）：
/// ```text
/// 放大（标题栏中间按钮） 窗口 2560x1400  四角 inset=3..16 = #e8ebf3 / #ffffff
///                                       ⇒ ★ 白角 **4/4**
/// 全屏（播放页 Enter）   窗口 2560x1440  四角全暗  ⇒ 白角 0/4
/// ```
/// ★ 根因：`IsFullscreenOnMonitor()` 比的是 **`rcMonitor`（2560x1440）**，
///   而**放大**铺满的是 **`rcWork`（2560x1400）** —— 差 **40px = 任务栏**
///   （而用户**明确要求**放大时保留任务栏）
///   ⇒ 判据**永远 false** ⇒ region **不清** ⇒ 四角仍被裁 ⇒ 露出 backdrop ✓
///   （日志证据：`[REGION] fullscreen -> ...` 只在全屏时出现，放大时**一次都没有**）
///
/// ★ 正确的语义（用户原话）：
/// ```text
/// 「客户端全屏也不应该是全屏窗口,只是跟正常客户端,占满屏幕但是保留任务栏
///   叫**放大**,只有播放页才是全屏(不保留任务栏)」
/// ```
/// ⇒ 两者**都**"铺满了可用区域"、**都**不存在"窗口边界外的桌面"
///   ⇒ **都**不该有圆角/垫色。
///
/// ⚠️ 判据用 `rcWork` **和** `rcMonitor` **两者之一**即可：
///    · 全屏 ⇒ 等于 `rcMonitor`（也 ≥ `rcWork`）⇒ 命中
///    · 放大 ⇒ 等于 `rcWork`                   ⇒ 命中
///    · 普通 ⇒ 两者都不等                        ⇒ 不命中
/// 铺满判据的**公共部分**：给定显示器 + 一个矩形，判断该矩形是否铺满了
/// 显示器的 `rcMonitor`（全屏）或 `rcWork`（放大）。
///
/// ⚠️ 抽出来的唯一原因：task-54 需要在 `WM_WINDOWPOSCHANGING` 里对
///    **"即将变成"的矩形**做**同一个**判断（那时 `GetWindowRect()` 还是旧值）。
///    两处必须用完全一样的容差 —— 否则会出现
///    "预判说不铺满、尺寸改完之后又说铺满" 这种自相矛盾的状态，
///    而那种状态下 region 会被**反复清/设**，表现为四角闪烁。
bool RectFillsMonitor(HMONITOR monitor, const RECT& r) {
  if (monitor == nullptr) {
    return false;
  }
  MONITORINFO mi = {};
  mi.cbSize = sizeof(MONITORINFO);
  if (::GetMonitorInfo(monitor, &mi) == 0) {
    return false;
  }
  // ★ 容差 2px：任务栏高度取整 / DPI 缩放可能带来 1px 偏差
  const auto covers = [&r](const RECT& t) {
    return r.left <= t.left + 2 && r.top <= t.top + 2 &&
           r.right >= t.right - 2 && r.bottom >= t.bottom - 2;
  };
  return covers(mi.rcMonitor) || covers(mi.rcWork);
}

bool IsFilledOnMonitor(HWND window) {
  if (window == nullptr) {
    return false;
  }
  RECT wr = {};
  if (::GetWindowRect(window, &wr) == 0) {
    return false;
  }
  return RectFillsMonitor(
      ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), wr);
}

/// 同 `IsFilledOnMonitor()`，但判的是**即将变成**的那个矩形。
///
/// 只给 `WM_WINDOWPOSCHANGING` 用（见 `MessageHandler` 里那条 case 的长注释）：
/// 那条消息在窗口**真正改尺寸之前**到达，`GetWindowRect()` 仍是旧值，
/// 所以"改完会不会铺满"只能拿 `lParam` 里的新尺寸算。
bool WillFillOnMonitor(HWND window, const RECT& next) {
  if (window == nullptr) {
    return false;
  }
  return RectFillsMonitor(::MonitorFromRect(&next, MONITOR_DEFAULTTONEAREST),
                          next);
}

/// 把窗口物理裁成圆角（`SetWindowRgn`）—— ★ 任务㉑① 的默认方案
///
/// # 为什么这条能解决"四个角多出来直角阴影"
///
/// `SetWindowRgn` 之后，**区域外的像素根本不属于这个窗口** ——
/// 桌面直接透出来，不是"我们用某个颜色去盖住它"。
/// 所以无论浅色/深色主题、无论背后是什么，四角都不可能出现"方角色块"。
///
/// 这是 Win10 上**唯一**能做到"圆角外透出桌面"的办法：
/// ```text
/// transparent + 自绘圆角   ❌ Flutter 的 D3D11 swapchain 不给 per-pixel alpha
/// DwmExtendFrameIntoClientArea(-1)  ❌ Win10 用【不透明白】填那块，更糟
/// SetWindowRgn             ✅ 区域外不属于窗口，不依赖任何透明机制
/// ```
///
/// # 实现上三个必须做对的点（原版踩过，照抄其结论）
///
/// ```text
/// ① 坐标：`SetWindowRgn` 收的是【窗口坐标】。
///    现在 `client == window`（nonclient=0x0），所以客户区就是整个窗口，
///    直接 (0,0,w,h) 即可。★ 这条是本轮才成立的 ——
///    原版在 Tauri 下客户区还有 (8,0) 偏移，必须额外换算，
///    否则会把那 8px 缩放边框也裁掉（表现为"左边像被咬掉一条"）。
/// ② 右/下要 +1：`CreateRoundRectRgn` 的右/下边界是**开区间**，
///    不 +1 会少掉最右一列/最下一行（表现为右边漏进 1px 桌面）。
/// ③ 成功后 region **归系统所有**，不能再 DeleteObject；
///    失败时仍归我们，**必须**自己释放，否则句柄泄漏。
/// ```
///
/// # ⚠️ 已知代价（如实记录，不粉饰）
///
/// `SetWindowRgn` 是**二值裁剪**，Win10 不给它抗锯齿 → 凑近看四角有轻微台阶。
/// 这是 Win10 的固有限制（无原生圆角 API，`DWMWA_WINDOW_CORNER_PREFERENCE`
/// 需要 Win11 22000+），不是实现缺陷。
///
/// 在「有台阶但透出桌面」与「圆角平滑但外面套一圈底色」之间，
/// 原版与用户都选了前者（原版注释原话：
/// 「有台阶但**没有黑框/白底**（选了这个）；
///   圆角平滑但**外面套着一圈底色**（实际观感更差，Owner 也否了）」）。
///
/// ⚠️ 半径用**物理像素**（`SetWindowRgn` 收物理坐标），所以要乘 DPI 缩放。
/// 铺满（全屏/放大）时**清掉**残留的圆角 region —— 幂等，没 region 时零副作用。
///
/// ⚠️ 只 "return" 是不够的 —— 从窗口态切进全屏时，圆角 region 已经设上了；
///    不清的话它仍然生效。`SetWindowRgn(window, nullptr, TRUE)` = "不裁"。
///
/// ⚠️ 但**先查一下有没有 region 再清**：本函数会被
///    `WM_SIZE` / `WM_ACTIVATE` / `WM_WINDOWPOSCHANGED` 反复调用，
///    而 `SetWindowRgn` 的第 3 个参数是"重画"，无条件调用会在
///    每次窗口消息时触发一次整窗重绘（无谓的闪烁/开销）。
///    全屏态下绝大多数调用都不需要做任何事。
///
/// ⚠️ 探测用的 HRGN 用**函数内静态**（只建一次）：
///    `GetWindowRgn` 只是把结果**拷进**我们给的 region，所有权仍在我们
///    手上 ⇒ 每次调用都 `CreateRectRgn` 而不删就是**每次泄漏一个 GDI 句柄**
///    （而本函数正是被反复调用的）。静态化之后全进程只用 1 个句柄。
///    C++11 保证函数内静态的初始化是线程安全的。
///
/// ★ 返回 true 表示**这次真的清掉了一个 region**（供诊断日志用）。
bool ClearRoundedRegionIfAny(HWND window) {
  static HRGN probe = ::CreateRectRgn(0, 0, 0, 0);
  if (probe == nullptr) {
    return false;
  }
  /*
   * ═══════════════════════════════════════════════════════════════════════
   * ★★★ task-54 实测更正：**没有 region 的窗口返回的是 `ERROR (0)`**，
   *     不是 `NULLREGION (1)` —— 所以判据必须写 `>= SIMPLEREGION`
   * ═══════════════════════════════════════════════════════════════════════
   *
   * 原来的写法是 `if (::GetWindowRgn(window, probe) != NULLREGION)`，
   * 本意是"没有 region 就什么都不用做"。但它**从来没短路成功过**：
   * ```text
   * 窗口有 region   → COMPLEXREGION(3)  ⇒ != NULLREGION 为真 ⇒ 走清 region  ✓
   * 窗口没有 region → ERROR(0)          ⇒ != NULLREGION 也为真 ⇒ 又清一次  ✗
   * ```
   * ⇒ 全屏态下**每一条** `WM_SIZE` / `WM_ACTIVATE` / `WM_WINDOWPOSCHANGED`
   *   都会执行一次 `SetWindowRgn(window, nullptr, TRUE)`，而第 3 个参数
   *   `TRUE` 的含义是"**整个窗口失效并重绘**"（系统级操作）
   *   ⇒ 在**正在切全屏**的那几十毫秒里，本来就有好几条这类消息
   *   ⇒ 每次都触发一次整窗重绘 = 额外的闪烁源。
   *
   * # 证据（`.probe/t54_region_sem.py`，原始整数，无解释）
   *
   * ```text
   * [A] pid 32620（真实交付实例，只读，不修改）
   *     hwnd=0xd42136 FLUTTER_RUNNER_WIN32_WINDOW  GetWindowRgn = 3  rgnbox=(0,0,1280,800)
   *     hwnd=0x1101f08 SourinShadowWindow           GetWindowRgn = 0  rgnbox=(0,0,0,0)
   * [B] 我自己的隔离实例（可以改）
   *     窗口态（我们的代码设过 region）  GetWindowRgn = 3  rgnbox=(0,0,1280,800)
   *     SetWindowRgn(hwnd, nullptr, TRUE) -> 1
   *     清掉之后（== "没有 region" 的状态）GetWindowRgn = 0  rgnbox=(0,0,0,0)
   * ```
   * 同一次运行里 `SourinShadowWindow`（本来就没有 region）也返回 **0**
   * ⇒ 两路独立证据都指向 `ERROR(0)` = "没有 region"。
   *
   * # 为什么不能写成 `!= ERROR`
   *
   * `GetWindowRgn` 返回 0 的**官方**语义是"窗口没有 region **或**出错"
   * （MSDN）。把它当"没有 region"用，等于把"真的出错了"也吞掉 ——
   * 那样一旦 `SetWindowRgn` 失败，圆角会**永久丢失**且没有任何线索。
   * 所以正向判定"有 region"更安全：只有 SIMPLEREGION / COMPLEXREGION
   * 才动手，其余（NULLREGION / ERROR）一律不动。
   */
  const int r = ::GetWindowRgn(window, probe);
  if (r != SIMPLEREGION && r != COMPLEXREGION) {
    return false;  // NULLREGION / ERROR ⇒ 本来就没有可清的 region
  }
  ::SetWindowRgn(window, nullptr, TRUE);
  /*
   * ★ 缓存置为无效 —— region 现在是"没有"，不能让它看起来像"已设好"。
   *   见文件作用域那段注释（否则切回窗口态时圆角会永久丢失）。
   */
  InvalidateRegionCache();
  return true;
}

void ApplyRoundedRegion(HWND window) {
  /*
   * ★★★ 全屏时**不裁圆角**（2026-09-25）—— 修用户报的「全屏四角白底」
   *
   * 判据与完整推导见 `IsFilledOnMonitor()` 上方的注释。
   * 一句话：**铺满可用区域（放大 或 全屏）= 不存在"窗口边界"，所以不该有圆角**；
   * 硬裁的话那四块不属于窗口 ⇒ 露出背后的桌面（用户看到"白色的底"）。
   *
   * ★ 2026-09-26 修正：判据从 `IsFullscreenOnMonitor()`（只认 `rcMonitor`）
   *   改成 `IsFilledOnMonitor()`（`rcMonitor` **或** `rcWork`）——
   *   因为**放大**铺满的是 `rcWork`（2560x1400，比显示器少 40px 任务栏），
   *   旧判据对它**永远 false** ⇒ region 不清 ⇒ 放大时四角白角 **4/4**（实测）。
   *
   * ⚠️ 放在**本函数最前面**（而不是只放在 `case kRegion`）——
   *    因为 `kRegion` 与 `kCompositionBlur` **两个** case 都会调本函数，
   *    把守卫放在函数里才不会漏掉第二个调用点。
   *
   * ⚠️⚠️ 这个守卫**只解决"窗口不该被裁"**那一半。用户看到的「四角白底」
   *    还有**另一半在 Dart 侧**：`WindowFrame` 的 `Stack([ColoredBox(backdrop),
   *    ClipRRect(...)])` 会**铺满整个窗口**并画圆角
   *    ⇒ 即使这里清了 region，四角仍是 `backdrop`（浅色主题 = #eef0f6 ≈ 白）。
   *    实测（`SOURIN_WIN_ALPHA=none` + 全屏）：
   *      TL=#eef0f6 TR=#eef0f6 BL=#eef0f6 BR=#eef0f6
   *    ⇒ `lib/ui/widgets/window_frame.dart` 的 `_filled`（`windowManager`
   *      事件驱动）同时在全屏/放大时不画那两层。**两侧都改才修得掉**。
   */
  if (IsFilledOnMonitor(window)) {
    /*
     * 全屏：必须**清掉**可能残留的圆角 region。
     *
     * ⚠️ 只 "return" 是不够的 —— 从窗口态切进全屏时，
     *    圆角 region 已经设上了；不清的话它仍然生效。
     *    `SetWindowRgn(window, nullptr, TRUE)` = "不裁"。
     *
     * ★ task-54：这段逻辑抽成了 `ClearRoundedRegionIfAny()`，
     *   因为现在**还有第二个调用点** —— `WM_WINDOWPOSCHANGING`
     *   （那条路必须在尺寸真正改变**之前**就清，见那里的长注释）。
     *   两处必须行为完全一致，所以只能有一份实现。
     */
    if (ClearRoundedRegionIfAny(window)) {
      ::printf("[REGION] fullscreen -> region cleared (no rounding)\n");
    }
    return;
  }

  RECT rect = {};
  ::GetWindowRect(window, &rect);
  const LONG w = rect.right - rect.left;
  const LONG h = rect.bottom - rect.top;
  if (w <= 0 || h <= 0) {
    return;
  }

  const double scale = GetWindowScale(window);
  // CreateRoundRectRgn 的椭圆宽高是"**直径**"，所以要乘 2
  const int diameter = static_cast<int>(g_corner_radius * scale * 2.0);

  /*
   * ═══════════════════════════════════════════════════════════════════════
   * ★★★ 尺寸没变就**不重建 region** —— 修用户报的「放大缩小非常卡顿」
   * ═══════════════════════════════════════════════════════════════════════
   *
   * # 用户原话（2026-09-25）
   *
   * > 窗口放大 缩小, 不在播放页 **非常卡顿**
   *
   * # 根因（读代码 + 注释自证）
   *
   * 本函数从 `WM_WINDOWPOSCHANGED` 进来，而那条消息**拖动和缩放都会触发**。
   * 于是**纯拖动**（位置变、尺寸没变）也会赔上：
   * ```text
   * ① GetWindowRect  ② GetWindowScale
   * ③ CreateRoundRectRgn   ④ ★ SetWindowRgn(..., TRUE)
   * ```
   * ★ 第 ④ 步的第 3 个参数是 **TRUE = 整个窗口失效并重绘**（系统级操作）
   *   ⇒ 拖动时每帧做一次 ⇒ **卡**。
   *
   * ★ 而 `CreateRoundRectRgn(0, 0, w + 1, h + 1, ...)` 的坐标是
   *   **窗口坐标**（永远从 (0,0) 起）⇒ **region 只依赖尺寸与半径，
   *   与窗口在屏幕上的位置无关** ⇒ **位置变化根本不需要重建** ✓
   *
   * ⚠️ 这正是**铺满分支**（本函数开头那个 `IsFilledOnMonitor` 守卫）
   *    已经做过的优化 —— 那里用 `GetWindowRgn` 先探测、只有真有 region
   *    才去 `SetWindowRgn`。本分支当时漏了同样的处理。
   *    现在两个分支用**同一种思路**（先判断再动手），不再"修一半"。
   *
   * # 缓存键为什么是 (w, h, diameter)
   *
   * ```text
   * w, h        尺寸变了 ⇒ region 必须重建
   * diameter    它 = 半径 × DPI 缩放 × 2
   *             ⇒ ★ 把窗口拖到**另一块不同 DPI 的显示器**时会变，
   *               此时即使 w/h 恰好相同也必须重建
   * ```
   * 位置 (left, top) **故意不进缓存键** —— 它不影响 region。
   *
   * ⚠️ 缓存的三个变量在**文件作用域**（`g_region_cache_*`）——
   *    这样 `case kComposition` 那条清 region 的路径也能让它失效，
   *    见 `InvalidateRegionCache()`。
   */
  if (w == g_region_cache_w && h == g_region_cache_h &&
      diameter == g_region_cache_diameter) {
    return;  // 纯拖动 / 无尺寸变化的 WM_WINDOWPOSCHANGED —— 什么都不用做
  }

  // 右/下 +1（开区间约定，见上面 ②）
  HRGN region =
      ::CreateRoundRectRgn(0, 0, w + 1, h + 1, diameter, diameter);
  if (region == nullptr) {
    return;
  }
  /*
   * ★ 返回值必须检查（见上面 ③）
   *
   * `SetWindowRgn` 成功 → 区域归系统，**不能**再删；
   * 失败 → 区域仍归我们，**必须**删，否则每次 resize 泄漏一个 GDI 句柄
   * （resize 时本函数会被反复调用）。
   */
  if (::SetWindowRgn(window, region, TRUE) == 0) {
    ::DeleteObject(region);
    /*
     * ⚠️ 失败时**不要**更新缓存 —— 否则下次尺寸相同的调用会直接 return，
     *    而 region 其实**没设上**（圆角/裁剪就永久丢了）。
     */
    return;
  }
  // ★ 只有真正设上了才记缓存
  g_region_cache_w = w;
  g_region_cache_h = h;
  g_region_cache_diameter = diameter;
}

/// 按当前方案给窗口应用"透明/圆角"
///
/// ⚠️ 会被调用多次（首次创建 + 之后每次尺寸/激活变化）——
///    window_manager 在设 TitleBarStyle / 全屏时会调
///    `DwmExtendFrameIntoClientArea({0,0,0,0})`，那会把玻璃效果冲掉。
///    所以这里必须能**重复应用**（都是幂等的 DWM 调用）。
///
/// # 为什么要重入保护
///
/// `kBlurFrame` 会调 `DwmExtendFrameIntoClientArea` —— 它自己就会触发
/// `WM_WINDOWPOSCHANGED`，而我们在那个消息里又调本函数 → **无限递归**。
/// 用 `g_applying` 挡住重入（只挡嵌套，不挡后续的正常调用）。
void ApplyWindowAlpha(HWND window) {
  static bool g_applying = false;
  if (g_applying) {
    return;
  }
  g_applying = true;

  ResolveAlphaConfig();

  /*
   * ★ 先去掉非客户区（`WS_CAPTION`），再设透明
   *
   * 顺序很重要：先去边框 → 客户区变成整个窗口 →
   * 那时 Flutter 的圆角才是"窗口的圆角"。
   * 如果先设透明再去边框，中间那一瞬间窗口仍是方的，
   * 而且 DWM 可能已经把边框画出来了（闪烁）。
   */
  const bool style_changed = ApplyFramelessStyle(window);

  HRESULT hr_blur = S_OK;
  HRESULT hr_frame = S_OK;

  switch (g_alpha_mode) {
    case AlphaMode::kNone:
      break;
    case AlphaMode::kBlur:
      hr_blur = ApplyBlurBehind(window);
      break;
    case AlphaMode::kBlurFrame:
      hr_blur = ApplyBlurBehind(window);
      hr_frame = ApplyExtendFrameGlass(window);
      break;
    case AlphaMode::kRegion:
      ApplyRoundedRegion(window);
      break;
    case AlphaMode::kColorKey:
      ApplyColorKey(window);
      break;
    case AlphaMode::kComposition:
      /*
       * ★ 任务㉗⑤：真透明。
       *
       * ⚠️ **不**在这里调 `ApplyRoundedRegion` —— 既然背景已经真透明，
       *    那圈方块根本不存在了，再裁 region 只会把 Dart 的**抗锯齿圆角**
       *    换成一条硬边（那正是用户报的"假圆角"）。
       *    ⇒ 圆角的唯一决定者是 Dart 的 `ClipRRect`。
       *
       * ⚠️ 同时必须**清掉**可能残留的 region（前面几帧可能设过）——
       *    `SetWindowRgn(window, nullptr, TRUE)` 就是"不裁"。
       */
      ApplyWindowComposition(window);
      ::SetWindowRgn(window, nullptr, TRUE);
      /*
       * ★ 清了 region ⇒ 缓存必须失效（见 `InvalidateRegionCache()` 的说明）。
       *   漏了这一步的话，从 kComposition 切回 kRegion 时若尺寸恰好相同，
       *   缓存会误判"region 已经设好了" ⇒ **圆角永久丢失**。
       */
      InvalidateRegionCache();
      break;
    case AlphaMode::kCompositionBlur:
      /*
       * ★ 任务㉗⑤：SWCA(BLURBEHIND) + **保留 region**
       *
       * 与 `kComposition` 的**唯一差别**：这里**不**清 region，
       * 而是照常裁圆角 —— 于是 DWM 只在 region 之外加模糊/透明，
       * 内容区（region 内）保持原样。
       *
       * ⚠️ 顺序：先设 region 再设 accent。
       *    反过来的话，第一帧 DWM 可能已经按"没有 region"合成了一次
       *    （那正是 `kComposition` 整窗透明的现象）。
       */
      ApplyRoundedRegion(window);
      ApplyWindowComposition(window);
      break;
  }

  /*
   * ★ 诊断输出
   *
   * # 为什么必须打出来
   * "四角是黑还是透"没法靠猜 —— 每次都要重新编译 C++ 再重启验证，
   * 成本很高。把**实际生效的方案 + DWM 调用的返回值**打出来，
   * 就能一次判定"代码有没有跑、DWM 认不认"。
   * 用 `printf` 而不是 `OutputDebugString`：我们要用
   * `Start-Process -RedirectStandardOutput` 收进 out.txt，
   * 而 OutputDebugString 只在调试器里看得到。
   *
   * ⚠️ 每次都打（前 12 次）：因为 `window_manager` 会在
   *    `TitleBarStyle` / 全屏切换时**整份覆盖** `GWL_STYLE`。
   *    只在第一次打会让人误判"设置成功了"，而实际上
   *    后面某个时刻已经被覆盖回去 —— 这正是第一轮踩的坑。
   */
  static int g_report_count = 0;
  g_report_count++;
  if (g_report_count <= 12 || style_changed) {
    const char* mode_name = "none";
    switch (g_alpha_mode) {
      case AlphaMode::kNone:      mode_name = "none";      break;
      case AlphaMode::kBlur:      mode_name = "blur";      break;
      case AlphaMode::kBlurFrame: mode_name = "blurframe"; break;
      case AlphaMode::kRegion:    mode_name = "region";    break;
      case AlphaMode::kColorKey:  mode_name = "colorkey";  break;
      case AlphaMode::kComposition: mode_name = "composition"; break;
      case AlphaMode::kCompositionBlur: mode_name = "compositionblur"; break;
    }
    RECT wr = {};
    RECT cr = {};
    ::GetWindowRect(window, &wr);
    ::GetClientRect(window, &cr);
    const LONG_PTR st = ::GetWindowLongPtr(window, GWL_STYLE);
    ::printf("[ALPHA] #%d mode=%s blur_hr=0x%08lX frame_hr=0x%08lX "
             "frameless=%d changed=%d window=%ldx%ld client=%ldx%ld "
             "nonclient=%ldx%ld caption=%d thickframe=%d\n",
             g_report_count, mode_name,
             static_cast<unsigned long>(hr_blur),
             static_cast<unsigned long>(hr_frame), g_frameless ? 1 : 0,
             style_changed ? 1 : 0, wr.right - wr.left, wr.bottom - wr.top,
             cr.right, cr.bottom, (wr.right - wr.left) - cr.right,
             (wr.bottom - wr.top) - cr.bottom, (st & WS_CAPTION) != 0 ? 1 : 0,
             (st & WS_THICKFRAME) != 0 ? 1 : 0);
    ::fflush(stdout);
  }

  g_applying = false;
}

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";


/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

/// 把 hit-test code 映射成缩放光标；非缩放区返回 nullptr（交回系统/Flutter）
LPCWSTR ResizeCursorFor(int hit_test_code) {
  switch (hit_test_code) {
    case HTLEFT:
    case HTRIGHT:
      return IDC_SIZEWE;
    case HTTOP:
    case HTBOTTOM:
      return IDC_SIZENS;
    case HTTOPLEFT:
    case HTBOTTOMRIGHT:
      return IDC_SIZENWSE;
    case HTTOPRIGHT:
    case HTBOTTOMLEFT:
      return IDC_SIZENESW;
    default:
      return nullptr;  // HTCLIENT / 其它 -- 一律交回，别抢 Flutter 的光标
  }
}

/// 光标是否落在「窗口边缘 kResizeBorderDip 逻辑像素」这条带里
bool InResizeBand(HWND window, POINT screen_point) {
  RECT wr = {};
  ::GetWindowRect(window, &wr);
  const double scale = GetWindowScale(window);
  const int border =
      static_cast<int>(kResizeBorderDip * (scale > 0 ? scale : 1.0));
  return screen_point.x < wr.left + border ||
         screen_point.x >= wr.right - border ||
         screen_point.y < wr.top + border ||
         screen_point.y >= wr.bottom - border;
}

/// 最大化时不做热区（否则屏幕四边会变成缩放边，点任务栏会误触）
bool IsMaximizedWindow(HWND window) {
  WINDOWPLACEMENT placement = {};
  placement.length = sizeof(WINDOWPLACEMENT);
  return ::GetWindowPlacement(window, &placement) &&
         placement.showCmd == SW_SHOWMAXIMIZED;
}

/*
 * =======================================================================
 * 子窗口子类化：把「窗口边缘」的命中交回父窗口
 *   -- Owner「鼠标移到窗口边缘没有缩放光标、拖不动大小」修复的 ①
 * =======================================================================
 *
 * # 为什么必须动子窗口
 *
 * FLUTTERVIEW（Flutter 的宿主子窗口）被刻意铺满整个窗口矩形
 * （见 WM_SIZE / SetChildContent，含那圈 8px 边框带），于是：
 *   SendMessage(父窗口, WM_NCHITTEST) -> 0..5px: HTLEFT/HTRIGHT/HTTOP/
 *                                        HTBOTTOM/四角
 *                                        >=6px : HTCLIENT
 *   SendMessage(子窗口, WM_NCHITTEST) -> 处处 HTCLIENT  <- 真实命中走这条
 * 真实鼠标命中的是最上层、铺满的子窗口，父窗口的 WM_NCHITTEST
 * 永远不会被系统问到 -- 热区代码（case WM_NCHITTEST:）形同虚设。
 *
 * # 修法：HTTRANSPARENT
 *
 * 系统收到子窗口的 HTTRANSPARENT(-1) 会继续向同线程的父窗口做命中测试，
 * 于是父窗口既有的 6px 热区 + WM_SETCURSOR 光标映射立刻生效，
 * 八条边 + 四个角全部可用。
 *
 * 注意：带外必须原样交回 CallWindowProcW(orig, ...)：
 *    Flutter 嵌入器的指针/键盘事件全靠子窗口自己的 WndProc，
 *    任何越界拦截都会让画面失去鼠标输入。
 * 注意：HTCLIENT 也照原样交回 -- 只有"边缘带"里才替换。
 * 注意：只装一次（SOURIN_ORIG_WNDPROC 属性作哨兵），
 *    否则 window_manager 反复 SetChildContent 会套娃。
 * 注意：装哨兵的顺序不能反：先挂属性、再换 WNDPROC。
 *    反过来的话，若 SetPropW 失败，子类 proc 拿不到原 proc，
 *    只能退化成 DefWindowProcW -- 那会让 Flutter 彻底失去鼠标输入。
 */
LRESULT CALLBACK SourinChildWndProc(HWND child,
                                    UINT message,
                                    WPARAM wparam,
                                    LPARAM lparam) noexcept {
  auto orig =
      reinterpret_cast<WNDPROC>(::GetPropW(child, L"SOURIN_ORIG_WNDPROC"));
  if (orig == nullptr || orig == reinterpret_cast<WNDPROC>(1)) {
    return ::DefWindowProcW(child, message, wparam, lparam);
  }

  if (message == WM_NCHITTEST) {
    HWND parent = ::GetAncestor(child, GA_ROOT);
    if (parent != nullptr && parent != child && !IsMaximizedWindow(parent) &&
        InResizeBand(parent, {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)})) {
      return HTTRANSPARENT;  // 让系统继续问父窗口
    }
  } else if (message == WM_SETCURSOR) {
    /*
     * 兜底：命中带内的 WM_SETCURSOR 有时仍会发给子窗口
     * （WM_SETCURSOR 发给"光标下的窗口"，而光标下就是子窗口）。
     * 这里按同一个映射表设光标 -- 与父窗口那段共用 ResizeCursorFor()，
     * 不会出现两套不一致的光标。
     */
    LPCWSTR cursor_id = ResizeCursorFor(LOWORD(lparam));
    if (cursor_id != nullptr) {
      ::SetCursor(::LoadCursor(nullptr, cursor_id));
      return TRUE;
    }
  }
  return ::CallWindowProcW(orig, child, message, wparam, lparam);
}

/// 幂等地给 child 装子类化（见 SourinChildWndProc 上方长注释）
void MaybeSubclassChild(HWND parent, HWND child) {
  (void)parent;
  if (child == nullptr) {
    return;
  }
  if (::GetPropW(child, L"SOURIN_ORIG_WNDPROC") != nullptr) {
    return;  // 已装过
  }
  ::SetPropW(child, L"SOURIN_ORIG_WNDPROC", reinterpret_cast<HANDLE>(1));
  const LONG_PTR old = ::SetWindowLongPtrW(
      child, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(&SourinChildWndProc));
  if (old == 0) {
    // 跨线程等失败 -- 保持原样（宁可不修缩放，也不能破坏鼠标输入）
    ::RemovePropW(child, L"SOURIN_ORIG_WNDPROC");
    return;
  }
  ::SetPropW(child, L"SOURIN_ORIG_WNDPROC", reinterpret_cast<HANDLE>(old));
}

/// 可选：关闭 DWM 的非客户区渲染（A/B 复测用，默认不动）
void ApplyNcRenderingPolicy(HWND window) {
  static const bool kDisabled = [] {
    char buf[16] = {0};
    DWORD n =
        ::GetEnvironmentVariableA("SOURIN_WIN_NCRENDERING", buf, sizeof(buf));
    return n > 0 && n < sizeof(buf) && std::string(buf) == "disabled";
  }();
  if (!kDisabled) {
    return;
  }
#ifndef DWMWA_NCRENDERING_POLICY
#define DWMWA_NCRENDERING_POLICY 2
#endif
#ifndef DWMNCRP_DISABLED
#define DWMNCRP_DISABLED 1
#endif
  const int policy = DWMNCRP_DISABLED;
  ::DwmSetWindowAttribute(window, DWMWA_NCRENDERING_POLICY, &policy,
                          sizeof(policy));
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  /*
   * ★★★ 创建窗口的样式 —— 消除 DWM 投影（见 `g_no_shadow` 上方那段长注释）
   *
   * # ⚠️ 这里**故意不改**样式位（我第一版改过，实测**失败**，别重蹈覆辙）
   *
   * 第一版把 `WS_CAPTION|WS_BORDER|WS_THICKFRAME` 从这里的样式里掩掉，
   * 以为"创建时给对样式就一劳永逸"。实测日志（`.probe/run-shadow/out.txt`）：
   * ```text
   * [NOSHADOW] style=0x04CB0000 window=1280x720 efb=1280x720 dwmMargin 0,0,0,0
   *                                     ↑ 创建那一刻看着是好的
   * 运行中再查同一个窗口：
   * GWL_STYLE = 0x14CB0000   CAPTION=1  ← ★ CAPTION/BORDER 又回来了
   * DWM margin L=7 T=0 R=7 B=7           ← 阴影照旧（用户报"还是有"）
   * ```
   * **`CreateWindow` 内部会把 `WS_CAPTION`/`WS_BORDER` 加回来**
   *（窗口带 `WS_SYSMENU`/`WS_MINIMIZEBOX`/`WS_MAXIMIZEBOX` 时系统会补装饰位），
   * 所以"在创建时掩样式位"这条路**根本走不通**。
   *
   * # 正确的路：创建**之后**再扒样式位
   *
   * `ApplyWindowAlpha()` → `ApplyFramelessStyle()` 就是干这个的：
   * 它 `SetWindowLongPtr` 扒掉装饰位，再紧跟
   * `SetWindowPos(SWP_FRAMECHANGED)` 强制系统**重算框架**。
   * 实测（`.probe/CTL-nothick-after.png`）：
   * ```text
   * style=0x140B0000  CAPTION=0 BORDER=0 DLGFRAME=0 THICKFRAME=0
   * efb=1280x800 == GetWindowRect  →  dwmMargin L=0 T=0 R=0 B=0
   * 窗口最外 16 像素： #ffffff x16（★ 阴影完全消失）
   * ```
   * 所以这里保持 `WS_OVERLAPPEDWINDOW` 不动，把"去投影"完全交给
   * `ResolveFramelessConfig()` 里 `g_no_shadow → g_frameless + g_drop_thickframe`
   * 那条**已验证**的机制。
   */
  ResolveFramelessConfig();

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  /*
   * ★ 诊断：确认"去投影"真的生效
   *
   * `ExtFrameBounds` 与 `GetWindowRect` 是否**重合**，是"还有没有
   * DWM 边框/投影"的**唯一可靠判据**（两者之差就是 DWM 保留的边框，
   * 也就是投影所在的那圈）。打出来，避免"以为改了其实没改"。
   *
   * ⚠️ 这里打的是**刚 CreateWindow 完**的状态 —— 那时装饰位还没扒，
   *    `dwmMargin` 必然是 7/7/7，**不能**用它判成败。
   *    真正的判据是 `ApplyFramelessStyle` 之后那次（见下面的 `[NOSHADOW-FIXED]`）。
   */
  if (g_no_shadow) {
    RECT wr = {};
    RECT efb = {};
    ::GetWindowRect(window, &wr);
    ::DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &efb,
                            sizeof(efb));
    ::printf("[NOSHADOW] style=0x%08lX window=%ldx%ld efb=%ldx%ld "
             "dwmMargin L=%ld T=%ld R=%ld B=%ld\n",
             static_cast<unsigned long>(::GetWindowLongPtr(window, GWL_STYLE)),
             wr.right - wr.left, wr.bottom - wr.top, efb.right - efb.left,
             efb.bottom - efb.top, efb.left - wr.left, efb.top - wr.top,
             wr.right - efb.right, wr.bottom - efb.bottom);
    ::fflush(stdout);
  }

  UpdateTheme(window);

  /*
   * ★ 圆角透明（见文件顶部那段长注释）
   *
   * 这里应用一次；之后 `WM_SIZE` / `WM_ACTIVATE` 还会**重复应用** ——
   * 因为 `window_manager` 在设 `TitleBarStyle` 和进出全屏时会调
   * `DwmExtendFrameIntoClientArea`，那会冲掉玻璃效果。
   * 应用本身是幂等的，多调几次无害。
   */
  ApplyWindowAlpha(window);

  // 2026-10-05: 可选关闭 DWM 非客户区渲染（默认不动，仅 A/B 复测用）
  ApplyNcRenderingPolicy(window);

  /*
   * ★ 非客户区归零（`WM_NCCALCSIZE` 返回 0）必须**触发一次重算**才生效
   *
   * `WM_NCCALCSIZE` 只在窗口框架被重算时才会发。刚 `CreateWindow`
   * 完那一次已经过去了（那时窗口还没有我们的样式），所以这里用
   * `SWP_FRAMECHANGED` 主动让系统重算一遍。
   *
   * ⚠️ 必须 `SWP_NOMOVE | SWP_NOSIZE`：否则会把主进程刚设好的
   *    尺寸/位置冲掉（`main.cpp` 传的 1280x720 会变成窗口默认值）。
   */
  ResolveFramelessConfig();
  if (g_frameless || g_no_shadow) {
    ::SetWindowPos(window, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                       SWP_FRAMECHANGED);

    /*
     * ★★ 决定性诊断：**扒完样式位之后**再查一次
     *
     * 这才是判"去投影成没成"的**唯一**有效读数：
     * ```text
     * dwmMargin 全 0  → ExtFrameBounds == GetWindowRect → 没有 DWM 边框/投影 ✅
     * dwmMargin 有值  → DWM 仍保留一圈 → 阴影还在 ❌
     * ```
     * ⚠️ 上面 `[NOSHADOW]` 那次是在 `CreateWindow` 之后、扒样式位**之前**
     *    打的，那时必然是 7/7/7 —— 只看它会把"没生效"误判成"生效了"
     *    （第一版就是这么翻车的）。
     */
    if (g_no_shadow) {
      RECT wr2 = {};
      RECT efb2 = {};
      ::GetWindowRect(window, &wr2);
      ::DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &efb2,
                              sizeof(efb2));
      const long ml = efb2.left - wr2.left;
      const long mt = efb2.top - wr2.top;
      const long mr = wr2.right - efb2.right;
      const long mb = wr2.bottom - efb2.bottom;
      ::printf("[NOSHADOW-FIXED] style=0x%08lX window=%ldx%ld efb=%ldx%ld "
               "dwmMargin L=%ld T=%ld R=%ld B=%ld -> %s\n",
               static_cast<unsigned long>(::GetWindowLongPtr(window, GWL_STYLE)),
               wr2.right - wr2.left, wr2.bottom - wr2.top, efb2.right - efb2.left,
               efb2.bottom - efb2.top, ml, mt, mr, mb,
               (ml == 0 && mt == 0 && mr == 0 && mb == 0)
                   ? "SHADOW GONE (ok)"
                   : "SHADOW STILL PRESENT (FAIL)");
      ::fflush(stdout);
      // 2026-10-05: 缩放修复的读数（THICKFRAME 是否还在）
      const LONG_PTR st_resize = ::GetWindowLongPtr(window, GWL_STYLE);
      ::printf("[RESIZE-FIX] thickframe=%d caption=%d frameless=%d "
               "drop_thickframe=%d\n",
               (st_resize & WS_THICKFRAME) ? 1 : 0,
               (st_resize & WS_CAPTION) ? 1 : 0, g_frameless ? 1 : 0,
               g_drop_thickframe ? 1 : 0);
      ::fflush(stdout);
    }

    /*
     * ★ 启动自愈定时器（见 `SelfHealClientArea` 上方的长注释）
     *
     * `window_manager` 随后会在**它自己的调用栈里**覆盖掉上面的归零结果，
     * 而那次覆盖**不产生** `WM_NCCALCSIZE` 消息（实测）。
     * 所以必须在**新的消息周期**里再校正 —— 由定时器负责。
     */
    g_self_heal_tick = 0;
    ::SetTimer(window, kSelfHealTimerId, kSelfHealIntervalMs, nullptr);
  }

  /*
   * ═══════════════════════════════════════════════════════════════════════
   * ★★★ 窗口投影（2026-09-25 用户要求「像 QQ 那种边缘模糊阴影」）
   * ═══════════════════════════════════════════════════════════════════════
   *
   * # 为什么放在这里（`OnCreate` 的**最后**）
   *
   * ```text
   * 阴影窗口要跟随主窗口的位置/尺寸，所以必须等：
   *   ① `ApplyFramelessStyle()` 扒完样式位（窗口矩形才定型）
   *   ② `SWP_FRAMECHANGED` 那次重算跑完（客户区才等于窗口矩形）
   *   ③ `main.cpp` 设的尺寸生效
   * ⇒ 只有到这里，`GetWindowRect` 才是最终值。
   * ```
   *
   * # 为什么是"独立 layered 窗口"（见 `window_shadow.h` 顶部的完整论证）
   *
   * ```text
   * ① DWM 阴影 —— ★ 本机拿不到（系统级 VisualFXSetting=2）
   *    实测：新建全新 WS_OVERLAPPEDWINDOW 窗口，外扩 = (0,0,0,0)
   * ② 窗口【内侧】画投影 —— ★ 结构上不可能对
   *    实测：变成"一圈比内容暗 19 级的实色带"，用户已明确否掉
   * ③ SetWindowRgn 二值裁剪 —— 做不出渐变
   * ⇒ ④ 独立 WS_EX_LAYERED 窗口 + UpdateLayeredWindow
   *      阴影是**静态**的 ⇒ 只在移动/缩放时重画一次
   *      （不违反"16.1ms/帧"那条否决 —— 那条是"每帧拷贝整窗"）
   * ```
   *
   * ⚠️ 失败不抛：阴影是"锦上添花"，不该让主窗口画不出来。
   * ⚠️ `SOURIN_WIN_SHADOW=0` 可关（A/B 对照用）。
   */
  sourin::WindowShadow::Instance().Attach(window);

  return OnCreate();
}


bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}


// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    /*
     * 2026-10-05: 给铺满窗口的 FLUTTERVIEW 子窗口装子类化。
     *   幂等（属性哨兵），每条消息都调也不会重复装。
     *   child_content_ 是 private，但本函数是 Win32Window 的静态成员，
     *   对同类实例有访问权，所以不需要加访问器。
     */
    MaybeSubclassChild(window, that->child_content_);
    /*
     * ═══════════════════════════════════════════════════════════════════════
     * ★★★ 抢在插件之前处理 `WM_NCCALCSIZE`
     *     —— `client != window`（16x8）的真正、也是最后一个根因
     *     （任务⑪ revision 6）
     * ═══════════════════════════════════════════════════════════════════════
     *
     * # 为什么必须在**这里**处理，而不是在下面的 `MessageHandler`
     *
     * 消息的传递链是：
     * ```text
     * WndProc（本函数）
     *   └─▶ that->MessageHandler()             ← 我们的 switch 在这里
     *         └─▶ FlutterWindow::MessageHandler()
     *               └─▶ flutter_controller_->HandleTopLevelWindowProc()
     *                     └─▶ ★ window_manager 插件的 top-level proc delegate
     *                           （见 window_manager_plugin.cpp:147）
     * ```
     * `window_manager` 插件是**注册的 top-level window proc delegate**，
     * 比我们的 `MessageHandler` **先**拿到 `WM_NCCALCSIZE`，而且它对
     * 这种情况**直接 `return 0`**（表示"我已处理"）——于是我们下面
     * `MessageHandler` 里那段 `WM_NCCALCSIZE` 代码**根本不会被执行**。
     *
     * 这就解释了为什么前两轮怎么改都没用：
     * ```text
     * 日志 #4  client=1280x720  nonclient=0x0    ← 生效过（创建早期，插件还没注册）
     * 日志 #5  client=1264x712  nonclient=16x8   ← 之后每次都被插件改回去
     * 中间【没有】NCCALCSIZE 打印 → 因为没走到我们的 handler
     * ```
     * **`SelfHealClientArea()` 永远修不好它**：它调 `SetWindowPos(SWP_FRAMECHANGED)`
     * 触发 `WM_NCCALCSIZE`，而那次消息又被插件截走并重新做 `-8`。
     * 自愈和插件在打一场**必输**的拉锯战 —— 每轮自愈都恰好重新触发一次缩小。
     *
     * # 插件的 bug 是什么（`window_manager` 0.5.2）
     *
     * `window_manager_plugin.cpp:165-184`，`title_bar_style_ == "hidden"`
     * 分支（`shell.dart` 用的正是 `TitleBarStyle.hidden`）：
     * ```cpp
     * sz->rgrc[0].top    += IsWindows11OrGreater() ? 0 : 1;   // ← 上没有
     * sz->rgrc[0].right  -= 8;                                // ← 右 8
     * sz->rgrc[0].bottom -= 8;                                // ← 下 8
     * sz->rgrc[0].left   -= -8;                               // ← 左 8（即 +8）
     * ```
     * 即**故意**把客户区四周各收 8px（上 0/1px）。这正是：
     * ```text
     * window=1280x800 → client=1264x792   ⇒ nonclient=16x8
     * 左8 右8 下8 上0                    ⇒ 用户原话「左右下都有,上没有」
     * ```
     * 上游注释说这 8px 是"为了能缩放窗口"
     * （leanflutter/window_manager#483）。但我们的缩放热区
     * 是自己在 `WM_NCHITTEST` 里实现的（返回 `HTLEFT/HTRIGHT/...`），
     * **不需要**靠这 8px 的非客户区 —— 所以这里可以安全地把它抹掉。
     *
     * # 修法
     *
     * 在 `WndProc` 里**最先**拦下 `WM_NCCALCSIZE(wParam=TRUE)`，
     * 把 `rgrc[0]` 明确设成"整个窗口矩形"（= 非客户区为 0），
     * 然后 `return 0`。这样插件**根本收不到**这条消息，
     * 那三行 `-= 8` 也就无从执行。
     *
     * ⚠️ 只在 `g_no_shadow`（用户要的"无边框无阴影"路径）时生效，
     *    不改变 `g_frameless` 单独开启时的既有行为。
     * ⚠️ 最大化时**放过**（交给原逻辑）：最大化时 Windows 故意把窗口
     *    撑到比工作区大一圈，强行归零会让内容溢出屏幕。
     */
    if (message == WM_NCCALCSIZE && wparam == TRUE) {
      /*
       * ⚠️ 必须先解析配置：`g_no_shadow` 平时是在 `MessageHandler()` 开头
       *    调 `ResolveFramelessConfig()` 时才从环境变量读出来的，
       *    而我们这里**比 `MessageHandler` 更早**执行。
       *    不先调一次，环境变量开关（`SOURIN_WIN_NOSHADOW=0` 的对照实验）
       *    在第一条 `WM_NCCALCSIZE` 上就会失效。
       *    `ResolveFramelessConfig()` 自带 `g_frameless_resolved` 幂等保护，
       *    重复调用无副作用。
       */
      ResolveFramelessConfig();
      if (g_no_shadow) {
        WINDOWPLACEMENT placement = {};
        placement.length = sizeof(WINDOWPLACEMENT);
        const BOOL placed = ::GetWindowPlacement(window, &placement);
        if (!placed || placement.showCmd != SW_SHOWMAXIMIZED) {
          /*
           * `rgrc[0]` 入参就是"系统建议的新窗口矩形"（屏幕坐标）。
           * **保持它不变**即"客户区 == 整个窗口" ⇒ 非客户区为 0。
           * 返回 0 告诉系统"我已经处理好了，别再用默认的非客户区"。
           *
           * ⚠️ 千万不要拿 `GetWindowRect()` 去覆盖 —— 本消息在窗口
           *    真正改尺寸**之前**发出，那时 `GetWindowRect` 还是**旧尺寸**，
           *    覆盖会把客户区钉死在旧值上（表现为 resize 后右下露出底色）。
           *    我第一版就是这么写的，被 `.probe/curprobe.ps1` 抓出来了。
           */
          return 0;
        }
      }
    }
    /*
     * ═══════════════════════════════════════════════════════════════════════
     * ★★★ 抢在插件之前处理 `WM_GETMINMAXINFO`
     *     —— 让「放大」保留任务栏（用户明确要求）
     * ═══════════════════════════════════════════════════════════════════════
     *
     * # 为什么必须在这里（与上面 `WM_NCCALCSIZE` **完全同一个原因**）
     *
     * 消息链（见上面那段长注释）：
     * ```text
     * WndProc（本函数）
     *   └─▶ that->MessageHandler()
     *         └─▶ FlutterWindow::MessageHandler()
     *               └─▶ flutter_controller_->HandleTopLevelWindowProc()
     *                     └─▶ ★ window_manager 插件的 top-level proc delegate
     * ```
     * ★ 我**第一版就写在了 `MessageHandler` 里**，实测**完全不生效**
     *   （`.probe/maximize_vs_workarea.py`：放大后仍是 2560x1440 = 整个显示器）
     *   —— 因为插件先拿到这条消息并 `return 0`，我们的 switch 根本收不到。
     *   ⇒ ★ 与 `WM_NCCALCSIZE` 是**同一个坑**，只是我踩了第二次。
     *
     * # 修法
     *
     * 把最大化矩形限制到**工作区**（`rcWork`）而不是整个显示器
     * （`rcMonitor`）。理由与完整推导见下面 `MessageHandler` 里
     * 那段被保留下来的注释（我把它留在原处，因为它解释了"为什么"）。
     */
    if (message == WM_GETMINMAXINFO) {
      auto* mmi = reinterpret_cast<MINMAXINFO*>(lparam);
      if (mmi != nullptr) {
        /*
         * ⚠️ 解析配置：本函数比 `MessageHandler` 更早执行，
         *    而 `IsFullscreenOnMonitor` 不依赖配置，但为了与
         *    上面 `WM_NCCALCSIZE` 的写法一致、并确保 `g_*` 已就绪，
         *    这里仍先调一次（自带幂等保护）。
         *
         * ⚠️⚠️ 这里**故意**继续用**窄**判据 `IsFullscreenOnMonitor()`，
         *    而**不是** `IsFilledOnMonitor()` —— 两者用途相反：
         * ```text
         * ApplyRoundedRegion() 问的是"该不该有圆角"
         *     ⇒ 放大与全屏**都**不该有 ⇒ 用宽判据 IsFilledOnMonitor ✓
         * 这里问的是"要不要把最大化矩形夹到工作区"
         *     ⇒ 只有**全屏**时不能夹（否则播放页全屏会露任务栏）
         *     ⇒ ★ 而"已放大"时**必须继续夹**（用户再次点最大化时仍要落在工作区）
         *     ⇒ 用窄判据 IsFullscreenOnMonitor ✓
         * ```
         * ★ 即：**同一个"是否铺满"的概念，在两处的正确答案不同** ——
         *   因为一处是"装饰（圆角）该不该画"，另一处是"尺寸该不该限制"。
         */
        ResolveFramelessConfig();
        if (!IsFullscreenOnMonitor(window)) {
          HMONITOR monitor =
              ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
          MONITORINFO mi = {};
          mi.cbSize = sizeof(MONITORINFO);
          if (monitor != nullptr && ::GetMonitorInfo(monitor, &mi) != 0) {
            const RECT& work = mi.rcWork;
            const RECT& mon = mi.rcMonitor;
            mmi->ptMaxPosition.x = work.left - mon.left;
            mmi->ptMaxPosition.y = work.top - mon.top;
            mmi->ptMaxSize.x = work.right - work.left;
            mmi->ptMaxSize.y = work.bottom - work.top;
          }
        }
      }
      /*
       * ⚠️⚠️ **不能直接 `return 0`** —— 必须**继续传给插件**！
       *
       * # 为什么（我第一版就是 `return 0`，那会引入一个回归）
       *
       * `window_manager` 插件在 `HandleTopLevelWindowProc` 里
       * **也**处理 `WM_GETMINMAXINFO`（`window_manager_plugin.cpp` L190-205）：
       * ```cpp
       * } else if (message == WM_GETMINMAXINFO) {
       *   if (minimum_size_.x != 0)
       *     info->ptMinTrackSize.x = minimum_size_.x * pixel_ratio_;
       *   ...  ptMaxTrackSize 同理 ...
       *   result = 0;
       * }
       * ```
       * 而 `shell.dart` L305 设了 `minimumSize: Size(200, 200)`
       * ⇒ ★ 若我们在这里 `return 0`，插件**收不到**这条消息
       *   ⇒ `ptMinTrackSize` **保持系统默认（很小）**
       *   ⇒ **用户可以把窗口拖到比 200x200 更小** ⇒ **最小尺寸限制失效**（回归）
       *
       * # 正确的做法
       *
       * ```text
       * 我们只改 ptMaxSize / ptMaxPosition（最大化目标矩形）
       * 然后把消息**继续往下传** ⇒ 插件照常填 ptMinTrackSize / ptMaxTrackSize
       * ⇒ 两边的字段**互不重叠**，各改各的，天然不冲突
       * ```
       * ★ 与上面 `WM_NCCALCSIZE` 的**关键区别**：
       *   那里我们必须 `return 0`，因为插件会对 `rgrc[0]` 做 `-= 8` 的**破坏性**
       *   修改，且我们改的是**同一个字段**（互相覆盖）。
       *   而这里我们改的是 `ptMaxSize`，插件改的是 `ptMinTrackSize` /
       *   `ptMaxTrackSize` —— **字段不同，可以共存**。
       *   ⇒ ★ **"同一个消息"不等于"同一个字段"** ——
       *     要不要拦下，取决于**是否改同一个字段**，不是取决于消息类型。
       */
    }
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  ResolveFramelessConfig();

  switch (message) {
    /*
     * ═══════════════════════════════════════════════════════════════
     * ★★★ 去掉非客户区 —— 这是四角"方框"的真正根因修复
     * ═══════════════════════════════════════════════════════════════
     *
     * # 为什么必须有这一条
     *
     * 实测：`WINDOW 1280x800` 而 `CLIENT 1264x792` —— 差 **16x8**。
     * `window_manager` 的 `TitleBarStyle.hidden` **没有**去掉
     * `WS_THICKFRAME`，那 8px 边框由 **DWM 画成不透明的方形**。
     * Dart 的 `ClipRRect` 只能裁客户区，管不到它 →
     * 用户看到"圆角内容 + 外面一圈方框"，深色下就是**黑角**。
     *
     * # 返回 0 是什么意思
     *
     * `WM_NCCALCSIZE` 的 `wParam=TRUE` 时，系统问"非客户区占多少"。
     * 返回 0 且**不修改** `lParam` 里的 `RECT`，就等于宣告
     * **非客户区尺寸为 0** → 客户区 == 整个窗口矩形 →
     * 那圈方框消失，只剩 Flutter 自绘的抗锯齿圆角。
     *
     * 这是 Electron(`frame:false`) / Chromium / Qt 无边框窗口的通行做法。
     *
     * ⚠️ 为什么保留 `WS_THICKFRAME`（不改成 `WS_POPUP`）：
     *    `WS_THICKFRAME` 是"可缩放 + 贴靠(Aero Snap)"的来源。
     *    直接去掉它窗口就不能拖边缩放了 —— 交互能力倒退。
     *    这里保留它、只把"非客户区尺寸"归零，缩放热区由下面的
     *    `WM_NCHITTEST` 自己实现（代价见那段注释）。
     *
     * ⚠️ 为什么在最大化时要**放过**（走 DefWindowProc）：
     *    最大化时 Windows 会把窗口撑到比工作区大一圈（藏边框），
     *    如果我们强行归零，窗口会溢出屏幕、内容被裁掉。
     */
    case WM_GETMINMAXINFO: {
      /*
       * ⚠️⚠️ 这条分支**不会被走到** —— 但**不是**因为我们在 `WndProc` 里
       *     `return 0`（那是**错的**，见下），而是因为：
       * ```text
       * WndProc 里我们改完 ptMaxSize/ptMaxPosition 后，把消息**继续下传**
       *   ⇒ that->MessageHandler(...)          ← 会走到这里
       *     ⇒ FlutterWindow::MessageHandler()
       *       ⇒ flutter_controller_->HandleTopLevelWindowProc()
       *         ⇒ ★ window_manager 插件（它 **return 0**，表示"已处理"）
       * ```
       * ★ 即：**插件**替我们终结了这条消息（它要填 `ptMinTrackSize` /
       *   `ptMaxTrackSize`），而不是我们。
       *
       * ⚠️ 我第一版在 `WndProc` 里写的是 **`return 0`** ⇒ 那会**引入回归**：
       *    插件收不到消息 ⇒ `ptMinTrackSize` 保持系统默认
       *    ⇒ `lib\shell.dart:346` 的 `minimumSize: const Size(900, 600)`
       *    **失效**（用户能把窗口拖得比 900x600 更小）。
       *    ★ 2026-09-30 更正：这段注释原先写的是 `shell.dart` L305 的
       *      `Size(200,200)` —— 行号和数值都已过期，实测是上面这行。
       *    ⇒ 已改成"改完自己的字段就下传"。
       *
       * ★ 保留这段注释是因为它解释了"**为什么**要限制到工作区"，
       *   而实现放在 `WndProc` 里（否则插件先截走，这里收不到）。
       *   ★ 我第一版就写在这里，实测**完全不生效**（放大后仍是整屏）。
       *
       * ═══════════════════════════════════════════════════════════════════
       * ★★★ 「放大」必须**保留任务栏**（用户明确要求，2026-09-25）
       * ═══════════════════════════════════════════════════════════════════
       *
       * # 用户原话
       *
       * > 客户端全屏也不应该是全屏窗口,只是跟正常客户端,占满屏幕但是保留任务栏
       * > 叫**放大**,只有播放页才是全屏(不保留任务栏)
       *
       * 即两个动作必须**可区分**：
       * ```text
       * 客户端「放大/最大化」  ⇒ 占满屏幕但**保留任务栏**（= maximize）
       * 播放页「全屏」         ⇒ 连任务栏一起盖住（= fullscreen）
       * ```
       *
       * # 实测：改前「放大」**盖住了任务栏**（用户报的问题成立）
       *
       * `.probe/maximize_vs_workarea.py`（只用窗口/监视器矩形，不需要屏幕）：
       * ```text
       * 显示器 2560x1440   工作区 2560x1400   ⇒ 任务栏 40px
       * ① 普通    1280x800
       * ② 放大    2560x1440   ← ★ 覆盖整个显示器（含任务栏）
       * ③ 全屏    2560x1440   ← 与②**区分不开**
       * ```
       *
       * # 根因：runner **没有** `WM_GETMINMAXINFO` 处理
       *
       * ```text
       * 本文件 grep `WM_GETMINMAXINFO` / `MINMAXINFO` = **0 命中**
       * ⇒ 走 `DefWindowProc` ⇒ 系统给的默认最大化矩形是
       *   **整个显示器**（`rcMonitor`），不是**工作区**（`rcWork`）
       * ```
       * ★ 这在**标准带边框窗口**上通常不是问题（系统会自己让开任务栏），
       *   但本窗口是**无边框**的（`WS_CAPTION`/`WS_THICKFRAME` 被扒掉、
       *   `WM_NCCALCSIZE` 返回 0）⇒ 系统不再替我们让任务栏。
       *
       * # 修法（实现在 `WndProc`）
       *
       * ```text
       * ptMaxPosition = rcWork 左上（相对显示器）
       * ptMaxSize     = rcWork 尺寸
       * ```
       * ★ 只改**最大化**的目标矩形；`ptMinTrackSize` / `ptMaxTrackSize`
       *   一律**不动**（见下面"故意不改 ptMaxTrackSize"的理由）。
       *
       * ⚠️ **只在"非全屏"时限制**：播放页全屏走的是
       *    `windowManager.setFullScreen(true)`，它会自己把窗口铺满
       *    `rcMonitor`。若我们在全屏时也把最大化矩形压到 `rcWork`，
       *    全屏就会**露出任务栏** ⇒ 反而破坏用户要的区分。
       *    判据用 `IsFullscreenOnMonitor()`（与圆角那边**同一个判据**）。
       *
       * ⚠️ `MonitorFromWindow(MONITOR_DEFAULTTONEAREST)` 而不是
       *    `MonitorFromPoint(0,0)` —— 多显示器时"当前那块屏"才是对的，
       *    否则副屏最大化会跳到主屏的工作区。
       *
       * ⚠️ **故意不改 `ptMaxTrackSize`**（考虑过，否决）：
       *    它管的是"用户**手动拖边**能拖多大"。把它压到工作区会：
       *    ```text
       *    ① 用户再也不能把窗口拖到覆盖任务栏（用户没要求改这个）
       *    ② ★ 风险：播放页全屏要经过一次 SetWindowPos 到 rcMonitor，
       *       若此刻窗口还是"非全屏"状态 ⇒ 这次 WM_GETMINMAXINFO
       *       可能把目标尺寸夹到工作区 ⇒ **全屏露任务栏**（反效果）
       *    ```
       *    ⇒ 本改动**只针对"点最大化按钮"**（`ptMaxSize`/`ptMaxPosition`），
       *      这是用户明确提的那一个动作。**最小改动**。
       *
       * ⚠️ 这里**故意用 `break` 而不是 `return 0`**（虽然按当前消息顺序
       *    这条分支不会被走到 —— 插件先拿到并 `return 0`）：
       *    ```text
       *    若将来消息顺序变了（比如插件改成不 return 0），这条分支就会活过来；
       *    而 `return 0` 会**再次掐掉插件** ⇒ 最小尺寸失效（就是上面那个回归）。
       *    ⇒ 用 `break` 走正常返回路径 ⇒ **即使它活过来也不会造成破坏**。
       *    ★ 判据：**对"当前不可达"的分支，也要选一个"万一可达时是安全的"写法。**
       *    ```
       */
      break;
    }

    case WM_NCCALCSIZE: {
      /*
       * ★ 诊断：确认这条消息**真的**到达了我们的处理函数
       *
       * 第一次实测时非客户区仍然是 16x8，说明"返回 0"没有生效。
       * 但没有日志就无法区分是"没收到消息"还是"收到了但被别处覆盖"。
       * 所以这里把到达次数与判定结果打出来（前几次）。
       */
      static int g_ncc_count = 0;
      g_ncc_count++;

      WINDOWPLACEMENT placement = {};
      placement.length = sizeof(WINDOWPLACEMENT);
      const BOOL placed = ::GetWindowPlacement(hwnd, &placement);

      if (g_ncc_count <= 10) {
        ::printf("[ALPHA] NCCALCSIZE#%d wp=%llu frameless=%d noshadow=%d placed=%d showCmd=%u\n",
                 g_ncc_count, static_cast<unsigned long long>(wparam),
                 g_frameless ? 1 : 0, g_no_shadow ? 1 : 0, placed ? 1 : 0,
                 static_cast<unsigned>(placement.showCmd));
        ::fflush(stdout);
      }

      /*
       * ★ `g_no_shadow` 也要走这条路
       *
       * 去投影的样式组合里已经去掉了 `WS_CAPTION`，但**光去掉样式位
       * 还不够** —— 系统仍会按缓存的 NC 度量留一圈非客户区。
       * 实测：只去 `WS_THICKFRAME` 时 `dwmMargin` 仍是 L=7 T=0 R=7 B=7；
       * 必须配合"非客户区归零"，`ExtFrameBounds` 才与 `GetWindowRect`
       * 重合、投影才真正消失。
       */
      if (!g_frameless && !g_no_shadow) {
        break;  // 两条路都关掉了（对照实验用）
      }
      /*
       * 最大化：必须还回系统默认的非客户区处理，否则
       * "最大化后内容超出屏幕"（Win10 上表现为任务栏被盖住）。
       */
      if (placed && placement.showCmd == SW_SHOWMAXIMIZED) {
        break;
      }

      /*
       * ═══════════════════════════════════════════════════════════════
       * ★★★ 两种 wParam 都要处理 —— 这是第一轮没生效的真正原因
       * ═══════════════════════════════════════════════════════════════
       *
       * 第一版只在 `wParam == TRUE` 时返回 0，`wParam == FALSE` 时
       * `break`（交给 DefWindowProc）。实测日志（`.probe/aa-fl2/out.txt`）：
       * ```text
       * #1..#4  nonclient=0x0    ← 归零成功
       * #5      nonclient=16x8   ← ★ 窗口被 resize 到 1280x720 之后
       * #8      nonclient=16x8   ← 之后一直是 16x8
       * ```
       * 中间**没有**新的 `NCCALCSIZE` 打印 —— 说明变回 16x8 的那次
       * 走的是 `wParam == FALSE` 分支：`DefWindowProc` 按
       * `WS_THICKFRAME` 把 8px 边框**又加了回来**。
       *
       * # 两种 wParam 的区别（Win32 文档）
       *
       * ```text
       * wParam=TRUE   窗口**正在被创建/尺寸变化**，lParam 指向 NCCALCSIZE_PARAMS
       *               → 返回 0 = 非客户区为 0
       * wParam=FALSE  窗口**尺寸已经变了**（如 WM_SIZE 路径），lParam 指向 RECT
       *               → 返回 0 同样表示"客户区覆盖整个窗口"
       * ```
       * 两者都归零，才能真正做到"客户区 == 窗口矩形"。
       */
      if (wparam == TRUE) {
        /*
         * ═══════════════════════════════════════════════════════════════
         * ★★★ 必须**显式改写** `rgrc[0]`，不能只 `return 0`
         *     （任务⑪ revision 6）
         * ═══════════════════════════════════════════════════════════════
         *
         * # 症状（用户三条反馈，其实是**同一个** bug）
         *
         * ```text
         * style = 0x140B0000   CAPTION=0 BORDER=0 THICKFRAME=0   ← 样式层面已无边框
         * dwmMargin = 0,0,0,0                                    ← DWM 也不认边框
         * ★ 但 window=1280x800  client=1264x792  nonclient=16x8  ← ★★ 客户区仍小 16x8
         * ```
         * 一个 bug，三个用户可见症状：
         * ```text
         * 左 8px → 露出窗口底色（用户说的"阴影"）
         * 右 8px → 挤掉自绘关闭按钮（用户说的"残缺，没完整到边边"，实测红块宽 38 而非 46）
         * 下 8px
         * 上 0px → 所以用户说"左右下都有，上没有"  ★ 逐边完全吻合
         * ```
         *
         * # `wParam=TRUE` 的语义（`NCCALCSIZE_PARAMS`）
         *
         * ```text
         * 输入：rgrc[0] = 系统**建议的新窗口矩形**（尺寸变化时是"将要变成"的那个）
         *       rgrc[1] = 变化前的窗口矩形
         *       rgrc[2] = 变化前的客户区矩形
         * 要求：把 rgrc[0] 改成"我要的客户区"，然后 return 0
         * ```
         * "客户区 == 整个窗口" ⇒ `rgrc[0]` 保持**等于窗口矩形**即可。
         *
         * ⚠️⚠️ 这里**绝对不要**用 `GetWindowRect()` 去覆盖它 ——
         *      `WM_NCCALCSIZE` 是**在窗口真正被改尺寸之前**发出的，
         *      此刻 `GetWindowRect` 拿到的是**旧尺寸**。
         *      用它覆盖 → 客户区被钉在旧尺寸上 → 窗口变大而画面不跟着变大
         *      （表现为右侧/底部露出窗口底色，且**resize 后更明显**）。
         *      我第一版就是这么写的，被 `.probe/curprobe.ps1` 抓出来了。
         *      正确做法：**什么都不用改**，`rgrc[0]` 本来就是窗口矩形。
         *
         * # 那为什么原来"只 return 0"不生效？
         *
         * 见 `ApplyFramelessStyle()` 里关于
         * `WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX` 的说明 ——
         * 那三个位会让系统在**非客户区度量**里塞回一圈标题栏边框，
         * 而"度量"发生在 `WM_NCCALCSIZE` 之后、由缓存决定。
         * 光靠这里返回 0 顶不住，必须**同时**把那些样式位去掉。
         */
        (void)lparam;  // rgrc[0] 已是窗口矩形，保持不变即是"零非客户区"
        return 0;
      }
      /*
       * wParam == FALSE：lParam 是 RECT（客户区）。
       * 把它设成**整个窗口**，等于非客户区为 0。
       * 注意坐标要转成**客户区坐标**（左上为 0,0）。
       */
      RECT* client_rect = reinterpret_cast<RECT*>(lparam);
      if (client_rect != nullptr) {
        RECT wr = {};
        ::GetWindowRect(hwnd, &wr);
        client_rect->left = 0;
        client_rect->top = 0;
        client_rect->right = wr.right - wr.left;
        client_rect->bottom = wr.bottom - wr.top;
      }
      return 0;
    }

    /*
     * ★ 自己做缩放热区（因为非客户区归零后，系统不知道该在哪儿缩放）
     *
     * # 为什么必须补这一条
     *
     * `WM_NCCALCSIZE` 返回 0 之后，系统认为没有边框 →
     * 鼠标移到窗口边缘**不再**出现缩放光标，拖边也缩不了。
     * 那等于"为了圆角丢掉了缩放"——不能接受。
     *
     * 所以这里手工判断鼠标是否落在边缘 [kResizeBorderDip] 像素内，
     * 是就返回对应的 `HTxxx`，把缩放还回去。
     *
     * ⚠️ 与 Flutter 的冲突：Flutter 自己也要处理鼠标事件。
     *    热区只取**最外 6 逻辑像素**，标题栏/按钮都在更内侧，
     *    不会抢掉正常点击。
     */
    case WM_NCHITTEST: {
      /*
       * ★ 两种情况都要自己做热区
       *
       * ```text
       * g_frameless   非客户区归零 → 系统不知道边框在哪
       * g_no_shadow   去掉了 WS_THICKFRAME → 系统**没有**可缩放边框了
       *               （只有 WS_CAPTION 的窗口是**固定尺寸**窗口）
       * ```
       * 后者是本轮新增：为了消除 DWM 投影去掉了 `WS_THICKFRAME`，
       * 代价就是系统的缩放边框一起没了 —— 这里把它补回来，
       * 否则用户会从"有阴影"变成"不能拖边缩放"，那是功能倒退。
       */
      if (!g_frameless && !g_no_shadow) {
        break;
      }
      /*
       * 最大化时不做热区 —— 否则屏幕四边会变成"缩放边"，
       * 用户想点任务栏/别的窗口就会误触。
       */
      WINDOWPLACEMENT placement = {};
      placement.length = sizeof(WINDOWPLACEMENT);
      if (::GetWindowPlacement(hwnd, &placement) &&
          placement.showCmd == SW_SHOWMAXIMIZED) {
        break;
      }

      RECT wr = {};
      ::GetWindowRect(hwnd, &wr);
      const POINT cursor = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};

      const double scale = GetWindowScale(hwnd);
      const int border =
          static_cast<int>(kResizeBorderDip * (scale > 0 ? scale : 1.0));

      const bool left = cursor.x < wr.left + border;
      const bool right = cursor.x >= wr.right - border;
      const bool top = cursor.y < wr.top + border;
      const bool bottom = cursor.y >= wr.bottom - border;

      if (top && left) return HTTOPLEFT;
      if (top && right) return HTTOPRIGHT;
      if (bottom && left) return HTBOTTOMLEFT;
      if (bottom && right) return HTBOTTOMRIGHT;
      if (left) return HTLEFT;
      if (right) return HTRIGHT;
      if (top) return HTTOP;
      if (bottom) return HTBOTTOM;

      // 其它位置交回系统（客户区里的点击照常给 Flutter）
      break;
    }

    /*
     * ═══════════════════════════════════════════════════════════════════
     * ★★★ 自己设缩放光标 —— 用户「鼠标移到边边没出现可调节状态」的修复
     *     （任务⑪ revision 6 A 项）
     * ═══════════════════════════════════════════════════════════════════
     *
     * # 用户原话
     *
     * > 我鼠标移动到边边,并没有出现 可调节的鼠标状态
     *
     * # 为什么 `WM_NCHITTEST` 返回 `HTLEFT` 还不够（重要教训）
     *
     * 编排者之前用 `SendMessage(WM_NCHITTEST)` 测到
     * `左=HTLEFT 右=HTRIGHT 上=HTTOP 下=HTBOTTOM`，据此认为"缩放已修好"——
     * **那个结论是错的**。`HTLEFT` 只告诉系统"这里是缩放边"，
     * 而用户**看得出**能缩放，靠的是**光标形状**，光标由 `WM_SETCURSOR` 决定。
     *
     * 实测（`.probe/orch_cursor_probe.ps1`）：
     * ```text
     * ③ hit-test:  左=HTLEFT(10) 右=HTRIGHT(11)          ← 看起来对
     * ④ 发 WM_SETCURSOR(HTLEFT) → 返回 0 (FALSE = 未处理) ← ★ 真问题
     *    发完后光标 = 仍是 IDC_ARROW (0x10009)
     * ```
     * 返回 `FALSE` 说明**连 `DefWindowProc` 都没走到** ——
     * 而正常应由它把光标设成 `IDC_SIZEWE`。
     *
     * 为什么会这样：窗口类注册时（见 `RegisterWindowClass`）
     * ```cpp
     * window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);   // 永远箭头
     * ```
     * 全项目**没有**任何 `WM_SETCURSOR` 处理、没有 `SetCursor`、
     * 也没有 `IDC_SIZEWE/SIZENS`。加上我们的 `WM_NCHITTEST`
     * 是**直接 `return HTLEFT`**（不经过 `DefWindowProc`），
     * 于是没有任何一环去设那个光标。
     *
     * # 修法
     *
     * 自己在 `WM_SETCURSOR` 里按 hit-test code 设光标。
     *
     * ⚠️ `HTCLIENT` 必须**交回**（`break` → `DefWindowProc`）：
     *    Flutter 在客户区里自己管光标（文本上是 I 型、按钮上是手型），
     *    我们若在这里强行设箭头，会把 Flutter 的光标覆盖掉。
     *
     * ⚠️ 非缩放区同样 `break`（交回系统）—— 标题栏/边缘的其它
     *    光标行为保持系统默认。
     */
    case WM_SETCURSOR: {
      /*
       * 只处理"在客户区上移动鼠标"的通知。
       * `LOWORD(lparam)` = 当前鼠标下的 hit-test code。
       */
      if (LOWORD(lparam) == HTCLIENT) {
        break;  // ★ 客户区交给 Flutter，别抢它的光标
      }
      // 2026-10-05: 映射表抽成 ResizeCursorFor()，与子窗口子类化共用一份，
      //   避免"父窗口设 A、子窗口设 B"两套光标不一致
      LPCWSTR cursor_id = ResizeCursorFor(LOWORD(lparam));
      if (cursor_id == nullptr) {
        break;
      }
      ::SetCursor(::LoadCursor(nullptr, cursor_id));
      return TRUE;  // ★ 已处理 —— 必须返回 TRUE，否则系统会再设一次
    }

    /*
     * ⚠️ 这里曾有一个 `WM_SYSCOMMAND` 处理（给 `Alt+F4` 兜底），
     *    它是为"扒掉 `WS_SYSMENU`"服务的 —— 而那个改动已回滚
     *    （见 `ApplyFramelessStyle()` 里的说明：16x8 的根因是
     *       `window_manager` 插件收缩 `rgrc[0]`，与 `WS_SYSMENU` 无关）。
     *    既然 `WS_SYSMENU` 还在，`Alt+F4` 由系统正常处理，
     *    这里就该交回默认逻辑 —— 不要凭空多一处行为改动。
     */

    /*
     * ★ 自愈定时器（见 `SelfHealClientArea` 上方的长注释）
     *
     * `window_manager` 在它自己的调用栈里把非客户区改回 16x8，
     * 且**不发** `WM_NCCALCSIZE`（实测）。所以在随后几个消息周期里
     * 主动校正；有界次数，之后自动停掉，不长期占用 CPU。
     */
    case WM_TIMER: {
      if (wparam != kSelfHealTimerId) {
        break;  // 不是我们的定时器，交回系统
      }
      g_self_heal_tick++;
      SelfHealClientArea(hwnd);
      if (g_self_heal_tick >= kSelfHealTicks) {
        ::KillTimer(hwnd, kSelfHealTimerId);
      }
      return 0;
    }

    case WM_DESTROY:
      ::KillTimer(hwnd, kSelfHealTimerId);
      /*
       * ★ 窗口投影：主窗口销毁时同步销毁阴影窗口
       *
       * ⚠️ 必须在这里（而不是 `Destroy()` 里）——
       *    因为 `WM_DESTROY` 时 `hwnd` 还有效，可以安全解绑；
       *    而阴影窗口若留到最后会成为"孤儿窗口"（屏幕上留一块阴影）。
       */
      sourin::WindowShadow::Instance().Detach();
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      /*
       * ═══════════════════════════════════════════════════════════════
       * ★★★ 让 Flutter 表面铺满**整个窗口** —— 修「背景色块」（任务⑰④）
       * ═══════════════════════════════════════════════════════════════
       *
       * # 用户报的现象
       *
       * > 背景还是有色块,左右跟下面
       *
       * # 根因（实测，`.probe/c4.ps1` 枚举子窗口）
       *
       * ```text
       * top-level HWND  1280x800
       * child   class='F' (Flutter 表面) 1264x792
       * 差额                              16 x 8   ← 左8 右8 下8 上0
       * ```
       * `GetClientArea()` 返回的是**客户区**。客户区比窗口小 16x8
       *（Win10 那圈**隐形**缩放边框：左 8 + 右 8 + 下 8，上边 0）——
       * 所以 `child_content_` 只铺了 1264x792，剩下的一圈**没有画面覆盖**，
       * 露出的是**窗口背景**（`WindowFrame` 推的 `backdrop` 色）。
       *
       * ⚠️ 这就是为什么用户说的是「**左右跟下面**」而不是"一圈"：
       *    `16x8` 的分布正好是 左8 / 右8 / 下8 / 上0 —— **逐边完全对上**。
       *
       * # 修法：用**窗口矩形**（而不是客户区）来摆子窗口
       *
       * ```text
       * 改前  MoveWindow(child, rect.left, rect.top, cr.right, cr.bottom)
       *       → 子窗口只盖客户区，边上露窗口底
       * 改后  MoveWindow(child, 0, 0, window_w, window_h)
       *       → 子窗口盖满整个窗口，那圈"色块"被画面本身覆盖
       * ```
       * 这是安全的：`g_no_shadow` 走的正是"客户区 == 整个窗口"这条路
       *（`WM_NCCALCSIZE` 返回 0），此时**窗口矩形与客户区本就该重合**；
       * 就算系统又把它算回 16x8，我们按窗口矩形摆也只会**多盖**那 8px，
       * 不会裁掉任何内容。
       *
       * ⚠️ 只在 `g_no_shadow`（即我们要"无边框 + 铺满"）时这么做；
       *    否则保持上游原语义（子窗口严格等于客户区）。
       */
      RECT rect = GetClientArea();
      if (g_no_shadow && child_content_ != nullptr) {
        /*
         * ★★★ 坐标要用**客户端坐标系**，且必须减去非客户区偏移
         *
         * # 我第一版写错了什么（实测抓出来的，别再犯）
         *
         * 第一版直接把 `rect.left=0, rect.top=0, right=窗口宽, bottom=窗口高`
         * 交给 `MoveWindow`。看起来"铺满整个窗口"，实测却**左边仍有 8px 色块**：
         * ```text
         * WindowRect 1280x800   ClientRect 1264x792   FLUTTER-CHILD 1280x800
         *   ↑ 子窗口确实被设成 1280x800 了，**但位置不对**
         * 像素（PrintWindow）：
         *   x=0..7  #eef0f6  ← ★ 8px backdrop 还在
         *   x=8..   #ffffff
         * ```
         * 原因：**子窗口的坐标是相对父窗口的「客户区」原点的**，
         * 而客户区原点并不在窗口原点 —— 它被那圈隐形边框推开了 8px：
         * ```text
         * 窗口原点 (0,0)  ──8px──▶  客户区原点 (0,0)
         * ```
         * 所以 `x=0`（客户区坐标）= 窗口坐标 `x=8` →
         * 左边 0..7 那 8px **永远没有子窗口覆盖**。
         *
         * # 正确做法：把客户区原点偏移量减掉
         *
         * ```text
         * ncLeft = 客户区原点在屏幕上的 x − 窗口在屏幕上的 x   （本例 = 8）
         * ncTop  = 客户区原点在屏幕上的 y − 窗口在屏幕上的 y   （本例 = 0）
         * 子窗口左上角（客户区坐标）= (−ncLeft, −ncTop)
         * 子窗口大小               = 窗口宽 × 窗口高
         * ```
         * 这样它在**窗口坐标系**里正好是 `(0,0)-(W,H)`，把那 8px 也盖住。
         *
         * ⚠️ 用 `ClientToScreen` 求偏移，而不是硬编码 8 ——
         *    该值随 DPI / 主题 / 最大化状态变化。
         */
        POINT client_origin = {0, 0};
        ::ClientToScreen(hwnd, &client_origin);
        RECT wr2 = {};
        ::GetWindowRect(hwnd, &wr2);

        rect.left = -(client_origin.x - wr2.left);
        rect.top = -(client_origin.y - wr2.top);
        rect.right = rect.left + (wr2.right - wr2.left);
        rect.bottom = rect.top + (wr2.bottom - wr2.top);
      }
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      /*
       * ★ 尺寸一变就重新应用透明/圆角
       *
       * # 为什么必须放在这里（用户明确要求"全屏时也要正确"）
       *
       * 进/出全屏走的是 `window_manager` 的 `SetFullScreen`，它会
       * `SetWindowPos(..., SWP_FRAMECHANGED)` 并改 `GWL_STYLE` ——
       * `SWP_FRAMECHANGED` 会让 DWM **重新计算**窗口框架，
       * 我们之前设的 blur-behind 就没了（表现为"全屏后又变回黑角"）。
       *
       * `region` 方案同理：区域坐标是**绝对像素**，窗口一大就必须重算，
       * 否则圆角区域还停在旧尺寸上。
       */
      ApplyWindowAlpha(hwnd);
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      /*
       * ★ 激活/取消激活时也重新应用一次
       *
       * `window_manager` 的 `Focus()` / `Show()` 会 `SetForegroundWindow`
       * 并改窗口样式（`SetAsFrameless` → `SetWindowPos(SWP_FRAMECHANGED)`），
       * `SWP_FRAMECHANGED` 之后 DWM 重算框架 → 玻璃效果被冲掉。
       * 激活是"窗口真正露面"的时刻，在这里补一次最稳。
       */
      ApplyWindowAlpha(hwnd);
      /*
       * ★ 投影也要跟着 —— 激活时窗口可能刚从最小化恢复，
       *   位置/尺寸都变了（`Update()` 内部会处理"不可见则隐藏"）。
       */
      sourin::WindowShadow::Instance().Update();
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;

    /*
     * ★ 合成状态变化（开关"透明效果"、远程桌面、显卡驱动重启等）
     *
     * DWM 合成被关掉时 `DwmEnableBlurBehindWindow` 就失效了 ——
     * 此时窗口四角会回到"黑角"。重新应用一次，让它恢复时立刻生效。
     */
    case WM_DWMCOMPOSITIONCHANGED:
      ApplyWindowAlpha(hwnd);
      return 0;

    /*
     * ═══════════════════════════════════════════════════════════════════════
     * ★★★ task-54：抢在**尺寸改变之前**清掉过期的圆角 region
     * ═══════════════════════════════════════════════════════════════════════
     *
     * # 用户报的现象（原话）
     *
     * > 3.播放器页面进入全屏,四个角还是白色的底
     *
     * # 根因（0.9 ms/次的所有权采样，`.probe/t54_flash_owner.py`）
     *
     * 下面那条 `WM_WINDOWPOSCHANGED` 是**尺寸已经改完之后**才到的，
     * 所以从窗口态切进全屏时存在**一帧**：
     * ```text
     * GetWindowRect = (0,0 2560x1440)                          ← 已经是全屏尺寸
     * GetWindowRgn  = COMPLEXREGION，rgnbox = (0,0,1280,800)   ← 还是旧尺寸的圆角
     * ```
     * 实测（`t54_flash_owner.py`，Enter 之后 0.9 ms 采一次）：
     * ```text
     * t(ms)  rect               region                  rgnbox           TL    TR    BL    BR
     *     0  (0,0 2560x1440)  COMPLEXREGION(clipped)  (0,0,1280,800)  OTHER OTHER OTHER OTHER
     *    81  (0,0 2560x1440)  ERROR                   (0,0,0,0)       MINE  MINE  OTHER OTHER
     *   107  (0,0 2560x1440)  ERROR                   (0,0,0,0)       MINE  MINE  MINE  MINE
     * ```
     * `OTHER` = `WindowFromPoint` 判定那个像素**不属于本窗口**
     * （`WindowFromPoint` 会把 window region 算进去）⇒ 它属于背后的窗口/桌面。
     * ⇒ 那一帧里四角、以及旧 1280x800 之外的**整片**区域都不是我们的
     *   ⇒ 用户看到"白色的底"。
     *
     * # 为什么在 `WM_WINDOWPOSCHANGED` 里清来不及
     *
     * 消息顺序是：
     * ```text
     * WM_WINDOWPOSCHANGING → 系统真正改尺寸 → WM_WINDOWPOSCHANGED
     * ```
     * ⇒ 在 `CHANGED` 里清，那一帧**已经画出去了**。
     *
     * # 修法
     *
     * 在 `CHANGING` 里**预判**"改完之后会不会铺满"，会就先清掉。
     * ⚠️ 预判必须用 `lParam` 里**即将生效**的矩形 —— 这条消息到达时
     *    `GetWindowRect()` 还是旧值，而旧值**恰好**是"不铺满"
     *    ⇒ 拿 `IsFilledOnMonitor()` 去问必然得到 false，
     *      这正是"明明有守卫却还是白角"的原因。
     *
     * # ⚠️ 三个必须做对的点
     *
     * ```text
     * ① SWP_NOMOVE / SWP_NOSIZE 时，lParam 里对应字段是【无意义的垃圾值】，
     *    必须用当前 rect 的对应分量补上。
     *    （插件进全屏的第 2 次 SetWindowPos 就带 SWP_NOMOVE。）
     * ② 必须与 ApplyRoundedRegion() 用【同一个】容差判据
     *    （= RectFillsMonitor()）—— 否则会出现"预判说不铺满、
     *    尺寸改完之后又说铺满"的自相矛盾，region 被反复清/设 ⇒ 四角闪烁。
     * ③ SetWindowRgn 自身可能**再**送一条 WM_WINDOWPOSCHANGING
     *    ⇒ 必须防重入，否则递归。
     * ```
     *
     * ⚠️ 这条**只**清 region，不碰 Dart 侧 —— `WindowFrame` 的
     *    `_filled` / `isWindowFullscreen()` 是另一半（那里已经是对的，
     *    见 `lib/ui/widgets/window_frame.dart` 的 `[WINDOWFRAME#]` 诊断）。
     */
    case WM_WINDOWPOSCHANGING: {
      auto* pos = reinterpret_cast<WINDOWPOS*>(lparam);
      if (pos == nullptr) {
        break;
      }
      /*
       * ★ 防重入：下面的 `SetWindowRgn` 可能**再**送一条
       *   `WM_WINDOWPOSCHANGING` 过来，不拦就是无限递归。
       *   用静态变量而不是成员：本函数是静态的，
       *   而这里只需要回答"当前是否正处理中"。
       */
      static bool in_preclear = false;
      if (in_preclear) {
        break;
      }
      /*
       * ⚠️ `SWP_NOSIZE` ⇒ 尺寸不变 ⇒ "改完之后会不会铺满" = "现在会不会铺满"。
       *    而如果现在就是铺满的，region 早就被清掉了 ⇒ 无事可做。
       *    全屏态下的纯移动 / 激活 / 置顶都会走这条，必须能**零开销**跳过。
       */
      if ((pos->flags & SWP_NOSIZE) == 0) {
        RECT cur = {};
        ::GetWindowRect(hwnd, &cur);
        RECT next = cur;
        if ((pos->flags & SWP_NOMOVE) == 0) {
          next.left = pos->x;
          next.top = pos->y;
        }
        next.right = next.left + pos->cx;
        next.bottom = next.top + pos->cy;
        if (WillFillOnMonitor(hwnd, next)) {
          in_preclear = true;
          if (ClearRoundedRegionIfAny(hwnd)) {
            ::printf(
                "[REGION] pre-size clear (about to fill %ldx%ld) "
                "-> no stale rounding\n",
                next.right - next.left, next.bottom - next.top);
            ::fflush(stdout);
          }
          in_preclear = false;
        }
        /*
         * ★ 尺寸变化**在途**（本帧还没落地）=> 给阴影布防一段**有界**的逐帧重同步。
         *   实测（.probe/t51_result.md 4.1 (2)）：最大化/还原时阴影会整段停在旧
         *   矩形上（最差 800px，逐样本比对自身恒为 0 变化）——更新路径根本没被
         *   触发过，因为尺寸落地晚于触发它的那次消息。这里是最早能知道「即将
         *   变尺寸」的地方（next 已经算好了），所以从这里布防。
         *   ★ 有界：kResyncTicks 拍后自动 KillTimer；重复进入只续期不重复布防。
         *   ★ 阴影被 SOURIN_WIN_SHADOW=0 关掉、或首帧未就绪时，这里是两次指针
         *     判断，零开销（不会碰 SetTimer）。
         */
        sourin::WindowShadow::Instance().NotifySizeChangeInFlight();
      }
      break;
    }

    /*
     * ⚠️ 覆盖"最大化/还原"这类**不触发 WM_SIZE** 的尺寸变化
     *     （少数路径下 window_manager 只改 GWL_STYLE + SetWindowPos，
     *      WM_SIZE 可能被 SWP_NOSIZE 吃掉）。
     */
    case WM_WINDOWPOSCHANGED:
      ApplyWindowAlpha(hwnd);
      /*
       * ═══════════════════════════════════════════════════════════════════
       * ★★★ 投影跟随（这是"阴影是静态的"那句话的落点）
       * ═══════════════════════════════════════════════════════════════════
       *
       * `WM_WINDOWPOSCHANGED` 覆盖了**所有**位置/尺寸变化：
       * ```text
       * 拖动      → 位置变
       * 缩放      → 尺寸变（同时触发 WM_SIZE）
       * 最大化    → 两者都变（且可能不触发 WM_SIZE，见上）
       * 贴靠      → 同最大化
       * ```
       * ⇒ 只在这里调一次 `Update()` 就能覆盖全部情况。
       *
       * ⚠️ `Update()` 内部有"尺寸没变就复用位图"的短路 ——
       *    拖动时每帧都会进这里，但**高斯模糊只在 resize 时重算**
       *    （这是性能关键：模糊 800x600 约 6ms，绝不能每帧跑）。
       */
      sourin::WindowShadow::Instance().Update();
      break;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  /*
   * ★ 同 `WM_SIZE`：让 Flutter 表面铺满**整个窗口**（修任务⑰④ 的「背景色块」）
   *
   * 这里是最早的一次摆放（引擎刚建好 surface）。若只用客户区，
   * 就会留下 16x8 的裸窗口底色（左8/右8/下8）—— 即用户报的"左右跟下面有色块"。
   *
   * ⚠️ 坐标必须减去**非客户区偏移**（详见 `WM_SIZE` 里那段长注释）：
   *    子窗口坐标是相对**客户区原点**的，而客户区原点被那圈隐形边框
   *    推开了 8px。直接写 `(0,0)` 会让左边 8px 仍然露出来（我第一版就栽在这）。
   */
  if (g_no_shadow) {
    POINT client_origin = {0, 0};
    ::ClientToScreen(window_handle_, &client_origin);
    RECT wr = {};
    ::GetWindowRect(window_handle_, &wr);

    frame.left = -(client_origin.x - wr.left);
    frame.top = -(client_origin.y - wr.top);
    frame.right = frame.left + (wr.right - wr.left);
    frame.bottom = frame.top + (wr.bottom - wr.top);
  }

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
