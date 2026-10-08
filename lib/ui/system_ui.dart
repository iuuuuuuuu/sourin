import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

/// 把系统栏（状态栏 + 导航栏）刷成与 App 内容区同色 —— task-17。
///
/// Owner 原话（m13309）：
/// 「手机APP这个顶部状态栏没沉浸,然后左右有圆角,然后底部是黑色的,这些都需要修复」
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ 根因（2026-10-04 定案 —— 第一版诊断错了一半，这里记全过程）
/// ══════════════════════════════════════════════════════════════════
///
/// ## 现象
///
/// 真机（`emulator-5554`，Android 14 / SDK 34）实测 `.probe/phone/t17_post.png`：
///
/// ```text
/// status y0..126    [((238,240,246), 33520), ...]  ✅ 已是 floor（修好了）
/// content y128..2272[((238,240,246), 264436), ...] ✅
/// nav   y2274..2399 [((0,0,0), 31841), (153,153,153), ...] ❌ 仍是纯黑
/// ```
///
/// ## 第一版诊断（对了一半）
///
/// `MaterialApp` 每次 build 都发一遍 `SystemUiOverlayStyle.dark`：
///
/// ```dart
/// // material_ui-1.4.0/lib/src/app.dart:1041-1043（_themeBuilder 里）
/// SystemChrome.setSystemUIOverlayStyle(
///   theme.brightness == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
/// );
/// ```
///
/// 而两个内置常量**都把导航栏写成纯黑**（`packages/flutter/lib/src/services/system_chrome.dart:316-330`）：
///
/// ```dart
/// static const SystemUiOverlayStyle dark = SystemUiOverlayStyle(
///   systemNavigationBarColor: Color(0xFF000000),   // ← 底栏那条黑
///   systemNavigationBarIconBrightness: Brightness.light,
///   statusBarIconBrightness: Brightness.dark,
///   statusBarBrightness: Brightness.light,
/// );   // 注意：statusBarColor 是 null，导航栏不是
/// ```
///
/// `setSystemUIOverlayStyle` 是**待发槽位**语义（`system_chrome.dart:746-780`）：
///
/// ```dart
/// if (_pendingStyle != null) { _pendingStyle = style; return; }  // 谁最后写槽位谁赢
/// if (style == _latestStyle) return;
/// _pendingStyle = style;
/// scheduleMicrotask(() { ... invokeMethod(...); _latestStyle = _pendingStyle; });
/// ```
///
/// ⇒ 于是第一版修法是「每帧最后一刀」：在 `SystemUiHost.build` 里排一个
///    `addPostFrameCallback` 把槽位抢回来。**这一刀不够。**
///
/// ## 第一版为什么不够（★ 关键）
///
/// 槽位里还有一个**每帧都发**的发送者 —— `RenderView._updateSystemChrome()`。
/// 它在 `compositeFrame()` 里被调用（`rendering/view.dart:347-359`），
/// 而 `compositeFrame()` 是 **persistent** frame callback
/// （`rendering/binding.dart:61 addPersistentFrameCallback(_handlePersistentFrameCallback)`
/// → `:691-697 drawFrame()` → `renderView.compositeFrame()`），
/// **每一帧都会跑**，跟 `SystemUiHost` 有没有 rebuild 无关。
///
/// 它的来源是层树里的 `AnnotatedRegion<SystemUiOverlayStyle>`
/// （`rendering/view.dart:429-434` 用 `layer!.find<SystemUiOverlayStyle>(...)` 取），
/// 而**这个 region 是 forui 自己挂的**：
///
/// ```dart
/// // forui-0.27.0/lib/src/widgets/scaffold.dart:109-110
/// return AnnotatedRegion<SystemUiOverlayStyle>(
///   value: style.systemOverlayStyle,
/// ```
///
/// 我们整个 shell 就包在 `FScaffold` 里（`shell.dart:3330`），
/// 而浅色下那个值就是 `SystemUiOverlayStyle.dark`
/// （`forui-0.27.0/lib/src/theme/colors.dart:146`：`systemOverlayStyle: .dark`）。
///
/// ```text
/// 帧内顺序（handleDrawFrame，scheduler/binding.dart:1338-1363）：
///   persistentCallbacks  ← RendererBinding.drawFrame → compositeFrame
///                          → _updateSystemChrome → 发 forui 的 dark
///   postFrameCallbacks   ← 我们的 SystemUiHost（只有它 rebuild 的那帧才有）
/// ```
///
/// ⇒ 任何**没有** `SystemUiHost` rebuild 的帧（滚动、动画、播放进度…）
///    最后一刀都是 forui 的 dark ⇒ 平台侧收到 `0xFF000000`。
///
/// ## 决定性证据：dump 里四个字段**同时**对上 `dark`
///
/// ```text
/// .probe/phone/t17_dwa.txt:455 taskDescription: statusBarColor=ffeef0f6 navigationBarColor=ff000000
/// .probe/phone/t17_dwa.txt:206 mLastAppearance=LIGHT_STATUS_BARS   ← 没有 LIGHT_NAVIGATION_BARS
/// ```
///
/// | 字段 | 观测 | 为什么只有 `dark` 能解释 |
/// |---|---|---|
/// | `statusBarColor` | 仍是我们的 floor | `dark.statusBarColor == null` ⇒ 插件**跳过** `setStatusBarColor`，保留首帧我们设的值 |
/// | `navigationBarColor` | 纯黑 | `dark.systemNavigationBarColor == 0xFF000000`，非 null ⇒ 每次都真的刷 |
/// | `LIGHT_STATUS_BARS` 有 | 有 | `dark.statusBarIconBrightness == dark` ⇒ `setAppearanceLightStatusBars(true)` |
/// | `LIGHT_NAVIGATION_BARS` 无 | 无 | `dark.systemNavigationBarIconBrightness == light` ⇒ `setAppearanceLightNavigationBars(false)` |
///
/// 我们自己拼的样式在浅色下会发 `systemNavigationBarIconBrightness: dark`，
/// 那一位**本应**出现 —— 没出现就说明最后落地的是 `dark`。
///
/// ## 修法：关掉那条每帧通道，改成显式驱动
///
/// `RenderView.automaticSystemUiAdjustment` 就是这个通道的开关
/// （`rendering/view.dart:233`，注释原话：
/// 「If you want to imperatively set the system ui style instead, it is
///  recommended that automaticSystemUiAdjustment is set to false.」）。
///
/// 把它关掉之后，**只剩我们一个发送者**，[applySystemUi] /
/// [reassertSystemUiOverlayStyle] 谁最后调用谁生效，不再有每帧争抢。
/// 见 [SystemUiHost.initState]。
///
/// ⚠️ 本应用 `targetSdk=36` ⇒ XML 里的 `statusBarColor`/`navigationBarColor`
///    会被系统忽略，只能走 `SystemChrome`。
///
/// ⚠️ 圆角**不是 App 画的**：左右圆角来自模拟器合成器的 `ScreenDecorOverlay`
///    （`pfl=... IS_ROUNDED_CORNERS_OVERLAY`，半径 28），**不要改**。
///
/// [brightness] 必须是**调用方自己解析出来的**亮度：
/// 本函数会在 `MaterialApp.builder` 里被调用，而那个 context 位于
/// `FTheme` / `Theme` 两套注入器**之上**，`Theme.of` / `FTheme.of` 在那里
/// 不抛异常、静默兜底成浅色（见 `shell.dart:1764-1810` 的注释）。
void applySystemUi(Brightness brightness) {
  // ① 显式声明 edge-to-edge。
  //
  //    `targetSdk=36` 时系统本来就强制 edge-to-edge，调这一句不改变行为
  //    （`system_chrome.dart:601-608` 的原文：「There is no way to opt out」）。
  //    PlatformPlugin 侧它只做 `setSystemUiVisibility(0)` +
  //    `WindowCompat.setDecorFitsSystemWindows(window, false)`
  //    （反编译 `pp.txt:360-372`）—— **完全不碰颜色**，
  //    所以两条栏的颜色只能靠 ②。
  //
  //    ⚠️ 这一句**不能**放进每帧路径：它没有去重，每次调用都会真的发一条
  //       平台消息（不像 ② 有 `_pendingStyle`/`_latestStyle` 双去重）。
  //       所以它只在 initState / 亮度变化 / 回前台时调。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // ② 真正决定两条栏颜色的地方。
  SystemChrome.setSystemUIOverlayStyle(systemUiOverlayStyleFor(brightness));
}

