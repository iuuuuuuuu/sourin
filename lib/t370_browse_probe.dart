/*
 * t370 —— 浏览页 task-75 两条需求的**真启动**取证
 * ══════════════════════════════════════════════════════════════════════════
 *
 * ── 被验证的需求（Owner 原话）────────────────────────────────────────────
 *   ①「触底加载更多,不要 加载更多  按钮」
 *      —— 滚到底必须**自动**取下一页；「加载更多」按钮必须消失。
 *   ②「返回按钮不要随这页面消失,往下滑固定在上面」
 *      —— 返回键不能随内容滚走，下滑时要**钉在顶部**。
 *
 * ── 被测的生产代码（本探针**一行都不改**）────────────────────────────────
 *   `lib/ui/browse_page.dart`：
 *     · 顶部 `SliverPersistentHeader(pinned: true, delegate: _StickyHeaderBar)`
 *       —— 可折叠：静止 100px，吸住后 68px（多出的 32px 是顶部留白，
 *       随滚动收缩掉）。返回键就在这个 pinned header 里。
 *     · 底部**没有按钮**：`_loadingMore` → 转圈；`_hasMore` → 空；
 *       否则 → `Text('已经到底了')`。
 *     · 自动加载唯一入口 `_maybeLoadMore()`，由 `_onScroll`
 *       （`extentAfter > 600` 就返回）与 `_fillViewportIfNeeded` 驱动。
 *
 * ── 为什么必须真启动 ─────────────────────────────────────────────────────
 *   `flutter test` 里 `sourin_core.dll` 必然加载失败 ⇒ 取数必抛 ⇒ `_items`
 *   恒空 ⇒ 所有断言都退化成对**空树**的断言。而且本仓的铁律是
 *   「交付前必须自跑完整实测：真启动、真滚动、真截图」——
 *   sliver 吸顶、懒构建、像素光栅化这三层只有真窗口才量得到。
 *
 * ── 判据纪律（本仓血泪，逐条对应）────────────────────────────────────────
 *   #9  断言**不抄被测代码的公式**：不写 `top == max(0, rest - off)`。
 *       写的是「每步都在视口内」+「吸住后多次测量彼此相等」。
 *   #10 `find` 只走**已构建**的元素树：滚出视口的 sliver 返回 0 ≠ 不存在。
 *       所以 ⑤ 段把「元素还在不在」当成**读数**如实报告，不当判据。
 *   #11 「检查了不等于闸住了」：闸门必须**被消费**。③ 段在飞行中砸 30 次
 *       触发，数**取数函数真的被调用了几次**；闸门若被摘掉，这个数会变。
 *   #12 每个阴性读数都配一个**同一次运行里已证明灵敏**的仪器：
 *       「找不到『加载更多』」旁边必须站着「找得到『已经到底了』」。
 *   #13 所有读数带单位（px / ms / 次）。
 *   #8  release 下子树抛错会变成 RenderErrorBox，真因只在 stderr
 *       ⇒ runner 必须回读 stderr。
 *
 * ── 仪器自检（⓪ 段）为什么是承重墙 ───────────────────────────────────────
 *   如果挂上来的不是生产 `BrowsePage`（比如被 ErrorWidget 顶掉），
 *   后面每一条「找不到『加载更多』」都会**因为页面根本没渲染**而假绿。
 *   所以 ⓪ 段先证明：壳挂上了、根元素在、树里没有 ErrorWidget、
 *   挂的确实是 `BrowsePage` 且 provider/title 与生产一致、截图非退化。
 *
 * ── 两个臂，各管一件事 ───────────────────────────────────────────────────
 *   · 真源臂（①R）：`BrowsePage(provider:'360')`，**不注入任何东西**，
 *     走真实 FFI 取数 ⇒ 证明生产数据路径活着、真源也能触底翻页。
 *   · 确定臂（①②③④⑤）：注入 `pageLoaderForTest`（构造参数，本仓既有口子，
 *     生产永不传）—— 它**只替换"取数那一次调用"**，代次检查、列表拼接、
 *     视口补取、分页状态、吸顶布局、像素全都是生产代码在跑。
 *     为什么要注入：真源的分页数/每页条数由上游决定，探针无法把
 *     「恰好 5 页」「到底了」这些边界摆出来。注入换来的是**可复现的边界**。
 *   ⚠️ 这是本探针最大的**局限**，在报告里如实声明。
 *
 * ── 仪器纪律 ─────────────────────────────────────────────────────────────
 *   · `exit()` 不展开 finally ⇒ 每条退出路径先 `finish()` 落产物。
 *   · 外壳用**生产本体** `SourinApp`，浏览页走**生产的 Navigator +
 *     生产的 MaterialPageRoute**（与 `shell.dart:3769 _openBrowse` 同一个）。
 *   · 绝不动 Owner 的鼠标：全程程序化，零真实指针事件；
 *     刻意**不**调 `windowManager.focus()`（那会抢 Owner 的焦点）。
 *   · 窗口必须 `show()`，否则引擎可能整帧不产出 ⇒ 退化图 ⇒ 假绿。
 */

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
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';
import 'shell.dart';
import 'ui/app_theme.dart';
import 'ui/browse_page.dart';

// ══════════════════════════════════════════════════════════════════════════
// 常量
// ══════════════════════════════════════════════════════════════════════════

const String _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

/// 与生产 `shell.dart:3769 _openBrowse` 同一个源/标题
const String _provider = '360';
const String _pageTitle = '浏览';

/// 返回键的 tooltip（`browse_page.dart` 里写死的那个）
const String _backTooltip = '返回';

/// 确定臂的分页参数：每页 20 条、共 6 页 ⇒ 120 条。
/// 页数要**算得刚刚好**：init 取第 1 页，① 的两次触底各带出 2/3 页，
/// ③c 的阳性对照取第 4 页，③a 的砸门取第 5 页，① 的收尾触底取第 6 页
/// ⇒ 最后一次触底是**真的**在翻页，而不是在重复已经翻过的页。
const int _perPage = 20;
const int _totalPages = 6;

/// 需求① 要求**不存在**的按钮文字
const String _noBtn = '加载更多';

/// 需求① 的**阳性对照**：同一处底部插槽在"到底了"时渲染的串。
/// 找不到 `_noBtn` 时，必须同时证明"这个仪器找得到该插槽里真的存在的串"。
const String _endMark = '已经到底了';

/// 文本仪器的**阴性对照**：绝不可能存在的串 ⇒ 证明 findText 会返回 null
const String _absentProbe = '这个按钮不存在XYZ';
const String _absentProbe2 = 'LoadMoreXYZ';

/// 条目标题格式（`条目0` / `条目1` …），用于"树里到底看得见第几条"
final RegExp _itemRe = RegExp(r'^条目(\d+)$');

// ══════════════════════════════════════════════════════════════════════════
// 计数 / 日志
// ══════════════════════════════════════════════════════════════════════════

int pass = 0;
int fail = 0;
final List<String> _log = <String>[];
final List<String> _shots = <String>[];

