// t423 —— arm64 黑屏归属：在 `runApp(SourinApp)` 这一行内部再切几刀
//
// ════════════════════════════════════════════════════════════════════
// 为什么要写这个探针
// ════════════════════════════════════════════════════════════════════
//
// t421 已把断点精确定位到 `runApp(SourinApp(...))` 这一行：
// ```text
//   段 0..5（MediaKit / Device.init / UiPrefs / SourinCore FFI /
//            LiquidGlassWidgets.initialize）在 arm64 翻译层下**全部上屏**
//   段 6  runApp(SourinApp)                        → 屏幕 colours=1 纯黑
// ```
// t422 用**同一个探针、同一台车**换成 x86_64 引擎再跑，段 6 渲染出
// `196 colours / #0A0A0A`（产品的深色底）⇒ **黑屏是 arm64 特有的**。
//
// 但 t421 有个仪器缺口：第 6 段**没有进程内读数**，所以无法区分
// ```text
//   ① Skia 根本没画出来（Dart 侧就黑了）
//   ② 画出来了但没上屏（合成/呈现层）
// ```
// 本探针补上这个读数，并把 `SourinApp` 内部按层次切成 6 刀。
//
// ════════════════════════════════════════════════════════════════════
// 刀法：从「能上屏的最小壳」逐层加到「产品整棵树」
// ════════════════════════════════════════════════════════════════════
//
//   A  MaterialApp 裸壳（无 theme / 无 builder）        ← 引擎能不能画 MaterialApp
//   B  A + 产品 theme:materialTheme                    ← 产品 ThemeData 有没有问题
//   C  B + 产品 builder: FTheme→FToaster→WindowFrame→ColoredBox
//                                                      ← 外壳那一串
//   D  C + home: ShellPage（产品首页整棵树）             ← 真正的产品内容
//   E  runApp(SourinApp(...))                          ← 与 t421 段 6 逐字相同
//   F  **恢复金丝雀** —— 证明「黑」之后进程还活着、还能画
//
// ★ 判据是**逐段对比**，不是单段绝对值：
//   某段第一次变黑 ⇒ 那一层就是凶手；
//   F 段若恢复正常 ⇒ 排除「进程/引擎已死」；
//   E 段必须复现 t421 的黑 ⇒ 否则说明这次构建/车况变了，结论不成立。
//
// ════════════════════════════════════════════════════════════════════
// 仪器纪律
// ════════════════════════════════════════════════════════════════════
// * 每段**都**有进程内读数（t421 的缺口）——用 `_rootKey` 包一层
//   `RepaintBoundary`。⚠️ 但 `runApp(SourinApp)` 不能包（要复刻产品），
//   所以 E 段的进程内读数用**整屏抓帧**的替代：`_rootKey` 是全局的，
//   `SourinApp` 自己不含 RepaintBoundary ⇒ E 段读 `no-context`。
//   ⇒ E 段只能靠屏幕读数，这正是 t421 的处境，**如实报告**。
// * 每段颜色**互不相同**，一个像素就能分辨是哪一段。
// * 段名同时写进设备侧报告与屏幕（金丝雀段），两个独立读数。
//
// 运行（必须单独 build，因为要改入口）：
// ```powershell
// flutter build apk --release --target-platform android-arm64 -t lib/t423_arm64_probe.dart
// $env:T422_ABI_TAG='t423_arm64'; python .probe\t422_drive.py <apk> emulator-5556 arm64-v8a
// ```
//
// ⚠️ `.probe\t422_drive.py` 的 `STAGE_NAMES` 是**硬编码 7 项**（t421 的），
//    本探针有 7 段但名字不同 ⇒ 驱动脚本打印的名字会不对。
//    判决表以 `t421_report.txt`（设备侧探针自报）为准，**不要**读驱动脚本的名字。

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
// ★★ 必须用 `material_ui` 的 `MaterialApp`，**不是** `flutter/material` 的！
//    本项目是「双 Material 拆分」：`flutter/material` 与 `material_ui`
//    各自有一套 `Theme` InheritedWidget，`Theme.of` 不能跨包
//    （`lib\shell.dart:1338-1339` 记着这个坑）。
//    产品用的是 `material_ui` 那套（`lib\shell.dart:35`），
//    所以对照臂必须同源，否则测的是**另一个 widget**。
import 'package:material_ui/material_ui.dart';
import 'package:forui/forui.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'core/device.dart';
import 'core/ffi.dart';
import 'core/ui_prefs.dart';
import 'shell.dart';
import 'ui/app_theme.dart';
import 'ui/theme_bridge.dart';
import 'ui/widgets/window_frame.dart';