/// 只补发系统栏**样式**（不发 `setEnabledSystemUIMode`）—— 每帧调用用这个。
///
/// 与 [applySystemUi] 拆开是为了让「每帧最后一刀」这条路径零平台流量：
/// 样式去重（`system_chrome.dart:752-756` 的 `if (style == _latestStyle) return;`）
/// 让颜色没变时**一条消息都不发**。
void reassertSystemUiOverlayStyle(Brightness brightness) {
  SystemChrome.setSystemUIOverlayStyle(systemUiOverlayStyleFor(brightness));
}

/// 纯函数：亮度 → 系统栏样式。
///
/// 单独抽出来是为了能被单测直接断言（不依赖平台通道）。
SystemUiOverlayStyle systemUiOverlayStyleFor(Brightness brightness) {
  final bool light = brightness == Brightness.light;
  final Color floor = AppTheme.floorColor(brightness);
  return SystemUiOverlayStyle(
    // ── 状态栏 ──
    //
    //    用 floor 而不是 `Colors.transparent`：FlutterView 本身铺满
    //    0,0-1080,2400（`.probe/phone/dw_top.txt`：`N.t{e70769d VFE...... 0,0-1080,2400 #1}`），
    //    但 `DecorView` 的 `android:id/statusBarBackground` 是叠在它**上面**的兄弟 View。
    //    给不透明色可以一次性盖掉那一层 —— 否则看到的就是 `PlatformPlugin.onStart`
    //    设的 `window.setStatusBarColor(0x40000000)`（= 25% 黑蒙层），
    //    正是修之前的 `(178,180,184) == (238,240,246) × 0.75`。
    statusBarColor: floor,
    // Android：底色浅 → 要深色图标。
    statusBarIconBrightness: light ? Brightness.dark : Brightness.light,
    // iOS：statusBarBrightness 描述的是**底色**亮度，不是图标。
    statusBarBrightness: light ? Brightness.light : Brightness.dark,

    // ── 导航栏 ──
    //
    //    ⚠️ 这三个字段**必须**非 null，否则 PlatformPlugin 会跳过
    //    `Window.setNavigationBarColor`，底栏就退回系统默认的黑 ——
    //    这正是 `SystemUiOverlayStyle.dark` 干的事（它的 statusBarColor 是 null，
    //    所以状态栏没事；systemNavigationBarColor 非 null，所以底栏变黑）。
    systemNavigationBarColor: floor,
    systemNavigationBarDividerColor: floor,
    systemNavigationBarIconBrightness: light ? Brightness.dark : Brightness.light,

    // ── 关掉系统自带的对比度蒙层 ──
    //
    //    两者都在 SDK≥29 生效（反编译 `pp.txt:447-457` / `:508-518`）。
    //    不关的话，浅色底栏上系统可能再叠一层半透明灰，
    //    又会和内容区出现色差 —— 正是这次要修的现象。
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  );
}

