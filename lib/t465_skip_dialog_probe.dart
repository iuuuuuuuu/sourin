// ══════════════════════════════════════════════════════════════════════
//  t465 —— 片头片尾弹窗 **真机实测**（真启动 + 真播放 + 真截图）
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么必须有这个探针（Owner 铁律）
//
// > 「交付前必须自跑完整实测」—— 真启动、真播放、真截图。
// >   编译通过 / 测试绿 / SHA256 都**不算数**。
//
// `flutter test` 里的 `SkipMarkerDialog` 跑在 **flutter_test 的假进程**里：
// ```text
// · 没有真实 mpv ⇒ 预览框永远是"正在启动预览…"（MediaKit 没初始化）
// · 没有 sourin_core.dll ⇒ 读跳过点直接抛 126
// · RenderFlex overflow 在 release 里是**被剥掉的 assert**
//   ⇒ 真机上"第四行被挤出视口"这种缺陷，widget 测试**看不见**
// ```
// ⇒ 本探针在**真实 release 进程**里挂**真实弹窗** + **真实视频文件**，
//   并把画面**光栅化成 PNG**（人眼可查）。
//
// # 三个待验收项（对应 Owner 两条原话）
// ```text
// ① 布局：四行都在视口内 + 预览按**真实宽高比**（不是写死的 16:9）
//         ← 「布局和ui再优化优化」「有点丑,要美观」
// ② 暂停：「整段」按钮能播能停，停下后画面**冻住**
//         ← 「预览的时候不支持暂停」
// ③ 夹边界提示：四个点被夹到边界时，**真的弹出一条人话提示**
//         ← 「不能静默」（本轮修了 Closure 乱码 / 方向说反 / 被守卫关掉）
// ```
//
// # ⚠️ 本探针的三个"仪器纪律"（都是踩过的坑）
//
// ## ① 宿主必须与生产**同源**
// 生产 `lib/ui/player_page.dart` 的结构是：
// ```text
// Scaffold → showDialog → SkipMarkerDialog
// ```
// ★ 弹窗路由是页面的**兄弟** ⇒ 往上找不到 `Scaffold`，
//   但页面的 `Scaffold` 已注册进同一个 `ScaffoldMessenger`
//   ⇒ `showSnackBar` **本来就能用**。
// ⇒ 本探针**逐字复刻**这个结构（不是把弹窗当 `home:` 裸挂）——
//   否则测出来的"提示弹不出来"是宿主造成的假象。
//
// ## ② 导入必须是 `material_ui`，**不是** `flutter/material`
// `material_ui-1.4.0` 是 Flutter material 库的**独立 fork**，
// 两个 `ScaffoldMessenger` **不是同一个类**。用错了 ⇒ `maybeOf` 返回 null
// ⇒ `?.` 静默短路 ⇒ **既没有 SnackBar 也没有任何异常**（看起来像产品 bug）。
//
// ## ③ 判据必须与它要判的东西**同层**
// ```text
// "四行都在视口内"  ⇒ 量**几何**（四个标签的 RenderBox 中心点落在弹窗矩形内），
//                     不能只判"树里有这个 Text"（滚出视口也在树里）
// "暂停生效"        ⇒ 量**位置随时间的变化**（采样 2 秒，看是否冻住），
//                     不能只判"按钮文字变成片头整段了"
// "提示弹出来了"    ⇒ 读**真实 SnackBar 的文案**，不是读日志
// ```
//
// 用法：
// ```powershell
// # 先 build 到 Release 目录，再从**含 libmpv-2.dll 的目录**运行
// $env:Path = "C:\Users\iuuuuuuuu\flutter\bin;$env:Path"
// flutter build windows --release -t lib/t465_skip_dialog_probe.dart `
//   --dart-define=DATA_DIR_OVERRIDE=D:\WishProject\sourin-flutter-spike\.probe\t465_data
// # 把 Release\* 复制到 .probe\t465_run\ 后：
// .\sourin_spike.exe
// # 结果：stdout 的 `[T465]` 行 + `%TEMP%\sourin_t465.txt` + .probe\t465-*.png
// ```
//
// # ★★★ 2026-10-02 22:57 事故：漏掉 `--dart-define` ⇒ 写进了**真实用户库**
// `resolveDataDir()` 的第一选择是**编译期**常量 `DATA_DIR_OVERRIDE`
// （`String.fromEnvironment`），为空才回退到**运行时**的 `APPDATA`。
// 一次重编只写了 `-t lib/t465_skip_dialog_probe.dart`、**没带 dart-define**
// ⇒ 静默回退到 `%APPDATA%\app.sourin.player`（真实用户库），
// 而探针 ④ 段会点「确认设置」⇒ 通过真机 FFI **往真实库写了一行 skip_marker**。
// ```text
// 用户硬规则：「绝不碰 %APPDATA%\app.sourin.player\（只读都不做写入）」
// ⇒ 这个回退路径本身就是**武器化**的：参数漏一个，就静默改真实数据。
// ```
// ⇒ 已加**硬闸**：override 为空**直接 exit(3) 拒绝启动**，
//   不再有任何“静默回退到 APPDATA”的可能（见 `resolveDataDir`）。

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

import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';
import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/skip_timeline.dart';

/// 被预览的媒体（默认 640x480 **4:3** —— 故意不是 16:9）
///
/// ★ 为什么用 4:3：Task C「预览去黑边」的判据就是"画布跟随真实宽高比"。
///   用 16:9 的片源，改前改后**长得一模一样** ⇒ 什么也证明不了。
const kProbeMedia = String.fromEnvironment(
  'PROBE_MEDIA',
  defaultValue: r'D:\WishProject\sourin-flutter-spike\.probe\t465_43.mp4',
);

const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

/// 素材的**真实**宽高比（4:3）。
///
/// ⚠️ 不要用 `_previewAspectNow()` 判"预览出画面了没" —— 它读的是
/// **声明的** `aspectRatio`，初始就是 `16/9`（永远非 null）。
/// 2026-10-02 我拿它当等待条件 ⇒ `fw=0` 根本没等 ⇒ 断言跑在了
/// 它要判的事情**前面**（详见 `_body` 里那段注释）。
const kProbeAspect = 4 / 3;

final _rootKey = GlobalKey();

int pass = 0;
int fail = 0;

void say(String s) {
  // ignore: avoid_print
  print('[T465] $s');
}

void ok(String label, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
    // ignore: avoid_print
    print('[T465] ✓ $label${extra.isEmpty ? '' : '  $extra'}');
  } else {
    fail++;
    // ignore: avoid_print
    print('[T465] ✗ $label${extra.isEmpty ? '' : '  $extra'}');
  }
}

void note(String s) => say('  · $s');

// ══════════════════════════════════════════════════════════════════════
//  帧 / 截图
// ══════════════════════════════════════════════════════════════════════

/// 等一帧（**必须带超时** —— 否则静默挂住）
Future<void> pumpFrame() async {
  final b = SchedulerBinding.instance;
  b.scheduleFrame();
  await b.endOfFrame.timeout(const Duration(seconds: 2), onTimeout: () {});
}

Future<void> settle(int ms) async {
  await pumpFrame();
  await Future<void>.delayed(Duration(milliseconds: ms));
}

/// 把整棵树光栅化成 PNG，返回 (路径, 采样颜色数)
///
/// ★ 颜色数是**仪器自检**：全黑/全白图只有 1~2 种颜色，那种图不能当证据。
Future<(String, int)> shoot(String name) async {
  final ctx = _rootKey.currentContext;
  if (ctx == null) {
    say('✗ $name：`_rootKey` 没有 context');
    return ('', 0);
  }
  final obj = ctx.findRenderObject();
  if (obj is! RenderRepaintBoundary) {
    say('✗ $name：根不是 RenderRepaintBoundary（${obj.runtimeType}）');
    return ('', 0);
  }
  final img = await obj.toImage(pixelRatio: 1.0);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  final path = '$_outDir\\t465-$name.png';
  File(path).writeAsBytesSync(png!.buffer.asUint8List());

  final rgba = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = rgba!.buffer.asUint8List();
  final seen = <int>{};
  for (var i = 0; i + 3 < bytes.length; i += 4 * 7) {
    seen.add((bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]);
  }
  final w = img.width, h = img.height;
  img.dispose();
  say(
    '  截图 $name: ${w}x$h  ${File(path).lengthSync()} B  '
    '采样颜色数=${seen.length}',
  );
  return (path, seen.length);
}

