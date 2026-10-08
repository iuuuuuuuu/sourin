/*
 * t87 —— 「云盘同步搬进备份二级页」的真机取证
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Owner 原话（m12567）：「云盘同步合并到备份二级页去」
 *
 * ── 改动 ─────────────────────────────────────────────────────────────────
 *   · 新文件 `lib/ui/widgets/sync_panel.dart`（自包含 `SyncPanel`）
 *   · `lib/ui/settings/backup_page.dart` 多摆一个 `SyncPanel()`
 *   · `lib/ui/settings_page.dart` 删掉云盘同步的**全部**痕迹
 *     （字段 / `Future.wait` 第 4 项 / 四个方法 / UI 区块 / `_WebdavDialog`）
 *
 * ── 为什么必须真机取证（编译绿 / 测试绿 / SHA 都不算数）──────────────────
 *   · `SettingsPage` / `SourinApp` 在 `flutter test` 里**挂不上**：
 *     `build()` 走到 `${SourinApi.version}` ⇒ `DynamicLibrary.open(
 *     'sourin_core.dll')` ⇒ 整棵子树被换成 `ErrorWidget`（本仓已记录）。
 *   · 「搬走了没有」是**元素树 + 光栅化**命题，只有真窗口才存在。
 *   · `toImage()` 在 `flutter test` 里挂死，在真进程里正常。
 *
 * ── ★★ 本探针最大的仪器陷阱：惰性构建 + 保活 ────────────────────────────
 *   1. `ListView(children: [...])` / `SliverList` 都是**惰性**的：
 *      视口外的子件**根本不在元素树上**。所以"找不到 `云盘同步`"
 *      很可能只是"它没被建出来"，而不是"它不在这一页"。
 *      ⇒ 必须**扫过整个可滚区间**，并且必须同时找到**已知存在**的邻居
 *        （`JS 插件` / `片头片尾`）当**阳性对照** ——
 *        扫得到邻居、扫不到目标，这个"零结果"才有信息量。
 *        （铁律：零结果必须随附一个**已被证明灵敏**的仪器。）
 *   2. shell 用 `Stack + Offstage` 保活所有 tab 页（`shell.dart:3046`），
 *      `Navigator` 也会保活被盖住的路由。⇒ 整树 DFS 会**同时**看到
 *      一级页和二级页的文本。所以**每一条断言都必须限定子树范围**：
 *        · 一级页范围 = `SettingsPage` 元素
 *        · 二级页范围 = `SettingsSubPage` 元素
 *      ★ 这也让"搬走了"能有一个**结构性**证明（比像素更硬）：
 *        `SyncPanel` 的祖先链里**有** `SettingsSubPage`、**没有** `SettingsPage`。
 *
 * ── 判据（每条都要有对照）────────────────────────────────────────────────
 *   ⓪ 仪器自检：shell 挂上 / 根元素在 / 隔离目录 / 截图非退化（>20 色）。
 *   ① 一级页身份：树里有 `Text('内容源、网络与同步')`；
 *      **阴性对照**：`Text('返回设置')` **不在**（证明还没进二级页）。
 *   ② 一级页**全区间扫描**（在 `SettingsPage` 子树内）：
 *      · 阳性对照：`局域网遥控` / `JS 插件` / `片头片尾` / `备份与恢复`
 *        / `主题` / `关于` **必须**都被扫到（证明扫描确实遍历到了
 *        整页、且 `云盘同步` 原来所在的那一段也被覆盖到了）；
 *      · **★ 核心阴性**：`云盘同步` **从未**出现；
 *      · **★ 结构性阴性**：`SettingsPage` 子树里**没有** `SyncPanel` 元素。
 *   ③ 点「备份与恢复」入口行（**合成指针，不碰 Owner 的鼠标**）⇒ 二级页。
 *   ④ 二级页**全区间扫描**（在 `SettingsSubPage` 子树内）：
 *      · **★ 核心阳性**：`云盘同步` 与 `备份` **都**被扫到；
 *      · `BackupPanel` 与 `SyncPanel` 元素都在；
 *      · **★ 结构性阳性**：`SyncPanel` 祖先链 ⊇ `SettingsSubPage`，
 *        且 ∩ `SettingsPage` = ∅（它真的在二级页里、真的不在一级页里）；
 *      · 面板**状态与后端同源**：`trailing` 文案（`已连接`/`未配置`）
 *        必须等于本探针**独立**调 `SourinApi.syncStatus()` 得到的状态。
 *   ⑤ **活性证明**：点面板上的「配置云盘 / 重新配置」⇒ 弹出
 *      `_WebdavDialog`（该对话框本次是从 `settings_page.dart`
 *      **原样搬进** `sync_panel.dart` 的）。对话框里四个字段标签
 *      与两个按钮都在 ⇒ 回调接线是活的，不是一块死文案。
 *      ★ 只点「取消」—— **绝不点「保存并测试」**（那会写凭据 + 发网络请求）。
 *   ⑥ 点「返回设置」⇒ 二级页真的弹掉、一级页还在。
 *
 * ── 仪器纪律（本仓血泪）──────────────────────────────────────────────────
 *   · `exit()` **不展开 finally** ⇒ 每条退出路径先 `finish()` 落产物。
 *   · 外壳直接用**生产本体** `SourinApp`（不是复刻）⇒ `FTheme → FScaffold
 *     → Material(transparency)` 天然满足；复刻漏 `Material` 层会让
 *     `InkWell` 抛 `Null check operator used on a null value` 并把整页换成
 *     ErrorWidget，真因只在 **stderr**。
 *   · 滚动条（600ms 淡出）与文本光标都是**瞬时叠加层**（#328/#330）
 *     ⇒ 取像素/截图前先 `settleOverlays()`。
 *   · `jumpTo()` 会**重新点亮滚动条** ⇒ 每次滚动之后都要重新 settle。
 *   · 绝不动 Owner 的鼠标：本探针**只**用 `debugSwitchTo` +
 *     `WidgetsBinding.handlePointerEvent`（框架层合成事件）。
 *   · 只读隔离数据目录（`--dart-define=DATA_DIR_OVERRIDE=...`），
 *     绝不碰 `%APPDATA%\app.sourin.player`。
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
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';
import 'shell.dart';
import 'ui/app_theme.dart';
import 'ui/settings_page.dart';
import 'ui/widgets/backup_panel.dart';
import 'ui/widgets/settings_sub_page.dart';
import 'ui/widgets/sync_panel.dart';

// ══════════════════════════════════════════════════════════════════════════
// 常量
// ══════════════════════════════════════════════════════════════════════════

const String _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

/// 产物标签（两次运行不互相覆盖）。
const String _tag = String.fromEnvironment('T87_TAG', defaultValue: 'cloudsync');

/// 页面底色应有的值 —— 来自**原版 Tauri 浅色主题**
/// `D:\WishProject\cctv_to_client\src\design\theme-light.css:32`
///   `--bg-base: #eef0f6;`
/// 与 `lib/ui/app_theme.dart` 的 `LightTokens.bgBase` 逐字一致。
/// ★ 2026-09-29 的灰带修复（`shell.dart:2929-2931`）就是为了让
///   「吸顶条 == 页面底色 == 这个值」，二级页自带 `Scaffold` 也是这个值。
const int kExpectedBg = 0xEEF0F6;

/// 页边距取样列：落在内容 `Padding`(24) 之外 ⇒ 纯页面底色。
/// ★ 这两个数字沿用 t84 的**量出来的**取值（`t84_greyband_probe.dart:109-126`），
///   不要改回"从布局常量推"的版本 —— 那一版瞄在带外，给过假绿。
const int kMarginColL = 20;
const int kMarginColR = 1260;

/// 底色扫描的 y 区间：避开顶部自绘标题栏（~39px）与底部导航条（~90px）。
const int kColScanY0 = 60;
const int kColScanY1 = 620;

/// 可点区域"安全带"（**一级页**）：避开标题栏与**底部导航条**，也避开视口上下边缘。
/// ★ 这两个值是从 t84 量出来的，只在**带底部导航条**的一级页成立。
const double kBandLo = 110;
const double kBandHi = 620;

/*
 * ★★ 可点区域"安全带"（**二级页**）—— 2026-09-29 修的一个**仪器错误**。
 *
 * 第一次跑 t87 时 ⑤ 判了两条 ✗（`配置按钮已滚进安全带` / `配置按钮可达`），
 * 原因是直接沿用了 kBandLo/kBandHi = 110..620。
 * 但二级页是 **push 上来的整屏路由**，没有底部导航条；而且本页内容很短，
 * `maxScrollExtent` 只有 **40px** ⇒ 按钮**根本不可能**被滚到 y≤620，
 * 判据在构造上就不可能满足。同一次运行的截图
 * `.probe\t87-cloudsync-04-backup-subpage.png` 里，`配置云盘` 按钮明明
 * 清清楚楚画在 y≈647 处。
 *
 * ⇒ 这是**探针瞄错区域**（VERIFY-LESSONS #361 的同类：定点取样落在判据区域之外），
 *   不是产品缺陷。修法：二级页用整屏安全带 —— 下界躲开**吸顶返回条**
 *   （`_backBarMin(44) + homeTopPadding(20) = 64`），上界留 20px 余量。
 */
