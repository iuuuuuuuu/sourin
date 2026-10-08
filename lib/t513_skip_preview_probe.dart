// ignore_for_file: prefer_interpolation_to_compose_strings
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: prefer_const_declarations
// 说明：本文件是**探针**（临时验收工具，不属于交付 UI）。为了用脚本安全落盘，
//       字符串一律用 'a' + x.toString() 拼接、不写 Dart 插值，因此关掉上面三条
//       纯风格 lint；逻辑与判据本身没有任何抑制。
// ======================================================================
//  t513 probe -- 片头片尾「单击预览这一帧」真机实测（task-13 ⑥）
// ======================================================================
//
// Owner 原话（task-13 ⑥，逐字）：
//   「片头片尾的片头 片尾 的开始与结束，单独点击预览没有反应，
//     点击后应该预览这一帧的画面才对，剪头也是一样的，
//     支持单击后预览这个停留的位置的画面」
//
// 要证的产品行为：三个入口 => 同一个终点 _previewFrame(秒)
//   ① 时间轴上单击箭头（含未设置时的幽灵箭头）=> seek 到该端点的值；
//      未设置 => seek 到 _defaultAt(e)（"若现在设下去会落在哪"）
//   ② 读数行单击那个秒数文本（连"— — —"也能点）=> 同上
//   ③ 读数行单击 ▶ 按钮（未设置时不再置灰）=> 同上
//
// ★ 判据必须落在像素层（这是本探针存在的理由）
//   timeline.position 就是 _previewPos —— 一个乐观值：
//   _previewSeek() 里 setState(() => _previewPos = s) 在 await p.seek()
//   之前就更新了。=> "位置读数变成了 30" 证明不了"画面停在第 30 秒"。
//   所以每个入口的主判据是：预览框内的像素真的换了（帧间差），
//   并且换到了与 kick 位置不同的一帧，并且换完之后冻住不动。
//
// ★ 为什么要先 kick（把预览挪到别处）再点
//   introStart 未设置时的默认值是 0，而弹窗打开时 _maybeInitialLocate()
//   已经停在 _introEnd ?? _introStart ?? 0 = 0 => 单击 introStart 的默认
//   位置恰好等于当前位置 => 画面不该变（那是阴性对照，不是"没生效"）。
//   => 每次点击前先把预览挪到一个确定不同的位置。
//
// ★ 阴性对照（判据灵敏度的证明）
//   同一个端点连点两次：第二次位置不变 => 画面必须几乎不动（diff ~ 0）。
//   若第二次也有大差异，说明像素判据坏了，而不是"产品每次都在换帧"。
//
// ★ 与 t465 的关系
//   t465 证的是"预览能播能停、刻度让位、夹边界提示"；本探针只证 ⑥。
//   宿主（主题链 / FTheme+FScaffold+Material / RepaintBoundary / 真实
//   showDialog 路由）逐字复刻 t465 —— 那套结构是踩过坑才对的
//   （见 t465 里"纯黑药丸"那段教训），不要另起炉灶。
//
// 运行（必须带 DATA_DIR_OVERRIDE，否则拒绝启动）：
//   flutter build windows --debug -t lib/t513_skip_preview_probe.dart
//     --dart-define=DATA_DIR_OVERRIDE=D:/WishProject/sourin-flutter-spike/.probe/t513_data
//   ⚠️ 用 --debug（走 build/windows/x64/runner/Debug/）—— --release 会覆盖
//      共享的 Release/data/app.so（生产产物），污染后 t489 与 finger_gate[3b]
//      会假红。CMakeLists.txt:158-161 的 CONFIGURATIONS Profile;Release 证明
//      Debug 不装 app.so；:122-135 说明 sourin_core.dll 仍会进 Debug bundle。
// ======================================================================

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

/// 被预览的媒体（640x480 4:3、40 秒彩条式测试画面）
///
/// ★ 与 t465 共用同一份素材：它已被证明在 Windows 上真的出画面
///   （.probe/t465-0*.png 预览区采样 517~618 色）。
/// ★ 4:3 是故意的：_previewAspect 初值 16:9，只有真素材的宽高比
///   才能证明"预览框跟着真实视频走"。
const kProbeMedia = String.fromEnvironment(
  'PROBE_MEDIA',
  defaultValue: r'D:\WishProject\sourin-flutter-spike\.probe\t465_43.mp4',
);

const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe\t513';

final _rootKey = GlobalKey();

int pass = 0;
int fail = 0;

void say(String s) {
  // ignore: avoid_print
  print('[T513] $s');
}

void ok(String label, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
    // ignore: avoid_print
    print('[T513] OK   $label${extra.isEmpty ? '' : '  $extra'}');
  } else {
    fail++;
    // ignore: avoid_print
    print('[T513] FAIL $label${extra.isEmpty ? '' : '  $extra'}');
  }
}

void note(String s) => say('  . $s');

// ======================================================================
//  帧 / 截图
// ======================================================================

