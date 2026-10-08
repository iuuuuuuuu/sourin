import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    /*
     * ═══════════════════════════════════════════════════════════════
     *  ★ 窗口参数 —— 与 Windows / Android 两端**对齐**
     * ═══════════════════════════════════════════════════════════════
     *
     * # 为什么要显式设（而不是用模板默认值）
     * ```text
     * 模板默认窗口是 800x600，而产品的 windowOptions 是 1280x800
     * （`lib/shell.dart` 的 `WindowOptions(size: Size(1280, 800))`）。
     * 不设的话，macOS 上首帧是 800x600，随后被 Dart 侧的
     * `windowManager` 调整 —— 用户会看到**窗口跳一下**。
     * ```
     *
     * ⚠️ 最小尺寸 900x600 与 Windows 一致：
     *    900 是 `media_page.dart` 的宽档阈值，窄于它右侧详情面板
     *    会走上下分栏，头部 + 选集放不下（详见 `lib/shell.dart`
     *    里 `minimumSize` 那段注释的实测数据）。
     */
    self.setContentSize(NSSize(width: 1280, height: 800))
    self.contentMinSize = NSSize(width: 900, height: 600)
    self.center()

    /*
     * ★ 标题栏样式：产品在 Windows 上是**自绘**标题栏
     *   （`titleBarStyle: TitleBarStyle.hidden`，见 `lib/shell.dart`）。
     *
     * macOS 这里**保持系统标题栏**（`titlebarAppearsTransparent = false`）：
     * ```text
     * ① macOS 的红黄绿交通灯按钮是系统级约定，自绘会显得很怪；
     * ② 自绘标题栏那条 40px 的栏在 macOS 上会与系统标题栏**重叠**；
     * ③ 产品代码里 `kIsDesktop` 判断包含 macOS，
     *    `_CustomTitleBar` 会照画 —— 所以这里把系统标题栏留着，
     *    让用户至少有一个能拖动/关闭的入口。
     * ```
     * ⚠️ 这是**如实记录的平台差异**，不是「忘了做」。
     *    要做成完全一致需要给 macOS 单独写一套 titleBarStyle 分支，
     *    那是后续工作。
     */
    self.titlebarAppearsTransparent = false
    self.titleVisibility = .visible

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
