// ═══════════════════════════════════════════════════════════════════════
//  task-74【④】「线路,出来的弹窗是从上往下出现的,这是错误的」
//  —— **真机方向**取证探针（2026-09-28）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单测不够、必须真机量位移
//
// `test/player_panel_wiring_test.dart` 组 B2 已经断言了
// `SheetTransition.slideFrom == const Offset(24, 0)`（读的是**生产那棵树**）。
// 但 Owner 报的是一个**运动**：「弹窗是从上往下出现的」。
// 常量断言只能证明"我写了 (24,0)"，**证不了**这个常量真的变成了屏幕上的方向 ——
// 中间还隔着 `SheetTransition` 的位移公式、`Transform.translate`、
// 以及面板自己的几何。⇒ 必须量**每帧的真实位置**。
//
// # 位移公式（`episode_strip.dart:1164-1194`，读源码得来）
// ```dart
// final t = curve.transform(_c.value).clamp(0.0, 1.0);
// Transform.translate(offset: Offset(slideFrom.dx * (1 - t), slideFrom.dy * (1 - t)))
// ```
//   t=1 ⇒ 位移 0（在位）；t=0 ⇒ 位移 == slideFrom
// ⇒ `slideFrom = (24,0)` 退出时 **dx: 0 → +24**，dy 恒 0
// ⇒ `slideFrom = (0,24)` 退出时 **dy: 0 → +24**，dx 恒 0
//
// # ★★ 本探针只测**退出**，因为**进入根本不动画**
//
// `didUpdateWidget`（`:1135-1156`）里进入那一支是：
// ```dart
// _c.value = 1.0;  setState(() => _mounted = true);
// ```
// 直接赋值，**不是** `forward()` ⇒ 打开的第一帧面板就已经在最终位置。
// ⇒ Owner 说的「从上往下出现」只可能来自**退出方向**（关闭时往下滑），
//   或者是他对"出现/消失"的整体观感描述。
// ★ 本探针**顺带把这一点也量出来**（进入段 20 帧的位置必须全部相同），
//   这样结论就不是猜的：进入不动 + 退出往右 ⇒ 「从上往下」不可能发生。
//
// # 仪器：每帧读面板的 global topLeft
//
// 定位链：`Text('线路 / 清晰度')`（`player_page.dart:9191`）
//   → 向上找第一个 `SizedBox(width: 320)`（`:9158`）
//   → 读它的 `renderObject.localToGlobal(Offset.zero)`
// ★ `localToGlobal` 会把祖先链上的 `Transform.translate` **算进去**
//   ⇒ 它就是"面板此刻在屏幕上的位置"，正是要量的东西。
//
// # ★★ 两极对照（spec Contract 23：没有阳性对照的读数不是读数）
//
// 同一个探针、同一台仪器，跑两次构建：
// ```text
// 极 A（现状）  lib/ui/player_page.dart:7356 = const Offset(24, 0)
//               EXPECT_AXIS=x  ⇒ 期望 dx>5 且 dy<1
// 极 B（突变）  :7356 = const Offset(0, 24)   ← 把 ④ 的 bug 放回去
//               EXPECT_AXIS=y  ⇒ 期望 dy>5 且 dx<1
// ```
// 极 B 存在的唯一理由是证明**仪器能检出这个 bug** ——
// 否则极 A 的 `dy≈0` 既可能是"修复生效"，也可能是"仪器根本不读 y"。
// ★ 突变必须逐字节还原（复用 `t75_redproof.py` 的还原校验手法）。
//
// # 关闭路径：走**真实用户路径**（点面板外空白）
//
// `_SheetScrim`（`player_page.dart:9003-9027`）：
// ```dart
// Stack([ Positioned.fill(GestureDetector(behavior: HitTestBehavior.opaque,
//                                            onTap: onClose)),
//         child ])
// ```
// ⇒ 在 `(100, 400)` 注入一次单击 ⇒ 命中 scrim ⇒ `_streamSheetOpen = false`
//   ⇒ `didUpdateWidget` 走退出支 ⇒ `_c.reverse()`（`Motion.base` = 260ms）。
// ★ z-order 已核实：线路面板在 `build()` 的 children 里排在
//   `_LoadingOverlay`(`:6769`)/`_ErrorOverlay`(`:6773`) **之后** ⇒ 面板在上层，
//   `_load()` 失败留下的错误浮层**挡不住** scrim。
// ★ 兜底：若点空白没关掉（`debugPlayerAnySheetOpen()` 仍为 true），
//   改用面板自带的 `IconButton(onPressed: onClose)`（`:9199-9202`）；
//   两条都失败 ⇒ 报 INSTRUMENT-FAILURE，**不许**把"面板没动"读成"方向正确"。
//
// # 用法
// ```powershell
// flutter build windows --release -t lib/t74_panel_dir_probe.dart `
//   "--dart-define=DATA_DIR_OVERRIDE=D:\...\.probe\t74d-data" `
//   "--dart-define=EXPECT_AXIS=x"
// ```
// ⚠️ 必须用隔离数据目录（挂了**真的** `PlayerPage`，它会读偏好、碰 FFI）。
// ⚠️ 必须从**带着 `libmpv-2.dll` 的目录**运行（复制 `build\...\Release\`）。