/// 等一帧（必须带超时 —— 否则静默挂住）
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
/// ★ 颜色数是仪器自检：全黑/全白图只有 1~2 种颜色，那种图不能当证据。
Future<(String, int)> shoot(String name) async {
  final ctx = _rootKey.currentContext;
  if (ctx == null) {
    say('FAIL $name：_rootKey 没有 context');
    return ('', 0);
  }
  final obj = ctx.findRenderObject();
  if (obj is! RenderRepaintBoundary) {
    say('FAIL $name：根不是 RenderRepaintBoundary');
    return ('', 0);
  }
  final img = await obj.toImage(pixelRatio: 1.0);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  final path = '$_outDir/$name.png';
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

/// 把当前画面抓成 rawRgba（只用于像素统计，不落盘）
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

// ======================================================================
//  ★ 像素判据：「画面到底换没换」
// ======================================================================
//
// 在 [r] 里按 [step] 采样，返回「通道差之和 > 30」的点占比。
//
// ★ 为什么是"通道差之和 > 30"而不是"不相等"：
//   视频解码 + 缩放 + 抗锯齿会带来 ±1~3 的噪声，"不相等"会把噪声
//   算成变化 => 判据虚高。
// ★ 阈值定在 2%：素材是彩条式测试画面，5 秒以上的位置差会让大片色块
//   换位置 => 实测差异远大于 2%。若某次只读到 0.3%，那是"几乎没变"。
double pixelDiffRatio(
  Uint8List a,
  Uint8List b,
  int w,
  int h,
  Rect r, {
  int step = 3,
}) {
  var n = 0;
  var diff = 0;
  final x0 = r.left.round().clamp(0, w - 1);
  final x1 = r.right.round().clamp(0, w);
  final y0 = r.top.round().clamp(0, h - 1);
  final y1 = r.bottom.round().clamp(0, h);
  for (var y = y0; y < y1; y += step) {
    for (var x = x0; x < x1; x += step) {
      final i = (y * w + x) * 4;
      final d =
          (a[i] - b[i]).abs() +
          (a[i + 1] - b[i + 1]).abs() +
          (a[i + 2] - b[i + 2]).abs();
      n++;
      if (d > 30) diff++;
    }
  }
  if (n == 0) return 0;
  return diff / n;
}

/// 窗口里的**不同颜色数** —— 用来证明"这个窗口里真的有画面"，
/// 而不是一块纯黑（纯黑窗口上的帧间差毫无意义）。
int regionColors(
  Uint8List px,
  int w,
  int h,
  Rect r, {
  int step = 3,
  double inset = 4.0,
}) {
  final x0 = (r.left + inset).round().clamp(0, w - 1);
  final x1 = (r.right - inset).round().clamp(0, w);
  final y0 = (r.top + inset).round().clamp(0, h - 1);
  final y1 = (r.bottom - inset).round().clamp(0, h);
  final seen = <int>{};
  for (var y = y0; y < y1; y += step) {
    for (var x = x0; x < x1; x += step) {
      final i = (y * w + x) * 4;
      seen.add((px[i] << 16) | (px[i + 1] << 8) | px[i + 2]);
    }
  }
  return seen.length;
}

// ======================================================================
//  元素树工具（逐字复刻 t465 —— 那套已被 t465 真机跑通）
// ======================================================================

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

List<Element> _findAll(Element root, bool Function(Widget) test) {
  final out = <Element>[];
  void walk(Element e) {
    if (test(e.widget)) out.add(e);
    e.visitChildren(walk);
  }

  walk(root);
  return out;
}

/// 当前挂着的 \`SkipTimeline\` widget（**读它的字段就是读产品状态**）
SkipTimeline? get timelineW {
  final r = _root;
  if (r == null) return null;
  final e = _findFirst(r, (w) => w is SkipTimeline);
  if (e == null) return null;
  final w = e.widget;
  return w is SkipTimeline ? w : null;
}

Element? findTextEl(String text) {
  final r = _root;
  if (r == null) return null;
  return _findFirst(r, (w) => w is Text && w.data == text);
}

List<Element> findTextEls(String text) {
  final r = _root;
  if (r == null) return const [];
  return _findAll(r, (w) => w is Text && w.data == text);
}

void _collectTexts(Element e, List<String> out) {
  final w = e.widget;
  if (w is Text && w.data != null) out.add(w.data!);
  e.visitChildren((c) => _collectTexts(c, out));
}

/// 真实 \`SnackBar\` 里的全部文案（不是日志 —— 是用户看得见的东西）
List<String> snackTexts() {
  final r = _root;
  if (r == null) return const [];
  final out = <String>[];
  for (final e in _findAll(r, (w) => w is SnackBar)) {
    _collectTexts(e, out);
  }
  return out;
}

Offset? centerOf(Element? e) {
  if (e == null) return null;
  final ro = e.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(ro.size.center(Offset.zero));
}

Rect? rectOf(Element? e) {
  if (e == null) return null;
  final ro = e.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

/// 从一堆候选元素里挑「与 [rowY] 同一行」的那个（|dy| 最小且 < 24）
///
/// ★ 为什么必须按行挑：四行读数用的是**同一个字面量** \`— — —\`，
///   四行按钮用的是**同一个 const Icon 实例** —— 按 widget 身份找会命中四个。
/// ★ [leftmost]：同一行有多个候选时（例如 ▶ 按钮里既有 Icon 又有 Text），
///   取最左的那个，保证点击落点确定。
Element? pickInRow(List<Element> cands, double rowY, {bool leftmost = true}) {
  Element? best;
  double? bestDy;
  double? bestDx;
  for (final e in cands) {
    final c = centerOf(e);
    if (c == null) continue;
    final dy = (c.dy - rowY).abs();
    if (dy >= 24) continue;
    if (best == null) {
      best = e;
      bestDy = dy;
      bestDx = c.dx;
      continue;
    }
    final dyBetter = dy < bestDy! - 1.0;
    final dySame = (dy - bestDy).abs() <= 1.0;
    if (dyBetter) {
      best = e;
      bestDy = dy;
      bestDx = c.dx;
    } else if (dySame) {
      final dx = c.dx;
      final want = leftmost ? dx < bestDx! : dx > bestDx!;
      if (want) {
        best = e;
        bestDx = dx;
      }
    }
  }
  return best;
}

/// 某个读数行标签的中心 dy（四行定位的锚）
double? labelRowY(String label) => centerOf(findTextEl(label))?.dy;

// ======================================================================
//  ★ 时间轴几何：尖端 / 箭身中心 / 全局坐标
// ======================================================================
//
// ★ 为什么要复算而不是硬编码坐标
//   轴宽由布局决定（弹窗宽 - padding），硬编码会在窗口尺寸变化时
//   静默点偏 —— 那时"点了没反应"是探针的错，却会被读成产品的错。
//   ⇒ 用产品自己的纯函数（computeSkipTips / ghostTipFor /
//     skipEdgeBodyCenter）算，与画家同源。
//
// ★ y 取 26 的理由
//   命中判定只看 dx（skip_timeline.dart:674-687 的 hitEdge 里
//   \`final d = (c - p.dx).abs()\`），y 完全不参与。
//   26 落在 _canvasH(=64) 内部、也在 _arrowH(=30) 那条带子里 ——
//   既命中箭头又不至于贴边。
const double kTapY = 26.0;

Size? timelineSize() {
  final r = _root;
  if (r == null) return null;
  final e = _findFirst(r, (w) => w is SkipTimeline);
  if (e == null) return null;
  final ro = e.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.size;
}

Offset? timelineTopLeft() {
  final r = _root;
  if (r == null) return null;
  final e = _findFirst(r, (w) => w is SkipTimeline);
  if (e == null) return null;
  final ro = e.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero);
}

/// 四个端点在当前布局下的**尖端 x**（已设置=画家画的实心箭头；
/// 未设置=幽灵位置，与画家同源）
Map<SkipEdge, double>? tipsNow() {
  final w = timelineSize()?.width;
  final t = timelineW;
  if (w == null || t == null) return null;
  final tips = computeSkipTips(
    width: w,
    total: t.total,
    introStart: t.introStart,
    introEnd: t.introEnd,
    outroStart: t.outroStart,
    outroEnd: t.outroEnd,
  );
  final out = <SkipEdge, double>{};
  for (final e in SkipEdge.values) {
    final tip =
        tips[e] ??
        ghostTipFor(edge: e, width: w, inset: kArrowInset, arrowW: kArrowW);
    out[e] = tip;
  }
  return out;
}

/// 端点箭身的**全局中心点**（就是 hitEdge 比的那个 x）
Offset? bodyPoint(SkipEdge e) {
  final o = timelineTopLeft();
  final tips = tipsNow();
  if (o == null || tips == null) return null;
  final c = skipEdgeBodyCenter(e, tips[e]);
  if (c == null) return null;
  return Offset(o.dx + c, o.dy + kTapY);
}

/// 命中自检：在 [p] 处按下，hitEdge 会选中谁
///
/// ★ 这是**仪器自检**，不是产品判据 —— 若它说"会选中别的端点"，
///   那本段的像素结论就是拿错尺子量的，不予采信。
SkipEdge? hitAt(Offset p) {
  final o = timelineTopLeft();
  final tips = tipsNow();
  if (o == null || tips == null) return null;
  const hitR = 20.0;
  SkipEdge? best;
  var bestD = hitR;
  for (final e in SkipEdge.values) {
    final c = skipEdgeBodyCenter(e, tips[e]);
    if (c == null) continue;
    final d = (o.dx + c - p.dx).abs();
    if (d < bestD) {
      bestD = d;
      best = e;
    }
  }
  return best;
}

/// 预览框（\`AspectRatio\` 那个 RenderBox）的全局矩形，**四边内缩 8px**
///
/// ★ 为什么要内缩：\`ClipRRect\` 圆角 + 边框会污染四边；
///   内缩 8px 后窗口里全是视频像素，帧间差才有意义。
Rect? previewWindow() {
  final r = _root;
  if (r == null) return null;
  for (final e in _findAll(r, (w) => w is AspectRatio)) {
    final ro = e.findRenderObject();
    if (ro is RenderBox && ro.hasSize && ro.size.width > 100) {
      final g = ro.localToGlobal(Offset.zero) & ro.size;
      return Rect.fromLTRB(g.left + 8, g.top + 8, g.right - 8, g.bottom - 8);
    }
  }
  return null;
}

/// 预览框**渲染出来的**尺寸（用于证明宽高比真的跟着素材走）
Size? previewSize() {
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

// ======================================================================
//  指针注入（与物理鼠标同一条管线）
// ======================================================================

var _ptr = 9600;

/// 一次完整单击
///
/// ⚠️ down 与 up 之间**必须让出事件循环**：手势竞技场要在真实的帧上结算
///    （\`kDoubleTapTimeout\` 挂在帧回调上）。同一个 microtask 里连发会漏掉 up。
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
  await settle(700);
  if (label.isNotEmpty)
    note(
      '已单击 $label @ (${pos.dx.toStringAsFixed(1)}, ${pos.dy.toStringAsFixed(1)})',
    );
}

Future<bool> tapEl(Element? e, {String label = ''}) async {
  final c = centerOf(e);
  if (c == null) {
    say('!! 找不到可点的元素「$label」');
    return false;
  }
  await tapAt(c, label: label);
  return true;
}

/// 点「和 [rowY] 同一行」的那个文本
Future<bool> tapTextInRow(String text, double rowY, {String? label}) async {
  final e = pickInRow(findTextEls(text), rowY);
  if (e == null) {
    say('!! 行 y=$rowY 附近找不到文本「$text」');
    return false;
  }
  return tapEl(e, label: label ?? '文本「$text」');
}

/// 点某一行的 `+` / `−`
///
/// ★ 为什么不能只按 dy 挑（第一版就栽在这）：四行用的是**同一个
///   const Icon(Icons.add) 实例**，按 widget 身份找会命中四个；而"同一行"
///   还包含「−」和「▶」，只按 dy 可能点错。可靠的判据是 **x 关系** ——
///   行结构是 [标签][读数][−][+][▶] ⇒
///     `+` = 中心落在读数右侧的那些 add 图标里**最靠左**的
///     `−` = 中心落在读数左侧的那些 remove 图标里**最靠右**的
///
/// ⚠️ 读数未设置时是 `— — —`（四行同一个字面量），所以这里改用
///    [rowValueCenter]：按行 dy 找那个读数 Text，而不是按文本内容找。
Future<bool> tapStep(String label, {required bool plus, int times = 1}) async {
  for (var i = 0; i < times; i++) {
    final rowY = labelRowY(label);
    if (rowY == null) {
      say('!! 找不到行「' + label + '」');
      return false;
    }
    final r = _root;
    if (r == null) return false;
    final valueC = rowValueCenter(label);
    final icon = plus ? Icons.add : Icons.remove;
    Element? best;
    double? bestDx;
    for (final e in _findAll(r, (w) => w is Icon && w.icon == icon)) {
      final c = centerOf(e);
      if (c == null) continue;
      if ((c.dy - rowY).abs() >= 24) continue;
      if (valueC != null) {
        if (plus && c.dx <= valueC.dx + 1) continue;
        if (!plus && c.dx >= valueC.dx - 1) continue;
      }
      if (best == null) {
        best = e;
        bestDx = c.dx;
      } else if (plus ? c.dx < bestDx! : c.dx > bestDx!) {
        best = e;
        bestDx = c.dx;
      }
    }
    if (best == null) {
      say('!! 「' + label + '」这一行找不到 ' + (plus ? '+' : '-'));
      return false;
    }
    await tapEl(best, label: label + (plus ? ' +' : ' -'));
  }
  return true;
}

/// ★ 本探针的主角：单击某个端点的**箭头**
///
/// 落点是箭身中心（不是尖端）—— 与 hitEdge 的判定同源。
Future<bool> tapArrow(SkipEdge e) async {
  final p = bodyPoint(e);
  if (p == null) {
    say('!! 算不出 ${e.name} 的箭身中心');
    return false;
  }
  final who = hitAt(p);
  if (who != e) {
    say(
      '!! 仪器自检失败：在 ${e.name} 的箭身中心按下，'
      'hitEdge 会选中 ${who?.name ?? "null"} ⇒ 本段结论不予采信',
    );
    return false;
  }
  await tapAt(p, label: '箭头「${edgeName(e)}」');
  return true;
}

/// 点某一行的 ▶ 预览按钮（未设置时它退化成 onTapValue，也是同一个终点）
Future<bool> tapPreviewBtn(String label) async {
  final rowY = labelRowY(label);
  if (rowY == null) {
    say('!! 找不到行「$label」');
    return false;
  }
  final r = _root;
  if (r == null) return false;
  // 宽布局是 TextButton.icon（Text('预览')）；窄布局是 IconButton(play_arrow)
  var e = pickInRow(findTextEls('预览'), rowY);
  e ??= pickInRow(
    _findAll(r, (w) => w is Icon && w.icon == Icons.play_arrow),
    rowY,
  );
  if (e == null) {
    say('!! 「$label」这一行找不到 ▶ 按钮');
    return false;
  }
  return tapEl(e, label: '$label ▶');
}

String edgeName(SkipEdge e) => switch (e) {
  SkipEdge.introStart => '片头开始',
  SkipEdge.introEnd => '片头结束',
  SkipEdge.outroStart => '片尾开始',
  SkipEdge.outroEnd => '片尾结束',
};

// ======================================================================
//  数据目录（带硬闸 —— 缺 DATA_DIR_OVERRIDE 就拒绝启动）
// ======================================================================

Future<String> resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isEmpty) {
    say('!! 拒绝启动：缺 --dart-define=DATA_DIR_OVERRIDE');
    say('   本探针会走真机 FFI（点「重置」真的清库），没有隔离目录');
    say('   就会落到真实用户库 %APPDATA%/app.sourin.player。');
    say('   正确命令：');
    say(
      '     flutter build windows --debug -t lib/t513_skip_preview_probe.dart',
    );
    say(
      '       --dart-define=DATA_DIR_OVERRIDE=D:/WishProject/sourin-flutter-spike/.probe/t513_data',
    );
    exit(3);
  }
  final d = Directory(override);
  if (!await d.exists()) await d.create(recursive: true);
  return d.path;
}

