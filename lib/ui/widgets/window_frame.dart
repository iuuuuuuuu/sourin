// ═══════════════════════════════════════════════════════════════════════
//  窗口外框 —— 圆角 + 圆角外**填主题色**
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户指出（2026-09-24）
//
// > 然后四个角也不圆润
//
// 实测（`PrintWindow` 抓图 + 逐像素扫描）：
// ```text
// 左上角 14x14：
//   y= 0 |       +######|     ← 从 y=0 就是实心，**完全没有圆角**
//   ...
//   y=13 |       +######|
// ```
// 四个角都是直角。
//
// # 为什么 Windows 10 上没圆角
//
// 原版是 Tauri（WebView2），靠 **CSS `border-radius`** 画圆角
// （`base.css` L73 的 `#app`），需要**四条同时到位**：
// ```text
// | 1 | transparent: true       | 窗口透明         | 缺了圆角外是不透明底 |
// | 2 | shadow: false           | 去掉窗口阴影     | 缺了窗口比客户区大 8px |
// | 3 | WebView2 底色 (0,0,0,0) | 画布透明         | 缺了圆角外露白底 |
// | 4 | CSS border-radius       | **画可见的圆角** | 缺了边缘是台阶 |
// ```
// Flutter 侧没有 WebView 底色这一层，但有等价的第 3/4 条：
// **把整个应用包进 `ClipRRect`** —— 同样是 Skia/Impeller 的光栅化器
// 做抗锯齿，而不是 Win32 `SetWindowRgn` 的硬裁剪。
//
// 原版明确否决过 `SetWindowRgn`：
// > 它是二值裁剪（Win10 不给它抗锯齿）……
// > 实测：有 `SetWindowRgn` 时 `x0..x12` 洋红 → `x13` 界面，
// > 中间**零个过渡像素**；去掉它之后对角线上 **26 个过渡像素**（平滑）
//
// ⚠️ **Windows 10（本机 Build 19045）没有原生圆角 API**
//    （`DWMWA_WINDOW_CORNER_PREFERENCE` 要 Win11 22000+）。
//    所以必须走"自绘 + 透明窗口"这条路 —— 与原版同一条路。
//
// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 2026-09-25 任务 AD：用户报的「深色主题白角 / 浅色主题黑角」
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 现在深色主题有白底四个角,浅色主题有黑底四个角,这也是bug
//
// # 取证（`lib/ad_diag_probe.dart`，让 Flutter 自己交图，不看屏幕）
//
// 用 `RepaintBoundary.toImage()` 把 **Flutter 自己合成的那张图**导出来
// （带 alpha）—— 不受锁屏影响、不受别的窗口遮挡影响：
// ```text
// 结构                    四角 alpha       四角 RGB
// ① WindowFrame+ColoredBox   0,0,0,0        10,10,10   ← 与 shell.dart 同构
// ② 去掉 ClipRRect           255            10,10,10
// ③ 只有 ColoredBox          255            10,10,10
// ```
// ★ **圆角外的 alpha = 0** —— Flutter 认为那里是**透明**的。
//   也就是说：**圆角外那圈白/黑根本不是 Flutter 画的**，
//   而是**窗口背景**（`window_manager` 的
//   `SetWindowCompositionAttribute(ACCENT_ENABLE_TRANSPARENTGRADIENT)`）
//   在 Flutter 表面**之外**填的。
//
// # 为什么是"与主题相反"的（这正是用户说的线索）
//
// ```text
// 窗口背景 = SetWindowCompositionAttribute 的 DWM 着色
//          = 用**系统**主题（注册表 AppsUseLightTheme）算的
// 应用主题 = 用户选的（dsh.theme，三态）
// ⇒ 两者**不同源**：用户在应用里选深色时，系统仍是浅色
//   → 深色应用 + 浅色窗口底 = **白角**
//   反之亦然
// ```
// 实测本机：`AppsUseLightTheme = 1`（系统浅色），
// 而 `.probe/testdata/ui-prefs.json` 里 `dsh.theme = "dark"` ——
// **正好相反**，所以四角是白的。
//
// # 修法：把圆角**外面**那圈自己画成主题色
//
// 既然 alpha=0 那块最终由**窗口背景**填充，而窗口背景我们控制不了
// （四条 DWM 路已实测全是 no-op，见 `windows/runner/win32_window.cpp`），
// 那就换个方向：**别让 alpha=0 露出来** ——
// 在 `ClipRRect` **外面**垫一层同色（`floorColor`）的圆角方块：
// ```text
// Stack
//  ├ Positioned.fill → ColoredBox(floorColor)   ← 圆角外是它（与主题同色）
//  └ ClipRRect → child                          ← 圆角内是内容
// ```
// 这样圆角外的不透明像素是**我们自己画的**，与主题**同源**，
// 结构上不可能再"与主题相反"。
//
// ⚠️ 如实说明：这**不是**"真透明圆角"（圆角外透出桌面）。
//    在 Win10 + Flutter 上做不到，理由见
//    `windows/runner/win32_window.cpp` 顶部那 90 行注释（四条路实测无效）。
//    这里做到的是用户明确要的那一条：**四角与主题一致**。

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/window_bounds.dart';

/// 窗口圆角半径
///
/// 原版 CSS 用 12px。这里用 10px —— 稍保守：
/// Flutter 的裁剪在 DPI 缩放下与 CSS 的取整方式不同，
/// 10px 在各缩放下都稳。
const double kWindowCornerRadius = 10;

