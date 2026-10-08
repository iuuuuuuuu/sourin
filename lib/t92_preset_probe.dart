/*
 * t92 —— 「WebDAV 服务预设」的真机取证（m13471）
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Owner 原话（m13471，随一张 481×481 的「配置云盘（WebDAV）」对话框截图）：
 *   「配置云盘这里,搞几个预设,点击后自动填充域名和配置信息,比如坚果云,
 *     选择后自动填充坚果云的网址 然后默认也是选择坚果云」
 *
 * ── 为什么必须真机取证（编译绿 / 测试绿 / SHA 都不算数）──────────────────
 *   · 已有 `test/t91_sync_presets_test.dart` 的 19 条断言全绿，但它只能证明
 *     **源码里有这些字符串**，以及**在 flutter test 的 800×600 逻辑视口里**
 *     能点到胶囊。它**证明不了**下面这三件事：
 *       ① 8 个胶囊在**真实窗口 1280×800** 下真的**排得下**（Wrap 换行后的
 *          行数与几何）；
 *       ② 每个胶囊的矩形**落在对话框矩形之内**（release 下 RenderFlex
 *          溢出**不会**画黄黑条，只是**静默裁掉** —— 一个被裁掉的胶囊
 *          用户点不到，而测试全绿）；
 *       ③ 对话框整体高度是否超出窗口 ⇒ 四个输入框是否真的**可见可滚**。
 *     ⇒ 这是**光栅化 + 几何**命题，只有真窗口才存在。
 *   · `SettingsPage` / `SourinApp` 在 `flutter test` 里**挂不上**：
 *     `build()` 走到 `${SourinApi.version}` ⇒ `DynamicLibrary.open(
 *     'sourin_core.dll')` ⇒ 整棵子树被换成 `ErrorWidget`。
 *   · `toImage()` 在 `flutter test` 里挂死，在真进程里正常。
 *
 * ── ★ 本探针的核心判据（几何，不是文案）────────────────────────────────
 *   ③ 「8 个胶囊都排得下且互不重叠」= 对每个胶囊：
 *        · 它在对话框矩形**之内**（左右都不越界）
 *        · 它和**任何**其它胶囊的矩形**不相交**
 *      这条在 release 下是唯一能发现"溢出被静默裁掉"的手段。
 *      ★ 阴性对照：故意把判据的容差收紧 1px，看它是否**真的会红**
 *        （否则"全绿"可能只是判据恒真）。
 *
 * ── 判据一览（每条都要有对照）──────────────────────────────────────────
 *   ⓪ 仪器自检：shell 挂上 / 根元素在 / 隔离目录 / 截图非退化（>20 色）/
 *      开局对话框数 = 0。
 *   ① 走到二级页（照 t87 的既有路线，不重复发明）：
 *      程序化 `debugSwitchTo(settings)` → 点「备份与恢复」入口行 →
 *      `SettingsSubPage` 推上来。
 *   ② 点「配置云盘」⇒ `AlertDialog` 弹出。
 *   ③ ★ 默认态：8 个胶囊都在；`坚果云` 的 `selected == true` 且另外 7 个
 *      都是 false；地址框 == 坚果云地址；远程目录 == `sourin`；
 *      用户名/密码框为空；密码框 `obscureText`；
 *      用户名/密码的 `hintText` 是坚果云专属文案（不是通用文案）。
 *   ④ ★ 几何：每个胶囊矩形 ⊂ 对话框矩形；胶囊两两不相交；
 *      报告行数 / 对话框尺寸 / 是否有纵向滚动。
 *   ⑤ ★ 活性：点「群晖 NAS」⇒ 地址框变成群晖地址、选中态转移、
 *      用户名 hint 变成 `DSM 用户名`；再点回「坚果云」⇒ 全部复原。
 *      ★ 这一步是 Owner 那句「点击后自动填充」的**直接**证据。
 *   ⑥ ★ 占位符拦截：点「Nextcloud」⇒ 地址含 `<主机>`；填上用户名后点
 *      「保存并测试」⇒ **对话框不关** + 出现「占位符」提示。
 *      ★ 这条**只走提前返回分支**，不写凭据、不发网络请求。
 *   ⑦ 点「取消」⇒ 对话框关掉，且**从未**出现「配置失败」文案
 *      （反证 ⑥ 的点击真的被拦住了，没有漏到 `configureWebdav`）。
 *
 * ── 仪器纪律（本仓血泪）──────────────────────────────────────────────────
 *   · `exit()` **不展开 finally** ⇒ 每条退出路径先 `finish()` 落产物。
 *   · 外壳直接用**生产本体** `SourinApp`（不是复刻）⇒ `FTheme → FScaffold
 *     → Material(transparency)` 天然满足；复刻漏 `Material` 层会让
 *     `InkWell` 抛 `Null check operator used on a null value` 并把整页换成
 *     ErrorWidget，真因只在 **stderr**。
 *   · 绝不动 Owner 的鼠标：只用 `debugSwitchTo` +
 *     `WidgetsBinding.handlePointerEvent`（框架层合成事件）。
 *   · 只读隔离数据目录（`--dart-define=DATA_DIR_OVERRIDE=...`），
 *     绝不碰 `%APPDATA%\app.sourin.player`。
 *   · ★ 唯一一处**合成输入**：⑥ 里直接给 `TextEditingController.text` 赋值
 *     填用户名（无法在不碰真键盘的前提下输入）。**此处如实披露** ——
 *     它只影响"用户名非空"这一个前置条件，不改任何产品代码路径。
 *   · ★ **绝不点「保存并测试」于合法地址**（那会写系统钥匙串 + 发网络请求）。
 *     ⑥ 点它的前提是地址含 `<…>`，产品代码在**发请求之前**就 return 了。
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
import 'core/ui_prefs.dart';
import 'shell.dart';
import 'ui/app_theme.dart';
import 'ui/settings_page.dart';
import 'ui/widgets/settings_kit.dart';
import 'ui/widgets/settings_sub_page.dart';
import 'ui/widgets/sync_panel.dart';

// ══════════════════════════════════════════════════════════════════════════
// 常量
// ══════════════════════════════════════════════════════════════════════════

const String _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

/// 产物标签（两次运行不互相覆盖）。
const String _tag = String.fromEnvironment('T92_TAG', defaultValue: 'presets');

/// 二级页"安全带"（照 t87 的**量出来的**取值，不要从布局常量重推）。
const double kBandLoSub = 70;
const double kBandHiSub = 780;

/// 坚果云地址 —— 默认选中项必须填的就是它。
const String kJianguoUrl = 'https://dav.jianguoyun.com/dav/';

/// 8 个预设的名字（顺序即源码顺序，第一个 = 默认选中）。
const List<String> kPresetNames = <String>[
  '坚果云',
  'Nextcloud',
  'ownCloud',
  '群晖 NAS',
  'pCloud',
  'Koofr',
  'Yandex Disk',
  'InfiniCLOUD',
];

// ══════════════════════════════════════════════════════════════════════════
// 计数 / 日志
// ══════════════════════════════════════════════════════════════════════════

int pass = 0;
int fail = 0;
final List<String> _log = <String>[];

void say(String s) {
  _log.add(s);
  debugPrint('[T92] $s');
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
  final f = File('$_outDir\\t92-preset-$_tag.txt');
  try {
    f.writeAsStringSync('${_log.join('\n')}\n');
  } catch (e) {
    debugPrint('[T92] ★ 产物写入失败: $e');
  }
  debugPrint('[T92] 产物 = ${f.path}  ${f.existsSync() ? f.lengthSync() : -1} B');
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
// 元素树（照 t87 已验证的实现）
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

Element? findText(Element root, String text) =>
    findWidget(root, (w) => w is Text && w.data == text);

Element? findTextContains(Element root, String needle) =>
    findWidget(root, (w) => w is Text && (w.data?.contains(needle) ?? false));

/// 子串匹配到的**文案原文**（排查用；找不到返回 null）。
String? textContaining(Element root, String needle) {
  final el = findTextContains(root, needle);
  final w = el?.widget;
  return w is Text ? w.data : null;
}

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

int countWidget(Element root, bool Function(Widget w) test) {
  var n = 0;
  void walk(Element e) {
    if (test(e.widget)) n++;
    e.visitChildren(walk);
  }

  walk(root);
  return n;
}

/// 子树里所有满足条件的 widget（保序 = DFS 序 = build 序）。
List<T> collectWidgets<T extends Widget>(Element root) {
  final out = <T>[];
  void walk(Element e) {
    final w = e.widget;
    if (w is T) out.add(w);
    e.visitChildren(walk);
  }

  walk(root);
  return out;
}

/// 子树里所有满足条件的 (widget, element) 对。
List<({Element el, Widget w})> collectPairs(
    Element root, bool Function(Widget w) test) {
  final out = <({Element el, Widget w})>[];
  void walk(Element e) {
    if (test(e.widget)) out.add((el: e, w: e.widget));
    e.visitChildren(walk);
  }

  walk(root);
  return out;
}

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

/// ★ `dart:ui` 的 `Rect` **没有覆写 `toString()`**，直接插值只打出
///   `Instance of 'Rect'` ⇒ 几何读数全丢。一律走这个格式化器。
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
}

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
  final path = '$_outDir\\t92-preset-$_tag-$name.png';
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

// ══════════════════════════════════════════════════════════════════════════
// 主流程
// ══════════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ★ 必须在 runApp 之前（`shell.dart:276` 的同一条）
  MediaKit.ensureInitialized();

  await Device.init();

  final dir = await _resolveDataDir();
  await UiPrefs.load(dir);

  // ★ 强制浅色：去掉"跑的那一刻系统主题"这个外部变量。
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
  } catch (e) {
    note('LiquidGlassWidgets.initialize 失败: $e');
  }

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    // ★ 窗口选项逐字复刻生产（`lib\shell.dart:309-395`）
    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(900, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
      title: '源影 · t92 预设取证 ($_tag)',
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
    ok('★ 探针异常逃出（必须报出来，不能静默停住）', false, '$e');
    say('$st');
    await finish(1);
  }
}

/// 对话框里的四个 `TextField`（DFS 序 = build 序：地址/用户名/密码/远程目录）。
List<TextField> _fields(Element dlg) => collectWidgets<TextField>(dlg);

String _fieldText(Element dlg, int i) {
  final f = _fields(dlg);
  if (i >= f.length) return '<越界:只有 ${f.length} 个>';
  return f[i].controller?.text ?? '';
}

/// 对话框里的胶囊（保序）。
List<SettingsGesturePill> _pills(Element dlg) =>
    collectWidgets<SettingsGesturePill>(dlg);

bool _pillSelected(Element dlg, String name) => _pills(dlg)
    .any((p) => p.text == name && p.selected);

/// 找某个胶囊的**元素**（要拿几何，必须拿元素不是 widget）。
Element? _pillEl(Element dlg, String name) {
  for (final p in collectPairs(dlg, (w) => w is SettingsGesturePill)) {
    final w = p.w as SettingsGesturePill;
    if (w.text == name) return p.el;
  }
  return null;
}

/// 把 [find] 找到的元素滚进"安全带"（照 t87）。
Future<bool> bringIntoBand(
  Element scope,
  Element? Function() find, {
  double lo = kBandLoSub,
  double hi = kBandHiSub,
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

Future<void> _body(String dir) async {
  debugPrint('[T92] ══════ WebDAV 服务预设 —— 真机取证 tag=$_tag ══════');

  // ── ⓪ 仪器自检 ────────────────────────────────────────────────────────
  say('');
  say('──────── ⓪ 仪器自检 ────────');

  final shellUp = await waitUntil(
    () => debugShellKey.currentState != null,
    timeout: const Duration(seconds: 40),
    label: 'shell 挂载',
  );
  ok('⓪ shell 已挂载', shellUp);
  if (!shellUp) {
    say('[T92] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  final root0 = _rootKey.currentContext as Element?;
  ok('⓪ 根元素已挂上', root0 != null);
  if (root0 == null) {
    say('[T92] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  ok('⓪ 数据目录是隔离目录（含 .probe，绝不写用户库）',
      dir.toLowerCase().contains('.probe'), dir);
  if (!dir.toLowerCase().contains('.probe')) {
    say('★ 不是隔离目录 ⇒ 立刻中止');
    await finish(1);
  }

  ok('⓪ 开局没有任何 AlertDialog（后面弹出来的才算数）',
      countWidget(root0, (w) => w is AlertDialog) == 0);

  // ── ① 走到「备份与恢复」二级页 ────────────────────────────────────────
  say('');
  say('──────── ① 走到二级页 ────────');

  final dynamic shell = debugShellKey.currentState;
  shell.debugSwitchTo(AppTab.settings);
  await Future<void>.delayed(const Duration(milliseconds: 1400));
  await pumpFrame();

  final hdrUp = await waitUntil(
    () => findText(root0, '内容源、网络与同步') != null,
    timeout: const Duration(seconds: 30),
    label: '设置页页头',
  );
  ok('① 设置页已渲染', hdrUp);
  if (!hdrUp) {
    await shoot('00-instrument-failure');
    say('[T92] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  final settingsEl = findWidget(root0, (w) => w is SettingsPage);
  ok('① 拿到一级页范围锚点 SettingsPage 元素', settingsEl != null);
  if (settingsEl == null) {
    say('[T92] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  Element? entryFinder() =>
      findText(settingsEl, '备份与恢复') ??
      findTextContains(settingsEl, '导出 / 导入本机数据');

  final inBand = await bringIntoBand(settingsEl, entryFinder,
      lo: 110, hi: 620);
  final entryRect = rectOf(entryFinder());
  note('入口行 rect = ${rectStr(entryRect)}');
  ok('① 入口行已滚进安全带', inBand, 'rect=${rectStr(entryRect)}');
  if (!inBand || entryRect == null) {
    await settleOverlays();
    await shoot('01-entry-unreachable');
    say('[T92] RESULT verdict=ENTRY-UNREACHABLE pass=$pass fail=$fail');
    await finish(1);
  }

  await tapAndSettle(entryRect.center);
  await Future<void>.delayed(const Duration(milliseconds: 900));
  await pumpFrame();

  final subUp = await waitUntil(
    () => findWidget(root0, (w) => w is SettingsSubPage) != null,
    timeout: const Duration(seconds: 15),
    label: '二级页挂载',
  );
  ok('① 点入口行 ⇒ 二级页推上来了', subUp);
  final subEl = findWidget(root0, (w) => w is SettingsSubPage);
  if (!subUp || subEl == null) {
    await settleOverlays();
    await shoot('01-subpage-missing');
    say('[T92] RESULT verdict=SUBPAGE-MISSING pass=$pass fail=$fail');
    await finish(1);
  }
  ok('① 二级页里有 SyncPanel（云盘同步面板）',
      findWidget(subEl, (w) => w is SyncPanel) != null);

  // ── ② 点「配置云盘」⇒ 对话框 ──────────────────────────────────────────
  say('');
  say('──────── ② 打开配置对话框 ────────');

  Element? cfgFinder() =>
      findText(subEl, '配置云盘') ?? findText(subEl, '重新配置');

  final cfgBand = await bringIntoBand(subEl, cfgFinder);
  final cfgRect = rectOf(cfgFinder());
  note('配置按钮 rect = ${rectStr(cfgRect)}');
  ok('② 配置按钮可达', cfgBand && cfgRect != null, 'rect=${rectStr(cfgRect)}');
  if (!cfgBand || cfgRect == null) {
    await settleOverlays();
    await shoot('02-config-unreachable');
    say('[T92] RESULT verdict=CONFIG-UNREACHABLE pass=$pass fail=$fail');
    await finish(1);
  }

  await tapAndSettle(cfgRect.center);
  await Future<void>.delayed(const Duration(milliseconds: 700));
  await pumpFrame();

  final dlgUp = await waitUntil(
    () => findWidget(root0, (w) => w is AlertDialog) != null,
    timeout: const Duration(seconds: 10),
    label: 'WebDAV 对话框',
  );
  ok('② 点配置按钮 ⇒ AlertDialog 弹出', dlgUp);
  final dlgEl = findWidget(root0, (w) => w is AlertDialog);
  if (!dlgUp || dlgEl == null) {
    await settleOverlays();
    await shoot('02-dialog-missing');
    say('[T92] RESULT verdict=DIALOG-MISSING pass=$pass fail=$fail');
    await finish(1);
  }

  ok('② 对话框标题 = 「配置云盘（WebDAV）」',
      findText(dlgEl, '配置云盘（WebDAV）') != null);
  ok('② 对话框里恰好 4 个输入框', _fields(dlgEl).length == 4,
      '实际 ${_fields(dlgEl).length}');
  for (final lbl in <String>['服务预设', '地址', '用户名', '密码', '远程目录']) {
    ok('② 对话框字段标签「$lbl」在', findText(dlgEl, lbl) != null);
  }

  // ── ③ ★ 默认态：坚果云 ───────────────────────────────────────────────
  say('');
  say('──────── ③ ★ 默认态（Owner: 「默认也是选择坚果云」）────────');

  final pills = _pills(dlgEl);
  note('对话框里胶囊数 = ${pills.length}');
  for (final p in pills) {
    note('   胶囊「${p.text}」 selected=${p.selected}');
  }

  ok('③ 8 个服务预设都在', pills.length == 8, '实际 ${pills.length}');
  for (final n in kPresetNames) {
    ok('③ 预设「$n」在', pills.any((p) => p.text == n));
  }

  ok('③ ★默认选中「坚果云」', _pillSelected(dlgEl, '坚果云'));
  final others = kPresetNames.where((n) => n != '坚果云').toList();
  final wrongSel = others.where((n) => _pillSelected(dlgEl, n)).toList();
  ok('③ ★另外 7 个预设默认都**未**选中', wrongSel.isEmpty,
      wrongSel.isEmpty ? '' : '误选=$wrongSel');

  note('地址框 = 「${_fieldText(dlgEl, 0)}」');
  ok('③ ★地址框默认已填坚果云地址', _fieldText(dlgEl, 0) == kJianguoUrl,
      '实际「${_fieldText(dlgEl, 0)}」');
  ok('③ 远程目录默认填 sourin', _fieldText(dlgEl, 3) == 'sourin',
      '实际「${_fieldText(dlgEl, 3)}」');
  ok('③ 用户名框默认为空（要用户自己填）', _fieldText(dlgEl, 1).isEmpty);
  ok('③ 密码框默认为空', _fieldText(dlgEl, 2).isEmpty);

  final fs = _fields(dlgEl);
  ok('③ 密码框是 obscureText（不明文显示）', fs[2].obscureText);
  final userHint = fs[1].decoration?.hintText ?? '';
  final passHint = fs[2].decoration?.hintText ?? '';
  note('用户名 hint = 「$userHint」');
  note('密码 hint = 「$passHint」');
  ok('③ 用户名 hint 是坚果云专属文案', userHint.contains('坚果云'), userHint);
  ok('③ 密码 hint 说明要用「第三方应用密码」',
      passHint.contains('应用密码'), passHint);
  ok('③ 坚果云的服务说明在（含「第三方应用管理」）',
      findTextContains(dlgEl, '第三方应用管理') != null);

  await settleOverlays();
  final s1 = await shoot('03-default-jianguo');
  note('截图 ${s1.path}  ${s1.w}x${s1.h}  采样颜色数=${s1.colors}');
  ok('⓪ 截图非退化（>20 色）', s1.colors > 20, '颜色数=${s1.colors}');

  // ── ④ ★ 几何：8 个胶囊排得下吗（只有真机能证）─────────────────────────
  say('');
  say('──────── ④ ★ 几何：胶囊是否真的排得下 ────────');

  /*
   * ★★ 仪器修正（2026-09-29，跑完第一版才发现 —— 第一版这里是**假阳**）：
   *
   * 第一版拿 `rectOf(AlertDialog 元素)` 当"对话框矩形"，实测得到
   *   **(0.0,40.0)-(1280.0,800.0)** —— 那是**整个路由**，不是对话框的边框。
   * 原因：`AlertDialog` 是 StatelessWidget，`findRenderObject()` 会下沉到它
   * 内部**第一个** RenderObjectElement，也就是 `AnimatedPadding` 的盒子；
   * 那个盒子撑满路由，`Dialog` 的居中/限宽发生在**它内部**。
   *
   * ⇒ 拿它当参照会让"胶囊在对话框之内"**恒真**（只要没画到窗口外面），
   *   属于本仓 VERIFY-LESSONS #320 那一类：判据恒真 ⇒ 假阳。
   *   实测读数里 8 个胶囊的 x 跨度是 430.0..800.8，看上去"在 1280 宽里"
   *   当然成立 —— 但那**没有**回答真问题："内容列装得下吗"。
   *
   * ⇒ 改用**地址输入框**的水平跨度当参照。理由：它与胶囊同处一个
   *   `Column`、被拉伸到内容列整宽，是一个**自测量**的真实边界，
   *   不依赖任何硬编码的 420。并额外加一条阳性对照：参照宽度必须
   *   **明显小于**窗口宽度，否则就说明我又拿到了整屏盒子（判据再次失效）。
   */
  const eps = 0.5;
  final winW = s1.w.toDouble(); // 光栅宽度 = 真实逻辑窗口宽（实测值，非推导）
  final fieldPairs = collectPairs(dlgEl, (w) => w is TextField);
  final addrRect = fieldPairs.isEmpty ? null : rectOf(fieldPairs.first.el);
  note('窗口逻辑宽 = ${winW.toStringAsFixed(1)}  （来自截图光栅 ${s1.w}x${s1.h}）');
  note('地址框 rect = ${rectStr(addrRect)}');
  ok('④ 拿到地址框几何（内容列宽度的自测量参照）',
      addrRect != null && addrRect.width > 100, 'rect=${rectStr(addrRect)}');
  if (addrRect == null) {
    say('[T92] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  // ★ 阳性对照：参照框必须是"内容列"，不能又是"整屏"，否则本节判据失效
  ok('④ ★阳性对照：参照框宽度**明显小于**窗口宽度（证明它真是内容列，'
      '不是又一次拿到整屏盒子）',
      addrRect.width < winW - 100,
      '参照宽=${addrRect.width.toStringAsFixed(1)}  窗口宽=${winW.toStringAsFixed(1)}');

  final refL = addrRect.left;
  final refR = addrRect.right;
  note('内容列水平范围 = ${refL.toStringAsFixed(1)} .. ${refR.toStringAsFixed(1)}'
      '  （宽 ${(refR - refL).toStringAsFixed(1)}）');

  final pillRects = <String, Rect>{};
  for (final n in kPresetNames) {
    final r = rectOf(_pillEl(dlgEl, n));
    if (r != null) pillRects[n] = r;
    note('   胶囊「$n」 rect = ${rectStr(r)}');
  }
  ok('④ 8 个胶囊的几何**全部**拿得到', pillRects.length == 8,
      '实际 ${pillRects.length}');

  // ④-a 每个胶囊都在**内容列**的左右边界之内（这才是"排得下"）
  final outside = <String>[];
  var maxRight = 0.0;
  for (final e in pillRects.entries) {
    final r = e.value;
    if (r.right > maxRight) maxRight = r.right;
    if (r.left < refL - eps || r.right > refR + eps) {
      outside.add('${e.key}${rectStr(r)}');
    }
  }
  note('胶囊最右沿 = ${maxRight.toStringAsFixed(1)}  '
      '内容列右沿 = ${refR.toStringAsFixed(1)}  '
      '余量 = ${(refR - maxRight).toStringAsFixed(1)}px');
  ok('④ ★8 个胶囊**全部**落在内容列的左右边界之内（没有被静默裁掉）',
      outside.isEmpty, outside.isEmpty ? '' : '越界=$outside');

  // ④-b 胶囊两两不相交
  final names = pillRects.keys.toList();
  final overlaps = <String>[];
  for (var i = 0; i < names.length; i++) {
    for (var j = i + 1; j < names.length; j++) {
      final a = pillRects[names[i]]!;
      final b = pillRects[names[j]]!;
      final inter = a.intersect(b);
      if (inter.width > 0.5 && inter.height > 0.5) {
        overlaps.add('${names[i]}×${names[j]}');
      }
    }
  }
  ok('④ ★胶囊两两不相交（Wrap 没有把它们叠在一起）', overlaps.isEmpty,
      overlaps.isEmpty ? '' : '重叠=$overlaps');

  // ④-c 行数 + 对话框纵向是否够用
  final rows = <double, List<String>>{};
  for (final e in pillRects.entries) {
    rows.putIfAbsent(e.value.top.roundToDouble(), () => <String>[]).add(e.key);
  }
  note('胶囊排成 ${rows.length} 行：');
  for (final e in (rows.keys.toList()..sort())) {
    note('   y=${e.toStringAsFixed(0)}  →  ${rows[e]!.join(" / ")}');
  }
  ok('④ 胶囊排成 ≥2 行（证明 Wrap 真的在换行，不是全挤一行溢出）',
      rows.length >= 2, '行数=${rows.length}');

  /*
   * ④-d ★ 判据灵敏度自检 —— 这一条是**本节修正的存在理由**。
   *
   * ★★ 2026-09-29 第二版修正：第一版把参照右沿"收窄 1px"（850→849）就断言
   *    最右胶囊该被判越界 —— **红了一条，但那是我的仪器错，不是产品错**：
   *    最右胶囊右沿是 800.8，收窄到 849.0 仍然远在它右边 ⇒ 当然不越界。
   *    我等于**构造了一条不可能满足的自检**（VERIFY-LESSONS #361 同类：
   *    判据瞄在真实信号之外）。固定步长的扰动**恰好**只在余量 <1px 时才有意义，
   *    而余量是数据，不是常数。
   *
   * ⇒ 正确写法：把阈值**压过被测值本身**，两侧各跨一次：
   *    · 阈值 = 最右胶囊右沿 − 1px ⇒ **必须**判越界（证明它真的读了这个数）
   *    · 阈值 = 最右胶囊右沿 + 1px ⇒ **必须不**判越界（证明它不是恒真）
   *   这样无论余量是多少，两侧都有反应 —— 才是真正的灵敏度证明。
   */
  if (pillRects.isNotEmpty) {
    final probeRect = pillRects.values
        .reduce((a, b) => a.right >= b.right ? a : b); // 最右的胶囊
    bool flags(double rightLimit) =>
        probeRect.left < refL - eps || probeRect.right > rightLimit + eps;

    ok('④ ★灵敏度自检：参照右沿压到最右胶囊**之内**（−1px）⇒ 判越界（判据会红）',
        flags(probeRect.right - 1),
        '最右胶囊右沿=${probeRect.right.toStringAsFixed(1)}  '
        '参考阈值=${(probeRect.right - 1).toStringAsFixed(1)}');
    ok('④ ★反面自检：参照右沿放到最右胶囊**之外**（+1px）⇒ 不判越界'
        '（证明判据真在比这两个数，不是恒真）',
        !flags(probeRect.right + 1));
    note('（这两条与余量大小无关 —— 第一版按固定 1px 扰动之所以误报，'
        '就是因为余量有 ${(refR - maxRight).toStringAsFixed(1)}px 而扰动只有 1px）');
  }

  final dlgScroll = scrollableIn(dlgEl);
  final dlgPos = dlgScroll?.position;
  final hasDims = dlgPos != null && dlgPos.hasContentDimensions;
  note('对话框内容可滚区间 = '
      '${hasDims ? "0..${dlgPos.maxScrollExtent.toStringAsFixed(1)}px" : "(无/未知)"}');
  ok('④ ★对话框内容装得下（内容列不可滚 ⇒ 没有任何字段被顶出可视区）',
      hasDims && dlgPos.maxScrollExtent <= 0.5,
      'maxScrollExtent=${hasDims ? dlgPos.maxScrollExtent.toStringAsFixed(1) : "?"}');

  // ── ⑤ ★ 活性：点别的预设 ⇒ 真的自动填充 ──────────────────────────────
  say('');
  say('──────── ⑤ ★ 活性：点击预设是否真的自动填充 ────────');

  const synologyUrl = 'https://<主机>:5006/';

  Future<void> tapPill(String name) async {
    final r = rectOf(_pillEl(dlgEl, name));
    if (r == null) {
      ok('⑤ 胶囊「$name」可点', false, 'rect=null');
      return;
    }
    await tapAndSettle(r.center);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await pumpFrame();
  }

  await tapPill('群晖 NAS');
  note('点「群晖 NAS」后 地址框 = 「${_fieldText(dlgEl, 0)}」');
  ok('⑤ ★点「群晖 NAS」⇒ 地址框被自动填充成群晖地址',
      _fieldText(dlgEl, 0) == synologyUrl, '实际「${_fieldText(dlgEl, 0)}」');
  ok('⑤ 选中态转移到「群晖 NAS」', _pillSelected(dlgEl, '群晖 NAS'));
  ok('⑤ 此时「坚果云」不再是选中态', !_pillSelected(dlgEl, '坚果云'));
  final synUserHint = _fields(dlgEl)[1].decoration?.hintText ?? '';
  note('群晖下 用户名 hint = 「$synUserHint」');
  ok('⑤ 用户名 hint 跟着预设变（群晖 ⇒ DSM 用户名）',
      synUserHint.contains('DSM'), synUserHint);
  ok('⑤ 群晖的服务说明在（含「套件中心」）',
      findTextContains(dlgEl, '套件中心') != null);

  await settleOverlays();
  final s2 = await shoot('05-synology-selected');
  note('截图 ${s2.path}  颜色数=${s2.colors}');

  // 点回坚果云
  await tapPill('坚果云');
  note('点回「坚果云」后 地址框 = 「${_fieldText(dlgEl, 0)}」');
  ok('⑤ ★点回「坚果云」⇒ 地址框复原', _fieldText(dlgEl, 0) == kJianguoUrl,
      '实际「${_fieldText(dlgEl, 0)}」');
  ok('⑤ 选中态回到「坚果云」', _pillSelected(dlgEl, '坚果云'));
  ok('⑤ 远程目录没被预设覆盖（仍是 sourin）',
      _fieldText(dlgEl, 3) == 'sourin', '实际「${_fieldText(dlgEl, 3)}」');

  // ── ⑥ ★ 占位符拦截（只走提前返回分支，零副作用）───────────────────────
  say('');
  say('──────── ⑥ ★ 占位符拦截 ────────');

  await tapPill('Nextcloud');
  final ncUrl = _fieldText(dlgEl, 0);
  note('Nextcloud 地址框 = 「$ncUrl」');
  ok('⑥ 点「Nextcloud」⇒ 地址框是含占位符的模板',
      ncUrl.contains('<') && ncUrl.contains('>'), ncUrl);

  /*
   * ★ 唯一一处合成输入：直接给 controller 赋值（不碰真键盘）。
   *   产品代码里「保存并测试」先判 `user.isEmpty` 再判占位符，
   *   所以用户名必须非空才能走到占位符分支。**此处如实披露**。
   */
  _fields(dlgEl)[1].controller?.text = 'probe-user';
  await pumpFrame();
  note('★ 合成输入：用户名框被直接赋值为「probe-user」（框架层，未碰键盘）');

  final saveEl = findText(dlgEl, '保存并测试');
  final saveRect = rectOf(saveEl);
  ok('⑥ 「保存并测试」按钮可点', saveRect != null,
      'rect=${rectStr(saveRect)}');
  if (saveRect != null) {
    await tapAndSettle(saveRect.center);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await pumpFrame();

    ok('⑥ ★点「保存并测试」⇒ 对话框**没有**关闭（被占位符判据拦住了）',
        findWidget(root0, (w) => w is AlertDialog) != null);
    ok('⑥ ★出现「占位符」提示',
        findTextContains(root0, '占位符') != null);
    note('提示原文 = 「${textContaining(root0, "占位符")}」');

    await settleOverlays();
    final s3 = await shoot('06-placeholder-guard');
    note('截图 ${s3.path}  颜色数=${s3.colors}');
  }

  // ── ⑦ 取消 ⇒ 关闭，且从未真正发起配置 ─────────────────────────────────
  say('');
  say('──────── ⑦ 取消 ────────');

  final dlgStill = findWidget(root0, (w) => w is AlertDialog);
  final cancelEl = dlgStill == null ? null : findText(dlgStill, '取消');
  final cancelRect = rectOf(cancelEl);
  ok('⑦ 取消按钮可点', cancelRect != null, 'rect=${rectStr(cancelRect)}');
  if (cancelRect != null) {
    await tapAndSettle(cancelRect.center);
    final gone = await waitUntil(
      () => findWidget(root0, (w) => w is AlertDialog) == null,
      timeout: const Duration(seconds: 10),
      label: '对话框关闭',
    );
    ok('⑦ 点取消 ⇒ 对话框关闭', gone);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await pumpFrame();

    ok('⑦ ★全程**从未**出现「配置失败」文案（反证 ⑥ 的点击真被拦住、'
        '没有漏到 configureWebdav）',
        findTextContains(root0, '配置失败') == null);
    ok('⑦ 二级页仍在（取消没有把路由弹掉）',
        findWidget(root0, (w) => w is SettingsSubPage) != null);
  }

  // ── 判词 ──────────────────────────────────────────────────────────────
  //
  // ★ 这里**不能**再走 `dlgEl`：⑦ 已经把对话框关掉了，那个 Element 已经是
  //   失效的（defunct）—— 再遍历它会读到过期/空树，判词会静默失真。
  //   所以用**前面已经取下来**的 widget 快照（`pills`）与几何读数。
  final defaultIsJianguo = pills.isNotEmpty &&
      pills.first.text == '坚果云' &&
      pills.first.selected;
  say('');
  say('判词: tag=$_tag  胶囊=${pills.length} 个  行数=${rows.length}  '
      '首个预设=${pills.isEmpty ? "(无)" : pills.first.text}  '
      '默认选中坚果云=$defaultIsJianguo');
  say('[T92] RESULT tag=$_tag pass=$pass fail=$fail');
  await finish(fail == 0 ? 0 : 1);
}
