// ═══════════════════════════════════════════════════════════════════════
//  t377 -- 产品真的**告诉用户**了吗？
//          「输出层建不起来」的横幅 + 生产看门狗判决，端到端取证
// ═══════════════════════════════════════════════════════════════════════
//
// # 这一轮补的是什么缺口
//
// `README-交付说明.md:126-129` 自己承认过（便签 `:394-395` 同）：
// ```text
// 输出层建不起来时没有任何降级、也没有用户可见的报错，全程静默
// ```
// 本轮把它修成了产品行为（`lib\ui\player_page.dart`）：
// ```text
// _watchVideoOutput(token)   ← 看门狗（判据：有视频轨 && vo-configured != yes）
// _videoOutputDead           ← 它立起来的旗
// _VideoOutputDeadBanner     ← 用户看到的那一条
// ```
// 判据本身已由 `.probe\t376_matrix.py` 在**五臂**上验证（`pass=14 fail=0`）。
//
// # 但「判据对」不等于「装进产品后判决对」
//
// 产品里的时序、代次号、`mounted` 守卫、`dispose` 交互、叠加层顺序，
// 任何一处都能让判决**永远立不起来**或**永远立着**。所以本探针：
//   * 不走"复刻判据"的路 —— 直接调**生产方法**
//     `debugPlayerWatchVideoOutputForProbe()`（内部就是 `_watchVideoOutput`）
//   * 不只读字段 —— 断言它**到了屏幕上**（横幅元素真的在渲染树里）
//
// # 为什么横幅验证要靠"注入"而不是等真失败
//
// 真失败需要一台 GL 上下文建不起来的机器（本机只有模拟器 `vo=gpu` 满足）。
// 但「横幅渲染对不对」（位置/文案/不盖画面/按钮能用）是**独立的另一件事**，
// 必须能在任何机器上、**可重复**地验证。`debugPlayerSetVideoOutputDeadForProbe`
// 就是为此存在的注入口（生产代码里零调用点）。
//
// ★★ 注入式验证的致命陷阱：**必须配阴性对照**。
//    「注入 true 后找得到横幅」这句话，若选择器写错了也照样失败 ——
//    但反过来，「注入 false 时找不到横幅」若选择器写错了会**假通过**。
//    所以本探针把 ①（false ⇒ 找不到）和 ②（true ⇒ 找得到）**成对**做，
//    两次读同一个选择器 ⇒ 选择器的灵敏度被同时证明。
//
// # 为什么要用 push 路由而不是 `home:`
//
// 横幅上的「返回」按钮走 `_exitPlayer()` → `Navigator.maybePop()`。
// 若 `PlayerPage` 挂在 `home:`，它就是**最后一个路由**，`maybePop()` 什么也不做
// ⇒ 「按钮能用」这条断言就成了**空通过**（点了没反应，但读数是"没崩"）。
// 所以本探针把它 push 到一个占位首页之上，然后断言**路由真的被弹掉了**。
//
// # 运行环境
//
// ```text
// Windows : 必须在带 libmpv-2.dll 的目录里跑（复制 build\...\Release\）
// Android : 产物是 x86_64 APK（模拟器）
// ```
// 输出：`<workdir>/t377_report.txt` + `<workdir>/t377-*.png`
//
// 退出协议：`exit(fail == 0 ? 0 : 1)` + `RESULT pass=N fail=M skipped=K`。

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/device.dart';
import 'core/ffi.dart';
import 'core/ui_prefs.dart';
import 'shell.dart';
import 'ui/app_theme.dart';
import 'ui/player_page.dart'
    show
        PlayerPage,
        debugPlayerOpenForProbe,
        debugPlayerPositionSeconds,
        debugPlayerSetVideoOutputDeadForProbe,
        debugPlayerVideoOutputDead,
        debugPlayerVideoOutputGateForProbe,
        debugPlayerWatchVideoOutputForProbe;

const String kTag = '[T377]';

/// 截图用的重绘边界（包住整棵 UI）
final _rootKey = GlobalKey();

String _workDir = '';
final StringBuffer _rep = StringBuffer();
int _pass = 0;
int _fail = 0;
int _skip = 0;

void _emit(String line) {
  _rep.writeln(line);
  debugPrint('$kTag $line');
}

void ok(String label, bool cond, [String extra = '']) {
  if (cond) {
    _pass++;
  } else {
    _fail++;
  }
  _emit('  [${cond ? 'PASS' : 'FAIL'}] $label'
      '${extra.isEmpty ? '' : '   $extra'}');
}

void note(String s) => _emit('  · $s');

/// 仪器失败 ⇒ 这一段**不产出结论**（不是"产品没通过"）
void skip(String why) {
  _skip++;
  _emit('  [SKIP] 未评估（仪器/环境不足，**不是**产品结论）: $why');
}

Future<Never> _finish(int code) async {
  final path = '$_workDir/t377_report.txt';
  final effective = (code != 0 || _fail > 0 || _skip > 0) ? 1 : 0;
  final body = StringBuffer()
    ..writeln('TAG t377-banner')
    ..writeln('EXIT $effective')
    ..writeln('RESULT pass=$_pass fail=$_fail skipped=$_skip')
    ..writeln('---')
    ..write(_rep);
  try {
    File(path).writeAsStringSync(body.toString());
    debugPrint('$kTag ARTIFACT $path (${File(path).lengthSync()} B)');
  } catch (e) {
    debugPrint('$kTag ★ ARTIFACT 写盘失败: $e');
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));
  exit(effective);
}

Future<String> _resolveWorkDir() async {
  if (Platform.isAndroid) {
    try {
      final d = await getExternalStorageDirectory();
      if (d != null) return d.path;
    } catch (_) {}
    return '/storage/emulated/0/Android/data/app.sourin.sourin_spike/files';
  }
  return r'D:\WishProject\sourin-flutter-spike\.probe';
}

Future<String> _resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isNotEmpty) {
    final d = Directory(override);
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }
  final base =
      Platform.environment['APPDATA'] ?? Platform.environment['HOME'] ?? '.';
  return '$base${Platform.pathSeparator}app.sourin.player';
}

/// ④ 用的媒体：Windows 用本机样本；Android 用 t285 那套已在设备上的文件
String _defaultMedia() {
  if (Platform.isAndroid) {
    return '/storage/emulated/0/Android/data/app.sourin.sourin_spike/files/'
        'media/t285_osd_test.mkv';
  }
  return r'D:\WishProject\sourin-flutter-spike\hevc_sample.mp4';
}