import 'dart:io';
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'core/device.dart';
import 'core/ffi.dart';
import 'core/models.dart' show StreamCandidate;
import 'core/ui_prefs.dart';
import 'ui/app_theme.dart';
import 'ui/player_page.dart'
    show
        PlayerPage,
        debugPlayerAnySheetOpen,
        debugPlayerOpenStreamSheetForProbe,
        debugPlayerSetStreamsForProbe;
import 'ui/theme_bridge.dart';

/// 截图用的重绘边界（包住整棵 UI）
final _rootKey = GlobalKey();

const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

/// 本构建期望面板往哪个轴滑出（`x` = 右，`y` = 下）
///
/// ★ 用**编译期开关**而不是改源码里的期望值：这样极 A / 极 B 跑的是
///   **同一份探针源码**，两次读数可直接逐字对比（唯一变量是生产常量）。
const kExpectAxis = String.fromEnvironment('EXPECT_AXIS', defaultValue: 'x');

/// 日志缓冲 —— `finish()` 会把它写成**产物文件**
///
/// ★ 为什么不只靠 stdout 重定向：本探针是 Windows **GUI** 子系统程序，
///   输出是否被父进程接住取决于句柄继承；而本仓的判据是**产物文件**
///   （「探针写了不等于跑过」，`.probe/*.txt` 才是读数）。
///   两条都写 ⇒ 任一条坏掉都还有证据。
final List<String> _log = [];

void say(String s) {
  _log.add(s);
  debugPrint('[T74D] $s');
}

int pass = 0;
int fail = 0;

void ok(String label, bool cond, [String extra = '']) {
  final line = '$label${extra.isEmpty ? '' : '  $extra'}';
  if (cond) {
    pass++;
    _log.add('✓ $line');
    debugPrint('[T74D] ✓ $line');
  } else {
    fail++;
    _log.add('✗ $line');
    debugPrint('[T74D] ✗ $line');
  }
}

/// 只打印、不计分（用于「观测到的现象」，不是判据）
void note(String s) {
  _log.add('· $s');
  debugPrint('[T74D] · $s');
}

/// 写产物文件，然后退出
///
/// ★★ `exit()` **不展开 `finally`**（它直接终止进程）⇒ 每一条退出路径
///   都必须先调用本函数。否则中途中止的那一次会**不留产物**，
///   于是"跑了但没证据" —— 与"没跑"在事后完全无法区分。
Future<Never> finish(int code) async {
  try {
    final f = File('$_outDir\\t74d-run-$kExpectAxis.txt');
    f.writeAsStringSync('${_log.join('\n')}\n');
    debugPrint('[T74D] 产物已写 ${f.path} (${f.lengthSync()} B)');
  } catch (e) {
    debugPrint('[T74D] ★ 写产物失败: $e');
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
  exit(code);
}

// ═══════════════════════════════════════════════════════════════════════
//  数据目录 / 截图
// ═══════════════════════════════════════════════════════════════════════

Future<String> _resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isNotEmpty) {
    final d = Directory(override);
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }
  final appdata =
      Platform.environment['APPDATA'] ?? Platform.environment['HOME'] ?? '.';
  return '$appdata${Platform.pathSeparator}app.sourin.player';
}