// ======================================================================
//  宿主：逐字复刻生产结构（与 t465 同一套 —— 踩过坑才对的）
// ======================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    MediaKit.ensureInitialized();
    say('MediaKit 已初始化');
  } catch (e) {
    say('!! MediaKit.ensureInitialized 失败: ' + e.toString());
    say('   （需要 libmpv-2.dll 在 exe 同目录）');
    exit(2);
  }

  final dataDir = await resolveDataDir();
  say('数据目录 = ' + dataDir);
  try {
    await UiPrefs.load(dataDir);
  } catch (e) {
    say('!! UiPrefs.load 失败（继续）: ' + e.toString());
  }
  try {
    await SourinCore.startAsync(dataDir);
    say('SourinCore 已启动');
  } catch (e) {
    say('!! SourinCore.startAsync 失败（继续）: ' + e.toString());
  }

  if (Platform.isWindows) {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setSize(const Size(1280, 800));
      say('窗口 1280x800');
    } catch (e) {
      say('!! windowManager 失败（继续）: ' + e.toString());
    }
  }

  Directory(_outDir).createSync(recursive: true);
  say('输出目录 = ' + _outDir);
  say(
    '媒体 = ' +
        kProbeMedia +
        '  exists=' +
        File(kProbeMedia).existsSync().toString(),
  );

  runApp(const _ProbeApp());
}