/// 运行期配置（可选）：`<workdir>/t377_config.txt`，`key=value` 每行一条
///
/// 支持 `media=<path>` —— 让**同一个 APK** 能在不同机器上换媒体，
/// 而不必为每台机器重编（同 t376 已验证的做法）。
String _cfgMedia = '';

void _loadConfig() {
  final f = File('$_workDir/t377_config.txt');
  if (!f.existsSync()) return;
  for (final raw in f.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final i = line.indexOf('=');
    if (i <= 0) continue;
    final k = line.substring(0, i).trim();
    final v = line.substring(i + 1).trim();
    if (k == 'media') _cfgMedia = v;
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  元素树读数器
// ═══════════════════════════════════════════════════════════════════════

/// 按**私有类名**找元素
///
/// `_VideoOutputDeadBanner` 是私有类，外部拿不到类型，
/// 但 `runtimeType.toString()` 就是 `'_VideoOutputDeadBanner'`。
///
/// ⚠️ 用私有类名当选择器**必须**配阴性/阳性对照（见文件头）——
///    否则「找不到」既可能是"横幅没画"，也可能是"选择器写错了"。
Element? findByTypeName(Element root, String typeName) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    if (e.widget.runtimeType.toString() == typeName) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

Element? findPlayerPage(Element root) => findByTypeName(root, 'PlayerPage');

/// 收集子树里所有 `Text` 的字面量（用于断言文案）
void collectTexts(Element e, List<String> out) {
  final w = e.widget;
  if (w is Text && w.data != null) out.add(w.data!);
  e.visitChildren((c) => collectTexts(c, out));
}

/// 子树里第一个 `OutlinedButton`（横幅上的「返回」）
OutlinedButton? findOutlinedButton(Element e) {
  OutlinedButton? hit;
  void walk(Element x) {
    if (hit != null) return;
    final w = x.widget;
    if (w is OutlinedButton) {
      hit = w;
      return;
    }
    x.visitChildren(walk);
  }

  walk(e);
  return hit;
}

/// 元素的全局矩形（拿不到就 null）
Rect? rectOf(Element? e) {
  if (e == null) return null;
  final ro = e.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  final tl = ro.localToGlobal(Offset.zero);
  return tl & ro.size;
}

/*
 * ══════════════════════════════════════════════════════════════════════
 * ★★★ 几何读数必须**显式格式化**，不能靠 `$rect` 插值（2026-09-30 实测）
 * ══════════════════════════════════════════════════════════════════════
 *
 * # 症状
 *
 * 报告里出现：
 * ```text
 * · 横幅矩形 = Instance of 'Rect'
 * · 横幅量到的 RenderObject = _RenderColoredBox  size=Instance of 'Size'
 * · 按钮中心 = Instance of 'Offset'
 * ```
 * 而 ⓪ 的几何断言失败时，读数长这样 ⇒ **根本没法判断**
 * 是"真的内缩了"还是"根本没量到"。
 *
 * # 根因
 *
 * 在这个 **release AOT** 构建里，`dart:ui` 的几何类
 * （`Rect` / `Size` / `Offset`）的 `toString()` 没有生效，
 * 走的是 `Object.toString()` ⇒ `Instance of 'X'`。
 *
 * ⚠️ 注意：**同一份报告里** ② 段那几条断言打出的
 * `left=0.0 right=1280.0` 是可读的 —— 因为那是**我手写的**
 * `${r.left}`（`double` 插值正常），而不是 `${r}`。
 * ⇒ 教训：**"读数可读"不是自动的**；几何对象必须逐字段取。
 */
String fmtRect(Rect? r) => r == null
    ? 'null'
    : 'L=${r.left.toStringAsFixed(1)} T=${r.top.toStringAsFixed(1)} '
        'R=${r.right.toStringAsFixed(1)} B=${r.bottom.toStringAsFixed(1)} '
        'W=${r.width.toStringAsFixed(1)} H=${r.height.toStringAsFixed(1)}';

String fmtSize(Size? s) => s == null
    ? 'null'
    : 'W=${s.width.toStringAsFixed(1)} H=${s.height.toStringAsFixed(1)}';

String fmtOffset(Offset? o) =>
    o == null ? 'null' : '(${o.dx.toStringAsFixed(1)}, ${o.dy.toStringAsFixed(1)})';

Element? _rootEl() => _rootKey.currentContext as Element?;

// ═══════════════════════════════════════════════════════════════════════
//  帧 / 指针 / 截图
// ═══════════════════════════════════════════════════════════════════════

Future<void> pumpFrame() async {
  SchedulerBinding.instance.scheduleFrame();
  await SchedulerBinding.instance.endOfFrame
      .timeout(const Duration(seconds: 2), onTimeout: () {});
}

/// 注入一次点击（**合成事件**，不碰 Owner 的系统光标）
///
/// ⚠️ 同一个 microtask 里连发 down/up 会漏掉 up（历史实测）
///    ⇒ 中间必须让出事件循环。
Future<void> tapAt(Offset p) async {
  WidgetsBinding.instance.handlePointerEvent(PointerDownEvent(
    pointer: 93,
    position: p,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryMouseButton,
  ));
  await Future<void>.delayed(const Duration(milliseconds: 40));
  WidgetsBinding.instance.handlePointerEvent(PointerUpEvent(
    pointer: 93,
    position: p,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryMouseButton,
  ));
  await Future<void>.delayed(const Duration(milliseconds: 60));
}

/// 光栅化根子树 → PNG，返回 `(路径, 采样颜色数)`
///
/// 颜色数是**仪器自检**：全黑/全白图只有 1~2 色，那种图不能当证据。
Future<(String, int)> shoot(String name) async {
  final ctx = _rootKey.currentContext;
  if (ctx == null) {
    _emit('  ★ $name: `_rootKey` 没有 context');
    return ('', 0);
  }
  final obj = ctx.findRenderObject();
  if (obj is! RenderRepaintBoundary) {
    _emit('  ★ $name: 根不是 RenderRepaintBoundary（${obj.runtimeType}）');
    return ('', 0);
  }
  final img = await obj.toImage(pixelRatio: 1.0);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  final path = '$_workDir/t377-$name.png';
  File(path).writeAsBytesSync(png!.buffer.asUint8List());

  final rgba = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = rgba!.buffer.asUint8List();
  final seen = <int>{};
  for (var i = 0; i + 3 < bytes.length; i += 4 * 7) {
    seen.add((bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]);
  }
  final w = img.width, h = img.height;
  img.dispose();
  _emit('  · 截图 $name: ${w}x$h  ${File(path).lengthSync()} B  '
      '采样颜色数=${seen.length}');
  return (path, seen.length);
}

Future<bool> waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 15),
  String label = '',
}) async {
  final t0 = DateTime.now();
  while (DateTime.now().difference(t0) < timeout) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  _emit('  ⏱ 等超时: $label（${timeout.inSeconds}s）');
  return false;
}

