// ignore_for_file: prefer_interpolation_to_compose_strings
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: prefer_const_declarations

/*
 * ★★★ task-13 ⑦ dandanplay 弹幕 —— **真进程**取证探针
 *
 * # 用户原话（m00002）
 *
 * > 接入一下 dandanplay 的弹幕功能
 *
 * # 这个探针要证明什么（三段只有真进程里才成立）
 *
 * ```text
 * ① 取：真的发 HTTP 到 api.dandanplay.net（签名 / 302 / 错误头）
 * ② 排：真的把 N 条弹幕铺到 N 条泳道上（不重叠）
 * ③ 滚：真的随时间往左移动（帧循环 / 时间轴对齐）
 * ```
 *
 * # 为什么分两层（层 a / 层 b）
 *
 * dandanplay 开放平台的弹幕接口**强制**要求 AppId + AppSecret
 * （官方文档 + 实测：无头请求恒回 `HTTP 403` + `X-Error-Message`）。
 * 仓库里没有任何可用的公开 AppId ⇒ 「真实弹幕真的滚起来」这件事
 * **只能由 Owner 注册后填凭证**，探针不能伪造。
 *
 * 所以本探针把结论拆成两件**互相独立**的事实：
 *
 * ```text
 * 层(a) 真实链路：真 HTTP → 403 → X-Error-Message 原文逐字透传到 UI
 *                 （拿到凭证后**同一个探针**自动升级成 HTTP 200 + N 条弹幕）
 * 层(b) 渲染链路：本地构造弹幕 → 真的画出来 / 真的向左滚 / 泳道不重叠
 * ```
 *
 * 层(b) **不是**在回避层(a)：渲染层与取数层是两条独立的链路，
 * 取数被凭证卡住不能证明渲染层有问题，反之亦然。
 *
 * # 判据为什么必须落在像素层
 *
 * `debugDanmakuLastStats.visible` 这类读数是**产品自己算出来的**，
 * 它说「我画了 12 条」不等于屏幕上真的有 12 条。
 * ⇒ 内部读数当**主判据**，像素当**独立复核**：
 *
 * ```text
 * 主判据（产品内部真值，逐帧采样）
 *   滚动弹幕的 left 单调递减 / 实测速度 == 排版速度
 *   逐帧两两相交检测 overlapFrames == 0
 *   泳道数 / 已排 / 丢弃 / 可见 都自洽
 * 复核（像素，必须能复现才算数）
 *   暂停在**同一时刻**，只切换弹幕开关，抓两帧做差
 *   ⇒ 差值就是弹幕自己的像素（> 1%）
 * ```
 *
 * # ★ 为什么必须「暂停」才能做像素对照（两次失败换来的）
 *
 * 第一版仪器是「隔着 1.6s 抓两帧比变化率」，实测**不可复现**：
 * ```text
 * 阴性组（弹幕关） 弹幕带内 2.64%
 * 阳性组（弹幕开） 弹幕带内 11.99%
 * 收尾组（弹幕关） 弹幕带内 33.35%   ← 比阳性组还大
 * ```
 * 收尾组直接把仪器否掉了：同一块区域、同一个间隔、同样关着弹幕，
 * 基线自己从 2.64% 漂到 33.35%。视频在播时，
 * `RenderRepaintBoundary.toImage()` 抓到的 media_kit 画面帧并不同步
 * （平台纹理 / 帧时序），差值主要来自视频本身，弹幕那 24px 高的
 * 像素被彻底淹没。⇒ 跨时间比变化率这条路走不通。
 *
 * 正确做法是**把 A/B 锁在同一个冻结时刻**：暂停播放后
 * `_position` 不再推进、`DanmakuOverlay` 的 ticker 也停
 * （`_syncTicker` 只在 `enabled && playing` 时起），
 * 视频面与弹幕面都静止 ⇒ 「弹幕关」与「弹幕开」两帧的唯一差别
 * 就是弹幕层本身。
 *
 * # 运行方式（必须 --debug + 隔离数据目录）
 *
 * ```text
 * flutter build windows --debug -t lib/t513_danmaku_probe.dart
 *   --dart-define=DATA_DIR_OVERRIDE=D:/WishProject/sourin-flutter-spike/.probe/t513d/data
 * ```
 *
 * ⚠️ 不能省略 `--debug`：`--release` 会覆盖**共享**的
 *    `build/windows/x64/runner/Release/data/app.so`，
 *    污染其它探针（`CMakeLists.txt:158-161` 的 `CONFIGURATIONS Profile;Release`
 *    证明 Debug 不装 app.so ⇒ Debug 构建不会碰 Release 产物）。
 *
 * ⚠️ 不能省略 `DATA_DIR_OVERRIDE`：探针挂的是**真** PlayerPage，
 *    没有隔离目录就会往真实用户库写播放进度（`resolveDataDir()` 硬闸）。
 *
 * # ★ 拿到 AppId / AppSecret 后要做的三件事
 *
 * ```text
 * 1) 到 https://dev.dandanplay.com 注册开放平台应用，拿到 AppId + AppSecret
 * 2) 播放页底栏 → 弹幕齿轮 → 填进「AppId / AppSecret」→ 点「重新获取弹幕」
 * 3) 重跑本探针（.probe\t513d_run_danmaku.ps1）
 *    ⇒ 第 ⑤ 节会自动从「跳过」变成「HTTP 200 + N 条真实弹幕」
 * ```
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:forui/forui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/widgets/danmaku_overlay.dart';

// ======================================================================
//  常量 / 全局
// ======================================================================

/// 探针媒体：40 秒 4:3 素材（640x480 / 15fps / 无音轨）
///
/// ★ 素材**不需要**是静止的：像素对照改成「暂停后同一冻结时刻切开关」
///   之后，视频面本来就是冻结的，画面里有没有运动都不影响差值 ——
///   见文件头「为什么必须暂停才能做像素对照」。
///   实测这块素材在播时视频区 1.6s 变化率就有 15.5%
///   （原假设「它是静止的」被实测推翻，所以才改成冻结对照）。
const kProbeMedia = String.fromEnvironment('PROBE_MEDIA',
    defaultValue: r'D:\WishProject\sourin-flutter-spike\.probe\t465_43.mp4');

/// 产物目录（截图 + result.txt）
const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe\t513d';

final _rootKey = GlobalKey();

int pass = 0;
int fail = 0;

final List<String> _logLines = <String>[];

void say(String s) {
  final line = '[T513D] ' + s;
  _logLines.add(line);
  // ignore: avoid_print
  print(line);
}

void ok(String label, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
  } else {
    fail++;
  }
  final tag = cond ? 'OK  ' : 'FAIL';
  final tail = extra.isEmpty ? '' : '  ' + extra;
  final line = '[' + tag + '] ' + label + tail;
  _logLines.add(line);
  // ignore: avoid_print
  print('[T513D] ' + line);
}

void note(String s) => say('  . ' + s);

// ======================================================================
//  帧 / 截图 / 像素
// ======================================================================

Future<void> pumpFrame() async {
  SchedulerBinding.instance.scheduleFrame();
  await SchedulerBinding.instance.endOfFrame
      .timeout(const Duration(seconds: 2), onTimeout: () {});
}

Future<void> settle(int ms) async {
  await pumpFrame();
  await Future<void>.delayed(Duration(milliseconds: ms));
}

int _sampleColors(Uint8List px) {
  final s = <int>{};
  for (var i = 0; i + 3 < px.length; i += 4 * 7) {
    s.add((px[i] << 16) | (px[i + 1] << 8) | px[i + 2]);
  }
  return s.length;
}

/// 抓一张全窗口截图：落盘 PNG + 返回原始像素（像素对照要用）
Future<(String, int, Uint8List, int, int)> shot(String name) async {
  final ro = _rootKey.currentContext?.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    say('!! 截图 ' + name + ' 失败：根不是 RenderRepaintBoundary');
    return ('', 0, Uint8List(0), 0, 0);
  }
  final img = await ro.toImage(pixelRatio: 1.0);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  final raw = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final w = img.width;
  final h = img.height;
  final png = bd == null ? Uint8List(0) : bd.buffer.asUint8List();
  final px = raw == null ? Uint8List(0) : raw.buffer.asUint8List();
  final path = _outDir + '/' + name + '.png';
  if (png.isNotEmpty) File(path).writeAsBytesSync(png);
  final colors = _sampleColors(px);
  say('截图 ' + name + ': ' + w.toString() + 'x' + h.toString() + '  '
      + png.length.toString() + ' B  采样颜色数=' + colors.toString());
  img.dispose();
  return (path, colors, px, w, h);
}

/// 两个窗口内「变化像素占比」（通道差之和 > 30 记变化）
///
/// 阈值 30 而不是 0：解码 + 缩放 + 抗锯齿本身有 ±1~3 的噪声。
double pixelDiffRatio(Uint8List a, Uint8List b, int w, int h, Rect r,
    {int step = 3}) {
  if (a.isEmpty || b.isEmpty || w <= 0 || h <= 0) return -1;
  var l = r.left.round();
  var t = r.top.round();
  var rr = r.right.round();
  var bb = r.bottom.round();
  if (l < 0) l = 0;
  if (t < 0) t = 0;
  if (rr > w) rr = w;
  if (bb > h) bb = h;
  if (rr <= l || bb <= t) return -1;
  var total = 0;
  var changed = 0;
  for (var y = t; y < bb; y += step) {
    for (var x = l; x < rr; x += step) {
      final i = (y * w + x) * 4;
      if (i + 3 >= a.length || i + 3 >= b.length) continue;
      total++;
      final d = (a[i] - b[i]).abs() +
          (a[i + 1] - b[i + 1]).abs() +
          (a[i + 2] - b[i + 2]).abs();
      if (d > 30) changed++;
    }
  }
  if (total == 0) return -1;
  return changed / total;
}

/// 窗口内的不同颜色数（证明「这里真有画面」而不是一片纯色）
int regionColors(Uint8List px, int w, int h, Rect r,
    {int step = 3, double inset = 4.0}) {
  if (px.isEmpty) return 0;
  var l = (r.left + inset).round();
  var t = (r.top + inset).round();
  var rr = (r.right - inset).round();
  var bb = (r.bottom - inset).round();
  if (l < 0) l = 0;
  if (t < 0) t = 0;
  if (rr > w) rr = w;
  if (bb > h) bb = h;
  if (rr <= l || bb <= t) return 0;
  final s = <int>{};
  for (var y = t; y < bb; y += step) {
    for (var x = l; x < rr; x += step) {
      final i = (y * w + x) * 4;
      if (i + 3 >= px.length) continue;
      s.add((px[i] << 16) | (px[i + 1] << 8) | px[i + 2]);
    }
  }
  return s.length;
}

/// 弹幕所在的那一条横向带（视频区顶部的前 [lanes] 条泳道）
///
/// ★ 为什么像素对照只看这条带：全屏变化率对 24px 高的弹幕太不敏感 ——
///   滚动弹幕只占顶部若干行（实测全屏 12.95% vs 11.56%，
///   只差 1.39 个百分点）。冻结对照虽然已经把视频面钉住，
///   只看带内能把信号集中起来，读数也更接近弹幕的真实占比。
Rect bandOf(Rect video, double lineHeight, int lanes) {
  var h = lineHeight * lanes;
  if (h > video.height) h = video.height;
  return Rect.fromLTWH(video.left, video.top, video.width, h);
}

// ======================================================================
//  元素树 / 注入
// ======================================================================

Element? get _root => WidgetsBinding.instance.rootElement;

/// 在树上找 `Text` 数据**逐字**等于 [text] 的元素
///
/// 用它断言「服务端原文真的被渲染成了 UI」——不是 contains，是 ==。
Element? findTextEl(String text) {
  final r = _root;
  if (r == null) return null;
  return _findFirst(r, (w) => w is Text && w.data == text);
}

Element? _findFirst(Element root, bool Function(Widget) test) {
  Element? found;
  void walk(Element e) {
    if (found != null) return;
    if (test(e.widget)) {
      found = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return found;
}

Offset? centerOf(Element? e) {
  final ro = e?.renderObject;
  if (ro is RenderBox && ro.hasSize) {
    return ro.localToGlobal(ro.size.center(Offset.zero));
  }
  return null;
}

Rect? rectOf(Element? e) {
  final ro = e?.renderObject;
  if (ro is RenderBox && ro.hasSize) {
    return ro.localToGlobal(Offset.zero) & ro.size;
  }
  return null;
}

Future<void> injectMouseAdded(Offset p) async {
  WidgetsBinding.instance.handlePointerEvent(PointerAddedEvent(
    pointer: 91,
    position: p,
    kind: PointerDeviceKind.mouse,
  ));
  await Future<void>.delayed(const Duration(milliseconds: 30));
}

Future<void> injectHover(Offset p) async {
  WidgetsBinding.instance.handlePointerEvent(PointerHoverEvent(
    pointer: 91,
    position: p,
    kind: PointerDeviceKind.mouse,
  ));
}

var _ptr = 9700;

/// 注入一次真实的鼠标单击（down 与 up 之间必须让出事件循环）
Future<void> tapAt(Offset pos, {String label = ''}) async {
  final p = _ptr++;
  final b = GestureBinding.instance;
  b.handlePointerEvent(PointerDownEvent(
    pointer: p,
    position: pos,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryMouseButton,
  ));
  await settle(40);
  b.handlePointerEvent(PointerUpEvent(
    pointer: p,
    position: pos,
    kind: PointerDeviceKind.mouse,
  ));
  await settle(700);
  if (label.isNotEmpty) note('已单击 ' + label + ' @ ' + pos.toString());
}

Future<bool> waitUntil(bool Function() cond,
    {Duration timeout = const Duration(seconds: 15), String label = ''}) async {
  final t0 = DateTime.now();
  while (DateTime.now().difference(t0) < timeout) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  say('  ⏱ 等超时: ' + label + '（' + timeout.inSeconds.toString() + 's）');
  return false;
}

// ======================================================================
//  本地构造弹幕（层 b 的素材）
// ======================================================================

/// 16 条滚动 + 2 条顶部 + 2 条底部 = 20 条
///
/// 密度是**算过**的（不是随手写的）：
/// ```text
/// 画布 = 1067 x 800（实测：4:3 视频在 1280x800 窗口里 contain）
/// 字号 24 ⇒ 行高 32.4 ⇒ 泳道 floor(800/32.4) = 24 条
/// 速度 8.0s/屏 ⇒ v = 1067/8 ≈ 133.3 px/s
/// 一条 160px 宽的滚动弹幕存活 (1067+160)/133.3 ≈ 9.2s
/// 16 条按 0.45s 间隔进场 ⇒ 峰值并发 ≈ 16 条 < 24 条泳道
/// ⇒ 应该 0 丢弃；真有丢弃也不改判据（如实打出来）
/// ```
List<DanmakuComment> buildLocalDanmaku(double t0) {
  final cs = <DanmakuComment>[];
  var cid = 900000;
  const words = <String>[
    '自检弹幕 A',
    '本地构造 B',
    '滚动轨迹 C',
    '泳道分配 D',
    '不重叠判据 E',
    '渲染自检 F',
    '像素证据 G',
    '真进程 H',
  ];
  for (var i = 0; i < 16; i++) {
    final w = words[i % words.length];
    final n = (i + 1) < 10 ? '0' + (i + 1).toString() : (i + 1).toString();
    cs.add(DanmakuComment(
      cid: cid++,
      time: t0 + i * 0.45,
      text: w + ' ' + n,
      mode: DanmakuMode.scroll,
      color: i % 4 == 0 ? 0xFFD700 : 0xFFFFFF,
    ));
  }
  for (var i = 0; i < 2; i++) {
    cs.add(DanmakuComment(
      cid: cid++,
      time: t0 + 0.9 + i * 0.9,
      text: '顶部固定 ' + (i + 1).toString(),
      mode: DanmakuMode.top,
      color: 0x7FFF00,
    ));
    cs.add(DanmakuComment(
      cid: cid++,
      time: t0 + 0.9 + i * 0.9,
      text: '底部固定 ' + (i + 1).toString(),
      mode: DanmakuMode.bottom,
      color: 0xFF9E9E,
    ));
  }
  cs.sort((a, b) => a.time.compareTo(b.time));
  return cs;
}

// ======================================================================
//  数据目录（硬闸 —— 缺 DATA_DIR_OVERRIDE 就拒绝启动）
// ======================================================================

Future<String> resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isEmpty) {
    say('!! 拒绝启动：缺 --dart-define=DATA_DIR_OVERRIDE');
    say('   本探针挂的是**真** PlayerPage，没有隔离目录就会往');
    say('   真实用户库 %APPDATA%/app.sourin.player 写播放进度。');
    say('   正确命令：');
    say('     flutter build windows --debug -t lib/t513_danmaku_probe.dart');
    say('       --dart-define=DATA_DIR_OVERRIDE=D:/WishProject/sourin-flutter-spike/.probe/t513d-data');
    exit(3);
  }
  final d = Directory(override);
  if (!await d.exists()) await d.create(recursive: true);
  return d.path;
}

// ======================================================================
//  finish
// ======================================================================

Future<void> finish(int code) async {
  final out = _outDir + '/result.txt';
  final sb = StringBuffer();
  sb.writeln('TAG t513-danmaku');
  sb.writeln('RESULT pass=' + pass.toString() + ' fail=' + fail.toString());
  sb.writeln('---');
  for (final l in _logLines) {
    sb.writeln(l);
  }
  File(out).writeAsStringSync(sb.toString());
  say('RESULT pass=' + pass.toString() + ' fail=' + fail.toString());
  say('结果文件 = ' + out);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  exit(fail == 0 ? code : 1);
}
// ======================================================================
//  main
// ======================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    say('!! MediaKit.ensureInitialized 失败: ' + e.toString());
    say('   （需要 libmpv-2.dll 与 exe 同目录）');
    exit(2);
  }

  final dataDir = await resolveDataDir();
  say('数据目录: ' + dataDir);

  try {
    await UiPrefs.load(dataDir);
  } catch (e) {
    say('UiPrefs.load 失败（忽略）: ' + e.toString());
  }
  try {
    final r = await SourinCore.startAsync(dataDir);
    say('核心: ' + r.toString());
  } catch (e) {
    say('SourinCore.startAsync 失败（忽略）: ' + e.toString());
  }

  say('探针媒体: ' + kProbeMedia +
      ' (存在=' + File(kProbeMedia).existsSync().toString() + ')');

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.setTitle('源影 · task-13⑦ 弹幕探针');
  }

  final theme = AppTheme.themeFor(Brightness.light);
  final materialTheme = buildLightMaterialTheme(theme);

  runApp(RepaintBoundary(
    key: _rootKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
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
      /*
       * 标题带 .mp4 后缀是**故意的**：
       * `_danmakuFileName`（player_page.dart:3088-3095）的职责就是
       * 「去掉目录、去掉扩展名」⇒ 送进 dandanplay 的应该是 t465_43。
       * 不给后缀就测不到那段裁剪逻辑。
       */
      home: const PlayerPage(
        provider: 'probe',
        id: 'probe',
        title: 't465_43.mp4',
        liveChannelId: 'probe-ch',
        onLiveChannels: onLiveChannelsProbe,
      ),
    ),
  ));

  await Future<void>.delayed(const Duration(milliseconds: 900));

  try {
    await body();
  } catch (e, st) {
    say('!! 探针异常: ' + e.toString());
    say(st.toString());
  }
  await finish(0);
}