class _ProbeApp extends StatelessWidget {
  const _ProbeApp();

  @override
  Widget build(BuildContext context) {
    /*
     * 主题链必须逐字复刻生产（t465 实测踩到，别再踩）
     *
     * 用 toApproximateMaterialTheme() 会绕过 theme_bridge.dart:240-307 的
     * fixButtonContrast，让「确认设置」渲染成纯黑药丸、字看不见。
     * 生产走的是 lib/shell.dart:1184-1186 的 buildLightMaterialTheme。
     */
    final theme = AppTheme.themeFor(Brightness.light);
    final materialTheme = buildLightMaterialTheme(theme);
    return RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        theme: materialTheme,
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

  /// 与生产 player_page.dart:3377-3411 同一形态（真实 showDialog 路由）
  void _openDialog(BuildContext ctx) {
    // ★ task-104：走全项目统一入口（动效与生产一致，不再有裸 showDialog）
    unawaited(
      showAppDialog<SkipMarkerResult>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => const SkipMarkerDialog(
          provider: 'probe',
          id: 't513',
          title: 't513 真机实测',
          streamUrl: kProbeMedia,
          duration: Duration(seconds: 40),
        ),
      ),
    );
  }

  Future<void> _run() async {
    final sink = StringBuffer();
    var crashed = '';
    try {
      await _body(sink);
    } catch (e, st) {
      crashed = e.toString() + ' / ' + st.toString();
      sink.writeln('!! 探针异常: ' + e.toString());
      sink.writeln(st.toString());
    }
    sink.writeln('');
    sink.writeln('RESULT pass=' + pass.toString() + ' fail=' + fail.toString());
    final out = _outDir + '/result.txt';
    File(out).writeAsStringSync(sink.toString());
    say('RESULT pass=' + pass.toString() + ' fail=' + fail.toString());
    if (crashed.isNotEmpty) say('崩溃: ' + crashed);
    say('结果文件 = ' + out);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(fail == 0 ? 0 : 1);
  }
}