// ═══════════════════════════════════════════════════════════════════════
//  首页占位 + 打开播放页
// ═══════════════════════════════════════════════════════════════════════

/*
 * ══════════════════════════════════════════════════════════════════════
 * ★★★ 外壳 = **生产本体** `SourinApp`，不再是复刻（2026-09-30 第二次纠正）
 * ══════════════════════════════════════════════════════════════════════
 *
 * # 为什么"复刻对了位置"还不够
 *
 * 上一版把 `FScaffold` 从 `builder` 移到 `home`（位置对了），
 * 「撑满宽」从 FAIL 变成 PASS。但**只读验证者**（`fix-window-shadow`）
 * 指出一个我无法反驳的证据边界：
 *
 * > 探针改后的 `builder` 只有 `FTheme` + `Material`，**省掉了生产的
 * > `FToaster` / `WindowFrame` / `ColoredBox` / `RemoteBridgeHost` /
 * > `_TitleBarHost` 五层** ⇒ 探针的「路由满宽」**不能单独**证明
 * > 生产也满宽。
 *
 * 他用源码逐层证明那五层都是 no-op（`Overlay` 的
 * `size = constraints.biggest`、`Stack(fit: StackFit.expand)`、
 * `build() => child`、`Expanded(ClipRect(...))`），但那是**推理**，
 * 不是**读数**。而本轮的主题恰恰是"把自认的缺口变成一次测量"。
 *
 * # 所以：不再复刻，直接挂生产
 *
 * 复刻外壳是一条**永远追不上**的路 —— 每加一层就要重新论证一次。
 * 而 lib 里**已经有 9 个探针挂的是生产本体**（`grep 'SourinApp('`）：
 * `lib\t74_perf_probe.dart:978` · `lib\t370_browse_probe.dart:510` ·
 * `lib\t84_greyband_probe.dart:440` · `lib\t76_live_tab_probe.dart:617` ·
 * `lib\shell.dart:546`（真入口）· `lib\t369_catbar_probe.dart:468` ·
 * `lib\t92_preset_probe.dart:433` · `lib\t87_cloudsync_probe.dart:606`。
 *
 * `t370_browse_probe.dart:507` 那行注释逐字就是
 * `// ★ 外壳 = 生产本体（不是复刻）`。
 *
 * # 挂生产本体会自动带上什么
 *
 * ```text
 * ① builder 六层（FTheme → FToaster → WindowFrame → ColoredBox →
 *    RemoteBridgeHost → _TitleBarHost）—— 全是**真的**
 * ② ★ _TitleBarHost 的 **40px 标题栏**（桌面端）——
 *    这是复刻版**从来没有**的东西，也是"每层占多少"那一层偏差。
 *    实测含义：被 push 的路由矩形是 T=40 B=800，不是 T=0 B=800。
 * ③ ShellPage 作为 home（`lib\shell.dart:1486` 带 `debugShellKey`）
 * ④ 生产自己的 Navigator —— 从 `debugShellKey.currentContext` 取，
 *    与 `t370_browse_probe.dart:615-623` 同一手法
 * ```
 *
 * # 代价（照实记）
 *
 * 首屏要等 `ShellPage` 真正挂上（它有核心启动 / 页面切换等逻辑），
 * 所以 `runApp` 之后必须 `waitUntil(debugShellKey.currentState != null)`，
 * 不能像复刻版那样只等固定 900ms。
 */

/// 生产 Navigator —— 从 `debugShellKey.currentContext` 取
///
/// ★ 不能再用探针自己的 `_navKey`：外壳是生产本体，它内部的
///   `MaterialApp` 用的是**生产自己的** navigator。往探针那个 key 上
///   push 会 push 到一棵**不在屏幕上的**树上（或直接 null）。
NavigatorState? _prodNav;

Future<void> openPlayerPage() async {
  final nav = _prodNav;
  if (nav == null) return;
  unawaited(nav.push(MaterialPageRoute<void>(
    builder: (_) => const PlayerPage(
      provider: 'probe',
      id: 'probe',
      title: 't377 横幅探针',
      // 直播模式：`_isLive == true` ⇒ `_saveProgress`/`_prepareResume` 都早退
      // ⇒ 合成播放不会往库里写进度（隔离库也干净些）
      liveChannelId: 'probe-ch',
    ),
  )));
  await waitUntil(
    () {
      final r = _rootEl();
      return r != null && findPlayerPage(r) != null;
    },
    timeout: const Duration(seconds: 12),
    label: 'PlayerPage 出现在树上',
  );
}