void say(String s) {
  _log.add(s);
  debugPrint('[T370] $s');
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

Future<Never> finish(int code) async {
  say('');
  say('RESULT pass=$pass fail=$fail');
  final f = File('$_outDir\\t370-browse.txt');
  try {
    f.writeAsStringSync('${_log.join('\n')}\n');
  } catch (e) {
    debugPrint('[T370] ★ 产物写入失败: $e');
  }
  debugPrint('[T370] 产物 = ${f.path}  ${f.existsSync() ? f.lengthSync() : -1} B');
  await Future<void>.delayed(const Duration(milliseconds: 250));
  exit(code);
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

Element? findWidget(Element root, bool Function(Widget w) test) {
  final l = findWidgets(root, test);
  return l.isEmpty ? null : l.first;
}

Element? findText(Element root, String text) =>
    findWidget(root, (w) => w is Text && w.data == text);

/// 收集子树里所有 `Text.data`
Set<String> collectTexts(Element root) {
  final out = <String>{};
  void walk(Element e) {
    final w = e.widget;
    if (w is Text && w.data != null) out.add(w.data!);
    e.visitChildren(walk);
  }

  walk(root);
  return out;
}

/// ★ 比 `collectTexts` 更宽的**全通道**文本收集器。
///
/// 为什么必须有它：`collectTexts` 只认 `Text.data`。若某处的文案走
/// `Text.rich` / `RichText` 的 `InlineSpan`、`Tooltip.message`、
/// 或 `Semantics` 的 label，`collectTexts` 就**看不见**它 —— 于是
/// "树里没有『加载更多』" 会退化成 "我的仪器看不见它"，即**空真**
/// （这正是判据纪律 #12 说的：阴性读数必须由已证明灵敏的仪器给出）。
///
/// 本函数把 5 条通道全收进来，并对每条通道单独计数，这样报告里可以
/// 证明"每条通道都真的取到了字"（阳性对照），而不是所有通道一起返回空集。
Set<String> collectAllTexts(Element root, {Map<String, int>? perChannel}) {
  final out = <String>{};
  final ch = perChannel ?? <String, int>{};
  void bump(String k, String? s) {
    if (s == null || s.isEmpty) return;
    out.add(s);
    ch[k] = (ch[k] ?? 0) + 1;
  }

  void walk(Element e) {
    final w = e.widget;
    // 通道 1：Text.data
    if (w is Text) {
      bump('Text.data', w.data);
      // 通道 2：Text.rich 的 InlineSpan
      bump('Text.textSpan', w.textSpan?.toPlainText());
    }
    // 通道 3：裸 RichText（不经过 Text 的那条路）
    if (w is RichText) bump('RichText', w.text.toPlainText());
    // 通道 4：Tooltip / IconButton 的提示语
    if (w is Tooltip) bump('Tooltip', w.message);
    if (w is IconButton) bump('IconButton.tooltip', w.tooltip);
    // 通道 5：Semantics 标签（读屏文案，按钮文案常挂这里）
    if (w is Semantics) {
      bump('Semantics.label', w.properties.label);
      bump('Semantics.value', w.properties.value);
      bump('Semantics.tooltip', w.properties.tooltip);
    }
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
bool hasErrorWidget(Element root) => findWidget(
      root,
      (w) => w.runtimeType.toString().contains('ErrorWidget'),
    ) !=
    null;

/// 元素的**全局矩形**（逻辑像素，与 `toImage(pixelRatio:1.0)` 同一坐标系）
Rect? globalRect(Element? e) {
  if (e == null) return null;
  final ro = e.renderObject;
  if (ro is! RenderBox) return null;
  if (!ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

/// 子树里**已经构建出来**的条目序号集合（`条目N`）
Set<int> itemIndices(Element scope) {
  final out = <int>{};
  for (final t in collectTexts(scope)) {
    final m = _itemRe.firstMatch(t);
    if (m != null) out.add(int.parse(m.group(1)!));
  }
  return out;
}

/// 是不是"按钮类"控件（编译期类型判断，不依赖 runtimeType 字符串）
bool isButton(Widget w) =>
    w is IconButton ||
    w is TextButton ||
    w is ElevatedButton ||
    w is OutlinedButton ||
    w is FilledButton;

// ══════════════════════════════════════════════════════════════════════════
// 帧 / 事件
// ══════════════════════════════════════════════════════════════════════════

/// ★ 必须带 timeout：万一没人请求帧，`endOfFrame` 会一直挂着 ⇒ 静默停住。
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

/// 滚动条 600ms 等待 + 300ms 淡出；光标闪烁也是瞬时叠加层 ⇒ 取像素前先静下来。
Future<void> settleOverlays() async {
  FocusManager.instance.primaryFocus?.unfocus();
  await pumpFrame();
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  await pumpFrame();
}

// ══════════════════════════════════════════════════════════════════════════
// 截图 + 像素
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

  /// 取 (x,y) 的 RGB（丢掉 alpha）
  int px(int x, int y) {
    final o = y * rowBytes + x * 4;
    return (bytes[o] << 16) | (bytes[o + 1] << 8) | bytes[o + 2];
  }
}

String hex(int c) => '#${c.toRadixString(16).padLeft(6, '0').toUpperCase()}';

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
  final path = '$_outDir\\t370-$name.png';
  if (png != null) {
    File(path).writeAsBytesSync(png.buffer.asUint8List());
  }
  _shots.add(path);
  // 仪器自检：退化图（全黑/全白）只有 1~2 种颜色
  final seen = <int>{};
  for (var i = 0; i + 3 < rgba.length; i += 7 * 4) {
    seen.add((rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2]);
  }
  return Shot(path, img.width, img.height, rgba, seen.length);
}

/// 矩形内与 [bg] 不同的像素数（判定"真的被光栅化了"）
int nonBgIn(Shot s, Rect r, int bg) {
  final x0 = r.left.floor().clamp(0, s.w - 1);
  final x1 = r.right.ceil().clamp(0, s.w - 1);
  final y0 = r.top.floor().clamp(0, s.h - 1);
  final y1 = r.bottom.ceil().clamp(0, s.h - 1);
  var n = 0;
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      if (s.px(x, y) != bg) n++;
    }
  }
  return n;
}

/// 矩形内像素的简单校验和（判定"两次截图的这一块逐像素相同"）
int regionSum(Shot s, Rect r) {
  final x0 = r.left.floor().clamp(0, s.w - 1);
  final x1 = r.right.ceil().clamp(0, s.w - 1);
  final y0 = r.top.floor().clamp(0, s.h - 1);
  final y1 = r.bottom.ceil().clamp(0, s.h - 1);
  var h = 17;
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      h = (h * 31 + s.px(x, y)) & 0x3FFFFFFF;
    }
  }
  return h;
}

// ══════════════════════════════════════════════════════════════════════════
// 确定臂的取数函数（**只替换取数那一次调用**）
// ══════════════════════════════════════════════════════════════════════════

final List<int> _loaderCalls = <int>[];
final List<DateTime> _loaderTimes = <DateTime>[];
Duration _loaderDelay = Duration.zero;
int? _loaderPageCount = _totalPages;