// ======================================================================
//  读数快照 + 等帧稳定
// ======================================================================

/// 一次「画面 + 产品自报位置」的快照
class _Snap {
  const _Snap({
    required this.tag,
    required this.px,
    required this.w,
    required this.h,
    required this.win,
    required this.colors,
    required this.pos,
  });

  final String tag;
  final Uint8List px;
  final int w;
  final int h;

  /// 预览框的判据窗口（全局坐标，四边内缩 8px）
  final Rect win;

  /// 窗口内的不同颜色数（证明"这里真有画面"）
  final int colors;

  /// 产品自己报的位置 = _previewPos（乐观值 —— 只当辅助读数）
  final double pos;
}

Rect _isect(Rect a, Rect b) {
  final l = a.left > b.left ? a.left : b.left;
  final t = a.top > b.top ? a.top : b.top;
  final r = a.right < b.right ? a.right : b.right;
  final bo = a.bottom < b.bottom ? a.bottom : b.bottom;
  return Rect.fromLTRB(l, t, r, bo);
}

/// 抓一张快照（不落盘）
Future<_Snap?> snap(String tag) async {
  final g = await grabRgba();
  if (g == null) return null;
  final (px, w, h) = g;
  final win = previewWindow();
  if (win == null) return null;
  return _Snap(
    tag: tag,
    px: px,
    w: w,
    h: h,
    win: win,
    colors: regionColors(px, w, h, win),
    pos: timelineW?.position ?? -1,
  );
}

/// 反复抓，直到**连续两张几乎一样**（解码器追上了），返回最后一张
///
/// 为什么要这样等：_previewSeek 里的 _previewPos 是乐观值，
/// 位置读数一到说明不了"画面到了"。像素稳了 = 解码器真的停在那里。
Future<_Snap?> snapStable(
  String tag, {
  int tries = 10,
  int gap = 320,
  double tol = 0.02,
}) async {
  _Snap? last;
  for (var i = 0; i < tries; i++) {
    await settle(gap);
    final s = await snap(tag + '/#' + i.toString());
    if (s == null) return last;
    if (last != null) {
      final r = _isect(last.win, s.win);
      final d = pixelDiffRatio(last.px, s.px, s.w, s.h, r);
      if (d < tol) {
        note(tag + ' 已稳（与上一张差 ' + (d * 100).toStringAsFixed(2) + '%）');
        return s;
      }
    }
    last = s;
  }
  say('!! ' + tag + ' 等了 ' + tries.toString() + ' 张仍不稳（解码器没停下？）');
  return last;
}

/// 等产品自报的位置稳定落在 target 附近
Future<bool> waitPos(double target, {double tol = 1.5, int tries = 40}) async {
  var stable = 0;
  for (var i = 0; i < tries; i++) {
    await settle(120);
    final p = timelineW?.position;
    if (p != null && (p - target).abs() <= tol) {
      stable++;
      if (stable >= 2) return true;
    } else {
      stable = 0;
    }
  }
  return false;
}