// ══════════════════════════════════════════════════════════════════════
//  ★★★ 像素级判据：「这个控件上到底有没有看得见的东西」
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它（2026-10-02 真实教训）
//
// 上面那些 `rectOf(...) != null` / `findTextEl('确认设置') != null` 判据
// **全部通过**，而截图里那个按钮是**一个纯黑药丸，一个字都看不见**。
// 结构性判据只能证明"这个 widget 在树里、有几何尺寸"，
// **证明不了"它画出来是给人看的"**。
//
// ⇒ 需要一条**落在像素层**的判据（判据必须与结论同层）。
//
// 判据设计：在一个矩形区域里
//   · `mode`  = 出现次数最多的颜色（= 该控件的**填充色**）
//   · `ink`   = 与该填充色**亮度差 > 96** 的像素数（= 字形/描边的"墨"）
// 「有填充、也有墨」才说明这个控件上有看得见的内容。

/// 把当前画面抓成 rawRgba（**只用于像素统计，不落盘**）
Future<(Uint8List, int, int)?> grabRgba() async {
  final ctx = _rootKey.currentContext;
  if (ctx == null) return null;
  final obj = ctx.findRenderObject();
  if (obj is! RenderRepaintBoundary) return null;
  final img = await obj.toImage(pixelRatio: 1.0);
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = data!.buffer.asUint8List();
  final r = (bytes, img.width, img.height);
  img.dispose();
  return r;
}

int _lum(int r, int g, int b) => (r * 299 + g * 587 + b * 114) ~/ 1000;

/// 在 [rect] 里统计 `(众数色, 众数色像素数, 墨像素数)`
///
/// [inset] 往里缩几个像素 —— 躲开圆角与描边的抗锯齿。
(int modeColor, int modeCount, int inkCount) pixelStats(
  Uint8List rgba,
  int imgW,
  int imgH,
  Rect rect, {
  int inset = 4,
  int inkDelta = 96,
}) {
  final x0 = (rect.left + inset).round().clamp(0, imgW - 1);
  final x1 = (rect.right - inset).round().clamp(0, imgW - 1);
  final y0 = (rect.top + inset).round().clamp(0, imgH - 1);
  final y1 = (rect.bottom - inset).round().clamp(0, imgH - 1);
  final hist = <int, int>{};
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final o = (y * imgW + x) * 4;
      final c = (rgba[o] << 16) | (rgba[o + 1] << 8) | rgba[o + 2];
      hist[c] = (hist[c] ?? 0) + 1;
    }
  }
  if (hist.isEmpty) return (0, 0, 0);
  var mode = 0, modeN = 0;
  for (final e in hist.entries) {
    if (e.value > modeN) {
      mode = e.key;
      modeN = e.value;
    }
  }
  final ml = _lum((mode >> 16) & 0xFF, (mode >> 8) & 0xFF, mode & 0xFF);
  var ink = 0;
  for (final e in hist.entries) {
    final l = _lum((e.key >> 16) & 0xFF, (e.key >> 8) & 0xFF, e.key & 0xFF);
    if ((l - ml).abs() > inkDelta) ink += e.value;
  }
  return (mode, modeN, ink);
}

/// **绝对阈值**墨计数（`lum < threshold` 才算墨），矩形**闭区间**
///
/// ★★★ 为什么不能直接用上面的 `pixelStats`
/// ```text
/// `pixelStats` 用**相对众数色**的 `inkDelta = 96`：
///   白底(255) ⇒ 只有 lum < 159 才算墨
/// 而离线量到「静态 00:40 右半段 = 29 墨」用的尺子是**绝对阈值 200**：
///   静态标签的抗锯齿像素 (186,186,186) lum=186 < 200 ⇒ **算墨**
///   （但 186 不满足 lum < 159 ⇒ 在 pixelStats 里**不算**）
/// ```
/// ⇒ 两把尺子混用，同一个画面会读出两个数，差异会被误当成"产品行为变了"。
///   **判据必须与"已经验证过敏感度的那次量测"用同一把尺子**
///   （那次的阳性/阴性对照：弹窗开着 62、弹窗关了 0）。
int inkCountAbs(
  Uint8List rgba,
  int imgW,
  int imgH,
  Rect rect, {
  int threshold = 200,
}) {
  final x0 = rect.left.round().clamp(0, imgW - 1);
  final x1 = rect.right.round().clamp(0, imgW - 1);
  final y0 = rect.top.round().clamp(0, imgH - 1);
  final y1 = rect.bottom.round().clamp(0, imgH - 1);
  var n = 0;
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final o = (y * imgW + x) * 4;
      if (_lum(rgba[o], rgba[o + 1], rgba[o + 2]) < threshold) n++;
    }
  }
  return n;
}

/// 逐列墨计数（`x0..x1` 闭区间）—— 把"墨在哪一列"直接打出来
///
/// ★ 为什么需要它：只报一个总数时，"0"既可能是"确实没画"，
///   也可能是"画到别处去了"。逐列剖面让读数**自解释**
///   （离线就是靠它把静态 `00:40` 的墨段定在 x 986..1008）。
List<int> inkColumnsAbs(
  Uint8List rgba,
  int imgW,
  int imgH,
  int x0,
  int x1,
  int y0,
  int y1, {
  int threshold = 200,
}) {
  final out = <int>[];
  for (var x = x0; x <= x1; x++) {
    var n = 0;
    for (var y = y0; y <= y1; y++) {
      final o = (y * imgW + x) * 4;
      if (_lum(rgba[o], rgba[o + 1], rgba[o + 2]) < threshold) n++;
    }
    out.add(n);
  }
  return out;
}

// ══════════════════════════════════════════════════════════════════════
//  ⑤ 段的读数载体
// ══════════════════════════════════════════════════════════════════════

/// 一臂的全部读数（用类而不是 5 元组 —— 5 个同类型返回值太容易接错位）
class _ArmRead {
  const _ArmRead({
    required this.arm,
    required this.pos,
    required this.main,
    required this.safe,
    required this.curInk,
    required this.prof,
    required this.rows,
  });

  final String arm;

  /// 产品自己报的位置（= `_previewPos`，画家读的就是它）
  final double pos;

  /// 判据主窗 996..1008 的墨量（**这是本段要证的那个数**）
  final int main;

  /// 更保守的备选窗 1000..1008
  final int safe;

  /// 当前时间标签自己那一带的墨量（它是无条件画的 ⇒ 证明刻度活着）
  final int curInk;

  /// x 984..1012 的逐列墨计数
  final List<int> prof;

  /// y 392..412 的逐行墨计数（x 984..1012）
  final List<int> rows;
}

// ══════════════════════════════════════════════════════════════════════
//  元素树工具
// ══════════════════════════════════════════════════════════════════════

Element? get _root => WidgetsBinding.instance.rootElement;

Element? _findFirst(Element root, bool Function(Widget) test) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    if (test(e.widget)) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

/// 找所有满足条件的元素（**不是**只找第一个）
List<Element> _findAll(Element root, bool Function(Widget) test) {
  final out = <Element>[];
  void walk(Element e) {
    if (test(e.widget)) out.add(e);
    e.visitChildren(walk);
  }

  walk(root);
  return out;
}

Element? findTimeline() {
  final r = _root;
  if (r == null) return null;
  return _findFirst(r, (w) => w is SkipTimeline);
}

Element? findTextEl(String text) {
  final r = _root;
  if (r == null) return null;
  return _findFirst(r, (w) => w is Text && w.data == text);
}