const String kTag = '[T424]';

/// 每段停多久，留给进程外截图。
const Duration kHold = Duration(seconds: 7);

final GlobalKey _rootKey = GlobalKey();

String _workDir = '';

/// 每段的颜色 —— **必须彼此差得远**，这样一个像素就能分辨是哪一段。
///
/// 顺序与下面 `main()` 的刀法一一对应：
/// ```text
/// 0   PRE-INIT 金丝雀（阳性对照：前置做完后引擎还能画）
/// 1   A   MaterialApp 裸壳
/// 2   B   + 产品 theme:materialTheme
/// ── 以下五段把产品 builder 链（lib\shell.dart:1174-1458）**逐层**加上 ──
/// 3   C1  + builder: FTheme
/// 4   C2  + FToaster                ← Overlay.wrap ⇒ Clip.hardEdge
/// 5   C2n 机制探针：同构 Overlay，Clip.none（与 C2 是**最小对**）
/// 6   C3  + WindowFrame             （Android 上 :562 直接 return child）
/// 7   C4  + ColoredBox(floorColor)  ← **t423 段 3 就是这一层**
/// ─────────────────────────────────────────────────────────────────
/// 8   D   + home: ShellPage（产品首页）
/// 9   E   runApp(SourinApp(...))    ← 复刻 t421 段 6
/// 10  F   恢复金丝雀（证明黑过之后进程还活着）
/// ```
/// ★ t423 的结论是「B 段彩、C 段黑」，凶手夹在 B→C 之间 —— 但那一条
///   里塞了 `FTheme → FToaster → WindowFrame → ColoredBox` **四个** widget。
///   本探针把这一条切成 4 刀，并把嫌疑最大的 `FToaster`（它内部
///   `Overlay.wrap` 会引入 `_RenderTheater` + `Clip.hardEdge`）单独配一个
///   「同构但 `Clip.none`」的**最小对**（段 4 vs 段 5）：
///   若 4 黑而 5 彩 ⇒ 凶手就是那一次裁剪；若两段同态 ⇒ 凶手在别处。
const List<int> kStageColors = <int>[
  0xFF1E63C8, // 0  蓝     PRE-INIT 金丝雀
  0xFFE8001E, // 1  红     A MaterialApp 裸壳
  0xFF1EC863, // 2  绿     B + 产品 theme
  0xFFC81EC8, // 3  洋红   C1 + builder:FTheme
  0xFFE8C81E, // 4  黄     C2 + FToaster（Overlay.wrap ⇒ Clip.hardEdge）
  0xFF1EC8C8, // 5  青     C2n 机制探针：同构 Overlay，Clip.none
  0xFFC81E63, // 6  玫红   C3 + WindowFrame
  0xFF63C81E, // 7  草绿   C4 + ColoredBox（== t423 段 3，必须复现黑）
  0xFFE8FF00, // 8  亮黄绿 D + home:ShellPage
  0xFF000000, // 9  黑（占位，E 段不画金丝雀 —— 它就是被测对象）
  0xFFFF00FF, // 10 紫红   F 恢复金丝雀
];

const List<String> kStageNames = <String>[
  'PREINIT_canary',
  'A_MaterialApp_bare',
  'B_plus_product_theme',
  'C1_plus_FTheme',
  'C2_plus_FToaster',
  'C2n_overlay_clip_none',
  'C3_plus_WindowFrame',
  'C4_plus_ColoredBox',
  'D_plus_ShellPage',
  'E_runApp_SourinApp',
  'F_recovery_canary',
];

void _log(String line) {
  debugPrint('$kTag $line');
}

