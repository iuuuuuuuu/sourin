/*
 * task-76 ③ 真机取证探针 —— JS 插件二级页的「直播源」tab
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Owner 的原话（m04668 ③）：
 *   「js源配置页面加一个直播源,导入js插件,自动更新直播源,或者js插件变更
 *     也自动更新,然后在这个直播源 tab下进行控制,然后这个tab也使用液态玻璃
 *     那个效果实现吧,记住固定在上面,而不是随着整体下滑」
 *
 * 拆准（Lead 已与 Owner 确认）：tab 条在 **JS 插件二级页** 内（不是一级设置页），
 * 要**液态玻璃**、要 **pinned 在顶部**、tab 下要能**控制**直播源，
 * 且「导入 js 插件 ⇒ 直播源列表自动更新」+「js 插件变更 ⇒ 也自动更新」。
 *
 * ── 为什么必须真机取证，不能只靠 flutter test ──────────────────────────────
 *  · `SettingsPage` 在 `flutter test` 里**根本挂不上**：`build()` 走到
 *    `${SourinApi.version}` ⇒ `DynamicLibrary.open('sourin_core.dll')` ⇒
 *    整棵子树被换成 `ErrorWidget`（本仓已记录）。而二级页的 `host` 就是它。
 *  · 液态玻璃要**真实光栅化**才有意义；`flutter test` 里没有真实窗口、
 *    没有 `window_manager`，`GlassContainer` 走的是哪条路径也拿不到。
 *  · 「pinned」是一个**几何**命题（滚过吸顶点后 bar.top 恒为 0），
 *    只能在真窗口里量。
 *
 * ── 判据（四件，每件都必须有对照）────────────────────────────────────────
 *  ① 玻璃 tab 条**真渲染**：截图非退化（>20 色）+ 树里数得到 `GlassContainer`
 *     且它的子树里确实有 `Text('直播源')`（不是数到别处的玻璃）。
 *  ② **真 pinned**：滚过吸顶点后，tab 条矩形 top **逐字不变**，
 *     同时必须有「内容真的滚了」的**阳性对照**（`重新加载` 的 top 上移 > 50px）。
 *     ★ 只有前者没有后者时，「bar.top 不变」在「吸顶生效」与「整页根本滚不动」
 *       两种情况下读数**完全一样** —— 那条断言恒真，等于没测。
 *  ③ 点「直播源」**真切页**：出现 `'还没有支持直播的源'` 或 `'\d+/\d+ 已启用'`。
 *  ④ **导入 js 插件 ⇒ 直播源列表自动更新**：走真实按钮 `粘贴源码安装`
 *     ⇒ `_installPluginSource()` ⇒ `SourinApi.installPluginSource` ⇒ `loadAll()`
 *     ⇒ `_dataRev.value++`。断言块头 chip `直播 N/M` 的 M **= 运行时读到的基线+1**，
 *     且新插件的 `@name` 真的出现在直播 tab 里。
 *     ★ M **绝不写死**：两个种子目录的 live 数不同（`.probe\testdata\plugins\`
 *       有 cctv+iptv 两个；`.probe\t74p-data\plugins\` 只有 cctv 一个）。
 *  ⑤ **js 插件变更 ⇒ 也自动更新**：用同一个 `@id` 再装一次、但把
 *     `capabilities.live` 改成 false ⇒ 该源必须从直播 tab **消失**，chip 回到基线。
 *
 * ── 仪器纪律（本仓血泪）────────────────────────────────────────────────
 *  · `exit()` **不展开 finally** ⇒ 每条退出路径先调 `finish()` 落产物。
 *    否则"跑了但没证据"与"没跑"事后完全无法区分。
 *  · 外壳必须**逐字复刻生产**：`FTheme → FScaffold → Material(transparency)`。
 *    缺 `Material` 层 ⇒ `InkWell` 抛 `Null check operator used on a null value`
 *    ⇒ **整页被换成 ErrorWidget 而不崩给你看**，真因只在 stderr。
 *    本探针直接跑 `SourinApp`（生产外壳本体），所以这条天然满足。
 *  · 截图用 `RepaintBoundary.toImage()`（真进程里可用；`flutter test` 里挂死）。
 *  · 滚动条 / 文本光标都是**瞬时叠加层**（VERIFY-LESSONS #328 / #330）
 *    ⇒ 每次几何/像素取样前先 `settleOverlays()`。
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'core/device.dart';
import 'core/ffi.dart';
import 'core/models.dart';
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';
import 'shell.dart';
import 'ui/widgets/page_transition.dart';
import 'ui/widgets/settings_kit.dart';

// ══════════════════════════════════════════════════════════════════════════
// 常量
// ══════════════════════════════════════════════════════════════════════════

const String _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';
const String _artifact = 't76-live-tab.txt';

/// `settings_page.dart:2928-2936` 的三个常量：
///   `_pluginsTabH = 34` / `Sp.x2 = 8`
///   `_pluginsTabBarExtent = _pluginsTabH + Sp.x2*2 + Sp.x2 = 58.0`（delegate 的 extent）
/// ★ 但**玻璃条本身**只有 `34 + 8*2 = 50` 高 —— delegate 的 Container 是 58，
///   它用 `alignment: centerLeft` 把玻璃条垂直居中 ⇒ 玻璃条 top = 容器顶 + 4。
///   （我第一版把 58 当成玻璃条高度来断言，会得到一个假的 ✗。）
const double kTabH = 34;
const double kPad = 8;
const double kGlassBarH = kTabH + kPad * 2; // 50
const double kBarExtent = kGlassBarH + kPad; // 58

/// 自动滚动条（Flutter desktop 给每个 Scrollable 自动包 Scrollbar）的列区间。
/// 与 `t74_search_sticky_probe.dart` 同一套常量（本机缩略图落在 x=1258..1265）。
const int kScrollbarColRef = 1240;
const int kScrollbarColSample = 1261;
const int kScrollbarColFirst = 1240;
const int kScrollbarColLast = 1276;
const int kScrollbarDarken = 10;

/// 探针自己装的插件（`@id` 只允许字母/数字/-/_，见 `plugins/mod.rs` save_plugin）
const String kProbePluginId = 't76probe';
const String kProbePluginName = '探针直播源';

/// ★ `parse_meta` 只看**开头 2KB**，且取到「下一个 `@` / 换行 / `*/`」就停
///   ⇒ `@id` 与 `@name` **必须各占一行**，不能写在同一行。
const String kSrcLiveOn = r'''
/**
 * @id t76probe
 * @name 探针直播源
 * @version 1.0.0
 * @author task-76
 * @description task-76 探针自动安装的插件（声明直播能力）
 */
globalThis.plugin = {
  id: 't76probe',
  capabilities: { vod: false, live: true },
  async liveChannels() { return []; },
  async liveStream(channelId) { return []; },
};
''';

/// 同一个 `@id`、版本 +1、把 `live` 关掉 —— 验证「插件变更也自动更新」
const String kSrcLiveOff = r'''
/**
 * @id t76probe
 * @name 探针直播源
 * @version 1.0.1
 * @author task-76
 * @description task-76 探针把直播能力去掉（验证「插件变更也自动更新」）
 */
globalThis.plugin = {
  id: 't76probe',
  capabilities: { vod: false, live: false },
  async liveChannels() { return []; },
  async liveStream(channelId) { return []; },
};
''';

// ══════════════════════════════════════════════════════════════════════════
// 计数 / 日志
// ══════════════════════════════════════════════════════════════════════════

int pass = 0;
int fail = 0;
final List<String> _log = <String>[];

void say(String s) {
  _log.add(s);
  debugPrint('[T76] $s');
}

void note(String s) => say('·  $s');

void ok(String line, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
  } else {
    fail++;
  }
  final mark = cond ? '✓' : '✗';
  say('$mark $line${extra.isEmpty ? '' : '   $extra'}');
}

/// ★ `exit()` 不展开 `finally`（它直接终止进程）⇒ 每一条退出路径都必须先调用
///   本函数。否则中途中止的那一次会**不留产物**，于是"跑了但没证据"
///   —— 与"没跑"在事后完全无法区分。
Future<Never> finish(int code) async {
  final f = File('$_outDir\\$_artifact');
  try {
    f.writeAsStringSync('${_log.join('\n')}\n');
  } catch (e) {
    debugPrint('[T76] ★ 产物写入失败: $e');
  }
  debugPrint('[T76] 产物 = ${f.path}  ${f.existsSync() ? f.lengthSync() : -1} B');
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
// 元素树工具
// ══════════════════════════════════════════════════════════════════════════

Element? findWidget(Element root, bool Function(Widget w) test) {
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

List<Element> findAllWidgets(Element root, bool Function(Widget w) test) {
  final out = <Element>[];
  void walk(Element e) {
    if (test(e.widget)) out.add(e);
    e.visitChildren(walk);
  }

  walk(root);
  return out;
}

Element? findText(Element root, String text) =>
    findWidget(root, (w) => w is Text && w.data == text);

/// 找文本能匹配正则的元素（用于 `直播 N/M` 与 `N/M 已启用` 这类动态文案）
Element? findTextMatching(Element root, RegExp re) =>
    findWidget(root, (w) => w is Text && w.data != null && re.hasMatch(w.data!));

bool subtreeHasText(Element e, String text) => findText(e, text) != null;

/// 玻璃条所在的**整条吸顶带**（delegate 的 Container，高 58）。
///
/// ★ 容器高 58、玻璃条高 50 ⇒ 玻璃条在容器里**垂直居中**，上下各留 4px
///   （= `kPad / 2`）。第一版写成 `bar.top - kPad`（8px），于是这条带的
///   y 范围整体偏了 4px：上沿多算了 4px 内容区、下沿少了 4px 背衬 ——
///   逐字节比对会因此把**内容区**的差异算进「条内」。
Rect bandOf(Rect bar) =>
    Rect.fromLTRB(0, bar.top - kPad / 2, 1, bar.bottom + kPad / 2);

/// 吸顶带里**玻璃条之外**的部分（左右两侧 + 上下各 4px 背衬）。
/// 这部分由 delegate 的不透明 `background` 铺满 ⇒ 滚内容时**必须逐字节不变**。
List<Rect> backingOf(Rect glass, double imageWidth) {
  final band = bandOf(glass);
  return <Rect>[
    // 玻璃条上方 4px 背衬（整幅宽）
    Rect.fromLTRB(0, band.top, imageWidth, glass.top),
    // 玻璃条下方 4px 背衬（整幅宽）
    Rect.fromLTRB(0, glass.bottom, imageWidth, band.bottom),
    // 玻璃条左侧背衬
    Rect.fromLTRB(0, glass.top, glass.left, glass.bottom),
    // 玻璃条右侧背衬
    Rect.fromLTRB(glass.right, glass.top, imageWidth, glass.bottom),
  ];
}

/// 找 `SettingsEntryRow`（一级设置页的入口行）。用它而不是按文本找 ——
/// 二级页 push 上来之后 `Text('JS 插件')` 在树里**有两个**
/// （宿主入口行 + 二级页页头），按文本找会歧义。
Element? findEntryRow(Element root, String title) =>
    findWidget(root, (w) => w is SettingsEntryRow && w.title == title);

/// 找包含 `Text('直播源')` 的那个 `GlassContainer` —— 即液态玻璃 tab 条。
/// ★ 不能只数 `GlassContainer`：shell 的标题栏（`shell.dart:3997`）与底部
///   药丸条（`shell.dart:4742`）**也是** GlassContainer，恒在树里。
Element? _findGlassBarContaining(Element root, String text) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    if (e.widget is GlassContainer && findText(e, text) != null) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

Rect? rectOf(Element? e) {
  if (e == null) return null;
  final ro = e.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

double? topOf(Element? e) => rectOf(e)?.top;

/// 从某个元素向上找最近的 `ScrollableState`（sliver 的祖先里就有）
ScrollableState? scrollableOf(Element? e) {
  ScrollableState? found;
  e?.visitAncestorElements((a) {
    if (a is StatefulElement && a.state is ScrollableState) {
      found = a.state as ScrollableState;
      return false;
    }
    return true;
  });
  return found;
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

// ══════════════════════════════════════════════════════════════════════════
// 帧 / 事件注入
// ══════════════════════════════════════════════════════════════════════════

/// ★ 必须带 timeout：万一没人请求帧，`endOfFrame` 会一直挂着 ⇒ 探针静默停住。
Future<void> pumpFrame() async {
  SchedulerBinding.instance.scheduleFrame();
  await SchedulerBinding.instance.endOfFrame
      .timeout(const Duration(seconds: 2), onTimeout: () {});
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

/// ★ 两次事件之间必须让出事件循环 —— 同一个 microtask 里连发 down/up
///   会**漏掉 up**（`delivery_test.dart:1671-1677`）。
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

/// `onTap` 要等过 `kDoubleTapTimeout`(300ms) 才派发 ⇒ 多等 700ms。
Future<void> tapAndSettle(Offset globalPos) async {
  await tapAt(globalPos);
  await Future<void>.delayed(const Duration(milliseconds: 700));
  await pumpFrame();
}

/// ★ `PointerScrollEvent` 的构造器**不透传 `pointer:`**（写了就是
///   `undefined_named_parameter`）。
void injectScroll(Offset at, double dy) {
  WidgetsBinding.instance.handlePointerEvent(PointerScrollEvent(
    position: at,
    scrollDelta: Offset(0, dy),
    kind: PointerDeviceKind.mouse,
  ));
}

/// 滚动条 600ms 等待 + 300ms 淡出；文本光标闪烁也是瞬时叠加层
/// （VERIFY-LESSONS #328 / #330）⇒ 取像素/几何前先让它静下来。
Future<void> settleOverlays() async {
  FocusManager.instance.primaryFocus?.unfocus();
  await pumpFrame();
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  await pumpFrame();
}

// ══════════════════════════════════════════════════════════════════════════
// 截图 + 指纹
// ══════════════════════════════════════════════════════════════════════════

final GlobalKey _rootKey = GlobalKey();

String fnv(List<int> bytes, int start, int end) {
  var h = 0x811c9dc5;
  final s = start.clamp(0, bytes.length);
  final e = end.clamp(s, bytes.length);
  for (var i = s; i < e; i++) {
    h = (h ^ bytes[i]) & 0xFFFFFFFF;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0').toUpperCase();
}

/// 数「自动滚动条滑块」的行数：同一行里 sample 列比 ref 列**三个通道同时暗**
/// ≥ 阈值。★ 用「变暗」而不是「不等」—— 按钮边缘那类 ±2 噪声是**变亮**的，
/// 第一版用「不等」被骗出 50 行常量假阳性（VERIFY-LESSONS #329）。
int scrollbarRows(List<int> bytes, int rowBytes, int y0, int y1) {
  final refOff = kScrollbarColRef * 4;
  final smpOff = kScrollbarColSample * 4;
  var rows = 0;
  for (var y = y0; y < y1; y++) {
    final base = y * rowBytes;
    if (base + smpOff + 3 >= bytes.length) break;
    final dr = bytes[base + refOff] - bytes[base + smpOff];
    final dg = bytes[base + refOff + 1] - bytes[base + smpOff + 1];
    final db = bytes[base + refOff + 2] - bytes[base + smpOff + 2];
    if (dr >= kScrollbarDarken && dg >= kScrollbarDarken && db >= kScrollbarDarken) {
      rows++;
    }
  }
  return rows;
}

/// 一次截图的全部读数。
///
/// ★ 用类而不是位置元组：本轮判据要按**区域**逐像素比对，元组会膨胀到 8 个
///   位置字段（`$6`/`$7` 写反是静默错误）。改名成字段后 `dart analyze` 会把
///   每一处漏改报成 error —— 免费的正确性检查（VERIFY-LESSONS #331）。
class Shot {
  Shot({
    required this.path,
    required this.colors,
    required this.stripHash,
    required this.allHash,
    required this.scrollbarRows,
    required this.bytes,
    required this.w,
    required this.h,
  });

  final String path;

  /// 采样颜色数（仪器自检：退化图只有 1~2 色）
  final int colors;

  /// `strip` 区域的指纹（未给 strip 时 = 全图）
  final String stripHash;

  /// 全图指纹
  final String allHash;

  /// `strip` 区域内的自动滚动条滑块行数
  final int scrollbarRows;

  /// 原始 RGBA（供逐像素比对）
  final Uint8List bytes;
  final int w;
  final int h;
}

/// 逐像素比对一个**全局矩形**区域，返回 (差异像素数, 单通道最大差值)。
///
/// 4 个通道全比（含 alpha）⇒ `n == 0` 就是字面意义上的「逐字节不变」。
/// ★ 只报读数、不在这里下结论：同一个差异数在「玻璃折射」与「背衬漏内容」
///   两种假设下含义相反，判决必须结合**区域位置**（VERIFY-LESSONS #336）。
({int n, int maxDelta}) diffRegion(Shot a, Shot b, Rect r) {
  if (a.w != b.w || a.h != b.h) {
    throw StateError('diffRegion: 尺寸不同 ${a.w}x${a.h} vs ${b.w}x${b.h}');
  }
  final x0 = r.left.round().clamp(0, a.w);
  final x1 = r.right.round().clamp(x0, a.w);
  final y0 = r.top.round().clamp(0, a.h);
  final y1 = r.bottom.round().clamp(y0, a.h);
  var n = 0;
  var maxDelta = 0;
  for (var y = y0; y < y1; y++) {
    var i = (y * a.w + x0) * 4;
    for (var x = x0; x < x1; x++, i += 4) {
      final dr = (a.bytes[i] - b.bytes[i]).abs();
      final dg = (a.bytes[i + 1] - b.bytes[i + 1]).abs();
      final db = (a.bytes[i + 2] - b.bytes[i + 2]).abs();
      final da = (a.bytes[i + 3] - b.bytes[i + 3]).abs();
      var d = dr > dg ? dr : dg;
      if (db > d) d = db;
      if (da > d) d = da;
      if (d != 0) n++;
      if (d > maxDelta) maxDelta = d;
    }
  }
  return (n: n, maxDelta: maxDelta);
}

/// 数一个区域内出现的不同颜色数（RGB，忽略 alpha）。
///
/// 用来区分「不透明实心背衬」与「能看见背后内容」：前者只有 1 种颜色，
/// 后者多色。它同时是判据 (a) 的**敏感性证明** —— 「零差异」既可能是
/// 「背衬挡住了内容」，也可能是「这块区域根本没画东西」，两者靠单色性区分
/// （VERIFY-LESSONS #327：零结果必须配已证明敏感的仪器）。
int distinctColours(Shot s, Rect r) {
  final x0 = r.left.round().clamp(0, s.w);
  final x1 = r.right.round().clamp(x0, s.w);
  final y0 = r.top.round().clamp(0, s.h);
  final y1 = r.bottom.round().clamp(y0, s.h);
  final seen = <int>{};
  for (var y = y0; y < y1; y++) {
    var i = (y * s.w + x0) * 4;
    for (var x = x0; x < x1; x++, i += 4) {
      seen.add(s.bytes[i] << 16 | s.bytes[i + 1] << 8 | s.bytes[i + 2]);
    }
  }
  return seen.length;
}

/// 截图。`strip` = 要单独打指纹的**全局矩形**（tab 条本体）。
Future<Shot> shoot(String name, {Rect? strip}) async {
  final ctx = _rootKey.currentContext;
  if (ctx == null) throw StateError('shoot($name): 根元素没挂上');
  final ro = ctx.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    throw StateError('shoot($name): 根不是 RenderRepaintBoundary，而是 ${ro.runtimeType}');
  }
  final img = await ro.toImage(pixelRatio: 1.0);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  final path = '$_outDir\\t76-$name.png';
  File(path).writeAsBytesSync(png!.buffer.asUint8List());

  final raw = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = raw!.buffer.asUint8List();
  final w = img.width;
  final h = img.height;
  final rowBytes = w * 4;

  // 仪器自检：退化图只 1~2 色
  final seen = <int>{};
  for (var i = 0; i + 3 < bytes.length; i += 4 * 7) {
    seen.add(bytes[i] << 16 | bytes[i + 1] << 8 | bytes[i + 2]);
  }

  final y0 = (strip?.top ?? 0).round().clamp(0, h);
  final y1 = (strip?.bottom ?? h.toDouble()).round().clamp(y0, h);
  final stripHash = fnv(bytes, y0 * rowBytes, y1 * rowBytes);
  final allHash = fnv(bytes, 0, bytes.length);
  final sb = scrollbarRows(bytes, rowBytes, y0, y1);
  img.dispose();
  return Shot(
    path: path,
    colors: seen.length,
    stripHash: stripHash,
    allHash: allHash,
    scrollbarRows: sb,
    bytes: bytes,
    w: w,
    h: h,
  );
}

// ══════════════════════════════════════════════════════════════════════════
// main
// ══════════════════════════════════════════════════════════════════════════

Future<void> main() async {
  final t0 = DateTime.now();

  WidgetsFlutterBinding.ensureInitialized();

  say('══════ task-76 ③ 真机取证：「直播源」tab ══════');
  say('可执行文件 = ${Platform.resolvedExecutable}');
  say('工作目录   = ${Directory.current.path}');

  try {
    MediaKit.ensureInitialized();
    say('media_kit 已初始化');
  } catch (e) {
    final dll = File('${Directory.current.path}\\libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
      say('media_kit 已用工作目录 libmpv-2.dll 初始化');
    } else {
      say('★ media_kit 初始化失败且找不到 libmpv-2.dll（不致命，本探针不播视频）: $e');
    }
  }

  try {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.setTitle('task-76 ③ 直播源 tab 真机取证');
  } catch (e) {
    note('窗口设置失败（不致命）: $e');
  }

  try {
    await Device.init();
    say('Device.init 完成  kind=${Device.kind}');
  } catch (e) {
    note('Device.init 失败（沿用默认）: $e');
  }

  final dir = await _resolveDataDir();
  say('数据目录 = $dir');
  await UiPrefs.load(dir);
  PageTransitionStyleStore.syncFromPrefs();

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

  runApp(RepaintBoundary(
    key: _rootKey,
    child: SourinApp(coreError: coreError, coreDataDir: dir),
  ));

  try {
    await _body(dir, t0);
  } catch (e, st) {
    // ★ 异常逃出会让探针**静默停住**，外层只看到超时 ⇒ 必须报出来
    ok('★ 探针异常逃出（必须报出来，不能静默停住）', false, '$e');
    say('$st');
    await finish(1);
  }
}

Future<void> _body(String dir, DateTime t0) async {
  // ── ⓪ 仪器自检 ────────────────────────────────────────────────────────
  say('');
  say('──────── ⓪ 仪器自检 ────────');

  final shellUp = await waitUntil(
    () => debugShellKey.currentState != null,
    timeout: const Duration(seconds: 40),
    label: 'shell 挂载',
  );
  ok('⓪ shell 已挂载（拿到 debugShellKey.currentState）', shellUp);
  if (!shellUp) {
    say('★ shell 没挂上 ⇒ 后续全部无意义，中止');
    say('[T76] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  final root0 = _rootKey.currentContext as Element?;
  ok('⓪ 根元素已挂上', root0 != null);
  if (root0 == null) {
    say('★ 根元素为 null ⇒ 中止');
    say('[T76] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  ok('⓪ 数据目录是隔离目录（含 .probe，绝不写用户库）',
      dir.toLowerCase().contains('.probe'), dir);
  if (!dir.toLowerCase().contains('.probe')) {
    say('★ 不是隔离目录 ⇒ 立刻中止（本探针会**真的装插件**）');
    await finish(1);
  }

  // 切到设置页
  final dynamic shell = debugShellKey.currentState;
  shell.debugSwitchTo(AppTab.settings);
  await Future<void>.delayed(const Duration(milliseconds: 800));
  await pumpFrame();

  final entryUp = await waitUntil(
    () => findEntryRow(root0, 'JS 插件') != null,
    timeout: const Duration(seconds: 40),
    label: '一级页「JS 插件」入口行',
  );
  ok('⓪ 一级设置页已渲染（找得到 SettingsEntryRow「JS 插件」）', entryUp);
  if (!entryUp) {
    final shot = await shoot('00-instrument-failure');
    note('失败现场截图 ${shot.path}  采样颜色数=${shot.colors}');
    say('★ 一级页没渲染 ⇒ 中止');
    say('[T76] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  final entry0 = findEntryRow(root0, 'JS 插件')!;
  final subtitle0 = (entry0.widget as SettingsEntryRow).subtitle;
  note('入口行副标题 = 「$subtitle0」');
  final nProv0 = _firstInt(subtitle0);
  ok('⓪ 入口行副标题里有内容源数量（阳性对照：读得到才有得比）',
      nProv0 != null, 'subtitle=$subtitle0');

  note('挂载时元素数 = ${elementCount(root0)}');
  {
    final shot = await shoot('00-mount');
    note('挂载截图 ${shot.path}  采样颜色数=${shot.colors}');
    ok('⓪ 挂载截图非退化（>20 色）', shot.colors > 20, '颜色数=${shot.colors}');
  }

  // 核心侧独立读数（与 UI 侧互为交叉验证）
  List<ProviderManifest> provs = const [];
  try {
    provs = await SourinApi.listProviders();
  } catch (e) {
    note('SourinApi.listProviders 失败: $e');
  }
  final liveCore = provs.where((p) => p.capabilities.live).toList();
  note('核心侧 listProviders = ${provs.length} 个源，其中 capabilities.live = ${liveCore.length}');
  note('核心侧 live 源 = ${liveCore.map((p) => '${p.id}(${p.name})').join(', ')}');

  // ── ① 打开二级页 + 玻璃 tab 条 ────────────────────────────────────────
  say('');
  say('──────── ① 打开 JS 插件二级页 ────────');

  final entryRect = rectOf(entry0);
  ok('① 入口行有几何（可点）', entryRect != null,
      entryRect == null ? '' : 'rect=$entryRect');
  if (entryRect == null) {
    say('★ 入口行没有几何 ⇒ 中止');
    await finish(1);
  }
  await tapAndSettle(entryRect!.center);

  final subUp = await waitUntil(
    () => findText(root0, '直播源') != null,
    timeout: const Duration(seconds: 20),
    label: '二级页 tab 条「直播源」',
  );
  ok('① 二级页已打开（树里出现了 tab 条上的 Text(\'直播源\')）', subUp,
      '★ 该文案只由 _PluginsTabBar 的 enum label 渲染，一级页没有它');
  if (!subUp) {
    final shot = await shoot('01-subpage-failure');
    note('失败现场截图 ${shot.path}  采样颜色数=${shot.colors}');
    say('★ 二级页没打开 ⇒ 中止');
    say('[T76] RESULT verdict=SUBPAGE-NOT-OPEN pass=$pass fail=$fail');
    await finish(1);
  }

  await settleOverlays();

  final barEl = _findGlassBarContaining(root0, '直播源');
  ok('① tab 条是**液态玻璃**（找到包含 Text(\'直播源\') 的 GlassContainer）',
      barEl != null,
      '★ 只数 GlassContainer 不算 —— shell 标题栏/底部药丸条也是玻璃，恒在树里');
  if (barEl == null) {
    say('★ 没有玻璃 tab 条 ⇒ 中止');
    await finish(1);
  }

  final glassTotal = findAllWidgets(root0, (w) => w is GlassContainer).length;
  note('全树 GlassContainer 数 = $glassTotal（含 shell 标题栏 + 底部药丸条）');

  final barRectA = rectOf(barEl);
  ok('① tab 条有几何', barRectA != null, barRectA == null ? '' : 'rect=$barRectA');
  if (barRectA == null) {
    say('★ tab 条没有几何 ⇒ 中止');
    await finish(1);
  }
  // ★ 断言目标是**玻璃条本身**（50），不是 delegate 的 Container（58）。
  //   第一版拿 58 去比 ⇒ 实测 50.0 ⇒ 一个假的 ✗（VERIFY-LESSONS #332）。
  note('tab 条几何 = $barRectA   玻璃条高=${barRectA!.height}（期望 $kGlassBarH）');
  ok('① 玻璃 tab 条高度 = $_glassBarHStr（= tabH $kTabH + 上下 padding 各 $kPad）',
      (barRectA.height - kGlassBarH).abs() < 0.5,
      '实测=${barRectA.height}');

  final shotA = await shoot('01-rest', strip: barRectA);
  note('静止态截图 ${shotA.path}  采样颜色数=${shotA.colors}  strip=${shotA.stripHash}  '
      '滑块行数=${shotA.scrollbarRows}');
  ok('① 截图非退化（>20 色）', shotA.colors > 20, '颜色数=${shotA.colors}');
  ok('① 截图里没有自动滚动条滑块（逐字节比对的前提）', shotA.scrollbarRows == 0,
      '滑块行数=${shotA.scrollbarRows}');

  // ── ② pinned 验证 ─────────────────────────────────────────────────────
  say('');
  say('──────── ② 「固定在上面，而不是随着整体下滑」 ────────');

  final scrollEl = findWidget(root0, (w) => w is CustomScrollView);
  final scroll = scrollableOf(barEl) ?? scrollableOf(scrollEl);
  ok('② 拿到二级页的 ScrollableState', scroll != null);
  if (scroll == null) {
    say('★ 拿不到 Scrollable ⇒ 无法验证 pinned，中止');
    await finish(1);
  }
  final pos = scroll!.position;
  note('滚动位置 maxScrollExtent=${pos.maxScrollExtent}  pixels=${pos.pixels}');
  ok('② 内容足够长（maxScrollExtent > 300，否则「吸顶」无从谈起）',
      pos.maxScrollExtent > 300, 'maxScrollExtent=${pos.maxScrollExtent}');

  // 阳性对照：内容区里一个确定会随滚动移动的文本
  final ctrlEl = findText(root0, '重新加载');
  ok('② 阳性对照元素存在（内容区的 Text(\'重新加载\')）', ctrlEl != null);
  final ctrlTopA = topOf(ctrlEl);

  // ★★ 注入点必须取**滚动容器自己的 RenderBox 中心**，不是祖先 CustomScrollView
  //    的矩形中心（照 `t74_perf_probe.dart:1256-1261` 的已验证配方）。
  //    第一版用 `rectOf(scrollEl).center` 且 dy = **-120**：探针从 pixels=0 开始，
  //    负 delta 是「继续往上滚」⇒ 被 clamp 成 0 ⇒ pixels 恒 0、帧逐字节不变
  //    ⇒ 下面那两条「top 不变 / strip 不变」变成**空洞通过**（VERIFY-LESSONS #334）。
  final scrollRb = scroll.context.findRenderObject();
  if (scrollRb is! RenderBox) {
    say('★ 滚动容器没有 RenderBox ⇒ 无法定位注入点，中止');
    await finish(1);
  }
  final injectAt = scrollRb.localToGlobal(scrollRb.size.center(Offset.zero));
  note('注入点（滚动容器自身中心）= $injectAt  容器尺寸=${scrollRb.size}');

  // 真手势滚（不是 jumpTo）—— 这样「内容真的滚了」本身也是被证明的。
  // ★ delta 取正 = 向下滚（内容上移）；循环里**不** pumpFrame，照已验证配方。
  for (var i = 0; i < 8; i++) {
    injectScroll(injectAt, 120);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  await Future<void>.delayed(const Duration(milliseconds: 600));
  await settleOverlays();

  final pixelsB = pos.pixels;
  final barRectB = rectOf(barEl);
  final ctrlTopB = topOf(ctrlEl);
  final shotB = await shoot('02-scrolled', strip: barRectB);

  note('滚后 pixels=$pixelsB  条.top=${barRectB?.top}  对照.top=${ctrlTopB ?? ctrlTopA}');
  ok('② ★阳性对照：内容真的滚了（对照元素上移 > 50px）',
      ctrlTopA != null && ctrlTopB != null && (ctrlTopA - ctrlTopB) > 50,
      '上移=${ctrlTopA == null || ctrlTopB == null ? 'n/a' : (ctrlTopA - ctrlTopB).toStringAsFixed(1)}px');
  ok('② 滚动位置真的前进了（position.pixels 增大 > 300）',
      pixelsB > 300, 'pixels=$pixelsB');

  ok('② ★★待证命题：滚过吸顶点后 tab 条 top **逐字不变**',
      barRectA.top == barRectB?.top,
      '静止=${barRectA.top} 滚后=${barRectB?.top}');
  ok('② tab 条矩形逐字不变（top 与高度同时比对）',
      barRectB != null &&
          barRectA.top == barRectB.top &&
          (barRectA.height - barRectB.height).abs() < 0.001,
      '静止=$barRectA 滚后=$barRectB');
  // ★★★ 判据重设计（VERIFY-LESSONS #336）
  //
  // 第一版要求「整条吸顶带逐字节不变」—— 它**必然失败**，因为液态玻璃是
  // 半透明的：滚动时玻璃会把背后的内容折射进来，那正是玻璃该有的行为。
  //
  // 实测定位（`.probe\t76_edge_probe.py`，逐像素）：
  //   · 条内差异 102 px，**100% 落在玻璃条自己的列区间内**（x=86..214 ⊂ 24..232）
  //     且只在玻璃最底 2 行（y=228/229）⇒ 没有任何差异溢出玻璃；
  //   · 玻璃背后的**原始内容**位移最大 **240/255**，而玻璃透出来的差值最大只有
  //     **6/255**（≈40× 衰减）⇒ 这是折射，不是「内容漏进条里」。
  //
  // 所以拆成两条**互不重叠**的判据，各自都能被证伪：
  //   (a) 玻璃**之外**的背衬（整幅宽、玻璃上下各 4px + 左右两侧）逐字节不变
  //       —— 这才是 Owner 要的「固定在上面，不随整体下滑」；
  //   (b) 玻璃**之内**的透出量必须远小于背后内容的实际位移（相对判据，自校准）。
  //
  // ★ 判据 (b) 用**相对**而非绝对阈值：绝对阈值（如「<10」）是我猜的；
  //   相对值拿同一对截图里内容的真实位移当标尺 ⇒ 无需猜、且玻璃一旦真的漏内容
  //   （透出量与内容位移同量级）必然被抓住。
  final glassRect = barRectA;
  final backingRects = backingOf(glassRect, shotA.w.toDouble());
  var backingDiffN = 0;
  var backingDiffMax = 0;
  for (final r in backingRects) {
    final d = diffRegion(shotA, shotB, r);
    backingDiffN += d.n;
    if (d.maxDelta > backingDiffMax) backingDiffMax = d.maxDelta;
  }
  final glassDiff = diffRegion(shotA, shotB, glassRect);
  // 标尺：玻璃正下方的原始内容（同样列区间）在两次截图之间移动了多少
  final contentRect = Rect.fromLTRB(
      glassRect.left, glassRect.bottom + kPad, glassRect.right,
      glassRect.bottom + kPad + 24);
  final contentDiff = diffRegion(shotA, shotB, contentRect);

  note('吸顶带几何 = ${bandOf(glassRect)}（高 ${bandOf(glassRect).height}，设计值 $kBarExtent）');
  note('逐像素：背衬(玻璃之外) 差异=$backingDiffN px 最大=$backingDiffMax  |  '
      '玻璃之内 差异=${glassDiff.n} px 最大=${glassDiff.maxDelta}  |  '
      '背后内容 差异=${contentDiff.n} px 最大=${contentDiff.maxDelta}');

  // ★★ 判据 (a) 的**敏感性证明**（VERIFY-LESSONS #327：零结果必须配已证明敏感的仪器）
  //
  // 「背衬零差异」有两种可能：①背衬不透明、真的挡住了滚动内容（正确）；
  // ②这块区域根本没画东西（空洞）。单色性把两者分开：不透明实心填充只有
  // 1 种颜色，而「能看见内容」必然多色。
  //
  // ★ 这里**替换掉**了原来那条「吸顶带高度自洽」断言 —— 它是**恒真**的：
  //   `bandOf()` 就是按 `glass.height + kPad` 定义的，断言它 == kBarExtent(58)
  //   永远成立，抓不住任何错误（VERIFY-LESSONS #331 的同类）。改成从**像素**
  //   读带的边界。
  final backingColours = <int>[];
  for (final r in backingRects) {
    backingColours.add(distinctColours(shotB, r));
  }
  var maxBackingColours = 0;
  for (final c in backingColours) {
    if (c > maxBackingColours) maxBackingColours = c;
  }
  // 带正下方 4px：玻璃已结束 ⇒ 整幅宽都该是内容
  final bandBottom = bandOf(glassRect).bottom;
  final belowRect = Rect.fromLTRB(
      0, bandBottom, shotB.w.toDouble(), bandBottom + 4);
  final belowColours = distinctColours(shotB, belowRect);
  // 带正上方 4px（同理，玻璃之上也是背衬）
  final aboveRect = Rect.fromLTRB(
      0, bandOf(glassRect).top, shotB.w.toDouble(), glassRect.top);
  final aboveColours = distinctColours(shotB, aboveRect);

  note('背衬颜色数=${backingColours.join('/')}（各矩形）  带上方颜色数=$aboveColours  '
      '带下方(内容)颜色数=$belowColours  玻璃内颜色数=${distinctColours(shotB, glassRect)}');

  ok('② 吸顶背衬是**单色不透明填充**（证明判据 (a) 的零差异不是「这块没画东西」）',
      maxBackingColours == 1, '各背衬矩形颜色数=${backingColours.join('/')}');
  ok('② 吸顶带下边界是真的（带正下方立刻是多色内容，不是又一层背衬）',
      belowColours > 1, '带下方颜色数=$belowColours');
  ok('② ★阳性对照：玻璃背后的内容真的动了（最大位移 > 50/255，否则下一条无意义）',
      contentDiff.maxDelta > 50, '内容最大位移=${contentDiff.maxDelta}/255');
  ok('② ★★待证命题 (a)：玻璃**之外**的吸顶背衬逐字节不变（内容没漏进条里）',
      backingDiffN == 0,
      '差异=${backingDiffN}px 最大=$backingDiffMax  带=${bandOf(glassRect)}');
  ok('② ★★待证命题 (b)：玻璃之内的透出量 << 背后内容位移（≥10× 衰减 = 折射而非漏内容）',
      glassDiff.maxDelta * 10 < contentDiff.maxDelta,
      '透出=${glassDiff.maxDelta}/255 vs 内容位移=${contentDiff.maxDelta}/255 '
      '（衰减 ${contentDiff.maxDelta == 0 ? 'n/a' : (contentDiff.maxDelta / (glassDiff.maxDelta == 0 ? 1 : glassDiff.maxDelta)).toStringAsFixed(1)}×）');
  ok('② 两张图的 strip 里都没有滚动条滑块（逐字节比对的前提）',
      shotB.scrollbarRows == 0, '滑块行数=${shotB.scrollbarRows}');
  ok('② 滚后截图非退化（>20 色）', shotB.colors > 20, '颜色数=${shotB.colors}');

  // ── ③ 点「直播源」真切页 ──────────────────────────────────────────────
  say('');
  say('──────── ③ 点「直播源」tab 真切页 ────────');

  final liveTabEl = findText(root0, '直播源');
  final liveTabRect = rectOf(liveTabEl);
  ok('③ tab 条上的「直播源」有几何（吸顶后依然可点）', liveTabRect != null,
      liveTabRect == null ? '' : 'rect=$liveTabRect');
  if (liveTabRect == null) {
    say('★ 拿不到 tab 几何 ⇒ 中止');
    await finish(1);
  }
  await tapAndSettle(liveTabRect!.center);
  await settleOverlays();

  // 「直播源」页的判据文案（settings_page.dart:2310 / :2293）
  final emptyEl = findText(root0, '还没有支持直播的源');
  final countEl = findTextMatching(root0, RegExp(r'^\d+/\d+ 已启用$'));
  ok('③ 直播源 tab 的内容真的渲染了（\'还没有支持直播的源\' 或 \'N/M 已启用\'）',
      emptyEl != null || countEl != null,
      'empty=${emptyEl != null} count=${countEl != null}');
  if (emptyEl == null && countEl == null) {
    final shot = await shoot('03-live-tab-failure');
    note('失败现场截图 ${shot.path}  采样颜色数=${shot.colors}');
    say('★ 直播源 tab 内容没渲染 ⇒ 中止');
    say('[T76] RESULT verdict=LIVE-TAB-EMPTY pass=$pass fail=$fail');
    await finish(1);
  }

  // 解析 chip 里的 M
  var m0 = 0;
  var n0 = 0;
  if (countEl != null) {
    final t = (countEl.widget as Text).data!;
    final parts = t.replaceAll(' 已启用', '').split('/');
    n0 = int.tryParse(parts[0]) ?? -1;
    m0 = int.tryParse(parts[1]) ?? -1;
  }
  note('直播 tab 计数 = 「${countEl == null ? '(空态)' : (countEl.widget as Text).data}」');
  ok('③ 直播 tab 的 M（直播源总数）= 核心侧读到的 live 数',
      m0 == liveCore.length,
      'UI M=$m0  核心 live=${liveCore.length}');
  // ★ n0 = 「N/M 已启用」的 N。空态（countEl == null）时无从谈起 ⇒ 只在有 chip 时断言。
  //   不加这一条，n0 就只是个被解析出来却没人用的数（analyzer 报 unused）。
  ok('③ 已启用数 N ≤ 总数 M（chip 自洽）',
      countEl == null || (n0 >= 0 && n0 <= m0),
      'N=$n0 M=$m0 chip=${countEl == null ? '(空态)' : '有'}');

  final shotC = await shoot('03-live-tab', strip: rectOf(barEl));
  note('直播 tab 截图 ${shotC.path}  采样颜色数=${shotC.colors}');
  ok('③ 直播 tab 截图非退化（>20 色）', shotC.colors > 20, '颜色数=${shotC.colors}');

  // ── ④ 导入 js 插件 ⇒ 直播源列表自动更新 ──────────────────────────────
  say('');
  say('──────── ④ 导入 js 插件 ⇒ 直播源自动更新（走真实按钮）────────');

  // 回插件 tab。
  // ★ 二级页页头也有 Text('JS 插件') ⇒ 全树 findText 会歧义（可能拿到页头，
  //   点页头什么都不会发生，然后 chip 读不到 ⇒ 假失败）。只用玻璃条子树里的那个。
  final tabBarPlugins = _findTextInside(root0, barEl, 'JS 插件');
  final tabPluginsRect = rectOf(tabBarPlugins);
  ok('④ 找得到 tab 条上的「JS 插件」（切回插件 tab 用）', tabPluginsRect != null,
      '★ 只在玻璃条子树里找，避免命中二级页页头');
  if (tabPluginsRect == null) {
    say('★ 拿不到插件 tab 几何 ⇒ 中止');
    await finish(1);
  }
  await tapAndSettle(tabPluginsRect!.center);
  await settleOverlays();

  final chipEl = findTextMatching(root0, RegExp(r'^直播 \d+/\d+$'));
  String chipText = chipEl == null ? '' : (chipEl.widget as Text).data!;
  var chipM = _secondInt(chipText);
  note('块头 chip = 「${chipText.isEmpty ? '(无，说明 _liveSources 为空)' : chipText}」');
  ok('④ 基线读到了（块头 chip「直播 N/M」存在 ⇒ 有直播源才有得比）',
      chipEl != null && chipM != null, 'chip=$chipText');
  if (chipM == null) {
    say('★ 基线读不到直播源数 ⇒ ④ 无从判定，中止');
    say('[T76] RESULT verdict=NO-BASELINE pass=$pass fail=$fail');
    await finish(1);
  }
  note('基线：核心 live=${liveCore.length}  直播 tab M=$m0  块头 chip M=$chipM');
  ok('④ 三处基线一致（核心 / 直播 tab / 块头 chip）',
      liveCore.length == m0 && m0 == chipM,
      'core=${liveCore.length} tab=$m0 chip=$chipM');

  // 走真实按钮
  final installBtn = findText(root0, '粘贴源码安装');
  final installRect = rectOf(installBtn);
  ok('④ 找得到真实按钮「粘贴源码安装」', installRect != null);
  if (installRect == null) {
    say('★ 找不到安装按钮 ⇒ 中止');
    await finish(1);
  }
  await tapAndSettle(installRect!.center);
  await Future<void>.delayed(const Duration(milliseconds: 600));
  await pumpFrame();

  final dlgUp = await waitUntil(
    () => findWidget(root0, (w) => w is TextField && w.maxLines == 10) != null,
    timeout: const Duration(seconds: 10),
    label: '粘贴源码对话框',
  );
  ok('④ 弹出了「粘贴插件内容」对话框（maxLines==10 的 TextField）', dlgUp);
  if (!dlgUp) {
    say('★ 对话框没弹出 ⇒ 中止');
    await finish(1);
  }

  final tf = findWidget(root0, (w) => w is TextField && w.maxLines == 10)!;
  final ctl = (tf.widget as TextField).controller;
  ok('④ 对话框的 TextField 带 controller（能注入源码）', ctl != null);
  if (ctl == null) {
    say('★ 没有 controller ⇒ 无法注入 ⇒ 中止');
    await finish(1);
  }
  ctl!.text = kSrcLiveOn;
  note('已注入插件源码 ${kSrcLiveOn.length} 字符（@id=$kProbePluginId @name=$kProbePluginName live=true）');
  await pumpFrame();

  final okBtns = findAllWidgets(root0, (w) => w is Text && w.data == '确定');
  note('树里 Text(\'确定\') 个数 = ${okBtns.length}（取最后一个 = 最上层路由）');
  ok('④ 找得到对话框的「确定」按钮', okBtns.isNotEmpty);
  if (okBtns.isEmpty) {
    say('★ 找不到「确定」⇒ 中止');
    await finish(1);
  }
  final okRect = rectOf(okBtns.last);
  if (okRect == null) {
    say('★ 「确定」没有几何 ⇒ 中止');
    await finish(1);
  }
  await tapAndSettle(okRect!.center);

  // 等 chip 变
  final grew = await waitUntil(
    () {
      final e = findTextMatching(root0, RegExp(r'^直播 \d+/\d+$'));
      if (e == null) return false;
      final m = _secondInt((e.widget as Text).data!);
      return m != null && m == chipM! + 1;
    },
    timeout: const Duration(seconds: 25),
    label: 'chip M 变为 ${chipM! + 1}',
  );
  await settleOverlays();

  final chipEl2 = findTextMatching(root0, RegExp(r'^直播 \d+/\d+$'));
  final chipText2 = chipEl2 == null ? '' : (chipEl2.widget as Text).data!;
  final chipM2 = _secondInt(chipText2);
  note('安装后块头 chip = 「$chipText2」  grew=$grew');

  ok('④ ★★★ 导入 js 插件后，直播源数自己从 $chipM 变成 ${chipM! + 1}',
      chipM2 == chipM + 1, 'chip=$chipText2');
  ok('④ 新插件在核心侧也真的注册了且 live=true',
      await _coreHasLive(kProbePluginId),
      'SourinApi.listProviders() 复查');

  // 二级页页头副标题（独立读数：内容源总数 +1）
  final entry1 = findEntryRow(root0, 'JS 插件');
  final subtitle1 = entry1 == null
      ? ''
      : (entry1.widget as SettingsEntryRow).subtitle;
  final nProv1 = _firstInt(subtitle1);
  note('入口行副标题 前=「$subtitle0」 后=「$subtitle1」');
  ok('④ 独立读数：内容源总数也 +1（副标题）',
      nProv0 != null && nProv1 != null && nProv1 == nProv0 + 1,
      '前=$nProv0 后=$nProv1');

  // 直播 tab 里真的出现新插件名
  final liveTabRect2 = rectOf(_findTextInside(root0, barEl, '直播源'));
  if (liveTabRect2 != null) {
    await tapAndSettle(liveTabRect2.center);
    await settleOverlays();
  }
  final nameInLive = findText(root0, kProbePluginName) != null;
  ok('④ ★ 新插件的名字真的出现在**直播 tab** 里（不是只在插件 tab）',
      nameInLive, 'Text(\'$kProbePluginName\')');
  final shotD = await shoot('04-after-install', strip: rectOf(barEl));
  note('安装后直播 tab 截图 ${shotD.path}  采样颜色数=${shotD.colors}');

  // ── ⑤ js 插件变更 ⇒ 也自动更新 ───────────────────────────────────────
  say('');
  say('──────── ⑤ js 插件变更（live: true → false）⇒ 也自动更新 ────────');

  final backRect = rectOf(_findTextInside(root0, barEl, 'JS 插件'));
  if (backRect != null) {
    await tapAndSettle(backRect.center);
    await settleOverlays();
  }
  final installRect2 = rectOf(findText(root0, '粘贴源码安装'));
  ok('⑤ 回到插件 tab、找得到安装按钮', installRect2 != null);
  if (installRect2 == null) {
    say('★ ⑤ 前置失败 ⇒ 中止');
    await finish(1);
  }
  await tapAndSettle(installRect2!.center);
  await Future<void>.delayed(const Duration(milliseconds: 600));
  await pumpFrame();

  final tf2 = findWidget(root0, (w) => w is TextField && w.maxLines == 10);
  ok('⑤ 对话框再次弹出', tf2 != null);
  if (tf2 == null) {
    say('★ ⑤ 对话框没弹出 ⇒ 中止');
    await finish(1);
  }
  final ctl2 = (tf2!.widget as TextField).controller!;
  ctl2.text = kSrcLiveOff;
  note('已注入变更后的源码（同一 @id，版本 1.0.1，capabilities.live=false）');
  await pumpFrame();

  final okBtns2 = findAllWidgets(root0, (w) => w is Text && w.data == '确定');
  if (okBtns2.isEmpty) {
    say('★ ⑤ 找不到「确定」⇒ 中止');
    await finish(1);
  }
  await tapAndSettle(rectOf(okBtns2.last)!.center);

  final shrank = await waitUntil(
    () {
      final e = findTextMatching(root0, RegExp(r'^直播 \d+/\d+$'));
      if (e == null) return false;
      final m = _secondInt((e.widget as Text).data!);
      return m != null && m == chipM;
    },
    timeout: const Duration(seconds: 25),
    label: 'chip M 回到 $chipM',
  );
  await settleOverlays();

  final chipEl3 = findTextMatching(root0, RegExp(r'^直播 \d+/\d+$'));
  final chipText3 = chipEl3 == null ? '' : (chipEl3.widget as Text).data!;
  note('变更后块头 chip = 「$chipText3」  shrank=$shrank');
  ok('⑤ ★★★ 插件变更后直播源数自己回到基线 $chipM（capabilities.live=false 生效）',
      _secondInt(chipText3) == chipM, 'chip=$chipText3');
  ok('⑤ 核心侧复查：该插件仍在（只是不再声明 live）',
      provs.any((p) => p.id == kProbePluginId) || await _coreHas(kProbePluginId),
      '@id=$kProbePluginId');

  final liveTabRect3 = rectOf(_findTextInside(root0, barEl, '直播源'));
  if (liveTabRect3 != null) {
    await tapAndSettle(liveTabRect3.center);
    await settleOverlays();
  }
  ok('⑤ ★ 变更后该插件的名字从直播 tab **消失**',
      findText(root0, kProbePluginName) == null,
      'Text(\'$kProbePluginName\')');

  // ── ⑥ 终态不变量 ─────────────────────────────────────────────────────
  say('');
  say('──────── ⑥ 终态不变量 ────────');

  final barRectEnd = rectOf(barEl);
  ok('⑥ tab 条从头到尾都在（几何仍然拿得到）', barRectEnd != null,
      barRectEnd == null ? '' : 'rect=$barRectEnd');
  ok('⑥ 玻璃 tab 条高度全程不变', barRectEnd != null &&
      (barRectEnd.height - kGlassBarH).abs() < 0.5,
      '实测=${barRectEnd?.height}');
  // ★ 第一版写的是 `ok('…', barEl != null)` —— 但 barEl 在上面已被 `await finish(1)`
  //   守卫提升为非空，analyzer 直接报 unnecessary_null_comparison ⇒ 那是**恒真判据**。
  //   改成「重新查找一次，看是否仍命中同一个 Element」：重新查找可能落空 ⇒ 真的可假。
  final barElEnd = _findGlassBarContaining(root0, '直播源');
  ok('⑥ tab 条仍然是那个玻璃容器（重新查找仍命中同一个 Element）',
      identical(barElEnd, barEl), 'end=${barElEnd != null}');

  final provsEnd = await _safeProviders();
  note('终态核心侧 = ${provsEnd.length} 个源，live=${provsEnd.where((p) => p.capabilities.live).length}');
  ok('⑥ 终态 live 数与基线一致（探针没有留下净变化）',
      provsEnd.where((p) => p.capabilities.live).length == liveCore.length,
      '基线=${liveCore.length} 终态=${provsEnd.where((p) => p.capabilities.live).length}');

  final elapsed = DateTime.now().difference(t0).inSeconds;
  say('');
  say('══════ 结束：pass=$pass fail=$fail  用时 ${elapsed}s ══════');
  // ★ 第一版这里写的是 `玻璃条=${barEl != null}` —— barEl 已提升为非空 ⇒ 恒真，
  //   analyzer 报 unnecessary_null_comparison。RESULT 行里放一个恒真的值
  //   比不放更糟（读的人会以为它被验证过）。改印几何，那是真的读出来的。
  say('[T76] RESULT task-76③ 直播源 tab：玻璃条=${barRectA.width.toStringAsFixed(0)}x'
      '${barRectA.height.toStringAsFixed(0)}@top${barRectA.top.toStringAsFixed(0)} '
      '条高=${barRectA.height} 静止top=${barRectA.top} 滚后top=${barRectB?.top} '
      '内容上移=${ctrlTopA == null || ctrlTopB == null ? 'n/a' : (ctrlTopA - ctrlTopB).toStringAsFixed(1)}px '
      '直播源数 核心=${liveCore.length} tab=$m0 chip=$chipM→$chipText2→$chipText3 '
      'pass=$pass fail=$fail | 环境 真机 | 时间 ${DateTime.now().toIso8601String()}');
  await finish(fail == 0 ? 0 : 1);
}

String get _glassBarHStr => kGlassBarH.toStringAsFixed(1);

Element? _findTextInside(Element root, Element? scope, String text) {
  if (scope == null) return findText(root, text);
  return findText(scope, text);
}

int? _firstInt(String s) {
  final m = RegExp(r'\d+').firstMatch(s);
  return m == null ? null : int.tryParse(m.group(0)!);
}

int? _secondInt(String s) {
  final ms = RegExp(r'\d+').allMatches(s).toList();
  return ms.length < 2 ? null : int.tryParse(ms[1].group(0)!);
}

Future<bool> _coreHasLive(String id) async {
  try {
    final ps = await SourinApi.listProviders();
    return ps.any((p) => p.id == id && p.capabilities.live);
  } catch (_) {
    return false;
  }
}

Future<bool> _coreHas(String id) async {
  try {
    final ps = await SourinApi.listProviders();
    return ps.any((p) => p.id == id);
  } catch (_) {
    return false;
  }
}

Future<List<ProviderManifest>> _safeProviders() async {
  try {
    return await SourinApi.listProviders();
  } catch (_) {
    return const <ProviderManifest>[];
  }
}