/// ★★★ 窗口投影 —— **已撤销（2026-09-25）**
///
/// # 用户原话
///
/// > 这次你改的没有了,但是不是应该加个浅色的边框或者阴影的,
/// > 用来区分跟其他浅色客户端的重叠
/// > 像 qq 客户端这种边缘模糊阴影,之前的是实体的非常难看
///
/// # ★★★ 为什么自绘"内侧投影"是错的（实测，不是推测）
///
/// ```text
/// 我曾在窗口【内侧】画一圈渐变（内容内缩 6px）来模拟投影。
/// 用户反馈：「现在就是一圈实色的边缘，根本就不是阴影」
///
/// 真实抓图（.probe/RING-real2.png，上边中点垂直扫描）：
///   y=-1: #FFFFFF   ← 窗口外（桌面）
///   y=+0: #E5E7ED   ← ★ 突然跳到我们的色
///   y=+5: #D5D7DD   ← ★ 最暗（比内容 #E8EBF3 暗 19 级）
///   y=+16: #E8EBF3  ← 回到内容色
/// ⇒ 窗口最外 5~16px 是一圈【比内容暗 19 级】的实色带
/// ```
///
/// ★ 根本原因（结构性的，不是参数问题）：
/// ```text
/// 真投影必须画在窗口【外面】（占用窗口外的像素）。
/// 而画在【内侧】时，那一圈被窗口边界【硬切】——
/// 从外面看就是"一圈比内容暗的实色边框"，永远不可能是"浮起来的阴影"。
/// ⇒ 这个方案从结构上就不可能对，调参数也救不回来。
/// ```
///
/// # ★★★ 那 DWM 阴影为什么拿不到（三层实测，全部排除）
///
/// ```text
/// ① 我们的窗口拿不到
///    DwmGetWindowAttribute(EXTENDED_FRAME_BOUNDS) → 外扩 (0,0,0,0)
///    即使把 WS_CAPTION + WS_THICKFRAME 加回来（实测 CAPTION=Y THICK=Y）
///    仍然 (0,0,0,0)
///
/// ② ★★★ 全新创建的标准窗口也拿不到（决定性实验）
///    创建一个全新的 WS_OVERLAPPEDWINDOW 窗口（CAPTION=Y THICK=Y）：
///      DWM 外扩 = (0,0,0,0)
///      窗口外像素 = 249 249 249 ... （均匀，无渐变）
///    ⇒ ★★ 不是我们的窗口样式问题，是【系统不给任何窗口画阴影】
///
/// ③ 系统设置核实
///    VisualFXSetting = 2   ← 「调整为最佳性能」（关闭窗口阴影）
///    SPI_GETDROPSHADOW = 1 （这个开关是开的，但被上面那条覆盖）
///    DwmIsCompositionEnabled = True（DWM 合成是开的）
///
/// ④ 曾以为"Deepseek 窗口有阴影"（外扩 -8,-8,-8,-8）—— ★ 那是误判：
///    它窗口外像素 = 255 均匀（无渐变）
///    "外扩 -8" 是因为它的窗口矩形本身在 (-8,-8)（超出屏幕），不是阴影
/// ```
///
/// # 结论
///
/// ```text
/// · 这台机器上 DWM 不给任何窗口画阴影（系统级设置 VisualFXSetting=2）
/// · 自绘"内侧投影"结构上不可能对（被窗口边界硬切）
/// ⇒ ★ 两条路都堵死 ⇒ 不加投影（保持现状：无边界）
/// ```
///
/// ⚠️ 若用户希望有边界，**唯一可行**的方向是让用户改系统设置
///    （「视觉效果」→ 勾上「显示窗口阴影」），或换 Win11
///    （`DWMWA_WINDOW_CORNER_PREFERENCE` 在 Win11 上有原生圆角+阴影）。
///    本机 `DwmGetWindowAttribute(33)` 返回 hr=0x80070057（Win10 无此 API）。
///
/// ★ 保留这个常量是为了让 `WindowFrame.shadowColor` 的调用方
///   （`shell.dart`）有个明确的可选项；**默认不传 ⇒ 不画**。
const double kWindowShadowWidth = 0;

/// 投影不透明度 —— 见 [kWindowShadowWidth]：**当前不启用投影**
const double kWindowShadowOpacity = 0.0;