Future<void> _append(String line) async {
  try {
    await File('$_workDir/t421_report.txt').writeAsString(
      '${DateTime.now().toIso8601String()}  $line\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

/// 把段号落盘 —— 这是进程外驱动脚本的**同步信号**。
///
/// ⚠️ 复用 t421 的文件名（`t421_stage.txt`），这样 `.probe\t422_drive.py`
///    不用改就能驱动本探针。
Future<void> _writeStage(int stage) async {
  try {
    await File('$_workDir/t421_stage.txt').writeAsString('$stage', flush: true);
  } catch (_) {}
}

/// 让出若干帧。
///
/// ⚠️ `endOfFrame` 必须带 timeout —— 否则引擎不出帧时这里**静默挂死**，
///    而挂死看起来和「黑屏」一模一样（都只是"没有画面"）。
Future<void> _settle() async {
  for (int i = 0; i < 3; i++) {
    try {
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // 超时/异常都不致命：继续，读数会如实反映。
    }
  }
}

/// 进程内读回像素（仪器一）—— t421 第 6 段缺的就是这个。
///
/// ★ t423 的仪器**丢掉了 alpha**：`(bytes[i] << 16) | ...` 只取 RGB，
///   于是「完全透明」与「不透明白」都读成 `#000000`，两者不可分辨。
///   而这两者在归属上意义完全相反（透明 ⇒ 什么都没画；
///   不透明黑 ⇒ 画了一层黑）。所以这里把 alpha 也读出来。
Future<String> _inProc() async {
  try {
    final ctx = _rootKey.currentContext;
    if (ctx == null) return 'no-context';
    final ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary) return 'not-boundary:${ro.runtimeType}';
    final ui.Image img = await ro.toImage(pixelRatio: 1.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (bd == null) return 'no-bytes';
    final bytes = bd.buffer.asUint8List();
    final rgb = <int>{};
    final alpha = <int>{};
    int n = 0;
    for (int i = 0; i + 3 < bytes.length; i += 4 * 7) {
      rgb.add((bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]);
      alpha.add(bytes[i + 3]);
      n++;
    }
    final top = rgb
        .take(4)
        .map((c) => '#${c.toRadixString(16).padLeft(6, '0').toUpperCase()}')
        .join(',');
    final corner = bytes.length >= 4
        ? '#${((bytes[0] << 16) | (bytes[1] << 8) | bytes[2]).toRadixString(16).padLeft(6, '0').toUpperCase()}'
        : 'n/a';
    final a0 = bytes.length >= 4 ? bytes[3] : -1;
    // alpha 集合很小（通常 1~3 个值），全列出来比只报角落更可信。
    final aList = (alpha.toList()..sort())
        .take(4)
        .map((a) => a.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(',');
    return 'colors=${rgb.length} sampled=$n px00=$corner a00=${a0.toRadixString(16).padLeft(2, '0').toUpperCase()} '
        'alphas=${alpha.length}[$aList] top=[$top]';
  } catch (e) {
    return 'ERR:$e';
  }
}

/// ★ 本轮的关键仪器：**不依赖 `_rootKey`** 的进程内读数。
///
/// `runApp(SourinApp(...))` 不能包 `RepaintBoundary`（要逐字复刻产品），
/// 所以 E 段拿不到 `_rootKey` 的 context。退而求其次：问引擎
/// 「**这一帧到底画了没有**」—— 用 `SchedulerBinding` 的帧计数 +
/// `RendererBinding.renderView` 的尺寸。这不是像素，但能回答
/// 「Dart 侧是否还在出帧」这个二分问题的**一半**。
Future<String> _engineState() async {
  try {
    // ⚠️ `renderViews` 在 `RendererBinding` 上，不在 `WidgetsBinding` 上。
    final views = RendererBinding.instance.renderViews;
    final rv = views.isNotEmpty ? views.first : null;
    final size = rv?.size;
    // ⚠️ 只写一个 `?.`：Dart 的流程分析在同一条 null-aware 链里会把
    //    `size?.width` 的续段提升为非空 ⇒ 第二个 `?.` 会被判
    //    `invalid_null_aware_operator`（我第一版写了两处）。
    return 'renderViews=${views.length} '
        'size=${size?.width.toStringAsFixed(0)}x${size?.height.toStringAsFixed(0)} '
        'frames=$_frameCount '
        'hasScheduledFrame=${SchedulerBinding.instance.hasScheduledFrame}';
  } catch (e) {
    return 'ERR:$e';
  }
}

int _frameCount = 0;
bool _timingsHooked = false;

void _hookTimings() {
  if (_timingsHooked) return;
  _timingsHooked = true;
  SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> t) {
    _frameCount += t.length;
  });
}

/// 画一段金丝雀、读一次进程内像素、停 `kHold` 让外面截图。
Future<void> _canary(int stage) async {
  runApp(
    RepaintBoundary(
      key: _rootKey,
      child: _Canary(stage: stage),
    ),
  );
  await _settle();

  final read = await _inProc();
  final eng = await _engineState();
  _log('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng');
  await _append('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng');

  await _writeStage(stage);
  _log('STAGE $stage HOLD-BEGIN');
  await Future<void>.delayed(kHold);
  _log('STAGE $stage HOLD-END');
}

/// 给非金丝雀段（A..E）用的读数 + 停留。
///
/// 与 `_canary` 的差别：**不 runApp**，只读 + 落段号 + 停。
Future<void> _holdStage(int stage, String what) async {
  await _settle();
  final read = await _inProc();
  final eng = await _engineState();
  _log('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng  [$what]');
  await _append('STAGE $stage (${kStageNames[stage]}) INPROC $read | $eng  [$what]');
  await _writeStage(stage);
  _log('STAGE $stage HOLD-BEGIN');
  await Future<void>.delayed(kHold);
  _log('STAGE $stage HOLD-END');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _hookTimings();

  try {
    final d = await getExternalStorageDirectory();
    _workDir = d?.path ??
        '/storage/emulated/0/Android/data/app.sourin.sourin_spike/files';
  } catch (_) {
    _workDir = '/data/local/tmp';
  }
  try {
    await Directory(_workDir).create(recursive: true);
  } catch (_) {}

  await _append('================ t423 start ================');
  _log('workdir=$_workDir');

  // ── 前置：与产品 main() 逐字同序的初始化 ──────────────────────
  // 这样 A..E 各段才有可比性（缺了它们，后面变黑可能只是"没初始化"）。
  String pre = 'ok';
  try {
    MediaKit.ensureInitialized();
    await Device.init();
    final dir = await _resolveDataDir();
    await UiPrefs.load(dir);
    await SourinCore.startAsync(dir);
    await LiquidGlassWidgets.initialize();
    _preDataDir = dir;
  } catch (e) {
    pre = 'ERR:$e';
  }
  _log('PRE-INIT -> $pre  kind=${Device.kind} isTv=${Device.isTv}');
  await _append('PRE-INIT -> $pre  kind=${Device.kind} isTv=${Device.isTv}');

  // 先画一次金丝雀（段 0），证明「前置做完后引擎还能画」。
  // ★ 这是本探针的**阳性对照**：若它都不上屏，后面所有黑都不可解释。
  await _canary(0);

  // ── A：MaterialApp 裸壳 ───────────────────────────────────────
  runApp(RepaintBoundary(
    key: _rootKey,
    child: const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _Flat(color: Color(0xFFE8001E), label: 'A MaterialApp bare'),
    ),
  ));
  await _holdStage(1, 'A MaterialApp 裸壳（无 theme / 无 builder）');

  // ── B：A + 产品 theme:materialTheme ──────────────────────────
  final brightness = AppTheme.resolve(systemBrightness: Brightness.dark);
  final theme = AppTheme.themeFor(brightness);
  final materialTheme = brightness == Brightness.light
      ? buildLightMaterialTheme(theme)
      : buildMaterialTheme(theme);
  runApp(RepaintBoundary(
    key: _rootKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: materialTheme,
      home: const _Flat(color: Color(0xFF1EC863), label: 'B + product theme'),
    ),
  ));
  await _holdStage(2, 'B = A + theme:materialTheme（产品 ThemeData）');

  // ── C1..C4：把产品的 builder 链**逐层**加上 ──────────────────────
  // t423 只证明了「B 彩 → C 黑」，但 C 里塞了四个 widget。这里一层一段。
  //
  // 产品原文（lib\shell.dart:1174-1458）：
  //   FTheme → FToaster → WindowFrame → ColoredBox → RemoteBridgeHost
  //   → _TitleBarHost → Column → [_CustomTitleBar, Expanded(child)=Navigator]
  // 本探针止于 ColoredBox（前四层）—— RemoteBridgeHost/_TitleBarHost
  // 是**第五、六层**，等这四层定位完再加，免得一次动两个自变量。

  // ── C1：B + builder: FTheme ──────────────────────────────────
  runApp(RepaintBoundary(
    key: _rootKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: materialTheme,
      builder: (context, child) => FTheme(
        data: theme,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _Flat(color: Color(0xFFC81EC8), label: 'C1 + FTheme'),
    ),
  ));
  await _holdStage(3, 'C1 = B + builder:FTheme（纯 InheritedWidget）');

  // ── C2：C1 + FToaster ───────────────────────────────────────
  // ★ 头号嫌疑：FToaster.build() 是
  //     `Overlay.wrap(child: Stack(clipBehavior: .none, fit: .passthrough, ...))`
  //   （forui-0.27.0\lib\src\widgets\toast\toaster.dart:410-412）
  //   而 `Overlay.wrap` 的 `clipBehavior` **默认 Clip.hardEdge**
  //   （flutter\...\widgets\overlay.dart:501-504）⇒ 它会在树里插进
  //   `_RenderTheater` + 一个 `ClipRectLayer`（overlay.dart:1531-1545）。
  runApp(RepaintBoundary(
    key: _rootKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: materialTheme,
      builder: (context, child) => FTheme(
        data: theme,
        child: FToaster(
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      home: const _Flat(color: Color(0xFFE8C81E), label: 'C2 + FToaster'),
    ),
  ));
  await _holdStage(4, 'C2 = C1 + FToaster（内部 Overlay.wrap ⇒ Clip.hardEdge）');

  // ── C2n：C2 的**最小对** —— 同构 Overlay，只把 Clip 换成 none ──
  // 这一段的唯一作用是回答：「凶手是不是那一次裁剪？」
  //   4 黑而 5 彩 ⇒ 就是 Clip.hardEdge 那次裁剪；
  //   4/5 同态     ⇒ 裁剪无罪，凶手在别处（继续看 C3/C4）。
  // 为了只动一个自变量，这里的 Stack 逐字照抄 FToaster 的那一行。
  runApp(RepaintBoundary(
    key: _rootKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: materialTheme,
      builder: (context, child) => FTheme(
        data: theme,
        child: Overlay.wrap(
          clipBehavior: Clip.none, // ← 与 C2 的**唯一**差别
          child: Stack(
            clipBehavior: Clip.none,
            fit: StackFit.passthrough,
            children: <Widget>[child ?? const SizedBox.shrink()],
          ),
        ),
      ),
      home: const _Flat(color: Color(0xFF1EC8C8), label: 'C2n Overlay Clip.none'),
    ),
  ));
  await _holdStage(5, 'C2n = 同构 Overlay 但 Clip.none（与 C2 最小对）');

  // ── C3：C2 + WindowFrame ────────────────────────────────────
  // 预期无差别：Android 上 WindowFrame 在 :562 就 `return widget.child`，
  // 连 :708 的 debugPrint 都到不了（t423 logcat 里 WINDOWFRAME 零命中）。
  // 留着它当**阴性对照** —— 若这一段也黑，说明我的层序假设错了。
  runApp(RepaintBoundary(
    key: _rootKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: materialTheme,
      builder: (context, child) => FTheme(
        data: theme,
        child: FToaster(
          child: WindowFrame(
            backdrop: AppTheme.floorColor(brightness),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
      home: const _Flat(color: Color(0xFFC81E63), label: 'C3 + WindowFrame'),
    ),
  ));
  await _holdStage(6, 'C3 = C2 + WindowFrame（Android 上 :562 直接 return child）');

  // ── C4：C3 + ColoredBox(floorColor) ─────────────────────────
  // ★ 这一段**必须复现 t423 段 3 的黑**，否则说明 t423 的结论不可复现，
  //   后面所有归属都要作废重来。深色下 floorColor == #0A0A0A。
  runApp(RepaintBoundary(
    key: _rootKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: materialTheme,
      builder: (context, child) => FTheme(
        data: theme,
        child: FToaster(
          child: WindowFrame(
            backdrop: AppTheme.floorColor(brightness),
            child: ColoredBox(
              color: AppTheme.floorColor(brightness),
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
      home: const _Flat(color: Color(0xFF63C81E), label: 'C4 + ColoredBox'),
    ),
  ));
  await _holdStage(7, 'C4 = C3 + ColoredBox(floorColor) —— == t423 段 3，必须复现黑');

  // ── D：C4 + home: ShellPage（产品首页整棵树） ─────────────────
  runApp(RepaintBoundary(
    key: _rootKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: materialTheme,
      builder: (context, child) => FTheme(
        data: theme,
        child: FToaster(
          child: WindowFrame(
            backdrop: AppTheme.floorColor(brightness),
            child: ColoredBox(
              color: AppTheme.floorColor(brightness),
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
      home: ShellPage(
        key: debugShellKey,
        coreError: null,
        coreDataDir: _preDataDir,
      ),
    ),
  ));
  await _holdStage(8, 'D = C4 + home: ShellPage（产品首页）');

  // ── E：runApp(SourinApp(...)) —— 与 t421 段 6 逐字相同 ───────
  // ⚠️ 这里**不能**包 RepaintBoundary（要复刻产品）⇒ `_inProc` 会报
  //    `no-context`，只能靠屏幕读数。**如实报告，不假装有读数。**
  runApp(SourinApp(coreError: null, coreDataDir: _preDataDir));
  _log('CALL runApp(SourinApp) done');
  await _append('CALL runApp(SourinApp) done');
  await _holdStage(9, 'E = runApp(SourinApp) —— 复刻 t421 段 6');

  // ── F：恢复金丝雀 —— 证明「黑」之后进程还活着、还能画 ─────────
  await _canary(10);

  _log('DONE');
  await _append('================ t424 done ================');
  exit(0);
}

String _preDataDir = '';

/// 一个纯色 + 一行字的极简页面（A..D 段用）。
class _Flat extends StatelessWidget {
  const _Flat({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color,
      child: SizedBox.expand(
        child: Center(
          child: Text(
            label,
            textAlign: TextAlign.center,
            softWrap: true,
            style: const TextStyle(
              fontSize: 56,
              fontWeight: FontWeight.bold,
              color: Color(0xFFFFFFFF),
              shadows: <Shadow>[
                Shadow(offset: Offset(3, 3), blurRadius: 6, color: Color(0xFF000000)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 金丝雀：纯色底 + 一行大字。颜色和文字**都**编码了段号 ⇒ 两个独立读数。
class _Canary extends StatelessWidget {
  const _Canary({required this.stage});

  final int stage;

  @override
  Widget build(BuildContext context) {
    final int c = kStageColors[stage];
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Color(c),
        child: SizedBox.expand(
          child: Center(
            child: Text(
              'S$stage ${kStageNames[stage]}',
              textAlign: TextAlign.center,
              softWrap: true,
              style: const TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.bold,
                color: Color(0xFFFFFFFF),
                shadows: <Shadow>[
                  Shadow(offset: Offset(3, 3), blurRadius: 6, color: Color(0xFF000000)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 产品数据目录。Android 上 `getApplicationSupportDirectory()` 就是
/// `/data/user/0/<pkg>/files` —— 与产品自己用的私有目录同址
/// （实测该目录里有 `ui-prefs.json`，正是 `UiPrefs` 写的那个）。
Future<String> _resolveDataDir() async {
  final d = await getApplicationSupportDirectory();
  if (!await d.exists()) await d.create(recursive: true);
  return d.path;
}