/// 把 `_rootKey` 那棵子树光栅化成 PNG；返回 (路径, 唯一颜色数)
///
/// ★ 颜色数是**仪器自检**：全黑/全白图只有 1~2 色，那种图不能当证据。
Future<(String, int)> shoot(String name) async {
  final ctx = _rootKey.currentContext;
  if (ctx == null) {
    say('✗ $name：`_rootKey` 还没有 context（UI 没挂上）');
    return ('', 0);
  }
  final obj = ctx.findRenderObject();
  if (obj is! RenderRepaintBoundary) {
    say('✗ $name：根不是 RenderRepaintBoundary（实际 ${obj.runtimeType}）');
    return ('', 0);
  }
  final img = await obj.toImage(pixelRatio: 1.0);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  final path = '$_outDir\\t74d-$name.png';
  File(path).writeAsBytesSync(data!.buffer.asUint8List());

  final rgba = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = rgba!.buffer.asUint8List();
  final seen = <int>{};
  for (var i = 0; i + 3 < bytes.length; i += 4 * 7) {
    seen.add((bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]);
  }
  final w = img.width, h = img.height;
  img.dispose();
  say('  截图 $name: ${w}x$h  ${File(path).lengthSync()} B  '
      '采样颜色数=${seen.length}');
  return (path, seen.length);
}

// ═══════════════════════════════════════════════════════════════════════
//  元素树
// ═══════════════════════════════════════════════════════════════════════

/// 找树上那个**真实的** `PlayerPage` 元素
Element? findPlayerPageElement(Element root) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    if (e.widget is PlayerPage) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

/// 找 `data == text` 的那个 `Text` 元素
Element? findText(Element root, String text) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    final w = e.widget;
    if (w is Text && w.data == text) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

/// 定位「线路 / 清晰度」面板本体
///
/// 链：`Text('线路 / 清晰度')` → 向上找第一个 `SizedBox(width: 320)`
/// （`player_page.dart:9158`，`_StreamSheet` 的面板体）。
/// ★ 面板**没打开**时 `SheetTransition.build` 返回 `SizedBox.shrink()`
///   ⇒ `_StreamSheet` 子树根本不在树上 ⇒ 本函数返回 null。
///   这正是「关着」的读数（可当"无极"对照）。
Element? findPanelBody(Element root) {
  final label = findText(root, '线路 / 清晰度');
  if (label == null) return null;
  Element? hit;
  label.visitAncestorElements((a) {
    final w = a.widget;
    if (w is SizedBox && w.width == 320) {
      hit = a;
      return false; // 停
    }
    return true;
  });
  return hit;
}

