/*
 * t84 —— 「搜索页灰带」修复的真机取证（**同仪器 A/B**）
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Owner 原话（m11605，附裁剪图）：「这里有一块阴影,搜索这里」
 *
 * ── 缺陷 ─────────────────────────────────────────────────────────────────
 * 搜索页顶部有一条 70px 高的灰色横带（搜索框背后），与下方纯白内容区
 * 形成一个**可见台阶**。实测（PrintWindow 逐像素，1280x800）：
 *   · 灰带  y=118..187（70px）  颜色 rgb(238,240,246) = #EEF0F6
 *   · 下方  其余内容区          颜色 rgb(255,255,255) = #FFFFFF
 *   · 几何自证：`_searchBarHeight(50) + AppMetrics.homeTopPadding(20) = 70`
 *     恰等于灰带高度 ⇒ 灰带**就是**那条吸顶搜索条。
 *
 * ── 根因（两个真相来源）──────────────────────────────────────────────────
 *   · 吸顶条  `lib/ui/search_page.dart:464 background: colors.surface`
 *             ⇒ `LightTokens.bgBase` = **#EEF0F6**
 *   · 页面底色 `lib/shell.dart` 的 `FScaffold` 用 forui 默认
 *             ⇒ `FScaffoldStyle.inherit` 取 `colors.background`
 *             ⇒ forui `neutral.light.background` = **#FFFFFF**
 *   浅色下两者**不等价** ⇒ 台阶。深色下两者都是 #0A0A0A ⇒ 零视觉差
 *   （这正是缺陷一直被掩盖的原因：此前所有交付截图都是深色）。
 *
 * ── 修法（H1）────────────────────────────────────────────────────────────
 *   `lib/shell.dart:2929-2931` 给 `FScaffold` 传
 *   `scaffoldStyle: FScaffoldStyleDelta.delta(
 *      backgroundColor: Theme.of(context).colorScheme.surface)`
 *   ⇒ 页面底色与吸顶条**逐字同源**，无论明暗都保证
 *   「吸顶条 == 页面底色」这个**不变量**。
 *   样板实证：`lib/ui/widgets/settings_sub_page.dart` 已经用同一个表达式
 *   同时当页面底色（`:130`）与吸顶条底色（`:254`）⇒ 该页**没有**灰带。
 *
 * ── 为什么必须真机取证，不能只靠 flutter test ──────────────────────────────
 *   · `SettingsPage` / `SourinApp` 在 `flutter test` 里**挂不上**：
 *     `build()` 走到 `${SourinApi.version}` ⇒ `DynamicLibrary.open(
 *     'sourin_core.dll')` ⇒ 整棵子树被换成 `ErrorWidget`（本仓已记录）。
 *   · 「灰带」是**光栅化**命题 —— 两个颜色的差值只有真窗口才存在。
 *   · `toImage()` 在 `flutter test` 里挂死，在真进程里正常。
 *
 * ── 判据（每一条都必须有对照）────────────────────────────────────────────
 *   ⓪ 仪器自检：shell 挂上 / 根元素在 / 隔离目录 / 截图非退化（>20 色）。
 *   ① 页面身份：树里找得到 `Text('搜索')` 与 `Text('同时搜索全部已启用内容源')`
 *      + 找得到 `EditableText`（搜索框真的渲染了）。
 *   ② **核心不变量**：左/右**页边距列**（x=20 与 x=1260 —— 落在吸顶条
 *      水平跨度 x=12..1267 之内、搜索框之外，见 `kMarginColL` 的注释）
 *      从吸顶带中部到视口底部**只有 1 种颜色**，且该颜色 == **#EEF0F6**。
 *      ★ 修前这两列会有 2 种颜色（带内 #EEF0F6 / 带外 #FFFFFF）⇒ 台阶。
 *   ③ **台阶读数**：`(x=20, y=150)` 与 `(x=20, y=250)` 的逐通道差，必须为 0。
 *   ④ **阴性对照（仪器灵敏度）**：顶部标题栏区（y=0..30）的颜色**必须
 *      不同于**页面底色 —— 否则说明扫描根本分辨不出区域，②的"只有1种颜色"
 *      是假绿。
 *   ⑤ **阳性对照（页面真的渲染了内容）**：搜索框内部颜色**必须不同于**
 *      页面底色（否则整页一片死色，②也可能被"全白"骗过）。
 *   ⑥ 全幅宽度剖面：y=150 行的游程编码（RLE），如实报告灰带的 x 范围。
 *
 * ── A/B 设计 ─────────────────────────────────────────────────────────────
 *   同一个探针源码、同一个隔离数据目录、同一个窗口尺寸，只换
 *   `lib/shell.dart` 一个变量（有/无 `scaffoldStyle:`），各 build 一次。
 *   `--dart-define=T84_TAG=<fixed|prefix>` 给产物打标签，两次不互相覆盖。
 *   ★ 只有这样才能说「读数变了是因为那一行」，而不是因为仪器/环境变了。
 *
 * ── 仪器纪律（本仓血泪）──────────────────────────────────────────────────
 *   · `exit()` **不展开 finally** ⇒ 每条退出路径先 `finish()` 落产物。
 *   · 外壳直接用**生产本体** `SourinApp`（不是复刻）⇒ `FTheme → FScaffold
 *     → Material(transparency)` 天然满足；复刻漏 `Material` 层会让
 *     `InkWell` 抛 `Null check operator used on a null value` 并把整页换成
 *     ErrorWidget，真因只在 stderr。
 *   · 滚动条 / 文本光标都是**瞬时叠加层**（#328/#330）⇒ 取样前 settle。
 *   · 绝不动 Owner 的鼠标：本探针**只**用 `debugSwitchTo` 程序化切页。
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
import 'core/ui_prefs.dart';
import 'shell.dart';
import 'ui/app_theme.dart';

// ══════════════════════════════════════════════════════════════════════════
// 常量
// ══════════════════════════════════════════════════════════════════════════

const String _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

/// A/B 标签：`fixed` = 含修复；`prefix` = 修前（无 scaffoldStyle:）。
const String _tag = String.fromEnvironment('T84_TAG', defaultValue: 'unknown');

/// 页面底色应有的值 —— 来自**原版 Tauri 浅色主题**
/// `D:\WishProject\cctv_to_client\src\design\theme-light.css:32`
///   `--bg-base: #eef0f6;`
/// 与 `lib/ui/app_theme.dart` 的 `LightTokens.bgBase` 逐字一致。
const int kExpectedBg = 0xEEF0F6;

/// 修前页面底色 = forui `neutral.light.background`
/// （`forui-0.27.0\lib\src\theme\colors.dart:144`）
const int kForuiWhite = 0xFFFFFF;

/// 取样列：必须落在**吸顶条的水平跨度之内**、又在搜索框之外。
///
/// ★★★ 这两个数字是**量出来的**，不是猜的 —— 而且第一版猜错了：
///   第一版取 `x=8` / `x=1272`，prefix 臂两次断言都读成 `#FFFFFF`
///   并打印 `台阶=无` —— 而同一张图的 ⑥ RLE 明明显示 `y=150` 处
///   `x=12..37` 是 `#EEF0F6`。**仪器瞄在了条带外面**，差点给出假绿。
///   实测（本探针 ⑥ 的 RLE，y=150，1280 宽）：
///     ```text
///     x=0..11      #FFFFFF   ← 窗口内边距（结构性，两臂都一样）
///     x=12..37     #EEF0F6   ← 吸顶条**左段**  ← 取样列必须落在这里
///     x=38..1241   搜索框（边框 #E0E2E9 / 内部 #F0F2F7 / 按钮 #D7D9DE）
///     x=1242..1267 #EEF0F6   ← 吸顶条**右段**  ← 取样列必须落在这里
///     x=1268..1279 #FFFFFF   ← 窗口内边距
///     ```
///   ⇒ 取 `20` 与 `1260`：距条带外缘 8px、距搜索框 ≥1px，
///     两侧都不挨着任何抗锯齿边缘。
const int kMarginColL = 20;
const int kMarginColR = 1260;

/// 吸顶带中部 / 带外（下方）—— 台阶读数用的两个 y。
/// 灰带实测 y=118..187；取 150 在带内、250 在带外。
const int kYInBand = 150;
const int kYBelowBand = 250;

/// 左列"只应有 1 种颜色"的扫描范围（从吸顶带上方到视口中部）。
const int kColScanY0 = 60;
const int kColScanY1 = 620;

// ══════════════════════════════════════════════════════════════════════════
// 计数 / 日志
// ══════════════════════════════════════════════════════════════════════════

int pass = 0;
int fail = 0;
final List<String> _log = <String>[];

void say(String s) {
  _log.add(s);
  debugPrint('[T84] $s');
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
  final f = File('$_outDir\\t84-greyband-$_tag.txt');
  try {
    f.writeAsStringSync('${_log.join('\n')}\n');
  } catch (e) {
    debugPrint('[T84] ★ 产物写入失败: $e');
  }
  debugPrint('[T84] 产物 = ${f.path}  ${f.existsSync() ? f.lengthSync() : -1} B');
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

bool hasEditableText(Element root) =>
    findWidget(root, (w) => w is EditableText) != null;

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

/// 滚动条 600ms 等待 + 300ms 淡出；文本光标闪烁也是瞬时叠加层
/// （VERIFY-LESSONS #328 / #330）⇒ 取像素前先让它静下来。
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
  final path = '$_outDir\\t84-$_tag-$name.png';
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

/// 某一行的游程编码（颜色 → 该颜色的 x 区间列表），用来量灰带 x 范围。
List<String> rowRle(Shot s, int y) {
  final out = <String>[];
  var start = 0;
  var cur = s.px(0, y);
  for (var x = 1; x < s.w; x++) {
    final c = s.px(x, y);
    if (c != cur) {
      out.add('x=$start..${x - 1} ${hex(cur)}');
      start = x;
      cur = c;
    }
  }
  out.add('x=$start..${s.w - 1} ${hex(cur)}');
  return out;
}

/// 逐通道差的最大绝对值（0 = 两个像素逐字节相同）。
int maxChannelDelta(Shot s, int x, int y1, int y2) {
  final a = s.px(x, y1);
  final b = s.px(x, y2);
  var m = 0;
  for (var sh = 0; sh < 24; sh += 8) {
    final d = (((a >> sh) & 0xFF) - ((b >> sh) & 0xFF)).abs();
    if (d > m) m = d;
  }
  return m;
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
   * ★ 强制浅色，理由必须写清楚（不是随手设的）：
   *   用户真实 `ui-prefs.json` **没有 `dsh.theme` 键** ⇒ `AppTheme.mode`
   *   回落 `AppThemeMode.system`；本机系统就是浅色 ⇒ 他看到的**就是浅色**。
   *   探针显式设成 light 只是**去掉"跑的那一刻系统主题"这个外部变量**，
   *   渲染结果与用户配置**等价**。
   *   ★ 隔离目录里的写入，不碰用户真实偏好文件。
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
     *   size 1280x800 / minimumSize 900x600 / center /
     *   titleBarStyle: TitleBarStyle.hidden / backgroundColor: transparent。
     *
     * ⚠️ 为什么必须一致 —— 不是"顺手抄一份"：
     *   `titleBarStyle: TitleBarStyle.hidden` 会**去掉系统标题栏**，
     *   于是自绘的 `_TitleBarHost` 才占得住顶部那 ~39px。
     *   若这里用默认的 `TitleBarStyle.normal`，系统标题栏会**吃掉**
     *   客户区高度，渲染出来的帧与用户看到的**不是同一个东西**
     *   ⇒ A/B 读数不可比，②③ 的 y 坐标也全部错位。
     *
     * ⚠️ 刻意**不**调 `windowManager.focus()`（生产那里有，
     *   `shell.dart:399`）—— 那会抢走 Owner 当前窗口的焦点。
     *
     * ★ 为什么必须 `show()`：窗口不可见时 Flutter 引擎可能整帧不产出，
     *   `toImage()` 就会拿到退化图；而"全黑"会被判据 ② 误读成
     *   "只有 1 种颜色"（假绿）。判据 ⓪ 的 >20 色自检也会兜住这一层。
     */
    /*
     * `const` 是可行的：`_tag` 是 `String.fromEnvironment`（编译期常量），
     * 其插值也是常量表达式 ⇒ 分析器不再报 prefer_const_constructors。
     * ★ 标题带上 tag，方便 A/B 两次运行在任务栏/截图里一眼区分。
     */
    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(900, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
      title: '源影 · t84 灰带取证 ($_tag)',
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
  debugPrint('[T84] ══════ 搜索页灰带 —— 真机取证 tag=$_tag ══════');

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
    say('[T84] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  final root0 = _rootKey.currentContext as Element?;
  ok('⓪ 根元素已挂上', root0 != null);
  if (root0 == null) {
    say('[T84] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  ok('⓪ 数据目录是隔离目录（含 .probe，绝不写用户库）',
      dir.toLowerCase().contains('.probe'), dir);
  if (!dir.toLowerCase().contains('.probe')) {
    say('★ 不是隔离目录 ⇒ 立刻中止');
    await finish(1);
  }

  note('AppTheme.rawStored = ${AppTheme.rawStored}');
  note('AppTheme.mode      = ${AppTheme.mode}');

  // ── ① 程序化切到搜索页（**不碰鼠标**）─────────────────────────────────
  say('');
  say('──────── ① 切到搜索页 ────────');

  final dynamic shell = debugShellKey.currentState;
  shell.debugSwitchTo(AppTab.search);
  await Future<void>.delayed(const Duration(milliseconds: 1400));
  await pumpFrame();

  final titleUp = await waitUntil(
    () => findText(root0, '搜索') != null,
    timeout: const Duration(seconds: 30),
    label: '搜索页标题',
  );
  ok('① 搜索页已渲染（树里有 Text("搜索")）', titleUp);
  ok('① 副标题在（Text("同时搜索全部已启用内容源")）',
      findText(root0, '同时搜索全部已启用内容源') != null);
  ok('① 搜索框真的渲染了（树里有 EditableText）', hasEditableText(root0));
  note('元素数 = ${elementCount(root0)}');

  if (!titleUp) {
    final s = await shoot('00-instrument-failure');
    note('失败现场 ${s.path} 颜色数=${s.colors}');
    say('★ 搜索页没渲染 ⇒ 中止');
    say('[T84] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  await settleOverlays();
  final s = await shoot('01-search');
  note('截图 ${s.path}  ${s.w}x${s.h}  采样颜色数=${s.colors}');
  ok('⓪ 截图非退化（>20 色）', s.colors > 20, '颜色数=${s.colors}');

  // ── ② 页边距列的颜色直方图（核心不变量）──────────────────────────────
  say('');
  say('──────── ② 页边距列：从吸顶带到视口中部 ────────');

  for (final x in <int>[kMarginColL, kMarginColR]) {
    final hist = columnColors(s, x, kColScanY0, kColScanY1);
    final desc = (hist.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .map((e) => '${hex(e.key)}(${rgbOf(e.key)}) × ${e.value} 行')
        .join('  |  ');
    note('x=$x  y=$kColScanY0..${kColScanY1 - 1}  ⇒ ${hist.length} 种颜色: $desc');
    ok('② x=$x 整列只有 1 种颜色（吸顶条与页面底色**无台阶**）',
        hist.length == 1, '实际 ${hist.length} 种');
    ok('② x=$x 该颜色 == 期望页面底色 ${hex(kExpectedBg)}（原版 --bg-base）',
        hist.length == 1 && hist.keys.first == kExpectedBg,
        '实际 ${hist.keys.map(hex).join(",")}');
  }

  // ── ③ 台阶读数（用户看到的那个差）─────────────────────────────────────
  say('');
  say('──────── ③ 台阶读数：(x,150) 带内 vs (x,250) 带外 ────────');

  for (final x in <int>[kMarginColL, kMarginColR, 640]) {
    final a = s.px(x, kYInBand);
    final b = s.px(x, kYBelowBand);
    final d = maxChannelDelta(s, x, kYInBand, kYBelowBand);
    note('x=$x  y=$kYInBand ${hex(a)}  y=$kYBelowBand ${hex(b)}  最大逐通道差=$d');
    if (x != 640) {
      // x=640 在带内落在搜索框上，天然不同 ⇒ 只对页边距列断言
      ok('③ x=$x 带内与带外**逐通道相同**（台阶 = 0）', d == 0, '实际差=$d');
    }
  }

  // ── ④ 阴性对照：仪器能分辨区域吗 ──────────────────────────────────────
  say('');
  say('──────── ④ 阴性对照（仪器灵敏度）────────');

  final titleBar = s.px(640, 15);
  final pageBg = s.px(kMarginColL, kYBelowBand);
  note('标题栏 (640,15) = ${hex(titleBar)} ${rgbOf(titleBar)}');
  note('页面底色 (8,250) = ${hex(pageBg)} ${rgbOf(pageBg)}');
  ok('④ 标题栏颜色**不同于**页面底色（证明扫描分辨得出区域，②不是假绿）',
      titleBar != pageBg);

  // ── ⑤ 阳性对照：搜索框真的画在底色上 ──────────────────────────────────
  say('');
  say('──────── ⑤ 阳性对照（内容真的渲染了）────────');

  // 搜索框内部：带中部、x 取内容区左侧往里一点（框内空白处）
  final boxIn = s.px(200, kYInBand);
  note('搜索框内部 (200,150) = ${hex(boxIn)} ${rgbOf(boxIn)}');
  ok('⑤ 搜索框内部颜色**不同于**页面底色（不是整页一片死色）',
      boxIn != pageBg, '框内=${hex(boxIn)} 底色=${hex(pageBg)}');

  // ── ⑥ 全幅剖面：如实报告灰带的 x 范围 ────────────────────────────────
  say('');
  say('──────── ⑥ y=150 行游程编码（全幅 1280px）────────');
  for (final seg in rowRle(s, kYInBand)) {
    note(seg);
  }
  say('');
  say('──────── ⑥ y=250 行游程编码（带外，对照）────────');
  for (final seg in rowRle(s, kYBelowBand)) {
    note(seg);
  }

  // ── 判词 ──────────────────────────────────────────────────────────────
  say('');
  final stepped = columnColors(s, kMarginColL, kColScanY0, kColScanY1).length > 1;
  say('判词: tag=$_tag  页边距列颜色数=${columnColors(s, kMarginColL, kColScanY0, kColScanY1).length}'
      '  带内=${hex(s.px(kMarginColL, kYInBand))}  带外=${hex(s.px(kMarginColL, kYBelowBand))}'
      '  台阶=${stepped ? "有" : "无"}');
  say('[T84] RESULT tag=$_tag verdict=${stepped ? "STEP-PRESENT" : "NO-STEP"}'
      ' pass=$pass fail=$fail');
  await finish(fail == 0 ? 0 : 1);
}