void _collectTexts(Element e, List<String> out) {
  final w = e.widget;
  if (w is Text && w.data != null) out.add(w.data!);
  e.visitChildren((c) => _collectTexts(c, out));
}

/// 真实 `SnackBar` 里的**全部文案**（不是日志 —— 是用户看得见的东西）
List<String> snackTexts() {
  final r = _root;
  if (r == null) return const [];
  final out = <String>[];
  for (final e in _findAll(r, (w) => w is SnackBar)) {
    _collectTexts(e, out);
  }
  return out;
}

/// 某元素的中心点（**全局坐标**）
Offset? centerOf(Element? e) {
  if (e == null) return null;
  final ro = e.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(ro.size.center(Offset.zero));
}

/// 某元素的**全局矩形**（用于几何判据）
Rect? rectOf(Element? e) {
  if (e == null) return null;
  final ro = e.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

SkipTimeline? get timeline {
  final e = findTimeline();
  return e?.widget is SkipTimeline ? e!.widget as SkipTimeline : null;
}

// ══════════════════════════════════════════════════════════════════════
//  指针注入（与物理鼠标**同一条管线**，只是不经过系统光标）
// ══════════════════════════════════════════════════════════════════════

var _ptr = 9600;

/// 一次完整单击
///
/// ⚠️ down 与 up 之间**必须让出事件循环**：手势竞技场要在真实的帧上结算
///    （`kDoubleTapTimeout` 挂在帧回调上）。同一个 microtask 里连发会漏掉 up。
Future<void> tapAt(Offset pos, {String label = ''}) async {
  final p = _ptr++;
  final b = GestureBinding.instance;
  b.handlePointerEvent(
    PointerDownEvent(
      pointer: p,
      position: pos,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    ),
  );
  await settle(40);
  b.handlePointerEvent(
    PointerUpEvent(pointer: p, position: pos, kind: PointerDeviceKind.mouse),
  );
  // 等过双击窗口（300ms）—— 否则 onTap 还没派发
  await settle(700);
  if (label.isNotEmpty) note('已单击 $label @ $pos');
}

/// 点某段文字（按钮）一次
Future<bool> tapText(String text) async {
  final c = centerOf(findTextEl(text));
  if (c == null) {
    say('!! 找不到可点的文字「$text」');
    return false;
  }
  await tapAt(c, label: '「$text」');
  return true;
}

/// 点某一行的 `+` / `−`
///
/// ★ 不能用 `find.byWidget(e.widget)` 之类按 widget 身份找 ——
///   四行用的是**同一个 `const Icon(Icons.add)` 实例**，会匹配到四个。
///   ⇒ 用"标签的 dy"把同一行的按钮挑出来。
Future<bool> tapStep(String label, {required bool plus, int times = 1}) async {
  for (var i = 0; i < times; i++) {
    final rowY = centerOf(findTextEl(label))?.dy;
    if (rowY == null) {
      say('!! 找不到行「$label」');
      return false;
    }
    final icon = plus ? Icons.add : Icons.remove;
    final r = _root;
    if (r == null) return false;
    Offset? hit;
    for (final e in _findAll(r, (w) => w is Icon && w.icon == icon)) {
      final c = centerOf(e);
      if (c == null) continue;
      if ((c.dy - rowY).abs() < 24) {
        hit = c;
        break;
      }
    }
    if (hit == null) {
      say('!! 「$label」这一行找不到 ${plus ? "+" : "−"}');
      return false;
    }
    await tapAt(hit, label: '$label ${plus ? "+" : "−"}');
  }
  return true;
}

// ══════════════════════════════════════════════════════════════════════
//  数据目录
// ══════════════════════════════════════════════════════════════════════

Future<String> resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');

  // ══════════════════════════════════════════════════════════════════════
  // ★★★ 硬闸（2026-10-02 22:57 事故后加）：override 为空 ⇒ **拒绝启动**
  // ══════════════════════════════════════════════════════════════════════
  //
  // # 改前（危险）
  // ```dart
  // final appdata =
  //     Platform.environment['APPDATA'] ?? Platform.environment['HOME'] ?? '.';
  // return '$appdata${Platform.pathSeparator}app.sourin.player';
  // ```
  // ⇒ 忘带 `--dart-define=DATA_DIR_OVERRIDE=...` 时**静默**落到
  //   `%APPDATA%\app.sourin.player` = **真实用户库**，
  //   而 ④ 段点「确认设置」会真的写进去（已实际发生一次）。
  //
  // # 为什么是“拒绝启动”而不是“回退到 .probe 下某个目录”
  // 回退仍会**静默**用错目录 ⇒ 读数（③ 段前置闸、④ 段落点）与
  // 上次跑的不是同一个前提，却看不出差别 —— 那是“看起来对”。
  // 只有**跑不起来**才逼人补上参数。宁可失败得响，不要成功得假。
  if (override.isEmpty) {
    say('!! 拒绝启动：缺 --dart-define=DATA_DIR_OVERRIDE');
    say('   本探针会**写数据**（④ 段点「确认设置」走真机 FFI 保存）。');
    say('   没有显式隔离目录 ⇒ 会落到真实用户库 %APPDATA%\\app.sourin.player');
    say('   正确命令：');
    say(
      '     flutter build windows --release -t lib/t465_skip_dialog_probe.dart `',
    );
    say(
      '       --dart-define=DATA_DIR_OVERRIDE=<DATA>\\t465_data',
    );
    say('   （2026-10-02 22:57 就因为这个参数漏了，往真实库写了一行 skip_marker）');
    exit(3);
  }

  final d = Directory(override);
  if (!await d.exists()) await d.create(recursive: true);
  return d.path;
}

// ══════════════════════════════════════════════════════════════════════
//  宿主：**逐字复刻生产结构**
// ══════════════════════════════════════════════════════════════════════

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ★ 必须在 runApp **之前**（生产 `lib/shell.dart:248-276` 同一顺序）
  try {
    MediaKit.ensureInitialized();
    say('MediaKit 已初始化');
  } catch (e) {
    say('!! MediaKit.ensureInitialized 失败: $e');
    say('   （需要 libmpv-2.dll 在 exe 同目录）');
    exit(2);
  }

  final dataDir = await resolveDataDir();
  say('数据目录 = $dataDir');
  try {
    await UiPrefs.load(dataDir);
  } catch (e) {
    say('!! UiPrefs.load 失败（继续）: $e');
  }
  try {
    await SourinCore.startAsync(dataDir);
    say('SourinCore 已启动');
  } catch (e) {
    say('!! SourinCore.startAsync 失败（继续）: $e');
  }

  if (Platform.isWindows) {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setSize(const Size(1280, 800));
      say('窗口 1280x800');
    } catch (e) {
      say('!! windowManager 失败（继续）: $e');
    }
  }

  say('媒体 = $kProbeMedia  exists=${File(kProbeMedia).existsSync()}');

  runApp(_ProbeApp(dataDir: dataDir));
}

class _ProbeApp extends StatelessWidget {
  const _ProbeApp({required this.dataDir});

  final String dataDir;