// ═══════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ★ media_kit 必须在 runApp 之前（`shell.dart:276` 记录过漏了它的事故）
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    final dll = File(
        '${Directory.current.path}${Platform.pathSeparator}libmpv-2.dll');
    _emit('默认初始化失败: $e');
    _emit('  → 退回显式 DLL: ${dll.path} (存在=${dll.existsSync()})');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    } else {
      _emit('★ 致命：找不到 libmpv-2.dll ⇒ 无法取证');
      _workDir = await _resolveWorkDir();
      await _finish(2);
    }
  }

  _workDir = await _resolveWorkDir();
  _loadConfig();

  try {
    await Device.init();
  } catch (e) {
    _emit('Device.init 失败（忽略，有兜底）: $e');
  }

  final dir = await _resolveDataDir();
  await UiPrefs.load(dir);

  // ★ 强制浅色：只去掉"跑的那一刻系统主题"这个外部变量，
  //   渲染结果与用户配置等价；写的是隔离目录，不碰用户偏好文件。
  //   （照 `t370_browse_probe.dart:464`）
  AppTheme.setMode(AppThemeMode.light);

  /*
   * ★★ `coreError` 必须**接住并传给 `SourinApp`**（照 `t370:466-473`）
   *
   * 这是"挂生产本体"的一个**代价**：复刻版里核心失败无所谓（探针自己
   * 造 `home`），但生产 `ShellPage` 会把 `coreError` 一路传下去，
   * 内容区被换成 `_CoreErrorView`（`shell.dart:3150-3167`）。
   * 那虽然不是"整页起不来"，但会让 ⓪ 段之后的一切都跑在一个
   * **不是首页**的界面上 ⇒ 读数不能代表生产。
   * ⇒ 所以：① 接住异常 ② 把字符串传进去（生产自己决定怎么显示）
   * ③ 并在日志里把它打出来，让"核心是否正常"成为可查的读数。
   */
  String? coreError;
  try {
    final r = await SourinCore.startAsync(dir);
    _emit('核心: $r');
  } catch (e) {
    coreError = e.toString();
    _emit('★ 核心启动失败 = $coreError');
  }

  // ★ 玻璃 shader 预热（`shell.dart:542`）。不致命，但生产会调 ⇒ 探针也调，
  //   否则首帧渲染路径与生产不同。
  try {
    await LiquidGlassWidgets.initialize();
    _emit('LiquidGlassWidgets.initialize 完成');
  } catch (e) {
    _emit('LiquidGlassWidgets.initialize 失败（不致命）: $e');
  }

  final media = _cfgMedia.isNotEmpty ? _cfgMedia : _defaultMedia();

  _emit('══════ t377 「输出层建不起来」的用户可见提示 —— 端到端取证 ══════');
  _emit('平台: ${Platform.operatingSystem}  工作目录: $_workDir');
  _emit('数据目录: $dir');
  _emit('媒体: $media (存在=${File(media).existsSync()})');

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    /*
     * ★ 窗口选项逐字复刻生产（`lib\shell.dart:309-395`）：
     *   size 1280x800 / minimumSize 900x600 / center /
     *   titleBarStyle: hidden / backgroundColor: transparent。
     *   `titleBarStyle: hidden` 才让自绘标题栏占住顶部 40px，
     *   否则 y 坐标全部错位（照 `t370_browse_probe.dart:484-492`）。
     * ⚠️ 刻意不调 `windowManager.focus()`（生产 `shell.dart:399` 有）
     *    —— 那会抢 Owner 的焦点。
     * ★ 必须 `show()`：窗口不可见时引擎可能整帧不产出 ⇒ 退化图 ⇒ 假绿。
     */
    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(900, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
      title: '源影 · t377 横幅探针',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
    });
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ 外壳 = **生产本体** `SourinApp`（2026-09-30 第二次纠正）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 为什么"复刻对了位置"还不够
   *
   * 上一版把 `FScaffold` 从 `builder` 移到 `home`（位置对了），
   * 「撑满宽」从 FAIL 变成 PASS。但**只读验证者**（`fix-window-shadow`）
   * 指出一个我无法反驳的证据边界：
   *
   * > 探针改后的 `builder` 只有 `FTheme` + `Material`，**省掉了生产的
   * > `FToaster` / `WindowFrame` / `ColoredBox` / `RemoteBridgeHost` /
   * > `_TitleBarHost` 五层** ⇒ 探针的「路由满宽」**不能单独**证明
   * > 生产也满宽。
   *
   * 他用源码逐层证明那五层都是 no-op（`Overlay` 的
   * `size = constraints.biggest`、`Stack(fit: StackFit.expand)`、
   * `build() => child`、`Expanded(ClipRect(...))`），但那是**推理**，
   * 不是**读数**。而本轮的主题恰恰是"把自认的缺口变成一次测量"。
   *
   * # 所以：不再复刻，直接挂生产
   *
   * 复刻外壳是一条**永远追不上**的路 —— 每加一层就要重新论证一次。
   * 而 lib 里**已经有 9 个探针挂的是生产本体**（`grep 'SourinApp('`）：
   * `lib\t74_perf_probe.dart:978` · `lib\t370_browse_probe.dart:510` ·
   * `lib\t84_greyband_probe.dart:440` · `lib\t76_live_tab_probe.dart:617` ·
   * `lib\shell.dart:546`（真入口）· `lib\t369_catbar_probe.dart:468` ·
   * `lib\t92_preset_probe.dart:433` · `lib\t87_cloudsync_probe.dart:606`。
   *
   * `t370_browse_probe.dart:507` 那行注释逐字就是
   * `// ★ 外壳 = 生产本体（不是复刻）`。
   *
   * # 挂生产本体会自动带上什么
   *
   * ```text
   * ① builder 六层（FTheme → FToaster → WindowFrame → ColoredBox →
   *    RemoteBridgeHost → _TitleBarHost）—— 全是**真的**
   * ② ★ _TitleBarHost 的 **40px 标题栏**（桌面端，`_CustomTitleBar
   *    .preferredSize => const Size.fromHeight(40)`，`shell.dart:4036`）
   *    —— 这是复刻版**从来没有**的东西，也是"每层占多少"那一层偏差。
   *    实测含义：被 push 的路由矩形是 T=40 B=800（高 760），
   *    **不是** T=0 B=800。复刻版与生产系统性差 40px。
   * ③ ShellPage 作为 home（`lib\shell.dart:1486` 带 `debugShellKey`）
   * ④ 生产自己的 Navigator —— 从 `debugShellKey.currentContext` 取，
   *    与 `t370_browse_probe.dart:615-623` 同一手法
   * ```
   *
   * # 代价（照实记）
   *
   * 首屏要等 `ShellPage` 真正挂上（它有核心启动 / 页面切换等逻辑），
   * 所以 `runApp` 之后必须 `waitUntil(debugShellKey.currentState != null)`，
   * 不能像复刻版那样只等固定 900ms。
   *
   * # 这条编辑让验证者的缺口 3 从"推理"变成"读数"
   *
   * 探针里再也没有"复刻的层"可以争论：屏幕上跑的就是生产 `SourinApp`。
   */
  runApp(
    RepaintBoundary(
      key: _rootKey,
      child: SourinApp(coreError: coreError, coreDataDir: dir),
    ),
  );

  /*
   * ★★ 等**生产** `ShellPage` 真正挂上（照 `t370_browse_probe.dart:591`）
   *
   * 复刻版只要等固定 900ms 就行（`home` 是 `_Host`，纯静态）。
   * 挂生产本体不行：`ShellPage` 自己有启动逻辑（核心就绪 / 页面切换 /
   * 远端桥），首帧未必立刻可用 ⇒ 必须轮询 `debugShellKey.currentState`。
   */
  final shellUp = await waitUntil(
    () => debugShellKey.currentState != null,
    timeout: const Duration(seconds: 20),
    label: '生产 ShellPage 挂上',
  );
  ok('⓪ 生产 `ShellPage` 已挂载（拿到 `debugShellKey.currentState`）', shellUp);

  /*
   * ★★ `coreError` 传下去之后会发生什么（**读源码纠正过一次**）
   *
   * 我先写下的推断是「核心失败 ⇒ `ShellPage` 被换成启动失败页 ⇒
   * `debugShellKey.currentState` 永远为 null」。**读源码证明这是错的**：
   * `shell.dart:3150-3167` 里 `coreError != null` 只把**内容区**换成
   * `_CoreErrorView`（`KeyedSubtree(key: ValueKey('core-error'))`），
   * `ShellPage` 本身照常挂载、`debugShellKey` 照常有 state。
   *
   * ⇒ 所以 `shellUp == false` **不能**归因于核心失败。
   *   这里改成照实报"两种可能都要查"，而不是断言一个我没验证过的因果。
   */
  if (!shellUp) {
    _emit('★ 生产 ShellPage 没挂上（等了 20s）');
    _emit('  · coreError = ${coreError ?? '（null，核心启动正常）'}');
    _emit('  · 注意：`coreError != null` 只会换掉**内容区**'
        '（`shell.dart:3150-3167`），不会阻止 `ShellPage` 挂载'
        ' ⇒ 这不是解释，两种可能都要查');
    await shoot('00-noshell');
    await _finish(2);
  }

  final shellEl = debugShellKey.currentContext;
  if (shellEl == null) {
    _emit('★ `debugShellKey.currentContext` 为 null'
        '（state 在但 context 不在）⇒ 中止');
    await _finish(2);
  }
  /*
   * `shellEl` 刚判过 null 且为 null 时 `_finish` 返回 `Never`（已 exit），
   * 所以走到这里必然非空 —— lint 看不到 `Never` 的控制流。
   * （照 `t370_browse_probe.dart:623` 的同一处 ignore。）
   */
  // ignore: use_build_context_synchronously
  _prodNav = Navigator.of(shellEl);
  _emit('  · 生产 Navigator 已取得'
      '（`Navigator.of(debugShellKey.currentContext)`）');

  // ─────────────────────────────────────────────────────────────────
  _emit('');
  _emit('── ⓪ 仪器自检 ──');
  final r0 = _rootEl();
  ok('根元素已挂上', r0 != null);
  if (r0 == null) {
    await _finish(2);
  }

  final selProbe = findByTypeName(r0, '_NoSuchWidgetTypeEver');
  ok('选择器对**不存在的类名**返回 null（灵敏度下限）', selProbe == null);

  await shoot('00-host');
  await openPlayerPage();

  var root = _rootEl();
  var pageEl = root == null ? null : findPlayerPage(root);
  ok('树上找到**真实的** PlayerPage 元素', pageEl != null,
      '${pageEl?.widget.runtimeType}');
  if (pageEl == null) {
    _emit('★ PlayerPage 没挂上 ⇒ 后续全部无意义，中止');
    await _finish(2);
  }

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ 外壳位置自检（2026-09-30 第二次改写：不再写死判据）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 这条是**仪器自检**，不是产品断言
   *
   * 它证明「被 push 的路由没有被外壳内缩，且它的上边界正好是外壳
   * 留给它的内容区上边界」。**若它失败，说明外壳不对，
   * ② 段的几何断言全部不可信** —— 而不是产品坏了。
   *
   * # 为什么现在是"量出来的"而不是"写死的"
   *
   * 第一版把 `FScaffold` 放在 `MaterialApp.builder` 里（Navigator 之外）
   * ⇒ 每个路由被 forui 默认 `childPadding` 内缩 12px ⇒ ② 段「撑满宽」
   * **假失败**（`left=12.0 right=1268.0`）。
   * 第二版把 `FScaffold` 移到 `home`，位置对了，但判据写死成
   * `left==0 && right==屏宽` —— 那对**复刻外壳**成立，对**生产外壳不成立**：
   *
   * ```text
   * 生产 `_TitleBarHost`（`shell.dart:3909-4009`）在桌面端返回
   *   Column[ AnimatedSize(_CustomTitleBar), Expanded(ClipRect(child)) ]
   * 而 `_CustomTitleBar.preferredSize => const Size.fromHeight(40)`
   *   （`shell.dart:4036`）
   * ⇒ 被 push 的路由矩形是 **T=40 B=800**（高 760），不是 T=0 B=800。
   * ```
   *
   * ★ 写死 `top==0` 会**假失败**；写死 `top==40` 会在标题栏高度变化时
   *   **假通过**。⇒ 正确做法：**量标题栏自己**，再断言"路由上边界 ==
   *   标题栏下边界"，两个数都来自同一棵树、同一次渲染。
   *
   * 这也顺带把"生产外壳真的在树上"变成一条读数：找得到
   * `_CustomTitleBar` 就说明 `_TitleBarHost` 是活的（它是私有类，
   * 探针 import 不到，但 `findByTypeName` 走 `runtimeType.toString()`）。
   */
  final screen0 = MediaQuery.of(_rootKey.currentContext!).size;
  /*
   * ★★★ 必须等路由转场动画结束再量几何（2026-09-30 实测抓到的假失败）
   *
   * 第一版这条判据 **FAIL**：量到 `left=12.0 right=1268.0`。
   * 但同一个 `FScaffold` 位置在 ② 段量出来的横幅却是
   * `left=0.0 right=1280.0` —— **同一个外壳，两次读数不一致**
   * ⇒ 说明问题不在外壳，在**测量的时刻**。
   *
   * `MaterialPageRoute` 的转场动画默认 ~300ms，转场中页面被
   * 平移/缩放 ⇒ 此刻量到的 `localToGlobal` 是**动画中间值**。
   * `openPlayerPage()` 里只等"PlayerPage 出现在树上"，那一瞬间
   * 路由刚开始滑入，量到的必然偏。
   *
   * ⇒ 修法：先 `pumpFrame()` 再等 600ms（> 转场时长），让动画落定。
   */
  await pumpFrame();
  await Future<void>.delayed(const Duration(milliseconds: 600));
  await pumpFrame();

  final rootTb = _rootEl()!;
  final tbEl = findByTypeName(rootTb, '_CustomTitleBar');
  final tbRect = rectOf(tbEl);
  /*
   * ★★★ ⓪b 必须是**平台条件式**判据（2026-09-30 自查抓到的探针缺陷）
   *
   * `_TitleBarHost.build` 的第一行就是（`shell.dart:3911`）：
   * ```dart
   * if (!kIsDesktop) return widget.child;
   * ```
   * ⇒ **Android 上根本没有 `_CustomTitleBar`**，路由上边界就是 0。
   *
   * 我第一版把 ⓪b 写成无条件的
   * 「路由上边界 == 标题栏下边界」—— 那在 Android 上
   * `tbRect == null` ⇒ `topOk == false` ⇒ **假失败**。
   * 这与第一版「写死 `top==0`」是**同一个错误的两面**：
   * 都是把"桌面端的形态"当成了"通用形态"。
   *
   * ⇒ 正确写法：**先看标题栏在不在**，再按对应形态断言：
   * ```text
   * 标题栏在（桌面）  ⇒ 路由 top == 标题栏 bottom（量出来的）
   * 标题栏不在（移动）⇒ 路由 top == 0
   * ```
   * 两个分支都写进 extra，让"走了哪条"成为读数。
   */
  final hasTitleBar = tbEl != null && tbRect != null;
  if (hasTitleBar) {
    ok('⓪ 生产自绘标题栏 `_CustomTitleBar` 在树上（⇒ `_TitleBarHost` 是活的）',
        true, '标题栏矩形=${fmtRect(tbRect)}');
  } else {
    note('⓪ 树上没有 `_CustomTitleBar` —— 移动端 `_TitleBarHost` 直接返回 child'
        '（`shell.dart:3911 if (!kIsDesktop) return widget.child;`）'
        '⇒ 路由上边界应为 0');
  }

  final pageRect = rectOf(pageEl);
  /*
   * 判据（全部来自同一次渲染）：
   *   · 左右：路由必须撑满窗口宽（左 0、右 == 屏宽）—— 这条对
   *     复刻版和生产版**都**成立，是本轮真正要证明的事。
   *   · 上边界：桌面 ⇒ == 标题栏下边界（**量出来的**，不写死 40）；
   *            移动 ⇒ == 0。
   *   · 下边界：== 屏高。
   */
  final expectedTop = hasTitleBar ? tbRect.bottom : 0.0;
  final topOk = pageRect != null &&
      (pageRect.top - expectedTop).abs() <= 1.0;
  final bottomOk =
      pageRect != null && (pageRect.bottom - screen0.height).abs() <= 1.0;
  final widthOk = pageRect != null &&
      pageRect.left.abs() <= 1.0 &&
      (pageRect.right - screen0.width).abs() <= 2.0;

  ok('⓪a 被 push 的路由**撑满窗口宽**（left==0 且 right==屏宽）', widthOk,
      '路由矩形=${fmtRect(pageRect)} 屏宽=${screen0.width}'
      '（若失败 ⇒ 外壳位置错了，② 的几何判据不可信）');

  ok('⓪b 路由上边界 == 外壳留给它的内容区上边界'
      '（桌面=标题栏下边界，移动=0；**量出来的**，不写死）', topOk,
      '形态=${hasTitleBar ? '桌面（有标题栏）' : '移动（无标题栏）'}'
      '  路由 top=${pageRect?.top}  应有 top=$expectedTop'
      '  差=${pageRect != null ? (pageRect.top - expectedTop).abs() : '?'}');

  ok('⓪c 路由下边界 == 屏高', bottomOk,
      '路由 bottom=${pageRect?.bottom}  屏高=${screen0.height}');

  note('⓪ 生产外壳的形状：标题栏 ${fmtRect(tbRect)} → 路由 ${fmtRect(pageRect)}');

  final (_, c0) = await shoot('01-mount');
  ok('挂载截图非退化（>20 色）', c0 > 20, '颜色数=$c0');

  // ─────────────────────────────────────────────────────────────────
  //  ① 阴性对照：dead == false ⇒ 横幅**不该**在树上
  // ─────────────────────────────────────────────────────────────────
  _emit('');
  _emit('── ① 阴性对照（未注入，dead 应为 false）──');

  final dead0 = debugPlayerVideoOutputDead();
  ok('① `debugPlayerVideoOutputDead()` 初值为 false', dead0 == false,
      'dead=$dead0');

  root = _rootEl()!;
  var bannerEl = findByTypeName(root, '_VideoOutputDeadBanner');
  ok('① 横幅**不在**树上（阴性对照）', bannerEl == null,
      'bannerEl=${bannerEl?.widget.runtimeType}');

  // ─────────────────────────────────────────────────────────────────
  //  ② 阳性：注入 dead == true ⇒ 横幅必须出现，且位置/文案/按钮都对
  // ─────────────────────────────────────────────────────────────────
  _emit('');
  _emit('── ② 阳性（注入 dead=true）──');

  final injected = debugPlayerSetVideoOutputDeadForProbe(true);
  ok('② 注入接口返回 true', injected);
  await pumpFrame();
  await Future<void>.delayed(const Duration(milliseconds: 250));

  root = _rootEl()!;
  bannerEl = findByTypeName(root, '_VideoOutputDeadBanner');
  ok('② 横幅**出现**在渲染树上（与 ① 同一选择器 ⇒ 灵敏度被证明）',
      bannerEl != null);

  final dead1 = debugPlayerVideoOutputDead();
  ok('② 字段读回 true', dead1 == true, 'dead=$dead1');

  if (bannerEl != null) {
    final screen = MediaQuery.of(_rootKey.currentContext!).size;
    final r = rectOf(bannerEl);
    note('屏幕 = ${screen.width}x${screen.height}');
    note('横幅矩形 = ${fmtRect(r)}');
    /*
     * ★★★ 量到的到底是哪个 RenderObject？（2026-09-30 加）
     *
     * `rectOf` 用 `Element.findRenderObject()`，它会**下潜**到第一个
     * `RenderObjectElement`。`_VideoOutputDeadBanner` 的 build 返回的是
     * `Positioned`（ParentDataWidget，**不产生 RenderObject**），
     * 所以量到的其实更深一层（`ColoredBox` 或 `Padding`）。
     *
     * 第一版就是因为没把这件事**打出来**，才会对着 `left=12.0` 猜了半天。
     * ⇒ 现在把 `runtimeType` 与 `size` 一起打出来，让"量到的是谁"变成读数。
     */
    final bannerRo = bannerEl.findRenderObject();
    note('横幅量到的 RenderObject = ${bannerRo.runtimeType}  '
        'size=${bannerRo is RenderBox ? fmtSize(bannerRo.size) : '?'}');

    ok('② 拿到横幅矩形', r != null);
    if (r != null) {
      /*
       * 位置判据（用**屏幕尺寸**而不是硬编码像素 ⇒ 换分辨率不失效）
       * ① 贴底：底边 == 屏高（±2px 容忍亚像素）
       * ② 在下半屏：顶边 > 屏高的一半 ⇒ 不盖画面中央
       * ③ 撑满宽：与屏宽一致
       */
      ok('② 贴底（bottom == 屏高）',
          (r.bottom - screen.height).abs() <= 2.0,
          'bottom=${r.bottom}  屏高=${screen.height}');
      ok('② 在下半屏（top > 屏高/2 ⇒ 不盖画面中央）',
          r.top > screen.height / 2,
          'top=${r.top}  屏高/2=${screen.height / 2}');
      ok('② 撑满宽（left==0 && right==屏宽）',
          r.left.abs() <= 1.0 && (r.right - screen.width).abs() <= 2.0,
          'left=${r.left} right=${r.right} 屏宽=${screen.width}');
      ok('② 高度 > 0 且不超过屏高 1/4（不是被压扁/撑爆）',
          r.height > 0 && r.height < screen.height / 4,
          '高=${r.height}');
    }

    // ── 文案 ──
    final texts = <String>[];
    collectTexts(bannerEl, texts);
    note('横幅文案 = $texts');
    ok('② 文案里点明了**是图形输出层**（不是含糊的"播放失败"）',
        texts.any((t) => t.contains('图形输出层')));
    ok('② 文案里说明了**声音正常**（用户知道还能听）',
        texts.any((t) => t.contains('声音是正常的')));

    // ── 按钮 ──
    final btn = findOutlinedButton(bannerEl);
    ok('② 横幅里有「返回」按钮', btn != null);
    ok('② 按钮的 onPressed **已接线**（不是 null）',
        btn?.onPressed != null);
    final btnEl = findByTypeName(bannerEl, 'OutlinedButton');
    final br = rectOf(btnEl);
    note('按钮矩形 = ${fmtRect(br)}');
    ok('② 按钮矩形在横幅内且尺寸有效',
        br != null &&
            br.width > 0 &&
            br.height > 0 &&
            (r == null || (br.left >= r.left - 1 && br.right <= r.right + 1)),
        'btn=${fmtRect(br)}');
  }

  final (_, c2) = await shoot('02-banner');
  ok('② 横幅截图非退化（>20 色）', c2 > 20, '颜色数=$c2');

  // ─────────────────────────────────────────────────────────────────
  //  ③ 阴性回到：注入 false ⇒ 横幅必须消失
  // ─────────────────────────────────────────────────────────────────
  _emit('');
  _emit('── ③ 撤销（注入 dead=false）──');

  debugPlayerSetVideoOutputDeadForProbe(false);
  await pumpFrame();
  await Future<void>.delayed(const Duration(milliseconds: 250));

  root = _rootEl()!;
  bannerEl = findByTypeName(root, '_VideoOutputDeadBanner');
  ok('③ 横幅**消失**（证明它由字段驱动，不是挂上就赖着）', bannerEl == null);
  ok('③ 字段读回 false', debugPlayerVideoOutputDead() == false,
      'dead=${debugPlayerVideoOutputDead()}');

  // ─────────────────────────────────────────────────────────────────
  //  ④ 「返回」按钮端到端：点了真的会 pop 掉播放页
  // ─────────────────────────────────────────────────────────────────
  _emit('');
  _emit('── ④ 「返回」按钮端到端（真的会弹掉播放页）──');

  debugPlayerSetVideoOutputDeadForProbe(true);
  await pumpFrame();
  await Future<void>.delayed(const Duration(milliseconds: 250));

  root = _rootEl()!;
  bannerEl = findByTypeName(root, '_VideoOutputDeadBanner');
  final btnEl2 = bannerEl == null ? null : findOutlinedButton(bannerEl);
  final btnBox = bannerEl == null
      ? null
      : findByTypeName(bannerEl, 'OutlinedButton');
  final center = rectOf(btnBox)?.center;
  note('按钮中心 = ${fmtOffset(center)}');
  ok('④ 找得到按钮中心点', center != null && btnEl2 != null);

  if (center != null) {
    final pageBefore = findPlayerPage(_rootEl()!);
    ok('④ 点击**前**播放页在树上', pageBefore != null);

    await tapAt(center);
    final popped = await waitUntil(
      () => findPlayerPage(_rootEl()!) == null,
      timeout: const Duration(seconds: 6),
      label: '播放页从树上消失',
    );
    ok('④ 点击「返回」后播放页**真的被弹掉**（Navigator.maybePop 生效）',
        popped);
    if (!popped) {
      note('⚠️ 也可能是点击没送到 —— 但 ①/② 已证明同一棵树上的选择器灵敏');
    }
  } else {
    skip('④ 拿不到按钮中心点');
  }

  // ─────────────────────────────────────────────────────────────────
  //  ⑤ 生产看门狗的真实判决（需要能真播放的媒体）
  // ─────────────────────────────────────────────────────────────────
  _emit('');
  _emit('── ⑤ 生产看门狗 `_watchVideoOutput` 的真实判决 ──');

  final hasMedia = File(media).existsSync();
  if (!hasMedia) {
    skip('⑤ 媒体不存在: $media（Android 需先把媒体放到设备上）');
  } else {
    await openPlayerPage();
    final root5 = _rootEl();
    final page5 = root5 == null ? null : findPlayerPage(root5);
    ok('⑤ 播放页重新挂上', page5 != null);

    final url = Uri.file(media).toString();
    note('open: $url');
    final opened = await debugPlayerOpenForProbe(url);
    ok('⑤ `debugPlayerOpenForProbe` 返回 true', opened);

    /*
     * ══════════════════════════════════════════════════════════════
     * ★★★ ⑤ 段的重做（2026-09-30，第一版在 Android 上 skip 之后）
     * ══════════════════════════════════════════════════════════════
     *
     * # 第一版为什么**必然**拿不到阳性读数
     *
     * 第一版的前置条件是「位置 > 0.5s 才继续」，否则 skip。
     * 而 Android 那一跑的实际日志是：
     * ```text
     * 13:50:38.718  E EGL_emulation: eglCreateContext(1755): error 0x3004 (EGL_BAD_ATTRIBUTE)
     * 13:50:38.726  I flutter: [PLAYER] 播放结束（endAction=autoNext）
     * ```
     * 即 **VO 建不起来 ⇒ 播放直接中止 ⇒ 位置当然不推进**。
     *
     * ⇒ 「位置推进了」当门槛 = **拿被测故障的反面当门槛**
     *   ⇒ 故障真的发生时门槛必然不成立 ⇒ **永远 skip**。
     *   这是「一个从不触发的探针不该报成功」的**镜像错误**：
     *   一个**只在故障缺席时**才触发的探针，同样永远给不出阳性。
     *
     * # 重做后的判据：直接读闸门的**两个原始输入**
     *
     * 不再要求位置推进。改成周期性采样三元组：
     * ```text
     * (有视频轨?, vo-configured?, dead?)
     * ```
     * 这样**无论画面黑不黑、位置动不动**，判决链的每一环都可观测。
     *
     * 三条断言（都非"永远为真"）：
     * ```text
     * ⑤a 闸门输入**读得到**（不是全 null）        ← 仪器自检
     * ⑤b 判决 == 闸门在当前输入下的应有值          ← 逻辑正确性
     * ⑤c 判决**到达屏幕**（dead ⇔ 横幅在树上）      ← 产品契约（两方向）
     * ```
     */
    note('启动生产看门狗 `_watchVideoOutput`（真实方法，非复刻）');
    final started = debugPlayerWatchVideoOutputForProbe();
    ok('⑤ 生产看门狗启动成功（`_watchVideoOutput` 真的被调到）', started);

    // 采样 12s（看门狗预算 40×250ms=10s ⇒ 一定走完）
    final traj = <({int ms, bool? hv, bool? vo, bool? dead})>[];
    final sw5 = Stopwatch()..start();
    while (sw5.elapsedMilliseconds < 12000) {
      final g = await debugPlayerVideoOutputGateForProbe();
      traj.add((
        ms: sw5.elapsedMilliseconds,
        hv: g.hasVideoTrack,
        vo: g.voConfigured,
        dead: debugPlayerVideoOutputDead(),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    // 轨迹压缩成"变化点"，避免 48 行噪声
    final changes = <String>[];
    ({int ms, bool? hv, bool? vo, bool? dead})? prev;
    for (final s in traj) {
      if (prev == null ||
          prev.hv != s.hv ||
          prev.vo != s.vo ||
          prev.dead != s.dead) {
        changes.add('t=${s.ms}ms hv=${s.hv} vo=${s.vo} dead=${s.dead}');
        prev = s;
      }
    }
    note('闸门轨迹（只打变化点，共 ${traj.length} 次采样）：');
    for (final c in changes) {
      note('   $c');
    }

    final last = traj.last;
    final anyReadable =
        traj.any((s) => s.hv != null || s.vo != null);
    ok('⑤a 闸门输入**读得到**（至少一次非 null ⇒ 仪器有灵敏度）',
        anyReadable,
        'hv=${last.hv} vo=${last.vo}');

    /*
     * ⑤b 逻辑正确性：判决必须等于"当前输入下的应有值"。
     *   应有值 = 有视频轨 && vo-configured == false
     * ⚠️ 若 vo 读不到（null），则无法判"应有值"，本条降级为观察。
     */
    if (last.vo == null) {
      note('⑤b 跳过：`vo-configured` 读不到（null）⇒ 无法算应有值');
    } else {
      final expected = (last.hv == true) && (last.vo == false);
      ok('⑤b 判决 == 闸门输入应有的值（hv=${last.hv} vo=${last.vo} ⇒ 应为 $expected）',
          last.dead == expected,
          'dead=${last.dead} expected=$expected');
    }

    // ★ 平台期望（只报不改判 —— 真机上"该不该有画面"取决于硬件）
    if (Platform.isWindows) {
      note('   期望：Windows 上 vo=libmpv 正常工作 ⇒ dead 应为 false');
    } else if (Platform.isAndroid) {
      note('   期望：本模拟器产品默认 vo=gpu 建不起 GL ⇒ dead 应为 true');
      note('   ⚠️ 真机 GPU 正常时也应为 false —— 这条**不是**通用断言');
    }

    /*
     * ★★ ⑤c 本段**唯一的通用断言**，也是产品契约本身：
     *    看门狗的判决必须**到达屏幕**。
     *    `dead == true` 而横幅不在 ⇒ 用户仍然看不到（等于没修）；
     *    `dead == false` 而横幅在 ⇒ 正常播放被假横幅挡住（更糟）。
     *    两个方向都覆盖，且在两种平台上都成立。
     */
    final dead = last.dead;
    final rootEnd = _rootEl()!;
    final bannerEnd = findByTypeName(rootEnd, '_VideoOutputDeadBanner');
    ok('⑤c 判决与屏幕**一致**（dead=$dead ⇔ 横幅在树上=${bannerEnd != null}）',
        (dead == true) == (bannerEnd != null),
        'dead=$dead banner=${bannerEnd != null}');

    note('位置 = ${debugPlayerPositionSeconds()}s（仅供参考，**不是**门槛）');
    final (_, c5) = await shoot('05-real-playback');
    ok('⑤ 真播放截图非退化（>20 色）', c5 > 20, '颜色数=$c5');
  }

  _emit('');
  _emit('RESULT pass=$_pass fail=$_fail skipped=$_skip');
  await _finish(0);
}