/// 当前是否**全屏**（窗口铺满它所在的显示器）—— ★ 修「全屏四角白底」
///
/// # 用户报的现象（2026-09-25）
///
/// > 全屏播放的时候,四个角有白色的底
///
/// # 两层根因（都要修，缺一不可）
///
/// ```text
/// ① C++ 层：`ApplyRoundedRegion()` 没有全屏判断
///    ⇒ 全屏时仍把窗口裁成圆角
///    ⇒ 那四块**不属于窗口** ⇒ 露出窗口背后的桌面
///    实测：全屏 2560x1440 时 GetWindowRgn=3，TL/TR/BL/BR 全 = 0（区域外）
///
/// ② Dart 层（本文件）：`Stack` 底层那层 `ColoredBox(backdrop)`
///    **铺满整个窗口矩形**
///    ⇒ 就算 C++ 不再裁圆角，四角也会被它填成 #EEF0F6（浅色主题 = 白）
///    实测（`SOURIN_WIN_ALPHA=none` + 全屏）：
///      TL=#eef0f6 TR=#eef0f6 BL=#eef0f6 BR=#eef0f6   ← ★ 正是"白色的底"
/// ```
///
/// ★ 所以**只改 C++ 不够**：预测实验已经证明，清掉 region 之后
///   四角仍然是我们自己的 backdrop 色。两层都必须按全屏来关掉圆角。
///
/// # 判据为什么用"窗口尺寸 == 显示器尺寸"
///
/// ```text
/// 全屏 = 铺满屏幕 ⇒ 不存在"窗口边界" ⇒ 不该有圆角，也不该有圆角外的垫色
/// ```
/// 用尺寸比较而不是"猜"哪个页面在全屏：
/// · 不依赖任何业务状态（播放页/直播页都可能全屏）
/// · 与 C++ 侧 `IsFullscreenOnMonitor()` **用同一个判据**，两层不会打架
///
/// ⚠️ `MediaQuery.sizeOf` 是**逻辑像素**，`display.size` 是**物理像素**，
///    所以要先乘 `devicePixelRatio` 再比；容差 2 逻辑像素（DPI 取整）。
///
/// # ★★★ 这是**度量判据**，不是结构性判据 —— 必须能显式覆盖
///
/// 它比较的是**同一个 `View`** 的 `physicalSize` 与 `display.size`
/// ⇒ 在**任何"窗口恰好与显示同尺寸"的环境**里都会返回 true。
/// `flutter_test` **恰好就是**这种环境（两者来自同一个 `TestFlutterView`）
/// ⇒ **差值恒为 0** ⇒ 恒为 true ⇒ 组件短路 ⇒ 断言找不到 `ColoredBox`/`ClipRRect`。
///
/// ⚠️ 这**不是**"测试环境的巧合"，而是**度量判据的结构性缺陷**：
///    任何"窗口 == 屏幕"的场合（含真机上某些情况）都会被误判为全屏。
/// ⇒ 所以 [WindowFrame.isFullscreen] 允许调用方用**结构性来源**
///    （如 `windowManager` 的全屏事件）直接告知状态；本函数只是**回退**。
bool isWindowFullscreen(BuildContext context) {
  final view = View.of(context);
  final logical = view.physicalSize / view.devicePixelRatio;
  final screen = view.display.size / view.devicePixelRatio;
  return (logical.width - screen.width).abs() <= 2 &&
      (logical.height - screen.height).abs() <= 2;
}

/// ★ task-54 对照开关 —— **修复后仍保留**（它现在是回归探针，不是临时诊断）
///
/// ```text
/// SOURIN_WF_DEPENDS_ON_SIZE=0  ⇒ 故意**不**注册尺寸依赖（模拟修复前的行为）
/// 未设置 / =1                  ⇒ 正常（注册尺寸依赖）★ 默认
/// ```
/// # 为什么保留一个"能让 bug 复现"的开关
///
/// 本次 bug 的根因是 **`WindowFrame` 不依赖窗口尺寸 ⇒ resize 时不重建
/// ⇒ `isWindowFullscreen()` 从未被重新求值**。而修复的核心动作就是
/// "在 build 里读一次 `MediaQuery`"（注册依赖）。
///
/// ⚠️ 那个读取**看起来是多余的**（`View.of(context)` 已经能拿到尺寸），
///    所以**后人极可能"清理"掉它** ⇒ bug **静默复发**。
/// ⇒ ★ 这个开关的作用是：**让那个读取变成"可被检验的"** ——
///   设 `=0` 就能立刻复现白角，证明那一行**不是冗余**。
///   （`.probe/t54_dep_ab.py` 就是跑这个 A/B 的。）
///
/// ★ 用**运行时环境变量**（不是 `--dart-define`）⇒ 同一个二进制跑两次即可，
///   不必为了对照重新编译（重编会引入其它变量，污染对照）。
/// ★ 这也是铁律 204 的实践：**诊断/开关必须可切换** ——
///   否则"带诊断时正常、去掉就坏"这类 bug 无法被发现。
final bool kDependsOnSize =
    Platform.environment['SOURIN_WF_DEPENDS_ON_SIZE'] != '0';

/// 把整个应用裁成圆角窗口，并把**圆角外**填成 [backdrop]
///
/// 放在 `MaterialApp.builder` 的**最外层** —— 必须包住标题栏 +
/// 内容 + 底栏，否则圆角只作用于一部分。
///
/// [backdrop] 必须传**与当前主题同源**的底色
/// （`shell.dart` 传的是 `AppTheme.floorColor(brightness)`）。
///
/// ⚠️ 别把 [backdrop] 和「推给系统的窗口背景色」搞混（2026-09-25 澄清）：
/// ```text
/// [backdrop]                     Flutter 自己画的，铺满窗口矩形（Stack 底层）
///                                ⇒ 传 transparent = 圆角外露出窗口背景（白/黑）
/// windowManager.setBackgroundColor(...)  推给 DWM 的 tint
///                                ⇒ ★ 必须传 transparent（否则圆角处出现方块）
/// ```
/// 两者**要求相反**，因为作用层不同：
/// 前者在 Flutter 层（圆角外要有个不透明的主题色垫着），
/// 后者在 DWM 合成层（它会把 region 裁掉的那块填色 = 用户报的"假圆角方块"）。
/// 详见 `_syncWindowBackground()` 的注释。
class WindowFrame extends StatefulWidget {
  const WindowFrame({
    super.key,
    required this.child,
    required this.backdrop,
    this.shadowColor,
    this.isFullscreen,
  });

  final Widget child;

  /// 圆角**外面**那一圈的颜色 —— 应当与主题地板色同源
  final Color backdrop;