  @override
  Widget build(BuildContext context) {
    /*
     * ★★★ 宿主主题必须**逐字复刻生产**（2026-10-02 实测踩到）
     *
     * 我第一版写的是 `theme.toApproximateMaterialTheme()` —— 结果
     * 「确认设置」按钮渲染成**一个纯黑药丸，一个字都看不见**：
     * ```text
     * 按钮内部颜色直方图（.probe\t465-02-布局.png 958..1028 x 714..762）：
     *   (23,23,23) 2274 个像素   ← 背景 #171717
     *   其余全是抗锯齿灰阶，**零个字形像素**
     * ```
     * 我当时差点把它当成产品缺陷报给 Owner。
     *
     * 真相：这个 bug **生产里早就修好了** ——
     * `lib/ui/theme_bridge.dart:240-307` 逐字记录了它
     * （forui 的 `filledButtonTheme` 前景取的是 `secondary` 的样式，
     *  而 neutral 主题里 `secondaryForeground == primary == #171717`
     *  ⇒ 对比度 **1.00:1**），修法是 `fixButtonContrast`，
     * 由 `buildLightMaterialTheme` / `buildMaterialTheme` 调用。
     *
     * 而 `lib/shell.dart:1184-1186` 走的是：
     * ```dart
     * final materialTheme = brightness == Brightness.light
     *     ? buildLightMaterialTheme(theme)
     *     : buildMaterialTheme(theme);
     * ```
     * ⇒ 我那条 `toApproximateMaterialTheme()` **绕过了修复**
     *   ⇒ 读数与生产无关（**这正是 lesson #563**：
     *     "宿主用了另一个库/另一条路径的同名东西"）。
     *
     * ⚠️ 判别法：截图里出现"纯色药丸/看不见的字"这类**观感缺陷**时，
     *    先确认宿主的主题链与生产一致，再怀疑产品。
     */
    final theme = AppTheme.themeFor(Brightness.light);
    final materialTheme = buildLightMaterialTheme(theme);
    return RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        theme: materialTheme,
        // ★ 生产外壳逐字复刻（`lib/shell.dart:2854-2865`）：
        //   FTheme → FScaffold → Material(transparency)
        // ⚠️ 缺 Material 层 ⇒ InkWell 抛
        //    `Null check operator used on a null value #0 Material.of`
        //    ⇒ **整页被换成 ErrorWidget 而不崩给你看**
        builder: (context, c) => FTheme(
          data: theme,
          child: FScaffold(
            child: Material(
              type: MaterialType.transparency,
              child: c ?? const SizedBox(),
            ),
          ),
        ),
        home: const _ProbePage(),
      ),
    );
  }
}

/// 页面 = **有 Scaffold 的页面**（对应生产 `player_page.dart:6613`）
class _ProbePage extends StatefulWidget {
  const _ProbePage();