/// 面板此刻在屏幕上的矩形（含祖先 `Transform.translate` 的位移）
Rect? panelRectNow(Element root) {
  final p = findPanelBody(root);
  final ro = p?.renderObject;
  if (ro is! RenderBox || !ro.attached) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

// ═══════════════════════════════════════════════════════════════════════
//  帧 / 指针
// ═══════════════════════════════════════════════════════════════════════

/// 等一帧真的画完（真实应用进程里没有 `tester.pump()`）
///
/// ⚠️ 加超时兜底：万一没人请求帧，`endOfFrame` 会一直挂着，
///    那会让探针**静默停住**（历史踩过：只看到超时，看不到原因）。
Future<void> pumpFrame() async {
  SchedulerBinding.instance.scheduleFrame();
  await SchedulerBinding.instance.endOfFrame
      .timeout(const Duration(seconds: 2), onTimeout: () {});
}

/// 逐帧采样面板位置
///
/// 返回 `(相对起点的毫秒数, 面板矩形)`；面板已消失的那一帧记为 null。
///
/// ★ `stopWhenGone`：一旦**曾经**定位到面板、之后又定位不到，就立刻停。
///   退出动画只有 `Motion.base` = 260ms，固定窗口要么截断要么白等 ——
///   按"面板从树上消失"停，采到的就是动画的**完整**轨迹。
/// ★ 上限 240 帧：万一 `endOfFrame` 每次都走 2s 超时，也不至于挂死。
Future<List<(double, Rect?)>> samplePanel(
  Element root,
  Duration maxTotal, {
  bool stopWhenGone = false,
}) async {
  final out = <(double, Rect?)>[];
  final t0 = DateTime.now();
  var everSeen = false;
  while (true) {
    await pumpFrame();
    final ms = DateTime.now().difference(t0).inMicroseconds / 1000.0;
    final r = panelRectNow(root);
    out.add((ms, r));
    if (r != null) everSeen = true;
    if (stopWhenGone && everSeen && r == null) break;
    if (DateTime.now().difference(t0) >= maxTotal) break;
    if (out.length >= 240) break;
  }
  return out;
}

/// 注入一次鼠标单击（不碰系统光标）
///
/// ★ 两次事件之间必须让出事件循环（`delivery_test.dart:1671-1677`：
///   同一个 microtask 里连发 down/up 会**漏掉 up**）。
/// ★ 这里**不**等 700ms（`merge_view_probe.tapAt` 要等过双击窗口）——
///   本探针要在 up 之后**立刻**逐帧采样退出动画（只有 260ms）。
Future<void> tapAt(Offset globalPos) async {
  WidgetsBinding.instance.handlePointerEvent(PointerDownEvent(
    pointer: 91,
    position: globalPos,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryMouseButton,
  ));
  await Future<void>.delayed(const Duration(milliseconds: 40));
  WidgetsBinding.instance.handlePointerEvent(PointerUpEvent(
    pointer: 91,
    position: globalPos,
    kind: PointerDeviceKind.mouse,
  ));
}

/// 先发一次 `PointerAddedEvent`，让框架知道有个鼠标设备
Future<void> injectMouseAdded(Offset globalPos) async {
  WidgetsBinding.instance.handlePointerEvent(PointerAddedEvent(
    pointer: 91,
    position: globalPos,
    kind: PointerDeviceKind.mouse,
  ));
  await Future<void>.delayed(const Duration(milliseconds: 30));
}

// ═══════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  /*
   * ★ media_kit 必须在 runApp 之前（`shell.dart:276` 的同一条，
   *   那里记录了"漏了它 ⇒ 播放器根本起不来"的事故）。
   */
  try {
    MediaKit.ensureInitialized();
    say('media_kit 已初始化');
  } catch (e) {
    final dll = File(
        '${Directory.current.path}${Platform.pathSeparator}libmpv-2.dll');
    say('默认初始化失败: $e');
    say('  → 退回显式 DLL: ${dll.path} (存在=${dll.existsSync()})');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    } else {
      say('★ 致命：找不到 libmpv-2.dll ⇒ 无法取证');
      await finish(2);
    }
  }

  try {
    await Device.init();
  } catch (e) {
    say('Device.init 失败（忽略，有兜底）: $e');
  }

  final dir = await _resolveDataDir();
  await UiPrefs.load(dir);
  final r = await SourinCore.startAsync(dir);

  debugPrint('[T74D] ══════ task-74④ 线路面板方向 —— 真机取证 ══════');
  say('数据目录: $dir');
  say('核心: $r');
  say('期望轴: kExpectAxis=$kExpectAxis  '
      '(${kExpectAxis == 'x' ? '期望 dx>5 且 dy<1（右滑）' : '期望 dy>5 且 dx<1（下滑）'})');

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.setTitle('源影 · task-74④ 面板方向探针');
  }

  final brightness = AppTheme.resolve(systemBrightness: Brightness.light);
  final theme = AppTheme.themeFor(brightness);
  final materialTheme = brightness == Brightness.light
      ? buildLightMaterialTheme(theme)
      : buildMaterialTheme(theme);

  runApp(
    RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: FLocalizations.localizationsDelegates,
        supportedLocales: FLocalizations.supportedLocales,
        theme: materialTheme,
        /*
         * ★★★ 必须逐字复刻生产外壳（`shell.dart:2854-2865`）
         *
         * 缺 `Material(type: MaterialType.transparency)` 那一层 ⇒
         * `InkWell` 抛 `Null check operator used on a null value`
         * （`Material.of`）⇒ **整页被换成 ErrorWidget 而不崩给你看**，
         * 断言只会以「找不到 XX」失败，真因只在 stderr。
         */
        builder: (context, child) => FTheme(
          data: theme,
          child: FScaffold(
            child: Material(
              type: MaterialType.transparency,
              child: child!,
            ),
          ),
        ),
        home: const PlayerPage(
          provider: 'probe',
          id: 'probe',
          title: 'task-74④ 面板方向探针',
          // 直播模式：`_isLive == true` ⇒ `_saveProgress`/`_prepareResume`
          // 都早退，不会往库里写进度（隔离库也干净些）
          liveChannelId: 'probe-ch',
        ),
      ),
    ),
  );

  await Future<void>.delayed(const Duration(milliseconds: 900));

  final root = _rootKey.currentContext as Element?;
  final pageEl = root == null ? null : findPlayerPageElement(root);

  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74D]');
  debugPrint('[T74D] ── ⓪ 仪器自检 ──');
  ok('根元素已挂上', root != null);
  ok('树上找到**真实的** PlayerPage 元素', pageEl != null,
      '${pageEl?.widget.runtimeType}');
  if (root == null || pageEl == null) {
    say('★ PlayerPage 没挂上 ⇒ 后续全部无意义，中止');
    debugPrint('[T74D] RESULT axis=$kExpectAxis verdict=INSTRUMENT-FAILURE '
        'pass=$pass fail=$fail');
    await finish(1);
  }

  await injectMouseAdded(const Offset(640, 400));

  /*
   * 「无极」对照：面板**关着**时定位链必须找不到东西。
   * ★ 没有这一条，后面"找到了"可能只是选择器太宽（匹配到别处）——
   *   而选择器太宽与"面板真的开了"在读数上**完全一样**。
   */
  final rectBeforeOpen = panelRectNow(root);
  ok('面板关着时定位链找不到它（"无极"对照）', rectBeforeOpen == null,
      'rect=$rectBeforeOpen');
  ok('关着时 debugPlayerAnySheetOpen() == false',
      debugPlayerAnySheetOpen() == false,
      '${debugPlayerAnySheetOpen()}');

  final (_, c0) = await shoot('00-mount');
  ok('挂载截图非退化（>20 色）', c0 > 20, '颜色数=$c0');

  // ─────────────────────────────────────────────────────────────────
  //  ① 注入假线路 + 打开面板 + **进入段**逐帧采样
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74D]');
  debugPrint('[T74D] ── ① 打开面板：进入段是否动画 ──');

  final injected = debugPlayerSetStreamsForProbe(const [
    StreamCandidate(url: 'https://probe.invalid/a.m3u8', label: '线路 A'),
    StreamCandidate(url: 'https://probe.invalid/b.m3u8', label: '线路 B'),
    StreamCandidate(url: 'https://probe.invalid/c.m3u8', label: '线路 C'),
  ]);
  ok('注入 3 条假线路', injected);

  final opened = debugPlayerOpenStreamSheetForProbe();
  ok('debugPlayerOpenStreamSheetForProbe 返回 true', opened);
  ok('打开后 debugPlayerAnySheetOpen() == true',
      debugPlayerAnySheetOpen() == true, '${debugPlayerAnySheetOpen()}');

  final entrySamples = await samplePanel(root, const Duration(milliseconds: 400));
  final entryRects = [
    for (final s in entrySamples)
      if (s.$2 != null) s.$2!,
  ];

  if (entryRects.isEmpty) {
    say('★ 打开后**一帧都没定位到面板** ⇒ 定位链坏了，本段无信息量，中止');
    debugPrint('[T74D] RESULT axis=$kExpectAxis verdict=INSTRUMENT-FAILURE '
        'pass=$pass fail=$fail');
    await finish(1);
  }

  final rest = entryRects.last;
  say('面板静止矩形 = '
      'left=${rest.left.toStringAsFixed(1)} top=${rest.top.toStringAsFixed(1)} '
      'w=${rest.width.toStringAsFixed(1)} h=${rest.height.toStringAsFixed(1)} '
      '(右边缘=${rest.right.toStringAsFixed(1)})');
  note('进入段采样 ${entrySamples.length} 帧，其中定位到面板 ${entryRects.length} 帧');

  /*
   * ★ 仪器自检：面板**真的是右侧抽屉**。
   *   若它是底部抽屉，`rest.top` 会很大 —— 那样"往右滑"就成了错的方向，
   *   本探针的整个前提就塌了。所以这一条必须先过。
   */
  /*
   * ★ 不能用 `MediaQuery.of(_rootKey.currentContext!)`：
   *   `_rootKey` 挂在 `MaterialApp` **外面**（`RepaintBoundary` 那层）
   *   ⇒ 那个 context 上**没有** MediaQuery 祖先 ⇒ 会抛。
   *   直接问平台视图（物理尺寸 / DPR）。
   */
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final screenW = view.physicalSize.width / view.devicePixelRatio;
  ok('仪器自检：面板贴右边（右边缘 ≈ 屏宽，宽 ≈ 320）',
      (rest.right - screenW).abs() < 2 && (rest.width - 320).abs() < 2,
      'right=${rest.right.toStringAsFixed(1)} 屏宽=$screenW '
      '宽=${rest.width.toStringAsFixed(1)}');

  final entryDx = entryRects.map((r) => r.left).reduce(max) -
      entryRects.map((r) => r.left).reduce(min);
  final entryDy =
      entryRects.map((r) => r.top).reduce(max) - entryRects.map((r) => r.top).reduce(min);
  note('进入段位移范围: dx=${entryDx.toStringAsFixed(2)} '
      'dy=${entryDy.toStringAsFixed(2)}  （源码说进入直接赋 1.0 ⇒ 期望全为 0）');
  ok('① 进入段面板**不动**（dx≈0 且 dy≈0）⇒ Owner 说的"从上往下出现"'
      '不可能发生在进入', entryDx < 1.0 && entryDy < 1.0,
      'entryDx=${entryDx.toStringAsFixed(2)} entryDy=${entryDy.toStringAsFixed(2)}');

  final (_, c1) = await shoot('01-sheet-open');
  ok('面板打开截图非退化（>20 色）', c1 > 20, '颜色数=$c1');

  // ─────────────────────────────────────────────────────────────────
  //  ② 走**真实用户路径**关闭（点面板外空白）⇒ 退出段逐帧采样
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74D]');
  debugPrint('[T74D] ── ② 点面板外空白关闭 ⇒ 退出段逐帧采样 ──');

  final blank = Offset(rest.left / 2, rest.center.dy); // 面板**左侧**的空白
  say('点空白处: (${blank.dx.toStringAsFixed(1)}, '
      '${blank.dy.toStringAsFixed(1)}) —— 期望命中 _SheetScrim.onTap');

  final exitFuture = samplePanel(
    root,
    const Duration(milliseconds: 900),
    stopWhenGone: true,
  );
  await tapAt(blank);
  final exitSamples = await exitFuture;

  final closedNow = await () async {
    for (var i = 0; i < 20; i++) {
      if (debugPlayerAnySheetOpen() == false) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return debugPlayerAnySheetOpen() == false;
  }();

  if (!closedNow) {
    /*
     * ★ 兜底：点空白没关掉 ⇒ 改用面板自带的关闭按钮（`:9199-9202`）。
     *   两条路都走不通才算仪器故障 —— 但**不许**把"面板没动"读成"方向对"。
     */
    say('★ 点空白没关掉（anySheetOpen=${debugPlayerAnySheetOpen()}）'
        ' ⇒ 改用面板自带关闭按钮');
    final closeBtn = Offset(rest.right - 40, rest.top + 40);
    final exitFuture2 = samplePanel(
      root,
      const Duration(milliseconds: 900),
      stopWhenGone: true,
    );
    await tapAt(closeBtn);
    final exitSamples2 = await exitFuture2;
    final closed2 = debugPlayerAnySheetOpen() == false;
    if (!closed2) {
      say('★ 两条真实关闭路径**都失败** ⇒ INSTRUMENT-FAILURE，本段不产出方向结论');
      debugPrint('[T74D] RESULT axis=$kExpectAxis verdict=INSTRUMENT-FAILURE '
          'pass=$pass fail=$fail');
      await finish(1);
    }
    say('兜底路径（关闭按钮）成功');
    exitSamples
      ..clear()
      ..addAll(exitSamples2);
  }
  ok('② 走真实用户路径 ⇒ 面板真的关掉了（anySheetOpen == false）', closedNow);

  final exitRects = [
    for (final s in exitSamples)
      if (s.$2 != null) s.$2!,
  ];
  if (exitRects.isEmpty) {
    say('★ 退出段一帧都没定位到面板 ⇒ 采不到位移，中止');
    debugPrint('[T74D] RESULT axis=$kExpectAxis verdict=INSTRUMENT-FAILURE '
        'pass=$pass fail=$fail');
    await finish(1);
  }

  // 逐帧打印（这就是原始证据）
  say('退出段逐帧位置（ms, left, top, right）:');
  for (final s in exitSamples) {
    final r = s.$2;
    if (r == null) {
      say('    ${s.$1.toStringAsFixed(1).padLeft(7)}   (面板已从树上移除)');
    } else {
      say('    ${s.$1.toStringAsFixed(1).padLeft(7)}   '
          '${r.left.toStringAsFixed(1).padLeft(7)} '
          '${r.top.toStringAsFixed(1).padLeft(7)} '
          '${r.right.toStringAsFixed(1).padLeft(7)}');
    }
  }

  final xs = exitRects.map((r) => r.left).toList();
  final ys = exitRects.map((r) => r.top).toList();
  final dx = xs.reduce(max) - xs.reduce(min);
  final dy = ys.reduce(max) - ys.reduce(min);
  final first = exitRects.first;
  final last = exitRects.last;

  note('退出段采样 ${exitSamples.length} 帧，其中定位到面板 ${exitRects.length} 帧');
  note('首帧 (${first.left.toStringAsFixed(1)}, ${first.top.toStringAsFixed(1)}) '
      '→ 末帧 (${last.left.toStringAsFixed(1)}, ${last.top.toStringAsFixed(1)})');
  note('位移范围 dx=${dx.toStringAsFixed(2)}  dy=${dy.toStringAsFixed(2)}');

  // ─────────────────────────────────────────────────────────────────
  //  ③ 方向判读
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74D]');
  debugPrint('[T74D] ── ③ 方向判读（期望轴 = $kExpectAxis）──');

  /*
   * ★ 判据用"哪个轴动了"，不用"位移恰好等于 24"：
   *   退出动画只有 260ms，采样窗口若在动画结束前截断，末帧位移 < 24 是正常的
   *   ⇒ 用 24 当判据会把**采样时机**的差异误判成**方向**错误。
   *   方向判据（>5 像素）与"另一个轴不动"（<1 像素）才是要证的命题。
   */
  final bool axisOk;
  if (kExpectAxis == 'x') {
    axisOk = dx > 5.0 && dy < 1.0;
  } else {
    axisOk = dy > 5.0 && dx < 1.0;
  }

  ok('③ 面板滑出方向 = 期望轴（$kExpectAxis）', axisOk,
      'dx=${dx.toStringAsFixed(2)} dy=${dy.toStringAsFixed(2)}');

  final (_, c2) = await shoot('02-after-exit');
  ok('关闭后截图非退化（>20 色）', c2 > 20, '颜色数=$c2');

  // 机器可 diff 的一行（极 A / 极 B 逐字对比就靠它）
  //
  // ★ 走 `say()` 而不是 `debugPrint()`：这一行必须进**产物文件** ——
  //   极 A / 极 B 的对比是在两次运行的 `.probe\t74d-run-{x,y}.txt` 之间做的，
  //   只在 stdout 里就等于没留下。
  say('VERDICT axis=$kExpectAxis '
      'dx=${dx.toStringAsFixed(2)} dy=${dy.toStringAsFixed(2)} '
      'entryDx=${entryDx.toStringAsFixed(2)} '
      'entryDy=${entryDy.toStringAsFixed(2)} '
      'restLeft=${rest.left.toStringAsFixed(1)} '
      'restTop=${rest.top.toStringAsFixed(1)} '
      'axisOk=$axisOk');

  say('');
  say('══════ 结果: pass=$pass fail=$fail ══════');
  say('RESULT axis=$kExpectAxis '
      'verdict=${axisOk ? 'PASS' : 'FAIL'} pass=$pass fail=$fail');

  await finish(fail == 0 ? 0 : 1);
}