Future<models.Page<MediaItem>> _detLoader(int page) async {
  _loaderCalls.add(page);
  _loaderTimes.add(DateTime.now());
  if (_loaderDelay > Duration.zero) {
    await Future<void>.delayed(_loaderDelay);
  }
  return models.Page<MediaItem>(
    items: <MediaItem>[
      for (var i = 0; i < _perPage; i++)
        MediaItem(
          id: 'demo:${(page - 1) * _perPage + i}',
          title: '条目${(page - 1) * _perPage + i}',
        ),
    ],
    page: page,
    pageCount: _loaderPageCount,
  );
}

// ══════════════════════════════════════════════════════════════════════════
//  main
// ══════════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ★ 必须在 runApp 之前（`shell.dart:276` 的同一条）
  MediaKit.ensureInitialized();

  await Device.init();

  final dir = await _resolveDataDir();
  await UiPrefs.load(dir);

  // ★ 强制浅色：只去掉"跑的那一刻系统主题"这个外部变量，
  //   渲染结果与用户配置等价；写的是隔离目录，不碰用户偏好文件。
  AppTheme.setMode(AppThemeMode.light);

  String? coreError;
  try {
    final r = await SourinCore.startAsync(dir);
    say('核心启动 = $r');
  } catch (e) {
    coreError = e.toString();
    say('★ 核心启动失败 = $coreError');
  }

  try {
    await LiquidGlassWidgets.initialize();
    say('LiquidGlassWidgets.initialize 完成');
  } catch (e) {
    note('LiquidGlassWidgets.initialize 失败: $e');
  }

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    /*
     * ★ 窗口选项逐字复刻生产（`lib\shell.dart:309-395`）：
     *   size 1280x800 / minimumSize 900x600 / center /
     *   titleBarStyle: hidden / backgroundColor: transparent。
     *   `titleBarStyle: hidden` 才让自绘标题栏占住顶部 ~39px，
     *   否则 y 坐标全部错位。
     * ⚠️ 刻意不调 `windowManager.focus()`（生产 `shell.dart:399` 有）。
     * ★ 必须 `show()`：窗口不可见时引擎可能整帧不产出 ⇒ 退化图 ⇒ 假绿。
     */
    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(900, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
      title: '源影 · t370 浏览页取证',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
    });
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  // ★ 外壳 = 生产本体（不是复刻）
  runApp(RepaintBoundary(
    key: _rootKey,
    child: SourinApp(coreError: coreError, coreDataDir: dir),
  ));

  try {
    await _body(dir);
  } catch (e, st) {
    // ★ 异常逃出会让探针**静默停住**，外层只看到超时 ⇒ 必须报出来
    ok('★ 探针异常逃出（必须报出来，不能静默停住）', false, '$e');
    say('$st');
    await finish(1);
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  几何读数
// ══════════════════════════════════════════════════════════════════════════

class Geo {
  Geo({
    required this.offset,
    required this.maxExtent,
    required this.backTop,
    required this.backBottom,
    required this.backLeft,
    required this.vpTop,
    required this.vpBottom,
    required this.itemCount,
    required this.visMin,
    required this.visMax,
    required this.visCount,
    required this.item0Top,
    required this.item0Found,
  });

  final double offset;
  final double maxExtent;
  final double backTop;
  final double backBottom;
  final double backLeft;
  final double vpTop;
  final double vpBottom;
  final int itemCount;
  final int visMin;
  final int visMax;
  final int visCount;
  final double item0Top;
  final bool item0Found;

  /// 返回键相对**滚动视口顶**的位置（px）——用户可见的那个量
  double get backTopRel => backTop - vpTop;

  bool get backInside => backTop >= vpTop - 0.5 && backBottom <= vpBottom + 0.5;

  String line() =>
      'offset=${offset.toStringAsFixed(1)}px '
      'max=${maxExtent.toStringAsFixed(1)}px '
      'back.top(绝对)=${backTop.toStringAsFixed(1)}px '
      'back.top(视口内)=${backTopRel.toStringAsFixed(1)}px '
      'back.x=${backLeft.toStringAsFixed(1)}px '
      '视口=[${vpTop.toStringAsFixed(1)},${vpBottom.toStringAsFixed(1)}]px '
      'back在视口内=$backInside '
      '条目数=${itemCount}条 '
      '可见条目=${visMin}..${visMax}(${visCount}条) '
      '条目0.top=${item0Found ? '${item0Top.toStringAsFixed(1)}px' : '未构建'}';
}

// ══════════════════════════════════════════════════════════════════════════
//  主流程
// ══════════════════════════════════════════════════════════════════════════

Future<void> _body(String dir) async {
  debugPrint('[T370] ══════ 浏览页 task-75 两条需求 —— 真启动取证 ══════');

  // ── ⓪ 仪器自检 ────────────────────────────────────────────────────────
  say('');
  say('──────── ⓪ 仪器自检 ────────');

  final exeDir = File(Platform.resolvedExecutable).parent.path;
  note('exe 目录 = $exeDir');

  final shellUp = await waitUntil(
    () => debugShellKey.currentState != null,
    timeout: const Duration(seconds: 40),
    label: 'shell 挂载',
  );
  ok('⓪ shell 已挂载（拿到 debugShellKey.currentState）', shellUp);
  if (!shellUp) {
    say('★ shell 没挂上 ⇒ 后续全部无意义，中止');
    await finish(1);
  }

  final root = _rootKey.currentContext as Element?;
  ok('⓪ 根元素已挂上', root != null);
  if (root == null) {
    say('★ 根元素为 null ⇒ 中止');
    await finish(1);
  }

  ok('⓪ 数据目录是隔离目录（含 .probe，绝不写用户库）',
      dir.toLowerCase().contains('.probe'), dir);
  if (!dir.toLowerCase().contains('.probe')) {
    say('★ 不是隔离目录 ⇒ 立刻中止');
    await finish(1);
  }

  final shellEl = debugShellKey.currentContext;
  if (shellEl == null) {
    say('★ shell context 为 null ⇒ 中止');
    await finish(1);
  }
  // ★ 上面刚判过 null 且为 null 时 finish() 返回 Never（已 exit），
  //   所以走到这里 shellEl 必然非空。lint 看不到 Never 的控制流。
  // ignore: use_build_context_synchronously
  final nav = Navigator.of(shellEl);

  // ── ⓪b FFI 地面真值：这个源到底能不能取到列表 ────────────────────────
  say('');
  say('──────── ⓪b FFI 地面真值（SourinApi.getList("$_provider", "")）────────');
  var ffiTitles = <String>[];
  String? ffiError;
  try {
    final page = await SourinApi.getList(_provider, '');
    ffiTitles = page.items.map((it) => it.title).toList();
    note('FFI 返回 ${page.items.length} 条  page=${page.page}  '
        'pageCount=${page.pageCount}  total=${page.total}');
    if (ffiTitles.isNotEmpty) {
      note('前 3 条 = ${ffiTitles.take(3).join(" / ")}');
    }
  } catch (e) {
    ffiError = e.toString();
  }
  if (ffiError != null) {
    say('★ getList 抛错 = $ffiError');
  }
  ok('⓪b 生产数据层可用（FFI 取到至少 1 条）—— 真源臂的前提',
      ffiTitles.isNotEmpty, 'FFI 条数=${ffiTitles.length}条');

  // ── ①R 真源臂（不注入任何 loader）────────────────────────────────────
  await _realSourceArm(root, nav);

  // ── 确定臂：挂上**生产**的浏览页，只注入取数那一次调用 ────────────────
  say('');
  say('──────── ① 确定臂：挂生产浏览页（只注入取数那一次调用）────────');

  _loaderCalls.clear();
  _loaderTimes.clear();
  _loaderDelay = Duration.zero;
  _loaderPageCount = _totalPages;

  nav.push(MaterialPageRoute<void>(
    builder: (_) => BrowsePage(
      provider: _provider,
      title: _pageTitle,
      isTv: Device.isTv,
      // ★ 本仓既有口子（生产永不传）：只替换 `SourinApi.getList` 那一次调用。
      //   代次检查 / 列表拼接 / 视口补取 / 分页状态 / 吸顶布局全是生产代码。
      pageLoaderForTest: _detLoader,
    ),
  ));
  await waitFor(900);

  final pages = findWidgets(root, (w) => w is BrowsePage);
  ok('① 树里恰好有 1 个 BrowsePage（真源臂已弹出）', pages.length == 1,
      '找到 ${pages.length} 个');
  if (pages.length != 1) {
    say('★ BrowsePage 数量不对 ⇒ 无法继续，中止');
    await finish(1);
  }
  final pageEl = pages.first;
  final pageW = pageEl.widget as BrowsePage;
  final st = (pageEl as StatefulElement).state as BrowsePageState;

  ok('① 挂的是**生产** BrowsePage，参数与生产一致'
      '（provider=${pageW.provider} title=${pageW.title}）',
      pageW.provider == _provider && pageW.title == _pageTitle);
  ok('① 子树里没有 ErrorWidget（release 下抛错会变成它）', !hasErrorWidget(pageEl));

  // 等第 1 页落定
  final p1 = await waitUntil(
    () => st.debugItemCount > 0 && !st.debugLoadingMore,
    timeout: const Duration(seconds: 30),
    label: '第 1 页',
  );
  ok('① 第 1 页已渲染（debugItemCount>0）', p1,
      '条目数=${st.debugItemCount}条  取数调用=${_loaderCalls.length}次');
  if (!p1) {
    final s = await shoot('00-no-page1');
    note('失败现场 ${s.path} 颜色数=${s.colors}');
    say('★ 第 1 页没出来 ⇒ 后续无意义，中止');
    await finish(1);
  }
  note('取数调用序列（此刻）= $_loaderCalls');
  note('元素数 = ${elementCount(root)}');

  final maxE1 = _maxExtent(st);
  note('第 1 页后 maxScrollExtent = '
      '${maxE1 == null ? "无 clients" : "${maxE1.toStringAsFixed(1)}px"}'
      '  extentAfter=${_extentAfter(st)?.toStringAsFixed(1)}px');
  if (maxE1 != null && maxE1 == 0) {
    note('★ maxScrollExtent==0 ⇒ 视口没填满，_fillViewportIfNeeded 会补取'
        '（这也是生产行为，读数照记）');
  }

  await settleOverlays();
  final s0 = await shoot('01-mount');
  note('截图 ${s0.path}  ${s0.w}x${s0.h}  采样颜色数=${s0.colors}');
  ok('⓪ 截图非退化（>20 色）', s0.colors > 20, '颜色数=${s0.colors}');
  note('⓪ 窗口逻辑尺寸 = ${s0.w}x${s0.h}px（pixelRatio=1.0）');

  final vpRect = _viewportRect(pageEl);
  ok('① 找到滚动视口（CustomScrollView 的 Scrollable）', vpRect != null,
      vpRect == null
          ? ''
          : '视口 = [${vpRect.top.toStringAsFixed(1)},'
              '${vpRect.bottom.toStringAsFixed(1)}]px  高 '
              '${vpRect.height.toStringAsFixed(1)}px');
  if (vpRect == null) {
    say('★ 找不到滚动视口 ⇒ 几何断言全部无法做，中止');
    await finish(1);
  }

  final backEl = findWidget(
    pageEl,
    (w) => w is IconButton && w.tooltip == _backTooltip,
  );
  ok('① 找到生产返回键（IconButton.tooltip=="$_backTooltip"）', backEl != null);
  if (backEl == null) {
    say('★ 找不到返回键 ⇒ 需求② 无法验证，中止');
    await finish(1);
  }
  final chevronEl = findWidget(
    backEl,
    (w) => w is Icon && w.icon == Icons.chevron_left,
  );
  ok('① 返回键里确实是 Icons.chevron_left', chevronEl != null);

  // ── ② 需求① 阴性：底部**没有**「加载更多」按钮 ───────────────────────
  say('');
  say('──────── ② 需求① 阴性：底部没有「$_noBtn」按钮 ────────');

  await _bottomSlotAudit(st, pageEl, 'hasMore=true（还没到底）');

  // ── ① 需求① 阳性：滚到底 → 真的多出一页 ──────────────────────────────
  say('');
  say('──────── ① 需求① 阳性：滚到底自动加载下一页 ────────');

  final g0 = _geo(st, pageEl, vpRect, backEl);
  say('  [前] ${g0.line()}');

  final callsBefore1 = _loaderCalls.length;
  await scrollTo(st, double.infinity);
  note('已 jumpTo 到底（offset=${_pixels(st)?.toStringAsFixed(1)}px）');

  final grew2 = await waitUntil(
    () => st.debugItemCount >= _perPage * 2,
    timeout: const Duration(seconds: 20),
    label: '第 2 页自动加载',
  );
  ok('① 只滚动、没点任何按钮 ⇒ 条目数从 ${g0.itemCount} 条涨到 '
      '${st.debugItemCount} 条', grew2, '取数调用新增 ${_loaderCalls.length - callsBefore1} 次');
  ok('① 自动翻页确实是"下一页"（取数序列 = $_loaderCalls，新取的是第 2 页）',
      _loaderCalls.length > callsBefore1 &&
          _loaderCalls.sublist(callsBefore1).contains(2));

  final maxE2 = _maxExtent(st);
  ok('① 内容变多 ⇒ 可滚动范围跟着变大'
      '（${maxE1?.toStringAsFixed(1)}px → ${maxE2?.toStringAsFixed(1)}px）',
      maxE1 != null && maxE2 != null && maxE2 > maxE1);

  // ★ 第二次触底会**立刻**启动第 3 页（extentAfter 归零）。
  //   必须等它落定，否则 ③c 的阳性对照会撞在飞行中 ⇒ 假红。
  await scrollTo(st, double.infinity);
  await waitUntil(
    () => !st.debugLoadingMore && st.debugItemCount >= _perPage * 3,
    timeout: const Duration(seconds: 20),
    label: '第 3 页落定（① 的第二次触底带出来的）',
  );
  await waitFor(300); // 再等一会，确认没有后续自动触发
  final g1 = _geo(st, pageEl, vpRect, backEl);
  say('  [后] ${g1.line()}');
  ok('① 第 2 页的内容真的画到了屏幕上'
      '（树里可见条目最大序号 ${g0.visMax} → ${g1.visMax}，第 2 页从 条目$_perPage 开始）',
      g1.visMax >= _perPage && g1.visMax > g0.visMax);
  ok('① 生产状态里确实拼上了第 2 页（debugItems 含 "条目$_perPage"）',
      st.debugItems.any((it) => it.title == '条目$_perPage'));
  note('此刻 debugPage=${st.debugPage}  条目=${st.debugItemCount}条  '
      '取数序列=$_loaderCalls（第二次触底把第 3 页也带出来了，这是生产行为）');

  // ── ③c 触发器的**阳性对照**：debugLoadMore() 真的能触发一次取数 ───────
  say('');
  say('──────── ③c 触发器阳性对照：debugLoadMore() 能真的触发取数 ────────');
  final pageBefore3 = st.debugPage;
  final before3 = _loaderCalls.length;
  await st.debugLoadMore();
  final fired3 = await waitUntil(
    () => _loaderCalls.length > before3,
    timeout: const Duration(seconds: 10),
    label: 'debugLoadMore 触发',
  );
  final new3 = _loaderCalls.sublist(before3);
  ok('③c 同一次运行里，debugLoadMore() 确实能触发取数'
      '（新增 = $new3，序列 = $_loaderCalls）—— ③a/③b 的"没触发"才有意义',
      fired3 && new3.length == 1 && new3.first == pageBefore3 + 1,
      '新增 ${new3.length} 次，取的是第 ${new3.isEmpty ? "?" : new3.first} 页'
      '（当时 debugPage=$pageBefore3）');
  await waitUntil(() => !st.debugLoadingMore,
      timeout: const Duration(seconds: 15), label: '第 ${pageBefore3 + 1} 页落定');
  await waitFor(300);

  // ── ③a 闸门：飞行中砸 40 次触发，看取数函数被调了几次 ────────────────
  say('');
  say('──────── ③a 闸门（#11）：飞行中重复触发必须被闸住 ────────');

  // ★ 把取数故意拖慢到 3s，好让整个"砸门"窗口**确定地**落在飞行期内。
  _loaderDelay = const Duration(seconds: 3);
  final pageBefore4 = st.debugPage;
  final before4 = _loaderCalls.length;
  await scrollTo(st, double.infinity); // 这一下是真的滚动触发
  await waitFor(60);
  final inFlight = st.debugLoadingMore;
  ok('③a 触底后确实处于"正在取下一页"状态（debugLoadingMore=true）', inFlight);

  final hammerT0 = DateTime.now();
  var hammered = 0;
  for (var i = 0; i < 20; i++) {
    await st.debugLoadMore(); // 直接打闸门入口
    hammered++;
  }
  for (var i = 0; i < 10; i++) {
    // 交替两个都在阈值内的位置：jumpTo 到相同像素**不会**通知监听器，
    // 必须真的改变 pixels 才能触发 `_onScroll`。
    await scrollTo(st, (_maxExtent(st) ?? 0) - 5);
    await scrollTo(st, double.infinity);
    hammered += 2;
  }
  final hammerMs = DateTime.now().difference(hammerT0).inMilliseconds;
  note('飞行中一共砸了 $hammered 次触发'
      '（20 次 debugLoadMore + 20 次触底滚动），耗时 $hammerMs ms');

  final landed4 = await waitUntil(
    () => !st.debugLoadingMore,
    timeout: const Duration(seconds: 25),
    label: '第 ${pageBefore4 + 1} 页落定',
  );
  final newCalls4 = _loaderCalls.sublist(before4);
  ok('③a 砸门窗口确实整个落在飞行期内（耗时 $hammerMs ms < 拖慢后的取数 '
      '3000 ms）—— 否则"砸了没反应"可能只是砸晚了',
      hammerMs < 3000 && landed4, '窗口=${hammerMs}ms  取数耗时=3000ms');
  ok('③a $hammered 次重复触发只换来 **1 次**取数调用（闸门消费了它们）',
      newCalls4.length == 1 && newCalls4.first == pageBefore4 + 1,
      '新增调用数=${newCalls4.length}次  新增=$newCalls4  '
      '（期望恰好第 ${pageBefore4 + 1} 页一次）');
  say('  ⇒ 反事实：若摘掉 `_loadingMore` 闸门，这 $hammered 次触发每次都会走到'
      ' `_load(_page+1)` ⇒ 取数调用数会变成 ${newCalls4.length + hammered} 次。'
      '计数是活的（③c 已证明它会涨），所以这里的"没涨"是真读数。');
  _loaderDelay = Duration.zero;

  // ── ① 再翻一页到「到底了」 ───────────────────────────────────────────
  say('');
  say('──────── ① 收尾触底：翻到最后一页（第 $_totalPages 页）────────');
  final before5 = _loaderCalls.length;
  final pageBefore5 = st.debugPage;
  await scrollTo(st, double.infinity);
  final lastPage = await waitUntil(
    () => !st.debugLoadingMore && st.debugItemCount >= _perPage * _totalPages,
    timeout: const Duration(seconds: 20),
    label: '第 $_totalPages 页',
  );
  final new5 = _loaderCalls.sublist(before5);
  ok('① 最后一次触底又自动取了一页（debugPage $pageBefore5 → ${st.debugPage}，'
      '新增调用 = $new5）', lastPage && new5.length == 1 && new5.first == _totalPages,
      '条目数=${st.debugItemCount}条');
  await scrollTo(st, double.infinity);
  await waitFor(400);
  note('debugPage=${st.debugPage}  debugHasMore=${st.debugHasMore}  '
      'debugItemCount=${st.debugItemCount}条  '
      'maxScrollExtent=${(_maxExtent(st) ?? -1).toStringAsFixed(1)}px');

  ok('③ 取数序列 = $_loaderCalls ⇒ 每页**恰好取一次**，没有重复页、没有跳页'
      '（重复页就是闸门失效的直接指纹）',
      _loaderCalls.length == _loaderCalls.toSet().length &&
          _loaderCalls.length == _totalPages &&
          _loaderCalls.reduce((a, b) => a > b ? a : b) == _totalPages,
      '总调用=${_loaderCalls.length}次  去重后=${_loaderCalls.toSet().length}次  '
      '页数=$_totalPages 页');
  ok('① $_totalPages 页全部到手后 hasMore 归 false（列表真的到头了）',
      !st.debugHasMore, 'debugItemCount=${st.debugItemCount}条');

  // ── ② 需求① 阴性 + 阳性对照（到底了）────────────────────────────────
  say('');
  say('──────── ② 需求① 阴性（到底后）：底部插槽里是什么 ────────');
  await _bottomSlotAudit(st, pageEl, 'hasMore=false（已经到底）');

  // ── ③b 终态闸门：没有下一页了，砸多少次都不该再取数 ──────────────────
  say('');
  say('──────── ③b 终态闸门（#11）：没有下一页时不得再取数 ────────');
  final before6 = _loaderCalls.length;
  for (var i = 0; i < 15; i++) {
    await st.debugLoadMore();
  }
  for (var i = 0; i < 15; i++) {
    await scrollTo(st, (_maxExtent(st) ?? 0) - 5);
    await scrollTo(st, double.infinity);
  }
  await waitFor(700);
  ok('③b debugHasMore=false 时砸 45 次触发 ⇒ 取数调用数不变',
      _loaderCalls.length == before6,
      '调用数 ${before6} → ${_loaderCalls.length}');
  say('  ⇒ 同一个 `debugLoadMore()` 在 ③c 里**确实**触发过取数'
      '（那时 hasMore=true），此刻不触发 ⇒ 闸门是被消费的，不是没接线。');

  // ── ④ 需求② 阳性：返回键全程在视口内、吸住后位置恒定 ────────────────
  say('');
  say('──────── ④ 需求② 阳性：返回键吸顶 ────────');

  final offsets = <double>[0, 16, 32, 48, 120, 600, 1500, 3000, double.infinity];
  final geos = <Geo>[];
  for (final o in offsets) {
    await scrollTo(st, o);
    await waitFor(120);
    final g = _geo(st, pageEl, vpRect, backEl);
    geos.add(g);
    say('  ${g.line()}');
  }

  ok('④ 每一个滚动位置，返回键都在滚动视口**内**（没有任何一步滚走）',
      geos.every((g) => g.backInside),
      '不满足的位置数=${geos.where((g) => !g.backInside).length}个');
  ok('④ 返回键元素在每一个滚动位置都还在树里（pinned 不会被销毁）',
      geos.every((g) => g.backTop.isFinite));

  final stuck = geos.where((g) => g.offset >= 32).toList();
  final tops = stuck.map((g) => g.backTopRel).toList();
  final firstTop = tops.first;
  final allEqual = tops.every((t) => (t - firstTop).abs() < 0.5);
  ok('④ 吸住之后（offset≥32px 的 ${tops.length} 个位置）返回键的视口内高度'
      '**彼此相等**（多个读数相等，不是等于我算出来的数）',
      allEqual && stuck.length >= 5,
      '读数 = ${tops.map((t) => '${t.toStringAsFixed(1)}px').join(" / ")}');

  final restTop = geos.first.backTopRel;
  final rise = restTop - firstTop;
  say('  ⇒ 静止时返回键距视口顶 ${restTop.toStringAsFixed(1)}px，'
      '吸住后 ${firstTop.toStringAsFixed(1)}px，'
      '页头折叠把它抬高了 ${rise.toStringAsFixed(1)}px');
  ok('④ 页头折叠带来的位移是"只往上、且很小"'
      '（0 ≤ ${rise.toStringAsFixed(1)}px ≤ 40px；折叠量本就是 32px）',
      rise >= -0.5 && rise <= 40);
  ok('④ 返回键的**横向**位置全程不变（说明它没有左右漂移）',
      geos.every((g) => (g.backLeft - geos.first.backLeft).abs() < 0.5),
      'x = ${geos.first.backLeft.toStringAsFixed(1)}px');

  // 标题也钉在同一根 header 上
  final titleTops = <double>[];
  for (final o in <double>[0, 32, 600, double.infinity]) {
    await scrollTo(st, o);
    await waitFor(100);
    final r = globalRect(findText(pageEl, _pageTitle));
    if (r != null) titleTops.add(r.top - vpRect.top);
  }
  ok('④ 同一根 header 上的标题也钉住了（≥3 个位置读数相等）',
      titleTops.length >= 3 &&
          titleTops.skip(1).every((t) => (t - titleTops[1]).abs() < 0.5),
      '读数 = ${titleTops.map((t) => '${t.toStringAsFixed(1)}px').join(" / ")}');

  // ── ⑤ 需求② 阴性对照：同一个页面里的普通元素**确实会**滚走 ───────────
  say('');
  say('──────── ⑤ 需求② 阴性对照：非吸顶元素必须真的滚走 ────────');

  final probes = <double>[0, 100, 200];
  final itemTops = <double>[];
  var item0FoundAt0 = false;
  for (final o in probes) {
    await scrollTo(st, o);
    await waitFor(100);
    final el = findText(pageEl, '条目0');
    final r = globalRect(el);
    if (r != null) {
      itemTops.add(r.top);
      if (o == 0) item0FoundAt0 = true;
    }
    say('  offset=${o.toStringAsFixed(0)}px  "条目0".top = '
        '${r == null ? "未构建" : "${r.top.toStringAsFixed(1)}px"}  '
        '视口顶=${vpRect.top.toStringAsFixed(1)}px  '
        '在视口内=${r == null ? "否" : (r.top >= vpRect.top - 0.5 && r.bottom <= vpRect.bottom + 0.5)}');
  }
  ok('⑤ 阴性对照的探针本身有效（offset=0 时找得到 "条目0"）', item0FoundAt0);

  await scrollTo(st, 800);
  await waitFor(150);
  final goneEl = findText(pageEl, '条目0');
  final goneRect = globalRect(goneEl);
  final item0Gone = goneRect == null || goneRect.bottom <= vpRect.top + 0.5;
  say('  offset=800px 时 "条目0" = '
      '${goneRect == null ? "元素已不在树里（滚出缓存区被回收，见 #10）" : "top=${goneRect.top.toStringAsFixed(1)}px（已在视口上方）"}');

  final itemMoved = itemTops.length >= 2 ? itemTops.first - itemTops.last : 0.0;
  ok('⑤ 同一次滚动里，普通元素"条目0"上移了 ${itemMoved.toStringAsFixed(1)}px，'
      '而返回键只动了 ${rise.toStringAsFixed(1)}px ⇒ "它没滚走"不是"什么都没滚"',
      itemMoved > 150 && rise <= 40);
  ok('⑤ offset=800px 时 "条目0" 已经滚出滚动视口', item0Gone);

  // ── ⑥ 像素层：返回键在多个滚动位置都真的被光栅化 ────────────────────
  say('');
  say('──────── ⑥ 像素层：返回键真的画在屏幕上 ────────');

  final shotOffsets = <double>[0, 48, 800, double.infinity];
  final shotNames = <String>['02-off000', '03-off048', '04-off800', '05-offmax'];
  final backSums = <int>[];
  for (var i = 0; i < shotOffsets.length; i++) {
    await scrollTo(st, shotOffsets[i]);
    await settleOverlays();
    final s = await shoot(shotNames[i]);
    final br = globalRect(backEl);
    if (br == null) {
      note('${s.path}: 返回键矩形为 null（异常）');
      continue;
    }
    final cy = br.center.dy.round().clamp(0, s.h - 1);
    // ★ 参照底色取自同一行 x=4：返回键左边就是页头背景（内容左内边距 24）
    final bg = s.px(4, cy);
    final nonBg = nonBgIn(s, br, bg);
    final sum = regionSum(s, br);
    backSums.add(sum);
    note('offset=${(_pixels(st) ?? 0).toStringAsFixed(0)}px  ${s.path}  '
        '颜色数=${s.colors}  返回键矩形='
        '(${br.left.toStringAsFixed(0)},${br.top.toStringAsFixed(0)}) '
        '${br.width.toStringAsFixed(0)}x${br.height.toStringAsFixed(0)}px  '
        '底色=${hex(bg)}  矩形内非底色像素=$nonBg 个  校验和=$sum');
    ok('⑥ offset=${(_pixels(st) ?? 0).toStringAsFixed(0)}px 的截图里'
        '返回键矩形内有非底色像素（真的画出来了）',
        nonBg > 0, '非底色像素=$nonBg 个');
  }
  ok('⑥ 吸住后的两张截图里，返回键那一块**逐像素相同**'
      '（同一位置同一像素，说明它真的没动）',
      backSums.length >= 3 && backSums.skip(1).every((v) => v == backSums[1]),
      '校验和 = ${backSums.join(" / ")}');

  // ── 判词 ──────────────────────────────────────────────────────────────
  say('');
  final verdictCh = <String, int>{};
  final verdictTexts = collectAllTexts(pageEl, perChannel: verdictCh);
  final verdictLoad = verdictTexts.where((t) => t.contains('加载')).toList();
  say('判词: 需求① 无按钮=${verdictLoad.isEmpty}'
      '（全通道查了 ${verdictTexts.length} 个串 / ${verdictCh.length} 条通道）  '
      '触底自动翻页=${_loaderCalls.length}页  '
      '需求② 返回键吸顶=${geos.every((g) => g.backInside)}  '
      'pass=$pass fail=$fail');
  say('截图 ${_shots.length} 张：');
  for (final p in _shots) {
    say('  · $p');
  }
  say('[T370] RESULT pass=$pass fail=$fail calls=$_loaderCalls '
      'rise=${rise.toStringAsFixed(1)}px shots=${_shots.length}');
  await finish(fail == 0 ? 0 : 1);
}

// ══════════════════════════════════════════════════════════════════════════
//  底部插槽审计（需求① 阴性 + 同插槽阳性对照）
// ══════════════════════════════════════════════════════════════════════════

Future<void> _bottomSlotAudit(
  BrowsePageState st,
  Element pageEl,
  String stage,
) async {
  say('  ── $stage ──');
  final texts = collectTexts(pageEl);

  // ★ 全通道收集：Text.data / Text.textSpan / RichText / Tooltip /
  //   IconButton.tooltip / Semantics。只查 Text.data 会让"没有『加载更多』"
  //   退化成"我的仪器看不见它"—— 那是空真，不是证据。
  final perChannel = <String, int>{};
  final wide = collectAllTexts(pageEl, perChannel: perChannel);
  say('  ·  全通道文本收集：命中 ${wide.length} 个不同串，'
      '各通道计数 = ${perChannel.entries.map((e) => "${e.key}:${e.value}").join("  ")}');
  // ★ 每条通道的灵敏度：至少 3 条通道真的取到了字，且 tooltip 通道
  //   必须找到返回键的「返回」—— 证明工具提示这条路是通的。
  ok('② [$stage] 全通道收集器**多条通道都活着**'
      '（活的通道数=${perChannel.length}，其中 tooltip 通道找到「$_backTooltip」='
      '${wide.contains(_backTooltip)}）',
      perChannel.length >= 3 && wide.contains(_backTooltip),
      '通道 = ${perChannel.keys.join(" / ")}');

  // ★ 仪器灵敏度：文本仪器能在这棵子树里找到**已知存在**的串
  final hasTitle = texts.contains(_pageTitle);
  final hasItem = texts.any((t) => _itemRe.hasMatch(t));
  ok('② [$stage] 阳性对照：文本仪器能在这棵子树里找到已知存在的串'
      '（"$_pageTitle"=$hasTitle，条目串=$hasItem）',
      hasTitle && hasItem);
  // ★ 阴性对照：证明"找不到"不是"找什么都返回 true"
  final absent = texts.contains(_absentProbe) ||
      texts.contains(_absentProbe2) ||
      findText(pageEl, _absentProbe) != null;
  ok('② [$stage] 阴性对照：绝不可能存在的串确实找不到（仪器两个方向都灵敏）',
      !absent);

  // ★ 控件仪器灵敏度：子树里确实有按钮控件（返回键），所以下面那句
  //   "没有一个按钮的标签含『加载』"不是空真
  final buttons = findWidgets(pageEl, isButton);
  var labelled = 0;
  var loadish = 0;
  for (final b in buttons) {
    // ★ 按钮标签也用全通道取，否则图标按钮的 tooltip 文案会被漏掉
    final t = collectAllTexts(b);
    if (t.isNotEmpty) labelled++;
    if (t.any((x) => x.contains('加载'))) loadish++;
  }
  ok('② [$stage] 控件仪器灵敏：子树里找到了 ${buttons.length} 个按钮控件'
      '（其中 $labelled 个带文字）⇒ 下面的"零命中"不是空真',
      buttons.isNotEmpty);

  final anyLoadText = wide.where((t) => t.contains('加载')).toList();
  ok('② [$stage] 需求①：整棵浏览页子树里没有任何文本通道含「加载」'
      '（查了 ${wide.length} 个串 / ${perChannel.length} 条通道）',
      anyLoadText.isEmpty, '命中 = ${anyLoadText.isEmpty ? "无" : anyLoadText.join(" / ")}');
  ok('② [$stage] 需求①：没有任何按钮控件的标签含「加载」（查了 $labelled 个带文字的按钮）',
      loadish == 0, '命中=$loadish 个');

  final hasEnd = texts.contains(_endMark);
  say('  ·  $_endMark 在树里 = $hasEnd');
  say('  ·  底部插槽当前渲染 = '
      '${st.debugLoadingMore ? "转圈（_loadingMore）" : st.debugHasMore ? "空（_hasMore）" : _endMark}');
}

// ══════════════════════════════════════════════════════════════════════════
//  真源臂（不注入任何东西，走真实 FFI）
// ══════════════════════════════════════════════════════════════════════════

Future<void> _realSourceArm(Element root, NavigatorState nav) async {
  say('');
  say('──────── ①R 真源臂：生产取数路径（provider=$_provider，零注入）────────');

  nav.push(MaterialPageRoute<void>(
    builder: (_) => BrowsePage(
      provider: _provider,
      title: _pageTitle,
      isTv: Device.isTv,
    ),
  ));
  await waitFor(900);

  final pages = findWidgets(root, (w) => w is BrowsePage);
  if (pages.length != 1) {
    note('★ 真源臂挂载后树里有 ${pages.length} 个 BrowsePage（预期 1 个）');
  }
  if (pages.isEmpty) {
    ok('①R 真源臂挂上了生产 BrowsePage', false);
    return;
  }
  final pageEl = pages.first;
  final st = (pageEl as StatefulElement).state as BrowsePageState;

  final up = await waitUntil(
    () => st.debugItemCount > 0 && !st.debugLoadingMore,
    timeout: const Duration(seconds: 45),
    label: '真源第 1 页',
  );
  final n1 = st.debugItemCount;
  note('真源第 1 页：条目数=$n1条  debugPage=${st.debugPage}  '
      'debugHasMore=${st.debugHasMore}');

  if (!up || n1 == 0) {
    // ★ 这**不是**产品缺陷判据：真源依赖网络与上游接口。
    say('★ 真源没取到条目（网络/上游/FFI 问题）⇒ 真源臂只作读数，不计入判据');
    say('  （确定臂仍然完整验证生产的分页/吸顶逻辑）');
    await _popRealArm(root, nav);
    return;
  }

  final max1 = _maxExtent(st);
  final vp = _viewportRect(pageEl);
  say('  ·  真源 maxScrollExtent=${max1?.toStringAsFixed(1)}px  '
      '视口高=${vp?.height.toStringAsFixed(1)}px  '
      '条目=${n1}条');

  if (!st.debugHasMore) {
    note('★ 真源自报"没有下一页"（pageCount 已被上游给出且已到末页）'
        '⇒ 真源臂不构成对需求① 的检验，只证明列表能渲染');
    ok('①R 真源列表真的渲染到了屏幕上（树里有它的条目文字）',
        findText(pageEl, st.debugItems.first.title) != null,
        '首条="${st.debugItems.first.title}"');
    await _popRealArm(root, nav);
    return;
  }

  ok('①R 真源列表真的渲染到了屏幕上（树里有它的条目文字）',
      findText(pageEl, st.debugItems.first.title) != null,
      '首条="${st.debugItems.first.title}"');

  // 触底：真的滚到最底，看条目数会不会自己涨
  final c = st.debugScrollController;
  if (!c.hasClients) {
    ok('①R 真源滚动控制器已挂上', false);
    await _popRealArm(root, nav);
    return;
  }
  c.jumpTo(c.position.maxScrollExtent);
  await pumpFrame();
  note('真源已 jumpTo 到底，等下一页（最多 40s）');
  final grew = await waitUntil(
    () => st.debugItemCount > n1,
    timeout: const Duration(seconds: 40),
    label: '真源第 2 页',
  );
  ok('①R 真源（零注入）：只滚动、没点按钮 ⇒ 条目数从 $n1 条涨到 '
      '${st.debugItemCount} 条', grew,
      '取数后 debugPage=${st.debugPage} debugHasMore=${st.debugHasMore}');
  if (grew) {
    final max2 = _maxExtent(st);
    ok('①R 真源内容变多 ⇒ 可滚动范围变大'
        '（${max1?.toStringAsFixed(1)}px → ${max2?.toStringAsFixed(1)}px）',
        max1 != null && max2 != null && max2 > max1);
    if (vp != null) {
      // ★ 这里必须把**真的**返回键元素传进去。早先传 null ⇒ 读数行打出
      //   `back.top=NaN`，看起来像"真源臂的返回键没了"，其实是探针没接线
      //   （`Geo` 在元素缺席时填 NaN）。读数行不能自己造出假红。
      final backReal = findWidget(
        pageEl,
        (w) => w is IconButton && w.tooltip == _backTooltip,
      );
      final g = _geo(st, pageEl, vp, backReal);
      say('  [真源后] ${g.line()}');
      // ★ 真源臂的条目是**真标题**（"姐姐快醒醒"…），不是确定臂的「条目N」，
      //   所以 `visMin/visMax` 必然读到 -1 —— 那是命名约定不同，不是缺陷。
      ok('①R 真源臂的返回键此刻也钉在视口内（与确定臂同一根 pinned 页头）',
          g.backInside,
          'back.top(视口内)=${g.backTopRel.toStringAsFixed(1)}px  '
          '视口=[${vp.top.toStringAsFixed(1)},${vp.bottom.toStringAsFixed(1)}]px  '
          '（注：真源条目标题不是「条目N」，故可见条目计数必然为 -1，属命名差异）');
    }
  } else {
    note('★ 真源第 2 页没在 40s 内回来（上游慢/无下一页）'
        '⇒ 真源臂的这一条记为**未验证**，不记为产品缺陷');
  }

  await _popRealArm(root, nav);
}

Future<void> _popRealArm(Element root, NavigatorState nav) async {
  nav.pop();
  await waitUntil(
    () => findWidgets(root, (w) => w is BrowsePage).isEmpty,
    timeout: const Duration(seconds: 10),
    label: '真源臂弹出',
  );
  await waitFor(300);
  note('真源臂已弹出，树里 BrowsePage 数 = '
      '${findWidgets(root, (w) => w is BrowsePage).length}');
}

// ══════════════════════════════════════════════════════════════════════════
//  几何工具
// ══════════════════════════════════════════════════════════════════════════

double? _maxExtent(BrowsePageState st) {
  final c = st.debugScrollController;
  if (!c.hasClients) return null;
  return c.position.maxScrollExtent;
}

double? _pixels(BrowsePageState st) {
  final c = st.debugScrollController;
  if (!c.hasClients) return null;
  return c.position.pixels;
}

double? _extentAfter(BrowsePageState st) {
  final c = st.debugScrollController;
  if (!c.hasClients) return null;
  return c.position.extentAfter;
}

/// 纵向滚动视口（`Scrollable` 的矩形）——返回键"在不在视口里"的参照系
Rect? _viewportRect(Element pageEl) {
  final els = findWidgets(
    pageEl,
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
  );
  if (els.isEmpty) return null;
  return globalRect(els.first);
}

/// ★ 必须自己夹紧：`jumpTo` 走 `forcePixels`，**不做**边界钳制
Future<void> scrollTo(BrowsePageState st, double target) async {
  final c = st.debugScrollController;
  if (!c.hasClients) return;
  final max = c.position.maxScrollExtent;
  final t = target.clamp(0.0, max);
  c.jumpTo(t);
  await pumpFrame();
}

Geo _geo(
  BrowsePageState st,
  Element pageEl,
  Rect vp,
  Element? backEl,
) {
  final br = globalRect(backEl);
  final idx = itemIndices(pageEl);
  final i0 = globalRect(findText(pageEl, '条目0'));
  return Geo(
    offset: _pixels(st) ?? -1,
    maxExtent: _maxExtent(st) ?? -1,
    backTop: br?.top ?? double.nan,
    backBottom: br?.bottom ?? double.nan,
    backLeft: br?.left ?? double.nan,
    vpTop: vp.top,
    vpBottom: vp.bottom,
    itemCount: st.debugItemCount,
    visMin: idx.isEmpty ? -1 : idx.reduce((a, b) => a < b ? a : b),
    visMax: idx.isEmpty ? -1 : idx.reduce((a, b) => a > b ? a : b),
    visCount: idx.length,
    item0Top: i0?.top ?? double.nan,
    item0Found: i0 != null,
  );
}