/// 关掉 Flutter 框架那条**每帧自动**改系统栏的通道。
///
/// # 为什么必须关
///
/// `RenderView.compositeFrame()` 每帧都会跑这段（`rendering/view.dart:347-359`）：
///
/// ```dart
/// void compositeFrame() {
///   ...
///   final ui.Scene scene = layer!.buildScene(builder);
///   if (automaticSystemUiAdjustment) {
///     _updateSystemChrome();          // ← 这里发样式
///   }
///   _view.render(scene, size: ...);
/// }
/// ```
///
/// `_updateSystemChrome()`（`rendering/view.dart:387-489`）会从层树里找
/// `AnnotatedRegion<SystemUiOverlayStyle>`（`:429-434` 的 `layer!.find<...>`），
/// 而**forui 的 `FScaffold` 正好挂了一个**
/// （`forui-0.27.0/lib/src/widgets/scaffold.dart:109-110`），
/// 浅色下它的值是 `SystemUiOverlayStyle.dark`
/// （`forui-0.27.0/lib/src/theme/colors.dart:146`）—— 导航栏纯黑。
///
/// 于是每一帧的**最后一刀**都是它，而我们写在 `build` 里的
/// `addPostFrameCallback` 只在 `SystemUiHost` 本帧 rebuild 时才排得上队
/// ⇒ 滚动/动画/播放进度这些帧，底栏又变回黑。
///
/// 关掉之后框架不再自动发，本文件成为**唯一**发送者。
///
/// 框架文档原话（`rendering/view.dart:226-227`）：
/// 「If you want to imperatively set the system ui style instead,
///  it is recommended that [automaticSystemUiAdjustment] is set to false.」
///
/// 幂等：重复调用只写同一个 bool。
void disableAutomaticSystemUiAdjustment() {
  // 用 `renderViews` 而不是已废弃的 `renderView`（`rendering/binding.dart:296-301`
  // 标了 @Deprecated）。类型靠推断，不必 import `package:flutter/rendering.dart`。
  for (final view in WidgetsBinding.instance.renderViews) {
    view.automaticSystemUiAdjustment = false;
  }
}
/// 在 `MaterialApp.builder` 的手机分支里挂一层，负责把 [applySystemUi]
/// 在**首帧之前**、**每次亮度变化时**、以及**每帧最后一刀**推给平台。
///
/// # 为什么需要「每帧最后一刀」
///
/// 见文件头「修法」一节。帧内顺序是固定的（`scheduler/binding.dart:1338-1363`
/// 的 `handleDrawFrame()` 就是一个同步块）：
///
/// ```text
/// persistentCallbacks
///   ├ RendererBinding._handlePersistentFrameCallback   ← rendering/binding.dart:61 注册，最早
///   │   └ drawFrame → build → layout → paint → compositeFrame
///   │       └ _updateSystemChrome（读 forui 的 AnnotatedRegion）
///   └ ★ 我们的 _reassertOnFrame                        ← 后注册 ⇒ 必然排在它后面
/// postFrameCallbacks                                   ← 只有本 widget rebuild 的那帧才有
/// ```
///
/// 两个要点：
///
/// 1. `RendererBinding` 在 `initInstances` 第 61 行注册自己的 persistent 回调，
///    而 `addPersistentFrameCallback` 就是 `_persistentCallbacks.add`
///    （`scheduler/binding.dart:781-783`，纯追加、无排序）。
///    ⇒ 我们在 `initState` 里注册的回调**必然**跑在 `compositeFrame()` 之后。
/// 2. 那一刻上一帧的微任务早已排空、`_pendingStyle` 是 null，
///    于是走 `if (style == _latestStyle) return;` 去重分支
///    ⇒ 颜色没变时**一条平台消息都不发**（每帧开销只有一次 `==`）。
///
/// 另有一层保险：`initState` 里调 [disableAutomaticSystemUiAdjustment]
/// 把那条每帧自动通道直接关掉 —— 于是本文件成为**唯一**发送者，
/// 最后一刀不再是「抢」，而是「只有我」。
///
/// 生命周期：`SystemChrome` 在 `AppLifecycleState.detached` 时会清掉
/// `_latestStyle`（`system_chrome.dart:783-791`），所以回到前台要重发。
class SystemUiHost extends StatefulWidget {
  const SystemUiHost({super.key, required this.brightness, required this.child});

