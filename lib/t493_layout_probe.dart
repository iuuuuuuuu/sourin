// ══════════════════════════════════════════════════════════════════════════
// t493 —— 布局 A/B 取证探针（只读真实 RenderBox 几何）
// ══════════════════════════════════════════════════════════════════════════
//
// # 回答什么
// 指定窗口尺寸下，浏览页网格**实际**是几列 / 单格多宽 / 列间距多大 /
// 内容带水平范围是多少 —— 全部来自 RenderBox 的 global rect，
// **不是**从 Layout.columnsForBand 那套生产公式反推的（判据纪律 #9）。
//
// # A/B 闸门
// --dart-define=LAYOUT_AB=legacy|fixed（默认 fixed，见 lib/ui/tokens.dart:256）。
// 两臂共用**同一份源码**，构建命令只差这一个 token ⇒ 这就是 AA 证据。
//
// # 判据纪律
// · #9  断言不许由生产公式反推；本文件**不 import** Layout 做判断。
// · #10 findWidgets 只走**已 build** 的元素 ⇒ 先等到 20 张卡在树上再量。
// · #11 闸门必须被消费：LAYOUT_AB 的取值会打印出来，并写进产物文件名。
// · #12 阴性读数必须由**已证明灵敏**的仪器给出 ⇒ 同一台 walker 先对
//       PosterCard(=20) 与 SliverGrid(>=1) 报正，再对不存在的类型/文案报 0。
// · #13 每个读数带单位（逻辑像素）。
//
// # ⚠️ 与任务书的唯一偏离（必须报出来，不许装作用了原 API）
// 任务书写 tester.renderObject<RenderBox>(find.byType(PosterCard).at(i))。
// 那是 WidgetTester 的 API，只在 widget test 里存在。本探针是**真实 app 探针**
// （runApp 起真窗口、真 RenderView），进程里没有 WidgetTester。
// ⇒ 用本仓既有的等价实现 globalRect(Element)（lib/t370_browse_probe.dart:272-279）：
//      renderObject as RenderBox -> localToGlobal(Offset.zero) & size
//   与 tester.renderObject<RenderBox>(...) 的几何语义一致。
//
// # 为什么量的是「格子」而不是「海报」
// SliverGrid 走 SliverGridRegularTileLayout，给每个 child **紧约束**（宽 = 列宽）；
// PosterCard 的 build 即使写 SizedBox(width: 148)，BoxConstraints.enforce 也会把它
// 撑到父级给的紧约束 ⇒ PosterCard 的 render box 宽度 = **网格列宽**（不是 148）。
// 所以本探针同时输出三个横向量，避免「cell 指哪个」的歧义：
//   cell   = PosterCard 矩形宽（= 网格列宽）
//   stride = 同行相邻卡 left 之差（= 列宽 + 列间距）
//   gap    = stride - cell（列间距）
//
// # 退出码
// 0 = 全部读数成立；1 = 有 ✗。任何异常都经 finish() 落盘，绝不静默停住。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'core/device.dart';
import 'core/ffi.dart';
import 'core/models.dart' as models;
import 'core/models.dart' show MediaItem;
import 'core/ui_prefs.dart';
import 'shell.dart';
import 'ui/app_theme.dart';
import 'ui/browse_page.dart';
import 'ui/tokens.dart';
import 'ui/widgets/poster_card.dart';

// ══════════════════════════════════════════════════════════════════════════
// 常量
// ══════════════════════════════════════════════════════════════════════════

const String _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

/// ★ A/B 闸门（与 lib/ui/tokens.dart:256 同一个 define、同一个默认值）
const String _arm = String.fromEnvironment('LAYOUT_AB', defaultValue: 'fixed');

/// 窗口尺寸（逻辑像素），例：2560x1440
const String _sizeReq = String.fromEnvironment('T493_SIZE', defaultValue: '2560x1440');

const String _provider = '360';
const String _pageTitle = '浏览';
const int _perPage = 20;

/// ★ pageCount=1 ⇒ 不会有第 2 页，树里就是确定的 20 条。
const int _totalPages = 1;

const String _negType = 'T493NoSuchWidgetXYZ';
const String _negText = 'T493-不存在的文案XYZ';

// ══════════════════════════════════════════════════════════════════════════
// 计数 / 日志
// ══════════════════════════════════════════════════════════════════════════

int pass = 0;
int fail = 0;
final List<String> _log = <String>[];
final List<String> _shots = <String>[];

void say(String s) {
  _log.add(s);
  debugPrint('[T493] $s');
}

void note(String s) => say('·  $s');

void ok(String line, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
  } else {
    fail++;
  }
  say('${cond ? '✓' : '✗'} $line${extra.isEmpty ? '' : '   $extra'}');
}

String _f2(double v) => v.toStringAsFixed(2);

String _armLabel() => _arm == 'legacy' ? 'legacy' : 'fixed';

class _SizeSpec {
  const _SizeSpec(this.w, this.h, this.label);
  final double w;
  final double h;
  final String label;
}