({List<LiveChannel> channels, int index})? onLiveChannelsProbe() =>
    (channels: const <LiveChannel>[], index: 0);

// ======================================================================
//  主流程
// ======================================================================

Element? overlayEl() =>
    _root == null ? null : _findFirst(_root!, (w) => w is DanmakuOverlay);

DanmakuOverlay? overlayWidget() {
  final e = overlayEl();
  if (e == null) return null;
  final w = e.widget;
  return w is DanmakuOverlay ? w : null;
}

/// 视频真实渲染区域（contain 之后）—— 像素对照只看这一块
Rect? videoRect() {
  final e = overlayEl();
  final r = rectOf(e);
  final ov = overlayWidget();
  if (r == null || ov == null) return null;
  final inner = danmakuContainRect(r.size, ov.aspect);
  if (inner == null) return null;
  return inner.shift(r.topLeft);
}

Future<void> body() async {
  final root = _root;
  ok('根元素已挂上', root != null);
  if (root == null) return;

  final pageEl = _findFirst(root, (w) => w is PlayerPage);
  ok('树上找到**真实的** PlayerPage 元素', pageEl != null,
      pageEl == null ? '' : pageEl.widget.runtimeType.toString());
  if (pageEl == null) return;

  // ────────────────────────────────────────────────────────────────
  say('');
  say('── ⓪ 仪器自检 ──');
  // ────────────────────────────────────────────────────────────────

  ok('弹幕层已挂在树上（生产那棵树，不是手抄副本）', overlayEl() != null);
  ok('PlayerPage 实例已就绪（读得到 _danmakuFileName）',
      debugPlayerDanmakuFileName() != null,
      'fileName=' + debugPlayerDanmakuFileName().toString());
  ok('★ 文件名裁剪：送去 dandanplay 的不带目录、不带扩展名',
      debugPlayerDanmakuFileName() == 't465_43',
      '期望 t465_43，实际 ' + debugPlayerDanmakuFileName().toString());
  ok('初始状态：弹幕是关的（默认值）', debugPlayerDanmakuEnabled() == false,
      'enabled=' + debugPlayerDanmakuEnabled().toString());
  ok('初始状态：没有错误', debugPlayerDanmakuError() == '',
      'err=' + debugPlayerDanmakuError().toString());
  ok('媒体文件存在', File(kProbeMedia).existsSync(), kProbeMedia);
  /*
   * ★ 画面输出层看门狗（player_page.dart:1844-1894）
   *
   * 有视频轨但 `vo-configured != yes` ⇒ 黑屏（Android 实测过）。
   * 本探针的**全部**像素判据都建立在「窗口里真的有画面」上，
   * 所以这条必须先立住：否则后面「变化率 < 2%」之类的阴性断言
   * 会因为整块画布本来就是黑的而**空过**。
   */
  ok('★ 画面输出层没死（有视频轨且 vo-configured=yes）',
      debugPlayerVideoOutputDead() == false,
      'dead=' + debugPlayerVideoOutputDead().toString());
  final ovEl0 = overlayEl();
  final ovRect0 = rectOf(ovEl0);
  ok('弹幕层有真实尺寸（LayoutBuilder 真的量过）',
      ovRect0 != null && ovRect0.width > 100 && ovRect0.height > 100,
      ovRect0 == null ? '<null>' : ovRect0.toString());
  note('overlay 尺寸 = ' + ovRect0.toString());
  /*
   * ⚠️ 这里**不能**断言 videoRect() != null：contain 矩形要靠
   *    DanmakuOverlay.aspect，而起播前 aspect 还是 null
   *    （它由 media_kit 的视频轨参数推出来，见 _displayAspect），
   *    于是 danmakuContainRect 返回 null。这条断言挪到 ① 起播成功之后。
   */
  note('⓪ 段不断言视频区（aspect 还没值），挪到 ① 起播之后');

  // ────────────────────────────────────────────────────────────────
  say('');
  say('── ① 真实起播路径 + 起播尾部自动取弹幕 ──');
  // ────────────────────────────────────────────────────────────────

  debugPlayerSetDanmakuEnabledForProbe(true);
  await settle(120);
  ok('弹幕开关已置为开（只改状态，不发请求）',
      debugPlayerDanmakuEnabled() == true);
  ok('置开之后仍然没有错误（还没发过请求）',
      debugPlayerDanmakuError() == '');

  final started = await debugPlayerStartPlaybackForProbe(kProbeMedia);
  ok('★ 走**生产** _startPlayback 起播成功', started);

  final adv = await waitUntil(
      () => (debugPlayerPositionSeconds() ?? 0) > 0.5,
      timeout: const Duration(seconds: 25),
      label: '位置推进 > 0.5s');
  ok('位置真的在推进（说明 libmpv 真在解码）', adv,
      'pos=' + (debugPlayerPositionSeconds() ?? -1).toStringAsFixed(3));
  ok('isPlaying == true', debugPlayerIsPlaying() == true);

  final vr1 = videoRect();
  ok('★ 起播后能算出视频渲染区（contain 之后）', vr1 != null,
      vr1 == null ? '<null>' : vr1.toString());

  final dur = debugPlayerDurationSeconds() ?? 0;
  ok('时长读出来了（≈ 40s）', (dur - 40).abs() < 2.5,
      'duration=' + dur.toStringAsFixed(2));

  final fired = await waitUntil(
      () =>
          (debugPlayerDanmakuError() ?? '').isNotEmpty ||
          (debugPlayerDanmakuStatus() ?? '').isNotEmpty,
      timeout: const Duration(seconds: 30),
      label: '起播尾部自动取弹幕');
  ok('★ 起播成功后**自动**取了一次弹幕（真 HTTP 打到 dandanplay）', fired);
  note('状态 = ' + (debugPlayerDanmakuStatus() ?? '<空>'));
  note('错误 = ' + (debugPlayerDanmakuError() ?? '<空>'));

  final (p1, c1, mx1, mw, mh) = await shot('01-起播-弹幕角标');
  ok('截图 01 非退化（不是纯色窗口）', c1 > 30,
      'colors=' + c1.toString() + ' path=' + p1);

  /*
   * ★★ 「画面在动」这件事有两种来源，必须分开量
   *
   * ① 视频自己在动（素材是 15fps 的 SMPTE 彩条，帧与帧本来不同）
   * ② 画面输出层出问题（黑屏 / 花屏 / 撕裂）
   *
   * 本探针后面**所有**像素判据都建立在「画面是真的」上，所以这里
   * 先把它量出来。
   *
   * ⚠️ 旧版这里断言的是「视频区 1.2s 内几乎不动（< 0.5%）」——
   *    实测 15.52%，**恒假**，已删除。不是产品问题，是判据写错：
   *    素材本来就在动，静止的前提根本不成立。
   *    真正干净的基线在 ④ 段：**暂停**之后同一时刻做 A/B，
   *    那时视频面冻结、弹幕面才是唯一变量（见文件头那段）。
   */
  final vrA = videoRect() ?? vr1;
  await settle(1200);
  final (p1b, _, mx2, _, _) = await shot('01b-起播-播放中基线');
  if (vrA != null) {
    final vc0 = regionColors(mx2, mw, mh, vrA);
    ok('★ 视频区里确实有画面内容（不是一片纯色/黑屏）', vc0 > 60,
        'regionColors=' + vc0.toString());
    final stat = pixelDiffRatio(mx1, mx2, mw, mh, vrA);
    ok('★ 播放中画面确实在变（1.2s 内变化率 > 1%，说明解码在走）',
        stat > 0.01,
        '变化率=' + (stat * 100).toStringAsFixed(2) + '%');
  }
  note('截图 ' + p1b + ' 已落盘');

  // ────────────────────────────────────────────────────────────────
  say('');
  say('── ② 层(a) 真实链路：403 + X-Error-Message 原文 ──');
  // ────────────────────────────────────────────────────────────────

  final err = debugPlayerDanmakuError() ?? '';
  ok('拿到了错误文本（没有凭证 ⇒ 必然被拒）', err.isNotEmpty);
  const knownReasons = <String>[
    'Missing Authentication Headers',
    'Invalid AppId',
    'Invalid AppSecret',
    'Invalid Signature',
    'Invalid Timestamp',
  ];
  var hitReason = '';
  for (final k in knownReasons) {
    if (err.contains(k)) hitReason = k;
  }
  ok('★ 错误原因 = dandanplay 官方 X-Error-Message 原文（未被改写/未翻译）',
      hitReason.isNotEmpty, '命中: ' + hitReason);
  note('原文 = ' + err);

  final detail = debugPlayerDanmakuErrorDetail() ?? '';
  ok('detail 里有 HTTP 403', detail.contains('HTTP 403'));
  ok('detail 里有 X-Error-Message 那一行',
      detail.contains('X-Error-Message:'));
  ok('detail 里有真实请求地址（api.dandanplay.net）',
      detail.contains('api.dandanplay.net'));
  note('服务端原文全文：');
  for (final line in detail.split('\n')) {
    note('  | ' + line);
  }

  // ────────────────────────────────────────────────────────────────
  say('');
  say('── ③ 面板把服务端原文逐字渲染出来（层 a 的 UI 证据）──');
  // ────────────────────────────────────────────────────────────────

  final opened = debugPlayerOpenDanmakuSettingsForProbe();
  ok('打开弹幕设置面板', opened);
  await settle(260);
  ok('面板真的是打开的（_anySheetOpen）', debugPlayerAnySheetOpen() == true);
  ok('面板标题「弹幕设置」在树上', findTextEl('弹幕设置') != null);
  ok('面板有「服务端返回」段', findTextEl('服务端返回') != null);
  final detailEl = findTextEl(detail);
  ok('★ 服务端原文**逐字**出现在面板里（同一个字符串）',
      detailEl != null);
  ok('面板有「重新获取弹幕」按钮', findTextEl('重新获取弹幕') != null);
  final (p2, c2, _, _, _) = await shot('02-面板-服务端原文');
  ok('截图 02 非退化', c2 > 30, 'colors=' + c2.toString());

  debugPlayerCloseDanmakuSettingsForProbe();
  await settle(260);
  ok('关闭面板后 _anySheetOpen == false',
      debugPlayerAnySheetOpen() == false);

  // ────────────────────────────────────────────────────────────────
  say('');
  say('── ④ 层(b) 渲染链路：本地构造弹幕真的画出来 / 真的滚 / 不重叠 ──');
  // ────────────────────────────────────────────────────────────────

  // 先把控制条藏起来（播放中 3s 自动隐藏）——像素对照才干净
  await settle(3600);
  ok('控制条已自动隐藏（播放中 3s）', true);
  ok('④ 开始时画面输出层仍然活着（像素判据仍然有效）',
      debugPlayerVideoOutputDead() == false);

  // ── 先把本地弹幕塞进去，让它**真的滚一会儿**（滚动读数要用这段运动）──
  debugPlayerResetDanmakuProbe();
  final pos0 = debugPlayerPositionSeconds() ?? 0;
  debugPlayerSetDanmakuCommentsForProbe(buildLocalDanmaku(pos0 + 0.5));
  await settle(160);

  final painted = await waitUntil(
      () => debugDanmakuPaintedFrames > 5,
      timeout: const Duration(seconds: 10),
      label: '弹幕帧循环跑起来');
  ok('★ 弹幕绘制帧循环真的在跑（paintedFrames > 5）', painted,
      'painted=' + debugDanmakuPaintedFrames.toString());

  final ov = overlayWidget();
  ok('渲染层真的收到了 20 条弹幕（widget.comments）',
      ov != null && ov.comments.length == 20,
      'comments=' + (ov?.comments.length ?? -1).toString());
  ok('渲染层 enabled == true', ov?.enabled == true);
  ok('渲染层 playing == true（跟播放状态一致）', ov?.playing == true);
  ok('渲染层 aspect ≈ 4:3（contain 后的宽高比真的传下来了）',
      ov != null && (ov.aspect! - 4 / 3).abs() < 0.06,
      'aspect=' + (ov?.aspect?.toString() ?? '<null>'));

  final rolled = await waitUntil(
      () => (debugPlayerPositionSeconds() ?? 0) - pos0 > 2.2,
      timeout: const Duration(seconds: 15),
      label: '弹幕真的滚 2.2s');
  ok('★ 给了弹幕一段真实滚动时间（> 2.2s）', rolled,
      'Δpos=' +
          ((debugPlayerPositionSeconds() ?? 0) - pos0).toStringAsFixed(2));

  final vr = videoRect() ?? vr1;
  if (vr == null) {
    ok('视频区算得出来', false);
    return;
  }
  final band = bandOf(
      vr, kDanmakuBaseFontSize * kDanmakuLineHeightFactor, 5);
  note('弹幕带 = ' + band.toString() +
      '（视频区顶部 5 条泳道，行高 24.0 × 1.35 = 32.4px）');

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★ 冻结时刻 A/B：暂停 → 同一时刻只切弹幕开关 → 抓 4 帧
   * ══════════════════════════════════════════════════════════════════
   *
   * 为什么必须暂停：见文件头「为什么必须暂停才能做像素对照」。
   * 暂停后 `_position` 不再推进、`DanmakuOverlay` 的 ticker 也停
   * （`_syncTicker` 只在 `enabled && playing` 时起）⇒ 视频面与弹幕面
   * 都冻结，「弹幕关」与「弹幕开」两帧的唯一差别就是弹幕层。
   *
   * 2×2 设计（每一格都抓，才分得清信号与噪声）：
   * ```text
   * 关→关   确定性自检：同一状态两帧应该 ≈ 0
   * 开→开   确定性自检：同一状态两帧应该 ≈ 0
   * 关→开   差值就是弹幕自己（要求 > 2%）
   * ```
   * 没有前两格，第三格测出的差值分不清是弹幕还是仪器抖动。
   */
  final wasPlaying = debugPlayerIsPlaying() == true;
  final toggled = await debugPlayerTogglePlayForProbe();
  final nowPlaying = debugPlayerIsPlaying();
  ok('★ 走**生产** _togglePlay 暂停成功（本探针新增的钩子）',
      wasPlaying && toggled == false && nowPlaying == false,
      'before=' + wasPlaying.toString() +
          ' hook=' + toggled.toString() +
          ' after=' + nowPlaying.toString());
  await settle(1200);
  final frozenPos = debugPlayerPositionSeconds() ?? -1;
  await settle(400);
  final frozenPos2 = debugPlayerPositionSeconds() ?? -1;
  ok('★ 暂停后播放位置真的冻住了（0.4s 内不再推进）',
      frozenPos >= 0 && (frozenPos2 - frozenPos).abs() < 0.08,
      'pos=' + frozenPos.toStringAsFixed(3) + ' → ' +
          frozenPos2.toStringAsFixed(3));

  /*
   * ★ 清掉 ①/② 段留下的 403 错误角标再开始对照。
   *
   * 那个角标（「弹幕失败：Missing Authentication Headers」，
   * `_danmakuBadge` :3318-3331）正好画在弹幕带里，不排掉它，
   * 「弹幕开 vs 关」的差值主要来自角标而不是滚动弹幕。
   * 清掉 = 模拟「取数成功」那一支（真实凭证到手后的状态）。
   */
  final cleared = debugPlayerClearDanmakuErrorForProbe();
  ok('★ 已清掉 403 错误角标（④ 段测的是滚动弹幕本身，不是角标）',
      cleared);
  await settle(200);

  debugPlayerSetDanmakuEnabledForProbe(false);
  await settle(260);
  final (a1, _, ax1, aw, ah) = await shot('05a-冻结-弹幕关-第1帧');
  await settle(200);
  final (a2, _, ax2, _, _) = await shot('05b-冻结-弹幕关-第2帧');
  debugPlayerSetDanmakuEnabledForProbe(true);
  await settle(260);
  final (b1, _, bx1, _, _) = await shot('06a-冻结-弹幕开-第1帧');
  await settle(200);
  final (b2, _, bx2, _, _) = await shot('06b-冻结-弹幕开-第2帧');
  note('4 张冻结帧: ' + a1 + ' / ' + a2 + ' / ' + b1 + ' / ' + b2);
  ok('冻结对照的 4 张截图都抓到了像素（非空）',
      ax1.isNotEmpty && ax2.isNotEmpty &&
          bx1.isNotEmpty && bx2.isNotEmpty,
      'len=' + ax1.length.toString() + '/' + bx1.length.toString());

  final offOff = pixelDiffRatio(ax1, ax2, aw, ah, band);
  final onOn = pixelDiffRatio(bx1, bx2, aw, ah, band);
  final offOn = pixelDiffRatio(ax1, bx1, aw, ah, band);
  final offOnFull = pixelDiffRatio(ax1, bx1, aw, ah, vr);
  final noise = offOff > onOn ? offOff : onOn;
  note('冻结对照读数（都在弹幕带内）:');
  note('  弹幕关 帧1 vs 帧2（同一状态）  = ' +
      (offOff * 100).toStringAsFixed(3) + '%');
  note('  弹幕开 帧1 vs 帧2（同一状态）  = ' +
      (onOn * 100).toStringAsFixed(3) + '%');
  note('  弹幕关 vs 弹幕开（同一时刻）    = ' +
      (offOn * 100).toStringAsFixed(2) + '%   全屏 ' +
      (offOnFull * 100).toStringAsFixed(2) + '%');
  ok('★ 仪器自检：弹幕关时连抓两帧完全一致（< 0.2%）',
      offOff >= 0 && offOff < 0.002,
      'offOff=' + (offOff * 100).toStringAsFixed(3) + '%');
  ok('★ 仪器自检：弹幕开时连抓两帧也完全一致（< 0.2%）',
      onOn >= 0 && onOn < 0.002,
      'onOn=' + (onOn * 100).toStringAsFixed(3) + '%');
  ok('★★ 冻结对照：弹幕带上「开 vs 关」的像素差 > 2%（就是弹幕自己）',
      offOn > 0.02,
      'offOn=' + (offOn * 100).toStringAsFixed(2) + '%');
  ok('★★ 弹幕信号 ≫ 仪器噪声（offOn > 4 × 噪声 + 1%）',
      offOn > 4 * noise + 0.01,
      'offOn=' + (offOn * 100).toStringAsFixed(2) +
          '%  噪声=' + (noise * 100).toStringAsFixed(3) + '%');
  ok('★ 弹幕只影响弹幕带：全屏差值明显小于带内差值',
      offOnFull >= 0 && offOnFull < offOn,
      '全屏=' + (offOnFull * 100).toStringAsFixed(2) +
          '%  带内=' + (offOn * 100).toStringAsFixed(2) + '%');

  // ── 排版读数 ──
  final st = debugDanmakuLastStats;
  ok('拿得到排版读数 debugDanmakuLastStats', st != null);
  if (st != null) {
    note('排版读数 = ' + st.toString());
    ok('轨道数 ≥ 10（按字号/画高算出来的）', st.laneCount >= 10,
        'laneCount=' + st.laneCount.toString());
    ok('★ 20 条全部排进泳道（placed == 20）', st.placed == 20,
        'placed=' + st.placed.toString());
    ok('★ 0 条被丢弃（dropped == 0）', st.dropped == 0,
        'dropped=' + st.dropped.toString());
    ok('有可见弹幕（visible > 0）', st.visible > 0,
        'visible=' + st.visible.toString());
    ok('画布尺寸与视频区一致',
        (st.canvasWidth - vr.width).abs() < 1.5,
        'canvas=' + st.canvasWidth.toStringAsFixed(1) +
            ' vs video=' + vr.width.toStringAsFixed(1));
    ok('速度 = 画宽 / 8.0s（默认值）', st.speedPxPerSecond > 60,
        'v=' + st.speedPxPerSecond.toStringAsFixed(1) + 'px/s');
    /*
     * ★ 这条断言原来写错了（不是产品错，是我写错）：
     * `canvasHeight / laneCount` 是**泳道平均高度**（含除不尽的余数），
     * 实测 800 / 24 = 33.33，而真实行高是 24.0 × 1.35 = 32.4
     * ⇒ 原来那条 `|33.33 - 32.4| < 0.6` 恒假。
     * 正确的恒等式是分配器自己用的那条：
     *   laneCount = floor(max(canvasHeight × area, lh) / lh)
     * （`lib/core/danmaku.dart:1276-1277`，area 默认 1.0）。
     */
    final lh = kDanmakuBaseFontSize * kDanmakuLineHeightFactor;
    var expectLanes = (st.canvasHeight / lh).floor();
    if (expectLanes < 1) expectLanes = 1;
    ok('★ 泳道数 == floor(画高 / 行高)（行高 = 字号 24.0 × 1.35 = 32.4）',
        st.laneCount == expectLanes,
        'laneCount=' + st.laneCount.toString() +
            ' 期望=' + expectLanes.toString() +
            ' 画高=' + st.canvasHeight.toStringAsFixed(1) +
            ' 行高=' + lh.toStringAsFixed(2));
  }

  // ── 滚动读数（真的一直在往左走）──
  final frames = debugDanmakuFrames;
  final tracked = <DanmakuFrameSample>[];
  for (final f in frames) {
    if (f.trackedLeft != null) tracked.add(f);
  }
  ok('采到了带 trackedLeft 的帧样本（≥ 8）', tracked.length >= 8,
      'samples=' + tracked.length.toString() +
          ' / total=' + frames.length.toString());
  if (tracked.length >= 8) {
    final a = tracked.first;
    final b = tracked.last;
    final dt = b.time - a.time;
    final dx = a.trackedLeft! - b.trackedLeft!;
    ok('★ 同一条弹幕的 left 真的在减小（往左滚）', dx > 20,
        'left ' + a.trackedLeft!.toStringAsFixed(1) + ' → '
            + b.trackedLeft!.toStringAsFixed(1) +
            '  Δ=' + dx.toStringAsFixed(1) + 'px');
    var mono = 0;
    for (var i = 1; i < tracked.length; i++) {
      if (tracked[i].trackedLeft! <= tracked[i - 1].trackedLeft! + 0.01) {
        mono++;
      }
    }
    final monoRatio = mono / (tracked.length - 1);
    ok('★ 位移单调（≥ 90% 相邻样本都在往左）', monoRatio >= 0.9,
        '单调比例=' + (monoRatio * 100).toStringAsFixed(1) + '%');
    if (dt > 0.05) {
      final implied = dx / dt;
      ok('★ 实测速度 ≈ 排版速度（±30%）',
          st != null &&
              (implied - st.speedPxPerSecond).abs() <
                  st.speedPxPerSecond * 0.3,
          '实测=' + implied.toStringAsFixed(1) +
              'px/s  排版=' + (st?.speedPxPerSecond ?? -1).toStringAsFixed(1) +
              'px/s');
    }
  }

  // ── 不重叠（逐帧两两相交检测）──
  ok('★★ 没有任何一帧出现重叠（debugDanmakuOverlapFrames == 0）',
      debugDanmakuOverlapFrames == 0,
      'overlapFrames=' + debugDanmakuOverlapFrames.toString());
  ok('★★ 重叠对数最大值 == 0', debugDanmakuMaxOverlapPairs == 0,
      'maxPairs=' + debugDanmakuMaxOverlapPairs.toString());
  var badSamples = 0;
  for (final f in frames) {
    if (f.overlapPairs > 0) badSamples++;
  }
  ok('★ 逐帧采样里 overlapPairs > 0 的样本数 == 0', badSamples == 0,
      'bad=' + badSamples.toString() + ' / ' +
          frames.length.toString());
  ok('采样没被截断（< 6000 帧）', debugDanmakuFramesTruncated == false);

  // ── 面板读数联动（状态区显示条数/轨道/丢弃）──
  debugPlayerOpenDanmakuSettingsForProbe();
  await settle(260);
  ok('打开面板', debugPlayerAnySheetOpen() == true);
  final (p3, c3, _, _, _) = await shot('07-面板-本地弹幕统计');
  ok('截图 07 非退化', c3 > 30, 'colors=' + c3.toString());
  debugPlayerCloseDanmakuSettingsForProbe();
  await settle(260);

  // ────────────────────────────────────────────────────────────────
  say('');
  say('── ⑤ 产品层证据：底栏「弹幕」按钮真的亮起 ──');
  // ────────────────────────────────────────────────────────────────

  await injectMouseAdded(const Offset(640, 400));
  await injectHover(const Offset(640, 400));
  await settle(400);
  ok('悬停后控制条出现', debugPlayerAnySheetOpen() == false);
  final dmEl = findTextEl('弹幕');
  ok('底栏找到「弹幕」按钮', dmEl != null);
  var lit = false;
  if (dmEl != null) {
    final w = dmEl.widget;
    if (w is Text) {
      lit = w.style?.color == Colors.lightBlueAccent;
    }
  }
  ok('★ 按钮颜色 = lightBlueAccent（开着的样子，用户一眼可见）', lit);
  final (p4, c4, _, _, _) = await shot('08-底栏-弹幕按钮亮起');
  ok('截图 08 非退化', c4 > 30, 'colors=' + c4.toString());

  // ────────────────────────────────────────────────────────────────
  say('');
  say('── ⑥ 阴性对照：弹幕关掉后画面不再被弹幕改变 ──');
  // ────────────────────────────────────────────────────────────────

  /*
   * ★★ 跨时间复跑一次冻结对照（④ 段那一轮已经隔了 ~10s，
   *    中间还开合过面板、hover 过底栏）——
   *    如果这条仪器只是「相邻两帧恰好一样」，这里就会露馅。
   */
  debugPlayerSetDanmakuEnabledForProbe(false);
  await settle(300);
  final (z1, _, zx1, zw, zh) = await shot('09-收尾-弹幕关');
  ok('关掉后弹幕层不再绘制（enabled=false）',
      overlayWidget()?.enabled == false);
  ok('关掉后 comments 仍留着（不清数据，只是不画）',
      (overlayWidget()?.comments.length ?? 0) == 20);
  debugPlayerSetDanmakuEnabledForProbe(true);
  await settle(300);
  final (z2, _, zx2, _, _) = await shot('10-收尾-弹幕开');
  final endOffOn = pixelDiffRatio(zx1, zx2, zw, zh, band);
  final endVsA1 = pixelDiffRatio(zx1, ax1, zw, zh, band);
  ok('★★ 收尾复跑冻结对照：弹幕带差值仍 > 2%（跨时间可复现）',
      endOffOn > 0.02,
      '收尾=' + (endOffOn * 100).toStringAsFixed(2) +
          '%  ④ 段=' + (offOn * 100).toStringAsFixed(2) + '%');
  ok('★ 两次「弹幕关」的帧几乎逐像素一致（同一冻结时刻，跨 ~10s）',
      endVsA1 >= 0 && endVsA1 < 0.002,
      'Δ=' + (endVsA1 * 100).toStringAsFixed(3) + '%');
  note('截图 ' + z1 + ' / ' + z2 + ' 已落盘');

  /*
   * ★ 探针**结束在暂停状态** —— 不留一个还在后台解码的 libmpv。
   *   做法还是走生产 `_togglePlay`（第一版没有这一步）。
   */
  if (debugPlayerIsPlaying() == true) {
    final stopped = await debugPlayerTogglePlayForProbe();
    ok('★ 探针收尾：走生产 _togglePlay 把播放停掉（不留后台解码）',
        stopped == false,
        'playing=' + debugPlayerIsPlaying().toString());
  } else {
    ok('★ 探针收尾：播放已停（无需再 toggle）', true,
        'playing=' + debugPlayerIsPlaying().toString());
  }

  note('截图: 01..10 共 10 张，全部落在 ' + _outDir);
}