  /// 已解析的亮度（**不要**在本 widget 内部用 `Theme.of` 重新取）。
  final Brightness brightness;

  final Widget child;

  @override
  State<SystemUiHost> createState() => _SystemUiHostState();
}

/// 当前活着的 host。
///
/// `addPersistentFrameCallback` **没有**反注册 API（`scheduler/binding.dart:781`），
/// 回调一旦装上就跟到进程结束。所以回调本身**不能**闭包捕获 `State` ——
/// 否则 host 被 dispose 之后那个闭包还会继续按旧亮度发样式。
/// 用这个静态引用做失效保护，`dispose` 时清空。
_SystemUiHostState? _activeSystemUiHost;

/// persistent 帧回调：每帧**最后一刀**。
///
/// 必须是顶层函数（或静态闭包）：它不能捕获任何 `State`。见 [_activeSystemUiHost]。
void _reassertOnFrame(Duration _) {
  final _SystemUiHostState? host = _activeSystemUiHost;
  if (host == null || !host.mounted) return;
  reassertSystemUiOverlayStyle(host.widget.brightness);
}

class _SystemUiHostState extends State<SystemUiHost> with WidgetsBindingObserver {
  /// 回调只装一次 —— `addPersistentFrameCallback` 是纯追加，装两次就发两次。
  static bool _frameHookInstalled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // ① 关掉那条每帧自动通道 —— 底栏黑条的**真正来源**。详见文件头。
    disableAutomaticSystemUiAdjustment();

    // ② 首帧之前先放上去（不等第一帧回调，避免闪一下系统默认色）。
    applySystemUi(widget.brightness);

    // ③ 装上「每帧最后一刀」。注册点必须在 widget 树里：
    //    `RendererBinding` 自己的 persistent 回调在 `rendering/binding.dart:61`
    //    注册，早于任何 widget 代码 ⇒ 我们后注册 ⇒ 排在它后面。
    _activeSystemUiHost = this;
    if (!_frameHookInstalled) {
      _frameHookInstalled = true;
      WidgetsBinding.instance.addPersistentFrameCallback(_reassertOnFrame);
    }
  }

  @override
  void didUpdateWidget(SystemUiHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.brightness != widget.brightness) {
      applySystemUi(widget.brightness);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // detached 时 SystemChrome 会丢掉 _latestStyle，回前台必须重发。
    if (state == AppLifecycleState.resumed) applySystemUi(widget.brightness);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 帧回调没有反注册 API，靠这里让 [_reassertOnFrame] 失效。
    if (identical(_activeSystemUiHost, this)) _activeSystemUiHost = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