/// 两个快照的帧间差（判据窗口取交集）
double diffOf(_Snap a, _Snap b) =>
    pixelDiffRatio(a.px, b.px, a.w, a.h, _isect(a.win, b.win));

Future<bool> tapText(String text) async =>
    tapEl(findTextEl(text), label: '「' + text + '」');

/// 某一行的**读数文本**元素中心（四行读数内容可能相同，只能按 dy 挑）
///
/// 读数文本在行里的位置是 [标签][读数][−][+][▶] 的第二格；
/// 同一 dy 上只有一个读数 Text ⇒ 取该 dy 带内最靠左的那个 Text。
Offset? rowValueCenter(String label) {
  final rowY = labelRowY(label);
  if (rowY == null) return null;
  final r = _root;
  if (r == null) return null;
  final cands = <Element>[];
  for (final e in _findAll(r, (w) => w is Text && w.data != null)) {
    final c = centerOf(e);
    if (c == null) continue;
    if ((c.dy - rowY).abs() >= 24) continue;
    // 排除行标签自身（它的中心就是 rowY 那条线上的锚点）
    final w = e.widget;
    if (w is Text && w.data == label) continue;
    cands.add(e);
  }
  return centerOf(pickInRow(cands, rowY));
}

/// ★ 入口②：单击某一行的**读数文本**（未设置时是 `— — —`，也应可点）
Future<bool> tapValueInRow(String label) async {
  final rowY = labelRowY(label);
  if (rowY == null) {
    say('!! 找不到行「' + label + '」');
    return false;
  }
  final r = _root;
  if (r == null) return false;
  final cands = <Element>[];
  for (final e in _findAll(r, (w) => w is Text && w.data != null)) {
    final c = centerOf(e);
    if (c == null) continue;
    if ((c.dy - rowY).abs() >= 24) continue;
    final w = e.widget;
    if (w is Text && w.data == label) continue;
    cands.add(e);
  }
  final e = pickInRow(cands, rowY);
  if (e == null) {
    say('!! 「' + label + '」这一行找不到读数文本');
    return false;
  }
  return tapEl(e, label: label + ' 的读数');
}

// ======================================================================
//  预览状态探针
// ======================================================================

/// 预览框三态里的错误文案（以「预览不可用：」开头）—— 有就直接报出来
String? previewErrText() {
  final r = _root;
  if (r == null) return null;
  for (final e in _findAll(r, (w) => w is Text && w.data != null)) {
    final d = (e.widget as Text).data!;
    if (d.startsWith('预览不可用：')) return d.split('\n').first;
  }
  return null;
}

/// 等预览首帧真的画出来（两个 loading 态都消失、且没有错误文案）
Future<bool> waitFirstFrame() async {
  for (var i = 0; i < 80; i++) {
    await settle(250);
    if (previewErrText() != null) return false;
    if (findTextEl('正在加载预览…') == null && findTextEl('正在启动预览…') == null) {
      return true;
    }
  }
  return false;
}

/// 等预览框宽高比真的变成素材的（证明它跟真实视频走，不是兜底的 16:9）
Future<double?> waitAspect(double want, {int tries = 40}) async {
  for (var i = 0; i < tries; i++) {
    await settle(250);
    final s = previewSize();
    if (s != null && s.height > 0) {
      final a = s.width / s.height;
      if ((a - want).abs() < 0.05) return a;
    }
  }
  final s = previewSize();
  return (s == null || s.height == 0) ? null : s.width / s.height;
}

// ======================================================================
//  主流程
// ======================================================================