  @override
  State<_ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<_ProbePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Timer(const Duration(milliseconds: 600), () => unawaited(_run()));
    });
  }

  @override
  Widget build(BuildContext context) {
    // ★ 生产结构：页面是 Scaffold，弹窗是它的**兄弟路由**
    return Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: TextButton(
            onPressed: () => _openDialog(ctx),
            child: const Text('打开片头片尾设置'),
          ),
        ),
      ),
    );
  }

  /// ★ 与生产 `player_page.dart:3377-3411` 同一形态
  void _openDialog(BuildContext ctx) {
    // ★ task-104：走全项目统一入口（动效与生产一致，不再有裸 showDialog）
    unawaited(
      showAppDialog<SkipMarkerResult>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => const SkipMarkerDialog(
          provider: 'probe',
          id: 't465',
          title: 't465 真机实测',
          // ★ 真实本地文件 ⇒ 预览**真的会出画面**
          streamUrl: kProbeMedia,
          duration: Duration(seconds: 40),
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────
  //  主流程
  // ────────────────────────────────────────────────────────────────────

  Future<void> _run() async {
    final sink = StringBuffer()
      ..writeln('=== t465 片头片尾弹窗真机实测 ===')
      ..writeln('时间: ${DateTime.now().toIso8601String()}')
      ..writeln('媒体: $kProbeMedia');

    void dump() {
      final f = File('${Platform.environment['TEMP'] ?? '.'}\\sourin_t465.txt');
      f.writeAsStringSync(sink.toString());
      say('已写入 ${f.path}');
    }

    try {
      await _body(sink);
    } catch (e, st) {
      say('!! 探针异常: $e');
      say('$st');
      sink.writeln('EXCEPTION: $e\n$st');
      fail++;
    }

    say('');
    say('════ 判据汇总 ════');
    say('pass=$pass fail=$fail');
    sink
      ..writeln('')
      ..writeln('RESULT pass=$pass fail=$fail');
    dump();
    say('[T465] RESULT pass=$pass fail=$fail');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(fail == 0 ? 0 : 1);
  }

  Future<void> _body(StringBuffer sink) async {
    void log(String s) {
      say(s);
      sink.writeln(s);
    }

    // ══ ⓪ 仪器自检 ══
    log('══ ⓪ 仪器自检 ══');
    final root = _root;
    ok('⓪-1 元素树根存在', root != null);
    if (root == null) {
      log('!! 没有元素树 ⇒ 后面全部无意义，直接停');
      return;
    }

    // 打开弹窗（走**真实路由**）
    log('打开弹窗（Scaffold → showDialog，与生产同构）…');
    final btn = centerOf(findTextEl('打开片头片尾设置'));
    if (btn == null) {
      ok('⓪-2 页面已挂载（能找到按钮）', false, '找不到「打开片头片尾设置」');
      return;
    }
    await tapAt(btn, label: '打开弹窗');

    // 等时间轴就绪（total > 0 = duration 拿到了）
    var waited = 0;
    while (waited < 60) {
      final t = timeline;
      if (t != null && t.total > 0) break;
      await settle(200);
      waited++;
    }
    final tl0 = timeline;
    log('等时间轴就绪 ${waited * 200}ms  total=${tl0?.total}');
    ok('⓪-2 真实弹窗已挂载（找得到 SkipTimeline）', tl0 != null);
    ok('⓪-3 时长已就绪（total > 0）', (tl0?.total ?? 0) > 0, 'total=${tl0?.total}');
    if (tl0 == null) return;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 先「重置」，让探针**自己建立前提**（2026-10-02 修）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须做
     *
     * 第一次跑（数据目录全新）：③ 段读数正确 ——
     * `introEnd=5, outroStart=null` ⇒ 按 `+` 送 want=1 ⇒ 夹到 6。
     * 但那次 ④ 段点了「确认设置」⇒ 把 `outroStart=6` **写进了数据目录**。
     * 第二次跑：弹窗一打开就**读回了** `outroStart=6`
     * ⇒ ③ 段按 `+` 变成 6+1=**7**（合法，不夹）⇒ 三条判据全红：
     * ```text
     * ✗ ③-4 值被夹到下界 6   outroStart=7
     * ✗ ③-5 真的弹出了 SnackBar   texts=[]
     * ```
     * ★ 看起来像"产品坏了"，其实是**探针只在全新数据目录下才成立**
     *   —— 这种"跑一次绿、跑第二次红"的探针比没有探针更糟。
     *
     * # 为什么用「重置」而不是删数据目录
     *
     * 删目录要重启进程（弹窗早就读完了），而「重置」走的是**产品自己的**
     * 清除路径（`_reset()` → `SourinApi.clearSkipMarker`）⇒
     * 顺带证明那条链路也是通的。
     *
     * # 顺带得到一条**阳性对照**
     *
     * `_reset()` 结尾会 `_toast('已重置')` —— 这是**无条件**走 SnackBar
     * 通道的操作（lesson #564：判别"通道坏了"还是"分支没走到"，
     * 靠的就是一条无条件走该路径的操作）。
     * 下面等它出现、再等它消失，两件事都有信息量。
     */
    log('先点「重置」让状态归零（探针自己建立前提）…');
    final resetTapped = await tapText('重置');
    ok('⓪-4 找到并点了「重置」', resetTapped);

    // ★ 阳性对照：重置的提示必须**真的出现**（证明 SnackBar 通道是通的）
    var sw = 0;
    while (sw < 20 && snackTexts().isEmpty) {
      await settle(200);
      sw++;
    }
    final resetTexts = snackTexts();
    log('重置后的 SnackBar = $resetTexts  （等了 ${sw * 200}ms）');
    ok(
      '⓪-5 ★阳性对照：「重置」的提示真的弹出来了（SnackBar 通道通）',
      resetTexts.any((s) => s.contains('已重置')),
      'texts=$resetTexts',
    );

    // 等它**消失** —— 否则 ③ 段会读到这条旧提示，把"没弹"误判成"弹了"
    var dw = 0;
    while (dw < 40 && snackTexts().isNotEmpty) {
      await settle(200);
      dw++;
    }
    log('等旧提示消失 ${dw * 200}ms  剩余=${snackTexts()}');
    ok('⓪-6 旧提示已清空（③ 段的读数不会被它污染）', snackTexts().isEmpty);

    // 前置闸：四个点必须都是**未设置**（null）
    final tReset = timeline;
    final allNull =
        tReset != null &&
        tReset.introStart == null &&
        tReset.introEnd == null &&
        tReset.outroStart == null &&
        tReset.outroEnd == null;
    ok(
      '⓪-7 ★前置闸：重置后四个点都是**未设置**',
      allNull,
      '[$tReset?.introStart, $tReset?.introEnd, '
          '$tReset?.outroStart, $tReset?.outroEnd]',
    );
    if (!allNull) {
      log('⚠ 前提没建立起来 ⇒ ③ 段的读数不可信，直接停');
      return;
    }

    // 等预览**真的出画面**（Task C/D 的验收前提）
    //
    // ★★★ 2026-10-02 修：判据原来是 `_previewAspectNow() != null`，
    //     可那个函数读的是**声明的** `aspectRatio` —— 初始就是 16/9，
    //     永远非 null ⇒ `fw=0`，**根本没等**。
    //     实测证据：①-8 读到 `ar=1.7777777777777777`，而产品日志
    //     `[SKIPDLG] 预览宽高比 1.778 → 1.333（rect=640x480）`
    //     在**读完之后**才打出来 —— 断言跑在了它要判的事情前面。
    //
    // ⇒ 改判**产品可见**的信号：加载提示消失（= 首帧渲染出来了）。
    //   这是"与结论同层"的判据 —— 用户看到的就是那行提示没了。
    var fw = 0;
    while (fw < 60) {
      if (findTextEl('正在加载预览…') == null && findTextEl('正在启动预览…') == null) {
        break;
      }
      await settle(250);
      fw++;
    }
    log('等预览首帧 ${fw * 250}ms');

    // 再等宽高比**真的变成 4:3**。
    // `onRect()` 是 `VideoOutput.Resize` 事件驱动的，实测**比首帧更晚**
    // （日志顺序：先 `Free/Create Texture` → `VideoOutput.Resize` → 宽高比）。
    // ★ 探针知道自己的素材是 4:3，所以等这个具体值是合法的。
    var aw = 0;
    while (aw < 40) {
      final a = _previewAspectNow();
      if (a != null && (a - kProbeAspect).abs() < 0.02) break;
      await settle(250);
      aw++;
    }
    log('等宽高比就绪 ${aw * 250}ms');
    final (p0, c0) = await shoot('01-打开后');
    ok('⓪-8 截图不是退化图（>20 色）', c0 > 20, '颜色数=$c0');
    sink.writeln('  截图: $p0');

    // ══ ① 布局 ══
    log('');
    log('══ ① 布局：四行都在视口内 + 预览按真实宽高比 ══');

    // 弹窗矩形（用时间轴所在的那张卡片当参照不够准 ⇒ 用四条标签的包围盒）
    const labels = ['片头开始', '片头结束', '片尾开始', '片尾结束'];
    final rects = <String, Rect>{};
    for (final l in labels) {
      final r = rectOf(findTextEl(l));
      rects[l] = r ?? Rect.zero;
      log('  $l  rect=$r');
    }
    final allFound = rects.values.every((r) => r != Rect.zero);
    ok(
      '①-1 四行标签**全部画出来了**',
      allFound,
      allFound
          ? ''
          : '缺: ${rects.entries.where((e) => e.value == Rect.zero).map((e) => e.key).join(",")}',
    );

    if (allFound) {
      // ★ 几何判据：四个标签必须**互不重叠**且**纵向递增**（行距一致）
      final ys = labels.map((l) => rects[l]!.center.dy).toList();
      final increasing = ys[0] < ys[1] && ys[1] < ys[2] && ys[2] < ys[3];
      ok(
        '①-2 四行纵向顺序正确且不重叠',
        increasing,
        'ys=${ys.map((v) => v.toStringAsFixed(1)).join(" < ")}',
      );
      final gaps = [ys[1] - ys[0], ys[2] - ys[1], ys[3] - ys[2]];
      final uniform = gaps.every((g) => (g - gaps[0]).abs() < 1.0);
      ok(
        '①-3 四行**行距一致**（= kRowH + Sp.x1 = 40）',
        uniform,
        'gaps=${gaps.map((v) => v.toStringAsFixed(1)).join(", ")}',
      );

      /*
       * ★★ 视口判据必须比"在窗口内"更严。
       *
       * 2026-09-24 Owner 报的 bug 是「只看到片头设置的两个箭头」——
       * 现象是**第四行被挤出滚动视口**（不是被挤出窗口）。
       * 那时四行的 `RenderBox` **都还在**，`localToGlobal` 也都能算出坐标
       * ⇒ 只判"中心点在窗口内"**会漏掉它**。
       *
       * ⇒ 加一条**同层**的判据：四行必须都在**「确认设置」按钮上方**。
       *    保存按钮是**固定脚**（永远可见），所以它是滚动视口的真实下边界。
       *    第四行若被挤出视口，它的 y 就会落到保存按钮那一带甚至更低。
       */
      final footerRect = rectOf(findTextEl('确认设置'));
      log('  「确认设置」按钮 rect=$footerRect');
      if (footerRect == null) {
        ok('①-4 能找到固定脚「确认设置」按钮', false);
      } else {
        final aboveFooter = rects.values.every(
          (r) => r.bottom <= footerRect.top + 1.0,
        );
        ok(
          '①-4 四行**全部在固定脚上方**（没被挤出滚动视口）',
          aboveFooter,
          '最低一行 bottom='
              '${rects.values.map((r) => r.bottom).reduce((a, b) => a > b ? a : b).toStringAsFixed(1)}'
              ' vs 确认设置 top=${footerRect.top.toStringAsFixed(1)}',
        );
        if (!aboveFooter) {
          for (final e in rects.entries) {
            if (e.value.bottom > footerRect.top + 1.0) {
              log('  !! ${e.key} bottom=${e.value.bottom} 越过确认设置按钮');
            }
          }
        }
      }

      const win = Rect.fromLTWH(0, 0, 1280, 800);
      final inside = rects.values.every((r) => win.contains(r.center));
      ok('①-5 四行中心点都在窗口 (1280x800) 内', inside);
      if (!inside) {
        for (final e in rects.entries) {
          log('  !! ${e.key} 中心=${e.value.center} 在窗口外');
        }
      }

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 像素级判据：固定脚那个按钮上**真的看得见字**吗
       * ══════════════════════════════════════════════════════════════
       *
       * 上面所有判据（`rectOf != null`、`findTextEl('确认设置') != null`、
       * 四行在固定脚上方）**全部通过**的那一版，截图里那个按钮是
       * **一个纯黑药丸、一个字都看不见**。
       *
       * ⇒ 结构性判据证明不了"画出来是给人看的"。
       *    所以这里加一条**落在像素层**的判据。
       */
      final grabbed = await grabRgba();
      if (grabbed == null) {
        ok('①-6a 抓到了像素缓冲（像素判据的前提）', false);
      } else {
        final (px, pw, ph) = grabbed;
        if (footerRect != null) {
          final (mc, mn, ink) = pixelStats(px, pw, ph, footerRect);
          final hex = '#${mc.toRadixString(16).padLeft(6, '0')}';
          log('  固定脚按钮像素：众数色=$hex ($mn 个)  墨像素=$ink');
          ok(
            '①-6 固定脚按钮上**有看得见的文字**（墨像素 > 40）',
            ink > 40,
            'ink=$ink  mode=$hex/$mn',
          );
        }
        // 阴性对照：同一张图上，「重置」是 TextButton（前景正常）
        // ⇒ 它也必须有墨。若它也没墨，说明我的判据坏了，不是按钮坏了。
        final resetRect = rectOf(findTextEl('重置'));
        if (resetRect != null) {
          final (rc, rn, rink) = pixelStats(px, pw, ph, resetRect);
          log(
            '  阳性对照「重置」像素：众数=#'
            '${rc.toRadixString(16).padLeft(6, '0')} ($rn 个)  墨像素=$rink',
          );
          ok('①-7 阳性对照：「重置」按钮有墨（判据本身灵敏）', rink > 20, 'ink=$rink');
        }
      }
    }

    // ── 预览宽高比（Task C 的判据）──
    final ar = _previewAspectNow();
    final arSize = _previewSizeNow();
    log('预览 AspectRatio = $ar  渲染尺寸 = $arSize');
    ok(
      '①-8 预览宽高比跟随**真实视频**(4:3 ≈ 1.333)',
      ar != null && (ar - kProbeAspect).abs() < 0.02,
      'ar=$ar（写死的 16:9 会是 1.778）',
    );
    if (arSize != null) {
      final rendered = arSize.width / arSize.height;
      ok(
        '①-9 **渲染出来的**预览框也是 4:3（不是被拉伸）',
        (rendered - kProbeAspect).abs() < 0.02,
        '${arSize.width.toStringAsFixed(1)}x'
            '${arSize.height.toStringAsFixed(1)} = '
            '${rendered.toStringAsFixed(3)}',
      );
    }
    final (p1, c1) = await shoot('02-布局');
    sink.writeln('  截图: $p1');

    // ══ ② 暂停 ══
    log('');
    log('══ ② 暂停：「整段」能播能停 ══');

    // ②-a 先点「片头整段」⇒ 应开始循环播
    final tappedPlay = await tapText('片头整段');
    ok('②-1 找到并点了「片头整段」', tappedPlay);

    // 等它开始播（按钮文字会变成「暂停」）
    var pw = 0;
    while (pw < 30) {
      if (findTextEl('暂停') != null) break;
      await settle(200);
      pw++;
    }
    final playing = findTextEl('暂停') != null;
    log('等「暂停」出现 ${pw * 200}ms  playing=$playing');
    ok('②-2 点击后进入**播放态**（按钮变「暂停」）', playing);

    // 播 1.5 秒，采位置 —— 证明**真的在动**
    final moving = <double>[];
    for (var i = 0; i < 6; i++) {
      await settle(250);
      moving.add(timeline?.position ?? -1);
    }
    log('播放中位置采样 = $moving');
    final moved = moving.isNotEmpty && (moving.last - moving.first).abs() > 0.3;
    ok('②-3 播放中位置**确实在推进**', moved, '${moving.first} → ${moving.last}');
    final (p2, c2) = await shoot('03-播放中');
    sink.writeln('  截图: $p2');

    // ②-b 点「暂停」⇒ 应停下并冻住
    final tappedPause = await tapText('暂停');
    ok('②-4 找到并点了「暂停」', tappedPause);
    await settle(300);

    // ★ 判据：暂停后采样 2 秒，位置必须**冻住**
    final frozen = <double>[];
    for (var i = 0; i < 8; i++) {
      await settle(250);
      frozen.add(timeline?.position ?? -1);
    }
    log('暂停后位置采样 = $frozen');
    final tail = frozen.skip(2).toList();
    final first = tail.isEmpty ? -1.0 : tail.first;
    final isFrozen =
        tail.isNotEmpty && tail.every((v) => (v - first).abs() < 0.3);
    ok(
      '②-5 暂停后画面**冻住**（2 秒内位置不变）',
      isFrozen,
      'tail=${tail.map((v) => v.toStringAsFixed(2)).join(", ")}',
    );
    ok(
      '②-6 按钮文字回到「片头整段」（退出播放态）',
      findTextEl('片头整段') != null && findTextEl('暂停') == null,
    );
    final (p3, c3) = await shoot('04-暂停后');
    sink.writeln('  截图: $p3');

    // ══ ③ 夹边界提示 ══
    log('');
    log('══ ③ 夹边界提示：真的弹出一条**人话**提示 ══');
    /*
     * ★★★ 为什么走这条路（算术推导，不是试出来的）
     *
     * `_EdgeRow` 的 `+`：
     * ```dart
     * onTap  : onChanged((v ?? 0) + 1)
     * enabled: (v ?? 0) < hi
     * ```
     * 「按 + 且被夹到**上界**」需要 `hi-1 < v < hi` ⇒ 整数无解
     * ⇒ **上界方向按不出来**（`−` 的下界方向同理）。
     *
     * 唯一能触发 clamp 的路：
     * ```text
     * 某点**未设置**（v == null ⇒ 默认按 0 算）而它的下界 lo > 1
     * ⇒ 按 + 送 want=1 ⇒ 夹到 lo ⇒ 提示「不能小于…」
     * ```
     * ⇒ 先设 `片头结束 = 5` ⇒ `片尾开始` 未设置时 lo = 5+1 = 6
     *   ⇒ 按一下它的 `+` ⇒ want=1 ⇒ 夹到 6。
     */
    log('先把「片头结束」加到 5…');
    final okPlus = await tapStep('片头结束', plus: true, times: 5);
    ok('③-1 能给「片头结束」加值', okPlus);
    var t = timeline;
    log('现在 introEnd=${t?.introEnd}  outroStart=${t?.outroStart}');
    ok('③-2 前置闸：片头结束 == 5', t?.introEnd == 5, 'introEnd=${t?.introEnd}');

    log('再按「片尾开始」的 + 一次（want=1，下界=6 ⇒ 必须被夹）…');
    final okPlus2 = await tapStep('片尾开始', plus: true, times: 1);
    ok('③-3 找到了「片尾开始」的 +', okPlus2);
    await settle(600); // 让 SnackBar 入场

    t = timeline;
    log('夹后 outroStart=${t?.outroStart}');
    ok(
      '③-4 **值被夹到下界 6**（不是 1，也不是没变）',
      t?.outroStart == 6,
      'outroStart=${t?.outroStart}',
    );

    final texts = snackTexts();
    log('真实 SnackBar 文案 = $texts');
    ok('③-5 **真的弹出了 SnackBar**（不是只打了日志）', texts.isNotEmpty, 'texts=$texts');

    final joined = texts.join(' | ');
    ok('③-6 文案是**人话**：含「不能小于」', joined.contains('不能小于'), joined);
    ok('③-7 文案说清了**是哪个点**（片尾开始）', joined.contains('片尾开始'), joined);
    ok('③-8 文案说清了**被谁挡住**（片头结束）', joined.contains('片头结束'), joined);
    ok('③-9 文案**不含** Closure 乱码', !joined.contains('Closure'), joined);
    ok('③-10 文案**方向没说反**（不含「不能超过」）', !joined.contains('不能超过'), joined);
    final (p4, c4) = await shoot('05-夹边界提示');
    sink.writeln('  截图: $p4');

    // ══════════════════════════════════════════════════════════════════
    // ★★★ ⑤ 刻度让位分支的真机画面证据（A/B 两臂互为阳性对照）
    // ══════════════════════════════════════════════════════════════════
    /*
     * # 要证的产品行为（`skip_timeline.dart` 的 `drawTickLabels`）
     * ```text
     * if (!tickLabelsCollide(rightRect, curRect)) right.paint(...);  ← 静态 00:40
     * cur.paint(canvas, curRect.topLeft);                            ← 当前 ▶ 00:NN（无条件）
     * ```
     * 即：**当前时间标签靠近静态 `00:40` 时，静态标签让位（不画）**。
     *
     * # 为什么必须落到像素层
     * 结构判据只能证明"两个 `TextPainter` 都被构造了、都有宽度"，
     * 证明不了"其中一个真的没落到画布上"。
     *
     * # 判据窗口（离线用**已存帧**的逐列剖面定出来的，不是猜的）
     * ```text
     * 静态 `00:40` 的墨段（全局 x）= 986..989 + 991..1002 + 1004..1008，合计 62
     * 取它右半段做窗口 996..1008 ⇒ 静态照画时 = 29 墨（脚本 t467_geom.py 实算）
     *                             静态让位时 = 0 墨
     * ```
     * ⚠️ 判据只设 `> 20` 的**阈值**，不钉死那个具体值：
     *    我对这个数的两次转录（29 / 33）不一致，而**转录过的数字不能当尺子**。
     *
     * y 取 399..405 —— 离线确认墨**只**落在这 7 行
     * （y 394..398 与 406..410 在全部 6 帧里都是 0），
     * 且避开了幽灵箭头带 y 378..385。
     *
     * ⚠️ 窗口左缘为什么取 996（而不是 992）：
     *    见下面"运行时几何"一节的教训 —— 当时我按错误的 `trackRight`
     *    算出 A 臂当前标签的墨右缘在 992.2，只差 0.2px。
     *    用**实测**几何（`trackRight=1009`）重算，`pos=38` 时
     *    `xOf(38)=972.10`、`cur` 盒 954.6..989.6 ⇒ 墨右缘 ≈989.6，
     *    窗口左缘 996 有 **6.4px 余量**。取 996 仍然是对的（更保守）。
     *
     * # 为什么两臂互为阳性对照
     * ```text
     * A 臂 pos=38 ⇒ xOf(38)=972.10 ⇒ cur 盒 954.6..989.6
     *              rightRect.inflate(4) ≈ 980..1013 ⇒ 重叠 ⇒ 静态让位 ⇒ 0
     * B 臂 pos=30 ⇒ xOf(30)=824.50 ⇒ cur 盒 807.0..842.0 ⇒ 不重叠 ⇒ 照画 ⇒ 有墨
     * ```
     * A 臂若读到有墨 ⇒ 让位分支被回退；B 臂若读到 0 ⇒ 窗口/几何错了。
     *
     * # ★ A 臂还必须**单独**证明"此刻刻度确实在画"
     * 否则"0 墨"既可能是"让位"，也可能是"整条时间轴压根没渲染"。
     * 所以 A 臂额外量当前标签自己那一带（`curInk`）——
     * 它是无条件画的，有墨才说明刻度活着。
     *
     * # 为什么用 `widget.onSeek` 而不是去点时间轴
     * ```text
     * onTapDown 先过 hitEdge（半径 _hitR = 20），命中就变成"拖箭头"而不是 seek；
     * 而四个端点此刻的命中位置取决于 ③ 段刚改过的 fixture
     *   （introEnd=5 已设、outroEnd 仍是幽灵）——
     *   也就是说"点哪儿能 seek 到 38"会随探针自己的前序步骤漂移。
     * ```
     * ⇒ 直接调 `SkipTimeline.onSeek`（**产品自己的公开回调**，
     *   与 tap 走到的那条路径终点同一个函数），去掉这层不确定性。
     */
    log('');
    log('══ ⑤ 刻度让位分支（A/B 真机画面证据）══');

    final tl5 = findTimeline();
    final tlRect = rectOf(tl5);
    if (tl5 == null || tlRect == null) {
      ok('⑤-0 时间轴还在（⑤ 必须排在保存/关窗之前）', false);
      return;
    }
    const kInset = kArrowInset; // 21.0，与产品同源（skip_timeline.dart）
    final trackLeftG = tlRect.left + kInset;
    final trackRightG = tlRect.right - kInset;
    final spanG = trackRightG - trackLeftG;
    log('时间轴 rect = $tlRect  宽=${tlRect.width.toStringAsFixed(2)}');
    log(
      '由它反推：trackLeft(全局)=${trackLeftG.toStringAsFixed(2)}  '
      'trackRight(全局)=${trackRightG.toStringAsFixed(2)}  '
      'span=${spanG.toStringAsFixed(2)}',
    );

    /*
     * ★★★ 几何校验：**用运行时几何去重现已存帧的 ground truth**，
     *     而不是拿它去对一个"最小二乘外推值"。
     *
     * # 为什么（2026-10-02 真实教训，被这条闸门当场抓到）
     * ```text
     * 我离线用 4 个 ground truth 做了最小二乘，得 trackRight=1012.28；
     * 但那 4 个点全在 x 295..399（都是小秒数），
     * 而判据窗在 x≈1000 —— **外推了 5.8 倍臂长**。
     * 本次真机跑出来 trackRight=1009.00，Δ=-3.28 ⇒ 闸门判"几何不一致"。
     * 复核：运行时几何对那 4 个点的残差是 -0.25/-0.81/-0.28/-0.20（**全在 1px 内**），
     *      比我那个外推值**更准**。⇒ 错的是我的拟合，不是产品。
     * ```
     * ⇒ 正确的校验是"**能不能重现已知的那几帧**"（同一把尺子），
     *   而不是"和我的外推值像不像"。
     */
    const groundTruths = <(double, double)>[
      (5.0, 363.0), // pos=5.000 时当前标签墨段 346..380 的中心
      (2.266, 312.0),
      (2.4, 315.0),
      (6.0, 381.5),
    ];
    var worst = 0.0;
    final residuals = <String>[];
    for (final (pos, centre) in groundTruths) {
      final pred = trackLeftG + spanG * (pos / 40.0);
      final d = (pred - centre).abs();
      if (d > worst) worst = d;
      residuals.add(
        'pos=$pos pred=${pred.toStringAsFixed(2)} '
        'meas=$centre d=${(pred - centre).toStringAsFixed(2)}',
      );
    }
    for (final r in residuals) {
      note(r);
    }
    final geomOk = worst <= 1.5;
    ok(
      '⑤-1 运行时几何能重现"定出判据窗口的那几帧"（最大残差 ≤1.5px）',
      geomOk,
      '最大残差=${worst.toStringAsFixed(2)}px',
    );
    if (!geomOk) {
      note(
        '★ 几何不一致 ⇒ 离线定的列号（996..1008）不再适用，'
        '本段像素判据**不予采信**（不拿旧尺子量新画面）',
      );
      return;
    }

    // 判据窗口（全局坐标）
    const winMain = Rect.fromLTRB(996, 399, 1008, 405);
    const winSafe = Rect.fromLTRB(1000, 399, 1008, 405);

    /// 把预览移到 [sec]，等**产品自己报的位置**稳定落在那里，再量三个窗口
    ///
    /// ⚠️ 这里等的 `timeline.position` 就是 `_previewPos` ——
    ///    **正是画家读的那个值**（`skip_marker_dialog.dart:1974`），
    ///    所以对本段判据来说它就是"被测对象本身"，不存在乐观值的问题。
    ///    （乐观值的问题在"画面到底是哪一帧"上，那不是本段要证的。）
    ///    但仍要多等一会儿：`setState` 之后标签要**下一帧**才落到画布上。
    Future<_ArmRead> probeAt(String arm, double sec) async {
      timeline?.onSeek(sec);
      var stable = 0;
      var waited = 0;
      double? pos;
      while (waited < 60 && stable < 2) {
        await settle(120);
        pos = timeline?.position;
        if (pos != null && (pos - sec).abs() <= 0.6) {
          stable++;
        } else {
          stable = 0;
        }
        waited++;
      }
      await settle(200); // 让 setState 后的那一帧真正画上去
      final g = await grabRgba();
      if (g == null) {
        ok('$arm 抓到画面', false);
        return _ArmRead(
          arm: arm,
          pos: pos ?? -1,
          main: -1,
          safe: -1,
          curInk: -1,
          prof: const <int>[],
          rows: const <int>[],
        );
      }
      final (rgba, iw, ih) = g;
      final main = inkCountAbs(rgba, iw, ih, winMain);
      final safe = inkCountAbs(rgba, iw, ih, winSafe);
      // ⚠️ 用**产品自己的** total，别写死 40（写死就等于把尺子钉在假设上）
      final tot = timeline?.total ?? 40.0;
      final cx = trackLeftG + spanG * (sec / tot);
      final curWin = Rect.fromLTRB(cx - 18, 399, cx + 18, 405);
      final curInk = inkCountAbs(rgba, iw, ih, curWin);
      final prof = inkColumnsAbs(rgba, iw, ih, 984, 1012, 399, 405);
      // 逐行墨量：**自校准 y 范围** —— 证明墨真的只落在 399..405
      final rows = <int>[];
      for (var y = 392; y <= 412; y++) {
        rows.add(
          inkCountAbs(
            rgba,
            iw,
            ih,
            Rect.fromLTRB(984, y.toDouble(), 1012, y.toDouble()),
          ),
        );
      }
      log(
        '$arm 位置=${pos?.toStringAsFixed(3)}  '
        '主窗(996..1008)=$main  备选窗(1000..1008)=$safe  '
        '当前标签带(${curWin.left.toStringAsFixed(0)}..'
        '${curWin.right.toStringAsFixed(0)})=$curInk',
      );
      log('$arm x984..1012 逐列 = $prof');
      log('$arm y392..412 逐行（x984..1012）= $rows');
      return _ArmRead(
        arm: arm,
        pos: pos ?? -1,
        main: main,
        safe: safe,
        curInk: curInk,
        prof: prof,
        rows: rows,
      );
    }

    /// 逐列剖面里**最右边**有墨的那一列（没有则 -1）
    int rightmostInked(List<int> prof) {
      for (var i = prof.length - 1; i >= 0; i--) {
        if (prof[i] > 0) return 984 + i;
      }
      return -1;
    }

    // ── A 臂：pos=38，静态 00:40 **应当让位** ──
    final a = await probeAt('⑤A(pos=38，应让位)', 38);
    final (pA, cA) = await shoot('07-A-pos38');
    sink.writeln('  截图: $pA');
    ok(
      '⑤-2 A 臂：预览**真的**被移到 38 附近（否则 0 墨没有意义）',
      (a.pos - 38).abs() <= 0.6,
      'pos=${a.pos.toStringAsFixed(3)}',
    );
    ok(
      '⑤-3 A 臂：刻度**确实在画**（当前标签那带有墨，它是无条件画的）',
      a.curInk > 20,
      'curInk=${a.curInk}',
    );
    /*
     * ★★★ ⑤-3b：让 A 臂的"0 墨"**可解释**
     *
     * 只报"判据窗 0 墨"是不够的 —— 如果当前标签自己的尾巴也伸进
     * x 984..1012，那 0 墨就说不清是"静态让位"还是"标签画到别处"。
     * 这条断言证明：此刻 x 984..1012 里**唯一**可能有的墨（当前标签）
     * 右缘 < 996，即判据窗**干净**。
     */
    final aRight = rightmostInked(a.prof);
    ok(
      '⑤-3b A 臂：当前标签的墨**没有伸进判据窗**（窗内 0 墨是干净的）',
      aRight < 996,
      'x984..1012 最右墨列=$aRight（判据窗左缘 996）',
    );
    ok('⑤-4 ★ A 臂：静态 00:40 **让位**（主窗 0 墨）', a.main == 0, 'main=${a.main}');
    ok('⑤-5 A 臂：更保守的窗口（1000..1008）也 0 墨', a.safe == 0, 'safe=${a.safe}');
    note('A 臂逐行 = ${a.rows}（判据窗 y399..405 之外应当全 0）');

    // ── B 臂：pos=30，静态 00:40 **不应让位**（阳性对照）──
    final b = await probeAt('⑤B(pos=30，不应让位)', 30);
    final (pB, cB) = await shoot('08-B-pos30');
    sink.writeln('  截图: $pB');
    ok(
      '⑤-6 B 臂：预览被移到 30 附近',
      (b.pos - 30).abs() <= 0.6,
      'pos=${b.pos.toStringAsFixed(3)}',
    );
    ok(
      '⑤-7 ★ B 臂（阳性对照）：静态 00:40 **照画**（主窗有墨）',
      b.main > 20,
      'main=${b.main}（离线读数 29，只设阈值不钉死）',
    );
    ok('⑤-8 B 臂：更保守的窗口也有墨', b.safe > 15, 'safe=${b.safe}（离线读数 21）');
    ok('⑤-9 B 臂：当前标签那带也有墨（两段同时在画）', b.curInk > 20, 'curInk=${b.curInk}');
    /*
     * ★★★ ⑤-9b：把**几何**和**像素**直接钉在一起
     *
     * 静态 `00:40` 是右对齐画的（`rightRect` 右缘 == `trackRight`），
     * 所以它的墨右缘应当落在 `trackRight - 1` 附近（1px 是字形的右侧留白）。
     * 这一条同时验证了两件事：
     *   ① 我用来算 `xOf` 的 `trackRight` 就是产品真正用的那个；
     *   ② 判据窗 996..1008 **确实落在静态标签的墨里面**（而不是落在空白上）——
     *      否则 B 臂的"有墨"和 A 臂的"无墨"都会变成没有意义的读数。
     */
    final bRight = rightmostInked(b.prof);
    ok(
      '⑤-9b ★ 静态标签墨右缘 == trackRight-1（几何与像素直接对上，'
          '且证明判据窗落在墨里）',
      (bRight - (trackRightG - 1)).abs() <= 3,
      '最右墨列=$bRight  trackRight=${trackRightG.toStringAsFixed(1)}',
    );
    // ★ 自校准：证明判据窗的 **y 范围**选对了（墨只落在 399..405）
    final bandIn = b.rows
        .sublist(399 - 392, 405 - 392 + 1)
        .fold<int>(0, (x, y) => x + y);
    final bandOut = b.rows.fold<int>(0, (x, y) => x + y) - bandIn;
    ok(
      '⑤-10 判据窗 y 范围自校准：墨全在 399..405 内（窗外 0）',
      bandIn > 20 && bandOut == 0,
      '带内=$bandIn 带外=$bandOut',
    );
    ok(
      '⑤-11 ★★ A/B 两臂读数**确实不同**（同一窗口：38 时 0、30 时有墨）',
      a.main == 0 && b.main > 20,
      'A=${a.main}  B=${b.main}',
    );
    // 仪器自检：两张图都不是退化图（全黑/全白只有 1~2 色，那种图不能当证据）
    ok('⑤-12 A 臂截图不是退化图', cA > 20, 'cA=$cA');
    ok('⑤-13 B 臂截图不是退化图', cB > 20, 'cB=$cB');
    log(
      '⑤ 汇总：A(38) 主窗=${a.main} 备选=${a.safe} cur=${a.curInk} '
      '最右墨列=$aRight ｜ '
      'B(30) 主窗=${b.main} 备选=${b.safe} cur=${b.curInk} '
      '最右墨列=$bRight',
    );
    log('⑤ 截图颜色数 cA=$cA cB=$cB');

    // ══ ④ 顺带：保存路径真的通（真机 FFI）══
    log('');
    log('══ ④ 保存（真机 FFI，sourin_core.dll 真在跑）══');
    final saved = await tapText('确认设置');
    await settle(900);
    log('点「确认设置」后：弹窗还在吗 = ${findTimeline() != null}');
    note('（弹窗关闭 = 保存成功并 pop；留着 = 报错并 toast）');
    ok('④-1 点确认设置后弹窗关闭（保存链路真的通）', findTimeline() == null, 'tapped=$saved');
    final (p5, c5) = await shoot('06-保存后');
    sink.writeln('  截图: $p5');
    log('截图颜色数 c0=$c0 c1=$c1 c2=$c2 c3=$c3 c4=$c4 c5=$c5');
  }

  // ── 预览几何读数 ──

  /// 弹窗里那个 `AspectRatio` 的 `aspectRatio` 值
  double? _previewAspectNow() {
    final r = _root;
    if (r == null) return null;
    for (final e in _findAll(r, (w) => w is AspectRatio)) {
      final w = e.widget as AspectRatio;
      // 弹窗里的那个：其 RenderBox 宽度 > 100（排除按钮等小部件）
      final ro = e.findRenderObject();
      if (ro is RenderBox && ro.hasSize && ro.size.width > 100) {
        return w.aspectRatio;
      }
    }
    return null;
  }

  /// 预览框**渲染出来的**尺寸
  Size? _previewSizeNow() {
    final r = _root;
    if (r == null) return null;
    for (final e in _findAll(r, (w) => w is AspectRatio)) {
      final ro = e.findRenderObject();
      if (ro is RenderBox && ro.hasSize && ro.size.width > 100) {
        return ro.size;
      }
    }
    return null;
  }
}