const double kBandLoSub = 70;
const double kBandHiSub = 780;

// ══════════════════════════════════════════════════════════════════════════
// 计数 / 日志
// ══════════════════════════════════════════════════════════════════════════

int pass = 0;
int fail = 0;
final List<String> _log = <String>[];

void say(String s) {
  _log.add(s);
  debugPrint('[T87] $s');
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
  final f = File('$_outDir\\t87-cloudsync-$_tag.txt');
  try {
    f.writeAsStringSync('${_log.join('\n')}\n');
  } catch (e) {
    debugPrint('[T87] ★ 产物写入失败: $e');
  }
  debugPrint('[T87] 产物 = ${f.path}  ${f.existsSync() ? f.lengthSync() : -1} B');
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

/// 深度优先找**第一个**匹配的 widget（★ 调用方必须自己限定子树范围）。
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

Element? findText(Element root, String text) =>
    findWidget(root, (w) => w is Text && w.data == text);

/// 子串匹配（用于拼接字面量、含变量的文案）。
Element? findTextContains(Element root, String needle) =>
    findWidget(root, (w) => w is Text && (w.data?.contains(needle) ?? false));

/// 收集子树里所有 `Text.data`（`Text.rich` 的 data 是 null，跳过）。
void collectTexts(Element root, Set<String> out) {
  void walk(Element e) {
    final w = e.widget;
    if (w is Text) {
      final d = w.data;
      if (d != null) out.add(d);
    }
    e.visitChildren(walk);
  }

  walk(root);
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

/// [e] 的祖先链里有没有匹配的 widget（★ 用来做"结构性"归属证明）。
bool ancestorChainHas(Element e, bool Function(Widget w) test) {
  var hit = false;
  e.visitAncestorElements((a) {
    if (test(a.widget)) {
      hit = true;
      return false;
    }
    return true;
  });
  return hit;
}

/// 从某个元素向上找最近的 `ScrollableState`（`t76_live_tab_probe.dart:291` 同源）。
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

/// 子树里**最外层**的 `ScrollableState`（DFS 序 ⇒ 第一个就是最外层）。
ScrollableState? scrollableIn(Element scope) {
  final el = findWidget(scope, (w) => w is Scrollable);
  if (el is StatefulElement && el.state is ScrollableState) {
    return el.state as ScrollableState;
  }
  return null;
}

Rect? rectOf(Element? e) {
  if (e == null) return null;
  final ro = e.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

/*
 * ★ `dart:ui` 的 `Rect` **没有覆写 `toString()`**，直接插值只会打出
 *   `Instance of 'Rect'` —— 几何读数全丢。第一次跑 t87 时 ⑤ 的两条 ✗
 *   后面就跟着 `rect=Instance of 'Rect'`，等于**没有任何现场信息**，
 *   逼得只能靠回看截图才判出是仪器错。⇒ 几何一律走这个格式化器。
 */
String rectStr(Rect? r) => r == null
    ? 'null'
    : '(${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)})'
        '-(${r.right.toStringAsFixed(1)},${r.bottom.toStringAsFixed(1)})'
        ' ${r.width.toStringAsFixed(1)}x${r.height.toStringAsFixed(1)}';

// ══════════════════════════════════════════════════════════════════════════
// 帧 / 事件
// ══════════════════════════════════════════════════════════════════════════

/// ★ 必须带 timeout：万一没人请求帧，`endOfFrame` 会一直挂着 ⇒ 静默停住。
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

/// 滚动条 600ms 等待 + 300ms 淡出；文本光标闪烁也是瞬时叠加层
/// （VERIFY-LESSONS #328 / #330）⇒ 取像素/几何前先让它静下来。
/// ★ `jumpTo()` 会重新点亮滚动条 ⇒ **每次滚动之后都要再 settle 一次**。
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

  /// 取 (x,y) 的 RGB（丢掉 alpha）。
  int px(int x, int y) {
    final o = y * rowBytes + x * 4;
    return (bytes[o] << 16) | (bytes[o + 1] << 8) | bytes[o + 2];
  }
}

String hex(int c) => '#${c.toRadixString(16).padLeft(6, '0').toUpperCase()}';

String rgbOf(int c) =>
    'rgb(${(c >> 16) & 0xFF},${(c >> 8) & 0xFF},${c & 0xFF})';

Future<Shot> shoot(String name) async {
  final ctx = _rootKey.currentContext;
  if (ctx == null) throw StateError('root context 为 null');
  final ro = ctx.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    throw StateError('根不是 RenderRepaintBoundary，而是 ${ro.runtimeType}');
  }
  final image = await ro.toImage(pixelRatio: 1.0);
  final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  if (raw == null || png == null) throw StateError('toByteData 返回 null');

  final bytes = raw.buffer.asUint8List();
  final w = image.width;
  final h = image.height;
  final path = '$_outDir\\t87-$_tag-$name.png';
  await File(path).writeAsBytes(png.buffer.asUint8List(), flush: true);

  // 仪器自检：每 7 像素采样一次数颜色（退化图只有 1~2 色）
  final set = <int>{};
  for (var y = 0; y < h; y += 7) {
    for (var x = 0; x < w; x += 7) {
      final o = y * w * 4 + x * 4;
      set.add((bytes[o] << 16) | (bytes[o + 1] << 8) | bytes[o + 2]);
    }
  }
  return Shot(path, w, h, bytes, set.length);
}

/// 某一列在 [y0,y1) 区间里的「颜色 → 行数」直方图（保序）。
Map<int, int> columnColors(Shot s, int x, int y0, int y1) {
  final m = <int, int>{};
  for (var y = y0; y < y1; y++) {
    final c = s.px(x, y);
    m[c] = (m[c] ?? 0) + 1;
  }
  return m;
}

/// 把某一列的颜色直方图印成一行可读文本。
String histLine(Map<int, int> hist) =>
    (hist.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .map((e) => '${hex(e.key)}(${rgbOf(e.key)}) × ${e.value} 行')
        .join('  |  ');

// ══════════════════════════════════════════════════════════════════════════
// 扫描 / 定位
// ══════════════════════════════════════════════════════════════════════════

/// ★★ 扫过 [scope] 的整个可滚区间，返回**每一步看到的 `Text.data` 并集**。
///
/// 为什么必须扫：`ListView` / `SliverList` 是**惰性**的，视口外的子件
/// 根本不在元素树上 ⇒ 单点取样得到的"找不到"是**无信息量**的。
/// 扫完之后要拿**已知存在**的文本当阳性对照，这个"零结果"才算数。
Future<Set<String>> sweepTexts(
  Element scope, {
  double step = 240,
  void Function(double off)? atStep,
}) async {
  final seen = <String>{};
  final pos = scrollableIn(scope)?.position;
  // ★ `hasClients` 在 `ScrollController` 上；`ScrollPosition` 用
  //   `hasContentDimensions`（内容尺寸未知时 maxScrollExtent 无意义）。
  if (pos == null || !pos.hasContentDimensions) {
    note('sweepTexts: 没拿到可滚位置 ⇒ 只收当前视口（**这一步无扫描能力**）');
    collectTexts(scope, seen);
    return seen;
  }

  final max = pos.maxScrollExtent;
  note('可滚区间 = 0..${max.toStringAsFixed(1)}px  步长=$step');
  var off = 0.0;
  var steps = 0;
  while (steps < 40) {
    pos.jumpTo(off.clamp(0.0, max));
    await pumpFrame();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    collectTexts(scope, seen);
    atStep?.call(pos.pixels);
    steps++;
    if (off >= max) break;
    off += step;
  }
  // 兜底：确保末段一定被看过
  pos.jumpTo(max);
  await pumpFrame();
  await Future<void>.delayed(const Duration(milliseconds: 60));
  collectTexts(scope, seen);
  atStep?.call(pos.pixels);
  note('扫描步数=$steps  累计文本=${seen.length} 条');
  return seen;
}

/// 把 [find] 找到的元素滚进"安全带"（避开标题栏 / 底部导航条）。
Future<bool> bringIntoBand(
  Element scope,
  Element? Function() find, {
  double lo = kBandLo,
  double hi = kBandHi,
  int tries = 6,
}) async {
  final pos = scrollableIn(scope)?.position;
  if (pos == null || !pos.hasContentDimensions) {
    note('bringIntoBand: 没拿到可滚位置');
    return false;
  }
  for (var i = 0; i < tries; i++) {
    final r = rectOf(find());
    if (r != null && r.center.dy >= lo && r.center.dy <= hi) return true;
    if (r == null) {
      // 元素还没被建出来 ⇒ 往一个方向试探
      final want = (pos.pixels + 240).clamp(0.0, pos.maxScrollExtent);
      if ((want - pos.pixels).abs() < 1) return false;
      pos.jumpTo(want);
    } else {
      final delta = r.center.dy - (lo + hi) / 2;
      final want = (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent);
      if ((want - pos.pixels).abs() < 1) return false;
      pos.jumpTo(want);
    }
    await pumpFrame();
    await Future<void>.delayed(const Duration(milliseconds: 90));
  }
  final r = rectOf(find());
  return r != null && r.center.dy >= lo && r.center.dy <= hi;
}

/// 底色检查：页边距列的主色必须是 [kExpectedBg]。
void checkPageBg(Shot s, String label) {
  final hist = columnColors(s, kMarginColL, kColScanY0, kColScanY1);
  const total = kColScanY1 - kColScanY0;
  final top = (hist.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
      .first;
  note('$label x=$kMarginColL y=$kColScanY0..${kColScanY1 - 1} ⇒ '
      '${hist.length} 种颜色: ${histLine(hist)}');
  ok('$label 页边距列主色 == ${hex(kExpectedBg)}（与灰带修复后的页面底色同源）',
      top.key == kExpectedBg, '实际主色=${hex(top.key)}');
  if (hist.length > 1) {
    note('$label 该列非单色，主色覆盖 ${top.value}/$total 行'
        '（${(100 * top.value / total).toStringAsFixed(1)}%）');
  }
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

  /*
   * ★ 强制浅色：本机系统就是浅色，用户真实 `ui-prefs.json` 里
   *   **没有 `dsh.theme` 键** ⇒ 他看到的**就是浅色**。
   *   探针显式设成 light 只是**去掉"跑的那一刻系统主题"这个外部变量**。
   *   ★ 写的是隔离目录，不碰用户真实偏好文件。
   */
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
     * ★ 窗口选项**逐字复刻生产**（`lib\shell.dart:309-395`）：
     *   `titleBarStyle: TitleBarStyle.hidden` 会去掉系统标题栏，
     *   自绘标题栏才占得住顶部那 ~39px。若用默认 `normal`，
     *   系统标题栏会**吃掉**客户区高度 ⇒ y 坐标全部错位、读数不可比。
     * ⚠️ 刻意**不**调 `windowManager.focus()`（生产那里有）—— 会抢 Owner 焦点。
     * ★ 必须 `show()`：窗口不可见时引擎可能整帧不产出 ⇒ `toImage()`
     *   拿到退化图，而"全黑"会被"颜色数"判据误读（假绿）。
     */
    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(900, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
      title: '源影 · t87 云盘同步搬迁取证 ($_tag)',
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

Future<void> _body(String dir) async {
  debugPrint('[T87] ══════ 云盘同步搬进备份二级页 —— 真机取证 tag=$_tag ══════');

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
    say('[T87] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  final root0 = _rootKey.currentContext as Element?;
  ok('⓪ 根元素已挂上', root0 != null);
  if (root0 == null) {
    say('[T87] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  ok('⓪ 数据目录是隔离目录（含 .probe，绝不写用户库）',
      dir.toLowerCase().contains('.probe'), dir);
  if (!dir.toLowerCase().contains('.probe')) {
    say('★ 不是隔离目录 ⇒ 立刻中止');
    await finish(1);
  }

  note('AppTheme.mode = ${AppTheme.mode}  (rawStored=${AppTheme.rawStored})');

  // ── ① 程序化切到设置页（**不碰鼠标**）─────────────────────────────────
  say('');
  say('──────── ① 切到设置页 ────────');

  final dynamic shell = debugShellKey.currentState;
  shell.debugSwitchTo(AppTab.settings);
  await Future<void>.delayed(const Duration(milliseconds: 1400));
  await pumpFrame();

  final hdrUp = await waitUntil(
    () => findText(root0!, '内容源、网络与同步') != null,
    timeout: const Duration(seconds: 30),
    label: '设置页页头',
  );
  ok('① 设置页已渲染（树里有 Text("内容源、网络与同步")）', hdrUp);
  if (!hdrUp) {
    final s = await shoot('00-instrument-failure');
    note('失败现场 ${s.path} 颜色数=${s.colors}');
    say('★ 设置页没渲染 ⇒ 中止');
    say('[T87] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  // ★ 阴性对照：还没进二级页，不该看到二级页的返回条
  ok('① 阴性对照：此刻树里**没有** Text("返回设置")（证明还没进二级页）',
      findText(root0!, '返回设置') == null);

  // ★ 范围锚点：一级页子树
  final settingsEl = findWidget(root0!, (w) => w is SettingsPage);
  ok('① 拿到一级页范围锚点 SettingsPage 元素', settingsEl != null);
  if (settingsEl == null) {
    say('[T87] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }
  note('SettingsPage 子树元素数 = ${elementCount(settingsEl)}');
  note('整树元素数 = ${elementCount(root0)}');

  await settleOverlays();
  final s1 = await shoot('01-settings-top');
  note('截图 ${s1.path}  ${s1.w}x${s1.h}  采样颜色数=${s1.colors}');
  ok('⓪ 截图非退化（>20 色）', s1.colors > 20, '颜色数=${s1.colors}');

  // ── ② 一级页全区间扫描（核心阴性）─────────────────────────────────────
  say('');
  say('──────── ② 一级页全区间扫描（SettingsPage 子树内）────────');

  final seenL1 = await sweepTexts(settingsEl);
  note('一级页扫描到 ${seenL1.length} 条文本:');
  for (final t in (seenL1.toList()..sort())) {
    note('   「$t」');
  }

  /*
   * ★ 阳性对照：这些是**一级页现在确实有**的区块/入口。
   *   它们被扫到 ⇒ 扫描确实走遍了整页（包括 `云盘同步` 原来所在的那一段）。
   *   没有这一组，"扫不到 云盘同步" 什么也证明不了。
   */
  for (final anchor in <String>[
    '局域网遥控',
    'JS 插件',
    '片头片尾',
    '备份与恢复',
    '主题',
    '关于',
  ]) {
    ok('② 阳性对照：一级页扫得到「$anchor」', seenL1.contains(anchor));
  }

  // ★★ 核心阴性
  ok('② ★核心阴性：一级页**从未**出现 Text("云盘同步")',
      !seenL1.contains('云盘同步'));
  ok('② 二级页专属文案「配置云盘 / 重新配置」也不在一级页',
      !seenL1.contains('配置云盘') && !seenL1.contains('重新配置'));
  ok('② 一级页扫得到入口行副标题（导出 / 导入本机数据（合并，不覆盖））',
      seenL1.contains('导出 / 导入本机数据（合并，不覆盖）'));

  // ★★ 结构性阴性：一级页子树里不该有 SyncPanel 元素
  ok('② ★结构性阴性：SettingsPage 子树里没有 SyncPanel 元素',
      findWidget(settingsEl, (w) => w is SyncPanel) == null);

  // 像素：一级页底色
  say('');
  await settleOverlays();
  final s2 = await shoot('02-settings-bottom');
  note('截图 ${s2.path}  ${s2.w}x${s2.h}  采样颜色数=${s2.colors}');
  checkPageBg(s2, '② 一级页');

  // ── ③ 点「备份与恢复」入口行 ⇒ 二级页 ────────────────────────────────
  say('');
  say('──────── ③ 点「备份与恢复」入口行（合成指针）────────');

  Element? entryFinder() =>
      findText(settingsEl, '备份与恢复') ??
      findTextContains(settingsEl, '导出 / 导入本机数据');

  final inBand = await bringIntoBand(settingsEl, entryFinder);
  final entryEl = entryFinder();
  final entryRect = rectOf(entryEl);
  note('入口行 rect = ${rectStr(entryRect)}');
  ok('③ 入口行已滚进安全带（一级页 $kBandLo..$kBandHi）', inBand,
      'rect=${rectStr(entryRect)}');
  if (!inBand || entryRect == null) {
    say('★ 入口行点不到 ⇒ 中止（截图留证）');
    await settleOverlays();
    final s = await shoot('03-entry-not-reachable');
    note('现场 ${s.path}');
    say('[T87] RESULT verdict=ENTRY-UNREACHABLE pass=$pass fail=$fail');
    await finish(1);
  }

  await tapAndSettle(entryRect!.center);
  await Future<void>.delayed(const Duration(milliseconds: 900));
  await pumpFrame();

  final subUp = await waitUntil(
    () => findWidget(root0!, (w) => w is SettingsSubPage) != null,
    timeout: const Duration(seconds: 15),
    label: '二级页挂载',
  );
  ok('③ 点入口行 ⇒ 二级页真的推上来了（树里有 SettingsSubPage）', subUp);

  final subEl = findWidget(root0!, (w) => w is SettingsSubPage);
  if (!subUp || subEl == null) {
    await settleOverlays();
    final s = await shoot('03-subpage-missing');
    note('现场 ${s.path}');
    say('[T87] RESULT verdict=SUBPAGE-MISSING pass=$pass fail=$fail');
    await finish(1);
  }
  note('SettingsSubPage 子树元素数 = ${elementCount(subEl)}');

  ok('③ 二级页标题在（Text("备份与恢复")）',
      findText(subEl, '备份与恢复') != null);
  ok('③ 二级页副标题在（Text("导出 / 导入本机数据")）',
      findText(subEl, '导出 / 导入本机数据') != null);
  ok('③ 二级页返回条在（Text("返回设置")）',
      findText(subEl, '返回设置') != null);

  // ── ④ 二级页全区间扫描（核心阳性）─────────────────────────────────────
  say('');
  say('──────── ④ 二级页全区间扫描（SettingsSubPage 子树内）────────');

  final seenSub = await sweepTexts(subEl);
  note('二级页扫描到 ${seenSub.length} 条文本:');
  for (final t in (seenSub.toList()..sort())) {
    note('   「$t」');
  }

  ok('④ ★核心阳性：二级页扫得到 Text("云盘同步")', seenSub.contains('云盘同步'));
  ok('④ 二级页扫得到 Text("备份")（原来的那个区块还在）',
      seenSub.contains('备份'));
  ok('④ 二级页扫得到云盘同步的说明文案',
      seenSub.any((t) => t.contains('支持任意 WebDAV 服务')));
  ok('④ 二级页扫得到配置按钮（配置云盘 / 重新配置）',
      seenSub.contains('配置云盘') || seenSub.contains('重新配置'));
  ok('④ 二级页扫得到备份区块的按钮（导出备份 / 导入备份）',
      seenSub.contains('导出备份') || seenSub.contains('导入备份'));

  // ★★ 结构性阳性：SyncPanel 归属二级页、且不在一级页
  say('');
  say('──────── ④ 结构性归属证明 ────────');
  final syncEl = findWidget(root0!, (w) => w is SyncPanel);
  final bakEl = findWidget(root0!, (w) => w is BackupPanel);
  ok('④ SyncPanel 元素在树上', syncEl != null);
  ok('④ BackupPanel 元素在树上', bakEl != null);
  if (syncEl != null) {
    final underSub = ancestorChainHas(syncEl, (w) => w is SettingsSubPage);
    final underSettings = ancestorChainHas(syncEl, (w) => w is SettingsPage);
    ok('④ ★SyncPanel 祖先链里**有** SettingsSubPage（它确实在二级页里）', underSub);
    ok('④ ★SyncPanel 祖先链里**没有** SettingsPage（它确实不在一级页里）',
        !underSettings);
  }
  if (bakEl != null) {
    ok('④ BackupPanel 祖先链里**有** SettingsSubPage',
        ancestorChainHas(bakEl, (w) => w is SettingsSubPage));
  }

  // ★ 面板状态与后端**同源**（本探针独立调一次 API 做对照）
  say('');
  say('──────── ④ 面板状态 vs 后端（同源对照）────────');
  String apiState;
  try {
    final st = await SourinApi.syncStatus();
    apiState = st.connected ? '已连接' : '未配置';
    note('本探针独立调 SourinApi.syncStatus() ⇒ connected=${st.connected}'
        ' backend=${st.backend} deviceId=${st.deviceId}');
  } catch (e) {
    apiState = '未配置';
    note('SourinApi.syncStatus() 抛错（**没配云盘时属正常**）: $e');
  }
  final shownState = seenSub.contains('已连接')
      ? '已连接'
      : (seenSub.contains('未配置') ? '未配置' : '(都没扫到)');
  note('二级页上面板 trailing 文案 = $shownState   后端口径 = $apiState');
  ok('④ 面板 trailing 文案与后端口径**一致**', shownState == apiState,
      '页面=$shownState 后端=$apiState');

  say('');
  await settleOverlays();
  final s3 = await shoot('04-backup-subpage');
  note('截图 ${s3.path}  ${s3.w}x${s3.h}  采样颜色数=${s3.colors}');
  checkPageBg(s3, '④ 二级页');

  // ── ⑤ 活性证明：点「配置云盘」⇒ _WebdavDialog ─────────────────────────
  say('');
  say('──────── ⑤ 活性证明：点配置按钮 ⇒ WebDAV 对话框 ────────');

  Element? cfgFinder() =>
      findText(subEl, '配置云盘') ??
      findText(subEl, '重新配置');

  final cfgBand = await bringIntoBand(subEl, cfgFinder,
      lo: kBandLoSub, hi: kBandHiSub);
  final cfgRect = rectOf(cfgFinder());
  note('配置按钮 rect = ${rectStr(cfgRect)}  '
      '（二级页安全带 $kBandLoSub..$kBandHiSub）');
  ok('⑤ 配置按钮在二级页安全带内', cfgBand, 'rect=${rectStr(cfgRect)}');

  if (!cfgBand || cfgRect == null) {
    note('★ 配置按钮点不到 ⇒ 跳过 ⑤ 的点击部分（其余判据仍有效）');
    ok('⑤ 配置按钮可达', false, 'rect=${rectStr(cfgRect)}');
  } else {
    await tapAndSettle(cfgRect.center);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await pumpFrame();

    final dlgUp = await waitUntil(
      () => findWidget(root0!, (w) => w is AlertDialog) != null,
      timeout: const Duration(seconds: 10),
      label: 'WebDAV 对话框',
    );
    ok('⑤ 点配置按钮 ⇒ 弹出 AlertDialog（回调接线是活的）', dlgUp);

    final dlgEl = findWidget(root0!, (w) => w is AlertDialog);
    if (dlgEl != null) {
      ok('⑤ 对话框标题 = Text("配置云盘（WebDAV）")',
          findText(dlgEl, '配置云盘（WebDAV）') != null);
      for (final f in <String>['地址', '用户名', '密码', '远程目录']) {
        ok('⑤ 对话框字段「$f」在', findText(dlgEl, f) != null);
      }
      ok('⑤ 对话框按钮「保存并测试」在', findText(dlgEl, '保存并测试') != null);
      ok('⑤ 对话框按钮「取消」在', findText(dlgEl, '取消') != null);
      ok('⑤ 对话框有 4 个输入框（TextField）',
          countWidget(dlgEl, (w) => w is TextField) == 4,
          '实际 ${countWidget(dlgEl, (w) => w is TextField)}');

      await settleOverlays();
      final s4 = await shoot('05-webdav-dialog');
      note('截图 ${s4.path}  ${s4.w}x${s4.h}  采样颜色数=${s4.colors}');

      /*
       * ★★ 只点「取消」—— **绝不点「保存并测试」**。
       *    后者会 `SourinApi.configureWebdav(...)`：写系统钥匙串 + 发网络请求。
       *    本探针是只读取证，不许有副作用。
       */
      final cancelEl = findText(dlgEl, '取消');
      final cancelRect = rectOf(cancelEl);
      ok('⑤ 取消按钮可点', cancelRect != null, 'rect=${rectStr(cancelRect)}');
      if (cancelRect != null) {
        await tapAndSettle(cancelRect.center);
        final gone = await waitUntil(
          () => findWidget(root0!, (w) => w is AlertDialog) == null,
          timeout: const Duration(seconds: 10),
          label: '对话框关闭',
        );
        ok('⑤ 点取消 ⇒ 对话框关闭（没留下任何副作用）', gone);
      }
    }
  }

  // ── ⑥ 点「返回设置」⇒ 二级页弹掉 ──────────────────────────────────────
  say('');
  say('──────── ⑥ 返回 ────────');

  final backEl = findText(subEl, '返回设置');
  final backRect = rectOf(backEl);
  ok('⑥ 返回按钮可点', backRect != null, 'rect=${rectStr(backRect)}');
  if (backRect != null) {
    await tapAndSettle(backRect.center);
    final popped = await waitUntil(
      () => findWidget(root0!, (w) => w is SettingsSubPage) == null,
      timeout: const Duration(seconds: 10),
      label: '二级页弹掉',
    );
    ok('⑥ 点返回 ⇒ 二级页弹掉（SettingsSubPage 已不在树上）', popped);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await pumpFrame();
    ok('⑥ 一级页仍在（SettingsPage 元素还在）',
        findWidget(root0!, (w) => w is SettingsPage) != null);
  }

  // ── 判词 ──────────────────────────────────────────────────────────────
  say('');
  say('判词: tag=$_tag  '
      '一级页扫到文本=${seenL1.length} 条（含「云盘同步」=${seenL1.contains('云盘同步')}）  '
      '二级页扫到文本=${seenSub.length} 条（含「云盘同步」=${seenSub.contains('云盘同步')}）');
  say('[T87] RESULT tag=$_tag pass=$pass fail=$fail');
  await finish(fail == 0 ? 0 : 1);
}

/// 数子树里满足条件的 widget 个数。
int countWidget(Element root, bool Function(Widget w) test) {
  var n = 0;
  void walk(Element e) {
    if (test(e.widget)) n++;
    e.visitChildren(walk);
  }

  walk(root);
  return n;
}