Future<void> _body(StringBuffer sink) async {
  void log(String s) {
    sink.writeln(s);
    note(s);
  }

  log('=== t513 片头片尾「单击预览这一帧」真机实测（task-13 ⑥）===');
  log('时间: ' + DateTime.now().toString());
  log('素材: ' + kProbeMedia);

  // ── ⓪ 真实路由打开弹窗 ──
  final opened = await tapText('打开片头片尾设置');
  ok('⓪-1 真实路由打开弹窗', opened && timelineW != null);
  if (timelineW == null) {
    log('弹窗没打开 ⇒ 后面无从谈起，如实失败');
    return;
  }

  var waited = 0;
  while (waited < 60 && (timelineW?.total ?? 0) <= 0) {
    await settle(200);
    waited++;
  }
  log(
    '时长 = ' +
        (timelineW?.total.toString() ?? 'null') +
        '（等了 ' +
        waited.toString() +
        ' 次）',
  );

  final first = await waitFirstFrame();
  final err = previewErrText();
  ok('⓪-2 预览首帧真的出来了', first, err == null ? '' : '错误=' + err);
  if (!first) {
    log('预览起不来 ⇒ 像素判据不成立，如实失败退出（不拿黑屏当证据）');
    return;
  }

  final asp = await waitAspect(4 / 3);
  ok(
    '⓪-3 预览框宽高比 = 素材的 4:3（不是兜底 16:9）',
    asp != null && (asp - 4 / 3).abs() < 0.06,
    '实际=' + (asp?.toStringAsFixed(3) ?? 'null'),
  );

  final win0 = previewWindow();
  final s0 = await snap('自检');
  ok(
    '⓪-4 判据窗口有效（AspectRatio 的 RenderBox 内缩 8px）',
    win0 != null && win0.width > 60 && win0.height > 40,
    win0 == null ? '' : '窗口=' + win0.toString(),
  );
  ok(
    '⓪-5 判据窗口里真有画面（不是纯黑）',
    (s0?.colors ?? 0) > 20,
    '不同颜色数=' + (s0?.colors ?? -1).toString(),
  );

  // ── ⓪-6..8 几何自检（落点必须与产品 hitEdge 同源，否则整段结论不予采信）──
  final pts = <SkipEdge, Offset>{};
  for (final e in SkipEdge.values) {
    final p = bodyPoint(e);
    if (p != null) pts[e] = p;
  }
  ok('⓪-6 四个端点的箭身落点都算得出来', pts.length == 4);
  if (pts.length == 4) {
    var minGap = 1e9;
    for (var i = 0; i < 4; i++) {
      for (var j = i + 1; j < 4; j++) {
        final d = (pts[SkipEdge.values[i]]!.dx - pts[SkipEdge.values[j]]!.dx)
            .abs();
        if (d < minGap) minGap = d;
      }
    }
    ok(
      '⓪-7 四个落点两两可分辨（最近间距 > 8px）',
      minGap > 8,
      '最近间距=' + minGap.toStringAsFixed(1) + 'px',
    );
    var allHit = true;
    final detail = StringBuffer();
    for (final e in SkipEdge.values) {
      final who = hitAt(pts[e]!);
      if (who != e) allHit = false;
      detail.write(e.name + '->' + (who?.name ?? 'null') + ' ');
    }
    ok('⓪-8 仪器自检：落点处的 hitEdge 判定 == 目标端点', allHit, detail.toString());
    log(
      '几何: 轴宽=' +
          (timelineSize()?.width.toStringAsFixed(1) ?? 'null') +
          ' 左上=' +
          (timelineTopLeft()?.toString() ?? 'null'),
    );
    for (final e in SkipEdge.values) {
      log('  ' + e.name + ' 落点=' + pts[e].toString());
    }
  }

  var rowsOk = true;
  for (final e in SkipEdge.values) {
    if (labelRowY(edgeName(e)) == null) rowsOk = false;
  }
  ok('⓪-9 四行读数（片头开始/结束、片尾开始/结束）都在树上', rowsOk);
  ok('⓪-10 「重置」按钮存在（阳性对照要用）', findTextEl('重置') != null);

  // ── ⓪-11/12 建立自己的前提 ──
  final r1 = await tapText('重置');
  var sawReset = false;
  for (var i = 0; i < 20; i++) {
    await settle(200);
    if (snackTexts().any((s) => s.contains('已重置'))) {
      sawReset = true;
      break;
    }
  }
  ok(
    '⓪-11 点「重置」⇒ 真的弹出「已重置」（阳性对照：手势管线通）',
    r1 && sawReset,
    'SnackBar=' + snackTexts().join('|'),
  );
  for (var i = 0; i < 40; i++) {
    await settle(250);
    if (snackTexts().isEmpty) break;
  }
  final tw = timelineW;
  ok(
    '⓪-12 前置闸：四个端点都未设置（读 timelineW 字段）',
    tw != null &&
        tw.introStart == null &&
        tw.introEnd == null &&
        tw.outroStart == null &&
        tw.outroEnd == null,
    'introStart=' +
        (tw?.introStart?.toString() ?? 'null') +
        ' introEnd=' +
        (tw?.introEnd?.toString() ?? 'null') +
        ' outroStart=' +
        (tw?.outroStart?.toString() ?? 'null') +
        ' outroEnd=' +
        (tw?.outroEnd?.toString() ?? 'null'),
  );

  // ── 用例跑法 ──
  var caseNo = 0;
  Future<void> oneCase({
    required String name,
    required double kick,
    required double expect,
    required Future<bool> Function() act,
    required String actDesc,
  }) async {
    caseNo++;
    final tag = 'C' + caseNo.toString() + '-' + name;
    log('');
    log(
      '-- ' +
          tag +
          '：' +
          actDesc +
          ' => 期望停到 ' +
          expect.toStringAsFixed(1) +
          's --',
    );

    // 前提：把预览挪到别处，等画面真稳（否则帧间差没有意义）
    timelineW?.onSeek(kick);
    final kicked = await waitPos(kick);
    final before = await snapStable(tag + '-点击前');
    if (before == null) {
      ok(tag + '-a 抓到「点击前」的画面', false);
      return;
    }
    final gap = (kick - expect).abs();
    ok(
      tag +
          '-a 前提：预览已挪到 ' +
          kick.toStringAsFixed(0) +
          's（与期望差 ' +
          gap.toStringAsFixed(1) +
          's）且画面非黑',
      kicked && gap > 3 && before.colors > 20,
      '颜色数=' + before.colors.toString(),
    );
    if (!kicked || gap <= 3) return;
    await shoot(tag + '-点击前');

    // 动作
    final acted = await act();
    if (!acted) {
      ok(tag + '-b 触发「' + actDesc + '」', false);
      return;
    }

    // 判据：位置 + 像素
    final posOk = await waitPos(expect);
    final after = await snapStable(tag + '-点击后');
    if (after == null) {
      ok(tag + '-c 抓到「点击后」的画面', false);
      return;
    }
    final d = diffOf(before, after);
    await shoot(tag + '-点击后');

    // 冻住？
    await settle(700);
    final later = await snap(tag + '-700ms后');
    final dFrozen = later == null ? 1.0 : diffOf(after, later);

    // 阴性对照：原地再点一次，画面不该再变
    final acted2 = await act();
    final again = await snapStable(tag + '-再点一次');
    final dAgain = again == null ? 1.0 : diffOf(after, again);

    ok(
      tag + '-b 产品自报位置落在 ' + expect.toStringAsFixed(1) + 's',
      posOk,
      'pos=' + after.pos.toStringAsFixed(2),
    );
    ok(
      tag + '-c ★像素判据：画面真的换了（帧间差 > 5%）',
      d > 0.05,
      'diff=' + (d * 100).toStringAsFixed(1) + '%',
    );
    ok(
      tag + '-d 点击后是**真画面**（不是黑屏）',
      after.colors > 20,
      '颜色数=' + after.colors.toString(),
    );
    ok(
      tag + '-e 点完**冻住**（700ms 后几乎没动）',
      dFrozen < 0.02,
      'diff=' + (dFrozen * 100).toStringAsFixed(2) + '%',
    );
    ok(
      tag + '-f 阴性对照：原地再点一次 => 画面几乎不变',
      acted2 && dAgain < 0.02,
      'diff=' + (dAgain * 100).toStringAsFixed(2) + '%',
    );
    sink.writeln(
      '   [' +
          tag +
          '] 位置 ' +
          before.pos.toStringAsFixed(2) +
          ' -> ' +
          after.pos.toStringAsFixed(2) +
          ' | 帧间差 ' +
          (d * 100).toStringAsFixed(1) +
          '%' +
          ' | 冻结差 ' +
          (dFrozen * 100).toStringAsFixed(2) +
          '%' +
          ' | 重复点差 ' +
          (dAgain * 100).toStringAsFixed(2) +
          '%' +
          ' | 颜色数 ' +
          before.colors.toString() +
          '->' +
          after.colors.toString(),
    );
  }

  // ══ 第一组：四个端点都未设置 => 单击「幽灵箭头」（Owner 抱怨的那个）══
  log('');
  log('== 第一组：未设置时单击幽灵箭头 ==');
  await oneCase(
    name: '幽灵箭头-片头开始',
    kick: 20,
    expect: 0,
    act: () => tapArrow(SkipEdge.introStart),
    actDesc: '单击「片头开始」箭头',
  );
  await oneCase(
    name: '幽灵箭头-片头结束',
    kick: 3,
    expect: 30,
    act: () => tapArrow(SkipEdge.introEnd),
    actDesc: '单击「片头结束」箭头',
  );
  await oneCase(
    name: '幽灵箭头-片尾开始',
    kick: 32,
    expect: 10,
    act: () => tapArrow(SkipEdge.outroStart),
    actDesc: '单击「片尾开始」箭头',
  );
  await oneCase(
    name: '幽灵箭头-片尾结束',
    kick: 18,
    expect: 40,
    act: () => tapArrow(SkipEdge.outroEnd),
    actDesc: '单击「片尾结束」箭头',
  );

  // ══ 第二组：三个入口都要能预览「已设置」的值 ══
  log('');
  log('== 第二组：先用 + 把「片头结束」设成 3s，再测三个入口 ==');
  final setOk = await tapStep('片头结束', plus: true, times: 3);
  await settle(900);
  final tw2 = timelineW;
  ok(
    'D-0 前置：点三次「+」后 introEnd = 3（读字段）',
    setOk && tw2?.introEnd == 3,
    'introEnd=' + (tw2?.introEnd?.toString() ?? 'null'),
  );
  await oneCase(
    name: '实心箭头-片头结束',
    kick: 20,
    expect: 3,
    act: () => tapArrow(SkipEdge.introEnd),
    actDesc: '单击已设置的「片头结束」箭头',
  );
  await oneCase(
    name: '读数文本-片头结束',
    kick: 22,
    expect: 3,
    act: () => tapValueInRow('片头结束'),
    actDesc: '单击「片头结束」那一行的读数文本',
  );
  await oneCase(
    name: '预览按钮-片头结束',
    kick: 25,
    expect: 3,
    act: () => tapPreviewBtn('片头结束'),
    actDesc: '单击「片头结束」那一行的 ▶ 预览',
  );
  await oneCase(
    name: '预览按钮-未设置-片尾开始',
    kick: 33,
    expect: 10,
    act: () => tapPreviewBtn('片尾开始'),
    actDesc: '单击「片尾开始」那一行的 ▶（该点仍未设置 => 走默认）',
  );

  // ══ 第三组：回归 —— 点时间轴空白处仍能跳转（既有行为不能被改坏）══
  log('');
  log('== 第三组：回归 —— 单击时间轴空白处仍能跳转 ==');
  await oneCase(
    name: '空白处-仍能跳转',
    kick: 35,
    expect: 20,
    act: () async {
      final o = timelineTopLeft();
      final sz = timelineSize();
      final t = timelineW;
      if (o == null || sz == null || t == null) return false;
      final x = xOfTip(width: sz.width, total: t.total, sec: 20);
      final p = Offset(o.dx + x, o.dy + kTapY);
      final who = hitAt(p);
      if (who != null) {
        say('!! 仪器自检失败：空白处落点其实命中了 ' + who.name);
        return false;
      }
      await tapAt(p, label: '时间轴空白处 20s');
      return true;
    },
    actDesc: '单击时间轴空白处（20s 位置）',
  );

  log('');
  log('== 汇总 ==');
  log('pass=' + pass.toString() + ' fail=' + fail.toString());
  if (fail == 0) {
    log('结论：三个入口（箭头 / 读数文本 / ▶ 按钮）单击后都真的换帧、');
    log('      且换到目标位置、换完冻住；原地重复点不动（阴性对照）；');
    log('      未设置时按 _defaultAt 的默认位置预览，不再是「点了没反应」。');
  } else {
    log('结论：有 ' + fail.toString() + ' 项未通过 —— 见上面的 FAIL 行。');
  }
}