  /// ★ 投影颜色（`null` = 不画投影）
  ///
  /// 只用到它的**明度** —— 实际绘制时会用 `withValues(alpha:)` 逐层降低。
  /// 调用方按当前 [Brightness] 传入（浅色给深色投影、深色给纯黑投影），
  /// 这样明暗切换时投影跟着变。
  ///
  /// 见 [kWindowShadowWidth] 上方那段：**系统不给阴影**（本机
  /// `VisualFXSetting = 2`「最佳性能」），所以必须自绘。
  final Color? shadowColor;

  /// ★ 窗口当前是否**全屏**（`null` = 由 [isWindowFullscreen] 按尺寸推断）
  ///
  /// # 为什么要有这个显式参数（而不是只靠尺寸推断）
  ///
  /// 尺寸推断是**度量判据** —— 它在"窗口恰好与显示同尺寸"的任何环境里
  /// 都会返回 true（`flutter_test` 就是这种环境，见 [isWindowFullscreen]）。
  /// 度量判据会**系统性误判**，所以调用方应当用**结构性来源**告知真实状态
  /// （例如 `windowManager` 的全屏事件、`_toggleFullscreen` 里那个 `next`）。
  ///
  /// ```text
  /// null  ⇒ 回退到尺寸推断（生产路径目前就是这条）
  /// true  ⇒ 全屏：不画 backdrop、不裁圆角（见 build()）
  /// false ⇒ 非全屏：正常画圆角 + 圆角外垫 backdrop
  /// ```
  ///
  /// ⚠️ 生产侧的 [WindowFrame] 调用点在 `shell.dart`，本次**未改动**它，
  ///    所以生产行为与之前**完全一致**（走的还是尺寸推断）。
  ///    这个参数是为"由 `windowManager` 驱动"预留的**真实语义入口**，
  ///    **不是**给测试开的特例后门。
  final bool? isFullscreen;

  /// ★ task-54 回归钩子：`build()` 被调用的累计次数
  ///
  /// # 为什么需要它（而不是"看行为"）
  ///
  /// 本次 bug 的本质是 **`build()` 没有被重新调用** —— 而"没被调用"这件事
  /// **没有可观察的行为差异**（界面就停在旧状态）。所以必须有**计数器**，
  /// 否则 `test/window_fullscreen_rebuild_test.dart` 无法区分：
  /// ```text
  /// ① 重建了、但判据仍 false  ⇒ 判据/来源的问题
  /// ② 根本没重建              ⇒ ★ 依赖注册的问题（本次的真根因）
  /// ```
  /// 这也正是 `.probe/t54_dep_ab.py` 判读的依据（build 1 次 vs 2 次）。
  ///
  /// ⚠️ 只读、只自增，**不注册任何依赖**（否则它自己就会变成"参与者"，
  ///    见铁律 204：诊断代码必须与被测路径等价）。
  @visibleForTesting
  static int debugBuildCount = 0;

  @override
  State<WindowFrame> createState() => _WindowFrameState();
}

class _WindowFrameState extends State<WindowFrame> with WindowListener {
  /// 已经推给操作系统的窗口背景色（`null` = 还没推过）
  static Color? _pushedBg;

  /// ★★★ task-54【2】：**结构性**的"窗口已铺满"状态
  ///
  /// # 为什么必须有它（【1】不够）
  ///
  /// 【1】（让 build 依赖尺寸）只解决**"判据没被重新求值"**。
  /// 而**放大（最大化）**状态下，**即使重新求值，尺寸判据也是 false**：
  /// ```text
  /// 放大：窗口 2560x1400，显示器 2560x1440 ⇒ |1400-1440| = 40 > 2 ⇒ false
  ///       ★ 而用户**要求**保留任务栏（40px）⇒ 这个差永远存在
  /// ⇒ 度量判据在"放大"状态下**结构性失效**，不是容差调大能救的
  /// ```
  /// 实测（`.probe/t54_states.py`，真实屏幕 BitBlt）：
  /// ```text
  /// 放大 2560x1400：inset=3..16 四角 = #e8ebf3 / #ffffff ⇒ ★ 白角 4/4
  /// 全屏 2560x1440：inset=0..16 四角全暗              ⇒ 白角 0/4
  /// ```
  ///
  /// # 判据：**"窗口是否铺满可用区域"**（不是"是否等于显示器"）
  ///
  /// ```text
  /// 普通窗口 ⇒ 有边界 ⇒ 该有圆角 + 圆角外垫色
  /// 放大     ⇒ 铺满【工作区】⇒ 没有"窗口外的桌面"⇒ 不该有圆角
  /// 全屏     ⇒ 铺满【显示器】⇒ 同上
  /// ```
  /// ⇒ 所以条件是 **`isMaximized || isFullScreen`**，来源是
  ///   `windowManager` 的**事件**（结构性），不是尺寸推断（度量）。
  ///
  /// ⚠️ 这里**不**去问 `windowManager.isMaximized()`（异步、要 await、
  ///    而且 build 里不能 await）—— 而是**订阅事件**维护一个同步的布尔值。
  /// ⚠️ 类型是 **`bool?`**（三态），不是 `bool`：
  /// ```text
  /// null  ⇒ **还不知道**（首次异步查询尚未返回）⇒ 回退到尺寸推断
  /// true  ⇒ 已铺满（放大 或 全屏）      ⇒ 不画圆角/垫色
  /// false ⇒ 普通窗口                    ⇒ 正常画圆角 + 垫色
  /// ```
  /// ★ 用 `null` 而不是 `false` 作初值是**必要的**：若初值给 `false`，
  ///   那么"放大状态下首次 build"会先按 `false` 画一次圆角/垫色，
  ///   等异步查询返回才纠正 ⇒ **用户会看到一帧白角闪烁**。
  bool? _filled;