_SizeSpec _parseSize(String s) {
  final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(s.trim().toLowerCase());
  if (m == null) {
    return const _SizeSpec(2560, 1440, '2560x1440');
  }
  var w = double.parse(m.group(1)!);
  var h = double.parse(m.group(2)!);
  if (w < 900) w = 900;
  if (h < 600) h = 600;
  return _SizeSpec(w, h, '${w.toInt()}x${h.toInt()}');
}

final _SizeSpec _size = _parseSize(_sizeReq);

Future<Never> finish(int code) async {
  say('');
  say('RESULT pass=$pass fail=$fail');
  say('ARM ab=$_arm mode=${_armLabel()} size=${_size.label}');
  final path = '$_outDir\\t493-${_armLabel()}-${_size.label}.txt';
  try {
    final f = File(path);
    f.writeAsStringSync('${_log.join('\n')}\n');
    debugPrint('[T493] 产物 = ${f.path}  ${f.lengthSync()} B');
  } catch (e) {
    debugPrint('[T493] ★ 产物写失败: $e');
  }
  await Future<void>.delayed(const Duration(milliseconds: 250));
  exit(code);
}

// ══════════════════════════════════════════════════════════════════════════
// 元素树
// ══════════════════════════════════════════════════════════════════════════

List<Element> findWidgets(Element root, bool Function(Widget w) test) {
  final out = <Element>[];
  void walk(Element e) {
    if (test(e.widget)) out.add(e);
    e.visitChildren(walk);
  }

  walk(root);
  return out;
}

int elementCount(Element root) {
  var n = 0;
  void walk(Element e) {
    n++;
    e.visitChildren(walk);
  }

  walk(root);
  return n;
}

/// 树里有没有 ErrorWidget（release 下子树抛错就变成它）
bool hasErrorWidget(Element root) => findWidgets(
      root,
      (w) => w.runtimeType.toString().contains('ErrorWidget'),
    ).isNotEmpty;

/// ★★ 本探针唯一的几何仪器（等价于 tester.renderObject<RenderBox>(...) 的全局矩形）
///
/// 逻辑像素，与 toImage(pixelRatio:1.0) 同一坐标系。
/// 返回 null 有三种原因，调用方必须区分「没有」与「量不到」：
///   · 元素为 null
///   · renderObject 不是 RenderBox
///   · RenderBox 还没 hasSize（未 layout 完）
Rect? globalRect(Element? e) {
  if (e == null) return null;
  final ro = e.renderObject;
  if (ro is! RenderBox) return null;
  if (!ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

// ══════════════════════════════════════════════════════════════════════════
// 帧 / 事件
// ══════════════════════════════════════════════════════════════════════════

Future<void> pumpFrame() async {
  SchedulerBinding.instance.scheduleFrame();
  await SchedulerBinding.instance.endOfFrame
      .timeout(const Duration(seconds: 2), onTimeout: () {});
}

Future<void> waitFor(int ms) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  await pumpFrame();
}

Future<bool> waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 20),
  String label = '',
}) async {
  final t0 = DateTime.now();
  while (DateTime.now().difference(t0) < timeout) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await pumpFrame();
  }
  if (label.isNotEmpty) note('waitUntil 超时: $label');
  return cond();
}

// ══════════════════════════════════════════════════════════════════════════
// 截图（仪器退化自检 + 留档）
// ══════════════════════════════════════════════════════════════════════════

final GlobalKey _rootKey = GlobalKey();

class Shot {
  Shot(this.path, this.w, this.h, this.bytes, this.colors);

  final String path;
  final int w;
  final int h;
  final Uint8List bytes;
  final int colors;

  int get rowBytes => w * 4;

  int px(int x, int y) {
    final o = y * rowBytes + x * 4;
    return (bytes[o] << 16) | (bytes[o + 1] << 8) | bytes[o + 2];
  }
}

Future<Shot> shoot(String name) async {
  final ctx = _rootKey.currentContext;
  if (ctx == null) throw StateError('root context 为 null');
  final ro = ctx.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    throw StateError('根不是 RenderRepaintBoundary，而是 ${ro.runtimeType}');
  }
  final img = await ro.toImage(pixelRatio: 1.0);
  final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bd == null) throw StateError('toByteData 返回 null');
  final rgba = bd.buffer.asUint8List();
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  final path = '$_outDir\\t493-$name.png';
  if (png != null) {
    File(path).writeAsBytesSync(png.buffer.asUint8List());
  }
  _shots.add(path);
  final seen = <int>{};
  for (var i = 0; i + 3 < rgba.length; i += 7 * 4) {
    seen.add((rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2]);
  }
  return Shot(path, img.width, img.height, rgba, seen.length);
}

// ══════════════════════════════════════════════════════════════════════════
// 数据目录
// ══════════════════════════════════════════════════════════════════════════

Future<String> _resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isNotEmpty) {
    await Directory(override).create(recursive: true);
    return override;
  }
  final appData = Platform.environment['APPDATA'] ?? '';
  return '$appData\\app.sourin.player';
}

// ══════════════════════════════════════════════════════════════════════════
// 确定性取数（只替换取数那一步，页面本体是生产代码）
// ══════════════════════════════════════════════════════════════════════════

final List<int> _loaderCalls = <int>[];

Future<models.Page<MediaItem>> _detLoader(int page) async {
  _loaderCalls.add(page);
  return models.Page<MediaItem>(
    items: <MediaItem>[
      for (var i = 0; i < _perPage; i++)
        MediaItem(
            id: 'demo:${page * 100 + i}',
            title: 't493条目${page * 100 + i}'),
    ],
    page: page,
    pageCount: _totalPages,
  );
}

// ══════════════════════════════════════════════════════════════════════════
// 几何读数
// ══════════════════════════════════════════════════════════════════════════

class CardGeo {
  CardGeo(this.index, this.rect);
  final int index;
  final Rect rect;
  double get left => rect.left;
  double get top => rect.top;
  double get width => rect.width;
  double get height => rect.height;
  double get right => rect.right;
}

double _median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final s = <double>[...xs]..sort();
  final n = s.length;
  if (n.isOdd) return s[n ~/ 2];
  return (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

bool _strictlyIncreasing(List<double> xs) {
  for (var i = 1; i < xs.length; i++) {
    if (xs[i] <= xs[i - 1]) return false;
  }
  return true;
}

class GridReading {
  GridReading({
    required this.rowsOf,
    required this.cols,
    required this.cell,
    required this.stride,
    required this.gap,
    required this.cellH,
    required this.minLeft,
    required this.maxRight,
    required this.widthSpread,
    required this.strideSpread,
  });

  final List<List<CardGeo>> rowsOf;
  final int cols;
  final double cell;
  final double stride;
  final double gap;
  final double cellH;
  final double minLeft;
  final double maxRight;
  final double widthSpread;
  final double strideSpread;

  int get rows => rowsOf.length;
  int get count => rowsOf.fold(0, (a, r) => a + r.length);
  double get span => maxRight - minLeft;
  List<int> get rowCounts => rowsOf.map((r) => r.length).toList();
}

/// ★ 从**真实矩形**分行：同行 top 相同（容差 0.5 逻辑像素）。
///   「几列」= 单行里不同 left 的个数；不做任何四舍五入猜测。
GridReading _readGrid(List<CardGeo> cards) {
  final sorted = <CardGeo>[...cards]
    ..sort((a, b) {
      final t = a.top.compareTo(b.top);
      return t != 0 ? t : a.left.compareTo(b.left);
    });
  final rows = <List<CardGeo>>[];
  for (final c in sorted) {
    if (rows.isNotEmpty && (c.top - rows.last.first.top).abs() <= 0.5) {
      rows.last.add(c);
    } else {
      rows.add(<CardGeo>[c]);
    }
  }
  var cols = 0;
  for (final r in rows) {
    if (r.length > cols) cols = r.length;
  }
  // 取「卡最多的那一行」算 stride（该行 left 严格递增）
  var widest = <CardGeo>[];
  for (final r in rows) {
    if (r.length >= widest.length) widest = r;
  }
  final strides = <double>[];
  for (var i = 1; i < widest.length; i++) {
    strides.add(widest[i].left - widest[i - 1].left);
  }
  final widths = cards.map((c) => c.width).toList();
  final heights = cards.map((c) => c.height).toList();
  final lefts = cards.map((c) => c.left).toList();
  final rights = cards.map((c) => c.right).toList();
  double spread(List<double> xs) {
    if (xs.length < 2) return 0;
    return xs.reduce((a, b) => a > b ? a : b) - xs.reduce((a, b) => a < b ? a : b);
  }

  return GridReading(
    rowsOf: rows,
    cols: cols,
    cell: _median(widths),
    stride: _median(strides),
    gap: _median(strides) - _median(widths),
    cellH: _median(heights),
    minLeft: lefts.isEmpty ? 0 : lefts.reduce((a, b) => a < b ? a : b),
    maxRight: rights.isEmpty ? 0 : rights.reduce((a, b) => a > b ? a : b),
    widthSpread: spread(widths),
    strideSpread: spread(strides),
  );
}

List<CardGeo> _cardGeos(Element root, void Function(int bad) onBad) {
  final els = findWidgets(root, (w) => w is PosterCard);
  final out = <CardGeo>[];
  var bad = 0;
  for (var i = 0; i < els.length; i++) {
    final r = globalRect(els[i]);
    if (r == null) {
      bad++;
      continue;
    }
    out.add(CardGeo(i, r));
  }
  onBad(bad);
  return out;
}

/// ⊥ 生产公式对照 —— **只打印**。本函数的输出不参与任何 ok()（判据纪律 #9）。
///
/// ★ 这里还把两条列数算法在**多个窗口宽**上闭式重算一遍，为的是看出「两臂到底差在哪些宽度」。
///   2560 上两臂被 12 列上限截断成同一结果，只看一个尺寸会误以为 A/B 闸门失效。
///
/// 公式按 lib/ui/tokens.dart 现文重算，用于人工看出「实测 vs 公式」是否对得上。
List<String> _crossCheck(GridReading g, double band) {
  final out = <String>[];
  // ★ 这一次不再手抄常数，而是直接问 lib/ui/tokens.dart 的 Layout（唯一权威）。
  //   legacy 臂下 Layout.legacy == true ⇒ columnsForBand 自己会走 legacy 分支。
  //
  // ★★ 入参必须是**内容带宽度** Layout.bandFor(窗口宽)，不是窗口宽本身：
  //   生产侧 lib/ui/browse_page.dart:653 就是 `final band = Layout.bandFor(w)`。
  //   第一版这里错传了窗口宽 ⇒ 在 fixed 臂上打印出 cols=12（并把实测 8 标成
  //   「不一致」），与真实渲染相反 —— 那是**诊断性输出**的错误，不是渲染的错误。
  final bandReal = Layout.bandFor(band);
  final colsNow = Layout.columnsForBand(bandReal);
  final cellNow = Layout.cellWidthFor(bandReal, colsNow);
  final gapNow = Layout.gapFor(bandReal);
  final innerNow = Layout.innerWidthFor(bandReal);
  final padNow = Layout.paddingFor(bandReal);
  final sideNow = Layout.sideInsetForWindow(band);
  // 另一臂的读数也一并算出来（打印用，说明两臂应该差在哪）
  // ★ 2026-10-04（① 两侧占满）：Layout.bandFor 两条臂**都不再封顶 1440**
  //   ⇒ 另一臂的 band 与本臂相同，两臂只剩「每行张数怎么算」的差别。
  //   旧版本这里有过 bandCap = min(band, Layout.contentMaxWidth)，现已删除。
  final innerLegacy = band - 48.0;
  final nLegacy = (innerLegacy / (148.0 + 12.0)).floor();
  final colsLegacy = nLegacy < 2 ? 2 : (nLegacy > 12 ? 12 : nLegacy);
  // ★ legacy 分支只决定**列数**；列间距来自 Layout.gapFor（现文宽档 = Sp.x4 = 16），
  //   所以真正落盘的 legacy 列宽是 (inner - 16*(cols-1))/cols。旧注释里的 198.33
  //   是按 gap=12 算的，**与现文不符**（实测 194.67）。两个数都打出来。
  final cellLegacyGap12 = colsLegacy == 0 ? innerLegacy : (innerLegacy - 12.0 * (colsLegacy - 1)) / colsLegacy;
  final cellLegacyGap16 = colsLegacy == 0 ? innerLegacy : (innerLegacy - 16.0 * (colsLegacy - 1)) / colsLegacy;
  final innerFixed = band - 24.0 * 2;
  final nFixed = ((innerFixed + 16.0) / (152.0 + 16.0)).floor();
  final colsFixed = nFixed < 2 ? 2 : (nFixed > 12 ? 12 : nFixed);
  final cellFixed = colsFixed == 0 ? innerFixed : (innerFixed - 16.0 * (colsFixed - 1)) / colsFixed;
  const sideFixed = 0.0; // band 不再封顶 ⇒ sideInsetForWindow 恒为 0
  out.add('⊥ 公式对照 窗口宽=${_f2(band)} ⇒ bandFor=${_f2(bandReal)}  Layout.legacy=${Layout.legacy}  Device.isTv=${Device.isTv}');
  out.add('⊥   本臂 Layout.columnsForBand ⇒ cols=$colsNow cell=${_f2(cellNow)} gap=${_f2(gapNow)} inner=${_f2(innerNow)} padding=${_f2(padNow)} sideInset=${_f2(sideNow)}');
  out.add('⊥   ｜实测 cols=${g.cols} cell=${_f2(g.cell)} gap=${_f2(g.gap)} left=${_f2(g.minLeft)} right=${_f2(g.maxRight)}  ${g.cols == colsNow ? '（列数一致）' : '（列数不一致）'} ${(g.cell - cellNow).abs() <= 0.5 ? '（列宽一致）' : '（列宽不一致 Δ=${_f2((g.cell - cellNow).abs())}）'}');
  out.add('⊥   若走 legacy（窗宽减 48 / 步长 160）⇒ cols=$colsLegacy cell=${_f2(cellLegacyGap16)}（按 gapFor=16 算，与现文一致）｜ 若按旧 gap=12 算则 ${_f2(cellLegacyGap12)}');
  out.add('⊥   若走 fixed （band 不封顶 = 窗口宽 / minCell 152 / gap 16）⇒ cols=$colsFixed cell=${_f2(cellFixed)} sideInset=${_f2(sideFixed)} ⇒ 内容带 left=${_f2(sideFixed + 24.0)} right=${_f2(band - sideFixed - 24.0)}');
  out.add('⊥   两臂对照：legacy cols=$colsLegacy / fixed cols=$colsFixed ⇒ ${colsLegacy == colsFixed ? '本尺寸下两条算法结果**相同**（预期，不是 A/B 失效）' : '本尺寸下两条算法结果**不同**'}。');
  // ★ 宽度扫描：两条列数算法的闭式解在多个窗口宽下重算（不依赖 Layout.legacy，纯公式）。
  out.add('⊥ 宽度扫描（闭式重算，不是渲染）：');
  const widths = <double>[900, 1024, 1280, 1440, 1600, 1920, 2560, 3440];
  for (final w in widths) {
    final inner = w - 24.0 * 2;
    final nL = (inner / (148.0 + 12.0)).floor();
    final cL = nL < 2 ? 2 : (nL > 12 ? 12 : nL);
    final cellL = (inner - 16.0 * (cL - 1)) / cL;
    final nF = ((inner + 16.0) / (152.0 + 16.0)).floor();
    final cF = nF < 2 ? 2 : (nF > 12 ? 12 : nF);
    final cellF = (inner - 16.0 * (cF - 1)) / cF;
    final same = cL == cF && (cellL - cellF).abs() <= 0.5;
    out.add('⊥   W=${w.toInt()}  legacy(cols=$cL cell=${_f2(cellL)})  fixed(cols=$cF cell=${_f2(cellF)})  same=$same');
  }
  out.add('⊥ 以上全是**重算公式**的产物，只供人工核对；探针的 ✓/✗ 一条都不依赖它。');
  return out;
}

// ══════════════════════════════════════════════════════════════════════════
// 主流程
// ══════════════════════════════════════════════════════════════════════════

Future<void> _body(String dir) async {
  say('');
  say('──────── ⓪ 仪器自检 ────────');
  note('exe 目录 = ${File(Platform.resolvedExecutable).parent.path}');
  note('请求窗口 = ${_size.label}（逻辑像素）  闸门 LAYOUT_AB=$_arm');

  final shellUp = await waitUntil(() => debugShellKey.currentState != null,
      timeout: const Duration(seconds: 40), label: 'shell 挂载');
  ok('⓪ shell 已挂上（debugShellKey.currentState != null）', shellUp);
  if (!shellUp) {
    say('★ shell 没挂上 ⇒ 后续全部无意义，中止');
    await finish(1);
  }

  final root = _rootKey.currentContext as Element?;
  ok('⓪ 根元素已挂上（RepaintBoundary 已 build）', root != null);
  if (root == null) {
    say('★ 根都没挂上 ⇒ 中止');
    await finish(1);
  }

  final isolated = dir.toLowerCase().contains('.probe');
  ok('⓪ 数据目录是隔离目录（含 .probe，绝不写用户库）', isolated, dir);
  if (!isolated) {
    say('★ 数据目录不是隔离目录 ⇒ 拒绝继续（绝不碰用户库）');
    await finish(1);
  }

  final shellEl = debugShellKey.currentContext;
  if (shellEl == null) {
    say('★ shell context 为 null ⇒ 中止');
    await finish(1);
  }
  // 上面几行 await 之后才取 shellEl，但那正是 shell 挂载完成的时刻；
  // shellEl 为 null 已就地返回。t370 同一形状，属取证脚本而非 UI 代码。
  // ignore: use_build_context_synchronously
  final nav = Navigator.of(shellEl);

  // ── ⓪b 真实视口（DPR 陷阱：物理 / 逻辑 / MediaQuery 全打出来）──
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final phys = view.physicalSize;
  final dprView = view.devicePixelRatio;
  final logical = phys.width / dprView;
  final logicalH = phys.height / dprView;
  final mqData = MediaQueryData.fromView(view);
  final mq = mqData.size;
  final mqRoot = MediaQuery.sizeOf(root);
  final viewOf = View.of(root);

  say('');
  say('──────── ⓪b 视口读数（除标注的 physical_px 外，一律 logical_px）────────');
  say('VIEW physical=${_f2(phys.width)}x${_f2(phys.height)} physical_px');
  say('VIEW dpr=${_f2(dprView)}');
  say('VIEW logical=${_f2(logical)}x${_f2(logicalH)} logical_px (= physical / dpr)');
  say('VIEW mediaquery=${_f2(mq.width)}x${_f2(mq.height)} logical_px (MediaQueryData.fromView)');
  say('VIEW mediaquery_at_root=${_f2(mqRoot.width)}x${_f2(mqRoot.height)} logical_px (MediaQuery.sizeOf(root))');
  say('VIEW view_of_root.physicalSize=${_f2(viewOf.physicalSize.width)}x${_f2(viewOf.physicalSize.height)} physical_px');
  say('VIEW window_requested=${_size.label} logical_px (WindowOptions)');
  ok('⓪b 两处 MediaQuery 读数一致（Δ ≤ 1 px）',
      (mq.width - mqRoot.width).abs() <= 1 && (mq.height - mqRoot.height).abs() <= 1,
      'fromView=${_f2(mq.width)}x${_f2(mq.height)} sizeOf(root)=${_f2(mqRoot.width)}x${_f2(mqRoot.height)}');
  ok('⓪b 视口逻辑宽 = 请求窗口宽（Δ ≤ 1 px）', (mq.width - _size.w).abs() <= 1,
      '实测 ${_f2(mq.width)} vs 请求 ${_size.w}');
  note('视口逻辑高 = ${_f2(mq.height)}（请求 ${_size.h}）—— 仅记录，不判（窗口高度受边框/缩放影响，而分列只看宽）');

  // ── ⓪c 阴性对照（判据纪律 #12）──
  say('');
  say('──────── ⓪c 仪器灵敏度：阳性 / 阴性对照 ────────');
  final nCard0 = findWidgets(root, (w) => w is PosterCard).length;
  final gridEls0 = findWidgets(root, (w) => w is SliverGrid);
  final nNegType = findWidgets(root, (w) => w.runtimeType.toString().contains(_negType)).length;
  final nNegText = findWidgets(root, (w) => w is Text && w.data == _negText).length;
  // ★ 挂页前量到 0 是**正常**的（页面还没挂），所以这里不能写成 ok(>=0) ——
  //   那种断言恒真、永不翻红，是假阳性（判据纪律 #12）。阳性对照在 ② 之后：
  //   同一台 walker 那时必须数到 20 张 PosterCard，数不到就翻红。
  note('挂页前基线（记录用，非断言）：PosterCard=$nCard0 SliverGrid=${gridEls0.length}');
  ok('⓪c 阴性：找类型 $_negType 得 0（证明该 walker 不会凭空报有）', nNegType == 0, 'n=$nNegType');
  ok('⓪c 阴性：找文案 $_negText 得 0', nNegText == 0, 'n=$nNegText');
  note('挂页前的基线：PosterCard=$nCard0 / SliverGrid=${gridEls0.length} ⇒ 「数得到」这件事在挂页后必须变正，否则是空真');

  // ── ① 挂生产浏览页（只替换取数那一步）──
  say('');
  say('──────── ① 挂生产浏览页（注入确定性取数）────────');
  _loaderCalls.clear();
  nav.push(MaterialPageRoute<void>(
    builder: (_) => BrowsePage(
      provider: _provider,
      title: _pageTitle,
      isTv: Device.isTv,
      pageLoaderForTest: _detLoader,
    ),
  ));
  await waitFor(900);

  final pages = findWidgets(root, (w) => w is BrowsePage);
  ok('① 树里恰好有 1 个 BrowsePage', pages.length == 1, '找到 ${pages.length} 个');
  if (pages.length != 1) {
    say('★ BrowsePage 数量不对 ⇒ 无法继续，中止');
    await finish(1);
  }
  final pageEl = pages.first;
  final pageW = pageEl.widget as BrowsePage;
  final st = (pageEl as StatefulElement).state as BrowsePageState;
  ok('① 挂的是**生产** BrowsePage，参数与生产一致（provider=$_provider title=$_pageTitle）',
      pageW.provider == _provider && pageW.title == _pageTitle);
  ok('① 子树里没有 ErrorWidget（release 下抛错会变成它）', !hasErrorWidget(pageEl));
  ok('① 设备不是 TV（TV 走独立分支：--poster-w 216 / gap 20 / 无 1440 上限）', !Device.isTv,
      'Device.isTv=${Device.isTv}');

  // ── ② 等真实网格就位 ──
  say('');
  say('──────── ② 等真实网格（$_perPage 张 PosterCard）────────');
  final gridUp = await waitUntil(
      // debugXxx 是 @visibleForTesting 的只读探针接口，本文件是取证脚本（非 UI）。
      // ignore: invalid_use_of_visible_for_testing_member
      () => findWidgets(root, (w) => w is PosterCard).length >= _perPage && !st.debugLoadingMore,
      timeout: const Duration(seconds: 30),
      label: '$_perPage 张 PosterCard');
  final cards = findWidgets(root, (w) => w is PosterCard);
  // ignore: invalid_use_of_visible_for_testing_member
  note('loader 调用 = $_loaderCalls  debugItemCount=${st.debugItemCount}  debugPage=${st.debugPage}  debugHasMore=${st.debugHasMore}  debugLoadingMore=${st.debugLoadingMore}');
  ok('② 真实网格已就位：PosterCard ≥ $_perPage 且不在 loadingMore', gridUp, 'PosterCard=${cards.length}');
  if (!gridUp) {
    try {
      final s = await shoot('00-no-grid');
      note('失败现场 ${s.path} 颜色数=${s.colors}');
    } catch (e) {
      note('失败现场截图也失败了: $e');
    }
    say('★ 网格没就位 ⇒ 后续无意义，中止');
    await finish(1);
  }
  ok('② 树里恰好 $_perPage 张 PosterCard（pageCount=$_totalPages ⇒ 不会取第 2 页）',
      cards.length == _perPage, '实测 ${cards.length}');
  ok('② 骨架网格不在树上（_SkeletonGrid 有 18 个假格子，量它没意义）',
      findWidgets(root, (w) => w.runtimeType.toString().contains('_SkeletonGrid')).isEmpty);

  final gridRects = <Rect>[];
  for (final e in findWidgets(root, (w) => w is SliverGrid)) {
    final r = globalRect(e);
    if (r != null) gridRects.add(r);
  }
  final pageRect = globalRect(pageEl);
  note('BrowsePage 矩形 = ${pageRect == null ? 'null' : '(${_f2(pageRect.left)},${_f2(pageRect.top)}) ${_f2(pageRect.width)}x${_f2(pageRect.height)}'}');
  for (var i = 0; i < gridRects.length; i++) {
    final r = gridRects[i];
    note('SliverGrid[$i] 矩形 = (${_f2(r.left)},${_f2(r.top)}) ${_f2(r.width)}x${_f2(r.height)}');
  }

  // ── ②b 逐张读真实矩形 ──
  say('');
  say('──────── ②b 真实渲染几何（单位：逻辑像素；全部来自 RenderBox 矩形）────────');
  var badRects = 0;
  final geos = _cardGeos(root, (bad) => badRects = bad);
  ok('②b 每张 PosterCard 都读到了 RenderBox 矩形（globalRect 无 null）',
      badRects == 0 && geos.length == cards.length,
      '读不到 $badRects 张 / 共 ${cards.length} 张；量到 ${geos.length} 张');
  final g = _readGrid(geos);
  say('T493GEO cards=${g.count} rows=${g.rows} cols=${g.cols} rowCounts=${g.rowCounts}');
  for (var i = 0; i < g.rowsOf.length; i++) {
    final r0 = g.rowsOf[i];
    say('T493ROW row=$i n=${r0.length} top=${_f2(r0.first.top)} lefts=[${r0.map((c) => _f2(c.left)).join(', ')}] w=${_f2(r0.first.width)} h=${_f2(r0.first.height)}');
  }
  say('T493GEO cell=${_f2(g.cell)} px  (PosterCard 矩形宽 = 网格列宽，因网格给紧约束)');
  say('T493GEO stride=${_f2(g.stride)} px  (同行相邻卡 left 之差 = 列宽 + 列间距)');
  say('T493GEO gap=${_f2(g.gap)} px  (= stride - cell)');
  say('T493GEO cellH=${_f2(g.cellH)} px');
  say('T493GEO content_left=${_f2(g.minLeft)} px  content_right=${_f2(g.maxRight)} px  content_span=${_f2(g.span)} px (= maxRight - minLeft)');
  say('T493GEO width_spread=${_f2(g.widthSpread)} px  stride_spread=${_f2(g.strideSpread)} px');

  // ── ②c 结构性读数（纯几何事实，⊥ 生产公式）──
  say('');
  say('──────── ②c 结构性读数（⊥ 生产公式；尺子本身对不对）────────');
  ok('②c 行数 ≥ 2', g.rows >= 2, 'rows=${g.rows}');
  ok('②c 列数 ≥ 2', g.cols >= 2, 'cols=${g.cols}');
  // ★ 20 张卡排 12 列 ⇒ 末行必然只有 8 张。'每行卡数相同' 是**错的判据**
  //   （曾在 legacy 车把它判红）。真判据：除末行外必须排满，末行 = 余数。
  final fullRows = g.rowCounts.length <= 1 ? <int>[] : g.rowCounts.sublist(0, g.rowCounts.length - 1);
  ok('②c 除末行外每一行都排满 == cols', fullRows.isEmpty || fullRows.every((n) => n == g.cols), '${g.rowCounts}');
  ok('②c 末行卡数在 1..cols 之间', g.rowCounts.isNotEmpty && g.rowCounts.last >= 1 && g.rowCounts.last <= g.cols, '末行=${g.rowCounts.isEmpty ? 'n/a' : g.rowCounts.last} cols=${g.cols}');
  ok('②c cols == max(rowCounts)', g.cols == g.rowCounts.reduce((a, b) => a > b ? a : b));
  final expectLast = g.count % g.cols == 0 ? g.cols : g.count % g.cols;
  ok('②c 末行卡数 == cards mod cols（余数自洽）', g.rowCounts.isNotEmpty && g.rowCounts.last == expectLast, 'cards=${g.count} cols=${g.cols} 期望末行=$expectLast 实测=${g.rowCounts.isEmpty ? 'n/a' : g.rowCounts.last}');
  ok('②c 每行内 left 严格单增（仪器认得出左右顺序）',
      g.rowsOf.every((r) => _strictlyIncreasing(r.map((c) => c.left).toList())));
  ok('②c 每行内 top 相同（Δ ≤ 0.5 px，仪器认得出同一行）',
      g.rowsOf.every((r) => _spreadOf(r.map((c) => c.top).toList()) <= 0.5));
  ok('②c 所有卡宽度相同（Δ ≤ 0.5 px）', g.widthSpread <= 0.5, 'spread=${_f2(g.widthSpread)}');
  ok('②c 所有行内 stride 相同（Δ ≤ 0.5 px）', g.strideSpread <= 0.5, 'spread=${_f2(g.strideSpread)}');
  ok('②c 列宽 > 0 且行高 > 0', g.cell > 0 && g.cellH > 0, 'cell=${_f2(g.cell)} cellH=${_f2(g.cellH)}');
  ok('②c 列间距 gap ≥ 0（列数>1 时，否则无定义）', g.cols == 1 || g.gap >= -0.01, 'gap=${_f2(g.gap)}');
  ok('②c 相邻卡不重叠（同行 right ≤ 下一张 left + 0.5）',
      g.rowsOf.every((r) {
        for (var i = 1; i < r.length; i++) {
          if (r[i].left < r[i - 1].right - 0.5) return false;
        }
        return true;
      }));

  // ── ②d ⊥ 公式对照（只打印）──
  say('');
  say('──────── ②d ⊥ 生产公式对照（**只打印，不作断言**；判据纪律 #9）────────');
  for (final line in _crossCheck(g, mq.width)) {
    note(line);
  }

  // ── ②e AA 自证 ──
  say('');
  say('──────── ②e AA 自证：同一进程/同一二进制里再量一遍 ────────');
  var bad2 = 0;
  final g2 = _readGrid(_cardGeos(root, (bad) => bad2 = bad));
  final same = g2.count == g.count &&
      g2.rows == g.rows &&
      g2.cols == g.cols &&
      (g2.cell - g.cell).abs() < 1e-9 &&
      (g2.stride - g.stride).abs() < 1e-9 &&
      (g2.gap - g.gap).abs() < 1e-9 &&
      (g2.minLeft - g.minLeft).abs() < 1e-9 &&
      (g2.maxRight - g.maxRight).abs() < 1e-9 &&
      g2.rowCounts.toString() == g.rowCounts.toString();
  ok('②e 两遍读数逐值相同（cards/rows/cols/cell/stride/gap/left/right）', same,
      'again cards=${g2.count} rows=${g2.rows} cols=${g2.cols} cell=${_f2(g2.cell)} stride=${_f2(g2.stride)} gap=${_f2(g2.gap)} left=${_f2(g2.minLeft)} right=${_f2(g2.maxRight)} bad=$bad2');

  // ── ③ 留档截图 + 像素灵敏度 ──
  say('');
  say('──────── ③ 留档截图（仪器退化自检）────────');
  try {
    final s = await shoot('01-${_armLabel()}-${_size.label}');
    ok('③ 截图不是退化图（颜色数 > 8）', s.colors > 8, '${s.path} ${s.w}x${s.h} 颜色数=${s.colors}');
    final bg = s.px(((s.w - 1) / 2).round(), 4);
    var fg = -1;
    if (g.rowsOf.isNotEmpty && g.rowsOf.first.isNotEmpty) {
      final c0 = g.rowsOf.first.first.rect;
      final px = (c0.left + c0.width / 2).round().clamp(0, s.w - 1);
      final py = (c0.top + c0.height * 0.5).round().clamp(0, s.h - 1);
      fg = s.px(px, py);
    }
    say('T493PIX size=${s.w}x${s.h} colors=${s.colors} bg=${_hex(bg)} 第一张卡中心像素=${fg < 0 ? 'n/a' : _hex(fg)}');
    ok('③ 第一张卡的中心像素与页面背景不同（卡片真的被光栅化到屏上）',
        fg >= 0 && fg != bg, 'bg=${_hex(bg)} fg=${fg < 0 ? 'n/a' : _hex(fg)}');
  } catch (e) {
    ok('③ 截图成功', false, '$e');
  }

  // ── 机器可读单行 ──
  say('');
  say('page=browse size=${mq.width.round()}x${mq.height.round()} dpr=${_f2(dprView)} ab=$_arm mode=${_armLabel()} cols=${g.cols} cell=${_f2(g.cell)} gap=${_f2(g.gap)} left=${_f2(g.minLeft)} right=${_f2(g.maxRight)} rows=${g.rows} stride=${_f2(g.stride)} cellH=${_f2(g.cellH)} span=${_f2(g.span)} cards=${g.count}');
  say('rows>=2 = ${g.rows >= 2}   cols>=2 = ${g.cols >= 2}   （rows<2 或 cols<2 ⇒ 本车直接判废）');
  await finish(fail == 0 ? 0 : 1);
}

double _spreadOf(List<double> xs) {
  if (xs.length < 2) return 0;
  return xs.reduce((a, b) => a > b ? a : b) - xs.reduce((a, b) => a < b ? a : b);
}

String _hex(int c) => '#${c.toRadixString(16).padLeft(6, '0').toUpperCase()}';

// ══════════════════════════════════════════════════════════════════════════
// main
// ══════════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Device.init();
  final dir = await _resolveDataDir();
  await UiPrefs.load(dir);
  AppTheme.setMode(AppThemeMode.light);

  String coreError = '';
  try {
    final r = await SourinCore.startAsync(dir);
    say('核心启动 = $r');
  } catch (e) {
    coreError = e.toString();
    say('★ 核心启动失败（不影响布局读数，但必须报出来） = $coreError');
  }

  try {
    await LiquidGlassWidgets.initialize();
  } catch (e) {
    say('玻璃层初始化失败 = $e');
  }

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    final windowOptions = WindowOptions(
      size: Size(_size.w, _size.h),
      minimumSize: const Size(900, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
      title: '源影 - t493 布局取证 (${_armLabel()})',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
    });
    await Future<void>.delayed(const Duration(milliseconds: 900));
  }

  runApp(RepaintBoundary(
    key: _rootKey,
    child: SourinApp(coreError: coreError, coreDataDir: dir),
  ));

  try {
    await _body(dir);
  } catch (e, st) {
    ok('★ 探针异常逃出（必须报出来，不能静默停住）', false, '$e');
    say('$st');
    await finish(1);
  }
}