  @override
  void initState() {
    super.initState();
    _syncWindowBackground();
    // ★ 订阅结构性事件（同时覆盖 放大/还原 与 全屏/退出全屏）
    windowManager.addListener(this);
    _refreshFilled();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  /// 向 `windowManager` 同步一次"是否铺满"（异步，但结果写进同步字段）
  ///
  /// ⚠️ `setState` 只在**值真的变了**时才调 —— 否则会与 build 形成回环
  ///    （每次 build 都 setState ⇒ 无限重建）。
  Future<void> _refreshFilled() async {
    try {
      final maximized = await windowManager.isMaximized();
      final full = await windowManager.isFullScreen();
      final next = maximized || full;
      if (!mounted) return;
      if (next != _filled) {
        setState(() => _filled = next);
      }
    } catch (_) {
      // 非桌面平台 / 插件缺失 ⇒ 保持 false（退回尺寸推断）
    }
  }

  // ── WindowListener：结构性事件的落点 ──
  //
  // ★ 覆盖全部四种"铺满状态变化"：
  //   放大 / 还原  ⇒ onWindowMaximize / onWindowUnmaximize
  //   全屏 / 退出  ⇒ onWindowEnterFullScreen / onWindowLeaveFullScreen
  //   以及 onWindowResized（部分路径下事件可能只发这个）
  @override
  void onWindowMaximize() => _refreshFilled();
  @override
  void onWindowUnmaximize() => _refreshFilled();
  @override
  void onWindowEnterFullScreen() => _refreshFilled();
  @override
  void onWindowLeaveFullScreen() => _refreshFilled();
  @override
  void onWindowRestore() => _refreshFilled();

  // ── ★★★ m13655 (B)：把「用户调好的窗口几何」记下来 ──
  //
  // # 为什么挂在**这两个**事件上
  //
  // ```text
  // 插件只在 WM_EXITSIZEMOVE 发事件（window_manager_plugin.cpp:216-225）：
  //   is_resizing_ ⇒ "resized"   ← 拖边框缩放结束
  //   is_moving_   ⇒ "moved"     ← 拖标题栏移动结束
  // ⇒ 一次拖拽手势**只发一次**，天然去抖，不需要自己做节流。
  //
  // ⚠️ 程序化的 SetWindowPos **不发**这两个事件（没有 WM_SIZING/WM_MOVING）
  //    ⇒ 启动时的还原不会把"还原出来的几何"再写回去一遍（无回环）。
  // ```
  //
  // ⚠️ 顺带：`onWindowResized` 里仍要 `_refreshFilled()` —— 覆盖
  //    "部分路径下只发 resized" 的情况（见上面那段注释）。
  @override
  void onWindowResized() {
    _refreshFilled();
    WindowBoundsStore.recordCurrent();
  }

  /// ★ m13655 (B)：移动结束 ⇒ 记位置
  ///
  /// ⚠️ `window_manager` 的 `WindowListener` 里 `onWindowMoved` 标了
  ///    `@platforms macos,windows`（`window_listener.dart:37`）—— 其它平台
  ///    不会发，`recordCurrent()` 自己有 `isSupported` 兜底。
  @override
  void onWindowMoved() => WindowBoundsStore.recordCurrent();

  @override
  void didUpdateWidget(WindowFrame old) {
    super.didUpdateWidget(old);
    if (old.backdrop != widget.backdrop) {
      _syncWindowBackground();
    }
  }

  /// 把窗口背景同步给操作系统那一层
  ///
  /// # ★★★ 2026-09-25：改成推**透明** —— 这是「假圆角」的真凶
  ///
  /// 用户原话：
  /// > 客户端假圆角,四个角都有图1这个直角边,这个需要优化
  ///
  /// # 真凶（读 `window_manager` 插件源码定位，不是猜的）
  ///
  /// `window_manager-0.5.2/windows/window_manager.cpp:662` 的
  /// `SetBackgroundColor()` 内部**就是**在调 `SetWindowCompositionAttribute`：
  /// ```cpp
  /// bool isTransparent = (A == 0 && R == 0 && G == 0 && B == 0);
  /// int32_t accent_state = isTransparent ? ACCENT_ENABLE_TRANSPARENTGRADIENT
  ///                                      : ACCENT_ENABLE_GRADIENT;
  /// ACCENTPOLICY policy = {accent_state, 2, (A<<24)+(B<<16)+(G<<8)+R, 0};
  /// SetWindowCompositionAttribute(hWnd, &data);
  /// ```
  /// 而这里原来推的是 `widget.backdrop`（`#EEF0F6`，**不透明**）⇒ 走
  /// `ACCENT_ENABLE_GRADIENT` 分支 ⇒ **DWM 把"被 `SetWindowRgn` 裁掉 /
  /// Flutter swapchain 没覆盖"的那块填成 `#EEF0F6`**。
  ///
  /// 于是圆角处是：桌面 → **一圈 `#EEF0F6` 方块**（DWM 填的）→ 内容。
  /// 那圈方块就是用户说的「四个角都有这个直角边」。
  ///
  /// 这条链解释了之前所有对不上的现象（实测记录）：
  /// ```text
  /// · 换 GDI class brush   → 无效（不是 GDI 画的，是 DWM 合成层）
  /// · 强制重绘             → 无效（同上）
  /// · 隐藏窗口             → 变黑（DWM 不再合成它）
  /// · region 半径越大方块越大 → 被裁面积越大，tint 填得越多
  /// ```
  ///
  /// # 修法：推 `Colors.transparent`（ARGB 全 0）
  ///
  /// 插件检测到全 0 ⇒ 走 `ACCENT_ENABLE_TRANSPARENTGRADIENT` ⇒ `nColor = 0`
  /// ⇒ **DWM 不再着色** ⇒ 那圈方块消失 ⇒ 只剩 Dart `ClipRRect` 的
  /// 抗锯齿圆弧（已实测：它**确实**有 14 个中间值 = 真 AA）。
  ///
  /// 实测对照（品红垫底，`.probe/` 里代理跑的）：
  /// ```text
  ///                   角上真透明   假圆角方块   内容还在
  /// GRADIENT(原)          0          44          ✓
  /// TRANSPARENTGRADIENT   0           0          ✓   ← ★ 选它
  /// BLURBEHIND           44           0          ✗ 整窗透明（内容没了）
  /// ```
  ///
  /// ⚠️ 原来那行的作用（"第二道防线"：防 AA 边缘漏出系统底色）现在由
  ///    `Stack` 里那层 `ColoredBox(backdrop)` 承担 —— 它铺满整个窗口矩形，
  ///    AA 的半透明像素合成到的就是它，不会漏到窗口背景。
  ///
  /// ⚠️ 只在不同色时才调（`_pushedBg` 去重）：`builder` 会频繁重建，
  ///    每次重建都发一次 MethodChannel 是浪费。
  /// ⚠️ 失败不抛：插件不可用（极端情况）不该让窗口画不出来。
  void _syncWindowBackground() {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    /*
     * ★★★ 推【透明】—— 消除「假圆角方块」（2026-09-25）
     *
     * 去重键固定成 transparent：不能再拿 `widget.backdrop` 去重，
     * 否则主题切换时会误判"色没变"而跳过（其实推的永远是同一个值）。
     *
     * ⚠️⚠️ 曾经被误回退过一次，记录教训（防止再次发生）：
     *   2026-09-25 08:4x，编排者把这里改回 `widget.backdrop`，
     *   理由是"实测窗口整个变透明了、内容也没了"。
     *   **那个实测是无效的** —— 量到的 (0,72,126) = `#00487E`
     *   正是**锁屏底色**（代理在同一天独立记录过这个值）。
     *   即：当时屏幕是锁屏状态，`ImageGrab` 抓到的是锁屏画面，
     *   不是应用窗口。**基于无效测量回退了一个正确的修复。**
     *   ⇒ 教训：验证前必须确认"窗口真的在画"（见 `.probe/VERIFY-LESSONS.md` 铁律②）。
     *
     * 为什么推透明是对的（代理用受控 A/B + 仪器自检对照验证）：
     * ```text
     * 二进制 A（推透明）  app's own state bg = #000000
     * 二进制 B（推 backdrop） app's own state bg = #eef0f6
     * CONTROL gradient #EEF0F6  bg = #eef0f6   ← ★ 仪器能看见被涂的背景
     * CONTROL transparentgrad  bg = #000000
     * ```
     * `CONTROL` 那两行证明仪器不是瞎的 —— 它能分清 `#EEF0F6` 和 `#000000`。
     * 角部方块像素数（代理测，品红垫底）：
     * ```text
     * GRADIENT（推 backdrop）  角上我们的 tint = 44 px  ← 就是用户看到的方块
     * TRANSPARENTGRADIENT      角上我们的 tint =  0 px  ← ★ 推透明的效果
     * BLURBEHIND               0 px，但整窗透明（内容也没了）← 已证伪
     * ```
     */
    const pushed = Color(0x00000000);
    if (_pushedBg == pushed) return;
    _pushedBg = pushed;
    unawaited(
      windowManager.setBackgroundColor(pushed).catchError((Object _) {
        // 插件不可用 —— 忽略。`_pushedBg` 已更新，避免每帧重试刷屏。
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    /*
     * ⚠️ 只在 Windows / macOS 裁圆角
     *
     * ```text
     * Android  全屏窗口，屏幕自己就是圆角 —— 再裁会露出黑边
     * Linux    GTK 自己管窗口装饰
     * ```
     * 原版也是这么分平台的（`base.css` 的"各平台差异"表）。
     */
    if (!Platform.isWindows && !Platform.isMacOS) return widget.child;

    /*
     * ★★★ 全屏时**不画 backdrop、不裁圆角**（2026-09-25）
     *
     * 修用户报的「全屏播放的时候,四个角有白色的底」。
     * 完整推导见 [isWindowFullscreen] 上方的注释（两层根因）。
     *
     * 这里直接返回 `child`：
     * ```text
     * · 没有 ColoredBox(backdrop) ⇒ 四角不再被填成主题地板色（浅色主题 = 白）
     * · 没有 ClipRRect            ⇒ 内容铺满整屏，不会被裁掉四角
     * ```
     * ⚠️ 必须与 C++ 侧的 `IsFullscreenOnMonitor()` **同时**生效 ——
     *    只关一层的话，另一层仍会留下角上的异色（实测过）。
     *
     * ⚠️ 判据**优先级**（task-54 修正）：
     * ```text
     * ① widget.isFullscreen（调用方显式传入）—— 最优先，结构性
     * ② _filled（windowManager 事件维护）  —— ★ 覆盖"放大"，结构性
     * ③ isWindowFullscreen(context)         —— 尺寸推断，兜底（度量）
     * ```
     * ★ ② 是本次新增的**关键**：**放大状态下 ③ 结构性失效** ——
     *   放大后窗口 = 工作区（2560x1400），显示器 = 2560x1440，
     *   差 40px（= 任务栏，而用户**要求**保留它）⇒ 永远 > 容差 ⇒ 永远 false。
     *   实测（`.probe/t54_states.py`，真实屏幕）：放大时四角白角 **4/4**。
     */
    /*
     * ⚠️⚠️ 必须用 **`||` 组合**，不能写成 `widget.isFullscreen ?? _filled ?? 尺寸推断`！
     *
     * # 我第一版就是那样写的，实测**全屏仍然白角**（`.probe/t54_player_states.py`）
     *
     * 日志铁证：
     * ```text
     * #5 filled=false physical=2560x1440 display.size=2560x1440 => fullscreen=false
     * ```
     * ★ 明明 `physical == display`（尺寸判据**应该** true），却得到 false ——
     *   因为 `??` 只在**左操作数为 null** 时才走右边，
     *   而 `_filled` 一旦被异步查询写成 **`false`**（非 null！）
     *   ⇒ **短路** ⇒ 右边的 `isWindowFullscreen()` **永远不会被求值** ✓
     *
     * ⇒ 正确语义是 **"或"**：
     * ```text
     * 显式传入         ⇒ 用它（最权威）
     * 否则 _filled==true 或 尺寸推断成立 ⇒ 已铺满
     * ```
     * 三态各司其职：
     * ```text
     * widget.isFullscreen != null ⇒ 调用方说了算，直接返回
     * _filled == true             ⇒ 结构性来源认定已铺满（覆盖"放大"）
     * 尺寸推断                     ⇒ 兜底（覆盖 _filled 还没查到 / 查错的情况）
     * ```
     */
    final fullscreen = widget.isFullscreen ??
        ((_filled ?? false) || isWindowFullscreen(context));
    /*
     * ★★ 诊断输出（task-54，**已转为常驻**）—— 打印"全屏判据"的全部输入
     *
     * 它回答了"播放页全屏那一刻判据看到什么"，而且是**唯一**能区分
     * "值不对"与"没被重新求值"的证据（见下面的 build 计数）。
     * ★ 保留它：它是"重建有没有发生"的外部可观测证据，
     *   也是 `.probe/t54_player_states.py` 判读的依据。
     */
    /*
     * ═══════════════════════════════════════════════════════════════════════
     * ★★★ 修 task-54：**必须注册"窗口尺寸"依赖**（这一行是修复的核心）
     * ═══════════════════════════════════════════════════════════════════════
     *
     * # 用户报的现象
     *
     * > 3.播放器页面进入全屏,四个角还是白色的底
     *
     * # 根因（同一个二进制的 A/B 实测确证，`.probe/t54_dep_ab.py`）
     *
     * ```text
     * 组 dep0（不读 MediaQuery）：[WINDOWFRAME#] 行数 = 1
     *     #1 physical=1280x800 mq=null => fullscreen=false
     *     真实屏幕四角 TL=#eef0f6 TR=#eef0f6  ⇒ ★ 白角 2/4（复现用户现象）
     * 组 dep1（读  MediaQuery）：[WINDOWFRAME#] 行数 = 2
     *     #2 physical=2560x1440 mq=2560x1440 => fullscreen=true
     *     真实屏幕四角 TL=#202023 TR=#735945 ⇒ 白角 0/4（正常）
     * ```
     * ★ **build 次数 1 vs 2 就是铁证** —— 它把"值对不对"与
     *   "**有没有被重新求值**"分开了：
     * ```text
     * `View.of(context)`           = 静态查表（platformDispatcher._views[id]）
     *                              ⇒ ★ 不注册任何 InheritedWidget 依赖
     *                              ⇒ 窗口 resize **不会**调度本 widget 重建
     * `MediaQuery.sizeOf(context)` = dependOnInheritedWidgetOfExactType
     *                              ⇒ ★ 注册依赖 ⇒ resize **会**重建
     * ```
     * 而 `isWindowFullscreen()` **只在 build 时**被求值一次
     * ⇒ ★ **判据的数学一直是对的，但它从未在全屏之后被重新调用过**。
     *
     * # ⚠️ 这一行**看起来冗余、实际不能删**
     *
     * `View.of(context)` 已经能拿到尺寸，所以"再读一次 MediaQuery"像是多余的。
     * ⚠️ 后人（或静态检查）极可能把它当冗余删掉 ⇒ **bug 静默复发**。
     * ⇒ 所以：① 这一行有**明确注释**说明它是修复而非冗余；
     *        ② `SOURIN_WF_DEPENDS_ON_SIZE=0` 可**立刻复现**白角
     *           （`.probe/t54_dep_ab.py` 跑的就是这个 A/B）；
     *        ③ `test/window_fullscreen_rebuild_test.dart` 有断言锁住"必须重建"。
     *
     * ⚠️ 铁律 204：**诊断代码必须与被测路径等价**。
     *    本次我加的第一版诊断**读了 MediaQuery** ⇒ 它自己注册了依赖 ⇒
     *    **把 bug 掩盖了**（我当时还以为"重建后就好了"）。
     *    ⇒ 这正是"带诊断时正常、去掉诊断就坏"的指纹。
     *    ⇒ 现在这行**不是诊断**，而是**修复本身**。
     */
    final mq = kDependsOnSize ? MediaQuery.maybeSizeOf(context) : null;
    final view = View.of(context);
    final logical = view.physicalSize / view.devicePixelRatio;
    final screen = view.display.size / view.devicePixelRatio;
    /*
     * ★ 注意：`Size` 的 toString 是 "Instance of 'Size'"（不可读）⇒ 必须取 .width/.height
     *
     * ★★ 同时打印 `MediaQuery` 尺寸与 `View` 尺寸 —— 两者**来源不同**：
     *    `mq` 来自布局层（resize 会更新且会触发重建），
     *    `view.physicalSize` 来自引擎视图层（静态查表）。
     *    ⇒ ★ 对照它们就能区分"值陈旧"与"树没重建"。
     */
    final diag = 'explicit=${widget.isFullscreen} filled=$_filled '
        'physical=${view.physicalSize.width.toInt()}x'
        '${view.physicalSize.height.toInt()} '
        'dpr=${view.devicePixelRatio} '
        'logical=${logical.width.toInt()}x${logical.height.toInt()} '
        'mq=${mq == null ? "null" : "${mq.width.toInt()}x${mq.height.toInt()}"} '
        'displayId=${view.display.id} '
        'display.size=${view.display.size.width.toInt()}x'
        '${view.display.size.height.toInt()} '
        'screen=${screen.width.toInt()}x${screen.height.toInt()} '
        '=> fullscreen=$fullscreen';
    /*
     * ★ 打印**每一次** build（带序号），而不是只在变化时打印。
     *
     * 为什么必须这样：上一版用"值变化才打印"去重，结果全屏前后**都只有 1 行**，
     * 于是**分不清**两种完全不同的情况：
     * ```text
     * ① 树**没重建** ⇒ 那行是旧的 ⇒ 根因在"重建没触发"
     * ② 树重建了、但**值没变** ⇒ 根因在"引擎不知道窗口变大了"
     * ```
     * 这两者的修法完全不同 ⇒ ★ 去重把关键信息**掩盖**了。
     * 带上 build 序号 + 不丢弃重复 ⇒ 能看出"到底重建了几次、每次看到什么"。
     */
    WindowFrame.debugBuildCount++;
    if (WindowFrame.debugBuildCount <= 60) {
      debugPrint('[WINDOWFRAME#${WindowFrame.debugBuildCount}] $diag');
    }
    if (fullscreen) {
      return widget.child;
    }

    /*
     * ★ 为什么是 `Stack` 而不是"直接给 ClipRRect 加背景色"
     *
     * `ClipRRect` 的裁剪发生在**它自己的 child 绘制时** ——
     * 给它套 `ColoredBox` 是**外面**的一层，仍然会被**外层的裁剪**
     * 影响；而且 `ClipRRect` 抗锯齿的边缘像素会与底色做 alpha 合成，
     * 得到的是"内容色 × 覆盖率 + 底色 × (1-覆盖率)"。
     * 用 `Stack` 把底色画在**下面**、裁剪内容画在**上面**，
     * 得到的就是同一个合成结果，且语义更清楚：
     * ```text
     * 底层  = 圆角外要显示的颜色（不裁剪，铺满）
     * 顶层  = 被裁成圆角的内容（圆角外完全不画）
     * ```
     *
     * ⚠️ 顺序不能反：反过来（先内容后底色）底色会把内容盖住。
     */
    /*
     * ═══════════════════════════════════════════════════════════════════
     * ★★★ 投影已撤销（2026-09-25）—— 见 [kWindowShadowWidth] 的完整记录
     * ═══════════════════════════════════════════════════════════════════
     *
     * 我曾在这里画一圈"内侧渐变投影"（内容内缩 6px）。
     * 用户实测反馈：「现在就是一圈实色的边缘，根本就不是阴影」
     *
     * 真实抓图（`.probe/RING-real2.png`，上边中点垂直扫描）：
     * ```text
     * y=-1: #FFFFFF   ← 窗口外（桌面）
     * y=+0: #E5E7ED   ← 突然跳到我们的色
     * y=+5: #D5D7DD   ← ★ 最暗（比内容 #E8EBF3 暗 19 级）
     * y=+16: #E8EBF3  ← 回到内容色
     * ```
     * ⇒ 窗口最外 5~16px 是一圈【比内容暗 19 级】的实色带
     *
     * ★ 结构性原因：真投影必须画在窗口**外面**；
     *   画在**内侧**时那一圈被窗口边界**硬切**，
     *   从外面看就是"一圈比内容暗的实色边框" —— 调参数救不回来。
     *
     * ★ 而 DWM 阴影本机拿不到（三层实测，全部排除）：
     * ```text
     * ① 我们的窗口：外扩 (0,0,0,0)；加回 CAPTION+THICKFRAME 仍 (0,0,0,0)
     * ② ★★★ 全新创建的标准窗口（WS_OVERLAPPEDWINDOW, CAPTION=Y THICK=Y）：
     *      外扩 (0,0,0,0)，窗口外像素 249 均匀（无渐变）
     *    ⇒ ★★ 不是我们的样式问题，是【系统不给任何窗口画阴影】
     * ③ VisualFXSetting = 2（「调整为最佳性能」← 关闭窗口阴影）
     * ```
     *
     * ⚠️ 若将来要恢复投影，**必须**先解决"画在窗口外"这个前提
     *    （需要窗口比内容大 + 那块区域真透明 —— 见 `win32_window.cpp`
     *      顶部记录的四条 DWM 路，目前都走不通）。
     *    在窗口**内侧**画任何东西都不可能变成投影。
     */
    return Stack(
      fit: StackFit.expand,
      children: [
        // 圆角**外面**那一圈 —— 与主题同源，不可能是"相反色"
        ColoredBox(color: widget.backdrop),
        // 被裁成圆角的内容
        ClipRRect(
          borderRadius: BorderRadius.circular(kWindowCornerRadius),
          child: widget.child,
        ),
      ],
    );
  }
}
